#!/usr/bin/env bash
# db-dump.sh — snapshot local dev databases + Docker named volumes into a
# directory OUTSIDE any git repo, so they can be carried to a new Mac and
# restored with scripts/db-restore.sh.
#
# Dumps (each skipped, exit 0, when its tool is not installed):
#   mysqldump --all-databases  -> <dir>/mysql-all-databases.sql
#   pg_dumpall                 -> <dir>/postgres-all.sql
#   mongodump                  -> <dir>/mongodb/
#   docker volumes (tar via alpine) -> <dir>/docker-volumes/<vol>.tar.gz
#
# Every tool is resolved via `command -v` on PATH, so tests can stub them.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: db-dump.sh [--dir DIR] [--volumes a,b,...] [--dry-run] [--help]

  --dir DIR        Output directory (default: ~/Development/db-dumps/<YYYY-MM-DD>).
                   A relative "latest" symlink in the parent dir is updated.
  --volumes LIST   Comma-separated Docker named volumes to archive (default: none).
  --dry-run        Print what would be dumped; write nothing.
  --help           Show this help.

Environment:
  DB_MYSQL_ARGS    Extra args for mysqldump (default: -uroot). Set MYSQL_PWD for
                   the password, e.g. MYSQL_PWD=root (the playbook's default).
  DB_PG_ARGS       Extra args for pg_dumpall (default: none).
  DB_MONGO_ARGS    Extra args for mongodump (default: none).

A missing tool (or a server that is not running) is logged and skipped; the
script still exits 0 so the remaining dumps are taken.
EOF
}

DUMP_DIR=""
VOLUMES=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DUMP_DIR="$2"; shift 2 ;;
    --dir=*) DUMP_DIR="${1#--dir=}"; shift ;;
    --volumes) VOLUMES="$2"; shift 2 ;;
    --volumes=*) VOLUMES="${1#--volumes=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "db-dump: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$DUMP_DIR" ]; then
  DUMP_DIR="$HOME/Development/db-dumps/$(date +%Y-%m-%d)"
fi

log()  { printf 'db-dump: %s\n' "$*"; }
skip() { printf 'db-dump: %s -- skip\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# dump_to FILE CMD... — run CMD with stdout redirected to FILE. On failure
# (server not running, auth, ...) remove the partial FILE and report a skip.
dump_to() {
  local out="$1"; shift
  if "$@" > "$out" 2> "$out.err"; then
    rm -f "$out.err"
    return 0
  fi
  local msg
  msg="$(tr '\n' ' ' < "$out.err")"
  rm -f "$out" "$out.err"
  skip "$1 failed (is the server running?): $msg"
  return 1
}

# --- Dry run: print the plan and touch nothing ------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  log "dry-run: would dump into $DUMP_DIR"
  log "dry-run: mysqldump --all-databases -> mysql-all-databases.sql"
  log "dry-run: pg_dumpall                -> postgres-all.sql"
  log "dry-run: mongodump                 -> mongodb/"
  if [ -n "$VOLUMES" ]; then
    IFS=',' read -r -a vols <<< "$VOLUMES"
    for vol in "${vols[@]}"; do
      [ -n "$vol" ] && log "dry-run: docker volume $vol -> docker-volumes/$vol.tar.gz"
    done
  else
    log "dry-run: no docker volumes requested (use --volumes a,b)"
  fi
  log "dry-run: nothing written"
  exit 0
fi

mkdir -p "$DUMP_DIR"
log "dumping into $DUMP_DIR"

# --- MySQL -------------------------------------------------------------------
if have mysqldump; then
  # shellcheck disable=SC2086
  dump_to "$DUMP_DIR/mysql-all-databases.sql" \
    mysqldump ${DB_MYSQL_ARGS:--uroot} --all-databases \
    && log "mysql    -> mysql-all-databases.sql"
else
  skip "mysqldump not found"
fi

# --- PostgreSQL --------------------------------------------------------------
if have pg_dumpall; then
  # shellcheck disable=SC2086
  dump_to "$DUMP_DIR/postgres-all.sql" \
    pg_dumpall ${DB_PG_ARGS:-} \
    && log "postgres -> postgres-all.sql"
else
  skip "pg_dumpall not found"
fi

# --- MongoDB -----------------------------------------------------------------
if have mongodump; then
  # shellcheck disable=SC2086
  if mongodump ${DB_MONGO_ARGS:-} --quiet --out "$DUMP_DIR/mongodb"; then
    log "mongodb  -> mongodb/"
  else
    rm -rf "$DUMP_DIR/mongodb"
    skip "mongodump failed (is the server running?)"
  fi
else
  skip "mongodump not found"
fi

# --- Docker named volumes ----------------------------------------------------
if [ -z "$VOLUMES" ]; then
  log "no docker volumes requested (use --volumes a,b)"
elif ! have docker; then
  skip "docker not found"
elif ! docker info >/dev/null 2>&1; then
  skip "docker daemon not running"
else
  mkdir -p "$DUMP_DIR/docker-volumes"
  IFS=',' read -r -a vols <<< "$VOLUMES"
  for vol in "${vols[@]}"; do
    [ -n "$vol" ] || continue
    if docker run --rm -v "$vol:/data" -v "$DUMP_DIR/docker-volumes:/backup" alpine \
        tar czf "/backup/$vol.tar.gz" -C /data .; then
      log "docker   -> docker-volumes/$vol.tar.gz"
    else
      rm -f "$DUMP_DIR/docker-volumes/$vol.tar.gz"
      skip "docker volume $vol failed (does it exist?)"
    fi
  done
fi

# --- 'latest' symlink (relative, so it survives copying the parent dir) -----
ln -sfn "$(basename "$DUMP_DIR")" "$(dirname "$DUMP_DIR")/latest"
log "latest -> $(basename "$DUMP_DIR")"

log "done"
