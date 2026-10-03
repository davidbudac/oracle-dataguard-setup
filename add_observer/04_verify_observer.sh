#!/usr/bin/env bash
# ============================================================
# Add an FSFO observer on a third host - Step 4 (verify, run anywhere)
# ============================================================
# Confirms the end state after the observer has been started:
#   - broker configuration health (SHOW CONFIGURATION)
#   - FSFO state, target and threshold/lag limit
#   - SHOW OBSERVER and the V$DATABASE observer columns
#   - that THIS observer (OBSERVER_NAME / OBSERVER_HOST from
#     observer_env.sh) is live, not merely registered: its own block in
#     SHOW OBSERVER must show a last ping no older than DG_OBS_MAX_PING_AGE
#     seconds (default 60). FS_FAILOVER_OBSERVER_PRESENT alone cannot tell a
#     different observer from this one
#   - that the observer host is NOT one of the two database hosts,
#     which is the entire point of a third host
#   - which users hold SYSDG in the password file
#
# How it connects:
#   default    -> wallet auth 'dgmgrl /@<primary alias>' using the alias
#                 from ./observer_env.sh (run it on the observer host)
#   --tns A    -> wallet auth against alias A
#   --local    -> OS auth 'dgmgrl /' (run it on a database host with
#                 ORACLE_SID set)
#
# Exit codes: 0 this observer live and FSFO ready, 1 observer missing /
#             not live / cannot verify, 2 bad arguments (including an
#             invalid DG_OBS_MAX_PING_AGE)
# ============================================================

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

if [[ -f "${SCRIPT_DIR}/observer_env.sh" ]]; then
    source "${SCRIPT_DIR}/observer_env.sh"
fi

TNS_ALIAS="${PRIMARY_TNS_ALIAS:-}"
USE_LOCAL=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [--tns ALIAS | --local]

  --tns ALIAS   Connect through the wallet as 'dgmgrl /@ALIAS'
                (default: PRIMARY_TNS_ALIAS from observer_env.sh)
  --local       Connect locally as 'dgmgrl /' (on a database host)
  -h, --help    Show this help

Environment:
  DG_OBS_MAX_PING_AGE  Ping age limit in seconds for "this observer is live"
                       (default 60)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tns)     [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                   TNS_ALIAS="$2"; USE_LOCAL=false; shift 2 ;;
        --local)   USE_LOCAL=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
done

DG_OBS_MAX_PING_AGE="${DG_OBS_MAX_PING_AGE:-60}"
if ! valid_ping_age "$DG_OBS_MAX_PING_AGE"; then
    log_error "DG_OBS_MAX_PING_AGE must be a positive whole number of seconds (got '${DG_OBS_MAX_PING_AGE}')."
    exit 2
fi

check_oracle_env
DGMGRL="$ORACLE_HOME/bin/dgmgrl"
SQLPLUS="$ORACLE_HOME/bin/sqlplus"
[[ -x "$DGMGRL" ]] || die "dgmgrl not found: ${DGMGRL}"

if $USE_LOCAL; then
    [[ -n "${ORACLE_SID:-}" ]] || die "--local needs ORACLE_SID set."
    DG_CONN="/"
    SQL_CONN="/ as sysdba"
else
    [[ -n "$TNS_ALIAS" ]] || die "No TNS alias: pass --tns ALIAS, or run this from the bundle that has observer_env.sh, or use --local on a database host."
    DG_CONN="/@${TNS_ALIAS}"
    SQL_CONN="/@${TNS_ALIAS} as sysdg"
fi
log_info "Connecting as: dgmgrl ${DG_CONN}"

# ============================================================
# Broker view
# ============================================================

log_section "Broker: SHOW CONFIGURATION"
CONFIG_OUT=$(run_dgmgrl "$DG_CONN" "SHOW CONFIGURATION;" || true)
printf '%s\n' "$CONFIG_OUT"

log_section "Broker: SHOW FAST_START FAILOVER"
FSFO_OUT=$(run_dgmgrl "$DG_CONN" "SHOW FAST_START FAILOVER;" || true)
printf '%s\n' "$FSFO_OUT"

log_section "Broker: SHOW OBSERVER"
OBSERVER_OUT=$(run_dgmgrl "$DG_CONN" "SHOW OBSERVER;" || true)
printf '%s\n' "$OBSERVER_OUT"

# ============================================================
# Database view
# ============================================================

log_section "V\$DATABASE Observer Columns"

