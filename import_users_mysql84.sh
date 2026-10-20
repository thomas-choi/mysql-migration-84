#!/usr/bin/env bash
# Create the accounts exported by export_users_mysql80.sh (or
# export_mysql80.sh --with-users) on a MySQL 8.4 server, apply their grants,
# then check every account and grant against the export.
#
# Usage: ./import_users_mysql84.sh --dir EXPORT_DIR [options]
#   --dir DIR           an export directory containing users.tsv
#   --env-file FILE     connection settings (default: ./.env)
#   --update-existing   accounts that already exist on the target get the
#                       source's password and account options (default: leave
#                       them as they are; their missing grants are still added)
#   --dry-run           print the statements (hashes masked), change nothing
#   --no-verify         skip the comparison with the export
#   -h, --help
#
# Run it after the databases are imported: table- and column-level grants need
# their tables. Safe to re-run; grants that already exist are no-ops.
# Exits non-zero if any statement failed or verification found a difference.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/users.sh
source "$HERE/lib/users.sh"

ENV_FILE=$HERE/.env DIR="" VERIFY=1
while (($#)); do
  case $1 in
    --dir) DIR=$2; shift ;;
    --env-file) ENV_FILE=$2; shift ;;
    --update-existing) USERS_UPDATE_EXISTING=1 ;;
    --dry-run) USERS_DRY_RUN=1 ;;
    --no-verify) VERIFY=0 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[[ -n $DIR ]] || die "--dir is required (an export directory)"
[[ -f $DIR/users.tsv ]] || die "$DIR has no users.tsv (export with export_users_mysql80.sh)"
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

((USERS_DRY_RUN)) && log "dry run - statements that would run:"
log "applying accounts$( ((USERS_UPDATE_EXISTING)) && echo " (updating existing ones)")"
apply_users "$CNF" "$DIR" accounts "$LOGS/users.log"
log "applying grants and default roles"
apply_users "$CNF" "$DIR" grants "$LOGS/users.log"
((USERS_DRY_RUN)) && { log "dry run - nothing changed"; exit 0; }

if ((${#USERS_ERRORS[@]})); then
  warn "${#USERS_ERRORS[@]} statement(s) failed (details: $LOGS/users.log):"
  for e in "${USERS_ERRORS[@]}"; do warn "  ${e/$'\t'/: }"; done
  grep -q "doesn't exist" "$LOGS/users.log" \
    && warn "table grants fail until the tables exist - import the databases, then re-run this"
fi

MISMATCH=0
if ((VERIFY)); then
  log "verifying accounts and grants against the export"
  if verify_users "$CNF" "$DIR"; then log "  all exported accounts and grants present"; else MISMATCH=1; fi
fi

log "accounts: $(grep -c '^create' "$DIR/users.tsv")  failed statements: ${#USERS_ERRORS[@]}  verify: $( ((MISMATCH)) && echo differences || echo OK)"
log "logs: $LOGS"
((${#USERS_ERRORS[@]} == 0 && MISMATCH == 0))
