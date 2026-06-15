# retail-pos-fleet-health — Reference

Detailed reference for `scripts/Invoke-PosFleetHealth.ps1`. For the agent-facing workflow
see [SKILL.md](SKILL.md).

## Parameters

| Parameter | Type | Default | Notes |
|-----------|------|---------|-------|
| `-ComputerName` | string[] | — | One or more hosts. Combine with `-ServerListFile`. |
| `-ServerListFile` | string | — | Text file, one host per line; `#` comments and blanks ignored. |
| `-ServicePattern` | string[] | `*POS*, *Retail*, MSSQL*, SQLAgent*` | Wildcard service names to inspect. Adjust to your fleet's service names. |
| `-EventHours` | int | 24 | Look-back for Critical/Error counts (System + Application). |
| `-DiskMinFreePct` | int | 10 | Warn when a fixed disk has less free space than this. |
| `-ExpressLimitGB` | double | 10 | SQL Server Express per-database data-file limit. |
| `-ExpressWarnAtPct` | int | 80 | Warn when a database reaches this % of the limit. |
| `-ErrorCountWarn` | int | 50 | Warn when a host logged at least this many errors in the window. |
| `-ThrottleLimit` | int | 12 | Hosts queried in parallel. |
| `-UseSSL` / `-Authentication` | | `Default` | WinRM transport/auth. |
| `-Credential` | pscredential | prompted | Testing/automation seam only. |
| `-OutFile` | string | — | Full JSON to file; stdout becomes the compact summary. |

Read-only contract: the script queries CIM (OS, disks), `Get-Service`, SQL catalog views
(`sys.master_files`, `SERVERPROPERTY`), and `Get-WinEvent` counts. It never changes
service state, never runs DDL/DML, and writes only the `-OutFile` you ask for. Enforced
by the Pester suite next to the script.

## Output schema

```json
{
  "status": "ok | partial | error",
  "generated_at": "2026-06-10T12:00:00Z",
  "query": { "hosts_total": 100, "service_patterns": ["*POS*"], "event_hours": 24,
             "disk_min_free_pct": 10, "express_limit_gb": 10 },
  "summary": {
    "hosts_ok": 97, "hosts_failed": 3, "warning_count": 9,
    "warnings": [ { "computer": "POS042", "type": "express_db_near_limit",
                    "detail": "MSSQL$SQLEXPRESS/RetailOffline: 8.61 GB data of 10 GB Express limit" } ]
  },
  "hosts": [
    {
      "computer": "POS001", "status": "ok | unreachable | auth_failed", "error": null,
      "boot_time": "2026-06-01T03:12:00Z", "os": "Windows 10 ...",
      "disks": [ { "drive": "C:", "size_gb": 119.2, "free_gb": 41.3, "free_pct": 34.6 } ],
      "services": [ { "name": "...", "display": "...", "status": "Running", "start_type": "Automatic" } ],
      "sql_instances": [ { "service": "MSSQL$SQLEXPRESS", "status": "Running",
                           "edition": "Express Edition ...", "version": "12.0...",
                           "databases": [ { "name": "RetailOffline", "data_gb": 8.61, "log_gb": 0.5 } ],
                           "error": null } ],
      "recent_errors": { "window_hours": 24, "count": 3,
                         "top_providers": [ { "provider": "...", "count": 2 } ] }
    }
  ]
}
```

Warning types, in ranking order: `unreachable`/`auth_failed`, `service_stopped`
(auto-start service not running), `express_db_near_limit`, `disk_low`,
`sql_query_failed`, `high_error_count`.

## Interpretation notes

