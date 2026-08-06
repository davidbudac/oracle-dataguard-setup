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
# Pipeline under test (M23):
#   REMOTE (inside the ssh command):
#     ps -ef | grep '[o]ra_pmon_' | grep -v '+ASM' | sed 's/^/DG_PMON|/'
#   LOCAL (after ssh, stderr NOT merged):
#     grep '^DG_PMON|' | grep 'ora_pmon_' | head -1
#     -> sed 's/[[:space:]]*$//'
#     -> sed -n 's/.*ora_pmon_\([A-Za-z][A-Za-z0-9_$]*\)$/\1/p'
#   Validation: [[ "$sid" =~ ^[A-Za-z][A-Za-z0-9_$]*$ ]]
#
# The DG_PMON| marker is what makes the local filter safe: anything the
# login shell prints on its own (an /etc/motd banner, "Last login:", a
# security notice) reaches the same stdout stream but is NOT marked, so it
# can never be mistaken for a process line. Before this, an unanchored
# `sed 's/.*ora_pmon_//'` over the merged stdout+stderr stream turned any
# banner text mentioning the string into a bogus "SID" and aborted the run.
# ============================================================

# Don't use set -e as we need to test for failures

PASS=0
FAIL=0

# ------------------------------------------------------------
# Local mirrors of dg_status.sh's SID detection helpers.
# ------------------------------------------------------------

# Simulates the REMOTE half: what the ssh command itself writes to stdout.
_simulate_remote_pmon_cmd() {
    local ps_output="$1"
    printf '%s\n' "$ps_output" | grep '[o]ra_pmon_' | grep -v '+ASM' | sed 's/^/DG_PMON|/'
}

# Mirrors the LOCAL half of dg_status.sh:_detect_pmon_sid - it takes the raw
# stdout stream coming back from ssh.
_detect_pmon_sid_from_stream() {
    local stream="$1"
    local pmon_line sid
    pmon_line=$(printf '%s\n' "$stream" | grep '^DG_PMON|' | grep 'ora_pmon_' | head -1)
    if [[ -z "$pmon_line" ]]; then
        printf ''
        return 0
    fi
    sid=$(printf '%s' "$pmon_line" \
        | sed 's/[[:space:]]*$//' \
        | sed -n 's/.*ora_pmon_\([A-Za-z][A-Za-z0-9_$]*\)$/\1/p')
    printf '%s' "$sid"
}

# Convenience wrapper for the common "clean host, no banner" case: run the
# full remote+local pipeline over captured `ps -ef` text.
_detect_pmon_sid_from_ps() {
    _detect_pmon_sid_from_stream "$(_simulate_remote_pmon_cmd "$1")"
}

# Full pipeline for a host whose login shell prints a banner first.
_detect_pmon_sid_with_banner() {
    local ps_output="$1" banner="$2"
    local stream
    stream="${banner}
$(_simulate_remote_pmon_cmd "$ps_output")"
    _detect_pmon_sid_from_stream "$stream"
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

sid=$(_detect_pmon_sid_from_stream "$SSH_ERROR")
assert_eq "SSH error text yields empty extraction (no DG_PMON marker)" "" "$sid"
assert_invalid "empty SID from SSH error is rejected by validation" "$sid"

# ============================================================
# Case 5: Garbage passthrough containing "ora_pmon_" inside error text
# ============================================================
echo "Case 5: a line that merely mentions ora_pmon_ inside noise/error text"
GARBAGE_LINE="bash: /usr/bin/ps: cannot execute - some error mentions ora_pmon_ but is not a real process line !@#"

sid=$(_detect_pmon_sid_from_stream "$GARBAGE_LINE")
# Unmarked (it never went through the remote `sed 's/^/DG_PMON|/'`), so the
# local marker filter drops it outright.
assert_eq "unmarked garbage mentioning ora_pmon_ is dropped by the marker filter" "" "$sid"
assert_invalid "garbage text containing ora_pmon_ never yields a valid SID" "$sid"

# Belt and braces: even if such a line DID carry the marker, the anchored
# extraction (ora_pmon_<SID> must be the last token, SID charset enforced)
# refuses to invent a SID from prose.
sid=$(_detect_pmon_sid_from_stream "DG_PMON|${GARBAGE_LINE}")
assert_eq "marked garbage still yields nothing (anchored extraction)" "" "$sid"

# ============================================================
# Case 5b (M23): login banner / MOTD pollution on the same stdout stream
# ============================================================
echo "Case 5b: server login banner precedes the real ps output"
BANNER="Last login: Tue Aug  5 09:12:31 2026 from 10.0.0.5
****************************************************************
 WARNING: Authorised users only. All sessions are logged.
 Do not stop ora_pmon_ processes without a change record.
****************************************************************"

sid=$(_detect_pmon_sid_with_banner "$PS_NORMAL" "$BANNER")
assert_eq "banner mentioning ora_pmon_ is ignored; real SID CDB1 wins" "CDB1" "$sid"
assert_valid "SID detected despite banner pollution passes validation" "$sid"

echo "Case 5c: banner-only output (instance down, banner still printed)"
sid=$(_detect_pmon_sid_with_banner "" "$BANNER")
assert_eq "banner with no running instance yields empty (not banner text)" "" "$sid"
assert_invalid "empty SID from a banner-only stream is rejected" "$sid"

# ============================================================
# Case 5d: ps line with trailing whitespace
# ============================================================
echo "Case 5d: ps line padded with trailing whitespace"
PS_TRAILING="oracle    1234     1  0 10:00 ?        00:00:01 ora_pmon_CDB1   "

sid=$(_detect_pmon_sid_from_ps "$PS_TRAILING")
assert_eq "trailing whitespace is trimmed from the extracted SID" "CDB1" "$sid"
assert_valid "SID extracted from a padded ps line passes validation" "$sid"

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
