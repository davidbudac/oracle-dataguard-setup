#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 3: Setup Standby Environment
# ============================================================
# Run this script on the STANDBY database server.
# It prepares the environment for RMAN duplicate.
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

print_banner "Step 3: Setup Standby Environment"
init_progress 9

# Initialize logging (will reinitialize with DB name later)
init_log "03_setup_standby_env"

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
init_log "03_setup_standby_env_${STANDBY_DB_UNIQUE_NAME}"

# Verify we're on the correct host
# AIX-compatible hostname detection
CURRENT_HOST=$(hostname 2>/dev/null)
log_info "Current hostname: $CURRENT_HOST"
log_info "Expected standby hostname: $STANDBY_HOSTNAME"

if [[ "$CURRENT_HOST" != "$STANDBY_HOSTNAME" ]]; then
    log_warn "Current hostname does not match expected standby hostname"
    if ! confirm_proceed "Continue anyway?"; then
        exit 1
    fi
fi

# ============================================================
# Validate Disk Space
# ============================================================

progress_step "Validating Disk Space"

if [[ -n "$REQUIRED_SPACE_MB" && "$REQUIRED_SPACE_MB" -gt 0 ]]; then
    log_info "Primary database requires approximately ${REQUIRED_SPACE_MB} MB (including 20% buffer)"
    log_info "  Datafiles:  ${DATAFILE_SIZE_MB:-N/A} MB"
    log_info "  Tempfiles:  ${TEMPFILE_SIZE_MB:-N/A} MB"
    log_info "  Redo logs:  ${REDOLOG_SIZE_MB:-N/A} MB"

    # Get the parent directory of standby data path
    STANDBY_DATA_PARENT=$(dirname "$STANDBY_DATA_PATH")

    # Ensure the parent directory exists for df check
    if [[ -d "$STANDBY_DATA_PARENT" ]]; then
        CHECK_PATH="$STANDBY_DATA_PARENT"
    elif [[ -d "$STANDBY_DATA_PATH" ]]; then
        CHECK_PATH="$STANDBY_DATA_PATH"
    else
        # Find the closest existing parent
        CHECK_PATH="$STANDBY_DATA_PARENT"
        while [[ ! -d "$CHECK_PATH" && "$CHECK_PATH" != "/" ]]; do
            CHECK_PATH=$(dirname "$CHECK_PATH")
        done
    fi

    log_info "Checking available space on: $CHECK_PATH"

    # Get available space in MB
    AVAILABLE_SPACE_KB=$(df -k "$CHECK_PATH" 2>/dev/null | tail -1 | awk '{print $4}')
    AVAILABLE_SPACE_MB=$((AVAILABLE_SPACE_KB / 1024))

    log_info "Available space: ${AVAILABLE_SPACE_MB} MB"
    log_info "Required space:  ${REQUIRED_SPACE_MB} MB"

    if [[ "$AVAILABLE_SPACE_MB" -lt "$REQUIRED_SPACE_MB" ]]; then
        log_error "INSUFFICIENT DISK SPACE!"
        log_error "  Available: ${AVAILABLE_SPACE_MB} MB"
        log_error "  Required:  ${REQUIRED_SPACE_MB} MB"
        log_error "  Shortfall: $((REQUIRED_SPACE_MB - AVAILABLE_SPACE_MB)) MB"
        log_error ""
        log_error "Please free up space or add storage before proceeding."
        exit 1
    else
        SPACE_REMAINING=$((AVAILABLE_SPACE_MB - REQUIRED_SPACE_MB))
        log_info "PASS: Sufficient disk space available"
        log_info "  Space remaining after clone: ${SPACE_REMAINING} MB"
    fi
else
    log_warn "Database size information not available in config file"
    log_warn "Skipping disk space validation - please verify manually"
fi

