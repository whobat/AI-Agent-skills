#requires -Version 7.0
# Pester 5 tests for Invoke-RdsProfileTriage.ps1
#   Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser
#   Invoke-Pester -Path ./skills/windows-ops/rds-profile-triage/scripts/Invoke-RdsProfileTriage.Tests.ps1 -Output Detailed
#
# Covers the deterministic, remoting-free helpers — especially the two pieces of
# logic that exist to stop the misdiagnoses this skill was born from:
#   - Get-ProfileUserClass (don't blame a double-hop / service account on real users)
#   - Test-ProfileListCorruption (the "Element not found" -> WSMan host-launch chain)
# The remote collector and DCOM collector are not unit-tested (they require a live
# host); their pure inputs/outputs are exercised here.

BeforeAll {
  . $PSScriptRoot/Invoke-RdsProfileTriage.ps1
}

Describe 'Read-ServerList' {
  It 'parses hostnames, skipping blanks and # comments, trimming whitespace' {
    $f = Join-Path $TestDrive 'hosts.txt'
    Set-Content -LiteralPath $f -Value @('rds01', '  rds02 ', '', '# note', 'rds03 # inline')
    @(Read-ServerList -Path $f) | Should -Be @('rds01', 'rds02', 'rds03')
  }
  It 'throws when the file is missing' {
    { Read-ServerList -Path (Join-Path $TestDrive 'nope.txt') } | Should -Throw
  }
}

Describe 'Resolve-TimeWindow' {
  BeforeAll { $now = [datetime]'2026-06-15T12:00:00' }
  It 'defaults to -Hours back from now' {
    $w = Resolve-TimeWindow -Hours 24 -Now $now
    $w.From | Should -Be ([datetime]'2026-06-14T12:00:00'); $w.To | Should -Be $now
  }
  It '-Since overrides -Hours' {
    $w = Resolve-TimeWindow -Hours 24 -Since ([datetime]'2026-06-10T00:00:00') -Now $now
    $w.From | Should -Be ([datetime]'2026-06-10T00:00:00')
  }
  It 'swaps an inverted -From/-To so From is never later than To' {
    $w = Resolve-TimeWindow -From ([datetime]'2026-06-10') -To ([datetime]'2026-06-01') -Now $now
    $w.From | Should -Be ([datetime]'2026-06-01'); $w.To | Should -Be ([datetime]'2026-06-10')
  }
  It '-From/-To win outright' {
    $w = Resolve-TimeWindow -From ([datetime]'2026-06-01') -To ([datetime]'2026-06-02') -Now $now
    $w.From | Should -Be ([datetime]'2026-06-01'); $w.To | Should -Be ([datetime]'2026-06-02')
  }
}

Describe 'Get-ProfileUserClass (anti-misattribution)' {
  It 'flags the connecting credential as self_or_admin (double-hop suspect)' {
    Get-ProfileUserClass -UserName 'CONTOSO\opsadmin' -CredUserName 'CONTOSO\opsadmin' | Should -Be 'self_or_admin'
    Get-ProfileUserClass -UserName 'opsadmin' -CredUserName 'CONTOSO\opsadmin' | Should -Be 'self_or_admin'
  }
  It 'recognises service / backup / machine accounts' {
    Get-ProfileUserClass -UserName 'CONTOSO\svc-sql' -CredUserName 'CONTOSO\admin' | Should -Be 'service_account'
    Get-ProfileUserClass -UserName 'CONTOSO\svc-backup' -CredUserName 'CONTOSO\admin' | Should -Be 'service_account'
    Get-ProfileUserClass -UserName 'CONTOSO\veeamsvc' -CredUserName 'CONTOSO\admin' | Should -Be 'service_account'
    Get-ProfileUserClass -UserName 'CONTOSO\RDS01$' -CredUserName 'CONTOSO\admin' | Should -Be 'service_account'
  }
  It 'treats a normal human as interactive_user (the one that actually matters)' {
    Get-ProfileUserClass -UserName 'CONTOSO\jdoe' -CredUserName 'CONTOSO\admin' | Should -Be 'interactive_user'
  }
  It 'returns unknown for empty input' {
    Get-ProfileUserClass -UserName '' -CredUserName 'CONTOSO\admin' | Should -Be 'unknown'
  }
}

