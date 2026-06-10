#Requires -Version 7.0
<#
.SYNOPSIS
    Collects a SQL Server performance snapshot tailored to Microsoft Dynamics NAV 2009
    databases and emits JSON. The agent reading the JSON writes the analysis narrative.

.DESCRIPTION
    Connects to a SQL Server instance (Windows integrated auth by default, optional SQL
    auth via -SqlCredential) and gathers DMV-based diagnostics in independent sections:
    server config, database settings, wait stats, top queries, missing/unused indexes,
    current blocking, recent deadlocks (system_health XEvents, SQL 2008+), NAV SIFT
    indexed views, index fragmentation, statistics staleness, and largest tables.

    Each section is wrapped independently: a failing section is reported with
    status=error and its message; the rest still run. The script performs READ-ONLY
    queries only — it never changes server or database state.

.NOTES
    Permissions: VIEW SERVER STATE for DMVs, VIEW DATABASE STATE (or db_owner) in the
    target database. DBCC TRACESTATUS may require sysadmin; that sub-check degrades
    gracefully. All timestamps in the output are SQL Server local time unless noted.
#>
[CmdletBinding()]
param(
    # SQL Server instance, e.g. 'SQLSRV01' or 'SQLSRV01\NAV'
    [Parameter(Mandatory = $true)]
    [string]$ServerInstance,

    # The NAV 2009 database. Omit to run server-level sections only.
    [string]$Database,

    # SQL authentication. Omit to use Windows integrated security.
    [pscredential]$SqlCredential,

    # Which sections to collect. Default: all. Accepts an array or a comma-joined
    # string ('pwsh -File' passes "a,b,c" as one string) — validated below.
    [string[]]$Sections = @('all'),

    # Row cap for each list-producing section.
    [int]$TopN = 20,

    # Per-query timeout in seconds. Fragmentation scans on large DBs may need more.
    [int]$QueryTimeout = 120,

    # Encrypt the connection (off by default — NAV 2009-era instances often lack TLS certs).
    [switch]$Encrypt,

    # Write the full JSON here; stdout then gets a compact summary instead.
    [string]$OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Normalize and validate -Sections ('pwsh -File' delivers "a,b,c" as a single string).
$ValidSections = @('all', 'server', 'database', 'waits', 'top_queries', 'missing_indexes',
    'unused_indexes', 'blocking', 'deadlocks', 'sift', 'fragmentation', 'stats', 'largest_tables')
$Sections = @($Sections | ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
$invalidSections = @($Sections | Where-Object { $ValidSections -notcontains $_ })
if ($invalidSections.Count -gt 0) {
    [Console]::Error.WriteLine("Unknown section(s): $($invalidSections -join ', '). Valid: $($ValidSections -join ', ')")
    exit 1
}

# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------
$csb = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
$csb['Data Source'] = $ServerInstance
$csb['Initial Catalog'] = if ($Database) { $Database } else { 'master' }
$csb['Application Name'] = 'NavSqlPerfTriage'
$csb['Connect Timeout'] = 15
$csb['Encrypt'] = $Encrypt.IsPresent
if ($SqlCredential) {
    $csb['User ID'] = $SqlCredential.UserName
    $csb['Password'] = $SqlCredential.GetNetworkCredential().Password
} else {
    $csb['Integrated Security'] = $true
}

$script:Conn = $null

function Invoke-Sql {
    param(
        [Parameter(Mandatory)] [string]$Query,
        [hashtable]$Parameters = @{}
    )
    $cmd = $script:Conn.CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = $QueryTimeout
    foreach ($key in $Parameters.Keys) {
        [void]$cmd.Parameters.AddWithValue($key, $Parameters[$key])
    }
    $table = [System.Data.DataTable]::new()
    $adapter = [System.Data.SqlClient.SqlDataAdapter]::new($cmd)
    try {
        [void]$adapter.Fill($table)
    } finally {
        $adapter.Dispose()
        $cmd.Dispose()
    }
    $rows = @(foreach ($row in $table.Rows) {
        $obj = [ordered]@{}
        foreach ($col in $table.Columns) {
            $value = $row[$col]
            if ($value -is [System.DBNull]) { $value = $null }
            elseif ($value -is [datetime]) { $value = $value.ToString('yyyy-MM-ddTHH:mm:ss') }
            elseif ($value -is [decimal] -or $value -is [double]) { $value = [math]::Round([double]$value, 2) }
            $obj[$col.ColumnName] = $value
        }
        $obj
    })
    # ',' keeps single-row results an array through pipeline unrolling — callers index with [0]
    return ,$rows
}

# ---------------------------------------------------------------------------
# Section runner
# ---------------------------------------------------------------------------
$result = [ordered]@{
    status       = 'ok'
    generated_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    server       = $ServerInstance
    database     = $Database
    sections     = [ordered]@{}
}

$runAll = $Sections -contains 'all'
function Test-SectionWanted([string]$Name) { return ($runAll -or ($Sections -contains $Name)) }

function Add-Section {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Body,
        [switch]$RequiresDatabase
    )
    if (-not (Test-SectionWanted $Name)) { return }
    if ($RequiresDatabase -and -not $Database) {
        $result.sections[$Name] = [ordered]@{ status = 'skipped'; reason = 'no -Database specified' }
        return
    }
    try {
        $data = & $Body
        $result.sections[$Name] = [ordered]@{ status = 'ok'; data = $data }
    } catch {
        $result.sections[$Name] = [ordered]@{ status = 'error'; error = $_.Exception.Message }
        $result.status = 'partial'
    }
}

# ---------------------------------------------------------------------------
# Connect
# ---------------------------------------------------------------------------
try {
    $script:Conn = [System.Data.SqlClient.SqlConnection]::new($csb.ConnectionString)
    $script:Conn.Open()
} catch {
    $result.status = 'error'
    $result.error = "Cannot connect to '$ServerInstance': $($_.Exception.Message)"
    $result | ConvertTo-Json -Depth 8
    exit 1
}

try {

# ---------------------------------------------------------------------------
# server — version, CPU/memory, key sp_configure values, trace flags, PLE
# ---------------------------------------------------------------------------
Add-Section -Name 'server' -Body {
    $info = [ordered]@{}
    $v = Invoke-Sql "SELECT @@VERSION AS version_string,
                            SERVERPROPERTY('ProductVersion') AS product_version,
                            SERVERPROPERTY('Edition') AS edition,
                            SERVERPROPERTY('ProductLevel') AS product_level"
    $info['version'] = $v[0]

    try {
        $sys = Invoke-Sql "SELECT cpu_count, hyperthread_ratio,
                                  sqlserver_start_time
                           FROM sys.dm_os_sys_info"
        $info['system'] = $sys[0]
    } catch {
        # sqlserver_start_time is missing pre-2008; retry without it
        $sys = Invoke-Sql "SELECT cpu_count, hyperthread_ratio FROM sys.dm_os_sys_info"
        $info['system'] = $sys[0]
    }

    $info['configuration'] = Invoke-Sql "
        SELECT name, CAST(value_in_use AS BIGINT) AS value_in_use
        FROM sys.configurations
        WHERE name IN ('max degree of parallelism', 'cost threshold for parallelism',
                       'max server memory (MB)', 'min server memory (MB)',
                       'optimize for ad hoc workloads', 'priority boost')
        ORDER BY name"

    try {
        $info['trace_flags'] = Invoke-Sql "DBCC TRACESTATUS(-1) WITH NO_INFOMSGS"
    } catch {
        $info['trace_flags'] = "unavailable: $($_.Exception.Message)"
    }

    try {
        $ple = Invoke-Sql "
            SELECT cntr_value AS page_life_expectancy_sec
            FROM sys.dm_os_performance_counters
            WHERE counter_name = 'Page life expectancy'
              AND object_name LIKE '%Buffer Manager%'"
        if ($ple.Count -gt 0) { $info['page_life_expectancy_sec'] = $ple[0].page_life_expectancy_sec }
    } catch { }

    $info
}

# ---------------------------------------------------------------------------
# database — settings, files, tempdb layout
# ---------------------------------------------------------------------------
Add-Section -Name 'database' -RequiresDatabase -Body {
    $info = [ordered]@{}
    $info['settings'] = (Invoke-Sql "
        SELECT name, compatibility_level, recovery_model_desc, page_verify_option_desc,
               is_auto_create_stats_on, is_auto_update_stats_on, is_auto_update_stats_async_on,
               is_read_committed_snapshot_on, is_auto_shrink_on, log_reuse_wait_desc
        FROM sys.databases WHERE name = @db" @{ '@db' = $Database })[0]

    # sys.database_files (db context) — visible with plain db access, unlike sys.master_files
    # which hides rows from logins without VIEW ANY DEFINITION / CREATE DATABASE.
    $info['files'] = Invoke-Sql "
        SELECT name, type_desc, physical_name,
               CAST(size * 8 / 1024.0 AS DECIMAL(18,1)) AS size_mb,
               CASE WHEN is_percent_growth = 1 THEN CAST(growth AS VARCHAR(10)) + ' %'
                    ELSE CAST(growth * 8 / 1024 AS VARCHAR(10)) + ' MB' END AS growth,
               max_size
        FROM sys.database_files"

    $info['tempdb_data_files'] = (Invoke-Sql "
        SELECT COUNT(*) AS n FROM tempdb.sys.database_files WHERE type = 0")[0].n
    $info
}

# ---------------------------------------------------------------------------
# waits — top waits since instance start, benign waits excluded
# ---------------------------------------------------------------------------
Add-Section -Name 'waits' -Body {
    Invoke-Sql "
        SELECT TOP (15)
               wait_type, waiting_tasks_count,
               wait_time_ms, signal_wait_time_ms,
               CAST(100.0 * wait_time_ms / NULLIF(SUM(wait_time_ms) OVER (), 0) AS DECIMAL(5,2)) AS pct_of_shown
        FROM sys.dm_os_wait_stats
        WHERE wait_type NOT IN (
            'CLR_SEMAPHORE','LAZYWRITER_SLEEP','RESOURCE_QUEUE','SQLTRACE_BUFFER_FLUSH',
            'SLEEP_TASK','SLEEP_SYSTEMTASK','WAITFOR','LOGMGR_QUEUE','CHECKPOINT_QUEUE',
            'REQUEST_FOR_DEADLOCK_SEARCH','XE_TIMER_EVENT','BROKER_TO_FLUSH','BROKER_TASK_STOP',
            'CLR_MANUAL_EVENT','CLR_AUTO_EVENT','DISPATCHER_QUEUE_SEMAPHORE','FT_IFTS_SCHEDULER_IDLE_WAIT',
            'XE_DISPATCHER_WAIT','XE_DISPATCHER_JOIN','BROKER_EVENTHANDLER','TRACEWRITE',
            'FT_IFTSHC_MUTEX','SQLTRACE_INCREMENTAL_FLUSH_SLEEP','BROKER_RECEIVE_WAITFOR',
            'ONDEMAND_TASK_QUEUE','DBMIRROR_EVENTS_QUEUE','DBMIRRORING_CMD','SP_SERVER_DIAGNOSTICS_SLEEP',
            'HADR_FILESTREAM_IOMGR_IOCOMPLETION','DIRTY_PAGE_POLL',
            'HADR_WORK_QUEUE','HADR_NOTIFICATION_DEQUEUE','HADR_TIMER_TASK','HADR_CLUSAPI_CALL',
            'HADR_LOGCAPTURE_WAIT','PARALLEL_REDO_WORKER_WAIT_WORK','PARALLEL_REDO_DRAIN_WORKER',
            'REDO_THREAD_PENDING_WORK','VDI_CLIENT_OTHER','BROKER_TRANSMITTER','SLEEP_BPOOL_FLUSH',
            'QDS_ASYNC_QUEUE','QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
            'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP','SQLTRACE_WAIT_ENTRIES',
            'SOS_WORK_DISPATCHER','WAIT_XTP_HOST_WAIT','WAIT_XTP_RECOVERY',
            'WAIT_XTP_OFFLINE_CKPT_NEW_LOG','WAIT_XTP_CKPT_CLOSE')
          AND waiting_tasks_count > 0
        ORDER BY wait_time_ms DESC"
}

# ---------------------------------------------------------------------------
# top_queries — by CPU and by logical reads (plan cache; resets on restart/eviction)
# ---------------------------------------------------------------------------
Add-Section -Name 'top_queries' -Body {
    $statement = "
        SELECT TOP (@top)
               qs.execution_count,
               qs.total_worker_time / 1000 AS total_cpu_ms,
               qs.total_worker_time / NULLIF(qs.execution_count, 0) / 1000 AS avg_cpu_ms,
               qs.total_logical_reads,
               qs.total_logical_reads / NULLIF(qs.execution_count, 0) AS avg_logical_reads,
               qs.total_elapsed_time / 1000 AS total_elapsed_ms,
               qs.max_elapsed_time / 1000 AS max_elapsed_ms,
               qs.last_execution_time,
               DB_NAME(st.dbid) AS database_name,
               LEFT(SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
                    ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text)
                      ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2) + 1), 500) AS statement_text
        FROM sys.dm_exec_query_stats qs
        CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
        ORDER BY {0} DESC"
    [ordered]@{
        note     = 'From plan cache: cumulative since plan compile; cleared by restarts and memory pressure. NAV 2009 ad hoc/cursor statements may show database_name = null.'
        by_cpu   = Invoke-Sql ($statement -f 'qs.total_worker_time') @{ '@top' = $TopN }
        by_reads = Invoke-Sql ($statement -f 'qs.total_logical_reads') @{ '@top' = $TopN }
    }
}

# ---------------------------------------------------------------------------
# missing_indexes — optimizer suggestions for the target database
# ---------------------------------------------------------------------------
Add-Section -Name 'missing_indexes' -RequiresDatabase -Body {
    Invoke-Sql "
        SELECT TOP (@top)
               CAST(migs.avg_total_user_cost * migs.avg_user_impact *
                    (migs.user_seeks + migs.user_scans) AS BIGINT) AS improvement_measure,
               OBJECT_NAME(mid.object_id, mid.database_id) AS table_name,
               mid.equality_columns, mid.inequality_columns, mid.included_columns,
               migs.user_seeks, migs.user_scans, migs.last_user_seek
        FROM sys.dm_db_missing_index_groups mig
        JOIN sys.dm_db_missing_index_group_stats migs ON migs.group_handle = mig.index_group_handle
        JOIN sys.dm_db_missing_index_details mid ON mid.index_handle = mig.index_handle
        WHERE mid.database_id = DB_ID()
        ORDER BY improvement_measure DESC" @{ '@top' = $TopN }
}

# ---------------------------------------------------------------------------
# unused_indexes — written to but never read since instance start
# ---------------------------------------------------------------------------
Add-Section -Name 'unused_indexes' -RequiresDatabase -Body {
    Invoke-Sql "
        SELECT TOP (@top)
               OBJECT_NAME(i.object_id) AS table_name, i.name AS index_name,
               ius.user_updates,
               CAST(sz.used_mb AS DECIMAL(18,1)) AS used_mb
        FROM sys.indexes i
        JOIN sys.dm_db_index_usage_stats ius
          ON ius.object_id = i.object_id AND ius.index_id = i.index_id AND ius.database_id = DB_ID()
        CROSS APPLY (SELECT SUM(ps.used_page_count) * 8 / 1024.0 AS used_mb
                     FROM sys.dm_db_partition_stats ps
                     WHERE ps.object_id = i.object_id AND ps.index_id = i.index_id) sz
        WHERE i.type = 2 AND i.is_primary_key = 0 AND i.is_unique_constraint = 0
          AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
          AND ius.user_seeks + ius.user_scans + ius.user_lookups = 0
          AND ius.user_updates > 1000
        ORDER BY sz.used_mb DESC" @{ '@top' = $TopN }
}

# ---------------------------------------------------------------------------
# blocking — current blocking chains (point-in-time snapshot)
# ---------------------------------------------------------------------------
Add-Section -Name 'blocking' -Body {
    Invoke-Sql "
        SELECT r.session_id, r.blocking_session_id, r.wait_type,
               r.wait_time AS wait_time_ms, r.wait_resource,
               DB_NAME(r.database_id) AS database_name, r.command,
               s.login_name, s.host_name, s.program_name,
               LEFT(st.text, 400) AS statement_text
        FROM sys.dm_exec_requests r
        JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
        OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) st
        WHERE r.blocking_session_id <> 0
        ORDER BY r.wait_time DESC"
}

