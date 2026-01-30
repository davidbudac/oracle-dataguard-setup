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

# Default FSFO threshold (seconds)
FSFO_THRESHOLD="${FSFO_THRESHOLD:-30}"

# ============================================================
# Main Script
# ============================================================

print_banner "Step 9: Configure Fast-Start Failover"

# Initialize logging
init_log "09_configure_fsfo"

# ============================================================
# Pre-flight Checks
# ============================================================

log_section "Pre-flight Checks"

check_oracle_env || exit 1
check_nfs_mount || exit 1
check_db_connection || exit 1

# ============================================================
# Load Configuration
# ============================================================

log_section "Loading Configuration"

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

log_section "Verifying Database Role"

DB_ROLE=$(run_sql_query "get_db_role.sql")
DB_ROLE=$(echo "$DB_ROLE" | tr -d ' \n\r')

if [[ "$DB_ROLE" != "PRIMARY" ]]; then
    log_error "This script must be run on the PRIMARY database"
    log_error "Current database role: $DB_ROLE"
    exit 1
fi

log_info "Confirmed: Running on PRIMARY database"

# ============================================================
# Verify Data Guard Broker Configuration
# ============================================================

log_section "Verifying Data Guard Broker"

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
    if ! confirm_proceed "Continue with FSFO configuration?"; then
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

log_section "Checking Synchronization Status"

log_info "Querying transport and apply lag..."

SYNC_STATUS=$(run_sql_query "check_sync_status.sql" 2>/dev/null || true)

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

log_section "Checking Current Protection Mode"

CURRENT_MODE=$(run_sql_query "get_db_status_pipe.sql" | awk -F'|' '{print $3}' | tr -d '\n\r' | sed 's/^ *//;s/ *$//')
log_info "Current protection mode: $CURRENT_MODE"

# ============================================================
# Configuration Summary
# ============================================================

log_section "FSFO Configuration Summary"

# ============================================================
# Prompt for Observer Username
# ============================================================

log_section "Observer User Configuration"

echo ""
echo "The observer requires a database user with SYSDG privilege."
echo "You can use any username (e.g., dg_observer, fsfo_user, etc.)"
echo ""

# Default username suggestion
DEFAULT_OBSERVER_USER="dg_observer"

printf "Enter username for observer [$DEFAULT_OBSERVER_USER]: "
read OBSERVER_USER
OBSERVER_USER="${OBSERVER_USER:-$DEFAULT_OBSERVER_USER}"

# Convert to uppercase for Oracle
OBSERVER_USER=$(echo "$OBSERVER_USER" | tr '[:lower:]' '[:upper:]')

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

log_section "Creating Observer User with SYSDG Privilege"

# Check if user already exists
USER_EXISTS=$(sqlplus -s / as sysdba << EOF
SET HEADING OFF FEEDBACK OFF VERIFY OFF
SELECT COUNT(*) FROM dba_users WHERE username = '${OBSERVER_USER}';
EXIT;
EOF
)
USER_EXISTS=$(echo "$USER_EXISTS" | tr -d ' \n\r')

