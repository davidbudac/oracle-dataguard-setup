#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Session Management
# ============================================================
# Manage sessions that remember your config file selection.
#
# Usage:
#   ./common/sessions.sh list              List all sessions
#   ./common/sessions.sh delete <id>       Delete a session
#   ./common/sessions.sh delete-all        Delete all sessions
#
# Sessions are created automatically when you select a config
# file in any setup script. Use -S <id> to restore a session:
#   ./primary/04_prepare_primary_dg.sh -S MYDB_STB
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "${SCRIPT_DIR}/dg_functions.sh"

usage() {
    echo "Usage: $0 {list|delete <session_id>|delete-all}"
    echo ""
    echo "Commands:"
    echo "  list              List all available sessions"
    echo "  delete <id>       Delete a specific session"
    echo "  delete-all        Delete all sessions"
    echo ""
    echo "Sessions are created automatically when you select a config file."
    echo "Use -S <session_id> with any setup script to restore a session."
    echo ""
    echo "Examples:"
    echo "  $0 list"
    echo "  $0 delete MYDB_STB"
    echo "  ./primary/04_prepare_primary_dg.sh -S MYDB_STB"
    exit 1
}

do_delete() {
    local sid="$1"
    local session_file="${NFS_SHARE}/sessions/${sid}.session"

    if [[ ! -f "$session_file" ]]; then
        log_error "Session not found: $sid"
        return 1
    fi

    rm -f "$session_file"
    log_info "Deleted session: $sid"
}

do_delete_all() {
    local session_dir="${NFS_SHARE}/sessions"

    if [[ ! -d "$session_dir" ]]; then
        log_info "No sessions directory found."
        return 0
    fi

    local count=0
    local session_file
    for session_file in "$session_dir"/*.session; do
        [[ -f "$session_file" ]] || continue
        rm -f "$session_file"
        count=$((count + 1))
    done

    log_info "Deleted $count session(s)."
}

# ============================================================
# Main
# ============================================================

if [[ $# -lt 1 ]]; then
    usage
fi

COMMAND="$1"

case "$COMMAND" in
    list)
        list_sessions
        ;;
    delete)
        if [[ -z "${2:-}" ]]; then
            log_error "delete requires a session ID"
            echo ""
            usage
        fi
        do_delete "$2"
        ;;
    delete-all)
        do_delete_all
        ;;
    *)
        usage
        ;;
esac
