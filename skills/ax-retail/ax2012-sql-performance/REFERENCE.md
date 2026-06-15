# ax2012-sql-performance — Reference

AX 2012 (incl. R3) interpretation guide for `scripts/Invoke-SqlPerfTriage.ps1`. For the
agent-facing workflow see [SKILL.md](SKILL.md). Script parameters and output schema match
the sibling skills (`sqlserver-perf-triage` documents the generic interpretation — use it
as the baseline; this file adds what is AX-specific).

## The two AX ground rules

1. **AX owns the schema through the AOT.** Tables, indexes, and (in R3) many statistics
   choices are defined in the AOT; a **database synchronization drops indexes that exist
   only in SQL**. Index changes go through the AOT (then synchronize), not SSMS. A raw SQL
   index is a documented stopgap at best.
2. **RCSI is expected ON.** AX 2012 is designed for `READ_COMMITTED_SNAPSHOT ON` (the
   installer enables it). The `database` section reports it — **OFF is a finding** (writers
   block readers needlessly). This is the opposite of NAV 2009.

## Finding → likely AX cause → action

| SQL finding | Likely AX-level cause | Recommended action |
|-------------|----------------------|--------------------|
| `largest_tables` topped by **INVENTSUMLOGTTS** | Master planning change tracking on, but MRP not run (or not run with cleanup) — the table grows unbounded | Run/schedule master planning so it consumes the log, or disable change tracking if MRP is unused; one-off cleanup per Microsoft guidance |
| Huge **SYSDATABASELOG** | Database log (audit) enabled on busy tables | Review Database log setup; archive + clean via the standard cleanup (System administration → Cleanup) |
| Huge **BATCHJOBHISTORY / BATCHHISTORY** | Batch job history never purged | Schedule the batch job history cleanup class |
| Huge **AIFMESSAGELOG / AIFDOCUMENTLOG** | AIF/services document logging retained forever | Schedule AIF history cleanup |
| Huge **EVENTINBOX / EVENTINBOXDATA** | Alert notifications piling up | Clean alerts inbox; review alert rules |
| Huge **DMF staging tables** (DMF*) | Data import/export framework staging never cleaned | Run DMF staging cleanup after imports |
| Huge **RETAILLOG / unsynced retail transaction tables** (channel or HQ) | CDX jobs failing or P-jobs not pulling transactions | Check Commerce Data Exchange job/session status on the HQ side; fix failing distribution schedules before touching SQL |
| `top_queries` full of cheap statements at huge execution counts | AX row-by-row patterns (`while select` loops, no `set-based` ops) or missing caching (table CacheLookup) | Identify the X++ call site; convert to set-based ops (insert_recordset/update_recordset) or fix EntireTable/Found caching |
| Statement with huge reads on InventTrans/InventSum/SalesLine | Missing/wrong AOT index for the query's WHERE clause | Add/adjust the index **in the AOT** and synchronize; validate against `missing_indexes` (consolidate naive suggestions) |
| `waits` dominated by `LCK_M_*` during posting/MRP | Long X++ transactions; number-sequence contention (non-preallocated number sequences are a classic) | Enable preallocation on hot number sequences; shorten transactions; check batch concurrency |
| `blocking` head is a SPID from the AOS service account | Long-running batch or interactive session holding locks | Identify the batch task (BatchJob forms) before killing anything |
| `waits`: `PAGEIOLATCH_*`, low PLE | Buffer pool too small for AX working set (AX DBs are scan-prone when indexes are missing) | `max server memory` review, then fix the scans |
| Trace flag check: **4136 absent** | AX 2012's parameterized queries are prone to parameter sniffing | TF4136 is commonly recommended for dedicated AX instances — evaluate, don't apply blindly |
| MAXDOP high on the AX OLTP instance | Microsoft's classic guidance for AX 2012 OLTP is MAXDOP 1 (batch/MRP-heavy shops sometimes differ) | Confirm CXPACKET in waits before changing; document the choice |
| `stats` stale on big AX tables | Auto-update can't keep pace with bulk operations | Scheduled statistics maintenance (e.g. Ola Hallengren) off-hours |
| `fragmentation` high | No index maintenance job | REORGANIZE/REBUILD job — safe; AX does not object to maintenance, only to schema changes |

## The Retail stack (R3): where to look when "POS is slow"

Data flows **AX (HQ) → CDX download jobs → channel database → POS** (and back via P-jobs).
A "slow POS" is often not the POS at all:

1. **Channel DB health** — run this skill against the channel database: blocking, top
   queries, unpurged transaction/log tables.
