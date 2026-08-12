#!/usr/bin/env bash
# ============================================================
# Observer SYS -> SYSDG conversion - Step 2 (run on OBSERVER host)
# ============================================================
# Switches the FSFO observer's authentication from SYS to the
# dedicated SYSDG user created by 01_create_sysdg_user.sh.
#
# Handles both starting points:
#   A) Observer already uses an Oracle Wallet holding SYS
#      credentials       -> the SYS credentials are REPLACED in
#                            place with the new user's.
#   B) Observer was started with an explicit sys/password@alias
#      (script, cron, interactive)
#                        -> a new auto-login wallet is created and
#                            sqlnet.ora is configured, so the
#                            observer can run as 'dgmgrl /@alias'.
#
# It then tests the new credentials against BOTH databases (the
# standby test proves the password file propagated) and offers to
# restart the observer under the new identity.
#
# Usage:
#   ./02_switch_observer_credentials.sh -u C##DG_OBSERVER
#   ./02_switch_observer_credentials.sh -u DG_OBSERVER \
#         --primary-tns prim --standby-tns stby
#   ./02_switch_observer_credentials.sh -u DG_OBSERVER --restart
#
# Options:
#   -u, --user USER        Observer username (created in step 01)
#   -w, --wallet-dir DIR   Wallet directory (default: discover from
#                          sqlnet.ora WALLET_LOCATION, else
#                          $ORACLE_HOME/network/admin/wallet)
#       --primary-tns A    TNS alias of the primary (prompted if absent)
#       --standby-tns A    TNS alias of the standby (prompted if absent)
#       --observer-dir D   Where START OBSERVER puts its fsfo.dat/log
#                          (default: $HOME/fsfo_observer)
#       --restart          Stop the running observer and start a new one
#                          without asking (needed for non-TTY runs;
#                          interactive runs are asked either way)
#       --no-restart       Never touch the running observer, only print
#                          the commands
#   -h, --help             Show this help
#
# Exit codes: 0 success, 1 fatal, 2 bad arguments
#
# Note on mkstore and `ps -ef`: mkstore has no stdin-based way to pass
# the credential password to -createCredential (only the wallet password
# can be fed via heredoc), so the observer password appears briefly on
# the mkstore argv at the -createCredential call sites. One-time setup
# exposure, not a long-lived service argv.
# ============================================================

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

OBSERVER_USER=""
WALLET_DIR=""
PRIMARY_TNS_ALIAS=""
STANDBY_TNS_ALIAS=""
OBSERVER_DIR="${HOME}/fsfo_observer"
RESTART_MODE="ask"     # ask | always | never
REBUILD_WALLET=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Switches the FSFO observer's authentication from SYS to a dedicated
SYSDG user (created by 01_create_sysdg_user.sh): replaces/creates the
observer wallet credentials, tests both databases, and offers to
restart the observer.

Options:
  -u, --user USER        Observer username (created in step 01)
  -w, --wallet-dir DIR   Wallet directory (default: discover from
                         sqlnet.ora WALLET_LOCATION, else
                         \$ORACLE_HOME/network/admin/wallet)
      --primary-tns A    TNS alias of the primary (prompted if absent)
      --standby-tns A    TNS alias of the standby (prompted if absent)
      --observer-dir D   Where START OBSERVER puts its fsfo.dat/log
                         (default: \$HOME/fsfo_observer)
      --restart          Stop the running observer and start a new one
                         without asking
      --no-restart       Never touch the running observer, only print
                         the commands
      --rebuild-wallet   Do not edit the existing wallet in place: back
                         it up and build a fresh one (automatic for
                         auto-login-only wallets, which mkstore cannot
                         reliably modify)
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)        [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                          OBSERVER_USER="$2"; shift 2 ;;
        -w|--wallet-dir)  [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                          WALLET_DIR="$2"; shift 2 ;;
        --primary-tns)    [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                          PRIMARY_TNS_ALIAS="$2"; shift 2 ;;
        --standby-tns)    [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                          STANDBY_TNS_ALIAS="$2"; shift 2 ;;
        --observer-dir)   [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                          OBSERVER_DIR="$2"; shift 2 ;;
        --restart)        RESTART_MODE="always"; shift ;;
        --no-restart)     RESTART_MODE="never"; shift ;;
        --rebuild-wallet) REBUILD_WALLET=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) log_error "Unknown option: $1"; exit 2 ;;
    esac
