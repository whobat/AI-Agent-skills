---
name: ax2012-aos-crash-triage
description: Triage Microsoft Dynamics AX 2012 / R3 AOS (Ax32Serv.exe) crashes and the RPC session-allocation cascade. The bundled script collects, server-side, AOS process crashes (Application 1000 / Ax32Serv.exe), unexpected service terminations (System 7031 / "Object Server"), and the kernel session precursors (Dynamics Server 110 "Session Allocation Failed: already allocated" + 180 "invalid session ID"), then correlates AOS terminations with AX rich-client (Ax32.exe) crashes on the RDS/Citrix farm to expose the "AOS dies -> every client drops at once -> reconnect storm" cascade. Use when an AX AOS service crashed/restarted, users got disconnected en masse, or you see Event 7031/110/180 — e.g. "why did the AOS crash", "AX kicked everyone out", "Ax32Serv keeps restarting". Do NOT use for AX SQL/database slowness (that is ax2012-sql-performance) or generic non-AX event-log triage (that is win-eventlog-triage). Requires PowerShell 7+ and WinRM + an admin credential (always prompted).
license: MIT
compatibility: Requires PowerShell 7+ on the operator machine and WinRM (PowerShell Remoting) enabled on the AOS and client/RDS hosts. Read-only; needs a credential that can read the System + Application logs and query services on the targets.
metadata:
  version: "1.0.0"
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
**AX-specific crash chain** and does the work that turns symptoms into a root cause:

- pulls the exact AX signatures (Ax32Serv fault offset/exception, Dynamics Server 110/180
  session-allocation precursors) and the AOS service state in one shot, and
- **correlates each AOS termination with simultaneous Ax32.exe client crashes** across the
  RDS farm — the signature of the cascade (clients on many hosts dying at the *same second*
  means the central AOS dropped them, not a client-side fault).

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

Key fields: `summary.crash_timeline` (merged AOS crashes + terminations, time-sorted),
`summary.cascade_correlation` (per AOS event: how many client crashes fell within
`CascadeWindowSeconds`, and on which hosts), `summary.aos_crash_total` /
`session_error_total` / `client_crash_total`, and per-host `aos[]` (crashes with fault
offset/exception, terminations, `session_errors`) + `clients[]`. All times are **UTC** (`Z`).
See [REFERENCE.md](REFERENCE.md) for the full schema and the AX-interpretation guide.

## What you (the agent) do with the result

1. **Run the script**, parse the JSON.
2. **Lead with the crash chain:** which AOS crashed, when, the fault signature (e.g.
   `Ax32Serv.exe 0xc0000005 @ offset 0x…`), and whether the offset is **identical across
   crashes** (deterministic kernel code path, not random memory corruption).
3. **State the cascade if present:** if `cascade_correlation` shows client crashes clustered at
   AOS termination times, say so plainly — "AOS X terminated at T; N clients across M RDS hosts
   dropped within seconds" — and explain the reconnect-storm loop.
4. **Surface the precursor:** the Dynamics Server 110/180 `session_errors` immediately before a
   crash are the trigger signature (stale/duplicate RPC session IDs).
5. **Fail loud:** list any host in `summary.failures` (unreachable/auth_failed) and any
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
