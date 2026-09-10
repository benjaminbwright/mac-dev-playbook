#!/usr/bin/env bats
# The db-restore task file is wired into main.yml behind tags ['db-restore',
# 'never']: reachable with --tags db-restore, absent from a default run.
# Requires the galaxy roles (ansible-galaxy role install -r requirements.yml
# -p ./roles) so ansible-playbook can parse main.yml; the playbook is never
# executed here — only listed.
load test_helper

setup() {
  command -v ansible-playbook >/dev/null || skip "ansible-playbook not installed"
  [ -d "$REPO_ROOT/roles" ] || skip "galaxy roles not installed under ./roles"
  cd "$REPO_ROOT"
}

@test "playbook: --tags db-restore lists the restore task" {
  run ansible-playbook main.yml --list-tasks --tags db-restore
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restore local databases"*"TAGS: [db-restore, never]"* ]]
}

@test "playbook: a default run does not include the restore task" {
  run ansible-playbook main.yml --list-tasks
  [ "$status" -eq 0 ]
  [[ "$output" != *"Restore local databases"* ]]
}

@test "playbook: config declares db_dump_dir and db_docker_volumes" {
  grep -Eq '^db_dump_dir:' default.config.yml
  grep -Eq '^db_docker_volumes:' default.config.yml
}
