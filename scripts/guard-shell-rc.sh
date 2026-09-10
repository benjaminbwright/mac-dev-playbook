#!/usr/bin/env bash
# guard-shell-rc.sh — make a shell rc file safe when installer-based CLIs are
# missing (see GitHub issue #10).
#
# Rewrites the given rc file (e.g. the dotfiles repo's .zshrc) so every PATH
# line that references one of the known installer-managed directories is
# guarded with `[ -d "<dir>" ] &&`. Lines it does not recognise are left
# byte-for-byte untouched; lines that are already guarded are skipped, so
# running it twice changes nothing. A `<file>.bak` copy is written once.
#
# usage: scripts/guard-shell-rc.sh <rcfile>
set -euo pipefail

# Directories created by vendor installers (not Homebrew). A PATH component
# ending in one of these is treated as "belongs to an installer-based CLI".
#   ~/.local/bin          codex, cursor-agent
#   ~/.pocket-server/bin  pocket-server
#   ~/.limbo              limbo (now the Homebrew `turso` formula)
TOOL_DIRS=".local/bin .pocket-server/bin .limbo"

# Command names of those CLIs; an alias whose body starts with one of these is
# only defined when the command exists (`command -v`).
TOOL_CMDS_RE="codex|cursor-agent|pocket-server|limbo"

usage() {
  echo "usage: $0 <rcfile>" >&2
  exit 2
}

[ $# -eq 1 ] || usage
rc="$1"
if [ ! -f "$rc" ]; then
  echo "error: $rc: no such file" >&2
  exit 1
fi

# Strip surrounding quotes and rewrite ~/x or ${HOME}/x as $HOME/x so the
# generated guard is uniform whatever spelling the rc file used.
normalize_path() {
  local p="$1"
  p="${p#\"}"; p="${p%\"}"; p="${p#\'}"; p="${p%\'}"
  case "$p" in
    "~/"*) p="\$HOME/${p#\~/}" ;;
    '${HOME}/'*) p="\$HOME/${p#\$\{HOME\}/}" ;;
  esac
  printf '%s' "$p"
}

# Print the tool directory this PATH component points at, or nothing.
tool_component() {
  local comp frag
  comp="$(normalize_path "$1")"
  for frag in $TOOL_DIRS; do
    case "$comp" in
      "\$HOME/$frag") printf '%s' "$comp"; return 0 ;;
    esac
  done
  return 1
}

strip_quotes() {
  local v="$1"
  v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
  printf '%s' "$v"
}

# True when the PATH line's value is nothing but $PATH (i.e. it became a no-op
# after we pulled the tool dirs out of it).
is_bare_path_line() {
  [[ "$1" =~ ^[[:space:]]*(export[[:space:]]+)?PATH=[\"\']?\$\{?PATH\}?[\"\']?[[:space:]]*$ ]]
}

# Rewrite one PATH= line. Prints the replacement line(s).
#  - Only component (besides $PATH) is a tool dir  -> wrap the whole line.
#  - Tool dir mixed with other dirs                -> pull it out into its own
#    guarded line (before the line if it was prepended, after if appended) so
#    the other dirs stay on PATH when the tool is missing. Repeats until no
#    tool dir is left in the line.
process_path_line() {
  local line="$1" indent value comp norm raw="" tdir="" side=0 seen_path=0 rest=0 stripped
  if ! [[ "$line" =~ ^([[:space:]]*)(export[[:space:]]+)?PATH=(.*)$ ]]; then
    printf '%s\n' "$line"
    return 0
  fi
  indent="${BASH_REMATCH[1]}"
  value="$(strip_quotes "${BASH_REMATCH[3]}")"
  if [ -z "$value" ]; then
    printf '%s\n' "$line"
    return 0
  fi
  local comps
  IFS=: read -r -a comps <<< "$value"
  for comp in "${comps[@]}"; do
    if [ -z "$tdir" ] && norm="$(tool_component "$comp")"; then
      raw="$comp"; tdir="$norm"; side="$seen_path"
    else
      case "$comp" in
        '$PATH' | '${PATH}') seen_path=1 ;;
        *) rest=$((rest + 1)) ;;
      esac
    fi
  done
  if [ -z "$tdir" ]; then
    printf '%s\n' "$line"
    return 0
  fi
  changed=$((changed + 1))
  if [ "$rest" -eq 0 ]; then
    printf '%s\n' "${indent}[ -d \"$tdir\" ] && ${line#"$indent"}"
    return 0
  fi
  stripped="${line/"$raw:"/}"
  if [ "$stripped" = "$line" ]; then
    stripped="${line/":$raw"/}"
  fi
  if [ "$side" -eq 0 ]; then
    printf '%s\n' "${indent}[ -d \"$tdir\" ] && export PATH=\"$tdir:\$PATH\""
    is_bare_path_line "$stripped" || process_path_line "$stripped"
  else
    is_bare_path_line "$stripped" || process_path_line "$stripped"
    printf '%s\n' "${indent}[ -d \"$tdir\" ] && export PATH=\"\$PATH:$tdir\""
  fi
}

# Print the normalised path if $1 is a file inside one of the tool dirs.
tool_file() {
  local file frag
  file="$(normalize_path "$1")"
  for frag in $TOOL_DIRS; do
    case "$file" in
      "\$HOME/$frag/"*) printf '%s' "$file"; return 0 ;;
    esac
  done
  return 1
}

# Rewrite one `source <file>` / `. <file>` line that loads a tool's env file.
process_source_line() {
  local line="$1" indent tfile
  if [[ "$line" =~ ^([[:space:]]*)(source|\.)[[:space:]]+([^[:space:]\;]+) ]] \
     && tfile="$(tool_file "${BASH_REMATCH[3]}")"; then
    indent="${BASH_REMATCH[1]}"
    changed=$((changed + 1))
    printf '%s\n' "${indent}[ -f \"$tfile\" ] && ${line#"$indent"}"
  else
    printf '%s\n' "$line"
  fi
}

# Rewrite one `alias x='<tool> ...'` line so it is only defined when the tool
# is actually on PATH (wherever it was installed from).
process_alias_line() {
  local line="$1" indent cmd
  if [[ "$line" =~ ^([[:space:]]*)alias[[:space:]]+[^=]+=[\"\']?($TOOL_CMDS_RE)([[:space:]\"\']|$) ]]; then
    indent="${BASH_REMATCH[1]}"
    cmd="${BASH_REMATCH[2]}"
    changed=$((changed + 1))
    printf '%s\n' "${indent}command -v $cmd >/dev/null 2>&1 && ${line#"$indent"}"
  else
    printf '%s\n' "$line"
  fi
}

changed=0
tmp="$(mktemp "${TMPDIR:-/tmp}/guard-shell-rc.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    *PATH=*) process_path_line "$line" >> "$tmp" ;;
    *source* | *.\ * | *.\	*) process_source_line "$line" >> "$tmp" ;;
    *alias*) process_alias_line "$line" >> "$tmp" ;;
    *) printf '%s\n' "$line" >> "$tmp" ;;
  esac
done < "$rc"

if [ "$changed" -gt 0 ]; then
  # Keep the very first original as <file>.bak; never replace an existing one.
  if [ ! -e "$rc.bak" ]; then
    cp -p "$rc" "$rc.bak"
  fi
  # Write through (not mv) so a symlinked ~/.zshrc keeps pointing at the repo.
  cat "$tmp" > "$rc"
  echo "guard-shell-rc: guarded $changed line(s) in $rc"
else
  echo "guard-shell-rc: no changes needed in $rc"
fi
