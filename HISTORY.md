# HISTORY

## 2026-10-11 — Initial export/import scripts for MySQL 8.0 → 8.4

**Goal.** Move every database from a MySQL 8.0 server to MySQL 8.4. Each database
becomes one self-contained SQL file covering data, views, procedures, functions,
triggers and events, and the file is produced by an 8.4 `mysqldump`.

**Implementation.**
- `lib/common.sh`: chooses the client tools. It uses a local 8.4 client if there
  is one; otherwise the `mysql:8.4` Docker image, because the host has 8.0.46. It
  also writes a 0600 option file for credentials, holds the SQL quoting helpers,
  and runs the object-count and row-count queries.
- `export_mysql80.sh`: dumps one file per database with `--databases` and
  `--single-transaction --routines --triggers --events --hex-blob
  --set-gtid-purged=OFF --no-tablespaces --add-drop-trigger`. It writes
  `manifest.tsv`, `preflight.txt` (FKs on non-unique keys and
  mysql_native_password accounts) and `SHA256SUMS`. Optional flags:
  `--with-users` (hex auth strings via `print_identified_with_as_hex`),
  `--strip-definers` and `--row-counts`.
- `import_mysql84.sh`: verifies the checksums, runs preflight warnings, applies
  `users.sql` first, then imports each database. Existing databases are skipped
  unless `--overwrite` is given. It verifies counts against the manifest and
  exits non-zero on any failure or mismatch.

**Related files.** `export_mysql80.sh`, `import_mysql84.sh`, `lib/common.sh`,
`.env.example`, `.gitignore`, `README.md`, `tests/roundtrip_test.sh`.

**Test coverage.** Added `tests/roundtrip_test.sh`: an end-to-end round trip
between real 8.0.46 and 8.4.11 containers. Result: 12/12 checks pass. The
checks cover the 8.4 dump header, manifest counts, utf8mb4/blob/escape fidelity,
the routines/trigger/view working on 8.4, DEFINER preservation, the hyphenated
database name, the migrated account logging in with its original password,
skip-on-rerun, `--overwrite`, `--strip-definers`, the incompatible FK being
flagged in preflight, and that FK being reported as a failed import.

## 2026-10-11 — Debug listing of source databases before screening

**Goal.** The export seemed to skip some databases on the source. It now logs
every database the source reports, and what happens to each one, so the cause
is visible.

**Implementation.** `export_mysql80.sh` logs `CURRENT_USER()`. It then reads
`information_schema.schemata` without the system-schema filter and logs every
schema (to stderr) with one tag: `[skip: system schema]`, `[skip: not in --db]`,
`[skip: --exclude]` or `[selected]`. The system-schema filter now runs in bash
instead of SQL. Which databases get selected is unchanged.

**Finding (not yet fixed).** The debug output showed the export connecting as
`sgmcp@%` instead of the account in the env file. The cause is that
`run_tool()` passes `--defaults-extra-file`, and MySQL reads `~/.my.cnf`
*after* that file. So with a local 8.4 client, `~/.my.cnf` replaces
host/port/user/password. Docker mode doesn't mount `~/.my.cnf`, so it was not
affected.

**Related files.** `export_mysql80.sh`.

**Test coverage.** `bash -n` passes. `tests/roundtrip_test.sh` currently
fails with "export files missing". The failure comes from the `~/.my.cnf`
override above: the export reached the real server instead of the test
container. It is not caused by this change. No tests were added or removed.

## 2026-10-11 — `--skip-broken-views` for views that no longer compile on the source

**Goal.** The export aborted on `Trading`. mysqldump failed with error 1356
on `Trading.stock_options_vw`.

**Root cause.** The view is broken on the source itself. It joins
`Trading.Stock_Options_Status`, a table that no longer exists. Its columns
appear to have moved into `Stock_Options`. mysqldump runs `SHOW FIELDS` on
every view, so one broken view makes the whole database fail.

**Implementation.** In `export_mysql80.sh`, after preflight, the script finds
broken views in the selected databases (`information_schema.tables`, VIEW rows
whose `table_comment` contains "references invalid"). It writes their names and
definitions to `preflight.txt`.
- Without the flag: the script stops before any dump and names the views.
  Before, it failed partway through the dumps.
- With `--skip-broken-views`: each view is passed to mysqldump as
  `--ignore-table=db.view`, and a warning is logged. The view count in
  `manifest.tsv` is reduced by the number skipped, so the import's verify step
  still matches.

**Related files.** `export_mysql80.sh`.

**Test coverage.** Ran by hand against a throwaway `mysql:8.0` container: one
working view, plus one view broken by dropping its base table. Without the flag
the script exits 1 with the hint. With the flag it exports both databases. The
broken view is missing from the dump and the working view is present, the
manifest shows views=1, and `preflight.txt` holds the broken view's definition.
This case is not yet in `tests/roundtrip_test.sh`.

## 2026-10-11 — Write views that could not be exported to `manual/broken_views.sql`

