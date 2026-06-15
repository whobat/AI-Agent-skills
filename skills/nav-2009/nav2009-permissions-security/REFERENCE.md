# nav2009-permissions-security — Reference

Detailed tables and reference for NAV 2009 security. For the short rules and diagnosis checklist
see [SKILL.md](SKILL.md). For C/AL code that touches permissions, see **nav2009-development**.

---

## The two layers: license vs permissions

| Layer | What it controls | Where it lives | Error symptom |
|-------|-----------------|----------------|---------------|
| **License (.flf)** | Which object IDs may exist and execute; granule access (e.g., Financial Management, Warehouse) | License file loaded into the database; viewable in Tools → License Information | "Your program license does not permit access to table/object X" — object missing from menus entirely |
| **Permissions (Roles)** | Which *users* may Read/Insert/Modify/Delete/Execute a licensed object | `Permission Set` + `Permission` tables; assigned via `User Role` | "You do not have permission to Read/Insert/Modify/Delete X" |

Rule: if the object simply does not appear in any menu and nothing in the application references
it, suspect the license granule first. Permissions cannot grant access beyond what the license
permits.

Custom objects in range **50000–99999** are covered by the developer/customization granule in the
license; they still need explicit permission records for each user Role.

---

## Roles & permission sets

**Key tables**

| Table | Description |
|-------|-------------|
| `Permission Set` (ID 2000000004) | One row per Role: `Role ID` (code, up to 20 chars) + `Name` |
| `Permission` (ID 2000000005) | One row per object right: `Role ID`, `Object Type`, `Object ID`, Read, Insert, Modify, Delete, Execute, Security Filter |
| `User` (ID 2000000120) | NAV user record; links to Windows or Database login |
| `User Role` (ID 2000000053) | Many-to-many: `User ID` ↔ `Role ID` |
| `Windows Login` / `Database Login` | Login records under Tools → Security; each maps to a `User` |

**Built-in special Roles**

| Role | Effect |
|------|--------|
| `SUPER` | Full access to all objects (Read/Insert/Modify/Delete/Execute on Object ID 0 = wildcard). Bypasses all permission checks. |
| `SUPER (DATA)` | Full data access (TableData rights on Object ID 0) but no object design rights (cannot modify C/SIDE objects). Use for power users who must not alter C/SIDE. |
| `BASIC` (if present) | Minimal rights required to log in and navigate (varies by localization/setup). |

Assigning a user multiple Roles is **additive** — rights union across all assigned Roles. There is
no deny mechanism; if any Role grants a right, the user has it.

---

## Object permissions

**Object types recognized in NAV 2009 Permission records**

| Object Type value | Covers |
|-------------------|--------|
| `TableData` | Read/Insert/Modify/Delete of *data rows* in a table (the business data layer) |
| `Table` | The table object itself (schema design rights in C/SIDE) |
| `Form` | Classic client Forms |
| `Report` | Reports (Classic sections and RDLC) |
| `Dataport` | Classic Dataports |
| `Codeunit` | C/AL Codeunits |
| `XMLport` | XMLports (RTC and Classic) |
| `MenuSuite` | Menu navigation objects |
| `Page` | RTC Pages |

**Rights matrix**

| Right | Applies to | Meaning |
|-------|-----------|---------|
| **Read** | TableData | SELECT rows from the table |
| **Insert** | TableData | INSERT new rows |
| **Modify** | TableData | UPDATE existing rows |
| **Delete** | TableData | DELETE rows |
| **Execute** | Report, Codeunit, XMLport, Page, Form, Dataport | Run / open the object |
| **Read / Execute** | Table (object) | Open the table in C/SIDE designer |

**Indirect permission (the "Yes (Indirect)" value)**

When a right is set to *Indirect* (displayed as `Yes (Indirect)` in the permission form), the
user may exercise that right **only when called from other C/AL code** — they cannot trigger it
directly (e.g., cannot open the table in a filter dialog, cannot run the report from a menu).
Posting codeunits that write to ledger tables typically require only Indirect Insert/Modify on
those ledger tables for the posting user.

**Object ID 0 (wildcard)**: granting a right on Object Type X with Object ID = 0 applies to all
objects of that type. Used by SUPER and sometimes by broad "power user" Roles.

---

## Security filters

Security filters are an optional string on a `Permission` record (the `Security Filter` column).
They restrict which *rows* a Role can access within a table — record-level security.

**Syntax**: a NAV filter string, identical to what you would type in the Filter field on a form
(e.g., `RES1|RES2`, `10000..19999`, `CRONUS`). The filter is applied as an additional AND
condition on every read/write by that Role on that table.

**Common use cases**

