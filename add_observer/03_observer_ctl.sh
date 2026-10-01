#!/usr/bin/env bash
# ============================================================
# Add an FSFO observer on a third host - Step 3 (run on the OBSERVER host)
# ============================================================
# Lifecycle management for the observer process on this host.
#
#   start    Start the observer detached (dgmgrl START OBSERVER ...
#            IN BACKGROUND), then wait for the broker to report it.
#   stop     Ask the broker to stop it, then clean up any local
#            leftover dgmgrl process.
#   restart  stop, wait until the broker no longer lists this observer,
#            then start.
#   status   Broker's view (SHOW OBSERVER / SHOW FAST_START FAILOVER,
#            V$DATABASE observer columns) plus the local process.
#   log      Show (or follow) the observer's own log file.
#   boot     Print what restarts the observer after a reboot - nothing
#            else will: a systemd unit or cron @reboot line (Linux), an
#            inittab entry or rc2.d script (AIX, whose cron has no @reboot),
#            and a watchdog cron line for all platforms.
#
# Settings come from ./observer_env.sh (written by 01_prepare_primary.sh)
# and can be overridden by the flags below. Authentication is the
# auto-login wallet built by 02_setup_observer_host.sh: no password is
# read, stored or passed anywhere here.
#
# Usage:
#   ./03_observer_ctl.sh start|stop|restart|status|log|boot [options]
#
# Exit codes: 0 success, 1 fatal / observer not present, 2 bad arguments
# ============================================================

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

if [[ -f "${SCRIPT_DIR}/observer_env.sh" ]]; then
    source "${SCRIPT_DIR}/observer_env.sh"
fi

COMMAND=""
FOLLOW_LOG=false
TNS_ADMIN_DIR=""

usage() {
    cat <<EOF
Usage: $(basename "$0") {start|stop|restart|status|log|boot} [options]

Options:
      --primary-tns A    TNS alias for the primary (default from observer_env.sh)
      --observer-name N  Registered observer name  (default from observer_env.sh)
      --observer-dir D   Directory for the observer's .dat and .log files
                         (default: \$HOME/fsfo_observer)
      --tns-admin DIR    TNS_ADMIN to use (default: \$TNS_ADMIN or
                         \$ORACLE_HOME/network/admin)
  -f, --follow           'log' only: follow the log (tail -f)
  -h, --help             Show this help
EOF
}

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
COMMAND="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --primary-tns)   [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                         PRIMARY_TNS_ALIAS="$2"; shift 2 ;;
        --observer-name) [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                         OBSERVER_NAME="$2"; shift 2 ;;
        --observer-dir)  [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                         OBSERVER_DIR="$2"; shift 2 ;;
        --tns-admin)     [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                         TNS_ADMIN_DIR="$2"; shift 2 ;;
        -f|--follow)     FOLLOW_LOG=true; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
done

case "$COMMAND" in
    start|stop|restart|status|log|boot) ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown command: ${COMMAND}"; usage >&2; exit 2 ;;
esac

# ============================================================
# Settings
# ============================================================

check_oracle_env
DGMGRL="$ORACLE_HOME/bin/dgmgrl"
SQLPLUS="$ORACLE_HOME/bin/sqlplus"
[[ -x "$DGMGRL" ]] || die "dgmgrl not found: ${DGMGRL}"

TNS_ADMIN_DIR="${TNS_ADMIN_DIR:-${TNS_ADMIN:-$ORACLE_HOME/network/admin}}"
export TNS_ADMIN="$TNS_ADMIN_DIR"

if [[ -z "${PRIMARY_TNS_ALIAS:-}" ]]; then
    prompt_with_default PRIMARY_TNS_ALIAS "TNS alias for the PRIMARY" ""
    [[ -n "$PRIMARY_TNS_ALIAS" ]] || die "The primary TNS alias is required (--primary-tns)."
fi

