#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 9: Configure Fast-Start Failover
# ============================================================
# Run this script on the PRIMARY database server after
# Data Guard setup is complete (Step 7 verification passes).
#
# This script:
# - Creates a user with SYSDG privilege for observer authentication
# - Sets protection mode to MAXIMUM AVAILABILITY
# - Sets LogXptMode to FASTSYNC
# - Enables Fast-Start Failover
# - Copies password file to NFS for observer server
# - Outputs wallet setup instructions for observer
#
# After running this script, set up the observer:
#   1. On the observer server, run: ./fsfo/observer.sh setup
#   2. Then start the observer: ./fsfo/observer.sh start
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source common functions
source "${COMMON_DIR}/dg_functions.sh"
enable_verbose_mode "$@"

# Default FSFO threshold (seconds)
FSFO_THRESHOLD="${FSFO_THRESHOLD:-30}"

# ============================================================
# Main Script
# ============================================================

print_banner "Step 9: Configure Fast-Start Failover"
init_progress 14

# Initialize logging
init_log "09_configure_fsfo"

# ============================================================
# Pre-flight Checks
# ============================================================

progress_step "Pre-flight Checks"

check_oracle_env || exit 1
check_nfs_mount || exit 1
check_db_connection || exit 1

# ============================================================
# Load Configuration
# ============================================================

progress_step "Loading Configuration"

# Find standby config file
if ! select_config_file STANDBY_CONFIG_FILE "standby configuration" "${NFS_SHARE}/standby_config_*.env"; then
    log_error "Please run the Data Guard setup scripts first (Steps 1-7)"
    exit 1
fi

source "$STANDBY_CONFIG_FILE"

# Re-initialize log with DB name
init_log "09_configure_fsfo_${STANDBY_DB_UNIQUE_NAME}"

# ============================================================
# Verify Database Role
# ============================================================

progress_step "Verifying Database Role"

DB_ROLE=$(run_sql_query "get_db_role.sql")
DB_ROLE=$(echo "$DB_ROLE" | tr -d ' \t\n\r')

if [[ "$DB_ROLE" != "PRIMARY" ]]; then
    log_error "This script must be run on the PRIMARY database"
    log_error "Current database role: $DB_ROLE"
    exit 1
fi

log_info "Confirmed: Running on PRIMARY database"

# ============================================================
# Verify Data Guard Broker Configuration
# ============================================================

progress_step "Verifying Data Guard Broker"

CONFIG_STATUS=$(run_dgmgrl "show_configuration.dgmgrl" 2>&1 || true)

if echo "$CONFIG_STATUS" | grep -q "ORA-16532"; then
    log_error "No Data Guard Broker configuration found"
    log_error "Please complete Data Guard setup (Steps 1-8) before configuring FSFO"
    exit 1
fi

if echo "$CONFIG_STATUS" | grep -q "SUCCESS"; then
    log_info "Data Guard Broker configuration: SUCCESS"
elif echo "$CONFIG_STATUS" | grep -q "WARNING"; then
    log_warn "Data Guard Broker has warnings - review before proceeding"
    echo ""
    echo "$CONFIG_STATUS"
    echo ""
    # M8: gated so a --check run reaches the preflight summary instead of
    # prompting, and a non-interactive real run aborts explicitly instead
    # of silently misreading stdin.
    if ! confirm_proceed_or_check "Continue with FSFO configuration?"; then
        log_info "FSFO configuration cancelled by user"
        exit 0
    fi
else
    log_error "Data Guard Broker configuration is not healthy"
    echo ""
    echo "$CONFIG_STATUS"
    exit 1
fi

# ============================================================
# Check Synchronization Status
# ============================================================

progress_step "Checking Synchronization Status"

log_info "Querying transport and apply lag..."

# Keep stderr visible: $(...) captures only stdout, so a missing-script
# (SP2-0310) or ORA- error surfaces instead of an empty result.
SYNC_STATUS=$(run_sql_query "check_sync_status.sql" || true)

