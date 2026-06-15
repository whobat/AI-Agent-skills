#requires -Version 7.0
<#
.SYNOPSIS
  Read-only triage of Remote Desktop Services (RDS) session-host profile & WinRM-host
  health across one or many servers. Emits structured JSON for an AI agent to reason over.

.DESCRIPTION
  Collects, per host (over WinRM by default; CIM-over-DCOM fallback for hosts whose
  WinRM host process cannot launch):

    - OS / uptime / pending-reboot / C: free space
    - RDS drain state (TSServerDrainMode + chglogon) — is the host taking logons?
    - Roaming profile path read RAW (DoNotExpandEnvironmentNames) so %USERNAME% is
      NEVER silently expanded to the running account (see the gotcha below)
    - FSLogix presence
    - Profile-hive leak: loaded HKEY_USERS hives vs active sessions
    - Temp-profile sprawl: C:\Users\TEMP* folder count + sample owners
    - ProfileList corruption: empty ProfileImagePath, *.bak, temp-pointing, stale entries
      (the "Element not found" class that breaks the WSMan host process)
    - User Profiles Service failure events GROUPED BY THE ACTUAL USER (event UserId SID),
      each tagged user_class so you don't misattribute one service account's churn —
      or your own double-hop connection — as a farm-wide outage
    - WinRM host-launch health: DCOM 10000 (wsmprovhost) + WinRM/Operational 86 counts

  The script does NOT call an LLM and makes NO changes — it produces data and a set of
  deterministic `findings`; the agent writes the narrative and decides remediation.

  Auth: a tier-admin credential is ALWAYS prompted for (Get-Credential), held in memory
  for the run only, reused across all hosts, never persisted.

  TWO GOTCHAS THIS SCRIPT IS BUILT TO STOP YOU REPEATING (full list in REFERENCE.md):
    1. REG_EXPAND_SZ expansion. `(Get-ItemProperty ...).MachineProfilePath` EXPANDS
       %USERNAME% in the CALLING account's context. Read as the connecting admin, a
       correct `\\fs\profiles$\%USERNAME%\..` looks "hardcoded to <admin>". This script
       reads it raw — trust `roaming_profile.machine_profile_path_raw`, not an expanded read.
    2. Double-hop. From a NON-domain-joined / workgroup operator box, WinRM uses NTLM and
       the remote host cannot delegate to a file server. Roaming-profile load then fails
       with "Access is denied" — for the CONNECTING account only. Those Event 1521s are
       YOUR artifact, not a user outage. The script tags such events user_class=self_or_admin.

.EXAMPLE
  ./Invoke-RdsProfileTriage.ps1 -ComputerName RDS01

.EXAMPLE
  ./Invoke-RdsProfileTriage.ps1 -ComputerName RDS01,RDS02 -Hours 48 -OutFile rds.json

.EXAMPLE
  # WinRM host won't launch on this box? Collect the registry/CIM subset over DCOM:
  ./Invoke-RdsProfileTriage.ps1 -ComputerName RDS01 -Protocol Dcom

.NOTES
  Requires PowerShell 7+. WinRM mode needs PowerShell Remoting on the target; DCOM mode
  needs DCOM/WMI (TCP 135 + dynamic) reachable. Read-only. See REFERENCE.md.
#>
[CmdletBinding()]
param(
  [string[]]$ComputerName,
  [string]$ServerListFile,
  [int]$Hours = 24,
  [datetime]$Since,
  [datetime]$From,
  [datetime]$To,
  [ValidateSet('WinRM', 'Dcom')]
  [string]$Protocol = 'WinRM',
  [int]$TempSampleSize = 10,
  [int]$MaxCorruptListed = 20,
  [int]$MaxMessageLength = 400,
  # Output shape. 'text' = deterministic, uniform human report (default — relay it as-is).
  # 'json' = full/compact JSON. 'both' = report then JSON.
  [ValidateSet('text', 'json', 'both')]
  [string]$Format = 'text',
  [string]$OutFile,
  [ValidateSet('Default', 'Negotiate', 'Kerberos', 'CredSSP')]
  [string]$Authentication = 'Default',
  # Testing/automation seam. Normal use OMITS this and is prompted.
  [pscredential]$Credential
)

