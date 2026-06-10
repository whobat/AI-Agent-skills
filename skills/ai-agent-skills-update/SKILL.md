---
name: ai-agent-skills-update
version: 1.0.0
description: Update skills installed FROM THE AI-Agent-skills GitHub REPO (github.com/whobat/AI-Agent-skills) to their latest published versions — it does not touch skills from any other source (plugins, other repos, hand-written skills). Runs the repo installer in update mode across Claude Code, Codex, and OpenCode, installs nothing new, and preserves local config.json files. Use when the user says "update my AI-Agent-skills", "update my skills from the repo", "opdater skills", "are my skills up to date?", or after being told a skill from this repo has a new version.
---

# AI-Agent-skills Update

Updates every skill **originating from the [AI-Agent-skills repo](https://github.com/whobat/AI-Agent-skills)**
that is installed on this machine to the latest published version. Skills from other sources
(plugins, other repos, hand-written skills) are never touched — the installer only considers
folders whose name matches a skill in this repo. Installs **nothing new** — only refreshes
what is already there. A `config.json` inside a skill folder is preserved.

## How to run

**Primary (no clone needed — fetches the latest repo automatically):**

```bash
npx -y github:whobat/AI-Agent-skills --update --agent all --yes
```

- `--agent all` covers Claude Code (`~/.claude/skills`), Codex (`~/.agents/skills`) and
  OpenCode (`~/.config/opencode/skills`) in one run. Use `--agent claude` etc. to limit it.
- Drop `--yes` if the user wants to confirm the update list first (the installer then shows
  `name: old -> new` and asks).
- Requires **Node.js 18+**.

**Fallback (no Node):** from a local clone of the repo (run `git pull` first — the comparison
is against the clone):

```powershell
./install.ps1 -Agent all -Update -Yes        # Windows
```
```bash
./install.sh --agent all --update --yes      # macOS / Linux / Git-Bash
```

## What you (the agent) do with the result

1. Parse the output: each agent section lists either `updated <skill> -> <version>` lines or
   `all installed skills are up to date.`
2. **Report per agent**: which skills were updated (`old -> new`) and which were already
   current. If a runtime warning appears (e.g. a missing prerequisite for an updated skill),
   relay it.
3. If an expected update does not show up, the npm cache may be serving a stale copy of the
   repo — run `npm cache clean --force` and retry once.
4. Skills updated in the **current** agent are not reloaded mid-session — mention that new
   skill versions take effect in the next session.
