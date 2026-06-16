# Pester 5 tests for Set-PeppolConfig.ps1 (no network; writes to a temp path).

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Set-PeppolConfig.ps1'
    $script:Tokens = $null
    $script:Errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$script:Tokens, [ref]$script:Errors)
    $script:Content = Get-Content $script:ScriptPath -Raw
    $script:Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("peppolcfg_" + [guid]::NewGuid().ToString('N'))
}

AfterAll {
    if ($script:Tmp -and (Test-Path -LiteralPath $script:Tmp)) {
        Remove-Item -Recurse -Force -LiteralPath $script:Tmp
    }
}

Describe 'Set-PeppolConfig.ps1' {

    It 'parses without errors' {
        $script:Errors | Should -BeNullOrEmpty
    }

    It 'is Windows PowerShell 5.1 compatible' {
        (Get-Content $script:ScriptPath -TotalCount 40) -join "`n" | Should -Match '#Requires -Version 5\.1'
        $script:Content | Should -Not -Match '\?\?'
    }

    It 'defaults ConfigPath to ~/.peppol-validation/config.json' {
        $script:Content | Should -Match '\.peppol-validation'
    }

    It 'writes the chosen endpoint to the config' {
        $cfg = Join-Path $script:Tmp 'config.json'
        & $script:ScriptPath -Endpoint 'http://localhost:8080/wsdvs' -ConfigPath $cfg | Out-Null
        Test-Path -LiteralPath $cfg | Should -BeTrue
        (Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json).endpoint | Should -Be 'http://localhost:8080/wsdvs'
    }

    It 'writes nothing (keeps the public Helger default) when the endpoint is blank' {
        $cfg = Join-Path $script:Tmp 'config-blank.json'
        & $script:ScriptPath -Endpoint '' -ConfigPath $cfg | Out-Null
        Test-Path -LiteralPath $cfg | Should -BeFalse
    }
}