# ------------------------------------------------------------
# Separate SRL Filesystem Check
# ------------------------------------------------------------
# If the operator configured STANDBY_SRL_PATH on a different
# filesystem than STANDBY_DATA_PATH, the check above only sized
# the data mount. Run a second df against the SRL path when it
# lives on a distinct filesystem.
# ------------------------------------------------------------
if [[ "$STANDBY_STORAGE_MODE" != "OMF" ]] \
   && [[ -n "${STANDBY_SRL_PATH:-}" ]] \
   && [[ "$STANDBY_SRL_PATH" != "$STANDBY_REDO_PATH" ]] \
   && [[ -n "${REDO_LOG_SIZE_MB:-}" ]] \
   && [[ -n "${STANDBY_REDO_GROUPS:-}" ]]; then

    # Find the closest existing parent for df (the SRL dir may not
    # be created yet - step 3 creates it later in this script).
    SRL_CHECK_PATH="$STANDBY_SRL_PATH"
    while [[ ! -d "$SRL_CHECK_PATH" && "$SRL_CHECK_PATH" != "/" ]]; do
        SRL_CHECK_PATH=$(dirname "$SRL_CHECK_PATH")
    done

    # Compute the data filesystem mount point independently (the
    # earlier REQUIRED_SPACE_MB block may have been skipped).
    DATA_CHECK_PATH="$STANDBY_DATA_PATH"
    while [[ ! -d "$DATA_CHECK_PATH" && "$DATA_CHECK_PATH" != "/" ]]; do
        DATA_CHECK_PATH=$(dirname "$DATA_CHECK_PATH")
    done

    # Determine whether SRL path is on a different filesystem than
    # STANDBY_DATA_PATH. If the same filesystem, the earlier df
    # already covered it (or REQUIRED_SPACE_MB was missing and the
    # operator accepted the manual-verification warning).
    DATA_FS=$(df -P "$DATA_CHECK_PATH" 2>/dev/null | tail -1 | awk '{print $NF}')
    SRL_FS=$(df -P "$SRL_CHECK_PATH" 2>/dev/null | tail -1 | awk '{print $NF}')

    if [[ -n "$DATA_FS" && "$DATA_FS" == "$SRL_FS" ]]; then
        log_info "SRL path shares the data filesystem ($DATA_FS) - space already covered"
    else
        # SRL storage needed = redo group size x group count x 1.2 (safety margin)
        SRL_REQUIRED_MB=$(( REDO_LOG_SIZE_MB * STANDBY_REDO_GROUPS * 12 / 10 ))
        log_info "Checking available space on separate SRL filesystem: $SRL_CHECK_PATH"
        log_info "SRL storage required: ${SRL_REQUIRED_MB} MB (${REDO_LOG_SIZE_MB} MB x ${STANDBY_REDO_GROUPS} groups + 20% buffer)"

        SRL_AVAILABLE_KB=$(df -k "$SRL_CHECK_PATH" 2>/dev/null | tail -1 | awk '{print $4}')
        SRL_AVAILABLE_MB=$(( SRL_AVAILABLE_KB / 1024 ))
        log_info "SRL filesystem available: ${SRL_AVAILABLE_MB} MB"

        if [[ "$SRL_AVAILABLE_MB" -lt "$SRL_REQUIRED_MB" ]]; then
            log_error "INSUFFICIENT SPACE ON SRL FILESYSTEM!"
            log_error "  Path:      $SRL_CHECK_PATH"
            log_error "  Available: ${SRL_AVAILABLE_MB} MB"
            log_error "  Required:  ${SRL_REQUIRED_MB} MB"
            log_error "  Shortfall: $(( SRL_REQUIRED_MB - SRL_AVAILABLE_MB )) MB"
            log_error ""
            log_error "Free up space on the SRL mount or reconfigure STANDBY_SRL_PATH."
            exit 1
        else
            log_info "PASS: Sufficient space on SRL filesystem"
        fi
    fi
fi

# Check Oracle environment
if [[ -z "$ORACLE_HOME" ]]; then
    # Try to set from config
    export ORACLE_HOME="$STANDBY_ORACLE_HOME"
