# nav2009-troubleshooting — Reference

Detailed symptom/cause/fix tables for NAV 2009 operational triage.
For the short routing table see [SKILL.md](SKILL.md).

---

## RTC client won't connect

**Default port:** 7046 (ClientServices). Also relevant: 7047 (SOAP web services), 7045 (Management / NST administration). NAV 2009 has **no OData** — that arrives in NAV 2013.

| Cause | Check | Fix / route |
|-------|-------|-------------|
| Service Tier stopped | `Get-Service *Nav*` on the NST server; Services.msc | → **nav2009-service-tier-admin** to restart |
| Wrong server/instance/port in client config | Review `ClientUserSettings.config` (`ServerName`, `ServerInstance`, `ClientServicesPort`) | Correct the client config; default port is **7046** |
| Firewall blocking 7046 | `Test-NetConnection <NST-hostname> -Port 7046` — TcpTestSucceeded must be True | Open TCP 7046 inbound on the NST server firewall |
| Kerberos / SPN ("double-hop") | RTC→NST→SQL is a 3-tier delegation chain. The NST service account must have an SPN (`setspn -L <account>`) and the SQL Server must be configured to trust it for constrained delegation (AD "Trust this user for delegation to specified services") | Register SPN: `setspn -A MicrosoftDynamicsNavWS/<NST-FQDN>:7046 <svc-account>`; configure delegation in AD; → **nav2009-permissions-security** |
| Certificate / credential type mismatch | If `ClientServicesCredentialType` is not `Windows` (e.g. `NavUserPassword`, `AccessControlService`) the client must present the matching credential | Match `ClientServicesCredentialType` in CustomSettings.config and the client config |
| NST instance name wrong | Instance name is case-sensitive; defaults to `DynamicsNAV` | Confirm with `nav2009-service-tier-admin`; check CustomSettings.config `ServerInstance` |

**Quick diagnostic sequence:**
1. `Test-NetConnection <NST> -Port 7046` — if fails, service is down or firewall.
2. Check NST is Running: `Get-Service *Nav*`.
3. Compare client `ClientUserSettings.config` values with CustomSettings.config.
4. If auth-related errors, check Windows Event Log Application source `Microsoft Dynamics NAV` → **win-eventlog-triage**.

---

## Service Tier won't start

**Event Log source:** `Microsoft Dynamics NAV` in the Windows Application log on the NST host.

| Cause | Check | Fix / route |
|-------|-------|-------------|
| Bad CustomSettings.config | XML syntax error or wrong `DatabaseServer`, `DatabaseInstance`, `DatabaseName`, `ServerInstance` | Open the file, validate XML, check every connection string value → **nav2009-service-tier-admin** |
| Service account has no SQL login / insufficient rights | SQL Server error in Event Log; the NST service account needs `db_owner` (or at minimum `CONNECT` + schema rights) on the NAV database | → **nav2009-permissions-security** to add the SQL login |
| Service account missing "Log on as a service" right | Event log: `Error 1069: The service did not start due to a logon failure` | Grant "Log on as a service" in Local Security Policy / GPO |
| Port 7046 already in use | `netstat -ano | findstr :7046` | Identify the conflicting process; change `ClientServicesPort` or free the port |
| SPN registration failure | Event log contains Kerberos or SPN errors | Register SPN correctly (see RTC section above) |
| Database offline / SQL Server down | NST cannot connect to SQL at startup | Verify SQL Server is running and the database is online |
| Corrupted or wrong NAV license at startup | Some builds validate the license on NST start | Check `.flf` path in CustomSettings.config (`LicenseFile`) → **nav2009-permissions-security** |

**Always start here:** → **win-eventlog-triage** to pull the Application log from the NST server filtered to source `Microsoft Dynamics NAV` and level Error/Critical within the failure window.

---

## Classic client errors (license / permission / SQL)

### License errors

- **"Your program license has expired"** / **"Your license does not permit the use of..."**: the `.flf` license file is missing, expired, or lacks the required granules. Licenses are stored in the database (uploaded via Tools → License Information) or as a file. Check the expiry date and granule list.
- Distinguish license from permissions: license = what the *product* is allowed to do (granules/objects); permissions = what the *user* is allowed to do in NAV. Both can produce "not permitted" messages. → **nav2009-permissions-security**.

### Permission errors

- **"You do not have permission to read/write/execute..."**: the NAV Role assigned to the user lacks the required permission set, or the permission set has `Read`/`Insert`/`Modify`/`Delete`/`Execute` set to blank/No for that object ID. → **nav2009-permissions-security**.

### SQL errors surfaced in Classic client

