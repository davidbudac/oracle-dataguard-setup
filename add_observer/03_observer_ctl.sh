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
#   restart  stop + start.
#   status   Broker's view (SHOW OBSERVER / SHOW FAST_START FAILOVER,
#            V$DATABASE observer columns) plus the local process.
#   log      Show (or follow) the observer's own log file.
#   boot     Print a systemd unit and a cron @reboot line that restart
#            the observer after a reboot - nothing else will.
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

DG_CONN="/@${PRIMARY_TNS_ALIAS}"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

# The observer runs as a detached dgmgrl process on THIS host. Matching on
# the connect string keeps other dgmgrl sessions (yours, a colleague's) out
# of the result.
local_observer_pids() {
    ps -eo pid,args 2>/dev/null \
        | grep -i 'dgmgrl' \
        | grep -i -- "@${PRIMARY_TNS_ALIAS}" \
        | grep -iv 'grep' \
        | awk '{print $1}' || true
}

observer_present() {
    # V$DATABASE is authoritative: FS_FAILOVER_OBSERVER_PRESENT is what the
    # primary itself sees, not what a local process table suggests.
    local out
    out=$("$SQLPLUS" -s -L "/@${PRIMARY_TNS_ALIAS}" as sysdg <<EOF 2>/dev/null || true
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

# ============================================================
# Commands
# ============================================================

do_start() {
    log_section "Starting the FSFO Observer"

    if [[ "$(observer_present)" == "YES" ]]; then
        log_warn "The broker already reports an observer as present."
        log_info "Where it runs:"
        run_dgmgrl "$DG_CONN" "SHOW OBSERVER;" | sed 's/^/    /' || true
        log_info "Use '$(basename "$0") restart' to replace it, or 'status' to inspect."
        exit 0
    fi

    if ! fsfo_enabled; then
        log_warn "Fast-Start Failover is DISABLED on this configuration."
        log_warn "The observer will register and idle, but it will never fail over."
        log_warn "Enable it on the primary: ./01_prepare_primary.sh --enable-fsfo"
    fi

    mkdir -p "$OBSERVER_DIR"
    chmod 700 "$OBSERVER_DIR" 2>/dev/null || true
    log_info "Observer files: ${OBSERVER_DIR}"
    log_info "Connect identifier: ${PRIMARY_TNS_ALIAS}   (auto-login wallet, TNS_ADMIN=${TNS_ADMIN})"

    # CONNECT IDENTIFIER IS is mandatory with IN BACKGROUND: the detached
    # observer opens its own connection rather than inheriting this dgmgrl
    # session's, and the command is rejected without it.
    local named_cmd unnamed_cmd out
    named_cmd="START OBSERVER ${OBSERVER_NAME} IN BACKGROUND FILE IS '${OBSERVER_DAT}' LOGFILE IS '${OBSERVER_LOG}' CONNECT IDENTIFIER IS ${PRIMARY_TNS_ALIAS};"
    unnamed_cmd="START OBSERVER IN BACKGROUND FILE IS '${OBSERVER_DAT}' LOGFILE IS '${OBSERVER_LOG}' CONNECT IDENTIFIER IS ${PRIMARY_TNS_ALIAS};"

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
    local i present=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        sleep 5
        present=$(observer_present)
        [[ "$present" == "YES" ]] && break
    done

    if [[ "$present" == "YES" ]]; then
        log_info "Observer is present (V\$DATABASE.FS_FAILOVER_OBSERVER_PRESENT = YES)."
        run_dgmgrl "$DG_CONN" "SHOW OBSERVER;" | sed 's/^/    /' || true
    else
        log_warn "The broker does not report the observer yet."
        log_warn "Check the observer's own log: ${OBSERVER_LOG}"
        log_warn "Then re-check with: $(basename "$0") status"
        exit 1
    fi

    printf '\n'
    log_info "The observer does NOT survive a reboot on its own."
    log_info "Run '$(basename "$0") boot' for a systemd unit / cron line."
}

do_stop() {
    log_section "Stopping the FSFO Observer"

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

do_status() {
    log_section "Broker: SHOW CONFIGURATION"
    run_dgmgrl "$DG_CONN" "SHOW CONFIGURATION;" | sed 's/^/  /' || true

    log_section "Broker: SHOW FAST_START FAILOVER"
    run_dgmgrl "$DG_CONN" "SHOW FAST_START FAILOVER;" | sed 's/^/  /' || true

    log_section "Broker: SHOW OBSERVER"
    run_dgmgrl "$DG_CONN" "SHOW OBSERVER;" | sed 's/^/  /' || true

    log_section "Primary: V\$DATABASE Observer Columns"
    "$SQLPLUS" -s -L "/@${PRIMARY_TNS_ALIAS}" as sysdg <<EOF 2>&1 | grep -E '^FS_' | sed 's/^/  /' || log_warn "Could not query V\$DATABASE."
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
        log_warn "No local dgmgrl process connected to @${PRIMARY_TNS_ALIAS} on this host."
        log_warn "If the broker reports an observer above, it is running somewhere ELSE."
    fi
    [[ -f "$OBSERVER_LOG" ]] && log_info "Observer log: ${OBSERVER_LOG}" || log_warn "No observer log at ${OBSERVER_LOG}"

    log_section "Verdict"
    if [[ "$(observer_present)" == "YES" ]]; then
        log_info "Observer is PRESENT."
        exit 0
    fi
    log_error "Observer is NOT present."
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

--- Option B: cron (any platform, incl. AIX) ---------------
As ${user}:

  crontab -e

  @reboot ORACLE_HOME=${ORACLE_HOME} TNS_ADMIN=${TNS_ADMIN} ${me} start >> ${OBSERVER_DIR}/boot.log 2>&1

--- Monitoring (do this either way) ------------------------
Neither option restarts an observer that dies while the host stays up.
A five-minute watchdog closes that gap:

  */5 * * * * ORACLE_HOME=${ORACLE_HOME} TNS_ADMIN=${TNS_ADMIN} ${me} status >/dev/null 2>&1 || ORACLE_HOME=${ORACLE_HOME} TNS_ADMIN=${TNS_ADMIN} ${me} start >> ${OBSERVER_DIR}/watchdog.log 2>&1

'status' exits 0 only when the primary reports the observer present, so
it is safe to drive a restart from.

Alert on a missing observer too - with FSFO enabled, losing the observer
AND the standby together stalls the primary:

  select fs_failover_observer_present from v\$database;   -- expect YES

============================================================

EOF
}

case "$COMMAND" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_stop; printf '\n'; do_start ;;
    status)  do_status ;;
    log)     do_log ;;
    boot)    do_boot ;;
esac