done

# ============================================================
# Pre-flight
# ============================================================

log_section "Pre-flight Checks"

check_oracle_env
MKSTORE="$ORACLE_HOME/bin/mkstore"
DGMGRL="$ORACLE_HOME/bin/dgmgrl"
SQLPLUS="$ORACLE_HOME/bin/sqlplus"
[[ -x "$MKSTORE" ]] || die "mkstore not found: $MKSTORE (Oracle client install incomplete?)"
[[ -x "$DGMGRL" ]]  || die "dgmgrl not found: $DGMGRL"
[[ -x "$SQLPLUS" ]] || die "sqlplus not found: $SQLPLUS"

TNS_ADMIN_DIR="${TNS_ADMIN:-$ORACLE_HOME/network/admin}"
SQLNET_FILE="${TNS_ADMIN_DIR}/sqlnet.ora"
log_info "ORACLE_HOME: $ORACLE_HOME"
log_info "TNS_ADMIN:   $TNS_ADMIN_DIR"

# Discover the wallet directory from sqlnet.ora when not given.
# Anchored to WALLET_LOCATION only - a plain substring match would also
# hit ENCRYPTION_WALLET_LOCATION (a TDE keystore, which is NOT a
# credential wallet) on TDE-enabled hosts.
if [[ -z "$WALLET_DIR" && -f "$SQLNET_FILE" ]]; then
    WALLET_DIR=$(awk '
        /^[[:space:]]*WALLET_LOCATION/ { grab = 1 }
        grab { block = block " " $0 }
        END {
            if (match(block, /DIRECTORY[[:space:]]*=[[:space:]]*[^)[:space:]]+/)) {
                s = substr(block, RSTART, RLENGTH)
                sub(/DIRECTORY[[:space:]]*=[[:space:]]*/, "", s)
                print s
            }
        }' "$SQLNET_FILE")
    [[ -n "$WALLET_DIR" ]] && log_info "Wallet directory from sqlnet.ora: $WALLET_DIR"
fi
WALLET_DIR="${WALLET_DIR:-$ORACLE_HOME/network/admin/wallet}"
log_info "Wallet directory: $WALLET_DIR"

if [[ -z "$OBSERVER_USER" ]]; then
    prompt_with_default OBSERVER_USER "Enter the SYSDG observer username (from step 01)" "dg_observer"
fi
OBSERVER_USER=$(printf '%s' "$OBSERVER_USER" | tr '[:lower:]' '[:upper:]')
[[ "$OBSERVER_USER" != "SYS" ]] || die "Refusing to store SYS credentials - that is what this conversion removes."
log_info "New observer user: $OBSERVER_USER"

if [[ -z "$PRIMARY_TNS_ALIAS" ]]; then
    [[ -t 0 ]] || die "--primary-tns is required when not running interactively."
    prompt_with_default PRIMARY_TNS_ALIAS "TNS alias of the PRIMARY database" ""
    [[ -n "$PRIMARY_TNS_ALIAS" ]] || die "Primary TNS alias is required."
fi
if [[ -z "$STANDBY_TNS_ALIAS" ]]; then
    [[ -t 0 ]] || die "--standby-tns is required when not running interactively."
    prompt_with_default STANDBY_TNS_ALIAS "TNS alias of the STANDBY database" ""
    [[ -n "$STANDBY_TNS_ALIAS" ]] || die "Standby TNS alias is required."
fi
log_info "TNS aliases: primary=$PRIMARY_TNS_ALIAS standby=$STANDBY_TNS_ALIAS"