# ---------------------------------------------------------------------------
# deadlocks — recent deadlock graphs from system_health (SQL 2008+)
# ---------------------------------------------------------------------------
Add-Section -Name 'deadlocks' -Body {
    $rows = Invoke-Sql "
        SELECT CAST(st.target_data AS NVARCHAR(MAX)) AS target_data
        FROM sys.dm_xe_session_targets st
        JOIN sys.dm_xe_sessions s ON s.address = st.event_session_address
        WHERE s.name = 'system_health' AND st.target_name = 'ring_buffer'"
    if ($rows.Count -eq 0) {
        return [ordered]@{ note = 'system_health Extended Events session not found (SQL Server 2005 has no XEvents).'; deadlocks = @() }
    }
    [xml]$buffer = $rows[0].target_data
    $events = @($buffer.SelectNodes("//event[@name='xml_deadlock_report']") | Select-Object -Last $TopN)
    $deadlocks = @(foreach ($evt in $events) {
        $entry = [ordered]@{ timestamp = $evt.GetAttribute('timestamp') }
        try {
            $graphNodes = @($evt.SelectNodes(".//deadlock"))
            if ($graphNodes.Count -gt 0) {
                $graph = $graphNodes[0]
                $entry['victim'] = $graph.GetAttribute('victim')
                $entry['processes'] = @(foreach ($p in @($graph.SelectNodes('.//process-list/process'))) {
                    $inputbuf = $p.SelectSingleNode('inputbuf')
                    $inputText = if ($inputbuf -and $inputbuf.InnerText) { $inputbuf.InnerText.Trim() } else { $null }
                    [ordered]@{
                        id              = $p.GetAttribute('id')
                        login           = $p.GetAttribute('loginname')
                        host            = $p.GetAttribute('hostname')
                        application     = $p.GetAttribute('clientapp')
                        isolation_level = $p.GetAttribute('isolationlevel')
                        wait_resource   = $p.GetAttribute('waitresource')
                        input_buffer    = if ($inputText) { $inputText.Substring(0, [math]::Min(300, $inputText.Length)) } else { $null }
                    }
                })
                $entry['objects'] = @($graph.SelectNodes('.//resource-list/*') |
                    ForEach-Object { $_.GetAttribute('objectname') } |
                    Where-Object { $_ } | Select-Object -Unique)
            } else {
                $entry['raw_xml'] = $evt.OuterXml.Substring(0, [math]::Min(4000, $evt.OuterXml.Length))
            }
        } catch {
            $entry['parse_error'] = $_.Exception.Message
            $entry['raw_xml'] = $evt.OuterXml.Substring(0, [math]::Min(4000, $evt.OuterXml.Length))
        }
        $entry
    })
    [ordered]@{
        note      = 'From the system_health ring buffer — covers recent history only (buffer wraps). Timestamps are UTC.'
        count     = $deadlocks.Count
        deadlocks = $deadlocks
    }
}

