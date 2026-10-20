#!/usr/bin/env bash
# End-to-end test for copy_tables.sh: throwaway MySQL 8.0 (source) and 8.4
# (target) containers. The target already holds older versions of the tables,
# plus a table that must survive and an FK that points at a copied table.
# Needs Docker; touches nothing outside its own containers and a temp dir.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=copy-test-src80 DST=copy-test-dst84 PW='T3st!pa"ss'
WORK=$(mktemp -d)
cleanup() { docker rm -f "$SRC" "$DST" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

docker rm -f "$SRC" "$DST" >/dev/null 2>&1 || true
docker run -d --name "$SRC" -e MYSQL_ROOT_PASSWORD="$PW" -p 127.0.0.1:33280:3306 mysql:8.0 >/dev/null
docker run -d --name "$DST" -e MYSQL_ROOT_PASSWORD="$PW" -p 127.0.0.1:33284:3306 mysql:8.4 \
  --log-bin-trust-function-creators=1 >/dev/null

wait_ready() {
  for _ in $(seq 90); do
    docker exec "$1" mysql -h127.0.0.1 -uroot -p"$PW" -e 'SELECT 1' >/dev/null 2>&1 && return 0
    sleep 2
  done
  fail "$1 did not start"
}
wait_ready "$SRC"; wait_ready "$DST"
src() { docker exec -i "$SRC" mysql -h127.0.0.1 -uroot -p"$PW" -N -B "$@" 2>/dev/null; }
dst() { docker exec -i "$DST" mysql -h127.0.0.1 -uroot -p"$PW" -N -B "$@" 2>/dev/null; }

src <<'SQL'
CREATE DATABASE shop CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE shop;
CREATE TABLE customer (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(100), avatar BLOB, tier INT);
CREATE TABLE orders (id INT PRIMARY KEY AUTO_INCREMENT, customer_id INT, total DECIMAL(10,2),
  FOREIGN KEY (customer_id) REFERENCES customer(id));
CREATE TABLE audit (id INT AUTO_INCREMENT PRIMARY KEY, msg VARCHAR(200));
CREATE TABLE not_copied (id INT PRIMARY KEY);
INSERT INTO customer (name, avatar, tier) VALUES ('Zoë 🚀', 0x00FF10DEADBEEF, 1), ('O''Brien\\x', NULL, 2), ('new', NULL, 3);
INSERT INTO orders (customer_id, total) VALUES (1, 9.99), (1, 20.00), (2, 5.50);
CREATE TRIGGER orders_ai AFTER INSERT ON orders FOR EACH ROW
  INSERT INTO audit (msg) VALUES (CONCAT('order ', NEW.id));
SQL

# Target: an older shape of customer (no tier column), stale rows, an old
# trigger name, a table that must not be touched, and an FK into customer.
dst <<'SQL'
CREATE DATABASE shop CHARACTER SET utf8mb4;
USE shop;
CREATE TABLE customer (id INT PRIMARY KEY, name VARCHAR(100), avatar BLOB);
INSERT INTO customer VALUES (1, 'stale', NULL), (99, 'only-on-target', NULL);
CREATE TABLE orders (id INT PRIMARY KEY, customer_id INT, total DECIMAL(10,2));
CREATE TABLE audit (id INT AUTO_INCREMENT PRIMARY KEY, msg VARCHAR(200));
CREATE TRIGGER orders_old AFTER INSERT ON orders FOR EACH ROW INSERT INTO audit (msg) VALUES ('old');
CREATE TABLE keepme (id INT PRIMARY KEY, customer_id INT, FOREIGN KEY (customer_id) REFERENCES customer(id));
INSERT INTO keepme VALUES (1, 1);
SQL

cat >"$WORK/.env" <<EOF
SRC_HOST=127.0.0.1
SRC_PORT=33280
SRC_USER=root
SRC_PASSWORD='$PW'
DST_HOST=127.0.0.1
DST_PORT=33284
DST_USER=root
DST_PASSWORD='$PW'
EOF

# --- copy and overwrite ---
out=$("$HERE/copy_tables.sh" --env-file "$WORK/.env" --out "$WORK/c1" --db shop \
      --table customer --table orders --table audit | tail -n1) || fail "copy reported failure"
[[ -f $out/source.sql && -f $out/target-before.sql && -f $out/SHA256SUMS ]] || fail "backup files missing"
(cd "$out" && sha256sum --quiet -c SHA256SUMS) || fail "SHA256SUMS does not match"
head -n1 "$out/source.sql" | grep -q 'Distrib 8\.4\.' || fail "dump not produced by mysqldump 8.4"
pass "backup written by mysqldump 8.4, checksummed"

[[ $(dst -e "SELECT COUNT(*) FROM shop.customer") == 3 ]] || fail "customer rows not replaced"
[[ $(dst -e "SELECT COUNT(*) FROM shop.customer WHERE id=99") == 0 ]] || fail "stale target row survived"
[[ $(dst -e "SELECT tier FROM shop.customer WHERE id=3") == 3 ]] || fail "new column missing on target"
pass "tables overwritten with source schema and rows"

[[ $(dst -e "SELECT name FROM shop.customer WHERE id=1") == 'Zoë 🚀' ]] || fail "utf8mb4 data mangled"
[[ $(dst -e "SELECT HEX(avatar) FROM shop.customer WHERE id=1") == 00FF10DEADBEEF ]] || fail "blob mangled"
[[ $(dst -e "SELECT name FROM shop.customer WHERE id=2") == "O'Brien\\\\x" ]] || fail "escaping mangled"
pass "utf8mb4, binary and escaped data intact"

[[ $(dst -e "SELECT GROUP_CONCAT(trigger_name) FROM information_schema.triggers WHERE event_object_table='orders'") \
   == orders_ai ]] || fail "triggers on orders not replaced"
dst -e "INSERT INTO shop.orders (customer_id, total) VALUES (2, 1.00)"
[[ $(dst -e "SELECT msg FROM shop.audit ORDER BY id DESC LIMIT 1") == 'order 4' ]] || fail "copied trigger did not fire"
pass "source trigger copied and fires; old target trigger gone"

[[ $(dst -e "SELECT customer_id FROM shop.keepme") == 1 ]] || fail "untouched table changed"
[[ $(dst -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='shop' AND table_name='not_copied'") == 0 ]] \
  || fail "a table that was not named was copied"
pass "only named tables copied; other target tables (and FKs into copied ones) untouched"

grep -q "only-on-target" "$out/target-before.sql" || fail "target-before.sql lacks the old target rows"
dst shop <"$out/target-before.sql" || fail "target-before.sql does not restore"
[[ $(dst -e "SELECT name FROM shop.customer WHERE id=99") == only-on-target ]] || fail "undo did not restore old rows"
pass "target-before.sql holds and restores the target's previous tables"

# --- new target database ---
"$HERE/copy_tables.sh" --env-file "$WORK/.env" --out "$WORK/c2" --db shop --table customer \
  --target-db shop_copy >/dev/null 2>&1 || fail "copy to a new database failed"
[[ $(dst -e "SELECT default_collation_name FROM information_schema.schemata WHERE schema_name='shop_copy'") \
   == utf8mb4_0900_ai_ci ]] || fail "target database not created with source collation"
[[ $(dst -e "SELECT COUNT(*) FROM shop_copy.customer") == 3 ]] || fail "rows missing in --target-db"
[[ ! -e $WORK/c2/target-before.sql ]] || fail "target-before.sql written although nothing existed"
pass "--target-db creates the database with the source collation"

# --- refusals ---
before=$(dst -e "SELECT COUNT(*) FROM shop.customer")
if msg=$("$HERE/copy_tables.sh" --env-file "$WORK/.env" --out "$WORK/c3" --db shop \
         --table customer --table nope 2>&1); then
  fail "missing table did not fail"
fi
grep -q 'no base table shop.nope on source' <<<"$msg" || fail "missing table not named: $msg"
[[ $(dst -e "SELECT COUNT(*) FROM shop.customer") == "$before" ]] || fail "target changed despite error"
pass "missing source table stops before touching the target"

# --- a session holding the target table: test lock fails fast, nothing changes ---
dst -e "START TRANSACTION; SELECT COUNT(*) FROM shop.customer; SELECT SLEEP(120);" >/dev/null &
holder_pid=$!
for _ in $(seq 20); do
  holder=$(dst -e "SELECT id FROM information_schema.processlist WHERE info LIKE 'SELECT SLEEP(120)%'")
  [[ -n $holder ]] && break; sleep 0.5
done
[[ -n $holder ]] || fail "lock-holding session did not start"
start=$SECONDS
if msg=$("$HERE/copy_tables.sh" --env-file "$WORK/.env" --out "$WORK/c5" --db shop --table customer \
         --lock-wait-timeout 2 2>&1); then
  fail "copy succeeded although the target table was held by another session"
fi
((SECONDS - start < 30)) || fail "lock test did not fail fast ($((SECONDS - start))s)"
grep -q 'target tables are locked - nothing was changed' <<<"$msg" || fail "lock failure not explained: $msg"
grep -q "id $holder .* on shop.customer" <<<"$msg" || fail "lock-holding session not named: $msg"
grep -q 'close anything connected to these tables' <<<"$msg" || fail "no advice to close connections: $msg"
[[ ! -e $WORK/c5/source.sql ]] || fail "dump ran although the lock test failed"
[[ $(dst -e "SELECT COUNT(*) FROM shop.customer") == "$before" ]] || fail "target changed despite lock failure"
[[ -z $(dst -e "SELECT id FROM information_schema.processlist WHERE state LIKE 'Waiting for table metadata lock'") ]] \
  || fail "a session was left waiting for the lock"
pass "held target table: lock test fails within the timeout, names the session, changes nothing"

dst -e "KILL $holder" || true
wait "$holder_pid" 2>/dev/null || true
"$HERE/copy_tables.sh" --env-file "$WORK/.env" --out "$WORK/c6" --db shop --table customer \
  --lock-wait-timeout 2 >/dev/null 2>&1 || fail "copy failed after the lock holder went away"
[[ $(dst -e "SELECT COUNT(*) FROM shop.customer") == 3 ]] || fail "rerun did not overwrite"
pass "once the holder is gone, the lock test passes and the copy finishes"

sed -i 's/^DST_PORT=.*/DST_PORT=33280/' "$WORK/.env"
if msg=$("$HERE/copy_tables.sh" --env-file "$WORK/.env" --out "$WORK/c4" --db shop --table customer 2>&1); then
  fail "same server and database was allowed"
fi
grep -q 'same server and database' <<<"$msg" || fail "same-server refusal not explained: $msg"
pass "refuses to overwrite a table with itself"

echo "ALL TESTS PASSED"
