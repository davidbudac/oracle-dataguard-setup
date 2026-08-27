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
enable_verbose_mode "$@"

# ============================================================
# Main Script
# ============================================================

print_banner "Step 4: Prepare Primary for DG"
init_progress 8

# Initialize logging (will reinitialize with DB name later)
init_log "04_prepare_primary_dg"

# ============================================================
# Pre-flight Checks
# ============================================================

progress_step "Pre-flight Checks"

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
# Review Planned Changes
# ============================================================

progress_step "Reviewing Planned Changes"

print_list_block "This Step Will Change" \
    "Update ${ORACLE_HOME}/network/admin/tnsnames.ora with the standby aliases if missing." \
    "Update ${ORACLE_HOME}/network/admin/listener.ora with static registration for primary and broker access." \
    "Enable FORCE LOGGING if required." \
    "Create missing standby redo log groups on the primary." \
    "Enable DG_BROKER_START and set STANDBY_FILE_MANAGEMENT=AUTO."

print_list_block "This Step Will Not Change" \
    "It will not run RMAN DUPLICATE." \
    "It will not create the broker configuration." \
    "It will not perform switchover or failover."

print_list_block "Files and Objects" \
    "Standby config: ${STANDBY_CONFIG_FILE}" \
    "Listener file: ${ORACLE_HOME}/network/admin/listener.ora" \
    "TNS file: ${ORACLE_HOME}/network/admin/tnsnames.ora" \
    "Database changes: FORCE LOGGING, standby redo logs, DG_BROKER_START, STANDBY_FILE_MANAGEMENT"

print_list_block "Recovery If This Step Fails" \
    "Restore any .bak timestamped listener.ora or tnsnames.ora files if needed." \
    "Drop any standby redo log groups created in error and re-run the step." \
    "Disable DG_BROKER_START or remove redo groups manually only if the failure requires rollback."

record_next_step "./standby/05_clone_standby.sh"

if [[ "$CHECK_ONLY" == "1" ]]; then
    finish_check_mode "Primary Data Guard preflight complete. No changes were applied."
fi

# ============================================================
# Configure TNS Names on Primary
# ============================================================

progress_step "Configuring TNS Names on Primary"

TNSNAMES_ORA="${ORACLE_HOME}/network/admin/tnsnames.ora"
TNSNAMES_ENTRY_FILE="${NFS_SHARE}/tnsnames_entries_${STANDBY_DB_UNIQUE_NAME}.ora"

if [[ ! -f "$TNSNAMES_ENTRY_FILE" ]]; then
    log_error "TNS entries file not found: $TNSNAMES_ENTRY_FILE"
    exit 1
fi

# M2: the generated entries file contains BOTH the primary and standby
# alias stanzas. The old check tested only the standby alias and, when
# missing, appended the WHOLE file - if the primary alias happened to
# already exist (e.g. a second run, or a hand-maintained tnsnames.ora),
# that produced a DUPLICATE primary definition. Oracle's tnsnames
# resolution takes the FIRST match, so the OLD (possibly stale)
# definition would silently keep winning. Check and append each alias
# independently instead.
extract_tns_alias_block() {
    # Prints alias $2's stanza (from its "<alias> =" line up to the
    # next blank line, or EOF for the last stanza) from file $1.
    local _file="$1" _alias="$2" _alias_re
    _alias_re=$(printf '%s' "$_alias" | sed 's/[.]/\\./g')
    sed -n "/^${_alias_re}[[:space:]]*=/,/^$/p" "$_file"
}

TNS_APPEND_BLOCKS=""
for TNS_ALIAS_TO_CHECK in "$PRIMARY_TNS_ALIAS" "$STANDBY_TNS_ALIAS"; do
    TNS_ALIAS_RE=$(printf '%s' "$TNS_ALIAS_TO_CHECK" | sed 's/[.]/\\./g')
    if [[ -f "$TNSNAMES_ORA" ]] && grep -qiE "^[[:space:]]*${TNS_ALIAS_RE}[[:space:]]*=" "$TNSNAMES_ORA"; then
        log_info "TNS entry for '$TNS_ALIAS_TO_CHECK' already exists"
    else
        TNS_BLOCK=$(extract_tns_alias_block "$TNSNAMES_ENTRY_FILE" "$TNS_ALIAS_TO_CHECK")
        if [[ -z "$TNS_BLOCK" ]]; then
            log_error "Could not find the '$TNS_ALIAS_TO_CHECK' stanza in $TNSNAMES_ENTRY_FILE"
            exit 1
        fi
        log_info "TNS entry for '$TNS_ALIAS_TO_CHECK' is missing - will be added"
        TNS_APPEND_BLOCKS="${TNS_APPEND_BLOCKS}${TNS_BLOCK}
