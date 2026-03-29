#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 5: Clone Standby Database
# ============================================================
# Run this script on the STANDBY database server.
# It performs RMAN duplicate to create the standby database.
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source common functions
source "${COMMON_DIR}/dg_functions.sh"
enable_verbose_mode "$@"

# ============================================================
# Main Script
# ============================================================

print_banner "Step 5: Clone Standby Database"
init_progress 9

# Initialize logging (will reinitialize with DB name later)
init_log "05_clone_standby"

# ============================================================
# Pre-flight Checks
# ============================================================

progress_step "Pre-flight Checks"

check_nfs_mount || exit 1

# Check for standby config files - support unique naming
if ! select_config_file STANDBY_CONFIG_FILE "standby configuration" "${NFS_SHARE}/standby_config_*.env"; then
    log_error "Please run 02_generate_standby_config.sh first"
    exit 1
fi

log_info "Loading standby configuration..."
source "$STANDBY_CONFIG_FILE"

# Reinitialize log with standby DB name
init_log "05_clone_standby_${STANDBY_DB_UNIQUE_NAME}"

# Set Oracle environment
export ORACLE_HOME="$STANDBY_ORACLE_HOME"
export ORACLE_SID="$STANDBY_ORACLE_SID"
export PATH="$ORACLE_HOME/bin:$PATH"

check_oracle_env || exit 1

# Check pfile exists
PFILE="${ORACLE_HOME}/dbs/init${ORACLE_SID}.ora"
if [[ ! -f "$PFILE" ]]; then
    log_error "Parameter file not found: $PFILE"
    log_error "Please run 03_setup_standby_env.sh first"
    exit 1
fi

# Check password file exists
PWD_FILE="${ORACLE_HOME}/dbs/orapw${ORACLE_SID}"
if [[ ! -f "$PWD_FILE" ]]; then
    log_error "Password file not found: $PWD_FILE"
    log_error "Please run 03_setup_standby_env.sh first"
    exit 1
fi

# ============================================================
# Verify Listener Status
# ============================================================

progress_step "Verifying Listener"

log_info "Checking listener status..."
if ! "$ORACLE_HOME/bin/lsnrctl" status > /dev/null 2>&1; then
    log_error "Listener is not running"
    log_error "Please start the listener: lsnrctl start"
    exit 1
fi

# Check for static registration
if ! "$ORACLE_HOME/bin/lsnrctl" status 2>&1 | grep -q "$STANDBY_DB_UNIQUE_NAME"; then
    log_error "Static registration not found for $STANDBY_DB_UNIQUE_NAME"
    log_error "Please verify listener.ora configuration"
    exit 1
fi

log_info "Listener is running with static registration"

# ============================================================
# Review Planned Changes
# ============================================================

progress_step "Reviewing Planned Changes"

print_list_block "This Step Will Change" \
    "Shut down any existing standby instance for ${STANDBY_ORACLE_SID} before restarting it in NOMOUNT." \
    "Run RMAN DUPLICATE FROM ACTIVE DATABASE against ${PRIMARY_TNS_ALIAS} -> ${STANDBY_TNS_ALIAS}." \
    "Create or verify the SPFILE and start managed recovery."

print_list_block "This Step Will Not Change" \
    "It will not create the broker configuration." \
    "It will not modify the primary host files." \
    "It will not remove old standby files for you if a reset is required."

print_list_block "Files and Commands" \
    "PFILE: ${PFILE}" \
    "Password file: ${PWD_FILE}" \
    "RMAN script: ${NFS_SHARE}/logs/rman_duplicate_<timestamp>.rcv" \
    "RMAN log: ${NFS_SHARE}/logs/rman_duplicate_<timestamp>.log"

print_list_block "Recovery If This Step Fails" \
    "This step is not directly restartable once RMAN duplicate starts." \
    "To reset: shut down the standby instance, remove standby datafiles/controlfiles/redo logs, then re-run this step." \
    "Review the RMAN log first to confirm whether cleanup is actually required."

