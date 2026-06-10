#Requires -Version 7.0
<#
.SYNOPSIS
    Health sweep across a fleet of Windows POS machines (or any Windows fleet) over
    PowerShell Remoting. Emits JSON; the agent reading it writes the narrative.

.DESCRIPTION
    For each host, collects in parallel:
      - OS basics: last boot time, fixed-disk free space
      - Services matching the given name patterns (default: POS/Retail/SQL services):
        status and start type, flagging auto-start services that are not running
      - Local SQL Server instances: edition/version and per-database data-file size,
        flagging databases approaching the SQL Server Express 10 GB data-file limit
      - Recent Critical/Error event counts (System + Application) in the look-back window

    The script is READ-ONLY on the targets: it queries services, disks, SQL catalog
    views, and event logs. It never starts/stops services or changes anything.

    Deterministic warnings are derived per host (service_stopped, disk_low,
    express_db_near_limit, sql_query_failed, high_error_count, unreachable) and ranked
    in summary.warnings so the agent can lead with what matters.

.NOTES
    Requires PowerShell 7+ on the operator machine and WinRM on the targets. A credential
    is always prompted (held in memory for the run; never written to disk). SQL queries
    run inside the remote session against localhost, so the remoting credential's Windows
    login is used — no SQL credentials needed.
#>
[CmdletBinding()]
param(
    # One or more hosts. Combine with -ServerListFile.
    [string[]]$ComputerName = @(),

    # Text file with one host per line; '#' comments and blank lines ignored.
    [string]$ServerListFile,

    # Service name patterns to inspect (wildcards). Defaults cover Retail POS + SQL.
    [string[]]$ServicePattern = @('*POS*', '*Retail*', 'MSSQL*', 'SQLAgent*'),

    # Look-back window for Critical/Error event counts.
    [int]$EventHours = 24,

    # Warn when a fixed disk has less free space than this percentage.
    [int]$DiskMinFreePct = 10,

    # SQL Server Express data-file limit (GB). Databases above WarnAtPct of it are flagged.
    [double]$ExpressLimitGB = 10,
    [int]$ExpressWarnAtPct = 80,

    # Warn when a host has more than this many Critical/Error events in the window.
    [int]$ErrorCountWarn = 50,

    # Max hosts queried in parallel.
    [int]$ThrottleLimit = 12,

    # WinRM transport/auth.
    [switch]$UseSSL,
    [ValidateSet('Default', 'Negotiate', 'Kerberos', 'Basic', 'CredSSP')]
    [string]$Authentication = 'Default',

    # Testing/automation seam only — omit in normal use and you are prompted.
    [pscredential]$Credential,

    # Write full JSON here; stdout becomes a compact summary instead.
    [string]$OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve host list
# ---------------------------------------------------------------------------
$hosts = [System.Collections.Generic.List[string]]::new()
foreach ($c in $ComputerName) { if ($c.Trim()) { $hosts.Add($c.Trim()) } }
if ($ServerListFile) {
    if (-not (Test-Path $ServerListFile)) {
        [Console]::Error.WriteLine("Server list file not found: $ServerListFile")
        exit 1
    }
    foreach ($line in Get-Content $ServerListFile) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith('#')) { $hosts.Add($t) }
    }
}
$hosts = @($hosts | Select-Object -Unique)
if ($hosts.Count -eq 0) {
    [Console]::Error.WriteLine('No hosts. Pass -ComputerName and/or -ServerListFile.')
    exit 1
}

if (-not $Credential) {
    $Credential = Get-Credential -Message 'Credential with admin rights on the target machines'
}

