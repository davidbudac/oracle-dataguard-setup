#!/usr/bin/env bash
# ============================================================
# Test script for step 5's inherited-FRA handling
# (standby/05_clone_standby.sh, "fra reset helpers" block)
# ============================================================
# Usage: bash tests/test_step5_fra_reset.sh
#
# RMAN DUPLICATE ... SPFILE copies the primary's spfile and overrides only
# the SET list, so a primary with db_recovery_file_dest set would hand its
# FRA to a standby configured WITHOUT one. Step 5 RESETs both parameters in
# that case. The pure helpers are extracted from the script between the
# "begin/end fra reset helpers" markers (nothing is mirrored) and the
# Traditional/OMF RMAN heredocs are extracted and evaluated too, so the text
# asserted here is the text the script generates. DB-free.
# ============================================================

# Don't use set -e as we need to test for failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT_UNDER_TEST="${REPO_DIR}/standby/05_clone_standby.sh"

LOG_FILE=/dev/null
source "${REPO_DIR}/common/dg_functions.sh"

PASS=0
FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    expected: [$expected]"
        echo "    actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s\n' "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name (missing: $needle)"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s\n' "$haystack" | grep -qF -- "$needle"; then
        echo "  FAIL: $name (unexpected: $needle)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    fi
}

# ------------------------------------------------------------
# Extract the real helper block
# ------------------------------------------------------------
_block=$(sed -n '/^# ---- begin fra reset helpers ----$/,/^# ---- end fra reset helpers ----$/p' "$SCRIPT_UNDER_TEST")
if [[ -z "$_block" ]]; then
    echo "FATAL: fra reset helper block not found in standby/05_clone_standby.sh"
    exit 1
fi
eval "$_block"
for _fn in fra_normalize_path fra_display_path parse_primary_fra_params build_rman_fra_lines check_archive_dest_1_without_fra fra_readback_verdict; do
    if ! type "$_fn" >/dev/null 2>&1; then
        echo "FATAL: ${_fn} missing after sourcing the helper block"
        exit 1
    fi
done

NL='
'

echo "=== Test 1: build_rman_fra_lines ==="

_reset_expected="    RESET DB_RECOVERY_FILE_DEST${NL}    RESET DB_RECOVERY_FILE_DEST_SIZE"
_set_expected="    SET DB_RECOVERY_FILE_DEST='/u02/fra'${NL}    SET DB_RECOVERY_FILE_DEST_SIZE='50G'"

out=$(build_rman_fra_lines TRADITIONAL NO "" "" "/u01/fra")
assert_eq "primary FRA set, standby FRA off -> both RESET lines, in order" "$_reset_expected" "$out"
assert_not_contains "RESET lines carry no value text" "/u01/fra" "$out"
assert_not_contains "RESET lines carry no quotes" "'" "$out"

out=$(build_rman_fra_lines TRADITIONAL NO "" "" "")
assert_eq "primary FRA empty, standby FRA off -> nothing" "" "$out"

out=$(build_rman_fra_lines TRADITIONAL YES "/u02/fra" "50G" "/u01/fra")
assert_eq "standby FRA on -> the two SET lines as before" "$_set_expected" "$out"
assert_not_contains "standby FRA on -> no RESET" "RESET" "$out"

out=$(build_rman_fra_lines TRADITIONAL YES "/u02/fra" "50G" "")
assert_eq "standby FRA on, primary has none -> SET lines unchanged" "$_set_expected" "$out"

out=$(build_rman_fra_lines OMF YES "/u02/fra" "50G" "/u01/fra")
assert_eq "OMF mode, FRA on -> helper prints nothing (OMF body has its own lines)" "" "$out"
out=$(build_rman_fra_lines OMF NO "" "" "/u01/fra")
assert_eq "OMF mode, USE_FRA=NO -> helper prints nothing" "" "$out"

out=$(build_rman_fra_lines "" "" "" "" "/u01/fra")
assert_eq "empty storage mode (old config) behaves as Traditional -> RESET" "$_reset_expected" "$out"

echo ""
echo "=== Test 2: parse_primary_fra_params ==="

