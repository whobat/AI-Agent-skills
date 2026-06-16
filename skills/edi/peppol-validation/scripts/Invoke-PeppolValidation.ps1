<#
.SYNOPSIS
    Validates Peppol documents against the official OpenPeppol BIS 3.0 rules.

.DESCRIPTION
    Give it a file, a folder, or a wildcard. For each XML document it:
      1. Auto-identifies the document type from the root element + cbc:CustomizationID.
      2. Tells you whether that matches the chosen standard (Peppol BIS 3.0).
      3. Runs the full official validation (UBL 2.1 XSD + Peppol Schematron) via the
         OpenPeppol/Helger validation web service and reports OK or the exact errors.

    Covers the Peppol BIS 3.0 document types normally used for trade in DK and the EU:
    invoice, credit note (incl. self-billing), order + responses/changes/cancellation,
    order agreement, catalogue + response, despatch advice, MLR, punch out, etc.

    Compatible with Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER Path
    One or more files, folders, or wildcards (e.g. C:\out, .\*.xml, invoice.xml).
    Also accepts pipeline input (Get-ChildItem *.xml | .\Invoke-PeppolValidation.ps1).

.PARAMETER VesId
    Optional. Force a specific VESID and skip auto-detection (e.g. for a non-default or
    deprecated ruleset).

.PARAMETER Endpoint
    Validation web service. Defaults to the public OpenPeppol/Helger instance.
    NOTE: the public service receives the document and rate-limits under load. For
    production / PII / batch, run your own phive-ws (Docker) and point -Endpoint at it.

.PARAMETER ReportFolder
    Optional. Writes the raw validation response (<file>.validation.xml) here.

.PARAMETER ConfigPath
    Optional. Path to a config.json. If omitted, the script looks for
    ~/.peppol-validation/config.json (written by Set-PeppolConfig.ps1 / the installer), then a
    config.json next to the skill. With no config at all the default is the public Helger
    service. Use a config to point at a self-hosted validator and/or pin VESIDs —
    see config.example.json. An explicit -Endpoint / -VesId still overrides the config.

.OUTPUTS
    Exit code: 0 = all valid, 1 = validation errors found, 3 = non-standard document
    (not Peppol BIS 3.0) detected, 2 = technical/usage problem.
    Precedence in a mixed batch: 2 > 1 > 3 > 0.

.EXAMPLE
    .\Invoke-PeppolValidation.ps1 invoice.xml

.EXAMPLE
    .\Invoke-PeppolValidation.ps1 C:\Peppol\Out -ReportFolder C:\Peppol\Reports

.EXAMPLE
    Get-ChildItem C:\Peppol\Out\*.xml | .\Invoke-PeppolValidation.ps1 -Endpoint http://phive:8080/wsdvs
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [Alias('FullName', 'PSPath')]
    [string[]] $Path,

    [string] $VesId,
    [string] $Endpoint = 'https://peppol.helger.com/wsdvs',
    [string] $ReportFolder,
    [string] $ConfigPath
)

