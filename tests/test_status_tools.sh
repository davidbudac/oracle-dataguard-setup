#!/usr/bin/env bash
# ============================================================
# Tests for the status/triage tools: dg_status.sh, dg_triage_sid.sh,
# dg_diag_sid.sh and the shared common/dg_render_common.sh /
# common/dg_local_status_common.sh.
# ============================================================
# Usage: bash tests/test_status_tools.sh
#
# No database, no network. The tools run against stub binaries (ssh, sqlplus,
# dgmgrl, ps, tnsping) placed in a scratch directory; the stub ssh runs the
# remote command locally with `sh -c`, so the exact remote script
# dg_status.sh builds (env exports, log-collection snippet, dgmgrl calls) is
# what gets executed.
#
# Covered:
#   - dg_repl_state: no lag data -> UNKNOWN, never IN SYNC (M12)
#   - threshold validation (80% -> rejected, 08 -> 8)
#   - FRA maths with a comma-decimal value / hostile text (locale finding)
#   - wallet CONNECT keeps the alias text; SET DEFINE OFF first (H5, C1)
#   - the background-and-kill watchdog (H5)
#   - dg_status.sh end to end: healthy run, ssh stderr noise (M13),
#     --standby-sid / multi-pmon (M11), hung remote job (M10), hung
#     discovery calls (probe / pmon scan / DB_NAME query), bad inputs
#   - dg_triage_sid.sh: missing lag data -> UNKNOWN + warning, primary
#     switchover status graded (M12)
# ============================================================

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK="${TMPDIR:-/tmp}/dg_status_tools_test.$$"
mkdir -p "$WORK/home/bin" "$WORK/diag" || { echo "FATAL: cannot create $WORK"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $name"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"; echo "    expected: '$expected'"; echo "    actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: $name"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $name (missing: $needle)"; FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  FAIL: $name (unexpected: $needle)"; FAIL=$((FAIL + 1))
    else
        echo "  PASS: $name"; PASS=$((PASS + 1))
    fi
}

# Orphan check for the hung-process cases. Needs a working `ps` (the watchdog's
# own tree-kill needs it too); inside a restricted sandbox it is skipped.
assert_no_orphans() {
    local name="$1" left
    if ! /bin/ps -ef >/dev/null 2>&1; then
        echo "  SKIP: $name (ps not usable here)"
        return
    fi
    left=$(/bin/ps -ef | grep 'sleep 67' | grep -v grep | wc -l | tr -d ' ')
    assert_eq "$name" "0" "$left"
}

# ------------------------------------------------------------
# Stubs
# ------------------------------------------------------------
BIN="$WORK/home/bin"

# ssh: last argument is the remote command; -p picks the side. Prints a
# known_hosts-style warning on stderr like a real first connection would.
cat > "$WORK/ssh" <<'EOS'
#!/bin/sh
side=primary
prev=""
for a in "$@"; do
    [ "$prev" = "-p" ] && [ "$a" = "2202" ] && side=standby
    prev="$a"
    last="$a"
done
echo "Warning: Permanently added 'stub' (ED25519) to the list of known hosts." >&2
# Discovery-hang hook: the reachability probe never answers on this side.
if [ "$last" = "echo DG_SSH_OK" ] && [ "${STUB_PROBE_HANG_SIDE:-}" = "$side" ]; then exec sleep 67; fi
STUB_SIDE=$side
export STUB_SIDE
exec sh -c "$last"
EOS

# ps: serve canned pmon lines for -ef, defer to the real ps otherwise (the
# watchdog uses `ps -eo pid,ppid`).
cat > "$BIN/ps" <<'EOS'
#!/bin/sh
if [ "$1" = "-ef" ]; then
    # Discovery-hang hook: the pmon scan never returns on this side.
    if [ -n "${STUB_PS_HANG_SIDE:-}" ] && [ "$STUB_SIDE" = "$STUB_PS_HANG_SIDE" ]; then exec sleep 67; fi
    if [ "$STUB_SIDE" = standby ]; then printf '%s\n' "$STUB_PS_STANDBY"; else printf '%s\n' "$STUB_PS_PRIMARY"; fi
    exit 0
fi
exec /bin/ps "$@"
EOS

