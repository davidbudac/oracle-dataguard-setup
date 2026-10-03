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
#   - M15: observer_block matches this observer by name, else by host
#   - F3: registration is not liveness - observer_block parses THIS block's
#         ping (stale / (unknown) / singular / CRLF / two observers), and
#         03_observer_ctl.sh status/start/restart run end to end against
#         stubbed dgmgrl/sqlplus/ps: stale listing, crashed and hung
#         observers, standby-alias fallback, restart with the existing state
#         file and the STOP-then-retry path, DG_OBS_MAX_PING_AGE validation
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
echo "Test 7: observer_block - this observer's own block and ping (M15, F3)"
# ------------------------------------------------------------
# The lab capture (19c, healthy observer), verbatim.
LAB_SHOW='Configuration - my_dg_config

  Fast-Start Failover:     ENABLED

  Primary:            cdb1
  Active Target:      cdb1_stby

Observer "dg_observer" - Master

  Host Name:                    ol9-19-dg3.localdomain
  Last Ping to Primary:         0 seconds ago
  Last Ping to Target:          1 second ago
'
B=$(observer_block "$LAB_SHOW" dg_observer "")
assert_eq "lab sample: one block"                "1"           "$(obs_field "$B" BLOCKS)"
assert_eq "lab sample: matched by name"          "name"        "$(obs_field "$B" MATCH)"
assert_eq "lab sample: role"                     "Master"      "$(obs_field "$B" ROLE)"
assert_eq "lab sample: host"                     "ol9-19-dg3.localdomain" "$(obs_field "$B" HOST)"
assert_eq "lab sample: ping to primary 0"        "0"           "$(obs_field "$B" PING_PRIMARY)"
assert_eq "lab sample: singular '1 second ago'"  "1"           "$(obs_field "$B" PING_TARGET)"
assert_true "lab sample: fresh -> live"          ping_is_fresh "$(obs_field "$B" PING_PRIMARY)" 60
B=$(observer_block "$LAB_SHOW" "" "OL9-19-DG3")
assert_eq "lab sample: matched by short host, case-insensitive" "host" "$(obs_field "$B" MATCH)"

CRLF_SHOW=$(printf '%s\n' "$LAB_SHOW" | sed 's/$/\r/')
B=$(observer_block "$CRLF_SHOW" DG_OBSERVER "")
assert_eq "CRLF: name still matches"     "name" "$(obs_field "$B" MATCH)"
assert_eq "CRLF: ping to primary"        "0"    "$(obs_field "$B" PING_PRIMARY)"
assert_eq "CRLF: ping to target"         "1"    "$(obs_field "$B" PING_TARGET)"
assert_eq "CRLF: host has no CR"         "ol9-19-dg3.localdomain" "$(obs_field "$B" HOST)"

STALE_SHOW=$(printf '%s\n' "$LAB_SHOW" | sed 's/Last Ping to Primary:  *0 seconds ago/Last Ping to Primary:         742 seconds ago/')
B=$(observer_block "$STALE_SHOW" dg_observer "")
assert_eq    "stale: still registered"   "name" "$(obs_field "$B" MATCH)"
assert_eq    "stale: ping parsed"        "742"  "$(obs_field "$B" PING_PRIMARY)"
assert_false "stale: 742 s is not fresh" ping_is_fresh 742 60

UNK_SHOW=$(printf '%s\n' "$LAB_SHOW" | sed 's/0 seconds ago/(unknown)/')
B=$(observer_block "$UNK_SHOW" dg_observer "")
assert_eq    "(unknown): no age"         ""          "$(obs_field "$B" PING_PRIMARY)"
assert_eq    "(unknown): text kept"      "(unknown)" "$(obs_field "$B" PING_PRIMARY_TEXT)"
assert_false "(unknown): not fresh"      ping_is_fresh "" 60

TWO_SHOW='Observer "other" - Master

  Host Name:                    elsewhere
  Last Ping to Primary:         1 second ago
  Last Ping to Target:          2 seconds ago

Observer "obs_prim" - Backup

  Host Name:                    obs1.example.com
  Last Ping to Primary:         742 seconds ago
  Last Ping to Target:          740 seconds ago