# ---------------------------------------------------------------------------
# Per-host collection (runs on the target)
# ---------------------------------------------------------------------------
$remoteScript = {
    param($ServicePattern, $EventHours, $ExpressLimitGB)
    $r = [ordered]@{}

    $os = Get-CimInstance Win32_OperatingSystem
    $r.boot_time = $os.LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $r.os = $os.Caption

    $r.disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        [ordered]@{
            drive    = $_.DeviceID
            size_gb  = [math]::Round($_.Size / 1GB, 1)
            free_gb  = [math]::Round($_.FreeSpace / 1GB, 1)
            free_pct = if ($_.Size -gt 0) { [math]::Round(100.0 * $_.FreeSpace / $_.Size, 1) } else { 0 }
        }
    })

    $svc = foreach ($pattern in $ServicePattern) { Get-Service -Name $pattern -ErrorAction SilentlyContinue }
    $r.services = @($svc | Sort-Object Name -Unique | ForEach-Object {
        [ordered]@{
            name       = $_.Name
            display    = $_.DisplayName
            status     = [string]$_.Status
            start_type = [string]$_.StartType
        }
    })

    # SQL instances: every MSSQL* service maps to an instance; query the running ones locally.
    $r.sql_instances = @()
    $sqlServices = @($svc | Where-Object { $_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*' } | Sort-Object Name -Unique)
    foreach ($s in $sqlServices) {
        $inst = [ordered]@{
            service = $s.Name
            status  = [string]$s.Status
            edition = $null
            version = $null
            databases = @()
            error   = $null
        }
        if ($s.Status -eq 'Running') {
            $dataSource = if ($s.Name -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$($s.Name.Split('$')[1])" }
            try {
                $conn = [System.Data.SqlClient.SqlConnection]::new(
                    "Data Source=$dataSource;Initial Catalog=master;Integrated Security=True;Connect Timeout=10")
                $conn.Open()
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = @"
SELECT CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128))        AS edition,
       CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)) AS version
"@
                $reader = $cmd.ExecuteReader()
                if ($reader.Read()) { $inst.edition = $reader['edition']; $inst.version = $reader['version'] }
                $reader.Close()
                $cmd.CommandText = @"
SELECT DB_NAME(database_id) AS name,
       CAST(SUM(CASE WHEN type = 0 THEN size END) * 8 / 1024.0 / 1024.0 AS DECIMAL(10,2)) AS data_gb,
       CAST(SUM(CASE WHEN type = 1 THEN size END) * 8 / 1024.0 / 1024.0 AS DECIMAL(10,2)) AS log_gb
FROM sys.master_files
GROUP BY database_id
ORDER BY 2 DESC
"@
                $reader = $cmd.ExecuteReader()
                $dbs = while ($reader.Read()) {
                    [ordered]@{
                        name    = $reader['name']
                        data_gb = [double]$reader['data_gb']
                        log_gb  = if ($reader['log_gb'] -is [System.DBNull]) { 0 } else { [double]$reader['log_gb'] }
                    }
                }
                $reader.Close()
                $conn.Dispose()
                $inst.databases = @($dbs)
            } catch {
                $inst.error = $_.Exception.Message
            }
        }
        $r.sql_instances += , $inst
    }

    # Recent Critical/Error counts (capped — this is a health signal, not a triage)
    $since = (Get-Date).AddHours(-1 * $EventHours)
    $r.recent_errors = [ordered]@{ window_hours = $EventHours; count = 0; top_providers = @() }
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System', 'Application'; Level = 1, 2; StartTime = $since } `
            -MaxEvents 500 -ErrorAction Stop)
        $r.recent_errors.count = $events.Count
        $r.recent_errors.top_providers = @($events | Group-Object ProviderName | Sort-Object Count -Descending |
            Select-Object -First 3 | ForEach-Object { [ordered]@{ provider = $_.Name; count = $_.Count } })
    } catch [Exception] {
        if ($_.Exception.Message -notmatch 'No events were found') { $r.recent_errors.error = $_.Exception.Message }
    }
    $r
}

# ---------------------------------------------------------------------------
# Fan out
# ---------------------------------------------------------------------------
$invokeParams = @{
    Credential     = $Credential
    Authentication = $Authentication
    ErrorAction    = 'Stop'
}
if ($UseSSL) { $invokeParams.UseSSL = $true }

# ForEach-Object -Parallel cannot receive a scriptblock via $using: — pass it as text.
$remoteScriptText = $remoteScript.ToString()

