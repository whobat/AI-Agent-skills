#requires -Version 5.1
<#
.SYNOPSIS
  Install Agent Skills into a coding agent's skills directory.
.EXAMPLE
  ./install.ps1 -Agent claude -Skill all
  ./install.ps1 -Agent codex  -Skill tidsregistrering
#>
param(
  [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'opencode')][string]$Agent,
  [string]$Skill = 'all',
  [switch]$Symlink
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillsSrc = Join-Path $root 'skills'

$targets = @{
  claude   = Join-Path $HOME '.claude/skills'
  codex    = Join-Path $HOME '.agents/skills'
  opencode = Join-Path $HOME '.config/opencode/skills'
}
$dest = $targets[$Agent]
New-Item -ItemType Directory -Force -Path $dest | Out-Null

# Resolve which skill folders to install
if ($Skill -eq 'all') {
  $folders = Get-ChildItem -Directory $skillsSrc
} else {
  $one = Join-Path $skillsSrc $Skill
  if (-not (Test-Path $one)) { throw "Skill '$Skill' findes ikke i $skillsSrc" }
  $folders = @(Get-Item $one)
}

foreach ($f in $folders) {
  $targetPath = Join-Path $dest $f.Name
  if (Test-Path $targetPath) { Remove-Item $targetPath -Recurse -Force }
  if ($Symlink) {
    New-Item -ItemType SymbolicLink -Path $targetPath -Target $f.FullName | Out-Null
    Write-Host "  linked $($f.Name) -> $targetPath"
  } else {
    Copy-Item $f.FullName $targetPath -Recurse
    # Never install real secrets
    Get-ChildItem $targetPath -Recurse -Include 'config.json' -File | Remove-Item -Force
    Get-ChildItem $targetPath -Recurse -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force
    Write-Host "  installed $($f.Name) -> $targetPath"
  }
}

Write-Host "`nDone. $Agent skills dir: $dest"
Write-Host "Reminder: skills needing secrets ship config.example.json — copy to config.json and add your tokens."