if [[ "$USER_EXISTS" == "1" ]]; then
    log_info "User $OBSERVER_USER already exists"

    # Check if user has SYSDG privilege
    HAS_SYSDG=$(sqlplus -s / as sysdba << EOF
SET HEADING OFF FEEDBACK OFF VERIFY OFF
SELECT COUNT(*) FROM dba_role_privs WHERE grantee = '${OBSERVER_USER}' AND granted_role = 'SYSDG';
EXIT;
EOF
)
    HAS_SYSDG=$(echo "$HAS_SYSDG" | tr -d ' \n\r')

    if [[ "$HAS_SYSDG" == "1" ]]; then
        log_info "User $OBSERVER_USER already has SYSDG privilege"
    else
        log_info "Granting SYSDG privilege to $OBSERVER_USER..."
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

        log_info "Updating password for $OBSERVER_USER..."
        log_cmd "sqlplus / as sysdba:" "ALTER USER ${OBSERVER_USER} IDENTIFIED BY ***"
        RESULT=$(sqlplus -s / as sysdba << EOF
SET HEADING OFF FEEDBACK OFF VERIFY OFF
ALTER USER ${OBSERVER_USER} IDENTIFIED BY "${OBSERVER_PASSWORD}";
SELECT 'SUCCESS' FROM DUAL;
EXIT;
EOF
)

        if ! echo "$RESULT" | grep -q "SUCCESS"; then
            log_error "Failed to update password for $OBSERVER_USER"
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

    # Confirm password
    OBSERVER_PASSWORD_CONFIRM=$(prompt_password "Confirm password")

    if [[ "$OBSERVER_PASSWORD" != "$OBSERVER_PASSWORD_CONFIRM" ]]; then
        log_error "Passwords do not match"
        exit 1
    fi

    log_info "Creating user $OBSERVER_USER with SYSDG privilege..."
    log_cmd "sqlplus / as sysdba:" "CREATE USER ${OBSERVER_USER} IDENTIFIED BY ***"
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

log_section "Setting LogXptMode to FASTSYNC"

log_info "Setting LogXptMode to FASTSYNC for both databases..."

log_cmd "dgmgrl / :" "EDIT DATABASE '${PRIMARY_DB_UNIQUE_NAME}' SET PROPERTY LogXptMode='FASTSYNC'"
run_dgmgrl "set_logxptmode_fastsync.dgmgrl" "$PRIMARY_DB_UNIQUE_NAME"
log_info "LogXptMode set to FASTSYNC for ${PRIMARY_DB_UNIQUE_NAME}"

log_cmd "dgmgrl / :" "EDIT DATABASE '${STANDBY_DB_UNIQUE_NAME}' SET PROPERTY LogXptMode='FASTSYNC'"
run_dgmgrl "set_logxptmode_fastsync.dgmgrl" "$STANDBY_DB_UNIQUE_NAME"
log_info "LogXptMode set to FASTSYNC for ${STANDBY_DB_UNIQUE_NAME}"

# ============================================================
# Configure Protection Mode
# ============================================================

log_section "Setting Protection Mode to MAXIMUM AVAILABILITY"

# Normalize protection mode for comparison (remove spaces)
CURRENT_MODE_NORMALIZED=$(echo "$CURRENT_MODE" | tr -d ' ')

if [[ "$CURRENT_MODE_NORMALIZED" == "MAXIMUMAVAILABILITY" ]]; then
    log_info "Protection mode is already MAXIMUM AVAILABILITY"
else
    log_cmd "dgmgrl / :" "EDIT CONFIGURATION SET PROTECTION MODE AS MAXAVAILABILITY"
    DGMGRL_OUTPUT=$(run_dgmgrl "set_maxavailability.dgmgrl" 2>&1)
    DGMGRL_RC=$?

    if [[ $DGMGRL_RC -ne 0 ]] || echo "$DGMGRL_OUTPUT" | grep -qi "error\|ORA-"; then
        log_error "DGMGRL command failed:"
        echo ""
        echo "$DGMGRL_OUTPUT"
        echo ""
        exit 1
    fi

    # Verify change
    sleep 3
    NEW_MODE=$(run_sql_query "get_db_status_pipe.sql" | awk -F'|' '{print $3}' | tr -d ' \n\r')
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

log_section "Setting FSFO Properties"

log_cmd "dgmgrl / :" "EDIT CONFIGURATION SET PROPERTY FastStartFailoverThreshold=${FSFO_THRESHOLD}"
log_cmd "dgmgrl / :" "EDIT CONFIGURATION SET PROPERTY FastStartFailoverTarget='${STANDBY_DB_UNIQUE_NAME}'"
run_dgmgrl "set_fsfo_properties.dgmgrl" "$STANDBY_DB_UNIQUE_NAME" "$FSFO_THRESHOLD"

log_info "FSFO threshold set to ${FSFO_THRESHOLD} seconds"
log_info "FSFO target set to ${STANDBY_DB_UNIQUE_NAME}"

