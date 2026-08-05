#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 13: Set Maximum Availability
# ============================================================
# Run this script on the PRIMARY database server after
# Data Guard setup is complete (Step 7 verification passes).
#
# This script:
# - Validates that the Data Guard configuration is healthy
#   (broker status, VALIDATE DATABASE readiness, lag, archive
#   destinations) BEFORE changing anything
# - Sets LogXptMode to FASTSYNC on both databases
# - Sets protection mode to MAXIMUM AVAILABILITY
# - Verifies the new protection mode took effect
#
# Note: Step 9 (Configure FSFO) already applies these same two
# settings as part of enabling Fast-Start Failover. Use this
# step when you want zero-data-loss protection WITHOUT FSFO.
# If FSFO is already enabled, this script is a no-op (the
# settings are already in place) or refuses to proceed.
#
# The script is idempotent - re-running against a configuration
# that is already MAXIMUM AVAILABILITY + FASTSYNC exits
# successfully without changing anything.
#
# Rollback (manual, via dgmgrl /):
#   EDIT CONFIGURATION SET PROTECTION MODE AS MAXPERFORMANCE;
#   EDIT DATABASE '<primary>' SET PROPERTY LogXptMode='ASYNC';
#   EDIT DATABASE '<standby>' SET PROPERTY LogXptMode='ASYNC';
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source common functions
source "${COMMON_DIR}/dg_functions.sh"
enable_verbose_mode "$@"

TARGET_LOGXPT="FASTSYNC"

# Extract a broker property value from SHOW DATABASE '<db>' '<prop>' output
# (line looks like:   LogXptMode = 'ASYNC')
parse_broker_property() {
    printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*'\(.*\)'.*/\1/p" | head -1
}

# ============================================================
# Main Script
# ============================================================

print_banner "Step 13: Set Maximum Availability Protection"
init_progress 13

# Initialize logging
init_log "13_set_max_availability"

# ============================================================
# Pre-flight Checks
# ============================================================

progress_step "Pre-flight Checks"

check_oracle_env || exit 1
check_nfs_mount || exit 1
check_db_connection || exit 1

# ============================================================
# Load Configuration
# ============================================================

progress_step "Loading Configuration"

# Find standby config file
if ! select_config_file STANDBY_CONFIG_FILE "standby configuration" "${NFS_SHARE}/standby_config_*.env"; then
    log_error "Please run the Data Guard setup scripts first (Steps 1-7)"
    log_error "Note: 'cleanup_nfs_artifacts.sh --all' removes this file - run Step 13 before a full cleanup"
    exit 1
fi

source "$STANDBY_CONFIG_FILE"

# Re-initialize log with DB name
init_log "13_set_max_availability_${STANDBY_DB_UNIQUE_NAME}"

# ============================================================
# Verify Database Role
# ============================================================

progress_step "Verifying Database Role"

DB_ROLE=$(run_sql_query "get_db_role.sql")
DB_ROLE=$(echo "$DB_ROLE" | tr -d ' \n\r')

if [[ "$DB_ROLE" != "PRIMARY" ]]; then
    log_error "This script must be run on the PRIMARY database"
    log_error "Current database role: $DB_ROLE"
    exit 1
fi

log_info "Confirmed: Running on PRIMARY database"

# ============================================================
# Verify Data Guard Broker Configuration
# ============================================================

progress_step "Verifying Data Guard Broker"

CONFIG_STATUS=$(run_dgmgrl "show_configuration.dgmgrl" 2>&1 || true)

if echo "$CONFIG_STATUS" | grep -q "ORA-16532"; then
    log_error "No Data Guard Broker configuration found"
    log_error "Please complete Data Guard setup (Steps 1-7) before changing the protection mode"
    exit 1
fi

if echo "$CONFIG_STATUS" | grep -q "SUCCESS"; then
    log_info "Data Guard Broker configuration: SUCCESS"
elif echo "$CONFIG_STATUS" | grep -q "WARNING"; then
    log_warn "Data Guard Broker has warnings - resolve them before raising the protection mode"
    echo ""
    echo "$CONFIG_STATUS"
    echo ""
    if ! confirm_proceed "Continue despite broker warnings?"; then
        log_info "Protection mode change cancelled by user"
        exit 0
    fi
else
    log_error "Data Guard Broker configuration is not healthy"
    echo ""
    echo "$CONFIG_STATUS"
    exit 1
fi

# ============================================================
# Check Current Protection Settings
# ============================================================

progress_step "Checking Current Protection Settings"