$ErrorActionPreference = 'Stop'

# ===========================================================================
# Pure, testable helpers (no remoting / no prompts).
# ===========================================================================

# Parse a server-list file: one hostname per line; '#' comments and blank lines ignored.
function Read-ServerList {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "Server list file not found: $Path" }
  Get-Content -LiteralPath $Path |
    ForEach-Object { ($_ -replace '#.*$', '').Trim() } |
    Where-Object { $_ -ne '' }
}

# Resolve the look-back window to [from,to] in local time. -From/-To win, then -Since, then -Hours.
function Resolve-TimeWindow {
  param([int]$Hours = 24, [datetime]$Since, [datetime]$From, [datetime]$To, [datetime]$Now = (Get-Date))
  if ($From -and $To) { return @{ From = $From; To = $To } }
  if ($From) { return @{ From = $From; To = $Now } }
  if ($Since) { return @{ From = $Since; To = $Now } }
  return @{ From = $Now.AddHours(-[math]::Abs($Hours)); To = $Now }
}

# Classify the owner of a profile-failure event so the agent does not misattribute it.
#  self_or_admin   -> equals the connecting credential -> on a workgroup operator box this
#                     is almost always a DOUBLE-HOP artifact, not a real user outage.
#  service_account -> machine ($) or name matching common service patterns -> churn, expected.
#  interactive_user-> a real human; THIS is the one that matters if it is failing.
function Get-ProfileUserClass {
  param([string]$UserName, [string]$CredUserName)
  if ([string]::IsNullOrWhiteSpace($UserName)) { return 'unknown' }
  $leaf = ($UserName -split '\\')[-1]
  if ($CredUserName) {
    $credLeaf = ($CredUserName -split '\\')[-1]
    if ($leaf -ieq $credLeaf -or $UserName -ieq $CredUserName) { return 'self_or_admin' }
  }
  if ($leaf -match '\$$') { return 'service_account' }
  if ($leaf -match '(?i)(svc|service|backup|veeam|spool|monitor|scheduler|automation)') { return 'service_account' }
  if ($leaf -match '(?i)(^|[-_.])(sql|task|sched|batch|agent|scan|bak)([-_.]|\d|$)') { return 'service_account' }
  return 'interactive_user'
}

# Given ProfileList entries [{sid,path,state}], flag the corrupt classes that cause
# "Element not found" / temp-profile fallback and can break the WSMan host process.
function Test-ProfileListCorruption {
  param([object[]]$Entries)
  $corrupt = foreach ($e in $Entries) {
    $reasons = @()
    if ([string]::IsNullOrWhiteSpace($e.path)) { $reasons += 'empty_profile_image_path' }
    if ($e.sid -like '*.bak') { $reasons += 'bak_entry' }
    if ($e.path -like '*\TEMP*') { $reasons += 'points_to_temp_profile' }
    if ($reasons.Count) { [pscustomobject]@{ sid = $e.sid; path = $e.path; state = $e.state; reason = ($reasons -join ',') } }
  }
  [pscustomobject]@{
    total         = $Entries.Count
    empty_path    = @($corrupt | Where-Object reason -like '*empty_profile_image_path*').Count
    bak           = @($corrupt | Where-Object reason -like '*bak_entry*').Count
    temp_pointing = @($corrupt | Where-Object reason -like '*points_to_temp_profile*').Count
    corrupt       = @($corrupt)
  }
}

# Count active interactive sessions from `quser` text (header + rows; STATE column).
function Get-ActiveSessionCount {
  param([string[]]$QuserLines)
  if (-not $QuserLines) { return 0 }
  @($QuserLines | Select-Object -Skip 1 | Where-Object { $_ -match '\bActive\b' }).Count
}

