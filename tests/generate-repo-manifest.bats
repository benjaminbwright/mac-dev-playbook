#!/usr/bin/env bats
# Tests for scripts/generate-repo-manifest.sh against a temp tree of fake repos.
# Run: bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
# GENERATE_REPO_MANIFEST=/path/to/script overrides the script under test.
SCRIPT="${GENERATE_REPO_MANIFEST:-$REPO_ROOT/scripts/generate-repo-manifest.sh}"

# refute_match PATTERN — fail if $output contains a line matching PATTERN.
# (A bare `! cmd` is NOT enforced by bats: bash skips the ERR trap for negated
# commands, so such a line can never fail a test. A function returning 1 can.)
refute_match() {
  if printf '%s\n' "$output" | grep -q -- "$1"; then
    echo "unexpected match for '$1' in output:" >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
}

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  mkdir -p "$HOME"
  # Keep git from reading the real user's config.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
}

teardown() {
  rm -rf "$TMP"
}

# make_repo DIR [REMOTE_URL] — create a git repo at DIR (under $HOME) with an
# optional origin remote.
make_repo() {
  local dir="$1" url="${2:-}"
  mkdir -p "$dir"
  git -C "$dir" init -q
  if [ -n "$url" ]; then
    git -C "$dir" remote add origin "$url"
  fi
}

@test "one repo with a remote yields a git_repositories entry with repo and dest relative to HOME" {
  make_repo "$HOME/projects/alpha" "git@github.com:acme/alpha.git"

  run "$SCRIPT" "$HOME/projects"

  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'git_repositories:'
  echo "$output" | grep -qx '  - repo: git@github.com:acme/alpha.git'
  echo "$output" | grep -qx '    dest: projects/alpha'
}

@test "a repo with no remote is skipped and reported on stderr" {
  make_repo "$HOME/projects/alpha" "git@github.com:acme/alpha.git"
  make_repo "$HOME/projects/local-only"

  run --separate-stderr "$SCRIPT" "$HOME/projects"

  [ "$status" -eq 0 ]
  echo "$output" | grep -qx '    dest: projects/alpha'
  refute_match 'local-only'
  echo "$stderr" | grep -q 'local-only'
  echo "$stderr" | grep -qi 'no remote'
}

@test "wt-* directories and linked worktrees (.git is a file) are skipped" {
  make_repo "$HOME/projects/alpha" "git@github.com:acme/alpha.git"
  git -C "$HOME/projects/alpha" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  # A named wt-* dir that is itself a full repo with a remote: skipped by name.
  make_repo "$HOME/projects/wt-feature" "git@github.com:acme/alpha.git"
  # A linked worktree of alpha (its .git is a file, not a directory).
  git -C "$HOME/projects/alpha" worktree add -q "$HOME/projects/alpha-hotfix" -b hotfix

  run "$SCRIPT" "$HOME/projects"

  [ "$status" -eq 0 ]
  echo "$output" | grep -qx '    dest: projects/alpha'
  refute_match 'wt-feature'
  refute_match 'alpha-hotfix'
  [ "$(echo "$output" | grep -c -- '- repo:')" -eq 1 ]
}

@test "entries are grouped under a comment per root, in argument order, with ~ for HOME" {
  make_repo "$HOME/projects/beta" "git@github.com:acme/beta.git"
  make_repo "$HOME/projects/alpha" "git@github.com:acme/alpha.git"
  make_repo "$HOME/sandbox/toy" "https://github.com/acme/toy.git"

  run "$SCRIPT" "$HOME/sandbox" "$HOME/projects"

  [ "$status" -eq 0 ]
  expected="$(cat <<'EOF'
git_repositories:
  # --- ~/sandbox ---
  - repo: https://github.com/acme/toy.git
    dest: sandbox/toy
  # --- ~/projects ---
  - repo: git@github.com:acme/alpha.git
    dest: projects/alpha
  - repo: git@github.com:acme/beta.git
    dest: projects/beta
EOF
)"
  [ "$(echo "$output" | grep -v '^#' | grep -v '^---$')" = "$expected" ]
}

@test "a missing root is reported on stderr, omitted from output, and does not fail the run" {
  make_repo "$HOME/projects/alpha" "git@github.com:acme/alpha.git"

  run --separate-stderr "$SCRIPT" "$HOME/does-not-exist" "$HOME/projects"

  [ "$status" -eq 0 ]
  echo "$stderr" | grep -q 'does-not-exist'
  refute_match 'does-not-exist'
  echo "$output" | grep -qx '    dest: projects/alpha'
}

@test "-o FILE writes the manifest to FILE and prints nothing on stdout" {
  make_repo "$HOME/projects/alpha" "git@github.com:acme/alpha.git"
  out="$TMP/repos.yml"

  run "$SCRIPT" -o "$out" "$HOME/projects"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qx '    dest: projects/alpha' "$out"
}

