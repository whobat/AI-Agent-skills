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
- **Access violations (`access_violations`):** Application **event 1000** whose message names
  `Ax32Serv.exe` — faulting app/module, **exception code (decoded)**, fault offset. This is one
  crash class (`0xc0000005`); the event has **no call stack**.
- **Forced terminations (`forced_terminations`):** Application **event 110** from provider
  `Dynamics Server*` ("Session Allocation Failed: Session N is already allocated") — a
  *separate* crash class where the AOS kernel self-terminates on a session-id collision.
- **SCM terminations (`scm_terminations`):** System **event 7031** mentioning *Object Server*.
- **Session symptoms (`session_symptoms`):** Application **event 180** ("RPC error: Client
  provided an invalid session ID") — **by-design, does not crash the AOS**; collected as context.
- **Crash-dump readiness (`wer_config` / `dump_readiness`):** the WER `LocalDumps\Ax32Serv.exe`
  registry config (key present? `DumpType`/`CustomDumpFlags`? dump files on disk?).
- **Change signals (`recent_hotfixes`, `lastboot`):** hotfixes installed in the last 14 days.
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
      "access_violations": [ { "t": "2026-06-17T08:33:57Z", "crash_class": "access_violation", "app": "Ax32Serv.exe", "module": "KERNELBASE.dll", "exception": "0xc0000005", "exception_meaning": "access violation … needs a dump or a correlatable change", "offset": "0x0000000000026ea8" } ],
      "forced_terminations": [ { "t": "2026-06-17T08:36:00Z", "crash_class": "forced_termination", "message": "Object Server 01: Session Allocation Failed: Session 277 is already allocated.", "note": "… proximate cause of this exit, not the deep root cause." } ],
      "scm_terminations": [ { "t": "2026-06-17T08:38:18Z" } ],
      "session_symptoms": { "count": 9, "first": "…", "last": "…", "sample": "… invalid session ID 508", "note": "BY-DESIGN symptom … does NOT crash the AOS - correlation with a crash is not causation." },
      "dump_readiness": { "ready": false, "note": "WER LocalDumps NOT configured for Ax32Serv.exe …" },
      "wer_config": { "key_present": false, "dump_type": null, "custom_dump_flags": null, "dump_files": 0 },
      "recent_hotfixes": [ { "id": "KB5034122", "installed": "2026-06-12T03:00:00Z" } ],
      "events_scanned": 14, "truncated": false
    }
  ],
  "clients": [
    { "computer": "RDS01", "role": "client", "status": "ok", "client_crash_count": 10, "client_crashes": [ { "t": "2026-06-17T08:38:17Z", "module": "Ax32.exe", "exception": "0xc0000005" } ], "truncated": false }
  ],
  "summary": {
    "aos_hosts_total": 2, "hosts_failed": 0,
    "access_violation_total": 1, "forced_termination_total": 2, "session_symptom_total": 9, "client_crash_total": 96,
    "crash_timeline": [ { "computer": "AOS02", "class": "access_violation", "time": "2026-06-17T08:33:57Z", "detail": "0xc0000005 KERNELBASE.dll" } ],
    "cascade_correlation": [ { "aos_event": "AOS02 forced_termination @ 2026-06-17T08:36:00Z", "client_crashes_in_window": 7, "client_hosts": ["RDS01","RDS03"] } ],
    "dump_capture_ready_hosts": 0, "dump_capture_missing": ["AOS02","AOS03"],
    "recent_hotfix_hosts": ["AOS02"],
    "caveats": ["CORRELATION IS NOT CAUSATION …", "… different crash classes …", "… session_symptoms are by-design …"],
    "failures": []
  }
}
```

With `-OutFile`, the file holds the full object; **stdout** holds status/query/summary +
a `note`, without per-host `aos[]`/`clients[]`.

## AX interpretation guide

**First, classify the crash — the two classes have different causes and must never be merged.**

| Signal | What it means (cause vs symptom) | What to do |
|--------|----------------------------------|-----------|
| **`access_violations`** — Event 1000 / `Ax32Serv.exe` / `0xc0000005` | An **unexpected termination** (access violation). The module + offset say *where control was*, **not** which AX code path faulted — the event has **no call stack**. | Look for a **correlatable preceding event or recent change** (`recent_hotfixes`, deployment, schema/compile, kernel drift, config/permissions). If one explains it, validate & fix — no dump needed. If **signature-less**, capture a dump (below) and read the stack. |
| `access_violations[].offset` **identical** across crashes | A **deterministic code path** (it dies at the same instruction each time) — *consistent with* a known kernel defect, but the offset alone does **not** name it. | Capture a dump → `!analyze -v` → match to a KB, or open a Microsoft case with the dump. |
| **`forced_terminations`** — Event 110 / "Session Allocation Failed: already allocated" | A **different class**: the AOS kernel **deliberately self-terminates** on a session-id collision. **Proximate** cause of *that* exit; **downstream** of orphaned `SysClientSessions` rows from a prior AOS↔DB interruption / dead cluster node. **Not** a benign artifact, **not** the deep root cause, **not** an access violation. | Inspect `SysServerSessions` (which AOS marked inactive/dead) + `SysClientSessions` (orphaned STATUS 0/2/3). Restart the dead node (clears DB IDs) or, AOS stopped, `DELETE FROM SysClientSessions WHERE status IN (0,2,3)`. Fix the upstream AOS↔DB connectivity. |
| **`session_symptoms`** — Event 180 / "invalid session ID" | **By design**: a client sent an RPC against a session the AOS already terminated (90s no-ping, ungraceful exit, AOS restart). **Does not crash the AOS.** | Context only. **Never** report as a cause. (Caveat: a *flood* of unreaped sessions can, separately, exhaust the AOS — KB 937873.) |
| `cascade_correlation` — many client crashes at an AOS-down time | The clients dropped **because the AOS went down** (effect). The reconnect storm can re-trigger a `forced_termination`. | Report as effect; to stop the loop, coordinated AOS restart. The *first* AOS-down event's cause still needs evidence (class + dump/change). |
| Crashes confined to **client** AOS, batch AOS clean | Consistent with the interactive reconnect cascade — not "only some servers are broken". | Focus on the client-AOS + RDS farm. Overnight batch `DeadlockException`s are a separate matter. |
| `dump_readiness.ready == false` | WER will **not** capture the next crash. | Emit the remediation (below) so the next `access_violation` is dumpable — the durable path to a real root cause. |

## Gotchas

These are the AX-specific and operational traps that produce confident-but-wrong conclusions.

**THE BIG ONE — correlation is not causation; do not conflate the two crash classes.** This
tool exists *because* the obvious read is usually wrong. Event 110 ("Session Allocation Failed")
and Event 1000 (`0xc0000005`) are **different failure modes**, and Event 180 ("invalid session
ID") is a by-design symptom that doesn't crash anything. A 110 appearing seconds before a 1000
does **not** mean the session error caused the access violation — they may be unrelated, or the
110 may be the *recovery* path of an earlier crash. **Never** emit "root cause: a client
presented a session ID that already existed." The event log gives you the crash *class* and
*signature*; the *cause* of a `0xc0000005` comes from a **symbolized dump** or a **change
correlation**, not from event ordering. (This is the exact mistake an earlier version made.)

**A symbolized dump is the escalation, not the first move.** Many `0xc0000005` crashes are
resolved from the event/change timeline alone — DAT/user-group config (KB 2258719), a
schema-vs-compiled-code mismatch (fix: full compile + synchronize), an outdated `SysLastValue`
after a deployment, kernel-version drift across AOS/clients, or a Windows-update regression. Try
that first (use `recent_hotfixes`/`lastboot`). Reach for a dump when a `0xc0000005` has **no**
correlatable preceding event or change — that is also when Microsoft requires one before issuing
a hotfix.

**An identical fault offset is suggestive, not conclusive.** When every
`access_violations[].offset` is the same value, the process dies on one specific instruction each
time (deterministic) — *consistent with* a kernel defect, but the offset alone **does not name**
the defect or prove a kernel bug (a config/data condition can also be deterministic). Capture a
dump and read the stack before attributing it to a specific KB.

**"Session already allocated" (Event 110) is a forced kernel self-termination — the proximate
cause of THAT exit, but downstream of an upstream condition.** The AOS kernel deliberately kills
itself on a session-id collision (it is **not** a memory access violation). The orphaned
`SysClientSessions` rows behind it are frequently left by a **brief AOS↔database interruption**
too short to log a SQL error or trip an AlwaysOn AG — so "the database looked healthy" does
**not** exclude the DB/network path. But report it as the *proximate* cause and chase the
upstream orphan/connectivity condition; do **not** call the collision message itself the root
cause, and do **not** equate it with a `0xc0000005`.

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

## Capturing a crash dump (the durable fix)

When an `access_violation` has no correlatable event/change, this is the only way to a real
root cause. Configure WER LocalDumps for `Ax32Serv.exe` so the **next** crash is captured with
the **AX-recommended** custom flags (a mini/full dump omits data the AX analyzer needs):

```powershell
$k = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\Ax32Serv.exe'
New-Item -Path $k -Force | Out-Null
New-ItemProperty -Path $k -Name DumpFolder      -Value 'D:\AOSDumps' -PropertyType ExpandString -Force | Out-Null
New-ItemProperty -Path $k -Name DumpType        -Value 0  -PropertyType DWord -Force | Out-Null   # 0 = Custom
New-ItemProperty -Path $k -Name CustomDumpFlags -Value 0x1B67 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $k -Name DumpCount       -Value 5  -PropertyType DWord -Force | Out-Null
```

GUI alternative needing no registry edit: **DebugDiag** with a crash rule on `Ax32Serv.exe`
(attaches to current and future AOS instances). After a crash: **copy the dump off production**,
then `DebugDiag → Start Analysis`, and/or **WinDbg** with
`_NT_SYMBOL_PATH = srv*C:\symbols*https://msdl.microsoft.com/download/symbols` → `!analyze -v`.
Full private `Ax32Serv` symbols are Microsoft-internal — if the signature is novel, open a
Microsoft support case with the dump attached.