record_next_step "./primary/06_configure_broker.sh"

if [[ "$CHECK_ONLY" == "1" ]]; then
    finish_check_mode "Standby clone preflight complete. No instance or RMAN changes were applied."
fi

# ============================================================
# Test TNS Connectivity
# ============================================================

progress_step "Testing Network Connectivity"

# Test tnsping to primary
log_info "Testing tnsping to primary ($PRIMARY_TNS_ALIAS)..."
if ! "$ORACLE_HOME/bin/tnsping" "$PRIMARY_TNS_ALIAS" > /dev/null 2>&1; then
    log_error "Cannot reach primary database via tnsping"
    log_error "Please verify tnsnames.ora and network connectivity"
    exit 1
fi
log_info "tnsping to primary successful"

# Test tnsping to self (standby)
log_info "Testing tnsping to standby ($STANDBY_TNS_ALIAS)..."
if ! "$ORACLE_HOME/bin/tnsping" "$STANDBY_TNS_ALIAS" > /dev/null 2>&1; then
    log_error "Cannot reach standby via tnsping"
    log_error "Please verify listener and tnsnames.ora"
    exit 1
fi
log_info "tnsping to standby successful"

# ============================================================
# Prompt for SYS Password
# ============================================================

progress_step "Authenticating to Primary"

echo ""
SYS_PASSWORD=$(prompt_password "Enter SYS password for primary database")

# Verify password against primary
log_info "Verifying SYS password against primary..."
if ! verify_sys_password "$SYS_PASSWORD" "$PRIMARY_TNS_ALIAS"; then
    log_error "Invalid SYS password or cannot connect to primary"
    exit 1
fi
log_info "Password verified successfully"

# ============================================================
# Start Instance in NOMOUNT
# ============================================================

progress_step "Starting Standby Instance"

# Check if instance is already running
INSTANCE_STATUS=$(run_sql_query "get_instance_status.sql" 2>&1)

if echo "$INSTANCE_STATUS" | grep -qE "STARTED|MOUNTED|OPEN"; then
    log_warn "Instance is already running"
    log_info "Shutting down existing instance..."
    log_cmd "sqlplus / as sysdba:" "SHUTDOWN ABORT"
    run_sql_command "shutdown_abort.sql"
fi

log_info "Starting instance in NOMOUNT mode..."
log_cmd "sqlplus / as sysdba:" "STARTUP NOMOUNT PFILE='${PFILE}'"
run_sql_command "startup_nomount.sql" "$PFILE"

# Verify NOMOUNT state
INSTANCE_STATUS=$(run_sql_query "get_instance_status.sql")
INSTANCE_STATUS=$(echo "$INSTANCE_STATUS" | tr -d ' \n\r')

if [[ "$INSTANCE_STATUS" != "STARTED" ]]; then
    log_error "Failed to start instance in NOMOUNT mode"
    log_error "Current status: $INSTANCE_STATUS"
    exit 1
fi

log_info "Instance started in NOMOUNT mode"

# ============================================================
# Execute RMAN Duplicate
# ============================================================

progress_step "Executing RMAN Duplicate"

echo ""
echo "================================================================"
echo "Starting RMAN duplicate from active database..."
echo "This process may take a while depending on database size."
echo "Watch the RMAN output below for channel allocation, restore, and recovery progress."
echo "================================================================"
echo ""

if ! confirm_typed_value "This will start the non-restartable RMAN duplicate for ${STANDBY_DB_UNIQUE_NAME}." "${STANDBY_DB_UNIQUE_NAME}"; then
    log_info "RMAN duplicate cancelled by user"
    exit 0
fi

# Create RMAN script
RMAN_SCRIPT="${NFS_SHARE}/logs/rman_duplicate_$(date '+%Y%m%d_%H%M%S').rcv"

