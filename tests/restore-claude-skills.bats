#!/usr/bin/env bats
# Exercises scripts/restore-claude-skills.sh with a fake HOME and a fake `npx` that
# records its arguments instead of installing anything.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO/scripts/restore-claude-skills.sh"
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude/skills" "$TMP/bin"
  NPX_LOG="$TMP/npx.log"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$NPX_LOG" > "$TMP/bin/npx"
  chmod +x "$TMP/bin/npx"
  export PATH="$TMP/bin:$PATH"
  LOCK="$TMP/skill-lock.json"
  cat > "$LOCK" <<'JSON'
{
  "version": 3,
  "skills": {
    "tdd":         { "source": "mattpocock/skills",  "sourceType": "github" },
    "grill-me":    { "source": "mattpocock/skills",  "sourceType": "github" },
    "find-skills": { "source": "vercel-labs/skills", "sourceType": "github" }
  }
}
JSON
}

teardown() {
  rm -rf "$TMP"
}

@test "installs every lock-file skill missing from ~/.claude/skills, one npx call per source" {
  run "$SCRIPT" "$LOCK"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$NPX_LOG" | tr -d ' ')" = "2" ]
  grep -qx -- "-y skills add mattpocock/skills -g -y -a claude-code -a pi --skill grill-me --skill tdd" "$NPX_LOG"
  grep -qx -- "-y skills add vercel-labs/skills -g -y -a claude-code -a pi --skill find-skills" "$NPX_LOG"
  [[ "$output" == *"mattpocock/skills"* ]]
}

@test "skips skills already present in ~/.claude/skills (no npx call when all present)" {
  mkdir -p "$HOME/.agents/skills/tdd" "$HOME/.agents/skills/grill-me" "$HOME/.agents/skills/find-skills"
  ln -s ../../.agents/skills/tdd "$HOME/.claude/skills/tdd"
  ln -s ../../.agents/skills/find-skills "$HOME/.claude/skills/find-skills"
  run "$SCRIPT" "$LOCK"
  [ "$status" -eq 0 ]
  grep -qx -- "-y skills add mattpocock/skills -g -y -a claude-code -a pi --skill grill-me" "$NPX_LOG"
  [ "$(wc -l < "$NPX_LOG" | tr -d ' ')" = "1" ]

  ln -s ../../.agents/skills/grill-me "$HOME/.claude/skills/grill-me"
  run "$SCRIPT" "$LOCK"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$NPX_LOG" | tr -d ' ')" = "1" ]
  [ -z "$output" ]
}

@test "--agents overrides the agent list" {
  run "$SCRIPT" "$LOCK" --agents claude-code
  [ "$status" -eq 0 ]
  grep -qx -- "-y skills add vercel-labs/skills -g -y -a claude-code --skill find-skills" "$NPX_LOG"
}

@test "fails clearly when the lock file is missing" {
  run "$SCRIPT" "$TMP/missing.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$TMP/missing.json"* ]]
  [ ! -e "$NPX_LOG" ]
}
