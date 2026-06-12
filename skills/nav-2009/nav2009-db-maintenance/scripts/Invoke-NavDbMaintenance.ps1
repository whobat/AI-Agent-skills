#Requires -Version 7.0
<#
.SYNOPSIS
    Plans and (with -Execute) runs SQL Server maintenance on a Dynamics NAV 2009 database,
    emitting JSON. Without -Execute the script is a safe dry run: it returns the exact T-SQL
    it would run but changes nothing.

.DESCRIPTION
    Connects to a SQL Server instance (Windows integrated auth by default, optional SQL auth
    via -SqlCredential) and for each requested action either plans or executes:

      backup            -- BACKUP DATABASE ... TO DISK WITH CHECKSUM, INIT, COMPRESSION
      checkdb           -- DBCC CHECKDB (...) WITH NO_INFOMSGS, ALL_ERRORMSGS
      index_maintenance -- ALTER INDEX REBUILD / REORGANIZE on fragmented NAV-owned indexes
      statistics        -- EXEC sp_updatestats

    CRITICAL: The script NEVER issues CREATE INDEX or DROP INDEX. NAV 2009 owns the physical
    schema through C/SIDE table Keys (MaintainSQLIndex) and SIFT indexed views (MaintainSIFTIndex).
    Out-of-band DDL is silently lost when NAV rebuilds objects. This script only REBUILDS or
    REORGANIZES existing indexes.

    Each action is wrapped independently: a failing action is reported with status=error and
    its message; the rest still run.

.NOTES
    Permissions:
      backup            -- db_backupoperator or db_owner
      checkdb           -- db_owner or sysadmin
      index_maintenance -- db_owner or ALTER permission on indexes
      statistics        -- db_owner or UPDATE STATISTICS permission
#>
[CmdletBinding()]
param(
    # SQL Server instance, e.g. 'SQLSRV01' or 'SQLSRV01\NAV'
    [Parameter(Mandatory = $true)]
    [string]$ServerInstance,

    # The NAV 2009 database to maintain.
    [Parameter(Mandatory = $true)]
    [string]$Database,

    # SQL authentication credential. Omit to use Windows integrated security.
    [pscredential]$SqlCredential,

    # Which actions to include. Default: all.
    [ValidateSet('all', 'backup', 'checkdb', 'index_maintenance', 'statistics')]
    [string[]]$Actions = @('all'),

    # Backup destination: a .bak file path or a directory (script appends <DB>_<UTC>.bak).
    # Resolved on the SQL Server host, not the client machine.
    [string]$BackupPath,

    # Avg fragmentation % at or above which an index is reorganized (and below RebuildThreshold).
    [int]$ReorganizeThreshold = 10,

    # Avg fragmentation % at or above which an index is fully rebuilt.
    [int]$RebuildThreshold = 30,

    # Indexes with fewer pages than this are skipped (fragmentation on tiny indexes is noise).
    [int]$MinPageCount = 1000,

    # Use ONLINE = ON for index rebuilds. Requires Enterprise edition.
    [switch]$Online,

    # Actually run the T-SQL. Without this switch the script is a dry run only.
    [switch]$Execute,

    # Encrypt the connection (off by default — NAV 2009-era instances often lack TLS certs).
    [switch]$Encrypt,

    # Per-query timeout in seconds. Index rebuild and CHECKDB can be long-running.
    [int]$QueryTimeout = 600,

    # Write the full JSON here; stdout then gets a compact summary instead.
    [string]$OutFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------
$csb = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
$csb['Data Source']        = $ServerInstance
$csb['Initial Catalog']    = $Database
$csb['Application Name']   = 'NavDbMaintenance'
$csb['Connect Timeout']    = 15
$csb['Encrypt']            = $Encrypt.IsPresent
if ($SqlCredential) {
    $csb['User ID']  = $SqlCredential.UserName
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
    $cmd.CommandText    = $Query
    $cmd.CommandTimeout = $QueryTimeout
    foreach ($key in $Parameters.Keys) {
        [void]$cmd.Parameters.AddWithValue($key, $Parameters[$key])
    }
    $table   = [System.Data.DataTable]::new()
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
            if ($value -is [System.DBNull])                         { $value = $null }
            elseif ($value -is [datetime])                          { $value = $value.ToString('yyyy-MM-ddTHH:mm:ss') }
            elseif ($value -is [decimal] -or $value -is [double])   { $value = [math]::Round([double]$value, 2) }
            $obj[$col.ColumnName] = $value
        }
        $obj
    })
    # Trailing comma keeps single-row results as an array through pipeline unrolling
    return ,$rows
}