PRIMARY_DB_UNIQUE_NAME="${PRIMARY_DB_UNIQUE_NAME:-$PRIMARY_TNS_ALIAS}"
OBSERVER_NAME="${OBSERVER_NAME:-obs_$(printf '%s' "$PRIMARY_DB_UNIQUE_NAME" | tr '[:upper:]' '[:lower:]')}"
OBSERVER_DIR="${OBSERVER_DIR:-$HOME/fsfo_observer}"
OBSERVER_DAT="${OBSERVER_DIR}/fsfo_${PRIMARY_DB_UNIQUE_NAME}.dat"
OBSERVER_LOG="${OBSERVER_DIR}/fsfo_${PRIMARY_DB_UNIQUE_NAME}.log"

# CONNECT_ALIAS is the alias every broker/SQL call goes through. It starts as
# the primary's; select_connection() switches it to the standby's when the
# primary does not answer (after a failover with the old primary down).
CONNECT_ALIAS="$PRIMARY_TNS_ALIAS"
DG_CONN="/@${CONNECT_ALIAS}"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

# The observer runs as a detached dgmgrl process on THIS host. Matching on
# the connect string keeps other dgmgrl sessions (yours, a colleague's) out
# of the result. Whether the detached process's argv carries "@<alias>" is not
# something every dgmgrl release guarantees, so its .dat / .log paths
# (unique to this configuration) match as well. Both the
# primary and standby aliases count: after a failover the observer may have
# been started through either.
local_observer_pids() {
    ps -eo pid,args 2>/dev/null \
        | grep -i 'dgmgrl' \
        | grep -iv 'grep' \
        | awk -v a1="@${PRIMARY_TNS_ALIAS}" -v a2="${STANDBY_TNS_ALIAS:+@$STANDBY_TNS_ALIAS}" \
              -v f1="$OBSERVER_DAT" -v f2="$OBSERVER_LOG" '
            function has(l, p) { return p != "" && index(l, tolower(p)) > 0 }
            { l = tolower($0); if (has(l, a1) || has(l, a2) || has(l, f1) || has(l, f2)) print $1 }
        ' || true
}

observer_present() {
    # V$DATABASE is authoritative: FS_FAILOVER_OBSERVER_PRESENT is what the
    # primary itself sees, not what a local process table suggests.
    local out
    out=$("$SQLPLUS" -s -L "/@${CONNECT_ALIAS}" as sysdg <<EOF 2>/dev/null || true
set pagesize 0 heading off feedback off
select 'PRESENT=' || fs_failover_observer_present from v\$database;
exit
EOF
    )
    printf '%s\n' "$out" | sed -n 's/^PRESENT=//p' | tr -d ' \r' | head -1
}

fsfo_enabled() {
    run_dgmgrl "$DG_CONN" "SHOW FAST_START FAILOVER;" \
        | grep -qiE 'Fast-Start Failover:[[:space:]]*Enabled'
}

# select_connection: use the primary alias unless it does not answer, then
# the standby alias. Without this, once the old primary is down after a
# failover, status exits 1 and the watchdog re-runs start every 5 minutes
# against an alias that can never connect. Either member can run SHOW
# OBSERVER / START OBSERVER, and V$DATABASE.FS_FAILOVER_OBSERVER_PRESENT is
# populated on both.
select_connection() {
    local probe
    probe=$(run_dgmgrl "$DG_CONN" "SHOW CONFIGURATION;" || true)
    printf '%s\n' "$probe" | grep -q 'Configuration -' && return 0
    [[ -n "${STANDBY_TNS_ALIAS:-}" && "$STANDBY_TNS_ALIAS" != "$CONNECT_ALIAS" ]] || return 0
    probe=$(run_dgmgrl "/@${STANDBY_TNS_ALIAS}" "SHOW CONFIGURATION;" || true)
    if printf '%s\n' "$probe" | grep -q 'Configuration -'; then
        log_warn "'${CONNECT_ALIAS}' did not answer; using the standby alias '${STANDBY_TNS_ALIAS}' (failed over?)."
        CONNECT_ALIAS="$STANDBY_TNS_ALIAS"
        DG_CONN="/@${CONNECT_ALIAS}"
    fi
    return 0
}

