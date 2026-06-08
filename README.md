# AI-Agent-Skills

A shared collection of **Agent Skills** — portable `SKILL.md`-based capabilities that work across multiple coding agents (Claude Code, OpenAI Codex, OpenCode, Gemini CLI, Cursor, and more).

A *skill* is just a folder containing a `SKILL.md` (YAML frontmatter `name` + `description`, then Markdown instructions) plus optional `scripts/` and `references/`. The format is an [open standard](https://www.agensi.io/learn/agent-skills-open-standard), so the same folder installs into any supporting agent.

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
    └── tidsregistrering/       # one folder per skill
        ├── SKILL.md            # the skill manifest + instructions
        ├── REFERENCE.md        # detailed reference (optional)
        ├── skill.install.json  # optional: declares the credential-setup command
        ├── config.example.json # template — copy to config.json (gitignored)
        └── scripts/
            ├── tidsregistrering.py
            └── test_tidsregistrering.py
```

## Available skills

| Skill | What it does | Extra setup |
|-------|--------------|-------------|
| **tidsregistrering** | Create/edit/delete time entries in 7pace Timetracker (Azure DevOps) via REST API, plus free-text work-item search. | Python 3.8+, `pip install requests`, and a `config.json` (see [skill README note](#configuration--secrets)). |

## Install with `npx` (recommended)

No clone needed — run it straight from GitHub:

```bash
# Interactive (pick agent + skill, optional credential setup)
npx github:whobat/AI-Agent-skills

# Non-interactive
npx github:whobat/AI-Agent-skills --agent claude --skill all
npx github:whobat/AI-Agent-skills --agent codex  --skill tidsregistrering --auth
```

Flags: `--agent claude|codex|opencode` · `--skill all|<name>` · `--auth` (run a skill's credential setup after install) · `--symlink` · `--list` · `-y/--yes` · `-h`.

The installer copies skill folders into the agent's skills dir and **never copies real `config.json`** (only `config.example.json`). With `--auth` (or when prompted), it runs the skill's credential setup so your tokens are entered securely and saved locally — see [Configuration & secrets](#configuration--secrets).

## Install with the bundled scripts (no Node)

If you've cloned the repo and prefer not to use Node:

**Windows (PowerShell):**
```powershell
./install.ps1 -Agent claude -Skill all
./install.ps1 -Agent codex -Skill tidsregistrering
```

**macOS / Linux / Git-Bash:**
```bash
./install.sh --agent claude --skill all
./install.sh --agent codex --skill tidsregistrering
```

`-Agent`/`--agent`: `claude` · `codex` · `opencode`.  `-Skill`/`--skill`: `all` or a skill folder name. Add `-Symlink`/`--symlink` to link instead of copy.

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

**Easiest — guided setup (recommended):** the installer's `--auth` runs it for you, or run it directly:
```bash
python skills/tidsregistrering/scripts/tidsregistrering.py --auth
```
It prompts (tokens hidden) and writes `~/.7pace/config.json` (chmod 600). For `tidsregistrering` that's the 7pace **Bearer token** (worklog CRUD) and an optional Azure DevOps **PAT** (work-item search) — two separate systems, both kept out of git.

**Manual alternative:**
```bash
cp skills/tidsregistrering/config.example.json ~/.7pace/config.json   # then edit with your tokens
```
The script reads `~/.7pace/config.json` by default; override with `--config <path>`.

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