# ---------------------------------------------------------------------------
# sift — NAV 2009 SIFT indexed views ($VSIFT$) by size
# ---------------------------------------------------------------------------
Add-Section -Name 'sift' -RequiresDatabase -Body {
    $count = (Invoke-Sql "SELECT COUNT(*) AS n FROM sys.views WHERE name LIKE '%[$]VSIFT[$]%'")[0].n
    $largest = Invoke-Sql "
        SELECT TOP (@top)
               v.name AS view_name,
               CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS DECIMAL(18,1)) AS used_mb,
               SUM(ps.row_count) AS row_count
        FROM sys.views v
        JOIN sys.indexes i ON i.object_id = v.object_id AND i.index_id = 1
        JOIN sys.dm_db_partition_stats ps ON ps.object_id = v.object_id AND ps.index_id = 1
        WHERE v.name LIKE '%[$]VSIFT[$]%'
        GROUP BY v.name
        ORDER BY SUM(ps.used_page_count) DESC" @{ '@top' = $TopN }
    [ordered]@{
        note         = 'NAV 2009 SIFT totals are SQL indexed views named <Company>$<Table>$VSIFT$<Key>. Every base-table write also maintains these views.'
        total_views  = $count
        largest      = $largest
    }
}

# ---------------------------------------------------------------------------
# fragmentation — indexes > 1000 pages with > 30% fragmentation (LIMITED scan)
# ---------------------------------------------------------------------------
Add-Section -Name 'fragmentation' -RequiresDatabase -Body {
    Invoke-Sql "
        SELECT TOP (@top)
               OBJECT_NAME(ips.object_id) AS table_name, i.name AS index_name,
               ips.index_type_desc,
               CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,1)) AS avg_fragmentation_pct,
               ips.page_count
        FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
        JOIN sys.indexes i ON i.object_id = ips.object_id AND i.index_id = ips.index_id
        WHERE ips.page_count > 1000 AND ips.avg_fragmentation_in_percent > 30
          AND ips.alloc_unit_type_desc = 'IN_ROW_DATA'
        ORDER BY ips.page_count DESC" @{ '@top' = $TopN }
}

