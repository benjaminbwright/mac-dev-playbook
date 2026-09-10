#!/usr/bin/env bats
# Tests for scripts/audit.sh — the read-only "am I in sync?" parity check.
#
# Every test runs against a throwaway HOME and a throwaway AUDIT_ROOT (fake
# default.config.yml / config.yml / files/*), with stub brew/mas/code/cursor
# binaries on PATH, so nothing touches the real machine.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
AUDIT="$REPO_ROOT/scripts/audit.sh"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export AUDIT_ROOT="$BATS_TEST_TMPDIR/root"
  export STUB="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$HOME" "$AUDIT_ROOT/files/vscode" "$AUDIT_ROOT/files/cursor" "$STUB/bin"
  export PATH="$STUB/bin:$PATH"
  export HOMEBREW_NO_AUTO_UPDATE=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  export GIT_CONFIG_NOSYSTEM=1
  # A minimal PATH ($STUB/bin:$TOOLS:/usr/bin:/bin) for "tool not installed"
  # tests: only the python3 that has PyYAML, no brew/mas/code/cursor.
  export TOOLS="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$TOOLS"
  ln -s "$(command -v python3)" "$TOOLS/python3"

  # Fake playbook config (what the machine SHOULD look like).
  cat > "$AUDIT_ROOT/default.config.yml" <<'YAML'
---
dotfiles_repo_local_destination: ~/dotfiles
dotfiles_files:
  - .zshrc
  - .vimrc
homebrew_installed_packages:
  - git
  - github/gh/gh
  - openssl
homebrew_taps:
  - hashicorp/tap
homebrew_cask_apps:
  - firefox
  - slack
mas_installed_apps:
  - id: 111
    name: "Xcode"
  - id: 222
    name: "Todoist"
YAML
  # config.yml overrides (gitignored on the real machine).
  cat > "$AUDIT_ROOT/config.yml" <<'YAML'
---
git_repositories:
  - repo: git@github.com:example/alpha.git
    dest: code/alpha
  - repo: git@github.com:example/missing.git
    dest: code/missing
YAML
  printf '%s\n' ext.one ext.two > "$AUDIT_ROOT/files/vscode/extensions.txt"
  printf '%s\n' ext.one cursor.only > "$AUDIT_ROOT/files/cursor/extensions.txt"
  echo '{"editor": "declared"}' > "$AUDIT_ROOT/files/vscode/settings.json"
  echo '{"editor": "declared"}' > "$AUDIT_ROOT/files/cursor/settings.json"
  echo '[]' > "$AUDIT_ROOT/files/cursor/keybindings.json"

  # Stub CLIs read canned output from $STUB/*.txt so each test can shape them.
  stub brew 'case "$*" in
    *--cask*) cat "$STUB/brew_casks.txt" ;;
    *--formula*) cat "$STUB/brew_formulae.txt" ;;
    leaves*) cat "$STUB/brew_leaves.txt" ;;
    tap) cat "$STUB/brew_taps.txt" ;;
    info*--json*) cat "$STUB/brew_info.json" ;;
    *) echo "unexpected brew $*" >&2; exit 99 ;;
  esac'
  echo '{"formulae": [], "casks": []}' > "$STUB/brew_info.json"
  stub mas 'case "$*" in
    list) cat "$STUB/mas_list.txt" ;;
    *) echo "unexpected mas $*" >&2; exit 99 ;;
  esac'
  stub code 'case "$*" in
    --list-extensions) cat "$STUB/code_extensions.txt" ;;
    *) echo "unexpected code $*" >&2; exit 99 ;;
  esac'
  stub cursor 'case "$*" in
    --list-extensions) cat "$STUB/cursor_extensions.txt" ;;
    *) echo "unexpected cursor $*" >&2; exit 99 ;;
  esac'
  # Baseline: machine matches config exactly.
  printf '%s\n' git gh openssl ca-certificates > "$STUB/brew_formulae.txt"
  printf '%s\n' git gh > "$STUB/brew_leaves.txt"
  printf '%s\n' firefox slack > "$STUB/brew_casks.txt"
  printf '%s\n' hashicorp/tap homebrew/services > "$STUB/brew_taps.txt"
  printf '%s\n' ' 111  Xcode    (16.0)' ' 222  Todoist  (9.1)' > "$STUB/mas_list.txt"
  printf '%s\n' ext.one ext.two > "$STUB/code_extensions.txt"
  printf '%s\n' ext.one cursor.only > "$STUB/cursor_extensions.txt"
}

