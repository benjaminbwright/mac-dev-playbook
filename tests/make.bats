#!/usr/bin/env bats
# The Makefile is a thin front door: `make audit` runs scripts/audit.sh,
# `make lint` runs the CI linters, `make test` runs these bats tests.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "make -n audit runs scripts/audit.sh" {
  run make -n -C "$REPO_ROOT" audit
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/audit.sh"* ]]
}

@test "make -n lint runs yamllint and ansible-lint" {
  run make -n -C "$REPO_ROOT" lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"yamllint"* ]]
  [[ "$output" == *"ansible-lint"* ]]
}

@test "make -n test runs bats over tests/" {
  run make -n -C "$REPO_ROOT" test
  [ "$status" -eq 0 ]
  [[ "$output" == *"bats"*"tests"* ]]
}
