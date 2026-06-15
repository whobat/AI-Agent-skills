# nav2009-db-maintenance — Reference

Detailed reference for `scripts/Invoke-NavDbMaintenance.ps1`. For the agent-facing workflow
see [SKILL.md](SKILL.md).

## Requirements

- **PowerShell 7+** (`pwsh`) on the machine running the script (uses the bundled
  `System.Data.SqlClient`). The repo installer auto-installs it.
- Network access to the SQL Server instance (default port 1433; named instances need SQL Browser
  or an explicit port).
- SQL permissions — see [SKILL.md §Permissions & auth](SKILL.md).
- Works against SQL Server **2005 → 2019+**. Version-dependent behavior:
  - `ONLINE` index rebuild requires **Enterprise edition** — fails with a clear error on
    Standard/Web/Express; remove `-Online` and use an offline maintenance window instead.
  - `BACKUP ... WITH COMPRESSION` is available from SQL Server 2008 Standard and later, and from
    SQL Server 2005 SP2+ Enterprise. The script wraps COMPRESSION in the statement; if the target
    instance does not support it, remove it or accept the error.

## Parameters

| Parameter | Type | Default | Notes |
|-----------|------|---------|-------|
| `-ServerInstance` | string | — | Required. `HOST` or `HOST\INSTANCE`. |
| `-Database` | string | — | Required. The NAV database to maintain. |
| `-SqlCredential` | pscredential | — | SQL auth. Omit for Windows integrated auth. |
| `-Actions` | string[] | `all` | Any of: `all backup checkdb index_maintenance statistics`. |
| `-BackupPath` | string | auto | File path (`.bak`) or directory for the backup. Default: `$env:TEMP\<DB>_<UTC>.bak`. |
| `-ReorganizeThreshold` | int | 10 | Avg fragmentation % at or above which an index is reorganized. |
| `-RebuildThreshold` | int | 30 | Avg fragmentation % at or above which an index is rebuilt. |
| `-MinPageCount` | int | 1000 | Indexes with fewer pages are skipped (fragmentation noise on small indexes). |
| `-Online` | switch | off | Use `ONLINE = ON` for index rebuilds (Enterprise edition only). |
| `-Execute` | switch | off | Actually run the T-SQL. Without this, dry run only. |
| `-Encrypt` | switch | off | Encrypt the connection. Off by default for old instances. |
| `-QueryTimeout` | int | 600 | Seconds per query. Index rebuild and CHECKDB on large DBs can be long-running. |
| `-OutFile` | string | — | Full JSON to file; stdout becomes the compact summary. |

## What each action does

### backup

Generates a `BACKUP DATABASE` statement to disk:

```sql
BACKUP DATABASE [<DB>] TO DISK = N'<path>'
WITH CHECKSUM, INIT, COMPRESSION, STATS = 10
```

- **CHECKSUM** — verifies page checksums during backup; catches corruption early.
- **INIT** — overwrites the backup file (use a timestamped path to keep history).
- **COMPRESSION** — reduces backup file size and I/O; available SQL 2008 Standard+. Remove if
  using SQL 2005 Standard.
- The backup path is resolved on the **SQL Server machine**, not the client. Ensure the SQL
  Server service account can write to it.
- This is a **SQL Server backup** (`.bak` file), not a NAV native `.fbk` backup. The `.fbk`
  format is only for the deprecated native NAV database engine and is not used with SQL Server.

### checkdb

```sql
DBCC CHECKDB (N'<DB>') WITH NO_INFOMSGS, ALL_ERRORMSGS
```

Checks physical and logical integrity of all objects in the database. Can take minutes to hours
on large NAV databases. Runs entirely inside SQL Server; holds shared locks on objects.
**Recommend a maintenance window or use DBCC CHECKDB ... WITH PHYSICAL_ONLY for a faster partial
check during business hours.**

### index_maintenance

