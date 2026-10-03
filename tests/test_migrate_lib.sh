#!/usr/bin/env bash
# ============================================================
# Tests for migrate_noncdb_to_pdb/_lib.sh and the step 02/03/04 state ordering
# ============================================================
# Usage: bash tests/test_migrate_lib.sh
#
# DB-free: sqlplus is a stub on PATH that records argv/stdin per call and
# answers by pattern (OS-auth "/ as sysdba" = the local instances, "/@alias" =
# the standby through the wallet, "/nolog" + CONNECT = the standby through the
# SYS password). Covers
#   - run_sql / _standby_sqlplus: SET DEFINE OFF and WHENEVER SQLERROR before
#     the CONNECT, '&' in the password reaches sqlplus literally, the password
#     never appears in output or xtrace, a failed login returns non-zero (also
#     when sqlplus itself exits 0 after "SP2-0640: Not connected")
#   - standby_pw_problem (double quote / empty refused)
#   - wait_standby_scn: reached, apply lag, a query/connection error reported
#     as an error within a bounded number of calls (not waited out as lag),
#     an alias answering as PRIMARY or another database is an error
#   - schema-validity guards: no applied_scn / v$archive_dest_status in the
#     toolkit's SQL, every current_scn read through TO_CHAR
#   - steps 02/03/04: a refused re-run leaves state.env byte-identical (so
#     step 05's require_state plug_done still passes); a permitted attempt
#     still clears the stale flags
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
KIT="${REPO_ROOT}/migrate_noncdb_to_pdb"
BASH_BIN="${BASH:-bash}"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }
check() {   # check "name" expected actual
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
contains() {   # contains "name" needle haystack
    case "$3" in
        *"$2"*) pass "$1" ;;
        *)      fail "$1 (no '$2' in: $3)" ;;
    esac
}
lacks() {   # lacks "name" needle haystack
    case "$3" in
        *"$2"*) fail "$1 ('$2' found in: $3)" ;;
        *)      pass "$1" ;;
    esac
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/migrate_lib_test.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# ---- stub sqlplus -----------------------------------------------------------
mkdir -p "$WORK/oh/bin" "$WORK/stub"
cat > "$WORK/oh/bin/sqlplus" <<'STUB'
#!/bin/bash
d="$STUB_DIR"
n=$(cat "$d/count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$d/count"
in="$d/stdin.$n"
cat > "$in"
cp "$in" "$d/last_stdin"
printf '%s\n' "$*" > "$d/last_argv"
has() { grep -qF -- "$1" "$in"; }

case " $* " in
    *" /nolog "*)
        pw=$(sed -n 's/^CONNECT sys\/"\(.*\)"@[^ ]* AS SYSDBA$/\1/p' "$in")
        if [ "$pw" != "${STUB_GOOD_PW-}" ]; then
            printf 'ERROR:\nORA-01017: invalid username/password; logon denied\n\n'
            if [ "${STUB_LOGIN_FAIL_MODE:-exit}" = "continue" ]; then
                # sqlplus did not exit on the failed CONNECT: every later
                # statement is "Not connected", and EXIT returns 0.
                printf 'SP2-0640: Not connected\nSP2-0640: Not connected\n'
                exit 0
            fi
            exit 1
        fi
        ;;
    *" /@"*)
        if [ "${STUB_WALLET:-ok}" = "fail" ]; then
            printf 'ERROR:\nORA-01017: invalid username/password; logon denied\n\n'
            exit 1
        fi
        ;;
    *)
        # local OS-auth instance (source non-CDB / target CDB primary)
        if [ "${STUB_LOCAL_DOWN:-0}" = "1" ]; then
            printf 'ERROR:\nORA-01034: ORACLE not available\n'
            exit 1
        fi
        if has "'PDB='" && [ -n "${STUB_EXISTING_PDB:-}" ]; then echo "PDB=${STUB_EXISTING_PDB}"; fi
        if has 'SELECT open_mode FROM v$database'; then echo "${STUB_OPEN_MODE:-READONLY}"; fi
        if has "'NAME='"; then printf '%b\n' "${STUB_SRC_ID:-NAME=OTHERDB\nCDB=NO}"; fi
        exit 0
        ;;
esac