'
B=$(observer_block "$TWO_SHOW" obs_prim "obs1.example.com")
assert_eq "two observers: picks ours"            "obs_prim" "$(obs_field "$B" NAME)"
assert_eq "two observers: our role"              "Backup"   "$(obs_field "$B" ROLE)"
assert_eq "two observers: OUR stale ping, not the other's" "742" "$(obs_field "$B" PING_PRIMARY)"
B=$(observer_block "$TWO_SHOW" other "")
assert_eq "two observers: the other one's ping"  "1"        "$(obs_field "$B" PING_PRIMARY)"
B=$(observer_block "$TWO_SHOW" nosuch "obs9")
assert_eq "neither name nor host: no match"      "none"     "$(obs_field "$B" MATCH)"
assert_eq "neither name nor host: no ping"       ""         "$(obs_field "$B" PING_PRIMARY)"
B=$(observer_block "$TWO_SHOW" nosuch "OBS1")
assert_eq "no name match: falls back to host"    "obs_prim" "$(obs_field "$B" NAME)"

B=$(observer_block 'ORA-16525: the Oracle Data Guard broker is not yet available' obs_prim obs1)
assert_eq "unparseable output: zero blocks"      "0"    "$(obs_field "$B" BLOCKS)"
assert_eq "unparseable output: no match"         "none" "$(obs_field "$B" MATCH)"

FALL_SHOW='Observer "obs_prim" - Master
  Host Name:                    obs1
  Last Ping to Primary:         742 seconds ago
  Last Ping to Target:          1 second ago
'
B=$(observer_block "$FALL_SHOW" obs_prim "")
assert_eq "observer_ping primary" "742|last ping to primary|742 seconds ago" "$(observer_ping "$B" primary)"
assert_eq "observer_ping target"  "1|last ping to target|1 second ago"       "$(observer_ping "$B" target)"
assert_eq "observer_ping either = fresher" "1|last ping to target|1 second ago" "$(observer_ping "$B" either)"

assert_true  "DG_OBS_MAX_PING_AGE 60 valid"   valid_ping_age 60
assert_true  "DG_OBS_MAX_PING_AGE 1 valid"    valid_ping_age 1
assert_false "DG_OBS_MAX_PING_AGE 0 invalid"  valid_ping_age 0
assert_false "DG_OBS_MAX_PING_AGE 060 invalid" valid_ping_age 060
assert_false "DG_OBS_MAX_PING_AGE -5 invalid" valid_ping_age -5
assert_false "DG_OBS_MAX_PING_AGE abc invalid" valid_ping_age abc
assert_false "DG_OBS_MAX_PING_AGE empty invalid" valid_ping_age ""
assert_false "DG_OBS_MAX_PING_AGE 10 digits invalid" valid_ping_age 1234567890
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

# ------------------------------------------------------------
echo "Test 9: 03_observer_ctl.sh - registered is not live (F3, end to end)"
# ------------------------------------------------------------
# A private copy of the kit with an observer_env.sh, a fake ORACLE_HOME whose
# dgmgrl/sqlplus answer from state files, and stub hostname/ps/sleep first on
# PATH. The stub ps lists rows of $ST/ps_table whose PID is alive (kill -0),
# so "observer processes" are real, disposable /bin/sleep children - started
# detached (re-parented to init) so a killed one does not linger as a zombie.
OK="$WORK/obskit"; OOH="$WORK/obsoh"; SB="$WORK/stubbin"; ST="$WORK/obsstate"
OBSDIR="$WORK/obsdir"
DAT="$OBSDIR/fsfo_prim.dat"
PIDF="$OBSDIR/fsfo_prim.pid"
mkdir -p "$OK" "$OOH/bin" "$SB" "$ST"
cp "${KIT}/_lib.sh" "${KIT}/03_observer_ctl.sh" "${KIT}/04_verify_observer.sh" "$OK/"
cat > "$OK/observer_env.sh" <<EOF
PRIMARY_DB_UNIQUE_NAME="prim"
STANDBY_DB_UNIQUE_NAME="stby"
PRIMARY_TNS_ALIAS="prim"
STANDBY_TNS_ALIAS="stby"
OBSERVER_NAME="obs_prim"
OBSERVER_HOST="obs1"
OBSERVER_DIR="${OBSDIR}"
EOF

