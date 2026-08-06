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
#
# Note on mkstore and `ps -ef`: mkstore has no stdin-based way to pass the
# observer credential password to -createCredential (only the wallet
# password itself can be fed via stdin/heredoc). The observer password
# therefore appears briefly on the mkstore process argv at the
# -createCredential call sites in the `setup` command below. This is a
# short, one-time exposure at setup time (not a long-lived service argv);
# see the comments at each call site.
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source common functions
source "${COMMON_DIR}/dg_functions.sh"
enable_verbose_mode "$@"

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
    if ! select_config_file STANDBY_CONFIG_FILE "standby configuration" "${NFS_SHARE}/standby_config_*.env"; then
        exit 1
    fi

    source "$STANDBY_CONFIG_FILE"

    # Set wallet directory (env override, then config, then ORACLE_HOME default)
    WALLET_DIR="${WALLET_DIR:-${OBSERVER_WALLET_DIR:-${ORACLE_HOME}/network/admin/wallet}}"

    # Set PID and log file paths.
    # Two separate log files, deliberately: OBSERVER_LOG_FILE is the dgmgrl
    # observer process's own stdout/stderr, which holds FSFO failover
    # history and must never be truncated on a later start/restart.
    # LOG_FILE is dg_functions.sh's global log target for this script's own
    # log_info/log_warn/log_error messages - if it shared OBSERVER_LOG_FILE's
    # path, do_start()'s truncating redirect into that path would wipe the
    # observer's history every time (the bug this split fixes).
    PID_FILE="${NFS_SHARE}/fsfo_observer_${STANDBY_DB_UNIQUE_NAME}.pid"
    OBSERVER_LOG_FILE="${NFS_SHARE}/logs/fsfo_observer_${STANDBY_DB_UNIQUE_NAME}.log"
    LOG_FILE="${NFS_SHARE}/logs/fsfo_observer_${STANDBY_DB_UNIQUE_NAME}_script.log"
}

check_wallet_exists() {
    if [[ -f "${WALLET_DIR}/cwallet.sso" ]] || [[ -f "${WALLET_DIR}/ewallet.p12" ]]; then
        return 0
    fi
    return 1
}

is_observer_running() {
    # Sets OBSERVER_PID (local case) or OBSERVER_REMOTE_HOST (pidfile was
    # written by another host - the NFS-shared pidfile stores host:pid
    # because PIDs are only meaningful on the host that wrote them).
    OBSERVER_PID=""
    OBSERVER_REMOTE_HOST=""

    if [[ ! -f "$PID_FILE" ]]; then
        return 1
    fi

    local entry pid pid_host
    entry=$(cat "$PID_FILE")

    if [[ -z "$entry" ]]; then
        rm -f "$PID_FILE"
        return 1
    fi

    case "$entry" in
        *:*)
            pid_host="${entry%%:*}"
            pid="${entry#*:}"
            ;;
        *)
            # Legacy pidfile with a bare PID - treat as local host.
            pid_host="$(hostname)"
            pid="$entry"
            ;;
    esac

    if [[ -z "$pid" ]]; then
        rm -f "$PID_FILE"
        return 1
    fi

    if [[ "$pid_host" != "$(hostname)" ]]; then
        # The PID belongs to another host and cannot be validated (or
        # cleaned up) from here - report the observer as running there.
        OBSERVER_REMOTE_HOST="$pid_host"
        return 0
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        # Process is gone - stale pidfile left over from a prior run.
        rm -f "$PID_FILE"
        return 1
    fi

    # kill -0 only proves *some* process owns this PID. After a reboot the
    # PID may have been recycled by an unrelated process, which would make
    # status/start/stop all trust the wrong process. Verify the command
    # line actually looks like our dgmgrl observer before trusting it.
    if ! ps -p "$pid" -o args= 2>/dev/null | grep -qi 'dgmgrl'; then
        log_warn "PID $pid from $PID_FILE is not a dgmgrl process - treating pidfile as stale"
        rm -f "$PID_FILE"
        return 1
    fi

    OBSERVER_PID="$pid"
    return 0
}

