#!/bin/bash
# ============================================================
# Test script for the OMF inherited-parameter helpers in
# common/dg_functions.sh:
#   is_safe_omf_dest_path / omf_default_online_log_dest /
#   build_rman_online_log_dest_set_lines /
#   build_pfile_online_log_dest_lines / parse_omf_placement_params
# ============================================================
# Usage: bash tests/test_omf_online_log_dest.sh
#
# Guards the fix for RMAN DUPLICATE ... SPFILE silently handing the
# primary's DB_CREATE_ONLINE_LOG_DEST_n (and *_FILE_NAME_CONVERT) to an
# OMF standby: the pure logic used by steps 1, 2, 3 and 5 lives in the
# shared library so it is tested here without a database.
# ============================================================

# Don't use set -e as we need to test for failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

LOG_FILE=/dev/null
source "${COMMON_DIR}/dg_functions.sh"

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

# assert_safe <name> <value> <yes|no>
assert_safe() {
    local name="$1" value="$2" want="$3" got
    if is_safe_omf_dest_path "$value"; then got="yes"; else got="no"; fi
    assert_eq "$name" "$want" "$got"
}

# ============================================================
echo "Test 1: omf_default_online_log_dest (n=1,2,3..5)"
assert_eq "n=1 -> db_create_file_dest" "/u01/oradata" "$(omf_default_online_log_dest 1 /u01/oradata /u02/fra)"
assert_eq "n=2 -> db_recovery_file_dest" "/u02/fra" "$(omf_default_online_log_dest 2 /u01/oradata /u02/fra)"
assert_eq "n=3 -> db_create_file_dest" "/u01/oradata" "$(omf_default_online_log_dest 3 /u01/oradata /u02/fra)"
assert_eq "n=4 -> db_create_file_dest" "/u01/oradata" "$(omf_default_online_log_dest 4 /u01/oradata /u02/fra)"
assert_eq "n=5 -> db_create_file_dest" "/u01/oradata" "$(omf_default_online_log_dest 5 /u01/oradata /u02/fra)"
assert_eq "n=2 with empty FRA falls back to file dest" "/u01/oradata" "$(omf_default_online_log_dest 2 /u01/oradata "")"
assert_eq "ASM file dest passes through" "+DATA" "$(omf_default_online_log_dest 1 +DATA +FRA)"
out=$(omf_default_online_log_dest 0 /a /b); rc=$?
assert_eq "n=0 prints nothing" "" "$out"
assert_eq "n=0 returns 1" "1" "$rc"
out=$(omf_default_online_log_dest 6 /a /b); rc=$?
assert_eq "n=6 prints nothing" "" "$out"
assert_eq "n=6 returns 1" "1" "$rc"
out=$(omf_default_online_log_dest x /a /b); rc=$?
assert_eq "non-numeric n returns 1" "1" "$rc"
assert_eq "empty file dest, n=1 -> empty" "" "$(omf_default_online_log_dest 1 "" "")"

# ============================================================
echo ""
echo "Test 2: is_safe_omf_dest_path accepts"
assert_safe "absolute path" "/u01/oradata" yes
assert_safe "path with trailing slash" "/u01/oradata/" yes
assert_safe "path with dots, dashes, underscores, plus" "/u01/app_1/ora-data.v2+x" yes
assert_safe "root" "/" yes
assert_safe "ASM disk group" "+DATA" yes
assert_safe "ASM disk group with directory" "+DATA/CDB1/redo" yes
assert_safe "ASM lower-case dg with digits" "+data01" yes

echo ""
echo "Test 3: is_safe_omf_dest_path rejects"
assert_safe "empty" "" no
assert_safe "relative path" "u01/oradata" no
assert_safe "dot-relative path" "./oradata" no
assert_safe "bare plus" "+" no
assert_safe "plus then slash" "+/x" no
assert_safe "embedded space" "/u01/ora data" no
assert_safe "trailing space" "/u01/oradata " no
assert_safe "leading space" " /u01/oradata" no
assert_safe "single quote" "/u01/ora'data" no
assert_safe "double quote" '/u01/ora"data' no
assert_safe "dollar sign" '/u01/$ORACLE_SID' no
assert_safe "backtick" '/u01/`id`' no
assert_safe "semicolon" "/u01/oradata;rm" no
assert_safe "pipe" "/u01/a|b" no
assert_safe "ampersand" "/u01/a&b" no
assert_safe "parenthesis" "/u01/(a)" no
assert_safe "backslash" '/u01/a\b' no
assert_safe "newline" $'/u01/a\nb' no
assert_safe "tab" $'/u01/a\tb' no
assert_safe "path with tilde" "~/oradata" no

