#!/usr/bin/env bats
# main.yml loads an optional git_repositories manifest from
# <dotfiles_repo_local_destination>/repos.yml. These tests drive the playbook in
# --check mode only (nothing is cloned or written), pointing the dotfiles
# location at a temp dir. Needs the Galaxy roles from requirements.yml on the
# roles path (ansible-galaxy install -r requirements.yml), otherwise skipped.
# Run: bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# refute_match PATTERN — fail if $output contains a line matching PATTERN.
# (A bare `! cmd` is not enforced by bats; a function returning 1 is.)
refute_match() {
  if printf '%s\n' "$output" | grep -q -- "$1"; then
    echo "unexpected match for '$1' in output" >&2
    return 1
  fi
}

setup() {
  TMP="$(mktemp -d)"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export ANSIBLE_CONFIG="$REPO_ROOT/ansible.cfg"
  export ANSIBLE_ROLES_PATH="$REPO_ROOT/roles:$REPO_ROOT/.ansible/roles:$HOME/.ansible/roles:/etc/ansible/roles"
  export ANSIBLE_NOCOLOR=1
  command -v ansible-playbook >/dev/null || skip "ansible-playbook not installed"
  ansible-playbook "$REPO_ROOT/main.yml" --syntax-check >/dev/null 2>&1 \
    || skip "Galaxy roles not on the roles path (ansible-galaxy install -r requirements.yml)"

  DOTFILES="$TMP/dotfiles"
  mkdir -p "$DOTFILES"
  # A local repo with one commit stands in for a GitHub remote.
  UPSTREAM="$TMP/upstream"
  mkdir -p "$UPSTREAM"
  git -C "$UPSTREAM" init -q
  git -C "$UPSTREAM" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  # Sentinel dest that must never appear on disk (check mode).
  DEST="mac-dev-playbook-manifest-test-$$"
}

teardown() {
  rm -rf "$TMP"
  [ ! -e "$HOME/$DEST" ]
}

run_repos_check() {
  # --skip-tags secrets: that task clones a private GitHub repo over SSH, which
  # a CI runner can't reach (and this test is about the manifest, not secrets).
  # configure_dotfiles=false: the test supplies the "clone" dir itself, so the
  # real dotfiles repo (private, over SSH) must not be fetched.
  run ansible-playbook "$REPO_ROOT/main.yml" --check --tags repos --skip-tags secrets \
    -e '{"ansible_become": false, "configure_dotfiles": false}' \
    -e "dotfiles_repo_local_destination=$DOTFILES"
}

@test "repos.yml in the dotfiles clone feeds git_repositories to the clone task" {
  cat > "$DOTFILES/repos.yml" <<EOF
---
git_repositories:
  - repo: $UPSTREAM
    dest: $DEST
EOF

  run_repos_check

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "item=$DEST"
  echo "$output" | grep -Eq 'failed=0'
}

@test "the playbook does not fail when the dotfiles clone has no repos.yml" {
  [ ! -e "$DOTFILES/repos.yml" ]

  run_repos_check

  [ "$status" -eq 0 ]
  refute_match "item=$DEST"
  echo "$output" | grep -Eq 'failed=0'
}


@test "the dotfiles repo is cloned before the manifest is read, under --tags repos" {
  run ansible-playbook "$REPO_ROOT/main.yml" --list-tasks --tags repos
  [ "$status" -eq 0 ]
  clone_line=$(echo "$output" | grep -n "Ensure the dotfiles repo is cloned" | head -1 | cut -d: -f1)
  manifest_line=$(echo "$output" | grep -n "Include the repo manifest from the dotfiles clone" | head -1 | cut -d: -f1)
  [ -n "$clone_line" ] && [ -n "$manifest_line" ]
  [ "$clone_line" -lt "$manifest_line" ]
}
