#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 6: Configure Data Guard Broker
# ============================================================
# Run this script on the PRIMARY database server.
# It creates and enables the Data Guard Broker configuration
# using DGMGRL.
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source common functions
source "${COMMON_DIR}/dg_functions.sh"

# ============================================================
# Main Script
# ============================================================

print_banner "Step 6: Configure Data Guard Broker"

# Initialize logging
init_log "06_configure_broker"

# ============================================================
# Pre-flight Checks
# ============================================================

log_section "Pre-flight Checks"

check_oracle_env || exit 1
check_nfs_mount || exit 1
check_db_connection || exit 1

# Load standby configuration
STANDBY_CONFIG_FILE="${NFS_SHARE}/standby_config.env"
if [[ ! -f "$STANDBY_CONFIG_FILE" ]]; then
    log_error "Standby config file not found: $STANDBY_CONFIG_FILE"
    exit 1
fi

log_info "Loading standby configuration..."
source "$STANDBY_CONFIG_FILE"

# ============================================================
# Verify DG Broker is Running
# ============================================================

log_section "Verifying Data Guard Broker Status"

# Check DG_BROKER_START on primary
DG_BROKER_START=$(get_db_parameter "dg_broker_start")
log_info "Primary DG_BROKER_START: $DG_BROKER_START"

if [[ "$DG_BROKER_START" != "TRUE" ]]; then
    log_error "DG_BROKER_START is not TRUE on primary"
    log_error "Please run 04_prepare_primary_dg.sh first"
    exit 1
fi

# Check DMON process is running
DMON_COUNT=$(run_sql "SELECT COUNT(*) FROM V\$PROCESS WHERE PNAME LIKE 'DMON%';")
DMON_COUNT=$(echo "$DMON_COUNT" | tr -d ' \n\r')

if [[ "$DMON_COUNT" -eq 0 ]]; then
    log_error "Data Guard Broker process (DMON) is not running"
    log_error "Try: ALTER SYSTEM SET DG_BROKER_START=FALSE; then TRUE;"
    exit 1
fi

log_info "DMON process is running on primary"

# ============================================================
# Verify TNS Connectivity
# ============================================================

log_section "Verifying Network Connectivity"

log_info "Testing tnsping to primary ($PRIMARY_TNS_ALIAS)..."
if ! "$ORACLE_HOME/bin/tnsping" "$PRIMARY_TNS_ALIAS" > /dev/null 2>&1; then
    log_error "Cannot reach primary via tnsping"
    exit 1
fi
log_info "tnsping to primary successful"

log_info "Testing tnsping to standby ($STANDBY_TNS_ALIAS)..."
if ! "$ORACLE_HOME/bin/tnsping" "$STANDBY_TNS_ALIAS" > /dev/null 2>&1; then
    log_error "Cannot reach standby via tnsping"
    log_error "Ensure standby listener is running"
    exit 1
fi
log_info "tnsping to standby successful"

# ============================================================
# Check for Existing Broker Configuration
# ============================================================

log_section "Checking for Existing Broker Configuration"

# Try to connect and check for existing config
EXISTING_CONFIG=$("$ORACLE_HOME/bin/dgmgrl" -silent / "show configuration" 2>&1 || true)

if echo "$EXISTING_CONFIG" | grep -q "ORA-16532"; then
    log_info "No existing broker configuration found - proceeding with creation"
elif echo "$EXISTING_CONFIG" | grep -q "Configuration -"; then
    log_warn "Existing broker configuration detected!"
    echo ""
    echo "$EXISTING_CONFIG"
    echo ""
    if ! confirm_proceed "Do you want to remove the existing configuration and create a new one?"; then
        log_info "Keeping existing configuration"
        exit 0
    fi

    log_info "Removing existing configuration..."
    "$ORACLE_HOME/bin/dgmgrl" -silent / "remove configuration" || true
    log_info "Existing configuration removed"
fi

# ============================================================
# Create Broker Configuration
# ============================================================

log_section "Creating Data Guard Broker Configuration"

DG_BROKER_CONFIG_NAME="${DG_BROKER_CONFIG_NAME:-${PRIMARY_DB_NAME}_DG}"

log_info "Configuration name: $DG_BROKER_CONFIG_NAME"
log_info "Primary database: $PRIMARY_DB_UNIQUE_NAME"
log_info "Standby database: $STANDBY_DB_UNIQUE_NAME"

# Create configuration
log_info "Creating broker configuration..."
"$ORACLE_HOME/bin/dgmgrl" -silent / <<EOF
CREATE CONFIGURATION '${DG_BROKER_CONFIG_NAME}' AS PRIMARY DATABASE IS '${PRIMARY_DB_UNIQUE_NAME}' CONNECT IDENTIFIER IS '${PRIMARY_TNS_ALIAS}';
EXIT;
EOF

if [[ $? -ne 0 ]]; then
    log_error "Failed to create broker configuration"
    exit 1
