#!/bin/bash
# ============================================================
# Test script for grep portability (AIX/Linux compatible grep usage)
# ============================================================
# Usage: bash tests/test_grep_portability.sh
#
# Part 1: behavior tests for the exact broker-output detection patterns
#         used in common/dg_local_status_common.sh (assess_broker), run
#         against realistic captured DGMGRL SHOW CONFIGURATION samples.
# Part 2: a repo-wide sweep that fails if any *.sh file uses grep -P,
#         \s / \S inside a grep pattern, or BRE-style \| alternation
#         inside a grep pattern - all of which are GNU-grep-only or
#         behave differently on AIX's POSIX grep.
# ============================================================

# Don't use set -e as we need to test for failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

assert_true() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
}

assert_false() {
    local name="$1"
    shift
    if ! "$@" >/dev/null 2>&1; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================
# Part 1: behavior tests
# ============================================================
# Patterns copied VERBATIM from common/dg_local_status_common.sh
# assess_broker(). If the code changes, update these to match, or this
# test drifts from what is actually shipped.
BROKER_ERROR_PATTERN="ORA-16532|not yet available|not exist"
MEMBER_LINE_PATTERN='^[[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+'

echo "Part 1: broker-output detection pattern behavior"

# (a) Healthy SHOW CONFIGURATION output
HEALTHY_CONFIG="Configuration - dgconfig

  Protection Mode: MaxAvailability
  Members:
  cdb1   - Primary database
    cdb1dr - Physical standby database

Fast-Start Failover: DISABLED

Configuration Status:
SUCCESS"

assert_false "healthy config does NOT match broker-error pattern" \
    bash -c "printf '%s' \"\$1\" | grep -qE \"\$2\"" _ "$HEALTHY_CONFIG" "$BROKER_ERROR_PATTERN"

assert_true "healthy config member line 'cdb1   - Primary database' matches member-line pattern" \
    bash -c "printf '%s' \"\$1\" | grep -qE \"\$2\"" _ "  cdb1   - Primary database" "$MEMBER_LINE_PATTERN"

assert_true "healthy config member line 'cdb1dr - Physical standby database' matches member-line pattern" \
    bash -c "printf '%s' \"\$1\" | grep -qE \"\$2\"" _ "    cdb1dr - Physical standby database" "$MEMBER_LINE_PATTERN"

# (b) Broker-not-configured output
NOT_CONFIGURED="DGMGRL for Linux: Release 19.0.0.0.0

ORA-16532: Oracle Data Guard broker configuration does not exist

Configuration details cannot be determined by DGMGRL"

assert_true "broker-not-configured output matches broker-error pattern (ORA-16532)" \
    bash -c "printf '%s' \"\$1\" | grep -qE \"\$2\"" _ "$NOT_CONFIGURED" "$BROKER_ERROR_PATTERN"

# (c) Member line with an error
ERROR_MEMBER_LINE="  cdb1dr - Physical standby database
    Error: ORA-16810: multiple errors or warnings detected for the database"

assert_true "member line with ORA-16810 still matches the member-line pattern" \
    bash -c "printf '%s' \"\$1\" | grep -qE \"\$2\"" _ "  cdb1dr - Physical standby database" "$MEMBER_LINE_PATTERN"

assert_true "'Error: ORA-16810...' line trimmed matches case-insensitive Error grep (as used downstream)" \
    bash -c "printf '%s' \"\$1\" | grep -qi \"Error\"" _ "Error: ORA-16810: multiple errors or warnings detected for the database"

# ============================================================
# Part 2: repo-wide sweep for non-portable grep usage
# ============================================================
echo ""
echo "Part 2: repo-wide grep portability sweep"

cd "$REPO_ROOT" || exit 1

SWEEP_FAIL=0
VIOLATIONS=""

# Collect all shell scripts, excluding .git and this test file itself.
# This test file necessarily mentions "grep -P", "\s", "\S" and "\|" in its
# own comments/strings (to describe what it looks for and to report
# findings) - those are not real production grep invocations, so exclude
# it from the sweep rather than trying to out-clever false positives on
# our own source.
mapfile -t SH_FILES < <(find . -path ./.git -prune -o -type f -name '*.sh' -print | sed 's#^\./##' | grep -v '^tests/test_grep_portability\.sh$')

for f in "${SH_FILES[@]}"; do
    # Candidate lines: strip pure comment lines (first non-blank char is #)
    # so narrative text like "# use sed instead of grep -P" doesn't trip
    # the sweep - we only care about actual grep invocations.
    while IFS=: read -r lineno line; do
        [[ -z "$lineno" ]] && continue
        if [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue  # comment-only line, skip
        fi

        # 1. grep -P usage (PCRE, GNU-only - not available on AIX grep)
        if printf '%s' "$line" | grep -qE '(^|[^A-Za-z0-9_])grep([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*P'; then
            VIOLATIONS="${VIOLATIONS}${f}:${lineno}: grep -P usage: ${line}
"
            SWEEP_FAIL=$((SWEEP_FAIL + 1))
        fi

        # 2. \s or \S inside a line that actually invokes grep
        if printf '%s' "$line" | grep -q 'grep' && printf '%s' "$line" | grep -qE '\\s|\\S'; then
            VIOLATIONS="${VIOLATIONS}${f}:${lineno}: grep with \\s/\\S: ${line}
"
            SWEEP_FAIL=$((SWEEP_FAIL + 1))
        fi

        # 3. BRE-style alternation \| inside a line that actually invokes grep
        if printf '%s' "$line" | grep -q 'grep' && printf '%s' "$line" | grep -qF '\|'; then
            VIOLATIONS="${VIOLATIONS}${f}:${lineno}: grep with BRE alternation \\|: ${line}
"
            SWEEP_FAIL=$((SWEEP_FAIL + 1))
        fi
    done < <(grep -n 'grep' "$f" 2>/dev/null)
done

if [[ -n "$VIOLATIONS" ]]; then
    echo "  FAIL: non-portable grep usage found:"
    printf '%s' "$VIOLATIONS"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: no grep -P, \\s/\\S, or BRE \\| alternation found in any *.sh file"
    PASS=$((PASS + 1))
fi

echo ""
echo "============================================================"
echo "Test Summary: $PASS passed, $FAIL failed"
echo "============================================================"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
