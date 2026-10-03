#!/usr/bin/env bash
# ============================================================
# Tests for fsfo/observer.sh (check mode, approval mode, broker member
# selection, wallet login proof, private wallet staging)
# ============================================================
# Usage: bash tests/test_fsfo_observer.sh
#
# DB-free: dgmgrl, sqlplus, mkstore and orapki are stubs in a fake
# ORACLE_HOME that record every invocation (arguments only - never stdin,
# which carries the passwords) in a call log. The script runs against a
# scratch NFS share holding one standby_config_*.env, a scratch wallet
# directory and a scratch TNS_ADMIN. Covers
#   1. -n with setup/start/stop/restart: no mkstore/orapki, no START/STOP
#      OBSERVER, pidfile (stale included), wallet and sqlnet.ora unchanged,
#      no file created, no process signalled, exit 0, "Check mode" printed
#   2. -a answered "n": the action does not run and the command exits non-zero
#   3. the primary alias hanging or down: the standby alias is chosen, within
#      DG_OBSERVER_CONNECT_TIMEOUT, for preflight, launch and stop
#   4. setup whose standby login fails (ORA-01017 with exit 1, the same with
#      exit 0, an SP2- line with exit 0, a SYS identity): exit 1, no SUCCESS,
#      restore hint; and the positive path proves both aliases
#   5. setup with mktemp failing/absent and no usable fallback directory:
#      no mkstore call at all
# Tests that need `ps` (a live fake observer process) are skipped where ps
# is not usable (e.g. a restricted sandbox).
# Runs under bash 3.2 and 5.x: the script under test is run with the same
# bash that runs this file.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OBS="${REPO_ROOT}/fsfo/observer.sh"
BASH_BIN="${BASH:-bash}"

PASS=0
FAIL=0
SKIP=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  SKIP: %s\n' "$1"; SKIP=$((SKIP+1)); }
assert_eq() {   # name expected actual
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
assert_ne() {   # name unexpected actual
    if [[ "$2" != "$3" ]]; then pass "$1"; else fail "$1 (got '$3')"; fi
}
assert_contains() {   # name haystack needle
    if printf '%s\n' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1 (missing '$3')"; fi
}
assert_not_contains() {
    if printf '%s\n' "$2" | grep -qF -- "$3"; then fail "$1 (unexpected '$3')"; else pass "$1"; fi
}

# The environment of the caller must not leak modes into the script.
unset CHECK_ONLY APPROVAL_MODE SUSPICIOUS VERBOSE ORACLE_SID TNS_ADMIN WALLET_DIR \
    OBSERVER_DIR OBSERVER_WALLET_DIR LOG_FILE DG_OBSERVER_CONNECT_TIMEOUT

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fsfo_observer_test.XXXXXX") || { echo "mktemp failed"; exit 1; }
BG_PIDS=""
cleanup() {
    local p
    for p in $BG_PIDS; do
        kill "$p" 2>/dev/null
    done
    chmod 700 "$WORK/rotmp" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

PS_OK=false
if ps -p $$ -o pid= >/dev/null 2>&1; then
    PS_OK=true
fi

# ------------------------------------------------------------
# Stubs
# ------------------------------------------------------------
OH="$WORK/oh"
mkdir -p "$OH/bin"

# dgmgrl [-silent] <connect> <command>
#   STUB_HANG_ALIASES  - aliases that never answer (exec sleep: one process to kill)
#   STUB_DOWN_ALIASES  - aliases that answer with ORA-12541
#   STUB_BAD_ALIASES   - aliases whose login fails with ORA-01017 (exit STUB_BAD_RC, default 1)
cat > "$OH/bin/dgmgrl" <<'STUB'
#!/bin/bash
[[ "$1" == "-silent" ]] && shift
conn="$1"; cmd="$2"
printf 'dgmgrl %s | %s\n' "$conn" "$cmd" >> "$STUB_LOG"
alias="${conn#/@}"
case " ${STUB_HANG_ALIASES:-} " in *" $alias "*) exec sleep 60 ;; esac
case " ${STUB_DOWN_ALIASES:-} " in *" $alias "*) echo "ORA-12541: TNS:no listener"; exit 1 ;; esac
case " ${STUB_BAD_ALIASES:-} " in
    *" $alias "*) echo "ORA-01017: invalid username/password; logon denied"; exit "${STUB_BAD_RC:-1}" ;;
