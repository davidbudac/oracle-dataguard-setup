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

# ============================================================
# Main Script
# ============================================================

print_banner "Step 3: Setup Standby Environment"

# Initialize logging (will reinitialize with DB name later)
init_log "03_setup_standby_env"

# ============================================================
# Pre-flight Checks
# ============================================================

log_section "Pre-flight Checks"

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

log_section "Validating Disk Space"

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
# Create Directory Structure
# ============================================================

log_section "Creating Directory Structure"

# Admin directories
DIRS_TO_CREATE=(
    "${STANDBY_ADMIN_DIR}/adump"
    "${STANDBY_ADMIN_DIR}/bdump"
    "${STANDBY_ADMIN_DIR}/cdump"
    "${STANDBY_ADMIN_DIR}/udump"
    "${STANDBY_ADMIN_DIR}/pfile"
    "${STANDBY_DATA_PATH}"
    "${STANDBY_REDO_PATH}"
)

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

log_info "Directory structure created successfully"

# ============================================================
# Copy Password File
# ============================================================

log_section "Copying Password File"

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
cp "$SOURCE_PWD_FILE" "$DEST_PWD_FILE"
chmod 640 "$DEST_PWD_FILE"
log_info "Password file copied to: $DEST_PWD_FILE"

# ============================================================
# Copy Standby Init File
# ============================================================

log_section "Setting Up Parameter File"

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
cp "$SOURCE_PFILE" "$DEST_PFILE"
chmod 640 "$DEST_PFILE"
log_info "Parameter file copied to: $DEST_PFILE"

# ============================================================
# Configure Listener
# ============================================================

log_section "Configuring Listener"

LISTENER_ORA="${ORACLE_HOME}/network/admin/listener.ora"
LISTENER_ENTRY_FILE="${NFS_SHARE}/listener_${STANDBY_DB_UNIQUE_NAME}.ora"

if [[ ! -f "$LISTENER_ENTRY_FILE" ]]; then
    log_error "Listener entry file not found: $LISTENER_ENTRY_FILE"
    exit 1
fi

# New SID_DESC entries to add - write to temp file for AIX compatibility
# Includes _DGMGRL service for Data Guard Broker switchover
# AIX compatible: use $$ (PID) instead of mktemp
TEMP_SID_DESC="/tmp/dg_sid_desc_standby_$$.tmp"
cat > "$TEMP_SID_DESC" <<EOF
    (SID_DESC =
      (GLOBAL_DBNAME = ${STANDBY_DB_UNIQUE_NAME})
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${STANDBY_ORACLE_SID})
    )
    (SID_DESC =
      (GLOBAL_DBNAME = ${STANDBY_DB_UNIQUE_NAME}_DGMGRL)
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${STANDBY_ORACLE_SID})
    )
EOF

# Check if listener.ora exists
if [[ -f "$LISTENER_ORA" ]]; then
    backup_file "$LISTENER_ORA"

    # Check if SID_LIST already contains our entry
    if grep -q "SID_NAME.*=.*${STANDBY_ORACLE_SID}[^A-Za-z0-9_]" "$LISTENER_ORA" || \
       grep -q "SID_NAME.*=.*${STANDBY_ORACLE_SID}$" "$LISTENER_ORA"; then
        log_warn "Listener entry for $STANDBY_ORACLE_SID already exists"
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

# Data Guard standby static registration - Added $(date)
# Includes _DGMGRL service for Data Guard Broker switchover
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = ${STANDBY_DB_UNIQUE_NAME})
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${STANDBY_ORACLE_SID})
    )
    (SID_DESC =
      (GLOBAL_DBNAME = ${STANDBY_DB_UNIQUE_NAME}_DGMGRL)
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${STANDBY_ORACLE_SID})
    )
  )
EOF
        log_info "Listener entry added successfully"
    fi
else
    # Create new listener.ora
    log_info "Creating new listener.ora"
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
    (SID_DESC =
      (GLOBAL_DBNAME = ${STANDBY_DB_UNIQUE_NAME})
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${STANDBY_ORACLE_SID})
    )
    (SID_DESC =
      (GLOBAL_DBNAME = ${STANDBY_DB_UNIQUE_NAME}_DGMGRL)
      (ORACLE_HOME = ${ORACLE_HOME})
      (SID_NAME = ${STANDBY_ORACLE_SID})
    )
  )
EOF
    log_info "listener.ora created successfully"
fi

rm -f "$TEMP_SID_DESC"

# ============================================================
# Configure TNS Names
# ============================================================

log_section "Configuring TNS Names"

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
        echo "" >> "$TNSNAMES_ORA"
        echo "# Data Guard TNS entries - Added $(date)" >> "$TNSNAMES_ORA"
        cat "$TNSNAMES_ENTRY_FILE" >> "$TNSNAMES_ORA"
        log_info "TNS entries added successfully"
    fi
else
    # Create new tnsnames.ora
    log_info "Creating new tnsnames.ora"
    echo "# TNS Names for Data Guard" > "$TNSNAMES_ORA"
    echo "# Created: $(date)" >> "$TNSNAMES_ORA"
    echo "" >> "$TNSNAMES_ORA"
    cat "$TNSNAMES_ENTRY_FILE" >> "$TNSNAMES_ORA"
    log_info "tnsnames.ora created successfully"
fi

# ============================================================
# Update oratab
# ============================================================

log_section "Updating oratab"

ORATAB="/etc/oratab"
if [[ -f "$ORATAB" ]]; then
    if grep -q "^${STANDBY_ORACLE_SID}:" "$ORATAB"; then
        log_info "Entry for $STANDBY_ORACLE_SID already exists in oratab"
    else
        log_info "Adding $STANDBY_ORACLE_SID to oratab"
        echo "${STANDBY_ORACLE_SID}:${ORACLE_HOME}:N" >> "$ORATAB"
    fi
else
    log_warn "oratab not found at $ORATAB"
fi

# ============================================================
# Start/Reload Listener
# ============================================================

log_section "Starting Listener"

# Check if listener is running
if "$ORACLE_HOME/bin/lsnrctl" status > /dev/null 2>&1; then
    log_info "Listener is running, reloading..."
    log_cmd "COMMAND:" "lsnrctl reload"
    "$ORACLE_HOME/bin/lsnrctl" reload
else
    log_info "Starting listener..."
    log_cmd "COMMAND:" "lsnrctl start"
    "$ORACLE_HOME/bin/lsnrctl" start
fi

# Show listener status
echo ""
"$ORACLE_HOME/bin/lsnrctl" status

# ============================================================
# Verify Static Registration
# ============================================================

log_section "Verifying Configuration"

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

echo ""
echo "COMPLETED ACTIONS:"
echo "=================="
echo "  - Created directory structure"
echo "  - Copied password file"
echo "  - Installed parameter file"
echo "  - Configured listener with static registration"
echo "  - Configured tnsnames.ora"
echo "  - Updated oratab"
echo "  - Started/reloaded listener"
echo ""
echo "NEXT STEPS:"
echo "==========="
echo ""
echo "1. On PRIMARY server:"
echo "   Run: ./04_prepare_primary_dg.sh"
echo ""
echo "2. Then return to STANDBY and run:"
echo "   ./05_clone_standby.sh"
echo ""
