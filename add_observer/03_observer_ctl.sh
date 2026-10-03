#!/usr/bin/env bash
# ============================================================
# Add an FSFO observer on a third host - Step 3 (run on the OBSERVER host)
# ============================================================
# Lifecycle management for the observer process on this host.
#
#   start    Start the observer detached (dgmgrl START OBSERVER ...
#            IN BACKGROUND), then wait until it is live (below). A
#            registered-but-dead observer is restarted with its existing
#            state file.
#   stop     Ask the broker to stop it, then clean up any local
#            leftover dgmgrl process.
#   restart  stop, wait until the broker no longer lists this observer,
#            then start.
#   status   Broker's view (SHOW OBSERVER / SHOW FAST_START FAILOVER,
#            V$DATABASE observer columns) plus the local process, and
#            whether THIS observer is live.
#
# "Live" is more than "registered": the broker keeps a crashed observer
# listed. This observer is live only when (a) SHOW OBSERVER lists it (by
# name, else by host), (b) ITS OWN block's 'Last Ping to Primary' is at most
# DG_OBS_MAX_PING_AGE seconds old (default 60; when the primary alias does
# not answer, the fresher of its primary/target pings), and (c) the dgmgrl
# process recorded in its pidfile is still running (checked when a pidfile
# exists and ps is available).
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
# Environment: DG_OBS_MAX_PING_AGE  ping age limit in seconds (default 60)
#
# Exit codes: 0 success, 1 fatal / observer not live, 2 bad arguments
#             (including an invalid DG_OBS_MAX_PING_AGE)
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

Environment:
  DG_OBS_MAX_PING_AGE    Seconds since this observer's last ping beyond which
                         it counts as dead even though the broker still lists
                         it (default 60)
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

DG_OBS_MAX_PING_AGE="${DG_OBS_MAX_PING_AGE:-60}"
if ! valid_ping_age "$DG_OBS_MAX_PING_AGE"; then
    log_error "DG_OBS_MAX_PING_AGE must be a positive whole number of seconds (got '${DG_OBS_MAX_PING_AGE}')."
    exit 2
fi

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
# PID(s) of the detached observer started from here, one per line. Written by
# 'start' once the process shows up; it is the local half of the liveness
# check and the only thing 'start' will ever kill without asking.
OBSERVER_PID_FILE="${OBSERVER_DIR}/fsfo_${PRIMARY_DB_UNIQUE_NAME}.pid"

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
        | observer_args_filter || true
}

# observer_args_filter: "<pid> <args>" lines in, the PIDs of this
# configuration's dgmgrl observer out (the matching rule described above).
observer_args_filter() {
    awk -v a1="@${PRIMARY_TNS_ALIAS}" -v a2="${STANDBY_TNS_ALIAS:+@$STANDBY_TNS_ALIAS}" \
        -v f1="$OBSERVER_DAT" -v f2="$OBSERVER_LOG" '
        function has(l, p) { return p != "" && index(l, tolower(p)) > 0 }
        {
            l = tolower($0)
            if (index(l, "dgmgrl") > 0 && (has(l, a1) || has(l, a2) || has(l, f1) || has(l, f2))) print $1
        }
    '
}

# pid_is_our_observer PID: the PID is alive AND is this configuration's
# dgmgrl observer - not merely some process that inherited a recycled PID.
# ps -p sees processes of every owner, so nothing is mistaken for dead.
pid_is_our_observer() {
    local args
    args=$(ps -p "$1" -o args= 2>/dev/null || true)
    [[ -n "$args" ]] || return 1
    [[ -n "$(printf '%s %s\n' "$1" "$args" | observer_args_filter)" ]]
}

# pidfile_pids -> the numeric lines of the pidfile (nothing if absent)
pidfile_pids() {
    [[ -f "$OBSERVER_PID_FILE" ]] || return 0
    grep '^[0-9][0-9]*$' "$OBSERVER_PID_FILE" 2>/dev/null || true
}

this_host() { hostname 2>/dev/null | tr -d ' \r'; }