VDB_OUT=$(run_sql_as "$SQL_CONN" "
select 'FS_FAILOVER_STATUS='           || fs_failover_status           from v\$database;
select 'FS_FAILOVER_OBSERVER_PRESENT=' || fs_failover_observer_present from v\$database;
select 'FS_FAILOVER_OBSERVER_HOST='    || fs_failover_observer_host    from v\$database;
select 'FS_FAILOVER_CURRENT_TARGET='   || fs_failover_current_target   from v\$database;
select 'FS_FAILOVER_THRESHOLD='        || fs_failover_threshold        from v\$database;
select 'DATABASE_ROLE='                || database_role                from v\$database;
select 'PROTECTION_MODE='              || protection_mode              from v\$database;
" 2>&1 || true)
printf '%s\n' "$VDB_OUT" | grep -E '^(FS_|DATABASE_ROLE|PROTECTION_MODE)' | sed 's/^/  /' \
    || log_warn "Could not query V\$DATABASE through this connection."

log_section "Password File: SYSDG Holders (V\$PWFILE_USERS)"
run_sql_as "$SQL_CONN" "
set pagesize 100 heading on feedback off linesize 200
col username format a30
select username, sysdba, sysdg from v\$pwfile_users;
" 2>&1 | grep -Ev '^[[:space:]]*$' | sed 's/^/  /' || log_warn "Could not query V\$PWFILE_USERS."

# ============================================================
# Placement check
# ============================================================

PRESENT=$(printf '%s\n' "$VDB_OUT"     | sed -n 's/^FS_FAILOVER_OBSERVER_PRESENT=//p' | tr -d ' \r' | head -1)
OBS_HOST=$(printf '%s\n' "$VDB_OUT"    | sed -n 's/^FS_FAILOVER_OBSERVER_HOST=//p'    | trim       | head -1)
FS_STATUS=$(printf '%s\n' "$VDB_OUT"   | sed -n 's/^FS_FAILOVER_STATUS=//p'           | trim       | head -1)
FS_TARGET=$(printf '%s\n' "$VDB_OUT"   | sed -n 's/^FS_FAILOVER_CURRENT_TARGET=//p'   | trim       | head -1)
DB_ROLE=$(printf '%s\n' "$VDB_OUT"     | sed -n 's/^DATABASE_ROLE=//p'                | trim       | head -1)

log_section "Observer Placement"

if [[ -n "$OBS_HOST" ]]; then
    log_info "The primary reports the observer on: ${OBS_HOST}"
    ON_DB_HOST=false
    for _h in "${PRIMARY_HOST:-}" "${STANDBY_HOST:-}"; do
        [[ -n "$_h" ]] || continue
        [[ "${OBS_HOST%%.*}" == "${_h%%.*}" ]] && ON_DB_HOST=true
    done
    if $ON_DB_HOST; then
        log_warn "That is one of the DATABASE hosts."
        log_warn "An observer sharing a failure domain with a database cannot tell a"
        log_warn "database failure from a network partition, and dies with the host it"
        log_warn "watches. Move it to a third host - that is what this kit is for."
    else
        log_info "Not a database host - correct placement for a third-host observer."
    fi
else
    log_warn "The primary reports no observer host."
fi

# ============================================================
# Verdict
# ============================================================

log_section "Verdict"

RC=0

if printf '%s\n' "$FSFO_OUT" | grep -qiE 'Fast-Start Failover:[[:space:]]*Disabled'; then
    log_error "Fast-Start Failover is DISABLED - an observer alone fails over nothing."
    log_error "  Enable it on the primary: ./01_prepare_primary.sh --enable-fsfo"
    RC=1
fi

case "$PRESENT" in
    YES)
        log_info "FS_FAILOVER_OBSERVER_PRESENT = YES (an observer is connected - which one is checked below)"
        ;;
    NO)
        log_error "FS_FAILOVER_OBSERVER_PRESENT = NO - the observer is not connected."
        log_error "  On the observer host: ./03_observer_ctl.sh status, then check its log."
        RC=1
        ;;
    *)
        log_warn "Could not determine observer presence from V\$DATABASE."
        RC=1
        ;;
esac