2. **CDX sync backlog** — failing or queued download/upload sessions show up as stale data
   and growing channel tables. Check Retail → Inquiries → Commerce Data Exchange on the HQ
   side (session status, failed distribution schedules). Verify exact table names in your
   environment before querying them directly — channel schema varies by CU.
3. **Retail Server / AOS load** — if SQL on both ends is healthy, the bottleneck is usually
   the service tier between them.
4. **The POS machines themselves** — offline database size, disk, services: use the
   `retail-pos-fleet-health` skill to sweep the fleet.

## Gotchas

Traps that produce a confident-but-wrong conclusion when reading a SQL DMV snapshot through
an AX lens. Check these before finalising any recommendation.

**Acting on a missing-index DMV suggestion by creating the index in SQL.**
The `missing_indexes` DMV legitimately identifies real gaps — but any index created directly
in SQL Server (via SSMS/T-SQL) is **silently dropped the next time AX runs a database
synchronisation** (`SysSqlSyncStartupBase`). The index disappears without error and the
problem returns. Correct path: cross-reference the suggestion against AOT indexes, then add
or adjust the index in the AOT and synchronise. A raw SQL index is only a validated stopgap
(e.g., emergency production fix to be promoted to the AOT within the same change window).

**Tuning queries when RCSI is OFF.**
The `database` section reports `is_read_committed_snapshot_on`. If it is `0`, every reader
competes with writers for shared locks — you will see inflated `LCK_M_S` / `LCK_M_IS` waits
and blocking chains that look like query problems. AX 2012 is designed and tested with RCSI
enabled (the installer sets it). The flag is commonly lost after a database restore or
migration that doesn't preserve the option. Fix: enable RCSI (`ALTER DATABASE … SET
READ_COMMITTED_SNAPSHOT ON`) before drawing any conclusions from the blocking or waits
picture — the wait profile will change substantially once readers stop blocking.

**Applying MAXDOP 1 because "that's the AX recommendation."**
The MAXDOP 1 guidance dates from pre-2012 AX deployments and is obsolete. Current Microsoft
guidance for AX 2012 (and later SQL Server best-practice) is **MAXDOP 8** (or the number of
logical processors per NUMA node, capped at 8) with `cost threshold for parallelism` raised
to 25–50. Setting MAXDOP 1 starves MRP and large batch queries that benefit from
parallelism. Only reduce MAXDOP toward 1 if `CXPACKET` waits are genuinely excessive and
the scheduler queue is saturated — check `waits` first.

**Truncating bloat tables directly in SQL instead of using AX cleanup routines.**
Tables such as `INVENTSUMLOGTTS`, `SYSDATABASELOG`, `BATCHJOBHISTORY`, `AIFMESSAGELOG`, and
`EVENTINBOX` accumulate legitimate bloat, but they carry application-layer cross-references
(foreign keys, workflow state, audit chains) that AX cleanup jobs handle correctly. A bare
`TRUNCATE TABLE` or ad hoc `DELETE` in SQL bypasses those checks and can leave AX in an
inconsistent state (orphaned workflow records, broken audit trails, MRP state corruption).
Each table has a supported in-AX cleanup path — see the `Finding → action` table above.
Advise the cleanup routine; never advise the SQL shortcut.

**Treating InventSumLogTTS bloat as an indexing problem.**
`INVENTSUMLOGTTS` grows because master planning's change-tracking accumulates rows that MRP
consumes during a planning run. A `missing_indexes` suggestion on this table is a red
herring — the table is insert-heavy by design and an extra index slows the writes that fill
it. The real question is whether master planning is scheduled and configured to run with
cleanup (`cleanUpLogTbl`). Recommend MRP scheduling and cleanup settings, not index
additions.

**Diagnosing a slow Retail channel database as a SQL problem.**
The channel database on AXDB-R (or equivalent) reflects what CDX download jobs last pushed
from HQ. Blocking, table bloat, or stale data on the channel DB usually has its root cause
**upstream on the HQ AX instance**: failed or queued distribution schedules, P-job backlog,
or dead-letter messages in the async client. Fixing SQL on the channel server (adding
indexes, killing sessions) treats symptoms. Check Commerce Data Exchange session/job status
on the HQ side first; the channel DB SQL findings are the consequence, not the cause.

**Environment-specific gotchas (local).** At the start of a run, read `gotchas.local.md` in this skill's folder if it exists — it records traps learned in *this* environment (real server/database names, local quirks, naming conventions). When you discover a new environment-specific pitfall here, **append it to `gotchas.local.md`** (not to this file, which must stay generic and company-agnostic). The file is gitignored and is preserved across skill updates, so this skill gets more useful every time it runs in your environment.

## Verification

A snapshot is only as trustworthy as its access and scope. Before drawing any conclusion —
and again after applying a fix — work through this checklist.

### Before recommending anything: confirm the snapshot is trustworthy

**VIEW SERVER STATE present.**
Check `server.errors` and `database.errors` in the JSON for `permission denied` on system
views. An empty section (zero rows) means *nothing found*, not *access denied* — but a
missing section or an error key means the data was never collected. If VIEW SERVER STATE was
absent, re-run with a login that has it; don't interpret a snapshot taken without it.

**Correct database scoped.**
The AX transaction database and the Retail channel database have distinct workload profiles
and different expected findings (RCSI, bloat tables, CDX tables). Confirm `database.name`
in the snapshot matches the database you intended to triage. A snapshot collected against
the wrong database (e.g., the model store, `tempdb`, or a reporting replica) will produce
misleading findings.

**RCSI state and instance restart time noted.**
Read `database.is_read_committed_snapshot_on` and `server.system.sqlserver_start_time`
before interpreting any other section. RCSI OFF invalidates the blocking and wait analysis
(see Gotchas). A recent restart shrinks the cumulative counter window — waits, query stats,
and missing-index suggestions all reflect only the uptime since the last restart. State both
values explicitly at the top of your analysis.

**Bloat-table findings understood as AX cleanup-routine targets.**
When `largest_tables` is dominated by `INVENTSUMLOGTTS`, `SYSDATABASELOG`,
`BATCHJOBHISTORY`, `AIFMESSAGELOG`, or `EVENTINBOX`, record the row counts and sizes as a
baseline before any action — these numbers confirm that cleanup routines are overdue and
give you a before/after reference. Do not recommend SQL-level truncation (see Gotchas).

**Capture a baseline.**
Note the top-3 wait types (with totals), the top query by total reads, any blocking head
blockers, and the largest tables with their sizes. This baseline is the benchmark for the
output verification step below.

### Output verification: confirm the AX-side fix moved the metric

AX fixes go through the AOT or supported cleanup routines — not raw SQL. After applying any
change, re-run the full snapshot (same `-Sections all`, same database) and compare against
the baseline captured above.

**AOT index sync.**
After adding or adjusting an AOT index and running a database synchronisation, re-run the
snapshot and confirm: (a) the index appears in the SQL catalog (verify via SSMS or
`sys.indexes`, not the DMV alone), (b) the `missing_indexes` entry for that table/column
set has dropped or its estimated impact has decreased, and (c) the relevant query's
`total_logical_reads` in `top_queries` has measurably fallen. If the query still shows the
same read count, the synchronisation may not have completed or the AOT change was
incorrect — fail loud.

**Cleanup job.**
After running a bloat-table cleanup routine (batch job history, database log, AIF log,
etc.), re-run `largest_tables` and confirm the affected table has shrunk. If it has not,
the cleanup job may have run against a different date range or encountered an error — check
the batch job log in AX before concluding the problem is resolved.

**RCSI toggle.**
After enabling RCSI (`ALTER DATABASE … SET READ_COMMITTED_SNAPSHOT ON`), re-run `waits`
and `blocking`. The `LCK_M_S` / `LCK_M_IS` share-lock waits should drop substantially.
If they do not, RCSI may not have taken effect (check `database.is_read_committed_snapshot_on`
= `1` in the new snapshot) or a separate locking root cause exists.

**Re-sample transient blocking.**
Blocking chains captured in a single snapshot are a point-in-time picture; they may not
recur. After a fix, collect at least two snapshots during the same business activity
(posting run, MRP batch, POS peak hour) before declaring blocking resolved. If the head
blocker SPID changes but blocking persists, a systemic cause (long transactions, number
sequence contention) remains — do not close the finding on a single clean sample.

**Fail loud on partial coverage.**
If any section in the post-fix snapshot is missing, errored, or covers a shorter uptime
window than the baseline (e.g., instance was restarted between runs), state this explicitly.
Do not claim a metric improved if the before and after snapshots are not comparable.

## What the script can NOT see

- **X++ call sites** — SQL statement text usually identifies the table and pattern, but
  tracing to code needs the AX Trace Parser / SQL statement trace in AX.
- **AOS-side behavior** — caching, record-set sizes, batch scheduling live on the AOS, not
  in SQL DMVs.
- **History** — counters reset at restart; for recurring windows, run during the window.
