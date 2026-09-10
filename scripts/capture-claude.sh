#!/usr/bin/env bash
# Capture the live Claude Code config on THIS Mac into the private dotfiles clone,
# so the playbook can restore it on a new machine (tasks/claude.yml).
#
# Usage: scripts/capture-claude.sh [<dotfiles-dir>]   (default: ~/Development/GitHub/dotfiles)
#
# Idempotent and non-destructive: it only copies/overwrites the snapshot files it
# owns and never deletes anything. Review with `git -C <dotfiles-dir> status`, then
# commit and push there yourself.
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [<dotfiles-dir>]

Copies the live Claude Code / skills / Pi config into the private dotfiles clone
(default: ~/Development/GitHub/dotfiles). Nothing is committed; review with git
and push yourself. Never deletes; never captures ~/.claude.json (tokens).

Captured:
  ~/.claude/settings.json, settings.local.json, config.json  -> <dotfiles>/claude/
  ~/.agents/.skill-lock.json                                  -> <dotfiles>/claude/skill-lock.json
  hand-made skills in ~/.claude/skills (not in the lock)      -> <dotfiles>/claude/skills/<name>/
  ~/.pi/agent/settings.json                                   -> <dotfiles>/pi/agent/settings.json
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

DF="${1:-$HOME/Development/GitHub/dotfiles}"
SNAP="$DF/claude"

log() { printf '%s\n' "$*"; }

if [ ! -d "$DF" ]; then
  log "error: dotfiles dir not found: $DF (clone it first, or pass the path)"
  exit 1
fi

capture_file() {
  # capture_file <src> <dest> [mode]
  local src="$1" dest="$2" mode="${3:-}"
  if [ ! -f "$src" ]; then
    log "skip   $src (not present)"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    log "same   $dest"
  else
    cp "$src" "$dest"
    log "copied $src -> $dest"
  fi
  [ -n "$mode" ] && chmod "$mode" "$dest"
  return 0
}

mkdir -p "$SNAP"

capture_file "$HOME/.claude/settings.json"       "$SNAP/settings.json"
capture_file "$HOME/.claude/settings.local.json" "$SNAP/settings.local.json"
capture_file "$HOME/.claude/config.json"         "$SNAP/config.json" 0600

# Skills are managed by the `skills` CLI (npx skills); the lock file is the source
# of truth for everything it installed. The playbook restores from it.
capture_file "$HOME/.agents/.skill-lock.json"    "$SNAP/skill-lock.json"

# Skill names the lock file knows about (one per line; empty if no lock file).
lock_skills() {
  [ -f "$HOME/.agents/.skill-lock.json" ] || return 0
  python3 - "$HOME/.agents/.skill-lock.json" <<'PY'
import json, sys
print("\n".join(sorted(json.load(open(sys.argv[1])).get("skills", {}))))
PY
}

in_lock() {
  # in_lock <name> <lock-names>
  printf '%s\n' "$2" | grep -qx -- "$1"
}

# Hand-made skills = anything in ~/.claude/skills the lock file doesn't manage.
# Each is mirrored (symlinks dereferenced) into the snapshot as a real directory.
LOCK_NAMES="$(lock_skills)"
if [ -d "$HOME/.claude/skills" ]; then
  for path in "$HOME/.claude/skills"/*/; do
    [ -d "$path" ] || continue
    name="$(basename "$path")"
    if in_lock "$name" "$LOCK_NAMES"; then
      continue
    fi
    mkdir -p "$SNAP/skills/$name"
    changes="$(rsync -aiL --delete --exclude .DS_Store "$path" "$SNAP/skills/$name/")"
    if [ -n "$changes" ]; then
      log "synced skill $name -> $SNAP/skills/$name (hand-made, not in lock)"
    else
      log "same   skill $name"
    fi
  done
fi

# Snapshot skill dirs that the lock file now manages are stale copies (the CLI
# restores them). Never deleted here — print the command so you can prune them.
stale=""
if [ -d "$SNAP/skills" ]; then
  for path in "$SNAP/skills"/*/; do
    [ -d "$path" ] || continue
    name="$(basename "$path")"
    if in_lock "$name" "$LOCK_NAMES"; then
      stale="$stale claude/skills/$name"
    fi
  done
fi
if [ -n "$stale" ]; then
  log "stale  snapshot skills now managed by the skills CLI (left in place):"
  for rel in $stale; do
    log "         git -C $DF rm -r $rel"
  done
fi

# Pi agent (~/.pi/agent): settings only. Its skills mirror is rebuilt by the skills
# CLI (-a pi) and auth.json is a secret.
capture_file "$HOME/.pi/agent/settings.json"     "$DF/pi/agent/settings.json"

# Deliberately NOT captured: ~/.claude.json holds OAuth tokens (plus the Jam MCP
# server and per-project state). Hand-carry it to the new Mac.
log "note   ~/.claude.json is NOT captured (contains tokens): hand-carry it."