# ---------------------------------------------------------------------------
# stats — stale statistics on large tables (modern DMF, legacy fallback)
# ---------------------------------------------------------------------------
Add-Section -Name 'stats' -RequiresDatabase -Body {
    try {
        $rows = Invoke-Sql "
            SELECT TOP (@top)
                   OBJECT_NAME(s.object_id) AS table_name, s.name AS stats_name,
                   STATS_DATE(s.object_id, s.stats_id) AS last_updated,
                   sp.rows, sp.modification_counter
            FROM sys.stats s
            CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
            WHERE OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
              AND sp.rows > 100000
              AND (sp.modification_counter > 0.10 * sp.rows
                   OR STATS_DATE(s.object_id, s.stats_id) < DATEADD(DAY, -30, GETDATE()))
            ORDER BY sp.modification_counter DESC" @{ '@top' = $TopN }
        [ordered]@{ method = 'dm_db_stats_properties'; data = $rows }
    } catch {
        # dm_db_stats_properties needs SQL 2008 R2 SP2+ — fall back to sysindexes.rowmodctr
        $rows = Invoke-Sql "
            SELECT TOP (@top)
                   OBJECT_NAME(si.id) AS table_name, si.name AS stats_name,
                   STATS_DATE(si.id, si.indid) AS last_updated,
                   si.rowcnt AS rows, si.rowmodctr AS modification_counter
            FROM sys.sysindexes si
            WHERE OBJECTPROPERTY(si.id, 'IsUserTable') = 1
              AND si.rowcnt > 100000 AND si.indid > 0
              AND (si.rowmodctr > 0.10 * si.rowcnt
                   OR STATS_DATE(si.id, si.indid) < DATEADD(DAY, -30, GETDATE()))
            ORDER BY si.rowmodctr DESC" @{ '@top' = $TopN }
        [ordered]@{ method = 'sysindexes.rowmodctr (legacy fallback)'; data = $rows }
    }
}

