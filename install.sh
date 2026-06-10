#!/usr/bin/env bash
# Install Agent Skills into a coding agent's skills directory.
#
# Usage:
#   ./install.sh --agent claude   --skill all
#   ./install.sh --agent codex    --skill 7pace-time-tracker
#   ./install.sh --agent opencode --skill all --symlink
set -euo pipefail

AGENT=""; SKILL="all"; SYMLINK=0; YES=0; UPDATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)   AGENT="${2:-}"; shift 2 ;;
    --skill)   SKILL="${2:-}"; shift 2 ;;
    --update)  UPDATE=1; shift ;;
    --symlink) SYMLINK=1; shift ;;
    -y|--yes)  YES=1; shift ;;
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

# Install a skill's Python dependencies (from its skill.install.json pipPackages).
# Uses the resolved python ($2) to parse JSON and run pip; no-op if python is unavailable.
pip_install_for_skill() {
  local manifest="$1" py="$2" pkgs
  [ -f "$manifest" ] || return 0
  [ -n "$py" ] || return 0
  pkgs="$("$py" - "$manifest" <<'PYEOF'
import json, sys
try:
    m = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
print(" ".join(m.get("pipPackages") or []))
PYEOF
)"
  [ -n "$pkgs" ] || return 0
  echo "  installing Python packages: $pkgs"
  # shellcheck disable=SC2086
  "$py" -m pip install --disable-pip-version-check $pkgs \
    || echo "  ! pip install failed. Run manually: $py -m pip install $pkgs" >&2
}

# Print where to obtain a skill's credentials (from its skill.install.json authHelp).
# If the skill's config file (configPath) already exists, say so instead of token instructions.
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
name = os.path.basename(os.path.dirname(sys.argv[1]))
cfg = m.get("configPath")
if cfg and os.path.exists(os.path.expanduser(cfg)):
    print()
    print("Credentials for %s: already configured (%s). Run '%s' to update tokens."
          % (name, os.path.expanduser(cfg), ac))
    sys.exit(0)
print()
print("Credential setup for %s:" % name)
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

# Echo the 'version:' value from a skill's SKILL.md frontmatter (empty if absent).
skill_version() {
  local md="$1/SKILL.md"
  [ -f "$md" ] || return 0
  awk '
    /^---[[:space:]]*$/ { if (inf) exit; inf=1; next }
    inf && /^[[:space:]]*version:[[:space:]]*/ {
      sub(/^[[:space:]]*version:[[:space:]]*/, ""); gsub(/[[:space:]]+$/, ""); print; exit
    }' "$md"
}

# Ensure runtime requirements declared in a skill.install.json. Needs python to read the manifest.
ensure_requirements() {
  local manifest="$1" py
  [ -f "$manifest" ] || return 0
  py="$(python_cmd || true)"
  if [ -z "$py" ]; then
    echo "  (skipping requirement check for $(basename "$(dirname "$manifest")") — no python to read manifest)" >&2
    return 0
  fi
  # Fields are joined with ASCII Unit Separator (\x1f): tab/space are "IFS whitespace"
  # in POSIX read, so empty fields would collapse and shift the columns.
  "$py" - "$manifest" <<'PYEOF' | while IFS=$'\x1f' read -r name detect minv brew url paths warnonly help; do
import json, sys
try:
    m = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
for r in (m.get("requirements") or []):
    print("\x1f".join([str(r.get("name","")), str(r.get("detect","")),
                       str(r.get("minVersion","")), str(r.get("brewCask","")), str(r.get("url","")),
                       "|".join(r.get("detectPaths") or []),
                       "1" if r.get("warnOnly") else "0",
                       str(r.get("help",""))]))
PYEOF
    [ -n "$detect" ] || [ -n "$paths" ] || continue
    # Present if the command is on PATH or any declared file path exists.
    found=0
    if [ -n "$detect" ] && command_exists "$detect"; then found=1; fi
    if [ "$found" -eq 0 ] && [ -n "$paths" ]; then
      IFS='|' read -ra path_list <<< "$paths"
      for p in "${path_list[@]}"; do
        [ -f "$p" ] && { found=1; break; }
      done
    fi
    if [ "$found" -eq 1 ]; then echo "  requirement OK: $name"; continue; fi
    # warnOnly requirements (e.g. NAV 2009 finsql.exe) cannot be auto-installed — warn and continue.
    if [ "$warnonly" = "1" ]; then
      echo "  ! WARNING: $name not found." >&2
      [ -n "$paths" ] && echo "    checked: ${paths//|/; }" >&2
      [ -n "$help" ] && echo "    $help" >&2
      [ -n "$url" ] && echo "    $url" >&2
      continue
    fi
    echo "  requirement missing: $name"
    if [ "$(uname)" = "Darwin" ] && command_exists brew && [ -n "$brew" ]; then
      echo "  installing via: brew install --cask $brew"
      brew install --cask "$brew" || echo "  ! brew install failed. Install manually: $url" >&2
    else
      echo "  ! Cannot auto-install $name on this platform. Install manually: $url" >&2
    fi
    if command_exists "$detect"; then echo "  $name ready"; else echo "  $name not on PATH; open a NEW terminal. ($url)"; fi
  done
}