# this_observer_registered: 0 when the broker lists an observer that is THIS
# one - by registered name, else by host name (SHOW OBSERVER prints
# 'Observer "<name>" - Master|Backup' followed by 'Host Name: <host>').
# OBS_LIST_PARSED is set to false when the output holds no observer entry at
# all (broker down, or a release with a different format); callers then fall
# back to the primary's any-observer flag instead of guessing.
OBS_LIST_PARSED=false
this_observer_registered() {
    local out names hosts n h me me_short
    OBS_LIST_PARSED=false
    out=$(run_dgmgrl "$DG_CONN" "SHOW OBSERVER;" || true)
    names=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*Observer[[:space:]]*"\([^"]*\)".*/\1/p' | tr -d '\r' | tr '[:upper:]' '[:lower:]')
    hosts=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*Host Name:[[:space:]]*//p' | tr -d ' \r' | tr '[:upper:]' '[:lower:]')
    [[ -n "$names" || -n "$hosts" ]] || return 1
    OBS_LIST_PARSED=true

    if [[ -n "$OBSERVER_NAME" ]]; then
        me=$(printf '%s' "$OBSERVER_NAME" | tr '[:upper:]' '[:lower:]')
        for n in $names; do
            [[ "$n" == "$me" ]] && return 0
        done
    fi
    me=$(hostname 2>/dev/null | tr -d ' \r' | tr '[:upper:]' '[:lower:]')
    me_short="${me%%.*}"
    [[ -n "$me" ]] || return 1
    for h in $hosts; do
        [[ "$h" == "$me" || "${h%%.*}" == "$me_short" ]] && return 0
    done
    return 1
}

# observer_up_here: this observer is registered with the broker; when the
# listing cannot be parsed, the primary's any-observer flag is the best
# remaining evidence.
observer_up_here() {
    this_observer_registered && return 0
    $OBS_LIST_PARSED && return 1
    [[ "$(observer_present)" == "YES" ]]
}

# ============================================================
# Commands
# ============================================================