# Build the ranked, plain-English findings list the agent leads with.
function Get-Findings {
  param([object]$HostData)
  $f = [System.Collections.Generic.List[object]]::new()
  $add = { param($sev, $msg) $f.Add([pscustomobject]@{ severity = $sev; finding = $msg }) }

  if ($HostData.winrm_host_launch -and $HostData.winrm_host_launch.failing) {
    & $add 'critical' ("WSMan host process is FAILING to launch (DCOM 10000 wsmprovhost x$($HostData.winrm_host_launch.dcom10000_wsmprovhost), WinRM 86 x$($HostData.winrm_host_launch.winrm86)). Usual cause: corrupt ProfileList entries -> 'Element not found'. See REFERENCE 'host-launch chain'.")
  }
  if ($HostData.profilelist -and ($HostData.profilelist.empty_path + $HostData.profilelist.bak + $HostData.profilelist.temp_pointing) -gt 0) {
    & $add 'high' ("ProfileList corruption: $($HostData.profilelist.empty_path) empty-path, $($HostData.profilelist.bak) .bak, $($HostData.profilelist.temp_pointing) temp-pointing entries. Removing these (back up first) fixes 'Element not found' / WinRM host launch.")
  }
  if ($HostData.hive_leak -and $HostData.hive_leak.leaked -gt 2) {
    & $add 'high' ("Profile-hive leak: $($HostData.hive_leak.loaded_user_hives) hives loaded vs $($HostData.hive_leak.active_sessions) active sessions ($($HostData.hive_leak.leaked) orphaned). Stuck hives cause 'logged out'/temp profiles. Reboot clears them.")
  }
  if ($HostData.temp_profiles -and $HostData.temp_profiles.count -ge 50) {
    & $add 'medium' ("Temp-profile sprawl: $($HostData.temp_profiles.count) C:\Users\TEMP* folders. Check sample owners — usually ONE service/batch account, not real users. Clean up + exclude that account from the roaming GPO.")
  }
  if ($HostData.drain -and $HostData.drain.accepting_logons -eq $false) {
    & $add 'medium' ("Host is in DRAIN mode ($($HostData.drain.state_text)) — not taking new logons. TSServerDrainMode resets on reboot; or run 'chglogon /enable'.")
  }
  if ($HostData.uptime_hours -ge (45 * 24)) {
    & $add 'medium' ("Uptime $([math]::Round($HostData.uptime_hours/24,0)) days — long uptime accumulates leaked hives/sessions on RDS. Schedule periodic reboots.")
  }
  if ($HostData.disk -and $HostData.disk.pct_free -lt 12) {
    & $add 'medium' ("C: only $($HostData.disk.pct_free)% free ($($HostData.disk.c_free_gb) GB). Temp-profile creation fails on a full drive.")
  }
  $realUserFails = @($HostData.profile_events | Where-Object { $_.user_class -eq 'interactive_user' })
  if ($realUserFails.Count) {
    $names = ($realUserFails.user | Select-Object -Unique) -join ', '
    & $add 'high' ("Profile failures for REAL interactive users: $names. This is a genuine user-facing problem (not double-hop/service-account noise) — investigate their roaming profile + hive state.")
  }
  $f
}

