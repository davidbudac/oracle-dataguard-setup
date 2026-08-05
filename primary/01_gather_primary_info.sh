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
init_progress 13

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
INSTANCE_NAME=$(echo "$INSTANCE_NAME" | tr -d '[:space:]')

# Get DBID
DBID=$(run_sql_query "get_dbid.sql")
DBID=$(echo "$DBID" | tr -d '[:space:]')

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
REDO_LOG_SIZE_MB=$(echo "$REDO_LOG_SIZE_MB" | tr -d '[:space:]')
if ! is_numeric "$REDO_LOG_SIZE_MB"; then
    log_error "get_redo_log_size.sql returned a non-numeric result: '${REDO_LOG_SIZE_MB}'"
    exit 1
fi

ONLINE_REDO_GROUPS=$(run_sql_query "get_online_redo_count.sql")
ONLINE_REDO_GROUPS=$(echo "$ONLINE_REDO_GROUPS" | tr -d '[:space:]')
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
STANDBY_REDO_COUNT=$(echo "$STANDBY_REDO_COUNT" | tr -d '[:space:]')
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
        _dir=$(printf '%s' "$_dir" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        _mb=$(printf '%s' "$_mb" | tr -d '[:space:]')
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
DATAFILE_SIZE_MB=$(echo "$DATAFILE_SIZE_MB" | tr -d '[:space:]')

TEMPFILE_SIZE_MB=$(run_sql_query "get_tempfile_size.sql")
TEMPFILE_SIZE_MB=$(echo "$TEMPFILE_SIZE_MB" | tr -d '[:space:]')

REDOLOG_SIZE_MB=$(run_sql_query "get_redolog_total_size.sql")
REDOLOG_SIZE_MB=$(echo "$REDOLOG_SIZE_MB" | tr -d '[:space:]')

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
LOG_MODE=$(echo "$LOG_MODE" | tr -d '[:space:]')
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
# Archive Log and Redo Generation Statistics
# ============================================================
# Sizing input for the standby build: the redo generation rate
# drives the bandwidth redo transport needs, how much archive space
# the standby has to hold, and whether the online redo logs (and
# therefore the standby redo logs sized from them) are big enough.
# V$ARCHIVED_LOG only retains as much history as
# CONTROL_FILE_RECORD_KEEP_TIME allows (7 days by default), so the
# window actually observed is reported next to the numbers.
#
# Everything here is informational: a query that fails or returns
# nothing degrades to zeros and a warning, and never fails the step.
# ============================================================

progress_step "Analyzing Archive Log and Redo Generation"

# AIX-compatible field extraction (no here-strings, no GNU-only tools)
pipe_field() {
    echo "$1" | awk -F'|' -v i="$2" '{print $i}'
}

# Assign a pipe field to a variable only when it is a plain integer -
# a failed query must not poison the arithmetic below or the .env.
# bash 3.2 has no namerefs, hence eval on an is_numeric-validated value.
assign_numeric_field() {
    local _val
    _val=$(pipe_field "$2" "$3")
    if is_numeric "$_val"; then
        eval "$1=\$_val"
    fi
}

# Labels (timestamps, "n/a") go into the .env, so keep them to
# characters that need no quoting and cannot expand when it is sourced.
sanitize_label() {
    echo "$1" | sed 's/[^A-Za-z0-9:_./-]//g'
}

# Defaults: the .env is always written with well-formed values.
REDO_STATS_SOURCE="ARCHIVED_LOG_HISTORY"
REDO_HISTORY_DAYS="0"
REDO_ARCHIVED_LOG_COUNT="0"
REDO_TOTAL_MB="0"
REDO_AVG_MB_PER_DAY="0"
REDO_PEAK_MB_PER_DAY="0"
REDO_PEAK_DAY="n/a"
REDO_AVG_MB_PER_HOUR="0"
REDO_PEAK_MB_PER_HOUR="0"
REDO_PEAK_HOUR="n/a"
REDO_AVG_SWITCHES_PER_DAY="0"
REDO_PEAK_SWITCHES_PER_HOUR="0"

ARCHIVE_LOGS_ON_DISK="0"
ARCHIVE_SIZE_ON_DISK_MB="0"
ARCHIVE_FRA_MB="0"
ARCHIVE_OLDEST_SEQ="0"
ARCHIVE_NEWEST_SEQ="0"
ARCHIVE_OLDEST_TIME="n/a"
ARCHIVE_NEWEST_TIME="n/a"

# --- Archived logs currently on disk ---
ARCHIVE_DISK_RAW=$(run_sql_query "get_archive_disk_usage_pipe.sql" | tr -d ' \t\n\r')
if [[ "$ARCHIVE_DISK_RAW" == *"|"* ]]; then
    assign_numeric_field ARCHIVE_LOGS_ON_DISK "$ARCHIVE_DISK_RAW" 1
    assign_numeric_field ARCHIVE_SIZE_ON_DISK_MB "$ARCHIVE_DISK_RAW" 2
    assign_numeric_field ARCHIVE_FRA_MB "$ARCHIVE_DISK_RAW" 3
    assign_numeric_field ARCHIVE_OLDEST_SEQ "$ARCHIVE_DISK_RAW" 4
    assign_numeric_field ARCHIVE_NEWEST_SEQ "$ARCHIVE_DISK_RAW" 5
    ARCHIVE_OLDEST_TIME=$(sanitize_label "$(pipe_field "$ARCHIVE_DISK_RAW" 6)")
    ARCHIVE_NEWEST_TIME=$(sanitize_label "$(pipe_field "$ARCHIVE_DISK_RAW" 7)")
else
    log_warn "Could not read archived log inventory from V\$ARCHIVED_LOG"
fi

# --- Redo generation rate over the retained history ---
REDO_STATS_RAW=$(run_sql_query "get_redo_stats_pipe.sql" | tr -d ' \t\n\r')
if [[ "$REDO_STATS_RAW" == *"|"* ]]; then
    REDO_HISTORY_DAYS=$(sanitize_label "$(pipe_field "$REDO_STATS_RAW" 1)")
    assign_numeric_field REDO_ARCHIVED_LOG_COUNT "$REDO_STATS_RAW" 2
    assign_numeric_field REDO_TOTAL_MB "$REDO_STATS_RAW" 3
    assign_numeric_field REDO_AVG_MB_PER_DAY "$REDO_STATS_RAW" 4
    assign_numeric_field REDO_PEAK_MB_PER_DAY "$REDO_STATS_RAW" 5
    REDO_PEAK_DAY=$(sanitize_label "$(pipe_field "$REDO_STATS_RAW" 6)")
    assign_numeric_field REDO_AVG_MB_PER_HOUR "$REDO_STATS_RAW" 7
    assign_numeric_field REDO_PEAK_MB_PER_HOUR "$REDO_STATS_RAW" 8
    REDO_PEAK_HOUR=$(sanitize_label "$(pipe_field "$REDO_STATS_RAW" 9)")
    assign_numeric_field REDO_AVG_SWITCHES_PER_DAY "$REDO_STATS_RAW" 10
    assign_numeric_field REDO_PEAK_SWITCHES_PER_HOUR "$REDO_STATS_RAW" 11
else
    log_warn "Could not read redo generation statistics from V\$ARCHIVED_LOG"
fi

# Fresh (or freshly restarted) database: no useful archive history.
# Fall back to redo generated since instance startup so the sizing
# numbers below are based on something rather than on zeros.
if [[ "$REDO_ARCHIVED_LOG_COUNT" -eq 0 ]]; then
    log_warn "No archived logs in the last 30 days - redo rate cannot be derived from archive history"
    log_warn "  Falling back to redo generated since instance startup (V\$SYSSTAT)"
    log_warn "  Re-run this step after a representative workload period for meaningful sizing"

    STARTUP_STATS_RAW=$(run_sql_query "get_redo_since_startup_pipe.sql" | tr -d ' \t\n\r')
    if [[ "$STARTUP_STATS_RAW" == *"|"* ]]; then
        REDO_STATS_SOURCE="INSTANCE_STARTUP"
        assign_numeric_field REDO_TOTAL_MB "$STARTUP_STATS_RAW" 1
        REDO_HISTORY_DAYS=$(sanitize_label "$(pipe_field "$STARTUP_STATS_RAW" 2)")
        assign_numeric_field REDO_AVG_MB_PER_HOUR "$STARTUP_STATS_RAW" 3
        # Uptime is reported in hours by the query; the .env stays in days.
        REDO_HISTORY_DAYS=$(awk -v h="$REDO_HISTORY_DAYS" 'BEGIN{printf "%.2f", h/24}')
        REDO_AVG_MB_PER_DAY=$((REDO_AVG_MB_PER_HOUR * 24))
        # Without per-hour history there is no observed peak; the average
        # is the only honest estimate, and it is labelled as such below.
        REDO_PEAK_MB_PER_HOUR="$REDO_AVG_MB_PER_HOUR"
        REDO_PEAK_MB_PER_DAY="$REDO_AVG_MB_PER_DAY"
    else
        log_warn "Could not read redo generated since instance startup either - rates reported as 0"
    fi
fi

# --- Derived transport sizing ---
# Peak hour drives the link: a day of average traffic still falls behind
# during the busiest hour if the link is sized on the daily average.
# 30% headroom covers protocol overhead plus catch-up after a gap.
REDO_AVG_MB_PER_SEC=$(awk -v m="$REDO_AVG_MB_PER_HOUR" 'BEGIN{printf "%.2f", m/3600}')
REDO_PEAK_MB_PER_SEC=$(awk -v m="$REDO_PEAK_MB_PER_HOUR" 'BEGIN{printf "%.2f", m/3600}')
REDO_REQUIRED_BANDWIDTH_MBPS=$(awk -v m="$REDO_PEAK_MB_PER_HOUR" 'BEGIN{printf "%.1f", m*8*1.3/3600}')
REDO_AVG_GB_PER_DAY=$(awk -v m="$REDO_AVG_MB_PER_DAY" 'BEGIN{printf "%.2f", m/1024}')
REDO_PEAK_GB_PER_DAY=$(awk -v m="$REDO_PEAK_MB_PER_DAY" 'BEGIN{printf "%.2f", m/1024}')

# --- Detail tables (only meaningful with archive history) ---
if [[ "$REDO_ARCHIVED_LOG_COUNT" -gt 0 ]]; then
    echo ""
    echo "Daily redo generation (last 14 days, PEAK_HR_* = busiest hour of that day):"
    run_sql_display "get_redo_daily_stats.sql"

    echo ""
    echo "Redo generation by hour of day (last 7 days, AVG_MB = per day of window):"
    run_sql_display "get_redo_hourly_profile.sql"
fi

print_status_block "Archive Log Overview" \
    "Log Mode" "$LOG_MODE" \
    "Archive Destination" "${ARCHIVE_DEST_PATH:-<not detected>}" \
    "Archives to FRA" "$USE_FRA_FOR_ARCHIVE" \
    "Logs on Disk" "${ARCHIVE_LOGS_ON_DISK} (${ARCHIVE_SIZE_ON_DISK_MB} MB, ${ARCHIVE_FRA_MB} MB in FRA)" \
    "Sequence Range" "${ARCHIVE_OLDEST_SEQ} - ${ARCHIVE_NEWEST_SEQ}" \
    "Oldest Archive" "$ARCHIVE_OLDEST_TIME" \
    "Newest Archive" "$ARCHIVE_NEWEST_TIME"

if [[ "$REDO_STATS_SOURCE" == "INSTANCE_STARTUP" ]]; then
    _redo_window_label="${REDO_HISTORY_DAYS} days since instance startup (no archive history)"
    _redo_peak_suffix=" (estimated - no per-hour history)"
else
    _redo_window_label="${REDO_HISTORY_DAYS} days of archive history, ${REDO_ARCHIVED_LOG_COUNT} logs"
    _redo_peak_suffix=""
fi

print_status_block "Redo Generation Statistics" \
    "Observed Window" "$_redo_window_label" \
    "Total Redo" "${REDO_TOTAL_MB} MB" \
    "Average per Day" "${REDO_AVG_MB_PER_DAY} MB (${REDO_AVG_GB_PER_DAY} GB)" \
    "Peak Day" "${REDO_PEAK_MB_PER_DAY} MB (${REDO_PEAK_GB_PER_DAY} GB) on ${REDO_PEAK_DAY}" \
    "Average per Hour" "${REDO_AVG_MB_PER_HOUR} MB (${REDO_AVG_MB_PER_SEC} MB/s)" \
    "Peak Hour" "${REDO_PEAK_MB_PER_HOUR} MB (${REDO_PEAK_MB_PER_SEC} MB/s) at ${REDO_PEAK_HOUR}${_redo_peak_suffix}" \
    "Log Switches per Day" "${REDO_AVG_SWITCHES_PER_DAY} avg" \
    "Peak Switches per Hour" "${REDO_PEAK_SWITCHES_PER_HOUR}" \
    "Redo Transport Link" "${REDO_REQUIRED_BANDWIDTH_MBPS} Mbps minimum (peak hour + 30% headroom)" \
    "Standby Archive Space" "${REDO_AVG_GB_PER_DAY} GB per day of retention"

# --- Sizing sanity checks ---

# Frequent log switches mean undersized online redo logs. Oracle's
# guidance is a switch every 15-20 minutes (3-4 per hour); the standby
# redo logs created later must match the online log size, so fixing this
# is much cheaper before the standby exists than after.
if [[ "$REDO_ARCHIVED_LOG_COUNT" -eq 0 ]]; then
    log_info "Log switch rate: not assessed (no archive history to measure)"
elif [[ "$REDO_PEAK_SWITCHES_PER_HOUR" -gt 12 ]]; then
    log_warn "Peak log switch rate is ${REDO_PEAK_SWITCHES_PER_HOUR}/hour (redo logs are ${REDO_LOG_SIZE_MB}MB)"
    log_warn "  Recommended: one switch every 15-20 minutes (3-4 per hour)"
    log_warn "  Consider larger online redo logs BEFORE the standby is built -"
    log_warn "  standby redo logs must match the online log size."
elif [[ "$REDO_PEAK_SWITCHES_PER_HOUR" -gt 6 ]]; then
    log_info "Peak log switch rate: ${REDO_PEAK_SWITCHES_PER_HOUR}/hour (redo logs are ${REDO_LOG_SIZE_MB}MB) - acceptable but on the high side"
else
    log_info "Peak log switch rate: ${REDO_PEAK_SWITCHES_PER_HOUR}/hour - within the recommended range"
fi

# FRA that cannot hold a day of redo will start deleting (or stalling)
# quickly once the standby build adds its own traffic.
if [[ -n "$DB_RECOVERY_FILE_DEST" ]] && is_numeric "$DB_RECOVERY_FILE_DEST_SIZE"; then
    FRA_SIZE_MB=$((DB_RECOVERY_FILE_DEST_SIZE / 1024 / 1024))
    log_info "FRA size: ${FRA_SIZE_MB} MB"
    if [[ "$REDO_AVG_MB_PER_DAY" -gt 0 && "$FRA_SIZE_MB" -lt "$REDO_AVG_MB_PER_DAY" ]]; then
        log_warn "FRA (${FRA_SIZE_MB} MB) is smaller than one day of redo (${REDO_AVG_MB_PER_DAY} MB)"
        log_warn "  Size the FRA - on BOTH sides - for the archive retention you need."
    fi
fi

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
    LISTENER_PORT=$(echo "$LISTENER_PORT" | tr -d '[:space:]')
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
FORCE_LOGGING=$(echo "$FORCE_LOGGING" | tr -d '[:space:]')

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

# --- Archive Log Inventory (snapshot at gather time) ---
ARCHIVE_LOGS_ON_DISK="$(strip_whitespace "$ARCHIVE_LOGS_ON_DISK")"
ARCHIVE_SIZE_ON_DISK_MB="$(strip_whitespace "$ARCHIVE_SIZE_ON_DISK_MB")"
ARCHIVE_FRA_MB="$(strip_whitespace "$ARCHIVE_FRA_MB")"
ARCHIVE_OLDEST_SEQ="$(strip_whitespace "$ARCHIVE_OLDEST_SEQ")"
ARCHIVE_NEWEST_SEQ="$(strip_whitespace "$ARCHIVE_NEWEST_SEQ")"
ARCHIVE_OLDEST_TIME="$ARCHIVE_OLDEST_TIME"
ARCHIVE_NEWEST_TIME="$ARCHIVE_NEWEST_TIME"

# --- Redo Generation Statistics ---
# REDO_STATS_SOURCE is ARCHIVED_LOG_HISTORY (derived from V\$ARCHIVED_LOG,
# limited to CONTROL_FILE_RECORD_KEEP_TIME) or INSTANCE_STARTUP (fallback
# from V\$SYSSTAT when no archive history exists - peak == average there).
# Rates drive redo transport bandwidth and standby archive space sizing.
REDO_STATS_SOURCE="$REDO_STATS_SOURCE"
REDO_HISTORY_DAYS="$REDO_HISTORY_DAYS"
REDO_ARCHIVED_LOG_COUNT="$(strip_whitespace "$REDO_ARCHIVED_LOG_COUNT")"
REDO_TOTAL_MB="$(strip_whitespace "$REDO_TOTAL_MB")"
REDO_AVG_MB_PER_DAY="$(strip_whitespace "$REDO_AVG_MB_PER_DAY")"
REDO_PEAK_MB_PER_DAY="$(strip_whitespace "$REDO_PEAK_MB_PER_DAY")"
REDO_PEAK_DAY="$REDO_PEAK_DAY"
REDO_AVG_MB_PER_HOUR="$(strip_whitespace "$REDO_AVG_MB_PER_HOUR")"
REDO_PEAK_MB_PER_HOUR="$(strip_whitespace "$REDO_PEAK_MB_PER_HOUR")"
REDO_PEAK_HOUR="$REDO_PEAK_HOUR"
REDO_AVG_SWITCHES_PER_DAY="$(strip_whitespace "$REDO_AVG_SWITCHES_PER_DAY")"
REDO_PEAK_SWITCHES_PER_HOUR="$(strip_whitespace "$REDO_PEAK_SWITCHES_PER_HOUR")"
REDO_REQUIRED_BANDWIDTH_MBPS="$REDO_REQUIRED_BANDWIDTH_MBPS"

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
        "Required Space" "${REQUIRED_SPACE_MB} MB" \
        "Redo Generated" "${REDO_AVG_GB_PER_DAY} GB/day (peak ${REDO_PEAK_MB_PER_HOUR} MB/h)" \
        "Redo Transport Link" "${REDO_REQUIRED_BANDWIDTH_MBPS} Mbps minimum"
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
