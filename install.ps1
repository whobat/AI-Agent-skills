#requires -Version 5.1
<#
.SYNOPSIS
  Install Agent Skills into a coding agent's skills directory.
.EXAMPLE
  ./install.ps1 -Agent claude -Skill all
  ./install.ps1 -Agent codex  -Skill 7pace-time-tracker
#>
param(
  [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'opencode', 'all')][string]$Agent,
  [string]$Skill = 'all',
  [switch]$Symlink,
  [switch]$Update,
  [switch]$Yes
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

# Install a skill's Python dependencies (from its skill.install.json pipPackages).
function Install-PipDeps($manifestPath, $py) {
  if (-not $py) { return }
  if (-not (Test-Path $manifestPath)) { return }
  try { $m = Get-Content $manifestPath -Raw | ConvertFrom-Json } catch { return }
  $pkgs = $m.pipPackages
  if (-not $pkgs) { return }
  Write-Host "  installing Python packages: $($pkgs -join ', ')"
  & $py -m pip install --disable-pip-version-check @pkgs
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "  pip install failed. Run manually: $py -m pip install $($pkgs -join ' ')"
  }
}

# Print where to obtain a skill's credentials (from its skill.install.json authHelp).
# If the skill's config file (configPath) already exists, say so instead of token instructions.
function Write-AuthHelp($manifestPath) {
  if (-not (Test-Path $manifestPath)) { return }
  try { $m = Get-Content $manifestPath -Raw | ConvertFrom-Json } catch { return }
  $ac = $m.authCommand
  $help = $m.authHelp
  if (-not $ac -and -not $help) { return }
  $name = Split-Path -Leaf (Split-Path -Parent $manifestPath)
  if ($m.configPath) {
    $cfg = if ($m.configPath -match '^~[/\\]?') { Join-Path $HOME ($m.configPath -replace '^~[/\\]?', '') } else { $m.configPath }
    if (Test-Path $cfg) {
      Write-Host "`nCredentials for ${name}: already configured ($cfg). Run '$ac' to update tokens."
      return
    }
  }
  Write-Host "`nCredential setup for ${name}:"
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

# Read the skill version from SKILL.md frontmatter. Per the Agent Skills spec the version
# lives under `metadata: version:` (indented); legacy top-level `version:` still accepted.
function Get-SkillVersion($skillDir) {
  $md = Join-Path $skillDir 'SKILL.md'
  if (-not (Test-Path $md)) { return $null }
  $inFront = $false
  foreach ($line in Get-Content $md) {
    if ($line -match '^---\s*$') { if ($inFront) { break } else { $inFront = $true; continue } }
    if ($inFront -and $line -match '^\s*version:\s*(.+?)\s*$') { return $Matches[1].Trim().Trim('"', "'") }
  }
  return $null
}

# Is a declared requirement already satisfied (on PATH or at a known file path, and >= minVersion when checkable)?
function Test-RequirementPresent($req) {
  foreach ($p in @($req.detectPaths)) {
    if ($p -and (Test-Path $p)) { return $true }
  }
  if (-not $req.detect) { return $false }
  $cmd = Get-Command $req.detect -ErrorAction SilentlyContinue
  if (-not $cmd) { return $false }
  if ($req.minVersion) {
    try {
      $out = & $req.detect '--version' 2>$null
      if ($LASTEXITCODE -ne 0) { $out = & $req.detect '-v' 2>$null }
      $m = [regex]::Match([string]$out, '(\d+)\.(\d+)(?:\.(\d+))?')
      if ($m.Success) {
        $have = [version]$m.Value
        $need = [version]$req.minVersion
        return ($have -ge $need)
      }
    } catch { }
  }
  return $true   # present; couldn't parse a version -> accept
}

# Download the latest GitHub-released MSI for a requirement and install it silently.
function Install-FromGitHubMsi($req) {
  if (-not $req.githubRepo) { return $false }
  $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } 'x86' { 'x86' } default { 'x64' } }
  Write-Host "  fetching latest $($req.name) MSI from github.com/$($req.githubRepo) ..."
  try {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$($req.githubRepo)/releases/latest" `
      -Headers @{ 'User-Agent' = 'ai-agent-skills-installer' }
    $asset = $rel.assets | Where-Object { $_.name -match "win-$arch\.msi$" } | Select-Object -First 1
    if (-not $asset) { Write-Warning "  No win-$arch MSI asset found. Install manually: $($req.url)"; return $false }
    $tmp = Join-Path $env:TEMP $asset.name
    Write-Host "  downloading $($asset.name) ..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp
    Write-Host "  installing: msiexec /i $tmp /quiet /norestart"
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$tmp`" /quiet /norestart" -Wait -PassThru
    return ($p.ExitCode -eq 0)
  } catch {
    Write-Warning "  MSI install failed: $($_.Exception.Message). Install manually: $($req.url)"
    return $false
  }
}

# Install a missing requirement: winget first, then GitHub MSI fallback.
function Install-Requirement($req) {
  if ($req.wingetId -and (Test-Command 'winget')) {
    Write-Host "  installing $($req.name) via: winget install $($req.wingetId)"
    winget install -e --id $req.wingetId --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -eq 0) { return $true }
    Write-Warning "  winget install returned $LASTEXITCODE; trying MSI fallback."
  }
  return (Install-FromGitHubMsi $req)
}

# Ensure every requirement declared in a skill's skill.install.json is present.
function Resolve-Requirements($manifestPath) {
  if (-not (Test-Path $manifestPath)) { return }
  try { $m = Get-Content $manifestPath -Raw | ConvertFrom-Json } catch { return }
  foreach ($req in @($m.requirements)) {
    if (-not $req) { continue }
    if (Test-RequirementPresent $req) { Write-Host "  requirement OK: $($req.name)"; continue }
    # warnOnly requirements (e.g. NAV 2009 finsql.exe) cannot be auto-installed — warn and continue.
    if ($req.warnOnly) {
      Write-Warning "$($req.name) not found."
      if ($req.detectPaths) { Write-Host "    checked: $(@($req.detectPaths) -join '; ')" }
      if ($req.help) { Write-Host "    $($req.help)" }
      if ($req.url) { Write-Host "    $($req.url)" }
      continue
    }
    Write-Host "  requirement missing: $($req.name) - installing ..."
    [void](Install-Requirement $req)
    if (Test-RequirementPresent $req) { Write-Host "  $($req.name) ready" }
    else { Write-Host "  $($req.name) installed but not on PATH for this session. Open a NEW terminal. ($($req.url))" }
  }
}

# Skills live under category subfolders (skills/<category>/<name>/SKILL.md). Find each skill
# folder by locating its SKILL.md; the install name is the folder's basename.
function Get-SkillFolders($skillsSrc) {
  # -Depth 2 matches bin/cli.js (skill folder at most 2 levels below skills/) — installer parity.
  Get-ChildItem -Path $skillsSrc -Recurse -Depth 2 -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue |
    ForEach-Object { Get-Item $_.Directory.FullName }
}

# Map a skill name to its repo folder (or $null if not in this repo).
function Resolve-SkillSource($skillsSrc, $name) {
  Get-SkillFolders $skillsSrc | Where-Object { $_.Name -eq $name } |
    Select-Object -First 1 -ExpandProperty FullName
}

# Offer to update already-installed skills (from this repo) whose version differs from the repo.
# Returns the number of update candidates found (0 = everything already current).
function Update-OutdatedSkills($dest, $skillsSrc, $chosenNames) {
  if (-not (Test-Path $dest)) { return 0 }
  $candidates = @()
  foreach ($d in (Get-ChildItem -Directory $dest -ErrorAction SilentlyContinue)) {
    if ($chosenNames -contains $d.Name) { continue }          # just (re)installed above
    $srcDir = Resolve-SkillSource $skillsSrc $d.Name
    if (-not $srcDir) { continue }                            # not a skill from this repo
    $instV = Get-SkillVersion $d.FullName
    $repoV = Get-SkillVersion $srcDir
    if ($repoV -and ($instV -ne $repoV)) {
      $candidates += [pscustomobject]@{ Name = $d.Name; From = $instV; To = $repoV }
    }
  }
  if ($candidates.Count -eq 0) { return 0 }
  Write-Host "`nUpdates available for already-installed skills:"
  foreach ($c in $candidates) {
    $from = if ($c.From) { $c.From } else { 'unknown' }
    Write-Host "  $($c.Name): $from -> $($c.To)"
  }
  if (-not $Yes) {
    $ans = Read-Host 'Update these now? [Y/n]'
    if ($ans -and ($ans.Trim().ToLower() -in @('n', 'no', 'nej'))) { return $candidates.Count }
  }
  foreach ($c in $candidates) {
    $srcDir = Resolve-SkillSource $skillsSrc $c.Name
    $tp = Join-Path $dest $c.Name
    # Preserve user secrets (config.json) and per-skill local learnings (gotchas.local.md)
    # that live inside the skill dir, so an update never wipes them.
    $saved = Join-Path $tp 'config.json'
    $keep = $null
    if (Test-Path $saved) { $keep = Get-Content $saved -Raw }
    $savedG = Join-Path $tp 'gotchas.local.md'
    $keepG = $null
    if (Test-Path $savedG) { $keepG = Get-Content $savedG -Raw }
    Remove-Item $tp -Recurse -Force
    Copy-Item $srcDir $tp -Recurse
    Get-ChildItem $tp -Recurse -Include 'config.json' -File | Remove-Item -Force
    Get-ChildItem $tp -Recurse -Include 'gotchas.local.md' -File | Remove-Item -Force
    Get-ChildItem $tp -Recurse -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force
    if ($null -ne $keep) { Set-Content -Path $saved -Value $keep -NoNewline }
    if ($null -ne $keepG) { Set-Content -Path $savedG -Value $keepG -NoNewline }
    Write-Host "  updated $($c.Name) -> $($c.To)"
    Resolve-Requirements (Join-Path $tp 'skill.install.json')
  }
  return $candidates.Count
}

