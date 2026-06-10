# tests/

## Purpose

Installer test suites — one per installer, kept in lockstep with [installer parity](../AGENTS.md#project-contract). When you change installer behavior, update the matching suite(s) here.

## Ownership

`tests/installers/` — three parallel suites covering `install.ps1`, `bin/cli.js`, and `install.sh`:

| Suite | Covers | Run |
|-------|--------|-----|
| `Install.Tests.ps1` | `install.ps1` | `Invoke-Pester -Path ./tests/installers/Install.Tests.ps1 -Output Detailed` |
| `cli.test.mjs` | `bin/cli.js` (npx) | `npm test` (Node 18+) |
| `test_install_sh.sh` | `install.sh` | `bash tests/installers/test_install_sh.sh` (bash 4+) |

## Local Contracts

- **Hermetic, always.** Each test builds a throwaway repo copy + a fake HOME and runs the installer with `USERPROFILE`/`HOME` overridden, so the real `~/.claude` is never touched. No network, no `winget`/`pip` (fixtures declare no requirements and ship no `.py`). Keep new tests hermetic.
- **Coverage to preserve across all three suites:** install / `all`, secret stripping (`config.json`, `__pycache__`), version updates (incl. preserving an installed `config.json`), error exits, and credential detection (configured → update-or-keep).

## Child DOX Index

No children.
