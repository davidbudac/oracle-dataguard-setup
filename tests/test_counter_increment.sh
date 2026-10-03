#!/usr/bin/env bash
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

# ------------------------------------------------------------
# Supported shell: Bash 3.2 or later (the macOS /bin/bash and the oldest
# shell the AIX 7.2 hosts run these scripts under).
#
# Test authors: do not use Bash-4-only syntax in any tests/test_*.sh -
#   mapfile / readarray, declare -A, ${v^^} / ${v,,}, &>> , |& , coproc,
#   negative array subscripts (${a[-1]}), `read -t 0.5` fractional timeouts.
# Build file lists with a `while read` loop, and make a check that could not
# run FAIL - never fall through to a PASS line. Run the suites under the
# oldest shell before relying on them:
#   mkdir -p "$TMPDIR/bash32/bin" && ln -sf /bin/bash "$TMPDIR/bash32/bin/bash"
#   PATH="$TMPDIR/bash32/bin:$PATH" /bin/bash tests/test_<name>.sh
# (the PATH entry makes every inner `bash` / `#!/usr/bin/env bash` 3.2 too).
# ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# The shell under test runs the Part 1 demonstrations: "$BASH" is the
# interpreter executing this file, so a `bash` that happens to be first on
# PATH (a different version) can never answer for it.
SHELL_UNDER_TEST="${BASH:-bash}"

PASS=0
FAIL=0

# Does `set -e` abort on a failing ((expr))? Bash added that in 4.1; 3.2 and
# 4.0 exempt the arithmetic command from errexit (its exit status is still 1).
if [[ "${BASH_VERSINFO[0]}" -gt 4 ]] || { [[ "${BASH_VERSINFO[0]}" -eq 4 ]] && [[ "${BASH_VERSINFO[1]}" -ge 1 ]]; }; then
    ERREXIT_ARITH="aborts"
else
    ERREXIT_ARITH="ignored"
fi

echo "Bash version under test: ${BASH_VERSION} (${SHELL_UNDER_TEST})"
echo "set -e on a false ((expr)) in this shell: ${ERREXIT_ARITH}"
echo "(the construct is banned either way - the Part 2 sweep is the enforcement)"
echo ""

# ============================================================
# Part 1: demonstrate the bug class
# ============================================================
echo "Part 1: ((VAR++)) vs \$((VAR+1)) under set -e"

echo "Test 1: ((x++)) from x=0 has exit status 1 in every Bash version"
out=$("$SHELL_UNDER_TEST" -c 'x=0; ((x++)); echo STATUS=$? X=$x' 2>&1)
rc=$?
if [[ $rc -eq 0 && "$out" == "STATUS=1 X=1" ]]; then
    echo "  PASS: ((x++)) incremented x to 1 but returned status 1 (the pre-increment value 0 is 'false') (out='$out')"
    PASS=$((PASS + 1))
else
    echo "  FAIL: expected 'STATUS=1 X=1', got rc=$rc out='$out'"
    FAIL=$((FAIL + 1))
fi

echo "Test 1b: ((x++)) in a 'set -e' subshell (this Bash: ${ERREXIT_ARITH})"
out=$("$SHELL_UNDER_TEST" -e -c 'x=0; ((x++)); echo SENTINEL_REACHED' 2>&1)
rc=$?
if [[ "$ERREXIT_ARITH" == "aborts" ]]; then
    if [[ $rc -ne 0 && "$out" != *SENTINEL_REACHED* ]]; then
        echo "  PASS: ((x++)) aborted the set -e subshell before the sentinel (rc=$rc, out='$out')"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: expected non-zero exit and no sentinel, got rc=$rc out='$out'"
        FAIL=$((FAIL + 1))
    fi
else
    if [[ $rc -eq 0 && "$out" == *SENTINEL_REACHED* ]]; then
        echo "  PASS (Bash < 4.1): set -e does NOT abort on ((x++)) here - the script limps on with a hidden status 1, and aborts as soon as it runs under Bash >= 4.1 (rc=$rc, out='$out')"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: expected Bash < 4.1 to ignore the status under set -e, got rc=$rc out='$out'"
        FAIL=$((FAIL + 1))
    fi
fi

echo "Test 2: x=\$((x+1)) survives 'set -e' and reaches the sentinel echo"
out=$("$SHELL_UNDER_TEST" -e -c 'x=0; x=$((x+1)); echo SENTINEL_REACHED' 2>&1)
rc=$?
if [[ $rc -eq 0 && "$out" == *SENTINEL_REACHED* ]]; then
    echo "  PASS: x=\$((x+1)) form survives set -e and reaches the sentinel (rc=$rc, out='$out')"
    PASS=$((PASS + 1))
else
    echo "  FAIL: expected rc=0 and sentinel reached, got rc=$rc out='$out'"
    FAIL=$((FAIL + 1))
fi

