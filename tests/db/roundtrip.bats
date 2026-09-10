#!/usr/bin/env bats
# End-to-end: what db-dump.sh writes is exactly what db-restore.sh reads back.
# All tools are PATH stubs — nothing here touches real databases or Docker.
load test_helper

setup() {
  setup_stub_env
  DIR="$BATS_TEST_TMPDIR/dump"
}

@test "roundtrip: restore consumes every artifact the dump produced" {
  stub_all_dump_tools
  run "$DUMP" --dir "$DIR" --volumes vol_a,vol_b
  [ "$status" -eq 0 ]

  : > "$STUB_LOG"
  stub_all_restore_tools
  run "$RESTORE" --dir "$DIR" --yes
  echo "$output"
  [ "$status" -eq 0 ]
  assert_logged '^mysql .*<stdin:[1-9][0-9]*>'
  assert_logged "^psql .*-f $DIR/postgres-all.sql"
  assert_logged "^mongorestore .*$DIR/mongodb"
  assert_logged 'tar xzf /backup/vol_a.tar.gz'
  assert_logged 'tar xzf /backup/vol_b.tar.gz'
  [[ "$output" != *"not present"* ]]
}
