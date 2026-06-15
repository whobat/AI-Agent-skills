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

## Gotchas

Traps that lead to a confident-but-wrong conclusion when reading a DMV snapshot through a
NAV 2009 lens.

**A `missing_indexes` suggestion is not a `CREATE INDEX` instruction.**
The optimizer knows only that the query would benefit from a column combination — it has no
knowledge of NAV's object model. Creating the index directly in SQL (e.g. via SSMS) will work
until NAV next touches the table: a key change, a new company, or a schema synchronisation
silently drops or rebuilds all indexes on that table, and your hand-crafted index disappears
without error. The correct path is to open the table in C/SIDE and add or adjust a **NAV key**
with `MaintainSQLIndex = Yes` covering the same fields. Use a raw SQL index only as an
acknowledged, documented stopgap while the C/SIDE change is arranged.

**DMV aggregates for a company-prefixed table represent only that one company's data.**
NAV stores each company's data in its own set of tables named `CompanyName$Table Name` (e.g.
`CRONUS$Item`, `CRONUS$G/L Entry`). `top_queries`, `missing_indexes`, `unused_indexes`, and
`largest_tables` all surface rows per physical table. If `missing_indexes` shows a suggestion
on `CRONUS$Item` and the instance hosts five companies, the same logical gap exists in
`OtherCo$Item`, `ThirdCo$Item`, etc. — those will have their own DMV rows, or may not appear
at all if those companies haven't run the same workload yet. Never read a finding on one
company's table as a complete picture of the schema problem; check sibling tables before
concluding scope.

**Write pressure and locking on a `$VSIFT$` view traces to SIFT maintenance, not the base table.**
NAV SIFT keys are implemented as SQL Server indexed views (`dbo.CompanyName$VSIFT$KeyName`).
Every `INSERT`, `UPDATE`, or `DELETE` on the base table (e.g. `CRONUS$G/L Entry`) causes SQL
Server to maintain all covering indexed views in the same transaction and under the same locks.
If `waits` shows `LCK_M_*` or `WRITELOG` pressure that the `top_queries` section can't explain
from the base-table statements alone, check the `sift` section for large or numerous VSIFT
views on that table. The locking is happening inside the view-maintenance step, not on a slow
base-table query. The fix is in C/SIDE: turn `MaintainSIFTIndex = No` on SIFT keys nobody
reads (cross-reference `unused_indexes` for the corresponding view).

**A `FETCH API_CURSOR` head blocker in `blocking` is a user/process problem, not an index problem.**
The Classic NAV client keeps a server-side cursor open for the lifetime of a form or a posting
session. If that session is mid-transaction — a user paused on a posting dialog, or a batch
job holding locks between rows — it will appear in `blocking` as a `FETCH API_CURSOR`
statement with a long `wait_time`. The instinct is to tune the underlying query; that changes
nothing, because the cursor is already past the read phase and is blocking because it holds
row/page locks acquired earlier in the transaction. The correct action is to identify the
`login_name` and `host_name` from the blocking row and contact or kill that session — the fix
is operational, not index-related.

**Cumulative DMV counters after a recent instance restart make `unused_indexes` and `waits` unreliable.**
`dm_os_wait_stats`, `dm_db_index_usage_stats`, and `dm_exec_query_stats` all reset to zero on
every SQL Server restart. If `server.system.sqlserver_start_time` is recent (hours or a few
days), the `unused_indexes` section may flag indexes as unread simply because the workload
hasn't cycled through all its paths yet — a month-end job, a rarely-run report, or a posting
run that hasn't happened since the restart. Similarly, a wait-type ranking built on two hours
of uptime will over-represent whatever happened to run in that window. Always state the uptime
window before drawing conclusions from cumulative sections, and treat `unused_indexes`
findings as provisional until the instance has been up through at least one full business cycle.

**High cursor execution count in `top_queries` is normal NAV behaviour — judge by reads per execution, not by count.**
The Classic NAV client driver (NDBCS) issues every record-set operation as a server-side
dynamic cursor: `sp_cursoropen` followed by repeated `sp_cursorfetch` / `FETCH API_CURSOR`
calls. A `FINDSET` loop over 10 000 rows produces 10 000+ individual fetch executions, each
cheap. In `top_queries` these accumulate to enormous `execution_count` figures that look
alarming next to a modern application's set-based queries. The metric that matters is
`avg_logical_reads` (logical reads per execution): a cursor fetch with 2–5 logical reads is
working correctly against a good key; the same fetch with 500–5 000 reads points to a missing
or mismatched key. Flag the reads-per-execution outliers; ignore high counts unless they are
accompanied by elevated per-execution cost.

