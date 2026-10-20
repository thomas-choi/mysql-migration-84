# shellcheck shell=bash
# Shared helpers for export_mysql80.sh and import_mysql84.sh. Sourced, not executed.
#
# Every MySQL client call goes through run_tool(), which uses either a local
# MySQL 8.4 client (if one is installed, or MYSQL_BIN_DIR points at one) or the
# official mysql:8.4 Docker image. That guarantees the dump is produced by an
# 8.4 mysqldump, whatever client version the host happens to have.

MYSQL84_IMAGE="${MYSQL84_IMAGE:-mysql:8.4}"
DOCKER_NETWORK="${DOCKER_NETWORK:-host}"
SYSTEM_SCHEMAS="'mysql','information_schema','performance_schema','sys'"

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

load_env_file() {
  local f=$1
  [[ -f $f ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
}

# Pick local 8.4 binaries or the Docker image; sets TOOL_MODE and BIN_DIR.
init_tools() {
  local ver
  if [[ -n ${MYSQL_BIN_DIR:-} ]]; then
    TOOL_MODE=local BIN_DIR=$MYSQL_BIN_DIR
  elif command -v mysqldump >/dev/null 2>&1 && mysqldump --version | grep -q 'Ver 8\.4\.'; then
    TOOL_MODE=local BIN_DIR=$(dirname "$(command -v mysqldump)")
  else
    command -v docker >/dev/null 2>&1 \
      || die "no MySQL 8.4 client found locally and docker is not installed"
    TOOL_MODE=docker
    if ! docker image inspect "$MYSQL84_IMAGE" >/dev/null 2>&1; then
      log "pulling $MYSQL84_IMAGE"
      docker pull -q "$MYSQL84_IMAGE" >/dev/null || die "docker pull $MYSQL84_IMAGE failed"
    fi
  fi
  ver=$(run_bare mysqldump --version)
  grep -q 'Ver 8\.4\.' <<<"$ver" || die "mysqldump is not 8.4: $ver"
  log "client tools: $TOOL_MODE ($ver)"
}

# Run a client tool without credentials (used for --version).
run_bare() {
  local tool=$1; shift
  if [[ $TOOL_MODE == local ]]; then
    "$BIN_DIR/$tool" "$@"
  else
    docker run --rm -i --network "$DOCKER_NETWORK" "$MYSQL84_IMAGE" "$tool" "$@"
  fi
}

# Run a client tool with credentials from an option file: run_tool CNF TOOL ARGS...
# Stdin and stdout pass straight through, so dumps and imports stream.
run_tool() {
  local cnf=$1 tool=$2; shift 2
  if [[ $TOOL_MODE == local ]]; then
    "$BIN_DIR/$tool" --defaults-extra-file="$cnf" "$@"
  else
    docker run --rm -i --network "$DOCKER_NETWORK" \
      -v "$cnf:/run/client.cnf:ro" "$MYSQL84_IMAGE" \
      "$tool" --defaults-extra-file=/run/client.cnf "$@"
  fi
}

# Run one SQL statement and print tab-separated rows, no header.
query() {
  local cnf=$1 sql=$2
  run_tool "$cnf" mysql -N -B -r -e "$sql"
}

# Write a 0600 [client] option file so the password never appears in `ps`.
# Usage: write_cnf PATH HOST PORT USER PASSWORD
write_cnf() {
  local path=$1 host=$2 port=$3 user=$4 pass=$5
  # Inside a container "localhost" means the Unix socket, which is not there.
  [[ $TOOL_MODE == docker && $host == localhost ]] && host=127.0.0.1
  pass=${pass//\\/\\\\}
  pass=${pass//\"/\\\"}
  (umask 077; cat >"$path" <<EOF
[client]
host="$host"
port=$port
user="$user"
password="$pass"
default-character-set=utf8mb4
max-allowed-packet=1G
EOF
  )
}

# Quote a value as a SQL string literal / an identifier.
sql_str()   { local s=${1//\\/\\\\}; printf "'%s'" "${s//\'/\'\'}"; }
sql_ident() { printf '`%s`' "${1//\`/\`\`}"; }

# Object counts for one schema: tables views procedures functions triggers events
object_counts() {
  local cnf=$1 db; db=$(sql_str "$2")
  query "$cnf" "SELECT
    (SELECT COUNT(*) FROM information_schema.tables   WHERE table_schema=$db AND table_type='BASE TABLE'),
    (SELECT COUNT(*) FROM information_schema.tables   WHERE table_schema=$db AND table_type='VIEW'),
    (SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema=$db AND routine_type='PROCEDURE'),
    (SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema=$db AND routine_type='FUNCTION'),
    (SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema=$db),
    (SELECT COUNT(*) FROM information_schema.events   WHERE event_schema=$db)"
}

# Exact row count per base table, one query per schema: prints "table<TAB>rows".
row_counts() {
  local cnf=$1 db=$2 sql="" t
  while IFS= read -r t; do
    [[ -n $sql ]] && sql+=" UNION ALL "
    sql+="SELECT $(sql_str "$t"), COUNT(*) FROM $(sql_ident "$db").$(sql_ident "$t")"
  done < <(query "$cnf" "SELECT table_name FROM information_schema.tables
                         WHERE table_schema=$(sql_str "$db") AND table_type='BASE TABLE'
                         ORDER BY table_name")
  [[ -z $sql ]] && return 0
  query "$cnf" "$sql" | sort
}
