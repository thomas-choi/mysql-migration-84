# shellcheck shell=bash
# Account and grant migration, shared by export_mysql80.sh --with-users,
# export_users_mysql80.sh, import_mysql84.sh and import_users_mysql84.sh.
# Sourced after lib/common.sh, not executed.
#
# users.tsv holds one statement per row, in the order they are applied:
#   KIND <TAB> ACCOUNT <TAB> STATEMENT
#   create  CREATE USER IF NOT EXISTS ..., original password hash
#   grant   one line of SHOW GRANTS, rewritten where 8.4 differs
#   role    ALTER USER ... DEFAULT ROLE ... (needs the role grants first)
# ACCOUNT is 'user'@'host' as QUOTE() prints it.
# users.sql has the same statements as a plain script, for reading or applying by hand.

# Never exported: MySQL's own accounts, plus the accounts a DigitalOcean managed
# server creates and manages itself (they already exist on the target).
USERS_SKIP_DEFAULT=(root mysql.sys mysql.session mysql.infoschema debian-sys-maint ""
                    doadmin optadmin repluser metrics_user_datadog metrics_user_telegraf)

USERS_UPDATE_EXISTING=${USERS_UPDATE_EXISTING:-0}  # ALTER accounts that already exist
USERS_DRY_RUN=${USERS_DRY_RUN:-0}                  # print statements, change nothing
USERS_ERRORS=()                                    # "account<TAB>error" per failed statement
declare -A USERS_PREEXISTING=()                    # target accounts present before apply_users

# Replace password hashes with a placeholder, for anything printed or logged.
mask_hashes() { sed -E "s/ AS (0x[0-9A-Fa-f]+|'([^']|'')*')/ AS <hash>/"; }