# FS_FAILOVER_STATUS is the one that says whether an automatic failover
# could actually happen right now.
case "$(upper "$FS_STATUS")" in
    SYNCHRONIZED)
        log_info "FS_FAILOVER_STATUS = SYNCHRONIZED - zero-data-loss failover is ready."
        ;;
    "TARGET UNDER LAG LIMIT")
        log_info "FS_FAILOVER_STATUS = TARGET UNDER LAG LIMIT - automatic failover is ready"
        log_info "  (MAXIMUM PERFORMANCE mode: up to FastStartFailoverLagLimit of redo can be lost)."
        ;;
    DISABLED|"")
        [[ "$RC" == "0" ]] && { log_warn "FS_FAILOVER_STATUS = ${FS_STATUS:-unknown}"; RC=1; }
        ;;
    *)
        log_warn "FS_FAILOVER_STATUS = ${FS_STATUS} - automatic failover is NOT currently possible."
        log_warn "  Common values: UNSYNCHRONIZED (transport/apply behind),"
        log_warn "  'TARGET OVER LAG LIMIT' (apply lag too big), STALLED, SUSPENDED."
        RC=1
        ;;
esac

[[ -n "$FS_TARGET" ]] && log_info "Failover target: ${FS_TARGET}"

# THIS observer, not "an" observer: the broker keeps a crashed observer
# registered, and with several observers FS_FAILOVER_OBSERVER_PRESENT can be
# YES because of a different one. The ping that counts is the one to the
# database this session is connected to (its broker saw it first hand); if
# that role is unknown, the fresher of the block's two pings.
OBS_BLK=$(observer_block "$OBSERVER_OUT" "${OBSERVER_NAME:-}" "${OBSERVER_HOST:-}")
case "$(upper "$DB_ROLE")" in
    PRIMARY)    PING_MODE=primary ;;
    *STANDBY*)  PING_MODE=target ;;
    *)          PING_MODE=either ;;
esac
IFS='|' read -r OBS_PING OBS_PING_LABEL OBS_PING_TEXT <<< "$(observer_ping "$OBS_BLK" "$PING_MODE")"
OBS_ID="'${OBSERVER_NAME:-?}'${OBSERVER_HOST:+ / host ${OBSERVER_HOST}}"
if [[ -z "${OBSERVER_NAME:-}" && -z "${OBSERVER_HOST:-}" ]]; then
    log_warn "No OBSERVER_NAME / OBSERVER_HOST (observer_env.sh) - cannot check THIS observer specifically;"
    log_warn "  FS_FAILOVER_OBSERVER_PRESENT above is weaker evidence: it does not say which observer."
elif [[ "$(obs_field "$OBS_BLK" BLOCKS)" == "0" ]]; then
    log_warn "SHOW OBSERVER could not be read - cannot check observer ${OBS_ID} specifically;"
    log_warn "  FS_FAILOVER_OBSERVER_PRESENT above is weaker evidence: it does not say which observer."
elif [[ "$(obs_field "$OBS_BLK" MATCH)" == "none" ]]; then
    log_error "SHOW OBSERVER does not list observer ${OBS_ID}."
    [[ "$PRESENT" == "YES" ]] && log_error "  FS_FAILOVER_OBSERVER_PRESENT = YES refers to a different observer."
    log_error "  On the observer host: ./03_observer_ctl.sh start"
    RC=1
elif [[ -z "$OBS_PING" ]]; then
    log_error "Observer \"$(obs_field "$OBS_BLK" NAME)\" is registered, but its ${OBS_PING_LABEL} is '${OBS_PING_TEXT}' - not live."
    log_error "  On the observer host: ./03_observer_ctl.sh status, then 'start' to restart it."
    RC=1
elif ! ping_is_fresh "$OBS_PING" "$DG_OBS_MAX_PING_AGE"; then
    log_error "Observer \"$(obs_field "$OBS_BLK" NAME)\" is registered, but its ${OBS_PING_LABEL} was ${OBS_PING} s ago"
    log_error "  (limit ${DG_OBS_MAX_PING_AGE} s) - a crashed or hung observer stays registered."
    log_error "  On the observer host: ./03_observer_ctl.sh status, then 'start' to restart it."
    RC=1
else
    log_info "Observer \"$(obs_field "$OBS_BLK" NAME)\" ($(obs_field "$OBS_BLK" ROLE), host $(obs_field "$OBS_BLK" HOST)) is live: ${OBS_PING_LABEL} ${OBS_PING} s ago."
fi

if [[ "$RC" == "0" ]]; then
    log_info "Observer verified."
    printf '\n'
    log_info "Worth doing once, in a maintenance window: prove it end to end with a"
    log_info "switchover drill (dgmgrl: SWITCHOVER TO '<standby>'), then switch back."
    log_info "The observer should follow the role change without being restarted."
else
    log_error "Verification did not pass - see the findings above."
fi

exit "$RC"
