#!/usr/bin/env bats
# The geerlingguy.dotfiles role removes ~/<file> BEFORE linking it and then fails
# when the clone lacks the source. main.yml must therefore only hand the role the
# files the clone actually has, so a stale snapshot can never delete live rc files.

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/dotfiles-guard.XXXXXX")"
  export ANSIBLE_CONFIG="$REPO/ansible.cfg"
  export ANSIBLE_ROLES_PATH="$REPO/roles:$REPO/.ansible/roles:$HOME/.ansible/roles"
  export ANSIBLE_LOCAL_TEMP="$TMP/ansible-tmp"
  export ANSIBLE_REMOTE_TEMP="$TMP/ansible-tmp"
  command -v ansible-playbook >/dev/null || skip "ansible-playbook not installed"
  (cd "$REPO" && ansible-playbook main.yml --syntax-check >/dev/null 2>&1) \
    || skip "Galaxy roles not on the roles path (ansible-galaxy install -r requirements.yml)"

  # A "dotfiles repo" that only contains .zshrc.
  mkdir -p "$TMP/src" "$TMP/home"
  git -C "$TMP/src" init -q -b main
  echo 'export FROM_DOTFILES=1' > "$TMP/src/.zshrc"
  # main.yml include_vars this file from the clone; it's how the test sets the
  # dotfiles list (extra-vars would out-rank the guard's set_fact).
  printf 'dotfiles_files:\n  - .zshrc\n  - .bashrc\n' > "$TMP/src/repos.yml"
  git -C "$TMP/src" add .zshrc repos.yml
  git -C "$TMP/src" -c user.email=t@example.com -c user.name=t commit -q -m 'add zshrc'
  git clone -q --bare "$TMP/src" "$TMP/origin.git"
  git clone -q "$TMP/origin.git" "$TMP/clone"

  # Live home: both are regular files whose content must not be lost.
  echo 'live zshrc' > "$TMP/home/.zshrc"
  echo 'live bashrc' > "$TMP/home/.bashrc"
}

teardown() { rm -rf "$TMP"; }

run_dotfiles_tag() {
  cd "$REPO" && ansible-playbook main.yml --tags dotfiles -i localhost, -c local \
    -e '{"ansible_become": false, "configure_dotfiles": true, "dotfiles_repo_accept_hostkey": false}' \
    -e "dotfiles_repo=$TMP/origin.git" \
    -e "dotfiles_repo_local_destination=$TMP/clone" \
    -e dotfiles_repo_version=main \
    -e "dotfiles_home=$TMP/home" \
    -e '{"dotfiles_nested_files": []}'
}

@test "dotfiles missing from the clone are skipped with a warning, never deleted" {
  run run_dotfiles_tag
  echo "$output" | tail -30
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing from"* && "$output" == *".bashrc"* ]]
  [ -f "$TMP/home/.bashrc" ] && [ ! -L "$TMP/home/.bashrc" ]
  [ "$(cat "$TMP/home/.bashrc")" = "live bashrc" ]
}

@test "dotfiles present in the clone are still linked" {
  run run_dotfiles_tag
  [ "$status" -eq 0 ]
  [ -L "$TMP/home/.zshrc" ]
  [ "$(readlink "$TMP/home/.zshrc")" = "$TMP/clone/.zshrc" ]
}
