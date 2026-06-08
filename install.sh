#!/usr/bin/env bash
# Install Agent Skills into a coding agent's skills directory.
#
# Usage:
#   ./install.sh --agent claude   --skill all
#   ./install.sh --agent codex    --skill tidsregistrering
#   ./install.sh --agent opencode --skill all --symlink
set -euo pipefail

AGENT=""; SKILL="all"; SYMLINK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)   AGENT="${2:-}"; shift 2 ;;
    --skill)   SKILL="${2:-}"; shift 2 ;;
    --symlink) SYMLINK=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Ukendt argument: $1" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/skills"

command_exists() { command -v "$1" >/dev/null 2>&1; }

python_cmd() {
  for c in python3 python py; do
    if command_exists "$c" && "$c" --version >/dev/null 2>&1; then echo "$c"; return 0; fi
  done
  return 1
}

install_python() {
  if command_exists brew; then
    echo "  installing Python via: brew install python" >&2
    brew install python
  elif command_exists apt-get; then
    echo "  installing Python via: sudo apt-get install -y python3" >&2
    sudo apt-get install -y python3
  elif command_exists dnf; then
    echo "  installing Python via: sudo dnf install -y python3" >&2
    sudo dnf install -y python3
  else
    echo "  ! Could not auto-install Python (no brew/apt-get/dnf). Install manually: https://www.python.org/downloads/" >&2
    return 1
  fi
}

# Print where to obtain a skill's credentials (from its skill.install.json authHelp).
# Uses the resolved python ($2) to parse JSON; no-op if python is unavailable.
print_auth_help() {
  local manifest="$1" py="$2"
  [ -f "$manifest" ] || return 0
  [ -n "$py" ] || return 0
  "$py" - "$manifest" <<'PYEOF'
import json, os, sys
try:
    m = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
ac = m.get("authCommand")
help_lines = m.get("authHelp") or []
if not (ac or help_lines):
    sys.exit(0)
print()
print("Credential setup for %s:" % os.path.basename(os.path.dirname(sys.argv[1])))
if ac:
    print("  run: %s" % ac)
for line in help_lines:
    print("  %s" % line)
PYEOF
}

# Echoes a working python command, installing it first if missing. Non-zero exit if unavailable.
ensure_python() {
  local py
  if py="$(python_cmd)"; then echo "$py"; return 0; fi
  echo "  Python not found on PATH." >&2
  install_python || return 1
  if py="$(python_cmd)"; then echo "  Python ready: $py" >&2; echo "$py"; return 0; fi
  echo "  Python installed, but not on PATH for this session. Open a NEW terminal to use it." >&2
  return 1
}

case "$AGENT" in
  claude)   DEST="$HOME/.claude/skills" ;;
  codex)    DEST="$HOME/.agents/skills" ;;
  opencode) DEST="$HOME/.config/opencode/skills" ;;
  *) echo "Angiv --agent claude|codex|opencode" >&2; exit 1 ;;
esac
mkdir -p "$DEST"

if [ "$SKILL" = "all" ]; then
  mapfile -t FOLDERS < <(find "$SRC" -mindepth 1 -maxdepth 1 -type d)
else
  [ -d "$SRC/$SKILL" ] || { echo "Skill '$SKILL' findes ikke i $SRC" >&2; exit 1; }
  FOLDERS=("$SRC/$SKILL")
fi

for f in "${FOLDERS[@]}"; do
  name="$(basename "$f")"
  target="$DEST/$name"
  rm -rf "$target"
  if [ "$SYMLINK" -eq 1 ]; then
    ln -s "$f" "$target"
    echo "  linked $name -> $target"
  else
    cp -r "$f" "$target"
    find "$target" -name 'config.json' -type f -delete
    find "$target" -name '__pycache__' -type d -prune -exec rm -rf {} +
    echo "  installed $name -> $target"
  fi
done

# Ensure Python is present if any installed skill ships .py scripts
needs_python=0
for f in "${FOLDERS[@]}"; do
  if find "$f" -name '*.py' -type f -print -quit | grep -q .; then needs_python=1; break; fi
done
PY=""
if [ "$needs_python" -eq 1 ]; then
  echo
  echo "Checking Python (required by an installed skill)..."
  PY="$(ensure_python || true)"
fi

# Show where to get credentials for any installed skill that needs them
[ -n "$PY" ] || PY="$(python_cmd || true)"   # for parsing manifests, even if no install was needed
for f in "${FOLDERS[@]}"; do
  print_auth_help "$DEST/$(basename "$f")/skill.install.json" "$PY"
done

echo
echo "Done. $AGENT skills dir: $DEST"
echo "Reminder: skills needing secrets ship config.example.json — copy to config.json and add your tokens."