# Determine LOG_ARCHIVE_DEST_1 setting based on FRA usage
if [[ "$USE_FRA_FOR_STANDBY" == "YES" ]]; then
    LOG_ARCHIVE_DEST_1_SETTING="LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${STANDBY_DB_UNIQUE_NAME}"
    FRA_SETTINGS="    SET DB_RECOVERY_FILE_DEST='${STANDBY_FRA}'
    SET DB_RECOVERY_FILE_DEST_SIZE='${DB_RECOVERY_FILE_DEST_SIZE}'"
else
    LOG_ARCHIVE_DEST_1_SETTING="LOCATION=${STANDBY_ARCHIVE_DEST} VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${STANDBY_DB_UNIQUE_NAME}"
    FRA_SETTINGS=""
fi

cat > "$RMAN_SCRIPT" <<EOF
# RMAN Duplicate for Standby (Data Guard Broker Managed)
# Generated: $(date)
# Note: DG parameters (LOG_ARCHIVE_DEST_2, FAL_SERVER, etc.) will be
#       configured by Data Guard Broker after duplication completes.

DUPLICATE TARGET DATABASE
  FOR STANDBY
  FROM ACTIVE DATABASE
  DORECOVER
  SPFILE
    SET DB_UNIQUE_NAME='${STANDBY_DB_UNIQUE_NAME}'
    SET CONTROL_FILES='${STANDBY_DATA_PATH}/control01.ctl','${STANDBY_DATA_PATH}/control02.ctl'
    SET LOG_ARCHIVE_DEST_1='${LOG_ARCHIVE_DEST_1_SETTING}'
${FRA_SETTINGS}
    SET DB_FILE_NAME_CONVERT=${DB_FILE_NAME_CONVERT}
    SET LOG_FILE_NAME_CONVERT=${LOG_FILE_NAME_CONVERT}
    SET STANDBY_FILE_MANAGEMENT='AUTO'
    SET DG_BROKER_START='TRUE'
    SET AUDIT_FILE_DEST='${STANDBY_ADMIN_DIR}/adump'
  NOFILENAMECHECK;
EOF

log_info "RMAN script created: $RMAN_SCRIPT"
log_detail "RMAN script contents:"
while IFS= read -r line; do
    log_detail "  $line"
done < "$RMAN_SCRIPT"
record_artifact "rman_script:${RMAN_SCRIPT}"

# Execute RMAN
RMAN_LOG="${NFS_SHARE}/logs/rman_duplicate_$(date '+%Y%m%d_%H%M%S').log"

log_info "Starting RMAN duplicate (logging to: $RMAN_LOG)..."
log_cmd "rman" "TARGET sys/***@${PRIMARY_TNS_ALIAS} AUXILIARY sys/***@${STANDBY_TNS_ALIAS}"
echo ""
confirm_approval_action "Run RMAN duplicate for standby creation" "\"$ORACLE_HOME/bin/rman\" TARGET sys/***@${PRIMARY_TNS_ALIAS} AUXILIARY sys/***@${STANDBY_TNS_ALIAS} @${RMAN_SCRIPT}" || exit 1

# Use tee to display output on screen AND write to log file
# AIX compatible: use temp file to capture exit code instead of PIPESTATUS
RMAN_EXIT_FILE="/tmp/rman_exit_$$"
(
"$ORACLE_HOME/bin/rman" TARGET "sys/${SYS_PASSWORD}@${PRIMARY_TNS_ALIAS}" \
    AUXILIARY "sys/${SYS_PASSWORD}@${STANDBY_TNS_ALIAS}" <<EOF
@${RMAN_SCRIPT}
EXIT;
EOF
echo $? > "$RMAN_EXIT_FILE"
) 2>&1 | tee "$RMAN_LOG"

RMAN_EXIT_CODE=$(cat "$RMAN_EXIT_FILE" 2>/dev/null || echo "1")
rm -f "$RMAN_EXIT_FILE"

# Clear password from memory
SYS_PASSWORD=""

if [[ $RMAN_EXIT_CODE -ne 0 ]]; then
    log_error "RMAN duplicate failed with exit code: $RMAN_EXIT_CODE"
    log_error "Please check the RMAN log: $RMAN_LOG"
    exit 1
