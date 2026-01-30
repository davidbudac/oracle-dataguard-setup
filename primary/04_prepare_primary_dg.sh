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

# Initialize logging (will reinitialize with DB name later)
init_log "04_prepare_primary_dg"

# ============================================================
# Pre-flight Checks
# ============================================================

log_section "Pre-flight Checks"

check_oracle_env || exit 1
check_nfs_mount || exit 1
check_db_connection || exit 1

# Check for standby config files - support unique naming
if ! select_config_file STANDBY_CONFIG_FILE "standby configuration" "${NFS_SHARE}/standby_config_*.env"; then
    log_error "Please run 02_generate_standby_config.sh first"
    exit 1
fi

log_info "Loading standby configuration..."
source "$STANDBY_CONFIG_FILE"

# Reinitialize log with standby DB name
init_log "04_prepare_primary_dg_${STANDBY_DB_UNIQUE_NAME}"

# ============================================================
# Configure TNS Names on Primary
# ============================================================

log_section "Configuring TNS Names on Primary"

TNSNAMES_ORA="${ORACLE_HOME}/network/admin/tnsnames.ora"
TNSNAMES_ENTRY_FILE="${NFS_SHARE}/tnsnames_entries_${STANDBY_DB_UNIQUE_NAME}.ora"

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
# Configure Listener on Primary
# ============================================================

log_section "Configuring Listener on Primary"

LISTENER_ORA="${ORACLE_HOME}/network/admin/listener.ora"
LISTENER_PRIMARY_FILE="${NFS_SHARE}/listener_primary_${PRIMARY_DB_UNIQUE_NAME}.ora"

# New SID_DESC entries to add - write to temp file for AIX compatibility
# Includes _DGMGRL service for Data Guard Broker switchover
# AIX compatible: use $$ (PID) instead of mktemp
TEMP_SID_DESC="/tmp/dg_sid_desc_primary_$$.tmp"
cat > "$TEMP_SID_DESC" <<EOF
    (SID_DESC =
      (GLOBAL_DBNAME = ${PRIMARY_DB_UNIQUE_NAME})
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${PRIMARY_ORACLE_SID})
    )
    (SID_DESC =
      (GLOBAL_DBNAME = ${PRIMARY_DB_UNIQUE_NAME}_DGMGRL)
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${PRIMARY_ORACLE_SID})
    )
EOF

# Check if listener.ora exists
if [[ -f "$LISTENER_ORA" ]]; then
    backup_file "$LISTENER_ORA"

    # Check if SID_LIST already contains our entry
    if grep -q "SID_NAME.*=.*${PRIMARY_ORACLE_SID}[^A-Za-z0-9_]" "$LISTENER_ORA" || \
       grep -q "SID_NAME.*=.*${PRIMARY_ORACLE_SID}$" "$LISTENER_ORA"; then
        log_info "Listener entry for $PRIMARY_ORACLE_SID already exists"
        log_info "Skipping listener configuration"
    elif grep -q "SID_LIST_LISTENER" "$LISTENER_ORA"; then
        # Use the add_sid_to_listener function from dg_functions.sh
        log_info "SID_LIST_LISTENER exists - adding new SID_DESC entry"
        if add_sid_to_listener "$LISTENER_ORA" "$TEMP_SID_DESC"; then
            log_info "SID_DESC entry added to existing SID_LIST_LISTENER"
        else
            log_warn "Could not auto-insert SID_DESC entry"
            log_warn "Please manually add the following entry to SID_LIST_LISTENER:"
            echo ""
            cat "$TEMP_SID_DESC"
            echo ""
        fi
    else
        # Append new SID_LIST_LISTENER section
        log_info "Adding SID_LIST_LISTENER to listener.ora"
        cat >> "$LISTENER_ORA" <<EOF

# Data Guard primary static registration - Added $(date)
# Includes _DGMGRL service for Data Guard Broker switchover
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = ${PRIMARY_DB_UNIQUE_NAME})
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${PRIMARY_ORACLE_SID})
    )
    (SID_DESC =
      (GLOBAL_DBNAME = ${PRIMARY_DB_UNIQUE_NAME}_DGMGRL)
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${PRIMARY_ORACLE_SID})
    )
  )
EOF
        log_info "Listener entry added successfully"
    fi
else
    # Create new listener.ora
    log_info "Creating new listener.ora"
    cat > "$LISTENER_ORA" <<EOF
# Listener configuration for Data Guard primary
# Created: $(date)

LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = ${PRIMARY_HOSTNAME})(PORT = ${PRIMARY_LISTENER_PORT}))
    )
  )

# Includes _DGMGRL service for Data Guard Broker switchover
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = ${PRIMARY_DB_UNIQUE_NAME})
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${PRIMARY_ORACLE_SID})
    )
    (SID_DESC =
      (GLOBAL_DBNAME = ${PRIMARY_DB_UNIQUE_NAME}_DGMGRL)
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${PRIMARY_ORACLE_SID})
    )
  )
