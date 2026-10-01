#!/usr/bin/env bash
# ============================================================
# Test script for the add_observer/ toolkit helpers
# ============================================================
# Usage: bash tests/test_add_observer_lib.sh
#
# Sources add_observer/_lib.sh (and, via sed extraction, the helper functions
# that live inside 02/03) with stubbed sqlplus/dgmgrl output:
#   - H2: broker_property tolerates a missing property under set -e +
#         pipefail, and 01_prepare_primary.sh with an empty broker reaches
#         the --standby-host hint / honours the override instead of dying
#         silently
#   - C9/M31: dgmgrl_failed (Warning: lines, Error: N, Failed., empty output)
#   - C1: run_sql / run_sql_as emit SET DEFINE OFF before anything else
#   - LOW: descriptor_part is case-insensitive
#   - C8: extract_tns_alias_block returns exactly one stanza
#   - M15: this_observer_registered matches by name, else by host
#   - A3: tcp_check's /dev/tcp fallback gives up within ~5 s
# ============================================================

# Don't use set -e as we need to test for failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
KIT="${REPO_ROOT}/add_observer"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then pass "$name"
    else fail "$name (expected '$expected', got '$actual')"; fi
}

assert_true() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

assert_false() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/test_add_observer.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

# extract_func FILE NAME -> the function definition (column-0 name() { ... })
extract_func() {
    sed -n "/^${2}() {/,/^}/p" "$1"
}

# ------------------------------------------------------------
echo "Test 1: broker_property under set -e + pipefail (H2)"
# ------------------------------------------------------------
cat > "$WORK/h2.sh" <<EOF
set -e
set -o pipefail
source "${KIT}/_lib.sh"
SHOW="Database - stby
  Role: PHYSICAL STANDBY
    DGConnectIdentifier = 'stby_tns'
    LogXptMode          = 'ASYNC'"
V=\$(broker_property "\$SHOW" "HostName")
echo "after-missing:[\$V]"
V=\$(broker_property "" "HostName")
echo "after-empty:[\$V]"
V=\$(broker_property "\$SHOW" "LogXptMode")
echo "value:[\$V]"
V=\$(broker_property "\$SHOW" "dgconnectidentifier")
echo "ci-value:[\$V]"
EOF
OUT=$(bash "$WORK/h2.sh" 2>&1); RC=$?
assert_eq "script survives missing property (rc)" "0" "$RC"
assert_true "missing property yields empty value" grep -qx 'after-missing:\[\]' <<< "$OUT"
assert_true "empty output yields empty value" grep -qx 'after-empty:\[\]' <<< "$OUT"
assert_true "present property is extracted" grep -qx 'value:\[ASYNC\]' <<< "$OUT"
assert_true "property name match is case-insensitive" grep -qx 'ci-value:\[stby_tns\]' <<< "$OUT"

# ------------------------------------------------------------
echo "Test 2: 01_prepare_primary.sh with an empty broker (H2, end to end)"
# ------------------------------------------------------------
FAKE_OH="$WORK/oh"
mkdir -p "$FAKE_OH/bin"
cat > "$FAKE_OH/bin/sqlplus" <<'EOF'
#!/bin/bash
# Stub: dispatch on the SQL text read from stdin.
sql=$(cat | tr '[:upper:]' '[:lower:]')
case "$sql" in
    *"count(*) from v\$dataguard_config"*) echo 1 ;;
    *"from v\$dataguard_config"*)          echo stby ;;
    *"database_role from v\$database"*)    echo PRIMARY ;;
    *"remote_login_passwordfile"*)         echo EXCLUSIVE ;;
    *"dg_broker_start"*)                   echo TRUE ;;
    *"select cdb from"*)                   echo NO ;;
    *"select db_unique_name from v\$database"*) echo prim ;;
    *"protection_mode"*)                   echo "MAXIMUM AVAILABILITY" ;;
    *"flashback_on"*)                      echo YES ;;
    *"count(*) from v\$standby_log"*)      echo 3 ;;
    *) : ;;
esac
exit 0
EOF
# dgmgrl prints nothing at all: no configuration, nothing to parse.
printf '#!/bin/bash\ncat >/dev/null\nexit 0\n' > "$FAKE_OH/bin/dgmgrl"
printf '#!/bin/bash\nexit 1\n' > "$FAKE_OH/bin/tnsping"
chmod +x "$FAKE_OH/bin/"*

run01() {
    ORACLE_HOME="$FAKE_OH" ORACLE_SID=prim NO_COLOR=1 \
        bash "${KIT}/01_prepare_primary.sh" "$@" </dev/null 2>&1
}