$targets = @{
  claude   = Join-Path $HOME '.claude/skills'
  codex    = Join-Path $HOME '.agents/skills'
  opencode = Join-Path $HOME '.config/opencode/skills'
}
# -Agent all installs into every supported agent's skills dir
$agentList = @(if ($Agent -eq 'all') { 'claude', 'codex', 'opencode' } else { $Agent })

# -Update: refresh installed skills to the repo versions; install nothing new
if ($Update) {
  foreach ($agentName in $agentList) {
    Write-Host "`nChecking for skill updates in $agentName ($($targets[$agentName]))"
    $n = Update-OutdatedSkills $targets[$agentName] $skillsSrc @()
    if ($n -eq 0) { Write-Host '  all installed skills are up to date.' }
  }
  Write-Host "`nDone."
  exit 0
}

# Resolve which skill folders to install (skills are nested under category folders)
if ($Skill -eq 'all') {
  $folders = @(Get-SkillFolders $skillsSrc)
} else {
  $one = Resolve-SkillSource $skillsSrc $Skill
  if (-not $one) { throw "Skill '$Skill' not found in $skillsSrc" }
  $folders = @(Get-Item $one)
}

foreach ($agentName in $agentList) {
$dest = $targets[$agentName]
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Write-Host "`nInstalling into $agentName ($dest)"

foreach ($f in $folders) {
  $targetPath = Join-Path $dest $f.Name
  # Show installed -> latest on the install line
  $instV = Get-SkillVersion $targetPath
  $repoV = Get-SkillVersion $f.FullName
  $note = if (-not $repoV) { '' }
          elseif ($instV -and $instV -ne $repoV) { " ($instV -> $repoV)" }
          elseif ($instV) { " ($repoV, reinstalled)" }
          else { " (new, $repoV)" }
  if (Test-Path $targetPath) { Remove-Item $targetPath -Recurse -Force }
  if ($Symlink) {
    New-Item -ItemType SymbolicLink -Path $targetPath -Target $f.FullName | Out-Null
    Write-Host "  linked $($f.Name) -> $targetPath$note"
  } else {
    Copy-Item $f.FullName $targetPath -Recurse
    # Never install real secrets or stray local learnings (those are created during use)
    Get-ChildItem $targetPath -Recurse -Include 'config.json' -File | Remove-Item -Force
    Get-ChildItem $targetPath -Recurse -Include 'gotchas.local.md' -File | Remove-Item -Force
    Get-ChildItem $targetPath -Recurse -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force
    Write-Host "  installed $($f.Name) -> $targetPath$note"
  }
}
}