CURRENT_MODE=$(run_sql_query "get_db_status_pipe.sql" | awk -F'|' '{print $3}' | tr -d '\n\r' | sed 's/^ *//;s/ *$//')
log_info "Current protection mode: $CURRENT_MODE"

PRIMARY_LOGXPT=$(parse_broker_property "$(run_dgmgrl "show_database_property.dgmgrl" "$PRIMARY_DB_UNIQUE_NAME" "LogXptMode" 2>&1 || true)" "LogXptMode")
STANDBY_LOGXPT=$(parse_broker_property "$(run_dgmgrl "show_database_property.dgmgrl" "$STANDBY_DB_UNIQUE_NAME" "LogXptMode" 2>&1 || true)" "LogXptMode")

log_info "LogXptMode ${PRIMARY_DB_UNIQUE_NAME}: ${PRIMARY_LOGXPT:-unknown}"
log_info "LogXptMode ${STANDBY_DB_UNIQUE_NAME}: ${STANDBY_LOGXPT:-unknown}"

CURRENT_MODE_NORMALIZED=$(echo "$CURRENT_MODE" | tr -d ' ')

MODE_CHANGE_NEEDED=1
[[ "$CURRENT_MODE_NORMALIZED" == "MAXIMUMAVAILABILITY" ]] && MODE_CHANGE_NEEDED=0

LOGXPT_CHANGE_NEEDED=0
[[ "$PRIMARY_LOGXPT" != "$TARGET_LOGXPT" ]] && LOGXPT_CHANGE_NEEDED=1
[[ "$STANDBY_LOGXPT" != "$TARGET_LOGXPT" ]] && LOGXPT_CHANGE_NEEDED=1

if [[ "$MODE_CHANGE_NEEDED" == "0" && "$LOGXPT_CHANGE_NEEDED" == "0" ]]; then
    print_summary "SUCCESS" "Configuration is already MAXIMUM AVAILABILITY with LogXptMode=FASTSYNC"
    print_status_block "Current Configuration" \
        "Protection Mode" "$CURRENT_MODE" \
        "LogXptMode (${PRIMARY_DB_UNIQUE_NAME})" "$PRIMARY_LOGXPT" \
        "LogXptMode (${STANDBY_DB_UNIQUE_NAME})" "$STANDBY_LOGXPT"
    exit 0
fi

# ============================================================
# Check Fast-Start Failover State
# ============================================================

progress_step "Checking Fast-Start Failover State"

FSFO_STATUS=$(run_sql_query "get_fsfo_status.sql" 2>/dev/null | awk -F'|' '{print $1}' | tr -d '\n\r' | sed 's/^ *//;s/ *$//' || true)
log_info "Fast-Start Failover status: ${FSFO_STATUS:-unknown}"

# The broker rejects LogXptMode edits on FSFO members while FSFO is
# enabled - and an enabled FSFO configuration set up by Step 9 already
# has FASTSYNC + MAXIMUM AVAILABILITY anyway (the early-exit above).
# Reaching this point with FSFO enabled means an unusual mixed state.
if [[ -n "$FSFO_STATUS" && "$FSFO_STATUS" != "DISABLED" ]]; then
    log_error "Fast-Start Failover is enabled (status: $FSFO_STATUS) but the configuration"
    log_error "does not match MAXIMUM AVAILABILITY + FASTSYNC"
    log_error "Disable FSFO first (dgmgrl /: DISABLE FAST_START FAILOVER), re-run this step,"
    log_error "then re-enable FSFO - or re-run Step 9 (primary/09_configure_fsfo.sh) instead"
    exit 1
fi

# ============================================================
# Validate Database Readiness (VALIDATE DATABASE)
# ============================================================

progress_step "Validating Database Readiness"

VALIDATION_OK=1

for DB in "$PRIMARY_DB_UNIQUE_NAME" "$STANDBY_DB_UNIQUE_NAME"; do
    log_info "Running VALIDATE DATABASE '${DB}'..."
    VALIDATE_OUTPUT=$(run_dgmgrl "validate_database.dgmgrl" "$DB" 2>&1 || true)
    echo ""
    echo "$VALIDATE_OUTPUT"
    echo ""

    if printf '%s\n' "$VALIDATE_OUTPUT" | grep -Eq 'ORA-[0-9]|DGM-[0-9]'; then
        log_error "VALIDATE DATABASE '${DB}' reported errors"
        VALIDATION_OK=0
        continue
    fi

    if printf '%s\n' "$VALIDATE_OUTPUT" | grep "Ready for Switchover:" | grep -q "Yes"; then
        log_info "${DB}: Ready for Switchover: Yes"
    else
        log_warn "${DB}: not reporting 'Ready for Switchover: Yes' - review the output above"
        VALIDATION_OK=0
    fi