| SQL Error | Meaning | Route |
|-----------|---------|-------|
| 1205 | Deadlock victim | → **nav2009-sql-performance** for deadlock graph; → **nav2009-development** for C/AL lock-order fix |
| 233 / 17142 | SQL Server not accepting connections / service paused | Check SQL Server state |
| 18456 | Login failed — bad password, account disabled, or login not mapped | → **nav2009-permissions-security** |
| 4060 | Cannot open database (wrong name or offline) | Check database name and state |
| 8152 | String or binary data would be truncated | C/AL writing a value longer than the field; → **nav2009-development** |

### "Another user has modified the record" / optimistic-concurrency conflict

NAV 2009 uses a timestamp-based optimistic-concurrency check on `MODIFY`/`DELETE`. This fires when a
second user (or concurrent session) writes the same record between your read and your write. Common
causes:

- Long transactions where the user leaves a record open for editing.
- Batch jobs that re-read and modify the same records another process is also touching.
- Stray `COMMIT` that broke a posting's atomicity, leaving a partial state another job then reads.

Action: → **nav2009-sql-performance** to see if blocking is involved; → **nav2009-development** to
review the C/AL transaction pattern.

---

## Slowness, locking & deadlocks

This is always a **two-skill** investigation: get the SQL evidence first, then map it back to C/AL.

**Step 1 — gather SQL evidence:** → **nav2009-sql-performance** (DMV triage script). It will surface:
- Current blocking chains and head blockers.
- Top queries by logical reads / CPU (identifies the expensive C/AL operations).
- Deadlock trace from the system health session or a configured trace.
- Index fragmentation and write-heavy indexes (SIFT views under posting load).
- Missing index suggestions.

**Step 2 — map to C/AL:** → **nav2009-development**. Common C/AL root causes:

| SQL symptom | C/AL root cause |
|-------------|----------------|
| Table scan on large ledger table | `SETCURRENTKEY` missing or not matching filters |
| High write contention on SIFT indexed views | Too many enabled SumIndexFields on hot posting tables |
| Deadlock involving `No. Series Line` | Custom code grabbing No. Series late in a transaction, after standard code already held it |
| Long-running blocking head blocker | `CONFIRM` or dialog inside a transaction; `COMMIT` in wrong place; batch job not chunked |
| `G/L Entry` or `Item Ledger Entry` scan per posting line | Missing key on a FlowField or `CALCSUMS` with no matching SIFT key |

**Step 3 — if fragmentation or stale stats are the finding:** → **nav2009-db-maintenance** to rebuild
indexes and update statistics.

---

## Posting & No. Series errors

Posting in NAV 2009 is all-or-nothing, driven by posting codeunits (CU 80 Sales-Post, CU 90
Purch.-Post, CU 12 Gen. Jnl.-Post Line, and their callers). A stray `COMMIT` or an abrupt
interruption mid-post can leave the system in a partial state.

| Symptom | Likely cause | Check / fix |
|---------|-------------|-------------|
| "G/L Entry already exists" on re-post | No. Series was advanced past the interrupt point; the document number was already used in a partial post | Check `G/L Entry` for the number; void/delete the partial entry if safe; reset `No. Series Line`."Last No. Used" — but only after confirming the partial post left no orphaned ledger entries |
| No. Series gaps after interrupted posting | Same as above — `COMMIT` inside the posting chain committed the No. Series advance but not the ledger writes | Review the posting chain for misplaced `COMMIT` → **nav2009-development** |
| "Dimension combination not allowed" | Dimension combination rule blocks the posting | Check Dimension Combinations setup; → **nav2009-development** if custom dimension code is involved |
| "Nothing to post" | Filters/conditions in the posting check found no lines; or all lines already posted | Check the document status and line `Qty. to Invoice`/`Qty. to Ship` fields |
| Posting hangs indefinitely | Blocking on `G/L Entry`, `No. Series Line`, or a ledger table | → **nav2009-sql-performance** to find the head blocker |

---

## NAS / Job Queue

The NAV Application Server (NAS) is a headless NAV service instance. Job Queue (standard in 2009)
runs inside NAS via **startup codeunit 450** (`Job Queue Dispatcher`).

