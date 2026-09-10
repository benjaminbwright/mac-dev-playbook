#!/usr/bin/env bats
# Exercises scripts/capture-claude.sh against a fake HOME and a fake dotfiles clone.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO/scripts/capture-claude.sh"
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  DF="$TMP/dotfiles"
  mkdir -p "$HOME/.claude" "$DF/claude"
  echo '{"model":"opus"}' > "$HOME/.claude/settings.json"
  echo '{"permissions":{}}' > "$HOME/.claude/settings.local.json"
  echo '{"customApiKeyResponses":{}}' > "$HOME/.claude/config.json"
}

teardown() {
  rm -rf "$TMP"
}

@test "copies the three ~/.claude settings files into <dotfiles>/claude" {
  run "$SCRIPT" "$DF"
  [ "$status" -eq 0 ]
  [ "$(cat "$DF/claude/settings.json")" = '{"model":"opus"}' ]
  [ "$(cat "$DF/claude/settings.local.json")" = '{"permissions":{}}' ]
  [ "$(cat "$DF/claude/config.json")" = '{"customApiKeyResponses":{}}' ]
  [[ "$output" == *"settings.json"* ]]
}

@test "snapshots ~/.agents/.skill-lock.json as claude/skill-lock.json" {
  mkdir -p "$HOME/.agents"
  echo '{"version":3,"skills":{}}' > "$HOME/.agents/.skill-lock.json"
  run "$SCRIPT" "$DF"
  [ "$status" -eq 0 ]
  [ "$(cat "$DF/claude/skill-lock.json")" = '{"version":3,"skills":{}}' ]
}

# Mirrors the live layout: ~/.claude/skills/<name> -> ../../.agents/skills/<name>
# for CLI-managed skills; hand-made skills are either a real dir in ~/.claude/skills
# or a symlink to a real dir in ~/.agents/skills that the lock file doesn't know.
make_skills_fixture() {
  mkdir -p "$HOME/.agents/skills/tdd" "$HOME/.agents/skills/issue-train" \
           "$HOME/.claude/skills/descript-cut"
  echo "# tdd" > "$HOME/.agents/skills/tdd/SKILL.md"
  echo "# issue-train" > "$HOME/.agents/skills/issue-train/SKILL.md"
  echo "# descript-cut" > "$HOME/.claude/skills/descript-cut/SKILL.md"
  ln -s ../../.agents/skills/tdd "$HOME/.claude/skills/tdd"
  ln -s ../../.agents/skills/issue-train "$HOME/.claude/skills/issue-train"
  echo '{"version":3,"skills":{"tdd":{"source":"mattpocock/skills"}}}' > "$HOME/.agents/.skill-lock.json"
}

@test "copies hand-made skills (not in the lock) and skips lock-managed ones" {
  make_skills_fixture
  run "$SCRIPT" "$DF"
  [ "$status" -eq 0 ]
  [ "$(cat "$DF/claude/skills/descript-cut/SKILL.md")" = "# descript-cut" ]
  [ "$(cat "$DF/claude/skills/issue-train/SKILL.md")" = "# issue-train" ]
  [ ! -L "$DF/claude/skills/issue-train" ]
  [ ! -e "$DF/claude/skills/tdd" ]
}

@test "reports (but does not delete) snapshot skill dirs that are now lock-managed" {
  make_skills_fixture
  mkdir -p "$DF/claude/skills/tdd"
  echo "stale copy" > "$DF/claude/skills/tdd/SKILL.md"
  run "$SCRIPT" "$DF"
  [ "$status" -eq 0 ]
  [ "$(cat "$DF/claude/skills/tdd/SKILL.md")" = "stale copy" ]
  [[ "$output" == *"stale"* ]]
  [[ "$output" == *"git -C $DF rm -r claude/skills/tdd"* ]]
}

@test "snapshots ~/.pi/agent/settings.json under pi/agent/ but never ~/.claude.json" {
  mkdir -p "$HOME/.pi/agent"
  echo '{"defaultProvider":"anthropic"}' > "$HOME/.pi/agent/settings.json"
  echo '{"oauthAccount":{"token":"SECRET"}}' > "$HOME/.claude.json"
  run "$SCRIPT" "$DF"
  [ "$status" -eq 0 ]
  [ "$(cat "$DF/pi/agent/settings.json")" = '{"defaultProvider":"anthropic"}' ]
  ! grep -r "SECRET" "$DF"
  [[ "$output" == *".claude.json"*"hand-carr"* ]]
}

@test "--help prints usage and writes nothing" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [ ! -e "$DF/claude/settings.json" ]
}

@test "fails clearly when the dotfiles dir is not a directory" {
  run "$SCRIPT" "$TMP/nope"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$TMP/nope"* ]]
}

@test "second run is a no-op (idempotent)" {
  make_skills_fixture
  "$SCRIPT" "$DF" > /dev/null
  run "$SCRIPT" "$DF"
  [ "$status" -eq 0 ]
  [[ "$output" != *"copied"* ]]
  [[ "$output" != *"synced"* ]]
  [[ "$output" == *"same   $DF/claude/settings.json"* ]]
}
