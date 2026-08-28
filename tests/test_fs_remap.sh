#!/bin/bash
# ============================================================
# Unit test for the Q1b per-filesystem remap logic in
# primary/02_generate_standby_config.sh
# ============================================================
# Step 2's Q1b asks whether the standby's filesystems (the FIRST path
# component of each location) are named differently than the primary's;
# if so, each distinct primary filesystem is listed and the operator
# supplies its standby counterpart. Only changed entries land in the
# parallel arrays STANDBY_FS_MAP_FROM / STANDBY_FS_MAP_TO (stored
# without the leading slash) that apply_fs_map() consults.
#
# apply_fs_map / derive_standby_path (and the token-remap helpers they
# build on) are kept byte-identical to the copies in
# primary/02_generate_standby_config.sh; the drift guard at the end
# diffs the two new functions against the script so a change in either
# copy fails this test. The token-remap helpers themselves are drift-
# guarded the same informal way as tests/test_path_token_remap.sh.
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
# Helpers lifted verbatim from 02_generate_standby_config.sh.
# ------------------------------------------------------------
_path_has_component() {
    case "/$1/" in
        *"/$2/"*) return 0 ;;
        *) return 1 ;;
    esac
}

_replace_path_component() {
    local _p="$1" _tok="$2" _rep="$3"
    _p=$(printf '%s' "$_p" | sed "s|/${_tok}/|/${_rep}/|g")
    _p=$(printf '%s' "$_p" | sed "s|/${_tok}\$|/${_rep}|")
    printf '%s' "$_p"
}

remap_path_token() {
    local _p="$1"
    if   _path_has_component "$_p" "$DB_UNIQUE_NAME_UPPER"; then
        _replace_path_component "$_p" "$DB_UNIQUE_NAME_UPPER" "$STANDBY_DIR_NAME_UPPER"
    elif _path_has_component "$_p" "$DB_UNIQUE_NAME_LOWER"; then
        _replace_path_component "$_p" "$DB_UNIQUE_NAME_LOWER" "$STANDBY_DIR_NAME_LOWER"
    elif _path_has_component "$_p" "$DB_UNIQUE_NAME"; then
        _replace_path_component "$_p" "$DB_UNIQUE_NAME" "$STANDBY_DB_UNIQUE_NAME"
    else
        printf '%s' "$_p"
    fi
}