stub() {
  printf '#!/bin/sh\nSTUB="%s"\n%s\n' "$STUB" "$2" > "$STUB/bin/$1"
  chmod +x "$STUB/bin/$1"
}

@test "--help prints usage and exits 0" {
  run "$AUDIT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [[ "$output" == *"--section"* ]]
  [[ "$output" == *"--strict"* ]]
}

@test "brew: in-sync machine reports no drift" {
  run "$AUDIT" --section brew --strict
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## brew"* ]]
  [[ "$output" != *"not declared"* ]]
  [[ "$output" != *"not installed"* ]]
}

@test "brew: reports formulae, casks and taps drifting in both directions" {
  printf '%s\n' git gh extra-tool > "$STUB/brew_leaves.txt"
  printf '%s\n' git gh extra-tool ca-certificates > "$STUB/brew_formulae.txt"   # openssl gone
  printf '%s\n' firefox zoom > "$STUB/brew_casks.txt"                           # slack gone, zoom extra
  printf '%s\n' heroku/brew homebrew/services > "$STUB/brew_taps.txt"           # hashicorp/tap gone
  run "$AUDIT" --section brew
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed, not declared"*"extra-tool"* ]]
  [[ "$output" == *"declared, not installed"*"openssl"* ]]
  [[ "$output" == *"installed, not declared"*"zoom"* ]]
  [[ "$output" == *"declared, not installed"*"slack"* ]]
  [[ "$output" == *"tapped, not declared"*"heroku/brew"* ]]
  [[ "$output" == *"declared, not tapped"*"hashicorp/tap"* ]]
  # dependencies that are not leaves are never reported as undeclared,
  # and 'github/gh/gh' matches the installed 'gh'.
  [[ "$output" != *"ca-certificates"* ]]
  [[ "$output" != *"gh"$'\n'* ]]
  [[ "$output" != *"homebrew/services"* ]]
}

@test "brew: declared aliases and renamed casks match their installed canonical names" {
  # Config says gpg / openssl / docker-desktop; brew has gnupg / openssl@3 and
  # the cask under its old token 'docker'. None of that is drift.
  printf '%s\n' 'homebrew_installed_packages: [git, github/gh/gh, gpg, openssl]' \
                'homebrew_cask_apps: [firefox, slack, docker-desktop]' >> "$AUDIT_ROOT/config.yml"
  printf '%s\n' git gh gnupg openssl@3 > "$STUB/brew_formulae.txt"
  printf '%s\n' git gh gnupg > "$STUB/brew_leaves.txt"
  printf '%s\n' firefox slack docker > "$STUB/brew_casks.txt"
  cat > "$STUB/brew_info.json" <<'JSON'
{"formulae": [{"name": "gnupg", "aliases": ["gpg", "gpg2"], "oldnames": ["gnupg2"]},
              {"name": "openssl@3", "aliases": ["openssl"], "oldnames": []}],
 "casks": [{"token": "docker-desktop", "old_tokens": ["docker"]}]}
JSON
  run "$AUDIT" --section brew --strict
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: formulae match"* ]]
  [[ "$output" == *"ok: casks match"* ]]
}

@test "brew: skipped when brew is not installed" {
  rm "$STUB/bin/brew"
  PATH="$STUB/bin:$TOOLS:/usr/bin:/bin" run "$AUDIT" --section brew
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped: brew not installed"* ]]
}

@test "mas: reports App Store apps drifting in both directions, matched by id" {
  # 222 (Todoist) gone; 333 (Sketch) installed but undeclared; Xcode present
  # under a different display name still matches by id.
  printf '%s\n' ' 111  Xcode-beta  (17.0)' ' 333  Sketch  (100.1)' > "$STUB/mas_list.txt"
  run "$AUDIT" --section mas
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"declared, not installed"*"222"*"Todoist"* ]]
  [[ "$output" == *"installed, not declared"*"333"*"Sketch"* ]]
  [[ "$output" != *"111"* ]]
}

@test "mas: in-sync machine reports no drift; skipped when mas is missing" {
  run "$AUDIT" --section mas --strict
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok:"* ]]
  rm "$STUB/bin/mas"
  PATH="$STUB/bin:$TOOLS:/usr/bin:/bin" run "$AUDIT" --section mas
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped: mas not installed"* ]]
}

