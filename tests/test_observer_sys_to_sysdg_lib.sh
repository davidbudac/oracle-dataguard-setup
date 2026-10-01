#!/usr/bin/env bash
# ============================================================
# Tests for observer_sys_to_sysdg/_lib.sh and the 01/02 scripts' wiring
# ============================================================
# Usage: bash tests/test_observer_sys_to_sysdg_lib.sh
#
# DB-free: sqlplus is a stub that records its stdin. Covers
#   - run_sql sends SET DEFINE OFF as the very first line (an '&' in a
#     password embedded in the SQL must not be substituted) and SET TAB OFF
#   - dgmgrl_output_has_error (anchored; Warning: lines and "Error: 0" benign)
#   - wallet_credential_lines (mkstore -listCredential parser)
#   - sqlnet_wallet_dir (case-insensitive, never ENCRYPTION_WALLET_LOCATION)
#   - broker_member_names / broker_property_value
#   - 01 rejects a double quote in the password via the shared run_sql path
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
KIT="${REPO_ROOT}/observer_sys_to_sysdg"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }
check() {   # check "name" expected actual
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/obs_sysdg_test.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/home/bin"
cat > "$WORK/home/bin/sqlplus" <<'STUB'
#!/bin/bash
cat > "$STUB_SQLPLUS_STDIN"
STUB
chmod +x "$WORK/home/bin/sqlplus"

export ORACLE_HOME="$WORK/home"
export NO_COLOR=1
# shellcheck disable=SC1090
source "${KIT}/_lib.sh"

echo "============================================================"
echo "observer_sys_to_sysdg/_lib.sh"
echo "============================================================"

echo ""
echo "Test 1: run_sql heredoc"
export STUB_SQLPLUS_STDIN="$WORK/stdin.txt"
run_sql "create user X identified by \"p&ss&w0rd\";"
check "SET DEFINE OFF is the first line" "set define off" "$(sed -n 1p "$STUB_SQLPLUS_STDIN")"
check "SET TAB OFF is set" "1" "$(grep -c 'tab off' "$STUB_SQLPLUS_STDIN")"
check "password with '&' reaches sqlplus verbatim" "1" "$(grep -c 'p&ss&w0rd' "$STUB_SQLPLUS_STDIN")"
check "script ends with exit" "exit" "$(tail -1 "$STUB_SQLPLUS_STDIN")"

echo ""
echo "Test 2: dgmgrl_output_has_error"
dgmgrl_output_has_error "ORA-16877: no observer"      && pass "ORA- code detected"     || fail "ORA- code detected"
dgmgrl_output_has_error "DGM-16954: Unable to"        && pass "DGM- code detected"     || fail "DGM- code detected"
dgmgrl_output_has_error "Error: 1"                    && pass "'Error: 1' detected"    || fail "'Error: 1' detected"
dgmgrl_output_has_error "Failed."                     && pass "'Failed.' detected"     || fail "'Failed.' detected"
dgmgrl_output_has_error "  Warning: ORA-16789: standby redo logs" && fail "Warning: line must be benign" || pass "Warning: line is benign"
dgmgrl_output_has_error "Error: 0"                    && fail "'Error: 0' must be benign" || pass "'Error: 0' is benign"
dgmgrl_output_has_error "Submitted command \"START OBSERVER\" using connect identifier \"prim\"" \
    && fail "normal START OBSERVER output must be benign" || pass "normal START OBSERVER output is benign"
dgmgrl_output_has_error "Property Error is set"       && fail "word 'Error' mid-line must be benign" || pass "word 'Error' mid-line is benign"

echo ""
echo "Test 3: wallet_credential_lines"
LISTING=$(printf 'Oracle Secret Store Tool : Version 19.0.0.0.0\r\nList credential (index: connect_string username)\r\n1: prim SYS\r\n2: stby.example.com sys\r\n3: other C##DG_OBSERVER\r\n')
GOT=$(printf '%s\n' "$LISTING" | wallet_credential_lines)
check "three pairs parsed" "3" "$(printf '%s\n' "$GOT" | wc -l | tr -d ' ')"
check "first pair" "prim SYS" "$(printf '%s\n' "$GOT" | sed -n 1p)"
check "second pair keeps FQDN key and lowercase user" "stby.example.com sys" "$(printf '%s\n' "$GOT" | sed -n 2p)"
check "SYS keys (case-insensitive)" "prim stby.example.com" \
    "$(printf '%s\n' "$GOT" | awk 'toupper($2) == "SYS" { print $1 }' | tr '\n' ' ' | sed 's/ $//')"
check "no credentials -> no pairs" "" "$(printf 'List credential\n' | wallet_credential_lines)"

echo ""
echo "Test 4: sqlnet_wallet_dir"
cat > "$WORK/sqlnet1.ora" <<'EOS'
NAMES.DIRECTORY_PATH = (TNSNAMES)
ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE) (METHOD_DATA = (DIRECTORY = /tde/keystore)))
wallet_location =
  (SOURCE = (METHOD = FILE)
    (METHOD_DATA = (DIRECTORY = /u01/app/wallet)))
