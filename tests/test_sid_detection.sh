#!/bin/bash
# ============================================================
# Test script for the SID-detection/validation pipeline used by
# dg_status.sh (_detect_pmon_sid / _validate_sid).
# ============================================================
# Usage: bash tests/test_sid_detection.sh
#
# dg_status.sh executes on load (it is not sourceable in isolation - it
# runs argument parsing, SSH connectivity checks, etc. as soon as it's
# read), so this test REPLICATES the extraction pipeline and validation
# regex as local helper functions instead of sourcing the real script.
#
# *** KEEP THIS IN SYNC WITH dg_status.sh ***
# The helpers below mirror dg_status.sh's _detect_pmon_sid/_validate_sid
# (see the "Resolve SID" section, around the comment
# "Priority: -s flag > $ORACLE_SID > auto-detect from pmon"). If that
# pipeline or regex changes in dg_status.sh, update this file's copies
# to match, or this test silently drifts from what's actually shipped.
#
# Pipeline under test:
#   ps -ef output -> grep '[o]ra_pmon_' | grep -v '+ASM' | head -1
#                 -> sed 's/.*ora_pmon_//'
#   Validation: [[ "$sid" =~ ^[A-Za-z][A-Za-z0-9_$]*$ ]]
# ============================================================

# Don't use set -e as we need to test for failures

PASS=0
FAIL=0

# ------------------------------------------------------------
# Local mirrors of dg_status.sh's SID detection helpers.
# ------------------------------------------------------------

# Mirrors dg_status.sh:_detect_pmon_sid, but takes captured `ps -ef`
# text on stdin instead of running it over SSH.
_detect_pmon_sid_from_ps() {
    local ps_output="$1"
    local pmon_line sid
    pmon_line=$(printf '%s\n' "$ps_output" | grep '[o]ra_pmon_' | grep -v '+ASM' | head -1)
    sid=$(printf '%s' "$pmon_line" | sed 's/.*ora_pmon_//')
    printf '%s' "$sid"
}

# Mirrors dg_status.sh:_validate_sid verbatim.
_validate_sid() {
    [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_$]*$ ]]
}

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    expected: '$expected'"
        echo "    actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_valid() {
    local name="$1" sid="$2"
    if _validate_sid "$sid"; then
        echo "  PASS: $name (accepted '$sid')"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name (expected '$sid' to validate, but it was rejected)"
        FAIL=$((FAIL + 1))
    fi
}

assert_invalid() {
    local name="$1" sid="$2"
    if ! _validate_sid "$sid"; then
        echo "  PASS: $name (rejected '$sid')"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name (expected '$sid' to be rejected, but it validated)"
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================
# Case 1: Normal - single DB pmon line
# ============================================================
echo "Case 1: normal ora_pmon_ line"
PS_NORMAL="root         1     0  0 09:00 ?        00:00:01 /sbin/init
oracle    1234     1  0 10:00 ?        00:00:01 ora_pmon_CDB1
oracle    1235     1  0 10:00 ?        00:00:00 ora_dbw0_CDB1"

sid=$(_detect_pmon_sid_from_ps "$PS_NORMAL")
assert_eq "extracts CDB1 from normal pmon line" "CDB1" "$sid"
assert_valid "extracted SID CDB1 passes validation" "$sid"

# ============================================================
# Case 2: +ASM pmon present ahead of the DB pmon - must be skipped
# ============================================================
echo "Case 2: ora_pmon_+ASM line precedes the real DB pmon line"
PS_ASM_FIRST="root         1     0  0 09:00 ?        00:00:01 /sbin/init
oracle     900     1  0 09:55 ?        00:00:01 ora_pmon_+ASM
oracle    1234     1  0 10:00 ?        00:00:01 ora_pmon_CDB1"

sid=$(_detect_pmon_sid_from_ps "$PS_ASM_FIRST")
assert_eq "+ASM pmon line is skipped; DB SID CDB1 is returned" "CDB1" "$sid"
assert_valid "extracted SID CDB1 (after skipping ASM) passes validation" "$sid"

# ============================================================
# Case 3: Only ASM present - no DB pmon at all
# ============================================================
echo "Case 3: only +ASM pmon present"
PS_ASM_ONLY="root         1     0  0 09:00 ?        00:00:01 /sbin/init
oracle     900     1  0 09:55 ?        00:00:01 ora_pmon_+ASM"

sid=$(_detect_pmon_sid_from_ps "$PS_ASM_ONLY")
assert_eq "no DB pmon present yields empty result" "" "$sid"

# ============================================================
# Case 4: SSH error text instead of ps output
# ============================================================
echo "Case 4: SSH connection error text (no ps output at all)"
SSH_ERROR="ssh: connect to host db1 port 22: Connection refused"

sid=$(_detect_pmon_sid_from_ps "$SSH_ERROR")
assert_eq "SSH error text yields empty extraction (no ora_pmon_ match)" "" "$sid"
assert_invalid "empty SID from SSH error is rejected by validation" "$sid"

# ============================================================
# Case 5: Garbage passthrough containing "ora_pmon_" inside error text
# ============================================================
echo "Case 5: a line that merely mentions ora_pmon_ inside noise/error text"
GARBAGE_LINE="bash: /usr/bin/ps: cannot execute - some error mentions ora_pmon_ but is not a real process line !@#"

sid=$(_detect_pmon_sid_from_ps "$GARBAGE_LINE")
# The sed strips everything up to and including the LAST "ora_pmon_",
# so whatever trails it in the garbage string becomes the "sid" - here
# that is "but is not a real process line !@#". It must fail validation.
assert_invalid "garbage text containing ora_pmon_ produces a string that fails SID validation" "$sid"

# ============================================================
# Case 6: sanity check on _validate_sid's regex directly (documents intent)
# ============================================================
echo "Case 6: _validate_sid regex sanity checks"
assert_valid "'CDB1' is a valid SID shape" "CDB1"
assert_valid "'orcl_1' is a valid SID shape (digits/underscore allowed after first char)" "orcl_1"
assert_invalid "'1CDB' is invalid (must start with a letter)" "1CDB"
assert_invalid "empty string is invalid" ""
assert_invalid "'+ASM' is invalid (must start with a letter, not '+')" "+ASM"

echo ""
echo "============================================================"
echo "Test Summary: $PASS passed, $FAIL failed"
echo "============================================================"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
