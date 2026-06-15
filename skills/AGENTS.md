# skills/

## Purpose

Each `skills/<name>/` folder is one portable Agent Skill, installable into any agent that honors the SKILL.md open standard. Folders here are the product the installers ship.

## Ownership

This doc owns skill-authoring conventions. Per-skill behavior is documented inside each skill's own `SKILL.md` / `REFERENCE.md` — do not duplicate it here.

## Local Contracts

- **Layout:** skills live in **category folders** — `skills/<category>/<name>/` (e.g. `skills/nav-2009/nav2009-sql-performance/`). The grouping is repo-side only; installers discover skills by their `SKILL.md` and install them **flat** into the agent dir. A new category folder must be added to `.claude-plugin/plugin.json`'s `skills` array (the validator fails otherwise). Skill `name`s are **globally unique** across all categories.
- **Required files:** `SKILL.md` with frontmatter that follows the [Agent Skills spec](https://agentskills.io/specification) strictly — only `name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`; no custom top-level fields. `name` must equal the skill's **own** folder name (not the category); `license: MIT`; the version lives under `metadata: version: "x.y.z"`. `npm run validate` enforces all of it (also in CI).
- **Bump `metadata.version` on every behavior change** to a skill — the installers diff installed vs repo version to offer updates. No bump = installed copies never get the change.
- **Evals:** each skill has `evals/<name>.json` at the repo root with 3+ scenarios (`query` + `expected_behavior`); update them when behavior changes. New skills start from `template/skill-name/`.
- **`description` is the trigger surface:** keep it specific with example phrasings; agents match on it to decide when to invoke the skill.
- **A `## Gotchas` section is REQUIRED** (`npm run validate` enforces its presence). Put it in `REFERENCE.md` (script/operational skills) or in `SKILL.md` for knowledge-only skills with no REFERENCE. It captures the *real, mechanism-level* pitfalls of the skill's domain — **measurement traps** (a tool that reports a misleading value), **errors that point at the wrong cause**, **environment foot-guns**, and known **misattributions** — so the agent doesn't repeat a mistake someone already made. Each gotcha states the **trap → the mechanism → the correct check/fix**. Quality over quantity: a few verifiable, specific gotchas beat a padded list; never invent one to satisfy the check.
- **Committed gotchas MUST be generic — no company-specific data, ever** (the repo is public; same rule as everywhere). Anything tenant-specific — a real server/DB/domain name, an environment quirk, a local naming convention — goes in a per-skill **`gotchas.local.md`** that is **gitignored and never committed** (`*.local.md` is in `.gitignore`; the installers strip it on a fresh copy and **preserve it on update**, like `config.json`). This is how a skill gets *better after first use*: the running agent reads `gotchas.local.md` (if present) at the start of a run and **appends** newly-learned environment-specific pitfalls to it. Every skill's Gotchas section must tell the agent to do this. Keep the repo gotchas generic; let the local file accumulate the specifics.
- **A `## Verification` section is REQUIRED** (`npm run validate` enforces its presence). It documents two things: (1) **how to verify correctness BEFORE making changes** — a baseline/repro/health-check/preconditions the agent establishes first (for read-only skills, how to confirm ground truth/coverage before recommending anything); and (2) **how to verify the OUTPUT/result afterward** — re-run the check, confirm the expected effect, and fail loud if it can't be confirmed. No change should be proposed without a before-check, and no result reported as done without an after-check.
- **Optional files:** `REFERENCE.md` (detailed reference), `scripts/` (code), `config.example.json` (secrets template — copy to `config.json`, which is gitignored and never committed), `gotchas.local.md` (env-specific learnings — gitignored, preserved on update), `skill.install.json` (install metadata).
- **`skill.install.json` has two shapes** depending on what the skill needs:
  - Runtime auto-install: a `requirements` array of `{name, detect, minVersion, wingetId, brewCask, githubRepo, url}` (see `nav2009-sql-performance`, `win-eventlog-triage`). Requirements that can't be auto-installed (e.g. `finsql.exe`) add `detectPaths` (file locations counting as present), `warnOnly: true`, and `help` — installers warn and continue instead of installing (see `nav2009-object-management`).
  - Credentials / packages: `authCommand`, `configPath`, `requires`, `pipPackages`, `description`, `authHelp` (see `7pace-time-tracker`).
- **Secrets stay out of git:** ship only `config.example.json`. The installers strip `config.json`, `gotchas.local.md`, and `__pycache__/` on copy, and preserve `config.json` + `gotchas.local.md` on update. A change to that strip/preserve logic in one installer (`bin/cli.js`, `install.ps1`, `install.sh`) requires the equivalent change in the other two **and** their test suites in `tests/installers/`.
- **Adding a skill:** create the folder + files above, then add its row to the **Available skills** and requirements tables in the root [README.md](../README.md).

## Verification

Skills that bundle scripts ship their own tests next to the script:
- Python: `cd skills/7pace-time-tracker/scripts && python -m unittest test_timetracker -v`
- PowerShell/Pester: `Invoke-Pester -Path ./skills/<name>/scripts/*.Tests.ps1 -Output Detailed`

## Child DOX Index

No child AGENTS.md — each skill is self-documented by its `SKILL.md`.