esac
case "$cmd" in
    "show configuration")
        printf 'Configuration - dg_cfg\n\n  Protection Mode: MaxAvailability\n  Members:\n'
        printf '  pri  - Primary database\n    Warning: ORA-16819: fast-start failover observer not started\n'
        printf '  stby - (*) Physical standby database\n\n'
        printf 'Fast-Start Failover: Enabled in Zero Data Loss Mode\n\nConfiguration Status:\nWARNING\n'
        ;;
    "show fast_start failover")
        printf '\nFast-Start Failover: Enabled in Zero Data Loss Mode\n\n  Threshold: 30 seconds\n'
        printf '  Observer:  (none)\n\n  Oracle Error Conditions:\n    (none)\n'
        ;;
    "SHOW OBSERVER")
        printf 'Configuration - dg_cfg\n\n  Primary:            pri\n'
        [[ -f "$STUB_STATE/started" ]] && printf '  Observer "obs1" - Master\n'
        ;;
    START\ OBSERVER*)
        : > "$STUB_STATE/started"
        # Runs like the real observer until STOP OBSERVER (or a signal)
        while [[ -f "$STUB_STATE/started" ]]; do sleep 1; done
        ;;
    "STOP OBSERVER")
        rm -f "$STUB_STATE/started"
        echo "Observer stopped."
        ;;
esac
exit 0
STUB

# sqlplus -s -L /@<alias> as sysdg  (query on stdin)
#   STUB_HANG_ALIASES / STUB_DOWN_ALIASES / STUB_BAD_ALIASES as above
#   STUB_SQLPLUS_ERR_ALIASES - print an SP2- error but exit 0
#   STUB_IDENT               - authenticated identity (default DG_OBSERVER)
cat > "$OH/bin/sqlplus" <<'STUB'
#!/bin/bash
conn=""
for a in "$@"; do case "$a" in /@*) conn="$a" ;; esac; done
alias="${conn#/@}"
in=$(cat)
what=other
case "$in" in
    *fs_failover_observer_present*) what=present ;;
    *AUTHENTICATED_IDENTITY*) what=identity ;;
esac
printf 'sqlplus %s | %s\n' "$conn" "$what" >> "$STUB_LOG"
case " ${STUB_HANG_ALIASES:-} " in *" $alias "*) exec sleep 60 ;; esac
case " ${STUB_DOWN_ALIASES:-} " in *" $alias "*) echo "ORA-12541: TNS:no listener"; exit 1 ;; esac
case " ${STUB_BAD_ALIASES:-} " in
    *" $alias "*) echo "ERROR:"; echo "ORA-01017: invalid username/password; logon denied"; exit "${STUB_BAD_RC:-1}" ;;
esac
case " ${STUB_SQLPLUS_ERR_ALIASES:-} " in *" $alias "*) echo "SP2-0306: Invalid option."; exit 0 ;; esac
case "$what" in
    present)  if [[ -f "$STUB_STATE/started" ]]; then echo "PRESENT=YES"; else echo "PRESENT=NO"; fi ;;
    identity) echo "IDENT=${STUB_IDENT:-DG_OBSERVER}|SYSDG" ;;
esac
exit 0
STUB

# mkstore: records its arguments (stdin - the secrets - is read and dropped)
cat > "$OH/bin/mkstore" <<'STUB'
#!/bin/bash
printf 'mkstore %s\n' "$*" >> "$STUB_LOG"
cat > /dev/null
wrl=""; prev=""
for a in "$@"; do
    [[ "$prev" == "-wrl" ]] && wrl="$a"
    prev="$a"
