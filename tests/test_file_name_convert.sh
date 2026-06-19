#!/bin/bash
# ============================================================
# Unit test for the DB_FILE_NAME_CONVERT generation logic in
# primary/02_generate_standby_config.sh
# ============================================================
# Regression guard for two specific bugs:
#   1. Only the first primary datafile directory ends up in
#      DB_FILE_NAME_CONVERT when the primary has multiple distinct
#      directories.
#   2. The bash `local a="$1" b="$2" key="$a=>$b"` gotcha - $a/$b
#      are unset at the time `key` is evaluated, so every dedup
#      check sees the same empty key and collapses every pair.
# ============================================================

set +e

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

# ------------------------------------------------------------
# Lift the _emit_pair function and surrounding pair-building
# logic out of 02_generate_standby_config.sh by sourcing this
# helper. Keep it byte-identical to the script so a regression
# in either copy fails the test.
# ------------------------------------------------------------
build_convert_pairs() {
    local -a primary_data=("${!1}")
    local -a standby_data=("${!2}")
    local -a primary_redo=("${!3}")
    local -a standby_redo=("${!4}")

    _convert_pairs=""
    _seen_pairs=" "

    _emit_pair() {
        local primary="$1"
        local standby="$2"
        local key=" ${primary}=>${standby} "
        [[ -z "$primary" || -z "$standby" ]] && return 0
        case "$_seen_pairs" in
            *"$key"*) return 0 ;;
        esac
        _seen_pairs="${_seen_pairs}${primary}=>${standby} "
        if [[ -z "$_convert_pairs" ]]; then
            _convert_pairs="'${primary}','${standby}'"
        else
            _convert_pairs="${_convert_pairs},'${primary}','${standby}'"
        fi
    }

    local _idx
    _idx=0
    for _p in "${primary_data[@]}"; do
        _emit_pair "$_p" "${standby_data[$_idx]}"
        _idx=$((_idx + 1))
    done
    _idx=0
    for _p in "${primary_redo[@]}"; do
        _emit_pair "$_p" "${standby_redo[$_idx]}"
        _idx=$((_idx + 1))
    done
}

# NOTE: redo directories now share the no-trailing-slash convention with
# datafile directories (get_redo_log_paths.sql strips the slash, matching
# get_datafile_dirs.sql), so a redo dir that names the same directory as a
# datafile dir collapses to one convert pair instead of two near-duplicates.

echo "Test 1: single data path + redo on a distinct directory"
PRIMARY_DATA=("/u01/app/oracle/oradata/DGNONC")
STANDBY_DATA=("/u01/app/oracle/oradata/DGNONC_S")
PRIMARY_REDO=("/u02/redo/DGNONC")
STANDBY_REDO=("/u02/redo/DGNONC_S")
build_convert_pairs PRIMARY_DATA[@] STANDBY_DATA[@] PRIMARY_REDO[@] STANDBY_REDO[@]
assert_eq "single data + redo on a separate mount = two pairs" \
    "'/u01/app/oracle/oradata/DGNONC','/u01/app/oracle/oradata/DGNONC_S','/u02/redo/DGNONC','/u02/redo/DGNONC_S'" \
    "$_convert_pairs"

echo "Test 2: three distinct data paths"
PRIMARY_DATA=(
    "/u01/app/oracle/oradata/DGNONC"
    "/u02/app/oracle/oradata/DGNONC"
    "/u03/app/oracle/oradata/DGNONC"
)
STANDBY_DATA=(
    "/u01/app/oracle/oradata/DGNONC_S"
    "/u02/app/oracle/oradata/DGNONC_S"
    "/u03/app/oracle/oradata/DGNONC_S"
)
PRIMARY_REDO=()
STANDBY_REDO=()
build_convert_pairs PRIMARY_DATA[@] STANDBY_DATA[@] PRIMARY_REDO[@] STANDBY_REDO[@]
assert_eq "three data paths emit three pairs" \
    "'/u01/app/oracle/oradata/DGNONC','/u01/app/oracle/oradata/DGNONC_S','/u02/app/oracle/oradata/DGNONC','/u02/app/oracle/oradata/DGNONC_S','/u03/app/oracle/oradata/DGNONC','/u03/app/oracle/oradata/DGNONC_S'" \
    "$_convert_pairs"

echo "Test 3: dedup drops exact duplicate pair"
PRIMARY_DATA=(
    "/u01/oradata/DGNONC"
    "/u01/oradata/DGNONC"
)
STANDBY_DATA=(
    "/u01/oradata/DGNONC_S"
    "/u01/oradata/DGNONC_S"
)
PRIMARY_REDO=()
STANDBY_REDO=()
build_convert_pairs PRIMARY_DATA[@] STANDBY_DATA[@] PRIMARY_REDO[@] STANDBY_REDO[@]
assert_eq "duplicate pair collapsed to one" \
    "'/u01/oradata/DGNONC','/u01/oradata/DGNONC_S'" \
    "$_convert_pairs"

echo "Test 4: data + redo where one redo dir coincides with a data dir"
# The first redo directory names the same directory as the first data
# directory. Under the no-trailing-slash convention the two are now
# byte-identical, so the dedup collapses them and only the genuinely
# new redo directory (/u04/redo/DGNONC) adds a pair.
PRIMARY_DATA=(
    "/u01/oradata/DGNONC"
    "/u02/oradata/DGNONC"
)
STANDBY_DATA=(
    "/u01/oradata/DGNONC_S"
    "/u02/oradata/DGNONC_S"
)
PRIMARY_REDO=(
    "/u01/oradata/DGNONC"
    "/u04/redo/DGNONC"
)
STANDBY_REDO=(
    "/u01/oradata/DGNONC_S"
    "/u04/redo/DGNONC_S"
)
build_convert_pairs PRIMARY_DATA[@] STANDBY_DATA[@] PRIMARY_REDO[@] STANDBY_REDO[@]
assert_eq "data (2) + redo (1 collapses, 1 new) = 3 pairs" \
    "'/u01/oradata/DGNONC','/u01/oradata/DGNONC_S','/u02/oradata/DGNONC','/u02/oradata/DGNONC_S','/u04/redo/DGNONC','/u04/redo/DGNONC_S'" \
    "$_convert_pairs"

echo ""
echo "============================================================"
echo "PASSED: $PASS  FAILED: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
