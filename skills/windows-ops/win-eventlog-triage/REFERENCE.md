# win-eventlog-triage — Reference

Detailed reference for `scripts/Invoke-EventLogTriage.ps1`. For the agent-facing
workflow see [SKILL.md](SKILL.md).

## Requirements

- **PowerShell 7+** (`pwsh`) on the machine running the script — it uses
  `ForEach-Object -Parallel`. Not bundled with Windows 10/11 (which ship Windows
  PowerShell 5.1); install with `winget install Microsoft.PowerShell`. The repo
  installer auto-installs it (see the repo README).
- **WinRM / PowerShell Remoting** enabled on the target servers (default in most
  domains; otherwise `Enable-PSRemoting` via GPO). The script connects with
  `Invoke-Command -ComputerName <srv> -Credential <tier-admin>`.
- A **tier-admin credential** with rights to read the targeted logs. It is always
  prompted for and never stored.

## Parameters

| Parameter | Type | Default | Notes |
|-----------|------|---------|-------|
| `-ComputerName` | string[] | — | One or more hosts (comma-separated). Combine with `-ServerListFile`. |
| `-ServerListFile` | string | — | Text file, one host per line; `#` comments and blank lines ignored. |
| `-Logs` | string[] | `System,Application` | Any event log names. |
| `-IncludeSecurity` | switch | off | Adds the `Security` log (see caveat below). |
| `-IncludeWarning` | switch | off | Adds Warning (level 3) to the default Critical+Error. |
| `-Level` | int[] | — | Explicit level set (1=Critical,2=Error,3=Warning,4=Info,5=Verbose). Overrides the above. |
| `-Hours` | int | 24 | Look-back window in hours. |
| `-Since` | datetime | — | Start at this time; end = now. Overrides `-Hours`. |
| `-From` / `-To` | datetime | — | Explicit interval. Overrides `-Since`/`-Hours`. |
| `-MaxEvents` | int | 5000 | Cap **per log per server**. Hitting it sets `truncated: true`. |
| `-SuppressList` | string | — | Path to a JSON suppress list (see below). Ships empty — build your own. |
| `-MaxMessageLength` | int | 1000 | Truncates each group's sample message. |
| `-ThrottleLimit` | int | 8 | Max servers queried in parallel. |
| `-TopCritical` | int | 20 | Size of the ranked `top_critical` list. |
| `-OutFile` | string | — | Write full detail JSON here; stdout becomes the compact view. |
| `-UseSSL` | switch | off | Connect over HTTPS (WinRM 5986) instead of HTTP (5985). Needs a listener + trusted cert on the target. |
| `-Authentication` | string | `Default` | WinRM auth scheme: `Default`/`Negotiate`/`Kerberos`/`Basic`/`CredSSP`. See the non-domain-joined note below. |
| `-Credential` | pscredential | — | Testing/automation seam only. Omit in normal use → you are prompted. |

## Time handling

`-Hours`/`-Since`/`-From`/`-To` are interpreted in the **local time** of the
machine running the script and used as `FilterHashtable` `StartTime`/`EndTime`.
All timestamps in the **output** (`first_seen`, `last_seen`, `generated_at`,
`query.from`/`to`) are normalized to **UTC** with a `Z` suffix so a multi-server
sweep is unambiguous regardless of each server's time zone.

## Suppress list format

```json
{
  "eventIds":  [7036, 10016],
  "providers": ["Some.Noisy.Provider"]
}
```

A group is dropped if its `event_id` is in `eventIds` **or** its `provider` is in
`providers`. Ships empty on purpose — what counts as benign noise is
environment-specific; curate your own over time.

## Output schema

