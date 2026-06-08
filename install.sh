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

echo
echo "Done. $AGENT skills dir: $DEST"
echo "Reminder: skills needing secrets ship config.example.json — copy to config.json and add your tokens."