# Render the report object as a deterministic, uniform plain-text triage report.
# Pure (no remoting). This is what the agent relays verbatim — same shape every run.
function Format-TriageReport {
  param([Parameter(Mandatory)][object]$Report)
  $tags = @{ critical = '[CRIT]'; high = '[HIGH]'; medium = '[MED ]' }
  $L = [System.Collections.Generic.List[string]]::new()
  $drainText = {
    param($d)
    if ($null -eq $d) { return 'n/a' }
    if ($d.accepting_logons -eq $false) { return 'ON (NOT accepting new logons)' }
    if ($d.accepting_logons -eq $true) { return 'off (accepting logons)' }
    "mode=$($d.mode)"
  }

  $L.Add("RDS PROFILE TRIAGE  -  $($Report.generated_at)")
  $L.Add("Hosts: $(($Report.query.hosts) -join ', ')  |  Window: $($Report.query.from)..$($Report.query.to)  |  Protocol: $($Report.query.protocol)")
  $L.Add("Status: $($Report.status.ToUpper())  |  Collected: $($Report.summary.hosts_ok)/$($Report.summary.hosts_total) hosts")
  $L.Add('')
  $L.Add('== FINDINGS (ranked) ==')
  if (@($Report.summary.findings).Count -eq 0) {
    $L.Add('  OK - no issues flagged.')
  }
  else {
    foreach ($f in $Report.summary.findings) {
      $tag = $tags[$f.severity]; if (-not $tag) { $tag = '[----]' }
      $L.Add("  $tag [$($f.computer)] $($f.finding)")
    }
  }
  $L.Add('')
  $L.Add('== PER-HOST ==')
  foreach ($h in $Report.hosts) {
    if ($h.status -ne 'ok') {
      $L.Add("  $($h.computer): FAILED - $($h.error)")
      if ($h.hint) { $L.Add("      hint: $($h.hint)") }
      continue
    }
    $L.Add("  $($h.computer)  [$($h.collection_method)]  $($h.os)")
    $L.Add("      uptime: $([math]::Round($h.uptime_hours / 24, 1))d   C: free $($h.disk.pct_free)% ($($h.disk.c_free_gb) GB)   pending_reboot: $($h.pending_reboot)")
    $L.Add("      drain: $(& $drainText $h.drain)")
    if ($null -ne $h.hive_leak) { $L.Add("      hive leak: $($h.hive_leak.leaked) orphaned ($($h.hive_leak.loaded_user_hives) loaded vs $($h.hive_leak.active_sessions) sessions)") }
    if ($null -ne $h.temp_profiles) {
      $own = (@($h.temp_profiles.sample) | Select-Object -First 1).owner
      $L.Add("      temp profiles: $($h.temp_profiles.count)$(if ($own) { "  (newest owner: $own)" })")
    }
    if ($null -ne $h.profilelist) { $L.Add("      ProfileList: $($h.profilelist.total) entries; corrupt: $($h.profilelist.empty_path) empty / $($h.profilelist.bak) .bak / $($h.profilelist.temp_pointing) temp-pointing") }
    if ($null -ne $h.roaming_profile) { $L.Add("      roaming path (RAW): $($h.roaming_profile.machine_profile_path_raw)") }
    if ($null -ne $h.winrm_host_launch) {
      $L.Add("      WinRM host-launch: $(if ($h.winrm_host_launch.failing) { "FAILING (DCOM10000 x$($h.winrm_host_launch.dcom10000_wsmprovhost), WinRM86 x$($h.winrm_host_launch.winrm86))" } else { 'ok' })")
    }
    $pe = @($h.profile_events)
    if ($pe.Count) {
      $L.Add('      profile events (by actual user):')
      foreach ($e in ($pe | Select-Object -First 6)) { $L.Add("        $($e.count)x  id $($e.event_id)  $($e.user) [$($e.user_class)]") }
      if ($pe.Count -gt 6) { $L.Add("        (+$($pe.Count - 6) more user/event groups)") }
    }
    if ($h.dcom_note) { $L.Add("      note: $($h.dcom_note)") }
  }
  if (@($Report.summary.failures).Count) {
    $L.Add(''); $L.Add('== COVERAGE GAPS ==')
    foreach ($fa in $Report.summary.failures) { $L.Add("  $($fa.computer): $($fa.status) - $($fa.error)"); if ($fa.hint) { $L.Add("      hint: $($fa.hint)") } }
  }
  $L.Add(''); $L.Add('== CAVEATS (apply before concluding) ==')
  foreach ($c in $Report.caveats) { $L.Add("  - $c") }
  ($L -join "`n")
}

# Reduce a full report to the compact stdout form used with -OutFile.
function ConvertTo-CompactReport {
  param([Parameter(Mandatory)][object]$Report)
  [pscustomobject]@{
    status       = $Report.status
    generated_at = $Report.generated_at
    query        = $Report.query
    summary      = $Report.summary
    caveats      = $Report.caveats
    note         = 'Compact view (full per-host detail written to -OutFile).'
  }
}