begin {
    $ErrorActionPreference = 'Stop'

    # =====================================================================================
    #  Peppol BIS 3.0 ruleset table - the "standard" this script enforces.
    #  Update the VESID versions when OpenPeppol publishes a new release (quarterly).
    #  Source: https://peppol.helger.com/public/menuitem-validation-ws2
    # =====================================================================================
    $script:VesByArtifact = @{
        'invoice'                  = 'eu.peppol.bis3:invoice:2025.11'
        'creditnote'               = 'eu.peppol.bis3:creditnote:2025.11'
        'invoice-self-billing'     = 'eu.peppol.bis3:invoice-self-billing:2026.3'
        'creditnote-self-billing'  = 'eu.peppol.bis3:creditnote-self-billing:2026.3'
        'order'                    = 'eu.peppol.bis3:order:2025.11'
        'order-response'           = 'eu.peppol.bis3:order-response:2025.11'
        'order-response-advanced'  = 'eu.peppol.bis3:order-response-advanced:2025.11'
        'order-change'             = 'eu.peppol.bis3:order-change:2025.11'
        'order-cancellation'       = 'eu.peppol.bis3:order-cancellation:2025.11'
        'order-agreement'          = 'eu.peppol.bis3:order-agreement:2025.11'
        'catalogue'                = 'eu.peppol.bis3:catalogue:2025.11'
        'catalogue-response'       = 'eu.peppol.bis3:catalogue-response:2025.11'
        'despatch-advice'          = 'eu.peppol.bis3:despatch-advice:2025.11'
        'mlr'                      = 'eu.peppol.bis3:mlr:2025.11'
        'punch-out'                = 'eu.peppol.bis3:punch-out:2025.11'
        'invoice-message-response' = 'eu.peppol.bis3:invoice-message-response:2025.11'
    }
    # Friendly labels
    $script:DocLabel = @{
        'invoice' = 'Invoice'; 'creditnote' = 'Credit Note'
        'invoice-self-billing' = 'Invoice (Self-Billing)'; 'creditnote-self-billing' = 'Credit Note (Self-Billing)'
        'order' = 'Order'; 'order-response' = 'Order Response'; 'order-response-advanced' = 'Order Response (Advanced)'
        'order-change' = 'Order Change'; 'order-cancellation' = 'Order Cancellation'; 'order-agreement' = 'Order Agreement'
        'catalogue' = 'Catalogue'; 'catalogue-response' = 'Catalogue Response'
        'despatch-advice' = 'Despatch Advice'; 'mlr' = 'Message Level Response'
        'punch-out' = 'Punch Out'; 'invoice-message-response' = 'Invoice Message Response'
    }
    # poacc transaction CustomizationID token -> artifact (ordered: most specific first)
    $script:TrnsRules = @(
        @{ Token = 'poacc:trns:order_response_advanced:3';   Artifact = 'order-response-advanced' }
        @{ Token = 'poacc:trns:order_response:3';            Artifact = 'order-response' }
        @{ Token = 'poacc:trns:order_change:3';              Artifact = 'order-change' }
        @{ Token = 'poacc:trns:order_cancellation:3';        Artifact = 'order-cancellation' }
        @{ Token = 'poacc:trns:order_agreement:3';           Artifact = 'order-agreement' }
        @{ Token = 'poacc:trns:order:3';                     Artifact = 'order' }
        @{ Token = 'poacc:trns:despatch_advice:3';           Artifact = 'despatch-advice' }
        @{ Token = 'poacc:trns:catalogue_response:3';        Artifact = 'catalogue-response' }
        @{ Token = 'poacc:trns:punch_out:3';                 Artifact = 'punch-out' }
        @{ Token = 'poacc:trns:catalogue:3';                 Artifact = 'catalogue' }
        @{ Token = 'poacc:trns:invoice_message_response:3';  Artifact = 'invoice-message-response' }
        @{ Token = 'poacc:trns:mlr:3';                       Artifact = 'mlr' }
    )

    $script:Files = New-Object System.Collections.Generic.List[string]
    $script:Valid = 0; $script:Invalid = 0; $script:Tech = 0; $script:NonStandard = 0

    # --- optional config.json: self-hosted endpoint + ruleset overrides ---
    # DEFAULT is the public Helger service; config is opt-in. Lets you point at a local
    # phive-ws (no data leaves the network, no rate limit) and/or pin VESID versions without
    # editing this script. Discovery order (first that exists wins):
    #   1. -ConfigPath (explicit)
    #   2. ~/.peppol-validation/config.json  (written by Set-PeppolConfig.ps1 / the installer)
    #   3. config.json next to the skill (manual / dev)
    # Explicit -Endpoint / -VesId on the command line still win over the file.
    $cfgCandidates = New-Object System.Collections.Generic.List[string]
    if ($ConfigPath) { $cfgCandidates.Add($ConfigPath) }
    $cfgCandidates.Add((Join-Path $HOME '.peppol-validation/config.json'))
    $cfgCandidates.Add((Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json'))
    $cfgFile = $null
    foreach ($c in $cfgCandidates) { if ($c -and (Test-Path -LiteralPath $c)) { $cfgFile = $c; break } }
    if ($cfgFile) {
        try {
            $cfg = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json
        } catch {
            throw "config.json is not valid JSON ($cfgFile): $($_.Exception.Message)"
        }
        if ($cfg.endpoint -and -not $PSBoundParameters.ContainsKey('Endpoint')) {
            $Endpoint = [string]$cfg.endpoint
        }
        if ($cfg.vesByArtifact) {
            foreach ($prop in $cfg.vesByArtifact.PSObject.Properties) {
                if ($prop.Name -notmatch '^_') { $script:VesByArtifact[$prop.Name] = [string]$prop.Value }
            }
        }
        Write-Host "[config] Loaded $cfgFile (endpoint: $Endpoint)" -ForegroundColor DarkGray
    }

    if ($ReportFolder) { New-Item -ItemType Directory -Force -Path $ReportFolder | Out-Null }

    function Get-Artifact {
        param([string] $RootName, [string] $CustId)
        # Returns the Peppol BIS 3.0 artifact key, or $null if not our standard.
        if ($CustId -like '*poacc:selfbilling:3.0*') {
            if ($RootName -eq 'CreditNote') { return 'creditnote-self-billing' }
            return 'invoice-self-billing'
        }
        if ($CustId -like '*poacc:billing:3.0*') {
            if ($RootName -eq 'CreditNote') { return 'creditnote' }
            return 'invoice'
        }
        foreach ($r in $script:TrnsRules) {
            if ($CustId -like ('*' + $r.Token + '*')) { return $r.Artifact }
        }
        return $null
    }

    function Invoke-Validation {
        param([string] $RawXml, [string] $Ves, [string] $ResponseFile)
        $body = [regex]::Replace($RawXml, '^\s*<\?xml[^>]*\?>\s*', '')
        if ($body.Contains(']]>')) {
            $inner = '<ws:XML>' + [System.Security.SecurityElement]::Escape($body) + '</ws:XML>'
        } else {
            $inner = '<ws:XML><![CDATA[' + $body + ']]></ws:XML>'
        }
        $envelope = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" ' +
                    'xmlns:ws="http://peppol.helger.com/ws/documentvalidationservice/201701/"><soapenv:Body>' +
                    '<ws:validateRequestInput VESID="' + $Ves + '" displayLocale="en">' + $inner +
                    '</ws:validateRequestInput></soapenv:Body></soapenv:Envelope>'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($envelope)
        # Retry on rate-limiting / transient service errors (429/503) with backoff.
        $resp = $null; $attempt = 0; $maxAttempts = 4
        while ($true) {
            $attempt++
            try {
                $resp = Invoke-WebRequest -Uri $Endpoint -Method Post -ContentType 'text/xml; charset=utf-8' `
                    -Headers @{ SOAPAction = 'validate' } -Body $bytes -UseBasicParsing -TimeoutSec 120
                break
            } catch {
                $status = 0
                if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
                if (($status -eq 429 -or $status -eq 503) -and $attempt -lt $maxAttempts) {
                    $wait = 3 * $attempt
                    Write-Host "    (service busy: HTTP $status - retrying in ${wait}s, attempt $attempt/$maxAttempts)" -ForegroundColor DarkYellow
                    Start-Sleep -Seconds $wait
                    continue
                }
                throw
            }
        }
        if ($ResponseFile) {
            [System.IO.File]::WriteAllText($ResponseFile, $resp.Content, (New-Object System.Text.UTF8Encoding($false)))
        }

        $rx = New-Object System.Xml.XmlDocument
        $rx.LoadXml($resp.Content)
        $nsm = New-Object System.Xml.XmlNamespaceManager($rx.NameTable)
        $nsm.AddNamespace('v', 'http://peppol.helger.com/ws/documentvalidationservice/201701/')
        $out = $rx.SelectSingleNode('//v:validateResponseOutput', $nsm)
        if (-not $out) { throw "Unexpected response from validation service." }

        $errors = New-Object System.Collections.Generic.List[string]
        $warnings = New-Object System.Collections.Generic.List[string]
        $artefacts = New-Object System.Collections.Generic.List[string]
        foreach ($res in $rx.SelectNodes('//v:validateResponseOutput/v:Result', $nsm)) {
            $artefacts.Add($res.GetAttribute('artifactPath'))
        }
        foreach ($item in $rx.SelectNodes('//v:validateResponseOutput/v:Result/v:Item', $nsm)) {
            $lvl = $item.GetAttribute('errorLevel')
            $id = $item.GetAttribute('errorID')
            $fld = $item.GetAttribute('errorFieldName')
            $txt = $item.GetAttribute('errorText')
            $msg = "[$id] $txt"
            if ($fld) { $msg += "`n        @ $fld" }
            if ($lvl -eq 'ERROR') { $errors.Add($msg) } elseif ($lvl -eq 'WARN') { $warnings.Add($msg) }
        }
        return [pscustomobject]@{
            Success    = ($out.GetAttribute('success') -eq 'true')
            MostSevere = $out.GetAttribute('mostSevereErrorLevel')
            Errors     = $errors
            Warnings   = $warnings
            Artefacts  = $artefacts
        }
    }

    function Expand-Inputs {
        param([string] $P)
        if (Test-Path -LiteralPath $P -PathType Container) {
            return Get-ChildItem -LiteralPath $P -Filter *.xml -File | Select-Object -ExpandProperty FullName
        }
        if (Test-Path -LiteralPath $P) {
            return (Get-Item -LiteralPath $P).FullName
        }
        # treat as wildcard
        return Get-ChildItem -Path $P -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    }
}

process {
    foreach ($p in $Path) {
        $expanded = @(Expand-Inputs -P $p)
        if ($expanded.Count -eq 0) {
            Write-Host "[SKIP] No file(s) found for: $p" -ForegroundColor DarkYellow
            $script:Tech++
            continue
        }
        foreach ($f in $expanded) { $script:Files.Add($f) }
    }
}

end {
    if ($script:Files.Count -eq 0 -and $script:Tech -eq 0) {
        Write-Host "No input files." -ForegroundColor Red
        exit 2
    }

    $isPublic = ($Endpoint -like '*helger.com*')
    $idx = 0
    foreach ($file in $script:Files) {
        $idx++
        # Be polite to the shared public service between files (fair use).
        if ($isPublic -and $idx -gt 1) { Start-Sleep -Milliseconds 800 }
        $name = Split-Path $file -Leaf
        Write-Host ""
        Write-Host "=== $name ===" -ForegroundColor White

        # --- load + identify ---
        try {
            $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8
            $doc = New-Object System.Xml.XmlDocument
            $doc.PreserveWhitespace = $true
            $doc.LoadXml($raw)
        } catch {
            Write-Host "  [ERROR] Not well-formed XML: $($_.Exception.Message)" -ForegroundColor Red
            $script:Tech++
            continue
        }

        $root = $doc.DocumentElement.LocalName
        $custNode = $doc.DocumentElement.SelectSingleNode("*[local-name()='CustomizationID']")
        $custId = ''
        if ($custNode) { $custId = $custNode.InnerText.Trim() }

        if ($VesId) {
            $ves = $VesId
            $label = "(forced VESID)"
            Write-Host "  Type:     $root" -ForegroundColor Gray
            Write-Host "  Ruleset:  $ves  $label" -ForegroundColor Gray
        } else {
            $artifact = Get-Artifact -RootName $root -CustId $custId
            Write-Host "  Type:     $root  ($custId)" -ForegroundColor Gray
            if (-not $artifact) {
                Write-Host "  Standard: [WARN] NOT a recognized Peppol BIS 3.0 document - unknown CustomizationID." -ForegroundColor Yellow
                Write-Host "            Cannot auto-select a ruleset. Re-run with -VesId <id> to validate anyway." -ForegroundColor Yellow
                $script:NonStandard++
                continue
            }
            $ves = $script:VesByArtifact[$artifact]
            $lbl = $script:DocLabel[$artifact]
            Write-Host "  Standard: [OK] Peppol BIS 3.0 - $lbl" -ForegroundColor Green
            Write-Host "  Ruleset:  $ves" -ForegroundColor Gray
        }

        # --- validate ---
        $reportFile = $null
        if ($ReportFolder) { $reportFile = Join-Path $ReportFolder ($name + '.validation.xml') }
        try {
            $r = Invoke-Validation -RawXml $raw -Ves $ves -ResponseFile $reportFile
        } catch {
            Write-Host "  [ERROR] Validation service problem: $($_.Exception.Message)" -ForegroundColor Red
            $script:Tech++
            continue
        }

        if ($r.Warnings.Count -gt 0) {
            Write-Host "  Warnings: $($r.Warnings.Count)" -ForegroundColor Yellow
            foreach ($w in $r.Warnings) { Write-Host "    - $w" -ForegroundColor Yellow }
        }
        if ($r.Errors.Count -eq 0) {
            Write-Host "  Result:   [OK] valid - no errors" -ForegroundColor Green
            $script:Valid++
        } else {
            Write-Host "  Result:   [FAIL] $($r.Errors.Count) error(s)" -ForegroundColor Red
            foreach ($e in $r.Errors) { Write-Host "    - $e" -ForegroundColor Red }
            $script:Invalid++
        }
    }

    # --- summary ---
    Write-Host ""
    $total = $script:Valid + $script:Invalid + $script:NonStandard + $script:Tech
    Write-Host ("Summary: {0} file(s) - {1} valid, {2} with errors, {3} non-standard, {4} technical" -f `
        $total, $script:Valid, $script:Invalid, $script:NonStandard, $script:Tech) -ForegroundColor Cyan

    if ($script:Tech -gt 0) { exit 2 }
    elseif ($script:Invalid -gt 0) { exit 1 }
    elseif ($script:NonStandard -gt 0) { exit 3 }
    else { exit 0 }
}
