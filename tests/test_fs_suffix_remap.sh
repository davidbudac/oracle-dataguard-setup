#!/bin/bash
# ============================================================
# Unit test for the Q1b filesystem-suffix derivation logic in
# primary/02_generate_standby_config.sh
# ============================================================
# Step 2's Q1b lets the operator declare that the standby uses the same
# layout on RENAMED filesystems: one suffix is appended to the FIRST
# path component of every derived standby location (/ora_1/oradata ->
# /ora_1_s/oradata), while the ORACLE_BASE default gets the suffix on
# its LAST component instead (/u01/app/oracle -> /u01/app/oracle_s).
#
# apply_fs_suffix / derive_standby_path (and the token-remap helpers
# they build on) are kept byte-identical to the copies in
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

apply_fs_suffix() {
    local _p="$1" _first _rest
    if [[ -z "${STANDBY_FS_SUFFIX:-}" ]]; then printf '%s' "$_p"; return 0; fi
    case "$_p" in
        ""|/) printf '%s' "$_p"; return 0 ;;
        /*) ;;
        *) printf '%s' "$_p"; return 0 ;;
    esac
    _rest="${_p#/}"
    _first="${_rest%%/*}"
    _rest="${_rest#"$_first"}"
    printf '/%s%s%s' "$_first" "$STANDBY_FS_SUFFIX" "$_rest"
}

derive_standby_path() {
    local _p
    _p=$(remap_path_token "$1")
    apply_fs_suffix "$_p"
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

echo "Test group A: apply_fs_suffix with suffix '_s'"
setup_names "PROD" "STBY"
STANDBY_FS_SUFFIX="_s"

assert_eq "suffix lands on the first path component only" \
    "/ora_1_s/oradata/x" "$(apply_fs_suffix "/ora_1/oradata/x")"

assert_eq "single-component mount gets the suffix" \
    "/ora_redo_s" "$(apply_fs_suffix "/ora_redo")"

assert_eq "trailing slash is preserved" \
    "/ora_1_s/oradata/" "$(apply_fs_suffix "/ora_1/oradata/")"

assert_eq "bare root is left unchanged" \
    "/" "$(apply_fs_suffix "/")"

assert_eq "empty path is left unchanged" \
    "" "$(apply_fs_suffix "")"

assert_eq "relative path is left unchanged" \
    "ora_1/oradata" "$(apply_fs_suffix "ora_1/oradata")"

echo "Test group B: derive_standby_path (token remap FIRST, then suffix)"

assert_eq "DB-name component swap and suffix compose" \
    "/ora_1_s/oradata/STBY" "$(derive_standby_path "/ora_1/oradata/PROD")"

assert_eq "first component that IS the DB name gets both transformations" \
    "/STBY_s/data" "$(derive_standby_path "/PROD/data")"

assert_eq "lowercase token variant still remaps under the suffix" \
    "/ora_1_s/stby/x" "$(derive_standby_path "/ora_1/prod/x")"

assert_eq "token-less path still gets the filesystem rename" \
    "/ora_arch_s/logs" "$(derive_standby_path "/ora_arch/logs")"

echo "Test group C: empty suffix is a byte-exact no-op (scenario 1)"
STANDBY_FS_SUFFIX=""

assert_eq "derive_standby_path == remap_path_token when suffix is empty" \
    "$(remap_path_token "/ora_1/oradata/PROD")" \
    "$(derive_standby_path "/ora_1/oradata/PROD")"

assert_eq "token-less path passes through unchanged when suffix is empty" \
    "/ora_arch/logs" "$(derive_standby_path "/ora_arch/logs")"

unset STANDBY_FS_SUFFIX
assert_eq "unset suffix behaves like empty (no-op)" \
    "/ora_1/oradata/x" "$(apply_fs_suffix "/ora_1/oradata/x")"

echo "Test group D: other suffix charsets"
STANDBY_FS_SUFFIX="-dr2"

assert_eq "suffix with '-' and digits works" \
    "/ora_1-dr2/oradata" "$(apply_fs_suffix "/ora_1/oradata")"

echo "Test group E: ORACLE_BASE last-component rule (inline expression)"
# The script appends the suffix to the END of ORACLE_BASE (the software
# mount is not renamed): STANDBY_ORACLE_BASE="${PRIMARY_ORACLE_BASE%/}${STANDBY_FS_SUFFIX}"
STANDBY_FS_SUFFIX="_s"
PRIMARY_ORACLE_BASE="/u01/app/oracle"
assert_eq "ORACLE_BASE default gets the suffix on its last component" \
    "/u01/app/oracle_s" "${PRIMARY_ORACLE_BASE%/}${STANDBY_FS_SUFFIX}"

PRIMARY_ORACLE_BASE="/u01/app/oracle/"
assert_eq "ORACLE_BASE trailing slash is stripped before appending" \
    "/u01/app/oracle_s" "${PRIMARY_ORACLE_BASE%/}${STANDBY_FS_SUFFIX}"

# ------------------------------------------------------------
# Drift guard: the apply_fs_suffix / derive_standby_path copies above
# must stay byte-identical to primary/02_generate_standby_config.sh,
# or these tests validate code that no longer ships.
# ------------------------------------------------------------
echo "Test group F: copies have not drifted from the script"
_SCRIPT="$(dirname "$0")/../primary/02_generate_standby_config.sh"
if [[ ! -f "$_SCRIPT" ]]; then
    echo "  FAIL: cannot find $_SCRIPT"
    FAIL=$((FAIL + 1))
else
    for _fn in apply_fs_suffix derive_standby_path; do
        # Range: the function header through its first column-0 '}'.
        _TMP_A="${TMPDIR:-/tmp}/fss_script.$$"
        _TMP_B="${TMPDIR:-/tmp}/fss_test.$$"
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