cat > "$OOH/bin/dgmgrl" <<EOF
#!/bin/bash
S="$ST"
EOF
cat >> "$OOH/bin/dgmgrl" <<'EOF'
conn=""
for a in "$@"; do case "$a" in /@*) conn="$a" ;; esac; done
alias="${conn#/@}"
while IFS= read -r cmd; do
    printf '%s|%s\n' "$conn" "$cmd" >> "$S/dgmgrl.log"
    if [ -f "$S/down_$alias" ]; then echo "ORA-12541: TNS:no listener"; continue; fi
    case "$cmd" in
        "SHOW CONFIGURATION;")       printf 'Configuration - cfg\nConfiguration Status:\nSUCCESS\n' ;;
        "SHOW FAST_START FAILOVER;") echo "Fast-Start Failover: Enabled" ;;
        "SHOW OBSERVER;")            cat "$S/show_observer" 2>/dev/null ;;
        "START OBSERVER"*)
            n=$(cat "$S/start_fail" 2>/dev/null || echo 0)
            if [ "$n" -gt 0 ]; then
                echo $((n - 1)) > "$S/start_fail"
                echo "ORA-16647: could not start more than one observer"
                echo "Failed."
                continue
            fi
            ( /bin/sleep 120 </dev/null >/dev/null 2>&1 & echo $! > "$S/spawned.pid" )
            pid=$(cat "$S/spawned.pid")
            echo "$pid" >> "$S/all_pids"
            echo "$pid dgmgrl -silent $conn $cmd" >> "$S/ps_table"
            [ -f "$S/show_observer_after" ] && cp "$S/show_observer_after" "$S/show_observer"
            echo "Submitted command \"START OBSERVER\" using connect identifier \"$alias\""
            ;;
        "STOP OBSERVER"*)
            [ -f "$S/show_after_stop" ] && cp "$S/show_after_stop" "$S/show_observer"
            echo "Observer stopped." ;;
        *) echo "Succeeded." ;;
    esac
done
exit 0
EOF
cat > "$OOH/bin/sqlplus" <<EOF
#!/bin/bash
S="$ST"
EOF
cat >> "$OOH/bin/sqlplus" <<'EOF'
sql=$(cat)
p=$(cat "$S/present" 2>/dev/null || echo NO)
case "$sql" in
    *"'PRESENT='"*) echo "PRESENT=$p" ;;
    *) echo "FS_FAILOVER_OBSERVER_PRESENT = $p" ;;
esac
exit 0
EOF
cat > "$SB/ps" <<EOF
#!/bin/bash
S="$ST"
EOF
cat >> "$SB/ps" <<'EOF'
plist=""; fmt=""
while [ $# -gt 0 ]; do
    case "$1" in
        -p)  plist="$2"; shift 2 ;;
        -o)  fmt="$fmt,$2"; shift 2 ;;
        -eo) fmt="$2"; shift 2 ;;
        *)   shift ;;
    esac
done
found=1
if [ -f "$S/ps_table" ]; then
    while read -r pid args; do
        kill -0 "$pid" 2>/dev/null || continue
        if [ -n "$plist" ]; then case ",$plist," in *",$pid,"*) ;; *) continue ;; esac; fi
        found=0
        case "$fmt" in *"args="*) echo "$args" ;; *) echo "$pid $args" ;; esac
    done < "$S/ps_table"
fi
[ -z "$plist" ] && exit 0
exit $found
EOF
printf '#!/bin/bash\necho obs1.example.com\n' > "$SB/hostname"
printf '#!/bin/bash\nexit 0\n' > "$SB/sleep"
chmod +x "$OOH/bin/"* "$SB/"*

# spawn_fake_observer -> PID of a detached /bin/sleep listed in ps as this
# configuration's dgmgrl observer
spawn_fake_observer() {
    ( /bin/sleep 120 </dev/null >/dev/null 2>&1 & echo $! > "$ST/spawned.pid" )
    local pid; pid=$(cat "$ST/spawned.pid")
    echo "$pid" >> "$ST/all_pids"
    echo "$pid dgmgrl -silent /@prim START OBSERVER obs_prim IN BACKGROUND FILE IS '$DAT'" >> "$ST/ps_table"
    echo "$pid"
}
reap_fake_observers() {
    local p
    [[ -f "$ST/all_pids" ]] || return 0
    for p in $(cat "$ST/all_pids"); do kill "$p" 2>/dev/null; done
    rm -f "$ST/all_pids"
}
trap 'reap_fake_observers; rm -rf "$WORK"' EXIT

