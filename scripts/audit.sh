#!/usr/bin/env bash
# audit.sh — read-only parity check: is this Mac in sync with the playbook?
#
# Compares the machine against default.config.yml (+ config.yml overrides) and
# files/ in both directions and prints the drift. Never changes anything:
# it only runs list/status commands and reads files.
#
# Usage: scripts/audit.sh [--section NAME]... [--strict] [--help]
#   (or `make audit`)
#
# Environment overrides (mainly for tests):
#   AUDIT_ROOT        playbook directory (default: the repo containing this script)
#   AUDIT_REPO_ROOTS  colon-separated dirs to scan for git repos
#                     (default: derived from git_repositories dests + ~/Development)

set -euo pipefail

SECTIONS="brew mas editors claude dotfiles repos repo-state"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--section NAME]... [--strict] [--help]

Read-only parity check between this Mac and the playbook config.
Prints drift in both directions; exits 0 unless --strict is given.

Options:
  --section NAME   run only this section (repeatable). One of:
                   $SECTIONS
  --strict         exit 1 if any drift was found
  -h, --help       show this help

Sections:
  brew        Homebrew formulae / casks / taps: installed vs declared
  mas         Mac App Store apps (mas list) vs mas_installed_apps
  editors     VS Code / Cursor extensions vs files/*/extensions.txt, settings diff
  claude      ~/.claude/skills on disk vs ~/.agents/.skill-lock.json
  dotfiles    dotfiles_files in ~ that are not symlinks into the dotfiles repo
  repos       git repos on disk with no remote / not in git_repositories, and
              manifest entries missing on disk
  repo-state  repos with dirty, unpushed, or stashed work
EOF
}

STRICT=0
SELECTED=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --strict) STRICT=1 ;;
    --section)
      [ $# -ge 2 ] || { echo "error: --section needs a NAME" >&2; usage >&2; exit 2; }
      case " $SECTIONS " in
        *" $2 "*) SELECTED="$SELECTED $2" ;;
        *) echo "error: unknown section '$2' (one of: $SECTIONS)" >&2; exit 2 ;;
      esac
      shift ;;
    *) echo "error: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$SELECTED" ] || SELECTED="$SECTIONS"

AUDIT_ROOT="${AUDIT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
export HOMEBREW_NO_AUTO_UPDATE=1   # never let `brew list` kick off an update
DRIFT=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/audit.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Find a python3 that can import yaml (Homebrew's usually can; fall back to
# the interpreter ansible itself runs on).
find_python() {
  local py
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    command -v python3; return 0
  fi
  if command -v ansible >/dev/null 2>&1; then
    py="$(ansible --version 2>/dev/null | sed -n 's/.*python version = .* (\(.*\))$/\1/p' | head -n1)"
    if [ -n "$py" ] && "$py" -c 'import yaml' >/dev/null 2>&1; then
      echo "$py"; return 0
    fi
  fi
  return 1
}
PYTHON="$(find_python || true)"

# cfg KEY [FIELD...] — print one line per item of the list variable KEY from
# default.config.yml merged with config.yml (config.yml wins). Plain items print
# as-is; dict items print the requested FIELDs tab-separated (default: name).
cfg() {
  [ -n "$PYTHON" ] || return 0
  "$PYTHON" - "$AUDIT_ROOT" "$@" <<'PY'
import os, sys, yaml
root, key, fields = sys.argv[1], sys.argv[2], sys.argv[3:] or ["name"]
cfg = {}
for name in ("default.config.yml", "config.yml"):
    path = os.path.join(root, name)
    if os.path.exists(path):
        with open(path) as fh:
            cfg.update(yaml.safe_load(fh) or {})
value = cfg.get(key)
if value is None:
    sys.exit(0)
if not isinstance(value, list):
    print(value)
    sys.exit(0)
for item in value:
    if isinstance(item, dict):
        print("\t".join(str(item.get(f, "")) for f in fields))
    elif item is not None:
        print(item)
PY
}

section() { echo; echo "## $1"; }
ok() { echo "  ok: $1"; }
skip() { echo "  skipped: $1"; }
drift() { DRIFT=$((DRIFT + 1)); echo "  ! $1"; }

sorted() { LC_ALL=C sort -u; }

# canon MAPFILE — rewrite stdin names through an "alias<TAB>canonical" map.
canon() {
  awk -v f="$1" 'BEGIN { while ((getline l < f) > 0) { split(l, p, "\t"); m[p[1]] = p[2] } }
                 { print ($0 in m) ? m[$0] : $0 }'
}

# report_missing LABEL FILE_A FILE_B — every line of FILE_A absent from FILE_B
# (both pre-sorted) is drift, reported under LABEL.
report_missing() {
  local label="$1" a="$2" b="$3" n=0 line
  while IFS= read -r line; do
    drift "$label: $line"; n=$((n + 1))
  done < <(LC_ALL=C comm -23 "$a" "$b")
  return 0
}

# report_both A_LABEL FILE_A B_LABEL FILE_B WHAT — two-way comparison.
report_both() {
  local before="$DRIFT"
  report_missing "$1" "$2" "$4"
  report_missing "$3" "$4" "$2"
  [ "$DRIFT" -gt "$before" ] || ok "$5 match"
}

# ---------------------------------------------------------------------------
# Sections
# ---------------------------------------------------------------------------

audit_brew() {
  section brew
  command -v brew >/dev/null 2>&1 || { skip "brew not installed"; return 0; }
  [ -n "$PYTHON" ] || { skip "no python3 with PyYAML to read the config"; return 0; }

  # Alias maps ("alias<TAB>canonical") so that declared 'gpg' / 'openssl' /
  # 'python' match installed 'gnupg' / 'openssl@3' / 'python@3.x', and a cask
  # still installed under an old token (docker -> docker-desktop) matches too.
  brew info --json=v2 --installed 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
with open(sys.argv[1], "w") as f_out, open(sys.argv[2], "w") as c_out:
    for f in d.get("formulae", []):
        for a in f.get("aliases", []) + f.get("oldnames", []):
            f_out.write(a + "\t" + f["name"] + "\n")
    for c in d.get("casks", []):
        for a in c.get("old_tokens", []):
            c_out.write(a + "\t" + c["token"] + "\n")
' "$TMP/f.aliases" "$TMP/c.aliases" 2>/dev/null || { : > "$TMP/f.aliases"; : > "$TMP/c.aliases"; }

  # Formulae: a declared package counts as installed if `brew list` has it
  # (even as a dependency); an installed package only counts as undeclared if
  # it is a leaf (installed on purpose, not pulled in by something else).
  cfg homebrew_installed_packages | sed 's|.*/||' | canon "$TMP/f.aliases" | sorted > "$TMP/f.declared"
  brew list --formula -1 2>/dev/null | canon "$TMP/f.aliases" | sorted > "$TMP/f.installed"
  brew leaves 2>/dev/null | sed 's|.*/||' | canon "$TMP/f.aliases" | sorted > "$TMP/f.leaves"
  local before="$DRIFT"
  report_missing "formula declared, not installed" "$TMP/f.declared" "$TMP/f.installed"
  report_missing "formula installed, not declared" "$TMP/f.leaves" "$TMP/f.declared"
  [ "$DRIFT" -gt "$before" ] || ok "formulae match"

  cfg homebrew_cask_apps | canon "$TMP/c.aliases" | sorted > "$TMP/c.declared"
  brew list --cask -1 2>/dev/null | canon "$TMP/c.aliases" | sorted > "$TMP/c.installed"
  report_both "cask declared, not installed" "$TMP/c.declared" \
              "cask installed, not declared" "$TMP/c.installed" "casks"

  # homebrew/* taps are built in / managed by brew itself.
  cfg homebrew_taps | sorted > "$TMP/t.declared"
  brew tap 2>/dev/null | grep -v '^homebrew/' | sorted > "$TMP/t.installed"
  report_both "tap declared, not tapped" "$TMP/t.declared" \
              "tap tapped, not declared" "$TMP/t.installed" "taps"
}