EOF
    log_info "listener.ora created successfully"
fi

rm -f "$TEMP_SID_DESC"

log_info "Listener configuration updated (changes will take effect on next listener reload)"
log_warn "NOTE: Listener was NOT restarted. Reload manually if needed: lsnrctl reload"

# ============================================================
# Check/Enable Force Logging
# ============================================================

log_section "Checking Force Logging"

FORCE_LOGGING=$(run_sql_query "get_force_logging.sql")
FORCE_LOGGING=$(echo "$FORCE_LOGGING" | tr -d ' \n\r')

if [[ "$FORCE_LOGGING" != "YES" ]]; then
    log_info "Enabling FORCE LOGGING..."
    log_cmd "sqlplus / as sysdba:" "ALTER DATABASE FORCE LOGGING"
    run_sql_command "enable_force_logging.sql"
    log_info "FORCE LOGGING enabled"
else
    log_info "FORCE LOGGING is already enabled"
fi

# ============================================================
# Check/Create Standby Redo Logs
# ============================================================

log_section "Checking Standby Redo Logs"

# Get current standby redo log count
CURRENT_STBY_GROUPS=$(run_sql_query "get_standby_redo_count.sql")
CURRENT_STBY_GROUPS=$(echo "$CURRENT_STBY_GROUPS" | tr -d ' \n\r')

REQUIRED_STBY_GROUPS=$STANDBY_REDO_GROUPS

log_info "Current standby redo groups: $CURRENT_STBY_GROUPS"
log_info "Required standby redo groups: $REQUIRED_STBY_GROUPS"

if [[ "$CURRENT_STBY_GROUPS" -lt "$REQUIRED_STBY_GROUPS" ]]; then
    log_info "Creating standby redo logs..."

    # Get the max group number
    MAX_GROUP=$(run_sql_query "get_max_redo_group.sql")
    MAX_GROUP=$(echo "$MAX_GROUP" | tr -d ' \n\r')

    # Get redo log path for standby redo logs
    REDO_PATH=$(run_sql_query "get_redo_member_path.sql")
    REDO_PATH=$(echo "$REDO_PATH" | tr -d ' \n\r')

    # Calculate how many to create
    GROUPS_TO_CREATE=$((REQUIRED_STBY_GROUPS - CURRENT_STBY_GROUPS))

    # Standby redo log groups start at group 11
    STANDBY_REDO_START_GROUP=11

    log_info "Creating $GROUPS_TO_CREATE standby redo log groups starting at group $STANDBY_REDO_START_GROUP..."

    i=0
    while [ "$i" -lt "$GROUPS_TO_CREATE" ]; do
        NEW_GROUP=$((STANDBY_REDO_START_GROUP + i))
        STBY_LOG_FILE="${REDO_PATH}standby_redo${NEW_GROUP}.log"

        log_info "Creating standby redo log group $NEW_GROUP: $STBY_LOG_FILE"
        log_cmd "sqlplus / as sysdba:" "ALTER DATABASE ADD STANDBY LOGFILE GROUP ${NEW_GROUP} ('${STBY_LOG_FILE}') SIZE ${REDO_LOG_SIZE_MB}M"

        run_sql_command "add_standby_logfile.sql" "$NEW_GROUP" "$STBY_LOG_FILE" "$REDO_LOG_SIZE_MB"
        i=$((i + 1))
    done

    log_info "Standby redo logs created successfully"

    # Verify
    echo ""
    log_info "Standby redo log configuration:"
    run_sql_display "get_standby_redo_info.sql"
else
    log_info "Sufficient standby redo logs already exist"
fi

# ============================================================
# Enable Data Guard Broker
# ============================================================

log_section "Enabling Data Guard Broker"

# Check current DG_BROKER_START setting
DG_BROKER_START=$(get_db_parameter "dg_broker_start")
log_info "Current DG_BROKER_START: $DG_BROKER_START"

if [[ "$DG_BROKER_START" != "TRUE" ]]; then
    log_info "Enabling DG_BROKER_START..."
    log_cmd "sqlplus / as sysdba:" "ALTER SYSTEM SET DG_BROKER_START=TRUE SCOPE=BOTH"
    run_sql_command "set_dg_broker_start.sql"
    log_info "DG_BROKER_START enabled"

    # Wait for broker processes to start
    log_info "Waiting for Data Guard Broker processes to start..."
    sleep 5
else
    log_info "DG_BROKER_START is already enabled"
fi

# Verify broker processes are running
DMON_COUNT=$(run_sql_query "get_dmon_count.sql")
DMON_COUNT=$(echo "$DMON_COUNT" | tr -d ' \n\r')

if [[ "$DMON_COUNT" -gt 0 ]]; then
    log_info "Data Guard Broker process (DMON) is running"
else
    log_warn "DMON process not detected yet - it may take a moment to start"
fi

