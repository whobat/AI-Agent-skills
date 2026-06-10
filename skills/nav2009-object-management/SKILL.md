---
name: nav2009-object-management
description: Import, export, and compile Microsoft Dynamics NAV 2009 C/AL objects via the Classic development environment CLI (finsql.exe). The bundled script wraps finsql.exe command-line operations to move objects between databases or between a file and a database — supporting both binary .fob files and text-format .txt files — and emits structured JSON so the agent can report results and errors clearly. Use when the user wants to export all codeunits in the 50000 range, import this .fob into NAV, compile all modified objects, deploy objects between two NAV databases, export a specific table or report to .txt, or migrate customisations from a development database to production. A developer license is required for .txt export/import and for compiling; .fob import works with an end-user license. Requires PowerShell 7+ and a NAV 2009 install (finsql.exe) with an appropriate license.
license: MIT
compatibility: Requires PowerShell 7+ and a Microsoft Dynamics NAV 2009 Classic client install (finsql.exe) with an appropriate license
metadata:
  version: "1.0.3"
---

# NAV 2009 Object Management

> Targets **Microsoft Dynamics NAV 2009 Classic development environment (finsql.exe)**. The bundled
> script `scripts/Invoke-NavObjects.ps1` drives finsql.exe and emits JSON; **the agent (you) writes
> the narrative.** Import and compile **MUTATE the database** — the script defaults to a dry run
> (`-WhatIf` behaviour without `-Execute`) and only contacts finsql.exe when you pass `-Execute`.
> The script never calls an LLM.

`SCRIPT` = this skill's `scripts/Invoke-NavObjects.ps1`. Requires **PowerShell 7+** (`pwsh`) and
**finsql.exe** installed on the machine (shipped with the NAV 2009 Classic client / development
environment).

## Permissions & licensing

- **Developer license** required for: exporting objects to **.txt**, importing **.txt**, and
  compiling objects. Without it finsql.exe will exit with a license error.
- **.fob import** works with an end-user license (the binary format bypasses the C/AL text licence
  check).
- Export and import both need **read/write DB access** to the target database.
- **Windows auth** is the default (NAV 2009 classic). Pass `-SqlCredential` for SQL auth — the
  credential object keeps the password out of the command line; never paste a raw password.

## How to run

Always run with `pwsh`. Parse the JSON it prints on stdout (or the compact summary when `-OutFile`
is set).

| Want | Pass |
|------|------|
| Export objects to .txt by filter | `-Command Export -ServerName SQLSRV01 -Database NAV_PROD -Path C:\obj\out.txt -Filter 'Type=Codeunit;ID=50000..50099'` |
| Export to .fob (binary) | `-Command Export -Path C:\obj\out.fob -Filter 'Type=Table;ID=50000..50199'` |
| Import a .fob | `-Command Import -Path C:\obj\patch.fob` |
| Import a .txt (needs dev license) | `-Command Import -Path C:\obj\codeunits.txt` |
| Compile by filter | `-Command Compile -Filter 'Type=Codeunit;ID=50000..50099'` |
| Compile with schema sync | `-Command Compile -SyncSchema Force` |
| Point at a specific finsql.exe | `-FinSqlPath 'D:\NAV\Classic\finsql.exe'` |
| SQL auth | `-SqlCredential (Get-Credential)` |
| Actually execute (drop dry-run) | add `-Execute` |

**Examples:**
```powershell
# Dry-run: see the exact finsql command before touching the database
pwsh -File SCRIPT -Command Export -ServerName SQLSRV01 -Database NAV_PROD `
    -Path C:\deploy\cu50000.txt -Filter 'Type=Codeunit;ID=50000..50099'

# Execute the export (add -Execute after confirming the dry-run output)
pwsh -File SCRIPT -Command Export -ServerName SQLSRV01 -Database NAV_PROD `
    -Path C:\deploy\cu50000.txt -Filter 'Type=Codeunit;ID=50000..50099' -Execute

# Import a .fob and compile all modified objects (two separate calls)
pwsh -File SCRIPT -Command Import -ServerName SQLSRV01 -Database NAV_PROD `
    -Path C:\deploy\patch.fob -ImportAction Overwrite -Execute
pwsh -File SCRIPT -Command Compile -ServerName SQLSRV01 -Database NAV_PROD `
    -Filter 'Type=Codeunit;ID=50000..50099' -Execute
```

## Output contract

- **Without `-OutFile`** → full JSON on stdout.
- **With `-OutFile`** → full JSON to the file; a **compact** summary on stdout (mirror of
  nav2009-sql-performance). Prefer `-OutFile` for compile runs so your context stays small.

Top level keys:

| Key | Type | Notes |
|-----|------|-------|
| `status` | `ok` / `error` | Derived from navcommandresult.txt / naverrorlog.txt |
| `generated_at` | string (UTC ISO 8601) | When the JSON was produced |
| `command` | string | `Export`, `Import`, or `Compile` |
| `executed` | bool | `false` in dry-run; `true` when finsql.exe was actually launched |
| `finsql` | string | Resolved absolute path to finsql.exe (or `null` if not found) |
| `arguments` | string | Full finsql argument string; **password replaced with `***`** |
| `result` | object | `command_result` (navcommandresult.txt contents), `error_log` (naverrorlog.txt contents or null) |

## What you (the agent) do with the result

1. **Run in dry-run first** (no `-Execute`). Show the user the resolved finsql path and the exact
   argument string before anything touches the database.
2. **Re-run with `-Execute` only after confirmation** — especially for Import and Compile, which
   modify live database objects.
3. **ALWAYS read `navcommandresult.txt` / `naverrorlog.txt` via `result`** because finsql.exe's
   process exit code is unreliable; a successful exit code does not mean the operation succeeded.
4. For compile failures: surface the individual object errors from `result.error_log` and point to
   the **nav2009-development** skill for the C/AL fix.
5. Remind the user that **compiling with `-SyncSchema Force`** can lock and alter SQL tables.
   Confirm scope (which tables are affected) before running it in production during business hours.

## Errors

- **finsql.exe not found**: auto-detect probes
  `C:\Program Files (x86)\Microsoft Dynamics NAV\60\Classic\finsql.exe` and
  `C:\Program Files\Microsoft Dynamics NAV\60\Classic\finsql.exe`. Use `-FinSqlPath` to
  override if installed elsewhere.
- **License error** (`You do not have permission...`): ensure a developer license is loaded in the
  NAV client tools for .txt operations and compile; for .fob import the end-user license suffices.
- **Object is locked / being edited**: another session has the object open in C/SIDE Object Designer.
  Close the session or wait, then retry.
- **Schema sync conflicts**: compile with `-SyncSchema Force` can fail when table-structure changes
  conflict with live data. Run against a test database first; review `naverrorlog.txt` carefully.
