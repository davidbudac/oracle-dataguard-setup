#!/usr/bin/env bash
# ============================================================
# Oracle Data Guard - FSFO Observer Lifecycle Management
# ============================================================
# Run this script on the OBSERVER server (can be standby or 3rd server).
#
# Usage:
#   ./observer.sh setup   - Set up Oracle Wallet for authentication
#   ./observer.sh start   - Start the observer process
#   ./observer.sh stop    - Stop the observer process
#   ./observer.sh status  - Check observer status (exit 0 only if the broker reports an observer present)
#   ./observer.sh restart - Restart the observer
#
# Prerequisites:
#   - FSFO must be configured (run Step 9 first)
#   - Oracle environment variables must be set
#   - For 3rd server: Oracle client installed, TNS entries configured
#   - Wallet must be set up before starting (run setup first)
#
# Note on mkstore and `ps -ef`: when the credential secret is left off
# argv, `mkstore -createCredential <alias> <user>` reads three lines from
# stdin (secret, secret again, wallet password). `setup` feeds them with
# printf (a shell builtin), so neither the observer password nor the wallet
# password ever appears on a process argv.
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source common functions
source "${COMMON_DIR}/dg_functions.sh"
# observer.sh takes a command word (setup|start|stop|status|restart)
DG_SCRIPT_POSITIONAL=1
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
    echo "  OBSERVER_DIR - Host-local directory for the observer's .dat/log files (default: \$HOME/fsfo_observer)"
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

    # Host-local state. Without FILE IS the observer drops fsfo.dat into
    # whatever directory `start` happened to run from, and a restart from a
    # different directory loses it. Kept off the NFS share on purpose: the
    # file is per-observer state, not something several hosts should share.
    OBSERVER_DIR="${OBSERVER_DIR:-${HOME}/fsfo_observer}"
    OBSERVER_DAT="${OBSERVER_DIR}/fsfo_${STANDBY_DB_UNIQUE_NAME}.dat"
    OBSERVER_DGMGRL_LOG="${OBSERVER_DIR}/fsfo_${STANDBY_DB_UNIQUE_NAME}_observer.log"
}

check_wallet_exists() {
    if [[ -f "${WALLET_DIR}/cwallet.sso" ]] || [[ -f "${WALLET_DIR}/ewallet.p12" ]]; then
        return 0
    fi
    return 1
}

# Process-table checks. `kill -0` cannot tell "gone" (ESRCH) from "exists but
# owned by another OS user" (EPERM) - it fails both ways - so a live observer
# owned by someone else would be mistaken for a stale pidfile and the file
# deleted. ps -p lists a process regardless of who owns it.
_pid_alive() {
    [[ -n "$(ps -p "$1" -o pid= 2>/dev/null | tr -d ' ')" ]]
}

_pid_is_dgmgrl() {
    ps -p "$1" -o args= 2>/dev/null | grep -qi 'dgmgrl'
}

# observer_present: YES/NO as the broker sees it (any observer, not
# necessarily this host's), or nothing at all when it cannot be determined
# (no connection, no usable output). Always returns 0 so callers can use
# it under set -e. Primary first, then the standby (the primary may be the
# member that is down after a failover); V$DATABASE.FS_FAILOVER_OBSERVER_
# PRESENT is populated on both. Falls back to SHOW OBSERVER when there is
# no sqlplus (instant-client style observer hosts).
observer_present() {
    local alias out="" flag
    for alias in "$PRIMARY_TNS_ALIAS" "$STANDBY_TNS_ALIAS"; do
        [[ -n "$alias" ]] || continue
        flag=""
        if [[ -x "$ORACLE_HOME/bin/sqlplus" ]]; then
            out=$("$ORACLE_HOME/bin/sqlplus" -s -L "/@${alias}" as sysdg <<EOF 2>/dev/null || true
set pagesize 0 heading off feedback off
select 'PRESENT=' || fs_failover_observer_present from v\$database;
exit
EOF
            )
            flag=$(printf '%s\n' "$out" | sed -n 's/^PRESENT=//p' | tr -d ' \r' | head -1)
        fi
        if [[ -z "$flag" ]]; then
            out=$("$ORACLE_HOME/bin/dgmgrl" -silent "/@${alias}" "SHOW OBSERVER" 2>&1 || true)
            if printf '%s\n' "$out" | tr -d '\r' | grep -q '^[[:space:]]*Observer[[:space:]]*"'; then
                flag="YES"
            elif printf '%s\n' "$out" | grep -q 'Configuration -'; then
                flag="NO"
            fi
        fi
        if [[ -n "$flag" ]]; then
            printf '%s\n' "$flag"
            return 0
        fi
    done
    return 0
}

