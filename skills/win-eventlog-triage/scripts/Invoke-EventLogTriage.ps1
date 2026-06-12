#requires -Version 7.0
<#
.SYNOPSIS
  Collect, filter and group Windows Event Log entries from one or many servers,
  in parallel, and emit structured JSON for an AI agent to triage.

.DESCRIPTION
  Pulls Critical/Error (optionally Warning) events from the System + Application
  logs (Security/operational logs are opt-in) across a time window, groups them
  deterministically, and ranks the most critical groups. The script does NOT
  call an LLM: it produces data; the agent reasons over it.

  Auth: a tier-admin credential is ALWAYS prompted for (Get-Credential), held in
  memory only for the run and reused across all servers. Nothing is persisted.

  Output contract:
    - With -OutFile : full detail JSON -> file, compact JSON (summary + top
                      critical) -> stdout.
    - Without       : full detail JSON -> stdout.

.EXAMPLE
  ./Invoke-EventLogTriage.ps1 -ComputerName SRV01

.EXAMPLE
  ./Invoke-EventLogTriage.ps1 -ServerListFile hosts.txt -Hours 12 -OutFile triage.json

.NOTES
  Requires PowerShell 7+ (uses ForEach-Object -Parallel) and WinRM enabled on
  the target servers. See REFERENCE.md for the full parameter and schema docs.
#>
[CmdletBinding()]
param(
  [string[]]$ComputerName,
  [string]$ServerListFile,
  [string[]]$Logs = @('System', 'Application'),
  [switch]$IncludeSecurity,
  [switch]$IncludeWarning,
  [int[]]$Level,
  [int]$Hours = 24,
  [datetime]$Since,
  [datetime]$From,
  [datetime]$To,
  [int]$MaxEvents = 5000,
  [string]$SuppressList,
  [int]$MaxMessageLength = 1000,
  [int]$ThrottleLimit = 8,
  [int]$TopCritical = 20,
  [string]$OutFile,
  [switch]$UseSSL,
  [ValidateSet('Default', 'Basic', 'Negotiate', 'Kerberos', 'CredSSP')]
  [string]$Authentication = 'Default',
  # Testing/automation seam. Normal use OMITS this and is prompted.
  [pscredential]$Credential
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Pure, testable helpers (no remoting / no prompts).
# ---------------------------------------------------------------------------

# Parse a server-list file: one hostname per line; '#' comments and blank lines ignored.
function Read-ServerList {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "Server list file not found: $Path" }
  Get-Content -LiteralPath $Path |
    ForEach-Object { ($_ -replace '#.*$', '').Trim() } |
    Where-Object { $_ -ne '' }
}

# Merge -ComputerName and -ServerListFile into a unique, ordered host list.
function Resolve-TargetComputers {
  param([string[]]$ComputerName, [string]$ServerListFile)
  $list = [System.Collections.Generic.List[string]]::new()
  if ($ComputerName) { foreach ($c in $ComputerName) { if ($c.Trim()) { $list.Add($c.Trim()) } } }
  if ($ServerListFile) { foreach ($c in (Read-ServerList -Path $ServerListFile)) { $list.Add($c) } }
  $list | Select-Object -Unique
}

# Decide which severity levels to query. Explicit -Level wins; else Critical+Error (+Warning).
function Resolve-Levels {
  param([int[]]$Level, [switch]$IncludeWarning)
  if ($Level) { return ($Level | Select-Object -Unique) }
  if ($IncludeWarning) { return @(1, 2, 3) }
  return @(1, 2)
}

# Final log set: defaults plus Security when -IncludeSecurity is set.
function Resolve-Logs {
  param([string[]]$Logs, [switch]$IncludeSecurity)
  $set = [System.Collections.Generic.List[string]]::new()
  foreach ($l in $Logs) { if ($l.Trim()) { $set.Add($l.Trim()) } }
  if ($IncludeSecurity -and ($set -notcontains 'Security')) { $set.Add('Security') }
  $set | Select-Object -Unique
}

# Resolve the [start,end] window (local DateTimes for FilterHashtable). Priority: From/To > Since > Hours.
function Resolve-TimeWindow {
  param([int]$Hours, [datetime]$Since, [datetime]$From, [datetime]$To, [datetime]$Now = (Get-Date))
  if ($PSBoundParameters.ContainsKey('From') -or $PSBoundParameters.ContainsKey('To')) {
    $start = if ($PSBoundParameters.ContainsKey('From')) { $From } else { $Now.AddHours(-$Hours) }
    $end = if ($PSBoundParameters.ContainsKey('To')) { $To } else { $Now }
  }
  elseif ($PSBoundParameters.ContainsKey('Since')) {
    $start = $Since; $end = $Now
  }
  else {
    $start = $Now.AddHours(-$Hours); $end = $Now
  }
  if ($start -gt $end) { throw "Start time ($start) is after end time ($end)." }
  [pscustomobject]@{ StartTime = $start; EndTime = $end }
}