"
    fi
done

if [[ -z "$TNS_APPEND_BLOCKS" ]]; then
    log_info "All required TNS entries already exist"
elif [[ -f "$TNSNAMES_ORA" ]]; then
    backup_file "$TNSNAMES_ORA"
    log_info "Adding missing TNS entries to tnsnames.ora"
    confirm_approval_action "Append standby TNS entry on primary" "append Data Guard entries to $TNSNAMES_ORA" || exit 1
    {
        echo ""
        echo "# Data Guard TNS entries - Added $(date)"
        printf '%s\n' "$TNS_APPEND_BLOCKS"
    } >> "$TNSNAMES_ORA"
    log_info "TNS entries added successfully"
else
    log_info "Creating new tnsnames.ora"
    confirm_approval_action "Create primary tnsnames.ora" "write $TNSNAMES_ORA" || exit 1
    {
        echo "# TNS Names for Data Guard"
        echo "# Created: $(date)"
        echo ""
        printf '%s\n' "$TNS_APPEND_BLOCKS"
    } > "$TNSNAMES_ORA"
    log_info "tnsnames.ora created successfully"
fi

# ============================================================
# Configure Listener on Primary
# ============================================================

progress_step "Configuring Listener on Primary"

LISTENER_ORA="${ORACLE_HOME}/network/admin/listener.ora"

# Private temp dir + EXIT-trap cleanup: create_temp_dir prefers `mktemp -d`,
# falling back to a mode-700 directory on AIX images without mktemp - safer
# than a predictable /tmp/..._$$ filename. No pre-existing EXIT trap in this
# script, so it is safe to install one here.
TEMP_SID_DESC_DIR=$(create_temp_dir) || { log_error "Could not create temp directory"; exit 1; }
trap 'rm -rf "$TEMP_SID_DESC_DIR"' EXIT
TEMP_SID_DESC="${TEMP_SID_DESC_DIR}/dg_sid_desc_primary.$$"
PRIMARY_STATIC_GLOBAL_NAME="${PRIMARY_DB_UNIQUE_NAME}${DB_DOMAIN:+.${DB_DOMAIN}}"
PRIMARY_DGMGRL_GLOBAL_NAME="${PRIMARY_DB_UNIQUE_NAME}_DGMGRL${DB_DOMAIN:+.${DB_DOMAIN}}"
MISSING_GLOBAL_NAMES=()

