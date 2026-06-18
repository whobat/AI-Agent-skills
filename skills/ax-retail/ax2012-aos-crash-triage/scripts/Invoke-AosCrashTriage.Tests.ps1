#requires -Version 7.0
# Pester 5 tests for Invoke-AosCrashTriage.ps1
#   Invoke-Pester ./Invoke-AosCrashTriage.Tests.ps1 -Output Detailed

BeforeAll {
  . $PSScriptRoot/Invoke-AosCrashTriage.ps1

  function New-TestCredential {
    [pscredential]::new('TIER\admin', (ConvertTo-SecureString 'pw' -AsPlainText -Force))
  }
  $script:AosMsg = 'Faulting application name: Ax32Serv.exe, version: 6.3.6000.7046, time stamp: 0x5b8922f7' + "`n" +
  'Faulting module name: KERNELBASE.dll, version: 10.0.14393' + "`n" +
  'Exception code: 0xc0000005' + "`n" + 'Fault offset: 0x0000000000026ea8'
  $script:ClientMsg = 'Faulting application name: Ax32.exe, version: 6.3.6000.7046' + "`n" +
  'Faulting module name: KERNELBASE.dll' + "`n" + 'Exception code: 0xc0000005'
}

Describe 'Read-HostListFile / Resolve-Hosts' {
  It 'parses a list file, skipping comments and blanks' {
    $f = Join-Path $TestDrive 'a.txt'
    Set-Content -LiteralPath $f -Value @('AOS01', '  AOS02 ', '', '# note', 'AOS03 # inline')
    (@(Read-HostListFile -Path $f)) | Should -Be @('AOS01', 'AOS02', 'AOS03')
  }
  It 'merges inline + file and de-duplicates' {
    $f = Join-Path $TestDrive 'b.txt'
    Set-Content -LiteralPath $f -Value @('AOS02', 'AOS03')
    (@(Resolve-Hosts -Name @('AOS01', 'AOS02') -ListFile $f)) | Should -Be @('AOS01', 'AOS02', 'AOS03')
  }
  It 'throws on a missing file' { { Read-HostListFile -Path (Join-Path $TestDrive 'no.txt') } | Should -Throw }
}

Describe 'Get-FaultFields' {
  It 'extracts app/module/exception/offset and decodes the exception class' {
    $f = Get-FaultFields $script:AosMsg
    $f.app | Should -Be 'Ax32Serv.exe'
    $f.module | Should -Be 'KERNELBASE.dll'
    $f.exception | Should -Be '0xc0000005'
    $f.exception_meaning | Should -Match 'access violation'
    $f.offset | Should -Be '0x0000000000026ea8'
  }
  It 'returns nulls for a non-matching message' {
    (Get-FaultFields 'nothing here').app | Should -BeNullOrEmpty
  }
}

Describe 'Get-ExceptionMeaning' {
  It 'decodes the common AOS exception codes' {
    (Get-ExceptionMeaning '0xc0000005') | Should -Match 'access violation'
    (Get-ExceptionMeaning '0xc0000374') | Should -Match 'heap corruption'
    (Get-ExceptionMeaning '0xdeadbeef') | Should -Match 'reference'
  }
}

Describe 'Get-DumpReadiness' {
  It 'flags not-ready when WER LocalDumps is absent' {
    (Get-DumpReadiness $null).ready | Should -BeFalse
    (Get-DumpReadiness ([pscustomobject]@{ key_present = $false })).ready | Should -BeFalse
  }
  It 'recognises the AX-recommended DumpType=0 / CustomDumpFlags=0x1B67 config' {
    $w = [pscustomobject]@{ key_present = $true; dump_type = '0'; custom_dump_flags = '0x1B67' }
    $r = Get-DumpReadiness $w
    $r.ready | Should -BeTrue
    $r.note | Should -Match '0x1B67'
  }
  It 'warns when a mini/full dump type is configured instead' {
    $w = [pscustomobject]@{ key_present = $true; dump_type = '2'; custom_dump_flags = $null }
    $r = Get-DumpReadiness $w
    $r.ready | Should -BeTrue
    $r.note | Should -Match 'DumpType=2'
  }
}

Describe 'Test-IsAosCrash / Test-IsClientCrash' {
  It 'classifies an Ax32Serv message as an AOS crash, not a client crash' {
    (Test-IsAosCrash $script:AosMsg) | Should -BeTrue
    (Test-IsClientCrash $script:AosMsg) | Should -BeFalse
  }
  It 'classifies an Ax32.exe message as a client crash, not an AOS crash' {
    (Test-IsClientCrash $script:ClientMsg) | Should -BeTrue
    (Test-IsAosCrash $script:ClientMsg) | Should -BeFalse
  }
}

