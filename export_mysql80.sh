#!/usr/bin/env bash
# Export every user database on a MySQL 8.0 server into one self-contained SQL
# file per database (schema, data, views, procedures, functions, triggers,
# events), produced by a MySQL 8.4 mysqldump so the output targets 8.4.
#
# Usage: ./export_mysql80.sh [options]
#   --env-file FILE     connection settings (default: ./.env)
#   --out DIR           output directory (default: $EXPORT_DIR/<timestamp>)
#   --db NAME           export only this database (repeatable)
#   --exclude NAME      skip this database (repeatable)
#   --with-users        also export accounts + grants to users.sql
#   --strip-definers    remove DEFINER=... clauses (objects get the importing
#                       user as definer; use when the accounts are not migrated)
#   --skip-broken-views leave out views that no longer compile on the source
#                       (missing table/column); their CREATE VIEW statements go
#                       to manual/broken_views.sql to fix and apply by hand
#   --row-counts        record exact per-table row counts for import-side verify
#                       (exact only if nothing writes to the source meanwhile)
#   -h, --help
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/users.sh
source "$HERE/lib/users.sh"

ENV_FILE=$HERE/.env OUT="" WITH_USERS=0 STRIP_DEFINERS=0 ROW_COUNTS=0 SKIP_BROKEN_VIEWS=0
INCLUDE=() EXCLUDE=()
while (($#)); do
  case $1 in
    --env-file) ENV_FILE=$2; shift ;;
    --out) OUT=$2; shift ;;
    --db) INCLUDE+=("$2"); shift ;;
    --exclude) EXCLUDE+=("$2"); shift ;;
    --with-users) WITH_USERS=1 ;;
    --strip-definers) STRIP_DEFINERS=1 ;;
    --row-counts) ROW_COUNTS=1 ;;
    --skip-broken-views) SKIP_BROKEN_VIEWS=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

load_env_file "$ENV_FILE"
: "${SRC_HOST:?SRC_HOST not set}" "${SRC_USER:?SRC_USER not set}"
SRC_PORT=${SRC_PORT:-3306} SRC_PASSWORD=${SRC_PASSWORD:-}
OUT=${OUT:-${EXPORT_DIR:-$HERE/exports}/$(date +%Y%m%d_%H%M%S)}

init_tools
mkdir -p "$OUT/databases"
OUT=$(cd "$OUT" && pwd)
CNF=$(mktemp "${TMPDIR:-/tmp}/src.XXXXXX.cnf")
trap 'rm -f "$CNF"' EXIT
write_cnf "$CNF" "$SRC_HOST" "$SRC_PORT" "$SRC_USER" "$SRC_PASSWORD"

SRC_VERSION=$(query "$CNF" "SELECT VERSION()") || die "cannot connect to $SRC_HOST:$SRC_PORT"
log "source: $SRC_HOST:$SRC_PORT, MySQL $SRC_VERSION"
[[ $SRC_VERSION == 8.0.* ]] || warn "source is $SRC_VERSION, not 8.0.x - continuing anyway"

