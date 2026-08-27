#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 5: Clone Standby Database
# ============================================================
# Run this script on the STANDBY database server.
# It performs RMAN duplicate to create the standby database.
#
# RMAN tuning flags:
#   -c, --channels NUM   Number of parallel auxiliary channels (default: 1)
#   -r, --rate RATE      Per-channel throughput limit (e.g. 200M, 1G)
#                        Default: unlimited
#
# Example: bash ./standby/05_clone_standby.sh -c 4 -r 200M
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source common functions
source "${COMMON_DIR}/dg_functions.sh"
enable_verbose_mode "$@"

# ============================================================
# Parse RMAN tuning flags
# ============================================================

RMAN_CHANNELS=1
RMAN_RATE=""

_args=("$@")
_i=0
while [[ $_i -lt ${#_args[@]} ]]; do
    case "${_args[$_i]}" in
        -c|--channels)
            _i=$((_i + 1))
            RMAN_CHANNELS="${_args[$_i]:-}"
            ;;
        -r|--rate)
            _i=$((_i + 1))
            RMAN_RATE="${_args[$_i]:-}"
            ;;
    esac
    _i=$((_i + 1))
done

if ! [[ "$RMAN_CHANNELS" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid --channels value: '$RMAN_CHANNELS' (must be a positive integer)"
    exit 1
fi

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

# Set Oracle environment. Prefer a locally-set ORACLE_HOME when it points
# at a usable installation (bin/sqlplus present) - the standby host's
# Oracle installation may live somewhere other than the path recorded in
# the config. Fall back to STANDBY_ORACLE_HOME from the config otherwise
# (same preference as 03_setup_standby_env.sh; check_oracle_env below
# still validates the final value).
if [[ -n "$ORACLE_HOME" && -x "$ORACLE_HOME/bin/sqlplus" ]]; then
    if [[ -n "$STANDBY_ORACLE_HOME" && "$ORACLE_HOME" != "$STANDBY_ORACLE_HOME" ]]; then
        log_warn "Locally-set ORACLE_HOME ($ORACLE_HOME) differs from config STANDBY_ORACLE_HOME ($STANDBY_ORACLE_HOME)"
        log_warn "Using the locally-set ORACLE_HOME"
    fi
    export ORACLE_HOME
else
    export ORACLE_HOME="$STANDBY_ORACLE_HOME"
fi
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
    "RMAN cmdfile: local private temp dir (mode 600, holds SYS connect strings, deleted after run)" \
    "RMAN log: ${NFS_SHARE}/logs/rman_duplicate_<timestamp>.log"

print_status_block "RMAN Tuning" \
    "Auxiliary channels" "$RMAN_CHANNELS" \
    "Per-channel rate" "${RMAN_RATE:-unlimited}"

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

# L16: verify_sys_password() and the RMAN CONNECT lines below both embed
# this in sys/"<pw>"@... - an embedded double-quote breaks that syntax and
# would otherwise be misreported as a plain "Invalid SYS password".
if [[ "$SYS_PASSWORD" == *'"'* ]]; then
    log_error "SYS password must not contain a double-quote (\") character"
    exit 1
fi

# Verify password against primary
log_info "Verifying SYS password against primary..."
if ! verify_sys_password "$SYS_PASSWORD" "$PRIMARY_TNS_ALIAS"; then
    # verify_sys_password() only reports pass/fail. Make a direct connection
    # attempt here so we can inspect the actual error text and distinguish a
    # locked SYS account (ORA-28000, typically left behind by
    # primary/08_security_hardening.sh) from a plain bad password or
    # connectivity failure, and point the operator at the right fix.
    # CONNECT is fed on stdin (sqlplus -s /nolog), not the sqlplus command
    # line, so SYS_PASSWORD never appears in `ps -ef`. WHENEVER SQLERROR EXIT
    # makes a failed CONNECT end the session immediately (error text still
    # lands in $VERIFY_ERROR_TEXT) instead of falling through to
    # check_connection.sql.
    pause_verbose_trace
    VERIFY_ERROR_TEXT=$(sqlplus -s /nolog <<SQL 2>&1
SET DEFINE OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE
CONNECT sys/"${SYS_PASSWORD}"@${PRIMARY_TNS_ALIAS} AS SYSDBA
@${SQL_DIR}/queries/check_connection.sql
SQL
) || true
    resume_verbose_trace
    if echo "$VERIFY_ERROR_TEXT" | grep -q "ORA-28000"; then
        log_error "SYS account on the primary is LOCKED (ORA-28000)"
        log_error ""
        log_error "This is expected if primary/08_security_hardening.sh has already run on the primary."
        log_error "To proceed with this clone, temporarily unlock and reset SYS on the PRIMARY:"
        log_error "  sqlplus / as sysdba"
        log_error "  ALTER USER SYS ACCOUNT UNLOCK;"
        log_error "  ALTER USER SYS IDENTIFIED BY <temporary_password>;"
        log_error ""
        log_error "After this clone completes, re-run primary/08_security_hardening.sh to re-harden SYS"
        log_error "(it generates a fresh random password, locks the account again, and re-propagates"
        log_error "the refreshed password file to this standby)."
    else
        log_error "Invalid SYS password or cannot connect to primary"
    fi
    exit 1
fi
log_info "Password verified successfully"

# ============================================================
# Start Instance in NOMOUNT
# ============================================================

progress_step "Starting Standby Instance"

# Check if instance is already running
INSTANCE_STATUS=$(run_sql_query "get_instance_status.sql" 2>&1 || true)

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
INSTANCE_STATUS=$(run_sql_query "get_instance_status.sql" 2>/dev/null || true)
INSTANCE_STATUS=$(echo "$INSTANCE_STATUS" | tr -d ' \t\n\r')

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

# Create RMAN script (cmdfile). It will hold the CONNECT TARGET/AUXILIARY
# lines (see below) needed to authenticate to primary and standby, so SYS
# credentials never appear on the rman process argv (visible via `ps -ef`
# for the life of the call). Because it briefly holds those credentials it
# must live in a local, private, mode-600 temp directory - never on the
# shared NFS share - and be removed on every exit path. RMAN runs locally
# against the local RMAN client, so a local temp dir works fine; only the
# RMAN log (unchanged, below) still goes to the NFS share.
# Private temp dir + EXIT-trap cleanup: create_temp_dir prefers `mktemp -d`,
# falling back to a mode-700 directory on AIX images without mktemp - safer
# than a predictable /tmp/..._$$ filename. No pre-existing EXIT trap in this
# script, so it is safe to install one here.
RMAN_TMP_DIR=$(create_temp_dir) || { log_error "Could not create temp directory"; exit 1; }
trap 'rm -rf "$RMAN_TMP_DIR"' EXIT
RMAN_SCRIPT="${RMAN_TMP_DIR}/rman_duplicate_$(date '+%Y%m%d_%H%M%S').rcv"
# Create the file and lock down permissions BEFORE any credential is written to it.
: > "$RMAN_SCRIPT"
chmod 600 "$RMAN_SCRIPT"

# Determine LOG_ARCHIVE_DEST_1 setting based on storage mode and FRA usage
if [[ "$STANDBY_STORAGE_MODE" == "OMF" || "$USE_FRA_FOR_STANDBY" == "YES" ]]; then
    LOG_ARCHIVE_DEST_1_SETTING="LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${STANDBY_DB_UNIQUE_NAME}"
else
    LOG_ARCHIVE_DEST_1_SETTING="LOCATION=${STANDBY_ARCHIVE_DEST} VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${STANDBY_DB_UNIQUE_NAME}"
fi

# Build optional RUN { ... } wrapper with auxiliary channel allocation.
# Allocated only when channels > 1 or rate is set; otherwise the bare
# DUPLICATE statement is used (preserving the default behavior).
RMAN_PROLOGUE=""
RMAN_EPILOGUE=""
if [[ "$RMAN_CHANNELS" -gt 1 || -n "$RMAN_RATE" ]]; then
    _rate_clause=""
    [[ -n "$RMAN_RATE" ]] && _rate_clause=" RATE $RMAN_RATE"

    _channel_lines=""
    _i=1
    while [[ $_i -le $RMAN_CHANNELS ]]; do
        _channel_lines="${_channel_lines}  ALLOCATE AUXILIARY CHANNEL aux${_i} TYPE DISK${_rate_clause};
"
        _i=$((_i + 1))
    done

    RMAN_PROLOGUE="RUN {
${_channel_lines}"
    RMAN_EPILOGUE="}"

    log_info "RMAN tuning: ${RMAN_CHANNELS} auxiliary channel(s)${RMAN_RATE:+, rate ${RMAN_RATE} per channel}"
fi

if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    # OMF mode: use db_create_file_dest, no FILE_NAME_CONVERT
    RMAN_BODY=$(cat <<EOF
# RMAN Duplicate for Standby (OMF Mode, Data Guard Broker Managed)
# Generated: $(date)
# Note: DG parameters (LOG_ARCHIVE_DEST_2, FAL_SERVER, etc.) will be
#       configured by Data Guard Broker after duplication completes.

${RMAN_PROLOGUE}
DUPLICATE TARGET DATABASE
  FOR STANDBY
  FROM ACTIVE DATABASE
  DORECOVER
  SPFILE
    SET DB_UNIQUE_NAME='${STANDBY_DB_UNIQUE_NAME}'
    SET DB_CREATE_FILE_DEST='${STANDBY_DB_CREATE_FILE_DEST}'
    SET DB_RECOVERY_FILE_DEST='${STANDBY_DB_RECOVERY_FILE_DEST}'
    SET DB_RECOVERY_FILE_DEST_SIZE='${STANDBY_DB_RECOVERY_FILE_DEST_SIZE}'
    SET LOG_ARCHIVE_DEST_1='${LOG_ARCHIVE_DEST_1_SETTING}'
    SET STANDBY_FILE_MANAGEMENT='AUTO'
    SET DG_BROKER_START='FALSE'
    SET LOCAL_LISTENER='(ADDRESS=(PROTOCOL=TCP)(HOST=${STANDBY_HOSTNAME})(PORT=${STANDBY_LISTENER_PORT}))'
    SET AUDIT_FILE_DEST='${STANDBY_ADMIN_DIR}/adump'
  NOFILENAMECHECK;
${RMAN_EPILOGUE}
EOF
)
else
    # Traditional mode: use FILE_NAME_CONVERT (existing behavior)
    if [[ "$USE_FRA_FOR_STANDBY" == "YES" ]]; then
        FRA_SETTINGS="    SET DB_RECOVERY_FILE_DEST='${STANDBY_FRA}'
    SET DB_RECOVERY_FILE_DEST_SIZE='${STANDBY_DB_RECOVERY_FILE_DEST_SIZE:-${DB_RECOVERY_FILE_DEST_SIZE}}'"
    else
        FRA_SETTINGS=""
    fi

    RMAN_BODY=$(cat <<EOF
# RMAN Duplicate for Standby (Data Guard Broker Managed)
# Generated: $(date)
# Note: DG parameters (LOG_ARCHIVE_DEST_2, FAL_SERVER, etc.) will be
#       configured by Data Guard Broker after duplication completes.

${RMAN_PROLOGUE}
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
    SET DG_BROKER_START='FALSE'
    SET LOCAL_LISTENER='(ADDRESS=(PROTOCOL=TCP)(HOST=${STANDBY_HOSTNAME})(PORT=${STANDBY_LISTENER_PORT}))'
    SET AUDIT_FILE_DEST='${STANDBY_ADMIN_DIR}/adump'
  NOFILENAMECHECK;
${RMAN_EPILOGUE}
EOF
)
fi

# Write the CONNECT lines first (RMAN requires TARGET/AUXILIARY connected
# before DUPLICATE can run), then the duplicate statement body. The file
# was created with chmod 600 above, before either password was written.
{
    printf 'CONNECT TARGET SYS/"%s"@%s;\n' "${SYS_PASSWORD}" "${PRIMARY_TNS_ALIAS}"
    printf 'CONNECT AUXILIARY SYS/"%s"@%s;\n' "${SYS_PASSWORD}" "${STANDBY_TNS_ALIAS}"
    printf '%s\n' "$RMAN_BODY"
} >> "$RMAN_SCRIPT"

log_info "RMAN script created: $RMAN_SCRIPT"
# RMAN masks credentials in its own echo of a script-embedded CONNECT
# command (it prints "connect target *" / "connect auxiliary *", never the
# literal connect string), so the RMAN_LOG produced below does not capture
# the password either. As a second layer, the diagnostic dump below only
# ever logs the non-credential DUPLICATE body - never the CONNECT lines.
log_detail "RMAN script contents (CONNECT lines redacted):"
log_detail "  CONNECT TARGET sys/***@${PRIMARY_TNS_ALIAS};"
log_detail "  CONNECT AUXILIARY sys/***@${STANDBY_TNS_ALIAS};"
while IFS= read -r line; do
    log_detail "  $line"
done <<< "$RMAN_BODY"
record_artifact "rman_script:${RMAN_SCRIPT} (transient - deleted after this run)"

# Execute RMAN
RMAN_LOG="${NFS_SHARE}/logs/rman_duplicate_$(date '+%Y%m%d_%H%M%S').log"

log_info "Starting RMAN duplicate (logging to: $RMAN_LOG)..."
log_cmd "rman" "cmdfile ${RMAN_SCRIPT}  # CONNECT TARGET sys/***@${PRIMARY_TNS_ALIAS}, CONNECT AUXILIARY sys/***@${STANDBY_TNS_ALIAS}"
echo ""
confirm_approval_action "Run RMAN duplicate for standby creation" "\"$ORACLE_HOME/bin/rman\" cmdfile ${RMAN_SCRIPT}  # cmdfile opens with CONNECT TARGET sys/***@${PRIMARY_TNS_ALIAS} and CONNECT AUXILIARY sys/***@${STANDBY_TNS_ALIAS}" || exit 1

# Use tee to display output on screen AND write to log file
# AIX compatible: use temp file to capture exit code instead of PIPESTATUS.
# Reuse RMAN_TMP_DIR (created above, mode 700, already covered by the
# EXIT-trap installed above) for the exit-code file too.
RMAN_EXIT_FILE="${RMAN_TMP_DIR}/rman_exit.$$"
# Disable errexit around the pipeline so an RMAN failure still writes the
# exit-code file and reaches the failure-handling block below.
set +e
(
"$ORACLE_HOME/bin/rman" cmdfile "${RMAN_SCRIPT}"
echo $? > "$RMAN_EXIT_FILE"
) 2>&1 | tee "$RMAN_LOG"
set -e

RMAN_EXIT_CODE=$(cat "$RMAN_EXIT_FILE" 2>/dev/null || echo "1")

# Remove the cmdfile (and exit-code file) now that RMAN is done with them -
# the cmdfile held SYS credentials. The EXIT trap above remains the safety
# net for early/abnormal exits; this is the prompt cleanup on the normal path.
rm -rf "$RMAN_TMP_DIR"

# Clear password from memory
SYS_PASSWORD=""

if [[ $RMAN_EXIT_CODE -ne 0 ]]; then
    log_error "RMAN duplicate failed with exit code: $RMAN_EXIT_CODE"
    log_error "Please check the RMAN log: $RMAN_LOG"

    # M10: this step is not restartable once RMAN duplicate has started -
    # the reset procedure was only printed once, in "Reviewing Planned
    # Changes", several minutes/many lines of RMAN output ago. Re-print it
    # here with the actual concrete paths for this build so it's still on
    # screen (and in the log) right where the failure just happened.
    if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
        RESET_DATA_NOTE="Remove standby files under: ${STANDBY_DB_CREATE_FILE_DEST}, ${STANDBY_DB_RECOVERY_FILE_DEST}"
    else
        RESET_DATA_PATHS=("$STANDBY_DATA_PATH")
        if [[ -n "${STANDBY_DATA_PATHS+x}" && ${#STANDBY_DATA_PATHS[@]} -gt 0 ]]; then
            RESET_DATA_PATHS=("${STANDBY_DATA_PATHS[@]}")
        fi
        RESET_REDO_PATHS=("$STANDBY_REDO_PATH")
        if [[ -n "${STANDBY_REDO_PATHS+x}" && ${#STANDBY_REDO_PATHS[@]} -gt 0 ]]; then
            RESET_REDO_PATHS=("${STANDBY_REDO_PATHS[@]}")
        fi
        RESET_SRL_NOTE=""
        if [[ -n "${STANDBY_SRL_PATH:-}" && "$STANDBY_SRL_PATH" != "$STANDBY_REDO_PATH" ]]; then
            RESET_SRL_NOTE=", ${STANDBY_SRL_PATH}"
        fi
        RESET_DATA_NOTE="Remove standby datafiles/controlfiles under: $(shell_join "${RESET_DATA_PATHS[@]}"); redo logs under: $(shell_join "${RESET_REDO_PATHS[@]}")${RESET_SRL_NOTE}"
    fi

    echo ""
    print_list_block "This Step Is NOT Directly Restartable - Reset Procedure" \
        "Shut down the standby instance: ORACLE_SID=${STANDBY_ORACLE_SID} sqlplus / as sysdba, then SHUTDOWN ABORT." \
        "$RESET_DATA_NOTE" \
        "Review the RMAN log first to confirm which files actually exist before deleting anything: ${RMAN_LOG}" \
        "Re-run ./standby/05_clone_standby.sh after correcting the failure."

    exit 1
fi

log_success "RMAN duplicate completed successfully"
record_artifact "rman_log:${RMAN_LOG}"

# ============================================================
# Create SPFILE and Restart
# ============================================================

progress_step "Finalizing Instance Configuration"

# Check if we're mounted
INSTANCE_STATUS=$(run_sql_query "get_instance_status.sql" 2>/dev/null || true)
INSTANCE_STATUS=$(echo "$INSTANCE_STATUS" | tr -d ' \t\n\r')

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

# RMAN DUPLICATE ... FOR STANDBY normally leaves the auxiliary instance
# already MOUNTED once the duplicate completes, so re-issuing MOUNT STANDBY
# DATABASE here would raise ORA-01100 (database already mounted) now that
# mount_standby.sql aborts on SQL errors. Only mount if it isn't already.
INSTANCE_STATUS=$(run_sql_query "get_instance_status.sql" 2>/dev/null || true)
INSTANCE_STATUS=$(echo "$INSTANCE_STATUS" | tr -d ' \t\n\r')

if [[ "$INSTANCE_STATUS" == "MOUNTED" ]]; then
    log_info "Standby instance is already mounted (left MOUNTED by RMAN duplicate) - skipping MOUNT STANDBY DATABASE"
else
    run_sql_command "mount_standby.sql"
fi

# The duplicate ran with DG_BROKER_START='FALSE' (deliberately: with the
# broker up DURING the clone, a leftover broker configuration file from an
# earlier standby build - which the documented re-clone reset procedure
# never removes - makes DMON start managed recovery mid-duplicate and the
# duplicate dies with ORA-01153; found live in the E2E run). Now that the
# clone is complete: clear any stale broker config files for this standby
# at their default location while the broker is still down, then enable it.
for _dr_file in "${ORACLE_HOME}/dbs/dr1${STANDBY_DB_UNIQUE_NAME}.dat" "${ORACLE_HOME}/dbs/dr2${STANDBY_DB_UNIQUE_NAME}.dat"; do
    if [[ -f "$_dr_file" ]]; then
        log_warn "Removing stale broker configuration file from a previous build: $_dr_file"
        rm -f "$_dr_file"
    fi
done
log_info "Enabling Data Guard Broker on the standby (was disabled during the duplicate)..."
log_cmd "sqlplus / as sysdba:" "ALTER SYSTEM SET DG_BROKER_START=TRUE SCOPE=BOTH"
run_sql_command "set_dg_broker_start.sql"

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

# L15: refresh the instance status here. The last assignment above was
# taken BEFORE the MOUNT STANDBY DATABASE / start_mrp.sql calls just above
# - the final summary block below used to print that pre-mount value
# (typically "STARTED") even though the instance is mounted and applying
# by this point.
INSTANCE_STATUS=$(run_sql_query "get_instance_status.sql" 2>/dev/null || true)
INSTANCE_STATUS=$(echo "$INSTANCE_STATUS" | tr -d ' \t\n\r')

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
