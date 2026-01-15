#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 1: Gather Primary Information
# ============================================================
# Run this script on the PRIMARY database server.
# It collects all necessary database information for standby setup.
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

print_banner "Step 1: Gather Primary Info"

# Initialize temporary logging (will reinitialize with DB_UNIQUE_NAME later)
init_log "01_gather_primary_info_${ORACLE_SID}"

# ============================================================
# Pre-flight Checks
# ============================================================

log_section "Pre-flight Checks"

check_oracle_env || exit 1
check_nfs_mount || exit 1
check_db_connection || exit 1

# ============================================================
# Gather Database Identity Information
# ============================================================

log_section "Gathering Database Identity Information"

DB_NAME=$(get_db_parameter "db_name")
DB_UNIQUE_NAME=$(get_db_parameter "db_unique_name")

# Reinitialize log with DB_UNIQUE_NAME for proper identification
init_log "01_gather_primary_info_${DB_UNIQUE_NAME}"
DB_DOMAIN=$(get_db_parameter "db_domain")
INSTANCE_NAME=$(run_sql "SELECT INSTANCE_NAME FROM V\$INSTANCE;")
INSTANCE_NAME=$(echo "$INSTANCE_NAME" | tr -d ' \n\r')

# Get DBID
DBID=$(run_sql "SELECT DBID FROM V\$DATABASE;")
DBID=$(echo "$DBID" | tr -d ' \n\r')

log_info "DB_NAME: $DB_NAME"
log_info "DB_UNIQUE_NAME: $DB_UNIQUE_NAME"
log_info "DB_DOMAIN: $DB_DOMAIN"
log_info "INSTANCE_NAME: $INSTANCE_NAME"
log_info "DBID: $DBID"

# ============================================================
# Gather Oracle Environment Info
# ============================================================

log_section "Gathering Oracle Environment Info"

# AIX-compatible hostname detection
PRIMARY_HOSTNAME=$(hostname 2>/dev/null)
# Try to get FQDN if possible
if command -v host >/dev/null 2>&1; then
    FQDN=$(host "$PRIMARY_HOSTNAME" 2>/dev/null | awk '/has address/{print $1; exit}')
    [[ -n "$FQDN" ]] && PRIMARY_HOSTNAME="$FQDN"
fi
PRIMARY_ORACLE_HOME="$ORACLE_HOME"
PRIMARY_ORACLE_BASE="${ORACLE_BASE:-$(dirname $(dirname $ORACLE_HOME))}"
PRIMARY_ORACLE_SID="$ORACLE_SID"

log_info "Hostname: $PRIMARY_HOSTNAME"
log_info "ORACLE_HOME: $PRIMARY_ORACLE_HOME"
log_info "ORACLE_BASE: $PRIMARY_ORACLE_BASE"
log_info "ORACLE_SID: $PRIMARY_ORACLE_SID"

# ============================================================
# Gather Database Configuration
# ============================================================

log_section "Gathering Database Configuration"

# Character set
NLS_CHARACTERSET=$(get_db_property "NLS_CHARACTERSET")
log_info "NLS_CHARACTERSET: $NLS_CHARACTERSET"

# Block size
DB_BLOCK_SIZE=$(get_db_parameter "db_block_size")
log_info "DB_BLOCK_SIZE: $DB_BLOCK_SIZE"

# Compatible version
COMPATIBLE=$(get_db_parameter "compatible")
log_info "COMPATIBLE: $COMPATIBLE"

# ============================================================
# Gather Redo Log Configuration
# ============================================================

log_section "Gathering Redo Log Configuration"

