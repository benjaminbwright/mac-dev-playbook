#!/usr/bin/env bats
# Checks that default.config.yml declares the Homebrew packages, taps, and casks
# this playbook is expected to install. Run with: bats tests/

setup() {
  CONFIG="$BATS_TEST_DIRNAME/../default.config.yml"
}

# Print each item of a top-level list variable in default.config.yml, one per line.
config_list() {
  python3 - "$CONFIG" "$1" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
for item in data.get(sys.argv[2], []):
    print(item)
PY
}

# Usage: assert_declared <list-variable> <item>...
assert_declared() {
  local key="$1"; shift
  local declared
  declared="$(config_list "$key")"
  local missing=()
  for want in "$@"; do
    grep -qxF -- "$want" <<<"$declared" || missing+=("$want")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "missing from $key: ${missing[*]}"
    return 1
  fi
}

@test "homebrew_installed_packages declares formulae installed on the current Mac" {
  assert_declared homebrew_installed_packages \
    caddy mongosh node@16 pipx grahamplata/tap/roku-remote
}

@test "homebrew_taps declares the tap backing roku-remote" {
  assert_declared homebrew_taps grahamplata/tap
}

@test "homebrew_cask_apps declares casks installed on the current Mac" {
  assert_declared homebrew_cask_apps thunderbird roku-remote-tool
}