fi
log_info "Configuration created successfully"

# Add standby database
log_info "Adding standby database to configuration..."
"$ORACLE_HOME/bin/dgmgrl" -silent / <<EOF
ADD DATABASE '${STANDBY_DB_UNIQUE_NAME}' AS CONNECT IDENTIFIER IS '${STANDBY_TNS_ALIAS}' MAINTAINED AS PHYSICAL;
EXIT;
EOF

if [[ $? -ne 0 ]]; then
    log_error "Failed to add standby database"
    exit 1
fi
log_info "Standby database added successfully"

# ============================================================
# Enable Configuration
# ============================================================

log_section "Enabling Data Guard Broker Configuration"

log_info "Enabling configuration..."
"$ORACLE_HOME/bin/dgmgrl" -silent / <<EOF
ENABLE CONFIGURATION;
EXIT;
EOF

# Wait for configuration to stabilize
log_info "Waiting for configuration to stabilize..."
sleep 10

# ============================================================
# Verify Configuration
# ============================================================

log_section "Verifying Broker Configuration"

echo ""
echo "Data Guard Broker Configuration:"
echo "================================="
"$ORACLE_HOME/bin/dgmgrl" -silent / <<EOF
SHOW CONFIGURATION;
EXIT;
EOF

echo ""
echo "Primary Database Details:"
echo "========================="
"$ORACLE_HOME/bin/dgmgrl" -silent / <<EOF
SHOW DATABASE '${PRIMARY_DB_UNIQUE_NAME}';
EXIT;
EOF

echo ""
echo "Standby Database Details:"
echo "========================="
"$ORACLE_HOME/bin/dgmgrl" -silent / <<EOF
SHOW DATABASE '${STANDBY_DB_UNIQUE_NAME}';
EXIT;
EOF

# ============================================================
# Check Configuration Status
# ============================================================

log_section "Configuration Status Check"

CONFIG_STATUS=$("$ORACLE_HOME/bin/dgmgrl" -silent / "show configuration" 2>&1)

if echo "$CONFIG_STATUS" | grep -q "SUCCESS"; then
    log_info "Configuration status: SUCCESS"
    BROKER_STATUS="SUCCESS"
elif echo "$CONFIG_STATUS" | grep -q "WARNING"; then
    log_warn "Configuration status: WARNING"
    log_warn "Check the configuration details above for warnings"
    BROKER_STATUS="WARNING"
else
    log_error "Configuration status: ERROR or UNKNOWN"
    log_error "Please check configuration details above"
    BROKER_STATUS="ERROR"
fi

# ============================================================
# Force Log Switch to Test
# ============================================================

log_section "Testing Log Shipping"

log_info "Forcing log switch to test redo transport..."
run_sql "ALTER SYSTEM SWITCH LOGFILE;"

sleep 5

log_info "Checking log shipping status..."
"$ORACLE_HOME/bin/dgmgrl" -silent / <<EOF
SHOW DATABASE '${STANDBY_DB_UNIQUE_NAME}' 'InconsistentProperties';
SHOW DATABASE '${STANDBY_DB_UNIQUE_NAME}' 'LogXptStatus';
EXIT;
EOF

# ============================================================
# Summary
# ============================================================

if [[ "$BROKER_STATUS" == "SUCCESS" ]]; then
    print_summary "SUCCESS" "Data Guard Broker configured successfully"
elif [[ "$BROKER_STATUS" == "WARNING" ]]; then
    print_summary "WARNING" "Data Guard Broker configured with warnings"
else
    print_summary "ERROR" "Data Guard Broker configuration has issues"
fi

echo ""
echo "COMPLETED ACTIONS:"
echo "=================="
echo "  - Created broker configuration: $DG_BROKER_CONFIG_NAME"
echo "  - Added primary database: $PRIMARY_DB_UNIQUE_NAME"
echo "  - Added standby database: $STANDBY_DB_UNIQUE_NAME"
echo "  - Enabled configuration"
echo "  - Tested log shipping"
echo ""
echo "BROKER MANAGEMENT COMMANDS:"
echo "==========================="
echo ""
echo "  # Show configuration status:"
echo "  dgmgrl / \"show configuration\""
echo ""
echo "  # Show database details:"
echo "  dgmgrl / \"show database '$PRIMARY_DB_UNIQUE_NAME'\""
echo "  dgmgrl / \"show database '$STANDBY_DB_UNIQUE_NAME'\""
echo ""
echo "  # Switchover to standby:"
echo "  dgmgrl / \"switchover to '$STANDBY_DB_UNIQUE_NAME'\""
echo ""
echo "  # Failover to standby (if primary is down):"
echo "  dgmgrl / \"failover to '$STANDBY_DB_UNIQUE_NAME'\""
echo ""
echo "NEXT STEPS:"
echo "==========="
echo ""
echo "Run verification script:"
echo "   ./standby/07_verify_dataguard.sh"
echo ""