do_start() {
    log_section "Starting the FSFO Observer"

    select_connection

    # Presence is judged for THIS observer (name, else host), not for "any
    # observer": on 12.2+ up to three may be registered, and one running
    # elsewhere must not stop this host from adding its own.
    if observer_up_here; then
        log_warn "The broker already lists this observer (${OBSERVER_NAME:-unnamed} on $(hostname 2>/dev/null))."
        log_info "Registered observers:"
        run_dgmgrl "$DG_CONN" "SHOW OBSERVER;" | sed 's/^/    /' || true
        log_info "Use '$(basename "$0") restart' to replace it, or 'status' to inspect."
        exit 0
    fi
    if $OBS_LIST_PARSED && [[ "$(observer_present)" == "YES" ]]; then
        log_info "Another observer is already registered (listing below); this host will add its own."
        run_dgmgrl "$DG_CONN" "SHOW OBSERVER;" | sed 's/^/    /' || true
    fi

    if ! fsfo_enabled; then
        log_warn "Fast-Start Failover is DISABLED on this configuration."
        log_warn "The observer will register and idle, but it will never fail over."
        log_warn "Enable it on the primary: ./01_prepare_primary.sh --enable-fsfo"
    fi

    mkdir -p "$OBSERVER_DIR"
    chmod 700 "$OBSERVER_DIR" 2>/dev/null || true
    log_info "Observer files: ${OBSERVER_DIR}"
    log_info "Connect identifier: ${CONNECT_ALIAS}   (auto-login wallet, TNS_ADMIN=${TNS_ADMIN})"

    # CONNECT IDENTIFIER IS is mandatory with IN BACKGROUND: the detached
    # observer opens its own connection rather than inheriting this dgmgrl
    # session's, and the command is rejected without it.
    local named_cmd unnamed_cmd out
    named_cmd="START OBSERVER ${OBSERVER_NAME} IN BACKGROUND FILE IS '${OBSERVER_DAT}' LOGFILE IS '${OBSERVER_LOG}' CONNECT IDENTIFIER IS ${CONNECT_ALIAS};"
    unnamed_cmd="START OBSERVER IN BACKGROUND FILE IS '${OBSERVER_DAT}' LOGFILE IS '${OBSERVER_LOG}' CONNECT IDENTIFIER IS ${CONNECT_ALIAS};"

    log_info "Starting observer '${OBSERVER_NAME}'..."
    out=$(run_dgmgrl "$DG_CONN" "$named_cmd" || true)
    printf '%s\n' "$out" | sed 's/^/    /'

    if dgmgrl_failed "$out"; then
        # Named observers need a 12.2+ broker configuration. On an older
        # configuration the name is a syntax error, so retry without it
        # rather than leaving the user with no observer at all.
        log_warn "Named START OBSERVER failed - retrying without a name (pre-12.2 configuration?)."
        out=$(run_dgmgrl "$DG_CONN" "$unnamed_cmd" || true)
        printf '%s\n' "$out" | sed 's/^/    /'
        if dgmgrl_failed "$out"; then
            log_error "START OBSERVER failed. Check ${OBSERVER_LOG} and the broker output above."
            exit 1
        fi
        OBSERVER_NAME=""
    fi

    log_info "Waiting for the broker to report the observer (up to 60s)..."
    local i up=false
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        sleep 5
        if observer_up_here; then up=true; break; fi
    done

    if $up; then
        log_info "Observer is registered with the broker."
        run_dgmgrl "$DG_CONN" "SHOW OBSERVER;" | sed 's/^/    /' || true
    else
        log_warn "The broker does not report the observer yet."
        log_warn "Check the observer's own log: ${OBSERVER_LOG}"
        log_warn "Then re-check with: $(basename "$0") status"
        exit 1
    fi

    printf '\n'
    log_info "The observer does NOT survive a reboot on its own."
    log_info "Run '$(basename "$0") boot' for a systemd unit / cron / AIX init entry."
}

do_stop() {
    log_section "Stopping the FSFO Observer"

    select_connection

    local out
    if [[ -n "$OBSERVER_NAME" ]]; then
        out=$(run_dgmgrl "$DG_CONN" "STOP OBSERVER ${OBSERVER_NAME};" || true)
        if dgmgrl_failed "$out" && ! printf '%s\n' "$out" | grep -q 'ORA-16877'; then
            log_warn "STOP OBSERVER ${OBSERVER_NAME} failed - retrying without the name."
            out=$(run_dgmgrl "$DG_CONN" "STOP OBSERVER;" || true)
        fi
    else
        out=$(run_dgmgrl "$DG_CONN" "STOP OBSERVER;" || true)
    fi
    printf '%s\n' "$out" | sed 's/^/    /'

    if printf '%s\n' "$out" | grep -q 'ORA-16877'; then
        log_info "No observer was registered - nothing to stop."
    elif dgmgrl_failed "$out"; then
        log_warn "The broker could not stop the observer cleanly (it may already be gone)."
    else
        log_info "Broker reports the observer stopped."
    fi

    # A dgmgrl observer that lost the broker can linger locally.
    local pids
    pids=$(local_observer_pids)
    if [[ -n "$pids" ]]; then
        log_warn "Local dgmgrl observer processes still running: ${pids}"
        if confirm_proceed "Kill them?"; then
            # shellcheck disable=SC2086
            kill $pids 2>/dev/null || true
            sleep 2
            pids=$(local_observer_pids)
            # shellcheck disable=SC2086
            [[ -n "$pids" ]] && { log_warn "Forcing: ${pids}"; kill -9 $pids 2>/dev/null || true; }
            log_info "Local processes cleaned up."
        fi
    fi

    printf '\n'
    log_warn "With no observer running, automatic failover cannot happen."
    log_warn "The databases keep running normally; a primary loss now needs a manual failover."
}

