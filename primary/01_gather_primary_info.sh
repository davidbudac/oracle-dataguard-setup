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
enable_verbose_mode "$@"

# ============================================================
# Main Script
# ============================================================

print_banner "Step 1: Gather Primary Info"
init_progress 12

# ============================================================
# NFS Share Configuration
# ============================================================

# Ask user to confirm or provide NFS share location
confirm_nfs_share

# Initialize temporary logging (will reinitialize with DB_UNIQUE_NAME later)
init_log "01_gather_primary_info_${ORACLE_SID}"

# ============================================================
# Pre-flight Checks
# ============================================================

progress_step "Pre-flight Checks"

check_oracle_env || exit 1
check_nfs_mount || exit 1
check_db_connection || exit 1

# ============================================================
# Verify SYS Password
# ============================================================
# Fail fast: if the SYS password is wrong, RMAN duplicate at
# step 5 cannot authenticate. Catching it here saves the user
# from running through six steps before discovering it.
# ============================================================

progress_step "Verifying SYS Password"

prompt_and_verify_local_sys_password \
    "Enter SYS password for the primary database (will be re-prompted at clone time)" \
    || exit 1
# We only used the password for live verification; do not keep
# it around or write it anywhere. Step 5 prompts again at the
# point RMAN actually needs it.
SYS_PASSWORD=""
unset SYS_PASSWORD

# ============================================================
# Gather Database Identity Information
# ============================================================

progress_step "Gathering Database Identity Information"

DB_NAME=$(get_db_parameter "db_name")
DB_UNIQUE_NAME=$(get_db_parameter "db_unique_name")

# Reinitialize log with DB_UNIQUE_NAME for proper identification
init_log "01_gather_primary_info_${DB_UNIQUE_NAME}"
DB_DOMAIN=$(get_db_parameter "db_domain")
INSTANCE_NAME=$(run_sql_query "get_instance_name.sql")
INSTANCE_NAME=$(echo "$INSTANCE_NAME" | tr -d ' \n\r')

# Get DBID
DBID=$(run_sql_query "get_dbid.sql")
DBID=$(echo "$DBID" | tr -d ' \n\r')

log_info "DB_NAME: $DB_NAME"
log_info "DB_UNIQUE_NAME: $DB_UNIQUE_NAME"
log_info "DB_DOMAIN: $DB_DOMAIN"
log_info "INSTANCE_NAME: $INSTANCE_NAME"
log_info "DBID: $DBID"

# ============================================================
# Gather Oracle Environment Info
# ============================================================

progress_step "Gathering Oracle Environment Information"

# AIX-compatible hostname detection
PRIMARY_HOSTNAME=$(hostname 2>/dev/null)
# Try to get FQDN if possible
if command -v host >/dev/null 2>&1; then
    FQDN=$(host "$PRIMARY_HOSTNAME" 2>/dev/null | awk '/has address/{print $1; exit}' || true)
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

progress_step "Gathering Database Configuration"

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

progress_step "Gathering Redo Log Configuration"

# Online redo log info
ONLINE_REDO_INFO=$(run_sql_display "get_online_redo_info.sql")
echo "$ONLINE_REDO_INFO"

# Get redo log size (in MB) and count
REDO_LOG_SIZE_MB=$(run_sql_query "get_redo_log_size.sql")
REDO_LOG_SIZE_MB=$(echo "$REDO_LOG_SIZE_MB" | tr -d ' \n\r')
if ! is_numeric "$REDO_LOG_SIZE_MB"; then
    log_error "get_redo_log_size.sql returned a non-numeric result: '${REDO_LOG_SIZE_MB}'"
    exit 1
fi

ONLINE_REDO_GROUPS=$(run_sql_query "get_online_redo_count.sql")
ONLINE_REDO_GROUPS=$(echo "$ONLINE_REDO_GROUPS" | tr -d ' \n\r')
if ! is_numeric "$ONLINE_REDO_GROUPS"; then
    log_error "get_online_redo_count.sql returned a non-numeric result: '${ONLINE_REDO_GROUPS}'"
    exit 1
fi