raw="db_recovery_file_dest|/u01/app/oracle/fra
db_recovery_file_dest_size|53687091200
log_archive_dest_1|LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES)
log_archive_dest_3|LOCATION=USE_DB_RECOVERY_FILE_DEST
log_archive_dest_12|location=use_db_recovery_file_dest
log_archive_dest_state_3|ENABLE
fra_query_ok|1"
parse_primary_fra_params "$raw"
assert_eq "dest parsed" "/u01/app/oracle/fra" "$PRIMARY_FRA_DEST"
assert_eq "size parsed" "53687091200" "$PRIMARY_FRA_SIZE"
assert_eq "sentinel seen" "YES" "$PRIMARY_FRA_QUERY_OK"
assert_eq "n>1 FRA destinations listed, dest_1 and *_state_n excluded" "log_archive_dest_3 log_archive_dest_12" "$PRIMARY_FRA_ARCHIVE_DESTS"

parse_primary_fra_params "fra_query_ok|1"
assert_eq "only the sentinel -> no FRA" "" "$PRIMARY_FRA_DEST"
assert_eq "only the sentinel -> query ok" "YES" "$PRIMARY_FRA_QUERY_OK"

parse_primary_fra_params ""
assert_eq "empty output -> query NOT ok (a failed query is not a pass)" "NO" "$PRIMARY_FRA_QUERY_OK"

parse_primary_fra_params "ERROR:
ORA-01017: invalid username/password; logon denied"
assert_eq "ORA- text -> query NOT ok" "NO" "$PRIMARY_FRA_QUERY_OK"
assert_eq "ORA- text -> no dest" "" "$PRIMARY_FRA_DEST"

parse_primary_fra_params "$(printf 'db_recovery_file_dest|/u01/fra\r\nfra_query_ok|1\r\n')"
assert_eq "CRLF output tolerated" "/u01/fra" "$PRIMARY_FRA_DEST"

echo ""
echo "=== Test 3: fra_display_path (no unvalidated value into logs) ==="
assert_eq "safe path shown" "/u01/fra" "$(fra_display_path /u01/fra)"
assert_eq "ASM path shown" "+RECO" "$(fra_display_path +RECO)"
_d=$(fra_display_path '/u01/fra;rm -rf /')
assert_not_contains "unsafe path not echoed" "rm -rf" "$_d"
_d=$(fra_display_path '/u01/$(id)')
assert_not_contains "command substitution text not echoed" 'id' "$_d"

echo ""
echo "=== Test 4: check_archive_dest_1_without_fra ==="
msg=$(check_archive_dest_1_without_fra TRADITIONAL NO "/arch/stby"); rc=$?
assert_eq "explicit dir passes" "0" "$rc"
msg=$(check_archive_dest_1_without_fra TRADITIONAL NO ""); rc=$?
assert_eq "empty dir -> refusal" "1" "$rc"
assert_contains "empty dir message names STANDBY_ARCHIVE_DEST" "STANDBY_ARCHIVE_DEST is empty" "$msg"
msg=$(check_archive_dest_1_without_fra TRADITIONAL NO "   "); rc=$?
assert_eq "blank dir -> refusal" "1" "$rc"
msg=$(check_archive_dest_1_without_fra TRADITIONAL NO "use_db_recovery_file_dest"); rc=$?
assert_eq "USE_DB_RECOVERY_FILE_DEST (any case) -> refusal" "1" "$rc"
msg=$(check_archive_dest_1_without_fra TRADITIONAL YES ""); rc=$?
assert_eq "FRA enabled -> not applicable" "0" "$rc"
msg=$(check_archive_dest_1_without_fra OMF NO ""); rc=$?
assert_eq "OMF -> not applicable" "0" "$rc"

