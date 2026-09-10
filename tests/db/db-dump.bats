#!/usr/bin/env bats
# Tests for scripts/db-dump.sh. All db/docker tools are PATH stubs (see
# test_helper.bash) — nothing here touches real databases or Docker.
load test_helper

setup() {
  setup_stub_env
  DIR="$BATS_TEST_TMPDIR/dump"
}

@test "dump: produces every dump file when all tools exist" {
  stub_all_dump_tools
  run "$DUMP" --dir "$DIR" --volumes vol_a,vol_b
  echo "$output"
  [ "$status" -eq 0 ]
  [ -s "$DIR/mysql-all-databases.sql" ]
  [ -s "$DIR/postgres-all.sql" ]
  [ -d "$DIR/mongodb/fakedb" ]
  [ -f "$DIR/docker-volumes/vol_a.tar.gz" ]
  [ -f "$DIR/docker-volumes/vol_b.tar.gz" ]
  assert_logged '^mysqldump .*--all-databases'
  assert_logged '^pg_dumpall'
  assert_logged "^mongodump .*--out(=| )$DIR/mongodb"
  assert_logged '^docker run --rm -v vol_a:/data'
  assert_logged '^docker run --rm -v vol_b:/data'
}

@test "dump: a missing tool is a logged no-op and the script still exits 0" {
  stub_tool pg_dumpall   # only postgres is "installed"
  run "$DUMP" --dir "$DIR" --volumes vol_a
  echo "$output"
  [ "$status" -eq 0 ]
  [ -s "$DIR/postgres-all.sql" ]
  [ ! -e "$DIR/mysql-all-databases.sql" ]
  [ ! -e "$DIR/mongodb" ]
  [ ! -e "$DIR/docker-volumes" ]
  [[ "$output" == *"mysqldump not found"*"skip"* ]]
  [[ "$output" == *"mongodump not found"*"skip"* ]]
  [[ "$output" == *"docker not found"*"skip"* ]]
}

@test "dump: docker daemon not running skips volumes with exit 0" {
  stub_tool docker
  DOCKER_STUB_DOWN=1 run "$DUMP" --dir "$DIR" --volumes vol_a
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$DIR/docker-volumes/vol_a.tar.gz" ]
  [[ "$output" == *"docker daemon not running"*"skip"* ]]
  refute_logged '^docker run'
}

@test "dump: a server that refuses the dump leaves no partial file and exits 0" {
  stub_tool mysqldump; stub_tool pg_dumpall
  MYSQLDUMP_STUB_FAIL=1 run "$DUMP" --dir "$DIR"
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$DIR/mysql-all-databases.sql" ]
  [ -s "$DIR/postgres-all.sql" ]
  [[ "$output" == *"mysqldump failed"*"skip"* ]]
}

@test "dump: --dry-run writes nothing and invokes no tool" {
  stub_all_dump_tools
  run "$DUMP" --dir "$DIR" --volumes vol_a --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$DIR" ]
  [ ! -s "$STUB_LOG" ]
  [[ "$output" == *"dry-run"* ]]
  [[ "$output" == *"mysql-all-databases.sql"* ]]
  [[ "$output" == *"docker-volumes/vol_a.tar.gz"* ]]
}

@test "dump: --help prints usage and exits 0" {
  run "$DUMP" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: db-dump.sh"* ]]
  [[ "$output" == *"--volumes"* ]]
}

@test "dump: unknown flag exits 2" {
  run "$DUMP" --bogus
  [ "$status" -eq 2 ]
}

@test "dump: default dir is ~/Development/db-dumps/<date> with a relative 'latest' symlink" {
  stub_tool pg_dumpall
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  run "$DUMP"
  echo "$output"
  [ "$status" -eq 0 ]
  today="$(date +%Y-%m-%d)"
  [ -s "$HOME/Development/db-dumps/$today/postgres-all.sql" ]
  [ -L "$HOME/Development/db-dumps/latest" ]
  [ "$(readlink "$HOME/Development/db-dumps/latest")" = "$today" ]
  [ -s "$HOME/Development/db-dumps/latest/postgres-all.sql" ]
}
