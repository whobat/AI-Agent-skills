#Requires -Version 7.0
<#
.SYNOPSIS
    Import, export, or compile NAV 2009 C/AL objects via finsql.exe, emitting JSON.
    The agent reading the JSON writes the narrative.

.DESCRIPTION
    Wraps the Microsoft Dynamics NAV 2009 Classic development environment CLI (finsql.exe)
    to drive exportobjects, importobjects, and compileobjects commands. Builds the finsql
    argument string, optionally launches the process, reads navcommandresult.txt and
    naverrorlog.txt, and returns a structured JSON result.

    Without -Execute the script performs a DRY RUN: it resolves the finsql path and builds
    the full argument string but does NOT launch finsql.exe. Always review the dry-run
    output before passing -Execute for Import or Compile operations.

.NOTES
    Requires finsql.exe from the NAV 2009 Classic client / development environment.
    Developer license required for Export/Import .txt and Compile.
    End-user license sufficient for Import .fob.
    finsql.exe exit code is unreliable — status is derived from navcommandresult.txt /
    naverrorlog.txt, not the process exit code.
#>
[CmdletBinding()]
param(
    # Operation to perform: Export objects to file, Import objects from file, or Compile objects.
    [Parameter(Mandatory = $true)]
    [ValidateSet('Export', 'Import', 'Compile')]
    [string]$Command,

    # SQL Server instance name, e.g. 'SQLSRV01' or 'SQLSRV01\NAV'.
    [Parameter(Mandatory = $true)]
    [string]$ServerName,

    # The NAV 2009 database name.
    [Parameter(Mandatory = $true)]
    [string]$Database,

    # Object file path (.txt or .fob). Required for Export and Import.
    [string]$Path,

    # NAV object filter, e.g. 'Type=Codeunit;ID=50000..50099'. Used by Export and Compile.
    [string]$Filter,

    # Override the auto-detected finsql.exe path.
    [string]$FinSqlPath,

    # SQL authentication credential. Omit to use Windows integrated auth.
    [pscredential]$SqlCredential,

    # Maps to synchronizeschemachanges (Compile/Import). 'Default' omits the parameter.
    [ValidateSet('Default', 'Yes', 'No', 'Force')]
    [string]$SyncSchema = 'Default',

    # finsql importaction for Import. 'Default' omits the parameter.
    [ValidateSet('Default', 'Overwrite', 'Skip')]
    [string]$ImportAction = 'Default',

    # Actually run finsql.exe. Without this switch the script returns the resolved command
    # without executing — safe to run first to review.
    [switch]$Execute,

    # Directory for finsql log files (navcommandresult.txt / naverrorlog.txt).
    [string]$LogPath = $env:TEMP,

    # Write full JSON to this file; stdout becomes a compact summary instead.
    [string]$OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Redact-Arguments {
    # NB: parameter must not be named $Args — the automatic variable shadows it (empty result).
    param([string]$ArgumentString)
    # Replace password=<value> with password=*** so credentials never appear in output.
    $ArgumentString -replace '(?i)password=[^,]+', 'password=***'
}

# ---------------------------------------------------------------------------
# Resolve finsql.exe
# ---------------------------------------------------------------------------
$defaultPaths = @(
    'C:\Program Files (x86)\Microsoft Dynamics NAV\60\Classic\finsql.exe',
    'C:\Program Files\Microsoft Dynamics NAV\60\Classic\finsql.exe'
)

$resolvedFinsql = $null
if ($FinSqlPath) {
    if (Test-Path $FinSqlPath) {
        $resolvedFinsql = $FinSqlPath
    }
} else {
    foreach ($candidate in $defaultPaths) {
        if (Test-Path $candidate) {
            $resolvedFinsql = $candidate
            break
        }
    }
}

# ---------------------------------------------------------------------------
# Map Command -> finsql command name
# ---------------------------------------------------------------------------
$finsqlCommand = switch ($Command) {
    'Export'  { 'exportobjects' }
    'Import'  { 'importobjects' }
    'Compile' { 'compileobjects' }
}

# ---------------------------------------------------------------------------
# Validate required parameters per command
# ---------------------------------------------------------------------------
if ($Command -in @('Export', 'Import') -and -not $Path) {
    $output = [ordered]@{
        status       = 'error'
        generated_at = [datetime]::UtcNow.ToString('o')
        command      = $Command
        executed     = $false
        finsql       = $resolvedFinsql
        arguments    = $null
        result       = $null
        error        = "-Path is required for $Command operations."
    }
    if ($OutFile) {
        $output | ConvertTo-Json -Depth 10 | Set-Content -Path $OutFile -Encoding UTF8
        [pscustomobject]@{ status = 'error'; out_file = $OutFile; command = $Command; executed = $false } |
            ConvertTo-Json -Compress
    } else {
        $output | ConvertTo-Json -Depth 10
    }
    exit 1
}

# ---------------------------------------------------------------------------
# Build finsql argument string
# ---------------------------------------------------------------------------
$logFile = Join-Path $LogPath 'navcommandresult.txt'

$argParts = [System.Collections.Generic.List[string]]::new()
$argParts.Add("command=$finsqlCommand")
$argParts.Add("servername=$ServerName")
$argParts.Add("database=$Database")

if ($Path) {
    $argParts.Add("file=$Path")
}
if ($Filter) {
    $argParts.Add("filter=$Filter")
}
if ($Command -eq 'Import' -and $ImportAction -ne 'Default') {
    $argParts.Add("importaction=$($ImportAction.ToLower())")
}
if ($Command -in @('Compile', 'Import') -and $SyncSchema -ne 'Default') {
    $argParts.Add("synchronizeschemachanges=$($SyncSchema.ToLower())")
}

$argParts.Add("logfile=$logFile")

if ($SqlCredential) {
    $argParts.Add('ntauthentication=no')
    $argParts.Add("username=$($SqlCredential.UserName)")
    $argParts.Add("password=$($SqlCredential.GetNetworkCredential().Password)")
} else {
    $argParts.Add('ntauthentication=yes')
}

$argString = $argParts -join ', '
$argStringRedacted = Redact-Arguments $argString

# ---------------------------------------------------------------------------
# Dry-run path — return command without executing
# ---------------------------------------------------------------------------
if (-not $Execute) {
    $output = [ordered]@{
        status       = 'ok'
        generated_at = [datetime]::UtcNow.ToString('o')
        command      = $Command
        executed     = $false
        finsql       = $resolvedFinsql
        arguments    = $argStringRedacted
        result       = $null
    }
    if ($OutFile) {
        $output | ConvertTo-Json -Depth 10 | Set-Content -Path $OutFile -Encoding UTF8
        [pscustomobject]@{ status = 'ok'; out_file = $OutFile; command = $Command; executed = $false } |
            ConvertTo-Json -Compress
    } else {
        $output | ConvertTo-Json -Depth 10
    }
    return
}

# ---------------------------------------------------------------------------
# Execute path — require a resolved finsql.exe
# ---------------------------------------------------------------------------
if (-not $resolvedFinsql) {
    $output = [ordered]@{
        status       = 'error'
        generated_at = [datetime]::UtcNow.ToString('o')
        command      = $Command
        executed     = $false
        finsql       = $null
        arguments    = $argStringRedacted
        result       = $null
        error        = "finsql.exe not found. Checked: $($defaultPaths -join '; '). Use -FinSqlPath to override."
    }
    if ($OutFile) {
        $output | ConvertTo-Json -Depth 10 | Set-Content -Path $OutFile -Encoding UTF8
        [pscustomobject]@{ status = 'error'; out_file = $OutFile; command = $Command; executed = $false } |
            ConvertTo-Json -Compress
    } else {
        $output | ConvertTo-Json -Depth 10
    }
    exit 1
}

# Ensure log dir exists
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

# Remove stale log files so we don't read results from a prior run
$errorLogFile = Join-Path $LogPath 'naverrorlog.txt'
foreach ($f in @($logFile, $errorLogFile)) {
    if (Test-Path $f) { Remove-Item $f -Force }
}

# ---------------------------------------------------------------------------
# Launch finsql.exe
# ---------------------------------------------------------------------------
$status = 'ok'
$launchError = $null

try {
    $proc = Start-Process -FilePath $resolvedFinsql `
        -ArgumentList $argString `
        -Wait `
        -PassThru `
        -WindowStyle Hidden
    # Note: exit code from finsql.exe is unreliable; we derive status from log files.
    $_ = $proc  # suppress unused-variable warning
} catch {
    $status = 'error'
    $launchError = $_.Exception.Message
}

# ---------------------------------------------------------------------------
# Read log files
# ---------------------------------------------------------------------------
$commandResult = $null
$errorLogContent = $null

if (Test-Path $logFile) {
    $commandResult = (Get-Content -Path $logFile -Raw -Encoding Unicode).Trim()
    if ([string]::IsNullOrWhiteSpace($commandResult)) {
        $commandResult = (Get-Content -Path $logFile -Raw).Trim()
    }
}

if (Test-Path $errorLogFile) {
    $errorLogContent = (Get-Content -Path $errorLogFile -Raw -Encoding Unicode).Trim()
    if ([string]::IsNullOrWhiteSpace($errorLogContent)) {
        $errorLogContent = (Get-Content -Path $errorLogFile -Raw).Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($errorLogContent)) {
        $status = 'error'
    }
}

if ($launchError) {
    $status = 'error'
}

# ---------------------------------------------------------------------------
# Build and emit result
# ---------------------------------------------------------------------------
$resultBlock = [ordered]@{
    command_result = $commandResult
    error_log      = $errorLogContent
}
if ($launchError) {
    $resultBlock['launch_error'] = $launchError
}

$output = [ordered]@{
    status       = $status
    generated_at = [datetime]::UtcNow.ToString('o')
    command      = $Command
    executed     = $true
    finsql       = $resolvedFinsql
    arguments    = $argStringRedacted
    result       = $resultBlock
}

if ($OutFile) {
    $output | ConvertTo-Json -Depth 10 | Set-Content -Path $OutFile -Encoding UTF8
    [pscustomobject]@{ status = $status; out_file = $OutFile; command = $Command; executed = $true } |
        ConvertTo-Json -Compress
} else {
    $output | ConvertTo-Json -Depth 10
}

if ($status -eq 'error') { exit 1 }