done

if [[ "$VALIDATION_OK" != "1" ]]; then
    log_error "Database validation did not pass cleanly"
    log_error "MAXIMUM AVAILABILITY requires healthy synchronous transport; fix the issues above first"
    if ! confirm_proceed "Continue anyway despite validation warnings?"; then
        log_info "Protection mode change cancelled by user"
        exit 1
    fi
fi

# ============================================================
# Check Synchronization Status
# ============================================================

progress_step "Checking Synchronization Status"

log_info "Querying transport and apply lag..."

# Keep stderr visible: $(...) captures only stdout, so a missing-script
# (SP2-0310) or ORA- error surfaces instead of an empty result.
SYNC_STATUS=$(run_sql_query "check_sync_status.sql" || true)

if [[ -z "$SYNC_STATUS" ]]; then
    log_warn "Could not query synchronization status"
    log_warn "V\$DATAGUARD_STATS may not be populated yet"
else
    echo ""
    echo "Current lag status:"
    echo "$SYNC_STATUS" | while IFS='|' read -r name value unit; do
        printf "  %-15s: %s %s\n" "$name" "$value" "$unit"
    done
    echo ""
fi

log_info "Note: The broker refuses MAXIMUM AVAILABILITY (ORA-16627) if the standby is not synchronized"

# ============================================================
# Check Archive Destinations
# ============================================================

progress_step "Checking Archive Destinations"

DEST_ERROR_COUNT=$(run_sql_query "get_archive_dest_error_count.sql" 2>/dev/null | tr -d ' \n\r' || true)

if [[ -n "$DEST_ERROR_COUNT" && "$DEST_ERROR_COUNT" != "0" ]]; then
    log_warn "Archive destinations reporting errors: $DEST_ERROR_COUNT"
    echo ""
    run_sql_query "get_archive_dest_errors.sql" || true
    echo ""
    if ! confirm_proceed "Continue despite archive destination errors?"; then
        log_info "Protection mode change cancelled by user"
        exit 1
    fi
else
    log_info "No archive destination errors"
fi

# ============================================================
# Change Summary
# ============================================================

progress_step "Reviewing Change Summary"

print_list_block "This Step Will Change" \
    "Set LogXptMode to FASTSYNC on ${PRIMARY_DB_UNIQUE_NAME} and ${STANDBY_DB_UNIQUE_NAME}." \
    "Set protection mode to MAXIMUM AVAILABILITY (${CURRENT_MODE} today)."

print_list_block "This Step Will Not Change" \
    "It will not enable Fast-Start Failover (use Step 9 for that)." \
    "It will not restart either database." \
    "It will not change application services."

print_list_block "Recovery If This Step Fails" \
    "Review the dgmgrl output for the exact failed operation (ORA-16627 = standby not synchronized)." \
    "Revert with: EDIT CONFIGURATION SET PROTECTION MODE AS MAXPERFORMANCE; then LogXptMode='ASYNC' on both databases." \
    "Re-run this step after correcting the transport issue."

record_next_step "bash dg_status.sh"

if [[ "$CHECK_ONLY" == "1" ]]; then
    finish_check_mode "Maximum Availability preflight complete. No Broker changes were applied."
fi

echo ""
echo "The following changes will be made:"
echo ""
echo "  1. LogXptMode           : ${PRIMARY_LOGXPT:-unknown}/${STANDBY_LOGXPT:-unknown} -> FASTSYNC (both ${PRIMARY_DB_UNIQUE_NAME} and ${STANDBY_DB_UNIQUE_NAME})"
echo "  2. Protection Mode      : $CURRENT_MODE -> MAXIMUM AVAILABILITY"
echo ""
echo "Note: With FASTSYNC, commits on the primary wait for the standby to"
echo "acknowledge redo receipt (not disk write). Expect a small commit"
echo "latency increase proportional to network round-trip time."
echo ""

if ! confirm_proceed "Proceed with protection mode change?"; then
    log_info "Protection mode change cancelled by user"
    exit 0
fi

# ============================================================
# Configure LogXptMode (must be done before changing protection mode)
# ============================================================

progress_step "Setting LogXptMode to FASTSYNC"

if [[ "$LOGXPT_CHANGE_NEEDED" == "0" ]]; then
    log_info "LogXptMode is already FASTSYNC on both databases"
