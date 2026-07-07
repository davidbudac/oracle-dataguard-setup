#!/bin/bash
# ============================================================
# Test script for parse_df_available_kb / get_available_space_kb
# in common/dg_functions.sh
# ============================================================
# Usage: bash tests/test_df_parsing.sh
#
# Guards the fix requiring `df -Pk` (POSIX output format) instead of
# plain `df -k`. On AIX, plain `df -k` places %Used (not free KB) in
# field 4, which silently breaks downstream arithmetic if ever used
# by mistake. `-P` produces an identical column layout on Linux and
# AIX: Filesystem 1024-blocks Used Available Capacity Mounted on
# ============================================================

# Don't use set -e as we need to test for failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source the functions (without logging setup), same as test_add_sid_to_listener.sh
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
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_true() {
    local name="$1" condition="$2"
    if [[ "$condition" -eq 0 ]]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================
# Test 1: Captured Linux df -Pk output (header + one data line)
# ============================================================
echo "Test 1: Linux df -Pk output"
LINUX_DF_PK="Filesystem             1024-blocks      Used Available Capacity Mounted on
/dev/mapper/vg00-oradata 104857600  41943040  62914560      41% /u01/app/oracle/oradata"

result=$(printf '%s\n' "$LINUX_DF_PK" | parse_df_available_kb)
assert_eq "Linux df -Pk extracts Available column" "62914560" "$result"

# ============================================================
# Test 2: Captured AIX 7.2 df -Pk output (POSIX format)
# ============================================================
echo "Test 2: AIX 7.2 df -Pk output"
AIX_DF_PK="Filesystem    1024-blocks      Used   Available Capacity Mounted on
/dev/oradatalv    20971520   8388608    12582912      41% /u01/app/oracle/oradata"

result=$(printf '%s\n' "$AIX_DF_PK" | parse_df_available_kb)
assert_eq "AIX df -Pk extracts Available column" "12582912" "$result"

# ============================================================
# Test 3: Long device name, single data row (still -P format)
# ============================================================
echo "Test 3: long device name, single data row"
LONG_DEV_DF_PK="Filesystem                                   1024-blocks      Used Available Capacity Mounted on
/dev/mapper/oracle_vg-oradata_lv_standby_dgnonc   52428800  10485760  41943040      21% /u02/app/oracle/oradata_standby"

result=$(printf '%s\n' "$LONG_DEV_DF_PK" | parse_df_available_kb)
assert_eq "long device name (no spaces) still extracts Available column" "41943040" "$result"

# ============================================================
# Test 4: AIX native df -k output (NOT -P) - documents why -P is required
# ============================================================
echo "Test 4: AIX native df -k (non-POSIX) - negative/documentation case"
# Columns: Filesystem 1024-blocks Free %Used Iused %Iused Mounted on
AIX_DF_K_NATIVE="Filesystem    1024-blocks      Free %Used    Iused %Iused Mounted on
/dev/oradatalv    20971520  12582912   41%     1024     1% /u01/app/oracle/oradata"

field4=$(printf '%s\n' "$AIX_DF_K_NATIVE" | tail -1 | awk '{print $4}')
# field4 should be something like "41%", i.e. NOT a plain integer.
if [[ "$field4" =~ ^[0-9]+$ ]]; then
    echo "  FAIL: AIX native df -k field 4 unexpectedly looks like a plain number ($field4)"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: AIX native df -k field 4 ('$field4') is NOT a plain number, confirming -P is required"
    PASS=$((PASS + 1))
fi

# ============================================================
# Test 5: Multi-line input (multiple filesystems) - takes LAST line
# ============================================================
echo "Test 5: multi-line df -Pk output uses tail -1 (last filesystem)"
MULTI_FS_DF_PK="Filesystem             1024-blocks      Used Available Capacity Mounted on
/dev/mapper/vg00-root    10485760   2097152   8388608      21% /
/dev/mapper/vg00-oradata 104857600  41943040  62914560      41% /u01/app/oracle/oradata"

result=$(printf '%s\n' "$MULTI_FS_DF_PK" | parse_df_available_kb)
assert_eq "multi-line input takes the last line's Available column" "62914560" "$result"

# ============================================================
# Test 6: get_available_space_kb caller wraps df -Pk correctly
# ============================================================
echo "Test 6: get_available_space_kb (caller) against a real path"
# We can't control the real system's df output deterministically, but we
# CAN assert the function returns a non-empty plain integer for a path
# that certainly exists (the test's own tmp dir), proving the -Pk +
# parse_df_available_kb wiring works end-to-end.
real_result=$(get_available_space_kb "/tmp")
if [[ "$real_result" =~ ^[0-9]+$ ]]; then
    echo "  PASS: get_available_space_kb('/tmp') returned a plain integer ($real_result)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: get_available_space_kb('/tmp') did not return a plain integer (got '$real_result')"
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
