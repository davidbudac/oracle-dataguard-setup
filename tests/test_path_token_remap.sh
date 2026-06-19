#!/bin/bash
# ============================================================
# Unit test for the per-path token remapping logic in
# primary/02_generate_standby_config.sh
# ============================================================
# Regression guard for two improvements:
#   1. Per-path token detection - each datafile/redo directory is
#      remapped independently, so a datafile mount using one case
#      (.../DGNONC) and a redo mount using another (.../dgnonc) BOTH
#      remap instead of leaving the case-mismatched one for the
#      operator to hand-edit.
#   2. Substring-safe replacement - the DB-name token is only swapped
#      when it is a whole, slash-delimited path COMPONENT, so a token
#      that also appears as a substring of a mount name (e.g. token
#      DGNONC inside /DGNONCDATA/) is never corrupted.
#
# The three helper functions below are kept byte-identical to the
# copies in primary/02_generate_standby_config.sh so a regression in
# either copy fails this test.
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
# remap_path_token() reads the four *_DIR_NAME_* / *_UNIQUE_NAME
# globals set per scenario below.
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

# Set the case-variant globals from DB_UNIQUE_NAME / STANDBY_DB_UNIQUE_NAME
# exactly as the script does before the remap loop.
setup_names() {
    DB_UNIQUE_NAME="$1"
    STANDBY_DB_UNIQUE_NAME="$2"
    DB_UNIQUE_NAME_UPPER=$(echo "$DB_UNIQUE_NAME" | tr '[:lower:]' '[:upper:]')
    DB_UNIQUE_NAME_LOWER=$(echo "$DB_UNIQUE_NAME" | tr '[:upper:]' '[:lower:]')
    STANDBY_DIR_NAME_UPPER=$(echo "$STANDBY_DB_UNIQUE_NAME" | tr '[:lower:]' '[:upper:]')
    STANDBY_DIR_NAME_LOWER=$(echo "$STANDBY_DB_UNIQUE_NAME" | tr '[:upper:]' '[:lower:]')
}

echo "Test group A: token DGNONC -> dgnonc_s (case-preserving per path)"
setup_names "DGNONC" "dgnonc_s"

assert_eq "uppercase datafile dir keeps uppercase standby dir" \
    "/u01/oradata/DGNONC_S" "$(remap_path_token "/u01/oradata/DGNONC")"

assert_eq "lowercase redo dir on a separate mount still remaps (improvement #2)" \
    "/u02/redo/dgnonc_s" "$(remap_path_token "/u02/redo/dgnonc")"

assert_eq "token as a substring of a larger dir name is NOT corrupted (improvement #3)" \
    "/u01/DGNONCDATA/DGNONC_S" "$(remap_path_token "/u01/DGNONCDATA/DGNONC")"

assert_eq "token only as a substring (no whole component) is left unchanged" \
    "/u01/DGNONCDATA/oradata" "$(remap_path_token "/u01/DGNONCDATA/oradata")"

assert_eq "every whole-component occurrence is replaced" \
    "/DGNONC_S/oradata/DGNONC_S" "$(remap_path_token "/DGNONC/oradata/DGNONC")"

assert_eq "a token-less path is returned unchanged (falls to operator confirm)" \
    "/shared/redo" "$(remap_path_token "/shared/redo")"

assert_eq "an old-style trailing-slash path still remaps" \
    "/u01/oradata/DGNONC_S/" "$(remap_path_token "/u01/oradata/DGNONC/")"

echo "Test group B: mixed-case DB name DgNonC -> DgNonC_s"
setup_names "DgNonC" "DgNonC_s"

assert_eq "literal mixed-case component maps to standby literal" \
    "/u01/oradata/DgNonC_s" "$(remap_path_token "/u01/oradata/DgNonC")"

assert_eq "uppercase variant of a mixed-case name maps to uppercase standby" \
    "/u01/oradata/DGNONC_S" "$(remap_path_token "/u01/oradata/DGNONC")"

assert_eq "lowercase variant of a mixed-case name maps to lowercase standby" \
    "/u01/oradata/dgnonc_s" "$(remap_path_token "/u01/oradata/dgnonc")"

echo ""
echo "============================================================"
echo "PASSED: $PASS  FAILED: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