# ===========================================================================
# The per-host collector that runs INSIDE the remote session (WinRM mode).
# Returns one PSCustomObject. Self-contained: no outer functions referenced.
# ===========================================================================
$RemoteCollector = {
  param([datetime]$From, [datetime]$To, [int]$TempSampleSize, [int]$MaxMessageLength, [string]$CredUserName)

  function U([datetime]$d) { $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
  function Trunc([string]$s, [int]$n) { if ($null -eq $s) { return $null }; $s = ($s -split "`r?`n")[0]; if ($s.Length -gt $n) { $s.Substring(0, $n) + '...' } else { $s } }
  function ClassOf([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return 'unknown' }
    $leaf = ($name -split '\\')[-1]
    if ($CredUserName) { $cl = ($CredUserName -split '\\')[-1]; if ($leaf -ieq $cl -or $name -ieq $CredUserName) { return 'self_or_admin' } }
    if ($leaf -match '\$$') { return 'service_account' }
    if ($leaf -match '(?i)(svc|service|backup|veeam|spool|monitor|scheduler|automation)') { return 'service_account' }
    if ($leaf -match '(?i)(^|[-_.])(sql|task|sched|batch|agent|scan|bak)([-_.]|\d|$)') { return 'service_account' }
    'interactive_user'
  }

  $os = Get-CimInstance Win32_OperatingSystem
  $boot = $os.LastBootUpTime
  $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"

  # Roaming profile path — RAW (do NOT expand %USERNAME%).
  $sysKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Default').OpenSubKey('SOFTWARE\Policies\Microsoft\Windows\System')
  $rawPath = $null; $kind = $null
  if ($sysKey -and ($sysKey.GetValueNames() -contains 'MachineProfilePath')) {
    $rawPath = $sysKey.GetValue('MachineProfilePath', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $kind = $sysKey.GetValueKind('MachineProfilePath').ToString()
  }
  $tsKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Default').OpenSubKey('SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services')
  $wfPath = if ($tsKey) { $tsKey.GetValue('WFProfilePath', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null }

  # Drain mode.
  $tsCtl = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue
  $drainMode = $tsCtl.TSServerDrainMode
  $drainText = (cmd /c "chglogon /query 2>&1") -join ' '

  # Hive leak: loaded user hives vs active sessions.
  $loadedHives = @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
      Where-Object { $_.PSChildName -like 'S-1-5-21-*' -and $_.PSChildName -notlike '*_Classes' }).Count
  $quser = @(cmd /c "quser 2>&1")
  $activeSessions = @($quser | Select-Object -Skip 1 | Where-Object { $_ -match '\bActive\b' }).Count

  # Temp-profile sprawl.
  $tempDirs = @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'TEMP' -or $_.Name -like 'TEMP.*' })
  $tempSample = $tempDirs | Sort-Object LastWriteTime -Descending | Select-Object -First $TempSampleSize | ForEach-Object {
    $owner = try { (Get-Acl $_.FullName).Owner } catch { $null }
    [pscustomobject]@{ name = $_.Name; last_write = (U $_.LastWriteTime); owner = $owner }
  }

  # ProfileList corruption.
  $plKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
  $entries = foreach ($k in Get-ChildItem $plKey -ErrorAction SilentlyContinue) {
    $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
    [pscustomobject]@{ sid = $k.PSChildName; path = $p.ProfileImagePath; state = $p.State }
  }
  $corrupt = foreach ($e in $entries) {
    $r = @()
    if ([string]::IsNullOrWhiteSpace($e.path)) { $r += 'empty_profile_image_path' }
    if ($e.sid -like '*.bak') { $r += 'bak_entry' }
    if ($e.path -like '*\TEMP*') { $r += 'points_to_temp_profile' }
    if ($r.Count) { [pscustomobject]@{ sid = $e.sid; path = $e.path; state = $e.state; reason = ($r -join ',') } }
  }

  # User Profiles Service failure events, grouped by ACTUAL user (event UserId SID).
  $ids = 1500, 1501, 1502, 1504, 1505, 1509, 1511, 1521, 1530, 1542
  $pe = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Microsoft-Windows-User Profiles Service'; Id = $ids; StartTime = $From; EndTime = $To } -ErrorAction SilentlyContinue
  $peGroups = $pe | ForEach-Object {
    $uname = $null
    if ($_.UserId) { try { $uname = $_.UserId.Translate([System.Security.Principal.NTAccount]).Value } catch { $uname = $_.UserId.Value } }
    [pscustomobject]@{ id = $_.Id; user = $uname; time = $_.TimeCreated; msg = $_.Message }
  } | Group-Object id, user | ForEach-Object {
    $g = $_.Group
    [pscustomobject]@{
      event_id       = $g[0].id
      user           = $g[0].user
      user_class     = (ClassOf $g[0].user)
      count          = $_.Count
      first_seen     = (U ($g.time | Measure-Object -Minimum).Minimum)
      last_seen      = (U ($g.time | Measure-Object -Maximum).Maximum)
      sample_message = (Trunc $g[0].msg $MaxMessageLength)
    }
  } | Sort-Object @{e = { $_.user_class -eq 'interactive_user' }; Descending = $true }, count -Descending

  # WinRM host-launch health (DCOM 10000 wsmprovhost + WinRM/Operational 86).
  $dcom = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 10000; ProviderName = 'Microsoft-Windows-DistributedCOM'; StartTime = $From; EndTime = $To } -ErrorAction SilentlyContinue |
      Where-Object { $_.Message -match 'wsmprovhost' }).Count
  $winrm86 = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-WinRM/Operational'; Id = 86; StartTime = $From; EndTime = $To } -ErrorAction SilentlyContinue).Count

  $pendCbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
  $pendWu = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'

  [pscustomobject]@{
    computer          = $env:COMPUTERNAME
    collection_method = 'winrm'
    os                = $os.Caption
    last_boot         = (U $boot)
    uptime_hours      = [math]::Round(((Get-Date) - $boot).TotalHours, 1)
    pending_reboot    = ($pendCbs -or $pendWu)
    drain             = [pscustomobject]@{ mode = $drainMode; state_text = $drainText.Trim(); accepting_logons = ($drainText -notmatch 'DISABLED') }
    disk              = [pscustomobject]@{ c_free_gb = [math]::Round($c.FreeSpace / 1GB, 2); c_total_gb = [math]::Round($c.Size / 1GB, 1); pct_free = [math]::Round($c.FreeSpace / $c.Size * 100, 1) }
    fslogix           = [pscustomobject]@{ installed = (Test-Path 'HKLM:\SOFTWARE\FSLogix\Apps'); profiles_enabled = ((Get-ItemProperty 'HKLM:\SOFTWARE\FSLogix\Profiles' -ErrorAction SilentlyContinue).Enabled) }
    roaming_profile   = [pscustomobject]@{ machine_profile_path_raw = $rawPath; value_kind = $kind; rds_wf_profile_path = $wfPath; note = 'RAW value — %USERNAME% intentionally NOT expanded.' }
    hive_leak         = [pscustomobject]@{ loaded_user_hives = $loadedHives; active_sessions = $activeSessions; leaked = [math]::Max(0, $loadedHives - $activeSessions) }
    temp_profiles     = [pscustomobject]@{ count = $tempDirs.Count; sample = @($tempSample) }
    profilelist       = [pscustomobject]@{ total = @($entries).Count; empty_path = @($corrupt | Where-Object reason -like '*empty*').Count; bak = @($corrupt | Where-Object reason -like '*bak*').Count; temp_pointing = @($corrupt | Where-Object reason -like '*temp*').Count; corrupt = @($corrupt) }
    profile_events    = @($peGroups)
    winrm_host_launch = [pscustomobject]@{ dcom10000_wsmprovhost = $dcom; winrm86 = $winrm86; failing = (($dcom + $winrm86) -gt 0) }
  }
}

