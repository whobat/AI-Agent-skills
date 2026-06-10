# skills/

## Purpose

Each `skills/<name>/` folder is one portable Agent Skill, installable into any agent that honors the SKILL.md open standard. Folders here are the product the installers ship.

## Ownership

This doc owns skill-authoring conventions. Per-skill behavior is documented inside each skill's own `SKILL.md` / `REFERENCE.md` — do not duplicate it here.

## Local Contracts

- **Required files:** `SKILL.md` with frontmatter that follows the [Agent Skills spec](https://agentskills.io/specification) strictly — only `name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`; no custom top-level fields. `name` must equal the folder name; `license: MIT`; the version lives under `metadata: version: "x.y.z"`. `npm run validate` enforces all of it (also in CI).
- **Bump `metadata.version` on every behavior change** to a skill — the installers diff installed vs repo version to offer updates. No bump = installed copies never get the change.
- **Evals:** each skill has `evals/<name>.json` at the repo root with 3+ scenarios (`query` + `expected_behavior`); update them when behavior changes. New skills start from `template/skill-name/`.
- **`description` is the trigger surface:** keep it specific with example phrasings; agents match on it to decide when to invoke the skill.
- **Optional files:** `REFERENCE.md` (detailed reference), `scripts/` (code), `config.example.json` (secrets template — copy to `config.json`, which is gitignored and never committed), `skill.install.json` (install metadata).
- **`skill.install.json` has two shapes** depending on what the skill needs:
  - Runtime auto-install: a `requirements` array of `{name, detect, minVersion, wingetId, brewCask, githubRepo, url}` (see `nav2009-sql-performance`, `win-eventlog-triage`). Requirements that can't be auto-installed (e.g. `finsql.exe`) add `detectPaths` (file locations counting as present), `warnOnly: true`, and `help` — installers warn and continue instead of installing (see `nav2009-object-management`).
  - Credentials / packages: `authCommand`, `configPath`, `requires`, `pipPackages`, `description`, `authHelp` (see `7pace-time-tracker`).
- **Secrets stay out of git:** ship only `config.example.json`. The installers strip `config.json` and `__pycache__/` on copy.
- **Adding a skill:** create the folder + files above, then add its row to the **Available skills** and requirements tables in the root [README.md](../README.md).

## Verification

Skills that bundle scripts ship their own tests next to the script:
- Python: `cd skills/7pace-time-tracker/scripts && python -m unittest test_timetracker -v`
- PowerShell/Pester: `Invoke-Pester -Path ./skills/<name>/scripts/*.Tests.ps1 -Output Detailed`

## Child DOX Index

No child AGENTS.md — each skill is self-documented by its `SKILL.md`.
