# rds-profile-triage — Reference

Detailed reference for `scripts/Invoke-RdsProfileTriage.ps1`. For the agent-facing
workflow see [SKILL.md](SKILL.md). The script is **read-only** — it never changes a host.

## Requirements

- **PowerShell 7+** (`pwsh`) on the operator machine.
- **WinRM mode** (default): PowerShell Remoting enabled on the target RDS hosts.
- **DCOM mode** (`-Protocol Dcom`): WMI/DCOM reachable (TCP **135** + the dynamic RPC
  range). Used when a host's WinRM endpoint can't launch its host process.
- A **tier-admin credential** with rights on the targets. Always prompted, never stored.

## Parameters

| Parameter | Type | Default | Notes |
|-----------|------|---------|-------|
| `-ComputerName` | string[] | — | One or more hosts. Combine with `-ServerListFile`. |
| `-ServerListFile` | string | — | One host per line; `#` comments and blanks ignored. |
| `-Hours` | int | 24 | Event look-back window. |
| `-Since` | datetime | — | Start time; end = now. Overrides `-Hours`. |
| `-From` / `-To` | datetime | — | Explicit interval. Overrides `-Since`/`-Hours`. |
| `-Protocol` | string | `WinRM` | `WinRM` (full) or `Dcom` (reduced; for dead-WinRM hosts). |
| `-TempSampleSize` | int | 10 | How many newest `TEMP*` folders to sample (with owner). |
| `-MaxCorruptListed` | int | 20 | Cap on listed corrupt ProfileList entries. |
| `-MaxMessageLength` | int | 400 | Truncates each event group's sample message. |
| `-Format` | string | `text` | `text` = uniform deterministic report (relay it); `json` = full/compact JSON; `both` = report then JSON. |
| `-OutFile` | string | — | Always writes full-detail JSON to the file; stdout still follows `-Format`. |
| `-Authentication` | string | `Default` | WinRM auth: `Default`/`Negotiate`/`Kerberos`/`CredSSP`. |
| `-Credential` | pscredential | — | Testing/automation seam only. Omit in normal use → prompted. |

All output timestamps are **UTC** with a `Z` suffix.

## Gotchas — read before you conclude

These are the traps that produce confident-but-wrong RDS root causes. The script is built
to neutralize them; this is the human-readable record.