## Verification

**Before drawing conclusions — classify, confirm coverage, ground-truth.**

- **Classify the crash before claiming anything.** Decide `access_violation` vs
  `forced_termination` from the data; never write a root cause that crosses the two classes, and
  never attribute a crash to `session_symptoms` (Event 180). Quote `summary.caveats`.
- **Do not state a `0xc0000005` root cause without evidence** — either a correlatable
  event/change you validated, or a symbolized dump stack. Absent that, say "cause undetermined;
  dump required" rather than inventing one.
- **No failed hosts.** Any `summary.failures` entry (`unreachable`/`auth_failed`) means that
  host is absent from the data — relay it and its `hint`; never say "the cluster is clean" with
  a host missing.
- **No truncated hosts.** `truncated: true` means `Get-WinEvent` hit `-MaxEvents` and older
  events in the window were dropped — narrow the window or raise `-MaxEvents` before concluding.
- **Spot-check a finding against the raw event.** Confirm the timestamp, offset and message
  match what the JSON implies.
- **Sanity-check a clean result on a host you expected to be crashing** (see the *clean 0* gotcha).

**After remediation — re-verify.** Following a coordinated AOS restart, `SysClientSessions`
cleanup, kernel hotfix, AOS↔DB fix, or a validated config/deployment fix, re-run over the same
window and confirm no new events of the relevant class (`access_violation_total` /
`forced_termination_total` drop to zero). A finding that persists means the fix did not take or a
separate instance is occurring. **Fail loud** if coverage was incomplete.

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser
Invoke-Pester -Path ./scripts/Invoke-AosCrashTriage.Tests.ps1 -Output Detailed
```

## Sources (the crash taxonomy this guide encodes)

- Microsoft Dynamics blog — *Possibilities to create memory dumps from crashing processes*
  (Event 110 forced-termination vs Event 1000 unexpected-termination; WER/DebugDiag):
  `https://www.microsoft.com/en-us/dynamics-365/blog/no-audience/2010/05/12/possibilities-to-create-memory-dumps-from-crashing-processes/`