| Scenario | Table | Filter example |
|----------|-------|----------------|
| Restrict by Responsibility Center | `Sales Header`, `Purchase Header`, etc. | `Responsibility Center=RES1` |
| Restrict by Location | `Item Ledger Entry`, `Transfer Header` | `Location Code=EAST` |
| Restrict to one company's data | Any cross-company scenario | `Company Name=CRONUS` |
| Posting-only to one G/L account range | `G/L Entry` | `G/L Account No.=60000..69999` |

**Limitations**
- Security filters are evaluated in NAV's application layer, not at the SQL level (unless using
  Enhanced security, which pushes some filters to SQL views).
- A user with multiple Roles gets the **union** of security filters for the same table — if any
  Role has no filter for that table, the filter from another Role does not restrict anything.
  Design carefully: if you need hard isolation, ensure all Roles a user holds carry a filter on
  the sensitive table, or dedicate a single Role for that table.

---

## Logins & authentication

**Windows logins**

- A Windows Login record in NAV maps an Active Directory user (or group) to a NAV User.
- At login, NAV looks up the AD identity in `Windows Login`; if found, it loads the associated
  `User` record and its Roles.
- The Windows Login `Login` field holds the domain\username (e.g., `MYDOMAIN\jsmith`).
- AD groups can be mapped: all members of the group inherit the mapped NAV User's Roles.

**Database logins**

- A Database Login record stores a NAV-managed username + password (hashed) in NAV.
- The user enters credentials on the NAV login dialog. NAV authenticates against its own tables.
- Useful where AD integration is unavailable (e.g., external users, mixed environments).

**Each NAV user = one SQL Server login**

NAV creates and manages a SQL Server login for each NAV user. The SQL login name mirrors the NAV
Login ID. In Standard security, this login is granted broad database access and NAV enforces
granular rights in the application layer. In Enhanced security, the SQL login is granted only the
SQL Server roles that NAV has computed from the user's Roles.

**3-tier / RTC**

In the RTC (3-tier) architecture, *end users never connect directly to SQL*. The **NAV Service
Tier** holds a single service-account SQL connection. All end-user permission checks happen in the
application layer on the service tier. SQL-level login synchronization still matters for Classic
client users who connect directly and for the Enhanced security model.

---

## SQL security models

### Standard security

- NAV creates SQL logins for each NAV user and grants them `db_datareader` + `db_datawriter`
  (or similar broad database roles).
- All permission enforcement happens inside the NAV application tier — no SQL row-level or
  object-level restrictions beyond the broad grant.
- Simpler to manage; works with Classic and RTC clients.
- Risk: a SQL-savvy user with a direct SQL tool could bypass NAV's permission checks.

### Enhanced security

- NAV creates **SQL Server database roles** per company (named `<CompanyName>$<RoleID>` or
  similar) and grants them fine-grained SELECT/INSERT/UPDATE/DELETE rights on the company's
  tables.
- Each NAV user's SQL login is placed in the appropriate SQL roles based on their assigned NAV
  Roles.
- Provides SQL-level enforcement — a direct SQL connection also cannot exceed the NAV-computed
  rights.
- **Requires synchronization**: after any change to NAV Roles, User Role assignments, or login
  records, you must run **Synchronize All Logins** (Database → Logins → Synchronize All Logins)
  to push the new rights to SQL. Until sync, NAV-layer checks reflect the new state but SQL does
  not.
- More complex to maintain; schema changes and company copies/renames require re-synchronization.

### When to synchronize

Always synchronize after:
- Adding or removing a User or Login record.
- Assigning or revoking a Role from a user.
- Changing a permission record within a Role.
- Renaming or deleting a company (the SQL roles are company-scoped).
- Restoring a database backup to a new server.

---

## Error → cause → fix

| Error / symptom | Likely cause | Fix |
|----------------|--------------|-----|
| "You do not have permission to Read table X" | No Read right (or only Indirect) on TableData for table X in any assigned Role | Add direct Read on TableData X to an appropriate Role; assign Role to user |
| "You do not have permission to Insert/Modify/Delete table X" | Missing Insert/Modify/Delete on TableData X | Add right to Role |
| "You do not have permission to Execute codeunit/report/page X" | Missing Execute on the object in any assigned Role | Add Execute right |
| User has the right but only on certain records; other records invisible | Security filter on the permission record | Review Filter column; broaden or remove filter if intended access is wider |
| "Your program license does not permit access to table/object X" | Object ID outside licensed granule range; developer granule not included | Check license granule in Tools → License Information; contact partner for correct license |
| Object/menu item simply not visible | License granule not included, OR object ID outside custom range 50000–99999 | License issue — not a permissions issue |
| User cannot log in to NAV at all | No Windows Login or Database Login record for the user; or login disabled | Create the Login record in Tools → Security; verify AD account is active |
| SQL login disabled or wrong password | SQL login out of sync after a NAV change | Synchronize All Logins (Database → Logins) |
| User logs in but no companies visible | User record exists but no Role grants access to any company | Assign at least one Role with TableData Read on the company's core tables; or check company access settings |
| "Another user has already modified the record" | **Locking conflict — not a permission error** | See **nav2009-sql-performance** / **nav2009-troubleshooting** |
| RTC users can act but Classic users cannot (or vice versa) | Classic client connects directly to SQL; Enhanced security SQL roles may be out of sync | Synchronize All Logins; verify the Classic user's SQL login rights |