apply_fs_map() {
    local _p="$1" _first _rest _i=0
    if [[ ${#STANDBY_FS_MAP_FROM[@]} -eq 0 ]]; then printf '%s' "$_p"; return 0; fi
    case "$_p" in
        ""|/) printf '%s' "$_p"; return 0 ;;
        /*) ;;
        *) printf '%s' "$_p"; return 0 ;;
    esac
    _rest="${_p#/}"
    _first="${_rest%%/*}"
    _rest="${_rest#"$_first"}"
    while [[ $_i -lt ${#STANDBY_FS_MAP_FROM[@]} ]]; do
        if [[ "${STANDBY_FS_MAP_FROM[$_i]}" == "$_first" ]]; then
            printf '/%s%s' "${STANDBY_FS_MAP_TO[$_i]}" "$_rest"
            return 0
        fi
        _i=$((_i + 1))
    done
    printf '%s' "$_p"
}

derive_standby_path() {
    local _p
    _p=$(apply_fs_map "$1")
    remap_path_token "$_p"
}

# Set the case-variant globals exactly as the script does.
setup_names() {
    DB_UNIQUE_NAME="$1"
    STANDBY_DB_UNIQUE_NAME="$2"
    DB_UNIQUE_NAME_UPPER=$(echo "$DB_UNIQUE_NAME" | tr '[:lower:]' '[:upper:]')
    DB_UNIQUE_NAME_LOWER=$(echo "$DB_UNIQUE_NAME" | tr '[:upper:]' '[:lower:]')
    STANDBY_DIR_NAME_UPPER=$(echo "$STANDBY_DB_UNIQUE_NAME" | tr '[:lower:]' '[:upper:]')
    STANDBY_DIR_NAME_LOWER=$(echo "$STANDBY_DB_UNIQUE_NAME" | tr '[:upper:]' '[:lower:]')
}

echo "Test group A: apply_fs_map with a two-entry map"
setup_names "PROD" "STBY"
STANDBY_FS_MAP_FROM=("ora_1" "ora_redo")
STANDBY_FS_MAP_TO=("ora_1_s" "ora_redo_s")

assert_eq "mapped filesystem is swapped, rest of path kept" \
    "/ora_1_s/oradata/x" "$(apply_fs_map "/ora_1/oradata/x")"

assert_eq "second map entry works too" \
    "/ora_redo_s/PROD" "$(apply_fs_map "/ora_redo/PROD")"

assert_eq "single-component mount is swapped" \
    "/ora_redo_s" "$(apply_fs_map "/ora_redo")"

assert_eq "unmapped filesystem passes through unchanged" \
    "/ora_arch/logs" "$(apply_fs_map "/ora_arch/logs")"

assert_eq "trailing slash is preserved" \
    "/ora_1_s/oradata/" "$(apply_fs_map "/ora_1/oradata/")"

assert_eq "bare root is left unchanged" \
    "/" "$(apply_fs_map "/")"

assert_eq "empty path is left unchanged" \
    "" "$(apply_fs_map "")"

assert_eq "relative path is left unchanged" \
    "ora_1/oradata" "$(apply_fs_map "ora_1/oradata")"

assert_eq "only a WHOLE-component match swaps (ora_1 != ora_10)" \
    "/ora_10/oradata" "$(apply_fs_map "/ora_10/oradata")"

echo "Test group B: derive_standby_path (filesystem map FIRST, then token remap)"

assert_eq "filesystem swap and DB-name component swap compose" \
    "/ora_1_s/oradata/STBY" "$(derive_standby_path "/ora_1/oradata/PROD")"

assert_eq "lowercase token variant still remaps under a mapped filesystem" \
    "/ora_1_s/stby/x" "$(derive_standby_path "/ora_1/prod/x")"

assert_eq "unmapped filesystem still gets the token remap" \
    "/ora_arch/STBY/logs" "$(derive_standby_path "/ora_arch/PROD/logs")"

# The map's keys are the PRIMARY filesystem names as the operator was
# shown them - a first component that IS the DB name is offered and
# mapped under its primary name, and the explicit answer wins (no
# token remap is applied on top of it).
STANDBY_FS_MAP_FROM=("PROD")
STANDBY_FS_MAP_TO=("PROD_s")
assert_eq "first component that IS the DB name maps under its primary name" \
    "/PROD_s/data" "$(derive_standby_path "/PROD/data")"

echo "Test group C: empty map is a byte-exact no-op (same-filesystems scenario)"
STANDBY_FS_MAP_FROM=()
STANDBY_FS_MAP_TO=()

assert_eq "derive_standby_path == remap_path_token when the map is empty" \
    "$(remap_path_token "/ora_1/oradata/PROD")" \
    "$(derive_standby_path "/ora_1/oradata/PROD")"

assert_eq "token-less path passes through unchanged when the map is empty" \
    "/ora_arch/logs" "$(derive_standby_path "/ora_arch/logs")"

echo "Test group D: multi-component map targets"
STANDBY_FS_MAP_FROM=("ora_1")
STANDBY_FS_MAP_TO=("mnt/oracle/ora_1")

assert_eq "a target with interior slashes relocates the filesystem" \
    "/mnt/oracle/ora_1/oradata/PROD" "$(apply_fs_map "/ora_1/oradata/PROD")"

assert_eq "token remap still applies after a multi-component relocation" \
    "/mnt/oracle/ora_1/oradata/STBY" "$(derive_standby_path "/ora_1/oradata/PROD")"

# ------------------------------------------------------------
# Drift guard: the apply_fs_map / derive_standby_path copies above
# must stay byte-identical to primary/02_generate_standby_config.sh,
# or these tests validate code that no longer ships.
# ------------------------------------------------------------
echo "Test group E: copies have not drifted from the script"
_SCRIPT="$(dirname "$0")/../primary/02_generate_standby_config.sh"
if [[ ! -f "$_SCRIPT" ]]; then
    echo "  FAIL: cannot find $_SCRIPT"
    FAIL=$((FAIL + 1))
else
    for _fn in apply_fs_map derive_standby_path; do
        # Range: the function header through its first column-0 '}'.
        _TMP_A="${TMPDIR:-/tmp}/fsm_script.$$"
        _TMP_B="${TMPDIR:-/tmp}/fsm_test.$$"
        awk "/^${_fn}\\(\\) \\{/,/^\\}\$/" "$_SCRIPT" > "$_TMP_A"
        awk "/^${_fn}\\(\\) \\{/,/^\\}\$/" "$0"       > "$_TMP_B"
        if [[ ! -s "$_TMP_A" ]]; then
            echo "  FAIL: could not extract ${_fn} from the script"
            FAIL=$((FAIL + 1))
        elif diff -u "$_TMP_A" "$_TMP_B" > /dev/null 2>&1; then
            echo "  PASS: ${_fn} copies are byte-identical"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: ${_fn} has drifted from $_SCRIPT"
            echo "        re-copy the function into this test (script is the source of truth):"
            diff -u "$_TMP_A" "$_TMP_B" | sed 's/^/        /'
            FAIL=$((FAIL + 1))
        fi
        rm -f "$_TMP_A" "$_TMP_B"
    done
fi

echo ""
echo "============================================================"
echo "PASSED: $PASS  FAILED: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
