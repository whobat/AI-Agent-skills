---
name: 7pace-time-tracker
version: 1.0.1
description: 7pace Time Tracker (Azure DevOps) — create/edit/delete worklogs in 7pace for the myCompany "IT Infrastruktur" org, on a SINGLE day or across a range of weekdays. Primary path is the bundled Python 7pace REST API script (fast, no UI); browser UI automation of 7pace is a fallback. Use when the user wants to log/register/track work hours in 7pace on a work item (by numeric ID or by name) — e.g. "register 4 hours on #32933 on 9 April 2026", "log 7.5h today on Nordisk Film", or "7:30 Mon–Thu and 7:00 Fri from April to today".
---

# 7pace Time Tracker (myCompany)

> **This skill targets [7pace Timetracker](https://www.7pace.com/) for Azure DevOps.** All time entries (worklogs) are created in 7pace via its REST API at `https://<org>.timehub.7pace.com`.

Creates / updates / deletes worklogs in 7pace. **Prefer the API script** (`scripts/timetracker.py`) — it calls the 7pace REST API directly and is far cheaper than driving the UI. Fall back to the browser UI only if no API token is available.

It supports **two modes**:

- **Single day** — one entry on one date: `--date <date> --hours <H>`.
- **Range of weekdays** — batch across a period with a per-weekday pattern: `--from <start> --to <end> --hours "<pattern>"` (weekends are skipped automatically).

`SCRIPT` = this skill's `scripts/timetracker.py`. Config lives at `~/.7pace/config.json` (the default — `--config <path>` only needed to override). Always pass `--yes --json` for automation.

## First-time setup (once)

`python SCRIPT --auth` prompts (input hidden) for the 7pace **Bearer API token** (7pace → Settings → Reporting & API → Create New Token) and an optional **Azure DevOps PAT** (only for `--search`, scope "Work Items (Read)"), and writes `~/.7pace/config.json` (chmod 600, gitignored). The two tokens are different systems — the ADO PAT does not work for 7pace and vice-versa. Skip if config already has valid tokens.

## Inputs to parse from the user's request

| Input | How to pass | Notes |
|-------|-------------|-------|
| **One date** | `--date 2026-04-09` | Single-day mode. Accepts `YYYY-MM-DD`, `DD-MM-YYYY`, `today`, or `yesterday`. Convert other relative dates ("last Friday") to an absolute `YYYY-MM-DD` yourself. |
| **Date range** | `--from 2026-04-01 --to 2026-06-08` | Batch mode. Same date formats; `--to today` = up to today. |
| **Hours (single)** | `--hours 4` or `--hours 7:30` | Decimal or `HH:MM`; comma or dot both work (`7,5` = `7.5` = `7:30`). |
| **Hours (range)** | `--hours "7.5 mon-thu and 7.0 fri"` | Per-weekday pattern. Weekday tokens: `mon tue wed thu fri sat sun` (or full names). Only the named days are created, so Sat/Sun are skipped. `all` = all weekdays. |
| **Comment** | `--comment "Work"` | Mandatory — 7pace rejects empty comments. |
| **Work item** | `--work-item 32933` | Numeric ID. If the user gives a **name** instead, resolve it with `--search` first (see Examples). |

## Holidays

Danish public holidays that fall on a weekday must be booked on work item **#840 "Ikke-arbejdstid"** (non-working time) with comment **"Helligdag"** (same hours as a normal day) — NOT the normal work item. In-scope holidays: Maundy Thursday, Good Friday, Easter Monday, Ascension Day, Whit Monday, New Year's Day, Christmas Day + Boxing Day. **Store Bededag is abolished (2024+) and Constitution Day (5 Jun) is not an official holiday** — treat both as normal workdays unless told otherwise. If a holiday already has time logged, flag it instead of duplicating.

## Examples

> Replace dates/IDs/hours with the user's actual request. `--json` returns machine-readable output you can parse and report back.

**1. Single day, known work item** ("register 4 hours on #32933 on 9 April 2026"):
```
python SCRIPT --date 2026-04-09 --hours 4 --work-item 32933 --comment "Work" --yes --json
```

**2. Single day = today** ("log 7.5 hours today on #32933"):
```
python SCRIPT --date today --hours 7.5 --work-item 32933 --comment "Work" --yes --json
```

**3. Register by project NAME** ("log 7:30 today on Nordisk Film") — search → pick → create:
```
python SCRIPT --search "Nordisk Film" --json          # returns matches with id/title/project/state
# 1 match → use it. Multiple → ask the user which id (show title — project — state). 0 → tell them.
python SCRIPT --date today --hours 7:30 --work-item <id> --comment "Work" --yes --json
```

**4. Date range with a weekday pattern** ("7:30 Mon–Thu and 7:00 Fri from 1 April to today"):
```
python SCRIPT --from 2026-04-01 --to today --hours "7.5 mon-thu and 7.0 fri" --work-item 32933 --comment "Work" --yes --json
```
Weekends are skipped automatically; days that already have time are skipped by default (`--no-skip-existing` to override).

**5. A holiday weekday** (book non-working time):
```
python SCRIPT --date 2026-05-14 --hours 7.5 --work-item 840 --comment "Helligdag" --yes --json
```

**6. List, update, delete** (find an entry's id, change it, or remove it):
```
python SCRIPT --date 2026-04-09 --list --json                                  # -> worklogs with ids
python SCRIPT --update <id> --hours 8 --work-item 32933 --comment "Work" --yes --json
python SCRIPT --delete <id> --yes --json
```

**7. Dry-run / health check** (verify auth + connection, creates nothing):
```
python SCRIPT --date today --hours 0 --dry-run --json     # expect status: dry_run
```

## Workflow for a bulk range (steps)

1. **Confirm the plan first** (day count, total hours, work item, comment) — a range can be 40+ entries.
2. **Health check** (Example 7) → expect `status: dry_run`.
3. **Batch create** the range (Example 4).
4. **Holidays**: the batch also creates entries on holiday *weekdays*. For each holiday in range, convert it: `--date <holiday> --list` to get the `id`, then `--update <id> --work-item 840 --comment "Helligdag" --hours <h> --yes`. (`--update` sets the work item from `--work-item`; always pass it so you don't reset it.)
5. **MANDATORY final validation** (always last): `--from <start> --to <end> --list --json` and confirm **every weekday in range has an entry** — normal work item on regular days, #840 on holiday weekdays. The only acceptable blanks are weekends and pre-existing days you intentionally left. Any other blank weekday is a gap → fix and re-list. Don't declare done until clean.
6. **Report**: days created (date+hours), holidays converted, days skipped (weekend/holiday/existing), totals, and "validation: every weekday accounted for". Fail loud on any gap or `status: error`/`partial`.

For a **single day** you don't need the full workflow — just confirm the request and run Example 1/2/3, then report.

## Search details

`--search "<text>"` matches work-item titles **org-wide** (across all ADO projects) by default; add `--project "IT Infrastruktur"` to narrow. Returns `matches` (id, title, type, state, project). Exactly 1 → use it; multiple → ask the user (show id — title — project — state, so they avoid Obsolete/closed items); 0 → tell them; ~50 (the cap) → ask them to refine.

## Errors

If the script returns `status: error` with `401`/auth problems, the token is missing/expired → tell the user to regenerate the 7pace token (Settings → Reporting & API; it is NOT the Azure DevOps PAT) or run `--auth`. Only then consider Method 2.

## Method 2 (fallback): browser UI automation

Only if the API token cannot be used. Drive the 7pace **Timesheet weekly grid** via the claude-in-chrome MCP. Full click recipe, coordinates and gotchas (masked Length field, double-click-Comment trick, limited-mode data lag) are in [REFERENCE.md](REFERENCE.md).
