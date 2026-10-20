#!/usr/bin/env bash
# Copy one or more tables from the source server (SRC_*) to the target server
# (DST_*), overwriting them there. The tables are first dumped from the source
# to a backup file, then that file is restored on the target: each named table
# is dropped and re-created with its data and triggers. Other tables in the
# target database are left alone.
#
# Usage: ./copy_tables.sh --db NAME --table NAME [--table NAME ...] [options]
#   --db NAME            source database
#   --table NAME         table to copy (repeatable)
#   --target-db NAME     database to restore into (default: same as --db);
#                        created with the source's charset/collation if missing
#   --env-file FILE      connection settings (default: ./.env)
#   --out DIR            backup directory (default: $EXPORT_DIR/tables_<timestamp>)
#   --no-target-backup   do not dump the target's current copy of the tables
#                        before overwriting them
#   --strip-definers     remove DEFINER=... from triggers (they get the
#                        importing user as definer)
#   --no-verify          skip the row-count comparison
#   --lock-wait-timeout N  seconds to wait for table locks on the target, both
#                        for the lock test and during the restore (default: 10)
#   -h, --help
#
# Before touching anything, the target tables are test-locked (LOCK TABLES ...
# WRITE). If another session holds them - typically an open transaction in a
# SQL client - the script names that session and exits instead of waiting.
#
# The backup directory holds:
#   source.sql           the tables as dumped from the source
#   target-before.sql    the target's tables before the overwrite (only those
#                        that existed); undo with: mysql TARGET_DB < target-before.sql
#   rowcounts.tsv        exact source row counts taken right after the dump
#   restore.log, SHA256SUMS
#
# The overwrite is not atomic: while a table is being restored, readers on the
# target see it missing or partly loaded. Stop writers on the source for an
# exact row-count match.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

ENV_FILE=$HERE/.env OUT="" DB="" TARGET_DB="" TARGET_BACKUP=1 STRIP_DEFINERS=0 VERIFY=1 LOCK_WAIT=10
TABLES=()
while (($#)); do
  case $1 in
    --db) DB=$2; shift ;;
    --table) TABLES+=("$2"); shift ;;
    --target-db) TARGET_DB=$2; shift ;;
    --env-file) ENV_FILE=$2; shift ;;
    --out) OUT=$2; shift ;;
    --no-target-backup) TARGET_BACKUP=0 ;;
    --strip-definers) STRIP_DEFINERS=1 ;;
    --no-verify) VERIFY=0 ;;
    --lock-wait-timeout) LOCK_WAIT=$2; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[[ -n $DB ]] || die "--db is required"