- Microsoft Learn — *Drain users from an AOS* (no user-session reconnect; restart/reset
  SysServerSessions): `https://learn.microsoft.com/en-us/dynamicsax-2012/appuser-itpro/drain-users-from-an-aos`
- Microsoft Learn — *Troubleshoot common AOS problems*:
  `https://learn.microsoft.com/en-us/dynamicsax-2012/appuser-itpro/troubleshoot-common-aos-problems`
- Microsoft Learn — *RPC exception 1726 occurred in session 10* (KB 937873; Event 180 / invalid
  session ID is by design): `https://learn.microsoft.com/en-us/previous-versions/troubleshoot/dynamics/ax/rpc-exception-1726-occurred-in-session-10-error-when-reviewing-application-log`
- Microsoft Learn — *AOS crashes using temporary tables in EP* (KB 2258719: a `0xc0000005`
  root-caused from events + config, no dump): `https://learn.microsoft.com/en-us/previous-versions/troubleshoot/dynamics/ax/application-object-server-crashes-when-using-temporary-tables-in-ep`
- Microsoft Learn — *Collecting user-mode dumps* (WER LocalDumps registry):
  `https://learn.microsoft.com/en-us/windows/win32/wer/collecting-user-mode-dumps`
- Microsoft Support — *AOS crashes with the Ax32Serv DBDPack call stack* (a named-stack hotfix):
  `https://support.microsoft.com/en-us/topic/the-application-object-server-aos-crashes-with-the-ax32serv-dbdpack-call-stack-in-microsoft-dynamics-ax-2012-6390ab86-38d7-3732-a64b-060f49647e3e`
- Dynamics Community (forum 4b05f31a) — *Session Allocation Failed: already allocated*
  (orphaned `SysClientSessions` from an AOS↔DB blip → second AOS crash; fix = restart dead node):
  `https://community.dynamics.com/forums/thread/details/?threadid=4b05f31a-1ec0-47f1-b5fa-028136f3dfad`
- DynamicsUser.net — *AOS crashing in AX 2012 R3 after KB4058327 / 6.3.6000.4155* (a CU
  regression — validate kernel updates): `https://www.dynamicsuser.net/t/aos-crashing-in-ax-2012-r3-after-installing-kb4058327-6-3-6000-4155/65232`
- daxdilip.blogspot.com — *How to troubleshoot an AOS crash using a crash dump* (WinDbg/DebugDiag
  walkthrough): `https://daxdilip.blogspot.com/2016/01/how-to-troubleshoot-aos-crash-using.html`

Tests cover the pure logic (host-list parsing, fault-field extraction, AOS/client
classification, timeline build, cascade correlation, host shaping, status/compact),
`Invoke-HostCollect` with a mocked `Invoke-Command`, and a guard that the remote block
computes the window **server-side** and stays down-level safe.