# Check if listener.ora exists
if [[ -f "$LISTENER_ORA" ]]; then
    backup_file "$LISTENER_ORA"

    if ! listener_has_global_dbname "$LISTENER_ORA" "$PRIMARY_STATIC_GLOBAL_NAME"; then
        MISSING_GLOBAL_NAMES+=("$PRIMARY_STATIC_GLOBAL_NAME")
    fi
    if ! listener_has_global_dbname "$LISTENER_ORA" "$PRIMARY_DGMGRL_GLOBAL_NAME"; then
        MISSING_GLOBAL_NAMES+=("$PRIMARY_DGMGRL_GLOBAL_NAME")
    fi

    if [[ ${#MISSING_GLOBAL_NAMES[@]} -eq 0 ]]; then
        log_info "Required primary static listener entries already exist"
    elif grep -q "SID_LIST_LISTENER" "$LISTENER_ORA"; then
        write_sid_desc_entries "$TEMP_SID_DESC" "$PRIMARY_ORACLE_SID" "$ORACLE_HOME" "${MISSING_GLOBAL_NAMES[@]}"
        log_info "SID_LIST_LISTENER exists - adding missing primary static registration entries"
        confirm_approval_action "Update primary listener.ora" "Insert primary SID_DESC entries into $LISTENER_ORA" || exit 1
        if add_sid_to_listener "$LISTENER_ORA" "$TEMP_SID_DESC"; then
            log_info "Missing SID_DESC entries added to existing SID_LIST_LISTENER"
            LISTENER_CONFIG_CHANGED=1
        else
            log_warn "Could not auto-insert SID_DESC entry"
            log_warn "Please manually add the following entry to SID_LIST_LISTENER:"
            echo ""
            cat "$TEMP_SID_DESC"
            echo ""
        fi
    else
        write_sid_desc_entries "$TEMP_SID_DESC" "$PRIMARY_ORACLE_SID" "$ORACLE_HOME" "${MISSING_GLOBAL_NAMES[@]}"
        log_info "Adding SID_LIST_LISTENER to listener.ora"
        confirm_approval_action "Append primary SID_LIST_LISTENER to listener.ora" "append Data Guard primary listener block to $LISTENER_ORA" || exit 1
        cat >> "$LISTENER_ORA" <<EOF

# Data Guard primary static registration - Added $(date)
# Includes _DGMGRL service for Data Guard Broker switchover
SID_LIST_LISTENER =
  (SID_LIST =
$(cat "$TEMP_SID_DESC")
  )
EOF
        log_info "Listener entry added successfully"
        LISTENER_CONFIG_CHANGED=1
    fi
else
    # Create new listener.ora
    log_info "Creating new listener.ora"
    confirm_approval_action "Create primary listener.ora" "write $LISTENER_ORA" || exit 1
    write_sid_desc_entries "$TEMP_SID_DESC" "$PRIMARY_ORACLE_SID" "$ORACLE_HOME" "$PRIMARY_STATIC_GLOBAL_NAME" "$PRIMARY_DGMGRL_GLOBAL_NAME"
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
$(cat "$TEMP_SID_DESC")
  )
EOF
    log_info "listener.ora created successfully"
    LISTENER_CONFIG_CHANGED=1
fi

rm -rf "$TEMP_SID_DESC_DIR"
record_artifact "listener:${LISTENER_ORA}"

# Reload the listener so the static _DGMGRL registration actually takes
# effect. Without this, everything up to step 7 passes (nothing uses the
# static service yet) and the gap only surfaces later: step 13's VALIDATE
# DATABASE fails its StaticConnectIdentifier probe with ORA-12514, and a
# real switchover would hit the same error - weeks after anyone looked at
# this step. `lsnrctl reload` re-reads listener.ora without dropping
# existing connections. Skipped when nothing was changed.
if [[ "${LISTENER_CONFIG_CHANGED:-0}" -eq 1 ]]; then
    confirm_approval_action "Reload primary listener" "$ORACLE_HOME/bin/lsnrctl reload  # activate the _DGMGRL static registration" || exit 1
    log_info "Reloading the listener to activate the static registration..."
    if "$ORACLE_HOME/bin/lsnrctl" reload >/dev/null 2>&1; then
        sleep 3
        if "$ORACLE_HOME/bin/lsnrctl" status 2>/dev/null | grep -qi "$PRIMARY_DGMGRL_GLOBAL_NAME"; then
            log_info "Listener reloaded - ${PRIMARY_DGMGRL_GLOBAL_NAME} static service is registered"
        else
            log_warn "Listener reloaded, but ${PRIMARY_DGMGRL_GLOBAL_NAME} is not visible in 'lsnrctl status' yet"
            log_warn "Verify manually: lsnrctl status | grep -i ${PRIMARY_DGMGRL_GLOBAL_NAME}"
        fi
    else
        log_warn "'lsnrctl reload' failed - reload the listener manually: lsnrctl reload"
        log_warn "Until then, DGMGRL switchover connects to this database will fail with ORA-12514"
    fi
else
    log_info "Listener configuration unchanged - no reload needed"
fi

# ============================================================
# Check/Enable Force Logging
# ============================================================

progress_step "Checking Force Logging"

FORCE_LOGGING=$(run_sql_query "get_force_logging.sql")
FORCE_LOGGING=$(echo "$FORCE_LOGGING" | tr -d '[:space:]')

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

progress_step "Checking Standby Redo Logs"

# Get current standby redo log count
CURRENT_STBY_GROUPS=$(run_sql_query "get_standby_redo_count.sql")
CURRENT_STBY_GROUPS=$(echo "$CURRENT_STBY_GROUPS" | tr -d '[:space:]')
if ! is_numeric "$CURRENT_STBY_GROUPS"; then
    log_error "get_standby_redo_count.sql returned a non-numeric result: '${CURRENT_STBY_GROUPS}'"
    exit 1
fi

REQUIRED_STBY_GROUPS=$STANDBY_REDO_GROUPS
# L13: an empty/non-numeric REQUIRED_STBY_GROUPS (e.g. a standby config
# missing STANDBY_REDO_GROUPS) makes the "-lt" comparison below treat it
# as 0 rather than error - "0 standby redo groups required" always
# reads as satisfied and the step silently reports success with none
# created.
if ! is_numeric "$REQUIRED_STBY_GROUPS"; then
    log_error "STANDBY_REDO_GROUPS from the standby config is not numeric: '${REQUIRED_STBY_GROUPS}' (re-run 02_generate_standby_config.sh)"
    exit 1
fi

log_info "Current standby redo groups: $CURRENT_STBY_GROUPS"
log_info "Required standby redo groups: $REQUIRED_STBY_GROUPS"

if [[ "$CURRENT_STBY_GROUPS" -lt "$REQUIRED_STBY_GROUPS" ]]; then
    log_info "Creating standby redo logs..."

    # Get the max group number
    MAX_GROUP=$(run_sql_query "get_max_redo_group.sql")
    MAX_GROUP=$(echo "$MAX_GROUP" | tr -d '[:space:]')
    if ! is_numeric "$MAX_GROUP"; then
        log_error "get_max_redo_group.sql returned a non-numeric result: '${MAX_GROUP}'"
        exit 1
    fi

    # Determine where to place SRLs on the primary.
    # Prefer PRIMARY_SRL_PATH from the config (set at step 2, may differ
    # from the ORL path for disk isolation). Fall back to querying the
    # ORL member path for backward compatibility with older configs.
    PRIMARY_SRL_PATH_FROM_CONFIG="NO"
    if [[ -n "${PRIMARY_SRL_PATH:-}" ]]; then
        REDO_PATH="$PRIMARY_SRL_PATH"
        PRIMARY_SRL_PATH_FROM_CONFIG="YES"
        log_info "Using PRIMARY_SRL_PATH from config: $REDO_PATH"
    else
        REDO_PATH=$(run_sql_query "get_redo_member_path.sql")
        REDO_PATH=$(echo "$REDO_PATH" | tr -d '[:space:]')
        log_info "PRIMARY_SRL_PATH not set in config, using queried ORL path: $REDO_PATH"
    fi

    # Ensure trailing slash since we concatenate the filename directly
    [[ "$REDO_PATH" != */ ]] && REDO_PATH="${REDO_PATH}/"

    # Verify the SRL directory exists and is writable by the Oracle user.
    # When PRIMARY_SRL_PATH comes from the config it may point at a
    # separate mount or freshly-provisioned directory that has never
    # been touched. If it's missing, offer to create it rather than
    # letting ALTER DATABASE ADD STANDBY LOGFILE fail mid-step.
    if [[ ! -d "$REDO_PATH" ]]; then
        log_warn "SRL directory does not exist: $REDO_PATH"
        if [[ "$PRIMARY_SRL_PATH_FROM_CONFIG" == "YES" ]]; then
            echo ""
            echo "The primary SRL directory configured in step 2 does not exist."
            echo "It must exist and be writable by the Oracle user before SRLs"
            echo "can be created."
            echo ""
            confirm_approval_action "Create primary SRL directory" "mkdir -p $REDO_PATH" || exit 1
            mkdir -p "$REDO_PATH" || {
                log_error "Failed to create SRL directory: $REDO_PATH"
                log_error "Check parent directory permissions and retry."
                exit 1
            }
            log_info "Created SRL directory: $REDO_PATH"
        else
            log_error "Queried ORL member path does not exist: $REDO_PATH"
            log_error "This indicates a broken database state - investigate manually."
            exit 1
        fi
    fi

    if [[ ! -w "$REDO_PATH" ]]; then
        log_error "SRL directory is not writable: $REDO_PATH"
        log_error "Fix permissions (owner should be the Oracle OS user) and retry."
        exit 1
    fi
    log_info "SRL directory verified: $REDO_PATH (exists, writable)"

    # Calculate how many to create
    GROUPS_TO_CREATE=$((REQUIRED_STBY_GROUPS - CURRENT_STBY_GROUPS))

    STANDBY_REDO_START_GROUP=$((MAX_GROUP + 1))

    # Create SRLs assigned to this instance's redo thread. Without the
    # THREAD clause they sit at THREAD#=0 until first use, and DGMGRL
    # VALIDATE DATABASE then reports "standby redo logs not configured
    # for thread N" - blocking step 13's MAXAVAILABILITY preflight even
    # though the SRLs exist (found live in the E2E run).
    REDO_THREAD=$(run_sql_query "get_instance_thread.sql")
    REDO_THREAD=$(echo "$REDO_THREAD" | tr -d '[:space:]')
    if ! is_numeric "$REDO_THREAD"; then
        log_warn "Could not determine the instance redo thread ('${REDO_THREAD}') - defaulting to thread 1"
        REDO_THREAD=1
    fi

    log_info "Creating $GROUPS_TO_CREATE standby redo log groups (thread ${REDO_THREAD}) starting at group $STANDBY_REDO_START_GROUP..."

    i=0
    while [ "$i" -lt "$GROUPS_TO_CREATE" ]; do
        NEW_GROUP=$((STANDBY_REDO_START_GROUP + i))
        STBY_LOG_FILE="${REDO_PATH}standby_redo${NEW_GROUP}.log"

        log_info "Creating standby redo log group $NEW_GROUP: $STBY_LOG_FILE"
        log_cmd "sqlplus / as sysdba:" "ALTER DATABASE ADD STANDBY LOGFILE THREAD ${REDO_THREAD} GROUP ${NEW_GROUP} ('${STBY_LOG_FILE}') SIZE ${REDO_LOG_SIZE_MB}M"

        run_sql_command "add_standby_logfile.sql" "$REDO_THREAD" "$NEW_GROUP" "$STBY_LOG_FILE" "$REDO_LOG_SIZE_MB"
        record_artifact "standby_redo_group:${NEW_GROUP}:${STBY_LOG_FILE}"
        i=$((i + 1))
    done

    log_info "Standby redo logs created successfully"

    # Verify
    echo ""
    log_info "Standby redo log configuration:"
    run_sql_display "get_standby_redo_info.sql"
else
    log_info "Sufficient standby redo logs already exist"

    # M6: count alone doesn't catch UNDERSIZED pre-existing SRLs. Oracle
    # rejects a standby redo log smaller than the largest online redo
    # log for real-time apply, so an SRL set created before an ORL
    # resize (or the H1 arbitrary-log-size bug this review also fixes)
    # can pass this count check while defeating step 1's own advice to
    # resize the ORLs before the standby exists. Compare, warn, and give
    # the fix DDL - do not auto-drop existing standby redo log groups.
    STBY_MIN_SIZE_MB=$(run_sql_query "get_standby_redo_min_size.sql")
    STBY_MIN_SIZE_MB=$(echo "$STBY_MIN_SIZE_MB" | tr -d '[:space:]')
    if is_numeric "$STBY_MIN_SIZE_MB" && is_numeric "${REDO_LOG_SIZE_MB:-}"; then
        if [[ "$STBY_MIN_SIZE_MB" -lt "$REDO_LOG_SIZE_MB" ]]; then
            log_warn "Existing standby redo logs are UNDERSIZED: smallest is ${STBY_MIN_SIZE_MB}MB, online redo logs are ${REDO_LOG_SIZE_MB}MB"
            log_warn "  Oracle rejects standby redo logs smaller than the largest online redo log for"
            log_warn "  real-time apply - transport silently falls back to archiver mode instead."
            log_warn "  Fix (run manually - not applied automatically), for each undersized group:"
            log_warn "    ALTER DATABASE DROP STANDBY LOGFILE GROUP <n>;"
            log_warn "    ALTER DATABASE ADD STANDBY LOGFILE GROUP <n> ('<path>') SIZE ${REDO_LOG_SIZE_MB}M;"
        else
            log_info "Existing standby redo logs are sized adequately (>= ${REDO_LOG_SIZE_MB}MB)"
        fi
    else
        log_warn "Could not verify existing standby redo log sizes (non-numeric query result) - check manually"
    fi
fi

# ============================================================
# Enable Data Guard Broker
# ============================================================

progress_step "Enabling Data Guard Broker"

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
DMON_COUNT=$(echo "$DMON_COUNT" | tr -d '[:space:]')

if [[ "$DMON_COUNT" -gt 0 ]]; then
    log_info "Data Guard Broker process (DMON) is running"
else
    log_warn "DMON process not detected yet - it may take a moment to start"
fi

# Set STANDBY_FILE_MANAGEMENT (still needed for automatic file creation)
log_info "Setting STANDBY_FILE_MANAGEMENT=AUTO..."
log_cmd "sqlplus / as sysdba:" "ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT=AUTO SCOPE=BOTH"
run_sql_command "set_standby_file_mgmt.sql"

log_success "Data Guard Broker enabled successfully"
log_info "Note: LOG_ARCHIVE_DEST_2, FAL_SERVER, etc. will be configured by DGMGRL"
record_artifact "tnsnames:${TNSNAMES_ORA}"

# ============================================================
# Configure RMAN Archivelog Deletion Policy
# ============================================================

log_section "Configuring RMAN Archivelog Deletion Policy"

log_info "Setting archivelog deletion policy to SHIPPED TO ALL STANDBY..."
log_cmd "rman target /" "CONFIGURE ARCHIVELOG DELETION POLICY TO SHIPPED TO ALL STANDBY"

run_rman "configure_archivelog_deletion.rman"

log_success "RMAN archivelog deletion policy configured"

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
elif [[ -x "${ORACLE_HOME}/bin/tnsping" ]]; then
    # AIX 7.2 ships neither nc nor timeout(1). tnsping is always present in
    # ORACLE_HOME and a raw descriptor makes it a pure listener-handshake
    # test (it never looks at the service), with the wait bounded by the
    # descriptor's own timeout parameters rather than an external tool.
    if "${ORACLE_HOME}/bin/tnsping" \
        "(DESCRIPTION=(CONNECT_TIMEOUT=5)(TRANSPORT_CONNECT_TIMEOUT=5)(RETRY_COUNT=0)(ADDRESS=(PROTOCOL=TCP)(HOST=${STANDBY_HOSTNAME})(PORT=${STANDBY_PORT})))" \
        2>/dev/null | grep -q '^OK'; then
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
    log_warn "None of nc, tnsping or timeout available - skipping basic port check"
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

progress_step "Reviewing Current Data Guard Configuration"

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

# M5: re-read the values this step itself may have just changed.
# FORCE_LOGGING and DG_BROKER_START were captured BEFORE the
# enable/set steps above (used only to decide whether to act) - the
# summary must reflect the actual post-change state, not show "NO"/
# "FALSE" when both were in fact just turned on.
FORCE_LOGGING=$(run_sql_query "get_force_logging.sql")
FORCE_LOGGING=$(echo "$FORCE_LOGGING" | tr -d '[:space:]')
DG_BROKER_START=$(get_db_parameter "dg_broker_start")

print_summary "SUCCESS" "Primary configured for Data Guard"
print_status_block "Primary Data Guard Readiness" \
    "Primary DB" "$PRIMARY_DB_UNIQUE_NAME" \
    "Standby DB" "$STANDBY_DB_UNIQUE_NAME" \
    "FORCE_LOGGING" "$FORCE_LOGGING" \
    "DG_BROKER_START" "$DG_BROKER_START" \
    "Standby Redo Groups" "$REQUIRED_STBY_GROUPS"

print_list_block "Completed Actions" \
    "Configured tnsnames.ora with the standby entry." \
    "Configured listener.ora static registration on primary." \
    "Enabled FORCE LOGGING when required." \
    "Created missing standby redo logs." \
    "Enabled DG_BROKER_START and STANDBY_FILE_MANAGEMENT=AUTO."

print_list_block "Next Steps" \
    "On STANDBY, run ./standby/05_clone_standby.sh." \
    "Make sure the standby listener is running with static registration first." \
    "After the clone completes, run ./primary/06_configure_broker.sh."
