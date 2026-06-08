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

function Test-Command($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Get-PythonCmd {
  foreach ($c in @('python', 'python3', 'py')) {
    try { & $c --version *> $null } catch { continue }
    if ($LASTEXITCODE -eq 0) { return $c }
  }
  return $null
}

function Install-Python {
  if (Test-Command 'winget') {
    Write-Host '  installing Python via: winget install Python.Python.3.12'
    winget install -e --id Python.Python.3.12 --source winget `
      --accept-package-agreements --accept-source-agreements
    return $true
  }
  Write-Warning '  Could not auto-install Python (winget not found). Install manually: https://www.python.org/downloads/'
  return $false
}

# Print where to obtain a skill's credentials (from its skill.install.json authHelp).
function Write-AuthHelp($manifestPath) {
  if (-not (Test-Path $manifestPath)) { return }
  try { $m = Get-Content $manifestPath -Raw | ConvertFrom-Json } catch { return }
  $ac = $m.authCommand
  $help = $m.authHelp
  if (-not $ac -and -not $help) { return }
  Write-Host "`nCredential setup for $(Split-Path -Leaf (Split-Path -Parent $manifestPath)):"
  if ($ac) { Write-Host "  run: $ac" }
  foreach ($line in $help) { Write-Host "  $line" }
}

# Returns a working python command, installing it first if missing. $null if unavailable.
function Resolve-Python {
  $py = Get-PythonCmd
  if ($py) { return $py }
  Write-Host '  Python not found on PATH.'
  if (-not (Install-Python)) { return $null }
  $py = Get-PythonCmd
  if (-not $py) {
    Write-Host '  Python installed, but not on PATH for this session. Open a NEW terminal to use it.'
    return $null
  }
  Write-Host "  Python ready: $py"
  return $py
}

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

# Ensure Python is present if any installed skill ships .py scripts
$needsPython = $false
foreach ($f in $folders) {
  if (Get-ChildItem $f.FullName -Recurse -File -Filter '*.py' -ErrorAction SilentlyContinue | Select-Object -First 1) {
    $needsPython = $true; break
  }
}
if ($needsPython) {
  Write-Host "`nChecking Python (required by an installed skill)..."
  $null = Resolve-Python
}

# Show where to get credentials for any installed skill that needs them
foreach ($f in $folders) {
  Write-AuthHelp (Join-Path (Join-Path $dest $f.Name) 'skill.install.json')
}

Write-Host "`nDone. $Agent skills dir: $dest"
Write-Host "Reminder: skills needing secrets ship config.example.json — copy to config.json and add your tokens."
