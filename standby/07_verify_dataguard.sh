#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 7: Verify Data Guard
# ============================================================
# Run this script on the STANDBY (or PRIMARY) database server.
# It validates the Data Guard Broker configuration and reports status.
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

print_banner "Step 7: Verify Data Guard"

# Initialize logging (will reinitialize with DB name later)
init_log "07_verify_dataguard"

# ============================================================
# Pre-flight Checks
# ============================================================

log_section "Pre-flight Checks"

check_nfs_mount || exit 1

# Check for standby config files - support unique naming
STANDBY_CONFIG_FILES=(${NFS_SHARE}/standby_config_*.env)

if [[ ${#STANDBY_CONFIG_FILES[@]} -eq 0 || ! -f "${STANDBY_CONFIG_FILES[0]}" ]]; then
    log_error "No standby config files found in $NFS_SHARE"
    log_error "Please run 02_generate_standby_config.sh first"
    exit 1
elif [[ ${#STANDBY_CONFIG_FILES[@]} -eq 1 ]]; then
    STANDBY_CONFIG_FILE="${STANDBY_CONFIG_FILES[0]}"
    log_info "Found standby config file: $STANDBY_CONFIG_FILE"
else
    # Multiple standby config files exist - let user choose
    echo ""
    echo "Multiple standby configurations found:"
    echo ""
    PS3="Select the standby configuration to use: "
    select STANDBY_CONFIG_FILE in "${STANDBY_CONFIG_FILES[@]}"; do
        if [[ -n "$STANDBY_CONFIG_FILE" ]]; then
            break
        fi
    done
fi

log_info "Loading standby configuration..."
source "$STANDBY_CONFIG_FILE"

# Reinitialize log with standby DB name
init_log "07_verify_dataguard_${STANDBY_DB_UNIQUE_NAME}"

# Set Oracle environment
export ORACLE_HOME="$STANDBY_ORACLE_HOME"
export ORACLE_SID="$STANDBY_ORACLE_SID"
export PATH="$ORACLE_HOME/bin:$PATH"

check_oracle_env || exit 1
check_db_connection || exit 1

# ============================================================
# Prompt for SYS Password (needed for DGMGRL network validation)
# ============================================================

log_section "Authentication"

echo ""
echo "SYS password is required for DGMGRL network validation."
read -s -p "Enter SYS password: " SYS_PASSWORD
echo ""

if [[ -z "$SYS_PASSWORD" ]]; then
    log_warn "No SYS password provided - DGMGRL network validation will be skipped"
fi

# ============================================================
# Initialize Status Tracking
# ============================================================

OVERALL_STATUS="HEALTHY"
WARNINGS=0
ERRORS=0

# ============================================================
# Check Database Role and Status
# ============================================================

log_section "Database Role and Status"

DB_INFO=$(run_sql_query "get_db_status_pipe.sql")
DB_INFO=$(echo "$DB_INFO" | tr -d ' \n\r')

# AIX-compatible: use awk instead of here-strings
DB_ROLE=$(echo "$DB_INFO" | awk -F'|' '{print $1}')
OPEN_MODE=$(echo "$DB_INFO" | awk -F'|' '{print $2}')
PROTECTION_MODE=$(echo "$DB_INFO" | awk -F'|' '{print $3}')
SWITCHOVER_STATUS=$(echo "$DB_INFO" | awk -F'|' '{print $4}')

echo ""
echo "Database Configuration:"
echo "  Database Role:      $DB_ROLE"
echo "  Open Mode:          $OPEN_MODE"
echo "  Protection Mode:    $PROTECTION_MODE"
echo "  Switchover Status:  $SWITCHOVER_STATUS"
echo ""

# Validate role (handle both "PHYSICAL STANDBY" and "PHYSICALSTANDBY" after space removal)
if [[ "$DB_ROLE" != "PHYSICALSTANDBY" && "$DB_ROLE" != "PHYSICAL STANDBY" ]]; then
    log_error "Database role is not PHYSICAL STANDBY (current: $DB_ROLE)"
    OVERALL_STATUS="ERROR"
    ((ERRORS++))
else
    log_info "PASS: Database role is PHYSICAL STANDBY"
fi

# Validate open mode (handle space removal: "READONLY" or "READ ONLY")
if [[ "$OPEN_MODE" != "MOUNTED" && "$OPEN_MODE" != *"READONLY"* && "$OPEN_MODE" != *"READ ONLY"* ]]; then
    log_warn "Unexpected open mode: $OPEN_MODE"
    ((WARNINGS++))
else
    log_info "PASS: Database open mode is correct ($OPEN_MODE)"
fi

# ============================================================
# Check Managed Recovery Process
# ============================================================

log_section "Managed Recovery Process (MRP)"

MRP_INFO=$(run_sql_query "get_mrp_info_pipe.sql")

if [[ -z "$MRP_INFO" || "$MRP_INFO" == *"no rows"* ]]; then
    log_error "Managed Recovery Process (MRP0) is NOT running"
    log_error "To start MRP: ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;"
    OVERALL_STATUS="ERROR"
    ((ERRORS++))
else
    # AIX-compatible: use awk instead of here-strings
    MRP_INFO_CLEAN=$(echo "$MRP_INFO" | tr -d ' \n\r')
    MRP_PROCESS=$(echo "$MRP_INFO_CLEAN" | awk -F'|' '{print $1}')
    MRP_STATUS=$(echo "$MRP_INFO_CLEAN" | awk -F'|' '{print $2}')
    MRP_SEQUENCE=$(echo "$MRP_INFO_CLEAN" | awk -F'|' '{print $3}')
    echo ""
    echo "MRP Status:"
    echo "  Process:   $MRP_PROCESS"
    echo "  Status:    $MRP_STATUS"
    echo "  Sequence:  $MRP_SEQUENCE"
    echo ""

    if [[ "$MRP_STATUS" == "APPLYING_LOG" || "$MRP_STATUS" == "WAIT_FOR_LOG" ]]; then
        log_info "PASS: MRP is running and healthy"
    else
        log_warn "MRP status is: $MRP_STATUS"
        ((WARNINGS++))
    fi
fi

# Show all managed standby processes
echo ""
echo "All Managed Standby Processes:"
run_sql_display "get_managed_standby_procs.sql"

# ============================================================
# Check Archive Log Gap
# ============================================================

log_section "Archive Log Gap Analysis"

GAP_INFO=$(run_sql_query "get_archive_gap_count.sql")
GAP_COUNT=$(echo "$GAP_INFO" | tr -d ' \n\r')

if [[ "$GAP_COUNT" -gt 0 ]]; then
    log_error "ARCHIVE GAP DETECTED: $GAP_COUNT gap(s) found"
    echo ""
    echo "Gap Details:"
    run_sql_display "get_archive_gap_details.sql"
    OVERALL_STATUS="ERROR"
    ((ERRORS++))
else
    log_info "PASS: No archive log gaps detected"
fi

# ============================================================
# Check Archive Log Apply Status
# ============================================================

log_section "Archive Log Apply Status"

# Get last received and applied sequence
APPLY_INFO=$(run_sql_query "get_apply_info_pipe.sql")

# AIX-compatible: use awk instead of here-strings
APPLY_INFO_CLEAN=$(echo "$APPLY_INFO" | tr -d ' \n\r')
LAST_APPLIED=$(echo "$APPLY_INFO_CLEAN" | awk -F'|' '{print $1}')
LAST_RECEIVED=$(echo "$APPLY_INFO_CLEAN" | awk -F'|' '{print $2}')

echo ""
echo "Archive Log Sequences:"
echo "  Last Received:  $LAST_RECEIVED"
echo "  Last Applied:   $LAST_APPLIED"

if [[ "$LAST_APPLIED" -gt 0 ]]; then
    LAG=$((LAST_RECEIVED - LAST_APPLIED))
    echo "  Apply Lag:      $LAG sequence(s)"
    echo ""

    if [[ "$LAG" -gt 10 ]]; then
        log_warn "Significant apply lag detected: $LAG sequences behind"
        ((WARNINGS++))
    elif [[ "$LAG" -gt 0 ]]; then
        log_info "Minor apply lag: $LAG sequence(s) - this is normal during activity"
    else
        log_info "PASS: Standby is caught up with primary"
    fi
else
    log_warn "No applied archive logs found yet"
    ((WARNINGS++))
fi

# ============================================================
# Check Data Guard Broker Configuration
# ============================================================

log_section "Data Guard Broker Configuration"

echo ""
echo "Broker Configuration Status:"
run_dgmgrl "show_configuration.dgmgrl" 2>&1 || true

echo ""
echo "Primary Database Status:"
run_dgmgrl "show_database.dgmgrl" "$PRIMARY_DB_UNIQUE_NAME" 2>&1 || true

echo ""
echo "Standby Database Status:"
run_dgmgrl "show_database.dgmgrl" "$STANDBY_DB_UNIQUE_NAME" 2>&1 || true

echo ""
echo "Network Configuration Validation:"
if [[ -n "$SYS_PASSWORD" ]]; then
    run_dgmgrl_with_password "$SYS_PASSWORD" "$STANDBY_TNS_ALIAS" "validate_network.dgmgrl" 2>&1 || true
else
    log_warn "Skipping network validation (no SYS password provided)"
fi

# ============================================================
# Check Data Guard Parameters
# ============================================================

log_section "Data Guard Parameters"

echo ""
echo "Key Data Guard Parameters:"
run_sql_display "get_dg_params_full.sql"

# ============================================================
# Check Archive Destination Status
# ============================================================

log_section "Archive Destination Status"

echo ""
echo "Archive Destination Configuration:"
run_sql_display "get_archive_dest_config.sql"

# Check for errors in archive destinations
DEST_ERRORS=$(run_sql_query "get_archive_dest_error_count.sql")
DEST_ERROR_COUNT=$(echo "$DEST_ERRORS" | tr -d ' \n\r')

if [[ "$DEST_ERROR_COUNT" -gt 0 ]]; then
    log_error "Archive destination error detected"
    run_sql_display "get_archive_dest_errors.sql"
    OVERALL_STATUS="ERROR"
    ((ERRORS++))
fi

# ============================================================
# Check Redo Log Configuration
# ============================================================

log_section "Redo Log Configuration"

echo ""
echo "Standby Redo Logs:"
run_sql_display "get_standby_redo_full.sql"

# ============================================================
# Network Connectivity Check
# ============================================================

log_section "Network Connectivity"

echo ""
log_info "Testing tnsping to primary ($PRIMARY_TNS_ALIAS)..."
if "$ORACLE_HOME/bin/tnsping" "$PRIMARY_TNS_ALIAS" > /dev/null 2>&1; then
    log_info "PASS: tnsping to primary successful"
else
    log_error "Cannot reach primary via tnsping"
    OVERALL_STATUS="ERROR"
    ((ERRORS++))
fi

# ============================================================
# Generate Summary Report
# ============================================================

log_section "Data Guard Health Summary"

echo ""
echo "================================================================"
echo "                 DATA GUARD HEALTH REPORT"
echo "================================================================"
echo ""
echo "  Primary Database:     $PRIMARY_DB_UNIQUE_NAME @ $PRIMARY_HOSTNAME"
echo "  Standby Database:     $STANDBY_DB_UNIQUE_NAME @ $STANDBY_HOSTNAME"
echo ""
echo "  Database Role:        $DB_ROLE"
echo "  Open Mode:            $OPEN_MODE"
echo "  Protection Mode:      $PROTECTION_MODE"
echo ""
echo "  MRP Status:           ${MRP_STATUS:-NOT RUNNING}"
echo "  Last Applied Seq:     $LAST_APPLIED"
echo "  Archive Gaps:         ${GAP_COUNT:-0}"
echo ""
echo "  Errors:               $ERRORS"
echo "  Warnings:             $WARNINGS"
echo ""

if [[ "$OVERALL_STATUS" == "HEALTHY" && "$ERRORS" -eq 0 ]]; then
    printf "  ${GREEN}OVERALL STATUS: HEALTHY${NC}\n"
    print_summary "SUCCESS" "Data Guard configuration is healthy"
elif [[ "$ERRORS" -gt 0 ]]; then
    printf "  ${RED}OVERALL STATUS: ERROR${NC}\n"
    print_summary "ERROR" "Data Guard configuration has $ERRORS error(s)"
else
    printf "  ${YELLOW}OVERALL STATUS: WARNING${NC}\n"
    print_summary "WARNING" "Data Guard configuration has $WARNINGS warning(s)"
fi

echo ""
echo "================================================================"
echo ""

# ============================================================
# Useful Commands
# ============================================================

echo "USEFUL MONITORING COMMANDS:"
echo "==========================="
echo ""
echo "# DGMGRL - Show configuration status:"
echo "dgmgrl / \"show configuration\""
echo ""
echo "# DGMGRL - Show database details:"
echo "dgmgrl / \"show database '$PRIMARY_DB_UNIQUE_NAME'\""
echo "dgmgrl / \"show database '$STANDBY_DB_UNIQUE_NAME'\""
echo ""
echo "# DGMGRL - Validate configuration:"
echo "dgmgrl / \"validate database '$STANDBY_DB_UNIQUE_NAME'\""
echo ""
echo "# SQL - Check apply lag in real-time:"
echo "SELECT NAME, VALUE, TIME_COMPUTED FROM V\$DATAGUARD_STATS WHERE NAME LIKE '%lag%';"
echo ""
echo "# SQL - Monitor log apply:"
echo "SELECT PROCESS, STATUS, SEQUENCE# FROM V\$MANAGED_STANDBY;"
echo ""
echo "# SQL - Check for gaps:"
echo "SELECT * FROM V\$ARCHIVE_GAP;"
echo ""
echo "# Force log switch on primary (for testing):"
echo "ALTER SYSTEM SWITCH LOGFILE;"
echo ""
echo "# DGMGRL - Switchover to standby:"
echo "dgmgrl / \"switchover to '$STANDBY_DB_UNIQUE_NAME'\""
echo ""
echo "# Open standby in read-only mode (Active Data Guard):"
echo "ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;"
echo "ALTER DATABASE OPEN READ ONLY;"
echo "ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;"
echo ""

# ============================================================
# Next Steps
# ============================================================

if [[ "$ERRORS" -eq 0 ]]; then
    echo ""
    echo "NEXT STEP (Optional but Recommended):"
    echo "======================================"
    echo ""
    echo "Run security hardening on PRIMARY to lock SYS account:"
    echo "   ./primary/08_security_hardening.sh"
    echo ""
fi

# Return appropriate exit code
if [[ "$ERRORS" -gt 0 ]]; then
    exit 1
elif [[ "$WARNINGS" -gt 0 ]]; then
    exit 0  # Warnings don't cause failure
else
    exit 0
fi