else
    log_cmd "dgmgrl / :" "EDIT DATABASE '${PRIMARY_DB_UNIQUE_NAME}' SET PROPERTY LogXptMode='FASTSYNC'"
    if ! run_dgmgrl_checked "set_logxptmode_fastsync.dgmgrl" "$PRIMARY_DB_UNIQUE_NAME"; then
        log_error "Failed to set LogXptMode=FASTSYNC on $PRIMARY_DB_UNIQUE_NAME"
        exit 1
    fi
    log_info "LogXptMode set to FASTSYNC for ${PRIMARY_DB_UNIQUE_NAME}"

    log_cmd "dgmgrl / :" "EDIT DATABASE '${STANDBY_DB_UNIQUE_NAME}' SET PROPERTY LogXptMode='FASTSYNC'"
    if ! run_dgmgrl_checked "set_logxptmode_fastsync.dgmgrl" "$STANDBY_DB_UNIQUE_NAME"; then
        log_error "Failed to set LogXptMode=FASTSYNC on $STANDBY_DB_UNIQUE_NAME"
        exit 1
    fi
    log_info "LogXptMode set to FASTSYNC for ${STANDBY_DB_UNIQUE_NAME}"
fi

# ============================================================
# Configure Protection Mode
# ============================================================

progress_step "Setting Protection Mode to MAXIMUM AVAILABILITY"

if [[ "$MODE_CHANGE_NEEDED" == "0" ]]; then
    log_info "Protection mode is already MAXIMUM AVAILABILITY"
else
    log_cmd "dgmgrl / :" "EDIT CONFIGURATION SET PROTECTION MODE AS MAXAVAILABILITY"
    if ! DGMGRL_OUTPUT=$(run_dgmgrl "set_maxavailability.dgmgrl" 2>&1); then
        log_error "DGMGRL command failed:"
        echo ""
        echo "$DGMGRL_OUTPUT"
        echo ""
        exit 1
    fi

    if echo "$DGMGRL_OUTPUT" | grep -qiE "error|ORA-"; then
        log_error "DGMGRL command failed:"
        echo ""
        echo "$DGMGRL_OUTPUT"
        echo ""
        exit 1
    fi

    # Verify change
    sleep 3
    NEW_MODE=$(run_sql_query "get_db_status_pipe.sql" | awk -F'|' '{print $3}' | tr -d ' \n\r')
    NEW_MODE_NORMALIZED=$(echo "$NEW_MODE" | tr -d ' ')

    if [[ "$NEW_MODE_NORMALIZED" == "MAXIMUMAVAILABILITY" ]]; then
        log_info "Protection mode set to MAXIMUM AVAILABILITY"
    else
        log_error "Failed to set protection mode (current: $NEW_MODE)"
        log_error "DGMGRL output was:"
        echo ""
        echo "$DGMGRL_OUTPUT"
        echo ""
        exit 1
    fi
fi

# ============================================================
# Verify Final Configuration
# ============================================================

progress_step "Verifying Final Configuration"

# The broker's health check can take a moment to converge after a
# protection mode change - poll SHOW CONFIGURATION for SUCCESS.
FINAL_STATUS=""
FINAL_OK=0
attempt=0
while [[ $attempt -lt 6 ]]; do
    FINAL_STATUS=$(run_dgmgrl "show_configuration.dgmgrl" 2>&1 || true)
    if echo "$FINAL_STATUS" | grep -q "SUCCESS"; then
        FINAL_OK=1
        break
    fi
    attempt=$((attempt+1))
    sleep 5
done

echo ""
echo "$FINAL_STATUS"
echo ""

if [[ "$FINAL_OK" == "1" ]]; then
    print_summary "SUCCESS" "Protection mode set to MAXIMUM AVAILABILITY with LogXptMode=FASTSYNC"
else
    log_warn "Broker configuration has not returned to SUCCESS yet - review the output above"
    log_warn "Run 'dgmgrl / \"SHOW CONFIGURATION\"' or 'bash dg_status.sh' in a few minutes"
    print_summary "WARNING" "Settings applied but broker status is not SUCCESS yet"
fi

print_status_block "Final Configuration" \
    "Protection Mode" "MAXIMUM AVAILABILITY" \
    "LogXptMode" "FASTSYNC (both databases)" \
    "Fast-Start Failover" "${FSFO_STATUS:-DISABLED}"

print_list_block "Notes" \
    "Commits now wait for standby redo receipt - watch commit latency after the change." \
    "If the standby becomes unreachable, the primary keeps running (availability over protection) and resynchronizes automatically when the standby returns." \
    "To also enable automatic failover, run Step 9 (primary/09_configure_fsfo.sh)." \
    "Verify overall health any time with: bash dg_status.sh"
