# ax2012-aos-crash-triage — Reference

Detailed reference for `scripts/Invoke-AosCrashTriage.ps1`. For the agent-facing workflow see
[SKILL.md](SKILL.md).

## Requirements

- **PowerShell 7+** (`pwsh`) on the operator machine (uses `ForEach-Object -Parallel`).
- **WinRM / PowerShell Remoting** on every AOS and client/RDS target.
- A credential that can read **System + Application** logs and query **services** on the
  targets. Always prompted; never stored.

## Parameters

| Parameter | Type | Default | Notes |
|-----------|------|---------|-------|
| `-AosComputerName` | string[] | — | AOS servers (client and/or batch AOS). Required (with or without `-AosListFile`). |
| `-ClientComputerName` | string[] | — | Optional RDS/Citrix session hosts running the AX rich client, for cascade correlation. |
| `-AosListFile` / `-ClientListFile` | string | — | One host per line; `#` comments and blanks ignored. |
| `-Hours` | int | 24 | Look-back window. **Computed on each target** (time-zone safe). |
| `-CascadeWindowSeconds` | int | 120 | A client crash counts toward an AOS event if within ± this many seconds. |
| `-MaxEvents` | int | 2000 | Cap per query per host. Hitting it sets `truncated: true`. |
| `-MaxMessageLength` | int | 600 | Truncates each captured message. |
| `-ThrottleLimit` | int | 8 | Max hosts queried in parallel. |
| `-OutFile` | string | — | Full JSON to file; stdout becomes the compact view. |
| `-UseSSL` | switch | off | WinRM over HTTPS (5986). |
| `-Authentication` | string | `Default` | `Default`/`Negotiate`/`Kerberos`/`Basic`/`CredSSP`. |
| `-Credential` | pscredential | — | Test/automation seam only. Omit → prompted. |

## What it collects (per host, server-side)

- **AOS service(s):** `Get-Service` where name `AOS60*` or display name `*Object Server*`.
- **AOS process crashes:** Application **event 1000** whose message names `Ax32Serv.exe`
  (faulting app/module, exception code, fault offset extracted).
