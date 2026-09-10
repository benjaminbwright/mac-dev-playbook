#!/usr/bin/env bash
# Capture dotfiles from $HOME into the PRIVATE dotfiles clone (issue #8).
#
# The playbook symlinks files from the dotfiles clone into ~; this is the
# reverse direction, used on the OLD Mac to get new files into the repo. It
# copies each file to the same relative path inside the clone (nested paths
# like .ssh/config are preserved) and never touches ~ itself. Files whose
# contents look like credentials are skipped with a warning -- those belong in
# the secrets repo, not the dotfiles repo. It does NOT commit; review + commit
# in the clone afterwards (see NEW-MAC.md, "Dotfiles & shell config").
#
# Usage:
#   scripts/capture-dotfiles.sh [--dest DIR] [--config FILE] [--list] [FILE...]
#
#   --dest DIR     dotfiles clone to copy into
#                  (default: $DOTFILES_DEST or ~/Development/GitHub/dotfiles)
#   --config FILE  playbook config to read the file list from
#                  (default: default.config.yml next to this script's repo)
#   --list         print the file list and exit
#   FILE...        capture only these paths (relative to ~) instead of the list
#
# With no FILE arguments the list is `dotfiles_files` + `dotfiles_nested_files`
# from the config, so the script and the playbook can't drift apart.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="${DOTFILES_DEST:-$HOME/Development/GitHub/dotfiles}"
config="$script_dir/../default.config.yml"
list_only=false
files=()

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) dest="$2"; shift 2 ;;
    --config) config="$2"; shift 2 ;;
    --list) list_only=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) files+=("$1"); shift ;;
  esac
done

# Pull the plain "  - path" entries out of the two list variables in the
# playbook config. Only those two top-level keys are read; comments and blank
# lines inside the lists are ignored; any other top-level key ends the list.
config_files() {
  awk '
    /^(dotfiles_files|dotfiles_nested_files):[[:space:]]*$/ { in_list = 1; next }
    in_list && /^[[:space:]]+-[[:space:]]+/ { sub(/^[[:space:]]+-[[:space:]]+/, ""); sub(/[[:space:]]+(#.*)?$/, ""); print; next }
    in_list && /^[[:space:]]*(#|$)/ { next }
    { in_list = 0 }
  ' "$config"
}

if [ ${#files[@]} -eq 0 ]; then
  [ -r "$config" ] || { echo "config not found: $config" >&2; exit 2; }
  while IFS= read -r line; do files+=("$line"); done < <(config_files)
fi

if [ "$list_only" = true ]; then
  printf '%s\n' "${files[@]}"
  exit 0
fi

# Lines that look like credentials: a secret-ish key being ASSIGNED a value
# (key: v / key = v / "key": "v"), .netrc-style `password x`, PEM headers, and
# well-known token prefixes. A bare mention of the word (a comment) doesn't
# count. Still err on the side of warning: a false positive just means you copy
# the file by hand after checking it; a false negative leaks.
secret_keys='(password|passwd|secret|token|cookie|api[_-]?key|access[_-]?key|private[_-]?key)'
secret_pattern="${secret_keys}[A-Za-z0-9_-]*[[:punct:]]?[[:space:]]*[:=][[:space:]]*[[:punct:]]?[^[:space:]]{4,}"
secret_pattern+="|(^|[[:space:]])password[[:space:]]+[^[:space:]]+"
secret_pattern+="|BEGIN [A-Z ]*PRIVATE KEY"
secret_pattern+="|bearer [A-Za-z0-9._-]{16,}|sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|xox[abp]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}"

looks_secret() {
  grep -qiE "$secret_pattern" "$1"
}

for f in "${files[@]}"; do
  src="$HOME/$f"
  target="$dest/$f"
  if [ ! -f "$src" ]; then
    echo "missing    $f (not on this machine; skipped)"
    continue
  fi
  # Already linked into the clone by the playbook: nothing to capture.
  if [ -L "$src" ] && [ "$src" -ef "$target" ]; then
    echo "linked     $f (already a symlink into the clone)"
    continue
  fi
  if looks_secret "$src"; then
    echo "WARN  $f: matches a secret pattern; NOT copied (keep it in the secrets repo)" >&2
    continue
  fi
  if [ -f "$target" ] && cmp -s "$src" "$target"; then
    echo "unchanged  $f"
    continue
  fi
  mkdir -p "$(dirname "$target")"
  cp "$src" "$target"
  echo "copied     $f"
done