**Goal.** Keep the views left out by `--skip-broken-views` in a file, so they
can be fixed and applied by hand later.

**Implementation.** `export_mysql80.sh` now writes
`<out>/manual/broken_views.sql` whenever it finds broken views, with or without
the flag. The file has one block per view: a comment with the source's error
text, then a complete `CREATE OR REPLACE [DEFINER=...] SQL SECURITY ... VIEW db.view
AS ... [WITH ... CHECK OPTION];` statement. The statement
is built from `information_schema.views`. DEFINER is left out under
`--strip-definers`, and identifiers containing backticks are escaped.
`preflight.txt` now lists only the view names and points to the file.
`SHA256SUMS` covers the file. `import_mysql84.sh` never applies it, because it
reads only `databases/*.sql` and `users.sql`.

**Related files.** `export_mysql80.sh`.

**Test coverage.** Ran by hand against a throwaway `mysql:8.0` container with
two broken views: one plain, and one with SQL SECURITY INVOKER, a CHECK OPTION
and a backtick in its name. Results: the file is written both with and without
the flag; both views are absent from the dump and the manifest shows views=1;
the `--strip-definers` variant has no DEFINER. After the missing table was
recreated on a fresh server, the file applied with exit 0 and both views
compiled. `tests/roundtrip_test.sh` does not cover this yet.

## 2026-10-11 — Separate scripts to export and import accounts and grants

**Goal.** Move every account, with its password and permissions, from the 8.0
source to the 8.4 target, separately from the database export and import.

**Root cause of the problems with `--with-users`.**
- It skipped only `root` and `mysql.*`. On DigitalOcean that would export the
  platform's own accounts (`doadmin`, `optadmin`, `repluser`, `metrics_user_*`),
  which already exist on the target and are managed by the platform.
- `SET_USER_ID` grants fail on 8.4, which removed that privilege.
- A `DEFAULT ROLE` inside `CREATE USER` fails when the role is created later.
- Grants were applied before the databases, so table and column grants failed
  because the tables did not exist yet.
- All statements ran in one `mysql --force`, so failures could not be traced
  to an account, and nothing was verified.

**Implementation.**
- New `lib/users.sh`, used by every route:
  - `export_users` writes `users.tsv` (kind, account, statement) and
    `users.sql`, with umask 077. It skips system and platform accounts and
    logs every account as skipped or exported. The hex-encoded hash is kept,
    `DEFAULT ROLE` is moved into a trailing `ALTER USER`, and `SET_USER_ID`
    becomes `SET_ANY_DEFINER,ALLOW_NONEXISTENT_DEFINER`.
  - `apply_users` runs each statement on its own, in an accounts phase or a
    grants phase. Accounts that already exist are left alone unless
    `USERS_UPDATE_EXISTING=1`, which turns their `CREATE USER` into
    `ALTER USER`. It has a dry-run mode, masks hashes in logs, and warns about
    `mysql_native_password` when that plugin is inactive.
  - `verify_users` compares the plugin, the hash (as hex), the lock state, and
    the grants one privilege at a time (`grant_atoms`).
- New `export_users_mysql80.sh`, with `--user`, `--exclude-user` and `--out`.
  It writes `exports/users_<ts>/` with mode 700 and a `SHA256SUMS`.
- New `import_users_mysql84.sh`, with `--update-existing`, `--dry-run` and
  `--no-verify`. It exits non-zero on a failed statement or a verify difference.
- `export_mysql80.sh --with-users` now calls `export_users`, and
  `SHA256SUMS` covers `users.tsv`.
- `import_mysql84.sh` creates the accounts before the databases and applies the
  grants after them, then verifies the accounts. Account problems are still
  warnings only, so its exit code is unchanged. Exports that have only a
  `users.sql` still apply the old way.
- README has a new "Accounts and grants" section, and the old
  DEFAULT ROLE gotcha is removed.

**Source and target as found (read-only check).** The source is DO MySQL 8.0.45
with 15 accounts: 14 use caching_sha2 and 1 uses native; there are no roles,
partial_revokes=ON, and one account holds SET_USER_ID. The target is DO 8.4.11,
with mysql_native_password ACTIVE and `thomas@%` already present. The accounts
to migrate are dbtester, fund-ops, fund_alloc, sgmcp, sso_app and thomas.

**Related files.** `lib/users.sh` (new), `export_users_mysql80.sh` (new),
`import_users_mysql84.sh` (new), `tests/users_roundtrip_test.sh` (new),
`export_mysql80.sh`, `import_mysql84.sh`, `README.md`.

**Test coverage.**
- Added `tests/users_roundtrip_test.sh`, using containers on ports 33180/33184.
  All 13 checks pass: skip list, `--user`, private files, SET_USER_ID rewrite,
  DEFAULT ROLE ordering, dry run, per-account failure reporting and verify,
  native and caching_sha2 logins with the original passwords, locked account,
  SET_ANY_DEFINER, existing account kept and then synced by `--update-existing`,
  column, table and GRANT OPTION grants, re-run safety, and identical
  `--with-users` output.