audit_mas() {
  section mas
  command -v mas >/dev/null 2>&1 || { skip "mas not installed"; return 0; }
  [ -n "$PYTHON" ] || { skip "no python3 with PyYAML to read the config"; return 0; }

  # Both files are "ID NAME" sorted by ID; join on the ID so names can differ.
  cfg mas_installed_apps id name | awk -F'\t' '{print $1, $2}' | sorted > "$TMP/m.declared"
  # `mas list` prints "  ID  NAME  (VERSION)".
  mas list 2>/dev/null | sed -E 's/^ *([0-9]+) +(.*[^ ]) +\([^)]*\) *$/\1 \2/' | sorted > "$TMP/m.installed"
  local before="$DRIFT" line
  while IFS= read -r line; do drift "app declared, not installed: $line"; done \
    < <(LC_ALL=C join -v1 "$TMP/m.declared" "$TMP/m.installed")
  while IFS= read -r line; do drift "app installed, not declared: $line"; done \
    < <(LC_ALL=C join -v2 "$TMP/m.declared" "$TMP/m.installed")
  [ "$DRIFT" -gt "$before" ] || ok "App Store apps match"
}

# audit_editor NAME CLI USER_DIR FILE... — extensions vs files/NAME/extensions.txt
# and a diff of each FILE in files/NAME/ against USER_DIR/FILE.
audit_editor() {
  local name="$1" cli="$2" user_dir="$3"; shift 3
  local before="$DRIFT" file
  command -v "$cli" >/dev/null 2>&1 || { skip "$cli not installed"; return 0; }

  # Extension ids are case-insensitive; the CLI may print them in either case.
  tr '[:upper:]' '[:lower:]' < "$AUDIT_ROOT/files/$name/extensions.txt" | grep -v '^$' | sorted > "$TMP/e.declared"
  "$cli" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' | sorted > "$TMP/e.installed"
  report_both "$name extension declared, not installed" "$TMP/e.declared" \
              "$name extension installed, not declared" "$TMP/e.installed" "$name extensions"

  for file in "$@"; do
    if [ ! -e "$user_dir/$file" ]; then
      drift "$name $file missing on disk ($user_dir/$file)"
    elif diff -q "$AUDIT_ROOT/files/$name/$file" "$user_dir/$file" >/dev/null 2>&1; then
      ok "$name $file matches"
    else
      drift "$name $file differs (- files/$name/$file, + on disk):"
      diff -u "$AUDIT_ROOT/files/$name/$file" "$user_dir/$file" | tail -n +3 | sed 's/^/      /' || true
    fi
  done
}

