# Shared bats helper for the db-dump / db-restore script tests.
#
# Every external tool the scripts call (mysqldump, mongodump, pg_dumpall,
# docker, mysql, mongorestore, psql) is replaced by a stub on PATH that
# records its argv to $STUB_LOG and fakes the tool's observable output.
# Nothing here ever touches a real database or the real Docker daemon.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
DUMP="$REPO_ROOT/scripts/db-dump.sh"
RESTORE="$REPO_ROOT/scripts/db-restore.sh"

setup_stub_env() {
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  mkdir -p "$STUB_BIN"
  : > "$STUB_LOG"
  export STUB_LOG
  # A minimal PATH: our stubs plus the system dirs the scripts need for
  # coreutils (mkdir, date, ln, ...). Homebrew dirs are deliberately absent
  # so no real db tool can be picked up by accident.
  export PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
}

# stub_tool NAME — put the fake NAME binary from tests/db/stubs on PATH.
stub_tool() {
  cp "$REPO_ROOT/tests/db/stubs/$1" "$STUB_BIN/$1"
  chmod +x "$STUB_BIN/$1"
}

stub_all_dump_tools() {
  stub_tool mysqldump; stub_tool mongodump; stub_tool pg_dumpall; stub_tool docker
}

stub_all_restore_tools() {
  stub_tool mysql; stub_tool mongorestore; stub_tool psql; stub_tool docker
}

# make_dump_layout DIR [VOL...] — lay down the on-disk layout db-dump.sh
# produces, so restore tests don't depend on running the dump script.
make_dump_layout() {
  local dir="$1"; shift
  mkdir -p "$dir/mongodb/fakedb" "$dir/docker-volumes"
  echo "-- fake mysql dump" > "$dir/mysql-all-databases.sql"
  echo "-- fake postgres dump" > "$dir/postgres-all.sql"
  echo fake > "$dir/mongodb/fakedb/coll.bson"
  local vol
  for vol in "$@"; do echo fake-tar > "$dir/docker-volumes/$vol.tar.gz"; done
}

# assert_logged PATTERN — the stub log has a line matching PATTERN (grep -E).
assert_logged() {
  grep -Eq -- "$1" "$STUB_LOG" || {
    echo "expected stub log to match: $1"; echo "--- stub log ---"; cat "$STUB_LOG"; return 1; }
}

refute_logged() {
  ! grep -Eq -- "$1" "$STUB_LOG" || {
    echo "expected stub log NOT to match: $1"; echo "--- stub log ---"; cat "$STUB_LOG"; return 1; }
}
