# Pester 5 tests for Invoke-PosFleetHealth.ps1.
# Static/contract tests — no fleet or WinRM required.

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Invoke-PosFleetHealth.ps1'
    $script:Tokens = $null
    $script:Errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$script:Tokens, [ref]$script:Errors)
}

Describe 'Invoke-PosFleetHealth.ps1' {

    It 'parses without errors' {
        $script:Errors | Should -BeNullOrEmpty
    }

    It 'requires PowerShell 7' {
        (Get-Content $script:ScriptPath -TotalCount 1) | Should -Match '#Requires -Version 7'
    }

    Context 'parameters' {
        BeforeAll {
            $script:ParamNames = $script:Ast.ParamBlock.Parameters.Name.VariablePath.UserPath
        }

        It 'has parameter <_>' -ForEach @(
            'ComputerName', 'ServerListFile', 'ServicePattern', 'EventHours',
            'DiskMinFreePct', 'ExpressLimitGB', 'ErrorCountWarn', 'ThrottleLimit',
            'UseSSL', 'Authentication', 'Credential', 'OutFile'
        ) {
            $script:ParamNames | Should -Contain $_
        }
    }

    Context 'read-only contract' {
        BeforeAll {
            $script:Content = Get-Content $script:ScriptPath -Raw
        }

        It 'contains no <_> calls (must never change target state)' -ForEach @(
            'Stop-Service', 'Start-Service', 'Restart-Service', 'Set-Service',
            'Restart-Computer', 'Stop-Computer', 'Remove-Item', 'Stop-Process',
            'INSERT INTO', 'UPDATE SET', 'DELETE FROM', 'ALTER ', 'DROP '
        ) {
            $script:Content | Should -Not -Match ([regex]::Escape($_))
        }

        It 'only writes to disk via -OutFile' {
            ([regex]::Matches($script:Content, 'Set-Content')).Count | Should -Be 1
        }
    }

    It 'exits with a clear error when no hosts are given' {
        $null = & pwsh -NoProfile -Command "& '$($script:ScriptPath)' -Credential ([pscredential]::new('x', (ConvertTo-SecureString 'x' -AsPlainText -Force)))" 2>$null
        $LASTEXITCODE | Should -Be 1
    }

    It 'reports an unreachable host as a warning, not a crash' {
        $cred = "[pscredential]::new('fake\user', (ConvertTo-SecureString 'x' -AsPlainText -Force))"
        $json = & pwsh -NoProfile -Command `
            "& '$($script:ScriptPath)' -ComputerName 'definitely-not-a-real-pos-host-0xDEAD' -Credential ($cred)" 2>$null
        $r = $json | ConvertFrom-Json
        $r.status | Should -Be 'error'
        $r.summary.warning_count | Should -BeGreaterOrEqual 1
        $r.summary.warnings[0].type | Should -BeIn @('unreachable', 'auth_failed')
        $r.hosts[0].computer | Should -Be 'definitely-not-a-real-pos-host-0xDEAD'
    }
}