if [[ -z "$SYNC_STATUS" ]]; then
    log_warn "Could not query synchronization status"
    log_warn "V\$DATAGUARD_STATS may not be populated yet"
else
    echo ""
    echo "Current lag status:"
    echo "$SYNC_STATUS" | while IFS='|' read -r name value unit; do
        printf "  %-15s: %s %s\n" "$name" "$value" "$unit"
    done
    echo ""
fi

log_info "Note: For MAXIMUM AVAILABILITY, standby should be synchronized"
log_info "Minor lag is acceptable; FSFO will wait for sync before failover"

# ============================================================
# Check Current Protection Mode
# ============================================================

progress_step "Checking Current Protection Mode"

CURRENT_MODE=$(run_sql_query "get_db_status_pipe.sql" | awk -F'|' '{print $3}' | tr -d '\n\r' | sed 's/^ *//;s/ *$//')
log_info "Current protection mode: $CURRENT_MODE"

# ============================================================
# Detect Multitenant (CDB) Configuration
# ============================================================
# M11: on a CDB, CREATE USER without a C## prefix raises ORA-65096 (common
# user names must start with C##/c##), and the observer needs to be
# created as a common user anyway since dgmgrl connects at the root.

progress_step "Detecting Multitenant (CDB) Configuration"

IS_CDB=$(sqlplus -s / as sysdba << 'EOSQL'
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT CDB FROM V$DATABASE;
EXIT;
EOSQL
)
IS_CDB=$(echo "$IS_CDB" | tr -d ' \t\n\r')

if [[ "$IS_CDB" == "YES" ]]; then
    log_info "Multitenant (CDB) database detected - the observer user must be a common (C##) user"
else
    log_info "Non-CDB (single-container) database detected"
fi

# ============================================================
# Configuration Summary
# ============================================================

progress_step "Reviewing FSFO Configuration Summary"

print_list_block "This Step Will Change" \
    "Create or update an observer user with SYSDG privilege." \
    "Set LogXptMode to FASTSYNC on ${PRIMARY_DB_UNIQUE_NAME} and ${STANDBY_DB_UNIQUE_NAME}." \
    "Set protection mode to MAXIMUM AVAILABILITY when needed." \
    "Enable Fast-Start Failover and persist observer metadata into ${STANDBY_CONFIG_FILE}."

print_list_block "This Step Will Not Change" \
    "It will not start the observer process." \
    "It will not create the observer wallet." \
    "It will not change application services."

print_list_block "Recovery If This Step Fails" \
    "Review dgmgrl / 'show fast_start failover' for the exact failed operation." \
    "Disable FSFO or revert protection mode manually only if the failure leaves the config in an intermediate state." \
    "Re-run this step after correcting the observer user or transport issue."

record_next_step "./fsfo/observer.sh setup"

if [[ "$CHECK_ONLY" == "1" ]]; then
    finish_check_mode "FSFO preflight complete. No Broker or user changes were applied."
fi

# ============================================================
# Prompt for Observer Username
# ============================================================

log_section "Observer User Configuration"

echo ""
echo "The observer requires a database user with SYSDG privilege."
echo "You can use any username (e.g., dg_observer, fsfo_user, etc.)"
echo ""

# Default username suggestion (M11: a common-user prefix on a CDB)
DEFAULT_OBSERVER_USER="dg_observer"
[[ "$IS_CDB" == "YES" ]] && DEFAULT_OBSERVER_USER="c##dg_observer"

prompt_with_default "Enter username for observer" "$DEFAULT_OBSERVER_USER" OBSERVER_USER

# Convert to uppercase for Oracle
OBSERVER_USER=$(echo "$OBSERVER_USER" | tr '[:lower:]' '[:upper:]')