**Environment-specific gotchas (local).** At the start of a run, read `gotchas.local.md` in this skill's folder if it exists — it records traps learned in *this* environment (real server/database names, local quirks, naming conventions). When you discover a new environment-specific pitfall here, **append it to `gotchas.local.md`** (not to this file, which must stay generic and company-agnostic). The file is gitignored and is preserved across skill updates, so this skill gets more useful every time it runs in your environment.

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

## Verification

This skill is **read-only diagnosis**. Verification has two phases: confirming the snapshot is
trustworthy before drawing conclusions, and confirming a NAV-side change actually worked after
it is deployed.

### Before recommending anything — confirm the snapshot is trustworthy

Do not interpret findings until all four checks pass:

1. **Permissions present.** Both `VIEW SERVER STATE` and `VIEW DATABASE STATE` must be available.
   An empty section (e.g. `waits: { status: ok, data: [] }`) means the query ran and found
   nothing — that is a real result. A section with `status: error` containing "permission denied"
   means the data is missing entirely, not that the metric is zero. Name every errored/skipped
   section explicitly before proceeding; do not fill gaps with assumptions.

2. **Right database scoped.** Confirm `database` in the top-level JSON matches the NAV production
   database you intend to analyse. The `database` section's `name` and `compatibility_level`
   fields double-check this. If `-Database` was omitted, all DB-scoped sections report `skipped`
   — that is expected but must be stated; never treat `skipped` as "nothing to see".

3. **Instance restart time noted (DMVs are cumulative).** Read `server.system.sqlserver_start_time`
   first. All cumulative sections — `waits`, `top_queries`, `unused_indexes`,
   `dm_exec_query_stats` — reflect the period from that timestamp to `generated_at`. State this
   window at the top of your analysis ("DMVs cover approx. 14 days since last restart"). If the
   window is short (hours to a few days), flag `unused_indexes` and `waits` as provisional; the
   workload may not have cycled through all its paths yet.

4. **Company-prefixed table findings understood as per-company.** A finding on
   `CompanyA$G/L Entry` does not represent all companies. If the instance hosts multiple
   companies, sibling tables (`CompanyB$G/L Entry`, etc.) will have their own DMV rows — or none
   at all if that company has not run the relevant workload since the last restart. Before
   concluding the scope of a missing-index or fragmentation finding, check whether sibling tables
   show the same pattern or are absent.

**Capture a baseline.** Record `generated_at`, `sqlserver_start_time`, and the top-3 wait types
(with their % share) before any change. This is the baseline to compare against after a fix.

### After a NAV-side change — confirm it worked

NAV 2009 changes are made **in C/SIDE and compiled there**, not in raw SQL. The verification
loop is:

1. Make the change in C/SIDE (key added/adjusted, `MaintainSQLIndex`/`MaintainSIFTIndex`
   toggled, C/AL loop restructured).
2. **Compile and synchronise** the object in C/SIDE (Object Designer → Compile; for key changes,
   also run Schema Synchronisation or Table Synchronisation). Confirm no sync errors.
3. **Re-run the snapshot** after the workload has had time to exercise the changed path. For
   index-usage changes, the relevant queries must execute at least once after the compile; for
   wait and blocking fixes, re-sample during a representative load window.
4. **Compare against the baseline**: the target metric (avg_logical_reads on the flagged
   statement, LCK_M_* wait share, blocking chain depth) should have improved. If it has not
   moved, the compiled change did not affect the path you diagnosed — re-examine which C/AL
   object issues the statement (Client Monitor or SQL Profiler with app-name filter).
5. **Transient blocking: re-sample before acting.** A single `blocking` snapshot proves a chain
   existed at that instant, not that it is chronic. If you cannot reproduce blocking on a second
   snapshot taken during the same load window, treat the first sighting as provisional and
   monitor before recommending a structural change.

**Fail loud on partial coverage.** If a section was `error` or `skipped` in the before-snapshot,
note it in the after-snapshot too. Do not claim the fix resolved "all issues" if sections were
unavailable — state exactly which metrics were verified and which remain unconfirmed.
