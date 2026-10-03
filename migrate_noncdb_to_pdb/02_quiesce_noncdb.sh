#!/usr/bin/env bash
# =============================================================================
# 02_quiesce_noncdb.sh  -  Bring the source non-CDB to a quiesced READ ONLY
#                          state ready for plug-in.
# =============================================================================
# Run on: PRIMARY host of the non-CDB.
#
# Effects:
#   * Final log switch on non-CDB primary.
#   * Wait until non-CDB standby (DGMGRL apply lag = 0) is fully caught up.
#   * Restart non-CDB primary into READ ONLY (clean dictionary close + reopen).
#   * Re-check that the standby has applied everything the read-only reopen
#     produced (apply and transport lag 0) - only then stop redo apply, so its
#     files match the read-only state and stay frozen during the plug-in. If it
#     has not caught up, apply is LEFT ON and the step fails.
#   * Capture an SCN baseline.
#
# Requires step 01 to have passed (state preflight_ok).
#
# After this step the non-CDB is read-only on the primary, and its standby
# datafiles are a frozen consistent copy on the standby host.
# =============================================================================

set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

load_config
init_log "02_quiesce_noncdb"
trap_err
log_step "02 QUIESCE non-CDB ${SOURCE_DB_UNIQUE_NAME}"

require_state preflight_ok 01_preflight.sh
assert_source_identity "READWRITE|READONLY" || exit 1

# begin_attempt  -  clear this step's and every later step's flags. Called just
# before the first change, never before a refusal that leaves the system as it
# was (identity check above, operator decline, lag re-check on a source that is
# already READ ONLY): a refused re-run must not wipe a later step's state.
ATTEMPT_STARTED=false
begin_attempt() {
    [[ "$ATTEMPT_STARTED" == "true" ]] && return 0
    clear_state noncdb_quiesced quiesce_scn describe_done create_pdb_done plug_done verify_done verify_failures
    ATTEMPT_STARTED=true
}

# wait_standby_drained <max attempts>  -  0 once apply AND transport lag of the
# non-CDB standby read 0 seconds, 1 on timeout. The attempt loop is a poll, so a
# transient broker hiccup is retried (|| true), not fatal.
wait_standby_drained() {
    local max="$1" n=0
    while (( n < max )); do
        DG_STATE="$(run_dgmgrl "$SOURCE_ORACLE_SID" "SHOW DATABASE VERBOSE '${SOURCE_STANDBY_UNIQUE_NAME}';")" || true
        APPLY_LAG=$(echo "$DG_STATE" | awk -F: '/Apply Lag/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
        TPT_LAG=$(  echo "$DG_STATE" | awk -F: '/Transport Lag/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
        log_info "  apply='${APPLY_LAG}' transport='${TPT_LAG}'"
        if echo "$APPLY_LAG" | grep -qi "^0 second" && echo "$TPT_LAG" | grep -qi "^0 second"; then
            return 0
        fi
        sleep 5
        n=$((n+1))
    done
    return 1
}

# Already READ ONLY (an earlier run stopped at the lag re-check below): skip the
# switch/bounce - ALTER SYSTEM SWITCH LOGFILE is not allowed read-only - and
# resume at the lag check.
ALREADY_RO=false
[[ "$(sql_scalar "$SOURCE_ORACLE_SID" "SELECT open_mode FROM v\$database;")" == "READONLY" ]] && ALREADY_RO=true

if [[ "$ALREADY_RO" == "true" ]]; then
    log_info "Source non-CDB is already OPEN READ ONLY - skipping the log switch and restart."
else
    # The source is READ WRITE, so whatever a later step recorded is stale.
    begin_attempt
    # ---- 1. Force a log switch and wait for standby to catch up ----------------
    log_info "Forcing log switches on the non-CDB primary ..."
    run_sql "$SOURCE_ORACLE_SID" "
    ALTER SYSTEM SWITCH LOGFILE;
    ALTER SYSTEM SWITCH LOGFILE;
    ALTER SYSTEM SWITCH LOGFILE;
    ALTER SYSTEM ARCHIVE LOG CURRENT;
    " | tee_into_log

    log_info "Waiting for non-CDB standby (${SOURCE_STANDBY_UNIQUE_NAME}) to drain ..."
    wait_standby_drained 30 || \
        log_warn "Standby did not reach 0s lag in 150s; proceeding anyway (the lag is re-checked after the read-only reopen, before apply is stopped)."

    # ---- 2. Bounce the non-CDB primary to READ ONLY ----------------------------
    confirm_or_abort "This will SHUTDOWN IMMEDIATE the source non-CDB ${SOURCE_DB_UNIQUE_NAME} (takes it offline) and restart it READ ONLY. Continue?"

    log_info "Restarting non-CDB primary into READ ONLY ..."
    run_sql "$SOURCE_ORACLE_SID" "
    SHUTDOWN IMMEDIATE;
    STARTUP MOUNT;
    ALTER DATABASE OPEN READ ONLY;
    " | tee_into_log

fi

# Verify
SRC_OPEN_MODE="$(sql_scalar "$SOURCE_ORACLE_SID" "SELECT open_mode FROM v\$database;")"
if [[ "$SRC_OPEN_MODE" != "READONLY" ]]; then
    log_error "Failed to open non-CDB READ ONLY (got '${SRC_OPEN_MODE}')"
    exit 1
fi
log_success "non-CDB ${SOURCE_DB_NAME} is now OPEN READ ONLY"

# Final SCN baseline (after RO open, no further changes)
# (TO_CHAR: a bare NUMBER wider than NUMWIDTH prints in scientific notation.)
SRC_SCN="$(sql_scalar "$SOURCE_ORACLE_SID" "SELECT TO_CHAR(current_scn) FROM v\$database;")"
log_info "Source SCN at quiesce: ${SRC_SCN}"

# ---- 3. Drain & stop apply on the non-CDB standby --------------------------
# The shutdown/reopen above generated redo; stopping apply before the standby
# has it would freeze the standby datafiles at an EARLIER point than the
# read-only primary, contradicting "frozen at the same state".
log_info "Re-checking that the standby has applied everything from the read-only reopen ..."
if ! wait_standby_drained 36; then
    log_error "Standby ${SOURCE_STANDBY_UNIQUE_NAME} has not caught up after the read-only reopen (apply='${APPLY_LAG}', transport='${TPT_LAG}')."
    log_error "Redo apply was NOT stopped. Wait for the lag to reach 0, then run:"
    log_error "  DGMGRL> EDIT DATABASE '${SOURCE_STANDBY_UNIQUE_NAME}' SET STATE='APPLY-OFF';"
    log_error "and re-run this step (it resumes here when the source is already READ ONLY)."
    exit 1
fi
begin_attempt
record_state "quiesce_scn" "$SRC_SCN"
log_info "Stopping redo apply on the non-CDB standby ..."
run_dgmgrl "$SOURCE_ORACLE_SID" "EDIT DATABASE '${SOURCE_STANDBY_UNIQUE_NAME}' SET STATE='APPLY-OFF';" | tee_into_log

# Print a final status snapshot
log_info "Final DG status on non-CDB:"
run_dgmgrl "$SOURCE_ORACLE_SID" "SHOW CONFIGURATION;" | tee_into_log || true

record_state "noncdb_quiesced" "true"
log_success "Quiesce complete. Source non-CDB is READ ONLY; standby apply is OFF."
log_info "Log file: ${LOG_FILE}"
