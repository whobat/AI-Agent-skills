# Per-entry recipe — Timesheet weekly grid

All actions use `mcp__Claude_in_Chrome__computer` on the active 7pace **Timesheet** tab.
Coordinates are for a **1568×744** viewport (keep the window ~maximized). Take a
screenshot first if unsure; the inline editor is a **fixed centered modal** so its
field positions are stable regardless of which cell you double-click.

## Layout reference (1568-wide)
- Week label + nav: `‹` ≈ `189,88`, `›` ≈ `331,88`.
- "Show items from previous week" checkbox ≈ `1362,116` (dropdown "previous week" ≈ `1490,116`).
- Grid data row y ≈ `172`. Column x-centers: **Mon 697, Tue 811, Wed 925, Thu 1038, Fri 1152** (Sat 1264, Sun 1378 — skip).
- Inline editor (after double-click a cell): title "Add Time", shows work item + date.
  - **Length** field ≈ `742,378` (masked HH:MM, shows e.g. `7:30`)
  - Activity Type ≈ `790,378` (leave `[Not Set]`)
  - Billable checkbox ≈ `843,378` (default on)
  - **Comment** field ≈ `925,378`
  - **Total** readout ≈ `735,457` (shows committed hours, e.g. `7.5`)
  - **Cancel** ≈ `940,483`, **Save** ≈ `986,483`, close X ≈ `994,291`

## Reaching the right week
- From any week, click `‹`/`›` to step weeks. After clicking, **wait ~3s** for "Loading…" to clear, then `zoom` the header+grid (`180,80 → 1540,210`) to read the week label and existing values. Navigation clicks fired during load are lost — re-click if the label didn't change.
- If the work-item row is absent (empty week), tick "Show items from previous week" (`1362,116`); the row appears with empty cells.

## Filling one cell (the reliable 3-call flow)
For a weekday cell that is **empty** and **in range** (else skip):

1. **Open + set Length** (one batch):
   `double_click` the day cell (e.g. Tue = `811,172`) → `wait 1` → `triple_click` Length (`742,378`) → four `key` presses for HHMM:
   - 7:30 → `0` `7` `3` `0`   (Mon–Thu)
   - 7:00 → `0` `7` `0` `0`   (Fri)
2. **Set Comment** (one batch): `double_click` Comment (`925,378`) → `wait 1` → `type` the comment (e.g. `work`) → `wait 1` → `zoom` (`722,350 → 1010,400`) to confirm BOTH the comment text and the committed Length/Total. If the comment is empty, repeat the double-click + type (it's ~50% on first try).
3. **Save + verify** (one batch): `left_click` Save (`986,483`) → `wait 3` → `zoom` the row (`180,138 → 1540,185`) and confirm the cell now shows the value and the week Σ increased.

Notes:
- `double_click` on the **cell** opens the editor; `double_click` on the **Comment field** forces its edit mode (plain click then type is unreliable). The Length field needs `triple_click` to select before the digit keys.
- Entering `0`,`7`,`3`,`0` yields `7:30` with minutes selected; Total shows `7.5` after the field blurs (clicking Comment blurs it).
- After Save the editor closes and the row updates in place; move to the next cell.

## Looping
- Fill all in-range empty weekdays in the current week, then `›` to the next week, wait, re-read, repeat.
- **Skip**: Sat/Sun; public holidays in the user's locale; any weekday already showing hours (report these as "skipped — already had time").
- Track progress and report at month boundaries. At the end, list every day registered (date+hours), every skip with reason, and the grand total. Flag ambiguous near-holidays (bridge days adjacent to an official holiday) — these are not official holidays so they get filled by default, but the user may want them removed.

## Gotchas

**The 7pace Bearer token and the ADO PAT are not interchangeable — using the wrong one fails silently or with a confusing error.**
The script uses two credentials for two different jobs: the 7pace Bearer token (set up via `--auth`) is required for all worklog CRUD operations against `timehub.7pace.com`; the Azure DevOps PAT is only used by `--search` to query the ADO Work Items API. If `--search` returns a `401` or no results despite the work item existing, check that the ADO PAT is present in `~/.7pace/config.json` and has "Work Items (Read)" scope — the 7pace token alone will not authenticate ADO searches.

**Re-running a range with `--no-skip-existing` creates duplicate worklogs — no overwrite protection.**
By default, the script skips days that already have a worklog (`--skip-existing` is on). If you re-run a batch and pass `--no-skip-existing`, it creates a second entry on every already-logged day. To correct a logged day, use `--date <date> --list --json` to find the existing worklog `id`, then `--update <id> ...` to change it — do not re-create.

**Work items can only be referenced by numeric ID — a name string passed to `--work-item` will fail or match incorrectly.**
`--work-item` expects a numeric ADO work-item ID (e.g. `--work-item 12345`). If the user gives a name ("Website Redesign"), you must resolve it first with `--search "Website Redesign" --json`, confirm exactly one non-closed match, and use its `id`. Skipping the search step and guessing or fabricating an ID will silently attach the worklog to the wrong item.

**`--update` resets the work item to the provided `--work-item` value — omitting it does not preserve the original.**
When running `--update <worklog-id>`, always pass `--work-item <id>` explicitly. The SKILL.md workflow (step 4) warns about this specifically for holiday conversions: if you omit `--work-item`, the update may clear or reset the associated work item, corrupting the entry. Always fetch the current entry via `--list --json` first to confirm what you are modifying.

**`today` and `yesterday` are resolved using the local machine's clock — a run near midnight can log to the wrong calendar date.**
The date tokens `today` and `yesterday` expand to the machine's local date at the moment the script runs. A request made at 23:58 on a Monday and executed at 00:01 Tuesday will log to Tuesday. For any time-sensitive or cross-midnight scenario, pass an explicit `YYYY-MM-DD` date instead of a relative token.

**Weekday tokens in `--hours` patterns must be English — locale names or abbreviations in other languages are rejected.**
The range pattern parser recognises only the English tokens `mon tue wed thu fri sat sun` (or full English names). Tokens in other languages (e.g. `lun`, `lundi`, `ma`) will not match and the day will be silently omitted from the batch. Always translate user-supplied weekday names to English before constructing the `--hours` string.
