# Pester 5 tests for Invoke-SqlPerfTriage.ps1.
# Static/contract tests only — no SQL Server required.

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Invoke-SqlPerfTriage.ps1'
    $script:Tokens = $null
    $script:Errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$script:Tokens, [ref]$script:Errors)
}

Describe 'Invoke-SqlPerfTriage.ps1' {

    It 'parses without errors' {
        $script:Errors | Should -BeNullOrEmpty
    }

    It 'requires PowerShell 7' {
        (Get-Content $script:ScriptPath -TotalCount 1) | Should -Match '#Requires -Version 7'
    }

    Context 'parameters' {
        BeforeAll {
            $script:Params = $script:Ast.ParamBlock.Parameters
            $script:ParamNames = $script:Params.Name.VariablePath.UserPath
        }

        It 'has parameter <_>' -ForEach @(
            'ServerInstance', 'Database', 'SqlCredential', 'Sections',
            'TopN', 'QueryTimeout', 'Encrypt', 'OutFile'
        ) {
            $script:ParamNames | Should -Contain $_
        }

        It 'ServerInstance is mandatory' {
            $p = $script:Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'ServerInstance' }
            $p.Attributes.NamedArguments |
                Where-Object { $_.ArgumentName -eq 'Mandatory' } |
                Should -Not -BeNullOrEmpty
        }

        It 'declares all documented sections in $ValidSections' {
            $content = Get-Content (Join-Path $PSScriptRoot 'Invoke-SqlPerfTriage.ps1') -Raw
            $expected = @('all', 'server', 'database', 'waits', 'top_queries', 'missing_indexes',
                'unused_indexes', 'blocking', 'deadlocks', 'sift', 'fragmentation',
                'stats', 'largest_tables')
            foreach ($section in $expected) { $content | Should -Match "'$section'" }
        }

        It 'rejects an unknown section before connecting' {
            $null = & pwsh -NoProfile -File $script:ScriptPath `
                -ServerInstance 'never-contacted' -Sections 'bogus_section' 2>$null
            $LASTEXITCODE | Should -Be 1
        }

        It 'accepts a comma-joined -Sections string (pwsh -File form)' {
            # Validation must pass and the script proceed to the connection attempt.
            $json = & pwsh -NoProfile -File $script:ScriptPath `
                -ServerInstance 'definitely-not-a-real-sql-host-0xDEAD' -Sections 'waits,blocking' 2>$null
            ($json | ConvertFrom-Json).error | Should -Match 'Cannot connect'
        }
    }

    Context 'read-only contract' {
        BeforeAll {
            # Every embedded T-SQL batch must be a query; no DDL/DML statement starts.
            $script:Content = Get-Content $script:ScriptPath -Raw
        }

        It 'contains no <_> statements' -ForEach @(
            'INSERT INTO', 'UPDATE SET', 'DELETE FROM', 'CREATE INDEX', 'CREATE TABLE',
            'ALTER INDEX', 'ALTER DATABASE', 'DROP ', 'TRUNCATE ', 'EXEC sp_configure'
        ) {
            $script:Content | Should -Not -Match ([regex]::Escape($_))
        }

        It 'only writes to disk via -OutFile' {
            # Set-Content must appear exactly once (the OutFile write)
            ([regex]::Matches($script:Content, 'Set-Content')).Count | Should -Be 1
        }
    }

    It 'fails fast with a clear error on an unreachable server' {
        $json = & pwsh -NoProfile -File $script:ScriptPath `
            -ServerInstance 'definitely-not-a-real-sql-host-0xDEAD' 2>$null
        $LASTEXITCODE | Should -Be 1
        $parsed = $json | ConvertFrom-Json
        $parsed.status | Should -Be 'error'
        $parsed.error | Should -Match 'Cannot connect'
    }
}
