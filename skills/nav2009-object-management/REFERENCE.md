# nav2009-object-management — Reference

Detailed reference for `scripts/Invoke-NavObjects.ps1`. For the agent-facing workflow see
[SKILL.md](SKILL.md).

## Requirements

- **PowerShell 7+** (`pwsh`) on the machine running the script. The repo installer
  auto-installs it.
- **finsql.exe** from the NAV 2009 Classic client / development environment install.
  Default probe paths:
  - `C:\Program Files (x86)\Microsoft Dynamics NAV\60\Classic\finsql.exe`
  - `C:\Program Files\Microsoft Dynamics NAV\60\Classic\finsql.exe`
- A valid NAV license loaded for the current Windows user:
  - Developer license — required for Export/Import .txt and Compile.
  - End-user license — sufficient for Import .fob.
- Read/write access to the target SQL Server database.
- Works with the SQL Server version that hosted NAV 2009 (typically SQL Server 2005–2008 R2).

## Parameters

| Parameter | Type | Default | Notes |
|-----------|------|---------|-------|
| `-Command` | `Export` \| `Import` \| `Compile` | — | **Required.** |
| `-ServerName` | string | — | **Required.** SQL Server instance name, e.g. `SQLSRV01` or `SQLSRV01\NAV`. |
| `-Database` | string | — | **Required.** The NAV database name. |
| `-Path` | string | — | Object file path (.txt or .fob). Required for Export and Import. |
| `-Filter` | string | — | NAV object filter, e.g. `Type=Codeunit;ID=50000..50099`. Used by Export and Compile. |
| `-FinSqlPath` | string | auto-detect | Override the finsql.exe path. |
| `-SqlCredential` | pscredential | — | SQL authentication. Omit for Windows integrated auth. |
| `-SyncSchema` | `Default` \| `Yes` \| `No` \| `Force` | `Default` | Maps to `synchronizeschemachanges` (Compile/Import). `Default` omits the parameter. |
| `-ImportAction` | `Default` \| `Overwrite` \| `Skip` | `Default` | finsql `importaction`. `Default` omits the parameter (finsql default is `Overwrite`). |
| `-Execute` | switch | off | Actually launch finsql.exe. Without this the script is a dry run. |
| `-LogPath` | string | `$env:TEMP` | Directory for finsql log files (`navcommandresult.txt`, `naverrorlog.txt`). |
| `-OutFile` | string | — | Write full JSON here; stdout becomes a compact summary. |

## finsql.exe command reference

finsql.exe accepts all arguments as a single comma-separated string in the form
`key=value, key=value, ...`. The script builds this string and passes it as one argument to
`Start-Process`.

### Commands

| Script `-Command` | finsql `command=` value |
|-------------------|------------------------|
| `Export` | `exportobjects` |
| `Import` | `importobjects` |
| `Compile` | `compileobjects` |

### Full finsql argument syntax

```
command=<cmd>, servername=<host>, database=<db>[, file=<path>][, filter=<filter>]
[, importaction=<overwrite|skip>][, synchronizeschemachanges=<force|yes|no>]
[, logfile=<path\navcommandresult.txt>]
[, ntauthentication=yes | ntauthentication=no, username=<u>, password=<p>]
```

### Filter syntax

Filters follow NAV's standard object filter syntax:

```
Type=Codeunit;ID=50000..50099
Type=Table|Report|Codeunit|XMLport|MenuSuite|Page|Query;ID=<range>
```

- Use `..` for ranges: `ID=50000..50099`
- Use `|` to OR types: `Type=Table|Codeunit`
- Omit `Filter` for all objects (Export) or all uncompiled objects (Compile)

### `importaction` values

| Value | Behaviour |
|-------|-----------|
| `Overwrite` | Replace existing objects (default finsql behaviour) |
| `Skip` | Skip objects that already exist |

### `synchronizeschemachanges` values

| Value | Behaviour |
|-------|-----------|
| `Force` | Apply all schema changes immediately (can lock/alter tables) |
| `Yes` | Sync if no conflicts; error on conflict |
| `No` | Skip schema sync (useful for recompile without table changes) |

## Output schema

```json
{
  "status": "ok | error",
  "generated_at": "2026-06-10T09:00:00.0000000Z",
  "command": "Export | Import | Compile",
  "executed": true,
  "finsql": "C:\\Program Files (x86)\\Microsoft Dynamics NAV\\60\\Classic\\finsql.exe",
  "arguments": "command=exportobjects, servername=SQLSRV01, database=NAV_PROD, file=C:\\obj\\out.txt, filter=Type=Codeunit;ID=50000..50099, ntauthentication=yes, logfile=C:\\Temp\\navcommandresult.txt",
  "result": {
    "command_result": "<contents of navcommandresult.txt>",
    "error_log": "<contents of naverrorlog.txt, or null if absent>"
  }
}
```

In dry-run (`-Execute` not passed):
- `executed` is `false`
- `result` is `null`
- `finsql` is the resolved path (or `null` if not found on disk); the script does **not** fail
  in dry-run when finsql.exe is absent — it still returns the argument string so the agent can
  review it.

With `-OutFile`, stdout carries a compact summary:
```json
{
  "status": "ok",
  "out_file": "C:\\ops\\result.json",
  "command": "Compile",
  "executed": true
}
```

## Notes & gotchas

- **Exit code is not reliable.** finsql.exe may exit 0 even when objects failed to compile.
  Always inspect `result.command_result` and `result.error_log`. The script derives `status`
  from these files, not the process exit code.
- **navcommandresult.txt encoding.** finsql.exe writes these files in Unicode (UTF-16 LE on
  some versions). The script uses `Get-Content` which handles BOM detection automatically in
  PowerShell 7.
- **naverrorlog.txt** is only present when errors occurred. The script reports `null` when the
  file does not exist.
- **Single-argument quoting.** finsql.exe expects the entire argument string as one argument.
  The script passes it via `Start-Process -ArgumentList` as a single string — do not split it.
- **Log file location.** finsql.exe writes `navcommandresult.txt` to the path given in
  `logfile=`. Use `-LogPath` to redirect to a writable directory if the default temp path is
  insufficient (e.g. running as a service account).
- **Compile scope.** Without a filter, `compileobjects` recompiles all uncompiled objects in
  the database — this can be slow. Use a filter in development; leave it open only for a full
  post-import compile pass.
- **Schema sync in production.** `-SyncSchema Force` translates to
  `synchronizeschemachanges=force`. This can lock tables and apply SQL DDL. Always test against
  a non-production database first. During the sync, affected tables are inaccessible to users.
- **Concurrent C/SIDE sessions.** If an object is open in Object Designer in another session,
  finsql.exe will report it as locked. The error appears in `naverrorlog.txt`.