# restart: STOP OBSERVER returns before the broker has dropped the observer.
# Starting at once would find it still listed and no-op, so wait (bounded)
# until it is gone.
do_restart() {
    local i
    do_stop
    printf '\n'
    log_info "Waiting for the broker to drop this observer (up to 30s)..."
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        observer_up_here || break
        sleep 2
    done
    if observer_up_here; then
        log_error "The broker still lists this observer after 30s - not starting a second one."
        log_error "Check '$(basename "$0") status'; stop it by hand if needed, then run 'start'."
        exit 1
    fi
    do_start
}

do_status() {
    select_connection

    log_section "Broker: SHOW CONFIGURATION"
    run_dgmgrl "$DG_CONN" "SHOW CONFIGURATION;" | sed 's/^/  /' || true

    log_section "Broker: SHOW FAST_START FAILOVER"
    run_dgmgrl "$DG_CONN" "SHOW FAST_START FAILOVER;" | sed 's/^/  /' || true

    log_section "Broker: SHOW OBSERVER"
    run_dgmgrl "$DG_CONN" "SHOW OBSERVER;" | sed 's/^/  /' || true

    log_section "Primary: V\$DATABASE Observer Columns"
    "$SQLPLUS" -s -L "/@${CONNECT_ALIAS}" as sysdg <<EOF 2>&1 | grep -E '^FS_' | sed 's/^/  /' || log_warn "Could not query V\$DATABASE."
set pagesize 0 heading off feedback off linesize 200
select 'FS_FAILOVER_STATUS           = ' || fs_failover_status           from v\$database;
select 'FS_FAILOVER_OBSERVER_PRESENT = ' || fs_failover_observer_present from v\$database;
select 'FS_FAILOVER_OBSERVER_HOST    = ' || fs_failover_observer_host    from v\$database;
select 'FS_FAILOVER_CURRENT_TARGET   = ' || fs_failover_current_target   from v\$database;
select 'FS_FAILOVER_THRESHOLD        = ' || fs_failover_threshold        from v\$database;
exit
EOF

    log_section "This Host"
    local pids
    pids=$(local_observer_pids)
    if [[ -n "$pids" ]]; then
        log_info "Local observer dgmgrl process(es): ${pids}"
        ps -o pid,etime,args -p $(printf '%s' "$pids" | tr '\n' ',' | sed 's/,$//') 2>/dev/null | sed 's/^/  /' || true
    else
        log_warn "No local observer dgmgrl process (@${PRIMARY_TNS_ALIAS}) found on this host."
        log_warn "If the broker reports an observer above, it is running somewhere ELSE."
    fi
    [[ -f "$OBSERVER_LOG" ]] && log_info "Observer log: ${OBSERVER_LOG}" || log_warn "No observer log at ${OBSERVER_LOG}"

    log_section "Verdict"
    if observer_up_here; then
        log_info "This observer is PRESENT."
        exit 0
    fi
    if [[ "$(observer_present)" == "YES" ]]; then
        log_warn "The broker reports an observer, but none registered as '${OBSERVER_NAME}' / this host."
    fi
    log_error "This observer is NOT present."
    exit 1
}

do_log() {
    [[ -f "$OBSERVER_LOG" ]] || die "No observer log at ${OBSERVER_LOG} (was the observer ever started from this host?)"
    if $FOLLOW_LOG; then
        tail -f "$OBSERVER_LOG"
    else
        tail -n 60 "$OBSERVER_LOG"
    fi
}