cat > "$BIN/sqlplus" <<'EOS'
#!/bin/sh
in=$(cat)
if [ -n "$STUB_SQLPLUS_LOG" ]; then printf '%s\n' "$in" >> "$STUB_SQLPLUS_LOG"; fi
[ -n "$STUB_SQLPLUS_SLEEP" ] && exec sleep 67
case "$in" in
    *"Diag Trace"*) echo "  $STUB_DIAG  "; exit 0 ;;
    *DG_DBNAME*)
        # Discovery-hang hook: the DB_NAME query never returns on this side.
        if [ -n "${STUB_DBNAME_HANG_SIDE:-}" ] && [ "$STUB_SIDE" = "$STUB_DBNAME_HANG_SIDE" ]; then exec sleep 67; fi
        case "$ORACLE_SID" in OTHER*) echo "DG_DBNAME|OTHERDB" ;; *) echo "DG_DBNAME|CDB1" ;; esac
        exit 0 ;;
    *WALLET_OK*) echo WALLET_OK; exit 0 ;;
    *PASS_OK*) echo PASS_OK; exit 0 ;;
esac
side="${STUB_SIDE:-$STUB_LOCAL_SIDE}"
if [ "$side" = primary ]; then
    echo "DBSTATUS|PRIMARY|READ WRITE|MAXIMUM AVAILABILITY|${STUB_PRI_SWITCH:-TO STANDBY}|YES|YES|cdb1"
    echo "DGPARAMS|dg_broker_start|TRUE"
    echo "REDOLOG|3|150"
    echo "SRLCOUNT|4"
    echo "ARCHGAP|0"
    echo "UNNAMEDDF|0"
    echo "ARCHDEST|2|VALID|cdb1_stby|"
    echo "FSFODB|ENABLED|YES|obs1"
    echo "FRA|/fra|20.0|0.4|0.1|3"
    echo "SERVICE|APP"
else
    echo "DBSTATUS|PHYSICAL STANDBY|MOUNTED|MAXIMUM AVAILABILITY|NOT ALLOWED|YES|${STUB_STB_FLASH:-YES}|cdb1_stby"
    echo "DGPARAMS|dg_broker_start|${STUB_STB_BROKER:-TRUE}"
    echo "MRP|MRP0|APPLYING_LOG|10"
    if [ -z "$STUB_NO_LAG" ]; then
        echo "DGSTATS|transport lag|+00 00:00:00"
        echo "DGSTATS|apply lag|+00 00:00:00"
        echo "APPLYINFO|10|10"
    fi
    echo "ARCHGAP|0"
    echo "UNNAMEDDF|0"
    echo "SRLCOUNT|4"
    echo "RECMODE|MANAGED REAL TIME APPLY"
    echo "FRA|/fra|20.0|0.4|0.1|3"
fi
exit 0
EOS

cat > "$BIN/dgmgrl" <<'EOS'
#!/bin/sh
[ -n "$STUB_HANG" ] && exec sleep 67
case "$*" in
    *"SHOW FAST_START FAILOVER"*)
        printf 'Fast-Start Failover: Enabled\n  Threshold:          30 seconds\n  Target:             cdb1_stby\n  Observer:           obs1\n'
        ;;
    *DGConnectIdentifier*)
        echo "  DGConnectIdentifier = 'PEER'"
        ;;
    *"SHOW DATABASE"*)
        printf '  Role: PHYSICAL STANDBY\n  Intended State: APPLY-ON\n'
        ;;
    *)
        printf 'Connected to "cdb1"\n\nConfiguration - stubcfg\n\n  Protection Mode: MaxAvailability\n  Members:\n  cdb1      - Primary database\n    cdb1_stby - Physical standby database\n\nFast-Start Failover: Enabled\n\nConfiguration Status:\nSUCCESS   (status updated 5 seconds ago)\n'
        ;;
esac
EOS

