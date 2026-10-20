#!/usr/bin/env bash
# End-to-end test: throwaway MySQL 8.0 and 8.4 containers, seed the 8.0 one with
# every object kind, export, import into 8.4, and check the objects work there.
# Needs Docker; touches nothing outside its own containers and a temp dir.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=mig-test-src80 DST=mig-test-dst84 PW='T3st!pa"ss'
WORK=$(mktemp -d)
cleanup() { docker rm -f "$SRC" "$DST" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

docker rm -f "$SRC" "$DST" >/dev/null 2>&1 || true
docker run -d --name "$SRC" -e MYSQL_ROOT_PASSWORD="$PW" -p 127.0.0.1:33080:3306 mysql:8.0 >/dev/null
docker run -d --name "$DST" -e MYSQL_ROOT_PASSWORD="$PW" -p 127.0.0.1:33084:3306 mysql:8.4 \
  --log-bin-trust-function-creators=1 >/dev/null

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

src <<'SQL'
CREATE USER 'app'@'%' IDENTIFIED BY 'AppPass#1';
CREATE DATABASE shop CHARACTER SET utf8mb4;
CREATE DATABASE `odd-name` CHARACTER SET utf8mb4;
GRANT ALL ON shop.* TO 'app'@'%';
USE shop;
CREATE TABLE customer (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(100), avatar BLOB);
CREATE TABLE orders (id INT PRIMARY KEY AUTO_INCREMENT, customer_id INT, total DECIMAL(10,2),
  FOREIGN KEY (customer_id) REFERENCES customer(id));
CREATE TABLE audit (id INT AUTO_INCREMENT PRIMARY KEY, msg VARCHAR(200));
INSERT INTO customer (name, avatar) VALUES ('Zoë 🚀', 0x00FF10DEADBEEF), ('O''Brien\\x', NULL);
INSERT INTO orders (customer_id, total) VALUES (1, 9.99), (1, 20.00), (2, 5.50);
CREATE VIEW customer_totals AS
  SELECT c.name, SUM(o.total) AS total FROM customer c JOIN orders o ON o.customer_id = c.id GROUP BY c.name;
DELIMITER //
CREATE DEFINER='app'@'%' PROCEDURE add_order(IN cid INT, IN amt DECIMAL(10,2))
BEGIN INSERT INTO orders (customer_id, total) VALUES (cid, amt); END//
CREATE FUNCTION order_count(cid INT) RETURNS INT READS SQL DATA
BEGIN RETURN (SELECT COUNT(*) FROM orders WHERE customer_id = cid); END//
CREATE TRIGGER orders_ai AFTER INSERT ON orders FOR EACH ROW
BEGIN INSERT INTO audit (msg) VALUES (CONCAT('order ', NEW.id)); END//
DELIMITER ;
CREATE EVENT purge_audit ON SCHEDULE EVERY 1 DAY DO DELETE FROM audit WHERE id < 0;
USE `odd-name`;
CREATE TABLE t (k VARCHAR(10) PRIMARY KEY, v JSON);
INSERT INTO t VALUES ('a', '{"x": [1, 2]}');
SQL

cat >"$WORK/.env" <<EOF
SRC_HOST=127.0.0.1
SRC_PORT=33080
SRC_USER=root
SRC_PASSWORD='$PW'
DST_HOST=127.0.0.1
DST_PORT=33084
DST_USER=root
DST_PASSWORD='$PW'
EOF

# --- export ---
out=$("$HERE/export_mysql80.sh" --env-file "$WORK/.env" --out "$WORK/export" --with-users --row-counts | tail -n1)
[[ -f $out/databases/shop.sql && -f "$out/databases/odd-name.sql" ]] || fail "export files missing"
grep -q 'Server version.*8\.0' "$out/databases/shop.sql" || fail "dump header lacks source version"
head -n1 "$out/databases/shop.sql" | grep -q 'Distrib 8\.4\.' || fail "dump not produced by mysqldump 8.4"
pass "export used mysqldump 8.4 and produced one file per database"
grep -q $'^shop\t3\t1\t1\t1\t1\t1$' "$out/manifest.tsv" || fail "manifest counts wrong: $(cat "$out/manifest.tsv")"
pass "manifest records 3 tables, 1 view, 1 proc, 1 function, 1 trigger, 1 event"

# --- import ---
"$HERE/import_mysql84.sh" --env-file "$WORK/.env" --dir "$out" || fail "import reported failure"
pass "import + verify succeeded"

[[ $(dst -e "SELECT name FROM shop.customer WHERE id=1") == 'Zoë 🚀' ]] || fail "utf8mb4 data mangled"
[[ $(dst -e "SELECT HEX(avatar) FROM shop.customer WHERE id=1") == 00FF10DEADBEEF ]] || fail "blob mangled"
[[ $(dst -e "SELECT name FROM shop.customer WHERE id=2") == "O'Brien\\\\x" ]] || fail "escaping mangled"
pass "utf8mb4, binary and escaped data intact"
dst -e "CALL shop.add_order(2, 1.00)"
[[ $(dst -e "SELECT shop.order_count(2)") == 2 ]] || fail "procedure/function broken"
[[ $(dst -e "SELECT COUNT(*) FROM shop.audit") == 1 ]] || fail "trigger did not fire"
[[ $(dst -e "SELECT COUNT(*) FROM shop.customer_totals") == 2 ]] || fail "view broken"
[[ $(dst -e "SELECT definer FROM information_schema.routines WHERE routine_name='add_order'") == 'app@%' ]] \
  || fail "definer not preserved"
pass "procedure, function, trigger, view work on 8.4; DEFINER preserved"
[[ $(dst -e 'SELECT v->>"$.x[1]" FROM `odd-name`.t') == 2 ]] || fail "odd-name db / JSON broken"
pass "database with a hyphenated name imported"
docker exec "$DST" mysql -h127.0.0.1 -uapp -p'AppPass#1' -N -e "SELECT COUNT(*) FROM shop.orders" >/dev/null 2>&1 \
  || fail "migrated account cannot log in with its original password"
pass "migrated account logs in with its original password"

# --- re-run safety ---
rerun=$("$HERE/import_mysql84.sh" --env-file "$WORK/.env" --dir "$out" --skip-users 2>&1) \
  || fail "second import exited non-zero: $rerun"
grep -q 'skipped: 2' <<<"$rerun" || fail "second import did not skip existing databases: $rerun"
pass "re-import without --overwrite skips existing databases"
"$HERE/import_mysql84.sh" --env-file "$WORK/.env" --dir "$out" --skip-users --overwrite >/dev/null 2>&1 \
  || fail "--overwrite import failed"
[[ $(dst -e "SELECT COUNT(*) FROM shop.orders") == 3 ]] || fail "--overwrite did not restore original data"
pass "--overwrite drops and re-imports to the exported state"

# --- strip definers ---
"$HERE/export_mysql80.sh" --env-file "$WORK/.env" --out "$WORK/export2" --db shop --strip-definers >/dev/null 2>&1
! grep -v '^INSERT INTO' "$WORK/export2/databases/shop.sql" | grep -q 'DEFINER=`' || fail "definers not stripped"
pass "--strip-definers removes DEFINER clauses"

# --- 8.4 incompatibility: FK on a non-unique key is flagged, and import reports failure ---
src <<'SQL'
CREATE DATABASE legacy;
CREATE TABLE legacy.parent (id INT PRIMARY KEY, code INT, KEY (code));
CREATE TABLE legacy.child (id INT PRIMARY KEY, code INT, FOREIGN KEY (code) REFERENCES legacy.parent(code));
SQL
"$HERE/export_mysql80.sh" --env-file "$WORK/.env" --out "$WORK/export3" --db legacy >/dev/null 2>&1
grep -q 'legacy.child .* -> legacy.parent(code)' "$WORK/export3/preflight.txt" || fail "non-standard FK not flagged"
pass "preflight flags FK on a non-unique key"
if rerun=$("$HERE/import_mysql84.sh" --env-file "$WORK/.env" --dir "$WORK/export3" 2>&1); then
  fail "import of an 8.4-incompatible FK reported success"
fi
grep -q 'failed: 1' <<<"$rerun" || fail "failure not reported: $rerun"
pass "import exits non-zero and names the failed database"

echo "ALL TESTS PASSED"
