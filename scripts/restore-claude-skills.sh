#!/usr/bin/env bash
# Restore agent skills from a `skills` CLI lock file (~/.agents/.skill-lock.json,
# snapshotted by scripts/capture-claude.sh as <dotfiles>/claude/skill-lock.json).
#
# Usage: scripts/restore-claude-skills.sh <lock-file> [--agents claude-code,pi]
#
# For every skill in the lock that is missing from ~/.claude/skills, runs
#   npx -y skills add <source> -g -y -a <agent>... --skill <name>...
# (one call per source repo). Skills already present are left untouched, so a
# re-run is a no-op. Prints one line per source it installs; nothing if up to date.
set -euo pipefail

usage() { echo "Usage: $(basename "$0") <lock-file> [--agents claude-code,pi]"; }

LOCK="${1:-}"
AGENTS="claude-code,pi"
case "$LOCK" in ""|-h|--help) usage; exit 0 ;; esac
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --agents) AGENTS="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

if [ ! -f "$LOCK" ]; then
  echo "error: lock file not found: $LOCK" >&2
  exit 1
fi
if ! command -v npx > /dev/null 2>&1; then
  echo "error: npx not found on PATH (install node first)" >&2
  exit 1
fi

# Emit "<source>\t<skill> <skill> ..." for skills not yet present in ~/.claude/skills.
missing_by_source() {
  python3 - "$LOCK" "$HOME/.claude/skills" <<'PY'
import json, os, sys
lock, skills_dir = sys.argv[1], sys.argv[2]
by_source = {}
for name, meta in json.load(open(lock)).get("skills", {}).items():
    if os.path.exists(os.path.join(skills_dir, name)):
        continue
    by_source.setdefault(meta["source"], []).append(name)
for source in sorted(by_source):
    print(source + "\t" + " ".join(sorted(by_source[source])))
PY
}

agent_args=()
IFS=',' read -r -a agent_list <<< "$AGENTS"
for a in "${agent_list[@]}"; do agent_args+=(-a "$a"); done

while IFS=$'\t' read -r source names; do
  [ -n "$source" ] || continue
  skill_args=()
  for n in $names; do skill_args+=(--skill "$n"); done
  echo "installing from $source: $names"
  npx -y skills add "$source" -g -y "${agent_args[@]}" "${skill_args[@]}"
done < <(missing_by_source)
