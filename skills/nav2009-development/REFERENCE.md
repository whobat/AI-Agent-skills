# nav2009-development — Reference

Detailed C/AL and NAV 2009 pattern tables. For the short rules see [SKILL.md](SKILL.md).
For SQL-side measurement, use the **nav2009-sql-performance** skill.

## Record access patterns

| Intent | Correct C/AL | Avoid | Why |
|--------|--------------|-------|-----|
| Loop over a set | `IF Rec.FINDSET THEN REPEAT ... UNTIL Rec.NEXT = 0;` | `FIND('-')` | FINDSET (NAV 5.0+) fetches a result set; `FIND('-')` opens a cursor positioned for bidirectional browsing |
| Loop + modify the same records | `FINDSET(TRUE)` (and `(TRUE,TRUE)` only when modifying key fields) | `FINDSET` then `MODIFY` | Without ForUpdate, NAV re-reads with UPDLOCK per row |
| First / last record | `FINDFIRST` / `FINDLAST` | `FIND('-')` / `FIND('+')` | TOP 1 query instead of a cursor |
| Does anything exist? | `IF NOT Rec.ISEMPTY THEN` | `IF Rec.FINDFIRST THEN` | `ISEMPTY` = `SELECT TOP 1 NULL` — no row data, no locks taken under LOCKTABLE |
| Count | `COUNT` only when the number matters; `COUNTAPPROX` for progress dialogs | `COUNT` in tight loops | `COUNT` scans/aggregates every call |
| Single known record | `GET(PK values)` | filter + FINDFIRST | Direct clustered-index seek |

**Key rule:** call `SETCURRENTKEY` with a key whose leading fields match the `SETRANGE`/`SETFILTER`
fields (and the `CALCSUMS` SumIndexFields). On big tables (`G/L Entry`, `Item Ledger Entry`,
`Value Entry`, `Warehouse Entry`) a filter without a supporting key is a table scan in disguise —
this shows up in the SQL triage as huge `avg_logical_reads`.

## Keys, SIFT, and the SQL schema

- Every enabled table **key** with `MaintainSQLIndex = Yes` becomes a SQL index. Disabled or
  `MaintainSQLIndex = No` keys can still be used for `SETCURRENTKEY` sorting validity but cost
  nothing to maintain (sorting then happens without index support).
- Every key with **SumIndexFields** and `MaintainSIFTIndex = Yes` becomes an **indexed view**
  named `<Company>$<Table>$VSIFT$<KeyNo>`. FlowFields of type Sum/Count and `CALCSUMS` read these.
- Each extra maintained index/SIFT view taxes every INSERT/MODIFY/DELETE on the base table. On hot
  ledger tables this is the classic posting-speed killer: review which SIFT views are actually read
  (the SQL triage `unused_indexes`/`sift` sections show write-only views) and set
  `MaintainSIFTIndex = No` on the dead ones.
- Schema changes belong in C/SIDE. Indexes created directly in SSMS are dropped when NAV rebuilds
  the table's SQL objects (key change, company copy/rename, some upgrades). A raw SQL index is an
  acceptable *labelled stopgap*, never the recommended fix.

## Transactions and locking

- An implicit transaction spans from the first write until the C/AL call stack returns (or COMMIT).
  NAV 2009 uses **pessimistic locking** (UPDLOCK/HOLDLOCK semantics via the NDBCS driver); readers
  inside `LOCKTABLE` scope take and hold locks until commit.
- **No `COMMIT`** inside posting chains (CU 80 Sales-Post, CU 90 Purch.-Post, CU 12 Gen. Jnl.-Post
  Line and anything they call) — a half-committed posting cannot roll back. Review any `COMMIT`
  for: is the prior state consistent if the code dies right after?
- Deadlock prevention is mostly **lock ordering**: touch shared resources (`No. Series Line`,
  setup tables, ledger tables, dimension tables) in the same order in every code path. Custom code
  that grabs the number series late is a classic deadlock source against standard posting.
- Long-running batch jobs over live tables: process in chunks, keep filters key-aligned and avoid
  holding locks across user-visible time (e.g. `CONFIRM` inside a transaction = lock held while a
  user thinks).

## Review checklist

1. **Performance**: SETCURRENTKEY vs filters on every loop over large tables; FIND usage per the
   table above; CALCFIELDS in loops; nested loops that should be one keyed filter.
2. **Transactions**: stray `COMMIT` (especially in posting paths); LOCKTABLE before
   read-then-update; consistent lock order; CONFIRM/dialogs inside transactions.
3. **Customization hygiene**: new fields/objects in 50000–99999; changes to standard objects
   tagged (`// TAG BEGIN/END`) and listed in the object Version List; logic hooked out to own
   codeunits with minimal lines in standard objects.