# ===========================================================================
# CIM-over-DCOM collector (reduced) — for hosts whose WinRM host won't launch.
# Reads via StdRegProv; no folder enumeration / no event log.
# ===========================================================================
function Invoke-DcomCollector {
  param([string]$Computer, [pscredential]$Cred)
  $opt = New-CimSessionOption -Protocol Dcom
  $cs = New-CimSession -ComputerName $Computer -Credential $Cred -SessionOption $opt -ErrorAction Stop
  try {
    $HKLM = [uint32]2147483650
    function RegStr($p, $n) { (Invoke-CimMethod -CimSession $cs -Namespace root\default -ClassName StdRegProv -MethodName GetStringValue -Arguments @{hDefKey = $HKLM; sSubKeyName = $p; sValueName = $n }).sValue }
    function RegDw($p, $n) { (Invoke-CimMethod -CimSession $cs -Namespace root\default -ClassName StdRegProv -MethodName GetDWORDValue -Arguments @{hDefKey = $HKLM; sSubKeyName = $p; sValueName = $n }).uValue }
    $os = Get-CimInstance Win32_OperatingSystem -CimSession $cs
    # NB: StdRegProv GetStringValue does NOT expand REG_EXPAND_SZ -> raw %USERNAME% preserved (good).
    $rawPath = RegStr 'SOFTWARE\Policies\Microsoft\Windows\System' 'MachineProfilePath'
    $plPath = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $sub = (Invoke-CimMethod -CimSession $cs -Namespace root\default -ClassName StdRegProv -MethodName EnumKey -Arguments @{hDefKey = $HKLM; sSubKeyName = $plPath }).sNames
    $entries = foreach ($s in $sub) { [pscustomobject]@{ sid = $s; path = (RegStr "$plPath\$s" 'ProfileImagePath'); state = (RegDw "$plPath\$s" 'State') } }
    $corruptInfo = Test-ProfileListCorruption -Entries $entries
    [pscustomobject]@{
      computer          = $os.CSName
      collection_method = 'dcom'
      os                = $os.Caption
      last_boot         = $os.LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
      uptime_hours      = [math]::Round(((Get-Date).ToUniversalTime() - $os.LastBootUpTime.ToUniversalTime()).TotalHours, 1)
      drain             = [pscustomobject]@{ mode = (RegDw 'SYSTEM\CurrentControlSet\Control\Terminal Server' 'TSServerDrainMode'); state_text = $null; accepting_logons = $null }
      roaming_profile   = [pscustomobject]@{ machine_profile_path_raw = $rawPath; value_kind = 'ExpandString(assumed)'; rds_wf_profile_path = $null; note = 'RAW via StdRegProv (no expansion). DCOM mode: reduced dataset.' }
      profilelist       = [pscustomobject]@{ total = $corruptInfo.total; empty_path = $corruptInfo.empty_path; bak = $corruptInfo.bak; temp_pointing = $corruptInfo.temp_pointing; corrupt = $corruptInfo.corrupt }
      hive_leak         = $null; temp_profiles = $null; profile_events = @(); fslogix = $null
      winrm_host_launch = $null
      dcom_note         = 'WinRM unavailable -> reduced CIM/DCOM collection. hive_leak/temp_profiles/events not collected. If profilelist shows corruption, that alone often explains the WinRM host-launch failure.'
    }
  }
  finally { if ($cs) { Remove-CimSession $cs } }
}

