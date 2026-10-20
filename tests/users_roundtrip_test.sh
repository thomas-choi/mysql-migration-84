#!/usr/bin/env bash
# End-to-end test of the account migration: throwaway MySQL 8.0 and 8.4
# containers, seed accounts and grants on 8.0, run export_users_mysql80.sh and
# import_users_mysql84.sh, and check logins, grants, roles and re-run safety.
# Needs Docker; touches nothing outside its own containers and a temp dir.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=mig-utest-src80 DST=mig-utest-dst84 PW='T3st!pa"ss'
WORK=$(mktemp -d)
cleanup() { docker rm -f "$SRC" "$DST" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

docker rm -f "$SRC" "$DST" >/dev/null 2>&1 || true
docker run -d --name "$SRC" -e MYSQL_ROOT_PASSWORD="$PW" -p 127.0.0.1:33180:3306 mysql:8.0 >/dev/null
# DigitalOcean's 8.4 keeps mysql_native_password on; do the same here.
docker run -d --name "$DST" -e MYSQL_ROOT_PASSWORD="$PW" -p 127.0.0.1:33184:3306 mysql:8.4 \
  --mysql-native-password=ON >/dev/null

wait_ready() {
  for _ in $(seq 90); do
    docker exec "$1" mysql -h127.0.0.1 -uroot -p"$PW" -e 'SELECT 1' >/dev/null 2>&1 && return 0
    sleep 2
  done
  fail "$1 did not start"
}
wait_ready "$SRC"; wait_ready "$DST"
src() { docker exec -i "$SRC" mysql -h127.0.0.1 -uroot -p"$PW" "$@" 2>/dev/null; }
dst() { docker exec -i "$DST" mysql -h127.0.0.1 -uroot -p"$PW" -N -B "$@" 2>/dev/null; }
# login CONTAINER USER PASSWORD SQL: run SQL as that account, print the result.
login() { docker exec "$1" mysql -h127.0.0.1 -u"$2" -p"$3" -N -B -e "$4" 2>/dev/null; }

src <<'SQL'
CREATE DATABASE shop;
CREATE TABLE shop.customer (id INT PRIMARY KEY, name VARCHAR(50), secret VARCHAR(50));
CREATE TABLE shop.orders (id INT PRIMARY KEY);
CREATE TABLE shop.only_on_source (id INT PRIMARY KEY);
CREATE ROLE 'r_read'@'%';
GRANT SELECT ON shop.* TO 'r_read'@'%';
CREATE USER 'app_sha'@'%' IDENTIFIED BY 'Sha#Pass1';
GRANT INSERT, UPDATE ON shop.* TO 'app_sha'@'%';
GRANT SELECT (id, name) ON shop.customer TO 'app_sha'@'%';
GRANT DELETE ON shop.orders TO 'app_sha'@'%' WITH GRANT OPTION;
GRANT 'r_read'@'%' TO 'app_sha'@'%';
SET DEFAULT ROLE 'r_read'@'%' TO 'app_sha'@'%';
CREATE USER 'fund-ops'@'%' IDENTIFIED WITH mysql_native_password BY 'Nat#Pass1';
GRANT SELECT ON shop.* TO 'fund-ops'@'%';
CREATE USER 'locked_u'@'%' IDENTIFIED BY 'Lock#Pass1' ACCOUNT LOCK;
CREATE USER 'definer_admin'@'%' IDENTIFIED BY 'Def#Pass1';
GRANT SET_USER_ID, ROLE_ADMIN ON *.* TO 'definer_admin'@'%';
CREATE USER 'gone'@'%' IDENTIFIED BY 'Gone#Pass1';
GRANT SELECT ON shop.only_on_source TO 'gone'@'%';
CREATE USER 'doadmin'@'%' IDENTIFIED BY 'Plat#Pass1';
CREATE USER 'repluser'@'%' IDENTIFIED BY 'Plat#Pass1';
SQL

# Target as it is mid-migration: databases imported (except one table), and
# one account that already exists with a different password.
dst <<'SQL'
CREATE DATABASE shop;
CREATE TABLE shop.customer (id INT PRIMARY KEY, name VARCHAR(50), secret VARCHAR(50));
CREATE TABLE shop.orders (id INT PRIMARY KEY);
CREATE USER 'app_sha'@'%' IDENTIFIED BY 'Old#Pass1';
SQL

cat >"$WORK/.env" <<EOF
SRC_HOST=127.0.0.1
SRC_PORT=33180
SRC_USER=root
SRC_PASSWORD='$PW'
DST_HOST=127.0.0.1
DST_PORT=33184
DST_USER=root
DST_PASSWORD='$PW'
EOF
imp() { "$HERE/import_users_mysql84.sh" --env-file "$WORK/.env" --dir "$out" "$@" 2>&1; }

# --- export ---
out=$("$HERE/export_users_mysql80.sh" --env-file "$WORK/.env" --out "$WORK/users" | tail -n1)
[[ -f $out/users.tsv && -f $out/users.sql && -f $out/SHA256SUMS ]] || fail "export files missing"
[[ $(stat -c %a "$out") == 700 && $(stat -c %a "$out/users.tsv") == 600 && $(stat -c %a "$out/users.sql") == 600 ]] \
  || fail "export not private: $(stat -c '%a %n' "$out" "$out"/*)"
pass "export wrote users.tsv, users.sql, SHA256SUMS, readable by owner only"
accts=$(awk -F'\t' '$1=="create" {print $2}' "$out/users.tsv" | sort | tr '\n' ' ')
[[ $accts == "'app_sha'@'%' 'definer_admin'@'%' 'fund-ops'@'%' 'gone'@'%' 'locked_u'@'%' 'r_read'@'%' " ]] \
  || fail "wrong account set: $accts"
pass "system and platform accounts (root, mysql.*, doadmin, repluser) skipped"
grep -q 'SET_USER_ID' "$out/users.tsv" && fail "SET_USER_ID not rewritten"
grep -q 'SET_ANY_DEFINER,ALLOW_NONEXISTENT_DEFINER' "$out/users.tsv" || fail "SET_ANY_DEFINER missing"
pass "SET_USER_ID rewritten to SET_ANY_DEFINER,ALLOW_NONEXISTENT_DEFINER"
grep -P '^create\t' "$out/users.tsv" | grep -q 'DEFAULT ROLE' && fail "DEFAULT ROLE left in CREATE USER"
grep -qP "^role\t'app_sha'@'%'\tALTER USER 'app_sha'@'%' DEFAULT ROLE 'r_read'@'%';" "$out/users.tsv" \
  || fail "default role row missing"
pass "default roles moved after the grants"
only=$("$HERE/export_users_mysql80.sh" --env-file "$WORK/.env" --out "$WORK/only" --user fund-ops | tail -n1)
[[ $(grep -c '^create' "$only/users.tsv") == 1 ]] || fail "--user did not limit the export"
pass "--user exports just that account"

# --- dry run ---
before=$(dst -e "SELECT COUNT(*) FROM mysql.user")
dry=$(imp --dry-run) || fail "dry run failed: $dry"
[[ $(dst -e "SELECT COUNT(*) FROM mysql.user") == "$before" ]] || fail "dry run changed the target"
grep -q 'AS <hash>' <<<"$dry" && ! grep -q 'AS 0x' <<<"$dry" || fail "dry run shows hashes: $dry"
pass "--dry-run changes nothing and masks password hashes"

# --- first import: one table is missing, the existing account is left alone ---
if res=$(imp); then fail "import with a failing grant reported success"; fi
grep -q "'gone'@'%': ERROR 1146" <<<"$res" || fail "failed grant not attributed to its account: $res"
grep -q "'gone'@'%': missing GRANT SELECT ON \`shop\`.\`only_on_source\`" <<<"$res" || fail "verify missed it: $res"
grep -q 'import the databases, then re-run' <<<"$res" || fail "no hint about missing tables: $res"
pass "a failed grant is named per account, verify flags it, exit is non-zero"
[[ $(login "$DST" fund-ops 'Nat#Pass1' "SELECT COUNT(*) FROM shop.customer") == 0 ]] \
  || fail "mysql_native_password account cannot log in with its original password"
[[ $(login "$DST" definer_admin 'Def#Pass1' "SELECT 1") == 1 ]] \
  || fail "caching_sha2 account cannot log in with its original password"
pass "accounts log in on 8.4 with their original passwords (native and caching_sha2)"
[[ $(dst -e "SELECT account_locked FROM mysql.user WHERE user='locked_u'") == Y ]] || fail "lock lost"
login "$DST" locked_u 'Lock#Pass1' "SELECT 1" >/dev/null && fail "locked account can log in"
pass "locked account stays locked"
dst -e "SHOW GRANTS FOR 'definer_admin'@'%'" | grep -q 'SET_ANY_DEFINER' || fail "SET_ANY_DEFINER not granted"
pass "SET_ANY_DEFINER granted on 8.4"
[[ $(login "$DST" app_sha 'Old#Pass1' "SELECT CURRENT_ROLE()") == '`r_read`@`%`' ]] \
  || fail "existing account changed, or default role not set"
login "$DST" app_sha 'Sha#Pass1' "SELECT 1" >/dev/null && fail "existing account's password changed without --update-existing"
grep -q "'app_sha'@'%' already exists" <<<"$res" || fail "no note about the existing account: $res"
pass "existing account keeps its password but gets grants and default role"
[[ $(login "$DST" app_sha 'Old#Pass1' "SELECT COUNT(name) FROM shop.customer") == 0 ]] || fail "column grant missing"
dst -e "SHOW GRANTS FOR 'app_sha'@'%'" | grep -q 'GRANT DELETE ON `shop`.`orders` TO `app_sha`@`%` WITH GRANT OPTION' \
  || fail "table grant WITH GRANT OPTION missing"
pass "column, table and WITH GRANT OPTION grants applied"

# --- second import: table now exists, --update-existing syncs the password ---
dst -e "CREATE TABLE shop.only_on_source (id INT PRIMARY KEY)"
res=$(imp --update-existing) || fail "import with --update-existing failed: $res"
grep -q 'all exported accounts and grants present' <<<"$res" || fail "verify not clean: $res"
[[ $(login "$DST" app_sha 'Sha#Pass1' "SELECT CURRENT_ROLE()") == '`r_read`@`%`' ]] \
  || fail "--update-existing did not set the source password"
pass "--update-existing gives the existing account the source password; verify clean"

# --- re-run ---
res=$(imp --update-existing) || fail "re-run failed: $res"
grep -q 'failed statements: 0' <<<"$res" || fail "re-run had failures: $res"
pass "re-running is safe"

# --- export_mysql80.sh --with-users shares the logic ---
full=$("$HERE/export_mysql80.sh" --env-file "$WORK/.env" --out "$WORK/full" --db shop --with-users 2>/dev/null | tail -n1)
diff "$out/users.tsv" "$full/users.tsv" >/dev/null || fail "--with-users output differs from export_users_mysql80.sh"
grep -q ' ./users.tsv$' "$full/SHA256SUMS" || fail "users.tsv not in SHA256SUMS"
pass "export_mysql80.sh --with-users writes the same users.tsv"

echo "ALL TESTS PASSED"