audit_editors() {
  section editors
  audit_editor vscode code "$HOME/Library/Application Support/Code/User" settings.json
  audit_editor cursor cursor "$HOME/Library/Application Support/Cursor/User" settings.json keybindings.json
}

audit_claude() {
  section claude
  local skills_dir="$HOME/.claude/skills" lock="$HOME/.agents/.skill-lock.json" entry name
  [ -f "$lock" ] || { skip "no skill lock file at $lock"; return 0; }
  [ -d "$skills_dir" ] || { skip "no $skills_dir"; return 0; }
  command -v python3 >/dev/null 2>&1 || { skip "python3 not installed"; return 0; }

  python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1])).get("skills", {})))' "$lock" \
    | sorted > "$TMP/s.lock"
  : > "$TMP/s.disk"
  for entry in "$skills_dir"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name="$(basename "$entry")"
    case "$name" in .DS_Store) continue ;; esac
    if [ -L "$entry" ] && [ ! -e "$entry" ]; then
      drift "skill symlink is broken: $name -> $(readlink "$entry")"
      continue
    fi
    echo "$name" >> "$TMP/s.disk"
  done
  sorted < "$TMP/s.disk" > "$TMP/s.disk.sorted"
  report_both "skill in lock file, not on disk" "$TMP/s.lock" \
              "skill on disk, not in lock file" "$TMP/s.disk.sorted" "Claude skills"
}

# expand_home PATH — replace a leading ~ with $HOME.
expand_home() {
  case "$1" in
    "~") echo "$HOME" ;;
    "~/"*) echo "$HOME/${1#\~/}" ;;
    *) echo "$1" ;;
  esac
}

