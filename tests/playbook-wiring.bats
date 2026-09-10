#!/usr/bin/env bats
# Checks that main.yml wires in the nested-dotfiles tasks under the dotfiles
# tag. Uses --list-tasks only (never runs the playbook). Needs the galaxy roles
# to resolve; set ANSIBLE_ROLES_PATH or install them to ./roles.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export ANSIBLE_CONFIG="$REPO_ROOT/ansible.cfg"
  export ANSIBLE_STDOUT_CALLBACK=default
  if [ -z "${ANSIBLE_ROLES_PATH:-}" ] && [ ! -d "$REPO_ROOT/roles/geerlingguy.dotfiles" ]; then
    # Fall back to the main checkout's roles dir when testing from a worktree.
    local main_roles="$REPO_ROOT/../../../roles"
    [ -d "$main_roles/geerlingguy.dotfiles" ] && export ANSIBLE_ROLES_PATH="$(cd "$main_roles" && pwd)"
  fi
  if [ -z "${ANSIBLE_ROLES_PATH:-}" ] && [ ! -d "$REPO_ROOT/roles/geerlingguy.dotfiles" ]; then
    skip "galaxy roles not installed (ansible-galaxy install -r requirements.yml)"
  fi
}

@test "main.yml runs the nested-dotfiles tasks under --tags dotfiles" {
  run ansible-playbook "$REPO_ROOT/main.yml" --list-tasks --tags dotfiles
  echo "$output"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Link nested dotfiles into the home folder"* ]]
}

@test "main.yml passes --syntax-check" {
  run ansible-playbook "$REPO_ROOT/main.yml" --syntax-check
  echo "$output"

  [ "$status" -eq 0 ]
}
