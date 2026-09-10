#!/usr/bin/env bats
# Tests for tasks/dotfiles-nested.yml, run through tests/dotfiles-nested-playbook.yml
# against a temporary HOME and a temporary fake dotfiles clone. The real ~ is
# never touched (HOME is overridden and become is off).

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  CLONE="$TMP/clone"
  mkdir -p "$HOME" "$CLONE/.ssh" "$CLONE/.warp/themes"
  printf 'Host example\n' > "$CLONE/.ssh/config"
  printf 'name: matrix\n' > "$CLONE/.warp/themes/matrix.yaml"
  # Deliberately NOT in the clone: .aws/config, .cursor/mcp.json, etc.

  export ANSIBLE_CONFIG="$REPO_ROOT/ansible.cfg"
  export ANSIBLE_BECOME=False
  export ANSIBLE_STDOUT_CALLBACK=default
  export ANSIBLE_LOCALHOST_WARNING=False
  export ANSIBLE_INVENTORY_UNPARSED_WARNING=False
  export ANSIBLE_LOCAL_TEMP="$TMP/ansible-tmp"
}

teardown() {
  rm -rf "$TMP"
}

run_playbook() {
  run ansible-playbook -i localhost, "$REPO_ROOT/tests/dotfiles-nested-playbook.yml" \
    -e "dotfiles_repo_local_destination=$CLONE"
}

@test "links nested dotfiles that exist in the clone into HOME, creating parent dirs" {
  run_playbook
  echo "$output"

  [ "$status" -eq 0 ]
  [ -L "$HOME/.ssh/config" ]
  [ "$HOME/.ssh/config" -ef "$CLONE/.ssh/config" ]
  [ -L "$HOME/.warp/themes/matrix.yaml" ]
  [ "$(cat "$HOME/.warp/themes/matrix.yaml")" = "name: matrix" ]
  # ~/.ssh must stay private.
  [ "$(stat -f %Lp "$HOME/.ssh")" = "700" ]
}

@test "skips nested dotfiles that are not in the clone (no dangling links, no stray dirs)" {
  run_playbook

  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.aws/config" ]
  [ ! -L "$HOME/.aws/config" ]
  [ ! -d "$HOME/.aws" ]
}

@test "is idempotent: a second run reports no changes" {
  run_playbook
  [ "$status" -eq 0 ]

  run_playbook
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed=0"* ]]
}

@test "replaces an existing plain file in HOME with the link (like the dotfiles role does)" {
  mkdir -p "$HOME/.ssh"
  printf 'Host stale\n' > "$HOME/.ssh/config"

  run_playbook

  [ "$status" -eq 0 ]
  [ -L "$HOME/.ssh/config" ]
  [ "$(cat "$HOME/.ssh/config")" = "Host example" ]
}