- The existing `tests/roundtrip_test.sh` still passes (all 12 checks). No tests
  were removed.

## 2026-10-20 — `copy_tables.sh`: copy named tables and overwrite them on the target

**Goal.** Back up one or more tables from one server and restore them on
another, replacing the target's copy. Until now, the only way to do this was to
re-import a whole database with `import_mysql84.sh --overwrite`.

**Implementation.** New `copy_tables.sh` reuses `lib/common.sh`: the 8.4 client
tools, the 0600 option files, and the quoting helpers. It reads `SRC_*` and
`DST_*` from `.env`. Options: `--db`, `--table` (repeatable), `--target-db`,
`--out`, `--no-target-backup`, `--strip-definers` and `--no-verify`.
- It logs the version, account, host and port reached on each side. It refuses
  to run when both sides have the same `@@server_uuid` and the same database.
  Without that check, a misconfigured `.env` or `~/.my.cnf` could make the
  script drop the table it had just read.
- Before any dump, it checks that every named table exists as a base table on
  the source.
- It dumps the tables to `source.sql` without `--databases`, so the file has no
  `USE` and can go into any database. The dump options match the export
  script, plus `--triggers --add-drop-trigger`. It then records exact row
  counts.
- Unless `--no-target-backup` is given, it dumps the target's existing copy of
  the tables to `target-before.sql`, so the overwrite can be undone.
- If the target database is missing, it is created with the source's charset
  and collation. The script then restores without `--force`. The dump's
  `FOREIGN_KEY_CHECKS=0` lets it drop tables that other target tables reference.
- Finally it compares row counts with the source and exits non-zero on a
  mismatch.

**Related files.** `copy_tables.sh` (new), `tests/copy_tables_test.sh` (new),
`README.md`. `.env.example` is unchanged: the script uses no new variables.

**Test coverage.** Added `tests/copy_tables_test.sh`, a round trip between
8.0.46 and 8.4.11 containers on ports 33280/33284. All 9 checks pass: the 8.4
dump and checksums; the schema and rows replaced, including a new column and a
stale row removed; utf8mb4, blob and escape fidelity; the trigger replaced and
firing; tables not named left untouched, along with an FK into a copied table;
undo through `target-before.sql`; `--target-db` creating the database with the
source collation; a missing table stopping before the target is touched; and
the same-server refusal. The existing `tests/roundtrip_test.sh` (12/12) and
`tests/users_roundtrip_test.sh` (15/15) still pass. No tests were removed.

## 2026-10-20 — `copy_tables.sh`: test-lock target tables instead of hanging

**Goal.** Copying `Trading.ETF_Options_v1` (9,726 rows, a 1.2 MB dump) to the
DigitalOcean target looked very slow. In fact it hung in the restore and never
finished. The script should fail fast and say why.

**Root cause.** Session 305426 (`doadmin` from 174.74.216.72, most likely a SQL
client) had read the table inside a transaction that was never committed. It
had been idle for 41 minutes and still held a SHARED_READ metadata lock. The
restore's `DROP TABLE` needs an exclusive lock, so it sat in "Waiting for table
metadata lock". The target's `lock_wait_timeout` is 31,536,000 seconds (the
default), so it would have waited a year. While it waited, every new query on
that table on the target queued behind it.

**Implementation.** In `copy_tables.sh`:
- New `--lock-wait-timeout N` option (default 10).
- Before any dump, the script runs `SET SESSION lock_wait_timeout=N;
  LOCK TABLES <target tables> WRITE; UNLOCK TABLES` on the target. Only tables
  that already exist there are tested.
- On error 1205, `lock_blocked` reads `performance_schema.metadata_locks` and
  lists the sessions holding the tables: id, user@host, command, seconds and
  table. It advises closing anything connected to those tables (commit or roll
  back open client transactions, stop app connections) or `KILL`ing those
  sessions, then exits non-zero. Nothing has been dumped or changed at that
  point. Other errors from the lock test are reported as they are.
- The restore's `mysql` runs with `--init-command="SET SESSION
  lock_wait_timeout=N"`. A session that takes a table after the lock test
  therefore causes the same named-session failure, not a hang. That message
  also points to `target-before.sql`.

**Related files.** `copy_tables.sh`, `tests/copy_tables_test.sh`, `README.md`.

**Test coverage.** `tests/copy_tables_test.sh` has two new checks, 11/11 in
total. In the first, another session holds an open transaction on
`shop.customer`, and the copy with `--lock-wait-timeout 2` must:
- exit non-zero in under 30s;
- name that session's id and the table;
- give the advice to close connections;
- write no dump and leave the target rows unchanged;
- leave no session waiting on the lock.

In the second, after that session is killed, the copy succeeds. The
restore-time timeout (a lock taken after the test) has no automated test. The
existing `tests/roundtrip_test.sh` and `tests/users_roundtrip_test.sh` were
rerun with this change. No tests were removed.