# Offer to update already-installed skills (from this repo) whose version differs from the repo.
# Sets UPD_CANDIDATES to the number of update candidates found (0 = everything current).
update_outdated() {
  local dest="$1" src="$2"; shift 2
  local chosen=" $* "
  local d name instv repov i ans
  local cand_name=() cand_from=() cand_to=()
  UPD_CANDIDATES=0
  for d in "$dest"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    case "$chosen" in *" $name "*) continue ;; esac
    [ -d "$src/$name" ] || continue
    instv="$(skill_version "$dest/$name")"
    repov="$(skill_version "$src/$name")"
    [ -n "$repov" ] || continue
    if [ "$instv" != "$repov" ]; then
      cand_name+=("$name"); cand_from+=("${instv:-unknown}"); cand_to+=("$repov")
    fi
  done
  [ "${#cand_name[@]}" -gt 0 ] || return 0
  UPD_CANDIDATES="${#cand_name[@]}"
  echo
  echo "Updates available for already-installed skills:"
  for i in "${!cand_name[@]}"; do echo "  ${cand_name[$i]}: ${cand_from[$i]} -> ${cand_to[$i]}"; done
  if [ "$YES" -ne 1 ]; then
    if [ -t 0 ]; then
      printf 'Update these now? [Y/n] '; read -r ans || true
      case "$(echo "${ans:-}" | tr '[:upper:]' '[:lower:]')" in n|no|nej) return 0 ;; esac
    else
      echo "  (non-interactive; re-run with --yes to apply these updates)"; return 0
    fi
  fi
  for i in "${!cand_name[@]}"; do
    name="${cand_name[$i]}"
    local tp="$dest/$name" keep=""
    [ -f "$tp/config.json" ] && keep="$(cat "$tp/config.json")"
    rm -rf "$tp"; cp -r "$src/$name" "$tp"
    find "$tp" -name 'config.json' -type f -delete
    find "$tp" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
    [ -n "$keep" ] && printf '%s' "$keep" > "$tp/config.json"
    echo "  updated $name -> ${cand_to[$i]}"
    ensure_requirements "$tp/skill.install.json"
  done
}

agent_dest() {
  case "$1" in
    claude)   echo "$HOME/.claude/skills" ;;
    codex)    echo "$HOME/.agents/skills" ;;
    opencode) echo "$HOME/.config/opencode/skills" ;;
  esac
}

# --agent all installs into every supported agent's skills dir
case "$AGENT" in
  all)                     AGENTS=(claude codex opencode) ;;
  claude|codex|opencode)   AGENTS=("$AGENT") ;;
  *) echo "Angiv --agent claude|codex|opencode|all" >&2; exit 1 ;;
esac

# --update: refresh installed skills to the repo versions; install nothing new
if [ "$UPDATE" -eq 1 ]; then
  for a in "${AGENTS[@]}"; do
    echo
    echo "Checking for skill updates in $a ($(agent_dest "$a"))"
    update_outdated "$(agent_dest "$a")" "$SRC"
    [ "${UPD_CANDIDATES:-0}" -eq 0 ] && echo "  all installed skills are up to date."
  done
  echo
  echo "Done."
  exit 0
fi

if [ "$SKILL" = "all" ]; then
  mapfile -t FOLDERS < <(find "$SRC" -mindepth 1 -maxdepth 1 -type d)
else
  [ -d "$SRC/$SKILL" ] || { echo "Skill '$SKILL' findes ikke i $SRC" >&2; exit 1; }
  FOLDERS=("$SRC/$SKILL")
fi

for a in "${AGENTS[@]}"; do
DEST="$(agent_dest "$a")"
mkdir -p "$DEST"
echo
echo "Installing into $a ($DEST)"

for f in "${FOLDERS[@]}"; do
  name="$(basename "$f")"
  target="$DEST/$name"
  # Show installed -> latest on the install line
  instv="$(skill_version "$target")"
  repov="$(skill_version "$f")"
  note=""
  if [ -n "$repov" ]; then
    if [ -n "$instv" ] && [ "$instv" != "$repov" ]; then note=" ($instv -> $repov)"
    elif [ -n "$instv" ]; then note=" ($repov, reinstalled)"
    else note=" (new, $repov)"
    fi
  fi
  rm -rf "$target"
  if [ "$SYMLINK" -eq 1 ]; then
    ln -s "$f" "$target"
    echo "  linked $name -> $target$note"
  else
    cp -r "$f" "$target"
    find "$target" -name 'config.json' -type f -delete
    find "$target" -name '__pycache__' -type d -prune -exec rm -rf {} +
    echo "  installed $name -> $target$note"
  fi
done
done

# Machine-level steps below run once per skill — the manifests are identical across agents,
# so use each skill's copy under the first agent's dir.
DEST="$(agent_dest "${AGENTS[0]}")"

# Ensure each installed skill's declared runtime requirements (e.g. PowerShell 7) are present
for f in "${FOLDERS[@]}"; do
  ensure_requirements "$DEST/$(basename "$f")/skill.install.json"
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

[ -n "$PY" ] || PY="$(python_cmd || true)"   # for parsing manifests / pip, even if no install was needed

# Install each installed skill's Python dependencies
for f in "${FOLDERS[@]}"; do
  pip_install_for_skill "$DEST/$(basename "$f")/skill.install.json" "$PY"
done

# Show where to get credentials for any installed skill that needs them
for f in "${FOLDERS[@]}"; do
  print_auth_help "$DEST/$(basename "$f")/skill.install.json" "$PY"
done

# Offer to update other already-installed skills whose repo version changed
CHOSEN_NAMES=()
for f in "${FOLDERS[@]}"; do CHOSEN_NAMES+=("$(basename "$f")"); done
for a in "${AGENTS[@]}"; do
  update_outdated "$(agent_dest "$a")" "$SRC" "${CHOSEN_NAMES[@]}"
done

echo
for a in "${AGENTS[@]}"; do echo "Done. $a skills dir: $(agent_dest "$a")"; done
echo "Reminder: skills needing secrets ship config.example.json — copy to config.json and add your tokens."
