#!/usr/bin/env bash
# Tests for install.sh. Run with: bash tests/installers/test_install_sh.sh
#
# Hermetic: each test builds a throwaway repo copy (installer + fixture skills) and a
# fake HOME, then runs install.sh with HOME/USERPROFILE overridden — the real
# ~/.claude is never touched. No network, no pip (fixtures ship no .py files).
# Credential-help tests need python on PATH (same dependency as install.sh itself).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check()        { if eval "$2"; then ok "$1"; else fail "$1"; fi; }
out_contains() { if grep -q -- "$2" "$OUT"; then ok "$1"; else fail "$1 (output missing: $2)"; fi; }
out_lacks()    { if grep -q -- "$2" "$OUT"; then fail "$1 (output contains: $2)"; else ok "$1"; fi; }

frontmatter() { printf -- '---\nname: %s\nversion: %s\ndescription: test fixture\n---\n# %s\n' "$1" "$2" "$1"; }

# Build a temp repo + fake home. Sets: TMP, REPO, FAKE_HOME, AGENT_DIR, OUT.
new_fixture() {
  TMP="$(mktemp -d)"
  REPO="$TMP/repo"; FAKE_HOME="$TMP/home"; AGENT_DIR="$FAKE_HOME/.claude/skills"; OUT="$TMP/out.txt"
  mkdir -p "$REPO" "$FAKE_HOME"
  cp "$ROOT/install.sh" "$REPO/"
  local s="$REPO/skills"
  # alpha-skill: ships a fake secret + cache that must never be installed
  mkdir -p "$s/alpha-skill/scripts/__pycache__"
  frontmatter alpha-skill 1.0.0 > "$s/alpha-skill/SKILL.md"
  printf '{"token":"SECRET"}' > "$s/alpha-skill/config.json"
  printf '{"token":""}' > "$s/alpha-skill/config.example.json"
  printf 'x' > "$s/alpha-skill/scripts/__pycache__/junk.bin"
  # beta-skill: plain
  mkdir -p "$s/beta-skill"
  frontmatter beta-skill 2.0.0 > "$s/beta-skill/SKILL.md"
  # cred-skill: authCommand + configPath (install.sh only prints these, never runs them)
  mkdir -p "$s/cred-skill"
  frontmatter cred-skill 1.0.0 > "$s/cred-skill/SKILL.md"
  cat > "$s/cred-skill/skill.install.json" <<'EOF'
{
  "authCommand": "python scripts/auth.py --auth",
  "configPath": "~/.credtest/config.json",
  "authHelp": ["Get your token at https://example.test"]
}
EOF
}

# run_installer <args...> — runs install.sh against the fixture; output in $OUT, rc in $RC.
run_installer() {
  HOME="$FAKE_HOME" USERPROFILE="$FAKE_HOME" bash "$REPO/install.sh" "$@" > "$OUT" 2>&1
  RC=$?
}

echo "install.sh tests"

echo "- installs a single skill into the agent dir"
new_fixture
run_installer --agent claude --skill beta-skill --yes
check "exit code 0" '[ "$RC" -eq 0 ]'
check "beta-skill installed" '[ -f "$AGENT_DIR/beta-skill/SKILL.md" ]'
check "alpha-skill not installed" '[ ! -d "$AGENT_DIR/alpha-skill" ]'

echo "- never installs secrets or caches; keeps config.example.json"
new_fixture
run_installer --agent claude --skill alpha-skill --yes
check "config.json stripped" '[ ! -f "$AGENT_DIR/alpha-skill/config.json" ]'
check "config.example.json kept" '[ -f "$AGENT_DIR/alpha-skill/config.example.json" ]'
check "__pycache__ stripped" '[ ! -d "$AGENT_DIR/alpha-skill/scripts/__pycache__" ]'

echo "- --skill all installs every skill"
new_fixture
run_installer --agent claude --skill all --yes
check "exit code 0" '[ "$RC" -eq 0 ]'
for s in alpha-skill beta-skill cred-skill; do
  check "$s installed" "[ -f \"$AGENT_DIR/$s/SKILL.md\" ]"
done

echo "- fails on unknown skill / missing agent"
new_fixture
run_installer --agent claude --skill nope --yes
check "unknown skill exits non-zero" '[ "$RC" -ne 0 ]'
run_installer --skill all --yes
check "missing agent exits non-zero" '[ "$RC" -ne 0 ]'

echo "- updates an outdated installed skill, preserving its config.json"
new_fixture
mkdir -p "$AGENT_DIR/alpha-skill"
frontmatter alpha-skill 0.9.0 > "$AGENT_DIR/alpha-skill/SKILL.md"
printf '{"keep":"me"}' > "$AGENT_DIR/alpha-skill/config.json"
run_installer --agent claude --skill beta-skill --yes
out_contains "update offered/applied" "alpha-skill: 0.9.0 -> 1.0.0"
check "SKILL.md updated to 1.0.0" 'grep -q "version: 1.0.0" "$AGENT_DIR/alpha-skill/SKILL.md"'
check "config.json preserved" '[ "$(cat "$AGENT_DIR/alpha-skill/config.json")" = "{\"keep\":\"me\"}" ]'

if HOME="$FAKE_HOME" bash -c 'command -v python || command -v python3 || command -v py' >/dev/null 2>&1; then
  echo "- unconfigured: prints credential setup help"
  new_fixture
  run_installer --agent claude --skill cred-skill --yes
  out_contains "setup help shown" "Credential setup for cred-skill"
  out_contains "token help shown" "example.test"

  echo "- configured: prints 'already configured' instead of token instructions"
  new_fixture
  mkdir -p "$FAKE_HOME/.credtest"
  printf '{"token":"old"}' > "$FAKE_HOME/.credtest/config.json"
  run_installer --agent claude --skill cred-skill --yes
  out_contains "already-configured notice" "already configured"
  out_lacks "no token help dumped" "example.test"
  check "existing config untouched" '[ "$(cat "$FAKE_HOME/.credtest/config.json")" = "{\"token\":\"old\"}" ]'
else
  echo "- SKIPPED credential-help tests (python not on PATH)"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
