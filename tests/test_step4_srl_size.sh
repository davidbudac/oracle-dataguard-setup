#!/usr/bin/env bash
# ============================================================
# Test script for step 4's pre-existing standby redo log size check
# (primary/04_prepare_primary_dg.sh, "srl size helpers" block)
# ============================================================
# Usage: bash tests/test_step4_srl_size.sh
#
# The check compares the smallest V$STANDBY_LOG size against the largest
# V$LOG size in exact bytes. Comparing two whole-MiB figures that were both
# rounded UP calls a 100.4 MiB SRL "adequate" against a 100.5 MiB ORL (101 vs
# 101). The pure helpers are extracted from the script between the
# "begin/end srl size helpers" markers (nothing is mirrored); check_existing_srl_sizes
# itself is exercised end to end with a stubbed run_sql_query. DB-free.
# ============================================================

# Don't use set -e as we need to test for failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT_UNDER_TEST="${REPO_DIR}/primary/04_prepare_primary_dg.sh"
QUERY_FILE="${REPO_DIR}/sql/queries/get_standby_redo_min_size.sql"

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
# Extract the real helper block and the real check function
# ------------------------------------------------------------
_block=$(sed -n '/^# ---- begin srl size helpers ----$/,/^# ---- end srl size helpers ----$/p' "$SCRIPT_UNDER_TEST")
if [[ -z "$_block" ]]; then
    echo "FATAL: srl size helper block not found in primary/04_prepare_primary_dg.sh"
    exit 1
fi
eval "$_block"
_fn_body=$(sed -n '/^check_existing_srl_sizes() {$/,/^}$/p' "$SCRIPT_UNDER_TEST")
if [[ -z "$_fn_body" ]]; then
    echo "FATAL: check_existing_srl_sizes not found in primary/04_prepare_primary_dg.sh"
    exit 1
fi
eval "$_fn_body"
for _fn in srl_size_label srl_size_verdict check_existing_srl_sizes; do
    if ! type "$_fn" >/dev/null 2>&1; then
        echo "FATAL: ${_fn} missing after sourcing the helper block"
        exit 1
    fi
done

MIB=1048576
GIB=$((1024 * MIB))

echo "=== Test 1: srl_size_verdict ==="

# 100.4 MiB vs 100.5 MiB: both CEIL to 101 MiB, yet the SRL is smaller.
srl=$(( 1004 * MIB / 10 ))
orl=$(( 1005 * MIB / 10 ))
assert_eq "100.4 MiB SRL vs 100.5 MiB ORL -> UNDERSIZED" "UNDERSIZED" "$(srl_size_verdict "$srl" "$orl")"
assert_eq "equal bytes -> ADEQUATE" "ADEQUATE" "$(srl_size_verdict 104857600 104857600)"
assert_eq "SRL one byte smaller -> UNDERSIZED" "UNDERSIZED" "$(srl_size_verdict 104857599 104857600)"
assert_eq "SRL one byte larger -> ADEQUATE" "ADEQUATE" "$(srl_size_verdict 104857601 104857600)"
assert_eq "SRL larger -> ADEQUATE" "ADEQUATE" "$(srl_size_verdict 209715200 104857600)"
assert_eq "SRL smaller by a whole log -> UNDERSIZED" "UNDERSIZED" "$(srl_size_verdict 52428800 104857600)"
assert_eq "20 GiB vs 20 GiB -> ADEQUATE" "ADEQUATE" "$(srl_size_verdict $((20 * GIB)) $((20 * GIB)))"
assert_eq "20 GiB - 1 byte vs 20 GiB -> UNDERSIZED" "UNDERSIZED" "$(srl_size_verdict $((20 * GIB - 1)) $((20 * GIB)))"
assert_eq "21 GiB vs 20 GiB -> ADEQUATE" "ADEQUATE" "$(srl_size_verdict $((21 * GIB)) $((20 * GIB)))"
assert_eq "leading zeros are decimal (no octal surprise)" "ADEQUATE" "$(srl_size_verdict 0000104857600 08)"

echo ""
echo "=== Test 2: srl_size_verdict refuses to guess ==="

assert_eq "empty SRL -> UNKNOWN" "UNKNOWN" "$(srl_size_verdict "" 104857600)"
assert_eq "empty ORL -> UNKNOWN" "UNKNOWN" "$(srl_size_verdict 104857600 "")"
assert_eq "both empty -> UNKNOWN" "UNKNOWN" "$(srl_size_verdict "" "")"
assert_eq "no arguments -> UNKNOWN" "UNKNOWN" "$(srl_size_verdict)"
assert_eq "non-numeric SRL -> UNKNOWN" "UNKNOWN" "$(srl_size_verdict abc 104857600)"
assert_eq "ORA- text -> UNKNOWN" "UNKNOWN" "$(srl_size_verdict "ORA-01034:" 104857600)"
assert_eq "scientific notation -> UNKNOWN" "UNKNOWN" "$(srl_size_verdict 1.04857E+08 104857600)"
assert_eq "negative -> UNKNOWN" "UNKNOWN" "$(srl_size_verdict -5 104857600)"
assert_eq "zero SRL -> UNKNOWN" "UNKNOWN" "$(srl_size_verdict 0 104857600)"
assert_eq "zero ORL -> UNKNOWN" "UNKNOWN" "$(srl_size_verdict 104857600 0)"
assert_eq "too wide for shell arithmetic -> UNKNOWN" "UNKNOWN" "$(srl_size_verdict 99999999999999999999 104857600)"

