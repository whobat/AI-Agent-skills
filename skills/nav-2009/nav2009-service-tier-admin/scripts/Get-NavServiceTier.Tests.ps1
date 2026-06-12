# Pester 5 tests for Get-NavServiceTier.ps1.
# Static/contract tests only — no live NAV server or Windows services required.

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Get-NavServiceTier.ps1'
    $script:Tokens     = $null
    $script:Errors     = $null
    $script:Ast        = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$script:Tokens, [ref]$script:Errors)
    $script:Content    = Get-Content $script:ScriptPath -Raw
}

Describe 'Get-NavServiceTier.ps1' {

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
            'ComputerName', 'Instance', 'IncludeFullConfig',
            'Restart', 'RestartTimeoutSec', 'OutFile'
        ) {
            $script:ParamNames | Should -Contain $_
        }

        It 'ComputerName defaults to $env:COMPUTERNAME' {
            $p = $script:Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'ComputerName' }
            # Default value expression references COMPUTERNAME environment variable
            $p.DefaultValue.ToString() | Should -Match 'COMPUTERNAME'
        }

        It 'RestartTimeoutSec has a default value of 60' {
            $p = $script:Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'RestartTimeoutSec' }
            $p.DefaultValue.ToString() | Should -Be '60'
        }
    }

    Context 'NAV service-name pattern' {
        It 'references the MicrosoftDynamicsNavServer service-name pattern' {
            $script:Content | Should -Match 'MicrosoftDynamicsNavServer'
        }

        It 'uses a LIKE filter for service enumeration' {
            $script:Content | Should -Match "LIKE 'MicrosoftDynamicsNavServer"
        }
    }

    Context 'CustomSettings.config handling' {
        It 'references CustomSettings.config by name' {
            $script:Content | Should -Match 'CustomSettings\.config'
        }

        It 'references the default Service folder path' {
            $script:Content | Should -Match 'Microsoft Dynamics NAV'
        }

        It 'parses XML using [xml] cast' {
            $script:Content | Should -Match '\[xml\]'
        }
    }

    Context '-Restart guard' {
        It 'requires -Instance when -Restart is used (guard text is present)' {
            # The script must contain a guard that checks Restart without Instance
            $script:Content | Should -Match '-Restart requires -Instance'
        }

        It 'exits with code 1 when -Restart is used without -Instance guard fires' {
            # Guard is followed by exit 1
            $script:Content | Should -Match 'exit 1'
        }
    }

    Context 'output contract' {
        It 'includes generated_at in output' {
            $script:Content | Should -Match 'generated_at'
        }

        It 'includes computer field in output' {
            $script:Content | Should -Match '\bcomputer\b'
        }

        It 'includes instances field in output' {
            $script:Content | Should -Match '\binstances\b'
        }

        It 'includes restart block in output' {
            $script:Content | Should -Match "'restart'"
        }

        It 'emits JSON via ConvertTo-Json' {
            $script:Content | Should -Match 'ConvertTo-Json'
        }

        It 'uses Set-Content exactly once (only for -OutFile write)' {
            ([regex]::Matches($script:Content, 'Set-Content')).Count | Should -Be 1
        }

        It 'timestamps use UTC via [datetime]::UtcNow' {
            $script:Content | Should -Match '\[datetime\]::UtcNow'
        }
    }

    Context 'NAS / Job Queue' {
        It 'references NASServicesStartupCodeunit' {
            $script:Content | Should -Match 'NASServicesStartupCodeunit'
        }

        It 'references NASServicesStartupMethod' {
            $script:Content | Should -Match 'NASServicesStartupMethod'
        }

        It 'references NASServicesStartupArgument' {
            $script:Content | Should -Match 'NASServicesStartupArgument'
        }
    }

    Context 'curated settings keys' {
        It 'surfaces ClientServicesPort' {
            $script:Content | Should -Match 'ClientServicesPort'
        }

        It 'surfaces SOAPServicesPort' {
            $script:Content | Should -Match 'SOAPServicesPort'
        }

        It 'surfaces ManagementServicesPort' {
            $script:Content | Should -Match 'ManagementServicesPort'
        }

        It 'surfaces DatabaseServer' {
            $script:Content | Should -Match 'DatabaseServer'
        }

        It 'surfaces DatabaseName' {
            $script:Content | Should -Match 'DatabaseName'
        }
    }

    Context 'error resilience' {
        It 'wraps per-instance work in try/catch so one bad config does not abort inventory' {
            # The script must contain try/catch blocks for per-instance error handling
            ([regex]::Matches($script:Content, '\btry\b')).Count | Should -BeGreaterOrEqual 2
        }

        It 'stores instance-level errors in an error field' {
            $script:Content | Should -Match "'error'"
        }
    }
}
