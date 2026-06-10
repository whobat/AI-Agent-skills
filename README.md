# AI-Agent-Skills

A shared collection of **Agent Skills** — portable `SKILL.md`-based capabilities that work across multiple coding agents (Claude Code, OpenAI Codex, OpenCode, Gemini CLI, Cursor, and more).

A *skill* is just a folder containing a `SKILL.md` (YAML frontmatter `name` + `description`, then Markdown instructions) plus optional `scripts/` and `references/`. The format is an [open standard](https://www.agensi.io/learn/agent-skills-open-standard), so the same folder installs into any supporting agent.

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
| **7pace-time-tracker** | Python 3.8+ | `requests` (installed automatically) | `config.json` with a 7pace **Bearer token** (worklog CRUD) + optional Azure DevOps **PAT** (work-item search). See [Configuration & secrets](#configuration--secrets). |
| **win-eventlog-triage** | PowerShell 7+ (auto-installed) | — | A tier-admin credential, **prompted each run** and never stored. WinRM must be enabled on the target servers. |
| **nav2009-development** | — (knowledge-only) | — | — |
| **nav2009-sql-performance** | PowerShell 7+ (auto-installed) | — | Windows integrated auth by default (or `-SqlCredential`, prompted). Needs `VIEW SERVER STATE` + `VIEW DATABASE STATE` on the SQL Server. Read-only. |

## Repository layout

```
AI-Agent-skills/
├── README.md
├── .gitignore                 # ignores real config.json / secrets
├── package.json               # enables: npx github:whobat/AI-Agent-skills
├── bin/cli.js                 # npx installer (interactive + flags)
├── install.ps1                # script installer (Windows PowerShell)
├── install.sh                 # script installer (macOS/Linux/Git-Bash)
└── skills/
    └── 7pace-time-tracker/ # one folder per skill (7pace Timetracker)
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
| **7pace-time-tracker** | **7pace Timetracker** (Azure DevOps): create/edit/delete time entries via REST API, plus free-text work-item search. | Python 3.8+, `pip install requests`, and a `config.json` (see [Configuration & secrets](#configuration--secrets)). |
| **win-eventlog-triage** | **Windows Event Log triage**: pulls Critical/Error events from one or many servers in parallel over WinRM, groups them, and returns JSON the agent turns into a critical-first summary. | PowerShell 7+ (auto-installed by the installer), WinRM on the targets, and a tier-admin credential (prompted each run — nothing stored). |
| **nav2009-development** | **Dynamics NAV 2009 / C/AL development**: coding patterns, key/SIFT design, review checklist, customization architecture, reports, integrations, and BC-upgrade posture. Knowledge-only (no scripts). | None. |
| **nav2009-sql-performance** | **NAV 2009 SQL performance triage**: read-only DMV snapshot of the SQL Server behind a NAV 2009 database (top queries, waits, blocking, deadlocks, missing/unused indexes, SIFT views, fragmentation, stale stats) as JSON, plus a NAV-specific interpretation guide for the agent. | PowerShell 7+ (auto-installed), `VIEW SERVER STATE`/`VIEW DATABASE STATE` on the SQL Server. |

## Install with `npx` (recommended)

No clone needed — run it straight from GitHub:

```bash
# Interactive (pick agent + skill, optional credential setup)
npx github:whobat/AI-Agent-skills

# Non-interactive
npx github:whobat/AI-Agent-skills --agent claude --skill all
npx github:whobat/AI-Agent-skills --agent codex  --skill 7pace-time-tracker --auth
```

Flags: `--agent claude|codex|opencode` · `--skill all|<name>` · `--auth` (run a skill's credential setup after install) · `--symlink` · `--list` · `-y/--yes` · `-h`.

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

`-Agent`/`--agent`: `claude` · `codex` · `opencode`.  `-Skill`/`--skill`: `all` or a skill folder name. Add `-Symlink`/`--symlink` to link instead of copy, or `-Yes`/`--yes` to auto-apply runtime installs and skill updates without prompting.

## Manual install (per agent)

A skill = the folder `skills/<name>/`. Copy (or symlink) that folder into the agent's skills directory. Install **all** skills by copying every folder, or **one** by copying just that folder.

| Agent | Personal/global skills dir | Project-level |
|-------|----------------------------|---------------|
| **Claude Code** | `~/.claude/skills/<name>/` | `.claude/skills/<name>/` |
| **OpenAI Codex** | `~/.agents/skills/<name>/` | `<repo>/.agents/skills/<name>/` |
| **OpenCode** | `~/.config/opencode/skills/<name>/` (also reads `~/.claude/skills/` and `~/.agents/skills/`) | `.opencode/skills/<name>/` |
| **Gemini CLI / Cursor / Cline / Windsurf** | place under their skills dir, or reuse `~/.claude/skills/` or `~/.agents/skills/` | project `.agents/skills/` |
| **Any other agent** | If it supports the `SKILL.md` standard, drop the folder in its skills dir. If not, the bundled Python script still works standalone — call it from the shell (see below). |

> **Tip — one copy, many agents:** `~/.agents/skills/` is read by Codex *and* OpenCode, and Claude Code reads `~/.claude/skills/`. Symlinking a skill into both covers most setups:
> ```bash
> ln -s "$PWD/skills/7pace-time-tracker" ~/.claude/skills/7pace-time-tracker
> ln -s "$PWD/skills/7pace-time-tracker" ~/.agents/skills/7pace-time-tracker
> ```

**Examples (manual copy):**
```bash
# Claude Code — all skills
cp -r skills/* ~/.claude/skills/
# Codex — single skill
cp -r skills/7pace-time-tracker ~/.agents/skills/
```
```powershell
# Claude Code — all skills (PowerShell)
Copy-Item skills/* "$HOME/.claude/skills/" -Recurse
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

Skills that bundle scripts may include tests.

```bash
# Python (7pace-time-tracker)
cd skills/7pace-time-tracker/scripts
python -m unittest test_timetracker -v                 # unit tests, no network
RUN_INTEGRATION=1 python -m unittest test_timetracker -v   # + live API (needs config.json)
```
```powershell
# PowerShell / Pester (win-eventlog-triage)
Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser
Invoke-Pester -Path ./skills/win-eventlog-triage/scripts/Invoke-EventLogTriage.Tests.ps1 -Output Detailed
Invoke-Pester -Path ./skills/nav2009-sql-performance/scripts/Invoke-NavSqlPerfTriage.Tests.ps1 -Output Detailed
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

If a runtime is installed but not yet on `PATH` for the current shell, open a **new**
terminal. (The same file may also declare `pipPackages`, `authCommand`, `authHelp`, and
`configPath` — the location of the skill's credential file, e.g. `~/.7pace/config.json`.)

## Updating installed skills

Each `SKILL.md` carries a `version:` in its frontmatter. On any install run, the
installer compares the **installed** version of every other skill in the target
agent's directory against the **repo** version, and offers to update the ones that
differ (showing `old -> new`). Updates re-copy the skill files while **preserving any
`config.json`** inside the skill folder. Pass `-Yes` (PowerShell) / `--yes` / `-y`
(bash, npx) to apply updates non-interactively; omit it to be prompted.

So after you change a skill, bump its `version:` and re-run the installer — anyone
who already has it installed is offered the update automatically.

## Adding a new skill

1. `mkdir -p skills/<name>/scripts` and add a `SKILL.md` (frontmatter `name`, `version`, `description`, then instructions).
2. Put any code in `scripts/`, reference docs in `REFERENCE.md`, and a `config.example.json` if it needs secrets.
3. If it needs a runtime (Python packages, PowerShell 7, …), declare it in `skill.install.json` (see [Runtime requirements](#runtime-requirements-skillinstalljson)).
4. Add a row to **Available skills** above. Bump `version:` whenever you change the skill so installed copies are offered the update. Commit.

## Sources

- [Agent Skills — the open standard](https://www.agensi.io/learn/agent-skills-open-standard)
- [Codex Agent Skills](https://developers.openai.com/codex/skills)
- [OpenCode Agent Skills](https://opencode.ai/docs/skills/)
- [Agent Skills in the Claude Code SDK](https://code.claude.com/docs/en/agent-sdk/skills)