# export_users CNF OUTDIR
# Writes OUTDIR/users.tsv and OUTDIR/users.sql. The USER_INCLUDE and
# USER_EXCLUDE arrays, if set, hold user names (any host) to keep or skip.
export_users() {
  local cnf=$1 out=$2 n acct row where
  local -a inc=(${USER_INCLUDE[@]+"${USER_INCLUDE[@]}"}) exc=(${USER_EXCLUDE[@]+"${USER_EXCLUDE[@]}"})
  local -a names=() accounts=()
  local -A default_roles=()

  query "$cnf" "SELECT COUNT(*) FROM mysql.user" >/dev/null \
    || die "cannot read mysql.user (the source account needs SELECT on mysql.*)"
  for n in "${USERS_SKIP_DEFAULT[@]}" ${exc[@]+"${exc[@]}"}; do names+=("$(sql_str "$n")"); done
  where="user NOT IN ($(IFS=,; echo "${names[*]}"))"
  if ((${#inc[@]})); then
    names=()
    for n in "${inc[@]}"; do names+=("$(sql_str "$n")"); done
    where+=" AND user IN ($(IFS=,; echo "${names[*]}"))"
  fi

  mapfile -t accounts < <(query "$cnf" "SELECT CONCAT(QUOTE(user),'@',QUOTE(host)) FROM mysql.user
                                        WHERE $where ORDER BY user, host")
  while IFS= read -r row; do
    log "  skip     $row"
  done < <(query "$cnf" "SELECT CONCAT(QUOTE(user),'@',QUOTE(host)) FROM mysql.user
                         WHERE NOT ($where) ORDER BY user, host")
  for acct in "${accounts[@]}"; do log "  export   $acct"; done
  for n in ${inc[@]+"${inc[@]}"}; do
    printf '%s\n' "${accounts[@]}" | grep -q "^$(sql_str "$n")@" || warn "--user $n: no such account"
  done

  while IFS=$'\t' read -r acct row; do default_roles[$acct]=$row; done < <(query "$cnf" "
    SELECT CONCAT(QUOTE(user),'@',QUOTE(host)),
           GROUP_CONCAT(CONCAT(QUOTE(default_role_user),'@',QUOTE(default_role_host)) SEPARATOR ',')
    FROM mysql.default_roles GROUP BY user, host")

  (umask 077
   {
     # Every CREATE USER first, so role grants resolve whatever the order.
     for acct in "${accounts[@]}"; do
       # Hex-encoded auth strings survive the text round-trip (caching_sha2 hashes are binary).
       row=$(query "$cnf" "SET SESSION print_identified_with_as_hex=ON; SHOW CREATE USER $acct") \
         || die "SHOW CREATE USER $acct failed"
       # DEFAULT ROLE moves to the end: the roles are not granted yet at this point.
       row=$(sed -E 's/^CREATE USER /CREATE USER IF NOT EXISTS /
                     s/ DEFAULT ROLE (`([^`]|``)*`@`([^`]|``)*`,?)+//' <<<"$row")
       printf 'create\t%s\t%s;\n' "$acct" "$row"
     done
     for acct in "${accounts[@]}"; do
       # SET_USER_ID is gone in 8.4; SET_ANY_DEFINER + ALLOW_NONEXISTENT_DEFINER replace it.
       query "$cnf" "SHOW GRANTS FOR $acct" \
         | sed -E 's/([ ,])SET_USER_ID([ ,])/\1SET_ANY_DEFINER,ALLOW_NONEXISTENT_DEFINER\2/' \
         | while IFS= read -r row; do printf 'grant\t%s\t%s;\n' "$acct" "$row"; done
     done
     for acct in "${accounts[@]}"; do
       [[ -n ${default_roles[$acct]:-} ]] \
         && printf 'role\t%s\tALTER USER %s DEFAULT ROLE %s;\n' "$acct" "$acct" "${default_roles[$acct]}"
     done
   } >"$out/users.tsv"

   {
     echo "-- Accounts and grants exported from $SRC_HOST:$SRC_PORT ($SRC_VERSION) on $(date -Is)"
     echo "-- CREATE USER statements first, then grants, then default roles."
     echo "-- Table- and column-level grants need the tables, so apply after the databases."
     cut -f3- "$out/users.tsv"
   } >"$out/users.sql"
  )
  log "  ${#accounts[@]} accounts -> $out/users.tsv, $out/users.sql"
}

# apply_users CNF DIR PHASE LOGFILE
# PHASE accounts: CREATE USER for new accounts; with USERS_UPDATE_EXISTING=1,
#   ALTER USER brings accounts that already exist in line with the source.
# PHASE grants: GRANT/REVOKE, then default roles. PHASE all: both.
# Each statement runs on its own, so one failure names its account and does not
# stop the rest. Failures go to USERS_ERRORS and LOGFILE (hashes masked).
apply_users() {
  local cnf=$1 dir=$2 phase=$3 logf=$4 tsv=$2/users.tsv kind acct stmt err status
  if [[ ! -f $tsv ]]; then
    # Export made before users.tsv existed: run the plain script once.
    [[ $phase == grants ]] && return 0
    run_tool "$cnf" mysql --force <"$dir/users.sql" 2>>"$logf" || true
    grep -q '^ERROR' "$logf" && USERS_ERRORS+=("(users.sql)"$'\t'"$(grep -c '^ERROR' "$logf") statement(s) failed")
    return 0
  fi

  if [[ $phase != grants ]]; then
    USERS_PREEXISTING=()
    while IFS= read -r acct; do USERS_PREEXISTING[$acct]=1; done \
      < <(query "$cnf" "SELECT CONCAT(QUOTE(user),'@',QUOTE(host)) FROM mysql.user")
    if grep -q "IDENTIFIED WITH 'mysql_native_password'" "$tsv"; then
      status=$(query "$cnf" "SELECT plugin_status FROM information_schema.plugins
                             WHERE plugin_name='mysql_native_password'")
      [[ $status == ACTIVE ]] || warn "some accounts use mysql_native_password, which is not active on" \
        "the target (add mysql_native_password=ON to my.cnf, or re-create those users)"
    fi
  fi

  while IFS=$'\t' read -r kind acct stmt; do
    case $phase:$kind in
      accounts:create | all:create | grants:grant | grants:role | all:grant | all:role) ;;
      *) continue ;;
    esac
    if [[ $kind == create && -n ${USERS_PREEXISTING[$acct]:-} ]]; then
      if ((!USERS_UPDATE_EXISTING)); then
        log "  $acct already exists - password and options left as they are (--update-existing syncs them)"
        continue
      fi
      stmt="ALTER USER ${stmt#CREATE USER IF NOT EXISTS }"
    fi
    if ((USERS_DRY_RUN)); then
      mask_hashes <<<"$stmt"
      continue
    fi
    if ! err=$(run_tool "$cnf" mysql <<<"$stmt" 2>&1); then
      printf '%s\n%s\n\n' "$stmt" "$err" | mask_hashes >>"$logf"
      USERS_ERRORS+=("$acct"$'\t'"$(grep -m1 '^ERROR' <<<"$err" || echo "$err")")
    fi
  done <"$tsv"
}

# Split GRANT/REVOKE lines ("account<TAB>statement") into one row per privilege:
# account, verb, privilege, object, option. Server-side formatting differences
# (privilege order, how dynamic privileges are grouped) then compare equal.
grant_atoms() {
  awk -F'\t' -v OFS='\t' '
  {
    acct = $1; s = $2; sub(/;$/, "", s)
    opt = ""
    if (match(s, / WITH (GRANT|ADMIN) OPTION$/)) { opt = substr(s, RSTART + 1); s = substr(s, 1, RSTART - 1) }
    verb = substr(s, 1, index(s, " ") - 1); s = substr(s, length(verb) + 2)
    n = 0; depth = 0; q = ""; cur = ""; on = 0
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (q != "") { cur = cur c; if (c == q) q = ""; continue }
      if (c == "`" || c == "\047") { q = c; cur = cur c; continue }
      if (c == "(") depth++
      if (c == ")") depth--
      if (depth == 0 && c == ",") { priv[++n] = cur; cur = ""; continue }
      if (depth == 0 && substr(s, i, 4) == " ON ") { priv[++n] = cur; on = i + 4; break }
      cur = cur c
    }
    if (!on) {  # role grant: GRANT `r`@`h` TO account
      sub(/ (TO|FROM) [`\047].*$/, "", s); print acct, verb, "ROLE", s, opt; next
    }
    obj = substr(s, on); sub(/ (TO|FROM) [`\047].*$/, "", obj)
    for (k = 1; k <= n; k++) {
      p = priv[k]; gsub(/^ +| +$/, "", p)
      if (p != "USAGE") print acct, verb, p, obj, opt
    }
    delete priv
  }'
}

# Hex of the password hash in a CREATE USER statement (AS 0x... or AS '...').
stmt_hash_hex() {
  local h
  h=$(sed -nE 's/.* AS 0x([0-9A-Fa-f]+).*/\1/p' <<<"$1")
  if [[ -z $h ]]; then
    h=$(sed -nE "s/.* AS '(([^']|'')*)'.*/\1/p" <<<"$1")
    h=$(printf '%s' "${h//\'\'/\'}" | od -An -tx1 | tr -d ' \n')
  fi
  printf '%s' "${h^^}"
}

# verify_users CNF DIR
# Compares every exported account on the target with users.tsv: it must exist
# with the same plugin, password hash and lock state, and hold every exported
# grant. Accounts that existed before the import and were not updated are only
# reported. Returns 0 when nothing is wrong.
verify_users() {
  local cnf=$1 tsv=$2/users.tsv kind acct stmt plugin locked t_plugin t_locked t_hash diffs bad=0 line
  local -A target=() exported=()
  [[ -f $tsv ]] || { log "  no users.tsv (older export) - account verification skipped"; return 0; }

  while IFS=$'\t' read -r acct t_plugin t_locked t_hash; do
    target[$acct]="$t_plugin"$'\t'"$t_locked"$'\t'"$t_hash"
  done < <(query "$cnf" "SELECT CONCAT(QUOTE(user),'@',QUOTE(host)), plugin, account_locked,
                                HEX(authentication_string) FROM mysql.user")

  while IFS=$'\t' read -r kind acct stmt; do
    [[ $kind == create ]] || continue
    exported[$acct]=1
    if [[ -z ${target[$acct]+x} ]]; then
      warn "  $acct: missing on target"; bad=1; continue
    fi
    IFS=$'\t' read -r t_plugin t_locked t_hash <<<"${target[$acct]}"
    plugin=$(sed -nE "s/.* IDENTIFIED WITH '([^']+)'.*/\1/p" <<<"$stmt")
    locked=N; [[ $stmt == *" ACCOUNT LOCK "* || $stmt == *" ACCOUNT LOCK;" ]] && locked=Y
    diffs=""
    [[ $plugin == "$t_plugin" ]] || diffs+=" plugin=$t_plugin (source $plugin)"
    [[ $(stmt_hash_hex "$stmt") == "${t_hash^^}" ]] || diffs+=" password"
    [[ $locked == "$t_locked" ]] || diffs+=" locked=$t_locked (source $locked)"
    if [[ -z $diffs ]]; then continue; fi
    if [[ -n ${USERS_PREEXISTING[$acct]:-} ]] && ((!USERS_UPDATE_EXISTING)); then
      log "  $acct: existed before the import and differs:$diffs (--update-existing syncs it)"
    else
      warn "  $acct: differs from source:$diffs"; bad=1
    fi
  done <"$tsv"

  local src_atoms tgt_atoms
  src_atoms=$(awk -F'\t' -v OFS='\t' '$1 == "grant" {print $2, $3}' "$tsv" | grant_atoms | sort -u)
  tgt_atoms=$(for acct in "${!exported[@]}"; do
                [[ -n ${target[$acct]+x} ]] || continue
                query "$cnf" "SHOW GRANTS FOR $acct" | sed "s/^/$(sed 's/[\/&]/\\&/g' <<<"$acct")\t/"
              done | grant_atoms | sort -u)
  while IFS=$'\t' read -r acct kind stmt line t_plugin; do
    [[ -n ${target[$acct]+x} ]] || continue  # already reported as missing
    warn "  $acct: missing $kind $stmt ON $line${t_plugin:+ $t_plugin}"; bad=1
  done < <(comm -23 <(printf '%s\n' "$src_atoms") <(printf '%s\n' "$tgt_atoms") | sed '/^$/d')
  while IFS=$'\t' read -r acct kind stmt line t_plugin; do
    log "  $acct: also has $kind $stmt ON $line on target (not in source; left alone)"
  done < <(comm -13 <(printf '%s\n' "$src_atoms") <(printf '%s\n' "$tgt_atoms") | sed '/^$/d')
  ((!bad))
}