# ============================================================
echo ""
echo "Test 4: build_rman_online_log_dest_set_lines"
out=$(build_rman_online_log_dest_set_lines "" "" "" "" ""); rc=$?
assert_eq "none set -> no output" "" "$out"
assert_eq "none set -> rc 0" "0" "$rc"
out=$(build_rman_online_log_dest_set_lines); rc=$?
assert_eq "no arguments -> no output" "" "$out"
assert_eq "no arguments -> rc 0" "0" "$rc"
out=$(build_rman_online_log_dest_set_lines "/u01/redo" "" "" "" "")
assert_eq "one dest (n=1)" "    SET DB_CREATE_ONLINE_LOG_DEST_1='/u01/redo'" "$out"
out=$(build_rman_online_log_dest_set_lines "" "" "+REDO" "" "")
assert_eq "one dest keeps its n (n=3)" "    SET DB_CREATE_ONLINE_LOG_DEST_3='+REDO'" "$out"
out=$(build_rman_online_log_dest_set_lines "/u01/redo" "/u02/fra" "" "" "")
assert_eq "two dests" "    SET DB_CREATE_ONLINE_LOG_DEST_1='/u01/redo'
    SET DB_CREATE_ONLINE_LOG_DEST_2='/u02/fra'" "$out"
out=$(build_rman_online_log_dest_set_lines "/a" "/b" "/c" "/d" "/e" | wc -l | tr -d '[:space:]')
assert_eq "five dests -> five lines" "5" "$out"
out=$(build_rman_online_log_dest_set_lines "/u01/redo" "/u02/bad dir" "" "" ""); rc=$?
assert_eq "unsafe value -> no partial output" "" "$out"
assert_eq "unsafe value -> rc 1" "1" "$rc"
out=$(build_rman_online_log_dest_set_lines "/u01/redo" "x'; drop" "" "" ""); rc=$?
assert_eq "quote injection rejected" "1" "$rc"

# the way step 5 splices the lines into the RMAN body
sets=$(build_rman_online_log_dest_set_lines "/u01/redo" "" "" "" "")
block=""
[[ -n "$sets" ]] && block="
${sets}"
body="    SET DB_CREATE_FILE_DEST='/u01/oradata'${block}
    SET DB_RECOVERY_FILE_DEST='/u02/fra'"
assert_eq "splice with one dest has no blank line" "    SET DB_CREATE_FILE_DEST='/u01/oradata'
    SET DB_CREATE_ONLINE_LOG_DEST_1='/u01/redo'
    SET DB_RECOVERY_FILE_DEST='/u02/fra'" "$body"
sets=$(build_rman_online_log_dest_set_lines "" "" "" "" "")
block=""
[[ -n "$sets" ]] && block="
${sets}"
body="    SET DB_CREATE_FILE_DEST='/u01/oradata'${block}
    SET DB_RECOVERY_FILE_DEST='/u02/fra'"
assert_eq "splice with none is the pre-fix body" "    SET DB_CREATE_FILE_DEST='/u01/oradata'
    SET DB_RECOVERY_FILE_DEST='/u02/fra'" "$body"

# ============================================================
echo ""
echo "Test 5: build_pfile_online_log_dest_lines"
out=$(build_pfile_online_log_dest_lines "" "" "" "" "")
assert_eq "none set -> no output" "" "$out"
out=$(build_pfile_online_log_dest_lines "/u01/redo" "/u02/fra" "" "" "")
assert_eq "two dests" "*.db_create_online_log_dest_1='/u01/redo'
*.db_create_online_log_dest_2='/u02/fra'" "$out"
out=$(build_pfile_online_log_dest_lines "" "" "" "" "+DG/x")
assert_eq "n=5 only" "*.db_create_online_log_dest_5='+DG/x'" "$out"
out=$(build_pfile_online_log_dest_lines "/u01/a b" "" "" "" ""); rc=$?
assert_eq "unsafe value rejected" "1" "$rc"