reset_obs() {
    reap_fake_observers
    rm -rf "$ST" "$OBSDIR"
    mkdir -p "$ST" "$OBSDIR"
    echo NO > "$ST/present"
}
# show_obs NAME HOST PRIMARY_PING TARGET_PING -> one observer block
show_obs() {
    printf 'Observer "%s" - Master\n\n  Host Name:                    %s\n  Last Ping to Primary:         %s\n  Last Ping to Target:          %s\n\n' "$1" "$2" "$3" "$4"
}
run03() {
    ORACLE_HOME="$OOH" TNS_ADMIN="$WORK" PATH="$SB:$PATH" NO_COLOR=1 \
        "$BASH" "$OK/03_observer_ctl.sh" "$@" </dev/null 2>&1
}
HDR='Configuration - cfg

  Primary:            prim
  Active Target:      stby
'

# --- status: the review's reproduced case ---------------------------------
reset_obs
{ printf '%s\n' "$HDR"; show_obs obs_prim obs1.example.com "742 seconds ago" "741 seconds ago"; } > "$ST/show_observer"
OUT=$(run03 status); RC=$?
assert_eq   "stale listing + present=NO: status exits 1" "1" "$RC"
assert_true "status reports registration separately"     grep -q 'registered: yes ("obs_prim" Master on obs1.example.com)' <<< "$OUT"
assert_true "status reports the stale ping and the limit" grep -q 'last ping to primary: 742 s ago (stale, limit 60 s)' <<< "$OUT"
assert_true "status names the failed condition"           grep -q 'NOT live: last ping to primary 742 s ago is stale' <<< "$OUT"

OUT=$(DG_OBS_MAX_PING_AGE=900 run03 status); RC=$?
assert_eq   "DG_OBS_MAX_PING_AGE=900 accepts a 742 s ping" "0" "$RC"

# --- status: healthy lab-format observer, no pidfile ------------------------
reset_obs
{ printf '%s\n' "$HDR"; show_obs obs_prim obs1.example.com "0 seconds ago" "1 second ago"; } > "$ST/show_observer"
OUT=$(run03 status); RC=$?
assert_eq   "fresh ping, no pidfile: status exits 0"   "0" "$RC"
assert_true "no pidfile: process not claimed dead"     grep -q 'local process: not checked (no pidfile' <<< "$OUT"

# --- two observers: another one's health never vouches for this one --------
reset_obs
echo YES > "$ST/present"
{ show_obs other elsewhere "1 second ago" "2 seconds ago"; show_obs obs_prim obs1.example.com "742 seconds ago" "742 seconds ago"; } > "$ST/show_observer"
OUT=$(run03 status); RC=$?
assert_eq "ours stale, other fresh, present=YES: exits 1" "1" "$RC"
{ show_obs other elsewhere "742 seconds ago" "742 seconds ago"; show_obs obs_prim obs1.example.com "3 seconds ago" "2 seconds ago"; } > "$ST/show_observer"
OUT=$(run03 status); RC=$?
assert_eq "ours fresh, other stale: exits 0" "0" "$RC"
show_obs other elsewhere "1 second ago" "1 second ago" > "$ST/show_observer"
OUT=$(run03 status); RC=$?
assert_eq   "only another observer registered: exits 1" "1" "$RC"
assert_true "says the present flag is someone else's"   grep -q "none registered as 'obs_prim'" <<< "$OUT"

# --- (unknown) ping ---------------------------------------------------------
reset_obs
show_obs obs_prim obs1.example.com "(unknown)" "(unknown)" > "$ST/show_observer"
OUT=$(run03 status); RC=$?
assert_eq   "(unknown) ping: exits 1"           "1" "$RC"
assert_true "(unknown) ping: explained"         grep -q "is '(unknown)', not an age" <<< "$OUT"