# --- the standby, connection established ---
if [ "${STUB_STBY_DOWN:-0}" = "1" ]; then
    printf 'ERROR:\nORA-01034: ORACLE not available\nProcess ID: 0\nSession ID: 0 Serial number: 0\n'
    exit 1
fi
has "'STBY_CONNECTED'" && echo "STBY_CONNECTED"
if has "'STBY_SCN|'"; then
    case "${STUB_SCN_MODE:-row}" in
        ora904)  printf 'ERROR at line 1:\nORA-00904: "CURRENT_SCN": invalid identifier\n'; exit 1 ;;
        ora_rc0) printf 'ORA-01536: space quota exceeded for tablespace\n'; exit 0 ;;
        empty)   exit 0 ;;
        row)
            k=$(cat "$d/scn_idx" 2>/dev/null || echo 0); k=$((k+1)); echo "$k" > "$d/scn_idx"
            line=$(sed -n "${k}p" "$d/scn_rows")
            [ -n "$line" ] || line=$(tail -1 "$d/scn_rows")
            echo "$line"
            ;;
    esac
fi
has "'STBY_ID|'" && echo "${STUB_STBY_ID_ROW:-STBY_ID|PHYSICAL STANDBY|cdb1_stby}"
has "name='standby_pdb_source_file_directory'" && echo "VAL=${STUB_STBY_PARAM_VAL:-/wrong/}"
exit 0
STUB
chmod +x "$WORK/oh/bin/sqlplus"

