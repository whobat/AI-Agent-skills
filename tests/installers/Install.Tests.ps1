# Pester 5 tests for install.ps1.
#
# Hermetic: each test builds a throwaway repo copy (installer + fixture skills) and a
# fake HOME, then runs install.ps1 in a CHILD pwsh with USERPROFILE overridden — the
# child's $HOME resolves to the fake home, so the real ~/.claude is never touched.
# No network, no winget/pip (fixtures declare no requirements and ship no .py files).

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

    function script:New-Fixture {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("skills-ps1-test-" + [System.IO.Path]::GetRandomFileName())
        $repo = Join-Path $tmp 'repo'
        $home_ = Join-Path $tmp 'home'
        $skills = Join-Path $repo 'skills'
        New-Item -ItemType Directory -Force $repo, $home_ | Out-Null
        Copy-Item (Join-Path $script:RepoRoot 'install.ps1') $repo

        # Spec-compliant frontmatter (version under metadata:, per agentskills.io).
        # Pre-installed fixtures below use the legacy top-level version: inline to
        # prove the legacy -> spec update path keeps working.
        function fm($name, $version) { "---`nname: $name`ndescription: test fixture`nlicense: MIT`nmetadata:`n  version: `"$version`"`n---`n# $name`n" }

        # alpha-skill: ships a fake secret + cache that must never be installed
        New-Item -ItemType Directory -Force (Join-Path $skills 'alpha-skill\scripts\__pycache__') | Out-Null
        Set-Content (Join-Path $skills 'alpha-skill\SKILL.md') (fm 'alpha-skill' '1.0.0')
        Set-Content (Join-Path $skills 'alpha-skill\config.json') '{"token":"SECRET"}'
        Set-Content (Join-Path $skills 'alpha-skill\config.example.json') '{"token":""}'
        Set-Content (Join-Path $skills 'alpha-skill\scripts\__pycache__\junk.bin') 'x'
        # beta-skill: plain
        New-Item -ItemType Directory -Force (Join-Path $skills 'beta-skill') | Out-Null
        Set-Content (Join-Path $skills 'beta-skill\SKILL.md') (fm 'beta-skill' '2.0.0')
        # cred-skill: authCommand + configPath (never executed by install.ps1 — only printed)
        New-Item -ItemType Directory -Force (Join-Path $skills 'cred-skill') | Out-Null
        Set-Content (Join-Path $skills 'cred-skill\SKILL.md') (fm 'cred-skill' '1.0.0')
        Set-Content (Join-Path $skills 'cred-skill\skill.install.json') (@{
            authCommand = 'python scripts/auth.py --auth'
            configPath  = '~/.credtest/config.json'
            authHelp    = @('Get your token at https://example.test')
        } | ConvertTo-Json)

        # tool-skill: warnOnly requirement detected via file paths (not auto-installable, e.g. finsql.exe)
        $toolPath = Join-Path $tmp 'fake-tool.exe'
        New-Item -ItemType Directory -Force (Join-Path $skills 'tool-skill') | Out-Null
        Set-Content (Join-Path $skills 'tool-skill\SKILL.md') (fm 'tool-skill' '1.0.0')
        Set-Content (Join-Path $skills 'tool-skill\skill.install.json') (@{
            requirements = @(@{
                name        = 'Fake Tool'
                detectPaths = @($toolPath)
                warnOnly    = $true
                help        = 'Install Fake Tool manually.'
                url         = 'https://example.test/tool'
            })
        } | ConvertTo-Json -Depth 5)

        [pscustomobject]@{ Tmp = $tmp; Repo = $repo; Home = $home_; AgentDir = Join-Path $home_ '.claude\skills'; ToolPath = $toolPath }
    }

    function script:Invoke-Installer($fx, [string[]]$InstallerArgs) {
        $saveUP = $env:USERPROFILE; $saveHome = $env:HOME
        $env:USERPROFILE = $fx.Home; $env:HOME = $fx.Home
        try {
            $out = & pwsh -NoProfile -File (Join-Path $fx.Repo 'install.ps1') @InstallerArgs 2>&1 | Out-String
            [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
        } finally {
            $env:USERPROFILE = $saveUP; $env:HOME = $saveHome
        }
    }
}

Describe 'install.ps1' {

    It 'ignores skills nested deeper than the depth limit (parity with cli/sh)' {
        $fx = New-Fixture
        $deep = Join-Path $fx.Repo 'skills\a\b\deep-skill'
        New-Item -ItemType Directory -Force $deep | Out-Null
        Set-Content (Join-Path $deep 'SKILL.md') "---`nname: deep-skill`ndescription: x`nlicense: MIT`nmetadata:`n  version: `"1.0.0`"`n---`n"
        (Invoke-Installer $fx @('-Agent', 'claude', '-Skill', 'deep-skill', '-Yes')).Code | Should -Not -Be 0
    }

    It 'discovers skills nested under category folders and installs them FLAT' {
        $fx = New-Fixture
        $flat = Join-Path $fx.Repo 'skills\beta-skill'
        $grouped = Join-Path $fx.Repo 'skills\tools\beta-skill'
        New-Item -ItemType Directory -Force (Split-Path $grouped) | Out-Null
        Move-Item $flat $grouped
        $r = Invoke-Installer $fx @('-Agent', 'claude', '-Skill', 'beta-skill', '-Yes')
        $r.Code | Should -Be 0
        Join-Path $fx.AgentDir 'beta-skill\SKILL.md' | Should -Exist        # flat
        Join-Path $fx.AgentDir 'tools' | Should -Not -Exist                  # no category folder
    }

    It 'installs a single skill into the agent dir, showing (new, version)' {
        $fx = New-Fixture
        $r = Invoke-Installer $fx @('-Agent', 'claude', '-Skill', 'beta-skill', '-Yes')
        $r.Code | Should -Be 0
        $r.Out | Should -Match 'installed beta-skill -> .+ \(new, 2\.0\.0\)'
        Join-Path $fx.AgentDir 'beta-skill\SKILL.md' | Should -Exist
        Join-Path $fx.AgentDir 'alpha-skill' | Should -Not -Exist
    }

    It 'reinstalling over an older version shows the transition on the install line' {
        $fx = New-Fixture
        $pre = Join-Path $fx.AgentDir 'beta-skill'
        New-Item -ItemType Directory -Force $pre | Out-Null
        Set-Content (Join-Path $pre 'SKILL.md') "---`nname: beta-skill`nversion: 1.5.0`ndescription: old`n---`n"
        $r = Invoke-Installer $fx @('-Agent', 'claude', '-Skill', 'beta-skill', '-Yes')
        $r.Out | Should -Match 'installed beta-skill -> .+ \(1\.5\.0 -> 2\.0\.0\)'
    }

    It 'never installs secrets or caches; keeps config.example.json' {
        $fx = New-Fixture
        [void](Invoke-Installer $fx @('-Agent', 'claude', '-Skill', 'alpha-skill', '-Yes'))
        $dest = Join-Path $fx.AgentDir 'alpha-skill'
        Join-Path $dest 'config.json' | Should -Not -Exist
        Join-Path $dest 'config.example.json' | Should -Exist
        Join-Path $dest 'scripts\__pycache__' | Should -Not -Exist
    }

    It '-Skill all installs every skill' {
        $fx = New-Fixture
        $r = Invoke-Installer $fx @('-Agent', 'claude', '-Skill', 'all', '-Yes')
        $r.Code | Should -Be 0
        foreach ($s in 'alpha-skill', 'beta-skill', 'cred-skill') {
            Join-Path $fx.AgentDir "$s\SKILL.md" | Should -Exist
        }
    }

    It '-Agent all installs into every agent skills dir' {
        $fx = New-Fixture
        $r = Invoke-Installer $fx @('-Agent', 'all', '-Skill', 'beta-skill', '-Yes')
        $r.Code | Should -Be 0
        foreach ($dir in @('.claude\skills', '.agents\skills', '.config\opencode\skills')) {
            Join-Path $fx.Home "$dir\beta-skill\SKILL.md" | Should -Exist
        }
    }

    It 'fails on an unknown skill' {
        $fx = New-Fixture
        (Invoke-Installer $fx @('-Agent', 'claude', '-Skill', 'nope', '-Yes')).Code | Should -Not -Be 0
    }

    It 'updates an outdated installed skill, preserving its config.json' {
        $fx = New-Fixture
        $pre = Join-Path $fx.AgentDir 'alpha-skill'
        New-Item -ItemType Directory -Force $pre | Out-Null
        Set-Content (Join-Path $pre 'SKILL.md') "---`nname: alpha-skill`nversion: 0.9.0`ndescription: old`n---`n"
        Set-Content (Join-Path $pre 'config.json') '{"keep":"me"}' -NoNewline
        Set-Content (Join-Path $pre 'gotchas.local.md') '' -NoNewline  # empty local file
        $r = Invoke-Installer $fx @('-Agent', 'claude', '-Skill', 'beta-skill', '-Yes')
        $r.Out | Should -Match 'alpha-skill: 0\.9\.0 -> 1\.0\.0'
        Get-Content (Join-Path $pre 'SKILL.md') -Raw | Should -Match 'version: "1\.0\.0"'
        Get-Content (Join-Path $pre 'config.json') -Raw | Should -Be '{"keep":"me"}'
        # per-skill local learnings survive the update too — even an empty file (preserved by existence)
        Join-Path $pre 'gotchas.local.md' | Should -Exist
    }

    It '-Update refreshes installed skills only, preserving config; second run is up to date' {
        $fx = New-Fixture
        $pre = Join-Path $fx.AgentDir 'alpha-skill'
        New-Item -ItemType Directory -Force $pre | Out-Null
        Set-Content (Join-Path $pre 'SKILL.md') "---`nname: alpha-skill`nversion: 0.9.0`ndescription: old`n---`n"
        Set-Content (Join-Path $pre 'config.json') '{"keep":"me"}' -NoNewline
        $r = Invoke-Installer $fx @('-Agent', 'claude', '-Update', '-Yes')
        $r.Code | Should -Be 0
        $r.Out | Should -Match 'alpha-skill: 0\.9\.0 -> 1\.0\.0'
        Get-Content (Join-Path $pre 'SKILL.md') -Raw | Should -Match 'version: "1\.0\.0"'
        Get-Content (Join-Path $pre 'config.json') -Raw | Should -Be '{"keep":"me"}'
        Join-Path $fx.AgentDir 'beta-skill' | Should -Not -Exist
        $r2 = Invoke-Installer $fx @('-Agent', 'claude', '-Update', '-Yes')
        $r2.Out | Should -Match 'all installed skills are up to date'
    }

    It 'unconfigured: prints credential setup help' {
        $fx = New-Fixture
        $r = Invoke-Installer $fx @('-Agent', 'claude', '-Skill', 'cred-skill', '-Yes')
        $r.Out | Should -Match 'Credential setup for cred-skill'
        $r.Out | Should -Match 'example\.test'
    }

    It 'warnOnly requirement missing: warns but install succeeds' {
        $fx = New-Fixture
        $r = Invoke-Installer $fx @('-Agent', 'claude', '-Skill', 'tool-skill', '-Yes')
        $r.Code | Should -Be 0
        $r.Out | Should -Match 'Fake Tool not found'
        $r.Out | Should -Match 'fake-tool\.exe'
        $r.Out | Should -Match 'Install Fake Tool manually'
        Join-Path $fx.AgentDir 'tool-skill\SKILL.md' | Should -Exist
    }

    It 'warnOnly requirement present via detectPaths: reports OK, no warning' {
        $fx = New-Fixture
        Set-Content $fx.ToolPath 'x'
        $r = Invoke-Installer $fx @('-Agent', 'claude', '-Skill', 'tool-skill', '-Yes')
        $r.Out | Should -Match 'requirement OK: Fake Tool'
        $r.Out | Should -Not -Match 'Fake Tool not found'
    }

    It 'configured: prints "already configured" instead of token instructions' {
        $fx = New-Fixture
        New-Item -ItemType Directory -Force (Join-Path $fx.Home '.credtest') | Out-Null
        Set-Content (Join-Path $fx.Home '.credtest\config.json') '{"token":"old"}'
        $r = Invoke-Installer $fx @('-Agent', 'claude', '-Skill', 'cred-skill', '-Yes')
        $r.Out | Should -Match 'already configured'
        $r.Out | Should -Not -Match 'example\.test'
        # and the existing config was not touched
        Get-Content (Join-Path $fx.Home '.credtest\config.json') -Raw | Should -Match '"old"'
    }
}
