# Pester 5 tests for Invoke-PeppolValidation.ps1.
# Static/contract tests only — no network required.

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot 'Invoke-PeppolValidation.ps1'
    $script:Tokens = $null
    $script:Errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$script:Tokens, [ref]$script:Errors)
    $script:Content = Get-Content $script:ScriptPath -Raw
}

Describe 'Invoke-PeppolValidation.ps1' {

    It 'parses without errors' {
        $script:Errors | Should -BeNullOrEmpty
    }

    It 'is Windows PowerShell 5.1 compatible (no #Requires 7, no ternary/null-coalescing)' {
        (Get-Content $script:ScriptPath -TotalCount 60) -join "`n" | Should -Match '#Requires -Version 5\.1'
        # PS 5.1 cannot parse `? :` ternary or `??`; the AST parse above would fail on 7-only syntax.
        $script:Content | Should -Not -Match '\?\?'
    }

    Context 'parameters' {
        BeforeAll {
            $script:Params = $script:Ast.ParamBlock.Parameters
            $script:ParamNames = $script:Params.Name.VariablePath.UserPath
        }

        It 'has parameter <_>' -ForEach @('Path', 'VesId', 'Endpoint', 'ReportFolder', 'ConfigPath') {
            $script:ParamNames | Should -Contain $_
        }

        It 'Path is mandatory and pipeline-bound' {
            $p = $script:Params | Where-Object { $_.Name.VariablePath.UserPath -eq 'Path' }
            $named = $p.Attributes.NamedArguments
            ($named | Where-Object { $_.ArgumentName -eq 'Mandatory' }) | Should -Not -BeNullOrEmpty
            ($named | Where-Object { $_.ArgumentName -eq 'ValueFromPipeline' }) | Should -Not -BeNullOrEmpty
        }

        It 'loads config.json for a self-hosted endpoint, without overriding an explicit -Endpoint' {
            # discovery order: -ConfigPath, ~/.peppol-validation/config.json, skill-folder config.json
            $script:Content | Should -Match '\.peppol-validation'
            $script:Content | Should -Match "Join-Path \(Split-Path \`$PSScriptRoot -Parent\) 'config\.json'"
            $script:Content | Should -Match 'ConvertFrom-Json'
            $script:Content | Should -Match "PSBoundParameters\.ContainsKey\('Endpoint'\)"
            $script:Content | Should -Match 'vesByArtifact'
        }

        It 'defaults Endpoint to the public OpenPeppol/Helger service' {
            $script:Content | Should -Match 'peppol\.helger\.com/wsdvs'
        }
    }

    Context 'document-type / VESID map' {
        It 'maps the common DK/EU trade document <_>' -ForEach @(
            'invoice', 'creditnote', 'order', 'order-response',
            'catalogue', 'despatch-advice', 'mlr'
        ) {
            $script:Content | Should -Match ("eu\.peppol\.bis3:" + [regex]::Escape($_) + ":")
        }

        It 'tells billing invoice from credit note by root element' {
            $script:Content | Should -Match "poacc:billing:3\.0"
            $script:Content | Should -Match "RootName -eq 'CreditNote'"
        }

        It 'orders the order_response token before the order token (specific first)' {
            $iResp = $script:Content.IndexOf('poacc:trns:order_response:3')
            $iOrder = $script:Content.IndexOf("poacc:trns:order:3'")
            $iResp | Should -BeGreaterThan -1
            $iResp | Should -BeLessThan $iOrder
        }

        It 'is root-aware: transaction rules carry an expected Root and a mismatch is non-standard' {
            $script:Content | Should -Match "Root = 'DespatchAdvice'"
            $script:Content | Should -Match "Root = 'OrderResponse'"
            $script:Content | Should -Match "if \(\`$RootName -and \`$RootName -ne \`$r\.Root\) \{ return \`$null \}"
        }
    }

    Context 'behaviour contract' {
        It 'final OK verdict also requires the service to report success (no false [OK])' {
            $script:Content | Should -Match '-not \$r\.Success'
            $script:Content | Should -Match '\$r\.Errors\.Count -gt 0'
        }

        It 'flags unrecognized documents as non-standard (exit 3 path)' {
            $script:Content | Should -Match 'NonStandard'
            $script:Content | Should -Match 'NOT a recognized Peppol BIS 3\.0 document'
        }

        It 'uses the four documented exit codes' {
            $script:Content | Should -Match 'exit 0'
            $script:Content | Should -Match 'exit 1'
            $script:Content | Should -Match 'exit 2'
            $script:Content | Should -Match 'exit 3'
        }

        It 'retries on rate limiting (429/503)' {
            $script:Content | Should -Match '429'
            $script:Content | Should -Match '503'
        }

        It 'posts the SOAP validate action with a VESID-bearing request' {
            $script:Content | Should -Match 'SOAPAction'
            $script:Content | Should -Match 'validateRequestInput'
            $script:Content | Should -Match 'VESID="'
        }
    }
}