export STUB_DIR="$WORK/stub"
export PATH="$WORK/oh/bin:$PATH"
stub_reset() {
    rm -f "$STUB_DIR"/*
    unset STUB_GOOD_PW STUB_LOGIN_FAIL_MODE STUB_WALLET STUB_LOCAL_DOWN STUB_EXISTING_PDB \
          STUB_OPEN_MODE STUB_SRC_ID STUB_STBY_DOWN STUB_SCN_MODE STUB_STBY_ID_ROW STUB_STBY_PARAM_VAL
}
stub_calls() { cat "$STUB_DIR/count" 2>/dev/null || echo 0; }
# line number of the first line matching a fixed string in the last stdin
line_of() { grep -nF -- "$1" "$STUB_DIR/last_stdin" | head -1 | cut -d: -f1; }

# ---- source the library -----------------------------------------------------
# shellcheck disable=SC1090
source "${KIT}/_lib.sh"
set +u   # _lib.sh turns nounset on; the test body does not need it
STANDBY_TNS_ALIAS="cdb1_stby"
TARGET_CDB_STANDBY_UNIQUE_NAME="CDB1_STBY"   # V$DATABASE answers lowercase: must still match

echo "============================================================"
echo "migrate_noncdb_to_pdb/_lib.sh"
echo "============================================================"

echo ""
echo "Test 1: run_sql heredoc"
stub_reset
run_sql cdb1 "SELECT 'x' FROM dual WHERE 'a&b' = 'a&b';" >/dev/null
check "SET DEFINE OFF is the first line" "SET DEFINE OFF" "$(sed -n 1p "$STUB_DIR/last_stdin")"
check "WHENEVER SQLERROR EXIT FAILURE (not SQL.SQLCODE, which wraps at 256)" "1" \
    "$(grep -c '^WHENEVER SQLERROR EXIT FAILURE$' "$STUB_DIR/last_stdin")"

echo ""
echo "Test 2: _standby_sqlplus password branch"
PW='Pa&ss&w0rd!1'
stub_reset; export STUB_GOOD_PW="$PW"
STANDBY_SYS_PW="$PW"
OUT="$(run_sql_standby "SELECT 1 FROM dual;" 2>&1)"; RC=$?
check "login with an '&' password succeeds" "0" "$RC"
check "connects through /nolog (password off argv)" "-s /nolog" "$(cat "$STUB_DIR/last_argv")"
lacks "password not on argv" "$PW" "$(cat "$STUB_DIR/last_argv")"
L_DEF="$(line_of 'SET DEFINE OFF')"; L_ERR="$(line_of 'WHENEVER SQLERROR EXIT')"; L_CON="$(line_of 'CONNECT sys/')"
if [[ -n "$L_DEF" && -n "$L_CON" && "$L_DEF" -lt "$L_CON" ]]; then pass "SET DEFINE OFF precedes CONNECT"; else fail "SET DEFINE OFF precedes CONNECT (define=${L_DEF:-none}, connect=${L_CON:-none})"; fi
if [[ -n "$L_ERR" && -n "$L_CON" && "$L_ERR" -lt "$L_CON" ]]; then pass "WHENEVER SQLERROR precedes CONNECT"; else fail "WHENEVER SQLERROR precedes CONNECT (whenever=${L_ERR:-none}, connect=${L_CON:-none})"; fi
check "password reaches sqlplus literally" "CONNECT sys/\"${PW}\"@cdb1_stby AS SYSDBA" "$(grep -F 'CONNECT sys/' "$STUB_DIR/last_stdin")"
lacks "password not in stdout/stderr (success)" "$PW" "$OUT"

stub_reset; export STUB_GOOD_PW="something-else"
OUT="$(run_sql_standby "SELECT 1 FROM dual;" 2>&1)"; RC=$?
if [[ "$RC" != "0" ]]; then pass "failed login returns non-zero (rc=$RC)"; else fail "failed login returns non-zero"; fi
contains "failed login shows the ORA- text" "ORA-01017" "$OUT"
lacks "password not in stdout/stderr (failed login)" "$PW" "$OUT"

stub_reset; export STUB_GOOD_PW="something-else" STUB_LOGIN_FAIL_MODE=continue
OUT="$(run_sql_standby "SELECT 1 FROM dual;" 2>&1)"; RC=$?
if [[ "$RC" != "0" ]]; then pass "failed login with sqlplus exit 0 (SP2-0640) still non-zero"; else fail "failed login with sqlplus exit 0 (SP2-0640) still non-zero"; fi
check "only one sqlplus call (no retry loop, no re-prompt)" "1" "$(stub_calls)"

stub_reset; export STUB_GOOD_PW="$PW"
TRACE="$( { set -x; run_sql_standby "SELECT 1 FROM dual;" >/dev/null; : TRACE_IS_BACK; set +x; } 2>&1 )"
lacks "password not in xtrace output" "$PW" "$TRACE"
contains "xtrace restored after the call" "TRACE_IS_BACK" "$TRACE"
check "trace depth back to 0" "0" "$_MIG_TRACE_DEPTH"

echo ""
echo "Test 3: _standby_sqlplus wallet branch"
stub_reset
STANDBY_SYS_PW=""
OUT="$(run_sql_standby "SELECT 1 FROM dual;" 2>&1)"; RC=$?
check "wallet login succeeds" "0" "$RC"
check "connects as /@alias with -L" "-s -L /@cdb1_stby as sysdba" "$(cat "$STUB_DIR/last_argv")"
check "SET DEFINE OFF is the first line" "SET DEFINE OFF" "$(sed -n 1p "$STUB_DIR/last_stdin")"
stub_reset; export STUB_WALLET=fail
OUT="$(run_sql_standby "SELECT 1 FROM dual;" 2>&1)"; RC=$?
if [[ "$RC" != "0" ]]; then pass "failed wallet login returns non-zero"; else fail "failed wallet login returns non-zero"; fi

echo ""
echo "Test 4: standby_pw_problem"
contains "double quote refused" "double quote" "$(standby_pw_problem 'ab"cd')"
contains "empty refused" "empty" "$(standby_pw_problem '')"
check "'&', '@', '/' accepted" "" "$(standby_pw_problem 'a&b@c/d')"

echo ""
echo "Test 5: standby_identity_problem"
stub_reset
check "physical standby with the configured name (any case)" "" "$(standby_identity_problem)"
stub_reset; export STUB_STBY_ID_ROW="STBY_ID|PRIMARY|cdb1"
contains "alias reaching the primary is reported" "not a PHYSICAL STANDBY" "$(standby_identity_problem)"
stub_reset; export STUB_STBY_ID_ROW="STBY_ID|PHYSICAL STANDBY|cdb1_far"
contains "another standby is reported" "not the configured CDB standby" "$(standby_identity_problem)"
stub_reset; export STUB_STBY_DOWN=1
contains "query error is reported with the ORA- text" "ORA-01034" "$(standby_identity_problem)"

echo ""
echo "Test 6: wait_standby_scn (step 05 applied-SCN gate)"
export MIGRATE_SCN_POLL_SECS=0 MIGRATE_SCN_WAIT_SECS=3 MIGRATE_SCN_ERR_RETRIES=2

stub_reset
printf 'STBY_SCN|PHYSICAL STANDBY|cdb1_stby|20030716\n' > "$STUB_DIR/scn_rows"
RC=0; wait_standby_scn 20030700 >/dev/null || RC=$?
check "caught-up standby: rc 0" "0" "$RC"
check "caught-up standby: applied SCN recorded" "20030716" "$STBY_SCN"
contains "caught-up message" "Standby applied SCN 20030716 >= gate SCN 20030700" "$(standby_scn_gate_message 0 20030700)"
check "query reads role, unique name and CURRENT_SCN from v\$database in one statement" "1" \
    "$(grep -c "database_role || '|' || db_unique_name || '|' || TO_CHAR(current_scn) FROM v\$database" "$STUB_DIR/last_stdin")"

stub_reset
printf 'STBY_SCN|PHYSICAL STANDBY|cdb1_stby|100\nSTBY_SCN|PHYSICAL STANDBY|cdb1_stby|150\nSTBY_SCN|PHYSICAL STANDBY|cdb1_stby|250\n' > "$STUB_DIR/scn_rows"
RC=0; wait_standby_scn 200 >/dev/null || RC=$?
check "standby catching up within the wait: rc 0" "0" "$RC"
check "  ... after 3 polls" "3" "$(stub_calls)"

stub_reset
printf 'STBY_SCN|PHYSICAL STANDBY|cdb1_stby|100\n' > "$STUB_DIR/scn_rows"
RC=0; wait_standby_scn 200 >/dev/null || RC=$?
check "lagging standby: rc 1" "1" "$RC"
MSG="$(standby_scn_gate_message "$RC" 200)"
contains "lagging standby: 'Apply lag' message" "Apply lag" "$MSG"
contains "  ... shows the standby SCN" "at SCN 100" "$MSG"
contains "  ... shows the gate SCN" "gate SCN 200" "$MSG"

stub_reset; export STUB_SCN_MODE=ora904 MIGRATE_SCN_POLL_SECS=1 MIGRATE_SCN_WAIT_SECS=120
START=$SECONDS
RC=0; wait_standby_scn 200 >/dev/null || RC=$?
ELAPSED=$((SECONDS - START))
check "ORA-00904: rc 2 (error, not lag)" "2" "$RC"
contains "ORA-00904: text reported" "ORA-00904" "$STBY_SCN_ERR"
check "ORA-00904: bounded retries (1 + 2 calls)" "3" "$(stub_calls)"
if (( ELAPSED < 10 )); then pass "ORA-00904: no multi-minute wait (${ELAPSED}s)"; else fail "ORA-00904: no multi-minute wait (${ELAPSED}s)"; fi
MSG="$(standby_scn_gate_message "$RC" 200)"
contains "error message says error" "Error reading the applied SCN" "$MSG"
lacks "error message does not call it apply lag" "Apply lag" "$MSG"
export MIGRATE_SCN_POLL_SECS=0 MIGRATE_SCN_WAIT_SECS=3

stub_reset; export STUB_STBY_DOWN=1
RC=0; wait_standby_scn 200 >/dev/null || RC=$?
check "ORA-01034 (standby down): rc 2" "2" "$RC"
contains "ORA-01034: text reported" "ORA-01034" "$STBY_SCN_ERR"

stub_reset; export STUB_SCN_MODE=ora_rc0
RC=0; wait_standby_scn 200 >/dev/null || RC=$?
check "ORA- error with sqlplus exit 0: still rc 2" "2" "$RC"

stub_reset; export STUB_SCN_MODE=empty
RC=0; wait_standby_scn 200 >/dev/null || RC=$?
check "no row at all: rc 2" "2" "$RC"

stub_reset
printf 'STBY_SCN|PRIMARY|cdb1|99999999\n' > "$STUB_DIR/scn_rows"
RC=0; wait_standby_scn 200 >/dev/null || RC=$?
check "alias answering as PRIMARY: rc 2 (never a pass)" "2" "$RC"
contains "  ... names the role" "PRIMARY" "$STBY_SCN_ERR"
check "  ... no retry" "1" "$(stub_calls)"

stub_reset
printf 'STBY_SCN|PHYSICAL STANDBY|other_stby|99999999\n' > "$STUB_DIR/scn_rows"
RC=0; wait_standby_scn 200 >/dev/null || RC=$?
check "another database's standby: rc 2" "2" "$RC"

stub_reset
RC=0; wait_standby_scn "1.2346E+13" >/dev/null || RC=$?
check "non-numeric gate: rc 2" "2" "$RC"
check "  ... standby not even queried" "0" "$(stub_calls)"

echo ""
echo "Test 7: schema-validity guards (toolkit SQL)"
# Non-comment lines of the toolkit's shell scripts.
CODE="$(cat "${KIT}"/*.sh | grep -v '^[[:space:]]*#')"
check "no applied_scn in the toolkit's SQL" "0" "$(printf '%s\n' "$CODE" | grep -ci 'applied_scn')"
check "no v\$archive_dest_status query in the toolkit" "0" "$(printf '%s\n' "$CODE" | grep -ci 'archive_dest_status')"
check "every current_scn is read through TO_CHAR (NUMWIDTH-safe)" "0" \
    "$(printf '%s\n' "$CODE" | grep -i 'current_scn.*from v' | grep -vci 'to_char(current_scn)')"
check "  ... and there are such queries to check" "yes" \
    "$( [[ "$(printf '%s\n' "$CODE" | grep -ci 'to_char(current_scn).*from v')" -ge 4 ]] && echo yes || echo no )"
check "step 05 gates through wait_standby_scn" "1" "$(grep -c '^wait_standby_scn "\$SCN_GATE"' "${KIT}/05_verify_pdb_dataguard.sh")"
check "_standby_sqlplus: no CONNECT before SET DEFINE OFF" "ok" \
    "$(awk '/^_standby_sqlplus\(\)/{f=1} f&&/SET DEFINE OFF/{d=1} f&&/^CONNECT /{print (d?"ok":"bad"); exit}' "${KIT}/_lib.sh")"

# ---- end-to-end state ordering: steps 02 / 03 / 04 --------------------------
echo ""
echo "Test 8: refused re-runs leave state.env unchanged"
SHARE="$WORK/share"
STAGE="$SHARE/migrate/dgnonc_to_dgcdb"
mkdir -p "$SHARE" "$WORK/ob" "$WORK/oradata" "$STAGE/datafiles"
cat > "$WORK/config.env" <<EOF
SOURCE_DB_NAME=dgnonc
SOURCE_DB_UNIQUE_NAME=dgnonc
SOURCE_STANDBY_UNIQUE_NAME=dgnonc_s
SOURCE_ORACLE_SID=dgnonc
TARGET_CDB_NAME=dgcdb
TARGET_CDB_UNIQUE_NAME=dgcdb
TARGET_CDB_ORACLE_SID=dgcdb
TARGET_CDB_STANDBY_UNIQUE_NAME=dgcdb_s
NEW_PDB_NAME=dgnonc_pdb
ORACLE_HOME=$WORK/oh
ORACLE_BASE=$WORK/ob
NFS_SHARE=$SHARE
TARGET_PDB_DATAFILE_DIR=$WORK/oradata
EOF
STATE="$STAGE/state.env"
write_completed_state() {   # the state.env of a migration whose step 05 passed
    cat > "$STATE" <<'EOF'
preflight_ok=true
standby_prereq_ok=true
standby_dirs_ok=true
noncdb_quiesced=true
quiesce_scn=20000000
describe_done=true
stage_datafile_count=2
create_pdb_done=true
plug_done=true
new_pdb_state=READ\ WRITE
verify_done=true
verify_failures=0
EOF
    cp "$STATE" "$WORK/state.before"
}
run_step() {   # run_step <script>  -> sets STEP_RC / STEP_OUT
    STEP_RC=0
    STEP_OUT="$(MIGRATE_CONFIG="$WORK/config.env" MIGRATE_NONINTERACTIVE=1 \
        "$BASH_BIN" "${KIT}/$1" </dev/null 2>&1)" || STEP_RC=$?
}
state_unchanged() { cmp -s "$STATE" "$WORK/state.before" && echo yes || echo no; }

# 04 re-run after a successful plug-in: PDB exists -> refused, state intact.
stub_reset; export STUB_EXISTING_PDB=DGNONC_PDB
write_completed_state
printf '<xml/>\n' > "$STAGE/dgnonc_manifest.xml"
: > "$STAGE/datafiles/system01.dbf"; : > "$STAGE/datafiles/sysaux01.dbf"
run_step 04_plug_into_cdb.sh
check "04 re-run with existing PDB: exit 1" "1" "$STEP_RC"
contains "04 re-run: says the PDB exists" "already exists" "$STEP_OUT"
check "04 re-run: state.env byte-identical" "yes" "$(state_unchanged)"
( MIGRATE_STATE_FILE="$STATE"; require_state plug_done 04_plug_into_cdb.sh >/dev/null 2>&1 ) \
    && pass "04 re-run: step 05's require_state plug_done still passes" \
    || fail "04 re-run: step 05's require_state plug_done still passes"

# 04: target CDB unreachable -> refused as a query error, not as "exists".
stub_reset; export STUB_LOCAL_DOWN=1
write_completed_state
run_step 04_plug_into_cdb.sh
check "04 with target CDB down: exit 1" "1" "$STEP_RC"
contains "04 with target CDB down: query error reported" "ORA-01034" "$STEP_OUT"
lacks "04 with target CDB down: not misreported as an existing PDB" "already exists" "$STEP_OUT"
check "04 with target CDB down: state.env byte-identical" "yes" "$(state_unchanged)"

# 04: manifest missing -> refused, state intact.
stub_reset
write_completed_state
mv "$STAGE/dgnonc_manifest.xml" "$WORK/manifest.away"
run_step 04_plug_into_cdb.sh
check "04 without manifest: exit 1" "1" "$STEP_RC"
check "04 without manifest: state.env byte-identical" "yes" "$(state_unchanged)"
mv "$WORK/manifest.away" "$STAGE/dgnonc_manifest.xml"

# 04: standby unreachable (no TTY, wallet fails) -> refused, state intact.
stub_reset; export STUB_WALLET=fail
write_completed_state
run_step 04_plug_into_cdb.sh
check "04 with standby unreachable: exit 1" "1" "$STEP_RC"
contains "04 with standby unreachable: says so" "Cannot connect to the CDB standby" "$STEP_OUT"
check "04 with standby unreachable: state.env byte-identical" "yes" "$(state_unchanged)"

# 04: a permitted attempt (no PDB, everything in place) still clears the stale
# plug/verify flags before its first change. The stub's standby read-back of
# STANDBY_PDB_SOURCE_FILE_DIRECTORY is wrong, which stops the step right after.
stub_reset; export STUB_STBY_PARAM_VAL=/wrong/
write_completed_state
run_step 04_plug_into_cdb.sh
check "04 new attempt stopped by the read-back: exit 1" "1" "$STEP_RC"
check "04 new attempt: plug_done cleared" "" "$( MIGRATE_STATE_FILE="$STATE"; read_state plug_done )"
check "04 new attempt: verify_done cleared" "" "$( MIGRATE_STATE_FILE="$STATE"; read_state verify_done )"
check "04 new attempt: preflight_ok kept" "true" "$( MIGRATE_STATE_FILE="$STATE"; read_state preflight_ok )"

# 03 with the source not READ ONLY -> refused, state intact.
stub_reset; export STUB_OPEN_MODE=READWRITE
write_completed_state
run_step 03_describe_and_stage.sh
check "03 with source READ WRITE: exit 1" "1" "$STEP_RC"
check "03 refused: state.env byte-identical" "yes" "$(state_unchanged)"

# 02 with SOURCE_ORACLE_SID pointing at another database -> refused, state intact.
stub_reset
write_completed_state
run_step 02_quiesce_noncdb.sh
check "02 with wrong source identity: exit 1" "1" "$STEP_RC"
check "02 refused: state.env byte-identical" "yes" "$(state_unchanged)"

echo ""
echo "============================================================"
echo "Test Summary: $PASS passed, $FAIL failed"
echo "============================================================"
[[ $FAIL -eq 0 ]]