# realpath PATH — fully resolved path (macOS ships no reliable `realpath`).
realpath_of() {
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

audit_dotfiles() {
  section dotfiles
  [ -n "$PYTHON" ] || { skip "no python3 with PyYAML to read the config"; return 0; }
  local repo before="$DRIFT" file path target
  repo="$(expand_home "$(cfg dotfiles_repo_local_destination)")"
  [ -d "$repo" ] || { drift "dotfiles repo not cloned at $repo"; return 0; }
  repo="$(realpath_of "$repo")"

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    path="$HOME/$file"
    if [ -L "$path" ]; then
      target="$(realpath_of "$path")"
      case "$target" in
        "$repo"/*) ;;
        *) drift "symlink points outside the dotfiles repo: $file -> $(readlink "$path")" ;;
      esac
    elif [ -e "$path" ]; then
      drift "regular file, not a symlink into the dotfiles repo: $file"
    else
      drift "missing from ~: $file"
    fi
  done < <(cfg dotfiles_files)
  [ "$DRIFT" -gt "$before" ] || ok "dotfiles are all symlinks into $repo"
}

# Repos the playbook itself manages outside git_repositories (see main.yml).
KNOWN_REPOS_EXTRA="Development/GitHub/secrets"

# repo_roots — directories to scan for git repos, one per line.
repo_roots() {
  local dest
  if [ -n "${AUDIT_REPO_ROOTS:-}" ]; then
    echo "$AUDIT_REPO_ROOTS" | tr ':' '\n'
  else
    { while IFS= read -r dest; do
        [ -n "$dest" ] && echo "$HOME/${dest%%/*}"
      done < <(cfg git_repositories dest)
      [ -d "$HOME/Development" ] && echo "$HOME/Development"; } | sorted
  fi
}

# find_repos — every git checkout under the scan roots (cached in $TMP/repos).
find_repos() {
  local root
  if [ ! -f "$TMP/repos" ]; then
    while IFS= read -r root; do
      [ -d "$root" ] || continue
      find "$root" -maxdepth 6 \( -name node_modules -o -name .Trash -o -name Library \) -prune \
        -o -name .git -prune -print 2>/dev/null
    done < <(repo_roots) | sed 's|/\.git$||' | sorted > "$TMP/repos"
  fi
  cat "$TMP/repos"
}

audit_repos() {
  section repos
  [ -n "$PYTHON" ] || { skip "no python3 with PyYAML to read the config"; return 0; }
  local before="$DRIFT" repo dest
  echo "  scanning: $(repo_roots | tr '\n' ' ')"

  { cfg git_repositories dest; echo "$KNOWN_REPOS_EXTRA"; } | grep -v '^$' \
    | sed "s|^|$HOME/|" | sorted > "$TMP/r.known"
  expand_home "$(cfg dotfiles_repo_local_destination)" >> "$TMP/r.known"
  echo "$(realpath_of "$AUDIT_ROOT")" >> "$TMP/r.known"

  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    if [ -z "$(git -C "$repo" remote 2>/dev/null)" ]; then
      drift "repo has no remote: $repo"
    fi
    grep -qxF "$repo" "$TMP/r.known" || drift "repo on disk, not in git_repositories: $repo"
  done < <(find_repos)

  while IFS= read -r dest; do
    [ -n "$dest" ] || continue
    [ -e "$HOME/$dest/.git" ] || drift "in git_repositories, missing on disk: $dest"
  done < <(cfg git_repositories dest)
  [ "$DRIFT" -gt "$before" ] || ok "all repos on disk have remotes and are in git_repositories"
}

audit_repo_state() {
  section repo-state
  [ -n "$PYTHON" ] || { skip "no python3 with PyYAML to read the config"; return 0; }
  local before="$DRIFT" repo n
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    # --no-optional-locks: don't refresh/write the index while looking.
    n="$(git -C "$repo" --no-optional-locks status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n" -eq 0 ] || drift "dirty working tree: $repo ($n path(s))"
    # Commits on any local branch that no remote-tracking ref contains —
    # covers both "ahead of origin" and local-only branches.
    n="$(git -C "$repo" log --branches --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n" -eq 0 ] || drift "unpushed commits: $repo ($n commit(s))"
    n="$(git -C "$repo" stash list 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n" -eq 0 ] || drift "stashed changes: $repo ($n stash(es))"
  done < <(find_repos)
  [ "$DRIFT" -gt "$before" ] || ok "all repos are clean, pushed and stash-free"
}

for section in $SELECTED; do
  case "$section" in
    brew) audit_brew ;;
    mas) audit_mas ;;
    editors) audit_editors ;;
    claude) audit_claude ;;
    dotfiles) audit_dotfiles ;;
    repos) audit_repos ;;
    repo-state) audit_repo_state ;;
  esac
done

echo
if [ "$DRIFT" -eq 0 ]; then
  echo "No drift found."
else
  echo "$DRIFT drift item(s) found."
fi

if [ "$STRICT" -eq 1 ] && [ "$DRIFT" -gt 0 ]; then
  exit 1
fi
exit 0
