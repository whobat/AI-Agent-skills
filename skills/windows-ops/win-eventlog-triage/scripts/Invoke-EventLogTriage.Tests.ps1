#requires -Version 7.0
# Pester 5 tests for Invoke-EventLogTriage.ps1
#   Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser
#   Invoke-Pester ./Invoke-EventLogTriage.Tests.ps1
#
# Tests cover the deterministic logic (parsing, resolving, grouping, ranking,
# status, output shaping) plus Invoke-HostTriage with a mocked Invoke-Command.
# The parallel orchestrator itself is not unit-tested (mocks cannot cross
# ForEach-Object -Parallel runspace boundaries); its building blocks are.

BeforeAll {
  . $PSScriptRoot/Invoke-EventLogTriage.ps1

  function New-TestCredential {
    $sec = ConvertTo-SecureString 'pw' -AsPlainText -Force
    [pscredential]::new('TIER\admin', $sec)
  }

  function New-Record {
    param($Computer = 'SRV01', $Log = 'System', $Provider = 'SCM',
      $EventId = 7034, $Level = 'Error', $TimeCreatedUtc = '2026-06-08T10:00:00Z', $Message = 'svc crashed')
    [pscustomobject]@{
      Computer = $Computer; Log = $Log; Provider = $Provider; EventId = $EventId
      Level = $Level; TimeCreatedUtc = $TimeCreatedUtc; Message = $Message
    }
  }
}

Describe 'Read-ServerList' {
  It 'parses hostnames, skipping blanks and # comments and trimming whitespace' {
    $f = Join-Path $TestDrive 'hosts.txt'
    Set-Content -LiteralPath $f -Value @(
      'srv01',
      '  srv02  ',
      '',
      '# a comment',
      'srv03 # inline comment'
    )
    $r = @(Read-ServerList -Path $f)
    $r | Should -Be @('srv01', 'srv02', 'srv03')
  }

  It 'throws when the file does not exist' {
    { Read-ServerList -Path (Join-Path $TestDrive 'nope.txt') } | Should -Throw
  }
}

Describe 'Resolve-TargetComputers' {
  It 'merges -ComputerName and file, de-duplicating' {
    $f = Join-Path $TestDrive 'h2.txt'
    Set-Content -LiteralPath $f -Value @('srv02', 'srv03')
    $r = @(Resolve-TargetComputers -ComputerName @('srv01', 'srv02') -ServerListFile $f)
    $r | Should -Be @('srv01', 'srv02', 'srv03')
  }

  It 'works with only -ComputerName' {
    (@(Resolve-TargetComputers -ComputerName @('a', 'b'))).Count | Should -Be 2
  }
}

Describe 'Resolve-Levels' {
  It 'defaults to Critical+Error' { Resolve-Levels | Should -Be @(1, 2) }
  It 'adds Warning with -IncludeWarning' { Resolve-Levels -IncludeWarning | Should -Be @(1, 2, 3) }
  It 'lets explicit -Level win' { Resolve-Levels -Level @(1) -IncludeWarning | Should -Be @(1) }
}

Describe 'Resolve-Logs' {
  It 'defaults to System+Application' { Resolve-Logs -Logs @('System', 'Application') | Should -Be @('System', 'Application') }
  It 'adds Security when requested, without duplicating' {
    Resolve-Logs -Logs @('System') -IncludeSecurity | Should -Be @('System', 'Security')
    Resolve-Logs -Logs @('Security') -IncludeSecurity | Should -Be @('Security')
  }
}

Describe 'Remote scriptblock down-level compatibility' {
  # The scriptblock passed to Invoke-Command runs ON THE TARGET, whose Windows
  # PowerShell can be as old as 2.0-4.0 (Server 2008/2012). It must avoid PS 5.0+
  # syntax. Regression guard for the field bug where ::new() failed on a
  # Server 2012 R2 box running PS 4.0.
  BeforeAll {
    $script:Source = Get-Content (Join-Path $PSScriptRoot 'Invoke-EventLogTriage.ps1') -Raw
    # Extract the $remote = { ... } scriptblock body.
    $m = [regex]::Match($script:Source, '(?s)\$remote\s*=\s*\{(.*?)\n  \}')
    $script:RemoteBlock = $m.Groups[1].Value
  }

  It 'extracted the remote scriptblock' {
    $script:RemoteBlock | Should -Not -BeNullOrEmpty
    $script:RemoteBlock | Should -Match 'Get-WinEvent'
  }

  It 'uses no ::new() constructor syntax (PS 5.0+) in the remote block' {
    $script:RemoteBlock | Should -Not -Match '::new\('
  }

  It 'builds its list with New-Object (down-level safe)' {
    $script:RemoteBlock | Should -Match 'New-Object System\.Collections\.Generic\.List'
  }
}