4. **Execution target**: code reachable from RTC service tier or NAS must not assume a Classic
   client — `GUIALLOWED` guards on dialogs, no client-side Automation/file dialogs server-side;
   `FILE` operations point at paths valid where the code runs.
5. **Data integrity**: `VALIDATE` when business logic must fire vs direct assignment when it must
   not (e.g. avoid re-triggering price calc); `TESTFIELD` on required setup; OnDelete cleanups for
   new child tables.
6. **Upgradability**: does the change deepen standard-object surgery, or is it hook-shaped? Flag
   new Dataports/Forms when an XMLport/Page would do (BC has no Dataports/Forms).

## Reports

**RDLC (RTC)** — a NAV 2009 RDLC report is the Classic report's DataItems feeding a flattened
dataset to a Visual Studio 2008 RDLC layout:

- Keep the dataset **flat and minimal** — every column ships for every row; remove unused columns,
  do aggregation in C/AL or SIFT (`CALCSUMS`/FlowFields with proper keys), not in the layout.
- Document headers (invoice/order/statement) need the `GetData`/`SetData` pattern: pack header
  values into a hidden textbox in the body via `SetData`, unpack in the page header with `GetData`.
- Grouping in the layout must match the DataItem sort order (`SETCURRENTKEY` / DataItemTableView),
  or totals silently misbehave.

**Classic sections** — when the customer runs the Classic client only, work in the Section
Designer; `CurrReport.SHOWOUTPUT`/`SKIP` for conditional sections, `CreateTotals`/GroupFooters for
totals. The same DataItem performance rules apply (filters + keys, `CALCSUMS` over loops).

## Integrations

| Mechanism | Runs on | Use for | Notes |
|-----------|---------|---------|-------|
| **SOAP web services** | RTC service tier (port 7047) | New synchronous integrations | Publish Pages (CRUD) or Codeunits (RPC) in Form 810 *Web Services*. Preferred when the counterpart can speak SOAP |
| **XMLport** | Both (RTC for WS, Classic for files) | XML/flat-file import-export | In 2009, XMLports also handle delimited text (`Format` property) — prefer over Dataports for anything that must survive a BC upgrade |
| **Dataport** | Classic only | Legacy flat-file import/export | No RTC, no BC equivalent — maintain, don't multiply |
| **NAS** (NAV Application Server) | Own service | Unattended/async processing, Job Queue runner | Single-threaded; no UI — everything behind `GUIALLOWED`; classic pattern: NAS polls Job Queue / MSMQ |
| **Job Queue** | NAS executes | Scheduled C/AL (codeunits/reports) | Setup in Application Setup → Job Queue |
| **MSMQ** | via Communication Components | Async message exchange | The 2009-era async pattern (with NAS); only for existing infrastructure |
| **COM/Automation** | Classic client / NAS | Office, file system, third-party COM | Client-side vs server-side instantiation differs; not portable to BC (AL uses DotNet/HTTP instead) |
| **C/FRONT, ODBC/NODBC** | external | External direct DB access | Last resort; bypasses C/AL business logic — never for writes to posted tables |

## Business Central upgrade posture

Decisions in NAV 2009 that pay off at migration time:

- **Hook pattern everywhere**: one tagged call-out line in the standard object → your codeunit.
  Hooks map ~1:1 to AL event subscribers; inline logic in standard objects must be untangled by hand.
- **Field/object IDs** consistently in 50000–99999 (they map into the extension range later);
  meaningful names, no reuse of abandoned fields.
- **Avoid net-new Classic-only artifacts** (Forms, Dataports, classic-only reports) — Pages and
  XMLports have direct BC equivalents.
- **Document data semantics** of custom fields/tables — BC migrations (NAV 2009 → 2013/2015/2018 →
  BC, or cloud-migration tooling) move schema + data, and undocumented magic values are what break.
- Flag as **migration debt** during reviews: modified posting codeunits, custom code keyed to
  Classic-client behavior (e.g. form triggers doing business logic), direct SQL access.

## Useful diagnostics (NAV 2009 toolbox)

- **Client Monitor** (Classic: Tools → Debugger → Client Monitor): per-call client-side trace —
  the tool for "which C/AL line causes this SQL". Pairs with the nav2009-sql-performance triage.
- **Code Coverage** (Tools → Debugger → Code Coverage): which code ran.
- **Classic Debugger** for C/AL stepping (Classic client); RTC-side debugging in 2009 is limited —
  reproduce in Classic where possible.
- **SQL Profiler** with `Application Name` filter (Classic client connections) when Client Monitor
  isn't enough.
