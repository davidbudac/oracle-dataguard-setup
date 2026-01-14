#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 6: Verify Data Guard
# ============================================================
# Run this script on the STANDBY database server.
# It validates the Data Guard configuration and reports status.
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

print_banner "Step 6: Verify Data Guard"

# Initialize logging
init_log "06_verify_dataguard"

# ============================================================
# Pre-flight Checks
# ============================================================

log_section "Pre-flight Checks"

check_nfs_mount || exit 1

# Load standby configuration
STANDBY_CONFIG_FILE="${NFS_SHARE}/standby_config.env"
if [[ ! -f "$STANDBY_CONFIG_FILE" ]]; then
    log_error "Standby config file not found: $STANDBY_CONFIG_FILE"
    exit 1
fi

log_info "Loading standby configuration..."
source "$STANDBY_CONFIG_FILE"

# Set Oracle environment
export ORACLE_HOME="$STANDBY_ORACLE_HOME"
export ORACLE_SID="$STANDBY_ORACLE_SID"
export PATH="$ORACLE_HOME/bin:$PATH"

check_oracle_env || exit 1
check_db_connection || exit 1

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

DB_INFO=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF LINESIZE 200
SELECT DATABASE_ROLE || '|' || OPEN_MODE || '|' || PROTECTION_MODE || '|' || SWITCHOVER_STATUS
FROM V\$DATABASE;
EXIT;
EOF
)
DB_INFO=$(echo "$DB_INFO" | tr -d ' \n\r')

IFS='|' read -r DB_ROLE OPEN_MODE PROTECTION_MODE SWITCHOVER_STATUS <<< "$DB_INFO"

echo ""
echo "Database Configuration:"
echo "  Database Role:      $DB_ROLE"
echo "  Open Mode:          $OPEN_MODE"
echo "  Protection Mode:    $PROTECTION_MODE"
echo "  Switchover Status:  $SWITCHOVER_STATUS"
echo ""

# Validate role
if [[ "$DB_ROLE" != "PHYSICAL STANDBY" ]]; then
    log_error "Database role is not PHYSICAL STANDBY (current: $DB_ROLE)"
    OVERALL_STATUS="ERROR"
    ((ERRORS++))
else
    log_info "PASS: Database role is PHYSICAL STANDBY"
fi

# Validate open mode
if [[ "$OPEN_MODE" != "MOUNTED" && "$OPEN_MODE" != *"READ ONLY"* ]]; then
    log_warn "Unexpected open mode: $OPEN_MODE"
    ((WARNINGS++))
else
    log_info "PASS: Database open mode is correct ($OPEN_MODE)"
fi

# ============================================================
# Check Managed Recovery Process
# ============================================================

log_section "Managed Recovery Process (MRP)"

MRP_INFO=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF LINESIZE 200
SELECT PROCESS || '|' || STATUS || '|' || NVL(TO_CHAR(SEQUENCE#), 'N/A')
FROM V\$MANAGED_STANDBY
WHERE PROCESS = 'MRP0';
EXIT;
EOF
)

if [[ -z "$MRP_INFO" || "$MRP_INFO" == *"no rows"* ]]; then
    log_error "Managed Recovery Process (MRP0) is NOT running"
    log_error "To start MRP: ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;"
    OVERALL_STATUS="ERROR"
    ((ERRORS++))
else
    IFS='|' read -r MRP_PROCESS MRP_STATUS MRP_SEQUENCE <<< "$(echo "$MRP_INFO" | tr -d ' \n\r')"
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
sqlplus -s / as sysdba <<EOF
SET LINESIZE 150 PAGESIZE 50
COLUMN PROCESS FORMAT A10
COLUMN STATUS FORMAT A15
COLUMN SEQUENCE# FORMAT 999999
COLUMN BLOCK# FORMAT 9999999
SELECT PROCESS, STATUS, THREAD#, SEQUENCE#, BLOCK#
FROM V\$MANAGED_STANDBY
ORDER BY PROCESS;
EXIT;
EOF

# ============================================================
# Check Archive Log Gap
# ============================================================

log_section "Archive Log Gap Analysis"

GAP_INFO=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF
SELECT COUNT(*) FROM V\$ARCHIVE_GAP;
EXIT;
EOF
)
GAP_COUNT=$(echo "$GAP_INFO" | tr -d ' \n\r')

if [[ "$GAP_COUNT" -gt 0 ]]; then
    log_error "ARCHIVE GAP DETECTED: $GAP_COUNT gap(s) found"
    echo ""
    echo "Gap Details:"
    sqlplus -s / as sysdba <<EOF
