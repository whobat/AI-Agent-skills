---
name: tidsregistrering
description: Registers/edits/deletes time entries in 7pace Timetracker (Azure DevOps, Dagrofa "IT Infrastruktur") across a range of weekdays. Primary path is the bundled Python API script (fast, no UI); browser UI automation is a fallback. Use when the user wants to log/register work hours ("tidsregistrering", "registrer tid", "log timer", "bogfør timer") on a work item ID over a date range with a per-day hours pattern (e.g. "7:30 man-tor og 7:00 fredag fra april til dags dato på #32933").
---

# Tidsregistrering (7pace Timetracker)

Creates/updates/deletes worklogs in 7pace. **Prefer the API script** (`scripts/tidsregistrering.py`) — it uses the 7pace REST API directly and is ~100× cheaper than clicking the UI. Fall back to the browser UI only if the API token is unavailable.

## Inputs to parse from the user's request

| Input | Example | Notes |
|-------|---------|-------|
| Hours per day | `7:30 man-tor og 7:00 fredag` | Maps to `--hours "7.5 man-tor og 7.0 fre"` (the script takes decimal or HH:MM, comma or dot). |
| Date range | `fra april til dags dato` | `--from`/`--to`. Script understands `dags dato`, Danish month names, `YYYY-MM-DD`, `DD-MM-YYYY`. |
| Description | `"work"` | `--comment`. Mandatory (this org rejects empty comments). |
| Work item ID | `#32933` **or** free text like `Nordisk film` | `--work-item 32933`. If the user gives a name instead of an ID, resolve it first with `--search` (see below). |

Danish weekdays: man=Mon … fre=Fri. The script's weekday pattern only includes the days you name, so **Sat/Sun are skipped automatically** in batch mode.

**Danish public-holiday weekdays** → register on **work item ID 840** ("Ikke-arbejdstid") with comment **"Helligdag"** (same hours as a normal day), NOT the normal work item. Holidays in scope: Skærtorsdag, Langfredag, 2. påskedag, Kr. Himmelfart, 2. pinsedag, 1. nytårsdag, 1.+2. juledag. **Store Bededag is abolished (2024+); Grundlovsdag (5 Jun) is NOT an official helligdag** — treat both as normal workdays unless told otherwise. If a holiday already has time, flag it rather than duplicating.

## Method 1 (preferred): API script

`SCRIPT` = this skill's `scripts/tidsregistrering.py`. `CFG` = `~/.7pace/config.json` (the default config path — so `--config` is optional below; shown for clarity).

**First-time setup:** `python SCRIPT --auth` prompts (hidden) for the 7pace **Bearer API token** (generated in 7pace → Settings → Reporting & API) and an optional **Azure DevOps PAT** (for `--search`, scope "Work Items (Read)"), then writes `~/.7pace/config.json` (chmod 600, gitignored). The two tokens are separate systems. If config already has valid tokens, skip this. Always pass `--yes --json` for automation.

0. **Resolve work item from free text** (if the user named a project/work item instead of a numeric ID): `python SCRIPT --config CFG --search "Nordisk film" --json`. Search is **org-wide** by default (across all ADO projects). To narrow when there are too many hits, add `--project "IT Infrastruktur"` (or whichever project the user names). Returns `matches` (id, title, type, state, project). **Exactly one match** → use its id. **Multiple matches** → ask the user which one (AskUserQuestion listing "id — title — project (state)"; surface state so they avoid Obsolete/closed items); never guess. **Zero matches** → tell the user; don't proceed. If `count` is ~50 (the cap), results were truncated → ask the user to refine the text. (Search uses the Azure DevOps PAT in `config.json` → `azure_devops.pat`, scope "Work Items (Read)" — separate from the 7pace token.)
1. **Confirm the plan first** (day count, total hours, work item, comment) — can be 40+ entries.
2. **Health check**: `python SCRIPT --config CFG --date "dags dato" --hours 0 --dry-run --json` → expect `status: dry_run` (proves auth + base_url).
3. **Batch create** the range (auto-skips weekends; skips days that already have time by default):
   `python SCRIPT --config CFG --from 2026-04-01 --to "dags dato" --hours "7.5 man-tor og 7.0 fre" --work-item 32933 --comment "work" --yes --json`
4. **Holidays**: batch step 3 also creates entries on holiday *weekdays*. For each Danish holiday in range, convert it: `python SCRIPT --config CFG --date 2026-05-14 --list --json` to get the worklog `id`, then `python SCRIPT --config CFG --update <id> --work-item 840 --comment "Helligdag" --hours 7.5 --yes --json`. (`--update` sets workItemId from `--work-item`; always pass it explicitly so you don't accidentally reset it to the default.)
5. **MANDATORY final validation** (always last): `python SCRIPT --config CFG --from <start> --to <end> --list --json` and confirm **every weekday in range has an entry** — normal work item on regular days, ID 840 on holiday weekdays. Acceptable blanks: weekends and pre-existing days you intentionally left. Any other blank weekday is an unintended gap → fix and re-list. Don't declare done until clean.
6. **Report**: days created (date+hours), holidays converted, days skipped (weekend/holiday/existing), totals, and "validation: every weekday accounted for". Fail loud on any gap or `status: error`/`partial`.

Single entry: `--date "2026-06-08" --hours 7.5 --work-item 32933 --comment "work" --yes --json`.
Delete: `--delete <id> --yes --json`. List a day/range: `--list` with `--date` or `--from/--to`.

If the script returns `status: error` with `401`/auth problems, the token is missing/expired → tell the user to regenerate the 7pace token in Settings → Reporting & API (it is NOT the Azure DevOps PAT). Then fall back to Method 2 only if needed.

## Method 2 (fallback): browser UI automation

Only if the API token can't be used. Drive the 7pace **Timesheet weekly grid** via the claude-in-chrome MCP. Full click recipe, coordinates, and gotchas (masked Length field, double-click-Comment trick, limited-mode data lag) are in [REFERENCE.md](REFERENCE.md).