fi

if [[ -z "$ORACLE_SID" ]]; then
    export ORACLE_SID="$STANDBY_ORACLE_SID"
fi

check_oracle_env || exit 1

# ============================================================
# Review Planned Changes
# ============================================================

progress_step "Reviewing Planned Changes"

if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    _dir_summary="Create any missing standby directories under ${STANDBY_DB_CREATE_FILE_DEST}, ${STANDBY_DB_RECOVERY_FILE_DEST}, and ${STANDBY_ADMIN_DIR}."
else
    _dir_summary="Create any missing standby directories under ${STANDBY_DATA_PATH}, ${STANDBY_REDO_PATH}, and ${STANDBY_ADMIN_DIR}."
    if [[ -n "${STANDBY_SRL_PATH:-}" ]] && [[ "$STANDBY_SRL_PATH" != "$STANDBY_REDO_PATH" ]]; then
        _dir_summary="${_dir_summary} Also create a separate SRL directory at ${STANDBY_SRL_PATH}."
    fi
fi
print_list_block "This Step Will Change" \
    "$_dir_summary" \
    "Install the standby password file at ${ORACLE_HOME}/dbs/orapw${STANDBY_ORACLE_SID}." \
    "Install the standby pfile at ${ORACLE_HOME}/dbs/init${STANDBY_ORACLE_SID}.ora." \
    "Update ${ORACLE_HOME}/network/admin/listener.ora and ${ORACLE_HOME}/network/admin/tnsnames.ora." \
    "Append ${STANDBY_ORACLE_SID}:${ORACLE_HOME}:N to /etc/oratab when missing."

print_list_block "This Step Will Not Change" \
    "It will not run RMAN DUPLICATE." \
    "It will not start or stop the database instance." \
    "It will not configure Data Guard Broker."

print_list_block "Files and Paths" \
    "Config source: ${STANDBY_CONFIG_FILE}" \
    "Password file source: ${NFS_SHARE}/orapw${PRIMARY_ORACLE_SID}" \
    "Pfile source: ${NFS_SHARE}/init${STANDBY_ORACLE_SID}_${STANDBY_DB_UNIQUE_NAME}.ora" \
    "Listener file: ${ORACLE_HOME}/network/admin/listener.ora" \
    "TNS file: ${ORACLE_HOME}/network/admin/tnsnames.ora"

print_list_block "Recovery If This Step Fails" \
    "Restore any .bak timestamped files created for listener.ora, tnsnames.ora, or the dbs files." \
    "Remove any directories created for the standby if you need to reset the host." \
    "Re-run this step after correcting the reported problem."

record_next_step "./primary/04_prepare_primary_dg.sh"

if [[ "$CHECK_ONLY" == "1" ]]; then
    finish_check_mode "Standby environment preflight complete. No changes were applied."
fi

# ============================================================
# Create Directory Structure
# ============================================================

progress_step "Creating Directory Structure"

# Admin directories (always needed regardless of storage mode)
DIRS_TO_CREATE=(
    "${STANDBY_ADMIN_DIR}/adump"
    "${STANDBY_ADMIN_DIR}/bdump"
    "${STANDBY_ADMIN_DIR}/cdump"
    "${STANDBY_ADMIN_DIR}/udump"
    "${STANDBY_ADMIN_DIR}/pfile"
)

if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    # OMF mode: create base directories only; Oracle creates subdirs automatically
    DIRS_TO_CREATE+=("${STANDBY_DB_CREATE_FILE_DEST}")
    DIRS_TO_CREATE+=("${STANDBY_DB_RECOVERY_FILE_DEST}")
    log_info "OMF mode: creating base OMF directories"
    log_info "  db_create_file_dest:   ${STANDBY_DB_CREATE_FILE_DEST}"
    log_info "  db_recovery_file_dest: ${STANDBY_DB_RECOVERY_FILE_DEST}"
