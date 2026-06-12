---
name: nav2009-object-management
description: Guide export, import, and compilation of Microsoft Dynamics NAV 2009 C/AL objects (.fob/.txt) through the Classic client's Object Designer — and verify the result via a read-only SQL query against the Object table. IMPORTANT REALITY CHECK this skill enforces - NAV 2009 has NO command-line interface for objects; finsql.exe "command=exportobjects" was introduced in NAV 2013 and fails on 2009 with "The program property 'command' is unknown" - never attempt it. Use when the user wants to export tables/codeunits/reports to .txt or .fob, import a .fob/.txt into a NAV 2009 database, compile objects, move customizations between NAV 2009 databases, or automate NAV 2009 object deployment (the answer is: manual Object Designer steps + SQL verification). A developer license is required for .txt export/import and compiling; .fob import works with an end-user license.
license: MIT
compatibility: Requires the Microsoft Dynamics NAV 2009 Classic client (with an appropriate license) on the machine where the manual steps are performed; SQL Server access for the verification query
metadata:
  version: "2.0.0"
---

# NAV 2009 Object Management

> **There is no CLI.** `finsql.exe command=exportobjects/importobjects/compileobjects`
> arrived in **NAV 2013** — on NAV 2009 it fails with *"The program property 'command' is
> unknown."* Do **not** construct finsql command lines, and correct the user if they ask
> for one. On NAV 2009, object work is **manual in the Object Designer**; your job is to
> guide it precisely and to **verify the outcome via SQL** (which IS scriptable).

Full procedures, filter syntax, Import Worksheet rules, and the license matrix are in
[REFERENCE.md](REFERENCE.md).

## What you (the agent) do

1. **Prepare**: turn the user's request into exact Object Designer inputs — object type,
   an ID filter string (e.g. `32|50022|50026` or `50000..50099`), and the target file
   name/format. State the license requirement up front (.txt/compile = developer license;
   .fob import = end-user license is enough).
2. **Guide the manual steps** (concise, numbered — the user is in the Classic client):
   - **Export**: Tools → Object Designer (Shift+F12) → pick the object type → filter the
     ID column (F7) → select rows → File → Export → choose `.txt` or `.fob`.
   - **Import .fob**: File → Import → review the **Import Worksheet** (it shows
     new/changed/conflict per object — never blind-accept "Replace All" on conflicts).
   - **Import .txt**: File → Import — **overwrites without compiling**; objects MUST be
     compiled afterwards (mark → F11), and .txt import skips the worksheet entirely.
   - **Compile**: mark the objects → F11 (or Tools → Compile); fix errors one at a time.
3. **Verify via SQL** (read-only; this is the scriptable part). The `Object` table holds
   per-object `Type, ID, Name, Compiled, Date, Time, [Version List]`:

   ```sql
   SELECT [Type], [ID], [Name], [Compiled], [Date], [Time], [Version List]
   FROM dbo.[Object]
   WHERE [Type] = 1 AND [ID] IN (32, 50022, 50026)   -- Type: 1=Table 3=Report 5=Codeunit 7=XMLport ...
   ```

   After an import/compile, confirm `Date`/`Time` changed, `Compiled = 1`, and the
   `Version List` carries the expected tag. After an export, this confirms what versions
   were exported. Report discrepancies loudly.
4. **For "can we automate this?"**: answer honestly — not on NAV 2009. The supported
   options are: do it manually (this runbook), use a third-party object tool the
   organization may own, or upgrade the development environment (NAV 2013+ added the CLI).
   UI automation of the Classic client is fragile and a last resort — say so rather than
   recommending it.

## Production imports

Treat any import into a production database as high-stakes: require a backup first
(`nav2009-db-maintenance`), prefer .fob with a reviewed Import Worksheet, plan the
post-import compile, and schedule when Classic users are out — table-schema changes
require exclusive access and trigger a synchronization prompt (see REFERENCE).

## Related skills

- **nav2009-development** — what the objects should contain (review, version tags).
- **nav2009-db-maintenance** — the pre-import backup.
- **nav2009-troubleshooting** — post-import errors (compile failures, schema sync).