require_observer_tools() {
    check_oracle_client_env || exit 1
    export PATH="$ORACLE_HOME/bin:$PATH"
}

do_setup() {
    print_banner "Observer Wallet Setup"

    log_section "Pre-flight Checks"

    require_observer_tools

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

    # NEW_WALLET_STAGED=true means the wallet is being (re)built from
    # scratch in a temporary staging directory and only swapped into
    # $WALLET_DIR after every step below succeeds - so a failure never
    # leaves the live wallet missing or half-written.
    NEW_WALLET_STAGED=false

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
            if ! confirm_typed_value "This will replace the existing wallet at ${WALLET_DIR}." "RECREATE WALLET"; then
                log_info "Wallet recreation cancelled by user"
                exit 0
            fi
            log_info "Wallet will be rebuilt in a staging directory and swapped in only on success"
            NEW_WALLET_STAGED=true
        fi
    else
        NEW_WALLET_STAGED=true
    fi

    # ============================================================
    # Create Wallet Directory
    # ============================================================

    log_section "Creating Wallet"

    if $NEW_WALLET_STAGED; then
        if command -v mktemp >/dev/null 2>&1; then
            WORK_WALLET_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dg_observer_wallet.XXXXXX")
        else
            WORK_WALLET_DIR="${TMPDIR:-/tmp}/dg_observer_wallet.$$"
            mkdir -p "$WORK_WALLET_DIR"
        fi
        chmod 700 "$WORK_WALLET_DIR"
        log_info "Staging new wallet in: $WORK_WALLET_DIR"
    else
        WORK_WALLET_DIR="$WALLET_DIR"
        mkdir -p "$WORK_WALLET_DIR"
        chmod 700 "$WORK_WALLET_DIR"
        log_info "Using existing wallet directory: $WORK_WALLET_DIR"
    fi

    # ============================================================
    # Create Wallet
    # ============================================================

    if [[ ! -f "${WORK_WALLET_DIR}/ewallet.p12" ]]; then
        log_info "Creating new Oracle Wallet..."

        WALLET_PASSWORD=$(prompt_password "Enter wallet password (used to protect the wallet)")

        if [[ -z "$WALLET_PASSWORD" ]]; then
            log_error "Wallet password cannot be empty"
            $NEW_WALLET_STAGED && rm -rf "$WORK_WALLET_DIR"
            exit 1
        fi

        WALLET_PASSWORD_CONFIRM=$(prompt_password "Confirm wallet password")

        if [[ "$WALLET_PASSWORD" != "$WALLET_PASSWORD_CONFIRM" ]]; then
            log_error "Passwords do not match"
            $NEW_WALLET_STAGED && rm -rf "$WORK_WALLET_DIR"
            exit 1
        fi

        # Create auto-login wallet
        if ! "$ORACLE_HOME/bin/mkstore" -wrl "$WORK_WALLET_DIR" -create << EOF
${WALLET_PASSWORD}
${WALLET_PASSWORD}
EOF
        then
            log_error "Failed to create wallet"
            $NEW_WALLET_STAGED && rm -rf "$WORK_WALLET_DIR"
            exit 1
        fi

        # Enable auto-login (creates cwallet.sso)
        if ! "$ORACLE_HOME/bin/mkstore" -wrl "$WORK_WALLET_DIR" -createSSO << EOF
${WALLET_PASSWORD}
EOF
        then
            log_error "Failed to enable auto-login (createSSO) for wallet"
            $NEW_WALLET_STAGED && rm -rf "$WORK_WALLET_DIR"
            exit 1
        fi

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
        printf "Enter observer username: "
        read OBSERVER_USER
        OBSERVER_USER=$(echo "$OBSERVER_USER" | tr '[:lower:]' '[:upper:]')
    fi

    log_info "Observer username: $OBSERVER_USER"
    log_info "Adding credentials for: $PRIMARY_TNS_ALIAS and $STANDBY_TNS_ALIAS"
    log_info "These entries must match your tnsnames.ora entries"

    OBSERVER_PASSWORD=$(prompt_password "Enter password for $OBSERVER_USER")

    if [[ -z "$OBSERVER_PASSWORD" ]]; then
        log_error "Password cannot be empty"
        $NEW_WALLET_STAGED && rm -rf "$WORK_WALLET_DIR"
        exit 1
    fi

    # Add credential for primary
    # NOTE: mkstore has no stdin-based way to supply the credential password
    # to -createCredential (only the wallet password above can be piped in),
    # so $OBSERVER_PASSWORD is briefly visible on this process's argv
    # (`ps -ef`) for the short lifetime of this one mkstore invocation. This
    # is a known limitation of the mkstore CLI, not something this script
    # can route around; the exposure is a one-time setup event, not a
    # persistent service argv.
    #
    # Delete-then-create (mirrors common/setup_dg_wallet.sh's
    # add_credential()): re-running setup into an existing wallet (e.g. to
    # rotate the observer password) otherwise hits "Failed to add
    # credential" because -createCredential refuses to overwrite an alias
    # that's already present. The delete is a no-op (ignored) when the
    # entry doesn't exist yet.
    log_info "Adding credential for $PRIMARY_TNS_ALIAS..."
    "$ORACLE_HOME/bin/mkstore" -wrl "$WORK_WALLET_DIR" -deleteCredential "$PRIMARY_TNS_ALIAS" << EOF 2>/dev/null || true
${WALLET_PASSWORD}
EOF
    if ! "$ORACLE_HOME/bin/mkstore" -wrl "$WORK_WALLET_DIR" -createCredential "$PRIMARY_TNS_ALIAS" "$OBSERVER_USER" "$OBSERVER_PASSWORD" << EOF
${WALLET_PASSWORD}
EOF
    then
        log_error "Failed to add credential for $PRIMARY_TNS_ALIAS"
        $NEW_WALLET_STAGED && rm -rf "$WORK_WALLET_DIR"
        exit 1
    fi

    # Add credential for standby (same mkstore argv caveat and
    # delete-then-create pattern as above)
    log_info "Adding credential for $STANDBY_TNS_ALIAS..."
    "$ORACLE_HOME/bin/mkstore" -wrl "$WORK_WALLET_DIR" -deleteCredential "$STANDBY_TNS_ALIAS" << EOF 2>/dev/null || true
${WALLET_PASSWORD}
EOF
    if ! "$ORACLE_HOME/bin/mkstore" -wrl "$WORK_WALLET_DIR" -createCredential "$STANDBY_TNS_ALIAS" "$OBSERVER_USER" "$OBSERVER_PASSWORD" << EOF
${WALLET_PASSWORD}
EOF
    then
        log_error "Failed to add credential for $STANDBY_TNS_ALIAS"
        $NEW_WALLET_STAGED && rm -rf "$WORK_WALLET_DIR"
        exit 1
    fi

    # ============================================================
    # Activate Staged Wallet
    # ============================================================
    # Everything above succeeded, so it is now safe to swap the fully
    # built wallet into place. The original wallet (if any) is moved
    # aside as a timestamped backup rather than deleted.

    if $NEW_WALLET_STAGED; then
        log_section "Activating New Wallet"

        if [[ -d "$WALLET_DIR" ]]; then
            WALLET_SWAP_BACKUP="${WALLET_DIR}.bak.$(date '+%Y%m%d_%H%M%S')_$$"
            if ! mv "$WALLET_DIR" "$WALLET_SWAP_BACKUP"; then
                log_error "Failed to move existing wallet out of the way: $WALLET_DIR"
                log_error "New wallet remains staged (not activated) at: $WORK_WALLET_DIR"
                exit 1
            fi
            log_info "Previous wallet backed up to: $WALLET_SWAP_BACKUP"
        fi

        if ! mv "$WORK_WALLET_DIR" "$WALLET_DIR"; then
            log_error "Failed to move staged wallet into place: $WALLET_DIR"
            if [[ -n "${WALLET_SWAP_BACKUP:-}" ]]; then
                log_error "Restoring previous wallet from backup: $WALLET_SWAP_BACKUP"
                mv "$WALLET_SWAP_BACKUP" "$WALLET_DIR" 2>/dev/null || log_error "Restore failed - previous wallet backup left at: $WALLET_SWAP_BACKUP"
            fi
            log_error "Staged wallet left at: $WORK_WALLET_DIR for manual recovery"
            exit 1
        fi

        log_info "New wallet activated at: $WALLET_DIR"
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
        # Anchored to only match a WALLET_LOCATION entry, not
        # ENCRYPTION_WALLET_LOCATION (TDE keystore) - a plain substring grep
        # matches both, so on a TDE host (e.g. cdb1 on dbmint) this used to
        # report the TDE keystore as the "existing" observer wallet and skip
        # adding the real WALLET_LOCATION entry entirely.
        if grep -Eq '^[[:space:]]*WALLET_LOCATION' "$SQLNET_FILE"; then
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

    if echo "$result" | grep -qE "Configuration -|SUCCESS|WARNING"; then
        return 0
    else
        log_warn "Connection test output:"
        echo "$result" | head -5
        return 1
    fi
}

