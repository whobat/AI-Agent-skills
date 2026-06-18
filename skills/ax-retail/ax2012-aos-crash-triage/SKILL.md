---
name: ax2012-aos-crash-triage
description: Triage Microsoft Dynamics AX 2012 / R3 AOS (Ax32Serv.exe) crashes and the RPC session-allocation cascade. The bundled script collects, server-side, AOS process crashes (Application 1000 / Ax32Serv.exe), unexpected service terminations (System 7031 / "Object Server"), and the kernel session precursors (Dynamics Server 110 "Session Allocation Failed: already allocated" + 180 "invalid session ID"), then correlates AOS terminations with AX rich-client (Ax32.exe) crashes on the RDS/Citrix farm to expose the "AOS dies -> every client drops at once -> reconnect storm" cascade. Use when an AX AOS service crashed/restarted, users got disconnected en masse, or you see Event 7031/110/180 — e.g. "why did the AOS crash", "AX kicked everyone out", "Ax32Serv keeps restarting". Do NOT use for AX SQL/database slowness (that is ax2012-sql-performance) or generic non-AX event-log triage (that is win-eventlog-triage). Requires PowerShell 7+ and WinRM + an admin credential (always prompted).
license: MIT
compatibility: Requires PowerShell 7+ on the operator machine and WinRM (PowerShell Remoting) enabled on the AOS and client/RDS hosts. Read-only; needs a credential that can read the System + Application logs and query services on the targets.
metadata:
  version: "1.1.1"
---

# AX 2012 AOS Crash & Session-Cascade Triage

> Targets **Dynamics AX 2012 / R3 AOS servers** (and, optionally, the **RDS/Citrix
> session hosts** running the AX rich client) over **WinRM**. The bundled script
> `scripts/Invoke-AosCrashTriage.ps1` collects the crash + session signals as JSON and
> correlates them; **the agent writes the root-cause narrative.** No LLM is called; nothing
> is changed (read-only).

`SCRIPT` = this skill's `scripts/Invoke-AosCrashTriage.ps1`. Requires **PowerShell 7+**
(`pwsh`) and WinRM on the targets.

## Why this skill (vs the generic event-log triage)

A `win-eventlog-triage` sweep shows *that* there are 7031/1000 errors. This skill encodes the
**AX-specific crash taxonomy** and gathers the evidence needed to root-cause correctly instead
of guessing:

- **separates the two crash classes** — Event 1000 `0xc0000005` access violations vs Event 110
  "Session Allocation Failed" forced terminations — and labels Event 180 as a by-design symptom,
  so they are never conflated into a false "session caused the crash" story;
- pulls the fault signature (module/exception/offset) **and** the **crash-dump readiness** for
  `Ax32Serv.exe` (WER LocalDumps) plus recent **change signals** (hotfixes, boot) — because the
  honest root cause comes from a dump or a change-correlation, not from event timing; and
- **correlates each AOS-down event with Ax32.exe client crashes** across the RDS farm to show the
  cascade as an *effect* (the AOS dropped the clients), not to assert what triggered the first crash.

## Credentials

Always prompts via `Get-Credential` (held in memory for the run, never stored). The
`-Credential` parameter is a test/automation seam only — don't put a password on the
command line.

