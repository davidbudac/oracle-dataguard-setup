#!/usr/bin/env bash
# ============================================================
# Unit tests for dg_check_srl.sh
# ============================================================
# Pure bash, no database: a stub `sqlplus` on PATH answers the checker's
# queries (dispatching on the SQL text) and a stub `dgmgrl` under
# $ORACLE_HOME/bin answers the DGConnectIdentifier lookup. Steered by env:
#   STUB_ORL         largest online redo log in MB (default 200; empty/0 =
#                    unreadable)
#   STUB_SRL_MB      size of every existing SRL in MB (default 200)
#   STUB_PEERS       comma-separated peer DB_UNIQUE_NAMEs the local database
#                    reports from V$DATAGUARD_CONFIG (default CDB1_STBY)
#   STUB_GOOD_ALIAS  space-separated aliases a peer CONNECT succeeds for
#                    (default CDB1_STBY); the peer DB_UNIQUE_NAME it answers
#                    with is the alias upper-cased
#   STUB_DGCONN      DGConnectIdentifier the stub dgmgrl returns (unset =
#                    a DGM- error, i.e. broker unavailable)
#   STUB_LOG         file every sqlplus stdin is appended to
#
# Usage: bash tests/test_check_srl.sh
#
# Don't use set -e as we need to test for failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT="$REPO_DIR/dg_check_srl.sh"

PASS=0
FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    missing: $needle"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  FAIL: $name"
        echo "    unexpectedly present: $needle"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    fi
}

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/dg_check_srl_test.XXXXXX") || {
    echo "FATAL: cannot create temp dir"; exit 1; }
trap 'rm -rf "$TEST_TMP"' EXIT

STUB_BIN="$TEST_TMP/bin"
ERR_FILE="$TEST_TMP/stderr.out"
mkdir -p "$STUB_BIN" "$TEST_TMP/oh/bin"

cat > "$STUB_BIN/sqlplus" <<'STUB'
#!/bin/bash
IN=$(cat)
if [[ -n "${STUB_LOG:-}" ]]; then printf '%s\n-----\n' "$IN" >> "$STUB_LOG"; fi
local_side="NO"
case "$IN" in *"CONNECT / as sysdba"*) local_side="YES" ;; esac
alias_used=$(printf '%s\n' "$IN" | sed -n 's/^CONNECT .*@\(.*\) as sysdba.*/\1/p' | head -1)
peer_du=$(printf '%s' "$alias_used" | tr 'a-z' 'A-Z')
if [[ "$local_side" == "NO" ]]; then
    ok="NO"
    for a in ${STUB_GOOD_ALIAS-CDB1_STBY}; do [[ "$a" == "$alias_used" ]] && ok="YES"; done
    if [[ "$ok" == "NO" ]]; then echo "ORA-12154: TNS:could not resolve" >&2; exit 1; fi
fi
case "$IN" in
*"SELECT 'OK' FROM DUAL"*)
    echo "OK" ;;
*"'~'||DATABASE_ROLE"*)
    if [[ "$local_side" == "YES" ]]; then echo "CDB1~PRIMARY"; else echo "${peer_du}~PHYSICAL STANDBY"; fi ;;
*"MAX(GROUP#)"*)
    echo "20" ;;
*"FROM V\$THREAD"*)
    printf '\t1:3:4:%s\n' "${STUB_SRL_MB-200}" ;;
*"NVL(THREAD#,0)=0"*)
    echo "0:0" ;;
*"MAX(BYTES)"*)
    printf '\t%s\n' "${STUB_ORL-200}" ;;
*"db_create_file_dest"*)
    echo "NO" ;;
*"TYPE='STANDBY'"*)
    echo "/u01/srl/" ;;
*"TYPE='ONLINE'"*)
    echo "/u01/orl/" ;;
*"LISTAGG"*)
    if [[ "$local_side" == "YES" ]]; then echo "${STUB_PEERS-CDB1_STBY}"; else echo "CDB1"; fi ;;