# --- just crashed: ping still fresh, pidfile process gone -------------------
reset_obs
show_obs obs_prim obs1.example.com "2 seconds ago" "2 seconds ago" > "$ST/show_observer"
DEADPID=$(spawn_fake_observer); kill "$DEADPID" 2>/dev/null
for _i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$DEADPID" 2>/dev/null || break; /bin/sleep 0.1; done
echo "$DEADPID" > "$PIDF"
OUT=$(run03 status); RC=$?
assert_eq   "fresh ping but dead process: exits 1"   "1" "$RC"
assert_true "dead process named in the status line"  grep -q "local process: not running (pidfile PID ${DEADPID} is gone)" <<< "$OUT"

# --- hung: process alive, ping stale ----------------------------------------
reset_obs
show_obs obs_prim obs1.example.com "742 seconds ago" "742 seconds ago" > "$ST/show_observer"
HUNG=$(spawn_fake_observer); echo "$HUNG" > "$PIDF"
OUT=$(run03 status); RC=$?
assert_eq   "alive process but stale ping: exits 1"  "1" "$RC"
assert_true "hung: process shown running"            grep -q "local process: running (PID ${HUNG})" <<< "$OUT"
assert_true "hung: stale ping is the reason"         grep -q 'NOT live: last ping to primary 742 s ago is stale' <<< "$OUT"
assert_true "status did not kill it"                 kill -0 "$HUNG"

# --- standby-alias fallback uses the target ping ----------------------------
reset_obs
show_obs obs_prim obs1.example.com "742 seconds ago" "1 second ago" > "$ST/show_observer"
OUT=$(run03 status); RC=$?
assert_eq "primary alias up: judged on the primary ping (742 s) - exits 1" "1" "$RC"
touch "$ST/down_prim"
OUT=$(run03 status); RC=$?
assert_eq   "primary alias down: standby alias, target ping (1 s) - exits 0" "0" "$RC"
assert_true "fallback: status line names the target ping" grep -q 'last ping to target: 1 s ago (fresh' <<< "$OUT"
assert_true "fallback: SHOW OBSERVER went through /@stby"  grep -q '^/@stby|SHOW OBSERVER;' "$ST/dgmgrl.log"

# --- start: stale registration, broker refuses the first START -------------
reset_obs
show_obs obs_prim obs1.example.com "742 seconds ago" "742 seconds ago" > "$ST/show_observer"
show_obs obs_prim obs1.example.com "0 seconds ago" "1 second ago" > "$ST/show_observer_after"
HUNG=$(spawn_fake_observer); echo "$HUNG" > "$PIDF"
echo "observer state" > "$DAT"
echo 1 > "$ST/start_fail"
OUT=$(run03 start); RC=$?
CMDS=$(grep -E '[|](START|STOP) OBSERVER' "$ST/dgmgrl.log" | sed 's/^[^|]*|//')
assert_eq   "stale start: exits 0" "0" "$RC"
assert_eq   "stale start: START, STOP <name>, START" \
    "START OBSERVER obs_prim IN BACKGROUND FILE IS '${DAT}' LOGFILE IS '${OBSDIR}/fsfo_prim.log' CONNECT IDENTIFIER IS prim;
STOP OBSERVER obs_prim;
START OBSERVER obs_prim IN BACKGROUND FILE IS '${DAT}' LOGFILE IS '${OBSDIR}/fsfo_prim.log' CONNECT IDENTIFIER IS prim;" "$CMDS"
assert_false "stale start: no bare 'STOP OBSERVER;'"   grep -q '|STOP OBSERVER;$' "$ST/dgmgrl.log"
assert_true  "stale start: existing .dat kept"         grep -qx 'observer state' "$DAT"
assert_false "stale start: hung pidfile process killed" kill -0 "$HUNG"
NEWPID=$(tail -1 "$ST/all_pids")
assert_eq    "stale start: pidfile records the new observer" "$NEWPID" "$(cat "$PIDF" 2>/dev/null)"
assert_true  "stale start: ends live"                  grep -q 'Observer is live: registered: yes' <<< "$OUT"
assert_false "stale start: never 'already running'"    grep -q 'already running' <<< "$OUT"

