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

## What the script can NOT see

- **X++ call sites** — SQL statement text usually identifies the table and pattern, but
  tracing to code needs the AX Trace Parser / SQL statement trace in AX.
- **AOS-side behavior** — caching, record-set sizes, batch scheduling live on the AOS, not
  in SQL DMVs.
- **History** — counters reset at restart; for recurring windows, run during the window.
