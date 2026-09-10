#!/usr/bin/env bats
# Behavioural tests for scripts/guard-shell-rc.sh, which rewrites a shell rc
# file so PATH/source/alias lines for installer-based CLIs are guarded and a
# missing tool can never break a fresh shell. Every test works on a temp copy.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/guard-shell-rc.sh"
  RC="$BATS_TEST_TMPDIR/zshrc"
}

@test "wraps a standalone tool PATH line in a [ -d ] guard" {
  printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' > "$RC"
  run "$SCRIPT" "$RC"
  [ "$status" -eq 0 ]
  run cat "$RC"
  [ "$output" = '[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"' ]
}

@test "splits a tool dir out of a compound PATH line so other dirs survive" {
  # Shape of the real .zshrc line: brew + misc dirs + pocket-server + $PATH.
  printf '%s\n' 'export PATH=/opt/homebrew/bin:/usr/local/bin:$HOME/bin:$HOME/.pocket-server/bin:$PATH' > "$RC"
  run "$SCRIPT" "$RC"
  [ "$status" -eq 0 ]
  run cat "$RC"
  [ "${lines[0]}" = '[ -d "$HOME/.pocket-server/bin" ] && export PATH="$HOME/.pocket-server/bin:$PATH"' ]
  [ "${lines[1]}" = 'export PATH=/opt/homebrew/bin:/usr/local/bin:$HOME/bin:$PATH' ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "guards a source line for a tool env file with [ -f ]" {
  printf '%s\n' 'source ~/.limbo/env' '. "$HOME/.limbo/env"' > "$RC"
  run "$SCRIPT" "$RC"
  [ "$status" -eq 0 ]
  run cat "$RC"
  [ "${lines[0]}" = '[ -f "$HOME/.limbo/env" ] && source ~/.limbo/env' ]
  [ "${lines[1]}" = '[ -f "$HOME/.limbo/env" ] && . "$HOME/.limbo/env"' ]
}

# A realistic rc file: what the tracked .zshrc looks like around these tools.
write_realistic_rc() {
  printf '%s\n' \
    '# Path' \
    'export PATH=/opt/homebrew/bin:/usr/local/bin:$HOME/bin:$HOME/go/bin:$HOME/.pocket-server/bin:$PATH' \
    '' \
    '# Limbo env (only if present on this machine).' \
    '[ -f "$HOME/.limbo/env" ] && . "$HOME/.limbo/env"' \
    'source ~/.limbo/env' \
    '' \
    '# Pocket-server aliases to always use port 9876' \
    "alias pocket-server-start='pocket-server start --port 9876'" \
    "alias pocket-server-pair='pocket-server pair --port 9876'" \
    '[ -f ~/.zshrc.local ] && source ~/.zshrc.local' \
    > "$1"
}

@test "running twice changes nothing (idempotent)" {
  write_realistic_rc "$RC"
  run "$SCRIPT" "$RC"
  [ "$status" -eq 0 ]
  cp "$RC" "$BATS_TEST_TMPDIR/after-first-run"
  run "$SCRIPT" "$RC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no changes"* ]]
  cmp "$RC" "$BATS_TEST_TMPDIR/after-first-run"
}

@test "leaves lines it does not recognise untouched" {
  printf '%s\n' \
    '# export PATH=$HOME/.local/bin:$PATH   (commented out)' \
    'export PATH="$HOME/go/bin:$PATH"' \
    'export CODEX_PATH=$HOME/.local/bin' \
    'source ~/.nvm/nvm.sh' \
    'if [ -d "$HOME/.local/bin" ]; then PATH="$HOME/.local/bin:$PATH"; fi' \
    "alias ll='ls -la'" \
    'eval "$(/opt/homebrew/bin/brew shellenv)"' \
    > "$RC"
  cp "$RC" "$BATS_TEST_TMPDIR/original"
  run "$SCRIPT" "$RC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no changes"* ]]
  cmp "$RC" "$BATS_TEST_TMPDIR/original"
}

@test "writes <file>.bak of the original once and never overwrites it" {
  write_realistic_rc "$RC"
  cp "$RC" "$BATS_TEST_TMPDIR/original"
  run "$SCRIPT" "$RC"
  [ "$status" -eq 0 ]
  cmp "$RC.bak" "$BATS_TEST_TMPDIR/original"
  # A later edit adds another unguarded line; the second run must keep the
  # very first backup rather than replacing it with the half-guarded file.
  printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' >> "$RC"
  run "$SCRIPT" "$RC"
  [ "$status" -eq 0 ]
  [[ "$output" == *"guarded 1 line"* ]]
  cmp "$RC.bak" "$BATS_TEST_TMPDIR/original"
}

@test "guards aliases that invoke an installer-based CLI with command -v" {
  printf '%s\n' \
    "alias pocket-server-start='pocket-server start --port 9876'" \
    "alias pocket-server-pair='pocket-server pair --port 9876'" \
    > "$RC"
  run "$SCRIPT" "$RC"
  [ "$status" -eq 0 ]
  run cat "$RC"
  [ "${lines[0]}" = "command -v pocket-server >/dev/null 2>&1 && alias pocket-server-start='pocket-server start --port 9876'" ]
  [ "${lines[1]}" = "command -v pocket-server >/dev/null 2>&1 && alias pocket-server-pair='pocket-server pair --port 9876'" ]
}