# ============================================================
echo ""
echo "Test 6: parse_omf_placement_params"
parse_omf_placement_params ""
assert_eq "empty input: dest_1 empty" "" "$OMF_PARAM_ONLINE_LOG_DEST_1"
assert_eq "empty input: LFNC NO" "NO" "$OMF_PARAM_LOG_FILE_NAME_CONVERT_SET"
assert_eq "empty input: DFNC NO" "NO" "$OMF_PARAM_DB_FILE_NAME_CONVERT_SET"
assert_eq "empty input: not unsafe" "NO" "$OMF_PARAM_UNSAFE"

parse_omf_placement_params "
db_create_online_log_dest_1|/u01/redo
db_create_online_log_dest_2|  /u02/fra  
log_file_name_convert|/a/,/b/
"
assert_eq "dest_1 parsed" "/u01/redo" "$OMF_PARAM_ONLINE_LOG_DEST_1"
assert_eq "dest_2 trimmed" "/u02/fra" "$OMF_PARAM_ONLINE_LOG_DEST_2"
assert_eq "dest_3 unset" "" "$OMF_PARAM_ONLINE_LOG_DEST_3"
assert_eq "LFNC YES" "YES" "$OMF_PARAM_LOG_FILE_NAME_CONVERT_SET"
assert_eq "DFNC NO" "NO" "$OMF_PARAM_DB_FILE_NAME_CONVERT_SET"
assert_eq "safe values not flagged" "NO" "$OMF_PARAM_UNSAFE"

parse_omf_placement_params "db_file_name_convert|/x,/y
db_create_online_log_dest_5|+REDO"
assert_eq "DFNC YES" "YES" "$OMF_PARAM_DB_FILE_NAME_CONVERT_SET"
assert_eq "LFNC reset to NO between calls" "NO" "$OMF_PARAM_LOG_FILE_NAME_CONVERT_SET"
assert_eq "dest_1 reset between calls" "" "$OMF_PARAM_ONLINE_LOG_DEST_1"
assert_eq "dest_5 ASM parsed" "+REDO" "$OMF_PARAM_ONLINE_LOG_DEST_5"

parse_omf_placement_params "db_create_online_log_dest_1|/u01/with space"
assert_eq "unsafe value kept raw" "/u01/with space" "$OMF_PARAM_ONLINE_LOG_DEST_1"
assert_eq "unsafe value flagged" "YES" "$OMF_PARAM_UNSAFE"

parse_omf_placement_params 'db_create_online_log_dest_2|/u01/$(id)'
assert_eq "command substitution text flagged" "YES" "$OMF_PARAM_UNSAFE"
assert_eq "command substitution text not executed" '/u01/$(id)' "$OMF_PARAM_ONLINE_LOG_DEST_2"

parse_omf_placement_params "ORA-01034: ORACLE not available
db_create_online_log_dest_9|/nope
unrelated_param|/x
db_create_online_log_dest_1|"
assert_eq "noise ignored: dest_1 empty" "" "$OMF_PARAM_ONLINE_LOG_DEST_1"
assert_eq "noise ignored: not unsafe" "NO" "$OMF_PARAM_UNSAFE"
assert_eq "noise ignored: LFNC NO" "NO" "$OMF_PARAM_LOG_FILE_NAME_CONVERT_SET"

# ============================================================
echo ""
echo "Test 7: step wiring (scripts use the shared helpers, SQL file present)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
for f in primary/01_gather_primary_info.sh primary/02_generate_standby_config.sh standby/05_clone_standby.sh; do
    if grep -Eq "omf_default_online_log_dest|parse_omf_placement_params" "${ROOT_DIR}/${f}"; then
        echo "  PASS: ${f} uses the shared OMF helpers"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${f} does not reference the shared OMF helpers"
        FAIL=$((FAIL + 1))
    fi
done
if [[ -f "${ROOT_DIR}/sql/queries/get_omf_placement_params.sql" ]] \
   && grep -q "WHENEVER SQLERROR EXIT" "${ROOT_DIR}/sql/queries/get_omf_placement_params.sql"; then
    echo "  PASS: get_omf_placement_params.sql exists and exits on SQL error"
    PASS=$((PASS + 1))
else
    echo "  FAIL: get_omf_placement_params.sql missing or lacks WHENEVER SQLERROR EXIT"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "============================================================"
echo "Test Summary: $PASS passed, $FAIL failed"
echo "============================================================"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