done
case " $* " in
    *" -create "*) mkdir -p "$wrl"; : > "$wrl/ewallet.p12" ;;
    *" -createSSO "*) : > "$wrl/cwallet.sso" ;;
    *" -createCredential "*) printf '%s\n' "$*" >> "$wrl/creds" ;;
esac
exit 0
STUB

cat > "$OH/bin/orapki" <<'STUB'
#!/bin/bash
printf 'orapki %s\n' "$*" >> "$STUB_LOG"
exit 0
STUB
chmod +x "$OH/bin/dgmgrl" "$OH/bin/sqlplus" "$OH/bin/mkstore" "$OH/bin/orapki"

# A failing mktemp, for "installed but broken"
mkdir -p "$WORK/badmk"
printf '#!/bin/sh\nexit 1\n' > "$WORK/badmk/mktemp"
chmod +x "$WORK/badmk/mktemp"

# A PATH with no mktemp at all: every tool from the system directories,
# symlinked, except mktemp.
mkdir -p "$WORK/nomk"
for d in /bin /usr/bin /sbin /usr/sbin; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
        n="${f##*/}"
        [[ "$n" == "mktemp" || -e "$WORK/nomk/$n" ]] && continue
        [[ -x "$f" && ! -d "$f" ]] && ln -s "$f" "$WORK/nomk/$n" 2>/dev/null
    done
done

# A TMPDIR nobody (not even us) can create anything in
mkdir -p "$WORK/rotmp"
chmod 500 "$WORK/rotmp"

SHARE="$WORK/share"
WALLET="$WORK/wallet"
TNS="$WORK/tns"
OBSDIR="$WORK/obs"
STATE="$WORK/state"
CALLS="$WORK/calls.log"
RUNTMP="$WORK/tmp"
PIDFILE="$SHARE/fsfo_observer_stby.pid"
HOST=$(hostname)

# Fresh scratch environment for one case
reset_env() {
    rm -rf "$SHARE" "$WALLET" "$WALLET".bak.* "$TNS" "$OBSDIR" "$STATE" "$RUNTMP"
    mkdir -p "$SHARE/logs" "$TNS" "$STATE" "$RUNTMP"
    : > "$CALLS"
    cat > "$SHARE/standby_config_stby.env" <<'EOF'
PRIMARY_DB_UNIQUE_NAME=pri
STANDBY_DB_UNIQUE_NAME=stby
PRIMARY_TNS_ALIAS=PRI
STANDBY_TNS_ALIAS=STB
OBSERVER_USER=DG_OBSERVER
EOF
}

# An existing auto-login wallet that sqlnet.ora already points at
make_wallet() {
    mkdir -p "$WALLET"
    printf 'p12\n' > "$WALLET/ewallet.p12"
    printf 'sso\n' > "$WALLET/cwallet.sso"
    printf 'WALLET_LOCATION = (SOURCE = (METHOD = FILE) (METHOD_DATA = (DIRECTORY = %s)))\nSQLNET.WALLET_OVERRIDE = TRUE\n' \
        "$WALLET" > "$TNS/sqlnet.ora"
}

# Everything a check-mode run must leave alone: names, then contents.
# snapshot_state: the same minus the script's own log, which a real
# (non-check) run - e.g. a declined approval - legitimately writes.
_snap() {   # _snap <find name-pattern to exclude>
    {
        find "$SHARE" "$WALLET" "$TNS" "$OBSDIR" "$RUNTMP" ! -name "$1" 2>/dev/null | sort
        find "$SHARE" "$WALLET" "$TNS" "$OBSDIR" "$RUNTMP" -type f ! -name "$1" 2>/dev/null | sort | while IFS= read -r f; do
            cksum < "$f"
        done
    } 2>/dev/null
}
snapshot() { _snap '/nothing/'; }
snapshot_state() { _snap '*_script.log'; }

