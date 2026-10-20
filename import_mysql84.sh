#!/usr/bin/env bash
# Import every database SQL file produced by export_mysql80.sh into a MySQL 8.4
# server, then verify object counts (and row counts, if exported) against the
# export manifest.
#
# Usage: ./import_mysql84.sh --dir EXPORT_DIR [options]
#   --dir DIR           an export directory (contains databases/, manifest.tsv)
#   --env-file FILE     connection settings (default: ./.env)
#   --db NAME           import only this database (repeatable)
#   --overwrite         DROP and re-create databases that already exist and are
#                       non-empty on the target (default: skip them)
#   --skip-users        do not apply users.sql even if the export has one
#   --no-verify         skip the post-import comparison
#   -h, --help
#
# Exits non-zero if any database failed to import or failed verification.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/users.sh
source "$HERE/lib/users.sh"

ENV_FILE=$HERE/.env DIR="" OVERWRITE=0 SKIP_USERS=0 VERIFY=1
INCLUDE=()
while (($#)); do
  case $1 in
    --dir) DIR=$2; shift ;;
    --env-file) ENV_FILE=$2; shift ;;
    --db) INCLUDE+=("$2"); shift ;;
    --overwrite) OVERWRITE=1 ;;
    --skip-users) SKIP_USERS=1 ;;
    --no-verify) VERIFY=0 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[[ -n $DIR ]] || die "--dir is required (an export directory)"
[[ -d $DIR/databases ]] || die "$DIR does not look like an export directory (no databases/)"
DIR=$(cd "$DIR" && pwd)
load_env_file "$ENV_FILE"
: "${DST_HOST:?DST_HOST not set}" "${DST_USER:?DST_USER not set}"
DST_PORT=${DST_PORT:-3306} DST_PASSWORD=${DST_PASSWORD:-}

if [[ -f $DIR/SHA256SUMS ]]; then
  (cd "$DIR" && sha256sum --quiet -c SHA256SUMS) || die "checksum mismatch - export files are damaged"
  log "checksums OK"
fi

init_tools
CNF=$(mktemp "${TMPDIR:-/tmp}/dst.XXXXXX.cnf")
trap 'rm -f "$CNF"' EXIT
write_cnf "$CNF" "$DST_HOST" "$DST_PORT" "$DST_USER" "$DST_PASSWORD"
LOGS=$DIR/import-logs/$(date +%Y%m%d_%H%M%S)
mkdir -p "$LOGS"

DST_VERSION=$(query "$CNF" "SELECT VERSION()") || die "cannot connect to $DST_HOST:$DST_PORT"
log "target: $DST_HOST:$DST_PORT, MySQL $DST_VERSION"
[[ $DST_VERSION == 8.4.* ]] || warn "target is $DST_VERSION, not 8.4.x - continuing anyway"