### 1. REG_EXPAND_SZ expands `%USERNAME%` in *your* context
`MachineProfilePath` ("Set roaming profile path for all users logging onto this computer")
is stored as **REG_EXPAND_SZ**, normally `\\FS01\profiles$\%USERNAME%\RdsProfile`.
`Get-ItemProperty` / `(Get-Item).GetValue()` **expand** it using the *running process's*
environment. Read inside a remote session running as `CONTOSO\admin`, it comes back as
`\\FS01\profiles$\admin\RdsProfile` — and you "discover" a hardcoded path that isn't there.
- ✅ The script reads it with `RegistryValueOptions.DoNotExpandEnvironmentNames`
  (`roaming_profile.machine_profile_path_raw`) and `StdRegProv.GetStringValue` in DCOM mode
  (which also doesn't expand). Trust those.
- ✅ Manual raw read: `reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v MachineProfilePath`
  shows the literal `%USERNAME%` and the `REG_EXPAND_SZ` type.

### 2. Double-hop turns *your* connection into a fake "Access is denied"
From a **non-domain-joined / workgroup** operator box, WinRM authenticates with **NTLM** and
the remote session **cannot delegate** your credentials onward to the profile **file server**.
So when the WSMan host (or any remote process running as you) loads *your* roaming profile, it
gets **Event 1521 "Access is denied"** — for **your account only**. This is *your* artifact,
not a user problem. Real interactive RDP users authenticate with Kerberos directly on the host
and have **no** double-hop.
- ✅ The script tags every profile-failure event `user_class` and surfaces `self_or_admin`
  (your account) vs `service_account` vs `interactive_user`. **Only `interactive_user`
  failures are real.**
- ✅ To test cleanly without double-hop: check the file share **directly** from your machine
  (`net use \\FS01\profiles$ ...` is a single hop), or connect from a domain-joined host.

### 3. Attribute every profile event to the *actual* user
Event **1521/1511/1505** carry a `UserId` SID. Before saying "the farm is broken", group by
that SID. In practice the bulk is often **one batch/backup service account** (Logon Type 4)
churning temp profiles, plus your own admin connections — with **zero** real users affected.
- ✅ `profile_events` is grouped by resolved user + `user_class`. A `findings` entry only calls
  it a real problem when `user_class=interactive_user`.

### 4. The "Element not found" → WinRM-host-launch chain
A corrupt `ProfileList` entry — **empty `ProfileImagePath`**, or a **`<SID>.bak`** pointing at a
deleted `TEMP.*` dir — makes the User Profile Service fail with **"Element not found"** while
building a profile. The WSMan host (`wsmprovhost.exe`, launched "With User Settings") then
**exits before registering its COM class**, so you see:
- WinRM: **Event 86** "The WSMan service could not launch a host process … **Error code 2**"
- System: **DCOM Event 10000** "Unable to start a DCOM Server: {…} … The error: **0** … `wsmprovhost.exe -Embedding`"
- and `New-PSSession` fails with *"could not launch a host process"*.

So **a dead WinRM endpoint can be a profile-store problem**, not a WinRM/WMI/DCOM-permissions
problem. Things that look implicated but usually aren't: the plugin registration, DCOM
launch/activation ACLs, User Rights Assignment, AppLocker/WDAC, the binaries, .NET. Verify the
binary actually exists and `Get-PSSessionConfiguration` is intact, then look at `ProfileList`.
- ✅ The script reports `winrm_host_launch` (the 10000/86 counts) and `profilelist` corruption
  together. When both fire, the fix is to **back up and remove the corrupt entries**, not to
  re-register WinRM.

### 5. Other RDS profile truths worth keeping
- **Leaked hives.** Loaded `HKEY_USERS\S-1-5-21-*` hives **without a matching session** (compare
  to `quser`) are orphaned — they cause "logged out immediately" and temp-profile fallback for
  the affected user. They accumulate with **long uptime**; a reboot clears them. (`hive_leak`.)
- **Drain mode persists, then resets on reboot.** `TSServerDrainMode` = 1/2 means "no new
  logons (until restart)". A host can sit drained for months if never rebooted. A reboot resets
  it to 0; or `chglogon /enable`. The RD Connection Broker has a *separate* "allow new
  connections" flag — check both before assuming a host is in rotation.
- **Roaming profiles are versioned.** Windows appends `.V6` (Server 2019/2022), `.V4`, `.V2` to
  the configured folder per OS generation. `\\FS01\profiles$\jdoe\RdsProfile.V6` is normal.
- **`.V6` ownership is not the discriminator.** A working profile can be owned by Administrators
  and a failing one owned by the user — don't chase ownership/MS16-072 before confirming the
  user actually fails (see gotcha #2/#3).

**Environment-specific gotchas (local).** At the start of a run, read `gotchas.local.md` in this skill's folder if it exists — it records traps learned in *this* environment (real server/database names, local quirks, naming conventions). When you discover a new environment-specific pitfall here, **append it to `gotchas.local.md`** (not to this file, which must stay generic and company-agnostic). The file is gitignored and is preserved across skill updates, so this skill gets more useful every time it runs in your environment.

## DCOM fallback recipe (when WinRM is dead)

When a host returns "could not launch a host process", you can still manage it over CIM/DCOM.
The script's `-Protocol Dcom` does the read-only collection; for ad-hoc work:

```powershell
$opt = New-CimSessionOption -Protocol Dcom
$cs  = New-CimSession -ComputerName RDS01 -Credential $cred -SessionOption $opt
# Read registry via StdRegProv (HKLM = 2147483650). GetStringValue does NOT expand REG_EXPAND_SZ.
Invoke-CimMethod -CimSession $cs -Namespace root\default -ClassName StdRegProv -MethodName GetStringValue `
  -Arguments @{ hDefKey = [uint32]2147483650; sSubKeyName = 'SOFTWARE\Policies\Microsoft\Windows\System'; sValueName = 'MachineProfilePath' }
# Run a command (returns a PID, not output): write to a file, then read it over the admin share.
Invoke-CimMethod -CimSession $cs -ClassName Win32_Process -MethodName Create `
  -Arguments @{ CommandLine = 'cmd /c "whoami > C:\Windows\Temp\out.txt"' }
# Read it back: \\RDS01\C$\Windows\Temp\out.txt  (authenticate the share first if workgroup)
```

Processes started this way are **not** killed when your CIM session ends (unlike a child of a
remote PSSession). Folder enumeration and event-log reads are awkward over DCOM, so DCOM mode
returns a **reduced** dataset (`dcom_note`): uptime, drain, roaming-raw, and ProfileList
corruption — which is exactly enough to confirm the "Element not found" cause.

## Non-domain-joined / workgroup operator

Symptoms when the operator box isn't in the target's domain:
- a `TrustedHosts` error (default Negotiate → NTLM), or `0x80090311` if forcing Kerberos.

Fixes, in order: (1) run from a **domain-joined admin host** (Kerberos just works, no double-hop);
(2) add the targets to WinRM TrustedHosts — `Set-Item WSMan:\localhost\Client\TrustedHosts -Value 'rds01.contoso.local' -Concatenate` (scope to **FQDNs, not `*`**; needs local admin) — note this is NTLM, so the **double-hop caveat applies**; (3) `-Protocol Dcom`.

## Output

`-Format text` (default) renders a deterministic report with fixed sections in a fixed order —
`header → == FINDINGS (ranked) == → == PER-HOST == → == COVERAGE GAPS == (only if any) →
== CAVEATS ==`. Severities render as `[CRIT]`/`[HIGH]`/`[MED ]` (ASCII, not emoji, for encoding
and terminal consistency). The report is built from the same object shown below, so two runs
against the same state produce byte-identical text. `-Format json`/`both` expose the raw object.

## Output schema (the object behind every format)

```json
{
  "status": "ok | partial | error",
  "generated_at": "2026-06-15T10:00:00Z",
  "query": { "hosts": ["RDS01"], "from": "…Z", "to": "…Z", "protocol": "WinRM" },
  "hosts": [
    {
      "computer": "RDS01", "status": "ok | failed", "error": null, "hint": null,
      "collection_method": "winrm | dcom",
      "os": "…", "last_boot": "…Z", "uptime_hours": 250.4, "pending_reboot": false,
      "drain": { "mode": 0, "state_text": "…", "accepting_logons": true },
      "disk": { "c_free_gb": 18.3, "c_total_gb": 79.0, "pct_free": 23.1 },
      "fslogix": { "installed": false, "profiles_enabled": null },
      "roaming_profile": { "machine_profile_path_raw": "\\\\FS01\\profiles$\\%USERNAME%\\RdsProfile", "value_kind": "ExpandString", "rds_wf_profile_path": null, "note": "RAW — %USERNAME% NOT expanded." },
      "hive_leak": { "loaded_user_hives": 21, "active_sessions": 6, "leaked": 15 },
      "temp_profiles": { "count": 1138, "sample": [ { "name": "TEMP.X.243", "last_write": "…Z", "owner": "BUILTIN\\Administrators" } ] },
      "profilelist": { "total": 16, "empty_path": 3, "bak": 2, "temp_pointing": 2,
        "corrupt": [ { "sid": "S-1-5-21-…-1003.bak", "path": "C:\\Users\\TEMP.X.848", "state": 16640, "reason": "bak_entry,points_to_temp_profile" } ] },
      "profile_events": [ { "event_id": 1511, "user": "CONTOSO\\svc-backup", "user_class": "service_account", "count": 185, "first_seen": "…Z", "last_seen": "…Z", "sample_message": "Windows cannot find the local profile…" } ],
      "winrm_host_launch": { "dcom10000_wsmprovhost": 0, "winrm86": 0, "failing": false },
      "findings": [ { "severity": "high", "finding": "…" } ]
    }
  ],
  "summary": {
    "hosts_total": 1, "hosts_ok": 1, "hosts_failed": 0,
    "failures": [],
    "findings": [ { "computer": "RDS01", "severity": "high", "finding": "…" } ]
  },
  "caveats": [ "…the four gotchas, restated for the agent…" ]
}
```

Per-host `status`: `ok` (collected) or `failed` (with `error` + an actionable `hint`). A failed
host never aborts the run. `findings` severity order: `critical` → `high` → `medium`.

## Verification

This skill is **read-only**. Verification happens in two places: before you conclude anything,
and after a remediation is applied.

### Before recommending anything — confirm the data is trustworthy

1. **Every host collected.** Check `summary.hosts_failed`. Any host with `status: failed` was
   not fully collected. Re-run it with `-Protocol Dcom` (the `hint` in the output says so) and
   relay the reduced result. Fail loud if a host in the farm is still missing after the DCOM
   re-run — coverage gaps mean gaps in your conclusion.
2. **Roaming path read RAW.** Confirm `roaming_profile.machine_profile_path_raw` contains the
   literal `%USERNAME%` (or a literal username that was deliberately hardcoded). If it shows
   the admin's own username and `value_kind` is `ExpandString`, the value was expanded — it is
   not the raw registry content. Trust only what the script emits via
   `RegistryValueOptions.DoNotExpandEnvironmentNames` (WinRM) or `StdRegProv.GetStringValue`
   (DCOM). A manual cross-check: `reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v MachineProfilePath`
   on the host — the output must show `REG_EXPAND_SZ` with `%USERNAME%` unexpanded.
3. **Profile-failure events attributed to the actual user.** Before calling an event-storm a
   real outage, verify `user_class` for each `profile_events` group. Dismiss `self_or_admin`
   (your own double-hop artifact) and `service_account` churn. A real outage requires at least
   one `interactive_user` failure. If the only events are `self_or_admin` or `service_account`,
   establish that baseline explicitly — "no interactive-user failures seen in the window" — before
   moving on.

### After remediation — confirm the fix landed

Re-run the triage against the same host(s) after any remediation is applied:

- **Reboot to clear leaked hives.** After the host comes back, re-run and confirm
  `hive_leak.leaked = 0` (or the value dropped to an acceptable level) and that the affected
  user can log on successfully.
- **Corrupt ProfileList entries removed.** Re-run and confirm `profilelist.empty_path = 0`,
  `profilelist.bak = 0`, and `profilelist.temp_pointing = 0` for the entries that were removed.
  Also confirm `winrm_host_launch.failing = false` if the host's WinRM was down — the host
  should now respond to WinRM without `-Protocol Dcom`.
- **Reduced DCOM coverage.** If a host is still only reachable via `-Protocol Dcom` after
  remediation, say so explicitly. DCOM mode returns a reduced dataset; full confirmation of
  hive-leak and event data requires WinRM. Do not assert "all clear" from a DCOM-only run —
  re-run in WinRM mode once the endpoint recovers.

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser
Invoke-Pester -Path ./scripts/Invoke-RdsProfileTriage.Tests.ps1 -Output Detailed
```

Tests cover the deterministic, remoting-free logic: server-list parsing, time-window
resolution, the **user classification** (anti-misattribution), **ProfileList corruption**
detection (the Element-not-found chain), active-session counting, the `findings` flags, and
compact shaping. The remote/DCOM collectors require a live host and are not unit-tested.