# run_obs "<stdin, printf %b>" [VAR=value ...] -- args...
# Sets OUT, RC, ELAPSED.
run_obs() {
    local input="$1" t0
    shift
    local envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        envs+=("$1")
        shift
    done
    shift
    t0=$(date +%s)
    OUT=$(printf '%b' "$input" | env HOME="$WORK" PATH="$OH/bin:$PATH" TMPDIR="$RUNTMP" \
        ORACLE_HOME="$OH" NFS_SHARE="$SHARE" WALLET_DIR="$WALLET" TNS_ADMIN="$TNS" \
        OBSERVER_DIR="$OBSDIR" NO_COLOR=1 STUB_LOG="$CALLS" STUB_STATE="$STATE" \
        ${envs[@]+"${envs[@]}"} "$BASH_BIN" "$OBS" "$@" 2>&1)
    RC=$?
    ELAPSED=$(( $(date +%s) - t0 ))
}

calls() { cat "$CALLS" 2>/dev/null; }
count_calls() { grep -c -- "$1" "$CALLS" 2>/dev/null | tr -d ' '; }

# A live fake observer: the dgmgrl stub in its START OBSERVER loop, with
# its host:PID in the pidfile (the shape observer.sh start leaves behind).
start_fake_observer() {
    : > "$STATE/started"
    STUB_LOG="$WORK/fake.log" STUB_STATE="$STATE" "$OH/bin/dgmgrl" "/@PRI" "START OBSERVER FILE IS 'x'" >/dev/null 2>&1 &
    FAKE_PID=$!
    BG_PIDS="$BG_PIDS $FAKE_PID"
    printf '%s:%s\n' "$HOST" "$FAKE_PID" > "$PIDFILE"
    sleep 1
}
pid_alive() { kill -0 "$1" 2>/dev/null; }

echo "============================================================"
echo "fsfo/observer.sh (bash ${BASH_VERSION})"
echo "============================================================"

echo ""
echo "Test 0: syntax"
if "$BASH_BIN" -n "$OBS"; then pass "bash -n fsfo/observer.sh"; else fail "bash -n fsfo/observer.sh"; fi

# ------------------------------------------------------------
echo ""
echo "Test 1: check mode (-n) changes nothing"
# ------------------------------------------------------------

reset_env
make_wallet
printf '%s:999999\n' "$HOST" > "$PIDFILE"      # stale: no such process
BEFORE=$(snapshot)
run_obs "" -- setup -n
assert_eq "setup -n exits 0" "0" "$RC"
assert_contains "setup -n says check mode" "$OUT" "Check mode"
assert_eq "setup -n: no mkstore call" "0" "$(count_calls '^mkstore')"
assert_eq "setup -n: no orapki call" "0" "$(count_calls '^orapki')"
assert_not_contains "setup -n: no password prompt" "$OUT" "Enter "
assert_eq "setup -n: wallet, sqlnet.ora, pidfile, share unchanged" "$BEFORE" "$(snapshot)"
assert_contains "setup -n: existing wallet tested for the standby too" "$(calls)" "sqlplus /@STB | identity"

reset_env      # no wallet, no sqlnet.ora: the "build everything" plan
BEFORE=$(snapshot)
run_obs "" -- -n setup
assert_eq "setup -n (no wallet) exits 0" "0" "$RC"
assert_contains "setup -n (no wallet) plans the sqlnet.ora creation" "$OUT" "Create $TNS/sqlnet.ora"
assert_eq "setup -n (no wallet): no mkstore call" "0" "$(count_calls '^mkstore')"
assert_eq "setup -n (no wallet): nothing created" "$BEFORE" "$(snapshot)"

for cmd in start stop restart; do
    reset_env
    make_wallet
    printf '%s:999999\n' "$HOST" > "$PIDFILE"
    BEFORE=$(snapshot)
    run_obs "" -- "$cmd" --check
    assert_eq "$cmd --check exits 0" "0" "$RC"
    assert_contains "$cmd --check says check mode" "$OUT" "Check mode"
    assert_eq "$cmd --check: no START OBSERVER" "0" "$(count_calls 'START OBSERVER')"
    assert_eq "$cmd --check: no STOP OBSERVER" "0" "$(count_calls 'STOP OBSERVER')"
    assert_eq "$cmd --check: no mkstore" "0" "$(count_calls '^mkstore')"
    assert_eq "$cmd --check: no orapki" "0" "$(count_calls '^orapki')"
    assert_eq "$cmd --check: stale pidfile, wallet, sqlnet.ora byte-identical, nothing created" "$BEFORE" "$(snapshot)"
    assert_contains "$cmd --check: stale pidfile reported, not removed" "$OUT" "left in place"