# --- start: stale registration, broker accepts the START --------------------
reset_obs
show_obs obs_prim obs1.example.com "742 seconds ago" "742 seconds ago" > "$ST/show_observer"
show_obs obs_prim obs1.example.com "1 second ago" "1 second ago" > "$ST/show_observer_after"
echo "observer state" > "$DAT"
OUT=$(run03 start); RC=$?
assert_eq    "accepted restart: exits 0" "0" "$RC"
assert_eq    "accepted restart: one START, no STOP" "1" "$(grep -c '|START OBSERVER' "$ST/dgmgrl.log")"
assert_false "accepted restart: no STOP OBSERVER" grep -q '|STOP OBSERVER' "$ST/dgmgrl.log"
assert_true  "accepted restart: .dat kept" test -f "$DAT"

# --- start: live observer is left alone -------------------------------------
reset_obs
show_obs obs_prim obs1.example.com "1 second ago" "1 second ago" > "$ST/show_observer"
LIVE=$(spawn_fake_observer); echo "$LIVE" > "$PIDF"
OUT=$(run03 start); RC=$?
assert_eq    "live: start exits 0"            "0" "$RC"
assert_true  "live: reports already running"  grep -q 'already running' <<< "$OUT"
assert_false "live: no START issued"          grep -q '|START OBSERVER' "$ST/dgmgrl.log"
assert_true  "live: process untouched"        kill -0 "$LIVE"

# --- start: not registered, named START refused -> unnamed fallback ----------
reset_obs
show_obs other elsewhere "1 second ago" "1 second ago" > "$ST/show_observer"
{ show_obs other elsewhere "1 second ago" "1 second ago"; show_obs obs1.example.com obs1.example.com "0 seconds ago" "0 seconds ago"; } > "$ST/show_observer_after"
echo 1 > "$ST/start_fail"
OUT=$(run03 start); RC=$?
assert_eq    "unnamed fallback: exits 0" "0" "$RC"
assert_true  "unnamed fallback: unnamed START issued" grep -q "|START OBSERVER IN BACKGROUND FILE IS '${DAT}'" "$ST/dgmgrl.log"
assert_false "unnamed fallback: no STOP OBSERVER"     grep -q '|STOP OBSERVER' "$ST/dgmgrl.log"

# --- start: broker unreachable -> nothing touched ---------------------------
reset_obs
touch "$ST/down_prim" "$ST/down_stby"
LIVE=$(spawn_fake_observer); echo "$LIVE" > "$PIDF"
OUT=$(run03 start); RC=$?
assert_eq    "broker unreachable: start exits 1"   "1" "$RC"
assert_false "broker unreachable: no START"        grep -q '|START OBSERVER' "$ST/dgmgrl.log"
assert_true  "broker unreachable: process untouched" kill -0 "$LIVE"

# --- restart waits for the old registration, then starts --------------------
reset_obs
show_obs obs_prim obs1.example.com "1 second ago" "1 second ago" > "$ST/show_observer"
printf '%s\n' "$HDR" > "$ST/show_after_stop"
show_obs obs_prim obs1.example.com "0 seconds ago" "0 seconds ago" > "$ST/show_observer_after"
OUT=$(run03 restart); RC=$?
CMDS=$(grep -E '[|](START|STOP) OBSERVER' "$ST/dgmgrl.log" | sed 's/^[^|]*|//' | awk '{print $1, $2, $3}')
assert_eq "restart: exits 0" "0" "$RC"
assert_eq "restart: STOP obs_prim then START obs_prim" "STOP OBSERVER obs_prim;
START OBSERVER obs_prim" "$CMDS"

# --- DG_OBS_MAX_PING_AGE validation ------------------------------------------
reset_obs
for v in abc 0 -5 060 1.5; do
    OUT=$(DG_OBS_MAX_PING_AGE="$v" run03 status); RC=$?
    assert_eq "DG_OBS_MAX_PING_AGE='$v': 03 exits 2" "2" "$RC"
done
assert_true "invalid value is named" grep -q "DG_OBS_MAX_PING_AGE must be a positive whole number" <<< "$OUT"
OUT=$(DG_OBS_MAX_PING_AGE=abc ORACLE_HOME="$OOH" PATH="$SB:$PATH" NO_COLOR=1 "$BASH" "$OK/04_verify_observer.sh" </dev/null 2>&1); RC=$?
assert_eq "DG_OBS_MAX_PING_AGE=abc: 04 exits 2" "2" "$RC"