# Machine-level steps below run once per skill — the manifests are identical across agents,
# so use each skill's copy under the first agent's dir.
$dest = $targets[$agentList[0]]

# Ensure each installed skill's declared runtime requirements (e.g. PowerShell 7) are present
foreach ($f in $folders) {
  Resolve-Requirements (Join-Path (Join-Path $dest $f.Name) 'skill.install.json')
}

# Ensure Python is present if any installed skill ships .py scripts
$needsPython = $false
foreach ($f in $folders) {
  if (Get-ChildItem $f.FullName -Recurse -File -Filter '*.py' -ErrorAction SilentlyContinue | Select-Object -First 1) {
    $needsPython = $true; break
  }
}
$py = $null
if ($needsPython) {
  Write-Host "`nChecking Python (required by an installed skill)..."
  $py = Resolve-Python
}

# Install each installed skill's Python dependencies
foreach ($f in $folders) {
  Install-PipDeps (Join-Path (Join-Path $dest $f.Name) 'skill.install.json') $py
}

# Show where to get credentials for any installed skill that needs them
foreach ($f in $folders) {
  Write-AuthHelp (Join-Path (Join-Path $dest $f.Name) 'skill.install.json')
}

# Offer to update other already-installed skills whose repo version has changed
foreach ($agentName in $agentList) {
  $null = Update-OutdatedSkills $targets[$agentName] $skillsSrc @($folders | ForEach-Object { $_.Name })
}

Write-Host "`nDone. Skills dir(s): $(($agentList | ForEach-Object { $targets[$_] }) -join '; ')"
Write-Host "Reminder: skills needing secrets ship config.example.json — copy to config.json and add your tokens."