echo ""
echo "=== Test 5: fra_readback_verdict ==="
msg=$(fra_readback_verdict NO "" "/u01/fra" "53687091200"); rc=$?
assert_eq "FRA off, inherited path -> fail" "1" "$rc"
assert_contains "failure names the inherited path" "/u01/fra" "$msg"
msg=$(fra_readback_verdict NO "" "" "0"); rc=$?
assert_eq "FRA off, empty dest and size 0 -> pass" "0" "$rc"
msg=$(fra_readback_verdict NO "" "" ""); rc=$?
assert_eq "FRA off, everything empty -> pass" "0" "$rc"
msg=$(fra_readback_verdict NO "" "  " "0"); rc=$?
assert_eq "FRA off, whitespace dest -> pass" "0" "$rc"
msg=$(fra_readback_verdict NO "" "" "53687091200"); rc=$?
assert_eq "FRA off, empty dest but leftover size -> warn only (2)" "2" "$rc"
msg=$(fra_readback_verdict YES "/u02/fra" "/u02/fra" "50G"); rc=$?
assert_eq "FRA on, path matches -> pass" "0" "$rc"
msg=$(fra_readback_verdict YES "/u02/fra" "/u02/fra/" "50G"); rc=$?
assert_eq "FRA on, trailing slash tolerated" "0" "$rc"
msg=$(fra_readback_verdict YES "/u02/fra/" "  /u02/fra  " "50G"); rc=$?
assert_eq "FRA on, whitespace and trailing slash tolerated" "0" "$rc"
msg=$(fra_readback_verdict YES "/u02/fra" "/u01/fra" "50G"); rc=$?
assert_eq "FRA on, different path -> fail" "1" "$rc"
msg=$(fra_readback_verdict YES "/u02/fra" "" "0"); rc=$?
assert_eq "FRA on, empty dest -> fail" "1" "$rc"
msg=$(fra_readback_verdict YES "" "" "0"); rc=$?
assert_eq "FRA on but no configured path -> fail (never a vacuous pass)" "1" "$rc"
msg=$(fra_readback_verdict YES "/" "/" "1G"); rc=$?
assert_eq "root path kept intact by normalisation" "0" "$rc"
assert_eq "normalize strips trailing slashes" "/u01/fra" "$(fra_normalize_path ' /u01/fra// ')"

echo ""
echo "=== Test 6: generated RMAN body (heredocs extracted from the script) ==="