function Invoke-SqlNonQuery {
    param([Parameter(Mandatory)] [string]$Query)
    $cmd = $script:Conn.CreateCommand()
    $cmd.CommandText    = $Query
    $cmd.CommandTimeout = $QueryTimeout
    try {
        return $cmd.ExecuteNonQuery()
    } finally {
        $cmd.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Result envelope
# ---------------------------------------------------------------------------
$result = [ordered]@{
    status       = 'ok'
    generated_at = [datetime]::UtcNow.ToString('o')
    executed     = $Execute.IsPresent
    server       = $ServerInstance
    database     = $Database
    sections     = [ordered]@{}
}

$runAll = $Actions -contains 'all'
function Test-ActionWanted([string]$Name) { return ($runAll -or ($Actions -contains $Name)) }

function Add-Action {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Body
    )
    if (-not (Test-ActionWanted $Name)) { return }
    try {
        $data = & $Body
        $result.sections[$Name] = $data
        if ($data.status -eq 'error') { $result.status = 'partial' }
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
    $result.error  = "Cannot connect to '$ServerInstance': $($_.Exception.Message)"
    $result | ConvertTo-Json -Depth 8
    exit 1
}

try {

# ---------------------------------------------------------------------------
# backup — BACKUP DATABASE ... TO DISK WITH CHECKSUM, INIT, COMPRESSION
# ---------------------------------------------------------------------------
Add-Action -Name 'backup' -Body {
    # Resolve backup path
    if (-not $BackupPath) {
        $ts   = [datetime]::UtcNow.ToString('yyyyMMdd_HHmmss')
        $bak  = "${Database}_${ts}.bak"
        $path = Join-Path $env:TEMP $bak
    } elseif ($BackupPath -notmatch '\.bak$') {
        $ts   = [datetime]::UtcNow.ToString('yyyyMMdd_HHmmss')
        $path = Join-Path $BackupPath "${Database}_${ts}.bak"
    } else {
        $path = $BackupPath
    }

    # NOTE: COMPRESSION requires SQL Server 2008 Standard+ or 2005 Enterprise SP2+.
    # If unsupported, remove WITH COMPRESSION or catch the error.
    $sql = "BACKUP DATABASE [$Database] TO DISK = N'$path' WITH CHECKSUM, INIT, COMPRESSION, STATS = 10"

    $section = [ordered]@{
        status = 'planned'
        plan   = @($sql)
    }

    if ($Execute) {
        try {
            [void](Invoke-SqlNonQuery $sql)
            # Retrieve backup size from msdb
            $sizeRows = Invoke-Sql "
                SELECT TOP 1
                       CAST(backup_size / 1048576.0 AS DECIMAL(18,1)) AS size_mb,
                       compressed_backup_size,
                       physical_device_name
                FROM msdb.dbo.backupset bs
                JOIN msdb.dbo.backupmediafamily bmf
                  ON bmf.media_set_id = bs.media_set_id
                WHERE bs.database_name = @db AND bs.type = 'D'
                ORDER BY bs.backup_finish_date DESC" @{ '@db' = $Database }
            $section['status'] = 'ok'
            $section['data']   = [ordered]@{
                backup_file = $path
                size_mb     = if ($sizeRows.Count -gt 0) { $sizeRows[0].size_mb } else { $null }
            }
        } catch {
            $section['status'] = 'error'
            $section['error']  = $_.Exception.Message
        }
    }
    $section
}

# ---------------------------------------------------------------------------
# checkdb — DBCC CHECKDB WITH NO_INFOMSGS, ALL_ERRORMSGS
# ---------------------------------------------------------------------------
Add-Action -Name 'checkdb' -Body {
    $sql = "DBCC CHECKDB (N'$Database') WITH NO_INFOMSGS, ALL_ERRORMSGS"

    $section = [ordered]@{
        status = 'planned'
        plan   = @($sql)
    }

    if ($Execute) {
        try {
            # DBCC CHECKDB output arrives via informational messages, not a result set.
            $messages = [System.Collections.Generic.List[string]]::new()
            $handler  = [System.Data.SqlClient.SqlInfoMessageEventHandler] {
                param($src, $e)
                $messages.Add($e.Message)
            }
            $script:Conn.add_InfoMessage($handler)
            try {
                [void](Invoke-SqlNonQuery $sql)
            } finally {
                $script:Conn.remove_InfoMessage($handler)
            }
            $section['status'] = 'ok'
            $section['data']   = [ordered]@{
                messages = $messages.ToArray()
                result   = if ($messages.Count -eq 0) { 'CHECKDB found no errors.' } else { $messages[-1] }
            }
        } catch {
            $section['status'] = 'error'
            $section['error']  = $_.Exception.Message
        }
    }
    $section
}

# ---------------------------------------------------------------------------
# index_maintenance — REORGANIZE or REBUILD fragmented NAV-owned indexes.
# NEVER CREATE INDEX or DROP INDEX — NAV owns the physical schema.
# ---------------------------------------------------------------------------
Add-Action -Name 'index_maintenance' -Body {
    # Read fragmentation using LIMITED mode (fast; avoids full page scan).
    # Includes NAV SIFT indexed views ($VSIFT$) — they are NAV-owned and safe to rebuild.
    $fragRows = Invoke-Sql "
        SELECT
               OBJECT_NAME(ips.object_id) AS object_name,
               i.name                     AS index_name,
               ips.index_type_desc,
               CAST(ips.avg_fragmentation_in_percent AS DECIMAL(5,1)) AS avg_frag_pct,
               ips.page_count,
               ips.object_id,
               ips.index_id
        FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
        JOIN sys.indexes i
          ON i.object_id = ips.object_id AND i.index_id = ips.index_id
        WHERE ips.page_count           >= @minPages
          AND ips.avg_fragmentation_in_percent >= @reorgThreshold
          AND ips.alloc_unit_type_desc  = 'IN_ROW_DATA'
          AND i.name IS NOT NULL
        ORDER BY ips.avg_fragmentation_in_percent DESC" @{
            '@minPages'       = $MinPageCount
            '@reorgThreshold' = $ReorganizeThreshold
        }

    $onlineOpt = if ($Online) { 'ON' } else { 'OFF' }

    $rebuildStatements   = [System.Collections.Generic.List[string]]::new()
    $reorganizeStatements = [System.Collections.Generic.List[string]]::new()

    foreach ($row in $fragRows) {
        $obj = $row.object_name
        $idx = $row.index_name
        if ($row.avg_frag_pct -ge $RebuildThreshold) {
            $rebuildStatements.Add("ALTER INDEX [$idx] ON [$obj] REBUILD WITH (ONLINE = $onlineOpt)")
        } else {
            $reorganizeStatements.Add("ALTER INDEX [$idx] ON [$obj] REORGANIZE")
        }
    }

    $plan = @($rebuildStatements) + @($reorganizeStatements)

    $section = [ordered]@{
        status                = 'planned'
        plan                  = $plan
        indexes_to_rebuild    = $rebuildStatements.Count
        indexes_to_reorganize = $reorganizeStatements.Count
        indexes_skipped       = 0   # below threshold — counted below
    }

    # Count skipped (below threshold) for informational purposes
    $skippedRows = Invoke-Sql "
        SELECT COUNT(*) AS n
        FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
        JOIN sys.indexes i
          ON i.object_id = ips.object_id AND i.index_id = ips.index_id
        WHERE ips.page_count            >= @minPages
          AND ips.avg_fragmentation_in_percent < @reorgThreshold
          AND ips.alloc_unit_type_desc   = 'IN_ROW_DATA'
          AND i.name IS NOT NULL" @{
              '@minPages'       = $MinPageCount
              '@reorgThreshold' = $ReorganizeThreshold
          }
    $section['indexes_skipped'] = $skippedRows[0].n

    if ($Execute) {
        $rebuilt    = 0
        $reorganized = 0
        $errors     = [System.Collections.Generic.List[string]]::new()

        foreach ($sql in $rebuildStatements) {
            try {
                [void](Invoke-SqlNonQuery $sql)
                $rebuilt++
            } catch {
                $errors.Add("REBUILD failed ($sql): $($_.Exception.Message)")
            }
        }
        foreach ($sql in $reorganizeStatements) {
            try {
                [void](Invoke-SqlNonQuery $sql)
                $reorganized++
            } catch {
                $errors.Add("REORGANIZE failed ($sql): $($_.Exception.Message)")
            }
        }

        $section['status']     = if ($errors.Count -gt 0 -and ($rebuilt + $reorganized) -eq 0) { 'error' }
                                  elseif ($errors.Count -gt 0) { 'partial' }
                                  else { 'ok' }
        $section['data']       = [ordered]@{
            rebuilt    = $rebuilt
            reorganized = $reorganized
        }
        if ($errors.Count -gt 0) { $section['errors'] = $errors.ToArray() }
    }
    $section
}

# ---------------------------------------------------------------------------
# statistics — EXEC sp_updatestats
# ---------------------------------------------------------------------------
Add-Action -Name 'statistics' -Body {
    $sql = 'EXEC sp_updatestats'

    $section = [ordered]@{
        status = 'planned'
        plan   = @($sql)
    }

    if ($Execute) {
        try {
            $rowsAffected = Invoke-SqlNonQuery $sql
            $section['status'] = 'ok'
            $section['data']   = [ordered]@{ rows_affected = $rowsAffected }
        } catch {
            $section['status'] = 'error'
            $section['error']  = $_.Exception.Message
        }
    }
    $section
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
        executed     = $result.executed
        server       = $ServerInstance
        database     = $Database
        out_file     = $OutFile
        sections     = [ordered]@{}
    }
    foreach ($name in $result.sections.Keys) {
        $section = $result.sections[$name]
        $entry   = [ordered]@{ status = $section.status }
        if ($section.status -eq 'error')   { $entry['error']  = $section.error }
        if ($section.status -eq 'planned') { $entry['statements'] = $section.plan.Count }
        $summary.sections[$name] = $entry
    }
    $summary | ConvertTo-Json -Depth 5
} else {
    $json
}