Describe 'Resolve-TimeWindow' {
  BeforeAll { $now = [datetime]'2026-06-08T12:00:00' }

  It 'uses -Hours by default' {
    $w = Resolve-TimeWindow -Hours 24 -Now $now
    $w.StartTime | Should -Be ([datetime]'2026-06-07T12:00:00')
    $w.EndTime | Should -Be $now
  }

  It 'honors -Since over -Hours' {
    $w = Resolve-TimeWindow -Hours 24 -Since ([datetime]'2026-06-01') -Now $now
    $w.StartTime | Should -Be ([datetime]'2026-06-01')
  }

  It 'honors -From/-To over everything' {
    $w = Resolve-TimeWindow -Hours 24 -From ([datetime]'2026-06-02') -To ([datetime]'2026-06-03') -Now $now
    $w.StartTime | Should -Be ([datetime]'2026-06-02')
    $w.EndTime | Should -Be ([datetime]'2026-06-03')
  }

  It 'throws when start is after end' {
    { Resolve-TimeWindow -From ([datetime]'2026-06-03') -To ([datetime]'2026-06-02') -Now $now } | Should -Throw
  }
}

Describe 'Get-SuppressSet / Test-Suppressed' {
  It 'returns an empty set when no path is given' {
    $s = Get-SuppressSet
    $s.eventIds.Count | Should -Be 0
    $s.providers.Count | Should -Be 0
  }

  It 'loads eventIds and providers from JSON' {
    $f = Join-Path $TestDrive 'sup.json'
    '{ "eventIds": [7036], "providers": ["Noisy"] }' | Set-Content -LiteralPath $f
    $s = Get-SuppressSet -Path $f
    $s.eventIds | Should -Contain 7036
    $s.providers | Should -Contain 'Noisy'
  }

  It 'suppresses by event id and by provider, not otherwise' {
    $s = [pscustomobject]@{ eventIds = @(7036); providers = @('Noisy') }
    (Test-Suppressed -Group ([pscustomobject]@{ event_id = 7036; provider = 'X' }) -Suppress $s) | Should -BeTrue
    (Test-Suppressed -Group ([pscustomobject]@{ event_id = 1; provider = 'Noisy' }) -Suppress $s) | Should -BeTrue
    (Test-Suppressed -Group ([pscustomobject]@{ event_id = 1; provider = 'X' }) -Suppress $s) | Should -BeFalse
  }
}

Describe 'Group-EventRecords' {
  It 'aggregates duplicates with count, first/last seen and a sample' {
    $records = @(
      New-Record -TimeCreatedUtc '2026-06-08T10:00:00Z' -Message 'first'
      New-Record -TimeCreatedUtc '2026-06-08T11:00:00Z' -Message 'second'
      New-Record -EventId 1000 -Provider 'AppX' -Level 'Critical' -TimeCreatedUtc '2026-06-08T09:00:00Z'
    )
    $g = @(Group-EventRecords -Records $records -Suppress (Get-SuppressSet))
    $g.Count | Should -Be 2
    $scm = $g | Where-Object { $_.event_id -eq 7034 }
    $scm.count | Should -Be 2
    $scm.first_seen | Should -Be '2026-06-08T10:00:00Z'
    $scm.last_seen | Should -Be '2026-06-08T11:00:00Z'
    $scm.sample_message | Should -Be 'first'
  }

  It 'drops suppressed groups' {
    $records = @(New-Record -EventId 7036)
    $sup = [pscustomobject]@{ eventIds = @(7036); providers = @() }
    (@(Group-EventRecords -Records $records -Suppress $sup)).Count | Should -Be 0
  }

  It 'returns empty for no records' {
    (@(Group-EventRecords -Records @() -Suppress (Get-SuppressSet))).Count | Should -Be 0
  }
}

Describe 'Select-TopCritical' {
  It 'orders Critical before Error, then by count, then by recency' {
    $groups = @(
      [pscustomobject]@{ level = 'Error'; count = 100; last_seen = '2026-06-08T10:00:00Z'; event_id = 1 }
      [pscustomobject]@{ level = 'Critical'; count = 1; last_seen = '2026-06-08T10:00:00Z'; event_id = 2 }
      [pscustomobject]@{ level = 'Error'; count = 100; last_seen = '2026-06-08T12:00:00Z'; event_id = 3 }
    )
    $top = Select-TopCritical -Groups $groups -Top 10
    $top[0].event_id | Should -Be 2     # Critical wins regardless of count
    $top[1].event_id | Should -Be 3     # same level+count -> more recent first
    $top[2].event_id | Should -Be 1
  }

  It 'respects the Top limit' {
    $groups = 1..5 | ForEach-Object { [pscustomobject]@{ level = 'Error'; count = $_; last_seen = '2026-06-08T10:00:00Z'; event_id = $_ } }
    (Select-TopCritical -Groups $groups -Top 2).Count | Should -Be 2
  }
}

