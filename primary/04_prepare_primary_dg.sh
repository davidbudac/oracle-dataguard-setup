#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 4: Prepare Primary for DG
# ============================================================
# Run this script on the PRIMARY database server.
# It configures the primary database for Data Guard operation.
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

print_banner "Step 4: Prepare Primary for DG"

# Initialize logging
init_log "04_prepare_primary_dg"

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
# Configure TNS Names on Primary
# ============================================================

log_section "Configuring TNS Names on Primary"

TNSNAMES_ORA="${ORACLE_HOME}/network/admin/tnsnames.ora"
TNSNAMES_ENTRY_FILE="${NFS_SHARE}/tnsnames_entries.ora"

if [[ ! -f "$TNSNAMES_ENTRY_FILE" ]]; then
    log_error "TNS entries file not found: $TNSNAMES_ENTRY_FILE"
    exit 1
fi

if [[ -f "$TNSNAMES_ORA" ]]; then
    backup_file "$TNSNAMES_ORA"

    # Check if entries already exist
    if grep -q "$STANDBY_TNS_ALIAS" "$TNSNAMES_ORA"; then
        log_info "TNS entry for standby already exists"
    else
        log_info "Adding TNS entries to tnsnames.ora"
        echo "" >> "$TNSNAMES_ORA"
        echo "# Data Guard TNS entries - Added $(date)" >> "$TNSNAMES_ORA"
        cat "$TNSNAMES_ENTRY_FILE" >> "$TNSNAMES_ORA"
        log_info "TNS entries added successfully"
    fi
else
    log_info "Creating new tnsnames.ora"
    echo "# TNS Names for Data Guard" > "$TNSNAMES_ORA"
    echo "# Created: $(date)" >> "$TNSNAMES_ORA"
    echo "" >> "$TNSNAMES_ORA"
    cat "$TNSNAMES_ENTRY_FILE" >> "$TNSNAMES_ORA"
    log_info "tnsnames.ora created successfully"
fi

# ============================================================
# Check/Enable Force Logging
# ============================================================

log_section "Checking Force Logging"

FORCE_LOGGING=$(run_sql "SELECT FORCE_LOGGING FROM V\$DATABASE;")
FORCE_LOGGING=$(echo "$FORCE_LOGGING" | tr -d ' \n\r')

if [[ "$FORCE_LOGGING" != "YES" ]]; then
    log_info "Enabling FORCE LOGGING..."
    run_sql "ALTER DATABASE FORCE LOGGING;"
    log_info "FORCE LOGGING enabled"
else
    log_info "FORCE LOGGING is already enabled"
fi

# ============================================================
# Check/Create Standby Redo Logs
# ============================================================

log_section "Checking Standby Redo Logs"

# Get current standby redo log count
CURRENT_STBY_GROUPS=$(run_sql "SELECT COUNT(DISTINCT GROUP#) FROM V\$STANDBY_LOG;")
CURRENT_STBY_GROUPS=$(echo "$CURRENT_STBY_GROUPS" | tr -d ' \n\r')

REQUIRED_STBY_GROUPS=$STANDBY_REDO_GROUPS

log_info "Current standby redo groups: $CURRENT_STBY_GROUPS"
log_info "Required standby redo groups: $REQUIRED_STBY_GROUPS"

if [[ "$CURRENT_STBY_GROUPS" -lt "$REQUIRED_STBY_GROUPS" ]]; then
    log_info "Creating standby redo logs..."

    # Get the max group number
    MAX_GROUP=$(run_sql "SELECT NVL(MAX(GROUP#), 0) FROM (SELECT GROUP# FROM V\$LOG UNION SELECT GROUP# FROM V\$STANDBY_LOG);")
    MAX_GROUP=$(echo "$MAX_GROUP" | tr -d ' \n\r')

    # Get redo log path for standby redo logs
    REDO_PATH=$(run_sql "SELECT SUBSTR(MEMBER, 1, INSTR(MEMBER, '/', -1)) FROM V\$LOGFILE WHERE ROWNUM=1;")
    REDO_PATH=$(echo "$REDO_PATH" | tr -d ' \n\r')

    # Calculate how many to create
    GROUPS_TO_CREATE=$((REQUIRED_STBY_GROUPS - CURRENT_STBY_GROUPS))

    log_info "Creating $GROUPS_TO_CREATE standby redo log groups..."

    for ((i=1; i<=GROUPS_TO_CREATE; i++)); do
        NEW_GROUP=$((MAX_GROUP + i))
        STBY_LOG_FILE="${REDO_PATH}standby_redo${NEW_GROUP}.log"

        log_info "Creating standby redo log group $NEW_GROUP: $STBY_LOG_FILE"

        run_sql "ALTER DATABASE ADD STANDBY LOGFILE GROUP ${NEW_GROUP} ('${STBY_LOG_FILE}') SIZE ${REDO_LOG_SIZE_MB}M;"
    done

    log_info "Standby redo logs created successfully"

    # Verify
    echo ""
    log_info "Standby redo log configuration:"
    run_sql_with_header "SELECT GROUP#, THREAD#, BYTES/1024/1024 AS SIZE_MB, STATUS FROM V\$STANDBY_LOG ORDER BY GROUP#;"