1. Runs a **read-only** fragmentation query against `sys.dm_db_index_physical_stats` (LIMITED mode)
   joined to `sys.indexes` and `sys.tables`. Indexes below `-MinPageCount` pages are ignored
   (fragmentation on small indexes is noise and recovery is instant anyway).

2. Buckets surviving indexes by fragmentation:
   - `avg_fragmentation_in_percent` **≥ RebuildThreshold** (default 30%) → `ALTER INDEX ... REBUILD`
   - `avg_fragmentation_in_percent` **≥ ReorganizeThreshold** (default 10%) → `ALTER INDEX ... REORGANIZE`
   - Below ReorganizeThreshold → skipped

3. Generates `ALTER INDEX [name] ON [table] REBUILD WITH (ONLINE = ON|OFF)` or
   `ALTER INDEX [name] ON [table] REORGANIZE` statements — **one per index**.

**NAV-owns-indexes rule (critical):** The script NEVER issues `CREATE INDEX` or `DROP INDEX`.
NAV 2009 creates and manages all indexes through the C/SIDE table designer:
- Regular keys → `MaintainSQLIndex = Yes` → SQL nonclustered index
- SIFT keys (SumIndexFields) → `MaintainSIFTIndex = Yes` → SQL schema-bound indexed view (`$VSIFT$`)

Out-of-band SQL DDL (creating/dropping indexes in SSMS) is **silently overwritten** when NAV
rebuilds the table (key changes, company renames, upgrades). Maintenance here means keeping the
NAV-owned indexes healthy, not changing what exists.

SIFT indexed views (`%$VSIFT$%`) are treated as regular indexes for fragmentation purposes and
are included in the rebuild/reorganize plan. They are NAV-owned and must not be dropped.

### statistics

```sql
EXEC sp_updatestats
```

Updates statistics for all tables in the database that have been modified since statistics were
last updated. Lightweight; does not rebuild indexes. Run this after index maintenance or after
large posting batches.

## Output schema

```json
{
  "status": "ok | partial | error",
  "generated_at": "2026-06-10T09:00:00Z",
  "executed": false,
  "server": "SQLSRV01",
  "database": "NAV_PROD",
  "sections": {
    "backup": {
      "status": "planned | ok | error | skipped",
      "plan":   ["BACKUP DATABASE ..."],
      "data":   { "backup_file": "...", "size_mb": 1234.5 },
      "error":  "message when status=error"
    },
    "checkdb": {
      "status": "planned | ok | error | skipped",
      "plan":   ["DBCC CHECKDB (...)"],
      "data":   { "result": "CHECKDB found 0 allocation errors..." }
    },
    "index_maintenance": {
      "status": "planned | ok | error | skipped",
      "plan":   ["ALTER INDEX [...] ON [...] REBUILD WITH (ONLINE = OFF)", "..."],
      "data":   { "rebuilt": 3, "reorganized": 5, "skipped": 12 }
    },
    "statistics": {
      "status": "planned | ok | error | skipped",
      "plan":   ["EXEC sp_updatestats"],
      "data":   { "rows_affected": 42 }
    }
  }
}
```

With `-OutFile`, stdout instead carries:
```json
{ "status": "ok", "generated_at": "...", "executed": false, "out_file": "C:\\...", "sections": { "<name>": { "status": "planned" } } }
```

## Safety & gotchas