# Load a suppress list (JSON: { "eventIds": [..], "providers": [".."] }). Missing/empty => nothing suppressed.
function Get-SuppressSet {
  param([string]$Path)
  $empty = [pscustomobject]@{ eventIds = @(); providers = @() }
  if (-not $Path) { return $empty }
  if (-not (Test-Path -LiteralPath $Path)) { throw "Suppress list file not found: $Path" }
  $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  [pscustomobject]@{
    eventIds  = @($json.eventIds)
    providers = @($json.providers)
  }
}

# True when a group should be dropped per the suppress set.
function Test-Suppressed {
  param([Parameter(Mandatory)]$Group, [Parameter(Mandatory)]$Suppress)
  if ($Suppress.eventIds -contains $Group.event_id) { return $true }
  if ($Suppress.providers -contains $Group.provider) { return $true }
  return $false
}

# Group lightweight event records (Computer/Log/Provider/EventId/Level/TimeCreatedUtc/Message)
# into aggregated groups with counts, first/last seen and one sample message.
function Group-EventRecords {
  param([object[]]$Records, [object]$Suppress)
  if (-not $Records) { return @() }
  $groups = $Records | Group-Object -Property Computer, Log, Provider, EventId, Level | ForEach-Object {
    $first = $_.Group[0]
    $times = $_.Group.TimeCreatedUtc | Sort-Object
    [pscustomobject]@{
      computer       = $first.Computer
      log            = $first.Log
      provider       = $first.Provider
      event_id       = $first.EventId
      level          = $first.Level
      count          = $_.Count
      first_seen     = $times[0]
      last_seen      = $times[-1]
      sample_message = $first.Message
    }
  }
  if ($Suppress) { $groups = $groups | Where-Object { -not (Test-Suppressed -Group $_ -Suppress $Suppress) } }
  @($groups)
}