Describe 'Test-ProfileListCorruption (Element-not-found chain)' {
  It 'detects empty path, .bak, and temp-pointing entries' {
    $entries = @(
      [pscustomobject]@{ sid = 'S-1-5-21-1-1-1-1001'; path = 'C:\Users\jdoe'; state = 0 },
      [pscustomobject]@{ sid = 'S-1-5-21-1-1-1-1002'; path = ''; state = 0 },
      [pscustomobject]@{ sid = 'S-1-5-21-1-1-1-1003.bak'; path = 'C:\Users\TEMP.X.848'; state = 16640 },
      [pscustomobject]@{ sid = 'S-1-5-21-1-1-1-1004'; path = 'C:\Users\TEMP.X.999'; state = 16664 }
    )
    $r = Test-ProfileListCorruption -Entries $entries
    $r.total | Should -Be 4
    $r.empty_path | Should -Be 1
    $r.bak | Should -Be 1
    $r.temp_pointing | Should -Be 2
    @($r.corrupt).Count | Should -Be 3   # the healthy one is excluded
  }
  It 'returns zero corruption for a clean ProfileList' {
    $r = Test-ProfileListCorruption -Entries @([pscustomobject]@{ sid = 'S-1-5-21-1-1-1-500'; path = 'C:\Users\admin'; state = 0 })
    $r.empty_path | Should -Be 0; @($r.corrupt).Count | Should -Be 0
  }
}

Describe 'Get-ActiveSessionCount' {
  It 'counts only Active rows, ignoring the header and Disc rows' {
    $q = @(
      ' USERNAME   SESSIONNAME  ID  STATE   IDLE  LOGON',
      ' jdoe       rdp-tcp#1     2  Active   .    08:00',
      ' asmith                   3  Disc     5    07:00',
      ' bjones     rdp-tcp#2     4  Active   1    08:10'
    )
    Get-ActiveSessionCount -QuserLines $q | Should -Be 2
  }
  It 'returns 0 for null/empty' { Get-ActiveSessionCount -QuserLines $null | Should -Be 0 }
}

Describe 'Get-Findings (deterministic flags)' {
  It 'raises the host-launch + corruption + real-user findings with correct severities' {
    $hd = [pscustomobject]@{
      uptime_hours      = 100
      drain             = [pscustomobject]@{ accepting_logons = $true }
      disk              = [pscustomobject]@{ pct_free = 30; c_free_gb = 20 }
      hive_leak         = [pscustomobject]@{ loaded_user_hives = 21; active_sessions = 6; leaked = 15 }
      temp_profiles     = [pscustomobject]@{ count = 1138 }
      profilelist       = [pscustomobject]@{ empty_path = 3; bak = 2; temp_pointing = 2 }
      winrm_host_launch = [pscustomobject]@{ failing = $true; dcom10000_wsmprovhost = 12; winrm86 = 12 }
      profile_events    = @([pscustomobject]@{ user = 'CONTOSO\jdoe'; user_class = 'interactive_user' })
    }
    $f = Get-Findings -HostData $hd
    ($f | Where-Object severity -eq 'critical').Count | Should -BeGreaterThan 0
    ($f.finding -join ' ') | Should -Match 'ProfileList corruption'
    ($f.finding -join ' ') | Should -Match 'REAL interactive users'
  }
  It 'stays quiet on a healthy host' {
    $hd = [pscustomobject]@{
      uptime_hours      = 50
      drain             = [pscustomobject]@{ accepting_logons = $true }
      disk              = [pscustomobject]@{ pct_free = 40; c_free_gb = 30 }
      hive_leak         = [pscustomobject]@{ loaded_user_hives = 6; active_sessions = 6; leaked = 0 }
      temp_profiles     = [pscustomobject]@{ count = 1 }
      profilelist       = [pscustomobject]@{ empty_path = 0; bak = 0; temp_pointing = 0 }
      winrm_host_launch = [pscustomobject]@{ failing = $false; dcom10000_wsmprovhost = 0; winrm86 = 0 }
      profile_events    = @()
    }
    @(Get-Findings -HostData $hd).Count | Should -Be 0
  }
}

