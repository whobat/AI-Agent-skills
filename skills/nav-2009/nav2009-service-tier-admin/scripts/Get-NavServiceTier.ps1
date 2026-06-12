#Requires -Version 7.0
<#
.SYNOPSIS
    Inventories Microsoft Dynamics NAV 2009 Service Tier (NST) instances and NAS/Job Queue
    configuration on a Windows server, emitting JSON. Optionally restarts a named instance.

.DESCRIPTION
    Enumerates all Windows services whose name matches 'MicrosoftDynamicsNavServer*' via
    Get-CimInstance Win32_Service (supports -ComputerName for remote targets). For each
    service the script derives the instance name, reads status/start mode/service account,
    locates CustomSettings.config next to the executable (or in the default Service folder),
    parses the XML <appSettings> block, and surfaces the curated keys: database target, ports,
    credential type, SOAP enabled flag, certificate thumbprint, and NAS startup codeunit/
    method/argument.

    Each instance is wrapped independently: a bad config file surfaces an 'error' field on
    that instance without aborting the rest of the inventory.

    The -Restart switch stops then starts the matched service and records before/after state.
    It requires -Instance (to prevent accidental multi-service restarts) and should only be
    used after explicit user confirmation — it disconnects all active RTC clients.

.NOTES
    Permissions:
      Local: local admin to query Win32_Service and read CustomSettings.config.
      Remote (-ComputerName): CIM/WinRM enabled on target + admin rights there.
      Restart: local admin (or service-control rights) on the hosting machine.

    NAV 2009 service name patterns:
      Multi-instance (R2): MicrosoftDynamicsNavServer$<InstanceName>
      Single-instance (SP1): MicrosoftDynamicsNavServer
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Target computer. Defaults to the local machine.
    [string]$ComputerName = $env:COMPUTERNAME,

    # Filter to one instance name (the part after '$' in the service name).
    # Required when -Restart is used.
    [string]$Instance,

    # Include every CustomSettings.config key in 'settings', not just the curated set.
    [switch]$IncludeFullConfig,

    # Restart the matched instance. Requires -Instance.
    [switch]$Restart,

    # Seconds to wait for the service to reach Running after start.
    [int]$RestartTimeoutSec = 60,

    # Write full JSON here; stdout becomes a compact summary instead.
    [string]$OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Guard: -Restart requires -Instance
# ---------------------------------------------------------------------------
if ($Restart -and -not $Instance) {
    Write-Error '-Restart requires -Instance to be specified. Aborting to prevent accidental restart of all NAV service tiers.'
    exit 1
}

# ---------------------------------------------------------------------------
# Curated settings keys to always surface
# ---------------------------------------------------------------------------
$CuratedKeys = @(
    'DatabaseServer',
    'DatabaseInstance',
    'DatabaseName',
    'ServerInstance',
    'ClientServicesPort',
    'SOAPServicesPort',
    'ManagementServicesPort',
    'ClientServicesCredentialType',
    'SOAPServicesEnabled',
    'ServicesCertificateThumbprint',
    'NASServicesStartupCodeunit',
    'NASServicesStartupMethod',
    'NASServicesStartupArgument'
)

# ---------------------------------------------------------------------------
# Helper: parse CustomSettings.config, return hashtable of key→value
# ---------------------------------------------------------------------------
function Read-NavConfig {
    param([string]$ConfigPath)

    if (-not (Test-Path $ConfigPath)) {
        throw "CustomSettings.config not found at: $ConfigPath"
    }

    try {
        [xml]$xml = Get-Content $ConfigPath -Raw -Encoding UTF8
    } catch {
        throw "Failed to parse CustomSettings.config at '$ConfigPath': $_"
    }

    $table = @{}
    foreach ($add in $xml.configuration.appSettings.add) {
        if ($null -ne $add.key) {
            $table[$add.key] = $add.value
        }
    }
    return $table
}