wallet_exists() {
    [[ -f "${WALLET_DIR}/cwallet.sso" || -f "${WALLET_DIR}/ewallet.p12" ]]
}

# ============================================================
# Wallet: update in place, or create fresh
# ============================================================

NEW_WALLET=false

backup_wallet_for_rebuild() {
    WALLET_BACKUP="${WALLET_DIR}.bak.$(date '+%Y%m%d_%H%M%S')"
    mv "$WALLET_DIR" "$WALLET_BACKUP" || die "Failed to move $WALLET_DIR aside."
    log_info "Old wallet moved to: $WALLET_BACKUP"
    NEW_WALLET=true
}

if wallet_exists; then
    if [[ ! -f "${WALLET_DIR}/ewallet.p12" ]]; then
        # Auto-login-only wallet (cwallet.sso without ewallet.p12): mkstore
        # has no real password to verify, so edits "succeed" (exit 0) while
        # producing credentials sqlplus cannot use. The only safe move is a
        # rebuild. (Found the hard way on a test system.)
        log_section "Existing Wallet Is Auto-Login-Only - Rebuild Required"
        log_warn "This wallet has cwallet.sso but no ewallet.p12; mkstore cannot"
        log_warn "reliably modify it, so it will be backed up and rebuilt."
        log_info "Best-effort listing of its current credentials:"
        "$MKSTORE" -wrl "$WALLET_DIR" -listCredential <<EOF 2>/dev/null | grep -E '^[0-9][0-9]*:' || log_warn "(could not list credentials)"
dummy
EOF
        confirm_proceed "Back up $WALLET_DIR and build a FRESH wallet in its place?" \
            || die "Cannot proceed: an auto-login-only wallet must be rebuilt."
        backup_wallet_for_rebuild
    elif $REBUILD_WALLET; then
        log_section "Existing Wallet Found - Rebuild Forced (--rebuild-wallet)"
        confirm_proceed "Back up $WALLET_DIR and build a FRESH wallet in its place?" \
            || die "Rebuild declined."
        backup_wallet_for_rebuild
    else
        log_section "Existing Wallet Found - Replacing Credentials"

        prompt_password WALLET_PASSWORD "Enter the wallet password for $WALLET_DIR"

        log_info "Current credentials in the wallet:"
        if ! CRED_LIST=$("$MKSTORE" -wrl "$WALLET_DIR" -listCredential <<EOF 2>&1
${WALLET_PASSWORD}
EOF
        ); then
            log_warn "Could not open the wallet (wrong password?)."
            printf '%s\n' "$CRED_LIST" | tail -3 >&2
            echo ""
            log_warn "The wallet cannot be modified without its password."
            confirm_proceed "Back up $WALLET_DIR and build a FRESH wallet in its place?" \
                || die "Cannot proceed without a modifiable wallet. Re-run with the correct password or --wallet-dir."
            backup_wallet_for_rebuild
        else
            printf '%s\n' "$CRED_LIST" | grep -E '^[0-9][0-9]*:' || printf '%s\n' "$CRED_LIST"
            if printf '%s\n' "$CRED_LIST" | grep -qi ' SYS$'; then
                log_warn "SYS credentials detected - they will be replaced with ${OBSERVER_USER}."
            fi
        fi
    fi
else
    log_section "No Wallet Found - Creating One"
    log_info "The observer was presumably started with an explicit sys/password@alias."
    log_info "A new auto-login wallet will be created at: $WALLET_DIR"
    NEW_WALLET=true
fi

if $NEW_WALLET; then
    mkdir -p "$WALLET_DIR"
    chmod 700 "$WALLET_DIR"

    prompt_password WALLET_PASSWORD  "Enter a NEW wallet password (protects the wallet itself)"
    prompt_password WALLET_PASSWORD2 "Confirm wallet password"
    [[ "$WALLET_PASSWORD" == "$WALLET_PASSWORD2" ]] || die "Wallet passwords do not match."
    unset WALLET_PASSWORD2

    if ! MK_OUT=$("$MKSTORE" -wrl "$WALLET_DIR" -create <<EOF 2>&1
${WALLET_PASSWORD}
${WALLET_PASSWORD}
EOF
    ); then
        printf '%s\n' "$MK_OUT" >&2
        die "Failed to create wallet."
    fi
    if ! MK_OUT=$("$MKSTORE" -wrl "$WALLET_DIR" -createSSO <<EOF 2>&1
${WALLET_PASSWORD}
EOF
    ); then
        printf '%s\n' "$MK_OUT" >&2
        die "Failed to enable auto-login (createSSO)."
    fi
    log_info "Auto-login wallet created."
