# nav2009-object-management — Reference

Manual Object Designer procedures for NAV 2009 and the SQL verification that goes with
them. For the agent-facing workflow see [SKILL.md](SKILL.md).

## Why there is no script in this skill

NAV 2009's `finsql.exe` accepts only client startup properties (servername, database,
ntauthentication, id, company, temppath, …). The development-environment command interface
(`command=exportobjects|importobjects|compileobjects|…`) was **introduced in NAV 2013**;
on NAV 2009 any `command=` argument produces the dialog *"The program property 'command'
is unknown."* There is consequently no supported unattended object export/import/compile
on NAV 2009 — the procedures below are manual, and verification is done via SQL.

## License matrix

| Operation | End-user license | Developer license |
|-----------|------------------|-------------------|
| Export to `.fob` | ✓ (objects the license can read) | ✓ |
| Export to `.txt` | ✗ | ✓ |
| Import `.fob` | ✓ | ✓ |
| Import `.txt` | ✗ | ✓ |
| Compile (F11) | ✗ | ✓ |
| Design/modify objects | ✗ | ✓ (within licensed ranges) |

The license is loaded per client session (Tools → License Information → Change) or
resides in the database (saved license). Check **Tools → License Information** when a
license error appears.

## Object Designer basics

- Open: **Tools → Object Designer** (Shift+F12). Left bar selects the object type.
- **Filter the ID column**: place the cursor in the ID column → **F7** (Field Filter).
  Filter syntax is standard NAV: `32|50022|50026` (list), `50000..50099` (range),
  combinable (`32|50000..50099`). Same syntax works on the Version List column to find
  objects by customization tag.
- **Select**: click + Shift/Ctrl-click rows, or Ctrl+A within the filtered view.
- Modified/uncompiled objects show `Compiled = No` and an updated Date/Time.

## Export

1. Filter and select the objects (above).
2. **File → Export** → choose file type: `.fob` (binary, importable with end-user
   license) or `.txt` (source text, requires developer license).
3. Exporting **all types at once**: select the "All" object type in the left bar before
   filtering — the export file then contains mixed types.
4. For a deployment package, prefer `.fob`; for diff/review/version control, `.txt`.

## Import

**`.fob`** — File → Import. If every object is new, NAV offers to import directly;
otherwise the **Import Worksheet** opens:

- Each row shows the incoming object vs the existing one with a proposed **Action**
  (Create / Replace / Skip / Merge for tables).
- **Conflicts** (both changed, or schema differences) are highlighted — resolve row by
  row; never blanket-Replace conflicted tables in production.
- Table imports that change schema prompt for **synchronization** afterwards and need
  exclusive access (no users in the table) — schedule accordingly.
- `.fob` objects import **compiled** — no compile step needed unless dependencies changed.

**`.txt`** — File → Import. **No worksheet**: existing objects are overwritten silently,
and imported objects are **not compiled**. Always: import → filter on `Compiled = No`
(or the imported IDs) → mark → **F11**. A `.txt` import of a table with schema changes
also triggers synchronization on compile.

## Compile

- Mark objects → **F11** (or Tools → Compile). Compile errors stop at the first problem
  per object — fix and re-run.
- Compiling a table = schema synchronization against SQL: with users in the system it
  can block or fail; with data-loss-risky changes NAV prompts (Force/Check options in
  the sync dialog). Take the `nav2009-db-maintenance` backup first.

## SQL verification (the scriptable part)

The `dbo.[Object]` table (system table 2000000001) is the source of truth. Read-only
queries the agent can run/compose:

```sql
-- State of specific objects (after export/import/compile)
SELECT [Type], [ID], [Name], [Compiled], [Date], [Time], [Version List]
FROM dbo.[Object]
WHERE [Type] = 1 AND [ID] IN (32, 50022, 50026);

-- Everything carrying a customization tag
SELECT [Type], [ID], [Name], [Compiled], [Version List]
FROM dbo.[Object]
WHERE [Version List] LIKE '%MYTAG%' AND [Type] > 0;

-- Uncompiled objects (e.g. after a .txt import)
SELECT [Type], [ID], [Name] FROM dbo.[Object]
WHERE [Compiled] = 0 AND [Type] > 0;
```

`Type` values: 1 Table, 2 Form, 3 Report, 4 Dataport, 5 Codeunit, 6 XMLport, 7 MenuSuite,
8 Page. Rows with `Type = 0` are table *data* definitions — exclude them. Never
UPDATE/INSERT/DELETE in this table.

