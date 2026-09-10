#!/usr/bin/env bats
# Tests for scripts/db-restore.sh. All db/docker tools are PATH stubs (see
# test_helper.bash) — nothing here touches real databases or Docker.
load test_helper

setup() {
  setup_stub_env
  DIR="$BATS_TEST_TMPDIR/dump"
}

@test "restore: refuses to run without an explicit --dir" {
  stub_all_restore_tools
  run "$RESTORE" --yes
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--dir"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "restore: a --dir that does not exist is an error" {
  stub_all_restore_tools
  run "$RESTORE" --dir "$DIR/nope" --yes
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
  [ ! -s "$STUB_LOG" ]
}

@test "restore: without --yes it only prints the plan and touches nothing" {
  stub_all_restore_tools
  make_dump_layout "$DIR" vol_a
  run "$RESTORE" --dir "$DIR"
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [[ "$output" == *"mysql-all-databases.sql"* ]]
  [[ "$output" == *"postgres-all.sql"* ]]
  [[ "$output" == *"mongodb/"* ]]
  [[ "$output" == *"vol_a"* ]]
  [[ "$output" == *"--yes"* ]]
}

@test "restore: --yes reverses the dump layout through every tool" {
  stub_all_restore_tools
  make_dump_layout "$DIR" vol_a vol_b
  run "$RESTORE" --dir "$DIR" --yes
  echo "$output"
  [ "$status" -eq 0 ]
  # mysql: the dump is piped on stdin (non-zero byte count recorded by the stub)
  assert_logged '^mysql .*<stdin:[1-9][0-9]*>'
  assert_logged "^psql .*-f $DIR/postgres-all.sql"
  assert_logged "^mongorestore .*$DIR/mongodb"
  assert_logged '^docker volume create vol_a'
  assert_logged '^docker volume create vol_b'
  assert_logged "^docker run --rm -v vol_a:/data -v $DIR/docker-volumes:/backup alpine .*tar xzf /backup/vol_a.tar.gz"
  assert_logged "^docker run --rm -v vol_b:/data -v $DIR/docker-volumes:/backup alpine .*tar xzf /backup/vol_b.tar.gz"
}

@test "restore: --volumes limits which tarballs are restored" {
  stub_all_restore_tools
  make_dump_layout "$DIR" vol_a vol_b
  run "$RESTORE" --dir "$DIR" --yes --volumes vol_b
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged '^docker volume create vol_b'
  refute_logged 'vol_a'
}

@test "restore: a missing tool is a logged no-op and the script still exits 0" {
  stub_tool psql   # only postgres is "installed"
  make_dump_layout "$DIR" vol_a
  run "$RESTORE" --dir "$DIR" --yes
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged '^psql'
  refute_logged '^mysql '
  refute_logged '^mongorestore'
  refute_logged '^docker'
  [[ "$output" == *"mysql not found"*"skip"* ]]
  [[ "$output" == *"mongorestore not found"*"skip"* ]]
  [[ "$output" == *"docker not found"*"skip"* ]]
}

@test "restore: a dump file that is absent is a logged no-op" {
  stub_all_restore_tools
  mkdir -p "$DIR"
  echo "-- only mysql" > "$DIR/mysql-all-databases.sql"
  run "$RESTORE" --dir "$DIR" --yes
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged '^mysql '
  refute_logged '^psql'
  refute_logged '^mongorestore'
  refute_logged '^docker'
  [[ "$output" == *"postgres-all.sql not present"*"skip"* ]]
}

@test "restore: docker daemon not running skips volumes with exit 0" {
  stub_all_restore_tools
  make_dump_layout "$DIR" vol_a
  DOCKER_STUB_DOWN=1 run "$RESTORE" --dir "$DIR" --yes
  echo "$output"
  [ "$status" -eq 0 ]
  refute_logged '^docker run'
  [[ "$output" == *"docker daemon not running"*"skip"* ]]
}

@test "restore: --dry-run with --yes still invokes nothing" {
  stub_all_restore_tools
  make_dump_layout "$DIR" vol_a
  run "$RESTORE" --dir "$DIR" --yes --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
  [[ "$output" == *"dry-run"* ]]
}

@test "restore: --help prints usage and exits 0" {
  run "$RESTORE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: db-restore.sh"* ]]
  [[ "$output" == *"--yes"* ]]
}
