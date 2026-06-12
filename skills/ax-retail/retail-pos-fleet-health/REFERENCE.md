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