## Bulk and recurring needs — honest options

| Need | Option |
|------|--------|
| One-off deployment between databases | Manual .fob + Import Worksheet (this runbook) |
| Regular text exports for version control | Not natively automatable on 2009. Third-party object managers exist; otherwise manual .txt export per release |
| True CLI automation | Requires upgrading the development environment/database to NAV 2013+ (`finsql.exe command=…`) — not available for 2009 databases |
| Last resort | UI automation of the Classic client — fragile, license-bound, and breaks on dialogs (Import Worksheet, sync prompts). Recommend against it |

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| "The program property 'command' is unknown" | Attempted NAV 2013+ CLI syntax on 2009 — no CLI exists; use this runbook |
| License error on export/import/compile | Operation needs a developer license (see matrix); check Tools → License Information |
| Import Worksheet shows unexpected conflicts | Target objects were modified — stop and diff (.txt export both sides) before replacing |
| Table sync prompt / "another user has modified" | Users in the system or schema change pending — get exclusive access, backup, retry |
| Object imports but RTC still shows old behavior | RTC service tier caches metadata — restart the NST (`nav2009-service-tier-admin`) |

## Gotchas

**`finsql.exe command=` does not exist on NAV 2009 — every "automate the import" plan fails
here.**
The `command=exportobjects|importobjects|compileobjects` interface was introduced in NAV
2013. On NAV 2009, `finsql.exe` only understands client startup properties (servername,
database, ntauthentication, …). Any attempt produces the dialog *"The program property
'command' is unknown"* and the process exits without touching the database. There is no
supported unattended object operation on NAV 2009; all deployment steps in this runbook are
manual. Correct the user immediately when they ask for a command-line import.

**A `.fob` import is an interactive binary merge — it cannot run silently or headlessly.**
When one or more incoming objects already exist in the target database, NAV opens the Import
Worksheet and waits for the user to resolve each conflict before importing anything. There
is no `/confirm` flag, no bypass, and no way to pre-answer the dialog. Any plan that relies
on a `.fob` import completing without a human present (including UI-automation scripts) will
stall on the first conflict row. The correct approach: review the Import Worksheet row by
row, decide Replace/Skip/Merge per object, and only then click OK.

**`.txt` import overwrites objects silently and leaves them uncompiled — runtime errors
follow if you skip the F11 step.**
Unlike `.fob`, a `.txt` import has no worksheet and performs no compile. Objects land in
the database in an uncompiled state (`Compiled = 0` in `dbo.[Object]`). Any attempt to run
or open an uncompiled object produces a C/AL runtime error. After every `.txt` import,
filter the Object Designer on `Compiled = No` (or filter by the imported IDs), mark all
rows, and press **F11** before declaring the import done. Verify with:

```sql
SELECT [Type], [ID], [Name] FROM dbo.[Object]
WHERE [Compiled] = 0 AND [Type] > 0;
```

The result set must be empty for the affected objects before the deployment is considered
complete.

**Importing a table that changes schema locks the table and fires a synchronization prompt
— do this on a live database without a backup and you risk data loss and downtime.**
When the incoming object is a table whose field layout differs from the existing one (added
fields, changed field types, deleted fields), NAV triggers schema synchronization during
import (`.fob`) or compile (`.txt`). Synchronization acquires an exclusive lock on the
SQL table for its duration. If other users or background jobs are accessing that table, the
operation blocks or fails with a lock-timeout error. If the change removes or shrinks a
field, NAV presents a Force/Check dialog — choosing Force deletes column data permanently.
Required steps before any table-schema import on a live database: full backup
(`nav2009-db-maintenance`), confirm zero active sessions in the affected company, schedule
outside business hours.

**An end-user/customer license can import a `.fob` but cannot export one, cannot import
`.txt`, and cannot compile — the session silently determines what menu items are active.**
The license type in the current client session controls which operations appear (or are
available) in the UI. A user running with an end-user license will find File → Export
greyed out for `.txt`, and F11 will produce a license error rather than compiling. The trap
is that the `.fob` import option remains available under an end-user license, leading teams
to assume the session is a full developer session when it is not. Always verify the active
license before starting a deployment: **Tools → License Information** — confirm the
Granule list includes the development granule (Granule 11110 or equivalent) before
attempting export, `.txt` import, or compile.
