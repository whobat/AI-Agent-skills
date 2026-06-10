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