@test "editors: extensions drift both ways (case-insensitive) and settings files are diffed" {
  local code_user="$HOME/Library/Application Support/Code/User"
  local cursor_user="$HOME/Library/Application Support/Cursor/User"
  mkdir -p "$code_user" "$cursor_user"
  echo '{"editor": "declared"}' > "$code_user/settings.json"          # identical
  echo '{"editor": "LOCAL EDIT"}' > "$cursor_user/settings.json"      # differs
  # cursor keybindings.json intentionally absent on "disk"
  printf '%s\n' Ext.One extra.ext > "$STUB/code_extensions.txt"        # ext.two missing, extra.ext extra
  printf '%s\n' ext.one cursor.only > "$STUB/cursor_extensions.txt"    # in sync
  run "$AUDIT" --section editors
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vscode extension declared, not installed: ext.two"* ]]
  [[ "$output" == *"vscode extension installed, not declared: extra.ext"* ]]
  [[ "$output" != *"ext.one"* ]]
  [[ "$output" == *"ok: cursor extensions match"* ]]
  [[ "$output" == *"ok: vscode settings.json matches"* ]]
  [[ "$output" == *"cursor settings.json differs"* ]]
  [[ "$output" == *'-{"editor": "declared"}'* ]]
  [[ "$output" == *'+{"editor": "LOCAL EDIT"}'* ]]
  [[ "$output" == *"cursor keybindings.json missing on disk"* ]]
}

@test "editors: an editor whose CLI is missing is skipped, the other still audited" {
  rm "$STUB/bin/cursor"
  mkdir -p "$HOME/Library/Application Support/Code/User"
  echo '{"editor": "declared"}' > "$HOME/Library/Application Support/Code/User/settings.json"
  PATH="$STUB/bin:$TOOLS:/usr/bin:/bin" run "$AUDIT" --section editors --strict
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped: cursor not installed"* ]]
  [[ "$output" == *"ok: vscode extensions match"* ]]
}

@test "claude: skills on disk vs the skill lock file, both directions, plus broken symlinks" {
  mkdir -p "$HOME/.agents/skills/alpha" "$HOME/.claude/skills/local-only"
  ln -s ../../.agents/skills/alpha "$HOME/.claude/skills/alpha"
  ln -s ../../.agents/skills/gone "$HOME/.claude/skills/broken"
  cat > "$HOME/.agents/.skill-lock.json" <<'JSON'
{"version": 3, "skills": {"alpha": {"source": "x/y"}, "beta": {"source": "x/y"}}, "dismissed": []}
JSON
  run "$AUDIT" --section claude
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skill in lock file, not on disk: beta"* ]]
  [[ "$output" == *"skill on disk, not in lock file: local-only"* ]]
  [[ "$output" == *"skill symlink is broken: broken"* ]]
  [[ "$output" != *": alpha"* ]]
}

@test "claude: skipped when there is no lock file" {
  mkdir -p "$HOME/.claude/skills/whatever"
  run "$AUDIT" --section claude --strict
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped:"*".skill-lock.json"* ]]
}

@test "dotfiles: regular files, foreign symlinks and missing files are drift; repo symlinks are ok" {
  printf '%s\n' 'dotfiles_files: [.zshrc, .vimrc, .aliases, .inputrc]' >> "$AUDIT_ROOT/config.yml"
  mkdir -p "$HOME/dotfiles" "$HOME/elsewhere"
  touch "$HOME/dotfiles/.zshrc" "$HOME/dotfiles/.vimrc" "$HOME/elsewhere/.aliases"
  ln -s "$HOME/dotfiles/.zshrc" "$HOME/.zshrc"       # correct
  echo 'local' > "$HOME/.vimrc"                      # regular file
  ln -s "$HOME/elsewhere/.aliases" "$HOME/.aliases"  # symlink, wrong place
  # .inputrc absent
  run "$AUDIT" --section dotfiles
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"regular file, not a symlink into the dotfiles repo: .vimrc"* ]]
  [[ "$output" == *"symlink points outside the dotfiles repo: .aliases"* ]]
  [[ "$output" == *"missing from ~: .inputrc"* ]]
  [[ "$output" != *".zshrc"* ]]
}

