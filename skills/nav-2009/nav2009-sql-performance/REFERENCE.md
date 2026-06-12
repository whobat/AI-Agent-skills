# nav2009-sql-performance — Reference

Detailed reference for `scripts/Invoke-SqlPerfTriage.ps1` and the NAV 2009 interpretation
guide. For the agent-facing workflow see [SKILL.md](SKILL.md).

## Requirements

- **PowerShell 7+** (`pwsh`) on the machine running the script (uses the bundled
  `System.Data.SqlClient`). The repo installer auto-installs it.
- Network access to the SQL Server instance (default port 1433; named instances need the
  SQL Browser service or an explicit port).
- SQL permissions: **VIEW SERVER STATE** (DMVs), **VIEW DATABASE STATE** or `db_owner` in the
  target database. `DBCC TRACESTATUS` may require sysadmin — that sub-check reports
  `unavailable` instead of failing the section.
- Works against SQL Server **2005 → 2019+**. Version-dependent behavior:
  - `deadlocks` needs Extended Events → **SQL 2008+**. On 2005 the section reports a note.
  - `stats` uses `sys.dm_db_stats_properties` (2008 R2 SP2+) and falls back to
    `sysindexes.rowmodctr` on older builds; the output's `method` field says which was used.

## Parameters

| Parameter | Type | Default | Notes |
|-----------|------|---------|-------|
| `-ServerInstance` | string | — | Required. `HOST` or `HOST\INSTANCE`. |
| `-Database` | string | — | The NAV database. Omitted → DB-scoped sections report `skipped`. |
| `-SqlCredential` | pscredential | — | SQL auth. Omit for Windows integrated auth. |
| `-Sections` | string[] | `all` | Any of: `server database waits top_queries missing_indexes unused_indexes blocking deadlocks sift fragmentation stats largest_tables`. |
| `-TopN` | int | 20 | Row cap per list section. |
| `-QueryTimeout` | int | 120 | Seconds per query. The `fragmentation` scan is the slow one on big DBs. |
| `-Encrypt` | switch | off | Encrypt the connection. Off by default for old instances. |
| `-OutFile` | string | — | Full JSON to file; stdout becomes the compact summary. |

The script is strictly **read-only**: SELECTs against DMVs/catalog views plus
`DBCC TRACESTATUS`. It never issues DDL/DML and never clears any stats.

## Output schema

```json
{
  "status": "ok | partial | error",
  "generated_at": "2026-06-10T09:00:00Z",
  "server": "SQLSRV01",
  "database": "Navision_PROD",
  "sections": {
    "<name>": {
      "status": "ok | error | skipped",
      "data":   "<section payload — array or object>",
      "error":  "<message when status=error>",
      "reason": "<why, when status=skipped>"
    }
  }
}
```

`status` is `partial` when at least one section errored. With `-OutFile`, stdout instead carries
`{ status, out_file, sections: { <name>: { status, rows } } }`.

**Timestamps:** `generated_at` and deadlock timestamps are UTC (`Z` suffix). Everything coming
out of DMVs (`last_execution_time`, `last_user_seek`, `STATS_DATE`, `sqlserver_start_time`) is
**SQL Server local time**.

### Sections

| Section | Source | Payload highlights | Caveats |
|---------|--------|--------------------|---------|
| `server` | `@@VERSION`, `dm_os_sys_info`, `sys.configurations`, `DBCC TRACESTATUS`, perf counters | version/edition, cpu_count, `sqlserver_start_time`, MAXDOP, cost threshold, max memory, active trace flags, page life expectancy | trace flags need sysadmin |
| `database` | `sys.databases`, `sys.master_files` | compatibility level, recovery model, auto-stats flags, RCSI, file sizes + autogrowth, tempdb data-file count | |
| `waits` | `dm_os_wait_stats` | top 15 waits, % of shown, signal wait | **cumulative since restart** |
| `top_queries` | `dm_exec_query_stats` + sql text | top `TopN` by CPU and by logical reads, per-execution averages, statement text (500 chars) | plan cache only — restarts/eviction reset it; ad hoc NAV statements often have `database_name: null` |
| `missing_indexes` | missing-index DMVs | optimizer suggestions ranked by improvement measure | suggestions are naive — translate to NAV keys, don't apply raw (see below) |
| `unused_indexes` | `dm_db_index_usage_stats` | nonclustered indexes with 0 reads and >1000 writes, by size | cumulative since restart — don't judge after a recent restart |
| `blocking` | `dm_exec_requests` | live blocking chains: who blocks whom, wait resource, statement | point-in-time snapshot; run while the problem is happening |
| `deadlocks` | system_health ring buffer | parsed graphs: victim, processes (login/host/app/isolation/inputbuf), objects involved | ring buffer wraps — recent history only; SQL 2008+ |
| `sift` | `sys.views` `%$VSIFT$%` + partition stats | total SIFT-view count, largest by MB/rows | |
| `fragmentation` | `dm_db_index_physical_stats` LIMITED | indexes >1000 pages with >30% fragmentation | the slow section; raise `-QueryTimeout` or exclude on very large DBs |
| `stats` | `dm_db_stats_properties` (fallback `sysindexes`) | stale stats on tables >100k rows (>10% modified or >30 days old) | `method` says which source was used |
| `largest_tables` | `dm_db_partition_stats` | top tables by total size, row count, NC index count | NAV table names are `Company$Table Name` |

