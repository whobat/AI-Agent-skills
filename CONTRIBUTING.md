# Contributing

Thanks for considering a contribution! This repo follows the
[Agent Skills specification](https://agentskills.io/specification) strictly — CI
rejects anything that doesn't.

## Adding a skill

1. Copy `template/skill-name/` to `skills/<category>/<your-skill-name>/` and fill it in.
   The skill's own folder name must equal the frontmatter `name` (the category folder above
   it is just for overview). Pick an existing category (`nav-2009`, `ax-retail`, `sql-server`,
   `windows-ops`, `documents`, `time-tracking`, `repo-tooling`) or add a new one — if new,
   add `"./skills/<category>"` to `.claude-plugin/plugin.json`'s `skills` array (the validator
   fails otherwise). Skill `name`s must be globally unique across all categories.
2. Frontmatter rules (enforced by `npm run validate`):
   - Only spec-defined fields: `name`, `description`, `license`, `compatibility`,
     `metadata`, `allowed-tools`. **No custom top-level fields.**
   - `license: MIT` (this repo's license).
   - `metadata.version: "x.y.z"` — the installers' update detection keys on it.
     **Bump it on every behavior change**, or installed copies never get the update.
   - `description` ≤ 1024 chars, third person, includes *when to use* triggers
     (and a negative trigger if a sibling skill could be confused).
   - `compatibility` (≤ 500 chars) only when the skill has real environment needs.
3. Keep `SKILL.md` under 500 lines; put detail in `REFERENCE.md` (or `references/`),
   linked **one level deep** from SKILL.md. Scripts go in `scripts/` with tests next
   to them (`*.Tests.ps1` for Pester, `test_*.py` for Python).
3b. **Add a `## Gotchas` section** (in `REFERENCE.md`, or `SKILL.md` for knowledge-only
   skills) — `npm run validate` requires it. Document the *real* domain pitfalls:
   measurement traps, errors that mislead about the cause, environment foot-guns, and
   known misattributions. Each entry: **trap → mechanism → correct check/fix**. Keep it
   honest and specific; don't pad to pass the check.
4. If the skill needs runtimes or credentials, declare them in `skill.install.json`
   (see [README — Runtime requirements](README.md#runtime-requirements-skillinstalljson)).
5. Add 3+ evaluation scenarios in `evals/<skill-name>.json` (see existing files for
   the format — `query` + `expected_behavior`).
6. Update the README **Available skills** and per-skill requirements tables.

## Hard rules

- **No company-specific data — ever.** No real company/customer names, domains,
  server/database names, ADO org/project names, real work-item IDs, or personal
  paths. Use placeholders (`Acme`, `MyProject`, `SRV01`, work item `12345`).
  Tenant-specific test inputs come from env vars/config and **skip when unset.**
- **Never commit secrets.** Only `config.example.json` is tracked.
- **Installer parity.** A behavior change in one of `bin/cli.js`, `install.ps1`,
  `install.sh` requires the equivalent change in the other two **and** their test
  suites in `tests/installers/`.

Full contracts live in [AGENTS.md](AGENTS.md) and [skills/AGENTS.md](skills/AGENTS.md).

## Running the checks locally

```bash
npm test                                          # spec validation + npx installer suite
bash tests/installers/test_install_sh.sh          # install.sh suite (bash 4+)
```
```powershell
Invoke-Pester -Path ./tests/installers/Install.Tests.ps1, ./skills/*/scripts/*.Tests.ps1
cd skills/7pace-time-tracker/scripts; python -m unittest test_timetracker -v
```

CI (GitHub Actions) runs all of the above on Windows and Linux for every PR.