fi

# ------------------------------------------------------------
# Store the new user's credentials for both aliases
# ------------------------------------------------------------

prompt_password OBSERVER_PASSWORD "Enter the database password for $OBSERVER_USER"
[[ -n "$OBSERVER_PASSWORD" ]] || die "Password cannot be empty."

add_credential() {
    # Delete-then-create: -createCredential refuses to overwrite an
    # existing alias entry. The delete is a no-op when absent.
    # (See header note: the credential password is briefly visible on
    # this one mkstore invocation's argv.)
    local alias="$1" mk_out
    log_info "Storing ${OBSERVER_USER}@${alias} in the wallet..."
    "$MKSTORE" -wrl "$WALLET_DIR" -deleteCredential "$alias" <<EOF >/dev/null 2>&1 || true
${WALLET_PASSWORD}
EOF
    if ! mk_out=$("$MKSTORE" -wrl "$WALLET_DIR" -createCredential "$alias" "$OBSERVER_USER" "$OBSERVER_PASSWORD" <<EOF 2>&1
${WALLET_PASSWORD}
EOF
    ); then
        printf '%s\n' "$mk_out" >&2
        die "Failed to add credential for $alias"
    fi
}

add_credential "$PRIMARY_TNS_ALIAS"
add_credential "$STANDBY_TNS_ALIAS"
unset OBSERVER_PASSWORD WALLET_PASSWORD
log_info "Wallet credentials now point at $OBSERVER_USER for both aliases."
if [[ -n "${WALLET_BACKUP:-}" ]]; then
    log_warn "The rebuilt wallet contains ONLY these two aliases - any other"
    log_warn "credentials the old wallet held remain in: $WALLET_BACKUP"
fi

# ============================================================
# sqlnet.ora
# ============================================================

log_section "Checking sqlnet.ora"

WALLET_CONFIG="
# Oracle Wallet Configuration (added for FSFO observer)
WALLET_LOCATION = (SOURCE = (METHOD = FILE) (METHOD_DATA = (DIRECTORY = ${WALLET_DIR})))
SQLNET.WALLET_OVERRIDE = TRUE
"

if [[ -f "$SQLNET_FILE" ]]; then
    # Same ENCRYPTION_WALLET_LOCATION caveat as above: anchored match only.
    if grep -Eq '^[[:space:]]*WALLET_LOCATION' "$SQLNET_FILE"; then
        log_info "WALLET_LOCATION already present in sqlnet.ora."
        if ! grep -Eq '^[[:space:]]*SQLNET\.WALLET_OVERRIDE[[:space:]]*=[[:space:]]*TRUE' "$SQLNET_FILE"; then
            cp "$SQLNET_FILE" "${SQLNET_FILE}.bak.$(date '+%Y%m%d_%H%M%S')"
            printf '\nSQLNET.WALLET_OVERRIDE = TRUE\n' >> "$SQLNET_FILE"
            log_info "Added missing SQLNET.WALLET_OVERRIDE = TRUE (sqlnet.ora backed up)."
        fi
    else
        cp "$SQLNET_FILE" "${SQLNET_FILE}.bak.$(date '+%Y%m%d_%H%M%S')"
        printf '%s\n' "$WALLET_CONFIG" >> "$SQLNET_FILE"
        log_info "Added wallet configuration to sqlnet.ora (backup kept)."
    fi
else
    printf '%s\n' "$WALLET_CONFIG" > "$SQLNET_FILE"
    log_info "Created sqlnet.ora with wallet configuration."