do_start() {
    require_observer_tools
    log_info "Starting FSFO observer..."

    # Check if already running
    if is_observer_running; then
        if [[ -n "$OBSERVER_REMOTE_HOST" ]]; then
            log_error "Observer is already running on host ${OBSERVER_REMOTE_HOST} (per $PID_FILE)"
            log_error "Run './observer.sh stop' on that host first if it must move"
            exit 1
        fi
        log_warn "Observer is already running (PID: $OBSERVER_PID)"
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

    # Match only genuine Oracle/TNS error codes here. A bare "error" match
    # is a false positive: the normal "show fast_start failover" output
    # contains the labels "Oracle Error Conditions:" and "Datafile Write
    # Errors", which would otherwise abort a perfectly healthy start.
    if echo "$FSFO_STATUS" | grep -qE "ORA-[0-9]|TNS-[0-9]"; then
        log_error "Cannot connect to Data Guard configuration"
        log_error "Check wallet credentials and TNS configuration"
        echo ""
        echo "$FSFO_STATUS"
        exit 1
    fi

    # Ensure log directory exists
    mkdir -p "$(dirname "$OBSERVER_LOG_FILE")"

    # Start observer in background using wallet authentication
    log_info "Starting observer process..."
    log_info "Observer log file: $OBSERVER_LOG_FILE"

    # Append (never truncate): OBSERVER_LOG_FILE accumulates the dgmgrl
    # observer's own stdout/stderr across every start/restart, including
    # FSFO failover records from previous runs. A leading marker makes each
    # run's boundary visible in the accumulated file.
    {
        printf '\n============================================================\n'
        printf 'Observer starting: %s (host: %s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(hostname)"
        printf '============================================================\n'
    } >> "$OBSERVER_LOG_FILE"

    nohup "$ORACLE_HOME/bin/dgmgrl" "/@${PRIMARY_TNS_ALIAS}" "START OBSERVER" >> "$OBSERVER_LOG_FILE" 2>&1 &
    OBSERVER_PID=$!

    # Save host:PID (pidfile lives on the NFS share, PIDs are host-local)
    echo "$(hostname):$OBSERVER_PID" > "$PID_FILE"

    # Wait a moment and verify it's running
    sleep 3

    if is_observer_running; then
        log_info "Observer started successfully (PID: $OBSERVER_PID)"
        echo ""
        echo "Observer is now monitoring the Data Guard configuration."
        echo ""
        echo "To check status: ./observer.sh status"
        echo "To view logs:    tail -f $OBSERVER_LOG_FILE"
        echo "To stop:         ./observer.sh stop"
    else
        log_error "Observer failed to start"
        log_error "Check observer log file: $OBSERVER_LOG_FILE"

        if [[ -f "$OBSERVER_LOG_FILE" ]]; then
            echo ""
            echo "Last 10 lines of log:"
            tail -10 "$OBSERVER_LOG_FILE"
        fi

        rm -f "$PID_FILE"
        exit 1
    fi
}