else
    # Traditional mode: create explicit data, redo, archive directories
    DIRS_TO_CREATE+=(
        "${STANDBY_DATA_PATH}"
        "${STANDBY_REDO_PATH}"
    )

    # Add SRL directory if configured separately from ORL path
    if [[ -n "${STANDBY_SRL_PATH:-}" ]] && [[ "$STANDBY_SRL_PATH" != "$STANDBY_REDO_PATH" ]]; then
        DIRS_TO_CREATE+=("${STANDBY_SRL_PATH}")
        log_info "Separate SRL directory configured: $STANDBY_SRL_PATH"
    fi

    # Add archive destination if configured (may be empty if using FRA)
    if [[ -n "$STANDBY_ARCHIVE_DEST" ]]; then
        DIRS_TO_CREATE+=("$STANDBY_ARCHIVE_DEST")
    else
        log_info "STANDBY_ARCHIVE_DEST not set - assuming FRA is used for archive logs"
    fi

    # Add FRA if configured (STANDBY_FRA is set in the config when using FRA)
    if [[ -n "$STANDBY_FRA" ]]; then
        DIRS_TO_CREATE+=("$STANDBY_FRA")
        log_info "Using Fast Recovery Area: $STANDBY_FRA"
    elif [[ -n "$DB_RECOVERY_FILE_DEST" && "$DB_RECOVERY_FILE_DEST" != "USE_DB_RECOVERY_FILE_DEST" ]]; then
        # Fallback: calculate from DB_RECOVERY_FILE_DEST if STANDBY_FRA not set
        STANDBY_FRA_CALC=$(echo "$DB_RECOVERY_FILE_DEST" | sed "s/${PRIMARY_DB_UNIQUE_NAME}/${STANDBY_DB_UNIQUE_NAME}/g")
        DIRS_TO_CREATE+=("$STANDBY_FRA_CALC")
    fi
fi

DIRS_MISSING=()
for dir in "${DIRS_TO_CREATE[@]}"; do
    [[ -z "$dir" ]] && continue
    if [[ ! -d "$dir" ]]; then
        DIRS_MISSING+=("$dir")
    fi
done