# ---- choose files -----------------------------------------------------------
FILES=()
for f in "$DIR"/databases/*.sql; do
  [[ -e $f ]] || continue
  db=$(basename "$f" .sql)
  if ((${#INCLUDE[@]})) && ! printf '%s\n' "${INCLUDE[@]}" | grep -qxF -- "$db"; then continue; fi
  FILES+=("$f")
done
for db in "${INCLUDE[@]}"; do
  [[ -f $DIR/databases/$db.sql ]] || die "no export file for database: $db"
done
((${#FILES[@]})) || die "no database files to import in $DIR/databases"

# ---- preflight --------------------------------------------------------------
read -r log_bin trust < <(query "$CNF" "SELECT @@log_bin, @@log_bin_trust_function_creators")
if [[ $log_bin == 1 && $trust == 0 ]] && grep -lq -E '^(/\*!50003 )?CREATE.*(FUNCTION|TRIGGER)' "${FILES[@]}"; then
  warn "binary logging is on and log_bin_trust_function_creators=0: creating functions/triggers"
  warn "needs SUPER (or SET_ANY_DEFINER/SYSTEM_VARIABLES_ADMIN). If imports fail on that, run"
  warn "SET PERSIST log_bin_trust_function_creators=1 on the target first."
fi

# ---- accounts first, so DEFINERs resolve; grants after the databases ---------
# Same logic as import_users_mysql84.sh (lib/users.sh).
APPLY_USERS=0
if [[ -f $DIR/users.tsv || -f $DIR/users.sql ]] && ((!SKIP_USERS)); then
  APPLY_USERS=1
  log "applying accounts"
  apply_users "$CNF" "$DIR" accounts "$LOGS/users.log"
fi

# ---- databases --------------------------------------------------------------
IMPORTED=() SKIPPED=() FAILED=()
for f in "${FILES[@]}"; do
  db=$(basename "$f" .sql)
  n=$(query "$CNF" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=$(sql_str "$db")")
  if ((n > 0)); then
    if ((!OVERWRITE)); then
      warn "$db already exists on target with $n table(s)/view(s) - skipped (use --overwrite)"
      SKIPPED+=("$db"); continue
    fi
    log "dropping existing $db (--overwrite)"
    query "$CNF" "DROP DATABASE $(sql_ident "$db")"
  fi

  log "importing $db ($(du -h "$f" | cut -f1))"
  start=$SECONDS
  # No --force: stop at the first error so a half-imported database is obvious.
  if run_tool "$CNF" mysql <"$f" 2>"$LOGS/$db.log"; then
    log "  ok in $((SECONDS - start))s"
    IMPORTED+=("$db")
  else
    warn "  FAILED after $((SECONDS - start))s: $(grep -m1 '^ERROR' "$LOGS/$db.log" || tail -n1 "$LOGS/$db.log")"
    FAILED+=("$db")
  fi
done

# ---- grants (table and column grants need the tables) ----------------------
if ((APPLY_USERS)); then
  log "applying grants and default roles"
  apply_users "$CNF" "$DIR" grants "$LOGS/users.log"
  ((${#USERS_ERRORS[@]})) && warn "${#USERS_ERRORS[@]} account statement(s) failed - see $LOGS/users.log"
fi

# ---- verify -----------------------------------------------------------------
MISMATCH=()
if ((VERIFY)) && [[ -f $DIR/manifest.tsv ]]; then
  log "verifying against manifest (tables views procedures functions triggers events)"
  for db in "${IMPORTED[@]}"; do
    expected=$(awk -F'\t' -v d="$db" '$1==d {print $2,$3,$4,$5,$6,$7}' "$DIR/manifest.tsv")
    actual=$(object_counts "$CNF" "$db" | tr '\t' ' ')
    bad=0
    if [[ $expected != "$actual" ]]; then
      warn "  $db objects: expected [$expected] got [$actual]"; bad=1
    fi
    if [[ -f $DIR/rowcounts/$db.tsv ]]; then
      if ! diff <(sort "$DIR/rowcounts/$db.tsv") <(row_counts "$CNF" "$db") >"$LOGS/$db.rows.diff"; then
        warn "  $db row counts differ - see $LOGS/$db.rows.diff"; bad=1
      else
        rm -f "$LOGS/$db.rows.diff"
      fi
    fi
    if ((bad)); then MISMATCH+=("$db"); else log "  $db OK [$actual]"; fi
  done
fi

if ((VERIFY && APPLY_USERS)); then
  log "verifying accounts and grants"
  verify_users "$CNF" "$DIR" || warn "  account differences found (details above)"
fi

# ---- summary ----------------------------------------------------------------
log "imported: ${#IMPORTED[@]}  skipped: ${#SKIPPED[@]}  failed: ${#FAILED[@]}  verify mismatches: ${#MISMATCH[@]}"
((${#SKIPPED[@]}))  && log "  skipped:  ${SKIPPED[*]}"
((${#FAILED[@]}))   && log "  failed:   ${FAILED[*]}"
((${#MISMATCH[@]})) && log "  mismatch: ${MISMATCH[*]}"
((${#USERS_ERRORS[@]})) && log "  some account statements failed: $LOGS/users.log"
log "logs: $LOGS"
((${#FAILED[@]} == 0 && ${#MISMATCH[@]} == 0))
