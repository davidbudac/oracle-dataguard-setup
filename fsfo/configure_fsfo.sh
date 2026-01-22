#!/bin/bash
# ============================================================
# Oracle Data Guard - Configure Fast-Start Failover (FSFO)
# ============================================================
# Run this script on the STANDBY database server after
# Data Guard setup is complete (Step 7 verification passes).
#
# This script configures:
# - Protection mode: MAXIMUM AVAILABILITY
# - LogXptMode: FASTSYNC
# - Fast-Start Failover with observer support
#
# After running this script, start the observer with:
#   ./fsfo/observer.sh start
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source common functions
source "${COMMON_DIR}/dg_functions.sh"

# Default FSFO threshold (seconds)
FSFO_THRESHOLD="${FSFO_THRESHOLD:-30}"

# ============================================================
# Main Script
# ============================================================

print_banner "Configure Fast-Start Failover"

# Initialize logging
init_log "configure_fsfo"

# ============================================================
# Pre-flight Checks
# ============================================================

log_section "Pre-flight Checks"

check_oracle_env || exit 1
check_nfs_mount || exit 1
check_db_connection || exit 1

# ============================================================
# Load Configuration
# ============================================================

log_section "Loading Configuration"

# Find standby config file
STANDBY_CONFIG_FILES=(${NFS_SHARE}/standby_config_*.env)

