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
