# MySQL 8.0 → 8.4 migration scripts

Two scripts copy every user database from a MySQL 8.0 server to a MySQL 8.4 server.
Two more copy the accounts (with their passwords) and grants on their own; see
[Accounts and grants](#accounts-and-grants).
The export writes one self-contained SQL file per database, and the dumps are always
made by a **MySQL 8.4 `mysqldump`**.

```bash
cp .env.example .env            # fill in SRC_* (8.0) and DST_* (8.4)
./export_mysql80.sh --with-users --row-counts
./import_mysql84.sh --dir exports/<timestamp>
```

## What gets exported

`exports/<timestamp>/`

| File | Contents |
|---|---|
| `databases/<db>.sql` | `CREATE DATABASE` + `USE`, then tables, data, views, procedures, functions, triggers and events |
| `users.sql`, `users.tsv` | (with `--with-users`) accounts and grants; see [Accounts and grants](#accounts-and-grants) |
| `manifest.tsv` | Per-database count of tables, views, procedures, functions, triggers and events |
| `rowcounts/<db>.tsv` | (with `--row-counts`) Exact row count for each table |
| `preflight.txt` | Things that dump cleanly but will break on 8.4 (see below) |
| `SHA256SUMS` | Checksums of the SQL files. The import verifies them first, so the export folder can be copied safely between hosts. |

The system schemas (`mysql`, `sys`, `information_schema`, `performance_schema`)
are never exported. Use `--db NAME` or `--exclude NAME` (both repeatable) to
choose which databases to export.

Key `mysqldump` options:
* `--single-transaction`: consistent snapshot with no locks, for InnoDB.
* `--routines --triggers --events`: include procedures, functions, triggers and events.
* `--hex-blob`: write binary columns as hex so they survive any client charset.
* `--set-gtid-purged=OFF`: don't carry the source's GTID set to the target.
* `--no-tablespaces`: avoids needing the PROCESS privilege.

## Where the 8.4 mysqldump comes from

If `mysqldump` on PATH reports 8.4, or `MYSQL_BIN_DIR` points at an 8.4 install,
the scripts use it. Otherwise they run the client tools from the `mysql:8.4`
Docker image with `--network host`. The script exits if the tool it finds is not
version 8.4. Passwords go to the tools through a temporary 0600 option file and
never appear on the command line.

## Import behaviour

1. The import checks the SHA256SUMS, then warns about target settings that will
   cause trouble: binary logging on with `log_bin_trust_function_creators=0`, and
   `mysql_native_password` accounts when that plugin is inactive.
2. Accounts are created first, so DEFINERs resolve. Grants are applied after the
   databases, because table and column grants need the tables. Each statement
   runs on its own, so one bad account doesn't stop the rest. Failures go to
   `users.log`, and the accounts are then verified (see below).
3. Each database is imported in turn. A database that already exists and is
   non-empty is **skipped** unless you pass `--overwrite`, which drops it and
   re-imports it. A database stops at its first error; the script records the
   failure and moves on to the next database.
4. Object counts, and row counts if they were exported, are compared with the
   manifest. The script exits non-zero if any database failed or didn't match.

Logs are written to `<export dir>/import-logs/<timestamp>/`.

## Accounts and grants

```bash
./export_users_mysql80.sh                       # -> exports/users_<timestamp>/
./export_mysql80.sh --skip-broken-views
./import_users_mysql84.sh --dir exports/users_<timestamp> --dry-run
./import_users_mysql84.sh --dir exports/users_<timestamp> [--update-existing]
```

`export_mysql80.sh --with-users` runs the same code (`lib/users.sh`), and
`import_mysql84.sh` applies its output, so you can use either route.

**Export.** One `CREATE USER IF NOT EXISTS` per account, with the original
password hash hex-encoded, so no password needs to be known or reset. Then every
line of `SHOW GRANTS`, then `ALTER USER ... DEFAULT ROLE`, which comes last
because the role grants must exist first. `users.tsv` holds these statements
with the account each one belongs to; the import and verify steps read it.
`users.sql` is the same statements as a plain script. The folder is created
readable by you only, because it contains password hashes.

* Never exported: `root`, `mysql.*`, `debian-sys-maint`, the anonymous user, and the
  accounts a DigitalOcean managed server creates itself: `doadmin`, `optadmin`,
  `repluser`, `metrics_user_*`.
* `--user NAME` exports only that user name, and `--exclude-user NAME` skips one
  more. Both are repeatable.
* `SET_USER_ID` was removed in 8.4. Its grants become `SET_ANY_DEFINER,ALLOW_NONEXISTENT_DEFINER`.

**Import.** Run it after the databases are imported. Accounts that are new on the
target are created. An account that already exists keeps its password and
options, and only gets the missing grants. Pass `--update-existing` to give it
the source's password and options too. `--dry-run` prints the statements with
the hashes masked. Re-running is safe.

**Verify.** For every exported account, the target must have the same auth
plugin, password hash and lock state, and every exported grant. Grants are
compared one privilege at a time, so differences in how 8.0 and 8.4 order or
group them don't count. Grants found only on the target are listed, not removed.
The script exits non-zero if a statement failed or something is missing.

## Copying individual tables

```bash
./copy_tables.sh --db Trading --table Stock_Options --table Orders
./copy_tables.sh --db Trading --table Stock_Options --target-db Trading_copy
```

`copy_tables.sh` dumps the named tables from the source (`SRC_*`) and restores
them on the target (`DST_*`), **overwriting** them there. Each table is dropped
and re-created with its data and triggers. Other tables in the target database,
and the FKs they hold into the copied tables, are left alone.

It writes `exports/tables_<timestamp>/`:

| File | Contents |
|---|---|
| `source.sql` | The tables as dumped from the source |
| `target-before.sql` | The target's copy of those tables before the overwrite. Undo with `mysql TARGET_DB < target-before.sql`. Skipped with `--no-target-backup`. |
| `rowcounts.tsv` | Source row counts, compared with the target after the restore |
| `restore.log`, `SHA256SUMS` | |

* The script logs which server and account it reached on each side. It refuses
  to run when the source and target are the same server and database.
* `--target-db NAME` restores into another database. If that database doesn't
  exist, it is created with the source's charset and collation.
* `--strip-definers` removes the DEFINER from triggers.
* **Lock test.** Before any dump, the script runs `LOCK TABLES ... WRITE` on the
  target's existing copies of the tables, and waits at most
  `--lock-wait-timeout` seconds (default 10). If another session holds a table
  (usually an uncommitted transaction left open in a SQL client), the script
  lists that session's id, user@host and idle time, and tells you to close
  anything connected to the table or `KILL` the session. It then exits without
  changing the target. The restore runs with the same timeout. Without it,
  `DROP TABLE` would wait up to a year (`lock_wait_timeout`'s default), and every
  query on that table would queue behind it.
* The overwrite is not atomic. While a table is being restored, readers on the
  target see it missing or partly loaded. Row counts match exactly only if
  nothing writes to the source during the copy. A mismatch exits non-zero.

## 8.0 → 8.4 gotchas (check `preflight.txt`)

* **Foreign keys must reference a full PRIMARY/UNIQUE key.** 8.4 sets
  `restrict_fk_on_non_standard_key=ON`. The preflight lists the offending FKs.
  Either fix the schema (add a UNIQUE key) or set `restrict_fk_on_non_standard_key=OFF`
  on the target while importing.
* **`mysql_native_password` is disabled by default.** Add `mysql_native_password=ON`
  to the target's `my.cnf`, or move those accounts to `caching_sha2_password`.
* **DEFINER accounts must exist on the target.** Use `--with-users`. Alternatively,
  `--strip-definers` makes the importing user the definer of every object.
* **Stored routine bodies are copied verbatim.** An unquoted identifier that became
  a reserved word in 8.4 will fail there. The import log shows the exact line.
* Row counts are exact only if nothing writes to the source during the export.
  Stop the application writers for the final cutover export.

## Tests

`tests/roundtrip_test.sh` starts throwaway `mysql:8.0` and `mysql:8.4` containers
on ports 33080 and 33084. It seeds a utf8mb4/blob/escaped-string table, an FK,
a view, a procedure with a non-root DEFINER, a function, a trigger, an event, a
hyphenated database name and an app account. It then exports, imports and checks
that everything works on 8.4: the routines run, the trigger fires, the account
logs in with its original password, re-runs skip or `--overwrite` as expected,
`--strip-definers` works, and an FK that is incompatible with 8.4 is flagged and
reported as a failure.

`tests/users_roundtrip_test.sh` does the same for accounts, on ports 33180 and
33184. It seeds a `caching_sha2_password` account, a `mysql_native_password`
account, a locked account, a role set as a default role, column- and table-level
grants with GRANT OPTION, `SET_USER_ID`, platform accounts (`doadmin`,
`repluser`), and a grant on a table missing from the target. It checks:

* the platform accounts are skipped and `--user` works;
* the export is private;
* `--dry-run` changes nothing and masks hashes;
* every account logs in on 8.4 with its original password, and the locked one stays locked;
* `SET_ANY_DEFINER` is granted and the default role is active;
* a pre-existing account keeps its password until `--update-existing`;
* the failed grant is named per account and verify flags it;
* a re-run is clean;
* `export_mysql80.sh --with-users` writes an identical `users.tsv`.

`tests/copy_tables_test.sh` tests `copy_tables.sh`, on ports 33280 and 33284. The
target starts with an older version of each table: a missing column, stale
rows, an old trigger, and an FK from another table into one of the copied
tables. It checks:

* the backup is made by mysqldump 8.4 and its checksums match;
* the target tables get the source schema and rows;
* utf8mb4, blob and escaped data come through intact;
* the source trigger replaces the old one and fires;
* tables that were not named are left alone;
* `target-before.sql` restores the previous state;
* `--target-db` creates the database with the source collation;
* a missing source table stops the script before the target is touched;
* with a session holding an open transaction on a target table, the lock test
  fails within the timeout, names the session, and changes nothing, and no
  session is left waiting for the lock;
* once that session is gone, the copy goes through;
* copying a table onto itself is refused.

Each test takes about 2 minutes and needs Docker.
