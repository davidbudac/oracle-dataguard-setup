#!/usr/bin/env bash
# ============================================================
# Test script for step 9's observer-user standby propagation
# (primary/09_configure_fsfo.sh)
# ============================================================
# Usage: bash tests/test_step9_observer_user.sh
#
# Verified on 19.27 with a MOUNTED physical standby: CREATE USER + GRANT SYSDG
# on the primary do not reach the standby's password file, a following
# ALTER USER ... IDENTIFIED BY (same password) does. Step 9 therefore sets the
# password a second time and proves the observer login to the other member
# before touching LogXptMode / protection mode / FSFO.
#
# prove_observer_standby_login is extracted from the script (nothing is
# mirrored) and run against a stub sqlplus on PATH. The SQL order of the
# create path is asserted statically (an end-to-end run needs a TTY for the
# password prompts). DB-free.
# ============================================================

# Don't use set -e as we need to test for failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT_UNDER_TEST="${REPO_DIR}/primary/09_configure_fsfo.sh"

LOG_FILE=/dev/null
source "${REPO_DIR}/common/dg_functions.sh"

PASS=0
FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    expected: [$expected]"
        echo "    actual:   [$actual]"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s\n' "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name (missing: $needle)"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s\n' "$haystack" | grep -qF -- "$needle"; then
        echo "  FAIL: $name (unexpected: $needle)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/step9_obs_test.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------
# Extract the function under test
# ------------------------------------------------------------
awk '/^prove_observer_standby_login\(\) \{/{p=1} p{print} p&&/^\}/{exit}' \
    "$SCRIPT_UNDER_TEST" > "$WORK/func.sh"
if [[ ! -s "$WORK/func.sh" ]]; then
    echo "FAIL: prove_observer_standby_login not found in $SCRIPT_UNDER_TEST"
    exit 1
fi
source "$WORK/func.sh"

# No real sleeping
sleep() { :; }