# ============================================================
# Enable Fast-Start Failover
# ============================================================

log_section "Enabling Fast-Start Failover"

log_cmd "dgmgrl / :" "ENABLE FAST_START FAILOVER"
ENABLE_RESULT=$(run_dgmgrl "enable_fsfo.dgmgrl" 2>&1 || true)

if echo "$ENABLE_RESULT" | grep -qi "error\|fail"; then
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
        cp "$ORAPW_FILE" "$NFS_ORAPW_FILE"
        chmod 640 "$NFS_ORAPW_FILE"
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

# Add FSFO settings to config file if not present
if ! grep -q "^FSFO_ENABLED=" "$STANDBY_CONFIG_FILE" 2>/dev/null; then
    cat >> "$STANDBY_CONFIG_FILE" << EOF

# ============================================================
# FSFO Configuration (added by Step 9)
# ============================================================
FSFO_ENABLED="YES"
FSFO_THRESHOLD="${FSFO_THRESHOLD}"
OBSERVER_USER="${OBSERVER_USER}"
OBSERVER_WALLET_DIR="\${ORACLE_HOME}/network/admin/wallet"
EOF
    log_info "Added FSFO settings to configuration file"
else
    # Update OBSERVER_USER if it changed
    # AIX compatible: use temp file instead of sed -i
    if grep -q "^OBSERVER_USER=" "$STANDBY_CONFIG_FILE" 2>/dev/null; then
        sed "s/^OBSERVER_USER=.*/OBSERVER_USER=\"${OBSERVER_USER}\"/" "$STANDBY_CONFIG_FILE" > "${STANDBY_CONFIG_FILE}.tmp"
        mv "${STANDBY_CONFIG_FILE}.tmp" "$STANDBY_CONFIG_FILE"
    else
        echo "OBSERVER_USER=\"${OBSERVER_USER}\"" >> "$STANDBY_CONFIG_FILE"
    fi
    log_info "FSFO settings updated in configuration file"
fi

# ============================================================
# Display Final Configuration
# ============================================================

log_section "Final FSFO Configuration"

echo ""
run_dgmgrl "show_fsfo_status.dgmgrl"
echo ""

# ============================================================
# Summary
# ============================================================

print_summary "SUCCESS" "Fast-Start Failover configured"

echo ""
echo "FSFO CONFIGURATION COMPLETE"
echo "==========================="
echo ""
echo "  Protection Mode : MAXIMUM AVAILABILITY"
echo "  LogXptMode      : FASTSYNC"
echo "  FSFO Threshold  : ${FSFO_THRESHOLD} seconds"
echo "  FSFO Target     : ${STANDBY_DB_UNIQUE_NAME}"
echo "  FSFO Status     : ENABLED (observer not yet started)"
echo "  Observer User   : ${OBSERVER_USER} (with SYSDG privilege)"
echo ""
echo "NEXT STEPS - Observer Setup"
echo "==========================="
echo ""
echo "The observer can run on the standby server or a 3rd dedicated server."
echo "On the observer server:"
echo ""
echo "  1. Ensure Oracle client is installed"
echo "  2. Configure tnsnames.ora with entries for:"
echo "     - ${PRIMARY_TNS_ALIAS}"
echo "     - ${STANDBY_TNS_ALIAS}"
echo ""
echo "  3. Set up the observer wallet:"
echo "     ./fsfo/observer.sh setup"
echo ""
echo "  4. Start the observer:"
echo "     ./fsfo/observer.sh start"
echo ""
echo "  5. Verify observer status:"
echo "     ./fsfo/observer.sh status"
echo ""
echo "OBSERVER WALLET SETUP"
echo "====================="
echo ""
echo "The wallet provides secure authentication without storing passwords."
echo "When running './fsfo/observer.sh setup', you will be prompted for the"
echo "password for user ${OBSERVER_USER}."
echo ""
echo "The observer connects using: dgmgrl /@${PRIMARY_TNS_ALIAS}"
echo ""
echo "NOTE: The observer must be running for automatic failover to occur."
echo ""