$results = $hosts | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $target = $_
    $params = $using:invokeParams
    try {
        $data = Invoke-Command -ComputerName $target @params `
            -ScriptBlock ([scriptblock]::Create($using:remoteScriptText)) `
            -ArgumentList $using:ServicePattern, $using:EventHours, $using:ExpressLimitGB
        [pscustomobject]@{ Computer = $target; Status = 'ok'; Data = $data; Error = $null }
    } catch {
        $status = if ($_.Exception.Message -match 'Access is denied|Logon failure|password') { 'auth_failed' } else { 'unreachable' }
        [pscustomobject]@{ Computer = $target; Status = $status; Data = $null; Error = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------------
# Derive warnings + assemble output
# ---------------------------------------------------------------------------
$warnings = [System.Collections.Generic.List[object]]::new()
$hostsOut = foreach ($res in ($results | Sort-Object Computer)) {
    $entry = [ordered]@{ computer = $res.Computer; status = $res.Status; error = $res.Error }
    if ($res.Status -ne 'ok') {
        $warnings.Add([ordered]@{ computer = $res.Computer; type = $res.Status; detail = $res.Error })
        $entry
        continue
    }
    $d = $res.Data
    $entry.boot_time = $d.boot_time
    $entry.os = $d.os
    $entry.disks = $d.disks
    $entry.services = $d.services
    $entry.sql_instances = $d.sql_instances
    $entry.recent_errors = $d.recent_errors

    foreach ($disk in $d.disks) {
        if ($disk.free_pct -lt $DiskMinFreePct) {
            $warnings.Add([ordered]@{ computer = $res.Computer; type = 'disk_low'
                detail = "$($disk.drive) $($disk.free_gb) GB free ($($disk.free_pct)%)" })
        }
    }
    foreach ($svc in $d.services) {
        if ($svc.start_type -eq 'Automatic' -and $svc.status -ne 'Running') {
            $warnings.Add([ordered]@{ computer = $res.Computer; type = 'service_stopped'
                detail = "$($svc.name) ($($svc.display)) is $($svc.status) but set to Automatic" })
        }
    }
    foreach ($inst in $d.sql_instances) {
        if ($inst.error) {
            $warnings.Add([ordered]@{ computer = $res.Computer; type = 'sql_query_failed'
                detail = "$($inst.service): $($inst.error)" })
        } elseif ($inst.edition -like '*Express*') {
            foreach ($db in $inst.databases) {
                if ($db.data_gb -ge $ExpressLimitGB * $ExpressWarnAtPct / 100.0) {
                    $warnings.Add([ordered]@{ computer = $res.Computer; type = 'express_db_near_limit'
                        detail = "$($inst.service)/$($db.name): $($db.data_gb) GB data of $ExpressLimitGB GB Express limit" })
                }
            }
        }
    }
    if ($d.recent_errors.count -ge $ErrorCountWarn) {
        $top = ($d.recent_errors.top_providers | ForEach-Object { "$($_.provider) ($($_.count))" }) -join ', '
        $warnings.Add([ordered]@{ computer = $res.Computer; type = 'high_error_count'
            detail = "$($d.recent_errors.count)+ Critical/Error events in $EventHours h - top: $top" })
    }
    $entry
}

$okCount = @($results | Where-Object Status -eq 'ok').Count
$output = [ordered]@{
    status       = if ($okCount -eq $hosts.Count) { 'ok' } elseif ($okCount -gt 0) { 'partial' } else { 'error' }
    generated_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    query        = [ordered]@{
        hosts_total      = $hosts.Count
        service_patterns = $ServicePattern
        event_hours      = $EventHours
        disk_min_free_pct = $DiskMinFreePct
        express_limit_gb = $ExpressLimitGB
    }
    summary      = [ordered]@{
        hosts_ok       = $okCount
        hosts_failed   = $hosts.Count - $okCount
        warning_count  = $warnings.Count
        warnings       = @($warnings | Sort-Object { switch ($_.type) {
            'unreachable' { 0 } 'auth_failed' { 0 } 'service_stopped' { 1 }
            'express_db_near_limit' { 2 } 'disk_low' { 3 } 'sql_query_failed' { 4 } default { 5 } } })
    }
    hosts        = @($hostsOut)
}

$json = $output | ConvertTo-Json -Depth 10
if ($OutFile) {
    $json | Set-Content -Path $OutFile -Encoding utf8
    [ordered]@{
        status        = $output.status
        out_file      = $OutFile
        hosts_ok      = $okCount
        hosts_failed  = $hosts.Count - $okCount
        warning_count = $warnings.Count
        warnings      = $output.summary.warnings
    } | ConvertTo-Json -Depth 6
} else {
    $json
}