is_observer_running() {
    # Sets OBSERVER_PID (local case) or OBSERVER_REMOTE_HOST (pidfile was
    # written by another host - the NFS-shared pidfile stores host:pid
    # because PIDs are only meaningful on the host that wrote them).
    # OBSERVER_PID_FOREIGN is true when the local dgmgrl process is owned by
    # another OS user (we can see it but not signal it).
    OBSERVER_PID=""
    OBSERVER_REMOTE_HOST=""
    OBSERVER_PID_FOREIGN=false

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

    if ! _pid_alive "$pid"; then
        # Process is gone - stale pidfile left over from a prior run.
        rm -f "$PID_FILE"
        return 1
    fi

    # A live PID only proves *some* process owns it. After a reboot the
    # PID may have been recycled by an unrelated process, which would make
    # status/start/stop all trust the wrong process. Verify the command
    # line actually looks like our dgmgrl observer before trusting it.
    if ! _pid_is_dgmgrl "$pid"; then
        log_warn "PID $pid from $PID_FILE is not a dgmgrl process - treating pidfile as stale"
        rm -f "$PID_FILE"
        return 1
    fi

    # It is our kind of process; if signalling it fails anyway (EPERM) it
    # belongs to another OS user and must be left alone, not cleaned up.
    if ! kill -0 "$pid" 2>/dev/null; then
        OBSERVER_PID_FOREIGN=true
    fi

    OBSERVER_PID="$pid"
    return 0
}

require_observer_tools() {
    check_oracle_client_env || exit 1
    export PATH="$ORACLE_HOME/bin:$PATH"
}

# add_observer_credential <alias>: store OBSERVER_USER/OBSERVER_PASSWORD for
# <alias> in WORK_WALLET_DIR. The caller holds the secrets and must have
# verbose tracing paused. Delete-then-create (mirrors common/setup_dg_wallet.sh's
# add_credential()): re-running setup into an existing wallet (e.g. to rotate
# the observer password) otherwise fails because -createCredential refuses to
# overwrite an alias that is already present; the delete is a harmless no-op
# when the entry does not exist yet.
# With the secret left off argv, mkstore reads three lines from stdin: the
# secret, the secret again, then the wallet password. printf is a shell
# builtin, so none of the passwords ever reaches a process argv (`ps -ef`).
add_observer_credential() {
    local alias="$1" mk_out
    log_info "Adding credential for $alias..."
    "$ORACLE_HOME/bin/mkstore" -wrl "$WORK_WALLET_DIR" -deleteCredential "$alias" << EOF >/dev/null 2>&1 || true
${WALLET_PASSWORD}
EOF
    if ! mk_out=$(printf '%s\n%s\n%s\n' "$OBSERVER_PASSWORD" "$OBSERVER_PASSWORD" "$WALLET_PASSWORD" \
            | "$ORACLE_HOME/bin/mkstore" -wrl "$WORK_WALLET_DIR" -createCredential "$alias" "$OBSERVER_USER" 2>&1); then
        printf '%s\n' "$mk_out" >&2
        log_error "Failed to add credential for $alias"
        return 1
    fi
    return 0
}

# Remove the wallet staging directory on EVERY way out of setup (success,
# error, Ctrl-C, SIGTERM): it holds an auto-login cwallet.sso, readable by
# anyone with access to it, and used to be removed only on specific failure
# branches. After a successful swap the staging path no longer exists, so
# this is a no-op; KEEP_STAGED_WALLET=true marks the "left for manual
# recovery" failures where the staged wallet is deliberately kept.
# Only an EXIT trap is installed (dg_functions.sh sets just an ERR trap, and
# prompt_password swaps and restores INT/TERM/HUP around its read), plus
# INT/TERM/HUP handlers that exit so the EXIT trap runs.
_setup_cleanup() {
    if [[ "${NEW_WALLET_STAGED:-false}" == "true" && "${KEEP_STAGED_WALLET:-false}" != "true" \
          && -n "${WORK_WALLET_DIR:-}" && -d "$WORK_WALLET_DIR" ]]; then
        rm -rf "$WORK_WALLET_DIR"
    fi
    return 0
}

