# AI-Agent-Skills

A shared collection of **Agent Skills** — portable `SKILL.md`-based capabilities that work across multiple coding agents (Claude Code, OpenAI Codex, OpenCode, Gemini CLI, Cursor, and more).

A *skill* is just a folder containing a `SKILL.md` (YAML frontmatter `name` + `description`, then Markdown instructions) plus optional `scripts/` and `references/`. The format is an [open standard](https://www.agensi.io/learn/agent-skills-open-standard), so the same folder installs into any supporting agent.

## Repository layout

```
AI-Agent-skills/
├── README.md
├── .gitignore                 # ignores real config.json / secrets
├── install.ps1                # installer (Windows PowerShell)
├── install.sh                 # installer (macOS/Linux/Git-Bash)
└── skills/
    └── tidsregistrering/       # one folder per skill
        ├── SKILL.md            # the skill manifest + instructions
        ├── REFERENCE.md        # detailed reference (optional)
        ├── config.example.json # template — copy to config.json (gitignored)
        └── scripts/
            ├── tidsregistrering.py
            └── test_tidsregistrering.py
```

## Available skills

| Skill | What it does | Extra setup |
|-------|--------------|-------------|
| **tidsregistrering** | Create/edit/delete time entries in 7pace Timetracker (Azure DevOps) via REST API, plus free-text work-item search. | Python 3.8+, `pip install requests`, and a `config.json` (see [skill README note](#configuration--secrets)). |

## Quick install (recommended)

Use the installer to copy skills into an agent's skills directory. It copies the folders and **never copies real `config.json`** (only `config.example.json`).

**Windows (PowerShell):**
```powershell
# All skills into Claude Code
./install.ps1 -Agent claude -Skill all
# A single skill into Codex
./install.ps1 -Agent codex -Skill tidsregistrering
```

**macOS / Linux / Git-Bash:**
```bash
./install.sh --agent claude --skill all
./install.sh --agent codex --skill tidsregistrering
```

`-Agent`/`--agent`: `claude` · `codex` · `opencode`.  `-Skill`/`--skill`: `all` or a skill folder name.

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
> ln -s "$PWD/skills/tidsregistrering" ~/.claude/skills/tidsregistrering
> ln -s "$PWD/skills/tidsregistrering" ~/.agents/skills/tidsregistrering
> ```

**Examples (manual copy):**
```bash
# Claude Code — all skills
cp -r skills/* ~/.claude/skills/
# Codex — single skill
cp -r skills/tidsregistrering ~/.agents/skills/
```
```powershell
# Claude Code — all skills (PowerShell)
Copy-Item skills/* "$HOME/.claude/skills/" -Recurse
```

### "Pi" / other agents

There is no single standard for every agent. Two fallbacks that always work:
1. **SKILL.md as instructions** — paste the `SKILL.md` body into the agent's rules/instructions file (e.g. `AGENTS.md`, a system prompt, or a custom command).
2. **Script is agent-agnostic** — `skills/tidsregistrering/scripts/tidsregistrering.py` is a plain Python CLI. Any agent (or you) can run it directly; see its `--help`.

## Configuration & secrets

Skills that need credentials ship a `config.example.json`. **Never commit real tokens** — `.gitignore` already excludes `config.json` (and `.env`, etc.).

```bash
cd skills/tidsregistrering
cp config.example.json config.json   # then edit config.json with your tokens
```

Point the script at it explicitly with `--config <path>` (or place it where the skill expects). For `tidsregistrering`, the config holds the 7pace Bearer token (worklog CRUD) and an Azure DevOps PAT (work-item search) — both kept out of git.

## Verifying a skill (tests)

Skills that bundle scripts may include tests.

```bash
cd skills/tidsregistrering/scripts
python -m unittest test_tidsregistrering -v                 # unit tests, no network
RUN_INTEGRATION=1 python -m unittest test_tidsregistrering -v   # + live API (needs config.json)
```

## Adding a new skill

1. `mkdir -p skills/<name>/scripts` and add a `SKILL.md` (frontmatter `name` + `description`, then instructions).
2. Put any code in `scripts/`, reference docs in `REFERENCE.md`, and a `config.example.json` if it needs secrets.
3. Add a row to **Available skills** above. Commit.

## Sources

- [Agent Skills — the open standard](https://www.agensi.io/learn/agent-skills-open-standard)
- [Codex Agent Skills](https://developers.openai.com/codex/skills)
- [OpenCode Agent Skills](https://opencode.ai/docs/skills/)
- [Agent Skills in the Claude Code SDK](https://code.claude.com/docs/en/agent-sdk/skills)