# Stub sqlplus: records the stdin of every call; "logs in" from call number
# $STUB_OK_AFTER on (0 = never), otherwise answers like a standby that has not
# got the user in its password file.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/sqlplus" <<'STUB'
#!/bin/bash
n=$(cat "$STUB_DIR/count" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$STUB_DIR/count"
echo "$*" >> "$STUB_DIR/argv"
cat > "$STUB_DIR/stdin.$n"
if [[ "${STUB_OK_AFTER:-0}" -gt 0 && $n -ge $STUB_OK_AFTER ]]; then
    echo "OBSERVER_LOGIN_OK|C##DG_OBSERVER"
else
    echo "ERROR:"
    echo "ORA-01017: invalid username/password; logon denied"
    echo "SP2-0640: Not connected"
fi
exit 0
STUB
chmod +x "$WORK/bin/sqlplus"
export STUB_DIR="$WORK/stub"
PATH="$WORK/bin:$PATH"

reset_stub() { rm -rf "$STUB_DIR"; mkdir -p "$STUB_DIR"; }

OBSERVER_USER="C##DG_OBSERVER"
OBSERVER_PASSWORD='S3cret&Pw#1'

# ------------------------------------------------------------
echo "Test 1: success on the first try"
# ------------------------------------------------------------
reset_stub
export STUB_OK_AFTER=1; OUT=$(prove_observer_standby_login "STBY.world" 2>&1); RC=$?
assert_eq "returns 0" "0" "$RC"
assert_eq "one sqlplus call" "1" "$(cat "$STUB_DIR/count")"
assert_contains "logs the success" "logs in AS SYSDG to STBY.world" "$OUT"
assert_contains "stdin: SET DEFINE OFF first" "SET DEFINE OFF" "$(sed -n 1p "$STUB_DIR/stdin.1")"
assert_contains "stdin: CONNECT user/\"pw\"@alias AS SYSDG" \
    'CONNECT C##DG_OBSERVER/"S3cret&Pw#1"@STBY.world AS SYSDG' "$(cat "$STUB_DIR/stdin.1")"
assert_eq "sqlplus is /nolog (no password on argv)" "-s -L /nolog" "$(sed -n 1p "$STUB_DIR/argv")"
assert_not_contains "password not in captured output" "S3cret" "$OUT"

# ------------------------------------------------------------
echo "Test 2: success after a few ORA-01017 answers"
# ------------------------------------------------------------
reset_stub
export STUB_OK_AFTER=4; OUT=$(prove_observer_standby_login "STBY.world" 2>&1); RC=$?
assert_eq "returns 0" "0" "$RC"
assert_eq "four sqlplus calls" "4" "$(cat "$STUB_DIR/count")"
assert_contains "reports the attempt count" "after 4 attempt(s)" "$OUT"
assert_not_contains "password not in captured output" "S3cret" "$OUT"

# ------------------------------------------------------------
echo "Test 3: failure after the bound"
# ------------------------------------------------------------
reset_stub
export STUB_OK_AFTER=0; OUT=$(prove_observer_standby_login "STBY.world" 2>&1); RC=$?
assert_eq "returns non-zero" "1" "$RC"
assert_eq "default bound: 30s / 3s poll = 11 attempts" "11" "$(cat "$STUB_DIR/count")"
assert_contains "the last ORA- line is reported" "ORA-01017: invalid username/password" "$OUT"
assert_contains "names the alias" "cannot log in AS SYSDG to STBY.world" "$OUT"
assert_not_contains "password not in captured output" "S3cret" "$OUT"

# ------------------------------------------------------------
echo "Test 4: the wait bound is overridable (DG_OBSERVER_STANDBY_LOGIN_WAIT_SECS)"
# ------------------------------------------------------------
reset_stub
export STUB_OK_AFTER=0; export DG_OBSERVER_STANDBY_LOGIN_WAIT_SECS=0; OUT=$(prove_observer_standby_login "STBY.world" 2>&1); RC=$?
assert_eq "0 = a single attempt, returns non-zero" "1" "$RC"
assert_eq "one sqlplus call" "1" "$(cat "$STUB_DIR/count")"
reset_stub
export DG_OBSERVER_STANDBY_LOGIN_WAIT_SECS=9; OUT=$(prove_observer_standby_login "STBY.world" 2>&1); RC=$?
assert_eq "9s / 3s poll = 4 attempts" "4" "$(cat "$STUB_DIR/count")"
reset_stub
export DG_OBSERVER_STANDBY_LOGIN_WAIT_SECS=abc; OUT=$(prove_observer_standby_login "STBY.world" 2>&1); RC=$?
assert_contains "a non-numeric value warns and falls back to 30" "not a non-negative integer" "$OUT"
assert_eq "fallback = 11 attempts" "11" "$(cat "$STUB_DIR/count")"
unset DG_OBSERVER_STANDBY_LOGIN_WAIT_SECS

# ------------------------------------------------------------
echo "Test 5: verbose trace never prints the password (xtrace paused)"
# ------------------------------------------------------------
reset_stub
export STUB_OK_AFTER=0 DG_OBSERVER_STANDBY_LOGIN_WAIT_SECS=0
VERBOSE=1
TRACE=$( { set -x; prove_observer_standby_login "STBY.world" >/dev/null; set +x; } 2>&1 )
VERBOSE=0
unset DG_OBSERVER_STANDBY_LOGIN_WAIT_SECS
# (the failure path is where the password is expanded: the redaction line)
assert_contains "the trace is really on (sanity)" "prove_observer_standby_login" "$TRACE"
assert_not_contains "no password in xtrace output" "S3cret" "$TRACE"

# ------------------------------------------------------------
echo "Test 6: alias choice follows DG_CONFIG_ROLES_SWAPPED (script text)"
# ------------------------------------------------------------
# The alias is chosen in the main flow, so it is asserted on the script text.
BLOCK=$(awk '/OBSERVER_PW_HELD" == "1"/{p=1} p{print} p&&/^fi$/{exit}' "$SCRIPT_UNDER_TEST")
assert_contains "swapped roles use PRIMARY_TNS_ALIAS" 'OBSERVER_PEER_ALIAS="$PRIMARY_TNS_ALIAS"' "$BLOCK"
assert_contains "normal roles use STANDBY_TNS_ALIAS" 'OBSERVER_PEER_ALIAS="$STANDBY_TNS_ALIAS"' "$BLOCK"
assert_contains "swapped test is on DG_CONFIG_ROLES_SWAPPED" 'DG_CONFIG_ROLES_SWAPPED:-0}" == "1"' "$BLOCK"
assert_contains "failure exits 1" "exit 1" "$BLOCK"

# ------------------------------------------------------------
echo "Test 7: new-user path issues ALTER USER ... IDENTIFIED BY after GRANT SYSDG"
# ------------------------------------------------------------
NEWUSER=$(awk '/CREATE_RC=0/{p=1} p{print} p&&/OBSERVER_PW_HELD=1/{exit}' "$SCRIPT_UNDER_TEST")
L_GRANT=$(printf '%s\n' "$NEWUSER" | grep -n '^GRANT SYSDG TO' | head -1 | cut -d: -f1)
L_ALTER=$(printf '%s\n' "$NEWUSER" | grep -n '^ALTER USER .* IDENTIFIED BY "' | head -1 | cut -d: -f1)
if [[ -n "$L_GRANT" && -n "$L_ALTER" && "$L_ALTER" -gt "$L_GRANT" ]]; then
    assert_eq "ALTER USER comes after GRANT SYSDG" "ok" "ok"
else
    assert_eq "ALTER USER comes after GRANT SYSDG (grant line '$L_GRANT', alter line '$L_ALTER')" "ok" "missing"
fi
assert_contains "a failed ALTER is a warning, not a failure" "Could not set the password again" "$NEWUSER"
L_POST=$(grep -n '^if \[\[ "\$OBSERVER_PW_HELD" == "1" \]\]' "$SCRIPT_UNDER_TEST" | head -1 | cut -d: -f1)
L_LOGX=$(grep -n '^progress_step "Setting LogXptMode' "$SCRIPT_UNDER_TEST" | head -1 | cut -d: -f1)
L_CHECKONLY=$(grep -n '^if \[\[ "\$CHECK_ONLY" == "1" \]\]' "$SCRIPT_UNDER_TEST" | head -1 | cut -d: -f1)
if [[ -n "$L_POST" && -n "$L_LOGX" && "$L_POST" -lt "$L_LOGX" && "$L_POST" -gt "$L_CHECKONLY" ]]; then
    assert_eq "standby login proof is after the -n stop and before LogXptMode" "ok" "ok"
else
    assert_eq "standby login proof placement (check-only $L_CHECKONLY, proof $L_POST, LogXptMode $L_LOGX)" "ok" "misplaced"
fi
assert_not_contains "the inaccurate redo-transport claim is gone" "replicated to standby via redo transport" "$(cat "$SCRIPT_UNDER_TEST")"

echo ""
echo "============================================================"
echo "Test Summary: $PASS passed, $FAIL failed"
echo "============================================================"
[[ $FAIL -eq 0 ]]