| Symptom | Likely cause | Check / fix |
|---------|-------------|-------------|
| NAS service not running | Windows service stopped or failed to start | → **win-eventlog-triage** on the NAS host; → **nav2009-service-tier-admin** to check config and restart |
| Job Queue entries stuck on "In Process" | NAS crashed mid-job; entry not reset | Restart NAS; set the stuck entry back to "Ready" or "On Hold" and re-enable |
| Job Queue entries errored | The C/AL codeunit/report the entry calls is throwing an error | Check `Job Queue Log Entry` for the error text; → **nav2009-development** to fix the code |
| NAS not picking up new entries | Wrong startup codeunit (must be 450) or wrong method/argument in NAS config | → **nav2009-service-tier-admin** to review `NASStartupCodeunit`, `NASStartupMethod`, `NASStartupArgument` in CustomSettings.config |
| NAS starts but processes no work | Job Queue entries all on hold, or no entries with "Ready" status | Check Job Queue entries in the application; re-enable entries |

Key CustomSettings.config values for NAS (verify via **nav2009-service-tier-admin**):
- `NASStartupCodeunit` = `450` for Job Queue
- `NASStartupMethod` = `RunJobQueue`
- `NASStartupArgument` = (optional category filter)

---

## .NET / COM (R2)

DotNet variables and .NET interop are available **only in NAV 2009 R2** on the RTC service tier. They
do not run in the Classic client or in pre-R2 builds.

| Symptom | Likely cause | Check |
|---------|-------------|-------|
| ".NET/COM call failed" at runtime | Assembly not present on the service tier server | Confirm the DLL is deployed server-side (not just on the developer workstation) |
| Works in Classic, fails via RTC | Code uses `Automation` (COM) which runs client-side in Classic but must run server-side in RTC | Audit `Automation` variable's `RunOnClient` property; true = client, false = server |
| "Type not found" or "Could not load file or assembly" | Wrong version/GAC vs local path; 32-bit vs 64-bit mismatch | Verify the assembly is GAC-registered or in the NAV service tier `Add-ins` folder; confirm bitness |
| Fails only on non-R2 Service Tier | Build is NAV 2009 SP1, not R2 | Confirm build number; DotNet variables require R2 (`7.0.x` service tier build) |

→ **nav2009-development** for the C/AL patterns around DotNet/Automation variable usage.

---

## Reports

| Symptom | Likely cause | Fix / route |
|---------|-------------|-------------|
| "Report layout not found" / blank RDLC output | The `.rdlc` file is not compiled into the report object, or wrong `DefaultLayout` property | Recompile the report with the correct RDLC; → **nav2009-object-management** |
| Classic report runs but RTC version shows wrong data | RDLC dataset columns don't match what the Classic DataItems produce | Regenerate the RDLC dataset; → **nav2009-development** |
| "Microsoft Report Viewer" error on client | Report Viewer 2008 (v9) not installed on the RTC client machine | Install Microsoft Report Viewer 2008 Redistributable |
| Report crashes / hangs | Infinite loop in DataItem triggers; very large dataset without key-aligned filters | → **nav2009-development** to review DataItem filters and SETCURRENTKEY |
| Totals wrong across page breaks | `GetData`/`SetData` pattern not implemented for page headers | → **nav2009-development** (RDLC section in REFERENCE) |

---

## Deployment / compile

| Symptom | Likely cause | Fix / route |
|---------|-------------|-------------|
| Objects won't import via finsql.exe | Wrong `servername`/`database`/`ntauthentication` arguments; Classic client not same build as database | → **nav2009-object-management** |
| Compile errors after import | Object references a non-existent function, table field, or global variable not present in this build | Fix missing references; → **nav2009-development** for C/AL patterns |
| Schema synchronization conflict | A table field was added/renamed in the object but the SQL column doesn't exist yet (or vice versa) | Run schema sync from C/SIDE (Tools → Schema Sync / Alter); → **nav2009-object-management** |
| "You do not have a license to modify object type..." | License granules don't cover the object type being compiled | → **nav2009-permissions-security** (license) |
| Version list conflicts | Merged object has version tags from multiple sources in unexpected order | Resolve manually in the object; → **nav2009-object-management** for merge workflow |

---

## Crashes

Crashes (NST process exits unexpectedly, Classic client crashes, NAS dies) require capturing the
Windows Event Log **before** any restart clears transient state.

**Immediate action:** → **win-eventlog-triage** on the affected server(s). Filter for:
- Source: `Microsoft Dynamics NAV`, `Application Error`, `.NET Runtime`, `Windows Error Reporting`
- Level: Critical, Error
- Time window: 5 minutes around the crash time

