#!/usr/bin/env bash
#
# Capture live VS Code + Cursor config (extension list, settings.json,
# keybindings.json) into files/<editor>/ so tasks/editors.yml restores it.
#
#   scripts/capture-editors.sh          # copy live config into files/
#   scripts/capture-editors.sh --check  # exit 1 if files/ drifted; write nothing
#
# Needs the `code` / `cursor` CLIs on PATH; an editor without one is skipped.
# Override the repo root with CAPTURE_EDITORS_REPO (used by the tests).

set -euo pipefail

REPO="${CAPTURE_EDITORS_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
CHECK=0
DRIFT=0

for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# compare_or_write <live-file> <repo-relative-path>
compare_or_write() {
  local live="$1" rel="$2"
  local dest="$REPO/$rel"
  if [ -f "$dest" ] && cmp -s "$live" "$dest"; then
    echo "  ok       $rel"
  elif [ "$CHECK" -eq 1 ]; then
    echo "  DRIFT    $rel"
    DRIFT=1
  else
    mkdir -p "$(dirname "$dest")"
    cp "$live" "$dest"
    echo "  updated  $rel"
  fi
}

# capture_editor <name> <cli> <user-dir>
capture_editor() {
  local name="$1" cli="$2" user_dir="$3"
  local tmp f
  if ! command -v "$cli" >/dev/null 2>&1; then
    echo "$name: '$cli' CLI not found, skipping"
    return 0
  fi
  echo "$name:"
  tmp="$(mktemp)"
  "$cli" --list-extensions | LC_ALL=C sort > "$tmp"
  compare_or_write "$tmp" "files/$name/extensions.txt"
  rm -f "$tmp"
  for f in settings.json keybindings.json; do
    if [ -f "$user_dir/$f" ]; then
      compare_or_write "$user_dir/$f" "files/$name/$f"
    fi
  done
}

capture_editor vscode code "$HOME/Library/Application Support/Code/User"
capture_editor cursor cursor "$HOME/Library/Application Support/Cursor/User"

exit "$DRIFT"