```json
{
  "status": "ok | partial | error",
  "generated_at": "2026-06-08T10:00:00Z",
  "query": {
    "logs": ["System", "Application"],
    "levels": [1, 2],
    "from": "2026-06-07T10:00:00Z",
    "to": "2026-06-08T10:00:00Z",
    "max_events_per_log": 5000,
    "suppress_list_applied": false
  },
  "hosts": [
    {
      "computer": "SRV01",
      "status": "ok | unreachable | auth_failed | error",
      "error": null,
      "events_scanned": 1234,
      "truncated": false,
      "groups": [
        {
          "computer": "SRV01",
          "log": "System",
          "provider": "Service Control Manager",
          "event_id": 7034,
          "level": "Error",
          "count": 42,
          "first_seen": "2026-06-08T01:10:00Z",
          "last_seen": "2026-06-08T09:55:00Z",
          "sample_message": "The X service terminated unexpectedly..."
        }
      ]
    }
  ],
  "summary": {
    "hosts_total": 3,
    "hosts_ok": 2,
    "hosts_failed": 1,
    "total_groups": 17,
    "total_events": 1400,
    "failures": [
      { "computer": "SRV02", "status": "unreachable", "error": "WinRM cannot complete the operation..." }
    ],
    "top_critical": [
      {
        "computer": "SRV01", "log": "System", "provider": "Service Control Manager",
        "event_id": 7034, "level": "Error", "count": 42,
        "first_seen": "2026-06-08T01:10:00Z", "last_seen": "2026-06-08T09:55:00Z",
        "sample_message": "The X service terminated unexpectedly..."
      }
    ]
  }
}
```

`top_critical` ranking is deterministic: **Critical → Error → Warning → other**,
then **count descending**, then **last_seen descending**.

With `-OutFile`, the file holds the object above; **stdout** holds a compact
version with `status`, `generated_at`, `query`, `summary` (which includes
`top_critical` and `failures`) and a `note` — but no `hosts[]`.

## Per-host status mapping

| status | meaning |
|--------|---------|
| `ok` | Reached and queried (may still have 0 groups). |
| `unreachable` | WinRM/DNS/RPC/connection failure. |
| `auth_failed` | Credential rejected, access denied, or an auth-transport config problem (TrustedHosts / Kerberos no-authority). |
| `error` | Any other failure (message in `error`). |

A failing host never aborts the sweep; it is recorded and the rest continue. Failed
hosts (and `summary.failures`) also carry a `hint` field with an actionable
next-step string when the failure matches a known pattern.

### Non-domain-joined / cross-domain clients