---

## Role-design best practices

1. **Functional decomposition**: one Role per business function (`SALES-BASIC`, `SALES-POST`,
   `PURCH-RECV`, `FINANCE-GL`, `WH-RECEIVE`, `WH-SHIP`). Users receive the combination their job
   requires.
2. **Never distribute SUPER** to end users. Create a `SETUP-ADMIN` Role with the specific setup
   tables that administrators need, rather than granting SUPER.
3. **SUPER (DATA)** is appropriate for power users or data-migration users who need all data
   rights but must not alter objects.
4. **Separate setup from transaction Roles**: Modify on `Payment Terms`, `Posting Groups`,
   `General Ledger Setup` etc. should be in a restricted admin Role — not bundled with the posting
   Role every finance user receives.
5. **One Role for custom objects**: group all 50000+ range TableData, Codeunit, Page, Report
   rights into a `CUSTOM-BASE` Role (or per-module variants). Assign it alongside standard Roles.
   This isolates custom-object permission management from standard Roles.
6. **Security filters for data segregation**: prefer a single Role with a Filter over creating
   per-user Role copies. Use Responsibility Center, Location, or Company filters to implement
   data-level partitioning without user account explosion.
7. **Indirect for ledger tables**: posting users typically need only Indirect Insert/Modify/Delete
   on ledger tables (`G/L Entry`, `Cust. Ledger Entry`, etc.) — direct rights on these tables
   should be limited to administrators.
8. **Re-synchronize after every change** in Enhanced security setups. Build this into your change
   process: Role change → save → Synchronize All Logins → test.
9. **Document custom Roles**: record what each Role is for, which object ranges it covers, and any
   security filters — especially filters, which are invisible in normal form navigation.
10. **Audit periodically**: review User Role assignments and security filters after staff changes,
    reorganizations, or new module go-lives.

---

## Gotchas

### **"No permission" and "license does not permit" are two completely different errors — but they look similar at a glance**

Trap: a user is blocked on an object and the support call goes straight to Roles. After 20 minutes of Role edits nothing changes, because the real error was "Your program license does not permit access to table X", not "You do not have permission to Read table X".

Why it happens: both errors surface as a dialog during a NAV operation and both stop the user cold. The wording is distinct but busy support staff often paraphrase them the same way ("they get a permission error"). The license layer is checked first; no amount of Role editing can grant access to an object that falls outside the licensed granules.

Correct approach: read the exact error text before touching anything. "Does not permit" → check Tools → License Information for the granule; "do not have permission" → check the user's Roles. Only if the granule is licensed but the user still cannot access the object does the Roles investigation begin.

---

### **Removing a "redundant" direct permission can silently break posting codeunits**

Trap: a user has both a direct Insert right and an Indirect Insert right on a ledger table (e.g., `G/L Entry`). A clean-up pass removes the direct Insert as "redundant" since posting goes through a codeunit. After the change the user can no longer post, even though the codeunit still has Execute and the Indirect Insert is in place.

Why it happens: Indirect means the right is exercisable only when called from C/AL code — but the call stack must end with the user's Role carrying that Indirect right on the table. If the user was also directly opening a reconciliation form that reads `G/L Entry` rows or runs a drilldown, that direct path now fails. NAV does not tell you which call path triggered the check. The error message names the table and the missing right, not whether it was a direct or indirect invocation, so it looks like the Indirect right simply stopped working.

Correct approach: before removing any direct right that co-exists with an Indirect right on the same table, trace every path the user takes that touches that table — not just the main posting flow. If any path is a direct invocation (open form, report, filter dialog), the direct right must stay. When in doubt, keep direct; the cost of a slightly broader right is lower than a broken posting workflow.

---

### **A security filter on one Role is silently nullified if the user holds a second Role with no filter on the same table**

Trap: `CONTOSO\user` is assigned two Roles — `SALES-BASIC` (which has a `Responsibility Center=RES1` filter on `Sales Header`) and `SALES-REPORT` (which has Read on `Sales Header` with no filter). The expectation is that the filter restricts the user to RES1 data. In practice the user can read all `Sales Header` rows.