OUT=$(run01 --no-user --observer-host obs1 -o "$WORK/bundle_a"); RC=$?
assert_eq "no standby host discoverable: exit 1" "1" "$RC"
assert_true "prints the 'Re-run with --standby-host' hint" grep -q 'Re-run with --standby-host' <<< "$OUT"

OUT=$(run01 --no-user --observer-host obs1 --standby-host stbhost --port 1522 -o "$WORK/bundle_b"); RC=$?
assert_eq "--standby-host override is reachable: exit 0" "0" "$RC"
assert_true "bundle env carries the override host" grep -q '^STANDBY_HOST="stbhost"$' "$WORK/bundle_b/observer_env.sh"
assert_true "bundle env carries the override port" grep -q '^STANDBY_PORT="1522"$' "$WORK/bundle_b/observer_env.sh"
assert_true "tnsnames has both stanzas" test "$(grep -c '^[a-z]* =$' "$WORK/bundle_b/tnsnames_observer.ora")" -eq 2
assert_true "tnsnames stanzas are blank-line separated" grep -q '^$' "$WORK/bundle_b/tnsnames_observer.ora"

# ------------------------------------------------------------
echo "Test 3: dgmgrl_failed (C9 / M31)"
# ------------------------------------------------------------
source "${KIT}/_lib.sh"

assert_true  "empty output is a failure"                dgmgrl_failed ""
assert_true  "whitespace-only output is a failure"      dgmgrl_failed "   "
assert_false "plain success is not a failure"           dgmgrl_failed "Succeeded."
assert_false "'Error: 0' is not a failure"              dgmgrl_failed "Database - x
  Error: 0
SUCCESS"
assert_true  "'Error: 5' is a failure"                  dgmgrl_failed "Error: 5"
assert_true  "standalone 'Failed.' is a failure"        dgmgrl_failed "Failed."
assert_false "'Failed.' inside a sentence is not"       dgmgrl_failed "Re-sync Failed. later maybe"
assert_true  "ORA- code is a failure"                   dgmgrl_failed "ORA-16627: operation disallowed"
assert_true  "DGM- code is a failure"                   dgmgrl_failed "DGM-17016: failed to retrieve status"
assert_false "'Warning: ORA-16789' line is not a failure" dgmgrl_failed "Configuration - cfg
  Warning: ORA-16789: standby redo logs configured incorrectly
Configuration Status:
WARNING"
assert_true  "a real ORA- next to a Warning line fails" dgmgrl_failed "Warning: ORA-16789: x
ORA-16795: database resource guard"

# ------------------------------------------------------------
echo "Test 4: SET DEFINE OFF first in every sqlplus heredoc (C1)"
# ------------------------------------------------------------
CAP_OH="$WORK/capoh"
mkdir -p "$CAP_OH/bin"
printf '#!/bin/bash\ncat > "%s/sql_in.txt"\nexit 0\n' "$WORK" > "$CAP_OH/bin/sqlplus"
chmod +x "$CAP_OH/bin/sqlplus"
export ORACLE_HOME="$CAP_OH"

run_sql 'create user u identified by "pa&ss";' >/dev/null
assert_eq "run_sql: first line" "set define off" "$(head -1 "$WORK/sql_in.txt" | tr 'A-Z' 'a-z')"
assert_true "run_sql: '&' password reaches sqlplus verbatim" grep -qF 'identified by "pa&ss";' "$WORK/sql_in.txt"
run_sql_as "/@x as sysdg" 'select 1 from dual;' >/dev/null
assert_eq "run_sql_as: first line" "set define off" "$(head -1 "$WORK/sql_in.txt" | tr 'A-Z' 'a-z')"

# ------------------------------------------------------------
echo "Test 5: descriptor_part is case-insensitive"
# ------------------------------------------------------------
D1='(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=hx1)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=svc1)))'
D2='(description = (address = (protocol = tcp)(host = hx2)(port = 1530))(connect_data = (service_name = svc2)))'
assert_eq "upper-case HOST"          "hx1"  "$(descriptor_part "$D1" HOST)"
assert_eq "upper-case SERVICE_NAME"  "svc1" "$(descriptor_part "$D1" SERVICE_NAME)"
assert_eq "lower-case host"          "hx2"  "$(descriptor_part "$D2" HOST)"
assert_eq "lower-case port"          "1530" "$(descriptor_part "$D2" PORT)"
assert_eq "lower-case service_name"  "svc2" "$(descriptor_part "$D2" SERVICE_NAME)"
assert_eq "absent key is empty"      ""     "$(descriptor_part "$D1" SID)"