# ===========================================================================
# Orchestrator (skipped when the script is dot-sourced, e.g. by Pester).
# ===========================================================================
if ($MyInvocation.InvocationName -ne '.') {
$caveats = @(
  "roaming_profile.machine_profile_path_raw is the RAW value. A reading via Get-ItemProperty in a session running as <admin> would WRONGLY show %USERNAME% expanded to <admin> — never conclude the GPO is hardcoded from an expanded read.",
  "profile_events are tagged user_class. user_class=self_or_admin events (especially 1521 'Access is denied') are almost certainly DOUBLE-HOP artifacts when you run from a non-domain-joined/workgroup box — NOT a user outage. Only user_class=interactive_user failures are real user problems.",
  "A single service/batch account can generate thousands of temp profiles. Check temp_profiles.sample owners and the user breakdown of profile_events before calling it farm-wide.",
  "WinRM host-launch failing + ProfileList corruption together = the 'Element not found' chain: corrupt ProfileList entry -> profile cannot be built -> wsmprovhost won't register its COM class -> Event 86 'could not launch host process' + DCOM 10000 'error 0'. Fix = remove the corrupt entries (back up ProfileList first)."
)

# Build host list.
$hosts = @()
if ($ComputerName) { $hosts += $ComputerName }
if ($ServerListFile) { $hosts += Read-ServerList -Path $ServerListFile }
$hosts = $hosts | Where-Object { $_ } | Select-Object -Unique
if (-not $hosts) { throw 'No hosts given. Use -ComputerName and/or -ServerListFile.' }

# Credential: prompt unless supplied (test/automation seam).
if (-not $Credential) { $Credential = Get-Credential -Message 'Tier-admin credential for RDS triage (reused for all hosts, never stored)' }
if (-not $Credential) { throw 'No credential supplied — aborting.' }

$win = Resolve-TimeWindow -Hours $Hours -Since $Since -From $From -To $To
$icmCommon = @{ Credential = $Credential; Authentication = $Authentication; ErrorAction = 'Stop' }

$hostResults = foreach ($h in $hosts) {
  try {
    if ($Protocol -eq 'Dcom') {
      $data = Invoke-DcomCollector -Computer $h -Cred $Credential
    }
    else {
      $data = Invoke-Command @icmCommon -ComputerName $h -ScriptBlock $RemoteCollector `
        -ArgumentList $win.From, $win.To, $TempSampleSize, $MaxMessageLength, $Credential.UserName
    }
    $obj = [pscustomobject]@{ computer = $h; status = 'ok'; error = $null; hint = $null }
    foreach ($p in $data.PSObject.Properties) { if ($p.Name -notin 'computer') { $obj | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force } }
    $obj | Add-Member -NotePropertyName 'findings' -NotePropertyValue @(Get-Findings -HostData $data) -Force
    $obj
  }
  catch {
    $msg = $_.Exception.Message
    $hint = switch -Regex ($msg) {
      'could not launch a host process' { "WinRM host process can't launch (often ProfileList corruption / 'Element not found'). Re-run with -Protocol Dcom to read uptime/drain/roaming-raw/ProfileList over DCOM." ; break }
      'TrustedHosts|0x80090311' { 'Workgroup/cross-domain WinRM. Run from a domain-joined admin host, or add the FQDNs to WinRM TrustedHosts, or use -Protocol Dcom.' ; break }
      'Access is denied' { 'Credential lacks rights on this host, or wrong tier.' ; break }
      default { $null }
    }
    [pscustomobject]@{ computer = $h; status = 'failed'; error = $msg; hint = $hint }
  }
}

$ok = @($hostResults | Where-Object status -eq 'ok')
$failed = @($hostResults | Where-Object status -ne 'ok')
$report = [pscustomobject]@{
  status       = if ($failed.Count -eq 0) { 'ok' } elseif ($ok.Count -eq 0) { 'error' } else { 'partial' }
  generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  query        = [pscustomobject]@{ hosts = @($hosts); from = $win.From.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); to = $win.To.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); protocol = $Protocol }
  hosts        = @($hostResults)
  summary      = [pscustomobject]@{
    hosts_total = @($hosts).Count
    hosts_ok    = $ok.Count
    hosts_failed = $failed.Count
    failures    = @($failed | Select-Object computer, status, error, hint)
    findings    = @($ok | ForEach-Object { $c = $_.computer; $_.findings | ForEach-Object { [pscustomobject]@{ computer = $c; severity = $_.severity; finding = $_.finding } } } |
        Sort-Object @{e = { switch ($_.severity) { 'critical' { 0 } 'high' { 1 } 'medium' { 2 } default { 3 } } } })
  }
  caveats      = $caveats
}

# Full detail always goes to -OutFile (JSON) when requested, regardless of -Format.
if ($OutFile) { $report | ConvertTo-Json -Depth 12 | Out-File -FilePath $OutFile -Encoding utf8 }

$jsonOut = if ($OutFile) { (ConvertTo-CompactReport -Report $report) | ConvertTo-Json -Depth 8 } else { $report | ConvertTo-Json -Depth 12 }

switch ($Format) {
  'text' { Format-TriageReport -Report $report }
  'json' { $jsonOut }
  'both' { Format-TriageReport -Report $report; ''; '--- JSON ---'; $jsonOut }
}
} # end dot-source guard
