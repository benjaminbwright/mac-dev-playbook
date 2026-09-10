#!/usr/bin/env bash
# db-restore.sh — reverse scripts/db-dump.sh: load a dump directory back into
# the local MySQL / PostgreSQL / MongoDB servers and Docker named volumes.
#
# Layout expected in --dir (whatever is absent is skipped):
#   mysql-all-databases.sql    -> mysql < file
#   postgres-all.sql           -> psql -d postgres -f file
#   mongodb/                   -> mongorestore dir
#   docker-volumes/<vol>.tar.gz -> docker volume create + tar xzf via alpine
#
# Refuses to run without an explicit --dir. Without --yes it only prints the
# plan. Every tool is resolved via `command -v` on PATH, so tests can stub them.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: db-restore.sh --dir DIR [--yes] [--volumes a,b,...] [--dry-run] [--help]

  --dir DIR        Dump directory produced by db-dump.sh (REQUIRED, no default).
  --yes            Actually restore. Without it the plan is printed and nothing
                   is touched.
  --volumes LIST   Restore only these Docker volumes (default: every
                   docker-volumes/*.tar.gz found in DIR).
  --dry-run        Print the plan; never restore, even with --yes.
  --help           Show this help.

Environment:
  DB_MYSQL_ARGS    Extra args for mysql (default: -uroot). Set MYSQL_PWD for the
                   password, e.g. MYSQL_PWD=root (the playbook's default).
  DB_PG_ARGS       Extra args for psql (default: -d postgres).
  DB_MONGO_ARGS    Extra args for mongorestore (default: none).

A missing tool, a stopped server, or an absent dump file is logged and skipped;
the script still exits 0 so the remaining restores run.
EOF
}

DUMP_DIR=""
VOLUMES=""
DRY_RUN=0
YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DUMP_DIR="$2"; shift 2 ;;
    --dir=*) DUMP_DIR="${1#--dir=}"; shift ;;
    --volumes) VOLUMES="$2"; shift 2 ;;
    --volumes=*) VOLUMES="${1#--volumes=}"; shift ;;
    --yes|-y) YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "db-restore: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log()  { printf 'db-restore: %s\n' "$*"; }
skip() { printf 'db-restore: %s -- skip\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ -z "$DUMP_DIR" ]; then
  echo "db-restore: --dir DIR is required (refusing to guess which dump to load)." >&2
  usage >&2
  exit 2
fi

if [ ! -d "$DUMP_DIR" ]; then
  echo "db-restore: dump directory not found: $DUMP_DIR" >&2
  exit 1
fi

# --- Work out which Docker volumes are in play --------------------------------
vols=()
if [ -n "$VOLUMES" ]; then
  IFS=',' read -r -a vols <<< "$VOLUMES"
elif [ -d "$DUMP_DIR/docker-volumes" ]; then
  for f in "$DUMP_DIR"/docker-volumes/*.tar.gz; do
    [ -e "$f" ] || continue
    f="$(basename "$f")"
    vols+=("${f%.tar.gz}")
  done
fi

# --- Plan ---------------------------------------------------------------------
log "plan for $DUMP_DIR:"
log "  mysql       < mysql-all-databases.sql"
log "  psql     -f   postgres-all.sql"
log "  mongorestore  mongodb/"
if [ "${#vols[@]}" -gt 0 ]; then
  log "  docker volumes: ${vols[*]}"
else
  log "  docker volumes: (none)"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "dry-run: nothing restored"
  exit 0
fi
if [ "$YES" -eq 0 ]; then
  log "no changes made. Re-run with --yes to restore."
  exit 0
fi

# --- Execute -------------------------------------------------------------------
# restore_with TOOL SRC LABEL CMD... — run CMD only if TOOL is on PATH and SRC
# exists. Failures (server not running, auth, ...) are logged, not fatal.
restore_with() {
  local tool="$1" src="$2" label="$3"; shift 3
  if ! have "$tool"; then skip "$tool not found"; return 0; fi
  if [ ! -e "$src" ]; then skip "$label not present in $DUMP_DIR"; return 0; fi
  if "$@"; then
    log "$tool <- $label"
  else
    skip "$tool failed on $label (is the server running?)"
  fi
}

# --- MySQL -------------------------------------------------------------------
mysql_restore() {
  # shellcheck disable=SC2086
  mysql ${DB_MYSQL_ARGS:--uroot} < "$DUMP_DIR/mysql-all-databases.sql"
}
restore_with mysql "$DUMP_DIR/mysql-all-databases.sql" "mysql-all-databases.sql" mysql_restore

# --- PostgreSQL --------------------------------------------------------------
pg_restore_all() {
  # shellcheck disable=SC2086
  psql ${DB_PG_ARGS:--d postgres} -q -f "$DUMP_DIR/postgres-all.sql"
}
restore_with psql "$DUMP_DIR/postgres-all.sql" "postgres-all.sql" pg_restore_all

# --- MongoDB -----------------------------------------------------------------
mongo_restore() {
  # shellcheck disable=SC2086
  mongorestore ${DB_MONGO_ARGS:-} --quiet "$DUMP_DIR/mongodb"
}
restore_with mongorestore "$DUMP_DIR/mongodb" "mongodb/" mongo_restore

# --- Docker named volumes ----------------------------------------------------
if [ "${#vols[@]}" -eq 0 ]; then
  log "no docker volumes to restore"
elif ! have docker; then
  skip "docker not found"
elif ! docker info >/dev/null 2>&1; then
  skip "docker daemon not running"
else
  for vol in "${vols[@]}"; do
    [ -n "$vol" ] || continue
    tarball="$DUMP_DIR/docker-volumes/$vol.tar.gz"
    if [ ! -f "$tarball" ]; then
      skip "docker-volumes/$vol.tar.gz not present in $DUMP_DIR"
      continue
    fi
    if docker volume create "$vol" >/dev/null \
       && docker run --rm -v "$vol:/data" -v "$DUMP_DIR/docker-volumes:/backup" alpine \
            sh -c "cd /data && tar xzf /backup/$vol.tar.gz"; then
      log "docker <- docker-volumes/$vol.tar.gz (volume $vol)"
    else
      skip "docker volume $vol failed"
    fi
  done
fi

log "done"
