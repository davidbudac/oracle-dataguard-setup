#!/bin/bash
# ============================================================
# Oracle Data Guard - FSFO Observer Lifecycle Management
# ============================================================
# Run this script on the OBSERVER server (can be standby or 3rd server).
#
# Usage:
#   ./observer.sh setup   - Set up Oracle Wallet for authentication
#   ./observer.sh start   - Start the observer process
#   ./observer.sh stop    - Stop the observer process
#   ./observer.sh status  - Check observer status
#   ./observer.sh restart - Restart the observer
#
# Prerequisites:
#   - FSFO must be configured (run Step 9 first)
#   - Oracle environment variables must be set
#   - For 3rd server: Oracle client installed, TNS entries configured
#   - Wallet must be set up before starting (run setup first)
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source common functions
source "${COMMON_DIR}/dg_functions.sh"

# ============================================================
# Functions
# ============================================================

usage() {
    echo "Usage: $0 {setup|start|stop|status|restart}"
    echo ""
    echo "Commands:"
    echo "  setup   - Set up Oracle Wallet for secure authentication"
    echo "  start   - Start the observer process in background"
    echo "  stop    - Stop the observer process"
    echo "  status  - Show observer status"
    echo "  restart - Restart the observer"
    echo ""
    echo "Environment Variables:"
    echo "  WALLET_DIR  - Override wallet directory (default: \$ORACLE_HOME/network/admin/wallet)"
    exit 1
}