Describe 'Format-TriageReport (uniform deterministic output)' {
  BeforeAll {
    $script:rep = [pscustomobject]@{
      status       = 'partial'; generated_at = '2026-06-15T10:00:00Z'
      query        = [pscustomobject]@{ hosts = @('RDS01', 'RDS02'); from = 'A'; to = 'B'; protocol = 'WinRM' }
      caveats      = @('caveat-one', 'caveat-two')
      hosts        = @(
        [pscustomobject]@{
          computer = 'RDS01'; status = 'ok'; collection_method = 'winrm'; os = 'Server 2019'
          uptime_hours = 240; pending_reboot = $false
          disk = [pscustomobject]@{ pct_free = 23.1; c_free_gb = 18.3 }
          drain = [pscustomobject]@{ accepting_logons = $true; mode = 0 }
          hive_leak = [pscustomobject]@{ leaked = 15; loaded_user_hives = 21; active_sessions = 6 }
          temp_profiles = [pscustomobject]@{ count = 1138; sample = @([pscustomobject]@{ owner = 'BUILTIN\Administrators' }) }
          profilelist = [pscustomobject]@{ total = 16; empty_path = 3; bak = 2; temp_pointing = 2 }
          roaming_profile = [pscustomobject]@{ machine_profile_path_raw = '\\FS01\profiles$\%USERNAME%\RdsProfile' }
          winrm_host_launch = [pscustomobject]@{ failing = $false; dcom10000_wsmprovhost = 0; winrm86 = 0 }
          profile_events = @([pscustomobject]@{ count = 185; event_id = 1511; user = 'CONTOSO\svc-backup'; user_class = 'service_account' })
        },
        [pscustomobject]@{ computer = 'RDS02'; status = 'failed'; error = "could not launch a host process"; hint = 'Re-run with -Protocol Dcom.' }
      )
      summary      = [pscustomobject]@{
        hosts_total = 2; hosts_ok = 1; hosts_failed = 1
        failures = @([pscustomobject]@{ computer = 'RDS02'; status = 'failed'; error = 'could not launch a host process'; hint = 'Re-run with -Protocol Dcom.' })
        findings = @([pscustomobject]@{ computer = 'RDS01'; severity = 'high'; finding = 'ProfileList corruption: 3 empty-path' })
      }
    }
    $script:txt = Format-TriageReport -Report $script:rep
  }
  It 'emits the standard section headers' {
    $txt | Should -Match 'RDS PROFILE TRIAGE'
    $txt | Should -Match '== FINDINGS \(ranked\) =='
    $txt | Should -Match '== PER-HOST =='
    $txt | Should -Match '== CAVEATS \(apply before concluding\) =='
  }
  It 'renders findings with a severity tag and the host name' {
    $txt | Should -Match '\[HIGH\] \[RDS01\] ProfileList corruption'
  }
  It 'shows the RAW roaming path verbatim (no expansion) and the by-user event line' {
    $txt | Should -Match ([regex]::Escape('\\FS01\profiles$\%USERNAME%\RdsProfile'))
    $txt | Should -Match '185x  id 1511  CONTOSO\\svc-backup \[service_account\]'
  }
  It 'reports the failed host with its hint and a coverage-gaps section' {
    $txt | Should -Match 'RDS02: FAILED - could not launch a host process'
    $txt | Should -Match '== COVERAGE GAPS =='
    $txt | Should -Match 'Re-run with -Protocol Dcom'
  }
  It 'prints the OK line when there are no findings' {
    $clean = [pscustomobject]@{
      status = 'ok'; generated_at = 'x'; query = [pscustomobject]@{ hosts = @('RDS01'); from = 'A'; to = 'B'; protocol = 'WinRM' }
      caveats = @('c'); hosts = @(); summary = [pscustomobject]@{ hosts_total = 1; hosts_ok = 1; hosts_failed = 0; failures = @(); findings = @() }
    }
    (Format-TriageReport -Report $clean) | Should -Match 'OK - no issues flagged'
  }
}

Describe 'ConvertTo-CompactReport' {
  It 'keeps summary/caveats but drops per-host detail' {
    $full = [pscustomobject]@{
      status = 'ok'; generated_at = 'x'; query = @{}; summary = @{ hosts_total = 1 }
      caveats = @('c'); hosts = @([pscustomobject]@{ computer = 'RDS01' })
    }
    $c = ConvertTo-CompactReport -Report $full
    $c.summary | Should -Not -BeNullOrEmpty
    $c.caveats | Should -Not -BeNullOrEmpty
    $c.PSObject.Properties.Name | Should -Not -Contain 'hosts'
  }
}