# ---------------------------------------------------------------------------
# largest_tables — by total size including indexes
# ---------------------------------------------------------------------------
Add-Section -Name 'largest_tables' -RequiresDatabase -Body {
    Invoke-Sql "
        SELECT TOP (@top)
               t.name AS table_name,
               MAX(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count ELSE 0 END) AS row_count,
               CAST(SUM(ps.used_page_count) * 8 / 1024.0 AS DECIMAL(18,1)) AS total_used_mb,
               COUNT(DISTINCT CASE WHEN ps.index_id > 1 THEN ps.index_id END) AS nonclustered_index_count
        FROM sys.tables t
        JOIN sys.dm_db_partition_stats ps ON ps.object_id = t.object_id
        GROUP BY t.name
        ORDER BY SUM(ps.used_page_count) DESC" @{ '@top' = $TopN }
}

} finally {
    if ($script:Conn) { $script:Conn.Dispose() }
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
$json = $result | ConvertTo-Json -Depth 10

if ($OutFile) {
    $json | Set-Content -Path $OutFile -Encoding utf8
    $summary = [ordered]@{
        status       = $result.status
        generated_at = $result.generated_at
        server       = $ServerInstance
        database     = $Database
        out_file     = $OutFile
        sections     = [ordered]@{}
    }
    foreach ($name in $result.sections.Keys) {
        $section = $result.sections[$name]
        $entry = [ordered]@{ status = $section.status }
        if ($section.status -eq 'error') { $entry['error'] = $section.error }
        if ($section.status -eq 'skipped') { $entry['reason'] = $section.reason }
        if ($section.status -eq 'ok' -and $section.data -is [System.Collections.IList]) {
            $entry['rows'] = @($section.data).Count
        }
        $summary.sections[$name] = $entry
    }
    $summary | ConvertTo-Json -Depth 5
} else {
    $json
}
