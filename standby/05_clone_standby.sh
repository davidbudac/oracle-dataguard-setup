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

# ============================================================
# Main Script
# ============================================================

print_banner "Step 5: Clone Standby Database"

# Initialize logging
init_log "05_clone_standby"

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

log_section "Verifying Listener"

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
# Test TNS Connectivity
# ============================================================

log_section "Testing Network Connectivity"

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

log_section "Authentication"

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

log_section "Starting Standby Instance"

# Check if instance is already running
INSTANCE_STATUS=$(sqlplus -s / as sysdba <<EOF 2>&1
SET HEADING OFF FEEDBACK OFF
SELECT STATUS FROM V\$INSTANCE;
EXIT;
EOF
)

if echo "$INSTANCE_STATUS" | grep -qE "STARTED|MOUNTED|OPEN"; then
    log_warn "Instance is already running"
    log_info "Shutting down existing instance..."
    sqlplus -s / as sysdba <<EOF
SHUTDOWN ABORT;
EXIT;
EOF
fi

log_info "Starting instance in NOMOUNT mode..."
sqlplus -s / as sysdba <<EOF
STARTUP NOMOUNT PFILE='${PFILE}';
EXIT;
EOF

# Verify NOMOUNT state
INSTANCE_STATUS=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF
SELECT STATUS FROM V\$INSTANCE;
EXIT;
EOF
)
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

log_section "Executing RMAN Duplicate"

echo ""
echo "================================================================"
echo "Starting RMAN duplicate from active database..."
echo "This process may take a while depending on database size."
echo "================================================================"
echo ""

# Create RMAN script
RMAN_SCRIPT="${NFS_SHARE}/logs/rman_duplicate_$(date '+%Y%m%d_%H%M%S').rcv"

cat > "$RMAN_SCRIPT" <<EOF
# RMAN Duplicate for Standby
# Generated: $(date)

DUPLICATE TARGET DATABASE
  FOR STANDBY
  FROM ACTIVE DATABASE
  DORECOVER
  SPFILE
    SET DB_UNIQUE_NAME='${STANDBY_DB_UNIQUE_NAME}'
    SET CONTROL_FILES='${STANDBY_DATA_PATH}/control01.ctl','${STANDBY_DATA_PATH}/control02.ctl'
    SET LOG_ARCHIVE_DEST_1='LOCATION=${STANDBY_ARCHIVE_DEST} VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${STANDBY_DB_UNIQUE_NAME}'
    SET LOG_ARCHIVE_DEST_2='SERVICE=${PRIMARY_TNS_ALIAS} ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=${PRIMARY_DB_UNIQUE_NAME}'
    SET FAL_SERVER='${PRIMARY_TNS_ALIAS}'
    SET FAL_CLIENT='${STANDBY_TNS_ALIAS}'
    SET STANDBY_FILE_MANAGEMENT='AUTO'
    SET LOG_ARCHIVE_CONFIG='DG_CONFIG=(${PRIMARY_DB_UNIQUE_NAME},${STANDBY_DB_UNIQUE_NAME})'
    SET DB_FILE_NAME_CONVERT=${DB_FILE_NAME_CONVERT}
    SET LOG_FILE_NAME_CONVERT=${LOG_FILE_NAME_CONVERT}
    SET AUDIT_FILE_DEST='${STANDBY_ADMIN_DIR}/adump'
  NOFILENAMECHECK;
EOF

log_info "RMAN script created: $RMAN_SCRIPT"

# Execute RMAN
RMAN_LOG="${NFS_SHARE}/logs/rman_duplicate_$(date '+%Y%m%d_%H%M%S').log"

log_info "Starting RMAN duplicate (logging to: $RMAN_LOG)..."
echo ""

"$ORACLE_HOME/bin/rman" TARGET "sys/${SYS_PASSWORD}@${PRIMARY_TNS_ALIAS}" \
    AUXILIARY "sys/${SYS_PASSWORD}@${STANDBY_TNS_ALIAS}" \
    LOG "$RMAN_LOG" <<EOF