done
assert_contains "restart --check plans the start too" "$OUT" "observer.sh start would"

# Remote host's pidfile while the broker reports no observer: start -n
# reports the record as stale instead of deleting it.
reset_env
make_wallet
printf 'otherhost:1234\n' > "$PIDFILE"
BEFORE=$(snapshot)
run_obs "" -- start -n
assert_eq "start -n with another host's stale record exits 0" "0" "$RC"
assert_eq "start -n leaves another host's record alone" "$BEFORE" "$(snapshot)"

# status is read-only and runs normally under -n; a stale pidfile stays
reset_env
make_wallet
printf '%s:999999\n' "$HOST" > "$PIDFILE"
BEFORE=$(snapshot)
run_obs "" -- status -n
assert_contains "status -n runs the normal status report" "$OUT" "FSFO Observer Status"
assert_eq "status -n keeps the stale pidfile" "$BEFORE" "$(snapshot)"

if $PS_OK; then
    for cmd in stop restart; do
        reset_env
        make_wallet
        start_fake_observer
        BEFORE=$(snapshot)
        run_obs "" -- "$cmd" -n
        assert_eq "$cmd -n with a live observer exits 0" "0" "$RC"
        assert_eq "$cmd -n: no STOP OBSERVER sent" "0" "$(count_calls 'STOP OBSERVER')"
        if pid_alive "$FAKE_PID"; then pass "$cmd -n: observer process not signalled"; else fail "$cmd -n: observer process not signalled"; fi
        assert_eq "$cmd -n: pidfile unchanged" "$BEFORE" "$(snapshot)"
        kill "$FAKE_PID" 2>/dev/null
        rm -f "$STATE/started"
    done
    assert_contains "restart -n plans the start after the planned stop" "$OUT" "assuming the observer was stopped"
else
    skip "stop/restart -n against a live observer process (ps not usable here)"
fi

# ------------------------------------------------------------
echo ""
echo "Test 2: approval mode (-a) answered 'n'"
# ------------------------------------------------------------

reset_env
make_wallet
BEFORE=$(snapshot_state)
run_obs "n\n" -- start -a
assert_ne "start -a, declined: non-zero exit" "0" "$RC"
assert_contains "start -a shows the approval prompt" "$OUT" "Start the FSFO observer"
assert_eq "start -a, declined: no START OBSERVER" "0" "$(count_calls 'START OBSERVER')"
assert_eq "start -a, declined: no pidfile, no directory" "$BEFORE" "$(snapshot_state)"

reset_env
run_obs "n\n" -- setup -a
assert_ne "setup -a, declined: non-zero exit" "0" "$RC"
assert_eq "setup -a, declined: no mkstore call" "0" "$(count_calls '^mkstore')"
assert_not_contains "setup -a, declined: no password prompt" "$OUT" "Enter wallet password"
if [[ -e "$WALLET" ]]; then fail "setup -a, declined: no wallet directory"; else pass "setup -a, declined: no wallet directory"; fi
if [[ -e "$TNS/sqlnet.ora" ]]; then fail "setup -a, declined: no sqlnet.ora"; else pass "setup -a, declined: no sqlnet.ora"; fi

# Approve the build and the credentials, decline the activation: the live
# wallet location stays empty and the staged copy is discarded.
reset_env
run_obs "y\nwpw\nwpw\ny\nopw\nn\n" -- setup -a
assert_ne "setup -a, activation declined: non-zero exit" "0" "$RC"
if [[ -e "$WALLET" ]]; then fail "setup -a, activation declined: no wallet activated"; else pass "setup -a, activation declined: no wallet activated"; fi
assert_eq "setup -a, activation declined: staging directory removed" "" "$(ls "$RUNTMP" 2>/dev/null)"