if [[ ${#STANDBY_CONFIG_FILES[@]} -eq 0 || ! -f "${STANDBY_CONFIG_FILES[0]}" ]]; then
    log_error "No standby configuration file found in ${NFS_SHARE}"
    log_error "Please run the Data Guard setup scripts first (Steps 1-7)"
    exit 1
elif [[ ${#STANDBY_CONFIG_FILES[@]} -eq 1 ]]; then
    STANDBY_CONFIG_FILE="${STANDBY_CONFIG_FILES[0]}"
    log_info "Using configuration: $(basename "$STANDBY_CONFIG_FILE")"
else
    log_info "Multiple configuration files found:"
    select STANDBY_CONFIG_FILE in "${STANDBY_CONFIG_FILES[@]}"; do
        if [[ -n "$STANDBY_CONFIG_FILE" ]]; then
            log_info "Selected: $(basename "$STANDBY_CONFIG_FILE")"
            break
        fi
    done
fi

source "$STANDBY_CONFIG_FILE"

# Re-initialize log with DB name
init_log "configure_fsfo_${STANDBY_DB_UNIQUE_NAME}"

# ============================================================
# Verify Database Role
# ============================================================

log_section "Verifying Database Role"

DB_ROLE=$(run_sql_query "get_db_role.sql")
DB_ROLE=$(echo "$DB_ROLE" | tr -d ' \n\r')

if [[ "$DB_ROLE" != "PHYSICAL STANDBY" ]]; then
    log_error "This script must be run on the STANDBY database"
    log_error "Current database role: $DB_ROLE"
    exit 1
fi

log_info "Confirmed: Running on PHYSICAL STANDBY database"

# ============================================================
# Verify Data Guard Broker Configuration
# ============================================================

log_section "Verifying Data Guard Broker"

CONFIG_STATUS=$(run_dgmgrl "show_configuration.dgmgrl" 2>&1 || true)

if echo "$CONFIG_STATUS" | grep -q "ORA-16532"; then
    log_error "No Data Guard Broker configuration found"
    log_error "Please complete Data Guard setup (Steps 1-7) before configuring FSFO"
    exit 1
fi

if echo "$CONFIG_STATUS" | grep -q "SUCCESS"; then
    log_info "Data Guard Broker configuration: SUCCESS"
elif echo "$CONFIG_STATUS" | grep -q "WARNING"; then
    log_warn "Data Guard Broker has warnings - review before proceeding"
    echo ""
    echo "$CONFIG_STATUS"
    echo ""
    if ! confirm_proceed "Continue with FSFO configuration?"; then
        log_info "FSFO configuration cancelled by user"
        exit 0
    fi
else
    log_error "Data Guard Broker configuration is not healthy"
    echo ""
    echo "$CONFIG_STATUS"
    exit 1
fi

# ============================================================
# Check Synchronization Status
# ============================================================

log_section "Checking Synchronization Status"

log_info "Querying transport and apply lag..."

SYNC_STATUS=$(run_sql_query "check_sync_status.sql" 2>/dev/null || true)

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

log_info "Note: For MAXIMUM AVAILABILITY, standby should be synchronized"
log_info "Minor lag is acceptable; FSFO will wait for sync before failover"

# ============================================================
# Check Current Protection Mode
# ============================================================

log_section "Checking Current Protection Mode"

CURRENT_MODE=$(run_sql_query "get_db_status_pipe.sql" | awk -F'|' '{print $3}' | tr -d ' \n\r')
log_info "Current protection mode: $CURRENT_MODE"

# ============================================================
# Configuration Summary
# ============================================================

log_section "FSFO Configuration Summary"

echo ""
echo "The following changes will be made:"
echo ""
echo "  1. Protection Mode    : $CURRENT_MODE -> MAXIMUM AVAILABILITY"
echo "  2. LogXptMode         : FASTSYNC (for ${STANDBY_DB_UNIQUE_NAME})"
echo "  3. FSFO Threshold     : ${FSFO_THRESHOLD} seconds"
echo "  4. FSFO Target        : ${STANDBY_DB_UNIQUE_NAME}"
echo "  5. Fast-Start Failover: ENABLED"
echo ""

if ! confirm_proceed "Proceed with FSFO configuration?"; then
    log_info "FSFO configuration cancelled by user"
    exit 0
fi

# ============================================================
# Configure Protection Mode
# ============================================================

log_section "Setting Protection Mode to MAXIMUM AVAILABILITY"

if [[ "$CURRENT_MODE" == "MAXIMUM AVAILABILITY" ]]; then
    log_info "Protection mode is already MAXIMUM AVAILABILITY"
else
    log_cmd "dgmgrl / :" "EDIT CONFIGURATION SET PROTECTION MODE AS MAXAVAILABILITY"
    run_dgmgrl "set_maxavailability.dgmgrl"

    # Verify change
    sleep 3
    NEW_MODE=$(run_sql_query "get_db_status_pipe.sql" | awk -F'|' '{print $3}' | tr -d ' \n\r')

    if [[ "$NEW_MODE" == "MAXIMUM AVAILABILITY" ]]; then
        log_info "Protection mode set to MAXIMUM AVAILABILITY"
    else
        log_error "Failed to set protection mode (current: $NEW_MODE)"
        exit 1
    fi
fi

# ============================================================
# Configure LogXptMode
# ============================================================

log_section "Setting LogXptMode to FASTSYNC"

log_cmd "dgmgrl / :" "EDIT DATABASE '${STANDBY_DB_UNIQUE_NAME}' SET PROPERTY LogXptMode='FASTSYNC'"
run_dgmgrl "set_logxptmode_fastsync.dgmgrl" "$STANDBY_DB_UNIQUE_NAME"

log_info "LogXptMode set to FASTSYNC for ${STANDBY_DB_UNIQUE_NAME}"

# ============================================================
# Configure FSFO Properties
# ============================================================

log_section "Setting FSFO Properties"

log_cmd "dgmgrl / :" "EDIT CONFIGURATION SET PROPERTY FastStartFailoverThreshold=${FSFO_THRESHOLD}"
log_cmd "dgmgrl / :" "EDIT CONFIGURATION SET PROPERTY FastStartFailoverTarget='${STANDBY_DB_UNIQUE_NAME}'"
run_dgmgrl "set_fsfo_properties.dgmgrl" "$STANDBY_DB_UNIQUE_NAME" "$FSFO_THRESHOLD"

log_info "FSFO threshold set to ${FSFO_THRESHOLD} seconds"
log_info "FSFO target set to ${STANDBY_DB_UNIQUE_NAME}"

# ============================================================
# Enable Fast-Start Failover
# ============================================================

log_section "Enabling Fast-Start Failover"

log_cmd "dgmgrl / :" "ENABLE FAST_START FAILOVER"
ENABLE_RESULT=$(run_dgmgrl "enable_fsfo.dgmgrl" 2>&1 || true)

if echo "$ENABLE_RESULT" | grep -qi "error\|fail"; then
    log_error "Failed to enable Fast-Start Failover"
    echo ""
    echo "$ENABLE_RESULT"
    exit 1
fi

log_info "Fast-Start Failover enabled"

# ============================================================
# Display Final Configuration
# ============================================================

log_section "Final FSFO Configuration"

echo ""
run_dgmgrl "show_fsfo_status.dgmgrl"
echo ""

# ============================================================
# Summary
# ============================================================

print_summary "SUCCESS" "Fast-Start Failover configured"

echo ""
echo "FSFO CONFIGURATION COMPLETE"
echo "==========================="
echo ""
echo "  Protection Mode : MAXIMUM AVAILABILITY"
echo "  LogXptMode      : FASTSYNC"
echo "  FSFO Threshold  : ${FSFO_THRESHOLD} seconds"
echo "  FSFO Target     : ${STANDBY_DB_UNIQUE_NAME}"
echo "  FSFO Status     : ENABLED (observer not yet started)"
echo ""
echo "NEXT STEPS"
echo "=========="
echo ""
echo "  1. Start the observer process:"
echo "     ./fsfo/observer.sh start"
echo ""
echo "  2. Verify observer is running:"
echo "     ./fsfo/observer.sh status"
echo ""
echo "  3. Monitor FSFO status:"
echo "     dgmgrl / \"show fast_start failover\""
echo ""
echo "NOTE: The observer must be running for automatic failover to occur."
echo ""
