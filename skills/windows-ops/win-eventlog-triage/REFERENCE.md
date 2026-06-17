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
machine running the script. Internally the window is **converted to UTC before it
crosses the remoting boundary** and **converted back to each target's local time**
inside the remote block, so a sweep of servers in a different time zone than the
caller filters the correct window. (A `Kind=Local` `DateTime` passed straight into
`Invoke-Command -ArgumentList` can have its kind reinterpreted during
serialization, shifting the window by the offset and silently returning **zero
events** — this is handled; see the *cross-time-zone* gotcha below.)

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

**A clean `0` events can be a lie — cross-time-zone window shift.** If a run returns
`events_scanned: 0` / empty `groups` with `status: ok` for a host you know is busy,
do not trust it. The script now passes the window as UTC and converts it to the
target's local time on the server (fixed), but the symptom is worth knowing: a
`DateTime` whose `Kind` flips during `Invoke-Command` serialization shifts the
filter window by the caller↔target time-zone offset, so a real, active log returns
nothing. **Verify** any surprising 0/low-count result with a direct unfiltered probe
on the host — `Invoke-Command -ComputerName <h> -Credential <c> { Get-WinEvent -LogName System -MaxEvents 5 }`
— before reporting "clean". A populated log with a 0-count triage result is the
tell.

**`Get-WinEvent -ListLog <name>` `LastWriteTime`/`RecordCount` can look frozen.**
The per-log file metadata is not a reliable "is this log active" signal — it can
read as the last boot time while events are in fact being written every minute.
Judge activity by querying actual events (most-recent N), never by `ListLog`
timestamps.

**The `Get-Credential` prompt needs an interactive console — agent/CI runners
hang on it.** The script always prompts (by design). When something drives it
non-interactively (an AI agent's shell tool, a CI step, a background job), the
GUI/console credential prompt cannot render and the run hangs or aborts. Launch it
in a **visible** console so the prompt appears, e.g.
`Start-Process pwsh -ArgumentList '-NoExit','-File','<script>','-ComputerName','SRV01','-OutFile','out.json'`,
then read the `-OutFile`. (The `-Credential` seam exists for true automation, but
treat it as test-only — don't put passwords on a command line in anger.)

**Passing multiple hosts through a wrapper: a quoted `"A,B"` is one host.** When a
launcher passes arguments as an array (e.g. `Start-Process -ArgumentList`), a single
quoted token `'SRV01,SRV02'` reaches the script as **one** computer name and fails
to resolve. Pass a real array (`-ComputerName SRV01,SRV02` as separate tokens, or
build the call with `& '<script>' -ComputerName 'A','B'` inside the launched
session), or use `-ServerListFile`.

**From a non-domain-joined client, connect by the FQDN that matches your
TrustedHosts entry.** A short name (`SRV01`) will **not** match a `*.contoso.local`
TrustedHosts wildcard and falls back to a failed NTLM path; the FQDN
(`SRV01.contoso.local`) does. Pair the FQDN with `-Authentication Negotiate`. (See
*Non-domain-joined / cross-domain clients* above for the TrustedHosts setup.)

**Environment-specific gotchas (local).** At the start of a run, read `gotchas.local.md` in this skill's folder if it exists — it records traps learned in *this* environment (real server/database names, local quirks, naming conventions). When you discover a new environment-specific pitfall here, **append it to `gotchas.local.md`** (not to this file, which must stay generic and company-agnostic). The file is gitignored and is preserved across skill updates, so this skill gets more useful every time it runs in your environment.

## Verification

This is a **read-only** triage skill — it does not modify anything on the target servers. Before drawing conclusions and before reporting results, verify that the run itself was sound.

**Before relying on the result — confirm coverage is complete.**

- **No failed hosts.** Check `summary.failures`: any entry with `status` of `unreachable` or `auth_failed` means that host is absent from the data. Never state "all servers look clean" if any host is listed there. Relay the failure and its `hint` field explicitly.
- **No truncated hosts.** Check every host in `hosts[]` for `truncated: true`. A truncated host means `Get-WinEvent` hit the `-MaxEvents` cap and silently dropped older events in the window — the oldest slice of the window is simply missing. Do not draw coverage conclusions ("no issues before 03:00") for a truncated host. Surface the flag and narrow the window or raise `-MaxEvents` before concluding.
- **Time window and log/level scope match the question.** Verify `query.from`/`query.to`, `query.logs`, and `query.levels` against what was asked. A mismatch (e.g., Security log omitted, Warning level excluded, window starts an hour too late) means the answer addresses a different question than the one posed.
- **Operator-local → UTC conversion is accounted for.** Input parameters (`-Hours`, `-Since`, `-From`/`-To`) are resolved in the operator machine's local time; `query.from`/`query.to` in the output are UTC. Confirm the UTC window in the output actually covers the period the user cares about before proceeding. (See the *Time-window inputs are operator-local* gotcha for an example.)
- **A clean result on a busy host is suspicious — spot-check it.** If a host returns `events_scanned: 0` or a near-empty group list but you expect activity (it serves users, it was just rebooted, it hosts a chatty role), confirm with a direct `Get-WinEvent -MaxEvents 5` on that host before reporting "clean". See the *cross-time-zone window shift* gotcha — a populated log with a 0-count triage result is the tell.
- **Establish what normal looks like.** Before labelling something an anomaly, consider whether the provider/event-ID combination is expected background noise in this environment. If a suppress list is in use (`query.suppress_list_applied: true`), known-benign events are already filtered; if not, cross-check unfamiliar high-count entries against the *High event counts are not severity* gotcha before surfacing them as findings.

**Output verification — cross-check findings and confirm remediation.**

- **Cross-check a top finding against the raw event — do not trust counts alone.** The `sample_message` in `top_critical` is a single truncated example; it may not represent all occurrences in the group. Before reporting a finding, open the raw event (via `Get-WinEvent` or Event Viewer on the server) and confirm the message content, exact timestamp, and context match what the JSON implies. A high-count group with a vague sample message warrants a spot-check.
- **Re-run after remediation.** If a remediation action is applied in response to a finding (service restarted, patch applied, config changed), re-run the triage over the same time window (or a short post-fix window) and confirm that the error group is absent or its `last_seen` predates the fix. A finding that persists post-fix means either the fix did not take effect or a separate instance of the same issue is occurring.
- **Fail loud on any failed or truncated host.** Never present a result as covering the full target set when any host is in `summary.failures` or carries `truncated: true`. Always make the gap explicit in the summary, even if the user did not ask about it.

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