# ---------------------------------------------------------------------------
# Helper: derive config path from exe path, falling back to default location
# ---------------------------------------------------------------------------
function Resolve-NavConfigPath {
    param(
        [string]$ExePath,
        [string]$InstanceName
    )

    # Strip surrounding quotes that Win32_Service may include
    $exeDir = Split-Path ($ExePath.Trim('"')) -Parent

    # R2 multi-instance layout: <ServiceDir>\Instances\<name>\CustomSettings.config
    $r2Path = Join-Path $exeDir "Instances\$InstanceName\CustomSettings.config"
    if (Test-Path $r2Path) { return $r2Path }

    # Single-instance layout: config sits next to the exe
    $sp1Path = Join-Path $exeDir 'CustomSettings.config'
    if (Test-Path $sp1Path) { return $sp1Path }

    # Default fallback
    return Join-Path 'C:\Program Files\Microsoft Dynamics NAV\60\Service' 'CustomSettings.config'
}

# ---------------------------------------------------------------------------
# Helper: build ports sub-object from parsed config hashtable
# ---------------------------------------------------------------------------
function Build-PortsObject {
    param([hashtable]$Config)

    $client     = if ($Config.ContainsKey('ClientServicesPort'))    { [int]$Config['ClientServicesPort'] }    else { 7046 }
    $soap       = if ($Config.ContainsKey('SOAPServicesPort'))      { [int]$Config['SOAPServicesPort'] }      else { 7047 }
    $management = if ($Config.ContainsKey('ManagementServicesPort')) { [int]$Config['ManagementServicesPort'] } else { 7045 }

    return [ordered]@{
        client     = $client
        soap       = $soap
        management = $management
    }
}

# ---------------------------------------------------------------------------
# Helper: build NAS sub-object from parsed config hashtable
# ---------------------------------------------------------------------------
function Build-NasObject {
    param([hashtable]$Config)

    $codeunit = if ($Config.ContainsKey('NASServicesStartupCodeunit')) { $Config['NASServicesStartupCodeunit'] } else { '' }
    $method   = if ($Config.ContainsKey('NASServicesStartupMethod'))   { $Config['NASServicesStartupMethod'] }   else { '' }
    $argument = if ($Config.ContainsKey('NASServicesStartupArgument')) { $Config['NASServicesStartupArgument'] } else { '' }

    return [ordered]@{
        codeunit = $codeunit
        method   = $method
        argument = $argument
        enabled  = ($codeunit -ne '')
    }
}

# ---------------------------------------------------------------------------
# Enumerate services
# ---------------------------------------------------------------------------
$cimParams = @{
    ClassName = 'Win32_Service'
    Filter    = "Name LIKE 'MicrosoftDynamicsNavServer%'"
}
if ($ComputerName -ne $env:COMPUTERNAME) {
    $cimParams['ComputerName'] = $ComputerName
}

try {
    $services = Get-CimInstance @cimParams
} catch {
    $result = [ordered]@{
        status       = 'error'
        generated_at = [datetime]::UtcNow.ToString('o')
        computer     = $ComputerName
        error        = "Failed to enumerate NAV services on '$ComputerName': $_"
        instances    = @()
    }
    Write-Output ($result | ConvertTo-Json -Depth 8)
    exit 1
}

# Apply -Instance filter if specified
if ($Instance) {
    $services = $services | Where-Object {
        $_.Name -eq "MicrosoftDynamicsNavServer`$$Instance" -or
        $_.Name -eq 'MicrosoftDynamicsNavServer'
    }
}

# ---------------------------------------------------------------------------
# Build instance list
# ---------------------------------------------------------------------------
$instances = [System.Collections.Generic.List[object]]::new()
$anyError  = $false

