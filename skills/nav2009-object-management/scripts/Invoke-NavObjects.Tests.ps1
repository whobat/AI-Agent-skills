# Pester 5 tests for Invoke-NavObjects.ps1.
# Static/contract tests only — no NAV install or finsql.exe required.

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Invoke-NavObjects.ps1'
    $script:Tokens = $null
    $script:Errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$script:Tokens, [ref]$script:Errors)
}

Describe 'Invoke-NavObjects.ps1' {

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
            'Command', 'ServerName', 'Database', 'Path', 'Filter',
            'FinSqlPath', 'SqlCredential', 'SyncSchema', 'ImportAction',
            'Execute', 'LogPath', 'OutFile'
        ) {
            $script:ParamNames | Should -Contain $_
        }

        It 'Command is mandatory' {
            $p = $script:Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Command' }
            $p.Attributes.NamedArguments |
                Where-Object { $_.ArgumentName -eq 'Mandatory' } |
                Should -Not -BeNullOrEmpty
        }

        It 'ServerName is mandatory' {
            $p = $script:Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'ServerName' }
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

        It 'Command ValidateSet covers Export/Import/Compile' {
            $p = $script:Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Command' }
            $set = ($p.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }).PositionalArguments.Value
            foreach ($v in @('Export', 'Import', 'Compile')) { $set | Should -Contain $v }
        }

        It 'SyncSchema ValidateSet covers Default/Yes/No/Force' {
            $p = $script:Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'SyncSchema' }
            $set = ($p.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }).PositionalArguments.Value
            foreach ($v in @('Default', 'Yes', 'No', 'Force')) { $set | Should -Contain $v }
        }

        It 'ImportAction ValidateSet covers Default/Overwrite/Skip' {
            $p = $script:Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'ImportAction' }
            $set = ($p.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }).PositionalArguments.Value
            foreach ($v in @('Default', 'Overwrite', 'Skip')) { $set | Should -Contain $v }
        }
    }

    Context 'finsql command names' {
        BeforeAll {
            $script:Content = Get-Content $script:ScriptPath -Raw
        }

        It 'references finsql command <_>' -ForEach @(
            'exportobjects', 'importobjects', 'compileobjects'
        ) {
            $script:Content | Should -Match ([regex]::Escape($_))
        }
    }

    Context 'dry run (behavioral — no finsql.exe needed)' {
        It 'returns the full argument string in the JSON (regression: $Args shadowing)' {
            $json = & $script:ScriptPath -Command Export -ServerName 'SRV01' -Database 'NAVDB' `
                -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'objects.txt') `
                -Filter 'Type=Table;ID=32|50022'
            $r = $json | ConvertFrom-Json
            $r.executed | Should -BeFalse
            $r.arguments | Should -Not -BeNullOrEmpty
            $r.arguments | Should -Match 'command=exportobjects'
            $r.arguments | Should -Match 'servername=SRV01'
            $r.arguments | Should -Match 'database=NAVDB'
            $r.arguments | Should -Match ([regex]::Escape('filter=Type=Table;ID=32|50022'))
            $r.arguments | Should -Match 'ntauthentication=yes'
        }

        It 'redacts the SQL password in the dry-run arguments' {
            $cred = [pscredential]::new('sa',
                (ConvertTo-SecureString 'S3cretValue!' -AsPlainText -Force))
            $json = & $script:ScriptPath -Command Export -ServerName 'SRV01' -Database 'NAVDB' `
                -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'objects.txt') `
                -SqlCredential $cred
            $r = $json | ConvertFrom-Json
            $r.arguments | Should -Match ([regex]::Escape('password=***'))
            $r.arguments | Should -Not -Match 'S3cretValue'
        }
    }

    Context 'security contract' {
        BeforeAll {
            $script:Content = Get-Content $script:ScriptPath -Raw
        }

        It 'redacts password in output (contains password=*** literal)' {
            $script:Content | Should -Match ([regex]::Escape('password=***'))
        }

        It 'uses Set-StrictMode' {
            $script:Content | Should -Match 'Set-StrictMode'
        }

        It 'sets ErrorActionPreference to Stop' {
            $script:Content | Should -Match "ErrorActionPreference\s*=\s*'Stop'"
        }
    }
}