# ------------------------------------------------------------
echo "Test 6: extract_tns_alias_block returns exactly one stanza (C8)"
# ------------------------------------------------------------
eval "$(extract_func "${KIT}/02_setup_observer_host.sh" extract_tns_alias_block)"

cat > "$WORK/tns_blank.ora" <<'EOF'
# header comment

prim =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = h1)(PORT = 1521))
  )

stby.dom =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = h2)(PORT = 1521))
  )
EOF
# Older bundles had no blank line between the two stanzas.
sed '/^$/d' "$WORK/tns_blank.ora" > "$WORK/tns_tight.ora"

for f in tns_blank tns_tight; do
    B=$(extract_tns_alias_block "$WORK/$f.ora" prim)
    assert_true  "$f: prim stanza has its host"         grep -q 'HOST = h1' <<< "$B"
    assert_false "$f: prim stanza stops before stby"    grep -q 'h2' <<< "$B"
    B=$(extract_tns_alias_block "$WORK/$f.ora" STBY.DOM)
    assert_true  "$f: stby.dom found case-insensitively" grep -q 'HOST = h2' <<< "$B"
    assert_false "$f: stby stanza has no prim lines"    grep -q 'h1' <<< "$B"
    B=$(extract_tns_alias_block "$WORK/$f.ora" nosuch)
    assert_eq    "$f: unknown alias gives nothing" "" "$B"
done

# ------------------------------------------------------------
echo "Test 7: this_observer_registered matches by name, else host (M15)"
# ------------------------------------------------------------
eval "$(extract_func "${KIT}/03_observer_ctl.sh" this_observer_registered)"
DG_CONN="/@x"
OBSERVER_NAME="obs_prim"
hostname() { echo "obs1.example.com"; }

SHOW_OUT=""
run_dgmgrl() { printf '%s\n' "$SHOW_OUT"; }

SHOW_OUT='Configuration - cfg
  Primary:            prim
  Active Target:      stby

Observer "other" - Master

  Host Name:                    elsewhere
  Last Ping to Primary:         1 second ago

Observer "obs_prim" - Backup

  Host Name:                    obs9
'
assert_true  "registered by name (other observer is master)" this_observer_registered
assert_eq    "listing was parsed" "true" "$OBS_LIST_PARSED"

SHOW_OUT='Observer "someone" - Master

  Host Name:                    elsewhere
'
assert_false "another host's observer is not ours" this_observer_registered
assert_eq    "listing parsed even when not ours" "true" "$OBS_LIST_PARSED"

SHOW_OUT='Observer "unnamed-run" - Master

  Host Name:                    OBS1
'
assert_true  "registered by short host name" this_observer_registered

SHOW_OUT='ORA-16525: the Oracle Data Guard broker is not yet available'
assert_false "unparseable output is not 'registered'" this_observer_registered
assert_eq    "unparseable output flagged" "false" "$OBS_LIST_PARSED"
unset -f hostname run_dgmgrl

# ------------------------------------------------------------
echo "Test 8: tcp_check's /dev/tcp fallback gives up within ~5s (A3)"
# ------------------------------------------------------------
eval "$(extract_func "${KIT}/02_setup_observer_host.sh" tcp_check)"
# Hide nc so the /dev/tcp branch runs.
command() {
    if [[ "$1" == "-v" && "$2" == "nc" ]]; then return 1; fi
    builtin command "$@"
}

T0=$(date +%s)
OUT=$(tcp_check 127.0.0.1 1 2>&1)
assert_true "closed local port: reported NOT reachable" grep -q 'NOT reachable' <<< "$OUT"

# 10.255.255.1 is typically a black hole (the connect would hang for the
# kernel timeout); where the network refuses it at once the bound still holds.
T0=$(date +%s)
OUT=$(tcp_check 10.255.255.1 1521 2>&1); RC=$?
T1=$(date +%s)
assert_eq "tcp_check returns 0 either way" "0" "$RC"
if [[ $((T1 - T0)) -le 9 ]]; then pass "unroutable host: returned in $((T1 - T0))s"
else fail "unroutable host: took $((T1 - T0))s (> 9s)"; fi
assert_true "unroutable host: reported NOT reachable" grep -q 'NOT reachable' <<< "$OUT"
unset -f command

echo
echo "============================================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "============================================================"
[[ $FAIL -eq 0 ]]