# Online redo log info
ONLINE_REDO_INFO=$(run_sql_with_header "
SELECT GROUP#, THREAD#, BYTES/1024/1024 AS SIZE_MB, STATUS
FROM V\$LOG ORDER BY GROUP#;
")
echo "$ONLINE_REDO_INFO"

# Get redo log size (in MB) and count
REDO_LOG_SIZE_MB=$(run_sql "SELECT DISTINCT BYTES/1024/1024 FROM V\$LOG WHERE ROWNUM=1;")
REDO_LOG_SIZE_MB=$(echo "$REDO_LOG_SIZE_MB" | tr -d ' \n\r')

ONLINE_REDO_GROUPS=$(run_sql "SELECT COUNT(DISTINCT GROUP#) FROM V\$LOG;")
ONLINE_REDO_GROUPS=$(echo "$ONLINE_REDO_GROUPS" | tr -d ' \n\r')

log_info "Redo log size: ${REDO_LOG_SIZE_MB}MB"
log_info "Online redo groups: $ONLINE_REDO_GROUPS"

# Redo log members/paths
REDO_LOG_PATHS=$(run_sql "SELECT DISTINCT SUBSTR(MEMBER, 1, INSTR(MEMBER, '/', -1)) AS PATH FROM V\$LOGFILE;")
REDO_LOG_PATH=$(echo "$REDO_LOG_PATHS" | head -1 | tr -d ' \n\r')
log_info "Redo log path: $REDO_LOG_PATH"

# ============================================================
# Check Standby Redo Logs
# ============================================================

log_section "Checking Standby Redo Logs"

STANDBY_REDO_COUNT=$(run_sql "SELECT COUNT(DISTINCT GROUP#) FROM V\$STANDBY_LOG;")
STANDBY_REDO_COUNT=$(echo "$STANDBY_REDO_COUNT" | tr -d ' \n\r')

if [[ "$STANDBY_REDO_COUNT" -gt 0 ]]; then
    log_info "Standby redo logs exist: $STANDBY_REDO_COUNT groups"
    STANDBY_REDO_EXISTS="YES"

    run_sql_with_header "
SELECT GROUP#, THREAD#, BYTES/1024/1024 AS SIZE_MB, STATUS
FROM V\$STANDBY_LOG ORDER BY GROUP#;
"
else
    log_warn "No standby redo logs found - they will need to be created"
    STANDBY_REDO_EXISTS="NO"
fi

# ============================================================
# Gather Data File Locations
# ============================================================

log_section "Gathering Data File Locations"

# Get unique data file directories
DATAFILE_DIRS=$(run_sql "
SELECT DISTINCT SUBSTR(NAME, 1, INSTR(NAME, '/', -1)-1)
FROM V\$DATAFILE;
")

PRIMARY_DATA_PATH=$(echo "$DATAFILE_DIRS" | head -1 | tr -d ' \n\r')
log_info "Primary data path: $PRIMARY_DATA_PATH"

# Show all data files
echo "Data files:"
run_sql_with_header "
SELECT FILE#, BYTES/1024/1024 AS SIZE_MB, NAME
FROM V\$DATAFILE ORDER BY FILE#;
"

# Calculate total database size (datafiles + tempfiles + redo logs)
log_info "Calculating total database size..."

DATAFILE_SIZE_MB=$(run_sql "SELECT ROUND(SUM(BYTES)/1024/1024) FROM V\$DATAFILE;")
DATAFILE_SIZE_MB=$(echo "$DATAFILE_SIZE_MB" | tr -d ' \n\r')

TEMPFILE_SIZE_MB=$(run_sql "SELECT NVL(ROUND(SUM(BYTES)/1024/1024), 0) FROM V\$TEMPFILE;")
TEMPFILE_SIZE_MB=$(echo "$TEMPFILE_SIZE_MB" | tr -d ' \n\r')

REDOLOG_SIZE_MB=$(run_sql "SELECT ROUND(SUM(BYTES)/1024/1024) FROM V\$LOG;")
REDOLOG_SIZE_MB=$(echo "$REDOLOG_SIZE_MB" | tr -d ' \n\r')

# Total size with 20% buffer for growth and standby redo logs
TOTAL_DB_SIZE_MB=$((DATAFILE_SIZE_MB + TEMPFILE_SIZE_MB + REDOLOG_SIZE_MB))
REQUIRED_SPACE_MB=$((TOTAL_DB_SIZE_MB * 120 / 100))

log_info "Database size breakdown:"
log_info "  Datafiles:     ${DATAFILE_SIZE_MB} MB"
log_info "  Tempfiles:     ${TEMPFILE_SIZE_MB} MB"
log_info "  Redo logs:     ${REDOLOG_SIZE_MB} MB"
log_info "  Total:         ${TOTAL_DB_SIZE_MB} MB"
log_info "  Required (with 20% buffer): ${REQUIRED_SPACE_MB} MB"

# ============================================================
# Gather Control File Locations
# ============================================================

log_section "Gathering Control File Locations"

CONTROL_FILES=$(get_db_parameter "control_files")
log_info "Control files: $CONTROL_FILES"

# ============================================================
# Gather Archive Log Configuration
# ============================================================

log_section "Gathering Archive Log Configuration"

# Check archive log mode
LOG_MODE=$(run_sql "SELECT LOG_MODE FROM V\$DATABASE;")
LOG_MODE=$(echo "$LOG_MODE" | tr -d ' \n\r')
log_info "Log mode: $LOG_MODE"

# Get archive destination
ARCHIVE_DEST=$(get_db_parameter "log_archive_dest_1")
ARCHIVE_DEST_PATH=""
USE_FRA_FOR_ARCHIVE="NO"

# Extract just the location part
if [[ "$ARCHIVE_DEST" == *"LOCATION="* ]]; then
    ARCHIVE_DEST_PATH=$(echo "$ARCHIVE_DEST" | sed 's/.*LOCATION=\([^ ]*\).*/\1/')
fi

# If no explicit LOCATION, check if using FRA
if [[ -z "$ARCHIVE_DEST_PATH" || "$ARCHIVE_DEST" == *"USE_DB_RECOVERY_FILE_DEST"* ]]; then
    log_info "Archive destination uses Fast Recovery Area (FRA)"
    USE_FRA_FOR_ARCHIVE="YES"
    # Get actual FRA path for reference
    if [[ -n "$DB_RECOVERY_FILE_DEST" ]]; then
        ARCHIVE_DEST_PATH="${DB_RECOVERY_FILE_DEST}/${DB_UNIQUE_NAME}/archivelog"
        log_info "FRA archive path: $ARCHIVE_DEST_PATH"
    fi
fi

if [[ -z "$ARCHIVE_DEST_PATH" ]]; then
    log_warn "Could not determine archive destination path"
    log_warn "Archive logs may be using FRA or a non-standard configuration"
fi
log_info "Archive destination: ${ARCHIVE_DEST_PATH:-'(FRA-managed)'}"

# Check Data Guard Broker status
DG_BROKER_START=$(get_db_parameter "dg_broker_start")
log_info "DG_BROKER_START: $DG_BROKER_START"

# Check for existing DG Broker configuration
if [[ "$DG_BROKER_START" == "TRUE" ]]; then
    log_info "Data Guard Broker is enabled on primary"
    BROKER_CONFIG=$(run_sql "SELECT NAME FROM V\$DG_BROKER_CONFIG WHERE ROWNUM=1;")
    if [[ -n "$BROKER_CONFIG" ]]; then
        log_warn "Existing Broker configuration found: $BROKER_CONFIG"
        log_warn "This setup will create a new configuration"
    fi
fi

# ============================================================
# Gather Recovery Configuration
# ============================================================

log_section "Gathering Recovery Configuration"

DB_RECOVERY_FILE_DEST=$(get_db_parameter "db_recovery_file_dest")
DB_RECOVERY_FILE_DEST_SIZE=$(get_db_parameter "db_recovery_file_dest_size")

log_info "DB_RECOVERY_FILE_DEST: $DB_RECOVERY_FILE_DEST"
log_info "DB_RECOVERY_FILE_DEST_SIZE: $DB_RECOVERY_FILE_DEST_SIZE"

# ============================================================
# Gather Network Configuration
# ============================================================

log_section "Gathering Network Configuration"

# Get listener port - try multiple methods
LISTENER_PORT=""

# Method 1: Get from running listener using lsnrctl status
log_info "Detecting listener port from running listener..."
LSNRCTL_OUTPUT=$("$ORACLE_HOME/bin/lsnrctl" status 2>/dev/null || true)
if [[ -n "$LSNRCTL_OUTPUT" ]]; then
    # Extract PORT from listener output (e.g., "(PORT = 1521)")
    # AIX-compatible: use sed instead of grep -P
    LISTENER_PORT=$(echo "$LSNRCTL_OUTPUT" | sed -n 's/.*PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
    if [[ -n "$LISTENER_PORT" ]]; then
        log_info "Listener port detected from lsnrctl: $LISTENER_PORT"
    fi
fi

# Method 2: Try V$LISTENER_NETWORK view
if [[ -z "$LISTENER_PORT" ]]; then
    LISTENER_PORT=$(run_sql "SELECT VALUE FROM V\$LISTENER_NETWORK WHERE TYPE='LOCAL LISTENER' AND ROWNUM=1;")
    LISTENER_PORT=$(echo "$LISTENER_PORT" | tr -d ' \n\r')
    if [[ -n "$LISTENER_PORT" ]]; then
        log_info "Listener port from V\$LISTENER_NETWORK: $LISTENER_PORT"
    fi
fi

# Method 3: Try local_listener parameter
if [[ -z "$LISTENER_PORT" ]]; then
    LOCAL_LISTENER=$(get_db_parameter "local_listener")
    if [[ -n "$LOCAL_LISTENER" ]]; then
        # AIX-compatible: use sed to extract 4-5 digit port numbers
        LISTENER_PORT=$(echo "$LOCAL_LISTENER" | sed -n 's/.*[^0-9]\([0-9]\{4,5\}\)[^0-9].*/\1/p' | head -1)
        # If sed didn't match, try a simpler pattern
        if [[ -z "$LISTENER_PORT" ]]; then
            LISTENER_PORT=$(echo "$LOCAL_LISTENER" | tr -cs '0-9\n' '\n' | awk 'length>=4 && length<=5 {print; exit}')
        fi
        if [[ -n "$LISTENER_PORT" ]]; then
            log_info "Listener port from local_listener parameter: $LISTENER_PORT"
        fi
    fi
fi

# Default to 1521 if not found
if [[ -z "$LISTENER_PORT" ]]; then
    LISTENER_PORT=1521
    log_warn "Could not detect listener port - defaulting to $LISTENER_PORT"
fi

log_info "Using listener port: $LISTENER_PORT"

# Service names
SERVICE_NAMES=$(get_db_parameter "service_names")
log_info "Service names: $SERVICE_NAMES"

# ============================================================
# Prerequisite Checks
# ============================================================

log_section "Data Guard Prerequisites Check"

PREREQ_PASS=true

# Check ARCHIVELOG mode
if [[ "$LOG_MODE" != "ARCHIVELOG" ]]; then
    log_error "PREREQUISITE FAILED: Database is NOT in ARCHIVELOG mode"
    log_error "To enable: SHUTDOWN IMMEDIATE; STARTUP MOUNT; ALTER DATABASE ARCHIVELOG; ALTER DATABASE OPEN;"
    PREREQ_PASS=false
else
    log_info "PASS: Database is in ARCHIVELOG mode"
fi

# Check FORCE LOGGING
FORCE_LOGGING=$(run_sql "SELECT FORCE_LOGGING FROM V\$DATABASE;")
FORCE_LOGGING=$(echo "$FORCE_LOGGING" | tr -d ' \n\r')

if [[ "$FORCE_LOGGING" != "YES" ]]; then
    log_warn "PREREQUISITE WARNING: FORCE_LOGGING is not enabled"
    log_warn "Recommended: ALTER DATABASE FORCE LOGGING;"
else
    log_info "PASS: FORCE_LOGGING is enabled"
fi

# Check REMOTE_LOGIN_PASSWORDFILE
REMOTE_LOGIN_PWFILE=$(get_db_parameter "remote_login_passwordfile")
if [[ "$REMOTE_LOGIN_PWFILE" != "EXCLUSIVE" ]]; then
    log_error "PREREQUISITE FAILED: REMOTE_LOGIN_PASSWORDFILE is not EXCLUSIVE (current: $REMOTE_LOGIN_PWFILE)"
    PREREQ_PASS=false
else
    log_info "PASS: REMOTE_LOGIN_PASSWORDFILE is EXCLUSIVE"
fi

# Check password file exists
PWD_FILE="${ORACLE_HOME}/dbs/orapw${ORACLE_SID}"
if [[ ! -f "$PWD_FILE" ]]; then
    log_error "PREREQUISITE FAILED: Password file not found: $PWD_FILE"
    PREREQ_PASS=false
else
    log_info "PASS: Password file exists: $PWD_FILE"
fi

# Check standby redo logs
RECOMMENDED_STBY_GROUPS=$((ONLINE_REDO_GROUPS + 1))
if [[ "$STANDBY_REDO_COUNT" -lt "$RECOMMENDED_STBY_GROUPS" ]]; then
    log_warn "PREREQUISITE WARNING: Insufficient standby redo logs"
    log_warn "  Current: $STANDBY_REDO_COUNT groups"
    log_warn "  Recommended: $RECOMMENDED_STBY_GROUPS groups (online groups + 1)"
    log_warn "  Standby redo logs will be created by the setup script"
else
    log_info "PASS: Sufficient standby redo logs configured ($STANDBY_REDO_COUNT groups)"
fi

# ============================================================
# Write Output File
# ============================================================

log_section "Writing Primary Information to NFS"

# Use DB_UNIQUE_NAME in filename to support concurrent builds
OUTPUT_FILE="${NFS_SHARE}/primary_info_${DB_UNIQUE_NAME}.env"

cat > "$OUTPUT_FILE" <<EOF
# ============================================================
# Oracle Data Guard - Primary Database Information
# Generated: $(date)
# Source Host: $PRIMARY_HOSTNAME
# ============================================================

# --- Database Identity ---
DB_NAME="$DB_NAME"
DB_UNIQUE_NAME="$DB_UNIQUE_NAME"
DB_DOMAIN="$DB_DOMAIN"
INSTANCE_NAME="$INSTANCE_NAME"
DBID="$DBID"

# --- Oracle Environment ---
PRIMARY_HOSTNAME="$PRIMARY_HOSTNAME"
PRIMARY_ORACLE_HOME="$PRIMARY_ORACLE_HOME"
PRIMARY_ORACLE_BASE="$PRIMARY_ORACLE_BASE"
PRIMARY_ORACLE_SID="$PRIMARY_ORACLE_SID"

# --- Database Configuration ---
NLS_CHARACTERSET="$NLS_CHARACTERSET"
DB_BLOCK_SIZE="$DB_BLOCK_SIZE"
COMPATIBLE="$COMPATIBLE"

# --- Storage Paths ---
PRIMARY_DATA_PATH="$PRIMARY_DATA_PATH"
PRIMARY_REDO_PATH="$REDO_LOG_PATH"
PRIMARY_ARCHIVE_DEST="$ARCHIVE_DEST_PATH"
CONTROL_FILES="$CONTROL_FILES"

# --- Recovery Configuration ---
DB_RECOVERY_FILE_DEST="$DB_RECOVERY_FILE_DEST"
DB_RECOVERY_FILE_DEST_SIZE="$DB_RECOVERY_FILE_DEST_SIZE"
USE_FRA_FOR_ARCHIVE="$USE_FRA_FOR_ARCHIVE"

# --- Redo Log Configuration ---
REDO_LOG_SIZE_MB="$REDO_LOG_SIZE_MB"
ONLINE_REDO_GROUPS="$ONLINE_REDO_GROUPS"
STANDBY_REDO_EXISTS="$STANDBY_REDO_EXISTS"
STANDBY_REDO_COUNT="$STANDBY_REDO_COUNT"

# --- Database Size ---
DATAFILE_SIZE_MB="$DATAFILE_SIZE_MB"
TEMPFILE_SIZE_MB="$TEMPFILE_SIZE_MB"
REDOLOG_SIZE_MB="$REDOLOG_SIZE_MB"
TOTAL_DB_SIZE_MB="$TOTAL_DB_SIZE_MB"
REQUIRED_SPACE_MB="$REQUIRED_SPACE_MB"

# --- Network Configuration ---
LISTENER_PORT="$LISTENER_PORT"
SERVICE_NAMES="$SERVICE_NAMES"

# --- Prerequisites Status ---
LOG_MODE="$LOG_MODE"
FORCE_LOGGING="$FORCE_LOGGING"
REMOTE_LOGIN_PASSWORDFILE="$REMOTE_LOGIN_PWFILE"

# --- Data Guard Broker ---
DG_BROKER_START="$DG_BROKER_START"
EOF

log_info "Primary info written to: $OUTPUT_FILE"

# Copy password file to NFS share
PWD_DEST="${NFS_SHARE}/orapw${PRIMARY_ORACLE_SID}"
if [[ -f "$PWD_FILE" ]]; then
    cp "$PWD_FILE" "$PWD_DEST"
    chmod 640 "$PWD_DEST"
    log_info "Password file copied to: $PWD_DEST"
fi

# ============================================================
# Summary
# ============================================================

if [[ "$PREREQ_PASS" == "true" ]]; then
    print_summary "SUCCESS" "Primary information gathered successfully"
    echo "Output files:"
    echo "  - Primary info: $OUTPUT_FILE"
    echo "  - Password file: $PWD_DEST"
    echo ""
    echo "Next step: Run 02_generate_standby_config.sh to generate standby configuration"
else
    print_summary "WARNING" "Primary information gathered with prerequisite issues"
    echo ""
    echo "Please resolve the prerequisite issues before proceeding."
    echo "Output files have been created for review:"
    echo "  - Primary info: $OUTPUT_FILE"
    exit 1
fi
