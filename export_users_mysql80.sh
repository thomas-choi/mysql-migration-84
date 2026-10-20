#!/usr/bin/env bash
# Export accounts (with their original password hashes) and their grants from a
# MySQL 8.0 server, for import_users_mysql84.sh. Same output as
# export_mysql80.sh --with-users, without dumping any database.
#
# Usage: ./export_users_mysql80.sh [options]
#   --env-file FILE     connection settings (default: ./.env)
#   --out DIR           output directory (default: $EXPORT_DIR/users_<timestamp>)
#   --user NAME         export only this user name, all its hosts (repeatable)
#   --exclude-user NAME skip this user name as well (repeatable)
#   -h, --help
#
# Never exported: root, mysql.*, debian-sys-maint, and the accounts a
# DigitalOcean managed server creates itself (doadmin, optadmin, repluser,
# metrics_user_*). SET_USER_ID grants become SET_ANY_DEFINER and
# ALLOW_NONEXISTENT_DEFINER, which replace it in 8.4.
# The output holds password hashes, so only you can read it.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/users.sh
source "$HERE/lib/users.sh"

ENV_FILE=$HERE/.env OUT=""
USER_INCLUDE=() USER_EXCLUDE=()
while (($#)); do
  case $1 in
    --env-file) ENV_FILE=$2; shift ;;
    --out) OUT=$2; shift ;;
    --user) USER_INCLUDE+=("$2"); shift ;;
    --exclude-user) USER_EXCLUDE+=("$2"); shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

load_env_file "$ENV_FILE"
: "${SRC_HOST:?SRC_HOST not set}" "${SRC_USER:?SRC_USER not set}"
SRC_PORT=${SRC_PORT:-3306} SRC_PASSWORD=${SRC_PASSWORD:-}
OUT=${OUT:-${EXPORT_DIR:-$HERE/exports}/users_$(date +%Y%m%d_%H%M%S)}

init_tools
mkdir -p "$OUT"
chmod 700 "$OUT"
OUT=$(cd "$OUT" && pwd)
CNF=$(mktemp "${TMPDIR:-/tmp}/src.XXXXXX.cnf")
trap 'rm -f "$CNF"' EXIT
write_cnf "$CNF" "$SRC_HOST" "$SRC_PORT" "$SRC_USER" "$SRC_PASSWORD"

SRC_VERSION=$(query "$CNF" "SELECT VERSION()") || die "cannot connect to $SRC_HOST:$SRC_PORT"
log "source: $SRC_HOST:$SRC_PORT, MySQL $SRC_VERSION"
[[ $SRC_VERSION == 8.0.* ]] || warn "source is $SRC_VERSION, not 8.0.x - continuing anyway"

log "exporting accounts and grants"
export_users "$CNF" "$OUT"
(cd "$OUT" && sha256sum users.sql users.tsv >SHA256SUMS)
log "done: $OUT"
echo "$OUT"
