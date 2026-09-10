#!/usr/bin/env bats
# Structural tests for the language-toolchain provisioning (issue #6).
#
# Run from the repo root:   bats tests/
# `ansible-playbook --list-tasks` needs the galaxy roles resolvable; if they are
# not in ./roles, point ANSIBLE_ROLES_PATH at a directory that has them.

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  cd "$REPO" || exit 1
}

# Print a top-level key of default.config.yml as compact JSON.
config_json() {
  python3 - "$1" <<'PY'
import json, sys, yaml
with open("default.config.yml") as fh:
    data = yaml.safe_load(fh)
print(json.dumps(data.get(sys.argv[1]), sort_keys=True))
PY
}

# Print field $2 of every entry in list $1 of default.config.yml, sorted,
# space-separated (plain string entries are printed as-is).
config_field_list() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
with open("default.config.yml") as fh:
    items = yaml.safe_load(fh).get(sys.argv[1]) or []
print(" ".join(sorted(str(i[sys.argv[2]]) if isinstance(i, dict) else str(i) for i in items)))
PY
}

# Task names selected by the toolchains tag.
toolchains_tasks() {
  ansible-playbook main.yml --list-tasks --tags toolchains
}

@test "nvm: toolchains tag installs Node via nvm and pins the default alias" {
  run toolchains_tasks
  [ "$status" -eq 0 ]
  [[ "$output" == *"Install Node versions via nvm."* ]]
  [[ "$output" == *"Set the default nvm Node version."* ]]
}

@test "nvm: config trims Node to 20 LTS + 24 with 20 as default" {
  [ "$(config_json nvm_node_versions)" = '["20", "24"]' ]
  [ "$(config_json nvm_default_node)" = '"20"' ]
}

@test "pyenv: toolchains tag installs Python via pyenv and sets the global" {
  run toolchains_tasks
  [ "$status" -eq 0 ]
  [[ "$output" == *"Install Python versions via pyenv."* ]]
  [[ "$output" == *"Set the global pyenv Python."* ]]
}

@test "pyenv: config declares 3.10.13 as the only and global Python" {
  [ "$(config_json pyenv_python_versions)" = '["3.10.13"]' ]
  [ "$(config_json pyenv_global_python)" = '"3.10.13"' ]
}

@test "go: toolchains tag installs Go tools with go install" {
  run toolchains_tasks
  [ "$status" -eq 0 ]
  [[ "$output" == *"Install Go tools (go install)."* ]]
}

@test "go: config lists the nine go-installed tools with their module paths" {
  [ "$(config_field_list go_packages name)" = \
    "amtool go-jsonschema goimports golangci-lint gopls gosec govulncheck protoc-gen-go staticcheck" ]
  [[ "$(config_json go_packages)" == *'"module": "golang.org/x/tools/gopls"'* ]]
  [[ "$(config_json go_packages)" == *'"module": "github.com/golangci/golangci-lint/v2/cmd/golangci-lint"'* ]]
}

@test "cargo: toolchains tag installs Rust crates with cargo install" {
  run toolchains_tasks
  [ "$status" -eq 0 ]
  [[ "$output" == *"Install Rust crates (cargo install)."* ]]
}

@test "cargo: config lists mdbook and wasm-pack" {
  [ "$(config_field_list cargo_packages name)" = "mdbook wasm-pack" ]
}

@test "pipx: toolchains tag ensures pipx exists and installs pipx apps" {
  run toolchains_tasks
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ensure pipx is installed (Homebrew, tolerant)."* ]]
  [[ "$output" == *"Install pipx apps."* ]]
}

@test "pipx: config lists ansible-lint and yamllint" {
  [ "$(config_field_list pipx_packages name)" = "ansible-lint yamllint" ]
}

@test "npm: toolchains tag installs global npm packages under nvm's default Node" {
  run toolchains_tasks
  [ "$status" -eq 0 ]
  [[ "$output" == *"Install global npm packages (nvm default Node)."* ]]
}

@test "npm: config lists @playwright/mcp only (issue-duck is a local npm link)" {
  [ "$(config_json nvm_npm_global_packages)" = '["@playwright/mcp"]' ]
}

@test "pip: toolchains tag installs Homebrew-Python pip packages" {
  run toolchains_tasks
  [ "$status" -eq 0 ]
  [[ "$output" == *"Install Homebrew Python pip packages (--break-system-packages)."* ]]
}

@test "pip: config lists pypdf, pillow, Jinja2 and PyYAML" {
  [ "$(config_field_list brew_pip_packages name)" = "Jinja2 PyYAML pillow pypdf" ]
}

@test "pnpm: toolchains tag has an opt-in pnpm setup task, off by default" {
  run toolchains_tasks
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run pnpm setup (opt-in)."* ]]
  [ "$(config_json toolchains_pnpm_setup)" = 'false' ]
}

@test "docs: NEW-MAC.md has a Language toolchains section that names the tag" {
  grep -q '^## Language toolchains' NEW-MAC.md
  section="$(sed -n '/^## Language toolchains/,/^## /p' NEW-MAC.md)"
  [[ "$section" == *"--tags toolchains"* ]]
  [[ "$section" == *"nvm"* && "$section" == *"pyenv"* && "$section" == *"pipx"* ]]
}