*)
    echo "STUB-UNKNOWN-QUERY"; exit 1 ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/sqlplus"

cat > "$TEST_TMP/oh/bin/dgmgrl" <<'STUB'
#!/bin/bash
if [[ -n "${STUB_DGCONN:-}" ]]; then
    echo "DGConnectIdentifier = '${STUB_DGCONN}'"
else
    echo "DGM-17016: failed to retrieve status for database"
fi
STUB
chmod +x "$TEST_TMP/oh/bin/dgmgrl"

# run_script [args...] - stdin is /dev/null unless a test pipes into it.
run_script() {
    OUT=$(PATH="$STUB_BIN:$PATH" ORACLE_SID=TESTSID ORACLE_HOME="$TEST_TMP/oh" \
          bash "$SCRIPT" "$@" 2>"$ERR_FILE" </dev/null)
    RC=$?
    ERR=$(cat "$ERR_FILE")
}

# ==== Test 1: arguments ====
echo "Test 1: argument handling"
run_script --help
assert_eq "help rc" "0" "$RC"
run_script --bogus
assert_eq "unknown option rc" "2" "$RC"
run_script -d
assert_eq "-d without a value rc" "2" "$RC"
assert_contains "-d without a value message" "$ERR" "requires a directory argument"

# ==== Test 2: compliant local-only run ====
echo "Test 2: compliant side"
run_script -L
assert_eq "compliant rc" "0" "$RC"
assert_contains "compliant result" "$OUT" "Result: OK - all 1 thread(s) have at least N+1 SRLs of at least 200 MB."

# ==== Test 3: SET DEFINE OFF precedes CONNECT (C1) ====
echo "Test 3: SET DEFINE OFF is the first line of every sqlplus session"
STUB_LOG="$TEST_TMP/q3.log"; : > "$STUB_LOG"; export STUB_LOG
printf 'Ab&cd1\n' | PATH="$STUB_BIN:$PATH" ORACLE_SID=TESTSID ORACLE_HOME="$TEST_TMP/oh" \
    bash "$SCRIPT" -p >"$TEST_TMP/p.out" 2>"$ERR_FILE"
RC=$?
unset STUB_LOG
FIRSTS=$(awk 'BEGIN{n=1} n==1{print; n=0} /^-----$/{n=1}' "$TEST_TMP/q3.log" | sort -u)
assert_eq "every session starts with SET DEFINE OFF" "SET DEFINE OFF" "$FIRSTS"
assert_eq "prompt-mode run rc" "0" "$RC"
assert_contains "password with & reaches CONNECT intact" "$(cat "$TEST_TMP/q3.log")" 'CONNECT sys/"Ab&cd1"@CDB1_STBY as sysdba'

# ==== Test 4: double quote in the -p password (LOW) ====
echo "Test 4: a double quote in the -p password is refused"
printf 'ab"cd\n' | PATH="$STUB_BIN:$PATH" ORACLE_SID=TESTSID ORACLE_HOME="$TEST_TMP/oh" \
    bash "$SCRIPT" -p >"$TEST_TMP/p.out" 2>"$ERR_FILE"
RC=$?
assert_eq "quoted password rc" "2" "$RC"
assert_contains "quoted password message" "$(cat "$ERR_FILE")" "contains a double quote"

# ==== Test 5: unreadable ORL size (LOW) ====
echo "Test 5: an unreadable online redo log size never produces SIZE 0M DDL"
for orl in "" 0 abc; do
    STUB_ORL="$orl"; export STUB_ORL
    run_script -L
    unset STUB_ORL
    assert_eq "ORL '$orl' rc" "2" "$RC"
    assert_contains "ORL '$orl' message" "$OUT" "could not read the online redo log size"
    assert_not_contains "ORL '$orl' prints no DDL" "$OUT" "SIZE 0M"
done