reset_env
make_wallet
printf '%s:999999\n' "$HOST" > "$PIDFILE"
BEFORE=$(snapshot_state)
run_obs "n\n" -- stop -a
assert_ne "stop -a, stale pidfile removal declined: non-zero exit" "0" "$RC"
assert_eq "stop -a, declined: stale pidfile kept" "$BEFORE" "$(snapshot_state)"

if $PS_OK; then
    reset_env
    make_wallet
    start_fake_observer
    BEFORE=$(snapshot_state)
    run_obs "n\n" -- stop -a
    assert_ne "stop -a, declined: non-zero exit" "0" "$RC"
    assert_eq "stop -a, declined: no STOP OBSERVER" "0" "$(count_calls 'STOP OBSERVER')"
    if pid_alive "$FAKE_PID"; then pass "stop -a, declined: observer still running"; else fail "stop -a, declined: observer still running"; fi
    assert_eq "stop -a, declined: pidfile intact" "$BEFORE" "$(snapshot_state)"
    kill "$FAKE_PID" 2>/dev/null
    rm -f "$STATE/started"
else
    skip "stop -a against a live observer process (ps not usable here)"
fi

# ------------------------------------------------------------
echo ""
echo "Test 3: original primary unreachable - the standby alias is used"
# ------------------------------------------------------------

reset_env
make_wallet
run_obs "" STUB_HANG_ALIASES=PRI DG_OBSERVER_CONNECT_TIMEOUT=2 -- start -n
assert_eq "start -n, primary hanging: exit 0" "0" "$RC"
assert_contains "start -n, primary hanging: launch planned through the standby" "$OUT" "dgmgrl /@STB \"START OBSERVER"
assert_contains "start -n names the chosen member and why" "$OUT" "Broker member for this run: STB"
assert_contains "start -n says why PRI was skipped" "$OUT" "no answer within 2s"
if [[ $ELAPSED -le 12 ]]; then pass "hanging primary bounded (${ELAPSED}s)"; else fail "hanging primary bounded (${ELAPSED}s > 12s)"; fi
assert_contains "FSFO preflight went through the standby" "$(calls)" "dgmgrl /@STB | show fast_start failover"
assert_eq "no FSFO preflight through the primary" "0" "$(count_calls 'dgmgrl /@PRI | show fast_start failover')"

reset_env
make_wallet
run_obs "" STUB_DOWN_ALIASES=PRI -- start -n
assert_eq "start -n, primary down (ORA-12541): exit 0" "0" "$RC"
assert_contains "start -n, primary down: the ORA- line is shown" "$OUT" "ORA-12541"
assert_contains "start -n, primary down: standby chosen" "$OUT" "dgmgrl /@STB \"START OBSERVER"

reset_env
make_wallet
run_obs "" "STUB_DOWN_ALIASES=PRI STB" -- start -n
assert_eq "start, both members down: exit 1" "1" "$RC"
assert_contains "start, both down: both aliases named" "$OUT" "Neither broker member answered through the wallet: PRI, STB"

reset_env
make_wallet
run_obs "" STUB_HANG_ALIASES=PRI DG_OBSERVER_CONNECT_TIMEOUT=x -- start -n
assert_eq "malformed DG_OBSERVER_CONNECT_TIMEOUT: exit 2" "2" "$RC"