# Rewrite sqlnet.ora in place (cat > keeps the file's owner and mode):
#   repoint  - comment out the existing WALLET_LOCATION and any
#              SQLNET.WALLET_OVERRIDE, then append the observer's block
#   override - comment out a non-TRUE SQLNET.WALLET_OVERRIDE, then append TRUE
# Single-line entries only (the caller refuses multi-line WALLET_LOCATION).
rewrite_sqlnet_wallet() {
    local mode="$1" new
    backup_file "$SQLNET_FILE" || return 1
    new=$(awk -v mode="$mode" '
        mode == "repoint" && tolower($0) ~ /^[ \t]*wallet_location/ {
            print "# " $0 "   # replaced by observer.sh setup"; next }
        tolower($0) ~ /^[ \t]*sqlnet\.wallet_override/ {
            print "# " $0 "   # replaced by observer.sh setup"; next }
        { print }
    ' "$SQLNET_FILE")
    if [[ "$mode" == "repoint" ]]; then
        new="${new}
${WALLET_CONFIG}"
    else
        new="${new}

SQLNET.WALLET_OVERRIDE = TRUE"
    fi
    printf '%s\n' "$new" > "$SQLNET_FILE"
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
                if [[ ! -f "${WALLET_DIR}/ewallet.p12" ]]; then
                    # Auto-login-only wallet (cwallet.sso with no ewallet.p12):
                    # mkstore has no password to verify against, so its edits
                    # exit 0 while producing credentials the client later
                    # rejects (ORA-01017). Rebuild it instead (the staged
                    # swap keeps the old wallet as a timestamped backup).
                    log_warn "The wallet is auto-login-ONLY (cwallet.sso without ewallet.p12);"
                    log_warn "mkstore cannot reliably modify such a wallet, so it must be rebuilt."
                    if ! confirm_typed_value "This will replace the existing wallet at ${WALLET_DIR} (the old one is kept as a backup)." "RECREATE WALLET"; then
                        log_info "Wallet recreation cancelled by user"
                        exit 0
                    fi
                    NEW_WALLET_STAGED=true
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
    # Check sqlnet.ora (decided now, applied after the credentials exist)
    # ============================================================
    # `dgmgrl /@alias` resolves the credential from whichever wallet
    # sqlnet.ora's WALLET_LOCATION names. If that is another wallet (for
    # example common/setup_dg_wallet.sh's dg_wallet), adding credentials
    # here would silently leave the observer connecting with the OTHER
    # wallet's entries, so ask before pointing sqlnet.ora elsewhere (TTY),
    # or stop (non-interactive) - WALLET_DIR=<that directory> reuses it.

    log_section "Checking sqlnet.ora"

    SQLNET_FILE="$(dg_net_admin_dir)/sqlnet.ora"
    SQLNET_ACTION="append"
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
        local existing_line existing_dir
        existing_line=$(grep -Ei '^[[:space:]]*WALLET_LOCATION' "$SQLNET_FILE" | head -1 || true)
        if [[ -n "$existing_line" ]]; then
            existing_dir=$(printf '%s\n' "$existing_line" \
                | sed -n 's/.*[Dd][Ii][Rr][Ee][Cc][Tt][Oo][Rr][Yy][[:space:]]*=[[:space:]]*\([^)[:space:]]*\).*/\1/p' \
                | tr -d "\"'" | head -1)
            existing_dir="${existing_dir%/}"
            if [[ -n "$existing_dir" && "$existing_dir" == "${WALLET_DIR%/}" ]]; then
                if grep -Eiq '^[[:space:]]*SQLNET\.WALLET_OVERRIDE[[:space:]]*=[[:space:]]*TRUE' "$SQLNET_FILE"; then
                    SQLNET_ACTION="none"
                else
                    SQLNET_ACTION="override"
                fi
            else
                log_warn "sqlnet.ora ($SQLNET_FILE) already names a different wallet:"
                log_warn "  $existing_line"
                log_warn "The observer's '/@alias' connections would keep using THAT wallet."
                local open_p close_p
                open_p=$(printf '%s' "$existing_line" | tr -cd '(' | wc -c)
                close_p=$(printf '%s' "$existing_line" | tr -cd ')' | wc -c)
                if [[ $((open_p)) -ne $((close_p)) ]]; then
                    log_error "That WALLET_LOCATION spans several lines - edit sqlnet.ora by hand to point at:"
                    log_error "  $WALLET_DIR"
                    exit 1
                fi
                if [[ -t 0 ]]; then
                    if ! confirm_proceed "Point WALLET_LOCATION at ${WALLET_DIR}? (credentials in the other wallet will stop being used on this host; sqlnet.ora is backed up)"; then
                        log_info "Cancelled. To add the observer credentials to the existing wallet instead, re-run:"
                        log_info "  WALLET_DIR=${existing_dir:-<that wallet directory>} ./fsfo/observer.sh setup"
                    log_info "(that replaces any existing entry for $PRIMARY_TNS_ALIAS / $STANDBY_TNS_ALIAS in it)"
                        exit 1
                    fi
                    SQLNET_ACTION="repoint"
                else
                    log_error "Not changing WALLET_LOCATION non-interactively. Either add the observer"
                    log_error "credentials to the existing wallet:"
                    log_error "  WALLET_DIR=${existing_dir:-<that wallet directory>} ./fsfo/observer.sh setup"
                    log_error "(that replaces any existing entry for $PRIMARY_TNS_ALIAS / $STANDBY_TNS_ALIAS in it)"
                    log_error "or edit sqlnet.ora by hand and re-run."
                    exit 1
                fi
            fi
        fi
    else
        SQLNET_ACTION="create"
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
        trap _setup_cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP
        log_info "Staging new wallet in: $WORK_WALLET_DIR"
    else
        WORK_WALLET_DIR="$WALLET_DIR"
        # The wallet is edited in place (delete-then-create per alias): keep a
        # copy first so a failed -createCredential cannot cost the entry.
        WALLET_INPLACE_BACKUP="${WALLET_DIR}.bak.$(date '+%Y%m%d_%H%M%S')_$$"
        if ! cp -pR "$WALLET_DIR" "$WALLET_INPLACE_BACKUP"; then
            log_error "Could not back up the existing wallet to $WALLET_INPLACE_BACKUP - not modifying it"
            exit 1
        fi
        chmod 700 "$WALLET_INPLACE_BACKUP"
        log_info "Existing wallet backed up to: $WALLET_INPLACE_BACKUP"
        mkdir -p "$WORK_WALLET_DIR"
        chmod 700 "$WORK_WALLET_DIR"
        log_info "Using existing wallet directory: $WORK_WALLET_DIR"
    fi

    # ============================================================
    # Create Wallet
    # ============================================================

    # Tracing (-v) stays paused from the first password prompt until both
    # credentials are stored and the passwords are unset below: every
    # assignment, here-doc and pipeline in between would otherwise echo the
    # wallet and observer passwords into the xtrace output (C2).
    pause_verbose_trace

    if [[ ! -f "${WORK_WALLET_DIR}/ewallet.p12" ]]; then
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
        if ! "$ORACLE_HOME/bin/mkstore" -wrl "$WORK_WALLET_DIR" -create << EOF
${WALLET_PASSWORD}
${WALLET_PASSWORD}
EOF
        then
            log_error "Failed to create wallet"
            exit 1
        fi

        # Enable auto-login (creates cwallet.sso)
        if ! "$ORACLE_HOME/bin/mkstore" -wrl "$WORK_WALLET_DIR" -createSSO << EOF
${WALLET_PASSWORD}
EOF
        then
            log_error "Failed to enable auto-login (createSSO) for wallet"
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
        exit 1
    fi

    # Store the credential for both aliases (see add_observer_credential).
    # On the in-place path a failure leaves the pre-change copy named in
    # WALLET_INPLACE_BACKUP.
    if ! add_observer_credential "$PRIMARY_TNS_ALIAS" || ! add_observer_credential "$STANDBY_TNS_ALIAS"; then
        if [[ -n "${WALLET_INPLACE_BACKUP:-}" ]]; then
            log_error "The wallet may now lack an entry; the pre-change copy is at: $WALLET_INPLACE_BACKUP"
        fi
        exit 1
    fi

    # Clear passwords from memory and bring tracing back
    unset WALLET_PASSWORD
    unset WALLET_PASSWORD_CONFIRM
    unset OBSERVER_PASSWORD
    resume_verbose_trace

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
                KEEP_STAGED_WALLET=true
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
            KEEP_STAGED_WALLET=true
            exit 1
        fi

        log_info "New wallet activated at: $WALLET_DIR"
    fi

    log_info "Credentials added successfully"

    # ============================================================
    # Configure sqlnet.ora
    # ============================================================

    log_section "Configuring sqlnet.ora"

    case "$SQLNET_ACTION" in
        create)
            printf '%s\n' "$WALLET_CONFIG" > "$SQLNET_FILE"
            log_info "Created $SQLNET_FILE with wallet configuration"
            ;;
        append)
            backup_file "$SQLNET_FILE"
            printf '%s\n' "$WALLET_CONFIG" >> "$SQLNET_FILE"
            log_info "Added wallet configuration to $SQLNET_FILE"
            ;;
        repoint)
            rewrite_sqlnet_wallet repoint
            log_info "Pointed WALLET_LOCATION in $SQLNET_FILE at $WALLET_DIR (previous entry kept as a comment)"
            ;;
        override)
            rewrite_sqlnet_wallet override
            log_info "Set SQLNET.WALLET_OVERRIDE = TRUE in $SQLNET_FILE (WALLET_LOCATION already pointed at $WALLET_DIR)"
            ;;
        *)
            log_info "$SQLNET_FILE already points at $WALLET_DIR with SQLNET.WALLET_OVERRIDE = TRUE"
            ;;
    esac

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