# M11: on a CDB, a common user name must start with C##. Auto-prefix
# rather than reject outright - interactively, confirm first; in a
# non-interactive run (e.g. piped automation), auto-prefix and log it
# clearly rather than adding an unconditional new prompt.
if [[ "$IS_CDB" == "YES" && "$OBSERVER_USER" != C##* ]]; then
    log_warn "This is a CDB - a common user name must start with C##"
    if [[ -t 0 ]]; then
        if confirm_proceed "Auto-prefix the username as C##${OBSERVER_USER}?"; then
            OBSERVER_USER="C##${OBSERVER_USER}"
        else
            log_error "Observer user must be a common user (C##...) on a CDB"
            exit 1
        fi
    else
        log_warn "Non-interactive stdin: auto-prefixing the observer username as C##${OBSERVER_USER}"
        OBSERVER_USER="C##${OBSERVER_USER}"
    fi
fi

# Validation regex allows '#' (needed for the CDB C## prefix) in addition
# to letters/digits/underscore/dollar. 30-char cap is Oracle's identifier
# limit.
if ! echo "$OBSERVER_USER" | grep -q '^[A-Za-z][A-Za-z0-9_$#]*$' || [[ ${#OBSERVER_USER} -gt 30 ]]; then
    log_error "Invalid observer username: $OBSERVER_USER"
    log_error "Usernames must start with a letter, contain only letters, numbers, underscore, dollar sign, and (on a CDB) '#', and be at most 30 characters"
    exit 1
fi

log_info "Observer username: $OBSERVER_USER"

echo ""
echo "The following changes will be made:"
echo ""
echo "  1. Create user          : $OBSERVER_USER (with SYSDG privilege)"
echo "  2. LogXptMode           : FASTSYNC (for both ${PRIMARY_DB_UNIQUE_NAME} and ${STANDBY_DB_UNIQUE_NAME})"
echo "  3. Protection Mode      : $CURRENT_MODE -> MAXIMUM AVAILABILITY"
echo "  4. FSFO Threshold       : ${FSFO_THRESHOLD} seconds"
echo "  5. FSFO Target          : ${STANDBY_DB_UNIQUE_NAME}"
echo "  6. Fast-Start Failover  : ENABLED"
echo ""

if ! confirm_proceed "Proceed with FSFO configuration?"; then
    log_info "FSFO configuration cancelled by user"
    exit 0
fi

# ============================================================
# Create Observer User with SYSDG Privilege
# ============================================================

progress_step "Creating Observer User"

# Check if user already exists
USER_EXISTS=$(sqlplus -s / as sysdba << EOF
SET HEADING OFF FEEDBACK OFF VERIFY OFF
SELECT COUNT(*) FROM dba_users WHERE username = '${OBSERVER_USER}';
EXIT;
EOF
)
USER_EXISTS=$(echo "$USER_EXISTS" | tr -d ' \t\n\r')

if [[ "$USER_EXISTS" == "1" ]]; then
    log_info "User $OBSERVER_USER already exists"

    # Check if user has SYSDG privilege. L5: SYSDG is a password-file/admin
    # privilege - it never shows up in DBA_ROLE_PRIVS (that only lists
    # regular roles). V$PWFILE_USERS is where it actually appears, so the
    # old query was always false here and could never detect a SYSDG grant
    # lost when step 8 replaced the password file.
    HAS_SYSDG=$(sqlplus -s / as sysdba << EOF
SET HEADING OFF FEEDBACK OFF VERIFY OFF
SELECT COUNT(*) FROM V\$PWFILE_USERS WHERE USERNAME = '${OBSERVER_USER}' AND SYSDG = 'TRUE';
EXIT;
EOF
)
    HAS_SYSDG=$(echo "$HAS_SYSDG" | tr -d ' \t\n\r')

    if [[ "$HAS_SYSDG" == "1" ]]; then
        log_info "User $OBSERVER_USER already has SYSDG privilege"
    else
        log_info "Granting SYSDG privilege to $OBSERVER_USER..."
        confirm_approval_action "Grant SYSDG and CREATE SESSION to observer user" "GRANT SYSDG TO ${OBSERVER_USER}; GRANT CREATE SESSION TO ${OBSERVER_USER};" || exit 1
        sqlplus -s / as sysdba << EOF
SET HEADING OFF FEEDBACK OFF VERIFY OFF
GRANT SYSDG TO ${OBSERVER_USER};
GRANT CREATE SESSION TO ${OBSERVER_USER};
EXIT;
EOF
        log_info "SYSDG privilege granted"
    fi

    if ! confirm_proceed "Do you want to reset the password for $OBSERVER_USER?"; then
        log_info "Keeping existing password for $OBSERVER_USER"
    else
        OBSERVER_PASSWORD=$(prompt_password "Enter new password for $OBSERVER_USER")

        if [[ -z "$OBSERVER_PASSWORD" ]]; then
            log_error "Password cannot be empty"
            exit 1
        fi

        if [[ "$OBSERVER_PASSWORD" == *'"'* ]]; then
            log_error "Password must not contain a double-quote (\") character"
            exit 1
        fi

        log_info "Updating password for $OBSERVER_USER..."
        log_cmd "sqlplus / as sysdba:" "ALTER USER ${OBSERVER_USER} IDENTIFIED BY ***"
        confirm_approval_action "Update observer user password" "ALTER USER ${OBSERVER_USER} IDENTIFIED BY ***" || exit 1
        RESULT=$(sqlplus -s / as sysdba << EOF
SET HEADING OFF FEEDBACK OFF VERIFY OFF
ALTER USER ${OBSERVER_USER} IDENTIFIED BY "${OBSERVER_PASSWORD}";
SELECT 'SUCCESS' FROM DUAL;
EXIT;
EOF
)

        if ! echo "$RESULT" | grep -q "SUCCESS"; then
            log_error "Failed to update password for $OBSERVER_USER"
            [[ -n "$OBSERVER_PASSWORD" ]] && RESULT=${RESULT//"$OBSERVER_PASSWORD"/********}
            echo "$RESULT"
            exit 1
        fi

        log_info "Password updated for $OBSERVER_USER"
    fi
else
    # Prompt for password
    OBSERVER_PASSWORD=$(prompt_password "Enter password for new user $OBSERVER_USER")

    if [[ -z "$OBSERVER_PASSWORD" ]]; then
        log_error "Password cannot be empty"
        exit 1
    fi

    if [[ "$OBSERVER_PASSWORD" == *'"'* ]]; then
        log_error "Password must not contain a double-quote (\") character"
        exit 1
    fi

    # Confirm password
    OBSERVER_PASSWORD_CONFIRM=$(prompt_password "Confirm password")

    if [[ "$OBSERVER_PASSWORD" != "$OBSERVER_PASSWORD_CONFIRM" ]]; then
        log_error "Passwords do not match"
        exit 1
    fi

    log_info "Creating user $OBSERVER_USER with SYSDG privilege..."
    log_cmd "sqlplus / as sysdba:" "CREATE USER ${OBSERVER_USER} IDENTIFIED BY ***"
    confirm_approval_action "Create observer user with SYSDG privilege" "CREATE USER ${OBSERVER_USER} IDENTIFIED BY ***; GRANT SYSDG TO ${OBSERVER_USER}; GRANT CREATE SESSION TO ${OBSERVER_USER};" || exit 1
    RESULT=$(sqlplus -s / as sysdba << EOF
SET HEADING OFF FEEDBACK OFF VERIFY OFF
CREATE USER ${OBSERVER_USER} IDENTIFIED BY "${OBSERVER_PASSWORD}";
GRANT SYSDG TO ${OBSERVER_USER};
GRANT CREATE SESSION TO ${OBSERVER_USER};
SELECT 'SUCCESS' FROM DUAL;
EXIT;
EOF
)

    if ! echo "$RESULT" | grep -q "SUCCESS"; then
        log_error "Failed to create user $OBSERVER_USER"
        [[ -n "$OBSERVER_PASSWORD" ]] && RESULT=${RESULT//"$OBSERVER_PASSWORD"/********}
        echo "$RESULT"
        exit 1
    fi

    log_info "User $OBSERVER_USER created successfully"
    log_info "Note: User will be replicated to standby via redo transport"
fi

# Clear password from memory
unset OBSERVER_PASSWORD
unset OBSERVER_PASSWORD_CONFIRM

# ============================================================
# Configure LogXptMode (must be done before changing protection mode)
# ============================================================

progress_step "Setting LogXptMode to FASTSYNC"

log_info "Setting LogXptMode to FASTSYNC for both databases..."

log_cmd "dgmgrl / :" "EDIT DATABASE '${PRIMARY_DB_UNIQUE_NAME}' SET PROPERTY LogXptMode='FASTSYNC'"
if ! run_dgmgrl_checked "set_logxptmode_fastsync.dgmgrl" "$PRIMARY_DB_UNIQUE_NAME"; then
    log_error "Failed to set LogXptMode=FASTSYNC on $PRIMARY_DB_UNIQUE_NAME"
    exit 1
fi
log_info "LogXptMode set to FASTSYNC for ${PRIMARY_DB_UNIQUE_NAME}"

log_cmd "dgmgrl / :" "EDIT DATABASE '${STANDBY_DB_UNIQUE_NAME}' SET PROPERTY LogXptMode='FASTSYNC'"
if ! run_dgmgrl_checked "set_logxptmode_fastsync.dgmgrl" "$STANDBY_DB_UNIQUE_NAME"; then
    log_error "Failed to set LogXptMode=FASTSYNC on $STANDBY_DB_UNIQUE_NAME"
    exit 1
fi
log_info "LogXptMode set to FASTSYNC for ${STANDBY_DB_UNIQUE_NAME}"

# ============================================================
# Configure Protection Mode
# ============================================================

progress_step "Setting Protection Mode to MAXIMUM AVAILABILITY"

# Normalize protection mode for comparison (remove spaces)
CURRENT_MODE_NORMALIZED=$(echo "$CURRENT_MODE" | tr -d ' ')

if [[ "$CURRENT_MODE_NORMALIZED" == "MAXIMUMAVAILABILITY" ]]; then
    log_info "Protection mode is already MAXIMUM AVAILABILITY"
else
    log_cmd "dgmgrl / :" "EDIT CONFIGURATION SET PROTECTION MODE AS MAXAVAILABILITY"
    # M7: no 2>&1 here - this is a mutating dgmgrl script, so run_dgmgrl's
    # own confirm_approval_action prompt goes to stderr; merging it into
    # this capture would swallow the prompt into $DGMGRL_OUTPUT invisibly
    # while still blocking on `read`, which looks like a silent hang in
    # approval mode. dgmgrl itself writes its output to stdout (same
    # assumption run_dgmgrl_checked already relies on), so dropping the
    # merge does not lose any diagnostic text.
    if ! DGMGRL_OUTPUT=$(run_dgmgrl "set_maxavailability.dgmgrl"); then
        log_error "DGMGRL command failed:"
        echo ""
        echo "$DGMGRL_OUTPUT"
        echo ""
        exit 1
    fi

    if echo "$DGMGRL_OUTPUT" | grep -qiE "error|ORA-"; then
        log_error "DGMGRL command failed:"
        echo ""
        echo "$DGMGRL_OUTPUT"
        echo ""
        exit 1
    fi

    # Verify change
    sleep 3
    NEW_MODE=$(run_sql_query "get_db_status_pipe.sql" | awk -F'|' '{print $3}' | tr -d ' \t\n\r')
    NEW_MODE_NORMALIZED=$(echo "$NEW_MODE" | tr -d ' ')

    if [[ "$NEW_MODE_NORMALIZED" == "MAXIMUMAVAILABILITY" ]]; then
        log_info "Protection mode set to MAXIMUM AVAILABILITY"
    else
        log_error "Failed to set protection mode (current: $NEW_MODE)"
        log_error "DGMGRL output was:"
        echo ""
        echo "$DGMGRL_OUTPUT"
        echo ""
        exit 1
    fi
fi

# ============================================================
# Configure FSFO Properties
# ============================================================

progress_step "Setting FSFO Properties"

log_cmd "dgmgrl / :" "EDIT CONFIGURATION SET PROPERTY FastStartFailoverThreshold=${FSFO_THRESHOLD}"
log_cmd "dgmgrl / :" "EDIT CONFIGURATION SET PROPERTY FastStartFailoverTarget='${STANDBY_DB_UNIQUE_NAME}'"
if ! run_dgmgrl_checked "set_fsfo_properties.dgmgrl" "$STANDBY_DB_UNIQUE_NAME" "$FSFO_THRESHOLD"; then
    log_error "Failed to set FSFO properties (threshold/target)"
    exit 1
fi

log_info "FSFO threshold set to ${FSFO_THRESHOLD} seconds"
log_info "FSFO target set to ${STANDBY_DB_UNIQUE_NAME}"

# ============================================================
# Enable Fast-Start Failover
# ============================================================

progress_step "Enabling Fast-Start Failover"

log_cmd "dgmgrl / :" "ENABLE FAST_START FAILOVER"
# M7: no 2>&1 (see the set_maxavailability.dgmgrl call above) - this is
# also a mutating dgmgrl script, so merging stderr would swallow the
# approval-mode prompt into $ENABLE_RESULT while still blocking on `read`.
ENABLE_RESULT=$(run_dgmgrl "enable_fsfo.dgmgrl" || true)

if echo "$ENABLE_RESULT" | grep -qiE "error|fail"; then
    log_error "Failed to enable Fast-Start Failover"
    echo ""
    echo "$ENABLE_RESULT"
    exit 1
fi

log_info "Fast-Start Failover enabled"

# ============================================================
# Copy Password File for Observer Server
# ============================================================

log_section "Preparing Files for Observer Server"

# Check if password file already exists on NFS
ORAPW_FILE="$ORACLE_HOME/dbs/orapw${ORACLE_SID}"
NFS_ORAPW_FILE="${NFS_SHARE}/orapw${PRIMARY_DB_NAME}"

if [[ -f "$NFS_ORAPW_FILE" ]]; then
    log_info "Password file already exists on NFS share"
else
    if [[ -f "$ORAPW_FILE" ]]; then
        log_info "Copying password file to NFS share..."
        # chmod 600 (owner-only): this file contains the SYS password hash
        # and the share is group-readable, so don't leave it group-readable
        # too. Run common/cleanup_nfs_artifacts.sh once the observer is
        # configured to remove it from the share entirely.
        confirm_approval_action "Copy primary password file for observer" "cp $ORAPW_FILE $NFS_ORAPW_FILE && chmod 600 $NFS_ORAPW_FILE" || exit 1
        ( umask 077; cp "$ORAPW_FILE" "$NFS_ORAPW_FILE" )
        chmod 600 "$NFS_ORAPW_FILE"
        log_info "Password file copied to: $NFS_ORAPW_FILE"
    else
        log_warn "Password file not found: $ORAPW_FILE"
        log_warn "Observer server may need manual password file configuration"
    fi
fi

# ============================================================
# Update Configuration File with FSFO Settings
# ============================================================

log_section "Updating Configuration File"

FSFO_WALLET_PATH='${ORACLE_HOME}/network/admin/wallet'

if ! grep -q "^FSFO_ENABLED=" "$STANDBY_CONFIG_FILE" 2>/dev/null; then
    confirm_approval_action "Append FSFO settings to standby configuration" "append FSFO configuration to $STANDBY_CONFIG_FILE" || exit 1
    cat >> "$STANDBY_CONFIG_FILE" << EOF

# ============================================================
# FSFO Configuration (added by Step 9)
# ============================================================
FSFO_ENABLED="YES"
FSFO_THRESHOLD="${FSFO_THRESHOLD}"
OBSERVER_USER="${OBSERVER_USER}"
OBSERVER_WALLET_DIR="${FSFO_WALLET_PATH}"
EOF
    log_info "Added FSFO settings to configuration file"
else
    confirm_approval_action "Refresh FSFO settings in standby configuration" "rewrite FSFO metadata in $STANDBY_CONFIG_FILE" || exit 1
    sed \
        -e "s/^FSFO_ENABLED=.*/FSFO_ENABLED=\"YES\"/" \
        -e "s/^FSFO_THRESHOLD=.*/FSFO_THRESHOLD=\"${FSFO_THRESHOLD}\"/" \
        -e "s/^OBSERVER_USER=.*/OBSERVER_USER=\"${OBSERVER_USER}\"/" \
        -e "s|^OBSERVER_WALLET_DIR=.*|OBSERVER_WALLET_DIR=\"${FSFO_WALLET_PATH}\"|" \
        "$STANDBY_CONFIG_FILE" > "${STANDBY_CONFIG_FILE}.tmp"
    mv "${STANDBY_CONFIG_FILE}.tmp" "$STANDBY_CONFIG_FILE"

    if ! grep -q "^FSFO_ENABLED=" "$STANDBY_CONFIG_FILE" 2>/dev/null; then
        echo "FSFO_ENABLED=\"YES\"" >> "$STANDBY_CONFIG_FILE"
    fi
    if ! grep -q "^FSFO_THRESHOLD=" "$STANDBY_CONFIG_FILE" 2>/dev/null; then
        echo "FSFO_THRESHOLD=\"${FSFO_THRESHOLD}\"" >> "$STANDBY_CONFIG_FILE"
    fi
    if ! grep -q "^OBSERVER_USER=" "$STANDBY_CONFIG_FILE" 2>/dev/null; then
        echo "OBSERVER_USER=\"${OBSERVER_USER}\"" >> "$STANDBY_CONFIG_FILE"
    fi
    if ! grep -q "^OBSERVER_WALLET_DIR=" "$STANDBY_CONFIG_FILE" 2>/dev/null; then
        echo "OBSERVER_WALLET_DIR=\"${FSFO_WALLET_PATH}\"" >> "$STANDBY_CONFIG_FILE"
    fi
    log_info "FSFO settings updated in configuration file"
fi
record_artifact "fsfo_config:${STANDBY_CONFIG_FILE}"

# ============================================================
# Display Final Configuration
# ============================================================

progress_step "Reviewing Final FSFO Configuration"

echo ""
run_dgmgrl "show_fsfo_status.dgmgrl"
echo ""

# ============================================================
# Summary
# ============================================================

print_summary "SUCCESS" "Fast-Start Failover configured"
print_status_block "FSFO Configuration" \
    "Protection Mode" "MAXIMUM AVAILABILITY" \
    "LogXptMode" "FASTSYNC" \
    "FSFO Threshold" "${FSFO_THRESHOLD} seconds" \
    "FSFO Target" "$STANDBY_DB_UNIQUE_NAME" \
    "Observer User" "$OBSERVER_USER"

print_list_block "Observer Setup" \
    "Ensure Oracle client is installed on the observer host." \
    "Configure tnsnames.ora with ${PRIMARY_TNS_ALIAS} and ${STANDBY_TNS_ALIAS}." \
    "Run ./fsfo/observer.sh setup." \
    "Run ./fsfo/observer.sh start." \
    "Verify with ./fsfo/observer.sh status."

print_list_block "Wallet Notes" \
    "The wallet avoids storing passwords in scripts or process arguments." \
    "observer.sh setup will prompt for the password of ${OBSERVER_USER}." \
    "The observer connects using dgmgrl /@${PRIMARY_TNS_ALIAS}." \
    "Automatic failover only works while the observer is running."
