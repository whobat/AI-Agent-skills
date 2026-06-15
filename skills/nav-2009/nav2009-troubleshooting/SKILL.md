---
name: nav2009-troubleshooting
description: Triage runbook and router for Microsoft Dynamics NAV 2009 operational problems — covers RTC/Classic client can't connect, Service Tier won't start, login/permission and license errors, slowness/locking/deadlocks during posting, posting and No.-Series errors, NAS/Job Queue not running, .NET/COM failures (R2), RDLC report failures, deployment/compile failures, and crashes. It maps a reported symptom to the most likely cause and routes you to the right sibling NAV 2009 skill. Use when: a user reports any NAV/Navision error or outage and you need to find the cause fast; "RTC won't connect"; "the NAV service won't start"; "posting is failing"; "the Job Queue stopped"; or any other NAV 2009 operational complaint where the root cause is unknown.
license: MIT
metadata:
  version: "1.0.3"
---

# NAV 2009 Troubleshooting

This is the **entry-point and router** for NAV 2009 / Navision operational incidents. It is
knowledge-only; detailed symptom/cause/fix tables live in [REFERENCE.md](REFERENCE.md) — consult it
before giving a diagnosis or asking the user to take action.

For writing or reviewing C/AL code, use **nav2009-development**. For SQL-side locking evidence, use
**nav2009-sql-performance**. For index rebuilds, backups, and CHECKDB, use **nav2009-db-maintenance**.

## First triage questions

Ask these before diving into any specific symptom — the answers determine which branch to follow:

1. **Which client?** Classic (2-tier, direct SQL) or RoleTailored Client / RTC (3-tier, via Service Tier)?
2. **Which build / version?** NAV 2009 SP1 or R2? (R2 adds .NET interop in the service tier.)
3. **One user or all users?** Single-user = auth/permission/workstation. All users = service, network, or DB.
4. **When did it start / after what change?** Deploy, config edit, SQL maintenance, patch, password change?
5. **Exact error text and/or error number?** (SQL error numbers, NAV error dialogs, Windows Event Log source and ID.)

## Symptom → first move

| Symptom | Most likely cause | First action / skill |
|---------|-------------------|----------------------|
| RTC client won't connect | Service Tier stopped; wrong port/server; firewall; Kerberos double-hop | `Test-NetConnection <NST> -Port 7046`; → **nav2009-service-tier-admin** |
| Service Tier won't start | Bad CustomSettings.config; service account/SQL login; port conflict; SPN failure | Check Windows Event Log → **win-eventlog-triage**; → **nav2009-service-tier-admin** |
| "You do not have permission to..." | NAV role/permission missing or not synchronized with SQL login | → **nav2009-permissions-security** |
| "Your program license has expired / does not permit..." | License file (.flf) missing, expired, or wrong granules | → **nav2009-permissions-security** (license vs permissions distinction) |
| "The following SQL Server error occurred..." | Connection failure, login, or deadlock (error 1205) | Read the SQL error number; deadlock → **nav2009-sql-performance** |
| "Another user has modified the record" | Optimistic-concurrency conflict / long transaction | → **nav2009-sql-performance** for blocking picture; → **nav2009-development** for C/AL lock order |
| Slowness / hangs / deadlocks during posting | Missing SETCURRENTKEY; SIFT contention; fragmentation; blocking | → **nav2009-sql-performance** (evidence), then **nav2009-development** (C/AL cause), then **nav2009-db-maintenance** (rebuild/stats) |
| Posting errors (No. Series, dimension, "nothing to post") | Interrupted posting advanced No. Series; dimension setup; stray COMMIT | → **nav2009-development** (posting chain logic) |
| NAS / Job Queue not processing | NAS service stopped; startup codeunit/argument wrong; entries on hold | → **nav2009-service-tier-admin** |
| ".NET/COM call failed" | Not running R2 service tier; assembly missing server-side | Confirm R2 build; → **nav2009-development** |
| Reports fail / RDLC errors | Wrong runtime (Classic sections vs RDLC); missing client report viewer | → **nav2009-development** |
| Objects won't import, compile, or schema-sync fails | Object conflicts; compile order; schema-sync mismatch | → **nav2009-object-management** |
| Crash / unexpected close | OS/driver issue, NAV build bug, or memory | → **win-eventlog-triage** (capture Application log + dump info) |

## Routing map

- **nav2009-service-tier-admin** — NST inventory, start/stop/restart, CustomSettings.config parsing, NAS/Job Queue service config.
- **nav2009-sql-performance** — read-only SQL DMV triage: locking, blocking, deadlocks, slow queries, index fragmentation evidence.
- **nav2009-db-maintenance** — SQL backups, CHECKDB integrity checks, index rebuilds, update statistics (action side).
- **nav2009-permissions-security** — NAV Roles/permissions, SQL logins, license files, NAV↔SQL security sync.
- **nav2009-development** — C/AL coding patterns, key/SIFT design, posting chain logic, reports, integrations, code review.
- **nav2009-object-management** — import/export/compile objects via finsql.exe, schema sync, version management.
- **win-eventlog-triage** — pull Critical/Error Windows Event Log entries across servers; essential for service-tier crashes and startup failures.