SQLNET.WALLET_OVERRIDE = TRUE
EOS
check "lowercase, multi-line, TDE entry ignored" "/u01/app/wallet" "$(sqlnet_wallet_dir "$WORK/sqlnet1.ora")"
cat > "$WORK/sqlnet2.ora" <<'EOS'
ENCRYPTION_WALLET_LOCATION = (SOURCE = (METHOD = FILE) (METHOD_DATA = (DIRECTORY = /tde/keystore)))
EOS
check "only ENCRYPTION_WALLET_LOCATION -> empty" "" "$(sqlnet_wallet_dir "$WORK/sqlnet2.ora")"
printf 'WALLET_LOCATION = (SOURCE = (METHOD = FILE) (METHOD_DATA = (DIRECTORY = /a/b)))\n' > "$WORK/sqlnet3.ora"
check "single-line entry" "/a/b" "$(sqlnet_wallet_dir "$WORK/sqlnet3.ora")"
mkdir -p "$WORK/w"
check "canonical_dir strips a trailing slash" "$(cd "$WORK/w" && pwd -P)" "$(canonical_dir "$WORK/w/")"
check "canonical_dir of a missing dir drops the slash" "/no/such/dir" "$(canonical_dir /no/such/dir/)"

echo ""
echo "Test 5: broker parsers"
CONF=$(cat <<'EOS'

Configuration - dg_cfg

  Protection Mode: MaxAvailability
  Members:
  prim - Primary database
    stby - (*) Physical standby database
      Warning: ORA-16789: standby redo logs configured incorrectly

Fast-Start Failover: Enabled in Zero Data Loss Mode

Configuration Status:
SUCCESS   (status updated 5 seconds ago)
EOS
)
check "members" "prim stby" "$(printf '%s\n' "$CONF" | broker_member_names | tr '\n' ' ' | sed 's/ $//')"
VERBOSE=$(printf "  Database - stby\r\n\r\n  DGConnectIdentifier             = 'stby.example.com'\r\n  LogXptMode                      = 'FASTSYNC'\r\n")
check "DGConnectIdentifier value" "stby.example.com" "$(broker_property_value "$VERBOSE" DGConnectIdentifier)"
check "missing property -> empty" "" "$(broker_property_value "$VERBOSE" NoSuchProperty)"

echo ""
echo "Test 6: scripts route password SQL through run_sql / reject a double quote"
check "01 builds the CREATE USER SQL via run_sql_or_die" "2" \
    "$(grep -c 'run_sql_or_die ".*identified by' "${KIT}/01_create_sysdg_user.sh")"
check "01 rejects a double quote in the password" "1" \
    "$(grep -c "Password must not contain a double quote" "${KIT}/01_create_sysdg_user.sh")"
check "no sqlplus heredoc embeds a password outside run_sql" "0" \
    "$(grep -n 'sqlplus' "${KIT}"/0*.sh | grep -ci 'password')"

echo ""
echo "============================================================"
echo "Test Summary: $PASS passed, $FAIL failed"
echo "============================================================"
[[ $FAIL -eq 0 ]]