echo "Test 3: ((x--)) from x=1 does not trip set -e (pre-decrement value 1 is truthy) in any version"
# The dangerous case for both ++ and -- is when the arithmetic expression's
# value (the *pre-value* for post-increment/decrement) evaluates to 0.
out=$("$SHELL_UNDER_TEST" -e -c 'x=1; ((x--)); echo SENTINEL_REACHED' 2>&1)
rc=$?
if [[ $rc -eq 0 && "$out" == *SENTINEL_REACHED* ]]; then
    # This documents the subtlety: the bug is intermittent/value-dependent,
    # which is exactly why the codebase bans the construct outright rather
    # than relying on callers to reason about which starting values are "safe".
    echo "  PASS (documentation): ((x--)) from x=1 does not trip set -e - illustrates the construct is unsafe in general, not merely when starting at 0"
    PASS=$((PASS + 1))
else
    echo "  FAIL: unexpected result for ((x--)) from x=1: rc=$rc out='$out'"
    FAIL=$((FAIL + 1))
fi

echo "Test 4: a second ((x--)) (pre-value 0) in a 'set -e' subshell (this Bash: ${ERREXIT_ARITH})"
out=$("$SHELL_UNDER_TEST" -e -c 'x=1; ((x--)); ((x--)); echo SENTINEL_REACHED X=$x' 2>&1)
rc=$?
if [[ "$ERREXIT_ARITH" == "aborts" ]]; then
    if [[ $rc -ne 0 && "$out" != *SENTINEL_REACHED* ]]; then
        echo "  PASS: second ((x--)) (evaluating the pre-value 0) aborted before the sentinel (rc=$rc, out='$out')"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: expected non-zero exit and no sentinel, got rc=$rc out='$out'"
        FAIL=$((FAIL + 1))
    fi
else
    if [[ $rc -eq 0 && "$out" == "SENTINEL_REACHED X=-1" ]]; then
        echo "  PASS (Bash < 4.1): second ((x--)) did not abort; x went to -1 with a hidden status 1 (rc=$rc, out='$out')"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: expected Bash < 4.1 to ignore the status under set -e, got rc=$rc out='$out'"
        FAIL=$((FAIL + 1))
    fi
fi

# ============================================================
# Part 2: repo-wide sweep for ((VAR++)) / ((VAR--)) usage
# ============================================================
echo ""
echo "Part 2: repo-wide sweep for ((VAR++)) / ((VAR--))"

cd "$REPO_ROOT" || { echo "  FAIL: cannot cd to $REPO_ROOT"; exit 1; }

# Exclude this test file itself: it necessarily quotes ((VAR++))/((VAR--))
# in comments and echo strings for documentation purposes, which are not
# real usages of the banned construct.
# .claude is excluded for the same reason as .git: tool-managed worktrees
# under it can hold a full repo copy that double-reports every finding.
# The list is built with a while-read loop (mapfile is Bash 4+), and a list
# that cannot be built - or is empty - FAILS the sweep: it must never report
# PASS for files it did not scan.
SWEEP_OK=1
FILE_LIST=$(find . \( -path ./.git -o -path ./.claude \) -prune -o -type f -name '*.sh' -print)
find_rc=$?
if [[ $find_rc -ne 0 ]]; then
    echo "  FAIL: find exited $find_rc while listing *.sh files"
    SWEEP_OK=0
fi

VIOLATIONS=""
SCANNED=0
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    f="${f#./}"
    [[ "$f" == "tests/test_counter_increment.sh" ]] && continue
    SCANNED=$((SCANNED + 1))
    matches=$(grep -nE '\(\([A-Za-z_]+(\+\+|--)\)\)' "$f" 2>&1)
    grc=$?
    if [[ $grc -ge 2 ]]; then
        echo "  FAIL: grep could not scan $f (rc=$grc): $matches"
        SWEEP_OK=0
        continue
    fi
    [[ $grc -ne 0 ]] && continue
    while IFS=: read -r lineno line; do
        [[ -z "$lineno" ]] && continue
        VIOLATIONS="${VIOLATIONS}${f}:${lineno}: ${line}
"
    done <<EOF_MATCHES
$matches
EOF_MATCHES
done <<EOF_FILES
$FILE_LIST
EOF_FILES

if [[ $SCANNED -eq 0 ]]; then
    echo "  FAIL: the sweep found no *.sh files to scan (find output empty) - nothing was verified"
    SWEEP_OK=0
fi

if [[ -n "$VIOLATIONS" ]]; then
    echo "  FAIL: ((VAR++))/((VAR--)) usage found:"
    printf '%s' "$VIOLATIONS"
    FAIL=$((FAIL + 1))
elif [[ $SWEEP_OK -ne 1 ]]; then
    FAIL=$((FAIL + 1))
else
    echo "  PASS: no ((VAR++)) or ((VAR--)) usage found in any of the $SCANNED *.sh files scanned"
    PASS=$((PASS + 1))
fi

echo ""
echo "============================================================"
echo "Test Summary: $PASS passed, $FAIL failed (Bash ${BASH_VERSION})"
echo "============================================================"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