fi

log_success "RMAN duplicate completed successfully"
record_artifact "rman_log:${RMAN_LOG}"

# ============================================================
# Create SPFILE and Restart
# ============================================================

progress_step "Finalizing Instance Configuration"

# Check if we're mounted
INSTANCE_STATUS=$(run_sql_query "get_instance_status.sql")
INSTANCE_STATUS=$(echo "$INSTANCE_STATUS" | tr -d ' \n\r')

log_info "Current instance status: $INSTANCE_STATUS"

# The RMAN duplicate with SPFILE option should have created an spfile
# Verify spfile exists
SPFILE="${ORACLE_HOME}/dbs/spfile${ORACLE_SID}.ora"
if [[ -f "$SPFILE" ]]; then
    log_info "SPFILE exists: $SPFILE"
else
    log_info "Creating SPFILE from PFILE..."
    log_cmd "sqlplus / as sysdba:" "CREATE SPFILE FROM PFILE='${PFILE}'"
    run_sql_command "create_spfile.sql" "$PFILE"
fi
record_artifact "spfile:${SPFILE}"

# ============================================================
# Start Managed Recovery
# ============================================================

progress_step "Starting Managed Recovery"

log_info "Starting managed recovery process (MRP)..."
log_cmd "sqlplus / as sysdba:" "ALTER DATABASE MOUNT STANDBY DATABASE"
log_cmd "sqlplus / as sysdba:" "ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION"

run_sql_command "mount_standby.sql"
run_sql_command "start_mrp.sql"

# Verify MRP is running
sleep 5

MRP_STATUS=$(run_sql_query "get_mrp_status.sql")

if echo "$MRP_STATUS" | grep -q "MRP0"; then
    log_info "Managed Recovery Process (MRP) is running"
    log_info "Status: $MRP_STATUS"
else
    log_warn "MRP status could not be verified"
    log_warn "Please check V\$MANAGED_STANDBY manually"
fi

# ============================================================
# Display Status
# ============================================================

log_section "Standby Database Status"

echo ""
echo "Database Role and Status:"
run_sql_display "get_db_status.sql"

echo ""
echo "Managed Standby Processes:"
run_sql_display "get_managed_standby_procs.sql"

echo ""
echo "Archive Log Apply Status:"
run_sql_display "get_archive_apply_status.sql"

# ============================================================
# Configure RMAN Archivelog Deletion Policy
# ============================================================

log_section "Configuring RMAN Archivelog Deletion Policy"

log_info "Setting archivelog deletion policy to SHIPPED TO ALL STANDBY..."
log_cmd "rman target /" "CONFIGURE ARCHIVELOG DELETION POLICY TO SHIPPED TO ALL STANDBY"

run_rman "configure_archivelog_deletion.rman"

log_success "RMAN archivelog deletion policy configured"

# ============================================================
# Summary
# ============================================================

print_summary "SUCCESS" "Standby database created successfully"
print_status_block "Standby Clone Result" \
    "DB_UNIQUE_NAME" "$STANDBY_DB_UNIQUE_NAME" \
    "Instance Status" "$INSTANCE_STATUS" \
    "MRP Verification" "${MRP_STATUS:-Unavailable}" \
    "RMAN Log" "$RMAN_LOG"

print_list_block "Completed Actions" \
    "Started the standby instance in NOMOUNT." \
    "Ran RMAN DUPLICATE FROM ACTIVE DATABASE." \
    "Verified or created the SPFILE." \
    "Started Managed Recovery Process (MRP)." \
    "Configured RMAN archivelog deletion policy."

print_list_block "Next Steps" \
    "On PRIMARY, run ./primary/06_configure_broker.sh to enable broker-managed log shipping." \
    "Then run ./standby/07_verify_dataguard.sh to validate the full setup."

echo ""
echo "Note: Log shipping will not be fully managed until broker configuration is complete."