# wallet_identity <alias>: the identity the wallet connection to <alias>
# authenticates as, as "AUTHENTICATED_IDENTITY|SESSION_USER" (empty when it
# cannot be read). Under AS SYSDG the session user is always the SYSDG schema,
# so SESSION_USER alone cannot tell the observer from SYS; the authenticated
# identity is the name the credential logged in with.
wallet_identity() {
    local alias="$1" out
    [[ -x "$ORACLE_HOME/bin/sqlplus" ]] || return 0
    out=$("$ORACLE_HOME/bin/sqlplus" -s -L "/@${alias}" as sysdg <<EOF 2>/dev/null || true
set pagesize 0 heading off feedback off
select 'IDENT=' || sys_context('USERENV', 'AUTHENTICATED_IDENTITY') || '|' || sys_context('USERENV', 'SESSION_USER') from dual;
exit
EOF
    )
    printf '%s\n' "$out" | sed -n 's/^IDENT=//p' | tr -d ' \r' | head -1
    return 0
}

test_wallet_connection() {
    # Test connection using wallet
    log_info "Testing connection to $PRIMARY_TNS_ALIAS via wallet..."

    local result ident auth_user want
    result=$("$ORACLE_HOME/bin/dgmgrl" -silent "/@${PRIMARY_TNS_ALIAS}" "show configuration" 2>&1 || true)

    if ! echo "$result" | grep -qE "Configuration -|SUCCESS|WARNING"; then
        log_warn "Connection test output:"
        echo "$result" | head -5
        return 1
    fi

    # A working connection is not proof the OBSERVER's credential was used:
    # with another WALLET_LOCATION in sqlnet.ora (or a leftover SYS entry for
    # the same alias) '/@alias' succeeds against that wallet instead. Check
    # who it actually logged in as.
    # Under AS SYSDG both USER and SESSION_USER read SYSDG whoever logged in;
    # AUTHENTICATED_IDENTITY carries the real login name (e.g. C##DG_OBSERVER).
    # Only "cannot check at all" (no sqlplus, no known observer user) passes
    # with a warning; anything else must equal the observer user.
    want=$(printf '%s' "$OBSERVER_USER" | tr '[:lower:]' '[:upper:]')
    if [[ ! -x "$ORACLE_HOME/bin/sqlplus" || -z "$want" ]]; then
        log_warn "Connected through the wallet, but could not confirm WHICH user it authenticated as"
        log_warn "(no sqlplus in $ORACLE_HOME/bin, or no observer username known)"
        return 0
    fi
    ident=$(wallet_identity "$PRIMARY_TNS_ALIAS")
    auth_user=$(printf '%s' "${ident%%|*}" | tr '[:lower:]' '[:upper:]')
    if [[ "$auth_user" != "$want" ]]; then
        log_warn "The wallet connection authenticated as ${auth_user:-<unreadable>}, not the observer user ${want}"
        log_warn "'/@${PRIMARY_TNS_ALIAS}' is resolving against a different wallet or credential."
        log_warn "Check WALLET_LOCATION / SQLNET.WALLET_OVERRIDE in $(dg_net_admin_dir)/sqlnet.ora"
        return 1
    fi
    log_info "Wallet authenticates as ${auth_user}"
    return 0
}

