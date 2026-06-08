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
- If the #32933 row is absent (empty week), tick "Show items from previous week" (`1362,116`); the row appears with empty cells.

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
- **Skip**: Sat/Sun; Danish public holidays; any weekday already showing hours (report these as "skipped — already had time").
- Track progress and report at month boundaries. At the end, list every day registered (date+hours), every skip with reason, and the grand total. Flag ambiguous near-holidays (e.g. the Friday after Kr. Himmelfart, Grundlovsdag June 5) — these are NOT official helligdage so they get filled by default, but the user may want them removed.
