#!/bin/bash
# ============================================================
# Test script demonstrating why `((VAR++))` / `((VAR--))` is banned
# in scripts that run under `set -e`, and sweeping the repo to make
# sure no script uses that construct.
# ============================================================
# Usage: bash tests/test_counter_increment.sh
#
# Background: `((expr))` returns a non-zero exit status when the
# arithmetic expression evaluates to 0. `x=0; ((x++))` evaluates the
# PRE-increment value (0) as the command's exit status, so under
# `set -e` the shell exits immediately - even though the increment
# itself "succeeded" and x is now 1. This is why the codebase
# standardizes on `x=$((x+1))` (a plain assignment, whose exit
# status is always 0) for PASS/FAIL-style counters.
# ============================================================

# Don't use set -e in THIS test driver - we need to test for failures,
# including deliberately triggering `set -e` exits in subshells.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

# ============================================================
# Part 1: demonstrate the bug class
# ============================================================
echo "Part 1: ((VAR++)) vs \$((VAR+1)) under set -e"

echo "Test 1: ((x++)) in a 'set -e' subshell must exit non-zero BEFORE the sentinel echo"
out=$(bash -e -c 'x=0; ((x++)); echo SENTINEL_REACHED' 2>&1)
rc=$?
if [[ $rc -ne 0 && "$out" != *SENTINEL_REACHED* ]]; then
    echo "  PASS: ((x++)) aborted the set -e subshell before the sentinel (rc=$rc, out='$out')"
    PASS=$((PASS + 1))
else
    echo "  FAIL: expected non-zero exit and no sentinel, got rc=$rc out='$out'"
    FAIL=$((FAIL + 1))
fi

echo "Test 2: x=\$((x+1)) survives 'set -e' and reaches the sentinel echo"
out=$(bash -e -c 'x=0; x=$((x+1)); echo SENTINEL_REACHED' 2>&1)
rc=$?
if [[ $rc -eq 0 && "$out" == *SENTINEL_REACHED* ]]; then
    echo "  PASS: x=\$((x+1)) form survives set -e and reaches the sentinel (rc=$rc, out='$out')"
    PASS=$((PASS + 1))
else
    echo "  FAIL: expected rc=0 and sentinel reached, got rc=$rc out='$out'"
    FAIL=$((FAIL + 1))
fi

echo "Test 3: ((x--)) has the same problem when x starts at 1 (post-decrement evaluates to 1... but going 1->0 is fine; the danger case is going TO zero)"
# The dangerous case for both ++ and -- is when the arithmetic expression's
# value (the *result*, for -- going down to 0, or the *pre-value* for ++
# starting at 0) evaluates to 0. Demonstrate the classic decrement-to-zero case.
out=$(bash -e -c 'x=1; ((x--)); echo SENTINEL_REACHED' 2>&1)
rc=$?
if [[ $rc -eq 0 && "$out" == *SENTINEL_REACHED* ]]; then
    # ((x--)) evaluates to the PRE-decrement value (1), which is non-zero,
    # so this particular case does NOT trip set -e. This documents the
    # subtlety: the bug is intermittent/value-dependent, which is exactly
    # why the codebase bans the construct outright rather than relying on
    # callers to reason about which starting values are "safe".
    echo "  PASS (documentation): ((x--)) from x=1 does not trip set -e (pre-decrement value 1 is truthy) - illustrates the construct is unsafe in general, not merely when starting at 0"
    PASS=$((PASS + 1))
else
    echo "  FAIL: unexpected result for ((x--)) from x=1: rc=$rc out='$out'"
    FAIL=$((FAIL + 1))
fi

echo "Test 4: ((x--)) from x=1 down to x=0 on the NEXT call trips set -e (post-state 0 becomes the next call's pre-state)"
out=$(bash -e -c 'x=1; ((x--)); ((x--)); echo SENTINEL_REACHED' 2>&1)
rc=$?
if [[ $rc -ne 0 && "$out" != *SENTINEL_REACHED* ]]; then
    echo "  PASS: second ((x--)) (x going 0->-1, evaluating the pre-value 0) aborted before the sentinel (rc=$rc, out='$out')"
    PASS=$((PASS + 1))
else
    echo "  FAIL: expected non-zero exit and no sentinel, got rc=$rc out='$out'"
    FAIL=$((FAIL + 1))
fi

# ============================================================
# Part 2: repo-wide sweep for ((VAR++)) / ((VAR--)) usage
# ============================================================
echo ""
echo "Part 2: repo-wide sweep for ((VAR++)) / ((VAR--))"

cd "$REPO_ROOT" || exit 1

# Exclude this test file itself: it necessarily quotes ((VAR++))/((VAR--))
# in comments and echo strings for documentation purposes, which are not
# real usages of the banned construct.
VIOLATIONS=""
# .claude is excluded for the same reason as .git: tool-managed worktrees
# under it can hold a full repo copy that double-reports every finding.
mapfile -t SH_FILES < <(find . \( -path ./.git -o -path ./.claude \) -prune -o -type f -name '*.sh' -print | sed 's#^\./##' | grep -v '^tests/test_counter_increment\.sh$')

for f in "${SH_FILES[@]}"; do
    while IFS=: read -r lineno line; do
        [[ -z "$lineno" ]] && continue
        VIOLATIONS="${VIOLATIONS}${f}:${lineno}: ${line}
"
    done < <(grep -nE '\(\([A-Za-z_]+(\+\+|--)\)\)' "$f" 2>/dev/null)
done

if [[ -n "$VIOLATIONS" ]]; then
    echo "  FAIL: ((VAR++))/((VAR--)) usage found:"
    printf '%s' "$VIOLATIONS"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: no ((VAR++)) or ((VAR--)) usage found in any *.sh file"
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