Describe 'Build-CrashTimeline' {
  It 'merges the two crash classes + SCM terminations, sorted by time, tagged by class' {
    $aos = @(
      [pscustomobject]@{ computer = 'A'; access_violations = @([pscustomobject]@{ t = '2026-06-17T09:03:00Z'; exception = '0xc0000005'; module = 'KERNELBASE.dll' }); forced_terminations = @([pscustomobject]@{ t = '2026-06-17T09:11:00Z' }); scm_terminations = @() }
      [pscustomobject]@{ computer = 'B'; access_violations = @([pscustomobject]@{ t = '2026-06-17T08:33:00Z'; exception = '0xc0000005'; module = 'x' }); forced_terminations = @(); scm_terminations = @() }
    )
    $tl = @(Build-CrashTimeline -AosHosts $aos)
    $tl.Count | Should -Be 3
    $tl[0].computer | Should -Be 'B'                 # earliest first
    $tl[0].class | Should -Be 'access_violation'
    (@($tl | Where-Object { $_.class -eq 'forced_termination' })).Count | Should -Be 1
  }
}

Describe 'Get-CascadeCorrelation' {
  It 'counts client crashes within the window of each AOS event' {
    $tl = @([pscustomobject]@{ computer = 'A'; type = 'aos_terminated'; time = '2026-06-17T09:11:20Z'; detail = $null })
    $clients = @(
      [pscustomobject]@{ computer = 'WTS1'; t = '2026-06-17T09:11:19Z' }  # in window
      [pscustomobject]@{ computer = 'WTS2'; t = '2026-06-17T09:11:25Z' }  # in window
      [pscustomobject]@{ computer = 'WTS3'; t = '2026-06-17T10:00:00Z' }  # far away
    )
    $c = @(Get-CascadeCorrelation -Timeline $tl -ClientCrashes $clients -WindowSeconds 120)
    $c[0].client_crashes_in_window | Should -Be 2
    $c[0].client_hosts | Should -Contain 'WTS1'
    $c[0].client_hosts | Should -Not -Contain 'WTS3'
  }
  It 'returns empty when the timeline is empty' {
    (@(Get-CascadeCorrelation -Timeline @() -ClientCrashes @() -WindowSeconds 60)).Count | Should -Be 0
  }
}

Describe 'Format-AosHost' {
  It 'keeps the two crash classes separate and labels Event 180 as a by-design symptom' {
    $raw = [pscustomobject]@{
      computer = 'AOS01'; status = 'ok'; error = $null; hint = $null; services = @(); lastboot = $null
      wer = [pscustomobject]@{ key_present = $false }; hotfixes = @()
      events_scanned = 4; truncated = $false
      records = @(
        [pscustomobject]@{ Log = 'Application'; Id = 1000; Provider = 'Application Error'; TimeUtc = '2026-06-17T09:03:00Z'; Msg = $script:AosMsg }
        [pscustomobject]@{ Log = 'System'; Id = 7031; Provider = 'Service Control Manager'; TimeUtc = '2026-06-17T09:11:00Z'; Msg = 'The Microsoft Dynamics AX Object Server ... terminated unexpectedly' }
        [pscustomobject]@{ Log = 'Application'; Id = 110; Provider = 'Dynamics Server 01'; TimeUtc = '2026-06-17T09:02:55Z'; Msg = 'Session Allocation Failed: Session 277 is already allocated.' }
        [pscustomobject]@{ Log = 'Application'; Id = 180; Provider = 'Dynamics Server 01'; TimeUtc = '2026-06-17T09:02:50Z'; Msg = 'RPC error: Client provided an invalid session ID 508' }
      )
    }
    $h = Format-AosHost -Raw $raw
    $h.role | Should -Be 'aos'
    # Event 1000 -> access_violation (distinct class), with the offset preserved
    @($h.access_violations).Count | Should -Be 1
    $h.access_violations[0].crash_class | Should -Be 'access_violation'
    $h.access_violations[0].offset | Should -Be '0x0000000000026ea8'
    # Event 110 -> forced_termination, NOT merged with the access violation
    @($h.forced_terminations).Count | Should -Be 1
    $h.forced_terminations[0].note | Should -Match 'not the deep root cause'
    # Event 7031 -> scm termination
    @($h.scm_terminations).Count | Should -Be 1
    # Event 180 -> by-design symptom bucket, explicitly labelled
    $h.session_symptoms.count | Should -Be 1
    $h.session_symptoms.note | Should -Match 'BY-DESIGN'
    # dump readiness surfaced (WER absent here)
    $h.dump_readiness.ready | Should -BeFalse
  }
}

Describe 'Format-ClientHost' {
  It 'keeps only Ax32.exe client crashes' {
    $raw = [pscustomobject]@{
      computer = 'RDS01'; status = 'ok'; error = $null; hint = $null; events_scanned = 2; truncated = $false
      records = @(
        [pscustomobject]@{ Log = 'Application'; Id = 1000; Provider = 'Application Error'; TimeUtc = '2026-06-17T09:11:19Z'; Msg = $script:ClientMsg }
        [pscustomobject]@{ Log = 'Application'; Id = 1000; Provider = 'Application Error'; TimeUtc = '2026-06-17T09:03:00Z'; Msg = $script:AosMsg }  # AOS, ignored
      )
    }
    $h = Format-ClientHost -Raw $raw
    $h.client_crash_count | Should -Be 1
    $h.client_crashes[0].t | Should -Be '2026-06-17T09:11:19Z'
  }
}