- **Unexpected terminations:** System **event 7031** mentioning *Object Server*.
- **Session precursors:** Application **events 110 / 180** from provider `Dynamics Server*`
  (110 = "Session Allocation Failed: Session N is already allocated"; 180 = "RPC error:
  Client provided an invalid session ID").
- **Client crashes (client hosts):** Application **event 1000** naming `Ax32.exe`.

## Output schema (abridged)

```json
{
  "status": "ok | partial | error",
  "generated_at": "2026-06-17T10:00:00Z",
  "query": { "aos_hosts": 2, "client_hosts": 9, "window_hours": 24, "cascade_window_seconds": 120, "max_events_per_query": 2000 },
  "aos": [
    {
      "computer": "AOS02", "role": "aos", "status": "ok",
      "aos_services": [ { "Name": "AOS60$01", "Status": "Running", "StartType": "Automatic" } ],
      "lastboot": "2026-05-23T20:32:30Z",
      "crashes": [ { "t": "2026-06-17T08:33:57Z", "app": "Ax32Serv.exe", "module": "KERNELBASE.dll", "exception": "0xc0000005", "offset": "0x0000000000026ea8" } ],
      "terminations": [ { "t": "2026-06-17T08:38:18Z" } ],
      "session_errors": { "count": 11, "first": "…", "last": "…", "by_id": [ { "event_id": 110, "count": 2 }, { "event_id": 180, "count": 9 } ], "sample": "Object Server 01: Session Allocation Failed: Session 277 is already allocated." },
      "events_scanned": 14, "truncated": false
    }
  ],
  "clients": [
    { "computer": "RDS01", "role": "client", "status": "ok", "client_crash_count": 10, "client_crashes": [ { "t": "2026-06-17T08:38:17Z", "module": "Ax32.exe", "exception": "0xc0000005" } ], "truncated": false }
  ],
  "summary": {
    "aos_hosts_total": 2, "hosts_failed": 0,
    "aos_crash_total": 3, "hosts_with_crashes": 2, "session_error_total": 18, "client_crash_total": 96,
    "crash_timeline": [ { "computer": "AOS02", "type": "aos_crash", "time": "2026-06-17T08:33:57Z", "detail": "0x…26ea8" } ],
    "cascade_correlation": [ { "aos_event": "AOS02 aos_terminated @ 2026-06-17T08:38:18Z", "client_crashes_in_window": 7, "client_hosts": ["RDS01","RDS03"] } ],
    "failures": []
  }
}
```

With `-OutFile`, the file holds the full object; **stdout** holds status/query/summary +
a `note`, without per-host `aos[]`/`clients[]`.

## AX interpretation guide

| Signal | Likely meaning | What to do |
|--------|----------------|-----------|
| `crashes[].offset` **identical** across every crash | A **deterministic AX kernel code path** (e.g. session allocation), not random memory corruption | Treat as a known-class kernel defect; capture a dump (WER LocalDumps for `Ax32Serv.exe`) for Microsoft to name the hotfix |
| `session_errors` (110/180) seconds **before** a crash | The trigger: **stale/duplicate RPC session IDs** the kernel can't reconcile → it self-terminates | Hunt the orphaned-session source (below); the crash is the symptom |
| `cascade_correlation` shows many client crashes at an AOS termination time | The clients dropped **because the AOS died** (not a client fault); the reconnect storm can re-trigger the crash | Break the loop with a coordinated AOS restart; don't chase the client machines |
| Crashes confined to **client** AOS, batch AOS clean | The cascade is driven by interactive RDS-client reconnects | Focus on the client-AOS nodes and the RDS farm, not the batch tier |
| "Session N is **already allocated**" | Orphaned rows in **`SysClientSessions`** (often left by a brief AOS↔DB network blip); another AOS reuses an in-use ID | Clean orphaned sessions (stop AOS → delete STATUS 0/2/3 → start; stale STATUS=1 needs the cluster briefly down); stabilize the AOS↔DB path |

## Gotchas

These are the AX-specific and operational traps that produce confident-but-wrong conclusions.

**Cause/effect runs AOS → clients, not the reverse.** Seeing ~100 `Ax32.exe` client crashes
is alarming, but if they cluster at the **same second** across many RDS hosts they are the
*consequence* of the central AOS terminating, not independent client faults. The
`cascade_correlation` block exists to make this explicit — read it before blaming the
clients or the RDS farm. The first domino is the **first** AOS crash in `crash_timeline`; what
preceded *that* (the 110/180 session errors, or an AOS↔DB blip) is the real trigger.

**An identical fault offset is a feature, not noise.** When every `crashes[].offset` is the
same value, that is the strongest signal in the report: the process dies on one specific code
path every time (deterministic), which points at a kernel defect with a potential Microsoft
hotfix — *not* at flaky hardware/memory. Do not dismiss repeated identical crashes as
"random".

**"Session already allocated" is a kernel self-protection kill, and is usually a DB-link
symptom.** The AX kernel deliberately terminates the AOS when it detects an already-allocated
session — it is not a memory crash. The orphaned `SysClientSessions` rows that cause it are
frequently left behind by a **brief AOS↔database network interruption** that is too short to
log a SQL error or trip an AlwaysOn AG. So "the database looked healthy" does **not** exclude
the DB/network path as the trigger — check `SysClientSessions` for stale STATUS=1 rows and
harden the AOS↔DB link.

**Batch AOS vs client AOS — don't expect the same symptoms.** Interactive ("client") AOS take
the session-collision cascade; batch AOS usually do not (they have no RDS reconnect storm).
Clean batch AOS alongside crashing client AOS is consistent with the cascade, not evidence
that "only some servers are broken". Overnight `DeadlockException`s on batch AOS are a separate
batch-contention matter.

**A clean `0` on a busy host is suspicious.** Empty results for an AOS you know was crashing
warrant a direct check (`Invoke-Command { Get-WinEvent -LogName Application -MaxEvents 5 }`).
The window is computed on the target to avoid the cross-time-zone shift that a DateTime passed
across remoting can cause — but verify ground truth before reporting "clean". `Get-WinEvent
-ListLog` file timestamps can read frozen at boot while events are actively written; judge
activity by querying events, not log metadata.

**Provider/source name vs message text.** Session events are matched by provider
`Dynamics Server*`; the instance suffix varies (`Dynamics Server 01`). If a targeted manual
query returns nothing, confirm the exact registered provider with
`(Get-WinEvent -ListProvider '*Dynamics*').Name` — a display-name guess silently returns zero.

**Operational remoting foot-guns (shared with the other WinRM triage skills).** The
`Get-Credential` prompt needs an **interactive console** — agent/CI/background runners hang on
it; launch in a visible window and read `-OutFile`. From a **non-domain** client, connect by
**FQDN** that matches a `*.domain` TrustedHosts entry (a short name won't) with
`-Authentication Negotiate`. A multi-host value passed through a launcher as a single quoted
token (`'A,B'`) arrives as one host — pass a real array or a list file.

**Environment-specific gotchas (local).** At the start of a run, read `gotchas.local.md` in
this skill's folder if it exists — it records traps learned in *this* environment (real
server/instance names, AOS↔DB topology, the specific integration that orphans sessions). When
you discover a new environment-specific pitfall, **append it there**, not to this file (which
must stay generic and company-agnostic). The file is gitignored and survives skill updates.

## Verification

**Before drawing conclusions — confirm coverage and ground truth.**

- **No failed hosts.** Any `summary.failures` entry (`unreachable`/`auth_failed`) means that
  host is absent from the data — relay it and its `hint`; never say "the cluster is clean" with
  a host missing.
- **No truncated hosts.** `truncated: true` means `Get-WinEvent` hit `-MaxEvents` and older
  events in the window were dropped — narrow the window or raise `-MaxEvents` before concluding.
- **Spot-check a finding against the raw event.** Before reporting a fault signature or a
  cascade, open one underlying event on the host (Event Viewer / `Get-WinEvent`) and confirm
  the timestamp, offset and message match what the JSON implies.
- **Sanity-check a clean result on a host you expected to be crashing** (see the *clean 0*
  gotcha).

**After remediation — re-verify.** Following a coordinated AOS restart, `SysClientSessions`
cleanup, kernel hotfix, or AOS↔DB network fix, re-run over the same window (or a short post-fix
window) and confirm no new `1000`/`7031` and that `session_error_total` has dropped. A finding
that persists means the fix did not take or a separate instance is occurring. **Fail loud** if
coverage was incomplete — never present a partial sweep as a full one.

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser
Invoke-Pester -Path ./scripts/Invoke-AosCrashTriage.Tests.ps1 -Output Detailed
```

Tests cover the pure logic (host-list parsing, fault-field extraction, AOS/client
classification, timeline build, cascade correlation, host shaping, status/compact),
`Invoke-HostCollect` with a mocked `Invoke-Command`, and a guard that the remote block
computes the window **server-side** and stays down-level safe.