# ---- choose databases -------------------------------------------------------
# schemata only lists databases this account has some privilege on (or all of
# them with SHOW DATABASES), so log who we are and the raw list before filtering.
log "debug: connected as $(query "$CNF" "SELECT CURRENT_USER()")"
mapfile -t RAW_DBS < <(query "$CNF" "SELECT schema_name FROM information_schema.schemata
                                     ORDER BY schema_name")
log "debug: databases visible on source (${#RAW_DBS[@]}), before screening:"
ALL_DBS=() DBS=()
for db in "${RAW_DBS[@]}"; do
  if grep -qxF -- "'$db'" <<<"${SYSTEM_SCHEMAS//,/$'\n'}"; then
    log "debug:   $db  [skip: system schema]"; continue
  fi
  ALL_DBS+=("$db")
  if ((${#INCLUDE[@]})) && ! printf '%s\n' "${INCLUDE[@]}" | grep -qxF -- "$db"; then
    log "debug:   $db  [skip: not in --db]"; continue
  fi
  if ((${#EXCLUDE[@]})) && printf '%s\n' "${EXCLUDE[@]}" | grep -qxF -- "$db"; then
    log "debug:   $db  [skip: --exclude]"; continue
  fi
  log "debug:   $db  [selected]"
  DBS+=("$db")
done
for db in "${INCLUDE[@]}"; do
  printf '%s\n' "${ALL_DBS[@]}" | grep -qxF -- "$db" || die "database not found on source: $db"
done
((${#DBS[@]})) || die "no databases selected"
log "databases to export (${#DBS[@]}): ${DBS[*]}"

# ---- preflight: things that export fine but break on 8.4 --------------------
db_list=$(for db in "${DBS[@]}"; do printf '%s,' "$(sql_str "$db")"; done); db_list=${db_list%,}
{
  echo "# Preflight report - source $SRC_HOST:$SRC_PORT ($SRC_VERSION), $(date -Is)"
  echo
  echo "## Foreign keys whose referenced columns are not exactly a PRIMARY/UNIQUE key"
  echo "## (8.4 rejects these by default: restrict_fk_on_non_standard_key=ON)"
  query "$CNF" "SELECT CONCAT(fk.db,'.',fk.tbl,' ',fk.name,' -> ',fk.rdb,'.',fk.rtbl,'(',fk.cols,')')
    FROM (SELECT constraint_schema db, table_name tbl, constraint_name name,
                 referenced_table_schema rdb, referenced_table_name rtbl,
                 GROUP_CONCAT(referenced_column_name ORDER BY position_in_unique_constraint) cols
          FROM information_schema.key_column_usage
          WHERE referenced_table_name IS NOT NULL AND constraint_schema IN ($db_list)
          GROUP BY 1,2,3,4,5) fk
    WHERE NOT EXISTS (
      SELECT 1 FROM (SELECT table_schema s, table_name t,
                            GROUP_CONCAT(column_name ORDER BY seq_in_index) cols
                     FROM information_schema.statistics WHERE non_unique=0
                     GROUP BY table_schema, table_name, index_name) ux
      WHERE ux.s=fk.rdb AND ux.t=fk.rtbl AND ux.cols=fk.cols)" | sed 's/^/  /'
  echo
  echo "## Accounts using mysql_native_password (plugin is disabled by default in 8.4)"
  query "$CNF" "SELECT CONCAT(user,'@',host) FROM mysql.user
                WHERE plugin='mysql_native_password' ORDER BY 1" 2>/dev/null | sed 's/^/  /' \
    || echo "(cannot read mysql.user - skipped)"
} >"$OUT/preflight.txt"
if grep -q '^  ' "$OUT/preflight.txt"; then
  warn "preflight found 8.4 compatibility issues - see $OUT/preflight.txt"
fi

# ---- views that are already broken on the source ----------------------------
# mysqldump aborts on these (error 1356); the server flags them in table_comment.
mapfile -t BROKEN_VIEWS < <(query "$CNF" "SELECT CONCAT(table_schema,'\t',table_name)
  FROM information_schema.tables
  WHERE table_type='VIEW' AND table_comment LIKE '%references invalid%'
    AND table_schema IN ($db_list) ORDER BY 1")
if ((${#BROKEN_VIEWS[@]})); then
  {
    echo
    echo "## Views broken on the source (reference a missing table/column/function)"
    echo "## Not exported; CREATE VIEW statements are in manual/broken_views.sql"
    printf '  %s\n' "${BROKEN_VIEWS[@]//$'\t'/.}"
  } >>"$OUT/preflight.txt"

  # The import never runs files under manual/ - these are applied by hand once fixed.
  mkdir -p "$OUT/manual"
  definer="CONCAT('DEFINER=', QUOTE(SUBSTRING_INDEX(definer,'@',1)), '@',
                  QUOTE(SUBSTRING_INDEX(definer,'@',-1)), ' ')"
  ((STRIP_DEFINERS)) && definer="''"
  {
    echo "-- Views that could not be exported from $SRC_HOST:$SRC_PORT ($SRC_VERSION) on $(date -Is)"
    echo "-- They no longer compile on the source. Fix each definition, then run it on the"
    echo "-- target after the import. import_mysql84.sh does not apply this file."
    for v in "${BROKEN_VIEWS[@]}"; do
      query "$CNF" "SELECT CONCAT('\n-- ', t.table_schema, '.', t.table_name,
          '\n-- source error: ', t.table_comment,
          '\nCREATE OR REPLACE ', $definer, 'SQL SECURITY ', v.security_type, ' VIEW ',
          '\`', REPLACE(t.table_schema,'\`','\`\`'), '\`.\`', REPLACE(t.table_name,'\`','\`\`'), '\`',
          ' AS ', v.view_definition,
          IF(v.check_option='NONE', '', CONCAT(' WITH ', v.check_option, ' CHECK OPTION')), ';')
        FROM information_schema.tables t
        JOIN information_schema.views v USING (table_schema, table_name)
        WHERE t.table_schema=$(sql_str "${v%%$'\t'*}") AND t.table_name=$(sql_str "${v#*$'\t'}")"
    done
  } >"$OUT/manual/broken_views.sql"

  ((SKIP_BROKEN_VIEWS)) || die "broken view(s) on source: ${BROKEN_VIEWS[*]//$'\t'/.}
  fix or drop them, or rerun with --skip-broken-views (see $OUT/manual/broken_views.sql)"
  warn "skipping ${#BROKEN_VIEWS[@]} broken view(s): ${BROKEN_VIEWS[*]//$'\t'/.} -> $OUT/manual/broken_views.sql"
fi

# ---- per-database dumps -----------------------------------------------------
DUMP_OPTS=(
  --single-transaction --quick      # consistent InnoDB snapshot, no table locks
  --routines --triggers --events    # stored procs/functions, triggers, events
  --add-drop-trigger                # makes re-import idempotent (tables/views already are)
  --hex-blob                        # binary columns survive any client charset
  --set-gtid-purged=OFF             # don't carry the source's GTID set to the target
  --no-tablespaces                  # avoids needing the PROCESS privilege
  --default-character-set=utf8mb4
  --max-allowed-packet=1G
)
printf 'database\ttables\tviews\tprocedures\tfunctions\ttriggers\tevents\n' >"$OUT/manifest.tsv"
((ROW_COUNTS)) && mkdir -p "$OUT/rowcounts"

for db in "${DBS[@]}"; do
  file=$OUT/databases/$db.sql
  log "dumping $db"
  skip_opts=()
  for v in "${BROKEN_VIEWS[@]}"; do
    [[ ${v%%$'\t'*} == "$db" ]] && skip_opts+=("--ignore-table=$db.${v#*$'\t'}")
  done
  # --databases emits CREATE DATABASE IF NOT EXISTS + USE, so the file is self-contained.
  if ! run_tool "$CNF" mysqldump "${DUMP_OPTS[@]}" "${skip_opts[@]}" --databases "$db" \
       >"$file.partial" 2>"$file.err"; then
    cat "$file.err" >&2
    die "mysqldump failed for $db"
  fi
  grep -v 'Using a password' "$file.err" >&2 || true
  rm -f "$file.err"
  tail -n 1 "$file.partial" | grep -q '^-- Dump completed' || die "dump of $db looks truncated"

  if ((STRIP_DEFINERS)); then
    # Only DDL lines; data rows (INSERT INTO ...) are left byte-for-byte untouched.
    sed -E -i '/^INSERT INTO /!s/DEFINER=`[^`]*`@`[^`]*`//g' "$file.partial"
  fi
  mv "$file.partial" "$file"

  # Skipped views are not in the dump, so they must not be in the expected view count.
  printf '%s\t%s\n' "$db" "$(object_counts "$CNF" "$db")" \
    | awk -F'\t' -v OFS='\t' -v n="${#skip_opts[@]}" '{$3 -= n; print}' >>"$OUT/manifest.tsv"
  ((ROW_COUNTS)) && row_counts "$CNF" "$db" >"$OUT/rowcounts/$db.tsv"
  log "  $(du -h "$file" | cut -f1)  $file"
done

# ---- accounts and grants (optional) -----------------------------------------
# Same logic as export_users_mysql80.sh (lib/users.sh).
if ((WITH_USERS)); then
  log "exporting accounts and grants"
  export_users "$CNF" "$OUT"
fi

(cd "$OUT" && find . -type f \( -name '*.sql' -o -name users.tsv \) -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
log "done: ${#DBS[@]} database(s) exported to $OUT"
echo "$OUT"