do_start() {
    require_observer_tools
    log_info "Starting FSFO observer..."

    # Check if already running
    if is_observer_running; then
        if [[ -n "$OBSERVER_REMOTE_HOST" ]]; then
            # The pidfile is another host's record and its PID cannot be
            # checked from here. Ask the broker: if it lists no observer at
            # all, the record is demonstrably stale (host gone, observer
            # stopped there) and is ignored; otherwise refuse.
            if [[ "$(observer_present)" == "NO" ]]; then
                log_warn "$PID_FILE names host ${OBSERVER_REMOTE_HOST}, but the broker reports no observer -"
                log_warn "treating that pidfile as stale and ignoring it"
                rm -f "$PID_FILE"
            else
                log_error "Observer is already running on host ${OBSERVER_REMOTE_HOST} (per $PID_FILE)"
                log_error "Run './observer.sh stop' on that host first if it must move"
                log_error "If that host is gone and the observer is not running anywhere, remove the stale record:"
                log_error "  rm $PID_FILE"
                exit 1
            fi
        else
            log_warn "Observer is already running (PID: $OBSERVER_PID)"
            log_info "Use './observer.sh status' to check status"
            exit 0
        fi
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

    # Anchored on the field label: "disabled" can appear elsewhere in the
    # output (property values, other fields) while FSFO is in fact enabled.
    if printf '%s\n' "$FSFO_STATUS" | tr -d '\r' | grep -Eiq '^[[:space:]]*Fast-Start Failover:[[:space:]]*Disabled'; then
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

    # Ensure log and state directories exist
    mkdir -p "$(dirname "$OBSERVER_LOG_FILE")"
    mkdir -p "$OBSERVER_DIR"
    chmod 700 "$OBSERVER_DIR" 2>/dev/null || true

    # Start observer in background using wallet authentication
    log_info "Starting observer process..."
    log_info "Observer log file: $OBSERVER_LOG_FILE"
    log_info "Observer state file: $OBSERVER_DAT (log: $OBSERVER_DGMGRL_LOG)"

    # Append (never truncate): OBSERVER_LOG_FILE accumulates the dgmgrl
    # observer's own stdout/stderr across every start/restart, including
    # FSFO failover records from previous runs. A leading marker makes each
    # run's boundary visible in the accumulated file.
    {
        printf '\n============================================================\n'
        printf 'Observer starting: %s (host: %s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(hostname)"
        printf '============================================================\n'
    } >> "$OBSERVER_LOG_FILE"

    # FILE IS pins the observer's .dat to a known host-local directory
    # instead of whatever the current directory is; LOGFILE IS gives it a log
    # of its own next to it.
    nohup "$ORACLE_HOME/bin/dgmgrl" "/@${PRIMARY_TNS_ALIAS}" "START OBSERVER FILE IS '${OBSERVER_DAT}' LOGFILE IS '${OBSERVER_DGMGRL_LOG}'" >> "$OBSERVER_LOG_FILE" 2>&1 &
    OBSERVER_PID=$!

    # Save host:PID (pidfile lives on the NFS share, PIDs are host-local)
    echo "$(hostname):$OBSERVER_PID" > "$PID_FILE"

    # A live process is not an observer the broker knows about (bad
    # credential, unreachable standby, syntax rejected after the process
    # started...). Poll the broker for up to 30s; stop early if the process
    # dies.
    log_info "Waiting for the broker to report the observer (up to 30s)..."
    local tries=0 present=""
    while [[ $tries -lt 15 ]]; do
        sleep 2
        tries=$((tries + 1))
        _pid_alive "$OBSERVER_PID" || break
        present=$(observer_present)
        [[ "$present" == "YES" ]] && break
    done

    if _pid_alive "$OBSERVER_PID" && [[ "$present" == "YES" ]]; then
        log_info "Observer started successfully (PID: $OBSERVER_PID) and is registered with the broker"
        echo ""
        echo "Observer is now monitoring the Data Guard configuration."
        echo ""
        echo "To check status: ./observer.sh status"
        echo "To view logs:    tail -f $OBSERVER_LOG_FILE"
        echo "To stop:         ./observer.sh stop"
    else
        if _pid_alive "$OBSERVER_PID"; then
            if [[ -z "$present" ]]; then
                log_error "The observer process is running (PID: $OBSERVER_PID) but the broker could not be queried to confirm it"
            else
                log_error "The observer process is running (PID: $OBSERVER_PID) but the broker does not report an observer after 30s"
            fi
            log_error "Left running; use './observer.sh stop' to remove it, or './observer.sh status' to re-check"
        else
            log_error "Observer failed to start (the process exited)"
            rm -f "$PID_FILE"
        fi
        log_error "Check observer log files: $OBSERVER_LOG_FILE and $OBSERVER_DGMGRL_LOG"

        if [[ -f "$OBSERVER_LOG_FILE" ]]; then
            echo ""
            echo "Last 10 lines of log:"
            tail -10 "$OBSERVER_LOG_FILE"
        fi

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
    while _pid_alive "$pid" && [[ $count -lt 30 ]]; do
        sleep 1
        count=$((count + 1))
    done

    # A live PID only proves *some* process still owns it. After the up
    # to ~33s wait across this function, the PID could have been recycled
    # by an unrelated process - re-validate it's still a dgmgrl process
    # (same check as is_observer_running()) immediately before each signal,
    # not just once at entry, or a PID-reuse race could kill the wrong
    # process.

    # An observer owned by another OS user can be stopped through the broker
    # (above) but not signalled from here, and its pidfile must stay.
    if $OBSERVER_PID_FOREIGN && _pid_alive "$pid"; then
        log_error "Observer (PID: $pid) is still running and is owned by another OS user - cannot signal it"
        log_error "Stop it as that user (or root): kill $pid"
        exit 1
    fi

    # Force kill if still running
    if _pid_alive "$pid"; then
        if _pid_is_dgmgrl "$pid"; then
            log_warn "Observer did not stop gracefully, sending SIGTERM..."
            kill -TERM "$pid" 2>/dev/null || true
            sleep 2
        else
            log_warn "PID $pid is no longer a dgmgrl process (PID reuse?) - not sending SIGTERM"
        fi
    fi

    if _pid_alive "$pid"; then
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

    if ! _pid_alive "$pid"; then
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

    # What the broker itself says decides the exit code: a live local
    # process the broker does not know about is not a working observer.
    echo "Broker Observer Check"
    echo "---------------------"
    local present
    present=$(observer_present)
    case "$present" in
        YES)
            echo "  Broker reports an observer present: YES"
            echo ""
            return 0
            ;;
        NO)
            echo "  Broker reports an observer present: NO"
            ;;
        *)
            echo "  Broker reports an observer present: UNKNOWN (could not query via the wallet)"
            ;;
    esac
    echo ""
    return 1
}