Describe 'Get-FailureClassification' {
  It 'maps TrustedHosts to auth_failed with an FQDN hint' {
    $c = Get-FailureClassification -Message 'add to the TrustedHosts configuration setting'
    $c.status | Should -Be 'auth_failed'
    $c.hint | Should -Match 'FQDN'
  }
  It 'maps DNS failures to unreachable' {
    (Get-FailureClassification -Message 'The name cannot be resolved').status | Should -Be 'unreachable'
  }
}

Describe 'Get-OverallStatus' {
  It 'ok / partial / error' {
    Get-OverallStatus -Hosts @([pscustomobject]@{ status = 'ok' }) | Should -Be 'ok'
    Get-OverallStatus -Hosts @([pscustomobject]@{ status = 'ok' }, [pscustomobject]@{ status = 'unreachable' }) | Should -Be 'partial'
    Get-OverallStatus -Hosts @([pscustomobject]@{ status = 'auth_failed' }) | Should -Be 'error'
  }
}

Describe 'Invoke-HostCollect (mocked remoting)' {
  It 'returns ok and passes records through on success' {
    Mock Invoke-Command {
      [pscustomobject]@{
        Services = @(); LastBootUtc = '2026-06-17T00:00:00Z'
        Records = @([pscustomobject]@{ Log = 'Application'; Id = 1000; Provider = 'Application Error'; TimeUtc = '2026-06-17T09:03:00Z'; Msg = 'Ax32Serv.exe' })
        Scanned = 1; Truncated = $false
      }
    }
    $r = Invoke-HostCollect -Computer 'AOS01' -Credential (New-TestCredential) -Hours 24 -MaxEvents 100 -MaxMessageLength 50
    $r.status | Should -Be 'ok'
    $r.events_scanned | Should -Be 1
  }
  It 'maps access-denied to auth_failed' {
    Mock Invoke-Command { throw 'Access is denied' }
    (Invoke-HostCollect -Computer 'AOS01' -Hours 1 -MaxEvents 1 -MaxMessageLength 1).status | Should -Be 'auth_failed'
  }
}

Describe 'Invoke-FleetCollect (parallel fan-out plumbing)' {
  # Regression: the parallel loop was wrapped in a scriptblock invoked with '& $collect', which
  # made $using: variables fail at runtime ("A Using variable cannot be retrieved") - a bug unit
  # tests missed because Pester mocks can't cross -Parallel runspaces. This exercises the real
  # fan-out against a bogus host: the connection fails and is caught (status != ok), but the
  # $using: plumbing must resolve WITHOUT throwing the using-variable error.
  It 'returns empty for an empty target list (no remoting)' {
    @(Invoke-FleetCollect -Targets @() -Credential (New-TestCredential) -Hours 1 -MaxEvents 1 `
        -MaxMessageLength 1 -ThrottleLimit 1 -Authentication 'Default' -FuncDef 'x' -ClsDef 'y').Count | Should -Be 0
  }
  It 'runs the parallel loop without a using-variable error and returns a per-host result' {
    $r = Invoke-FleetCollect -Targets @('nonexistent.invalid.test') -Credential (New-TestCredential) `
      -Hours 1 -MaxEvents 1 -MaxMessageLength 1 -ThrottleLimit 1 -Authentication 'Default' `
      -FuncDef ${function:Invoke-HostCollect}.ToString() -ClsDef ${function:Get-FailureClassification}.ToString()
    @($r).Count | Should -Be 1
    $r[0].status | Should -Not -Be 'ok'   # unreachable/auth_failed/error - but NOT a using-variable throw
  }
}

Describe 'Remote block: server-side window + down-level safety' {
  BeforeAll {
    $script:Source = Get-Content (Join-Path $PSScriptRoot 'Invoke-AosCrashTriage.ps1') -Raw
    $m = [regex]::Match($script:Source, '(?s)\$remote\s*=\s*\{(.*?)\n  \}')
    $script:RemoteBlock = $m.Groups[1].Value
  }
  It 'computes the look-back window ON the target (no DateTime crosses the boundary)' {
    $script:RemoteBlock | Should -Match '\$since\s*=\s*\(Get-Date\)\.AddHours'
    # ArgumentList passes the integer hours, not a DateTime window.
    $script:Source | Should -Match 'ArgumentList = @\(\$Hours,'
  }
  It 'uses no ::new() and builds its list with New-Object (down-level safe)' {
    $script:RemoteBlock | Should -Not -Match '::new\('
    $script:RemoteBlock | Should -Match 'New-Object System\.Collections\.Generic\.List'
  }
}