get_config() {
    # Find and load standby config file
    STANDBY_CONFIG_FILES=(${NFS_SHARE}/standby_config_*.env)

    if [[ ${#STANDBY_CONFIG_FILES[@]} -eq 0 || ! -f "${STANDBY_CONFIG_FILES[0]}" ]]; then
        log_error "No standby configuration file found in ${NFS_SHARE}"
        exit 1
    elif [[ ${#STANDBY_CONFIG_FILES[@]} -eq 1 ]]; then
        STANDBY_CONFIG_FILE="${STANDBY_CONFIG_FILES[0]}"
    else
        # Use first config or let user select
        if [[ -t 0 ]]; then
            echo "Multiple configuration files found:"
            select STANDBY_CONFIG_FILE in "${STANDBY_CONFIG_FILES[@]}"; do
                if [[ -n "$STANDBY_CONFIG_FILE" ]]; then
                    break
                fi
            done
        else
            STANDBY_CONFIG_FILE="${STANDBY_CONFIG_FILES[0]}"
        fi
    fi

    source "$STANDBY_CONFIG_FILE"

    # Set wallet directory (can be overridden by environment variable)
    WALLET_DIR="${WALLET_DIR:-${ORACLE_HOME}/network/admin/wallet}"

    # Set PID and log file paths
    PID_FILE="${NFS_SHARE}/fsfo_observer_${STANDBY_DB_UNIQUE_NAME}.pid"
    LOG_FILE="${NFS_SHARE}/logs/fsfo_observer_${STANDBY_DB_UNIQUE_NAME}.log"
}

check_wallet_exists() {
    if [[ -f "${WALLET_DIR}/cwallet.sso" ]] || [[ -f "${WALLET_DIR}/ewallet.p12" ]]; then
        return 0
    fi
    return 1
}

is_observer_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

do_setup() {
    print_banner "Observer Wallet Setup"

    log_section "Pre-flight Checks"

    # Check ORACLE_HOME
    if [[ -z "$ORACLE_HOME" ]]; then
        log_error "ORACLE_HOME is not set"
        exit 1
    fi

    if [[ ! -d "$ORACLE_HOME" ]]; then
        log_error "ORACLE_HOME directory does not exist: $ORACLE_HOME"
        exit 1
    fi

    # Check mkstore exists
    if [[ ! -x "$ORACLE_HOME/bin/mkstore" ]]; then
        log_error "mkstore not found: $ORACLE_HOME/bin/mkstore"
        log_error "Oracle client/database installation may be incomplete"
        exit 1
    fi

    log_info "ORACLE_HOME: $ORACLE_HOME"
    log_info "Wallet directory: $WALLET_DIR"

    # ============================================================
    # Check for Existing Wallet
    # ============================================================

    log_section "Checking for Existing Wallet"

    if check_wallet_exists; then
        log_warn "Wallet already exists at: $WALLET_DIR"

        if ! confirm_proceed "Do you want to recreate the wallet?"; then
            log_info "Keeping existing wallet"

            # Check if credentials already exist
            echo ""
            echo "Testing existing wallet credentials..."

            if test_wallet_connection; then
                log_info "Wallet credentials are valid"
                echo ""
                echo "Wallet setup complete. You can now start the observer:"
                echo "  ./fsfo/observer.sh start"
                echo ""
                return 0
            else
                log_warn "Existing wallet credentials may be invalid"
                if ! confirm_proceed "Add/update credentials in existing wallet?"; then
                    exit 0
                fi
            fi
        else
            log_info "Removing existing wallet..."
            rm -rf "$WALLET_DIR"
        fi
    fi

    # ============================================================
    # Create Wallet Directory
    # ============================================================

    log_section "Creating Wallet"

    mkdir -p "$WALLET_DIR"
    chmod 700 "$WALLET_DIR"

    log_info "Created wallet directory: $WALLET_DIR"

    # ============================================================
    # Create Wallet
    # ============================================================

    if [[ ! -f "${WALLET_DIR}/ewallet.p12" ]]; then
        log_info "Creating new Oracle Wallet..."

        WALLET_PASSWORD=$(prompt_password "Enter wallet password (used to protect the wallet)")

        if [[ -z "$WALLET_PASSWORD" ]]; then
            log_error "Wallet password cannot be empty"
            exit 1
        fi

        WALLET_PASSWORD_CONFIRM=$(prompt_password "Confirm wallet password")

        if [[ "$WALLET_PASSWORD" != "$WALLET_PASSWORD_CONFIRM" ]]; then
            log_error "Passwords do not match"
            exit 1
        fi

        # Create auto-login wallet
        "$ORACLE_HOME/bin/mkstore" -wrl "$WALLET_DIR" -create << EOF
${WALLET_PASSWORD}
${WALLET_PASSWORD}
EOF

        if [[ $? -ne 0 ]]; then
            log_error "Failed to create wallet"
            exit 1
        fi

        # Enable auto-login (creates cwallet.sso)
        "$ORACLE_HOME/bin/mkstore" -wrl "$WALLET_DIR" -createSSO << EOF
${WALLET_PASSWORD}
EOF

        log_info "Wallet created with auto-login enabled"
    else
        log_info "Using existing wallet"

        WALLET_PASSWORD=$(prompt_password "Enter existing wallet password")

        if [[ -z "$WALLET_PASSWORD" ]]; then
            log_error "Wallet password cannot be empty"
            exit 1
        fi
    fi

    # ============================================================
    # Add Credentials
    # ============================================================

    log_section "Adding Observer Credentials"

    # Get observer username from config or prompt
    if [[ -z "$OBSERVER_USER" ]]; then
        echo ""
        echo "No observer username found in configuration."
        read -p "Enter observer username: " OBSERVER_USER
        OBSERVER_USER=$(echo "$OBSERVER_USER" | tr '[:lower:]' '[:upper:]')
    fi

    log_info "Observer username: $OBSERVER_USER"
    log_info "Adding credentials for: $PRIMARY_TNS_ALIAS and $STANDBY_TNS_ALIAS"
    log_info "These entries must match your tnsnames.ora entries"

    OBSERVER_PASSWORD=$(prompt_password "Enter password for $OBSERVER_USER")

    if [[ -z "$OBSERVER_PASSWORD" ]]; then
        log_error "Password cannot be empty"
        exit 1
    fi

    # Add credential for primary
    log_info "Adding credential for $PRIMARY_TNS_ALIAS..."
    "$ORACLE_HOME/bin/mkstore" -wrl "$WALLET_DIR" -createCredential "$PRIMARY_TNS_ALIAS" "$OBSERVER_USER" "$OBSERVER_PASSWORD" << EOF
${WALLET_PASSWORD}
EOF

    if [[ $? -ne 0 ]]; then
        log_error "Failed to add credential for $PRIMARY_TNS_ALIAS"
        exit 1
    fi

    # Add credential for standby
    log_info "Adding credential for $STANDBY_TNS_ALIAS..."
    "$ORACLE_HOME/bin/mkstore" -wrl "$WALLET_DIR" -createCredential "$STANDBY_TNS_ALIAS" "$OBSERVER_USER" "$OBSERVER_PASSWORD" << EOF
${WALLET_PASSWORD}
EOF

    if [[ $? -ne 0 ]]; then
        log_error "Failed to add credential for $STANDBY_TNS_ALIAS"
        exit 1
    fi

    # Clear passwords from memory
    unset WALLET_PASSWORD
    unset WALLET_PASSWORD_CONFIRM
    unset OBSERVER_PASSWORD

    log_info "Credentials added successfully"

    # ============================================================
    # Configure sqlnet.ora
    # ============================================================

    log_section "Configuring sqlnet.ora"

    SQLNET_FILE="${ORACLE_HOME}/network/admin/sqlnet.ora"
    WALLET_CONFIG="
# Oracle Wallet Configuration (added for FSFO observer)
WALLET_LOCATION = (SOURCE = (METHOD = FILE) (METHOD_DATA = (DIRECTORY = ${WALLET_DIR})))
SQLNET.WALLET_OVERRIDE = TRUE
"

    if [[ -f "$SQLNET_FILE" ]]; then
        if grep -q "WALLET_LOCATION" "$SQLNET_FILE"; then
            log_warn "WALLET_LOCATION already exists in sqlnet.ora"
            log_warn "Please verify it points to: $WALLET_DIR"
        else
            backup_file "$SQLNET_FILE"
            echo "$WALLET_CONFIG" >> "$SQLNET_FILE"
            log_info "Added wallet configuration to sqlnet.ora"
        fi
    else
        echo "$WALLET_CONFIG" > "$SQLNET_FILE"
        log_info "Created sqlnet.ora with wallet configuration"
    fi

    # ============================================================
    # Test Wallet Connection
    # ============================================================

    log_section "Testing Wallet Connection"

    if test_wallet_connection; then
        log_info "Wallet authentication test successful"
    else
        log_warn "Wallet authentication test failed"
        log_warn "Please verify:"
        log_warn "  1. TNS entries exist for $PRIMARY_TNS_ALIAS and $STANDBY_TNS_ALIAS"
        log_warn "  2. Databases are accessible"
        log_warn "  3. SYSDG user exists and password is correct"
    fi

    # ============================================================
    # Summary
    # ============================================================

    print_summary "SUCCESS" "Observer wallet configured"

    echo ""
    echo "WALLET SETUP COMPLETE"
    echo "====================="
    echo ""
    echo "  Wallet Location: $WALLET_DIR"
    echo "  Observer User:   $OBSERVER_USER"
    echo "  Credentials:     ${OBSERVER_USER}@$PRIMARY_TNS_ALIAS"
    echo "                   ${OBSERVER_USER}@$STANDBY_TNS_ALIAS"
    echo "  Auto-login:      Enabled"
    echo ""
    echo "NEXT STEPS"
    echo "=========="
    echo ""
    echo "  1. Start the observer:"
    echo "     ./fsfo/observer.sh start"
    echo ""
    echo "  2. Verify observer status:"
    echo "     ./fsfo/observer.sh status"
    echo ""
}

test_wallet_connection() {
    # Test connection using wallet
    log_info "Testing connection to $PRIMARY_TNS_ALIAS via wallet..."

    local result
    result=$("$ORACLE_HOME/bin/dgmgrl" -silent "/@${PRIMARY_TNS_ALIAS}" "show configuration" 2>&1 || true)

    if echo "$result" | grep -q "Configuration -\|SUCCESS\|WARNING"; then
        return 0
    else
        log_warn "Connection test output:"
        echo "$result" | head -5
        return 1
    fi
}

do_start() {
    log_info "Starting FSFO observer..."

    # Check if already running
    if is_observer_running; then
        local pid=$(cat "$PID_FILE")
        log_warn "Observer is already running (PID: $pid)"
        log_info "Use './observer.sh status' to check status"
        exit 0
    fi

    # Check if wallet exists
    if ! check_wallet_exists; then
        log_error "No Oracle Wallet found at: $WALLET_DIR"
        log_error "Please run './observer.sh setup' first to configure the wallet"
        exit 1
    fi

    # Verify FSFO is enabled
    log_info "Verifying FSFO is enabled..."
    FSFO_STATUS=$("$ORACLE_HOME/bin/dgmgrl" -silent "/@${PRIMARY_TNS_ALIAS}" "show fast_start failover" 2>&1 || true)

    if echo "$FSFO_STATUS" | grep -qi "disabled"; then
        log_error "Fast-Start Failover is not enabled"
        log_error "Please run Step 9 (primary/09_configure_fsfo.sh) first"
        exit 1
    fi

    if echo "$FSFO_STATUS" | grep -qi "ORA-\|error"; then
        log_error "Cannot connect to Data Guard configuration"
        log_error "Check wallet credentials and TNS configuration"
        echo ""
        echo "$FSFO_STATUS"
        exit 1
    fi

    # Ensure log directory exists
    mkdir -p "$(dirname "$LOG_FILE")"

    # Start observer in background using wallet authentication
    log_info "Starting observer process..."
    log_info "Log file: $LOG_FILE"

    nohup "$ORACLE_HOME/bin/dgmgrl" "/@${PRIMARY_TNS_ALIAS}" "START OBSERVER" > "$LOG_FILE" 2>&1 &
    OBSERVER_PID=$!

    # Save PID
    echo "$OBSERVER_PID" > "$PID_FILE"

    # Wait a moment and verify it's running
    sleep 3

    if is_observer_running; then
        log_info "Observer started successfully (PID: $OBSERVER_PID)"
        echo ""
        echo "Observer is now monitoring the Data Guard configuration."
        echo ""
        echo "To check status: ./observer.sh status"
        echo "To view logs:    tail -f $LOG_FILE"
        echo "To stop:         ./observer.sh stop"
    else
        log_error "Observer failed to start"
        log_error "Check log file: $LOG_FILE"

        if [[ -f "$LOG_FILE" ]]; then
            echo ""
            echo "Last 10 lines of log:"
            tail -10 "$LOG_FILE"
        fi

        rm -f "$PID_FILE"
        exit 1
    fi
}

do_stop() {
    log_info "Stopping FSFO observer..."

    if ! is_observer_running; then
        log_info "Observer is not running"
        rm -f "$PID_FILE" 2>/dev/null
        return 0
    fi

    local pid=$(cat "$PID_FILE")

    # Try graceful stop via DGMGRL first
    log_info "Sending stop command via DGMGRL..."

    if check_wallet_exists; then
        "$ORACLE_HOME/bin/dgmgrl" -silent "/@${PRIMARY_TNS_ALIAS}" "STOP OBSERVER" 2>/dev/null || true
    else
        # Fallback to OS auth if wallet not available
        "$ORACLE_HOME/bin/dgmgrl" -silent / "STOP OBSERVER" 2>/dev/null || true
    fi

    # Wait for process to exit
    local count=0
    while kill -0 "$pid" 2>/dev/null && [[ $count -lt 30 ]]; do
        sleep 1
        count=$((count + 1))
    done

    # Force kill if still running
    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Observer did not stop gracefully, sending SIGTERM..."
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2
    fi

    if kill -0 "$pid" 2>/dev/null; then
        log_warn "Observer still running, sending SIGKILL..."
        kill -KILL "$pid" 2>/dev/null || true
        sleep 1
    fi

    # Cleanup PID file
    rm -f "$PID_FILE"

    if ! kill -0 "$pid" 2>/dev/null; then
        log_info "Observer stopped successfully"
    else
        log_error "Failed to stop observer (PID: $pid)"
        exit 1
    fi
}

do_status() {
    echo ""
    echo "FSFO Observer Status"
    echo "===================="
    echo ""

    # Check process status
    if is_observer_running; then
        local pid=$(cat "$PID_FILE")
        echo "Process Status : RUNNING (PID: $pid)"
        echo "PID File       : $PID_FILE"
        echo "Log File       : $LOG_FILE"
    else
        echo "Process Status : NOT RUNNING"
        if [[ -f "$PID_FILE" ]]; then
            echo "Note: Stale PID file found, removing..."
            rm -f "$PID_FILE"
        fi
    fi

    echo ""
    echo "Wallet Status"
    echo "-------------"
    if check_wallet_exists; then
        echo "Wallet         : CONFIGURED ($WALLET_DIR)"
    else
        echo "Wallet         : NOT CONFIGURED"
        echo "Note: Run './observer.sh setup' to configure wallet"
    fi

    echo ""

    # Get FSFO status from DGMGRL
    echo "FSFO Configuration Status"
    echo "-------------------------"
    echo ""

    if check_wallet_exists; then
        "$ORACLE_HOME/bin/dgmgrl" -silent "/@${PRIMARY_TNS_ALIAS}" "show fast_start failover" 2>&1 || true
    else
        # Fallback to OS auth for status check (works if on primary/standby)
        "$ORACLE_HOME/bin/dgmgrl" -silent / "show fast_start failover" 2>&1 || echo "(Unable to connect - wallet not configured)"
    fi
    echo ""

    # Get observer info from V$DATABASE (if local)
    echo "Database Observer Info"
    echo "----------------------"
    FSFO_INFO=$(run_sql_query "get_fsfo_status.sql" 2>/dev/null || true)

    if [[ -n "$FSFO_INFO" ]]; then
        echo "$FSFO_INFO" | while IFS='|' read -r status present host; do
            printf "  %-25s: %s\n" "FS_FAILOVER_STATUS" "$status"
            printf "  %-25s: %s\n" "FS_FAILOVER_OBSERVER_PRESENT" "$present"
            printf "  %-25s: %s\n" "FS_FAILOVER_OBSERVER_HOST" "$host"
        done
    else
        echo "  (Unable to query V\$DATABASE - may be running on 3rd server)"
    fi
    echo ""
}

do_restart() {
    do_stop
    sleep 2
    do_start
}

# ============================================================
# Main
# ============================================================

# Verify command provided
if [[ $# -lt 1 ]]; then
    usage
fi

COMMAND="$1"

# Basic environment checks
check_oracle_env || exit 1
check_nfs_mount || exit 1

# Load configuration
get_config

# Execute command
case "$COMMAND" in
    setup)
        do_setup
        ;;
    start)
        do_start
        ;;
    stop)
        do_stop
        ;;
    status)
        do_status
        ;;
    restart)
        do_restart
        ;;
    *)
        usage
        ;;
esac