If you run the script from a machine that is **not joined to the target's domain**
(or can't reach a domain controller), Kerberos is unavailable. Symptoms:

- `auth_failed` with error code **`0x80090311`** ("no authenticating authority" /
  "domænet ikke tilgængeligt") when forcing `-Authentication Kerberos`, or
- an error mentioning **`TrustedHosts`** when using the default (Negotiate → NTLM).

Fixes, in order of preference:

1. **Run from a domain-joined admin workstation / PAW** so Kerberos just works (the intended setup).
2. **Add the targets to WinRM TrustedHosts on the client** (one-time, needs local admin) and let NTLM be used:
   ```powershell
   Set-Item WSMan:\localhost\Client\TrustedHosts -Value 'host1.contoso.local,host2.contoso.local' -Concatenate
   ```
   Note: TrustedHosts means the client will send NTLM credentials to those hosts — scope it to specific FQDNs, not `*`.
3. **Use HTTPS**: `-UseSSL` (requires a WinRM HTTPS listener + trusted certificate on the target).

## Known caveats

- **Security log + level filtering.** Security audit events are typically
  *Information* level with Success/Failure *keywords*, so the default
  Critical+Error filter surfaces little from `-IncludeSecurity`. To hunt audit
  failures, query the Security log with appropriate keywords/event IDs (e.g. 4625
  failed logons) via `-Logs Security -Level 0,1,2,3,4` plus a tighter window —
  full keyword filtering is out of scope for this skill.
- **`MaxEvents` is a per-log cap.** A very busy server can hit it on one log; the
  host is flagged `truncated: true`. Narrow the window or raise `-MaxEvents`.
- **Parallelism.** Servers are queried concurrently up to `-ThrottleLimit`. The
  per-host fetch runs remotely (server-side filtering); grouping/ranking happens
  locally after collection.

## Gotchas

These are interpretation and misdiagnosis traps — distinct from the known
operational caveats above (Security-log level filtering, `MaxEvents` truncation,
parallelism). Where those overlap, a cross-reference is noted.

**High event counts are not severity — dominant noise providers will bury real
issues.** Benign providers such as `Service Control Manager` event 7036
(service state-change) or DCOM event 10016 can fire thousands of times and land
at the top of `top_critical` by count. The ranking is
Critical → Error → count → recency (see *Output schema*), so a high-count
Error drowns out a single-occurrence Critical. Always check the full ranked
list, not just rank-1. If a noisy provider is known-benign in your environment,
add it to a `suppress_list` so it cannot pad the count.

**A service crash plus its dependent failures is one incident, not many.**
When a service terminates unexpectedly (event 7034), every service or application
that depends on it typically logs its own Error immediately after. These appear
as separate groups with separate counts, making a single root-cause look like a
cluster. Correlate by `first_seen` timestamps and provider chain (Service Control
Manager → dependent-app provider) before reporting the count of affected groups
as independent problems. Report: "service X crashed, pulling down Y and Z" — not
three distinct incidents.

**Time-window inputs are operator-local; output timestamps are UTC — do not
compare them directly.** `-Hours`, `-Since`, `-From`, and `-To` are resolved in
the local time zone of the machine running the script, but every timestamp in
the JSON output (`first_seen`, `last_seen`, `query.from`, `query.to`) is
normalized to UTC with a `Z` suffix. If an operator on UTC+2 passes
`-Since '2026-06-15T08:00'`, the `query.from` in the output reads
`2026-06-15T06:00:00Z`. Comparing a server's local-time log viewer screenshot
("event at 08:00") against the JSON `first_seen` will show a two-hour gap that
is not a gap. Always convert to a common time zone before cross-referencing
output with external sources (SIEM, tickets, screenshots from remote desktop).

**A truncated host does not mean "no more events" — it means coverage was
capped.** When `truncated: true` appears on a host, `Get-WinEvent` stopped at
`-MaxEvents` (default 5000 per log) and events before that cut-off are simply
absent from the output. The most *recent* events are returned first, so older
events in the window are the ones silently dropped. Never state that a host
showed "no issues before 03:00" when `truncated: true`; the data to support
that claim was never collected. Surface the flag explicitly and narrow the
window or raise `-MaxEvents` before drawing coverage conclusions. (Also noted
in *Known caveats* — repeated here because it is the most common source of
false-clean verdicts.)

**`ProviderName` and the legacy `Source` field are not the same string —
a wrong name silently returns zero events.** `Get-WinEvent -FilterHashtable
@{ProviderName='...'}` matches against the ETW provider registration, which
can differ from the source name shown in Event Viewer's legacy "Source" column
(e.g., `Microsoft-Windows-Security-Auditing` vs `Security`). Passing the
display-name string as a `ProviderName` filter will silently return nothing
rather than erroring. If a targeted filter via `-Logs` plus a manual
`Get-WinEvent` call yields an unexpectedly empty result, verify the exact
registered provider name with
`(Get-WinEvent -ListProvider '*<keyword>*').Name` before concluding the log
is clean.

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser
Invoke-Pester -Path ./scripts/Invoke-EventLogTriage.Tests.ps1 -Output Detailed
```

Tests cover the deterministic logic (parsing, level/log/time resolution,
grouping, suppression, ranking, status, compact shaping) and `Invoke-HostTriage`
with a mocked `Invoke-Command`. The parallel orchestrator is not unit-tested
(Pester mocks cannot cross `-Parallel` runspace boundaries); its building blocks
are.