> **Agent / non-interactive runners:** `Get-Credential` needs an interactive console. Launch
> in a **visible** window and read the `-OutFile`, e.g.
> `Start-Process pwsh -ArgumentList '-NoExit','-File','SCRIPT','-AosComputerName','AOS01.contoso.local,AOS02.contoso.local','-OutFile','C:\ops\aos.json'`.
> From a non-domain client use the **FQDN** (matches a `*.domain` TrustedHosts entry; a short
> name won't) + `-Authentication Negotiate`.

## How to run

| Want | Pass |
|------|------|
| **AOS servers** | `-AosComputerName AOS01,AOS02` or `-AosListFile C:\ops\aos.txt` |
| **+ client/RDS hosts for cascade correlation** | `-ClientComputerName RDS01,RDS02` or `-ClientListFile C:\ops\rds.txt` |
| **Look-back window** | `-Hours 24` (default) — computed *on each target* (TZ-safe) |
| **Cascade match window** | `-CascadeWindowSeconds 120` (how close a client crash must be to an AOS termination to count) |
| **Save full report** | `-OutFile C:\ops\aos-triage.json` (stdout becomes the compact view) |
| **Transport/auth** | `-UseSSL` · `-Authentication Negotiate\|Kerberos\|CredSSP` |
| **Tuning** | `-MaxEvents 2000` (cap per query per host) · `-MaxMessageLength 600` · `-ThrottleLimit 8` |

```powershell
# Client-AOS pair, last 24h
pwsh -File SCRIPT -AosComputerName AOS01,AOS02

# Full picture: AOS cluster + RDS farm, last 6h, detail to a file
pwsh -File SCRIPT -AosListFile C:\ops\aos.txt -ClientListFile C:\ops\rds.txt -Hours 6 -OutFile C:\ops\aos-triage.json
```

## Output contract

- **Without `-OutFile`** → full JSON on stdout.
- **With `-OutFile`** → full detail to the file; a **compact** JSON (status, query, summary —
  incl. `crash_timeline`, `cascade_correlation`, `failures`) on stdout. Prefer `-OutFile` for
  big sweeps.

Key fields: `summary.crash_timeline` (AOS-down events tagged by `class`:
`access_violation` / `forced_termination` / `scm_7031`, time-sorted), `summary.cascade_correlation`
(per AOS event: client crashes within `CascadeWindowSeconds`), the per-class totals
(`access_violation_total`, `forced_termination_total`, `session_symptom_total`,
`client_crash_total`), `summary.dump_capture_ready_hosts` / `dump_capture_missing`, and
`summary.caveats` (the correlation-not-causation guardrails). Per-host `aos[]` carries
`access_violations` (with `exception_meaning`/`offset`), `forced_terminations`,
`scm_terminations`, `session_symptoms` (labelled by-design), `dump_readiness`/`wer_config`, and
`recent_hotfixes`. All times are **UTC** (`Z`). See [REFERENCE.md](REFERENCE.md) for the full
schema and the AX-interpretation guide.

## What you (the agent) do with the result

> **Golden rule: report correlation, not causation.** The event log can tell you the crash
> *class* and *signature*, not which code path faulted. Never output "root cause: a client
> presented a session ID that already existed." Read `summary.caveats` before writing anything.

1. **Run the script**, parse the JSON.
2. **Classify the crash first** (`summary.crash_timeline` is tagged by `class`):
   - **`access_violation`** (Event 1000 / `0xc0000005`): report the fault signature
     (`module`, `exception`, `exception_meaning`, `offset`) and whether the offset is
     **identical across crashes** (deterministic code path). The event has **no call stack** —
     you cannot name the faulting AX code from it.
   - **`forced_termination`** (Event 110 / "Session Allocation Failed: already allocated"): the
     AOS kernel **deliberately self-terminated** on a session-id collision. This is the
     *proximate* cause of that exit, but it is **downstream** of orphaned `SysClientSessions`
     rows from a prior AOS↔DB interruption / dead cluster node — investigate **that**, not the
     collision message. It is a **different crash class** from an access violation.
3. **Treat `session_symptoms` (Event 180) as by-design**, never as a cause — they don't crash
   the AOS.
4. **State the cascade as correlation:** if `cascade_correlation` shows client crashes clustered
   at AOS-down times, report it as "clients dropped when AOS X went down" (effect), and note the
   reconnect-storm can re-trigger a `forced_termination` — but the *first* AOS-down event's cause
   still needs evidence.
5. **Drive to evidence, not a guess:**
   - Check `aos[].dump_readiness` — if WER LocalDumps isn't configured for `Ax32Serv.exe`,
     give the remediation so the **next** crash is captured (this is the durable fix).
   - Check `aos[].recent_hotfixes` / `lastboot` — many `0xc0000005` crashes are a
     config/deployment/Windows-update regression, found by **change correlation**, not a dump.
   - Decision gate: `forced_termination` → fix orphaned sessions / the AOS↔DB link first;
     `access_violation` with a correlatable change → validate that; **signature-less
     `access_violation` → capture a dump and analyse the symbolized stack** (WinDbg `!analyze -v`
     / DebugDiag), or open a Microsoft case with the dump.
6. **Fail loud:** list any host in `summary.failures` (unreachable/auth_failed) and any
   `truncated: true` host — never imply full coverage.

## Gotchas

See [REFERENCE.md](REFERENCE.md#gotchas) for the AX-specific traps (cause/effect direction,
the deterministic-offset tell, batch vs client AOS, the orphaned-session root cause, and the
operational remoting foot-guns). **Environment-specific** traps (real host names, local
quirks) go in `gotchas.local.md` in this folder — read it at the start of a run if present,
and append new local pitfalls there (it is gitignored and survives skill updates), never to
the committed docs.

## Verification

See [REFERENCE.md](REFERENCE.md#verification): confirm coverage (no failed/truncated hosts)
and ground-truth a finding against the raw event before reporting; after any remediation
(coordinated AOS restart, session cleanup, network fix), re-run the same window and confirm
no new 7031/1000.

## Errors

- `Get-Credential` cancelled → re-run and supply the admin credential.
- Per-host `auth_failed` / `unreachable` → see the `hint` field (TrustedHosts/FQDN, Kerberos
  no-authority, or WinRM/DNS reachability). Per-host failures never abort the sweep.
- `pwsh` not found → install PowerShell 7 (`winget install Microsoft.PowerShell`).