# Deterministic ranking: Critical before Error before Warning before rest; then count desc, last_seen desc.
function Select-TopCritical {
  param([object[]]$Groups, [int]$Top = 20)
  if (-not $Groups) { return @() }
  $rank = @{ 'Critical' = 0; 'Error' = 1; 'Warning' = 2 }
  $sorted = $Groups | Sort-Object `
    @{ Expression = { if ($rank.ContainsKey($_.level)) { $rank[$_.level] } else { 9 } } }, `
    @{ Expression = 'count'; Descending = $true }, `
    @{ Expression = 'last_seen'; Descending = $true }
  @($sorted | Select-Object -First $Top)
}

# Classify a remoting failure message into a per-host status plus an actionable hint.
function Get-FailureClassification {
  param([string]$Message)
  $m = [string]$Message
  if ($m -match 'TrustedHosts') {
    return [pscustomobject]@{ status = 'auth_failed'; hint = 'NTLM path blocked: add the host to WinRM TrustedHosts on this client (Set-Item WSMan:\localhost\Client\TrustedHosts), or pass -UseSSL, or run from a domain-joined host so Kerberos is used.' }
  }
  if ($m -match '0x80090311|no authenticating authority|dom.net ikke|domain.*not avail') {
    return [pscustomobject]@{ status = 'auth_failed'; hint = 'Kerberos found no domain authority (client likely not domain-joined / no DC reachable). Run from a domain-joined host, or use TrustedHosts + -Authentication Negotiate, or -UseSSL.' }
  }
  if ($m -match 'Access is denied|logon failure|legitimationsoplysninger|authentication failed|0x8009030c') {
    return [pscustomobject]@{ status = 'auth_failed'; hint = 'Credential rejected - verify it is the correct tier-admin account with rights to read these logs on this host.' }
  }
  if ($m -match 'cannot be resolved|actively refused|timed out|RPC server is unavailable|network path|kan ikke fortolkes') {
    return [pscustomobject]@{ status = 'unreachable'; hint = 'Network/DNS/WinRM reachability problem - check name resolution, the 5985/5986 port, and that WinRM is enabled.' }
  }
  if ($m -match 'WinRM|connecting to remote') {
    return [pscustomobject]@{ status = 'unreachable'; hint = 'WinRM connection failed - verify WinRM is enabled and reachable on the target.' }
  }
  return [pscustomobject]@{ status = 'error'; hint = $null }
}

# Derive overall status from per-host statuses.
function Get-OverallStatus {
  param([object[]]$Hosts)
  if (-not $Hosts) { return 'error' }
  $ok = @($Hosts | Where-Object { $_.status -eq 'ok' }).Count
  if ($ok -eq $Hosts.Count) { return 'ok' }
  if ($ok -eq 0) { return 'error' }
  return 'partial'
}

# Build the compact result (summary + top_critical, no per-host groups) for stdout when -OutFile is used.
function ConvertTo-CompactResult {
  param([Parameter(Mandatory)]$Full)
  [pscustomobject]@{
    status       = $Full.status
    generated_at = $Full.generated_at
    query        = $Full.query
    summary      = $Full.summary
    note         = 'Compact view. Full per-host detail written to the -OutFile path.'
  }
}

# ---------------------------------------------------------------------------
# Side-effecting helpers (prompt / remoting). Mocked in tests.
# ---------------------------------------------------------------------------

# Always prompt for the tier-admin credential (unless one was injected for tests/automation).
function Get-AdminCredential {
  param([pscredential]$Provided)
  if ($Provided) { return $Provided }
  $cred = Get-Credential -Message 'Enter the tier-admin credential used to reach the target servers'
  if (-not $cred) { throw 'No credential supplied; aborting.' }
  return $cred
}

# Fetch + project events from a single host. Returns a per-host result object (never throws).
function Invoke-HostTriage {
  param(
    [Parameter(Mandatory)][string]$Computer,
    [pscredential]$Credential,
    [string[]]$Logs,
    [int[]]$Levels,
    [datetime]$StartTime,
    [datetime]$EndTime,
    [int]$MaxEvents,
    [int]$MaxMessageLength,
    [switch]$UseSSL,
    [string]$Authentication = 'Default'
  )

  $remote = {
    param($logs, $levels, $start, $end, $maxEvents, $maxLen)
    # Runs ON the target server, whose Windows PowerShell may be old (Server 2008/2012
    # ship PS 2.0-4.0). The static-new constructor syntax is PS 5.0+, so use New-Object
    # here to stay down-level compatible. Keep this whole block to PS 3.0-era constructs.
    $out = New-Object System.Collections.Generic.List[object]
    $scanned = 0
    $truncated = $false
    foreach ($log in $logs) {
      $filter = @{ LogName = $log; Level = $levels; StartTime = $start; EndTime = $end }
      try {
        $evts = Get-WinEvent -FilterHashtable $filter -MaxEvents $maxEvents -ErrorAction Stop
      }
      catch {
        # "No events were found" is not an error condition for triage.
        if ($_.Exception.Message -match 'No events were found') { continue }
        throw
      }
      $evts = @($evts)
      $scanned += $evts.Count
      if ($evts.Count -ge $maxEvents) { $truncated = $true }
      foreach ($e in $evts) {
        $msg = if ($null -ne $e.Message) { $e.Message } else { '' }
        if ($msg.Length -gt $maxLen) { $msg = $msg.Substring(0, $maxLen) + '...[truncated]' }
        $lvl = if ($e.LevelDisplayName) { $e.LevelDisplayName } else { "Level$($e.Level)" }
        $out.Add([pscustomobject]@{
            Computer       = $env:COMPUTERNAME
            Log            = $e.LogName
            Provider       = $e.ProviderName
            EventId        = [int]$e.Id
            Level          = $lvl
            TimeCreatedUtc = $e.TimeCreated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            Message        = $msg
          })
      }
    }
    [pscustomobject]@{ Records = $out.ToArray(); Scanned = $scanned; Truncated = $truncated }
  }

  $invokeArgs = @{
    ComputerName = $Computer
    ScriptBlock  = $remote
    ArgumentList = @($Logs, $Levels, $StartTime, $EndTime, $MaxEvents, $MaxMessageLength)
    ErrorAction  = 'Stop'
  }
  if ($Credential) { $invokeArgs.Credential = $Credential }
  if ($UseSSL) { $invokeArgs.UseSSL = $true }
  if ($Authentication -and $Authentication -ne 'Default') { $invokeArgs.Authentication = $Authentication }

  try {
    $r = Invoke-Command @invokeArgs
    return [pscustomobject]@{
      computer       = $Computer
      status         = 'ok'
      error          = $null
      hint           = $null
      events_scanned = $r.Scanned
      truncated      = $r.Truncated
      records        = @($r.Records)
    }
  }
  catch {
    $msg = $_.Exception.Message
    $cls = Get-FailureClassification -Message $msg
    return [pscustomobject]@{
      computer       = $Computer
      status         = $cls.status
      error          = $msg
      hint           = $cls.hint
      events_scanned = 0
      truncated      = $false
      records        = @()
    }
  }
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

function Invoke-EventLogTriage {
  [CmdletBinding()]
  param(
    [string[]]$ComputerName,
    [string]$ServerListFile,
    [string[]]$Logs = @('System', 'Application'),
    [switch]$IncludeSecurity,
    [switch]$IncludeWarning,
    [int[]]$Level,
    [int]$Hours = 24,
    [datetime]$Since,
    [datetime]$From,
    [datetime]$To,
    [int]$MaxEvents = 5000,
    [string]$SuppressList,
    [int]$MaxMessageLength = 1000,
    [int]$ThrottleLimit = 8,
    [int]$TopCritical = 20,
    [switch]$UseSSL,
    [string]$Authentication = 'Default',
    [pscredential]$Credential
  )

  $targets = @(Resolve-TargetComputers -ComputerName $ComputerName -ServerListFile $ServerListFile)
  if ($targets.Count -eq 0) { throw 'No target computers. Pass -ComputerName and/or -ServerListFile.' }

  $resolvedLogs = @(Resolve-Logs -Logs $Logs -IncludeSecurity:$IncludeSecurity)
  $levels = @(Resolve-Levels -Level $Level -IncludeWarning:$IncludeWarning)
  $twArgs = @{ Hours = $Hours }
  if ($PSBoundParameters.ContainsKey('Since')) { $twArgs.Since = $Since }
  if ($PSBoundParameters.ContainsKey('From')) { $twArgs.From = $From }
  if ($PSBoundParameters.ContainsKey('To')) { $twArgs.To = $To }
  $window = Resolve-TimeWindow @twArgs
  $suppress = Get-SuppressSet -Path $SuppressList

  $cred = Get-AdminCredential -Provided $Credential

  # Parallel fetch. NOTE: -Parallel runspaces cannot see script functions, so we
  # re-hydrate Invoke-HostTriage from its source text; grouping is done locally.
  # Member access on a $using: variable is unreliable, so pull scalars into locals first.
  $funcDef = ${function:Invoke-HostTriage}.ToString()
  $clsDef = ${function:Get-FailureClassification}.ToString()
  $startTime = $window.StartTime
  $endTime = $window.EndTime
  $hostResults = $targets | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    ${function:Get-FailureClassification} = $using:clsDef
    ${function:Invoke-HostTriage} = $using:funcDef
    Invoke-HostTriage -Computer $_ -Credential $using:cred -Logs $using:resolvedLogs `
      -Levels $using:levels -StartTime $using:startTime -EndTime $using:endTime `
      -MaxEvents $using:MaxEvents -MaxMessageLength $using:MaxMessageLength `
      -UseSSL:$using:UseSSL -Authentication $using:Authentication
  }

  # Local grouping + ranking.
  $hosts = foreach ($hr in $hostResults) {
    $groups = @(Group-EventRecords -Records $hr.records -Suppress $suppress)
    [pscustomobject]@{
      computer       = $hr.computer
      status         = $hr.status
      error          = $hr.error
      hint           = $hr.hint
      events_scanned = $hr.events_scanned
      truncated      = $hr.truncated
      groups         = $groups
    }
  }
  $hosts = @($hosts)

  $allGroups = @($hosts | ForEach-Object { $_.groups })
  $top = @(Select-TopCritical -Groups $allGroups -Top $TopCritical)
  $failures = @($hosts | Where-Object { $_.status -ne 'ok' } |
      Select-Object computer, status, error, hint)

  [pscustomobject]@{
    status       = Get-OverallStatus -Hosts $hosts
    generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    query        = [pscustomobject]@{
      logs                = $resolvedLogs
      levels              = $levels
      from                = $window.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
      to                  = $window.EndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
      max_events_per_log  = $MaxEvents
      suppress_list_applied = [bool]$SuppressList
    }
    hosts        = $hosts
    summary      = [pscustomobject]@{
      hosts_total  = $hosts.Count
      hosts_ok     = @($hosts | Where-Object { $_.status -eq 'ok' }).Count
      hosts_failed = $failures.Count
      total_groups = $allGroups.Count
      total_events = @($hosts | Measure-Object -Property events_scanned -Sum).Sum
      failures     = $failures
      top_critical = $top
    }
  }
}

# Write per the output contract.
function Write-TriageOutput {
  param([Parameter(Mandatory)]$Result, [string]$OutFile)
  if ($OutFile) {
    $Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutFile -Encoding UTF8
    (ConvertTo-CompactResult -Full $Result) | ConvertTo-Json -Depth 8
  }
  else {
    $Result | ConvertTo-Json -Depth 8
  }
}

# ---------------------------------------------------------------------------
# Entrypoint (skipped when the script is dot-sourced, e.g. by Pester).
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
  $triageArgs = @{}
  foreach ($kv in $PSBoundParameters.GetEnumerator()) {
    if ($kv.Key -ne 'OutFile') { $triageArgs[$kv.Key] = $kv.Value }
  }
  $result = Invoke-EventLogTriage @triageArgs
  Write-TriageOutput -Result $result -OutFile $OutFile
}