echo ""
echo "=== Test 3: srl_size_label ==="

assert_eq "whole MiB -> N MB" "100 MB" "$(srl_size_label 104857600)"
assert_eq "not whole MiB -> exact bytes" "105272729 bytes" "$(srl_size_label 105272729)"
assert_eq "20 GiB -> 20480 MB" "20480 MB" "$(srl_size_label $((20 * GIB)))"

echo ""
echo "=== Test 4: check_existing_srl_sizes end to end (stubbed query) ==="

# Capture the log lines instead of writing them.
log_info() { printf 'INFO: %s\n' "$*"; }
log_warn() { printf 'WARN: %s\n' "$*"; }

run_sql_query() { printf '%s\n' "$STUB_SQL_OUT"; return "${STUB_SQL_RC:-0}"; }

REDO_LOG_SIZE_MB=101
STUB_SQL_OUT="${srl}|${orl}"
out=$(check_existing_srl_sizes)
assert_contains "100.4 vs 100.5 MiB -> UNDERSIZED warning" "UNDERSIZED" "$out"
assert_not_contains "100.4 vs 100.5 MiB -> not reported adequate" "sized adequately" "$out"
assert_contains "warning shows exact bytes, not equal-looking MiB" "${srl} bytes" "$out"
assert_contains "warning shows the ORL exact bytes" "${orl} bytes" "$out"
assert_contains "fix DDL keeps SIZE <REDO_LOG_SIZE_MB>M" "SIZE 101M;" "$out"
assert_contains "DDL is printed, not run" "run manually - not applied automatically" "$out"

STUB_SQL_OUT="104857600|104857600"
out=$(check_existing_srl_sizes)
assert_contains "equal bytes -> adequate" "sized adequately" "$out"
assert_contains "whole MiB labelled N MB" "100 MB" "$out"
assert_not_contains "equal bytes -> no warning" "WARN:" "$out"

STUB_SQL_OUT="209715200|104857600"
out=$(check_existing_srl_sizes)
assert_contains "larger SRL -> adequate" "sized adequately" "$out"

STUB_SQL_OUT="$((20 * GIB - 1))|$((20 * GIB))"
REDO_LOG_SIZE_MB=20480
out=$(check_existing_srl_sizes)
assert_contains "20 GiB - 1 byte -> UNDERSIZED" "UNDERSIZED" "$out"
assert_contains "20 GiB DDL size" "SIZE 20480M;" "$out"

REDO_LOG_SIZE_MB=100
STUB_SQL_OUT="${srl}|${orl}"
out=$(check_existing_srl_sizes)
assert_contains "stale config size below live ORL -> DDL uses the live rounded-up size" "SIZE 101M;" "$out"

for _bad in "" "|" "|104857600" "104857600|" "ORA-00942: table or view does not exist" "104857600"; do
    STUB_SQL_OUT="$_bad"
    out=$(check_existing_srl_sizes)
    assert_contains "unusable result [${_bad}] -> cannot verify" "Could not verify" "$out"
    assert_not_contains "unusable result [${_bad}] -> never 'adequate'" "sized adequately" "$out"
done

# A failing query (nonzero rc) must not abort a set -e caller.
STUB_SQL_OUT="ERROR: ORA-01034"
STUB_SQL_RC=1
out=$(set -e; check_existing_srl_sizes; echo SURVIVED)
assert_contains "failed query under set -e -> warning, step not aborted" "Could not verify" "$out"
assert_contains "failed query under set -e -> function returned" "SURVIVED" "$out"
STUB_SQL_RC=0

echo ""
echo "=== Test 5: the query returns exact bytes ==="

if [[ ! -f "$QUERY_FILE" ]]; then
    echo "FATAL: ${QUERY_FILE} missing"
    exit 1
fi
_script_query=$(grep -o 'run_sql_query "[^"]*"' "$SCRIPT_UNDER_TEST" | grep 'standby_redo_min_size')
assert_contains "step 4 uses get_standby_redo_min_size.sql" "get_standby_redo_min_size.sql" "$_script_query"
# Strip SQL comments (-- ...) so the header prose cannot trip the checks.
_sql=$(sed 's/--.*$//' "$QUERY_FILE" | tr 'a-z' 'A-Z')
assert_not_contains "no CEIL on the sizes" "CEIL" "$_sql"
assert_not_contains "no ROUND on the sizes" "ROUND" "$_sql"
assert_not_contains "no TRUNC on the sizes" "TRUNC" "$_sql"
assert_not_contains "no division into MiB" "/1024" "$_sql"
assert_contains "reads V\$STANDBY_LOG" 'MIN(BYTES)) FROM V$STANDBY_LOG' "$_sql"
assert_contains "reads V\$LOG" 'MAX(BYTES)) FROM V$LOG' "$_sql"
assert_contains "TO_CHAR on the byte counts (no scientific notation)" "TO_CHAR(MIN(BYTES))" "$_sql"
assert_contains "min|max in one result" "'|'" "$_sql"
assert_contains "keeps WHENEVER SQLERROR EXIT" "WHENEVER SQLERROR EXIT SQL.SQLCODE" "$_sql"

echo ""
echo "================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "================================"
[[ $FAIL -eq 0 ]]