else
    log_info "Sufficient standby redo logs already exist"
fi

# ============================================================
# Configure Data Guard Parameters
# ============================================================

log_section "Configuring Data Guard Parameters"

# LOG_ARCHIVE_CONFIG
log_info "Setting LOG_ARCHIVE_CONFIG..."
run_sql "ALTER SYSTEM SET LOG_ARCHIVE_CONFIG='${LOG_ARCHIVE_CONFIG}' SCOPE=BOTH;"

# LOG_ARCHIVE_DEST_2 - Ship to standby
log_info "Setting LOG_ARCHIVE_DEST_2..."
run_sql "ALTER SYSTEM SET LOG_ARCHIVE_DEST_2='SERVICE=${STANDBY_TNS_ALIAS} ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=${STANDBY_DB_UNIQUE_NAME}' SCOPE=BOTH;"

# Enable destination 2
log_info "Enabling LOG_ARCHIVE_DEST_STATE_2..."
run_sql "ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_2=ENABLE SCOPE=BOTH;"

# FAL_SERVER
log_info "Setting FAL_SERVER..."
run_sql "ALTER SYSTEM SET FAL_SERVER='${STANDBY_TNS_ALIAS}' SCOPE=BOTH;"

# STANDBY_FILE_MANAGEMENT
log_info "Setting STANDBY_FILE_MANAGEMENT..."
run_sql "ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT=${STANDBY_FILE_MANAGEMENT} SCOPE=BOTH;"

log_info "Data Guard parameters configured successfully"

# ============================================================
# Verify TNS Connectivity to Standby
# ============================================================

log_section "Verifying Network Connectivity"

log_info "Testing tnsping to standby ($STANDBY_TNS_ALIAS)..."

if "$ORACLE_HOME/bin/tnsping" "$STANDBY_TNS_ALIAS" > /dev/null 2>&1; then
    log_info "tnsping $STANDBY_TNS_ALIAS successful"
    "$ORACLE_HOME/bin/tnsping" "$STANDBY_TNS_ALIAS"
else
    log_warn "tnsping $STANDBY_TNS_ALIAS failed"
    log_warn "This is expected if the standby listener is not yet running"
    log_warn "Please ensure standby listener is started before running RMAN duplicate"
fi

# ============================================================
# Display Current Configuration
# ============================================================

log_section "Current Data Guard Configuration"

echo ""
echo "Archive Destinations:"
run_sql_with_header "
SELECT DEST_ID, DEST_NAME, STATUS, TARGET, DESTINATION
FROM V\$ARCHIVE_DEST
WHERE DEST_ID IN (1,2);
"

echo ""
echo "Data Guard Parameters:"
run_sql_with_header "
SELECT NAME, VALUE
FROM V\$PARAMETER
WHERE NAME IN (
    'log_archive_config',
    'log_archive_dest_1',
    'log_archive_dest_2',
    'log_archive_dest_state_1',
    'log_archive_dest_state_2',
    'fal_server',
    'standby_file_management'
)
ORDER BY NAME;
"

echo ""
echo "Standby Redo Logs:"
run_sql_with_header "
SELECT GROUP#, THREAD#, BYTES/1024/1024 AS SIZE_MB, STATUS
FROM V\$STANDBY_LOG
ORDER BY GROUP#;
"

# ============================================================
# Summary
# ============================================================

print_summary "SUCCESS" "Primary configured for Data Guard"

echo ""
echo "COMPLETED ACTIONS:"
echo "=================="
echo "  - Configured tnsnames.ora with standby entry"
echo "  - Enabled FORCE LOGGING (if needed)"
echo "  - Created standby redo logs (if needed)"
echo "  - Set LOG_ARCHIVE_CONFIG"
echo "  - Set LOG_ARCHIVE_DEST_2 for standby"
echo "  - Set FAL_SERVER"
echo "  - Set STANDBY_FILE_MANAGEMENT=AUTO"
echo ""
echo "NEXT STEPS:"
echo "==========="
echo ""
echo "On STANDBY server:"
echo "   Run: ./05_clone_standby.sh"
echo ""
echo "IMPORTANT: Ensure the standby listener is running with"
echo "static registration before running the clone script."
echo ""