# Set STANDBY_FILE_MANAGEMENT (still needed for automatic file creation)
log_info "Setting STANDBY_FILE_MANAGEMENT=AUTO..."
log_cmd "sqlplus / as sysdba:" "ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT=AUTO SCOPE=BOTH"
run_sql_command "set_standby_file_mgmt.sql"

log_info "Data Guard Broker enabled successfully"
log_info "Note: LOG_ARCHIVE_DEST_2, FAL_SERVER, etc. will be configured by DGMGRL"

# ============================================================
# Configure RMAN Archivelog Deletion Policy
# ============================================================

log_section "Configuring RMAN Archivelog Deletion Policy"

log_info "Setting archivelog deletion policy to SHIPPED TO ALL STANDBY..."
log_cmd "rman target /" "CONFIGURE ARCHIVELOG DELETION POLICY TO SHIPPED TO ALL STANDBY"

run_rman "configure_archivelog_deletion.rman"

log_info "RMAN archivelog deletion policy configured"

# ============================================================
# Verify Network Connectivity to Standby
# ============================================================

log_section "Verifying Network Connectivity"

# Basic port connectivity check (before tnsping which requires listener)
# Port is taken from primary listener configuration (via standby_config.env)
if [[ -z "$STANDBY_LISTENER_PORT" ]]; then
    log_error "STANDBY_LISTENER_PORT not set in configuration"
    log_error "Please re-run 02_generate_standby_config.sh"
    exit 1
fi
STANDBY_PORT="$STANDBY_LISTENER_PORT"
log_info "Testing basic port connectivity to ${STANDBY_HOSTNAME}:${STANDBY_PORT}..."
log_info "(Port ${STANDBY_PORT} taken from primary listener configuration)"

PORT_CHECK_RESULT=0
if command -v nc >/dev/null 2>&1; then
    # Use netcat if available
    if nc -z -w 5 "$STANDBY_HOSTNAME" "$STANDBY_PORT" 2>/dev/null; then
        log_info "PASS: Port ${STANDBY_PORT} is reachable on ${STANDBY_HOSTNAME}"
    else
        log_error "FAILED: Cannot reach port ${STANDBY_PORT} on ${STANDBY_HOSTNAME}"
        log_error "Please check:"
        log_error "  1. Network connectivity between servers"
        log_error "  2. Firewall rules allow port ${STANDBY_PORT}"
        log_error "  3. Hostname '${STANDBY_HOSTNAME}' resolves correctly"
        PORT_CHECK_RESULT=1
    fi
elif command -v timeout >/dev/null 2>&1; then
    # Use bash /dev/tcp with timeout
    if timeout 5 bash -c "echo > /dev/tcp/${STANDBY_HOSTNAME}/${STANDBY_PORT}" 2>/dev/null; then
        log_info "PASS: Port ${STANDBY_PORT} is reachable on ${STANDBY_HOSTNAME}"
    else
        log_error "FAILED: Cannot reach port ${STANDBY_PORT} on ${STANDBY_HOSTNAME}"
        log_error "Please check:"
        log_error "  1. Network connectivity between servers"
        log_error "  2. Firewall rules allow port ${STANDBY_PORT}"
        log_error "  3. Hostname '${STANDBY_HOSTNAME}' resolves correctly"
        PORT_CHECK_RESULT=1
    fi
else
    log_warn "Neither 'nc' nor 'timeout' available - skipping basic port check"
fi

if [[ "$PORT_CHECK_RESULT" -ne 0 ]]; then
    log_error "Network connectivity check failed. Cannot proceed."
    exit 1
fi

# TNS connectivity check (requires listener to be running)
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
echo "Data Guard Broker Status:"
run_sql_display "get_dg_params.sql"

echo ""
echo "Archive Destination 1 (Local):"
run_sql_display "get_archive_dest_1_status.sql"

echo ""
echo "Standby Redo Logs:"
run_sql_display "get_standby_redo_info.sql"

echo ""
echo "Note: LOG_ARCHIVE_DEST_2 and other DG parameters will be"
echo "      configured automatically when the broker is enabled."

# ============================================================
# Summary
# ============================================================

print_summary "SUCCESS" "Primary configured for Data Guard"

echo ""
echo "COMPLETED ACTIONS:"
echo "=================="
echo "  - Configured tnsnames.ora with standby entry"
echo "  - Configured listener.ora with static registration (NOT restarted)"
echo "  - Enabled FORCE LOGGING (if needed)"
echo "  - Created standby redo logs (if needed)"
echo "  - Enabled DG_BROKER_START=TRUE"
echo "  - Set STANDBY_FILE_MANAGEMENT=AUTO"
echo ""
echo "NEXT STEPS:"
echo "==========="
echo ""
echo "On STANDBY server:"
echo "   Run: ./standby/05_clone_standby.sh"
echo ""
echo "IMPORTANT: Ensure the standby listener is running with"
echo "static registration before running the clone script."
echo ""
echo "After cloning, run the broker configuration:"
echo "   ./primary/06_configure_broker.sh"
echo ""