fi

# ============================================================
# Connection Tests
# ============================================================

log_section "Testing the New Credentials"

test_sqlplus_alias() {
    # V$ fixed views work in MOUNT too, so the same test covers the
    # mounted standby and the open primary.
    local alias="$1" expected_role="$2" out role
    out=$("$SQLPLUS" -s -L "/@${alias}" as sysdg <<EOF 2>&1
set pagesize 0 heading off feedback off
select 'ROLE=' || database_role from v\$database;
exit
EOF
    ) || true
    role=$(printf '%s\n' "$out" | sed -n 's/^ROLE=//p' | head -1 | tr -d ' \r')
    if [[ -n "$role" ]]; then
        log_info "sqlplus /@${alias} as sysdg -> connected, database_role=$role"
        # $role had its spaces stripped above - strip them from the expected
        # value too before comparing ("PHYSICAL STANDBY" vs PHYSICALSTANDBY)
        if [[ -n "$expected_role" && "$role" != "${expected_role// /}" ]]; then
            log_warn "Expected $expected_role at $alias - check your aliases (roles may also be swapped post-switchover)."
        fi
        return 0
    fi
    log_error "Connection to $alias as $OBSERVER_USER failed:"
    printf '%s\n' "$out" | grep -E 'ORA-|TNS-' | head -3 >&2
    return 1
}

PRIMARY_OK=true
STANDBY_OK=true
test_sqlplus_alias "$PRIMARY_TNS_ALIAS" "PRIMARY" || PRIMARY_OK=false
test_sqlplus_alias "$STANDBY_TNS_ALIAS" "PHYSICAL STANDBY" || STANDBY_OK=false

if ! $PRIMARY_OK; then
    log_error "Primary connection failed - fix this before touching the observer:"
    log_error "  - wrong alias / wrong password / SYSDG user missing (re-run step 01)"
    log_error "  - or a pre-existing wallet that did not take the edit cleanly:"
    log_error "    re-run with --rebuild-wallet to back it up and build a fresh one."
    die "Aborting before the observer is touched."
fi
if ! $STANDBY_OK; then
    log_error "STANDBY connection failed. Most likely the primary's password file"
    log_error "change has not reached the standby (ORA-01017). Fix:"
    log_error "  primary>  scp \$ORACLE_HOME/dbs/orapw<PRIMARY_SID> standby:\$ORACLE_HOME/dbs/orapw<STANDBY_SID>"
    log_error "then re-run this script. (On 12.2+ it propagates automatically while"
    log_error "the standby is receiving redo - a long-disconnected standby will not have it.)"
    die "Not restarting the observer with credentials the standby rejects - it could not follow a failover."
fi

log_info "Testing broker connectivity (dgmgrl /@${PRIMARY_TNS_ALIAS})..."
DG_TEST=$("$DGMGRL" -silent "/@${PRIMARY_TNS_ALIAS}" "show configuration" 2>&1 || true)
if printf '%s\n' "$DG_TEST" | grep -qE 'Configuration -|SUCCESS|WARNING'; then
    log_info "Broker connection via wallet works."
else
    printf '%s\n' "$DG_TEST" | head -5 >&2
    die "dgmgrl could not talk to the broker with the new wallet credentials."
fi

# ============================================================
# Observer Restart
# ============================================================

log_section "Observer Restart"

log_info "Current observer registration (broker's view):"
"$DGMGRL" -silent "/@${PRIMARY_TNS_ALIAS}" "show observer" 2>&1 | sed -n '1,25p' || true
echo ""

DO_RESTART=false
case "$RESTART_MODE" in
    always) DO_RESTART=true ;;
    never)  DO_RESTART=false ;;
    ask)
        log_warn "The running observer is still connected as its OLD identity (SYS)."
        log_warn "While the observer is down (a few seconds), no automatic failover can happen."
        if confirm_proceed "Stop the current observer and start a new one from THIS host now?"; then
            DO_RESTART=true
        fi
        ;;