Why it happens: multiple Role assignments are additive. NAV unions the access rights across all Roles. A Role with no security filter on a table contributes an unrestricted Read on that table — effectively overriding the restrictive filter in the other Role. There is no "most restrictive wins" logic; the absence of a filter is itself a grant of unrestricted access.

Correct approach: for any table that must be hard-restricted by a security filter, ensure that **every** Role the user holds either carries the same (or equally narrow) filter on that table, or carries no access to that table at all. Audit this whenever a new Role is added to a user. The Role-design best practice of building functional Roles (§Role-design best practices point 1) helps here: a catch-all "reporting" Role with broad TableData Read rights is the most common source of accidental filter bypass.

---

### **In Enhanced security, Role changes take effect in NAV immediately but SQL enforcement lags until Synchronize All Logins is run**

Trap: a new Role is assigned to `CONTOSO\user` and tested from the RTC client — everything works. The same user then opens the Classic client and gets a SQL login error or "permission denied" at the database level. Alternatively, a revoked Role still works in Classic for an hour after removal.

Why it happens: in Enhanced security, NAV maintains SQL Server database roles (one per company/Role combination) and places each user's SQL login in the appropriate SQL roles. This mapping is **not updated automatically** when you change a NAV Role assignment — it is updated only when Synchronize All Logins is run. RTC-tier users connect through the service account, so NAV's application-layer check reflects the new assignment instantly. Classic-tier users connect to SQL directly with their own SQL login, which is still in the old SQL role membership until sync runs.

Correct approach: treat Synchronize All Logins as a mandatory final step of every Role change, not an optional housekeeping task. In Enhanced security setups, add it to the change procedure: make the NAV Role change → save → Database → Logins → Synchronize All Logins → verify with the affected user. If Classic and RTC behavior diverges immediately after a change, unsynchronized SQL roles are the first thing to check.

---

### **SUPER bypasses all permission checks, but it does not bypass the license — and this surprises administrators**

Trap: a consultant assigned to `SUPER` tries to open an object from an unlicensed granule and gets a license error. The assumption was that SUPER means unrestricted access to everything.

Why it happens: SUPER is implemented as a wildcard permission record (Object ID = 0) on every object type — it grants Read/Insert/Modify/Delete/Execute on all *licensed* objects. The license check is a separate, earlier gate that SUPER has no effect on. The NAV security model is layered: license → permission → security filter. SUPER collapses the permission layer to nothing but cannot collapse the license layer.

Correct approach: when a SUPER user cannot access an object, check the license first (Tools → License Information), exactly as you would for any other user. If the granule is missing, the fix is a license upgrade — Role changes, including adding or modifying SUPER, will not help.

---

**Environment-specific gotchas (local).** At the start of a run, read `gotchas.local.md` in this skill's folder if it exists — it records traps learned in *this* environment (real server/database names, local quirks, naming conventions). When you discover a new environment-specific pitfall here, **append it to `gotchas.local.md`** (not to this file, which must stay generic and company-agnostic). The file is gitignored and is preserved across skill updates, so this skill gets more useful every time it runs in your environment.

---

## Verification

### Before changing permissions: establish the real cause and capture a baseline

1. **Confirm license vs permission first.** Read the exact error text the user sees — "Your program license does not permit access to table/object X" and "You do not have permission to Read/Insert/Modify/Delete/Execute X" require completely different fixes. Do not touch Roles until you have confirmed which layer is failing (see § The two layers: license vs permissions).
2. **Capture the user's current effective access as a baseline.** Before editing any Role or login record, open the user's Role list (Tools → Security → Windows Logins / Database Logins → select user → Roles) and note every assigned Role. For each Role relevant to the failing object, note the current right values and any security filter. This baseline lets you diff what you changed and revert cleanly if the fix introduces regressions.

### After a change: sync, then confirm with a real test

1. **Run "Synchronize All Logins" before testing** (Enhanced security setups only): navigate to Database → Logins → Synchronize All Logins. NAV's application-layer check reflects the new Role assignment immediately, but SQL-level enforcement does not update until sync runs. Testing before sync can give a false positive (RTC user passes; Classic user still fails).
2. **Verify with the affected user or an equivalent test login.** Have the user (or a test account carrying the same Roles) perform the exact action that was blocked — not just navigate to the object, but execute the failing operation. Confirm the exact error is gone.
3. **Confirm you did not over-grant.** After the fix, check that the user cannot access objects or records beyond their job function: spot-check a record they should *not* see (security filter scenarios) and an object they should *not* be able to execute. If you cannot confirm with a real test, say so explicitly — do not report the fix as verified.
