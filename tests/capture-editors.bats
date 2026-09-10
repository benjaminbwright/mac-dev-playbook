#!/usr/bin/env bats
# Tests for scripts/capture-editors.sh. Everything runs against a fake HOME,
# stub `code`/`cursor` CLIs on PATH, and a scratch repo dir -- the real ~ and
# the real files/ are never touched.

SCRIPT="$BATS_TEST_DIRNAME/../scripts/capture-editors.sh"

setup() {
  HOME="$BATS_TEST_TMPDIR/home"
  REPO="$BATS_TEST_TMPDIR/repo"
  BIN="$BATS_TEST_TMPDIR/bin"
  export HOME REPO
  export CAPTURE_EDITORS_REPO="$REPO"
  # Only stubs + system utils: the real `code`/`cursor` (Homebrew) must never be found.
  export PATH="$BIN:/usr/bin:/bin"
  mkdir -p "$BIN" "$REPO/files/cursor" "$REPO/files/vscode"
  mkdir -p "$HOME/Library/Application Support/Cursor/User"
  mkdir -p "$HOME/Library/Application Support/Code/User"
}

# Create a stub editor CLI that answers --list-extensions with the given lines.
stub_cli() {
  local name="$1"; shift
  {
    echo '#!/bin/sh'
    echo '[ "$1" = "--list-extensions" ] || { echo "unexpected args: $*" >&2; exit 2; }'
    for ext in "$@"; do echo "echo '$ext'"; done
  } > "$BIN/$name"
  chmod +x "$BIN/$name"
}

@test "--check fails and writes nothing when Cursor has an extension the repo lacks" {
  stub_cli cursor anthropic.claude-code anysphere.remote-ssh
  stub_cli code
  printf 'anthropic.claude-code\n' > "$REPO/files/cursor/extensions.txt"

  run "$SCRIPT" --check

  [ "$status" -eq 1 ]
  [[ "$output" == *"cursor/extensions.txt"* ]]
  [ "$(cat "$REPO/files/cursor/extensions.txt")" = "anthropic.claude-code" ]
}

@test "--check fails and writes nothing when Cursor settings.json differs from the repo copy" {
  stub_cli cursor anthropic.claude-code
  stub_cli code
  printf 'anthropic.claude-code\n' > "$REPO/files/cursor/extensions.txt"
  printf '{ "editor.accessibilitySupport": "on" }\n' > "$HOME/Library/Application Support/Cursor/User/settings.json"
  printf '{}\n' > "$REPO/files/cursor/settings.json"

  run "$SCRIPT" --check

  [ "$status" -eq 1 ]
  [[ "$output" == *"cursor/settings.json"* ]]
  [ "$(cat "$REPO/files/cursor/settings.json")" = "{}" ]
}

@test "capture writes sorted extensions plus settings/keybindings so --check then passes" {
  stub_cli cursor zzz.last aaa.first
  stub_cli code golang.go
  printf '{ "a": 1 }\n' > "$HOME/Library/Application Support/Cursor/User/settings.json"
  printf '[]' > "$HOME/Library/Application Support/Cursor/User/keybindings.json"
  printf '{ "b": 2 }\n' > "$HOME/Library/Application Support/Code/User/settings.json"

  run "$SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(cat "$REPO/files/cursor/extensions.txt")" = $'aaa.first\nzzz.last' ]
  [ "$(cat "$REPO/files/cursor/settings.json")" = '{ "a": 1 }' ]
  [ "$(cat "$REPO/files/cursor/keybindings.json")" = '[]' ]
  [ "$(cat "$REPO/files/vscode/extensions.txt")" = 'golang.go' ]
  [ "$(cat "$REPO/files/vscode/settings.json")" = '{ "b": 2 }' ]
  [ ! -e "$REPO/files/vscode/keybindings.json" ]

  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
}

@test "an editor whose CLI is missing is skipped without failing or touching its repo files" {
  stub_cli cursor anthropic.claude-code
  # no `code` stub: VS Code is "not installed" on this fake machine
  printf 'anthropic.claude-code\n' > "$REPO/files/cursor/extensions.txt"
  printf 'golang.go\n' > "$REPO/files/vscode/extensions.txt"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vscode"*"skipping"* ]]
  [ "$(cat "$REPO/files/vscode/extensions.txt")" = 'golang.go' ]

  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
}