log_info "Redo log size: ${REDO_LOG_SIZE_MB}MB"
log_info "Online redo groups: $ONLINE_REDO_GROUPS"

# Redo log members/paths - capture ALL distinct directories
REDO_LOG_PATHS_RAW=$(run_sql_query "get_redo_log_paths.sql")
PRIMARY_REDO_PATHS=()
while IFS= read -r _line; do
    _line=$(printf '%s' "$_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$_line" ]] && continue
    PRIMARY_REDO_PATHS+=("$_line")
done <<< "$REDO_LOG_PATHS_RAW"
REDO_LOG_PATH="${PRIMARY_REDO_PATHS[0]:-}"
log_info "Redo log path (primary): $REDO_LOG_PATH"
if [[ ${#PRIMARY_REDO_PATHS[@]} -gt 1 ]]; then
    log_info "  Additional redo log directories detected: ${#PRIMARY_REDO_PATHS[@]} total"
    for _p in "${PRIMARY_REDO_PATHS[@]}"; do
        log_info "    $_p"
    done
fi

# ============================================================
# Check Standby Redo Logs
# ============================================================

progress_step "Checking Standby Redo Logs"

STANDBY_REDO_COUNT=$(run_sql_query "get_standby_redo_count.sql")
STANDBY_REDO_COUNT=$(echo "$STANDBY_REDO_COUNT" | tr -d ' \n\r')
if ! is_numeric "$STANDBY_REDO_COUNT"; then
    log_error "get_standby_redo_count.sql returned a non-numeric result: '${STANDBY_REDO_COUNT}'"
    exit 1
fi

if [[ "$STANDBY_REDO_COUNT" -gt 0 ]]; then
    log_info "Standby redo logs exist: $STANDBY_REDO_COUNT groups"
    STANDBY_REDO_EXISTS="YES"

    run_sql_display "get_standby_redo_info.sql"
else
    log_warn "No standby redo logs found - they will need to be created"
    STANDBY_REDO_EXISTS="NO"
fi

# ============================================================
# Gather Data File Locations
# ============================================================

progress_step "Gathering Data File Locations"

# Get unique data file directories - capture ALL distinct directories
DATAFILE_DIRS=$(run_sql_query "get_datafile_dirs.sql")

PRIMARY_DATA_PATHS=()
while IFS= read -r _line; do
    _line=$(printf '%s' "$_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$_line" ]] && continue
    PRIMARY_DATA_PATHS+=("$_line")
done <<< "$DATAFILE_DIRS"

# Merge in tempfile directories - tempfiles on a mount with no
# datafiles would otherwise get no convert pair and no standby
# directory, and the RMAN duplicate would fail.
TEMPFILE_DIRS=$(run_sql_query "get_tempfile_dirs.sql")
while IFS= read -r _line; do
    _line=$(printf '%s' "$_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$_line" ]] && continue
    _found="NO"
    for _p in "${PRIMARY_DATA_PATHS[@]}"; do
        if [[ "$_p" == "$_line" ]]; then
            _found="YES"
            break
        fi
    done
    if [[ "$_found" == "NO" ]]; then
        PRIMARY_DATA_PATHS+=("$_line")
        log_info "  Tempfile-only directory detected: $_line"
    fi
done <<< "$TEMPFILE_DIRS"

# Deterministic primary data path: use the SYSTEM datafile's directory
# (FILE#=1) - on a CDB, the first directory in sorted order can be a
# GUID/seed directory. Fall back to the first gathered directory.
PRIMARY_DATA_PATH=$(run_sql_query "get_system_datafile_dir.sql")
PRIMARY_DATA_PATH=$(printf '%s' "$PRIMARY_DATA_PATH" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if [[ -z "$PRIMARY_DATA_PATH" ]]; then
    PRIMARY_DATA_PATH="${PRIMARY_DATA_PATHS[0]:-}"
fi
log_info "Primary data path: $PRIMARY_DATA_PATH"
if [[ ${#PRIMARY_DATA_PATHS[@]} -gt 1 ]]; then
    log_info "  Additional datafile directories detected: ${#PRIMARY_DATA_PATHS[@]} total"
    for _p in "${PRIMARY_DATA_PATHS[@]}"; do
        log_info "    $_p"
    done
fi

# Per-directory sizes (datafiles + tempfiles) for per-mount disk
# checks on the standby. PRIMARY_DATA_PATH_SIZES_MB is kept EXACTLY
# parallel to PRIMARY_DATA_PATHS (same order, same length); a
# directory with no size reported gets 0.
DATAFILE_DIR_SIZES_RAW=$(run_sql_query "get_datafile_dir_sizes.sql")
PRIMARY_DATA_PATH_SIZES_MB=()
for _p in "${PRIMARY_DATA_PATHS[@]}"; do
    _size=""
    while IFS='|' read -r _dir _mb; do
        _dir=$(printf '%s' "$_dir" | tr -d ' \r')
        _mb=$(printf '%s' "$_mb" | tr -d ' \r')
        if [[ -n "$_dir" && "$_dir" == "$_p" ]]; then
            _size="$_mb"
        fi
    done <<< "$DATAFILE_DIR_SIZES_RAW"
    PRIMARY_DATA_PATH_SIZES_MB+=("${_size:-0}")
    log_info "  Directory size: $_p = ${_size:-0} MB"
done

# Show all data files
echo "Data files:"
run_sql_display "get_datafile_info.sql"

# Calculate total database size (datafiles + tempfiles + redo logs)
log_info "Calculating total database size..."

DATAFILE_SIZE_MB=$(run_sql_query "get_datafile_size.sql")
DATAFILE_SIZE_MB=$(echo "$DATAFILE_SIZE_MB" | tr -d ' \n\r')

TEMPFILE_SIZE_MB=$(run_sql_query "get_tempfile_size.sql")
TEMPFILE_SIZE_MB=$(echo "$TEMPFILE_SIZE_MB" | tr -d ' \n\r')

REDOLOG_SIZE_MB=$(run_sql_query "get_redolog_total_size.sql")
REDOLOG_SIZE_MB=$(echo "$REDOLOG_SIZE_MB" | tr -d ' \n\r')

# Guard the three sizes before they feed shell arithmetic - a failed
# query (or unexpected NULL) must not silently poison the required-space
# calculation with a garbage value.
if ! is_numeric "$DATAFILE_SIZE_MB"; then
    log_error "get_datafile_size.sql returned a non-numeric result: '${DATAFILE_SIZE_MB}'"
    exit 1
fi
if ! is_numeric "$TEMPFILE_SIZE_MB"; then
    log_error "get_tempfile_size.sql returned a non-numeric result: '${TEMPFILE_SIZE_MB}'"
    exit 1
fi
if ! is_numeric "$REDOLOG_SIZE_MB"; then
    log_error "get_redolog_total_size.sql returned a non-numeric result: '${REDOLOG_SIZE_MB}'"
    exit 1
fi

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

progress_step "Gathering Control File Locations"

CONTROL_FILES=$(get_db_parameter "control_files")
log_info "Control files: $CONTROL_FILES"

# ============================================================
# Gather Archive Log Configuration
# ============================================================

progress_step "Gathering Archive Log Configuration"

# Check archive log mode
LOG_MODE=$(run_sql_query "get_log_mode.sql")
LOG_MODE=$(echo "$LOG_MODE" | tr -d ' \n\r')
log_info "Log mode: $LOG_MODE"

# Get archive destination - query V$ARCHIVE_DEST for the resolved path
ARCHIVE_DEST_PATH=""
USE_FRA_FOR_ARCHIVE="NO"

# First try V$ARCHIVE_DEST which shows the actual resolved destination
ARCHIVE_DEST_PATH=$(run_sql_query "get_archive_dest.sql")
ARCHIVE_DEST_PATH=$(printf '%s' "$ARCHIVE_DEST_PATH" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# If V$ARCHIVE_DEST didn't return a path, try the parameter
if [[ -z "$ARCHIVE_DEST_PATH" ]]; then
    ARCHIVE_DEST=$(get_db_parameter "log_archive_dest_1")
    # Check if using FRA
    if [[ "$ARCHIVE_DEST" == *"USE_DB_RECOVERY_FILE_DEST"* ]]; then
        USE_FRA_FOR_ARCHIVE="YES"
        log_info "Archive destination uses Fast Recovery Area (FRA)"
    # Extract just the location part if it contains LOCATION=
    elif [[ "$ARCHIVE_DEST" == *"LOCATION="* ]]; then
        ARCHIVE_DEST_PATH=$(echo "$ARCHIVE_DEST" | sed 's/.*LOCATION=\([^ ]*\).*/\1/')
    elif [[ -n "$ARCHIVE_DEST" ]]; then
        ARCHIVE_DEST_PATH="$ARCHIVE_DEST"
    fi
fi

# If still empty, try to derive from FRA or existing archives
if [[ -z "$ARCHIVE_DEST_PATH" ]]; then
    FRA_DEST=$(get_db_parameter "db_recovery_file_dest")
    if [[ -n "$FRA_DEST" ]]; then
        USE_FRA_FOR_ARCHIVE="YES"
        ARCHIVE_DEST_PATH="${FRA_DEST}/${DB_UNIQUE_NAME}/archivelog"
        log_info "Archive destination (derived from FRA): $ARCHIVE_DEST_PATH"
    else
        # Last resort: query V$ARCHIVED_LOG for an existing archive location
        ARCHIVE_DEST_PATH=$(run_sql_query "get_archive_dest_from_logs.sql")
        ARCHIVE_DEST_PATH=$(printf '%s' "$ARCHIVE_DEST_PATH" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -n "$ARCHIVE_DEST_PATH" ]]; then
            log_info "Archive destination (from archived logs): $ARCHIVE_DEST_PATH"
        else
            log_warn "Could not determine archive destination path"
        fi
    fi
else
    log_info "Archive destination: $ARCHIVE_DEST_PATH"
fi

# Check Data Guard Broker status
DG_BROKER_START=$(get_db_parameter "dg_broker_start")
log_info "DG_BROKER_START: $DG_BROKER_START"

# Check for existing DG Broker configuration
if [[ "$DG_BROKER_START" == "TRUE" ]]; then
    log_info "Data Guard Broker is enabled on primary"
    BROKER_CONFIG=$(run_sql_query "get_broker_config_name.sql")
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
    LISTENER_PORT=$(run_sql_query "get_listener_port.sql")
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

progress_step "Running Data Guard Prerequisite Checks"

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
FORCE_LOGGING=$(run_sql_query "get_force_logging.sql")
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

progress_step "Writing Primary Information to NFS"

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
DB_BLOCK_SIZE="$(strip_whitespace "$DB_BLOCK_SIZE")"
COMPATIBLE="$COMPATIBLE"

# --- Storage Paths ---
# *_PATH is a single representative directory (SYSTEM datafile's
# directory for DATA, first directory otherwise) and stays for
# backward compatibility.
# *_PATHS is the FULL list of distinct directories (bash array literal)
# - step 2 uses it to build a full DB_FILE_NAME_CONVERT covering every
# primary directory, and step 3 uses the standby equivalent to create
# all required directories.
PRIMARY_DATA_PATH="$PRIMARY_DATA_PATH"
PRIMARY_DATA_PATHS=(
$(printf '    "%s"\n' "${PRIMARY_DATA_PATHS[@]}")
)
# *_SIZES_MB is parallel to PRIMARY_DATA_PATHS (same order/length):
# size in MB (datafiles + tempfiles) of each directory, for
# per-mount disk space checks on the standby.
PRIMARY_DATA_PATH_SIZES_MB=(
$(printf '    "%s"\n' "${PRIMARY_DATA_PATH_SIZES_MB[@]}")
)
PRIMARY_REDO_PATH="$REDO_LOG_PATH"
PRIMARY_REDO_PATHS=(
$(printf '    "%s"\n' "${PRIMARY_REDO_PATHS[@]}")
)
PRIMARY_ARCHIVE_DEST="$ARCHIVE_DEST_PATH"
CONTROL_FILES="$CONTROL_FILES"

# --- Recovery Configuration ---
DB_RECOVERY_FILE_DEST="$DB_RECOVERY_FILE_DEST"
DB_RECOVERY_FILE_DEST_SIZE="$DB_RECOVERY_FILE_DEST_SIZE"
USE_FRA_FOR_ARCHIVE="$USE_FRA_FOR_ARCHIVE"

# --- Redo Log Configuration ---
REDO_LOG_SIZE_MB="$(strip_whitespace "$REDO_LOG_SIZE_MB")"
ONLINE_REDO_GROUPS="$(strip_whitespace "$ONLINE_REDO_GROUPS")"
STANDBY_REDO_EXISTS="$STANDBY_REDO_EXISTS"
STANDBY_REDO_COUNT="$(strip_whitespace "$STANDBY_REDO_COUNT")"

# --- Database Size ---
DATAFILE_SIZE_MB="$(strip_whitespace "$DATAFILE_SIZE_MB")"
TEMPFILE_SIZE_MB="$(strip_whitespace "$TEMPFILE_SIZE_MB")"
REDOLOG_SIZE_MB="$(strip_whitespace "$REDOLOG_SIZE_MB")"
TOTAL_DB_SIZE_MB="$(strip_whitespace "$TOTAL_DB_SIZE_MB")"
REQUIRED_SPACE_MB="$(strip_whitespace "$REQUIRED_SPACE_MB")"

# --- Network Configuration ---
LISTENER_PORT="$(strip_whitespace "$LISTENER_PORT")"
SERVICE_NAMES="$SERVICE_NAMES"

# --- Prerequisites Status ---
LOG_MODE="$LOG_MODE"
FORCE_LOGGING="$FORCE_LOGGING"
REMOTE_LOGIN_PASSWORDFILE="$REMOTE_LOGIN_PWFILE"

# --- Data Guard Broker ---
DG_BROKER_START="$DG_BROKER_START"
EOF

log_info "Primary info written to: $OUTPUT_FILE"

# Copy password file to NFS share. chmod 600 (owner-only): this file
# contains the SYS password hash and the share is group-readable, so
# don't leave it group-readable too. Run common/cleanup_nfs_artifacts.sh
# once Data Guard setup is verified to remove it from the share entirely.
PWD_DEST="${NFS_SHARE}/orapw${PRIMARY_ORACLE_SID}"
if [[ -f "$PWD_FILE" ]]; then
    confirm_approval_action "Copy primary password file to NFS share" "cp $PWD_FILE $PWD_DEST && chmod 600 $PWD_DEST" || exit 1
    cp "$PWD_FILE" "$PWD_DEST"
    chmod 600 "$PWD_DEST"
    log_success "Password file copied to: $PWD_DEST"
fi

# ============================================================
# Summary
# ============================================================

if [[ "$PREREQ_PASS" == "true" ]]; then
    print_summary "SUCCESS" "Primary information gathered successfully"
    print_status_block "Primary Snapshot" \
        "Primary Host" "$PRIMARY_HOSTNAME" \
        "DB_UNIQUE_NAME" "$DB_UNIQUE_NAME" \
        "Instance" "$INSTANCE_NAME" \
        "Redo Size" "${REDO_LOG_SIZE_MB} MB" \
        "Required Space" "${REQUIRED_SPACE_MB} MB"
    print_list_block "Generated Files" \
        "Primary info: $OUTPUT_FILE" \
        "Password file: $PWD_DEST"
    print_list_block "Next Step" \
        "Run ./primary/02_generate_standby_config.sh to build the standby configuration."
else
    print_summary "WARNING" "Primary information gathered with prerequisite issues"
    print_status_block "Review Required" \
        "Primary Host" "$PRIMARY_HOSTNAME" \
        "DB_UNIQUE_NAME" "$DB_UNIQUE_NAME" \
        "ARCHIVELOG Mode" "$LOG_MODE" \
        "FORCE_LOGGING" "$FORCE_LOGGING" \
        "REMOTE_LOGIN_PASSWORDFILE" "$REMOTE_LOGIN_PWFILE"
    print_list_block "Generated Files" \
        "Primary info: $OUTPUT_FILE"
    echo ""
    echo "Please resolve the prerequisite issues before proceeding."
    exit 1
fi
