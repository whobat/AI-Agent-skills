# sqlserver-perf-triage — Reference

Generic SQL Server interpretation guide for `scripts/Invoke-SqlPerfTriage.ps1`. For the
agent-facing workflow see [SKILL.md](SKILL.md). Parameters, output schema, and per-section
caveats are identical to the vendored script's documentation in the sibling skills; the
essentials are repeated here.

## Parameters

| Parameter | Type | Default | Notes |
|-----------|------|---------|-------|
| `-ServerInstance` | string | — | Required. `HOST` or `HOST\INSTANCE`. |
| `-Database` | string | — | Omitted → DB-scoped sections report `skipped`. |
| `-SqlCredential` | pscredential | — | SQL auth. Omit for Windows integrated auth. |
| `-Sections` | string[] | `all` | `server database waits top_queries missing_indexes unused_indexes blocking deadlocks sift fragmentation stats largest_tables`. |
| `-TopN` | int | 20 | Row cap per list section. |
| `-QueryTimeout` | int | 120 | Seconds per query; raise for `fragmentation` on big DBs. |
| `-Encrypt` | switch | off | Encrypt the connection. |
| `-OutFile` | string | — | Full JSON to file; stdout becomes the compact summary. |

The script is strictly **read-only**: SELECTs against DMVs/catalog views plus
`DBCC TRACESTATUS`. Works against SQL Server 2005 → current; `deadlocks` needs 2008+
(Extended Events), `stats` falls back to `sysindexes.rowmodctr` on pre-2008 R2 SP2.

## Generic interpretation guide

Triage order: **blocking → deadlocks → waits → top queries → indexes/stats/config.**

### Waits (what is the server waiting on?)

| Dominant wait | Usual meaning | Next step |
|---------------|---------------|-----------|
| `LCK_M_*` | Blocking/lock contention | `blocking` section for chain heads; long transactions; isolation level review (RCSI?) |
| `PAGEIOLATCH_*` | Reading data pages from disk | Low page life expectancy? Check `max server memory`, then hunt scan-heavy queries in `top_queries` by reads |
| `WRITELOG` | Transaction log write latency | Log file disk latency; very chatty commits from the app |
| `CXPACKET`/`CXCONSUMER` | Parallelism (often scan-driven) | Check `cost threshold for parallelism` (raise from default 5) and MAXDOP; tune the scanning queries |
| `ASYNC_NETWORK_IO` | Client consuming results slowly | App-side: row-by-row processing of large result sets |
| `SOS_SCHEDULER_YIELD` | CPU pressure | Top queries by CPU; plan regressions; missing indexes causing scans |
| `RESOURCE_SEMAPHORE` | Memory grants queueing | Huge sorts/hashes — find queries with big grants, usually missing indexes or stale stats |
| `HADR_SYNC_COMMIT` | Sync AG replica latency | Replica disk/network; consider async for non-critical replicas |
| `PAGELATCH_*` on tempdb (2:1:x) | tempdb allocation contention | Multiple equal tempdb data files (the `database` section reports the count) |

### Top queries

- Judge by **avg per execution** (CPU, logical reads) *and* total volume — one query at a
  million small executions can out-cost a single big scan.
- Plan cache is reset by restarts and memory pressure: check `sqlserver_start_time` before
  trusting totals.
- A statement with huge reads whose WHERE clause matches a `missing_indexes` suggestion is
  the classic pairing — but validate the suggestion (see below) before creating anything.

### Indexes & statistics

- `missing_indexes` suggestions are naive: they ignore existing similar indexes, overlap each
  other, and over-include columns. Consolidate before creating; prefer widening an existing
  index over adding a near-duplicate.
- **If an application owns the schema** (ERP systems like Dynamics NAV/AX regenerate indexes
  on synchronization), route index changes through the application layer — see the sibling
  skills. Out-of-band indexes get dropped silently.
- `unused_indexes` (writes but no reads) are rebuild/storage tax — but counters reset at
  restart; don't judge a freshly restarted instance.
- Stale `stats` on big tables → bad plans. A scheduled `UPDATE STATISTICS`/Ola Hallengren
  IndexOptimize job is the standard fix.

### Configuration red flags (server/database sections)

| Finding | Note |
|---------|------|
| `max server memory` at default (2147483647 MB) | Unbounded — OS/other services starve. Set an explicit cap |
| `cost threshold for parallelism` = 5 | 2005-era default; 25-50 is the common modern starting point |
| MAXDOP 0 on many-core OLTP box | Often causes CXPACKET noise; set per workload guidance |
| 1 tempdb data file, many cores | Allocation contention; use multiple equal files |
| `is_auto_shrink_on` = true | Almost always wrong — fragments everything |
| `page_verify_option_desc` != CHECKSUM | Old default (TORN_PAGE/NONE); switch to CHECKSUM |
| `log_reuse_wait_desc` != NOTHING/CHECKPOINT | Log can't truncate — replication, open transaction, or missing log backups (FULL recovery) |
| Compatibility level far below server version | Locked to old optimizer behavior — intentional or forgotten? |

