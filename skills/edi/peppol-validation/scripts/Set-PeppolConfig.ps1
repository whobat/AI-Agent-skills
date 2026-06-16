<#
.SYNOPSIS
    Optional config setup for the peppol-validation skill.

.DESCRIPTION
    The DEFAULT validator is the public OpenPeppol/Helger service — you do NOT need to run
    this for that. Run it only to point the skill at a self-hosted phive-ws (or to pin
    ruleset versions). It writes ~/.peppol-validation/config.json, which Invoke-PeppolValidation.ps1
    auto-discovers. Pressing Enter at the prompt keeps the public Helger default and writes nothing.

    Invoked by the installer's auth step (skill.install.json authCommand), or run by hand.

.PARAMETER Endpoint
    Non-interactive: set the validation endpoint directly (e.g. http://localhost:8080/wsdvs).
    An empty string keeps the public Helger default.

.PARAMETER ConfigPath
    Where to write the config. Defaults to ~/.peppol-validation/config.json.

.EXAMPLE
    pwsh -File Set-PeppolConfig.ps1
    # interactive: Enter = keep Helger, or type a self-hosted URL

.EXAMPLE
    pwsh -File Set-PeppolConfig.ps1 -Endpoint http://localhost:8080/wsdvs
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $Endpoint,
    [string] $ConfigPath = (Join-Path $HOME '.peppol-validation/config.json')
)
$ErrorActionPreference = 'Stop'

Write-Host "peppol-validation - validation endpoint setup" -ForegroundColor Cyan
Write-Host "Default: the public OpenPeppol/Helger service (https://peppol.helger.com/wsdvs)."
Write-Host "Run this only to use a self-hosted phive-ws instead. Press Enter to keep the default."

if (-not $PSBoundParameters.ContainsKey('Endpoint')) {
    $Endpoint = Read-Host "Self-hosted validator endpoint URL (Enter = keep public Helger)"
}
$Endpoint = ("$Endpoint").Trim()

if (-not $Endpoint) {
    Write-Host "Keeping the default public Helger service - no config written." -ForegroundColor Green
    if (Test-Path -LiteralPath $ConfigPath) {
        Write-Host "An existing config remains at $ConfigPath - delete it to fully revert to the default." -ForegroundColor DarkYellow
    }
    return
}

$dir = Split-Path -Parent $ConfigPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

$cfg = [ordered]@{ endpoint = $Endpoint }
($cfg | ConvertTo-Json) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

Write-Host "Wrote $ConfigPath" -ForegroundColor Green
Write-Host "peppol-validation will now validate against: $Endpoint" -ForegroundColor Green
Write-Host "(Delete that file or re-run with Enter to go back to the public Helger service.)" -ForegroundColor DarkGray
