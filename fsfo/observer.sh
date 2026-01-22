#!/bin/bash
# ============================================================
# Oracle Data Guard - FSFO Observer Lifecycle Management
# ============================================================
# Run this script on the STANDBY database server.
#
# Usage:
#   ./observer.sh start   - Start the observer process
#   ./observer.sh stop    - Stop the observer process
#   ./observer.sh status  - Check observer status
#   ./observer.sh restart - Restart the observer
#
# Prerequisites:
#   - FSFO must be configured (run configure_fsfo.sh first)
#   - Oracle environment variables must be set
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
    echo "Usage: $0 {start|stop|status|restart}"
    echo ""
    echo "Commands:"
    echo "  start   - Start the observer process in background"
    echo "  stop    - Stop the observer process"
    echo "  status  - Show observer status"
    echo "  restart - Restart the observer"
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

    # Set PID and log file paths
    PID_FILE="${NFS_SHARE}/fsfo_observer_${STANDBY_DB_UNIQUE_NAME}.pid"
    LOG_FILE="${NFS_SHARE}/logs/fsfo_observer_${STANDBY_DB_UNIQUE_NAME}.log"
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

do_start() {
    log_info "Starting FSFO observer..."

    # Check if already running
    if is_observer_running; then
        local pid=$(cat "$PID_FILE")
        log_warn "Observer is already running (PID: $pid)"
        log_info "Use './observer.sh status' to check status"
        exit 0
    fi

    # Verify FSFO is enabled
    FSFO_STATUS=$(run_dgmgrl "show_fsfo_status.dgmgrl" 2>&1 || true)

    if echo "$FSFO_STATUS" | grep -qi "disabled"; then
        log_error "Fast-Start Failover is not enabled"
        log_error "Please run './configure_fsfo.sh' first"
        exit 1
    fi

    # Ensure log directory exists
    mkdir -p "$(dirname "$LOG_FILE")"

    # Start observer in background
    log_info "Starting observer process..."
    log_info "Log file: $LOG_FILE"

    nohup "$ORACLE_HOME/bin/dgmgrl" / "START OBSERVER" > "$LOG_FILE" 2>&1 &
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
    run_dgmgrl "stop_observer.dgmgrl" 2>/dev/null || true

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

    # Get FSFO status from DGMGRL
    echo "FSFO Configuration Status"
    echo "-------------------------"
    echo ""
    run_dgmgrl "show_fsfo_status.dgmgrl" 2>&1 || true
    echo ""

    # Get observer info from V$DATABASE
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
        echo "  (Unable to query V\$DATABASE)"
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