| Topic | Detail |
|-------|--------|
| **Dry-run default** | Without `-Execute` the script returns `status: planned` and the T-SQL it would run. No database state is changed. Always review the plan before executing. |
| **Maintenance window** | Index rebuild (especially OFFLINE) and CHECKDB hold locks and can be I/O-intensive. Schedule outside peak NAV posting hours. Even REORGANIZE generates log; ensure the transaction log has room. |
| **ONLINE edition requirement** | `REBUILD WITH (ONLINE=ON)` requires Enterprise edition. On Standard/Web/Express remove `-Online` and schedule offline rebuild during a quiet window. |
| **Never DDL on NAV indexes** | The script asserts this by construction: `ALTER INDEX REBUILD/REORGANIZE` only. Fragmentation that cannot be fixed by maintenance is a key/SIFT design issue — see **nav2009-development**. |
| **SIFT views are NAV-owned** | `$VSIFT$` indexed views appear in the index maintenance plan and are safe to rebuild/reorganize. They must NEVER be dropped out-of-band. |
| **Backup path is server-side** | The path in `-BackupPath` is resolved on the SQL Server, not the machine running the script. Use a UNC path the SQL Server service account can write to, or a local path on the SQL Server host. |
| **COMPRESSION compatibility** | `WITH COMPRESSION` in BACKUP requires SQL 2008 Standard+ or SQL 2005 Enterprise SP2+. Omit it or catch the error on older editions. |
| **Stats after index rebuild** | `ALTER INDEX REBUILD` implicitly updates statistics for the rebuilt index. `sp_updatestats` afterward covers any remaining stale stats on unrebult tables. |

## Gotchas

**The dry run prints T-SQL but executes nothing — confirm `"executed": true` in the output before trusting the result.**
Without `-Execute` every section returns `status: planned` and the `plan` array contains the T-SQL the script *would* run. Nothing is changed on the server. The trap is running the script, seeing a long list of `ALTER INDEX` statements in the output, and assuming the job is done. Always re-run with `-Execute` and verify that the returned JSON shows `"executed": true` and each section reports `status: ok` before marking the maintenance task complete.

**`sp_updatestats` uses sampling on large tables — stale statistics on high-volume NAV tables may survive it.**
`sp_updatestats` skips objects whose row count has not changed since the last update, and for objects it does update it uses the SQL Server default sample rate, which shrinks to a small percentage on tables with millions of rows (the `Item Ledger Entry` or `G/L Entry` table on a busy NAV instance can have tens of millions of rows). Auto-update-statistics fires at the same sampled rate. If the query optimizer picks bad plans on large posting tables after a maintenance pass, run `UPDATE STATISTICS [dbo].[<Table>] WITH FULLSCAN` on the specific table to force a complete scan. Use `sys.dm_db_stats_properties` to check `last_updated` and `rows_sampled` vs `rows` to confirm whether sampling is the issue.

**Rebuilding clustered indexes and SIFT indexed views is offline and blocking on Standard edition — it holds an exclusive lock for the entire duration.**
When the fragmentation query flags a clustered index or a `$VSIFT$` indexed view for rebuild, the generated `ALTER INDEX ... REBUILD WITH (ONLINE = OFF)` statement acquires a schema modification lock that blocks all reads and writes on that table (or the base table of the view) until the rebuild completes. On a large posting table this can run for many minutes. On SQL Server Standard edition `ONLINE = ON` is not available, so the only safe path is to run index rebuilds in a scheduled maintenance window when no NAV clients or posting jobs are active. Check for blocking before executing: `SELECT * FROM sys.dm_exec_requests WHERE blocking_session_id <> 0`.

**A SQL Server `.bak` backup and a NAV native `.fbk` backup are different artifacts — only the `.bak` is a valid DR copy of the SQL database.**
The NAV client's `Backup Company` function produces a `.fbk` file in the deprecated NAV native database format. It does not back up the SQL Server database. A SQL-hosted NAV 2009 installation requires a SQL Server backup (`.bak`) for disaster recovery, point-in-time restore, and log shipping. If users report "we backed up NAV last night" and produced a `.fbk`, the SQL database itself has no verified backup. Confirm a `.bak` (or equivalent snapshot/log backup chain) exists on the SQL Server before treating the database as protected.