do_stop() {
    require_observer_tools
    log_info "Stopping FSFO observer..."

    if ! is_observer_running; then
        log_info "Observer is not running"
        rm -f "$PID_FILE" 2>/dev/null
        return 0
    fi

    if [[ -n "$OBSERVER_REMOTE_HOST" ]]; then
        log_error "Observer is running on host ${OBSERVER_REMOTE_HOST} (per $PID_FILE)"
        log_error "Run './observer.sh stop' on that host - it cannot be stopped from $(hostname)"
        exit 1
    fi

    local pid="$OBSERVER_PID"

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

    # kill -0 only proves *some* process still owns this PID. After the up
    # to ~33s wait across this function, the PID could have been recycled
    # by an unrelated process - re-validate it's still a dgmgrl process
    # (same check as is_observer_running()) immediately before each signal,
    # not just once at entry, or a PID-reuse race could kill the wrong
    # process.
    _pid_is_dgmgrl() {
        ps -p "$1" -o args= 2>/dev/null | grep -qi 'dgmgrl'
    }

    # Force kill if still running
    if kill -0 "$pid" 2>/dev/null; then
        if _pid_is_dgmgrl "$pid"; then
            log_warn "Observer did not stop gracefully, sending SIGTERM..."
            kill -TERM "$pid" 2>/dev/null || true
            sleep 2
        else
            log_warn "PID $pid is no longer a dgmgrl process (PID reuse?) - not sending SIGTERM"
        fi
    fi

    if kill -0 "$pid" 2>/dev/null; then
        if _pid_is_dgmgrl "$pid"; then
            log_warn "Observer still running, sending SIGKILL..."
            kill -KILL "$pid" 2>/dev/null || true
            sleep 1
        else
            log_warn "PID $pid is no longer a dgmgrl process (PID reuse?) - not sending SIGKILL"
        fi
    fi

    # Cleanup PID file
    rm -f "$PID_FILE"

    if ! kill -0 "$pid" 2>/dev/null; then
        log_info "Observer stopped successfully"
    elif ! _pid_is_dgmgrl "$pid"; then
        log_warn "PID $pid is still running but is no longer a dgmgrl process (PID reuse) - left alone"
        log_info "The observer process itself already exited"
    else
        log_error "Failed to stop observer (PID: $pid)"
        exit 1
    fi
}

do_status() {
    require_observer_tools
    echo ""
    echo "FSFO Observer Status"
    echo "===================="
    echo ""

    # Check process status
    if is_observer_running; then
        if [[ -n "$OBSERVER_REMOTE_HOST" ]]; then
            echo "Process Status : RUNNING on host ${OBSERVER_REMOTE_HOST} (not verifiable from $(hostname))"
        else
            echo "Process Status : RUNNING (PID: $OBSERVER_PID)"
        fi
        echo "PID File       : $PID_FILE"
        echo "Observer Log   : $OBSERVER_LOG_FILE"
        echo "Script Log     : $LOG_FILE"
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
    if [[ -n "$ORACLE_SID" && -x "$ORACLE_HOME/bin/sqlplus" ]]; then
        # Keep stderr visible: $(...) captures only stdout, so a missing-script
        # (SP2-0310) or ORA- error surfaces instead of an empty result.
        FSFO_INFO=$(run_sql_query "get_fsfo_status.sql" || true)
    else
        FSFO_INFO=""
    fi

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