@test "output is a YAML document with a header comment that parses into a list of repo/dest maps" {
  make_repo "$HOME/projects/alpha" "git@github.com:acme/alpha.git"
  make_repo "$HOME/projects/beta" "https://github.com/acme/beta.git"

  run "$SCRIPT" "$HOME/projects"

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "---" ]
  [ "$(echo "$output" | grep -c '^# .*generate-repo-manifest.sh')" -ge 1 ]
  command -v yamllint >/dev/null || skip "yamllint not installed"
  echo "$output" | yamllint -d '{extends: default, rules: {document-start: disable}}' -
  # Structural check via ansible's YAML loader (ships with ansible).
  command -v ansible >/dev/null || skip "ansible not installed"
  echo "$output" > "$TMP/out.yml"
  run env ANSIBLE_BECOME=false ANSIBLE_NOCOLOR=1 \
    ansible localhost -c local -e "@$TMP/out.yml" -m debug \
    -a "msg={{ (git_repositories | length) ~ ':' ~ (git_repositories | map(attribute='repo') | join(',')) ~ ':' ~ (git_repositories | map(attribute='dest') | join(',')) }}"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '2:git@github.com:acme/alpha.git,https://github.com/acme/beta.git:projects/alpha,projects/beta'
}

@test "when no repos are found the list is an explicit empty list, not null" {
  mkdir -p "$HOME/projects/not-a-repo"

  run "$SCRIPT" "$HOME/projects"

  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'git_repositories: \[\]'
  refute_match '^git_repositories:$'
}

@test "with no arguments the default roots under HOME are scanned, missing ones skipped" {
  make_repo "$HOME/praxis-loop/site" "git@github.com:acme/site.git"
  make_repo "$HOME/Development/GitHub/dotfiles" "git@github.com:acme/dotfiles.git"
  make_repo "$HOME/active-git/tool" "git@github.com:acme/tool.git"
  make_repo "$HOME/sandbox/toy" "git@github.com:acme/toy.git"
  make_repo "$HOME/xpow/x" "git@github.com:acme/x.git"
  make_repo "$HOME/agent-avocado/a" "git@github.com:acme/a.git"
  make_repo "$HOME/elsewhere/ignored" "git@github.com:acme/ignored.git"

  run --separate-stderr "$SCRIPT"

  [ "$status" -eq 0 ]
  for d in praxis-loop/site Development/GitHub/dotfiles active-git/tool sandbox/toy xpow/x agent-avocado/a; do
    echo "$output" | grep -qx "    dest: $d"
  done
  refute_match 'elsewhere'
  [ "$(echo "$output" | grep -c -- '- repo:')" -eq 6 ]
}

@test "repos are found at most two levels deep, not inside other repos, and a root that is itself a repo is listed" {
  make_repo "$HOME/projects/alpha" "git@github.com:acme/alpha.git"
  make_repo "$HOME/projects/client/beta" "git@github.com:acme/beta.git"          # depth 2: listed
  make_repo "$HOME/projects/a/b/too-deep" "git@github.com:acme/too-deep.git"    # depth 3: not listed
  make_repo "$HOME/projects/alpha/vendor/nested" "git@github.com:acme/nested.git" # inside alpha: not listed
  make_repo "$HOME/vault" "git@github.com:acme/vault.git"                         # root is the repo: listed

  run "$SCRIPT" "$HOME/projects" "$HOME/vault"

  [ "$status" -eq 0 ]
  echo "$output" | grep -qx '    dest: projects/alpha'
  echo "$output" | grep -qx '    dest: projects/client/beta'
  echo "$output" | grep -qx '    dest: vault'
  refute_match 'too-deep'
  refute_match 'nested'
  [ "$(echo "$output" | grep -c -- '- repo:')" -eq 3 ]
}

@test "a repo outside HOME is skipped with a warning (dest must be HOME-relative)" {
  make_repo "$HOME/projects/alpha" "git@github.com:acme/alpha.git"
  make_repo "$TMP/outside/other" "git@github.com:acme/other.git"

  run --separate-stderr "$SCRIPT" "$HOME/projects" "$TMP/outside"

  [ "$status" -eq 0 ]
  echo "$output" | grep -qx '    dest: projects/alpha'
  refute_match 'outside/other'
  echo "$stderr" | grep -q 'outside/other'
  echo "$stderr" | grep -qi 'HOME'
}

@test "-h prints usage naming the options and default roots, and exits 0" {
  run "$SCRIPT" -h

  [ "$status" -eq 0 ]
  echo "$output" | grep -qi 'usage'
  echo "$output" | grep -q -- '-o FILE'
  echo "$output" | grep -q 'praxis-loop'
  refute_match 'git_repositories:'
}