do_boot() {
    local me="${SCRIPT_DIR}/$(basename "$0")"
    local user; user=$(id -un)
    # Literal values, expanded now: neither cron nor init has this shell's
    # environment, and non-login ssh/cron skip .profile. LIBPATH is the AIX
    # library path, LD_LIBRARY_PATH the Linux one; dgmgrl needs the right one.
    local envs="ORACLE_HOME=${ORACLE_HOME} TNS_ADMIN=${TNS_ADMIN} LIBPATH=${ORACLE_HOME}/lib LD_LIBRARY_PATH=${ORACLE_HOME}/lib"
    cat <<EOF

============================================================
SURVIVING A REBOOT
============================================================

A background observer is an ordinary detached dgmgrl process. Nothing in
Oracle restarts it - after a reboot of this host the configuration keeps
running with NO observer, and no automatic failover, until someone starts
it again. Install one of these.

--- Option A: systemd (Linux, preferred) -------------------
Write /etc/systemd/system/dg-observer-${PRIMARY_DB_UNIQUE_NAME}.service as root:

[Unit]
Description=Oracle Data Guard FSFO observer for ${PRIMARY_DB_UNIQUE_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${user}
Environment=ORACLE_HOME=${ORACLE_HOME}
Environment=TNS_ADMIN=${TNS_ADMIN}
Environment=LD_LIBRARY_PATH=${ORACLE_HOME}/lib
ExecStart=${me} start
ExecStop=${me} stop
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target

Then:

  sudo systemctl daemon-reload
  sudo systemctl enable --now dg-observer-${PRIMARY_DB_UNIQUE_NAME}

(Type=oneshot + RemainAfterExit is deliberate: 'START OBSERVER IN
BACKGROUND' returns immediately and the real observer is a detached
child, so systemd must not treat the exit as a crash. It gives you
start-at-boot, not process supervision - pair it with the monitoring
below.)

--- Option B: cron @reboot (Linux / vixie-style cron only) --
AIX cron has no @reboot - use Option C there.
As ${user}:

  crontab -e

  @reboot ${envs} ${me} start >> ${OBSERVER_DIR}/boot.log 2>&1

--- Option C: AIX (init) -----------------------------------
AIX cron supports neither @reboot nor */N steps. Start the observer from
init instead. As root, either an inittab entry (preferred - 'once' means init
does not wait for the ~60s 'start'):

  mkitab "dgobs:2:once:/usr/bin/su - ${user} -c '${envs} ${me} start' >/dev/console 2>&1"

(remove it later with: rmitab dgobs), or an rc script - /etc/rc.d/rc2.d/S99dgobserver,
mode 755, owned by root:

  #!/bin/ksh
  case "\$1" in
  start) /usr/bin/su - ${user} -c "${envs} ${me} start >> ${OBSERVER_DIR}/boot.log 2>&1" ;;
  stop)  /usr/bin/su - ${user} -c "${envs} ${me} stop >> ${OBSERVER_DIR}/boot.log 2>&1" ;;
  esac

--- Monitoring (do this either way) ------------------------
Neither option restarts an observer that dies while the host stays up.
A five-minute watchdog closes that gap. The minute list is spelled out
because AIX cron rejects */5; it is valid everywhere:

  0,5,10,15,20,25,30,35,40,45,50,55 * * * * ${envs} ${me} status >/dev/null 2>&1 || ${envs} ${me} start >> ${OBSERVER_DIR}/watchdog.log 2>&1

'status' exits 0 only when the broker lists THIS observer (by name or host; it
falls back to the standby alias when the primary is down), so it is safe
to drive a restart from.

Alert on a missing observer too - with FSFO enabled, losing the observer
AND the standby together stalls the primary:

  select fs_failover_observer_present from v\$database;   -- expect YES

============================================================

EOF
}

case "$COMMAND" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_restart ;;
    status)  do_status ;;
    log)     do_log ;;
    boot)    do_boot ;;
esac