# ==== Test 6: SRL size direction (LOW) ====
echo "Test 6: larger SRLs are fine, smaller ones are a finding"
STUB_SRL_MB=400; export STUB_SRL_MB
run_script -L
unset STUB_SRL_MB
assert_eq "larger SRL rc" "0" "$RC"
assert_contains "larger SRL is OK" "$OUT" "Result: OK"
assert_not_contains "larger SRL is not undersized" "$OUT" "smaller than"
STUB_SRL_MB=100; export STUB_SRL_MB
run_script -L
unset STUB_SRL_MB
assert_eq "smaller SRL rc" "1" "$RC"
assert_contains "smaller SRL finding" "$OUT" "smaller than 200 MB"
assert_contains "smaller SRL query" "$OUT" "WHERE BYTES/1024/1024 < 200;"

# ==== Test 7: peer alias resolution (M24) ====
echo "Test 7: the peer is reached through its DGConnectIdentifier"
STUB_LOG="$TEST_TMP/q7.log"; : > "$STUB_LOG"; export STUB_LOG
STUB_DGCONN=cdb1_stby_tns STUB_GOOD_ALIAS=cdb1_stby_tns run_script
unset STUB_LOG
assert_eq "resolved alias rc" "0" "$RC"
assert_contains "wallet CONNECT uses the broker alias" "$(cat "$TEST_TMP/q7.log")" "CONNECT /@cdb1_stby_tns as sysdba"
assert_contains "peer summarised" "$OUT" "CDB1_STBY_TNS (PHYSICAL STANDBY)"
STUB_DGCONN= STUB_GOOD_ALIAS=CDB1_STBY run_script
assert_eq "broker unavailable falls back to DB_UNIQUE_NAME rc" "0" "$RC"
assert_contains "fallback peer summarised" "$OUT" "CDB1_STBY (PHYSICAL STANDBY)"
STUB_DGCONN=bogus_alias STUB_GOOD_ALIAS=CDB1_STBY run_script
assert_eq "bad broker alias retries the DB_UNIQUE_NAME rc" "0" "$RC"
STUB_GOOD_ALIAS=none run_script
assert_eq "unreachable peer rc" "1" "$RC"
assert_contains "unreachable peer unchecked" "$OUT" "UNCHECKED"
assert_contains "unreachable peer warned" "$ERR" "Could not reach peer 'CDB1_STBY' via wallet"

# ==== Test 8: more than one peer (LOW) ====
echo "Test 8: every peer is checked"
STUB_PEERS="CDB1_STBY,CDB1_STBY2" STUB_GOOD_ALIAS="CDB1_STBY CDB1_STBY2" run_script
assert_eq "two peers rc" "0" "$RC"
assert_contains "first peer summarised" "$OUT" "CDB1_STBY (PHYSICAL STANDBY)"
assert_contains "second peer summarised" "$OUT" "CDB1_STBY2 (PHYSICAL STANDBY)"
STUB_PEERS="CDB1_STBY,CDB1_STBY2" STUB_GOOD_ALIAS="CDB1_STBY" run_script
assert_eq "one of two peers unreachable rc" "1" "$RC"
assert_contains "the unreachable peer is listed" "$OUT" "CDB1_STBY2 (peer)"
STUB_PEERS="CDB1_STBY,CDB1_STBY2" run_script -L
assert_eq "-L skips every peer rc" "0" "$RC"
assert_not_contains "-L reports no peer" "$OUT" "CDB1_STBY"

# ==== Test 9: the stty guard is wired ====
echo "Test 9: the password prompt restores the terminal on interrupt"
PROMPT_FN=$(sed -n '/^read_peer_password() {/,/^}$/p' "$SCRIPT")
assert_contains "INT trap restores echo" "$PROMPT_FN" "trap 'stty echo 2>/dev/null || true; printf \"\\n\" >&2; exit 130' INT"
assert_contains "TERM trap restores echo" "$PROMPT_FN" "exit 143' TERM"

echo ""
echo "Test Summary: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