### What the script can NOT see

- **Historical data** — DMV counters reset at restart; plan cache forgets evicted plans. For
  a recurring window problem, run during the window (blocking/deadlocks are point-in-time /
  short-history). For continuous history, Query Store (2016+) is the right tool — suggest
  enabling it.
- **Client-side time** — app/network latency makes an app slow with a healthy SQL Server.
- **Query plans** — the snapshot has statement text and stats, not plans. Follow up on a
  specific query with its actual plan in SSMS.

## Gotchas

**`sys.dm_exec_query_stats` totals are cumulative since the plan entered cache — they reset silently on eviction, recompile, or restart.**
Trap: a query that just had its plan evicted (e.g. ad-hoc, unparameterized, or touched by memory pressure) shows zero executions, so it disappears from the top-N list entirely even if it dominated the previous hour. Conversely, a plan that has lived in cache since the last restart accumulates totals spanning days or weeks — reading its `total_logical_reads` as "recent" over-weights old, no-longer-relevant activity. Why it happens: the DMV is keyed by `sql_handle`/`plan_handle`; any event that forces a new plan handle starts a fresh counter at zero. Correct check: always read `sqlserver_start_time` from the `server` section first to know the accumulation window, and cross-reference with `execution_count` vs average per execution — a high total with a low execution count signals a long-lived plan, not recent abuse.

**A live blocking snapshot that shows no blocking does not mean there is no blocking problem.**
Trap: the `blocking` section is a point-in-time query against `sys.dm_exec_requests`. Transient blocking that resolves in under a second (the most common OLTP case) is invisible — the script captures empty results and the agent reports "no blocking" while users are experiencing second-level waits. Why it happens: blocking rows exist in the DMV only while the waiter is actively waiting; fast-resolving locks vanish before the query runs. Correct check: treat blocking evidence from the `waits` section (`LCK_M_*` dominant wait, high `wait_time_ms`) as the authoritative signal of a locking problem. If waits indicate lock contention but `blocking` is empty, re-run with `-Sections blocking` two or three times in rapid succession, or enable Query Store / Extended Events to capture the full history.

**Missing-index DMV suggestions ignore existing indexes, overlap each other, and ignore write amplification — creating them blindly can make things worse.**
Trap: `sys.dm_db_missing_index_details` reports the columns and predicates SQL Server encountered without a suitable index, scored by estimated impact. The DMV does not know about: (a) existing indexes that could be widened by one column to cover the suggestion, (b) other suggestions in the same list that cover overlapping columns, or (c) the write overhead of an additional index on a high-DML table. An agent that creates every suggestion in ranked order can produce five near-duplicate indexes that slow every INSERT/UPDATE/DELETE. Why it happens: each missing-index entry is generated independently by the query optimizer per-query, with no cross-query deduplication. Correct check: before recommending any creation, inspect `sys.indexes` on the same table for existing indexes whose key columns are a superset or near-superset; consolidate overlapping suggestions; estimate write ratio (`missing_indexes.user_seeks + user_scans` vs the table's writes in `top_queries`). Prefer widening an existing index over adding a new one.

**Without VIEW SERVER STATE most DMV sections return zero rows — a quiet result that looks healthy rather than an explicit error.**
Trap: if the login running the script has VIEW SERVER STATE denied (common on shared or locked-down instances), DMVs like `sys.dm_exec_query_stats`, `sys.dm_os_wait_stats`, and `sys.dm_exec_requests` return an empty result set rather than an access-denied error. The script's section will report `status: ok` with `data: []`, which an agent may read as "no top queries / no waits / no blocking" — a clean bill of health from a permission gap. Why it happens: by design, SQL Server returns only the rows a login is entitled to see; rows owned by other sessions are filtered out, leaving an empty set with no error. Correct check: verify the `server.permissions` sub-key in the JSON output (the script probes for VIEW SERVER STATE) and confirm that `sys.dm_exec_sessions` row count matches a reasonable session count before trusting any empty DMV result.

**`query_hash` and `plan_hash` are different things — confusing them leads to wrong conclusions about parameterization and plan reuse.**
Trap: `sys.dm_exec_query_stats` exposes both `query_hash` (same for all executions of logically identical queries regardless of literal values) and `plan_hash` (same only when the compiled plan is also identical). An agent that groups by `plan_handle` or treats each row as a distinct query will see dozens of rows for the same logical SELECT with different literal constants — inflating the count of "distinct queries" and missing the real culprit: a single unparameterized query generating a plan-cache storm (thousands of single-use plans). Conversely, one `query_hash` with many distinct `plan_hash` values signals parameter sniffing or plan instability, not many different queries. Correct check: when the top-queries list is suspiciously long with similar statement text, group by `query_hash` to collapse parameterization variants; then compare distinct `plan_hash` counts per `query_hash` to diagnose sniffing vs. cache bloat.