# local_process_state: the local half of the liveness check. Sets
#   OBS_PROC       running | dead | unknown
#   OBS_PROC_TEXT  what was seen, for the status line
#   OBS_PROC_PIDS  the pidfile PIDs that are verified to be our observer
# 'dead' needs positive evidence: a pidfile whose PIDs are all gone (or
# recycled) and no matching dgmgrl process found either. With no pidfile
# (started by hand, or by an older kit) or no ps, nothing is claimed and the
# ping age alone decides.
local_process_state() {
    local pids p alive="" scan
    OBS_PROC=unknown; OBS_PROC_TEXT=""; OBS_PROC_PIDS=""
    if ! command -v ps >/dev/null 2>&1; then
        OBS_PROC_TEXT="not checked (no ps on this host)"
        return 0
    fi
    pids=$(pidfile_pids)
    for p in $pids; do
        pid_is_our_observer "$p" && alive="${alive:+$alive }$p"
    done
    if [[ -n "$alive" ]]; then
        OBS_PROC=running; OBS_PROC_PIDS="$alive"
        OBS_PROC_TEXT="running (PID ${alive})"
        return 0
    fi
    scan=$(local_observer_pids | tr '\n' ' ' | sed 's/ *$//')
    if [[ -n "$scan" ]]; then
        OBS_PROC=running
        if [[ -n "$pids" ]]; then
            OBS_PROC_TEXT="running (PID ${scan}; the pidfile names $(printf '%s' "$pids" | tr '\n' ' ' | sed 's/ *$//'), which is gone)"
        else
            OBS_PROC_TEXT="running (PID ${scan}; no pidfile)"
        fi
    elif [[ -n "$pids" ]]; then
        OBS_PROC=dead
        OBS_PROC_TEXT="not running (pidfile PID $(printf '%s' "$pids" | tr '\n' ' ' | sed 's/ *$//') is gone)"
    else
        OBS_PROC_TEXT="not checked (no pidfile at ${OBSERVER_PID_FILE})"
    fi
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
BROKER_REACHABLE=false
select_connection() {
    local probe
    probe=$(run_dgmgrl "$DG_CONN" "SHOW CONFIGURATION;" || true)
    if printf '%s\n' "$probe" | grep -q 'Configuration -'; then
        BROKER_REACHABLE=true
        return 0
    fi
    [[ -n "${STANDBY_TNS_ALIAS:-}" && "$STANDBY_TNS_ALIAS" != "$CONNECT_ALIAS" ]] || return 0
    probe=$(run_dgmgrl "/@${STANDBY_TNS_ALIAS}" "SHOW CONFIGURATION;" || true)
    if printf '%s\n' "$probe" | grep -q 'Configuration -'; then
        log_warn "'${CONNECT_ALIAS}' did not answer; using the standby alias '${STANDBY_TNS_ALIAS}' (failed over?)."
        CONNECT_ALIAS="$STANDBY_TNS_ALIAS"
        DG_CONN="/@${CONNECT_ALIAS}"
        BROKER_REACHABLE=true
    fi
    return 0
}

# observer_state: one look at THIS observer. Sets
#   OBS_LIST_PARSED  true when SHOW OBSERVER held at least one observer block.
#                    false (broker down, or a release with another format)
#                    means only the primary's any-observer flag is left - the
#                    weaker evidence: it does not say WHICH observer.
#   OBS_REGISTERED   the broker lists this observer (by name, else by host)
#   OBS_REG_NAME / OBS_REG_ROLE / OBS_REG_HOST / OBS_MATCH   its block
#   OBS_PING / OBS_PING_LABEL / OBS_PING_TEXT   the ping age that decides:
#                    that block's 'Last Ping to Primary' through the primary
#                    alias; through the standby alias (primary not answering)
#                    the fresher of the block's primary and target pings,
#                    because after a failover that alias IS the primary
#   OBS_PROC*        local_process_state
#   OBS_LIVE         registered AND ping <= DG_OBS_MAX_PING_AGE AND the local
#                    process is not known to be dead
#   OBS_WHY          the failed conditions, '; '-separated
OBS_LIST_PARSED=false
OBS_REGISTERED=false
OBS_LIVE=false
observer_state() {
    local out blk mode
    OBS_LIST_PARSED=false; OBS_REGISTERED=false; OBS_LIVE=false; OBS_WHY=""
    OBS_REG_NAME=""; OBS_REG_ROLE=""; OBS_REG_HOST=""; OBS_MATCH=none
    OBS_PING=""; OBS_PING_LABEL=""; OBS_PING_TEXT=""; OBS_PRESENT=""

    out=$(run_dgmgrl "$DG_CONN" "SHOW OBSERVER;" || true)
    blk=$(observer_block "$out" "$OBSERVER_NAME" "$(this_host)")
    [[ "$(obs_field "$blk" BLOCKS)" =~ ^[1-9] ]] && OBS_LIST_PARSED=true
    local_process_state

    if ! $OBS_LIST_PARSED; then
        OBS_PRESENT=$(observer_present)
        [[ "$OBS_PRESENT" == "YES" ]] \
            || OBS_WHY="SHOW OBSERVER could not be read and the primary reports no observer (FS_FAILOVER_OBSERVER_PRESENT=${OBS_PRESENT:-unknown})"
        [[ "$OBS_PROC" == dead ]] && OBS_WHY="${OBS_WHY:+$OBS_WHY; }local process ${OBS_PROC_TEXT}"
        [[ -n "$OBS_WHY" ]] || OBS_LIVE=true
        return 0
    fi

    OBS_MATCH=$(obs_field "$blk" MATCH)
    if [[ "$OBS_MATCH" == none ]]; then
        OBS_WHY="not registered with the broker"
        return 0
    fi
    OBS_REGISTERED=true
    OBS_REG_NAME=$(obs_field "$blk" NAME)
    OBS_REG_ROLE=$(obs_field "$blk" ROLE)
    OBS_REG_HOST=$(obs_field "$blk" HOST)

    mode=primary
    [[ "$CONNECT_ALIAS" == "$PRIMARY_TNS_ALIAS" ]] || mode=either
    IFS='|' read -r OBS_PING OBS_PING_LABEL OBS_PING_TEXT <<< "$(observer_ping "$blk" "$mode")"
    if [[ -z "$OBS_PING" ]]; then
        OBS_WHY="${OBS_PING_LABEL} is '${OBS_PING_TEXT}', not an age in seconds"
    elif ! ping_is_fresh "$OBS_PING" "$DG_OBS_MAX_PING_AGE"; then
        OBS_WHY="${OBS_PING_LABEL} ${OBS_PING} s ago is stale (limit ${DG_OBS_MAX_PING_AGE} s)"
    fi
    [[ "$OBS_PROC" == dead ]] && OBS_WHY="${OBS_WHY:+$OBS_WHY; }local process ${OBS_PROC_TEXT}"
    [[ -n "$OBS_WHY" ]] || OBS_LIVE=true
    return 0
}

# observer_summary -> one line, registration and liveness side by side, e.g.
#   registered: yes ("obs_x" Master on obs1); last ping to primary: 742 s ago
#   (stale, limit 60 s); local process: not running (pidfile PID 4711 is gone)
# observer_summary [SEP] joins the parts with SEP (default '; ').
observer_summary() {
    local sep="${1:-; }" reg ping
    if ! $OBS_LIST_PARSED; then
        reg="unknown (SHOW OBSERVER not readable)"
        ping="primary reports an observer present: ${OBS_PRESENT:-unknown} (weaker evidence - any observer, not necessarily this one)"
    elif ! $OBS_REGISTERED; then
        reg="no"
        ping=""
    else
        reg="yes (\"${OBS_REG_NAME}\"${OBS_REG_ROLE:+ ${OBS_REG_ROLE}}${OBS_REG_HOST:+ on ${OBS_REG_HOST}})"
        if [[ -z "$OBS_PING" ]]; then
            ping="${OBS_PING_LABEL}: ${OBS_PING_TEXT} (not an age - counts as not live)"
        elif ping_is_fresh "$OBS_PING" "$DG_OBS_MAX_PING_AGE"; then
            ping="${OBS_PING_LABEL}: ${OBS_PING} s ago (fresh, limit ${DG_OBS_MAX_PING_AGE} s)"
        else
            ping="${OBS_PING_LABEL}: ${OBS_PING} s ago (stale, limit ${DG_OBS_MAX_PING_AGE} s)"
        fi
    fi
    printf 'registered: %s%s%slocal process: %s\n' "$reg" "$sep" "${ping:+${ping}${sep}}" "$OBS_PROC_TEXT"
}

# this_observer_registered: 0 when the broker lists this observer, live or not.
this_observer_registered() {
    observer_state
    $OBS_REGISTERED
}

# observer_up_here: 0 when this observer is live (observer_state).
observer_up_here() {
    observer_state
    $OBS_LIVE
}

# dgmgrl_observer_name NAME -> NAME as a DGMGRL command operand: bare when it
# is a plain identifier, otherwise single-quoted (an observer registered by
# the unnamed form is named after its host, e.g. 'obs-1.example.com').
dgmgrl_observer_name() {
    if printf '%s' "$1" | grep -q '^[A-Za-z][A-Za-z0-9_$#]*$'; then
        printf '%s' "$1"
    else
        printf "'%s'" "$1"
    fi
}

# kill_recorded_observer: stop a leftover local observer - but only PIDs from
# the pidfile that are verified (pid_is_our_observer) to be this
# configuration's dgmgrl observer. Anything else is reported, never signalled.
kill_recorded_observer() {
    local p i victims=""
    for p in $(pidfile_pids); do
        pid_is_our_observer "$p" && victims="${victims:+$victims }$p"
    done
    [[ -n "$victims" ]] || return 0
    log_warn "Stopping the leftover local observer process (PID ${victims}) - it is not live."
    # shellcheck disable=SC2086
    kill $victims 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
        p=""
        for p in $victims; do pid_is_our_observer "$p" && break; p=""; done
        [[ -n "$p" ]] || break
        sleep 1
    done
    for p in $victims; do
        if pid_is_our_observer "$p"; then
            log_warn "PID ${p} ignored SIGTERM - sending SIGKILL."
            kill -9 "$p" 2>/dev/null || true
        fi
    done
}

# record_pidfile "<PIDs that existed before START>": once the detached
# observer shows up in ps, write its PID(s) to the pidfile. Processes that
# were already there before the START are not ours to record.
record_pidfile() {
    local before="$1" p q new="" seen
    for p in $(pidfile_pids); do
        pid_is_our_observer "$p" && return 0
    done
    for p in $(local_observer_pids); do
        seen=false
        for q in $before; do [[ "$p" == "$q" ]] && seen=true; done
        $seen || new="${new:+$new }$p"
    done
    [[ -n "$new" ]] || return 0
    # shellcheck disable=SC2086
    printf '%s\n' $new > "$OBSERVER_PID_FILE" 2>/dev/null \
        || log_warn "Could not write ${OBSERVER_PID_FILE}"
    chmod 600 "$OBSERVER_PID_FILE" 2>/dev/null || true
}

# ============================================================
# Commands
# ============================================================

do_start() {
    log_section "Starting the FSFO Observer"

    select_connection

    # Nothing is killed or started on a guess: without a broker connection
    # neither the liveness check nor START OBSERVER can work, and a healthy
    # observer that merely cannot be confirmed must not be touched.
    if ! $BROKER_REACHABLE; then
        log_error "Neither '${PRIMARY_TNS_ALIAS}'${STANDBY_TNS_ALIAS:+ nor '${STANDBY_TNS_ALIAS}'} answered SHOW CONFIGURATION."
        log_error "Not touching the observer. Check the listeners, the wallet and TNS_ADMIN=${TNS_ADMIN}."
        exit 1
    fi

    # Liveness is judged for THIS observer (name, else host), not for "any
    # observer": on 12.2+ up to three may be registered, and one running
    # elsewhere must not stop this host from adding its own - nor stand in
    # for this one's health.
    observer_state
    if $OBS_LIVE; then
        log_info "This observer is already running: $(observer_summary)"
        if ! $OBS_LIST_PARSED; then
            log_warn "SHOW OBSERVER could not be read; FS_FAILOVER_OBSERVER_PRESENT=YES is weaker"
            log_warn "evidence - it says AN observer is connected, not that it is this one."
        fi
        log_info "Registered observers:"
        run_dgmgrl "$DG_CONN" "SHOW OBSERVER;" | sed 's/^/    /' || true
        log_info "Use '$(basename "$0") restart' to replace it, or 'status' to inspect."
        exit 0
    fi

    # A registered-but-dead observer (crashed, killed, or hung) is restarted
    # in place: same name, same FILE IS / LOGFILE IS, so the existing .dat
    # state file is reused, never deleted.
    local stale_reg=false stale_name=""
    if $OBS_REGISTERED; then
        stale_reg=true
        stale_name="$OBS_REG_NAME"
        log_warn "The broker lists this observer, but it is NOT live: ${OBS_WHY}."
        log_warn "  $(observer_summary)"
        log_info "Restarting it with its existing state file."
    elif $OBS_LIST_PARSED && [[ "$(observer_present)" == "YES" ]]; then
        log_info "Another observer is already registered (listing below); this host will add its own."
        run_dgmgrl "$DG_CONN" "SHOW OBSERVER;" | sed 's/^/    /' || true
    fi

    # A leftover local process (hung, or alive but unknown to the broker)
    # would hold the same state file. Only the pidfile's verified PIDs are
    # killed, and only on the parsed listing's word - never on the weaker
    # any-observer flag.
    if $OBS_LIST_PARSED && [[ "$OBS_PROC" == running ]]; then
        if [[ -n "$OBS_PROC_PIDS" ]]; then
            kill_recorded_observer
        else
            log_warn "A local dgmgrl observer process is running but is not the one in ${OBSERVER_PID_FILE}:"
            log_warn "  ${OBS_PROC_TEXT}"
            log_warn "Not killing it. If the start below fails, stop it by hand and re-run 'start'."
        fi
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

    # The pidfile describes the previous run; once its PIDs are gone (or were
    # killed above) it is dropped. The .dat state file stays where it is.
    local p any_alive=false before
    for p in $(pidfile_pids); do pid_is_our_observer "$p" && any_alive=true; done
    $any_alive || rm -f "$OBSERVER_PID_FILE" 2>/dev/null || true
    before=$(local_observer_pids | tr '\n' ' ')
    [[ -f "$OBSERVER_DAT" ]] && log_info "Reusing the existing observer state file: ${OBSERVER_DAT}"

    log_info "Starting observer '${OBSERVER_NAME}'..."
    out=$(run_dgmgrl "$DG_CONN" "$named_cmd" || true)
    printf '%s\n' "$out" | sed 's/^/    /'

    if dgmgrl_failed "$out" && $stale_reg && [[ -n "$stale_name" ]]; then
        # The broker still holds the dead observer's registration, and a
        # START under a registered name can be refused. Deregister that one
        # entry - by its own name, never a bare STOP OBSERVER, which could hit
        # another host's observer - and retry once. A stale registration means
        # SHOW OBSERVER exists, i.e. a 12.2+ configuration, so the unnamed
        # fallback below is not the answer here.
        log_warn "START OBSERVER was refused while the stale registration \"${stale_name}\" is still listed."
        log_warn "Deregistering it (STOP OBSERVER $(dgmgrl_observer_name "$stale_name")) and retrying once."
        out=$(run_dgmgrl "$DG_CONN" "STOP OBSERVER $(dgmgrl_observer_name "$stale_name");" || true)
        printf '%s\n' "$out" | sed 's/^/    /'
        sleep 2
        out=$(run_dgmgrl "$DG_CONN" "$named_cmd" || true)
        printf '%s\n' "$out" | sed 's/^/    /'
        if dgmgrl_failed "$out"; then
            log_error "START OBSERVER failed again after deregistering \"${stale_name}\"."
            log_error "Check ${OBSERVER_LOG}, the broker output above and '$(basename "$0") status'."
            exit 1
        fi
    elif dgmgrl_failed "$out"; then
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

    # Registered is not enough here either: wait until the broker shows a
    # fresh ping from THIS observer (and its process, once recorded, is up).
    log_info "Waiting for the observer to register and ping (up to 60s, ping limit ${DG_OBS_MAX_PING_AGE}s)..."
    local i up=false
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        sleep 5
        record_pidfile "$before"
        if observer_up_here; then up=true; break; fi
    done

    if $up; then
        log_info "Observer is live: $(observer_summary)"
        $OBS_LIST_PARSED || log_warn "(weaker evidence: SHOW OBSERVER could not be read; FS_FAILOVER_OBSERVER_PRESENT=YES names no observer)"
        run_dgmgrl "$DG_CONN" "SHOW OBSERVER;" | sed 's/^/    /' || true
    else
        log_warn "The observer is not live yet: ${OBS_WHY}."
        log_warn "  $(observer_summary)"
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

    # Stop the observer under the name the broker actually lists for it (it
    # differs from OBSERVER_NAME when it was started by the unnamed form and
    # registered under its host name). The bare STOP OBSERVER is kept for a
    # configuration without SHOW OBSERVER (pre-12.2, one observer only): on
    # 12.2+ it is not aimed at this observer and could stop another host's.
    local out stop_name
    observer_state
    stop_name="$OBSERVER_NAME"
    $OBS_REGISTERED && [[ -n "$OBS_REG_NAME" ]] && stop_name="$OBS_REG_NAME"
    if [[ -n "$stop_name" ]]; then
        out=$(run_dgmgrl "$DG_CONN" "STOP OBSERVER $(dgmgrl_observer_name "$stop_name");" || true)
        if dgmgrl_failed "$out" && ! printf '%s\n' "$out" | grep -q 'ORA-16877'; then
            if $OBS_LIST_PARSED; then
                log_warn "STOP OBSERVER ${stop_name} failed. Not retrying a bare STOP OBSERVER: on this"
                log_warn "configuration it is not aimed at this observer and could stop another host's."
            else
                log_warn "STOP OBSERVER ${stop_name} failed - retrying without the name."
                out=$(run_dgmgrl "$DG_CONN" "STOP OBSERVER;" || true)
            fi
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
    # Drop the pidfile once nothing it names is still our observer.
    local p any_alive=false
    for p in $(pidfile_pids); do pid_is_our_observer "$p" && any_alive=true; done
    $any_alive || rm -f "$OBSERVER_PID_FILE" 2>/dev/null || true

    printf '\n'
    log_warn "With no observer running, automatic failover cannot happen."
    log_warn "The databases keep running normally; a primary loss now needs a manual failover."
}

# restart: STOP OBSERVER returns before the broker has dropped the observer.
# Starting at once would find it still listed (and, while its last ping is
# fresh, live), so wait (bounded) until the registration is gone. If it is
# still listed after that but no longer live, start treats it as the stale
# registration it is; if it is still live, something else keeps it running.
do_restart() {
    local i
    do_stop
    printf '\n'
    log_info "Waiting for the broker to drop this observer (up to 30s)..."
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        this_observer_registered || break
        sleep 2
    done
    if this_observer_registered; then
        if $OBS_LIVE; then
            log_error "The broker still lists this observer as live after 30s - not starting a second one."
            log_error "  $(observer_summary)"
            log_error "Check '$(basename "$0") status'; stop it by hand if needed, then run 'start'."
            exit 1
        fi
        log_warn "The broker still lists this observer, but it is not live (${OBS_WHY}) -"
        log_warn "start will replace the stale registration."
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
        log_warn "If the broker still lists this observer above, it runs somewhere ELSE - or it is"
        log_warn "dead and only its registration is left (see 'This Observer' below)."
    fi
    [[ -f "$OBSERVER_LOG" ]] && log_info "Observer log: ${OBSERVER_LOG}" || log_warn "No observer log at ${OBSERVER_LOG}"
    [[ -f "$OBSERVER_DAT" ]] && log_info "Observer state file: ${OBSERVER_DAT}"

    # Registration and liveness are reported separately: a crashed observer
    # stays registered, so "registered: yes" alone proves nothing.
    log_section "This Observer"
    observer_state
    observer_summary "
" | sed 's/^/  /'

    log_section "Verdict"
    if $OBS_LIVE; then
        if $OBS_LIST_PARSED; then
            log_info "This observer is LIVE (registered, pinging within ${DG_OBS_MAX_PING_AGE}s, process not known dead)."
        else
            log_warn "SHOW OBSERVER could not be read - judged on the primary's FS_FAILOVER_OBSERVER_PRESENT=YES"
            log_warn "alone, which is weaker evidence: it says AN observer is connected, not that it is this one."
            log_info "An observer is PRESENT (not confirmed to be this one)."
        fi
        exit 0
    fi
    if $OBS_LIST_PARSED && ! $OBS_REGISTERED && [[ "$(observer_present)" == "YES" ]]; then
        log_warn "The broker reports an observer, but none registered as '${OBSERVER_NAME}' / this host."
    fi
    log_error "This observer is NOT live: ${OBS_WHY}."
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
    # A non-default ping limit has to reach cron/init too.
    [[ "$DG_OBS_MAX_PING_AGE" == "60" ]] || envs="${envs} DG_OBS_MAX_PING_AGE=${DG_OBS_MAX_PING_AGE}"
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

'status' exits 0 only when THIS observer is live, not merely registered -
the broker keeps a crashed observer listed. Live means: the broker lists it
(by name or host), ITS OWN last ping is at most DG_OBS_MAX_PING_AGE seconds
old (default 60; another observer's ping never counts), and the dgmgrl
process recorded in its pidfile is still running. It falls back to the
standby alias when the primary is down. When status fails, 'start' kills a
leftover hung process from its pidfile, restarts the observer with the same
state file, and deregisters the stale entry first if the broker refuses -
so it is safe to drive a restart from.

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
