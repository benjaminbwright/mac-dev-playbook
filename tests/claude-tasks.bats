#!/usr/bin/env bats
# End-to-end check of tasks/claude.yml via tests/claude-tasks.yml: a throwaway HOME,
# a fake dotfiles clone, and fake `npx` / `claude` binaries that only log their args.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  DF="$TMP/dotfiles"
  mkdir -p "$HOME/proj" "$DF/claude/skills/descript-cut" "$DF/pi/agent" "$TMP/bin"
  echo '{"model":"opus"}' > "$DF/claude/settings.json"
  echo '{"permissions":{}}' > "$DF/claude/settings.local.json"
  echo '{"customApiKeyResponses":{}}' > "$DF/claude/config.json"
  echo '{"version":3,"skills":{"tdd":{"source":"mattpocock/skills"}}}' > "$DF/claude/skill-lock.json"
  echo "# descript-cut" > "$DF/claude/skills/descript-cut/SKILL.md"
  echo '{"defaultProvider":"anthropic"}' > "$DF/pi/agent/settings.json"

  NPX_LOG="$TMP/npx.log"
  CLAUDE_LOG="$TMP/claude.log"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$NPX_LOG" > "$TMP/bin/npx"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n[ "$1 $2" = "plugin list" ] && echo "Installed plugins:"\nexit 0\n' "$CLAUDE_LOG" > "$TMP/bin/claude"
  chmod +x "$TMP/bin/npx" "$TMP/bin/claude"
  export PATH="$TMP/bin:$PATH"
}

teardown() {
  rm -rf "$TMP"
}

run_play() {
  cd "$REPO" && ansible-playbook -i localhost, tests/claude-tasks.yml \
    -e "test_home=$HOME" -e "test_df=$DF" "$@"
}

@test "restores settings, lock-file skills, hand-made skills, Pi settings and plugins" {
  run run_play
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.claude/settings.json")" = '{"model":"opus"}' ]
  [ "$(cat "$HOME/.claude/skills/descript-cut/SKILL.md")" = "# descript-cut" ]
  grep -qx -- "-y skills add mattpocock/skills -g -y -a claude-code -a pi --skill tdd" "$NPX_LOG"
  [ "$(cat "$HOME/.pi/agent/settings.json")" = '{"defaultProvider":"anthropic"}' ]
  grep -qx -- "plugin install gopls-lsp@claude-plugins-official --scope user" "$CLAUDE_LOG"
  grep -qx -- "plugin install figma@claude-plugins-official --scope project" "$CLAUDE_LOG"
}

@test "a snapshot without lock file / Pi settings / project dir still succeeds" {
  rm -f "$DF/claude/skill-lock.json" "$DF/pi/agent/settings.json"
  rmdir "$HOME/proj"
  run run_play
  [ "$status" -eq 0 ]
  [ ! -e "$NPX_LOG" ]
  [ ! -e "$HOME/.pi/agent/settings.json" ]
  ! grep -q "figma" "$CLAUDE_LOG"
  grep -qx -- "plugin install gopls-lsp@claude-plugins-official --scope user" "$CLAUDE_LOG"
}

@test "does not reinstall plugins that 'claude plugin list' already shows" {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n[ "$1 $2" = "plugin list" ] && printf "Installed plugins:\\n  gopls-lsp@claude-plugins-official\\n  figma@claude-plugins-official\\n"\nexit 0\n' "$CLAUDE_LOG" > "$TMP/bin/claude"
  run run_play
  [ "$status" -eq 0 ]
  ! grep -q "plugin install" "$CLAUDE_LOG"
}
