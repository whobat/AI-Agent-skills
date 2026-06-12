# DOX framework

- DOX is highly performant AGENTS.md hierarchy installed here
- Agent must follow DOX instructions across any edits

## Core Contract

- AGENTS.md files are binding work contracts for their subtrees
- Work products, source materials, instructions, records, assets, and durable docs must stay understandable from the nearest applicable AGENTS.md plus every parent AGENTS.md above it

## Read Before Editing

1. Read the root AGENTS.md
2. Identify every file or folder you expect to touch
3. Walk from the repository root to each target path
4. Read every AGENTS.md found along each route
5. If a parent AGENTS.md lists a child AGENTS.md whose scope contains the path, read that child and continue from there
6. Use the nearest AGENTS.md as the local contract and parent docs for repo-wide rules
7. If docs conflict, the closer doc controls local work details, but no child doc may weaken DOX

Do not rely on memory. Re-read the applicable DOX chain in the current session before editing.

## Update After Editing

Every meaningful change requires a DOX pass before the task is done.

Update the closest owning AGENTS.md when a change affects:

- purpose, scope, ownership, or responsibilities
- durable structure, contracts, workflows, or operating rules
- required inputs, outputs, permissions, constraints, side effects, or artifacts
- user preferences about behavior, communication, process, organization, or quality
- AGENTS.md creation, deletion, move, rename, or index contents

Update parent docs when parent-level structure, ownership, workflow, or child index changes. Update child docs when parent changes alter local rules. Remove stale or contradictory text immediately. Small edits that do not change behavior or contracts may leave docs unchanged, but the DOX pass still must happen.

## Hierarchy

- Root AGENTS.md is the DOX rail: project-wide instructions, global preferences, durable workflow rules, and the top-level Child DOX Index
- Child AGENTS.md files own domain-specific instructions and their own Child DOX Index
- Each parent explains what its direct children cover and what stays owned by the parent
- The closer a doc is to the work, the more specific and practical it must be

## Child Doc Shape

- Create a child AGENTS.md when a folder becomes a durable boundary with its own purpose, rules, responsibilities, workflow, materials, or quality standards
- Work Guidance must reflect the current standards of the project or user instructions; if there are no specific standards or instructions yet, leave it empty
- Verification must reflect an existing check; if no verification framework exists yet, leave it empty and update it when one exists

Default section order:
- Purpose
- Ownership
- Local Contracts
- Work Guidance
- Verification
- Child DOX Index

## Style

- Keep docs concise, current, and operational
- Document stable contracts, not diary entries
- Put broad rules in parent docs and concrete details in child docs
- Prefer direct bullets with explicit names
- Do not duplicate rules across many files unless each scope needs a local version
- Delete stale notes instead of explaining history
- Trim obvious statements, repeated rules, misplaced detail, and warnings for risks that no longer exist

## Closeout

1. Re-check changed paths against the DOX chain
2. Update nearest owning docs and any affected parents or children
3. Refresh every affected Child DOX Index
4. Remove stale or contradictory text
5. Run existing verification when relevant
6. Report any docs intentionally left unchanged and why

## Project

Distributes portable **Agent Skills** — `SKILL.md` folders that install into Claude Code, Codex, OpenCode, and any agent honoring the open SKILL.md standard. User-facing usage, the skill catalog, and setup live in [README.md](README.md); this file holds the binding rules for editing the repo.

Layout: `skills/<name>/` (the skills, one folder each) · `bin/cli.js` + `install.ps1` + `install.sh` (the three installers) · `tests/installers/` (installer test suites) · `package.json` (enables `npx github:whobat/AI-Agent-skills`).

## Project Contract

- **`main` is protected — no direct pushes.** A GitHub ruleset requires every change to
  go through a pull request, and all three CI status checks (spec validation, Windows,
  Linux) must pass before merge. Workflow: create a branch, commit, push the branch,
  open a PR (`gh pr create`), wait for CI (`gh pr checks --watch`), then merge
  (`gh pr merge --squash --delete-branch`). There is no bypass — run the test suites
  locally before pushing to avoid red PRs.
- **Installer parity is mandatory.** `bin/cli.js`, `install.ps1`, and `install.sh` must behave identically (same agents, flags, copy/secret-strip/version-update/credential-detection logic). A change to one requires the equivalent change to the other two and to their test suites in `tests/installers/`.
- **A skill is the folder `skills/<category>/<name>/`** with a `SKILL.md` whose frontmatter follows the [Agent Skills specification](https://agentskills.io/specification) **strictly**: only spec-defined fields (`name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`); the version lives under `metadata.version`. Skills are grouped into category folders for repo overview, but `name` must equal the skill's **own** folder (not the category), and **names are globally unique** (they install flat into one namespace). Every category folder must be listed in `.claude-plugin/plugin.json`'s `skills` array (else the marketplace misses it). The installers discover skills by their `SKILL.md` (any depth ≤ 2) and install them **flat** into the agent dir. `node tests/validate-skills.mjs` (also `npm run validate` / CI) enforces all of this and must pass before every commit that touches a skill. Owning rules live in [skills/AGENTS.md](skills/AGENTS.md).
- **Never commit real secrets.** Only `config.example.json` is tracked; `.gitignore` excludes `config.json`. Installers strip `config.json` and `__pycache__/` on copy and preserve an already-installed `config.json` on update.
- **No company-specific data — ever.** This repo is public and must be usable by anyone. Committed content must not contain: real company or customer names, AD/DNS domains, server/instance/database names, Azure DevOps organization or project names, real work-item IDs, license details, internal policies tied to one employer, or personal usernames/home paths. Use neutral placeholders instead (`<your-org>`, `Acme`, `MyProject`, `SRV01`, `NAVDB`, work item `12345`). Anything tenant-specific belongs in the user's local `config.json` (gitignored) or environment variables; tenant-dependent tests must read those and **skip** when unset. Before committing, grep your changes for names that only make sense inside one company.
- **Vendored scripts stay byte-identical.** Skills must be self-contained (spec + plugin caching + per-skill installs), so scripts shared between skills are vendored — copied into each skill's `scripts/` folder. `tests/check-vendored-parity.mjs` (in `npm test` and CI) lists the groups and fails on drift. To change one: edit a copy, propagate it to every copy in the group, and bump `metadata.version` in every affected skill. Current group: `Invoke-SqlPerfTriage.ps1` (+ its Tests) across `nav2009-sql-performance`, `sqlserver-perf-triage`, `ax2012-sql-performance`.
- **Keep README in sync** with reality: the **Available skills** table and per-skill requirements rows must match the actual `skills/` folders and their `skill.install.json`.

## User Preferences

When the user requests a durable behavior change, record it here or in the relevant child AGENTS.md

- All committed content must be fully anonymized and generalized (see "No company-specific data" above) — placeholders, not the real employer, customers, or infrastructure.

## Child DOX Index

- [skills/AGENTS.md](skills/AGENTS.md) — authoring contract for skills: `SKILL.md` shape, `skill.install.json`, versioning, scripts, secrets.
- [tests/AGENTS.md](tests/AGENTS.md) — hermetic installer test suites (one per installer) and how to run them.