foreach ($svc in $services) {
    # Derive instance name from service name
    $instName = if ($svc.Name -match '\$(.+)$') { $Matches[1] } else { 'default' }

    $entry = [ordered]@{
        serviceName  = $svc.Name
        instanceName = $instName
        status       = $svc.State
        startMode    = $svc.StartMode
        account      = $svc.StartName
        exePath      = $svc.PathName
        configPath   = $null
        settings     = $null
        nas          = $null
        ports        = $null
        error        = $null
    }

    try {
        $configPath         = Resolve-NavConfigPath -ExePath $svc.PathName -InstanceName $instName
        $entry['configPath'] = $configPath
        $allConfig          = Read-NavConfig -ConfigPath $configPath

        # Build curated settings object
        $settingsObj = [ordered]@{}
        if ($IncludeFullConfig) {
            foreach ($k in ($allConfig.Keys | Sort-Object)) {
                $settingsObj[$k] = $allConfig[$k]
            }
        } else {
            foreach ($k in $CuratedKeys) {
                $settingsObj[$k] = if ($allConfig.ContainsKey($k)) { $allConfig[$k] } else { '' }
            }
        }

        $entry['settings'] = $settingsObj
        $entry['nas']      = Build-NasObject  -Config $allConfig
        $entry['ports']    = Build-PortsObject -Config $allConfig
    } catch {
        $entry['error'] = $_.ToString()
        $anyError = $true
    }

    $instances.Add($entry)
}

# ---------------------------------------------------------------------------
# Restart logic
# ---------------------------------------------------------------------------
$restartBlock = $null

if ($Restart) {
    $targetSvc = $services | Select-Object -First 1
    if (-not $targetSvc) {
        Write-Error "No NAV service found for instance '$Instance' on '$ComputerName'."
        exit 1
    }

    $beforeState  = $targetSvc.State
    $restartStart = [datetime]::UtcNow.ToString('o')

    try {
        if ($PSCmdlet.ShouldProcess("$($targetSvc.Name) on $ComputerName", 'Stop-Service')) {
            Stop-Service -Name $targetSvc.Name -Force -ErrorAction Stop
        }
        if ($PSCmdlet.ShouldProcess("$($targetSvc.Name) on $ComputerName", 'Start-Service')) {
            Start-Service -Name $targetSvc.Name -ErrorAction Stop
        }

        # Wait for Running up to RestartTimeoutSec
        $deadline = [datetime]::UtcNow.AddSeconds($RestartTimeoutSec)
        $afterState = 'Unknown'
        while ([datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 1000
            $svcRefresh = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($targetSvc.Name)'"
            $afterState = $svcRefresh.State
            if ($afterState -eq 'Running') { break }
        }

        $restartBlock = [ordered]@{
            requested = $restartStart
            instance  = $Instance
            before    = $beforeState
            after     = $afterState
            ok        = ($afterState -eq 'Running')
        }

        # Refresh the instance entry status
        $refreshed = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($targetSvc.Name)'"
        $entry = $instances | Where-Object { $_.serviceName -eq $targetSvc.Name } | Select-Object -First 1
        if ($entry) { $entry['status'] = $refreshed.State }

    } catch {
        $restartBlock = [ordered]@{
            requested = $restartStart
            instance  = $Instance
            before    = $beforeState
            after     = 'Unknown'
            ok        = $false
            error     = $_.ToString()
        }
        $anyError = $true
    }
}

# ---------------------------------------------------------------------------
# Assemble result
# ---------------------------------------------------------------------------
$overallStatus = if ($instances.Count -eq 0) {
    'error'
} elseif ($anyError) {
    'partial'
} else {
    'ok'
}

$result = [ordered]@{
    status       = $overallStatus
    generated_at = [datetime]::UtcNow.ToString('o')
    computer     = $ComputerName
    instances    = $instances.ToArray()
}

if ($restartBlock) {
    $result['restart'] = $restartBlock
}

$fullJson = $result | ConvertTo-Json -Depth 8

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if ($OutFile) {
    Set-Content -Path $OutFile -Value $fullJson -Encoding UTF8
    $summary = [ordered]@{
        status    = $overallStatus
        out_file  = $OutFile
        instances = @($instances | ForEach-Object {
            [ordered]@{ instanceName = $_['instanceName']; status = $_['status'] }
        })
    }
    Write-Output ($summary | ConvertTo-Json -Depth 4)
} else {
    Write-Output $fullJson
}
