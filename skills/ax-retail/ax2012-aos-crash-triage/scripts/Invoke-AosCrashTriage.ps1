#requires -Version 7.0
<#
.SYNOPSIS
  Triage Microsoft Dynamics AX 2012 AOS (Ax32Serv.exe) crashes and the RPC
  session-allocation cascade across the AOS cluster and the RDS/Citrix farm
  that runs the AX rich clients. Emits structured JSON for an agent to reason over.

.DESCRIPTION
  For each AOS server it collects, server-side: the AOS service state, AOS process
  crashes (Application event 1000 / Ax32Serv.exe), unexpected terminations
  (System event 7031 / "...Object Server..."), and the session-allocation precursors
  the AX kernel logs just before the crash (Dynamics Server events 110 "Session
  Allocation Failed: ... already allocated" and 180 "invalid session ID").

  For each optional client/RDS host it collects AX *client* crashes (event 1000 /
  Ax32.exe). The script then correlates AOS terminations against client crashes in a
  short time window to expose the "AOS dies -> every connected client drops at the same
  second -> reconnect storm" cascade.

  The script does NOT call an LLM and makes NO changes (read-only). Auth: a credential
  is ALWAYS prompted (Get-Credential) unless the -Credential test seam is supplied.

  Time window: the look-back is computed ON each target from the integer -Hours, so a
  cross-time-zone sweep is correct (a DateTime passed across Invoke-Command can have its
  Kind reinterpreted and silently shift the window). All output times are UTC ('Z').

.EXAMPLE
  ./Invoke-AosCrashTriage.ps1 -AosComputerName AXAOS01,AXAOS02 -Hours 24

.EXAMPLE
  ./Invoke-AosCrashTriage.ps1 -AosComputerName (Get-Content aos.txt) `
    -ClientComputerName (Get-Content rds.txt) -Hours 6 -OutFile aos-triage.json
#>
[CmdletBinding()]
param(
  [string[]]$AosComputerName,
  [string[]]$ClientComputerName,
  [string]$AosListFile,
  [string]$ClientListFile,
  [int]$Hours = 24,
  [int]$CascadeWindowSeconds = 120,
  [int]$MaxEvents = 2000,
  [int]$MaxMessageLength = 600,
  [int]$ThrottleLimit = 8,
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

function Read-HostListFile {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "Host list file not found: $Path" }
  Get-Content -LiteralPath $Path |
    ForEach-Object { ($_ -replace '#.*$', '').Trim() } |
    Where-Object { $_ -ne '' }
}

# Merge inline names + file into a unique, ordered list.
function Resolve-Hosts {
  param([string[]]$Name, [string]$ListFile)
  $list = [System.Collections.Generic.List[string]]::new()
  if ($Name) { foreach ($c in $Name) { if ($c.Trim()) { $list.Add($c.Trim()) } } }
  if ($ListFile) { foreach ($c in (Read-HostListFile -Path $ListFile)) { $list.Add($c) } }
  $list | Select-Object -Unique
}

# Plain-English meaning of a Windows exception code (the crash *class*, not its cause).
function Get-ExceptionMeaning {
  param([string]$Code)
  switch -regex ([string]$Code) {
    '0xc0000005' { 'access violation (read/write to invalid memory) - needs a dump or a correlatable change to find the faulting code path' ; break }
    '0xc0000374' { 'heap corruption - often a kernel/CU defect (e.g. KB4058327 regression)'; break }
    '0xc0000409' { 'stack buffer overrun (fast-fail)'; break }
    '0xc00000fd' { 'stack overflow (e.g. unbounded recursion)'; break }
    '0xe0434352' { '.NET/CLR unhandled managed exception'; break }
    default      { 'see Windows exception-code reference' }
  }
}

# Extract the faulting-application fields from an Application event 1000 message, with the
# exception class decoded. NOTE: module + offset localise WHERE control was, not WHICH AX code
# path caused the fault - the event carries no call stack. Do not infer a cause from this alone.
function Get-FaultFields {
  param([string]$Message)
  $m = [string]$Message
  $code = if ($m -match 'Exception code:\s*(0x[0-9a-fA-F]+)') { $Matches[1] } else { $null }
  [pscustomobject]@{
    app               = if ($m -match 'Faulting application name:\s*([^,]+)') { $Matches[1].Trim() } else { $null }
    module            = if ($m -match 'Faulting module name:\s*([^,]+)') { $Matches[1].Trim() } else { $null }
    exception         = $code
    exception_meaning = if ($code) { Get-ExceptionMeaning $code } else { $null }
    offset            = if ($m -match 'Fault offset:\s*(0x[0-9a-fA-F]+)') { $Matches[1] } else { $null }
  }
}

# True when a 1000 message is an AOS process crash.
function Test-IsAosCrash { param([string]$Message) [bool]([string]$Message -match 'Ax32Serv') }
# True when a 1000 message is an AX rich-client crash.
function Test-IsClientCrash { param([string]$Message) [bool]([string]$Message -match 'Ax32\.exe') }

# Build a merged, time-sorted timeline of AOS-down events, tagged by crash CLASS so the two
# distinct failure modes are never conflated:
#   access_violation     - Event 1000 / 0xc0000005 (faulting-module signature; no call stack)
#   forced_termination   - Event 110 / "Session Allocation Failed: already allocated" (the AOS
#                          kernel deliberately self-terminates on a session-ID collision)
#   scm_7031             - SCM noticed the service died (class unknown from this event alone)
function Build-CrashTimeline {
  param([object[]]$AosHosts)
  $rows = foreach ($h in $AosHosts) {
    foreach ($c in @($h.access_violations)) { [pscustomobject]@{ computer = $h.computer; class = 'access_violation'; time = $c.t; detail = "$($c.exception) $($c.module)" } }
    foreach ($f in @($h.forced_terminations)) { [pscustomobject]@{ computer = $h.computer; class = 'forced_termination'; time = $f.t; detail = 'session-id collision (Event 110)' } }
    foreach ($t in @($h.scm_terminations)) { [pscustomobject]@{ computer = $h.computer; class = 'scm_7031'; time = $t.t; detail = $null } }
  }
  @($rows | Where-Object { $_.time } | Sort-Object time)
}

# For each AOS event time, count client crashes within +/- window seconds (the cascade signal).
function Get-CascadeCorrelation {
  param([object[]]$Timeline, [object[]]$ClientCrashes, [int]$WindowSeconds = 120)
  if (-not $Timeline) { return @() }
  $cc = @($ClientCrashes)
  foreach ($evt in $Timeline) {
    $t0 = [datetimeoffset]::Parse($evt.time).UtcDateTime
    $near = @($cc | Where-Object {
        $ct = [datetimeoffset]::Parse($_.t).UtcDateTime
        [math]::Abs(($ct - $t0).TotalSeconds) -le $WindowSeconds
      })
    [pscustomobject]@{
      aos_event              = "$($evt.computer) $($evt.class) @ $($evt.time)"
      client_crashes_in_window = $near.Count
      client_hosts             = @($near | Select-Object -ExpandProperty computer -Unique)
    }
  }
}

# Parse the WER LocalDumps registry config for Ax32Serv.exe into a readiness verdict.
# Microsoft AX guidance: DumpType=0 (Custom) with CustomDumpFlags=0x1B67 (NOT mini=1 / full=2).
function Get-DumpReadiness {
  param($Wer)
  if (-not $Wer -or -not $Wer.key_present) {
    return [pscustomobject]@{ ready = $false; note = 'WER LocalDumps NOT configured for Ax32Serv.exe - the next crash will not be captured. Configure it now (see remediation) so a signature-less access violation can be dumped.' }
  }
  $custom = ("$($Wer.dump_type)" -eq '0' -and ("$($Wer.custom_dump_flags)" -match '6999$|0x1B67'))
  if ($custom) { return [pscustomobject]@{ ready = $true; note = 'WER LocalDumps configured with the AX-recommended DumpType=0 / CustomDumpFlags=0x1B67.' } }
  [pscustomobject]@{ ready = $true; note = "WER LocalDumps present but DumpType=$($Wer.dump_type) - AX analysis wants DumpType=0 with CustomDumpFlags=0x1B67 (mini/full omit data the AX analyzer needs)." }
}

function Get-FailureClassification {
  param([string]$Message)
  $m = [string]$Message
  if ($m -match 'TrustedHosts') {
    return [pscustomobject]@{ status = 'auth_failed'; hint = 'NTLM path blocked: connect by the FQDN that matches your WinRM TrustedHosts entry (a short name will not match a *.domain wildcard), use -Authentication Negotiate, or run from a domain-joined host.' }
  }
  if ($m -match '0x80090311|no authenticating authority') {
    return [pscustomobject]@{ status = 'auth_failed'; hint = 'Kerberos found no domain authority (client not domain-joined / no DC). Use TrustedHosts + -Authentication Negotiate, -UseSSL, or run from a domain-joined host.' }
  }
  if ($m -match 'Access is denied|logon failure|authentication failed|0x8009030c') {
    return [pscustomobject]@{ status = 'auth_failed'; hint = 'Credential rejected - verify it has admin/log-read rights on this host.' }
  }
  if ($m -match 'cannot be resolved|actively refused|timed out|RPC server is unavailable|network path') {
    return [pscustomobject]@{ status = 'unreachable'; hint = 'Network/DNS/WinRM reachability problem - check name resolution, port 5985/5986, and that WinRM is enabled.' }
  }
  if ($m -match 'WinRM|connecting to remote') {
    return [pscustomobject]@{ status = 'unreachable'; hint = 'WinRM connection failed - verify WinRM is enabled and reachable on the target.' }
  }
  return [pscustomobject]@{ status = 'error'; hint = $null }
}

function Get-OverallStatus {
  param([object[]]$Hosts)
  if (-not $Hosts) { return 'error' }
  $ok = @($Hosts | Where-Object { $_.status -eq 'ok' }).Count
  if ($ok -eq $Hosts.Count) { return 'ok' }
  if ($ok -eq 0) { return 'error' }
  return 'partial'
}

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

function Get-AdminCredential {
  param([pscredential]$Provided)
  if ($Provided) { return $Provided }
  $cred = Get-Credential -Message 'Enter the admin credential used to reach the AOS / client hosts'
  if (-not $cred) { throw 'No credential supplied; aborting.' }
  return $cred
}

# Collect raw event/service data from one host. Returns a per-host result (never throws).
function Invoke-HostCollect {
  param(
    [Parameter(Mandatory)][string]$Computer,
    [pscredential]$Credential,
    [int]$Hours,
    [int]$MaxEvents,
    [int]$MaxMessageLength,
    [switch]$UseSSL,
    [string]$Authentication = 'Default'
  )

  $remote = {
    param($hours, $maxEvents, $maxLen)
    # Runs ON the target (Windows PowerShell may be 2.0-4.0). Keep to down-level syntax:
    # use New-Object rather than the PS5 static-new constructor, and no $using. Compute the
    # window HERE so it is in the target's own local time - never pass a DateTime across the
    # boundary (its Kind can flip during serialization and silently shift the window).
    $since = (Get-Date).AddHours(-1 * $hours)
    $out = New-Object System.Collections.Generic.List[object]
    $scanned = 0
    $truncated = $false

    $svc = @()
    try {
      $svc = Get-Service -ErrorAction Stop |
        Where-Object { $_.Name -like 'AOS60*' -or $_.DisplayName -like '*Object Server*' -or $_.DisplayName -like '*AX Object Server*' } |
        ForEach-Object { New-Object psobject -Property @{ Name = $_.Name; DisplayName = $_.DisplayName; Status = "$($_.Status)"; StartType = "$($_.StartType)" } }
    } catch { }

    $boot = $null
    try { $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch { }

    $queries = @(
      @{ Log = 'Application'; Id = 1000 },
      @{ Log = 'System'; Id = 7031 },
      @{ Log = 'Application'; Id = 110 },
      @{ Log = 'Application'; Id = 180 }
    )
    foreach ($q in $queries) {
      $filter = @{ LogName = $q.Log; Id = $q.Id; StartTime = $since }
      try {
        $evts = Get-WinEvent -FilterHashtable $filter -MaxEvents $maxEvents -ErrorAction Stop
      } catch {
        if ($_.Exception.Message -match 'No events were found') { continue }
        # A missing log or other per-query issue should not kill the whole host.
        continue
      }
      $evts = @($evts)
      $scanned += $evts.Count
      if ($evts.Count -ge $maxEvents) { $truncated = $true }
      foreach ($e in $evts) {
        $msg = if ($null -ne $e.Message) { $e.Message } else { '' }
        if ($msg.Length -gt $maxLen) { $msg = $msg.Substring(0, $maxLen) }
        $out.Add((New-Object psobject -Property @{
              Log      = $e.LogName
              Id       = [int]$e.Id
              Provider = $e.ProviderName
              TimeUtc  = $e.TimeCreated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
              Msg      = $msg
            }))
      }
    }
    # WER LocalDumps readiness for Ax32Serv.exe - so the NEXT crash can be captured for a
    # symbolized stack. This is the evidence-based path, replacing event-log guesswork.
    $wer = New-Object psobject -Property @{ key_present = $false; dump_folder = $null; dump_type = $null; custom_dump_flags = $null; dump_count = $null; dump_files = 0 }
    try {
      $werKey = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\Ax32Serv.exe'
      if (Test-Path $werKey) {
        $p = Get-ItemProperty -Path $werKey -ErrorAction Stop
        $wer.key_present = $true
        $wer.dump_folder = "$($p.DumpFolder)"
        $wer.dump_type = "$($p.DumpType)"
        $wer.custom_dump_flags = if ($null -ne $p.CustomDumpFlags) { ('0x{0:X}' -f [int]$p.CustomDumpFlags) } else { $null }
        $wer.dump_count = "$($p.DumpCount)"
        if ($p.DumpFolder -and (Test-Path ([System.Environment]::ExpandEnvironmentVariables("$($p.DumpFolder)")))) {
          $wer.dump_files = @(Get-ChildItem -Path ([System.Environment]::ExpandEnvironmentVariables("$($p.DumpFolder)")) -Filter '*.dmp' -ErrorAction SilentlyContinue).Count
        }
      }
    } catch { }

    # Change-correlation signal: hotfixes installed in the last 14 days (a 0xc0000005 is often a
    # config/deployment/Windows-update regression, not a session collision).
    $hotfix = @()
    try {
      $cut = (Get-Date).AddDays(-14)
      $hotfix = Get-HotFix -ErrorAction Stop |
        Where-Object { $_.InstalledOn -and $_.InstalledOn -gt $cut } |
        ForEach-Object { New-Object psobject -Property @{ id = "$($_.HotFixID)"; installed = $_.InstalledOn.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } }
    } catch { }

    New-Object psobject -Property @{ Services = $svc; LastBootUtc = $boot; Wer = $wer; Hotfixes = @($hotfix); Records = $out.ToArray(); Scanned = $scanned; Truncated = $truncated }
  }

  $invokeArgs = @{
    ComputerName = $Computer
    ScriptBlock  = $remote
    ArgumentList = @($Hours, $MaxEvents, $MaxMessageLength)
    ErrorAction  = 'Stop'
  }
  if ($Credential) { $invokeArgs.Credential = $Credential }
  if ($UseSSL) { $invokeArgs.UseSSL = $true }
  if ($Authentication -and $Authentication -ne 'Default') { $invokeArgs.Authentication = $Authentication }

  try {
    $r = Invoke-Command @invokeArgs
    return [pscustomobject]@{
      computer = $Computer; status = 'ok'; error = $null; hint = $null
      services = @($r.Services); lastboot = $r.LastBootUtc; wer = $r.Wer; hotfixes = @($r.Hotfixes)
      records  = @($r.Records); events_scanned = $r.Scanned; truncated = $r.Truncated
    }
  } catch {
    $cls = Get-FailureClassification -Message $_.Exception.Message
    return [pscustomobject]@{
      computer = $Computer; status = $cls.status; error = $_.Exception.Message; hint = $cls.hint
      services = @(); lastboot = $null; wer = $null; hotfixes = @(); records = @(); events_scanned = 0; truncated = $false
    }
  }
}

# Shape a raw AOS host-collect result into the AOS output object. CRASH CLASSES ARE KEPT
# SEPARATE - they have different causes and must never be conflated:
#   access_violations  (Event 1000 / Ax32Serv 0xc0000005) - unexpected termination; no call
#                       stack in the event -> capture a dump or correlate a change to find cause.
#   forced_terminations(Event 110 / Dynamics Server "Session Allocation Failed: already
#                       allocated") - the AOS kernel self-terminates on a session-ID collision;
#                       proximate cause of THIS exit, downstream of orphaned SysClientSessions
#                       (from a prior AOS<->DB blip / dead cluster node). NOT a benign artifact,
#                       NOT the deep root cause, and NOT the same thing as an access violation.
#   session_symptoms   (Event 180 / "invalid session ID") - BY DESIGN: a client RPC against a
#                       session the AOS already terminated. Does NOT crash the AOS by itself.
function Format-AosHost {
  param([Parameter(Mandatory)]$Raw)
  $recs = @($Raw.records)
  $av = foreach ($r in ($recs | Where-Object { $_.Id -eq 1000 -and (Test-IsAosCrash $_.Msg) })) {
    $f = Get-FaultFields $r.Msg
    [pscustomobject]@{ t = $r.TimeUtc; crash_class = 'access_violation'; app = $f.app; module = $f.module; exception = $f.exception; exception_meaning = $f.exception_meaning; offset = $f.offset }
  }
  $forced = foreach ($r in ($recs | Where-Object { $_.Id -eq 110 -and $_.Provider -like 'Dynamics Server*' })) {
    [pscustomobject]@{ t = $r.TimeUtc; crash_class = 'forced_termination'; message = ($r.Msg -split "`r?`n")[0]; note = 'AOS kernel self-terminated on a session-id collision; investigate orphaned SysClientSessions / a prior AOS<->DB interruption upstream - this is the proximate cause of this exit, not the deep root cause.' }
  }
  $scm = foreach ($r in ($recs | Where-Object { $_.Id -eq 7031 -and $_.Msg -match 'Object Server' })) {
    [pscustomobject]@{ t = $r.TimeUtc }
  }
  $sym = @($recs | Where-Object { $_.Id -eq 180 -and $_.Provider -like 'Dynamics Server*' })
  $symSummary = if ($sym.Count) {
    $sorted = $sym | Sort-Object t
    [pscustomobject]@{
      count = $sym.Count; first = $sorted[0].TimeUtc; last = $sorted[-1].TimeUtc
      sample = ($sorted[0].Msg -split "`r?`n")[0]
      note = 'BY-DESIGN symptom (client RPC against an already-terminated session). Does NOT crash the AOS - correlation with a crash is not causation.'
    }
  } else { $null }
  [pscustomobject]@{
    computer = $Raw.computer; role = 'aos'; status = $Raw.status; error = $Raw.error; hint = $Raw.hint
    aos_services = @($Raw.services); lastboot = $Raw.lastboot
    access_violations = @($av); forced_terminations = @($forced); scm_terminations = @($scm)
    session_symptoms = $symSummary
    dump_readiness = (Get-DumpReadiness $Raw.wer); wer_config = $Raw.wer; recent_hotfixes = @($Raw.hotfixes)
    events_scanned = $Raw.events_scanned; truncated = $Raw.truncated
  }
}

# Shape a raw client host-collect result into the client output object.
function Format-ClientHost {
  param([Parameter(Mandatory)]$Raw)
  $crashes = foreach ($r in (@($Raw.records) | Where-Object { $_.Id -eq 1000 -and (Test-IsClientCrash $_.Msg) })) {
    $f = Get-FaultFields $r.Msg
    [pscustomobject]@{ t = $r.TimeUtc; module = $f.module; exception = $f.exception }
  }
  [pscustomobject]@{
    computer = $Raw.computer; role = 'client'; status = $Raw.status; error = $Raw.error; hint = $Raw.hint
    client_crashes = @($crashes); client_crash_count = @($crashes).Count
    events_scanned = $Raw.events_scanned; truncated = $Raw.truncated
  }
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

function Invoke-AosCrashTriage {
  [CmdletBinding()]
  param(
    [string[]]$AosComputerName, [string[]]$ClientComputerName,
    [string]$AosListFile, [string]$ClientListFile,
    [int]$Hours = 24, [int]$CascadeWindowSeconds = 120,
    [int]$MaxEvents = 2000, [int]$MaxMessageLength = 600, [int]$ThrottleLimit = 8,
    [switch]$UseSSL, [string]$Authentication = 'Default', [pscredential]$Credential
  )

  $aosTargets = @(Resolve-Hosts -Name $AosComputerName -ListFile $AosListFile)
  $clientTargets = @(Resolve-Hosts -Name $ClientComputerName -ListFile $ClientListFile)
  if ($aosTargets.Count -eq 0) { throw 'No AOS targets. Pass -AosComputerName and/or -AosListFile.' }

  $cred = Get-AdminCredential -Provided $Credential

  $funcDef = ${function:Invoke-HostCollect}.ToString()
  $clsDef = ${function:Get-FailureClassification}.ToString()

  $collect = {
    param($targets)
    $targets | ForEach-Object -ThrottleLimit $using:ThrottleLimit -Parallel {
      ${function:Get-FailureClassification} = $using:clsDef
      ${function:Invoke-HostCollect} = $using:funcDef
      Invoke-HostCollect -Computer $_ -Credential $using:cred -Hours $using:Hours `
        -MaxEvents $using:MaxEvents -MaxMessageLength $using:MaxMessageLength `
        -UseSSL:$using:UseSSL -Authentication $using:Authentication
    }
  }

  $aosRaw = @(& $collect $aosTargets)
  $clientRaw = if ($clientTargets.Count) { @(& $collect $clientTargets) } else { @() }

  $aosHosts = @($aosRaw | ForEach-Object { Format-AosHost -Raw $_ })
  $clientHosts = @($clientRaw | ForEach-Object { Format-ClientHost -Raw $_ })

  $timeline = @(Build-CrashTimeline -AosHosts $aosHosts)
  $allClientCrashes = @($clientHosts | ForEach-Object { $c = $_; @($c.client_crashes) | ForEach-Object { [pscustomobject]@{ computer = $c.computer; t = $_.t } } })
  $cascade = @(Get-CascadeCorrelation -Timeline $timeline -ClientCrashes $allClientCrashes -WindowSeconds $CascadeWindowSeconds)

  $allHosts = @($aosHosts + $clientHosts)
  $failures = @($allHosts | Where-Object { $_.status -ne 'ok' } | Select-Object computer, role, status, error, hint)
  $avTotal = @($aosHosts | ForEach-Object { @($_.access_violations).Count } | Measure-Object -Sum).Sum
  $forcedTotal = @($aosHosts | ForEach-Object { @($_.forced_terminations).Count } | Measure-Object -Sum).Sum
  $symTotal = @($aosHosts | ForEach-Object { if ($_.session_symptoms) { $_.session_symptoms.count } else { 0 } } | Measure-Object -Sum).Sum
  $clientCrashTotal = @($clientHosts | ForEach-Object { $_.client_crash_count } | Measure-Object -Sum).Sum
  $dumpReady = @($aosHosts | Where-Object { $_.dump_readiness -and $_.dump_readiness.ready })
  $dumpMissing = @($aosHosts | Where-Object { $_.status -eq 'ok' -and -not ($_.dump_readiness -and $_.dump_readiness.ready) } | Select-Object -ExpandProperty computer)

  $caveats = @(
    'CORRELATION IS NOT CAUSATION. Event timing alone cannot identify the faulting code path or prove which event triggered a crash.',
    'access_violation (Event 1000 / 0xc0000005) and forced_termination (Event 110 / session-id collision) are DIFFERENT crash classes with different causes - do not merge them.',
    'session_symptoms (Event 180 / invalid session ID) are BY DESIGN and do not crash the AOS; never report them as a root cause.',
    'For a forced_termination: investigate orphaned SysClientSessions / a prior AOS<->DB interruption (the upstream cause), not the collision message itself.',
    'For an access_violation with no correlatable preceding event or recent change: capture a crash dump (WER LocalDumps DumpType=0 / CustomDumpFlags=0x1B67, or DebugDiag) and analyse the symbolized stack before claiming a root cause.'
  )

  [pscustomobject]@{
    status       = Get-OverallStatus -Hosts $allHosts
    generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    query        = [pscustomobject]@{
      aos_hosts = $aosTargets.Count; client_hosts = $clientTargets.Count
      window_hours = $Hours; cascade_window_seconds = $CascadeWindowSeconds; max_events_per_query = $MaxEvents
    }
    aos          = $aosHosts
    clients      = $clientHosts
    summary      = [pscustomobject]@{
      aos_hosts_total          = $aosHosts.Count
      hosts_failed             = $failures.Count
      access_violation_total   = [int]$avTotal
      forced_termination_total = [int]$forcedTotal
      session_symptom_total    = [int]$symTotal
      client_crash_total       = [int]$clientCrashTotal
      crash_timeline           = $timeline
      cascade_correlation      = $cascade
      dump_capture_ready_hosts = $dumpReady.Count
      dump_capture_missing     = @($dumpMissing)
      recent_hotfix_hosts      = @($aosHosts | Where-Object { @($_.recent_hotfixes).Count -gt 0 } | Select-Object -ExpandProperty computer)
      caveats                  = $caveats
      failures                 = $failures
    }
  }
}

function Write-TriageOutput {
  param([Parameter(Mandatory)]$Result, [string]$OutFile)
  if ($OutFile) {
    $Result | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $OutFile -Encoding UTF8
    (ConvertTo-CompactResult -Full $Result) | ConvertTo-Json -Depth 9
  } else {
    $Result | ConvertTo-Json -Depth 9
  }
}

# ---------------------------------------------------------------------------
# Entrypoint (skipped when dot-sourced by Pester).
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
  $triageArgs = @{}
  foreach ($kv in $PSBoundParameters.GetEnumerator()) {
    if ($kv.Key -ne 'OutFile') { $triageArgs[$kv.Key] = $kv.Value }
  }
  $result = Invoke-AosCrashTriage @triageArgs
  Write-TriageOutput -Result $result -OutFile $OutFile
}