if [[ ${#DIRS_MISSING[@]} -gt 0 ]]; then
    confirm_approval_action "Create standby directories" "mkdir -p $(shell_join "${DIRS_MISSING[@]}")" || exit 1
fi

for dir in "${DIRS_TO_CREATE[@]}"; do
    # Skip empty entries
    [[ -z "$dir" ]] && continue

    if [[ ! -d "$dir" ]]; then
        log_info "Creating directory: $dir"
        mkdir -p "$dir"
    else
        log_info "Directory exists: $dir"
    fi
done

log_success "Directory structure created successfully"
record_artifact "directory_tree:${STANDBY_ADMIN_DIR}"

# ============================================================
# Copy Password File
# ============================================================

progress_step "Installing Password File"

SOURCE_PWD_FILE="${NFS_SHARE}/orapw${PRIMARY_ORACLE_SID}"
DEST_PWD_FILE="${ORACLE_HOME}/dbs/orapw${STANDBY_ORACLE_SID}"

if [[ ! -f "$SOURCE_PWD_FILE" ]]; then
    log_error "Password file not found on NFS: $SOURCE_PWD_FILE"
    log_error "Please ensure 01_gather_primary_info.sh copied the password file"
    exit 1
fi

if [[ -f "$DEST_PWD_FILE" ]]; then
    backup_file "$DEST_PWD_FILE"
fi

log_cmd "COMMAND:" "cp $SOURCE_PWD_FILE $DEST_PWD_FILE"
confirm_approval_action "Install standby password file" "cp $SOURCE_PWD_FILE $DEST_PWD_FILE && chmod 640 $DEST_PWD_FILE" || exit 1
cp "$SOURCE_PWD_FILE" "$DEST_PWD_FILE"
chmod 640 "$DEST_PWD_FILE"
log_success "Password file copied to: $DEST_PWD_FILE"
record_artifact "password_file:${DEST_PWD_FILE}"

# ============================================================
# Copy Standby Init File
# ============================================================

progress_step "Installing Parameter File"

SOURCE_PFILE="${NFS_SHARE}/init${STANDBY_ORACLE_SID}_${STANDBY_DB_UNIQUE_NAME}.ora"
DEST_PFILE="${ORACLE_HOME}/dbs/init${STANDBY_ORACLE_SID}.ora"

if [[ ! -f "$SOURCE_PFILE" ]]; then
    log_error "Standby pfile not found on NFS: $SOURCE_PFILE"
    log_error "Please ensure 02_generate_standby_config.sh generated the pfile"
    exit 1
fi

if [[ -f "$DEST_PFILE" ]]; then
    backup_file "$DEST_PFILE"
fi

log_cmd "COMMAND:" "cp $SOURCE_PFILE $DEST_PFILE"
confirm_approval_action "Install standby parameter file" "cp $SOURCE_PFILE $DEST_PFILE && chmod 640 $DEST_PFILE" || exit 1
cp "$SOURCE_PFILE" "$DEST_PFILE"
chmod 640 "$DEST_PFILE"
log_success "Parameter file copied to: $DEST_PFILE"
record_artifact "pfile:${DEST_PFILE}"

# ============================================================
# Configure Listener
# ============================================================

progress_step "Configuring Listener"

LISTENER_ORA="${ORACLE_HOME}/network/admin/listener.ora"
LISTENER_ENTRY_FILE="${NFS_SHARE}/listener_${STANDBY_DB_UNIQUE_NAME}.ora"

if [[ ! -f "$LISTENER_ENTRY_FILE" ]]; then
    log_error "Listener entry file not found: $LISTENER_ENTRY_FILE"
    exit 1
fi

# Static services required for RMAN duplicate and broker switchover
TEMP_SID_DESC="/tmp/dg_sid_desc_standby_$$.tmp"
STANDBY_STATIC_GLOBAL_NAME="${STANDBY_DB_UNIQUE_NAME}${DB_DOMAIN:+.${DB_DOMAIN}}"
STANDBY_DGMGRL_GLOBAL_NAME="${STANDBY_DB_UNIQUE_NAME}_DGMGRL${DB_DOMAIN:+.${DB_DOMAIN}}"
MISSING_GLOBAL_NAMES=()

# Check if listener.ora exists
if [[ -f "$LISTENER_ORA" ]]; then
    backup_file "$LISTENER_ORA"

    if ! listener_has_global_dbname "$LISTENER_ORA" "$STANDBY_STATIC_GLOBAL_NAME"; then
        MISSING_GLOBAL_NAMES+=("$STANDBY_STATIC_GLOBAL_NAME")
    fi
    if ! listener_has_global_dbname "$LISTENER_ORA" "$STANDBY_DGMGRL_GLOBAL_NAME"; then
        MISSING_GLOBAL_NAMES+=("$STANDBY_DGMGRL_GLOBAL_NAME")
    fi

    if [[ ${#MISSING_GLOBAL_NAMES[@]} -eq 0 ]]; then
        log_info "Required standby static listener entries already exist"
    elif grep -q "SID_LIST_LISTENER" "$LISTENER_ORA"; then
        write_sid_desc_entries "$TEMP_SID_DESC" "$STANDBY_ORACLE_SID" "$ORACLE_HOME" "${MISSING_GLOBAL_NAMES[@]}"
        log_info "SID_LIST_LISTENER exists - adding missing static registration entries"
        confirm_approval_action "Update standby listener.ora" "Insert standby SID_DESC entries into $LISTENER_ORA" || exit 1
        if add_sid_to_listener "$LISTENER_ORA" "$TEMP_SID_DESC"; then
            log_info "Missing SID_DESC entries added to existing SID_LIST_LISTENER"
        else
            log_warn "Could not auto-insert the standby static registration entries"
            log_warn "Please manually add the following entry to SID_LIST_LISTENER:"
            echo ""
            cat "$TEMP_SID_DESC"
            echo ""
        fi
    else
        write_sid_desc_entries "$TEMP_SID_DESC" "$STANDBY_ORACLE_SID" "$ORACLE_HOME" "${MISSING_GLOBAL_NAMES[@]}"
        log_info "Adding SID_LIST_LISTENER to listener.ora"
        confirm_approval_action "Append standby SID_LIST_LISTENER to listener.ora" "append Data Guard standby listener block to $LISTENER_ORA" || exit 1
        cat >> "$LISTENER_ORA" <<EOF

# Data Guard standby static registration - Added $(date)
# Includes _DGMGRL service for Data Guard Broker switchover
SID_LIST_LISTENER =
  (SID_LIST =
$(cat "$TEMP_SID_DESC")
  )
EOF
        log_info "Listener entry added successfully"
    fi
else
    # Create new listener.ora
    log_info "Creating new listener.ora"
    confirm_approval_action "Create standby listener.ora" "write $LISTENER_ORA" || exit 1
    write_sid_desc_entries "$TEMP_SID_DESC" "$STANDBY_ORACLE_SID" "$ORACLE_HOME" "$STANDBY_STATIC_GLOBAL_NAME" "$STANDBY_DGMGRL_GLOBAL_NAME"
    cat > "$LISTENER_ORA" <<EOF
# Listener configuration for Data Guard standby
# Created: $(date)

LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = ${STANDBY_HOSTNAME})(PORT = ${STANDBY_LISTENER_PORT}))
    )
  )

# Includes _DGMGRL service for Data Guard Broker switchover
SID_LIST_LISTENER =
  (SID_LIST =
$(cat "$TEMP_SID_DESC")
  )
EOF
    log_info "listener.ora created successfully"
fi

rm -f "$TEMP_SID_DESC"
record_artifact "listener:${LISTENER_ORA}"

# ============================================================
# Configure TNS Names
# ============================================================

progress_step "Configuring TNS Names"

TNSNAMES_ORA="${ORACLE_HOME}/network/admin/tnsnames.ora"
TNSNAMES_ENTRY_FILE="${NFS_SHARE}/tnsnames_entries_${STANDBY_DB_UNIQUE_NAME}.ora"

if [[ ! -f "$TNSNAMES_ENTRY_FILE" ]]; then
    log_error "TNS entries file not found: $TNSNAMES_ENTRY_FILE"
    exit 1
fi

# Check if tnsnames.ora exists
if [[ -f "$TNSNAMES_ORA" ]]; then
    backup_file "$TNSNAMES_ORA"

    # Check if entries already exist
    if grep -q "$PRIMARY_TNS_ALIAS" "$TNSNAMES_ORA" && grep -q "$STANDBY_TNS_ALIAS" "$TNSNAMES_ORA"; then
        log_warn "TNS entries already exist for both primary and standby"
        log_info "Please verify tnsnames.ora manually if needed"
    else
        # Append entries
        log_info "Adding TNS entries to tnsnames.ora"
        confirm_approval_action "Append Data Guard TNS entries" "append Data Guard entries to $TNSNAMES_ORA" || exit 1
        echo "" >> "$TNSNAMES_ORA"
        echo "# Data Guard TNS entries - Added $(date)" >> "$TNSNAMES_ORA"
        cat "$TNSNAMES_ENTRY_FILE" >> "$TNSNAMES_ORA"
        log_info "TNS entries added successfully"
    fi
else
    # Create new tnsnames.ora
    log_info "Creating new tnsnames.ora"
    confirm_approval_action "Create standby tnsnames.ora" "write $TNSNAMES_ORA" || exit 1
    echo "# TNS Names for Data Guard" > "$TNSNAMES_ORA"
    echo "# Created: $(date)" >> "$TNSNAMES_ORA"
    echo "" >> "$TNSNAMES_ORA"
    cat "$TNSNAMES_ENTRY_FILE" >> "$TNSNAMES_ORA"
    log_info "tnsnames.ora created successfully"
fi
record_artifact "tnsnames:${TNSNAMES_ORA}"

# ============================================================
# Update oratab
# ============================================================

progress_step "Updating oratab"

ORATAB="/etc/oratab"
if [[ -f "$ORATAB" ]]; then
    if grep -q "^${STANDBY_ORACLE_SID}:" "$ORATAB"; then
        log_info "Entry for $STANDBY_ORACLE_SID already exists in oratab"
    else
        log_info "Adding $STANDBY_ORACLE_SID to oratab"
        confirm_approval_action "Update /etc/oratab" "append ${STANDBY_ORACLE_SID}:${ORACLE_HOME}:N to $ORATAB" || exit 1
        echo "${STANDBY_ORACLE_SID}:${ORACLE_HOME}:N" >> "$ORATAB"
    fi
else
    log_warn "oratab not found at $ORATAB"
fi

# ============================================================
# Start/Reload Listener
# ============================================================

progress_step "Starting or Reloading Listener"

# Check if listener is running
if "$ORACLE_HOME/bin/lsnrctl" status > /dev/null 2>&1; then
    log_info "Listener is running, reloading..."
    log_cmd "COMMAND:" "lsnrctl reload"
    confirm_approval_action "Reload Oracle listener" "$ORACLE_HOME/bin/lsnrctl reload" || exit 1
    "$ORACLE_HOME/bin/lsnrctl" reload
else
    log_info "Starting listener..."
    log_cmd "COMMAND:" "lsnrctl start"
    confirm_approval_action "Start Oracle listener" "$ORACLE_HOME/bin/lsnrctl start" || exit 1
    "$ORACLE_HOME/bin/lsnrctl" start
fi

# Show listener status
echo ""
"$ORACLE_HOME/bin/lsnrctl" status

# ============================================================
# Verify Static Registration
# ============================================================

progress_step "Verifying Listener Registration"

echo ""
log_info "Checking listener services..."
"$ORACLE_HOME/bin/lsnrctl" services

# Look for our service
if "$ORACLE_HOME/bin/lsnrctl" status 2>&1 | grep -q "$STANDBY_DB_UNIQUE_NAME"; then
    log_info "Static registration verified for $STANDBY_DB_UNIQUE_NAME"
else
    log_warn "Could not verify static registration - please check listener status"
fi

# ============================================================
# Summary
# ============================================================

print_summary "SUCCESS" "Standby environment setup complete"
if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    print_status_block "Standby Environment" \
        "Host" "$CURRENT_HOST" \
        "DB_UNIQUE_NAME" "$STANDBY_DB_UNIQUE_NAME" \
        "ORACLE_SID" "$STANDBY_ORACLE_SID" \
        "Storage Mode" "OMF" \
        "db_create_file_dest" "$STANDBY_DB_CREATE_FILE_DEST" \
        "Listener Port" "$STANDBY_LISTENER_PORT"
else
    print_status_block "Standby Environment" \
        "Host" "$CURRENT_HOST" \
        "DB_UNIQUE_NAME" "$STANDBY_DB_UNIQUE_NAME" \
        "ORACLE_SID" "$STANDBY_ORACLE_SID" \
        "Data Path" "$STANDBY_DATA_PATH" \
        "Listener Port" "$STANDBY_LISTENER_PORT"
fi

print_list_block "Completed Actions" \
    "Created the standby directory structure." \
    "Installed the password file and parameter file." \
    "Configured listener static registration." \
    "Updated tnsnames.ora and oratab." \
    "Started or reloaded the listener."

print_list_block "Next Steps" \
    "On PRIMARY, run ./primary/04_prepare_primary_dg.sh." \
    "Then return to STANDBY and run ./standby/05_clone_standby.sh."