((${#TABLES[@]})) || die "at least one --table is required"
[[ $LOCK_WAIT =~ ^[1-9][0-9]*$ ]] || die "--lock-wait-timeout must be a positive number of seconds"
TARGET_DB=${TARGET_DB:-$DB}
load_env_file "$ENV_FILE"
: "${SRC_HOST:?SRC_HOST not set}" "${SRC_USER:?SRC_USER not set}"
: "${DST_HOST:?DST_HOST not set}" "${DST_USER:?DST_USER not set}"
SRC_PORT=${SRC_PORT:-3306} SRC_PASSWORD=${SRC_PASSWORD:-}
DST_PORT=${DST_PORT:-3306} DST_PASSWORD=${DST_PASSWORD:-}
OUT=${OUT:-${EXPORT_DIR:-$HERE/exports}/tables_$(date +%Y%m%d_%H%M%S)}

init_tools
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
SRC_CNF=$(mktemp "${TMPDIR:-/tmp}/src.XXXXXX.cnf")
DST_CNF=$(mktemp "${TMPDIR:-/tmp}/dst.XXXXXX.cnf")
trap 'rm -f "$SRC_CNF" "$DST_CNF"' EXIT
write_cnf "$SRC_CNF" "$SRC_HOST" "$SRC_PORT" "$SRC_USER" "$SRC_PASSWORD"
write_cnf "$DST_CNF" "$DST_HOST" "$DST_PORT" "$DST_USER" "$DST_PASSWORD"

# Log what we actually reached: option files read after ours (~/.my.cnf) can
# redirect a local client, and this script drops tables on the target.
IFS=$'\t' read -r src_ver src_uuid src_who < <(query "$SRC_CNF" \
  "SELECT VERSION(), @@server_uuid, CONCAT(CURRENT_USER(),' on ',@@hostname,':',@@port)") \
  || die "cannot connect to source $SRC_HOST:$SRC_PORT"
IFS=$'\t' read -r dst_ver dst_uuid dst_who < <(query "$DST_CNF" \
  "SELECT VERSION(), @@server_uuid, CONCAT(CURRENT_USER(),' on ',@@hostname,':',@@port)") \
  || die "cannot connect to target $DST_HOST:$DST_PORT"
log "source: $SRC_HOST:$SRC_PORT, MySQL $src_ver ($src_who)"
log "target: $DST_HOST:$DST_PORT, MySQL $dst_ver ($dst_who)"
[[ $src_uuid == "$dst_uuid" && $DB == "$TARGET_DB" ]] \
  && die "source and target are the same server and database - refusing to overwrite $DB with itself"

# ---- check the tables -------------------------------------------------------
table_list=$(for t in "${TABLES[@]}"; do printf '%s,' "$(sql_str "$t")"; done); table_list=${table_list%,}
mapfile -t found < <(query "$SRC_CNF" "SELECT table_name FROM information_schema.tables
  WHERE table_schema=$(sql_str "$DB") AND table_type='BASE TABLE' AND table_name IN ($table_list)")
for t in "${TABLES[@]}"; do
  printf '%s\n' "${found[@]}" | grep -qxF -- "$t" || die "no base table $DB.$t on source"
done
mapfile -t existing < <(query "$DST_CNF" "SELECT table_name FROM information_schema.tables
  WHERE table_schema=$(sql_str "$TARGET_DB") AND table_name IN ($table_list) ORDER BY table_name")
log "tables to copy $DB -> $TARGET_DB (${#TABLES[@]}): ${TABLES[*]}"
if ((${#existing[@]})); then
  log "will overwrite on target: ${existing[*]}"
fi

# Sessions holding metadata locks on the target tables: "id<TAB>user@host<TAB>command<TAB>secs<TAB>table".
lock_holders() {
  query "$DST_CNF" "SELECT DISTINCT t.processlist_id, CONCAT(t.processlist_user, '@', t.processlist_host),
      t.processlist_command, t.processlist_time, m.object_name
    FROM performance_schema.metadata_locks m
    JOIN performance_schema.threads t ON t.thread_id = m.owner_thread_id
    WHERE m.object_type = 'TABLE' AND m.object_schema = $(sql_str "$TARGET_DB")
      AND m.object_name IN ($table_list) AND m.lock_status = 'GRANTED'
      AND t.processlist_id <> CONNECTION_ID()
    ORDER BY t.processlist_time DESC"
}

# Explain a lock conflict on the target, name the sessions holding the tables, and exit.
lock_blocked() {
  local why=$1 outcome=$2 holders id who cmd secs tbl
  holders=$(lock_holders 2>/dev/null) || holders=""
  warn "$why"
  if [[ -n $holders ]]; then
    warn "sessions holding these tables on the target:"
    while IFS=$'\t' read -r id who cmd secs tbl; do
      warn "  id $id  $who  $cmd for ${secs}s  on $TARGET_DB.$tbl"
    done <<<"$holders"
  fi
  warn "close anything connected to these tables on the target - commit or roll back open"
  warn "transactions in SQL clients (DBeaver, Workbench, ...), stop app connections - or"
  warn "KILL the session(s) above, then rerun"
  die "target tables are locked - $outcome"
}

# ---- test-lock the target tables --------------------------------------------
# DROP TABLE waits for every open transaction that has touched the table, and
# lock_wait_timeout defaults to a year. Try the lock first, with a short wait.
if ((${#existing[@]})); then
  locks=""
  for t in "${existing[@]}"; do locks+="$(sql_ident "$TARGET_DB").$(sql_ident "$t") WRITE,"; done
  log "test-locking target tables (waits up to ${LOCK_WAIT}s)"
  if ! err=$(query "$DST_CNF" "SET SESSION lock_wait_timeout=$LOCK_WAIT; LOCK TABLES ${locks%,}; UNLOCK TABLES" 2>&1); then
    grep -q 'ERROR 1205' <<<"$err" || die "lock test failed on target: $err"
    lock_blocked "cannot lock target tables within ${LOCK_WAIT}s: ${err##*$'\n'}" \
      "nothing was changed on the target"
  fi
  log "  lock test OK"
fi

DUMP_OPTS=(
  --single-transaction --quick      # consistent InnoDB snapshot, no table locks
  --triggers --add-drop-trigger     # table triggers come along and replace old ones
  --hex-blob                        # binary columns survive any client charset
  --set-gtid-purged=OFF             # don't carry the source's GTID set to the target
  --no-tablespaces                  # avoids needing the PROCESS privilege
  --default-character-set=utf8mb4
  --max-allowed-packet=1G
)

# Dump TABLES... of DB from the server in CNF to FILE; no --databases, so the
# file has no USE and restores into whichever database the client selects.
dump_tables() {
  local cnf=$1 db=$2 file=$3; shift 3
  if ! run_tool "$cnf" mysqldump "${DUMP_OPTS[@]}" "$db" "$@" >"$file.partial" 2>"$file.err"; then
    cat "$file.err" >&2
    die "mysqldump failed for $db: $*"
  fi
  grep -v 'Using a password' "$file.err" >&2 || true
  rm -f "$file.err"
  tail -n 1 "$file.partial" | grep -q '^-- Dump completed' || die "dump of $db looks truncated"
  mv "$file.partial" "$file"
}

# Exact row count for each named table: prints "table<TAB>rows", sorted.
table_rows() {
  local cnf=$1 db=$2 sql="" t; shift 2
  for t in "$@"; do
    [[ -n $sql ]] && sql+=" UNION ALL "
    sql+="SELECT $(sql_str "$t"), COUNT(*) FROM $(sql_ident "$db").$(sql_ident "$t")"
  done
  query "$cnf" "$sql" | sort
}

# ---- backup: source tables --------------------------------------------------
log "dumping from source"
dump_tables "$SRC_CNF" "$DB" "$OUT/source.sql" "${TABLES[@]}"
if ((STRIP_DEFINERS)); then
  # Only DDL lines; data rows (INSERT INTO ...) are left byte-for-byte untouched.
  sed -E -i '/^INSERT INTO /!s/DEFINER=`[^`]*`@`[^`]*`//g' "$OUT/source.sql"
fi
table_rows "$SRC_CNF" "$DB" "${TABLES[@]}" >"$OUT/rowcounts.tsv"
log "  $(du -h "$OUT/source.sql" | cut -f1)  $OUT/source.sql"

# ---- backup: target's current copy -----------------------------------------
if ((TARGET_BACKUP && ${#existing[@]})); then
  log "saving target's current tables before overwrite"
  dump_tables "$DST_CNF" "$TARGET_DB" "$OUT/target-before.sql" "${existing[@]}"
  log "  $(du -h "$OUT/target-before.sql" | cut -f1)  $OUT/target-before.sql"
fi
(cd "$OUT" && sha256sum ./*.sql rowcounts.tsv >SHA256SUMS)

# ---- restore on target ------------------------------------------------------
read -r charset collation < <(query "$SRC_CNF" "SELECT default_character_set_name, default_collation_name
  FROM information_schema.schemata WHERE schema_name=$(sql_str "$DB")")
query "$DST_CNF" "CREATE DATABASE IF NOT EXISTS $(sql_ident "$TARGET_DB")
  CHARACTER SET $charset COLLATE $collation" >/dev/null

log "restoring into $TARGET_DB on target"
start=$SECONDS
# No --force: stop at the first error. The dump sets FOREIGN_KEY_CHECKS=0, so
# tables that other target tables reference can still be dropped and reloaded.
# The lock timeout covers a session that grabs a table after the lock test.
if ! run_tool "$DST_CNF" mysql --init-command="SET SESSION lock_wait_timeout=$LOCK_WAIT" \
     "$TARGET_DB" <"$OUT/source.sql" 2>"$OUT/restore.log"; then
  if grep -q '^ERROR 1205' "$OUT/restore.log"; then
    lock_blocked "restore hit a lock after ${LOCK_WAIT}s: $(grep -m1 '^ERROR' "$OUT/restore.log")" \
      "restore stopped partway; previous target tables: $OUT/target-before.sql"
  fi
  warn "restore FAILED after $((SECONDS - start))s: $(grep -m1 '^ERROR' "$OUT/restore.log" || tail -n1 "$OUT/restore.log")"
  [[ -f $OUT/target-before.sql ]] && warn "previous target tables: $OUT/target-before.sql"
  die "restore failed - see $OUT/restore.log"
fi
log "  ok in $((SECONDS - start))s"

# ---- verify -----------------------------------------------------------------
if ((VERIFY)); then
  if ! diff "$OUT/rowcounts.tsv" <(table_rows "$DST_CNF" "$TARGET_DB" "${TABLES[@]}") >"$OUT/rows.diff"; then
    warn "row counts differ (source changed during the copy?) - see $OUT/rows.diff"
    exit 1
  fi
  rm -f "$OUT/rows.diff"
  while IFS=$'\t' read -r t n; do log "  $TARGET_DB.$t OK ($n rows)"; done <"$OUT/rowcounts.tsv"
fi

log "done: ${#TABLES[@]} table(s) copied, backup in $OUT"
echo "$OUT"