cat > "$BIN/tnsping" <<'EOS'
#!/bin/sh
echo "Attempting to contact (DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=h)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=s)))"
echo "OK (10 msec)"
EOS
chmod +x "$WORK/ssh" "$BIN"/*

printf '2026-10-01T10:00:00.1+00:00\nORA-16810 something\n' > "$WORK/diag/alert_cdb1.log"
printf 'ORA-16810 broker\n' > "$WORK/diag/drccdb1.log"

cat > "$WORK/config.env" <<EOS
PRIMARY_HOST="pri.example"
STANDBY_HOST="stb.example"
PRIMARY_ORACLE_HOSTNAME="pri"
STANDBY_ORACLE_HOSTNAME="stb"
PRIMARY_SSH_PORT=2201
STANDBY_SSH_PORT=2202
SSH_USER="oracle"
SSH_OPTS="-o StrictHostKeyChecking=no"
SSH_KEY=""
JUMP_HOST=""
ORACLE_HOME="$WORK/home"
ORACLE_BASE="$WORK"
EOS

# The stub dir goes first on PATH for the tools; "ssh" must win over /usr/bin/ssh.
mkdir -p "$WORK/path"
cp "$WORK/ssh" "$WORK/path/ssh"
STUB_PATH="$WORK/path:$BIN:$PATH"

PS_ONE="oracle  1234  1  0 10:00 ?  00:00:01 ora_pmon_cdb1"

run_status() {
    # run_status [args...]; leaves output in $OUT and the exit code in $RC
    OUT=$(env -u ORACLE_SID PATH="$STUB_PATH" STUB_DIAG="$WORK/diag" \
        STUB_PS_PRIMARY="$PS_ONE" STUB_PS_STANDBY="${STUB_PS_STANDBY_OVERRIDE:-$PS_ONE}" \
        bash "$ROOT/dg_status.sh" -c "$WORK/config.env" --no-color "$@" 2>&1)
    RC=$?
}

# ============================================================
echo "Case 1: dg_repl_state / thresholds / FRA maths (dg_render_common.sh)"
# ============================================================
(
    source "$ROOT/common/dg_render_common.sh"
    r1=$(dg_repl_state "" "" "")
    r2=$(dg_repl_state "+00 00:00:00" "" "")
    r3=$(dg_repl_state "" "+00 00:05:00" "")
    r4=$(dg_repl_state "" "" "9")
    r5=$(dg_repl_state "" "" "3")
    r6=$(dg_repl_state "+00 00:00:00" "+00 00:00:00" "0")
    printf '%s|%s|%s|%s|%s|%s\n' "$r1" "$r2" "$r3" "$r4" "$r5" "$r6"
    printf 'text=%s\n' "$(dg_repl_state_text "$r1")"
    printf 'pct=%s eff=%s\n' "$(compute_fra_pct 20,0 0,4 0,1)" "$(compute_fra_effective 0,4 0,1)"
    printf 'hostile=%s\n' "$(compute_fra_pct 'x;system("echo pwned")' 'a' 'b')"
    DG_FRA_WARN_PCT='80%' dg_validate_thresholds 2>/dev/null; printf 'badrc=%s\n' "$?"
    DG_SEQ_GAP_WARN=08; dg_validate_thresholds; printf 'norm=%s\n' "$DG_SEQ_GAP_WARN"
) > "$WORK/case1.out"
c1=$(cat "$WORK/case1.out")
assert_contains "no data -> UNKNOWN; in sync/lagging/behind classified" "$c1" "UNKNOWN|IN_SYNC|LAGGING|BEHIND_CRIT|BEHIND_WARN|IN_SYNC"
assert_contains "UNKNOWN renders as UNKNOWN text, not IN SYNC" "$c1" "text=UNKNOWN"
assert_contains "comma-decimal FRA values compute (2% / 0.3)" "$c1" "pct=2 eff=0.3"
assert_contains "hostile FRA text is inert (0%)" "$c1" "hostile=0"
assert_contains "threshold '80%' is rejected" "$c1" "badrc=1"
assert_contains "threshold '08' is normalized to 8" "$c1" "norm=8"

# ============================================================
echo "Case 2: wallet CONNECT keeps the alias; SET DEFINE OFF first (H5, C1)"
# ============================================================
(
    export PATH="$STUB_PATH" STUB_SQLPLUS_LOG="$WORK/sqlplus.log" ORACLE_HOME="$WORK/home"
    : > "$WORK/sqlplus.log"
    source "$ROOT/common/dg_local_status_common.sh"
    run_remote_sql_timeout 5 "/@PEER.WORLD" "SELECT 'WALLET_OK' FROM DUAL;" > /dev/null 2>&1
    run_remote_sql_timeout 5 'sys/"p&ss"@PEER' "SELECT 'PASS_OK' FROM DUAL;" > /dev/null 2>&1
)
log=$(cat "$WORK/sqlplus.log")
assert_contains "wallet connect uses /@alias unchanged" "$log" "CONNECT /@PEER.WORLD AS SYSDBA"
assert_not_contains "wallet connect is never rewritten into a descriptor" "$(printf '%s\n' "$log" | grep '/@')" "DESCRIPTION"
assert_contains "password connect still gets descriptor timeouts" "$log" 'CONNECT sys/"p&ss"@(DESCRIPTION=(CONNECT_TIMEOUT=5)'
first_lines=$(printf '%s\n' "$log" | grep -c '^SET DEFINE OFF$')
assert_eq "SET DEFINE OFF precedes every CONNECT script" "2" "$first_lines"
assert_eq "SET DEFINE OFF is the line before CONNECT" "2" "$(printf '%s\n' "$log" | grep -A1 '^SET DEFINE OFF$' | grep -c '^CONNECT ')"

# ============================================================
echo "Case 3: watchdog bounds a hung sqlplus without the timeout binary (H5)"
# ============================================================
(
    export PATH="$STUB_PATH" ORACLE_HOME="$WORK/home" STUB_SQLPLUS_SLEEP=1
    source "$ROOT/common/dg_local_status_common.sh"
    start=$SECONDS
    run_remote_sql_watchdog 2 "/@PEER" "SELECT 1 FROM DUAL;" > "$WORK/wd.out" 2>&1
    echo "elapsed=$((SECONDS - start))" > "$WORK/wd.time"
)
elapsed=$(sed 's/elapsed=//' "$WORK/wd.time")
if [[ "$elapsed" =~ ^[0-9]+$ ]] && (( elapsed <= 6 )); then
    echo "  PASS: hung sqlplus killed after ~2s (took ${elapsed}s)"; PASS=$((PASS + 1))
else
    echo "  FAIL: watchdog took '${elapsed}'s"; FAIL=$((FAIL + 1))
fi
assert_no_orphans "no orphaned sqlplus left behind"
(
    export PATH="$STUB_PATH" ORACLE_HOME="$WORK/home"
    source "$ROOT/common/dg_local_status_common.sh"
    run_remote_sql_watchdog 5 "/@PEER" "SELECT 'WALLET_OK' FROM DUAL;" 2>&1
) > "$WORK/wd2.out"
assert_contains "watchdog returns the output of a fast sqlplus" "$(cat "$WORK/wd2.out")" "WALLET_OK"

# ============================================================
echo "Case 4: dg_status.sh end to end - healthy configuration"
# ============================================================
run_status
assert_eq "healthy run exits 0" "0" "$RC"
assert_contains "reports HEALTHY" "$OUT" "HEALTHY"
assert_not_contains "ssh stderr warning is not a finding (M13)" "$OUT" "Permanently added"
assert_contains "standby flashback is graded and shown (M12)" "$OUT" "Flashback                YES"
assert_contains "standby DG Broker row is shown (M12)" "$OUT" "DG Broker                TRUE"
assert_contains "redo apply is IN SYNC with data" "$OUT" "IN SYNC"
assert_contains "FRA parsed" "$OUT" "0.3/20.0 GB effective (2%)"
assert_contains "alert log path printed" "$OUT" "alert_cdb1.log"

echo "Case 4b: standby flashback / broker are errors or warnings (M12)"
OUT=$(env -u ORACLE_SID PATH="$STUB_PATH" STUB_DIAG="$WORK/diag" STUB_PS_PRIMARY="$PS_ONE" STUB_PS_STANDBY="$PS_ONE" \
    STUB_STB_FLASH=NO STUB_STB_BROKER=FALSE bash "$ROOT/dg_status.sh" -c "$WORK/config.env" --no-color 2>&1); RC=$?
assert_eq "broker FALSE on standby -> exit 2" "2" "$RC"
assert_contains "standby broker error in summary" "$OUT" "DG Broker is 'FALSE' on standby"
assert_contains "standby flashback warning in summary" "$OUT" "Flashback is 'NO' on standby"

echo "Case 4c: no lag data from a reachable standby -> UNKNOWN + warning, never IN SYNC (M12/M18)"
OUT=$(env -u ORACLE_SID PATH="$STUB_PATH" STUB_DIAG="$WORK/diag" STUB_PS_PRIMARY="$PS_ONE" STUB_PS_STANDBY="$PS_ONE" \
    STUB_NO_LAG=1 bash "$ROOT/dg_status.sh" -c "$WORK/config.env" --no-color 2>&1); RC=$?
assert_eq "no lag data -> exit 1" "1" "$RC"
assert_contains "warning names the unknown replication state" "$OUT" "Replication state unknown"
assert_not_contains "no green IN SYNC" "$OUT" "IN SYNC"

# ============================================================
echo "Case 5: several instances on the standby host (M11)"
# ============================================================
PS_STB_MULTI="oracle 1 1 0 10:00 ? 00:00:01 ora_pmon_OTHER
oracle 2 1 0 10:00 ? 00:00:01 ora_pmon_cdb1"
STUB_PS_STANDBY_OVERRIDE="$PS_STB_MULTI" run_status
assert_contains "standby instance matching the primary's DB_NAME is chosen" "$OUT" "Standby: stb (SID: cdb1)"
assert_not_contains "no ambiguity warning when DB_NAME decides" "$OUT" "Several Oracle instances"

PS_STB_MULTI2="oracle 1 1 0 10:00 ? 00:00:01 ora_pmon_OTHER
oracle 2 1 0 10:00 ? 00:00:01 ora_pmon_OTHER2"
STUB_PS_STANDBY_OVERRIDE="$PS_STB_MULTI2" run_status
assert_contains "undecidable choice is warned about" "$OUT" "Several Oracle instances run on standby"

STUB_PS_STANDBY_OVERRIDE="$PS_STB_MULTI2" run_status --standby-sid cdb1
assert_contains "--standby-sid overrides detection" "$OUT" "Standby: stb (SID: cdb1)"
assert_not_contains "no warning with --standby-sid" "$OUT" "Several Oracle instances"
run_status --standby-sid "1bad"
assert_eq "invalid --standby-sid -> exit 3" "3" "$RC"
run_status --standby-sid
assert_eq "--standby-sid without argument -> exit 3" "3" "$RC"

PS_PRI_MULTI="oracle 1 1 0 10:00 ? 00:00:01 ora_pmon_cdb1
oracle 2 1 0 10:00 ? 00:00:01 ora_pmon_second"
OUT=$(env -u ORACLE_SID PATH="$STUB_PATH" STUB_DIAG="$WORK/diag" STUB_PS_PRIMARY="$PS_PRI_MULTI" STUB_PS_STANDBY="$PS_ONE" \
    bash "$ROOT/dg_status.sh" -c "$WORK/config.env" --no-color 2>&1)
assert_contains "several primary instances are warned about" "$OUT" "Several Oracle instances run on primary"

# ============================================================
echo "Case 6: a hung remote job is cut off and reported (M10)"
# ============================================================
start=$SECONDS
OUT=$(env -u ORACLE_SID PATH="$STUB_PATH" STUB_DIAG="$WORK/diag" STUB_PS_PRIMARY="$PS_ONE" STUB_PS_STANDBY="$PS_ONE" \
    STUB_HANG=1 DG_REMOTE_TIMEOUT=3 bash "$ROOT/dg_status.sh" -c "$WORK/config.env" --no-color 2>&1); RC=$?
elapsed=$((SECONDS - start))
assert_eq "hung dgmgrl -> exit 2" "2" "$RC"
assert_contains "timeout is named in the summary" "$OUT" "timed out after 3s"
assert_contains "the cut-off job is named" "$OUT" "DGMGRL configuration"
if (( elapsed < 20 )); then
    echo "  PASS: dashboard finished in ${elapsed}s instead of hanging"; PASS=$((PASS + 1))
else
    echo "  FAIL: took ${elapsed}s"; FAIL=$((FAIL + 1))
fi
assert_no_orphans "hung remote processes were killed (no orphans)"

# ============================================================
echo "Case 6a: discovery is bounded too - a hung DB_NAME query on a healthy ssh connection"
# ============================================================
# Two pmon SIDs on the standby force the remote `sqlplus / as sysdba` DB_NAME
# queries; the standby's never returns. ssh keepalives cannot help (the stub
# connection is alive), only the bounded-execution watchdog can.
PS_STB_MULTI="oracle 1 1 0 10:00 ? 00:00:01 ora_pmon_OTHER
oracle 2 1 0 10:00 ? 00:00:01 ora_pmon_cdb1"
start=$SECONDS
OUT=$(env -u ORACLE_SID PATH="$STUB_PATH" STUB_DIAG="$WORK/diag" STUB_PS_PRIMARY="$PS_ONE" STUB_PS_STANDBY="$PS_STB_MULTI" \
    STUB_DBNAME_HANG_SIDE=standby DG_REMOTE_TIMEOUT=3 bash "$ROOT/dg_status.sh" -c "$WORK/config.env" --no-color 2>&1); RC=$?
elapsed=$((SECONDS - start))
assert_eq "hung standby DB_NAME query -> exit 2 (never a healthy-looking pass)" "2" "$RC"
assert_contains "timeout message names the standby host" "$OUT" "Discovery on standby stb.example"
assert_contains "timeout message names the limit and what hung" "$OUT" "after 3s (DB_NAME query for SID OTHER)"
assert_contains "existing could-not-match fallback still applies" "$OUT" "Several Oracle instances run on standby"
if (( elapsed < 20 )); then
    echo "  PASS: dashboard finished in ${elapsed}s instead of hanging"; PASS=$((PASS + 1))
else
    echo "  FAIL: took ${elapsed}s"; FAIL=$((FAIL + 1))
fi
assert_no_orphans "hung DB_NAME query tree was killed (no orphans)"

echo "Case 6a-2: hung pmon detection on the primary -> bounded, exit 2"
start=$SECONDS
OUT=$(env -u ORACLE_SID PATH="$STUB_PATH" STUB_DIAG="$WORK/diag" STUB_PS_PRIMARY="$PS_ONE" STUB_PS_STANDBY="$PS_ONE" \
    STUB_PS_HANG_SIDE=primary DG_REMOTE_TIMEOUT=3 bash "$ROOT/dg_status.sh" -c "$WORK/config.env" --no-color 2>&1); RC=$?
elapsed=$((SECONDS - start))
assert_eq "hung primary pmon scan -> exit 2 (errors present, not usage)" "2" "$RC"
assert_contains "primary timeout is reported" "$OUT" "instance detection on primary (pri.example:2201) timed out after 3s"
if (( elapsed < 20 )); then
    echo "  PASS: finished in ${elapsed}s instead of hanging"; PASS=$((PASS + 1))
else
    echo "  FAIL: took ${elapsed}s"; FAIL=$((FAIL + 1))
fi
assert_no_orphans "hung pmon scan tree was killed (no orphans)"

echo "Case 6a-3: hung pmon detection on the standby -> standby not collected, exit 2"
OUT=$(env -u ORACLE_SID PATH="$STUB_PATH" STUB_DIAG="$WORK/diag" STUB_PS_PRIMARY="$PS_ONE" STUB_PS_STANDBY="$PS_ONE" \
    STUB_PS_HANG_SIDE=standby DG_REMOTE_TIMEOUT=3 bash "$ROOT/dg_status.sh" -c "$WORK/config.env" --no-color 2>&1); RC=$?
assert_eq "hung standby pmon scan -> exit 2" "2" "$RC"
assert_contains "standby timeout names the host and the step" "$OUT" "Discovery on standby stb.example:2202"
assert_contains "standby row says why it was not collected" "$OUT" "UNREACHABLE (discovery timed out)"
assert_no_orphans "hung standby pmon scan tree was killed (no orphans)"

echo "Case 6a-4: hung ssh reachability probe -> bounded, host reported"
start=$SECONDS
OUT=$(env -u ORACLE_SID PATH="$STUB_PATH" STUB_DIAG="$WORK/diag" STUB_PS_PRIMARY="$PS_ONE" STUB_PS_STANDBY="$PS_ONE" \
    STUB_PROBE_HANG_SIDE=standby DG_REMOTE_TIMEOUT=3 bash "$ROOT/dg_status.sh" -c "$WORK/config.env" --no-color 2>&1); RC=$?
elapsed=$((SECONDS - start))
assert_eq "hung standby probe -> exit 2" "2" "$RC"
assert_contains "probe timeout names the standby host" "$OUT" "SSH probe to standby (stb.example:2202) timed out after 3s"
if (( elapsed < 20 )); then
    echo "  PASS: finished in ${elapsed}s instead of hanging"; PASS=$((PASS + 1))
else
    echo "  FAIL: took ${elapsed}s"; FAIL=$((FAIL + 1))
fi
assert_no_orphans "hung probe tree was killed (no orphans)"

echo "Case 6b: invalid DG_REMOTE_TIMEOUT / thresholds are usage errors"
OUT=$(env -u ORACLE_SID PATH="$STUB_PATH" DG_REMOTE_TIMEOUT=abc bash "$ROOT/dg_status.sh" -c "$WORK/config.env" 2>&1); RC=$?
assert_eq "DG_REMOTE_TIMEOUT=abc -> exit 3" "3" "$RC"
OUT=$(env -u ORACLE_SID PATH="$STUB_PATH" DG_FRA_WARN_PCT='80%' bash "$ROOT/dg_status.sh" -c "$WORK/config.env" 2>&1); RC=$?
assert_eq "DG_FRA_WARN_PCT=80% -> exit 3" "3" "$RC"

# ============================================================
echo "Case 7: empty Diag Trace -> 'path could not be determined' (not MISSING|/alert_SID.log)"
# ============================================================
OUT=$(env -u ORACLE_SID PATH="$STUB_PATH" STUB_DIAG="" STUB_PS_PRIMARY="$PS_ONE" STUB_PS_STANDBY="$PS_ONE" \
    bash "$ROOT/dg_status.sh" -c "$WORK/config.env" --no-color 2>&1)
assert_contains "documented outcome is rendered" "$OUT" "path could not be determined"
assert_not_contains "no bogus /alert_cdb1.log path" "$OUT" "(file not found: /alert"

# ============================================================
echo "Case 8: SSH key path with spaces survives (array options)"
# ============================================================
KEY="$WORK/my key"; : > "$KEY"
sed "s|^SSH_KEY=.*|SSH_KEY=\"$KEY\"|" "$WORK/config.env" > "$WORK/config_key.env"
# a stub that fails loudly if -i is split
cat > "$WORK/path/ssh" <<'EOS'
#!/bin/sh
prev=""
for a in "$@"; do
    if [ "$prev" = "-i" ]; then
        case "$a" in *"my key") : ;; *) echo "SPLIT_KEY:$a" >&2; exit 255 ;; esac
    fi
    prev="$a"
done
exec "$STUB_REAL_SSH" "$@"
EOS
chmod +x "$WORK/path/ssh"
OUT=$(env -u ORACLE_SID PATH="$STUB_PATH" STUB_REAL_SSH="$WORK/ssh" STUB_DIAG="$WORK/diag" STUB_PS_PRIMARY="$PS_ONE" STUB_PS_STANDBY="$PS_ONE" \
    bash "$ROOT/dg_status.sh" -c "$WORK/config_key.env" --no-color 2>&1); RC=$?
assert_not_contains "key path is passed as one argument" "$OUT" "SPLIT_KEY"
assert_eq "run with spaced key path succeeds" "0" "$RC"

# ============================================================
echo "Case 9: dg_triage_sid.sh on a standby with no lag data (M12)"
# ============================================================
run_triage() {
    OUT=$(env PATH="$STUB_PATH" ORACLE_SID=cdb1 ORACLE_HOME="$WORK/home" STUB_DIAG="$WORK/diag" "$@" \
        bash "$ROOT/dg_triage_sid.sh" -L --no-color 2>&1)
    RC=$?
}
run_triage STUB_LOCAL_SIDE=standby STUB_NO_LAG=1
assert_contains "missing lag data renders UNKNOWN" "$OUT" "UNKNOWN"
assert_not_contains "never a green IN SYNC without data" "$OUT" "IN SYNC"
assert_contains "and raises a warning" "$OUT" "Replication state unknown"

run_triage STUB_LOCAL_SIDE=standby
assert_contains "with lag data the standby is IN SYNC" "$OUT" "IN SYNC"

echo "Case 9b: primary switchover status is graded by the local engine (M12)"
run_triage STUB_LOCAL_SIDE=primary STUB_PRI_SWITCH="NOT ALLOWED"
assert_contains "primary switchover warning" "$OUT" "Primary switchover status is NOT ALLOWED"
run_triage STUB_LOCAL_SIDE=primary
assert_not_contains "TO STANDBY is fine" "$OUT" "Primary switchover status"

echo "Case 9c: bad threshold -> usage exit 64 in the local tools"
OUT=$(env PATH="$STUB_PATH" ORACLE_SID=cdb1 ORACLE_HOME="$WORK/home" DG_LAG_WARN_SECONDS=1m \
    bash "$ROOT/dg_triage_sid.sh" -L --no-color 2>&1); RC=$?
assert_eq "DG_LAG_WARN_SECONDS=1m -> exit 64" "64" "$RC"

echo ""
echo "============================================================"
echo "Test Summary: $PASS passed, $FAIL failed"
echo "============================================================"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
