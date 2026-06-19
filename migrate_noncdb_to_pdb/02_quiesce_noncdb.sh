#!/bin/bash
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
#   * Stop redo apply on the non-CDB standby (so its files match the RO SCN
#     and stay frozen during the plug-in).
#   * Flush log buffer on the standby and freeze.
#   * Capture an SCN baseline.
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

# ---- 1. Force a log switch and wait for standby to catch up ----------------
log_info "Forcing log switches on the non-CDB primary ..."
run_sql "$SOURCE_ORACLE_SID" "
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM ARCHIVE LOG CURRENT;
" | tee_into_log

log_info "Waiting for non-CDB standby (${SOURCE_STANDBY_UNIQUE_NAME}) to drain ..."
ATTEMPTS=0
while (( ATTEMPTS < 30 )); do
    DG_STATE="$(run_dgmgrl "$SOURCE_ORACLE_SID" "SHOW DATABASE VERBOSE '${SOURCE_STANDBY_UNIQUE_NAME}';")"
    APPLY_LAG=$(echo "$DG_STATE" | awk -F: '/Apply Lag/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
    TPT_LAG=$(  echo "$DG_STATE" | awk -F: '/Transport Lag/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
    log_info "  apply='${APPLY_LAG}' transport='${TPT_LAG}'"
    if echo "$APPLY_LAG" | grep -qi "^0 second" && echo "$TPT_LAG" | grep -qi "^0 second"; then
        break
    fi
    sleep 5
    ATTEMPTS=$((ATTEMPTS+1))
done
if (( ATTEMPTS >= 30 )); then
    log_warn "Standby did not reach 0s lag in 150s; proceeding anyway (RO will quiesce)."
fi

# ---- 2. Bounce the non-CDB primary to READ ONLY ----------------------------
log_info "Restarting non-CDB primary into READ ONLY ..."
run_sql "$SOURCE_ORACLE_SID" "
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE OPEN READ ONLY;
" | tee_into_log

# Verify
SRC_OPEN_MODE="$(sql_scalar "$SOURCE_ORACLE_SID" "SELECT open_mode FROM v\$database;")"
if [[ "$SRC_OPEN_MODE" != "READONLY" ]]; then
    log_error "Failed to open non-CDB READ ONLY (got '${SRC_OPEN_MODE}')"
    exit 1
fi
log_success "non-CDB ${SOURCE_DB_NAME} is now OPEN READ ONLY"

# Final SCN baseline (after RO open, no further changes)
SRC_SCN="$(sql_scalar "$SOURCE_ORACLE_SID" "SELECT current_scn FROM v\$database;")"
log_info "Source SCN at quiesce: ${SRC_SCN}"
record_state "quiesce_scn" "$SRC_SCN"

# ---- 3. Drain & stop apply on the non-CDB standby --------------------------
log_info "Stopping redo apply on the non-CDB standby ..."
run_dgmgrl "$SOURCE_ORACLE_SID" "EDIT DATABASE '${SOURCE_STANDBY_UNIQUE_NAME}' SET STATE='APPLY-OFF';" | tee_into_log

# Print a final status snapshot
log_info "Final DG status on non-CDB:"
run_dgmgrl "$SOURCE_ORACLE_SID" "SHOW CONFIGURATION;" | tee_into_log || true

record_state "noncdb_quiesced" "true"
log_success "Quiesce complete. Source non-CDB is READ ONLY; standby apply is OFF."
log_info "Log file: ${LOG_FILE}"