@test "dotfiles: in-sync home reports ok" {
  mkdir -p "$HOME/dotfiles"
  touch "$HOME/dotfiles/.zshrc" "$HOME/dotfiles/.vimrc"
  ln -s "$HOME/dotfiles/.zshrc" "$HOME/.zshrc"
  ln -s "$HOME/dotfiles/.vimrc" "$HOME/.vimrc"
  run "$AUDIT" --section dotfiles --strict
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: dotfiles"* ]]
}

# make_repo DIR [REMOTE_URL] — a git repo with one commit (and optionally a remote).
make_repo() {
  git init -q "$1"
  git -C "$1" commit -q --allow-empty -m init
  [ $# -lt 2 ] || git -C "$1" remote add origin "$2"
}

@test "repos: no-remote and unmanifested repos on disk, and manifest entries missing on disk" {
  make_repo "$HOME/code/alpha" git@github.com:example/alpha.git         # in manifest
  make_repo "$HOME/code/beta" git@github.com:example/beta.git           # not in manifest
  make_repo "$HOME/code/noremote"                                       # no remote
  make_repo "$HOME/code/beta/node_modules/dep" https://x/dep.git        # ignored
  run "$AUDIT" --section repos
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo has no remote: $HOME/code/noremote"* ]]
  [[ "$output" == *"repo on disk, not in git_repositories: $HOME/code/beta"* ]]
  [[ "$output" == *"in git_repositories, missing on disk: code/missing"* ]]
  [[ "$output" != *"code/alpha"* ]]
  [[ "$output" != *"node_modules"* ]]
}

@test "repos: AUDIT_REPO_ROOTS overrides the scanned directories" {
  make_repo "$HOME/code/alpha" git@github.com:example/alpha.git
  make_repo "$HOME/other/gamma" git@github.com:example/gamma.git
  AUDIT_REPO_ROOTS="$HOME/other" run "$AUDIT" --section repos
  echo "$output"
  [[ "$output" == *"not in git_repositories: $HOME/other/gamma"* ]]
  [[ "$output" != *"code/alpha"* ]]
}

# make_pushed_repo DIR — a repo whose main branch is fully pushed to a local bare remote.
make_pushed_repo() {
  git init -q --bare "$1.remote.git"
  make_repo "$1" "$1.remote.git"
  git -C "$1" push -q -u origin HEAD
}

@test "repo-state: dirty, unpushed (incl. local-only branches) and stashed work is reported" {
  make_pushed_repo "$HOME/code/clean"
  make_pushed_repo "$HOME/code/dirty";   touch "$HOME/code/dirty/scratch.txt"
  make_pushed_repo "$HOME/code/ahead";   git -C "$HOME/code/ahead" commit -q --allow-empty -m more
  make_pushed_repo "$HOME/code/branchy"; git -C "$HOME/code/branchy" checkout -q -b wip
                                         git -C "$HOME/code/branchy" commit -q --allow-empty -m wip
  make_pushed_repo "$HOME/code/stashy";  echo x > "$HOME/code/stashy/f"; git -C "$HOME/code/stashy" add f
                                         git -C "$HOME/code/stashy" stash push -q -m t
  run "$AUDIT" --section repo-state
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dirty working tree: $HOME/code/dirty"* ]]
  [[ "$output" == *"unpushed commits: $HOME/code/ahead"* ]]
  [[ "$output" == *"unpushed commits: $HOME/code/branchy"* ]]
  [[ "$output" == *"stashed changes: $HOME/code/stashy"* ]]
  [[ "$output" != *"code/clean"* ]]
}

@test "repo-state: all-clean repos report ok" {
  make_pushed_repo "$HOME/code/clean"
  run "$AUDIT" --section repo-state --strict
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok:"* ]]
}

@test "exit code: drift exits 0 by default and 1 with --strict; unknown section exits 2" {
  printf '%s\n' git gh extra-tool > "$STUB/brew_leaves.txt"
  run "$AUDIT" --section brew
  [ "$status" -eq 0 ]
  [[ "$output" == *"drift item(s) found"* ]]
  run "$AUDIT" --section brew --strict
  [ "$status" -eq 1 ]
  run "$AUDIT" --section nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown section"* ]]
}

@test "full run covers every section and summarises" {
  run "$AUDIT"
  echo "$output"
  [ "$status" -eq 0 ]
  for s in brew mas editors claude dotfiles repos repo-state; do
    [[ "$output" == *"## $s"* ]]
  done
  [[ "$output" == *"drift item(s) found."* || "$output" == *"No drift found."* ]]
}