if $PS_OK; then
    reset_env
    make_wallet
    run_obs "" STUB_HANG_ALIASES=PRI DG_OBSERVER_CONNECT_TIMEOUT=2 -- start
    assert_eq "start, primary hanging: exit 0" "0" "$RC"
    assert_contains "observer launched through the standby alias" "$(calls)" "dgmgrl /@STB | START OBSERVER"
    assert_eq "no launch through the primary alias" "0" "$(count_calls 'dgmgrl /@PRI | START OBSERVER')"
    assert_contains "presence polled through the standby" "$(calls)" "sqlplus /@STB | present"
    if [[ $ELAPSED -le 20 ]]; then pass "start within the bound (${ELAPSED}s)"; else fail "start within the bound (${ELAPSED}s)"; fi
    LAUNCHED=$(sed -n 's/^[^:]*://p' "$PIDFILE" 2>/dev/null)
    [[ -n "$LAUNCHED" ]] && BG_PIDS="$BG_PIDS $LAUNCHED"

    run_obs "" STUB_HANG_ALIASES=PRI DG_OBSERVER_CONNECT_TIMEOUT=2 -- stop
    assert_eq "stop, primary hanging: exit 0" "0" "$RC"
    assert_contains "STOP OBSERVER sent through the standby alias" "$(calls)" "dgmgrl /@STB | STOP OBSERVER"
    if [[ -e "$PIDFILE" ]]; then fail "stop removed the pidfile"; else pass "stop removed the pidfile"; fi
else
    skip "start/stop through the standby alias with a live process (ps not usable here)"
fi

# ------------------------------------------------------------
echo ""
echo "Test 4: setup proves the wallet login on both aliases"
# ------------------------------------------------------------

reset_env
run_obs "wpw\nwpw\nopw\n" STUB_BAD_ALIASES=STB -- setup
assert_eq "standby ORA-01017 (exit 1): setup exits 1" "1" "$RC"
assert_not_contains "standby ORA-01017: no SUCCESS summary" "$OUT" "SUCCESS:"
assert_not_contains "standby ORA-01017: no completion banner" "$OUT" "WALLET SETUP COMPLETE"
assert_contains "standby ORA-01017: failing alias and Oracle error named" "$OUT" "STB: dgmgrl: ORA-01017"
assert_contains "no previous wallet: undo command printed" "$OUT" "to undo: rm -rf"
assert_contains "the primary was tested too" "$(calls)" "sqlplus /@PRI | identity"

reset_env
make_wallet
run_obs "y\nRECREATE WALLET\nwpw\nwpw\nopw\n" STUB_BAD_ALIASES=STB STUB_BAD_RC=0 -- setup
assert_eq "standby ORA-01017 with exit 0: setup exits 1" "1" "$RC"
assert_not_contains "exit-0 ORA-01017: no SUCCESS summary" "$OUT" "SUCCESS:"
BACKUP=$(ls -d "$WALLET".bak.* 2>/dev/null | head -1)
if [[ -n "$BACKUP" && -f "$BACKUP/ewallet.p12" ]]; then pass "previous wallet kept as a backup"; else fail "previous wallet kept as a backup"; fi
assert_contains "restore command printed with the backup path" "$OUT" "mv ${BACKUP} ${WALLET}"
assert_contains "backup location stated" "$OUT" "before this run is at: ${BACKUP}"

reset_env
run_obs "wpw\nwpw\nopw\n" STUB_SQLPLUS_ERR_ALIASES=STB -- setup
assert_eq "identity query prints SP2- but exits 0: setup exits 1" "1" "$RC"
assert_contains "the SP2- line is shown" "$OUT" "SP2-0306"
assert_not_contains "SP2- with exit 0: no SUCCESS summary" "$OUT" "SUCCESS:"

reset_env
run_obs "wpw\nwpw\nopw\n" STUB_IDENT=SYS -- setup
assert_eq "wallet authenticates as SYS: setup exits 1" "1" "$RC"
assert_contains "SYS identity named" "$OUT" "authenticated as SYS, not the observer user DG_OBSERVER"

reset_env
run_obs "wpw\nwpw\nopw\n" -- setup
assert_eq "both aliases log in as the observer: exit 0" "0" "$RC"
assert_contains "positive path keeps its SUCCESS summary" "$OUT" "SUCCESS: Observer wallet configured"
assert_contains "positive path: primary identity proven" "$(calls)" "sqlplus /@PRI | identity"
assert_contains "positive path: standby identity proven" "$(calls)" "sqlplus /@STB | identity"
assert_eq "positive path: one credential per alias" "2" "$(count_calls 'createCredential')"
if [[ -f "$WALLET/cwallet.sso" ]]; then pass "positive path: wallet activated"; else fail "positive path: wallet activated"; fi
assert_contains "positive path: sqlnet.ora names the wallet" "$(cat "$TNS/sqlnet.ora" 2>/dev/null)" "DIRECTORY = $WALLET"
assert_eq "positive path: staging directory gone" "" "$(ls "$RUNTMP" 2>/dev/null)"