# The script builds RMAN_BODY twice (OMF, then Traditional) with
# RMAN_BODY=$(cat <<EOF ... EOF ). Pull each heredoc block out of the script
# and evaluate it with representative variables.
_extract_rman_body_block() {
    awk -v want="$1" '
        /^    RMAN_BODY=\$\(cat <<EOF$/ { n++; if (n == want) { grab = 1 } }
        grab { print }
        grab && /^EOF$/ { eof = 1; next }
        grab && eof { exit }
    ' "$SCRIPT_UNDER_TEST"
}
OMF_BLOCK=$(_extract_rman_body_block 1)
TRAD_BLOCK=$(_extract_rman_body_block 2)
assert_contains "OMF heredoc extracted" "OMF Mode" "$OMF_BLOCK"
assert_contains "Traditional heredoc extracted" 'SET CONTROL_FILES' "$TRAD_BLOCK"

_render_body() {
    # $1 = OMF|TRADITIONAL, $2 = USE_FRA_FOR_STANDBY, $3 = primary FRA ("" = none)
    local STANDBY_STORAGE_MODE="$1" USE_FRA_FOR_STANDBY="$2" LIVE_PRIMARY_FRA_DEST="$3"
    local STANDBY_DB_UNIQUE_NAME=cdb1_stby STANDBY_DATA_PATH=/u02/oradata STANDBY_CONTROL_FILE_2_DIR=""
    local STANDBY_FRA="/u02/fra" STANDBY_DB_RECOVERY_FILE_DEST="/u02/fra"
    local STANDBY_DB_RECOVERY_FILE_DEST_SIZE="50G" DB_RECOVERY_FILE_DEST_SIZE="100G"
    local STANDBY_DB_CREATE_FILE_DEST=/u02/oradata
    local LOG_ARCHIVE_DEST_1_SETTING="LOCATION=/arch VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=cdb1_stby"
    local DB_FILE_NAME_CONVERT="'/u01/oradata','/u02/oradata'" LOG_FILE_NAME_CONVERT="'/u01/oradata','/u02/oradata'"
    local STANDBY_HOSTNAME=stby STANDBY_LISTENER_PORT=1521 STANDBY_ADMIN_DIR=/u01/admin/cdb1_stby
    local DIAG_DEST_SET="" BROKER_FILE_SETS="" OMF_ONLINE_LOG_DEST_SETS="" RMAN_PROLOGUE="" RMAN_EPILOGUE=""
    local FRA_SETTINGS RMAN_BODY
    if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
        eval "$OMF_BLOCK"
    else
        FRA_SETTINGS=$(build_rman_fra_lines "$STANDBY_STORAGE_MODE" "$USE_FRA_FOR_STANDBY" "${STANDBY_FRA:-}" "${STANDBY_DB_RECOVERY_FILE_DEST_SIZE:-${DB_RECOVERY_FILE_DEST_SIZE}}" "$LIVE_PRIMARY_FRA_DEST")
        eval "$TRAD_BLOCK"
    fi
    printf '%s\n' "$RMAN_BODY"
}

# A RESET <P> line must never coexist with a SET <P> line.
assert_no_reset_set_conflict() {
    local name="$1" body="$2" p conflict=0
    for p in DB_RECOVERY_FILE_DEST DB_RECOVERY_FILE_DEST_SIZE; do
        if printf '%s\n' "$body" | grep -q "^[[:space:]]*RESET ${p}[[:space:]]*\$" \
           && printf '%s\n' "$body" | grep -q "^[[:space:]]*SET ${p}="; then
            conflict=1
        fi
    done
    assert_eq "$name: RESET and SET never both present for one parameter" "0" "$conflict"
}

body=$(_render_body TRADITIONAL NO "/u01/fra")
assert_contains "trad/no-FRA/primary-FRA: RESET dest" "    RESET DB_RECOVERY_FILE_DEST" "$body"
assert_contains "trad/no-FRA/primary-FRA: RESET size" "    RESET DB_RECOVERY_FILE_DEST_SIZE" "$body"
_fra_sets=$(printf '%s\n' "$body" | grep -c "^[[:space:]]*SET DB_RECOVERY_FILE_DEST")
assert_eq "trad/no-FRA/primary-FRA: no SET of the FRA" "0" "$_fra_sets"
assert_not_contains "trad/no-FRA/primary-FRA: primary path never in the RMAN body" "/u01/fra" "$body"
assert_no_reset_set_conflict "trad/no-FRA/primary-FRA" "$body"
_pos_ad1=$(printf '%s\n' "$body" | grep -n "SET LOG_ARCHIVE_DEST_1" | head -1 | cut -d: -f1)
_pos_r1=$(printf '%s\n' "$body" | grep -n "RESET DB_RECOVERY_FILE_DEST$" | head -1 | cut -d: -f1)
_pos_r2=$(printf '%s\n' "$body" | grep -n "RESET DB_RECOVERY_FILE_DEST_SIZE" | head -1 | cut -d: -f1)
_pos_conv=$(printf '%s\n' "$body" | grep -n "SET DB_FILE_NAME_CONVERT" | head -1 | cut -d: -f1)
if [[ -n "$_pos_ad1" && "$_pos_ad1" -lt "$_pos_r1" && "$_pos_r1" -lt "$_pos_r2" && "$_pos_r2" -lt "$_pos_conv" ]]; then
    assert_eq "RESET lines sit between LOG_ARCHIVE_DEST_1 and DB_FILE_NAME_CONVERT, dest before size" "ok" "ok"
else
    assert_eq "RESET lines sit between LOG_ARCHIVE_DEST_1 and DB_FILE_NAME_CONVERT, dest before size" "ok" "ad1=$_pos_ad1 r1=$_pos_r1 r2=$_pos_r2 conv=$_pos_conv"
fi
assert_contains "body still ends the statement" "NOFILENAMECHECK;" "$body"

body=$(_render_body TRADITIONAL NO "")
assert_not_contains "trad/no-FRA/no primary FRA: no RESET" "RESET" "$body"
assert_not_contains "trad/no-FRA/no primary FRA: no FRA SET" "DB_RECOVERY_FILE_DEST" "$body"

body=$(_render_body TRADITIONAL YES "/u01/fra")
assert_contains "trad/FRA on: SET dest" "SET DB_RECOVERY_FILE_DEST='/u02/fra'" "$body"
assert_contains "trad/FRA on: SET size" "SET DB_RECOVERY_FILE_DEST_SIZE='50G'" "$body"
assert_not_contains "trad/FRA on: no RESET" "RESET" "$body"
assert_no_reset_set_conflict "trad/FRA on" "$body"

body=$(_render_body OMF YES "/u01/fra")
assert_contains "OMF: SET dest as before" "SET DB_RECOVERY_FILE_DEST='/u02/fra'" "$body"
assert_not_contains "OMF: no RESET" "RESET" "$body"
assert_no_reset_set_conflict "OMF" "$body"
body=$(_render_body OMF NO "/u01/fra")
assert_not_contains "OMF with USE_FRA=NO: still no RESET" "RESET" "$body"

echo ""
echo "=== Test 7: script wiring (static) ==="
_script=$(cat "$SCRIPT_UNDER_TEST")
assert_contains "live primary query goes through stdin CONNECT, not argv" 'CONNECT sys/"${SYS_PASSWORD}"@${PRIMARY_TNS_ALIAS} AS SYSDBA' "$_script"
assert_contains "a failed live query refuses the step" "Refusing to start the non-restartable RMAN duplicate without this check" "$_script"
assert_contains "completion sentinel is required" "fra_query_ok" "$_script"
assert_contains "read-back comparison is wired in" "fra_readback_verdict" "$_script"
# one SYS-password prompt only: this fix must not add any read
_reads=$(grep -c '^[[:space:]]*read ' "$SCRIPT_UNDER_TEST")
assert_eq "no 'read' statements added to step 5 (E2E piped-stdin sequence)" "0" "$_reads"
_prompts=$(grep -c '=\$(prompt_password' "$SCRIPT_UNDER_TEST")
assert_eq "SYS password prompted exactly once" "1" "$_prompts"

echo ""
echo "=== Test 8: a read-back contradiction must not abort the post-clone sequence (static) ==="
# The DUPLICATE is done and step 5 is not restartable: an exit between the
# read-back and the MRP start would skip the broker start, MRP and deletion policy.
_mid=$(awk '/^# Read back the standby.s effective FRA parameters/ { grab = 1 }
            grab { print }
            grab && /run_sql_command "start_mrp.sql"/ { exit }' "$SCRIPT_UNDER_TEST")
assert_contains "read-back section extracted (reaches start_mrp.sql)" 'run_sql_command "start_mrp.sql"' "$_mid"
assert_contains "extract includes the verdict call" "fra_readback_verdict" "$_mid"
assert_contains "extract includes the broker start" "set_dg_broker_start.sql" "$_mid"
_exits=$(printf '%s\n' "$_mid" | grep -c '^[[:space:]]*exit\b')
assert_eq "no exit between the read-back verdict and the MRP start" "0" "$_exits"
assert_contains "contradiction is recorded in a flag" "FRA_CHECK_FAILED=1" "$_mid"

_tail=$(awk '/^if \[\[ "\$FRA_CHECK_FAILED" == "1" \]\]; then$/ { n++ } n >= 1 { print }' "$SCRIPT_UNDER_TEST")
_final=$(printf '%s\n' "$_tail" | awk '/^print_summary / { grab = 1 } grab { print }')
assert_contains "final block: summary status is not hard-coded SUCCESS" 'print_summary "$_final_status"' "$_final"
assert_contains "final block: error status chosen when flag set" '_final_status="ERROR"' "$_tail"
assert_contains "final block: failure block repeated" "print_fra_check_failure" "$_final"
assert_contains "final block: tells the operator the post-clone actions ran" "WERE carried out" "$_final"
assert_contains "final block: step 6 must wait" "Do NOT run ./primary/06_configure_broker.sh" "$_final"
_last_if=$(printf '%s\n' "$_final" | awk '/^if \[\[ "\$FRA_CHECK_FAILED" == "1" \]\]; then$/ { grab = 1 } grab { print } grab && /^fi$/ { exit }')
assert_contains "final block: exits 1 when the flag is set" "    exit 1" "$_last_if"
_nexts=$(printf '%s\n' "$_final" | grep -n 'print_list_block "Next Steps"' | head -1 | cut -d: -f1)
_exitl=$(printf '%s\n' "$_final" | grep -n '^    exit 1$' | head -1 | cut -d: -f1)
if [[ -n "$_nexts" && -n "$_exitl" && "$_exitl" -lt "$_nexts" ]]; then
    assert_eq "exit 1 comes before the 'Next Steps' (go-ahead) block" "ok" "ok"
else
    assert_eq "exit 1 comes before the 'Next Steps' (go-ahead) block" "ok" "exit=$_exitl next=$_nexts"
fi

# FRA-enabled manual fix: size first, then destination, both as statements
_fix=$(awk '/FRA_CHECK_FIX_1="ALTER SYSTEM SET db_recovery_file_dest_size/ { print; getline; print }' "$SCRIPT_UNDER_TEST")
assert_contains "FRA-enabled fix sets the size first" 'FRA_CHECK_FIX_1="ALTER SYSTEM SET db_recovery_file_dest_size=' "$_fix"
assert_contains "FRA-enabled fix then sets the destination" "FRA_CHECK_FIX_2=\"ALTER SYSTEM SET db_recovery_file_dest='" "$_fix"

echo ""
echo "=========================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "=========================================="
[[ $FAIL -eq 0 ]]