- **`express_db_near_limit`** — SQL Server Express enforces a per-database data-file cap
  (10 GB since 2008 R2; logs don't count). A POS offline database at the cap stops
  accepting writes → the till stops syncing or working offline. This is the highest-value
  early warning a POS fleet sweep produces. Typical causes: transaction/preaction tables
  never purged because sync to the channel DB is failing — check the sync chain (see
  `ax2012-sql-performance` → Retail stack) before shrinking anything.
- **`service_stopped`** — an Automatic service that isn't running is either crashed or
  manually stopped; correlate with `recent_errors.top_providers` on the same host.
- **Counts are signals, not triage** — `recent_errors` is capped at 500 events per host.
  For real event-log triage of a specific machine, use `win-eventlog-triage`.
- **`boot_time`** — a till that hasn't rebooted for months often correlates with leaks and
  stuck services; a till that rebooted minutes ago may be crash-looping.
- **Fleet-wide patterns beat per-host reads**: the same service stopped on 30 machines is
  a deployment/GPO problem; on one machine it's a local problem.

## Scaling to ~100 hosts

- Default `-ThrottleLimit 12` sweeps ~100 hosts in a few minutes (WinRM latency-bound).
  Raise carefully; each session costs memory on the operator machine.
- Always use `-OutFile` — the full JSON for 100 hosts is large; the stdout summary stays
  small and the agent reads details selectively from the file.
- Unreachable hosts cost the WinRM timeout each; a list with many dead entries slows the
  sweep — prune the host list or lower the throttle impact by sweeping in batches.

## Gotchas

- **SQL Express 10 GB cap applies per database data file, not per instance — and log files
  don't count.** `data_gb` in the output is the right measure; `log_gb` is reported
  separately and does not count against the cap. A host whose instance holds two databases
  at 5.5 GB each is two independent near-limit problems, not one 11 GB problem. Conversely,
  a database with a large log file but a small `data_gb` is not near the cap. Always read
  `data_gb` only when evaluating `express_db_near_limit` warnings.

- **A stopped auto-start service on a POS can be correct — not every till is expected to be
  running at sweep time.** Tills that are offline, closed for the day, or not yet opened
  for trading may have their POS/Retail services deliberately stopped (e.g. stopped by the
  POS shutdown procedure). Before escalating a `service_stopped` warning, confirm the
  expected posture for that store and shift — a machine that is `service_stopped` plus
  `unreachable` and outside trading hours is almost certainly powered down on schedule, not
  faulted. Reserve escalation for machines that are reachable (i.e., the WinRM session
  succeeded) but whose service is unexpectedly stopped.

- **`unreachable` most often means the till is powered off, not broken.** WinRM on a POS
  machine is only reachable when Windows is fully booted. Tills swept outside trading
  hours, or those shut down between shifts, will appear as `unreachable` indistinguishably
  from a machine with a WinRM misconfiguration or network fault. Cross-reference the
  `hosts_failed` list with the store's trading schedule before treating `unreachable` as an
  incident — a machine that was reachable in the prior sweep and is now unreachable at
  3 AM is almost certainly off, not broken.

- **A burst of recent errors after a reboot is normal noise, not an ongoing problem.**
  `recent_errors.count` covers a fixed window (default 24 h). A till that rebooted
  following a patch or power cycle will log a cluster of events at startup — drivers
  initialising, services starting, network re-establishing — that can easily exceed the
  `-ErrorCountWarn` threshold. Check `boot_time`: if the machine rebooted recently
  (within the event window) and the `top_providers` are boot-phase sources (e.g. Service
  Control Manager, disk/network drivers), treat the count as startup noise rather than a
  live fault. A high count on a machine with a `boot_time` days in the past is the
  signal that warrants triage.

- **`ThrottleLimit` caps concurrency, so a fleet result is not a point-in-time snapshot.**
  With `-ThrottleLimit 12` (the default), a 100-host sweep runs in ~9 sequential waves.
  The first host and the last host are queried minutes apart. Do not compare absolute error
  counts or disk figures across hosts as if they were collected simultaneously, and do not
  assume a machine's absence from the `hosts_ok` list means it was reachable and clean —
  it may simply have been in a later wave that hadn't started when you read partial output.
  Always wait for the script to complete and parse the final JSON before drawing
  fleet-wide conclusions.

**Environment-specific gotchas (local).** At the start of a run, read `gotchas.local.md` in this skill's folder if it exists — it records traps learned in *this* environment (real server/database names, local quirks, naming conventions). When you discover a new environment-specific pitfall here, **append it to `gotchas.local.md`** (not to this file, which must stay generic and company-agnostic). The file is gitignored and is preserved across skill updates, so this skill gets more useful every time it runs in your environment.

## Verification

These steps are read-only — run them before acting on sweep results and after any fix.

### Before acting on results: establish coverage and baseline

- **Confirm which tills were unreachable and why.** Cross-reference `hosts_failed` with
  the store trading schedule: a till that is unreachable outside its trading window is
  almost certainly powered off on schedule, not broken. A till that is unreachable *during*
  trading hours, or that was reachable in the previous sweep and is now not, is the one
  that warrants action. Do not treat the two categories the same.

- **Check for throttle-sampling skew.** If `-ThrottleLimit` was set lower than the
  default, or the sweep was interrupted and restarted, the result set may not cover the
  full fleet evenly. Verify `query.hosts_total` matches the host list you intended before
  drawing fleet-wide comparisons. A partial sweep is only valid for the hosts it reached.

- **Know the expected per-store service posture.** Before judging any `service_stopped`
  warning, confirm what services are expected to be running at the time of the sweep for
  that store (trading/non-trading, open/closed shift). Build a reference of the normal
  fleet state — which services run on which machine types, which tills are expected online
  at which times — so that deviations stand out clearly from expected posture.

### Output verification: confirm persistent problems and cleared fixes

- **Re-sweep a flagged till before dispatching anyone.** A single sweep result can reflect
  a transient condition (a reboot in progress, a brief WinRM timeout, a startup burst).
  Run the script against the specific host (`-ComputerName <till>`) after a short wait and
  confirm the warning is still present in the second result. A warning that disappears on
  re-sweep is transient noise; one that persists is a real signal.

- **After a fix, re-run the sweep for that till and confirm it cleared.** Do not mark a
  problem resolved based on a verbal report or a service restart alone. Re-sweep the host,
  parse the JSON, and verify the relevant warning type is absent from `summary.warnings`
  for that machine before closing the incident.

- **Fail loud on unreachable hosts — never report them as healthy.** An unreachable host
  produces no service, disk, SQL, or event data. It must appear in your report as
  `unreachable` (or `auth_failed`), not as a host with no warnings. Omitting failed hosts
  from the summary gives a false impression of fleet health.