@${RMAN_SCRIPT}
EXIT;
EOF

RMAN_EXIT_CODE=$?

# Clear password from memory
SYS_PASSWORD=""

if [[ $RMAN_EXIT_CODE -ne 0 ]]; then
    log_error "RMAN duplicate failed with exit code: $RMAN_EXIT_CODE"
    log_error "Please check the RMAN log: $RMAN_LOG"
    exit 1
fi

log_info "RMAN duplicate completed successfully"

# ============================================================
# Create SPFILE and Restart
# ============================================================

log_section "Finalizing Instance Configuration"

# Check if we're mounted
INSTANCE_STATUS=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF
SELECT STATUS FROM V\$INSTANCE;
EXIT;
EOF
)
INSTANCE_STATUS=$(echo "$INSTANCE_STATUS" | tr -d ' \n\r')

log_info "Current instance status: $INSTANCE_STATUS"

# The RMAN duplicate with SPFILE option should have created an spfile
# Verify spfile exists
SPFILE="${ORACLE_HOME}/dbs/spfile${ORACLE_SID}.ora"
if [[ -f "$SPFILE" ]]; then
    log_info "SPFILE exists: $SPFILE"
else
    log_info "Creating SPFILE from PFILE..."
    sqlplus -s / as sysdba <<EOF
CREATE SPFILE FROM PFILE='${PFILE}';
EXIT;
EOF
fi

# ============================================================
# Start Managed Recovery
# ============================================================

log_section "Starting Managed Recovery"

log_info "Starting managed recovery process (MRP)..."

sqlplus -s / as sysdba <<EOF
-- Ensure database is mounted
ALTER DATABASE MOUNT STANDBY DATABASE;

-- Start managed recovery with real-time apply
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
EXIT;
EOF

# Verify MRP is running
sleep 5

MRP_STATUS=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF
SELECT PROCESS || ':' || STATUS FROM V\$MANAGED_STANDBY WHERE PROCESS = 'MRP0';
EXIT;
EOF
)

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
sqlplus -s / as sysdba <<EOF
SET LINESIZE 150 PAGESIZE 50
SELECT DATABASE_ROLE, OPEN_MODE, PROTECTION_MODE, SWITCHOVER_STATUS
FROM V\$DATABASE;
EXIT;
EOF

echo ""
echo "Managed Standby Processes:"
sqlplus -s / as sysdba <<EOF
SET LINESIZE 150 PAGESIZE 50
SELECT PROCESS, STATUS, THREAD#, SEQUENCE#, BLOCK#
FROM V\$MANAGED_STANDBY
ORDER BY PROCESS;
EXIT;
EOF

echo ""
echo "Archive Log Apply Status:"
sqlplus -s / as sysdba <<EOF
SET LINESIZE 150 PAGESIZE 50
SELECT THREAD#, MAX(SEQUENCE#) AS LAST_APPLIED
FROM V\$ARCHIVED_LOG
WHERE APPLIED = 'YES'
GROUP BY THREAD#;
EXIT;
EOF

# ============================================================
# Summary
# ============================================================

print_summary "SUCCESS" "Standby database created successfully"

echo ""
echo "COMPLETED ACTIONS:"
echo "=================="
echo "  - Started instance in NOMOUNT"
echo "  - Executed RMAN DUPLICATE FOR STANDBY FROM ACTIVE DATABASE"
echo "  - Created SPFILE"
echo "  - Started Managed Recovery Process (MRP)"
echo ""
echo "RMAN LOG: $RMAN_LOG"
echo ""
echo "NEXT STEPS:"
echo "==========="
echo ""
echo "Run verification script:"
echo "   ./06_verify_dataguard.sh"
echo ""
echo "To monitor log apply:"
echo "   SELECT PROCESS, STATUS, SEQUENCE# FROM V\$MANAGED_STANDBY;"
echo ""
echo "To check for gaps:"
echo "   SELECT * FROM V\$ARCHIVE_GAP;"
echo ""