**DBCC CHECKDB on a busy production instance competes heavily for I/O and tempdb — run it during a low-activity window.**
`DBCC CHECKDB` reads every page of every object in the database using an internal database snapshot (on SQL 2005 SP2+ with sufficient disk space in tempdb), and on older or resource-constrained instances it can fall back to acquiring shared locks on objects instead. Both paths generate significant I/O that competes directly with NAV posting and report queries. On a large NAV database (tens of GB) a full `CHECKDB` can run for hours. If daytime integrity validation is required, use `DBCC CHECKDB ('<DB>') WITH PHYSICAL_ONLY` for a fast page-level check and defer the full logical consistency check to an overnight window.

**Environment-specific gotchas (local).** At the start of a run, read `gotchas.local.md` in this skill's folder if it exists — it records traps learned in *this* environment (real server/database names, local quirks, naming conventions). When you discover a new environment-specific pitfall here, **append it to `gotchas.local.md`** (not to this file, which must stay generic and company-agnostic). The file is gitignored and is preserved across skill updates, so this skill gets more useful every time it runs in your environment.

## Verification

This is an ACTION skill — backup, CHECKDB, index rebuild, and statistics update all change database state. Verify at each phase.

### BEFORE running with `-Execute`

1. **Run the dry run first and read the T-SQL.** Execute the script without `-Execute` and inspect every `plan` array in the returned JSON. Confirm the statements target the correct server, database, and indexes before proceeding. Do not skip this step even for routine maintenance.

2. **Confirm a current backup exists before any destructive or heavy operation.** Before running CHECKDB or index rebuild, verify that a recent SQL Server `.bak` backup has been taken and is restorable. A failed CHECKDB or an interrupted rebuild that leaves an index in an inconsistent state is recoverable only if a good backup exists. Do not rely on a `.fbk` (NAV native backup) — it is not a SQL Server backup (see Gotchas).

3. **Confirm a maintenance window is in place for rebuilds and CHECKDB.** Index rebuild (`OFFLINE`) and a full CHECKDB acquire locks that block all reads and writes on affected tables for the duration. On Standard edition `ONLINE = ON` is unavailable. Verify that no NAV clients are posting, no scheduled posting jobs are running, and no reports are active before issuing `-Execute` for these actions.

4. **Confirm you are not creating or dropping indexes.** The planned T-SQL must contain only `ALTER INDEX ... REBUILD` or `ALTER INDEX ... REORGANIZE` statements for index maintenance. Any `CREATE INDEX` or `DROP INDEX` in the plan is a defect — do not execute it.

### OUTPUT verification (after `-Execute`)

1. **Confirm execution actually happened.** Check that the top-level `"executed"` field in the JSON is `true`. If it is `false`, the script ran in dry-run mode — re-run with `-Execute`.

2. **Check each section's `status`.** Every requested action should show `status: ok`. A status of `planned`, `skipped`, or `error` means the action did not complete successfully. Fail loud — do not report maintenance as done if any section was not `ok`.

3. **Verify backup restorability.** After a backup action, run `RESTORE VERIFYONLY FROM DISK = N'<path>'` against the `.bak` file to confirm the backup is readable and structurally valid. A backup that cannot be verified is not a usable backup.

4. **Verify CHECKDB returned 0 errors.** In the `checkdb.data.result` field, confirm the message contains `CHECKDB found 0 allocation errors and 0 consistency errors`. Any non-zero error count must be investigated immediately — do not proceed with other maintenance actions until the integrity issue is understood.

5. **Verify fragmentation dropped after index maintenance.** Re-run the fragmentation query from **nav2009-sql-performance** (or a direct `sys.dm_db_index_physical_stats` query) on the rebuilt/reorganized indexes and confirm `avg_fragmentation_in_percent` is below the reorganize threshold. If fragmentation is unchanged, the rebuild may have been skipped or interrupted.

6. **Verify statistics were updated after a statistics action.** Query `sys.dm_db_stats_properties` on high-volume tables (e.g., `Item Ledger Entry`, `G/L Entry`) and confirm `last_updated` reflects the current maintenance window. If `rows_sampled` is significantly below `rows`, consider a targeted `UPDATE STATISTICS ... WITH FULLSCAN` on those tables.