esac

if $DO_RESTART; then
    mkdir -p "$OBSERVER_DIR"

    log_info "Stopping the registered observer..."
    # dgmgrl -silent exits 0 even when the command fails, so the outcome
    # must be judged from the output, not the exit code.
    STOP_OUT=$("$DGMGRL" -silent "/@${PRIMARY_TNS_ALIAS}" "STOP OBSERVER" 2>&1 || true)
    printf '%s\n' "$STOP_OUT"
    if printf '%s\n' "$STOP_OUT" | grep -q 'ORA-16877'; then
        log_info "No observer was registered - nothing to stop."
    elif printf '%s\n' "$STOP_OUT" | grep -qE 'ORA-[0-9]|Failed'; then
        log_warn "STOP OBSERVER reported an error. If the old observer process is dead"
        log_warn "or unreachable, kill it manually on its host, then continue."
        confirm_proceed "Continue and start the new observer anyway?" || exit 1
    fi

    log_info "Starting the new observer in the background (SYSDG identity, wallet auth)..."
    # CONNECT IDENTIFIER is mandatory with IN BACKGROUND: the detached
    # observer daemon opens its own connection and does not inherit this
    # session's - dgmgrl rejects the command with a syntax error without it.
    "$DGMGRL" -silent "/@${PRIMARY_TNS_ALIAS}" \
        "START OBSERVER IN BACKGROUND FILE IS '${OBSERVER_DIR}/fsfo_observer.dat' LOGFILE IS '${OBSERVER_DIR}/fsfo_observer.log' CONNECT IDENTIFIER IS ${PRIMARY_TNS_ALIAS}" \
        || die "START OBSERVER failed - see ${OBSERVER_DIR}/fsfo_observer.log"

    sleep 5
    OBS_PRESENT=$("$SQLPLUS" -s -L "/@${PRIMARY_TNS_ALIAS}" as sysdg <<EOF 2>/dev/null | tr -d ' \t\r' | grep -E '^(YES|NO)' | head -1
set pagesize 0 heading off feedback off
select fs_failover_observer_present from v\$database;
exit
EOF
    ) || OBS_PRESENT=""

    if [[ "$OBS_PRESENT" == "YES" ]]; then
        log_info "Observer is registered and present (FS_FAILOVER_OBSERVER_PRESENT=YES)."
    else
        log_warn "Observer not (yet) reported present - it can take ~30s. Verify with:"
        log_warn "  ./03_verify_conversion.sh --tns ${PRIMARY_TNS_ALIAS}"
    fi
else
    cat <<EOF
Not restarting the observer. When ready, run (from the observer host):

  dgmgrl -silent /@${PRIMARY_TNS_ALIAS} "STOP OBSERVER"
  dgmgrl -silent /@${PRIMARY_TNS_ALIAS} "START OBSERVER IN BACKGROUND \\
      FILE IS '${OBSERVER_DIR}/fsfo_observer.dat' \\
      LOGFILE IS '${OBSERVER_DIR}/fsfo_observer.log' \\
      CONNECT IDENTIFIER IS ${PRIMARY_TNS_ALIAS}"

If the old observer was started from cron / a systemd unit / a shell
script containing 'sys/<password>@...', update that script to the
wallet form above or it will resurrect the SYS observer.
EOF
fi

# ============================================================
# Summary
# ============================================================

cat <<EOF

============================================================
CREDENTIAL SWITCH COMPLETE
============================================================

  Wallet:        $WALLET_DIR
  Credentials:   ${OBSERVER_USER}@${PRIMARY_TNS_ALIAS}
                 ${OBSERVER_USER}@${STANDBY_TNS_ALIAS}
  Observer auth: dgmgrl /@${PRIMARY_TNS_ALIAS}   (auto-login wallet, SYSDG)

Verify the end state with:
  ./03_verify_conversion.sh --tns ${PRIMARY_TNS_ALIAS}

Remember: any start script / cron entry / service unit that still
embeds sys/<password> must be updated to the wallet syntax.
EOF
