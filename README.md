# AI-Agent-Skills

[![CI](https://github.com/whobat/AI-Agent-skills/actions/workflows/ci.yml/badge.svg)](https://github.com/whobat/AI-Agent-skills/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A shared collection of **Agent Skills** — portable `SKILL.md`-based capabilities that work across multiple coding agents (Claude Code, OpenAI Codex, OpenCode, Gemini CLI, Cursor, and more).

A *skill* is just a folder containing a `SKILL.md` (YAML frontmatter + Markdown instructions) plus optional `scripts/` and `references/`. Every skill in this repo conforms to the [Agent Skills specification](https://agentskills.io/specification) — only spec-defined frontmatter fields (`name`, `description`, `license`, `compatibility`, `metadata`), validated in CI by `npm run validate` — so the same folder installs into any supporting agent. Licensed under [MIT](LICENSE); contributions welcome, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Requirements

What you need depends on which skills you install. The skill itself (`SKILL.md`) is just text and needs nothing — the requirements come from any scripts a skill ships and the credentials it talks to.

**General**

| Requirement | When it's needed | Notes |
|-------------|------------------|-------|
| **Node.js 18+** | Only for the `npx` installer (`bin/cli.js`). | Not needed if you use `install.ps1` / `install.sh` or copy folders manually. |
| **Python 3.8+** | Any skill that ships `.py` scripts (currently **7pace-time-tracker**). | All three installers **auto-detect Python and offer to install it** when a Python-based skill is selected — via `winget` (Windows), `brew` (macOS), or `apt-get`/`dnf` (Linux). If no package manager is found, install manually from [python.org](https://www.python.org/downloads/). The installers also **`pip install` each skill's Python packages** (declared in `skill.install.json`). |
| **PowerShell 7+** | Any skill that declares it as a requirement (currently **win-eventlog-triage** and **nav2009-sql-performance**). | All three installers **auto-install it** when such a skill is selected: `winget install Microsoft.PowerShell` on Windows (falling back to downloading + silently running the latest MSI from GitHub if `winget` is absent), `brew install --cask powershell` on macOS. See [Runtime requirements](#runtime-requirements-skillinstalljson). |
| **A supported package manager** | Only for the auto-install above. | `winget` / `brew` / `apt-get` / `dnf`. Without one, install the runtime yourself, then re-run. |

> After an auto-install, Python may not be on `PATH` for the current terminal session — open a **new** terminal (or re-run the installer) so the freshly installed `python` is found.

**Per-skill**

| Skill | Runtime | Python packages | Credentials |
|-------|---------|-----------------|-------------|
| **branded-report** | Python 3.8+ | `markdown`, `python-docx`, `beautifulsoup4`, `pillow`, `pypdfium2`, `pypdf` (installed automatically) | A local `theme.json` (brand colors/fonts/logo). PDF additionally needs a headless Chrome/Edge/Chromium (warn-only). |
| **7pace-time-tracker** | Python 3.8+ | `requests` (installed automatically) | `config.json` with a 7pace **Bearer token** (worklog CRUD) + optional Azure DevOps **PAT** (work-item search). See [Configuration & secrets](#configuration--secrets). |
| **win-eventlog-triage** | PowerShell 7+ (auto-installed) | — | A tier-admin credential, **prompted each run** and never stored. WinRM must be enabled on the target servers. |
| **rds-profile-triage** | PowerShell 7+ (auto-installed) | — | A tier-admin credential, **prompted each run** and never stored. WinRM (or DCOM/WMI for the dead-WinRM fallback) on the target RDS hosts. Read-only. |
| **nav2009-development** | — (knowledge-only) | — | — |
| **nav2009-sql-performance** | PowerShell 7+ (auto-installed) | — | Windows integrated auth by default (or `-SqlCredential`, prompted). Needs `VIEW SERVER STATE` + `VIEW DATABASE STATE` on the SQL Server. Read-only. |
| **nav2009-object-management** | NAV 2009 Classic client (`finsql.exe` — from a NAV install, not auto-installable; warned if missing) | — | Manual Object Designer runbook (NAV 2009 has **no object CLI** — that arrived in NAV 2013). Developer license for `.txt`/compile; end-user license suffices for `.fob` import. SQL read access for verification. |
| **nav2009-service-tier-admin** | PowerShell 7+ (auto-installed) | — | Local admin to read service config / restart; remote needs CIM/WinRM + admin on the target. Inventory is read-only; restart is opt-in. |
| **nav2009-db-maintenance** | PowerShell 7+ (auto-installed) | — | Windows integrated auth by default (or `-SqlCredential`, prompted). `db_backupoperator`/`db_owner` (backup), ALTER (index), `db_owner`/`sysadmin` (CHECKDB). Defaults to a dry run. |
| **nav2009-permissions-security** | — (knowledge-only) | — | — |
| **nav2009-troubleshooting** | — (knowledge-only) | — | — |
| **ai-agent-skills-update** | Node.js 18+ (for the npx path; warn-only) | — | — |
| **sqlserver-perf-triage** | PowerShell 7+ (auto-installed) | — | Windows integrated auth (or `-SqlCredential`, prompted). `VIEW SERVER STATE` + `VIEW DATABASE STATE`. Read-only. |
| **ax2012-sql-performance** | PowerShell 7+ (auto-installed) | — | Windows integrated auth (or `-SqlCredential`, prompted). `VIEW SERVER STATE` + `VIEW DATABASE STATE`. Read-only. |
| **retail-pos-fleet-health** | PowerShell 7+ (auto-installed) | — | Admin credential on the targets, **prompted each run**. WinRM on the targets. Read-only. |

## Repository layout

Skills are grouped into **category folders** for overview (`skills/<category>/<name>/`).
The grouping is repo-side only — every installer discovers skills by their `SKILL.md` and
installs them **flat** into the agent's skills dir, so an agent still sees one namespace
(`~/.claude/skills/<name>/`). Each category folder is listed in `.claude-plugin/plugin.json`
so the Claude Code marketplace finds them too.

```
AI-Agent-skills/
├── README.md
├── .gitignore                 # ignores real config.json / secrets
├── package.json               # enables: npx github:whobat/AI-Agent-skills
├── bin/cli.js                 # npx installer (interactive + flags)
├── install.ps1                # script installer (Windows PowerShell)
├── install.sh                 # script installer (macOS/Linux/Git-Bash)
├── .claude-plugin/            # marketplace.json + plugin.json (lists the category folders)
└── skills/
    ├── nav-2009/              # category folder (7 NAV 2009 skills)
    ├── ax-retail/             # Dynamics AX 2012 + Retail POS
    ├── sql-server/ · windows-ops/ · documents/ · time-tracking/ · repo-tooling/
    └── time-tracking/
        └── 7pace-time-tracker/   # one folder per skill; name == this folder
            ├── SKILL.md            # the skill manifest + instructions
            ├── REFERENCE.md        # detailed reference (optional)
            ├── skill.install.json  # optional: runtime requirements, pip packages, credential-setup command
            ├── config.example.json # template — copy to config.json (gitignored)
            └── scripts/
                ├── timetracker.py
                └── test_timetracker.py
```

## Available skills

| Skill | What it does | Extra setup |
|-------|--------------|-------------|
| **branded-report** | **Standardized branded documents**: turns a Markdown report into **HTML + PDF + DOCX** from one source and one theme, so every report looks identical. The theme (brand colors/fonts/logo) can be auto-extracted from a PowerPoint/Office template (`.pptx`/`.docx`/`.xlsx`/…) or sampled from an image, website, or PDF. | Python 3.8+, `pip install markdown python-docx beautifulsoup4 pillow pypdfium2 pypdf`, a local `theme.json`; PDF needs a headless browser. |
| **7pace-time-tracker** | **7pace Timetracker** (Azure DevOps): create/edit/delete time entries via REST API, plus free-text work-item search. | Python 3.8+, `pip install requests`, and a `config.json` (see [Configuration & secrets](#configuration--secrets)). |
| **win-eventlog-triage** | **Windows Event Log triage**: pulls Critical/Error events from one or many servers in parallel over WinRM, groups them, and returns JSON the agent turns into a critical-first summary. | PowerShell 7+ (auto-installed by the installer), WinRM on the targets, and a tier-admin credential (prompted each run — nothing stored). |
| **rds-profile-triage** | **RDS session-host profile & WinRM-host triage**: read-only health of terminal-server profiles over WinRM (CIM/DCOM fallback when the WinRM host won't even launch) — profile-hive leaks, temp-profile sprawl, ProfileList corruption (the "Element not found" chain that kills WinRM), the roaming-profile path read RAW, drain state, and User-Profiles-Service failures grouped by the actual user. Built to dodge the REG_EXPAND_SZ and double-hop misdiagnosis traps. | PowerShell 7+ (auto-installed), WinRM (or DCOM/WMI) on the targets, a tier-admin credential (prompted each run). |
| **nav2009-development** | **Dynamics NAV 2009 / C/AL development**: coding patterns, key/SIFT design, review checklist, customization architecture, reports, integrations, and BC-upgrade posture. Knowledge-only (no scripts). | None. |
| **nav2009-sql-performance** | **NAV 2009 SQL performance triage**: read-only DMV snapshot of the SQL Server behind a NAV 2009 database (top queries, waits, blocking, deadlocks, missing/unused indexes, SIFT views, fragmentation, stale stats) as JSON, plus a NAV-specific interpretation guide for the agent. | PowerShell 7+ (auto-installed), `VIEW SERVER STATE`/`VIEW DATABASE STATE` on the SQL Server. |
| **nav2009-object-management** | **NAV 2009 object deployment runbook**: guides export/import/compile of C/AL objects (`.fob`/`.txt`) through the Classic client's Object Designer — NAV 2009 has **no object CLI** (`finsql command=` arrived in NAV 2013) — and verifies results via a read-only SQL query against the Object table. Knowledge-only. | NAV 2009 Classic client with an appropriate license on the machine doing the manual steps. |
| **nav2009-service-tier-admin** | **NAV 2009 Service Tier / NAS admin**: inventories NST instances (status, account, ports, parsed `CustomSettings.config`, NAS/Job Queue config) as JSON; optional opt-in restart in the correct order. Local or via `-ComputerName`. | PowerShell 7+ (auto-installed); local admin (or remote CIM/WinRM). |
| **nav2009-db-maintenance** | **NAV 2009 SQL maintenance** (action side of the perf skill): backup, `DBCC CHECKDB`, rebuild/reorganize NAV-owned indexes, and update statistics — defaulting to a dry run that prints the exact T-SQL. Never creates/drops indexes (NAV owns them). | PowerShell 7+ (auto-installed), SQL maintenance permissions. |
| **nav2009-permissions-security** | **NAV 2009 security & permissions**: Roles/permission sets, object permissions (incl. indirect), security filters, Windows vs Database logins, NAV↔SQL synchronization and Standard vs Enhanced models, and the license-vs-permission distinction. Knowledge-only. | None. |
| **nav2009-troubleshooting** | **NAV 2009 triage runbook**: maps a reported symptom (RTC won't connect, Service Tier won't start, login/permission/license errors, posting/locking failures, NAS/Job Queue stopped, deployment/compile errors, crashes) to a likely cause and routes to the right NAV 2009 skill. Knowledge-only. | None. |
| **sqlserver-perf-triage** | **Generic SQL Server performance triage** (any instance/database): read-only DMV snapshot — top queries, waits, blocking, deadlocks, missing/unused indexes, fragmentation, stale stats, config — as JSON, with a generic interpretation guide. | PowerShell 7+ (auto-installed), `VIEW SERVER STATE`/`VIEW DATABASE STATE`. |
| **ax2012-sql-performance** | **Dynamics AX 2012 (R3) SQL performance triage**: the same read-only snapshot, interpreted through an AX lens — known bloat tables and their cleanup routines, RCSI/TF4136/MAXDOP posture, AOT-owned indexes, and Retail channel DB / CDX sync health. | PowerShell 7+ (auto-installed), `VIEW SERVER STATE`/`VIEW DATABASE STATE`. |
| **retail-pos-fleet-health** | **POS / Windows fleet health sweep** over WinRM: stopped auto-start services, local SQL instances with per-DB sizes (flags databases nearing the SQL Express 10 GB limit), low disk, recent error counts — ranked warnings as JSON. Read-only. | PowerShell 7+ (auto-installed), WinRM on the targets, admin credential (prompted). |
| **ai-agent-skills-update** | **Update skills installed from THIS repo** (and only this repo — other skills are never touched): runs the installer in `--update` mode across all agents, refreshes every installed repo skill to the latest published version, installs nothing new, preserves local `config.json`. Triggers on "update my AI-Agent-skills". | Node.js 18+ for the npx path (warned if missing; clone + `install.ps1`/`install.sh -Update` works without). |

## Install as a Claude Code plugin (marketplace)

Claude Code users can install everything through the native plugin system — updates then
arrive automatically with every push to this repo:

```
/plugin marketplace add whobat/AI-Agent-skills
/plugin install ai-agent-skills@ai-agent-skills
```

The plugin exposes all skills in `skills/`. For Codex/OpenCode (or if you want the
runtime auto-install and credential setup), use the `npx` installer below instead.

## Install with `npx` (recommended)

No clone needed — run it straight from GitHub:

```bash
# Interactive (pick agent + skill, optional credential setup)
npx github:whobat/AI-Agent-skills

# Non-interactive
npx github:whobat/AI-Agent-skills --agent claude --skill all
npx github:whobat/AI-Agent-skills --agent codex  --skill 7pace-time-tracker --auth
```

Flags: `--agent claude|codex|opencode|all` (`all` = every agent in one run) · `--skill all|<name>` · `--update` (refresh installed skills to the latest repo versions — installs nothing new) · `--auth` (run a skill's credential setup after install) · `--symlink` · `--list` (add `--agent` to see installed vs latest versions) · `-y/--yes` · `-h`.

```bash
# Update everything you have installed, across all agents, in one go:
npx -y github:whobat/AI-Agent-skills --update --agent all --yes
```
(The **ai-agent-skills-update** skill wraps exactly this — say "update my AI-Agent-skills" to your agent. It only touches skills from this repo.)

The installer copies skill folders into the agent's skills dir and **never copies real `config.json`** (only `config.example.json`). With `--auth` (or when prompted), it runs the skill's credential setup so your tokens are entered securely and saved locally — see [Configuration & secrets](#configuration--secrets). If a skill's credentials are **already configured** (its `configPath` file exists, e.g. `~/.7pace/config.json`), the installer detects it and asks whether to **update the tokens or keep them** (keep is the default) instead of prompting for setup from scratch.

## Install with the bundled scripts (no Node)

If you've cloned the repo and prefer not to use Node:

**Windows (PowerShell):**
```powershell
./install.ps1 -Agent claude -Skill all
./install.ps1 -Agent codex -Skill 7pace-time-tracker
```

**macOS / Linux / Git-Bash:**
```bash
./install.sh --agent claude --skill all
./install.sh --agent codex --skill 7pace-time-tracker
```

`-Agent`/`--agent`: `claude` · `codex` · `opencode` · `all` (every agent in one run).  `-Skill`/`--skill`: `all` or a skill folder name. Add `-Update`/`--update` to refresh installed skills only (installs nothing new; run `git pull` first — the comparison is against your clone), `-Symlink`/`--symlink` to link instead of copy, or `-Yes`/`--yes` to auto-apply runtime installs and skill updates without prompting.

## Manual install (per agent)

A skill = the folder `skills/<category>/<name>/`. Copy (or symlink) that folder into the agent's skills directory **as `<name>/`** (drop the category — agents want a flat skills dir). The `npx`/script installers do this flattening for you; the commands below are the manual equivalent.

| Agent | Personal/global skills dir | Project-level |
|-------|----------------------------|---------------|
| **Claude Code** | `~/.claude/skills/<name>/` | `.claude/skills/<name>/` |
| **OpenAI Codex** | `~/.agents/skills/<name>/` | `<repo>/.agents/skills/<name>/` |
| **OpenCode** | `~/.config/opencode/skills/<name>/` (also reads `~/.claude/skills/` and `~/.agents/skills/`) | `.opencode/skills/<name>/` |
| **Gemini CLI / Cursor / Cline / Windsurf** | place under their skills dir, or reuse `~/.claude/skills/` or `~/.agents/skills/` | project `.agents/skills/` |
| **Any other agent** | If it supports the `SKILL.md` standard, drop the folder in its skills dir. If not, the bundled Python script still works standalone — call it from the shell (see below). |

> **Tip — one copy, many agents:** `~/.agents/skills/` is read by Codex *and* OpenCode, and Claude Code reads `~/.claude/skills/`. Symlinking a skill into both covers most setups:
> ```bash
> ln -s "$PWD/skills/time-tracking/7pace-time-tracker" ~/.claude/skills/7pace-time-tracker
> ln -s "$PWD/skills/time-tracking/7pace-time-tracker" ~/.agents/skills/7pace-time-tracker
> ```

**Examples (manual copy)** — note the `skills/*/*` glob, which flattens the category folders:
```bash
# Claude Code — all skills (flattened from their category folders)
cp -r skills/*/* ~/.claude/skills/
# Codex — single skill (drop the category in the destination)
cp -r skills/time-tracking/7pace-time-tracker ~/.agents/skills/7pace-time-tracker
```
```powershell
# Claude Code — all skills (PowerShell)
Copy-Item skills/*/* "$HOME/.claude/skills/" -Recurse
```

### "Pi" / other agents

There is no single standard for every agent. Two fallbacks that always work:
1. **SKILL.md as instructions** — paste the `SKILL.md` body into the agent's rules/instructions file (e.g. `AGENTS.md`, a system prompt, or a custom command).
2. **Script is agent-agnostic** — `skills/7pace-time-tracker/scripts/timetracker.py` is a plain Python CLI. Any agent (or you) can run it directly; see its `--help`.

## Configuration & secrets

Skills that need credentials ship a `config.example.json`. **Never commit real tokens** — `.gitignore` already excludes `config.json` (and `.env`, etc.).

**Easiest — guided setup (recommended):** the installer's `--auth` runs it for you, or run it directly:
```bash
python skills/7pace-time-tracker/scripts/timetracker.py --auth
```
It prompts (tokens hidden) and writes `~/.7pace/config.json` (chmod 600). For `7pace-time-tracker` that's the **7pace Bearer token** (worklog CRUD) and an optional Azure DevOps **PAT** (work-item search) — two separate systems, both kept out of git.

**Manual alternative:**
```bash
cp skills/7pace-time-tracker/config.example.json ~/.7pace/config.json   # then edit with your tokens
```
The script reads `~/.7pace/config.json` by default; override with `--config <path>`.

## Verifying a skill (tests)

Skills that bundle scripts may include tests. **CI (GitHub Actions) runs everything below
on Windows and Linux for every push/PR**, plus `npm run validate`, which checks every
skill against the [Agent Skills specification](https://agentskills.io/specification).
`evals/<skill>.json` holds per-skill evaluation scenarios (query + expected behavior) for
manual/LLM-driven behavior testing.

**Installer tests** live in `tests/installers/` — one suite per installer. They are
hermetic: each test runs the installer against a throwaway repo copy with fixture
skills and a **fake HOME**, so your real skills dirs, configs, and network are never
touched. They cover install/`all`, secret stripping (`config.json`/`__pycache__`),
version updates (incl. preserving an installed `config.json`), error exits, and the
credential detection (configured → update-or-keep / "already configured").

```bash
npm test                                                    # npx installer (Node 18+)
bash tests/installers/test_install_sh.sh                    # install.sh (needs bash 4+)
```
```powershell
Invoke-Pester -Path ./tests/installers/Install.Tests.ps1 -Output Detailed   # install.ps1
```

```bash
# Python (7pace-time-tracker)
cd skills/7pace-time-tracker/scripts
python -m unittest test_timetracker -v                 # unit tests, no network
RUN_INTEGRATION=1 python -m unittest test_timetracker -v   # + live API (needs config.json)
```
```powershell
# PowerShell / Pester — every script-backed skill ships a *.Tests.ps1 next to its script
Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser
Invoke-Pester -Path (Get-ChildItem skills -Recurse -Filter '*.Tests.ps1').FullName -Output Detailed
```

## Runtime requirements (`skill.install.json`)

A skill can declare runtimes it needs in `skill.install.json`. All three installers
ensure each requirement is present (and ≥ `minVersion` when detectable) before
finishing, **auto-installing** any that are missing:

```json
{
  "requirements": [
    {
      "name": "PowerShell 7",
      "detect": "pwsh",
      "minVersion": "7.0",
      "wingetId": "Microsoft.PowerShell",
      "brewCask": "powershell",
      "githubRepo": "PowerShell/PowerShell",
      "url": "https://github.com/PowerShell/PowerShell/releases/latest"
    }
  ]
}
```

- **Windows:** `winget install <wingetId>`; if `winget` is missing, the installer
  downloads the latest `win-<arch>.msi` from `github.com/<githubRepo>` and runs it
  silently (`msiexec /quiet`).
- **macOS:** `brew install --cask <brewCask>`.
- **Linux / no package manager:** prints the `url` to install manually.

Requirements that **cannot be auto-installed** (e.g. NAV 2009's `finsql.exe`, which only
ships with the NAV Classic client) instead declare `detectPaths` (file locations to check —
the installer also accepts these as present) and `"warnOnly": true` plus a `help` text: the
installer then prints a **warning with the checked paths and guidance** and continues — the
skill still installs, since the tool may live on another machine or a custom path
(the script's `-FinSqlPath` overrides detection at runtime).

If a runtime is installed but not yet on `PATH` for the current shell, open a **new**
terminal. (The same file may also declare `pipPackages`, `authCommand`, `authHelp`, and
`configPath` — the location of the skill's credential file, e.g. `~/.7pace/config.json`.)

## Updating installed skills

Each `SKILL.md` carries a version under `metadata: version:` in its frontmatter (per the
Agent Skills spec; legacy top-level `version:` in already-installed copies is still
recognized). On any install run, the
installer compares the **installed** version of every other skill in the target
agent's directory against the **repo** version, and offers to update the ones that
differ (showing `old -> new`). Updates re-copy the skill files while **preserving any
`config.json`** inside the skill folder. Pass `-Yes` (PowerShell) / `--yes` / `-y`
(bash, npx) to apply updates non-interactively; omit it to be prompted.

So after you change a skill, bump its `metadata.version` and re-run the installer —
anyone who already has it installed is offered the update automatically.

## Adding a new skill

Copy [`template/skill-name/`](template/skill-name/SKILL.md) to `skills/<name>/` and follow
[CONTRIBUTING.md](CONTRIBUTING.md). In short:

1. Spec-compliant frontmatter only (`name` matching the folder, `description` ≤1024 chars with when-to-use triggers, `license: MIT`, `metadata.version`, optional `compatibility`). `npm run validate` enforces this.
2. Put any code in `scripts/` (with tests next to it), reference docs in `REFERENCE.md`, and a `config.example.json` if it needs secrets.
3. If it needs a runtime (Python packages, PowerShell 7, …), declare it in `skill.install.json` (see [Runtime requirements](#runtime-requirements-skillinstalljson)).
4. Add 3+ evaluation scenarios in `evals/<name>.json` and a row to **Available skills** above. Bump `metadata.version` whenever you change the skill so installed copies are offered the update. Commit.

## Sources

- [Agent Skills — the open standard](https://www.agensi.io/learn/agent-skills-open-standard)
- [Codex Agent Skills](https://developers.openai.com/codex/skills)
- [OpenCode Agent Skills](https://opencode.ai/docs/skills/)
- [Agent Skills in the Claude Code SDK](https://code.claude.com/docs/en/agent-sdk/skills)
