# Pester 5 tests for Invoke-NavDbMaintenance.ps1.
# Static / contract tests only — no SQL Server required.

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Invoke-NavDbMaintenance.ps1'
    $script:Tokens     = $null
    $script:Errors     = $null
    $script:Ast        = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$script:Tokens, [ref]$script:Errors)
    $script:Content    = Get-Content $script:ScriptPath -Raw
}

Describe 'Invoke-NavDbMaintenance.ps1' {

    It 'parses without errors' {
        $script:Errors | Should -BeNullOrEmpty
    }

    It 'requires PowerShell 7' {
        (Get-Content $script:ScriptPath -TotalCount 1) | Should -Match '#Requires -Version 7'
    }

    Context 'parameters' {
        BeforeAll {
            $script:Params     = $script:Ast.ParamBlock.Parameters
            $script:ParamNames = $script:Params.Name.VariablePath.UserPath
        }

        It 'has parameter <_>' -ForEach @(
            'ServerInstance', 'Database', 'SqlCredential', 'Actions',
            'BackupPath', 'ReorganizeThreshold', 'RebuildThreshold', 'MinPageCount',
            'Online', 'Execute', 'Encrypt', 'QueryTimeout', 'OutFile'
        ) {
            $script:ParamNames | Should -Contain $_
        }

        It 'ServerInstance is mandatory' {
            $p = $script:Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'ServerInstance' }
            $p.Attributes.NamedArguments |
                Where-Object { $_.ArgumentName -eq 'Mandatory' } |
                Should -Not -BeNullOrEmpty
        }

        It 'Database is mandatory' {
            $p = $script:Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Database' }
            $p.Attributes.NamedArguments |
                Where-Object { $_.ArgumentName -eq 'Mandatory' } |
                Should -Not -BeNullOrEmpty
        }

        It 'Actions ValidateSet covers all documented values' {
            $p   = $script:Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Actions' }
            $set = ($p.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }).PositionalArguments.Value
            $expected = @('all', 'backup', 'checkdb', 'index_maintenance', 'statistics')
            foreach ($v in $expected) { $set | Should -Contain $v }
        }

        It 'Execute is a switch (dry-run default)' {
            $p = $script:Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Execute' }
            $p.StaticType.Name | Should -Be 'SwitchParameter'
        }

        It 'Online is a switch' {
            $p = $script:Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Online' }
            $p.StaticType.Name | Should -Be 'SwitchParameter'
        }
    }

    Context 'required T-SQL operations present' {

        It 'contains ALTER INDEX statement (rebuild/reorganize)' {
            $script:Content | Should -Match 'ALTER INDEX'
        }

        It 'contains BACKUP DATABASE statement' {
            $script:Content | Should -Match 'BACKUP DATABASE'
        }

        It 'contains DBCC CHECKDB statement' {
            $script:Content | Should -Match 'DBCC CHECKDB'
        }

        It 'contains sp_updatestats call' {
            $script:Content | Should -Match 'sp_updatestats'
        }

        It 'uses CHECKSUM in backup statement' {
            $script:Content | Should -Match 'WITH CHECKSUM'
        }
    }

    Context 'NAV-owns-indexes safety contract — no CREATE/DROP INDEX' {
        BeforeAll {
            # Remove block comments (<# ... #>) and line comments (# ...) before checking DDL.
            # The safety-notice prose inside the comment-based help legitimately names CREATE/DROP
            # INDEX as *forbidden* operations — we only care about executable code.
            $noBlock = [regex]::Replace($script:Content, '(?s)<#.*?#>', '')
            $script:ExecutableContent = ($noBlock -split "`n" |
                Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        }

        It 'does not contain CREATE INDEX in executable code' {
            $script:ExecutableContent | Should -Not -Match '(?i)CREATE\s+INDEX'
        }

        It 'does not contain DROP INDEX in executable code' {
            $script:ExecutableContent | Should -Not -Match '(?i)DROP\s+INDEX'
        }
    }

    Context 'dry-run default' {

        It 'has a planned status literal in the script body' {
            $script:Content | Should -Match "'planned'"
        }

        It 'Execute switch defaults to absent (no default value that would make it true)' {
            $p = $script:Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Execute' }
            # SwitchParameter with no default initializer is $false by default
            $p.DefaultValue | Should -BeNullOrEmpty
        }
    }

    Context 'output contract' {

        It 'contains generated_at field' {
            $script:Content | Should -Match 'generated_at'
        }

        It 'contains executed field' {
            # The field appears as a bare key in an ordered hashtable: "executed = ..."
            $script:Content | Should -Match '\bexecuted\b'
        }

        It 'uses ConvertTo-Json for output' {
            $script:Content | Should -Match 'ConvertTo-Json'
        }

        It 'writes to -OutFile via Set-Content exactly once' {
            ([regex]::Matches($script:Content, 'Set-Content')).Count | Should -Be 1
        }
    }

    It 'fails fast with a clear error on an unreachable server' {
        $json        = & pwsh -NoProfile -File $script:ScriptPath `
            -ServerInstance 'definitely-not-a-real-sql-host-0xDEAD' `
            -Database 'NAV_PROD' 2>$null
        $LASTEXITCODE | Should -Be 1
        $parsed = $json | ConvertFrom-Json
        $parsed.status | Should -Be 'error'
        $parsed.error  | Should -Match 'Cannot connect'
    }
}