do_restart() {
    do_stop
    sleep 2
    do_start
}

# ============================================================
# Main
# ============================================================

# The command is the one non-dash argument; the global flags (-v, -n, ...)
# were already validated and consumed by enable_verbose_mode, and may appear
# before or after it. Zero or several commands, or an unknown one, is a usage
# error.
COMMAND=""
_cmd_count=0
_after_dd=false
for _arg in "$@"; do
    if ! $_after_dd; then
        case "$_arg" in
            --) _after_dd=true; continue ;;
            -*) continue ;;
        esac
    fi
    COMMAND="$_arg"
    _cmd_count=$((_cmd_count + 1))
done

if [[ $_cmd_count -ne 1 ]]; then
    if [[ $_cmd_count -gt 1 ]]; then
        echo "Error: expected exactly one command, got $_cmd_count" >&2
    fi
    usage
fi
case "$COMMAND" in
    setup|start|stop|status|restart) ;;
    *)
        echo "Error: unknown command: $COMMAND" >&2
        usage
        ;;
esac

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
        # Exit 0 only when the broker reports the observer present, else 1
        # (|| keeps the nonzero return from tripping set -e / the ERR trap).
        status_rc=0
        do_status || status_rc=$?
        exit "$status_rc"
        ;;
    restart)
        do_restart
        ;;
    *)
        usage
        ;;
esac