# Keeping an existing wallet that does not work, and declining the update,
# is not a completed setup either.
reset_env
make_wallet
run_obs "n\nn\n" STUB_BAD_ALIASES=STB -- setup
assert_eq "kept wallet failing on the standby, update declined: exit 1" "1" "$RC"
assert_eq "kept wallet, update declined: no mkstore" "0" "$(count_calls '^mkstore')"

# ------------------------------------------------------------
echo ""
echo "Test 5: no private staging directory = no mkstore"
# ------------------------------------------------------------

reset_env
OUT=$(printf 'wpw\nwpw\nopw\n' | env HOME="$WORK" PATH="$WORK/badmk:$OH/bin:$PATH" TMPDIR="$WORK/rotmp" \
    ORACLE_HOME="$OH" NFS_SHARE="$SHARE" WALLET_DIR="$WALLET" TNS_ADMIN="$TNS" \
    OBSERVER_DIR="$OBSDIR" NO_COLOR=1 STUB_LOG="$CALLS" STUB_STATE="$STATE" \
    "$BASH_BIN" "$OBS" setup 2>&1)
RC=$?
assert_eq "mktemp failing + unusable TMPDIR: exit 1" "1" "$RC"
assert_eq "mktemp failing: no mkstore call" "0" "$(count_calls '^mkstore')"
assert_contains "mktemp failing: staging failure explained" "$OUT" "Could not create a private staging directory"
assert_not_contains "mktemp failing: no password prompt" "$OUT" "Enter wallet password"
if [[ -e "$WALLET" ]]; then fail "mktemp failing: no wallet directory"; else pass "mktemp failing: no wallet directory"; fi

reset_env
OUT=$(printf 'wpw\nwpw\nopw\n' | env HOME="$WORK" PATH="$OH/bin:$WORK/nomk" TMPDIR="$WORK/rotmp" \
    ORACLE_HOME="$OH" NFS_SHARE="$SHARE" WALLET_DIR="$WALLET" TNS_ADMIN="$TNS" \
    OBSERVER_DIR="$OBSDIR" NO_COLOR=1 STUB_LOG="$CALLS" STUB_STATE="$STATE" \
    "$BASH_BIN" "$OBS" setup 2>&1)
RC=$?
assert_eq "no mktemp + unusable TMPDIR: exit 1" "1" "$RC"
assert_eq "no mktemp: no mkstore call" "0" "$(count_calls '^mkstore')"

# The fallback itself still works where it can: no mktemp, writable TMPDIR
reset_env
OUT=$(printf 'wpw\nwpw\nopw\n' | env HOME="$WORK" PATH="$OH/bin:$WORK/nomk" TMPDIR="$RUNTMP" \
    ORACLE_HOME="$OH" NFS_SHARE="$SHARE" WALLET_DIR="$WALLET" TNS_ADMIN="$TNS" \
    OBSERVER_DIR="$OBSDIR" NO_COLOR=1 STUB_LOG="$CALLS" STUB_STATE="$STATE" \
    "$BASH_BIN" "$OBS" setup 2>&1)
RC=$?
assert_eq "no mktemp, writable TMPDIR: setup completes" "0" "$RC"
assert_contains "no mktemp: wallet staged under TMPDIR" "$(calls)" "mkstore -wrl $RUNTMP/"
assert_eq "no mktemp: staging directory cleaned up" "" "$(ls "$RUNTMP" 2>/dev/null)"

echo ""
echo "============================================================"
echo "Test Summary: $PASS passed, $FAIL failed, $SKIP skipped"
echo "============================================================"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