**Useful details to capture:**
- NAV build number (Help → About in the client, or the NST service binary version).
- Any dump file written to `%LOCALAPPDATA%\Microsoft\Microsoft Dynamics NAV\` or the Windows Error Reporting store.
- The exact sequence of user actions or batch job that triggered the crash.

Common crash patterns in NAV 2009:
- Stack overflow from deep recursive C/AL (usually a coding error → **nav2009-development**).
- Out-of-memory on the NST when a runaway query returns millions of rows.
- .NET assembly exception in R2 bubbling uncaught out of a DotNet variable call (→ **nav2009-development**).
- Windows patch or .NET Framework update changing COM/Automation behavior.

---

## Gotchas

Common misdiagnoses when triaging NAV 2009 symptoms — the surface presentation points you the wrong way.

**"RTC won't connect" is almost never a client problem — check the Service Tier first.**
The RoleTailored Client has no direct path to SQL; every connection goes through the NST on port 7046. When users report that the client "can't connect" or hangs at the loading screen, the instinct is to check the client config (`ClientUserSettings.config`) or the user's workstation. In practice the NST service is stopped or crashed in the majority of cases. Run `Get-Service *Nav*` on the NST host before touching anything on the client side. → **nav2009-service-tier-admin**.

**A "permission error" may be a license limit — they need different fixes.**
"You do not have permission to..." can be raised by both the NAV permission system (Role/Permission Set) and by the license granule check. The message text is nearly identical; the fix is not. A missing permission set entry is fixed in NAV security setup. A missing granule requires a new or updated `.flf` license file uploaded to the database. Trying to fix a license problem through permission sets (or vice versa) wastes time and changes nothing. Check the license granule list in Tools → License Information before editing any Role. → **nav2009-permissions-security**.

**"Another user has modified the record" is a concurrency conflict, not data corruption.**
The phrasing makes users fear their data is inconsistent or that someone deliberately overwrote their work. In almost all cases it is NAV's timestamp-based optimistic-concurrency guard firing because two sessions read and then attempted to write the same record. There is nothing wrong with the data; the losing transaction was simply rolled back. The real question is *why* the collision is recurring — usually a long open transaction (user left a record in edit mode) or a batch job that overlaps with interactive use. → **nav2009-sql-performance** to check for blocking; → **nav2009-development** for the C/AL transaction pattern.

**Slow posting is a locking/blocking problem, not a raw query speed problem.**
When posting hangs or takes minutes, the first instinct is to look for slow queries or missing indexes. In NAV 2009 posting is almost always bottlenecked by *lock contention* — typically the `No. Series Line` table or a high-traffic ledger table (`G/L Entry`, `Item Ledger Entry`) held by another session or by the posting transaction itself. A missing SIFT key or a `CALCSUMS` without a matching SumIndexField are secondary causes. Start with `sys.dm_exec_requests` and `sys.dm_os_waiting_tasks` to find the blocking head; only move to index fragmentation or query cost analysis if no blocking is present. → **nav2009-sql-performance**.

**Compile errors after an object import mean the objects were not compiled — the import itself succeeded.**
When `finsql.exe` imports objects and the subsequent compile step fails, users often conclude that the import was corrupt or incomplete and re-run it. The import wrote the objects to the database correctly; the compile failed because the imported code references something (a function, a field, a global) that does not exist in this database/build. Re-importing the same FOB achieves nothing. Fix the missing reference or resolve the build mismatch, then recompile. → **nav2009-object-management** for the compile workflow; → **nav2009-development** if the reference gap is a C/AL code issue.

**"The Job Queue stopped processing" is usually an NST/NAS instance issue, not an application-level problem.**
When Job Queue entries stop being picked up, the first place users look is the entries themselves — status, schedule, recurrence. But if *all* entries have stopped simultaneously, the NAS Windows service has almost certainly stopped or crashed. Check `Get-Service *Nav*` on the NAS host and the Windows Application Event Log before touching any Job Queue entries in the application. Resetting entries to "Ready" while the NAS service is down has no effect. → **win-eventlog-triage** on the NAS host; → **nav2009-service-tier-admin** to restart.

---

## When to use which skill

| Problem domain | Skill |
|---------------|-------|
| NST won't start; start/stop/restart; CustomSettings.config; NAS config | **nav2009-service-tier-admin** |
| Slow queries, blocking, deadlocks, fragmentation evidence (read-only) | **nav2009-sql-performance** |
| Index rebuild, CHECKDB, backup, update stats (action) | **nav2009-db-maintenance** |
| Permissions, roles, SQL logins, license files | **nav2009-permissions-security** |
| C/AL coding, key/SIFT design, posting chain, reports, integrations | **nav2009-development** |
| Import/export/compile objects, finsql.exe, schema sync | **nav2009-object-management** |
| Windows Event Log capture on any server | **win-eventlog-triage** |
| You don't know which skill yet — start here | **nav2009-troubleshooting** (this skill) |