## NAV 2009 interpretation guide (the important part)

NAV 2009 talks to SQL Server through its own driver (NDBCS). Two consequences shape everything:

1. **The Classic client / classic runtime uses server-side dynamic cursors** —
   `sp_cursoropen`/`sp_cursorfetch`/`FETCH API_CURSOR...` dominating `top_queries` is *normal*,
   not a finding in itself. Judge statements by **avg_logical_reads per execution** and total
   volume.
2. **NAV owns the physical design.** Table keys generate SQL indexes (`MaintainSQLIndex`),
   SIFT keys generate indexed views (`MaintainSIFTIndex`). Schema changes made directly in SQL
   are silently lost when NAV rebuilds objects (key change, company rename, upgrade). Index
   changes should therefore go through **C/SIDE key design** whenever possible.

### Finding → likely NAV cause → action

| SQL finding | Likely NAV-level cause | Recommended action |
|-------------|------------------------|--------------------|
| Statement with huge `avg_logical_reads`, WHERE clause doesn't match any index | C/AL filters without matching key: `SETRANGE`/`SETFILTER` after the wrong (or no) `SETCURRENTKEY` | Find the C/AL object; set a key matching the filter fields, or add a key in the table designer |
| Many executions of the same small statement (death by a thousand cuts) | `FIND('-')`/`FINDSET` loop issuing a row-by-row pattern, or repeated `GET` in a loop | Restructure the loop; filter once; consider `SETRANGE` + `FINDSET` over the right key |
| `missing_indexes` suggests an index on a NAV table | Same as above — the optimizer sees the filter mismatch | **Translate to a NAV key** (table designer) rather than `CREATE INDEX` in SSMS. A raw SQL index works but is lost on key/company changes — if used as a stopgap, document it |
| Top query is `SELECT SUM(...)` on a base table | `CALCSUMS`/FlowField without a SIFT key covering those dimensions | Add/adjust a SIFT key (SumIndexFields on a key with the filter fields) |
| `unused_indexes`: large `$VSIFT$` views or NC indexes with only writes | Over-indexed table: SIFT keys/indexes nobody reads, but every `INSERT` into e.g. `G/L Entry`, `Item Ledger Entry`, `Value Entry` pays for them | In C/SIDE: disable `MaintainSIFTIndex` / `MaintainSQLIndex` on the unused key. Classic posting-speed win |
| `waits` dominated by `LCK_M_*` | NAV 2009 classic locking is pessimistic (`UPDLOCK`/`HOLDLOCK`); long posting transactions serialize on hot tables | Shorten transactions in C/AL, check lock ordering, look at `blocking` section for the chain heads |
| `waits` dominated by `PAGEIOLATCH_*`, low page life expectancy | Buffer pool too small for working set, or scan-heavy queries flushing it | Check `max server memory`, then kill the scans (see read-heavy findings above) |
| `waits`: high `WRITELOG` | Log on slow disk; very chatty commits (C/AL `COMMIT` in loops) | Log disk latency; review C/AL for `COMMIT` inside loops |
| Deadlocks on `G/L Entry` / `No. Series Line` / dimension tables during posting | Concurrent posting hits the same resources in different order; SIFT-view maintenance adds locks | Classic mitigations: serialize the hot step, consistent lock order in custom code, `MaintainSIFTIndex` off on contested SIFT views, batch posting off-hours |
| `blocking`: head blocker is a `FETCH API_CURSOR` held open | A Classic-client user mid-transaction (form open in edit, posting paused) | Identify login/host from the row; it's a user/process problem, not an index problem |
| `fragmentation` high on big NAV tables | No index maintenance job | Add an ALTER INDEX REORGANIZE/REBUILD maintenance job — safe, NAV-compatible |
| `stats` stale on big ledgers | Auto-update stats can't keep up with bulk posting | Scheduled `UPDATE STATISTICS ... WITH FULLSCAN` (or sp_updatestats) off-hours |
| `server`: MAXDOP 0 on many-core box, NAV workload | Parallelism rarely helps NAV OLTP; can cause CXPACKET noise | Common NAV guidance: MAXDOP 1 (or low) for dedicated NAV instances — confirm CXPACKET in waits first |
| `database`: RCSI on | NAV 2009 expects its own locking semantics | Flag it — RCSI on a NAV 2009 DB is unusual and worth questioning |
| `database`: 1 tempdb data file, many cores | tempdb allocation contention (PAGELATCH on 2:1:x) | Standard advice: multiple equal tempdb data files |
| Trace flag check | — | TF **4136** (disable parameter sniffing) was commonly recommended for NAV; note its presence/absence, don't push it blindly |

### What the script can NOT see

Be explicit about these gaps instead of overreaching:

- **Client-side time** (C/AL execution, form rendering, network latency). A NAV session can be
  slow with a healthy SQL Server. The Classic client's **Client Monitor** (Tools → Debugger →
  Client Monitor) traces per-statement client-side activity; suggest it when SQL looks clean.
- **Historical data** — DMV counters reset at restart; the plan cache forgets evicted plans.
  For a recurring nightly problem, run the script *during* the window (blocking/deadlocks
  especially are point-in-time / short-history).
- **Which C/AL object issued a statement.** Statement text + table names usually narrow it down;
  Client Monitor or SQL Profiler with application-name filtering closes the gap.