Describe 'Get-OverallStatus' {
  It 'is ok when all hosts ok' {
    Get-OverallStatus -Hosts @([pscustomobject]@{ status = 'ok' }, [pscustomobject]@{ status = 'ok' }) | Should -Be 'ok'
  }
  It 'is partial on mixed results' {
    Get-OverallStatus -Hosts @([pscustomobject]@{ status = 'ok' }, [pscustomobject]@{ status = 'unreachable' }) | Should -Be 'partial'
  }
  It 'is error when all hosts failed' {
    Get-OverallStatus -Hosts @([pscustomobject]@{ status = 'auth_failed' }) | Should -Be 'error'
  }
}

Describe 'ConvertTo-CompactResult' {
  It 'keeps summary/status but drops per-host detail' {
    $full = [pscustomobject]@{
      status = 'ok'; generated_at = 'x'; query = @{}; hosts = @(1, 2, 3)
      summary = [pscustomobject]@{ hosts_total = 3 }
    }
    $c = ConvertTo-CompactResult -Full $full
    $c.summary.hosts_total | Should -Be 3
    ($c.PSObject.Properties.Name) | Should -Not -Contain 'hosts'
  }
}

Describe 'Get-FailureClassification' {
  It 'maps a TrustedHosts error to auth_failed with a hint' {
    $c = Get-FailureClassification -Message 'WinRM cannot process the request ... add to the TrustedHosts configuration setting'
    $c.status | Should -Be 'auth_failed'
    $c.hint | Should -Match 'TrustedHosts'
  }
  It 'maps Kerberos 0x80090311 (no domain authority) to auth_failed with a hint' {
    $c = Get-FailureClassification -Message 'error code 0x80090311 occurred while using Kerberos authentication'
    $c.status | Should -Be 'auth_failed'
    $c.hint | Should -Match 'domain-joined|Kerberos'
  }
  It 'maps access denied to auth_failed' {
    (Get-FailureClassification -Message 'Access is denied').status | Should -Be 'auth_failed'
  }
  It 'maps DNS/connection errors to unreachable' {
    (Get-FailureClassification -Message 'The name cannot be resolved').status | Should -Be 'unreachable'
  }
  It 'falls back to error for unknown messages' {
    $c = Get-FailureClassification -Message 'something weird'
    $c.status | Should -Be 'error'
    $c.hint | Should -BeNullOrEmpty
  }
}

Describe 'Get-AdminCredential' {
  It 'returns the provided credential without prompting' {
    $cred = New-TestCredential
    (Get-AdminCredential -Provided $cred).UserName | Should -Be 'TIER\admin'
  }
}

Describe 'Invoke-HostTriage' {
  It 'returns ok and maps records on success' {
    Mock Invoke-Command {
      [pscustomobject]@{
        Records   = @([pscustomobject]@{ Computer = 'SRV01'; Log = 'System'; Provider = 'SCM'; EventId = 7034; Level = 'Error'; TimeCreatedUtc = '2026-06-08T10:00:00Z'; Message = 'x' })
        Scanned   = 1
        Truncated = $false
      }
    }
    $r = Invoke-HostTriage -Computer 'SRV01' -Credential (New-TestCredential) -Logs @('System') -Levels @(1, 2) -StartTime (Get-Date) -EndTime (Get-Date) -MaxEvents 100 -MaxMessageLength 50
    $r.status | Should -Be 'ok'
    $r.events_scanned | Should -Be 1
    $r.records.Count | Should -Be 1
  }

  It 'maps access-denied to auth_failed' {
    Mock Invoke-Command { throw 'Access is denied' }
    (Invoke-HostTriage -Computer 'SRV01' -Logs @('System') -Levels @(1) -StartTime (Get-Date) -EndTime (Get-Date) -MaxEvents 1 -MaxMessageLength 1).status | Should -Be 'auth_failed'
  }

  It 'maps WinRM/connection errors to unreachable' {
    Mock Invoke-Command { throw 'The WinRM client cannot complete the operation' }
    (Invoke-HostTriage -Computer 'SRV01' -Logs @('System') -Levels @(1) -StartTime (Get-Date) -EndTime (Get-Date) -MaxEvents 1 -MaxMessageLength 1).status | Should -Be 'unreachable'
  }

  It 'maps other failures to error' {
    Mock Invoke-Command { throw 'something weird' }
    (Invoke-HostTriage -Computer 'SRV01' -Logs @('System') -Levels @(1) -StartTime (Get-Date) -EndTime (Get-Date) -MaxEvents 1 -MaxMessageLength 1).status | Should -Be 'error'
  }
}
