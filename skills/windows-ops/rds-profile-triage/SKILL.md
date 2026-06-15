---
name: rds-profile-triage
description: Read-only triage of Remote Desktop Services (RDS) session-host profile & WinRM-host health across one or many servers. The bundled script collects (over WinRM, with a CIM-over-DCOM fallback for hosts whose WinRM host process won't even launch) profile-hive leaks, temp-profile sprawl, ProfileList corruption, the roaming-profile path read RAW, RDS drain state, and User-Profiles-Service failure events grouped BY THE ACTUAL USER — then emits JSON the agent turns into a critical-first triage. Use when a user reports RDS/terminal-server problems like "user X gets logged out immediately / logged off right after sign-in", "everyone's getting temporary profiles", "their settings don't save on the RDS farm", "the session host won't accept logins", or "I can't PowerShell-remote into the RDS server (could not launch a host process)". Do NOT use for generic event-log sweeps (that is win-eventlog-triage) or SQL Server issues (sqlserver-perf-triage). Requires PowerShell 7+ and a tier-admin credential (always prompted).
license: MIT
compatibility: Requires PowerShell 7+ on the operator machine. WinRM mode needs PowerShell Remoting on the target RDS hosts; DCOM mode needs WMI/DCOM (TCP 135 + dynamic range) reachable. Read-only — makes no changes.
metadata:
  version: "1.0.0"
---

# RDS Profile & WinRM-Host Triage

> Targets **Windows RDS session hosts** over **WinRM** (with a **CIM-over-DCOM** fallback). The bundled `scripts/Invoke-RdsProfileTriage.ps1` collects read-only health data and a set of deterministic `findings`; **you (the agent) write the triage and decide remediation.** The script never calls an LLM and **changes nothing**.

`SCRIPT` = this skill's `scripts/Invoke-RdsProfileTriage.ps1`. It **requires PowerShell 7+** (`pwsh`).

## Why this skill exists (the gotchas it encodes)

RDS profile triage is a minefield of measurement traps that produce confident-but-wrong root causes. This skill bakes the corrections in — **read the `caveats` array in the output before concluding anything**, and see [REFERENCE.md](REFERENCE.md#gotchas--read-before-you-conclude) for the full list. The big four:

1. **REG_EXPAND_SZ expansion.** Reading the roaming-profile path with `Get-ItemProperty` **expands `%USERNAME%` in the calling account's context**. Read as admin, a perfectly correct `\\FS01\profiles$\%USERNAME%\...` looks **hardcoded to the admin** — a classic false "the GPO is broken" call. The script reads it **raw**; trust `roaming_profile.machine_profile_path_raw`.
2. **Double-hop.** From a **non-domain-joined / workgroup** operator box, WinRM uses NTLM and the host can't delegate to the file server → roaming load fails with **"Access is denied"** — *for your connecting account only*. Those Event 1521s are **your artifact**, not a user outage. The script tags them `user_class=self_or_admin`.
3. **One noisy account ≠ the whole farm.** A single backup/batch service account can mint thousands of temp profiles. The script groups profile-failure events **by the real user** so you don't generalize one service account's churn into a farm-wide outage.
4. **The "Element not found" chain.** Corrupt `ProfileList` entries (empty `ProfileImagePath`, `.bak` pointing at deleted temp dirs) → the user profile can't be built → `wsmprovhost` never registers its COM class → **WinRM "could not launch a host process" (Event 86) + DCOM 10000 "error 0"**. So *a broken WinRM endpoint can be a profile problem.* The script detects the corruption and the host-launch events together.

## How to run

Always run with `pwsh`. The script prompts for the tier-admin credential (reused for all hosts, never stored). Parse the JSON on stdout.

| Want | Pass |
|------|------|
| **One host** | `-ComputerName RDS01` |
| **A farm** | `-ComputerName RDS01,RDS02` or `-ServerListFile C:\ops\rds.txt` |
| **Time window for events** | `-Hours 24` (default) · `-Since '2026-06-15T00:00'` · `-From <dt> -To <dt>` |
| **WinRM host won't launch on a box** | `-Protocol Dcom` (reduced CIM/DCOM collection: uptime, drain, roaming-raw, ProfileList corruption) |
| **Save full report** | `-OutFile C:\ops\rds.json` (stdout becomes compact summary) |
| **Auth/transport** | `-Authentication Negotiate\|Kerberos\|CredSSP` (default `Default`) |
| **Tuning** | `-TempSampleSize 10` · `-MaxCorruptListed 20` · `-MaxMessageLength 400` |

```powershell
# Single host, last 24h
pwsh -File SCRIPT -ComputerName RDS01

# Two-host farm, 48h window, full detail to a file
pwsh -File SCRIPT -ComputerName RDS01,RDS02 -Hours 48 -OutFile C:\ops\rds.json

# The host's own WinRM is dead ("could not launch a host process") — go in over DCOM
pwsh -File SCRIPT -ComputerName RDS01 -Protocol Dcom
```

## Output contract

- **Without `-OutFile`** → full JSON (every host + all detail) on stdout.
- **With `-OutFile`** → full detail to the file; a **compact** JSON (`status`, `query`, `summary`, `caveats`) on stdout.

Key fields: `summary.findings` (deterministic, severity-ranked flags across all hosts — your starting list); `summary.failures` (hosts that couldn't be collected, each with a `hint`); per host `roaming_profile.machine_profile_path_raw`, `hive_leak`, `temp_profiles`, `profilelist` (corruption counts + entries), `profile_events` (grouped by user + `user_class`), `winrm_host_launch`; and the top-level **`caveats`** array. Full schema in [REFERENCE.md](REFERENCE.md#output-schema).

## What you (the agent) do with the result

1. **Run the script**, parse the JSON. If a host failed with "could not launch a host process", **re-run that host with `-Protocol Dcom`** — that exact failure is usually ProfileList corruption the DCOM pass can still read.
2. **Lead with `summary.findings`** (critical → high → medium), named by host. Translate each into plain language + a suggested next action.
3. **Apply the caveats before blaming anything** (this is the whole point):
   - Profile-failure events with `user_class=self_or_admin` → likely **your double-hop**, not a user problem. Say so; don't report it as an outage.
   - `user_class=service_account` churn (temp profiles) → name the account; it's housekeeping, not a farm outage. Recommend excluding it from the roaming GPO.
   - Only `user_class=interactive_user` failures are real user-facing problems — these get priority.
   - Report the roaming path from `machine_profile_path_raw` **exactly**; never claim it's hardcoded to a user unless the RAW value truly lacks `%USERNAME%`.
4. **Fail loud** (Karpathy): list every host in `summary.failures`; note when DCOM mode returned a **reduced** dataset (`dcom_note`); never imply full coverage you didn't get.
5. **Only then** propose remediation (reboot to clear leaked hives, back-up-then-remove corrupt ProfileList entries, clean temp sprawl, exclude service accounts from roaming) — and confirm before changing anything.

## Errors

- `Get-Credential` cancelled → re-run and supply the tier-admin credential.
- **"could not launch a host process"** on a host → its WinRM endpoint is down (often ProfileList corruption). Re-run that host with `-Protocol Dcom`; check `profilelist` in the result.
- **Workgroup / cross-domain** (`TrustedHosts` message or `0x80090311`) → run from a domain-joined admin host, or add the FQDNs to WinRM `TrustedHosts` (scope to specific hosts, not `*`), or use `-Protocol Dcom`. See [REFERENCE.md](REFERENCE.md#non-domain-joined--workgroup-operator).
- `pwsh` not found → install PowerShell 7 (`winget install Microsoft.PowerShell`); the repo installer auto-installs it.