SET LINESIZE 150 PAGESIZE 50
SELECT THREAD#, LOW_SEQUENCE#, HIGH_SEQUENCE#
FROM V\$ARCHIVE_GAP;
EXIT;
EOF
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
APPLY_INFO=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF LINESIZE 200
SELECT
    NVL(MAX(CASE WHEN APPLIED='YES' THEN SEQUENCE# END), 0) || '|' ||
    NVL(MAX(SEQUENCE#), 0)
FROM V\$ARCHIVED_LOG
WHERE THREAD# = 1;
EXIT;
EOF
)

IFS='|' read -r LAST_APPLIED LAST_RECEIVED <<< "$(echo "$APPLY_INFO" | tr -d ' \n\r')"

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
# Check Data Guard Parameters
# ============================================================

log_section "Data Guard Parameters"

echo ""
echo "Key Data Guard Parameters:"
sqlplus -s / as sysdba <<EOF
SET LINESIZE 200 PAGESIZE 50
COLUMN NAME FORMAT A30
COLUMN VALUE FORMAT A100
SELECT NAME, VALUE
FROM V\$PARAMETER
WHERE NAME IN (
    'db_name',
    'db_unique_name',
    'log_archive_config',
    'log_archive_dest_1',
    'log_archive_dest_2',
    'fal_server',
    'fal_client',
    'standby_file_management'
)
ORDER BY NAME;
EXIT;
EOF

# ============================================================
# Check Archive Destination Status
# ============================================================

log_section "Archive Destination Status"

echo ""
echo "Archive Destination Configuration:"
sqlplus -s / as sysdba <<EOF
SET LINESIZE 200 PAGESIZE 50
COLUMN DEST_NAME FORMAT A20
COLUMN STATUS FORMAT A10
COLUMN DESTINATION FORMAT A60
SELECT DEST_ID, DEST_NAME, STATUS, TARGET, DESTINATION
FROM V\$ARCHIVE_DEST
WHERE DEST_ID IN (1, 2);
EXIT;
EOF

# Check for errors in archive destinations
DEST_ERRORS=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF
SELECT COUNT(*) FROM V\$ARCHIVE_DEST WHERE STATUS = 'ERROR' AND DEST_ID IN (1,2);
EXIT;
EOF
)
DEST_ERROR_COUNT=$(echo "$DEST_ERRORS" | tr -d ' \n\r')

if [[ "$DEST_ERROR_COUNT" -gt 0 ]]; then
    log_error "Archive destination error detected"
    sqlplus -s / as sysdba <<EOF
SET LINESIZE 200 PAGESIZE 50
SELECT DEST_ID, ERROR FROM V\$ARCHIVE_DEST WHERE STATUS = 'ERROR';
EXIT;
EOF
    OVERALL_STATUS="ERROR"
    ((ERRORS++))
fi

# ============================================================
# Check Redo Log Configuration
# ============================================================

log_section "Redo Log Configuration"

echo ""
echo "Standby Redo Logs:"
sqlplus -s / as sysdba <<EOF
SET LINESIZE 150 PAGESIZE 50
SELECT GROUP#, THREAD#, BYTES/1024/1024 AS SIZE_MB, STATUS, ARCHIVED
FROM V\$STANDBY_LOG
ORDER BY GROUP#;
EXIT;
EOF

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
    echo -e "  ${GREEN}OVERALL STATUS: HEALTHY${NC}"
    print_summary "SUCCESS" "Data Guard configuration is healthy"
elif [[ "$ERRORS" -gt 0 ]]; then
    echo -e "  ${RED}OVERALL STATUS: ERROR${NC}"
    print_summary "ERROR" "Data Guard configuration has $ERRORS error(s)"
else
    echo -e "  ${YELLOW}OVERALL STATUS: WARNING${NC}"
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
echo "# Check apply lag in real-time:"
echo "SELECT NAME, VALUE, TIME_COMPUTED FROM V\$DATAGUARD_STATS WHERE NAME LIKE '%lag%';"
echo ""
echo "# Monitor log apply:"
echo "SELECT PROCESS, STATUS, SEQUENCE# FROM V\$MANAGED_STANDBY;"
echo ""
echo "# Check for gaps:"
echo "SELECT * FROM V\$ARCHIVE_GAP;"
echo ""
echo "# Force log switch on primary (for testing):"
echo "ALTER SYSTEM SWITCH LOGFILE;"
echo ""
echo "# Open standby in read-only mode (Active Data Guard):"
echo "ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;"
echo "ALTER DATABASE OPEN READ ONLY;"
echo "ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;"
echo ""

# Return appropriate exit code
if [[ "$ERRORS" -gt 0 ]]; then
    exit 1
elif [[ "$WARNINGS" -gt 0 ]]; then
    exit 0  # Warnings don't cause failure
else
    exit 0
fi