# ------------------------------------------------------------
echo "Test 10: 04_verify_observer.sh - present flag is not this observer (F3)"
# ------------------------------------------------------------
cat > "$OOH/bin/sqlplus" <<EOF
#!/bin/bash
S="$ST"
EOF
cat >> "$OOH/bin/sqlplus" <<'EOF'
sql=$(cat)
case "$sql" in
    *v\$pwfile_users*) echo "C##OBS FALSE TRUE" ;;
    *) printf 'FS_FAILOVER_STATUS=SYNCHRONIZED\nFS_FAILOVER_OBSERVER_PRESENT=%s\nFS_FAILOVER_OBSERVER_HOST=elsewhere\nFS_FAILOVER_CURRENT_TARGET=stby\nFS_FAILOVER_THRESHOLD=30\nDATABASE_ROLE=%s\nPROTECTION_MODE=MAXIMUM AVAILABILITY\n' \
           "$(cat "$S/present" 2>/dev/null || echo NO)" "$(cat "$S/role" 2>/dev/null || echo PRIMARY)" ;;
esac
exit 0
EOF
chmod +x "$OOH/bin/sqlplus"
run04() {
    ORACLE_HOME="$OOH" TNS_ADMIN="$WORK" PATH="$SB:$PATH" NO_COLOR=1 \
        "$BASH" "$OK/04_verify_observer.sh" "$@" </dev/null 2>&1
}
reset_obs
echo YES > "$ST/present"
{ show_obs other elsewhere "1 second ago" "1 second ago"; show_obs obs_prim obs1.example.com "742 seconds ago" "742 seconds ago"; } > "$ST/show_observer"
OUT=$(run04); RC=$?
assert_eq   "04: present=YES but ours stale: exits 1" "1" "$RC"
assert_true "04: explains the stale ping"            grep -q 'was 742 s ago' <<< "$OUT"
{ show_obs other elsewhere "742 seconds ago" "742 seconds ago"; show_obs obs_prim obs1.example.com "2 seconds ago" "1 second ago"; } > "$ST/show_observer"
OUT=$(run04); RC=$?
assert_eq   "04: ours fresh: exits 0"                "0" "$RC"
show_obs other elsewhere "1 second ago" "1 second ago" > "$ST/show_observer"
OUT=$(run04); RC=$?
assert_eq   "04: only another observer: exits 1"     "1" "$RC"
assert_true "04: present flag attributed to another" grep -q 'refers to a different observer' <<< "$OUT"
echo "PHYSICAL STANDBY" > "$ST/role"
show_obs obs_prim obs1.example.com "742 seconds ago" "1 second ago" > "$ST/show_observer"
OUT=$(run04 --tns stby); RC=$?
assert_eq   "04 via a standby: judged on the target ping" "0" "$RC"

# ------------------------------------------------------------
echo "Test 11: 01 sets a new user's password again AFTER the grants (standby password file)"
# ------------------------------------------------------------
# Verified on 19.27 with a MOUNTED physical standby: create + grant do not
# reach the standby's password file; a following ALTER USER ... IDENTIFIED BY
# does. The password prompts need a TTY, so the SQL order is asserted on the
# script text: create user -> grant sysdg -> alter user ... identified by.
order_ok() {   # order_ok FILE: create < grant sysdg < alter user identified by
    awk 'tolower($0) ~ /create user .*identified by/ && !c {c=NR}
         c && tolower($0) ~ /^grant sysdg to/ && !g {g=NR}
         g && tolower($0) ~ /alter user .*identified by/ && !a {a=NR}
         END {exit !(c && g && a && c < g && g < a)}' "$1"
}
assert_true  "01_prepare_primary: create -> grant sysdg -> alter user identified by" order_ok "${KIT}/01_prepare_primary.sh"
assert_true  "01_prepare_primary: a refused ALTER is a warning, not a die" \
    grep -q 'Could not set the password again' "${KIT}/01_prepare_primary.sh"
assert_false "01_prepare_primary: no 12.2+ 'picks up automatically' claim" \
    grep -qi 'picks up' "${KIT}/01_prepare_primary.sh"
assert_false "02_setup_observer_host: no 'propagates automatically' claim" \
    grep -qi 'propagates automatically' "${KIT}/02_setup_observer_host.sh"

echo
echo "============================================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "============================================================"
[[ $FAIL -eq 0 ]]
