#!/usr/bin/env bash
# ============================================================
# Observer SYS -> SYSDG conversion - Step 1 (run on PRIMARY)
# ============================================================
# Creates (or fixes up) a dedicated database user for the FSFO
# observer with exactly the privileges the observer needs:
#
#   CREATE SESSION + SYSDG
#
# nothing more - specifically NOT SYSDBA and NOT the SYS account.
#
# The script is idempotent:
#   - user missing            -> created with both grants
#   - user exists, no SYSDG   -> SYSDG granted
#   - user exists with SYSDG  -> verified, optional password reset
#
# On a multitenant primary (CDB) the user must be a COMMON user
# (dgmgrl connects at the root), so the name is auto-prefixed
# with C## after confirmation.
#
# Run interactively on the PRIMARY host with ORACLE_SID/ORACLE_HOME
# set and 'sqlplus / as sysdba' working.
#
# Usage:
#   ./01_create_sysdg_user.sh                # prompts (default dg_observer)
#   ./01_create_sysdg_user.sh -u dg_watcher  # explicit username
#
# Exit codes: 0 success, 1 fatal, 2 bad arguments
# ============================================================

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

OBSERVER_USER=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [-u|--user USERNAME]

Creates/verifies a dedicated observer user with SYSDG + CREATE SESSION
on the local PRIMARY database (connects 'sqlplus / as sysdba').

Options:
  -u, --user USERNAME   Observer username (default: dg_observer,
                        c##dg_observer on a CDB)
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)
            [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
            OBSERVER_USER="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
done

# ============================================================
# Pre-flight
# ============================================================

log_section "Pre-flight Checks"

check_oracle_env
[[ -n "${ORACLE_SID:-}" ]] || die "ORACLE_SID is not set."
[[ -x "$ORACLE_HOME/bin/sqlplus" ]] || die "sqlplus not found under $ORACLE_HOME/bin"

DB_ROLE=$(run_sql "select database_role from v\$database;" | tr -d ' \t\r') \
    || die "Cannot connect 'sqlplus / as sysdba' to $ORACLE_SID."
[[ "$DB_ROLE" == "PRIMARY" ]] || die "This database is $DB_ROLE, not PRIMARY. Run this script on the PRIMARY."
log_info "Database role: PRIMARY ($ORACLE_SID)"

PWFILE_MODE=$(run_sql "select upper(nvl(value,'NONE')) from v\$parameter where name = 'remote_login_passwordfile';" | tr -d ' \t\r') || PWFILE_MODE="NONE"
if [[ "$PWFILE_MODE" != "EXCLUSIVE" && "$PWFILE_MODE" != "SHARED" ]]; then
    die "remote_login_passwordfile = ${PWFILE_MODE}. A password file is required for the observer's remote SYSDG connections."
fi
log_info "Password file authentication: $PWFILE_MODE"

IS_CDB=$(run_sql "select cdb from v\$database;" | tr -d ' \t\r') || IS_CDB="NO"
log_info "Multitenant (CDB): $IS_CDB"

# ============================================================
# Determine Username
# ============================================================

log_section "Observer Username"

DEFAULT_OBSERVER_USER="dg_observer"
[[ "$IS_CDB" == "YES" ]] && DEFAULT_OBSERVER_USER="c##dg_observer"

if [[ -z "$OBSERVER_USER" ]]; then
    prompt_with_default OBSERVER_USER "Enter username for the observer" "$DEFAULT_OBSERVER_USER"
fi

OBSERVER_USER=$(printf '%s' "$OBSERVER_USER" | tr '[:lower:]' '[:upper:]')

if [[ "$OBSERVER_USER" == "SYS" ]]; then
    die "The whole point of this conversion is to stop using SYS - pick a dedicated username."
fi

# On a CDB, a non-C## name would fail with ORA-65096 (common user must be
# created at the root, where dgmgrl connects).
if [[ "$IS_CDB" == "YES" && "$OBSERVER_USER" != C##* ]]; then
    log_warn "This is a CDB: the observer user must be a COMMON user (C## prefix)."
    if [[ -t 0 ]]; then
        confirm_proceed "Auto-prefix the username as C##${OBSERVER_USER}?" \
            || die "Cannot create a non-common observer user on a CDB."
    else
        log_warn "Non-interactive stdin: auto-prefixing the observer username as C##${OBSERVER_USER}"
    fi
    OBSERVER_USER="C##${OBSERVER_USER}"
fi

if ! printf '%s' "$OBSERVER_USER" | grep -q '^[A-Za-z][A-Za-z0-9_$#]*$' || [[ ${#OBSERVER_USER} -gt 30 ]]; then
    die "Invalid observer username: $OBSERVER_USER"
fi

log_info "Observer username: $OBSERVER_USER"

# ============================================================
# Create / Fix Up the User
# ============================================================

log_section "Creating / Verifying Observer User"

USER_EXISTS=$(run_sql "select count(*) from dba_users where username = '${OBSERVER_USER}';" | tr -d ' \t\r')

set_password() {
    # $1 = "new user" | "existing user"
    local pw pw2
    prompt_password pw  "Enter password for ${1} ${OBSERVER_USER}"
    prompt_password pw2 "Confirm password"
    [[ "$pw" == "$pw2" ]] || die "Passwords do not match."
    [[ -n "$pw" ]] || die "Password cannot be empty."
    case "$pw" in
        *\"*) die 'Password must not contain a double quote (").' ;;
    esac
    OBSERVER_PASSWORD="$pw"
}

# run_sql, but on failure print sqlplus's output (the ORA- error) before dying.
run_sql_or_die() {
    local __sql="$1" __msg="$2" __out=""
    if ! __out=$(run_sql "$__sql"); then
        printf '%s\n' "$__out" >&2
        die "$__msg"
    fi
}

if [[ "$USER_EXISTS" == "0" ]]; then
    log_info "User $OBSERVER_USER does not exist - creating it."
    set_password "new user"
    run_sql_or_die "create user ${OBSERVER_USER} identified by \"${OBSERVER_PASSWORD}\";
grant create session to ${OBSERVER_USER};
grant sysdg to ${OBSERVER_USER};" "Failed to create $OBSERVER_USER."
    unset OBSERVER_PASSWORD
    log_info "User created with CREATE SESSION + SYSDG."
else
    log_info "User $OBSERVER_USER already exists."

    # SYSDG is a password-file/administrative privilege: it shows up in
    # V$PWFILE_USERS, never in DBA_ROLE_PRIVS / DBA_SYS_PRIVS.
    HAS_SYSDG=$(run_sql "select count(*) from v\$pwfile_users where username = '${OBSERVER_USER}' and sysdg = 'TRUE';" | tr -d ' \t\r')

    if [[ "$HAS_SYSDG" == "1" ]]; then
        log_info "User already has SYSDG."
    else
        log_info "Granting SYSDG + CREATE SESSION to $OBSERVER_USER..."
        run_sql_or_die "grant create session to ${OBSERVER_USER};
grant sysdg to ${OBSERVER_USER};" "Failed to grant SYSDG to $OBSERVER_USER."
        log_info "SYSDG granted."
    fi

    if confirm_proceed "Reset the password for $OBSERVER_USER now?"; then
        set_password "existing user"
        run_sql_or_die "alter user ${OBSERVER_USER} identified by \"${OBSERVER_PASSWORD}\";" \
            "Failed to reset password for $OBSERVER_USER."
        unset OBSERVER_PASSWORD
        log_info "Password updated."
    else
        log_info "Keeping the existing password (you will need it for the wallet in step 02)."
    fi
fi

# ============================================================
# Verify
# ============================================================

log_section "Verification"

VERIFIED=$(run_sql "select count(*) from v\$pwfile_users where username = '${OBSERVER_USER}' and sysdg = 'TRUE';" | tr -d ' \t\r')
[[ "$VERIFIED" == "1" ]] || die "$OBSERVER_USER does not show SYSDG='TRUE' in V\$PWFILE_USERS."
log_info "$OBSERVER_USER has SYSDG in the password file (V\$PWFILE_USERS)."

cat <<EOF

============================================================
SYSDG OBSERVER USER READY: ${OBSERVER_USER}
============================================================

The grant updated the PRIMARY's password file. The observer also
connects to the STANDBY (that is how it survives a failover), so the
standby's password file must contain this user too:

  - On 12.2+ a physical standby that is receiving redo picks up
    primary password file changes AUTOMATICALLY - usually nothing
    to do.
  - If the wallet connection test to the standby in step 02 fails
    with ORA-01017, copy the file manually:

      primary>  scp \$ORACLE_HOME/dbs/orapw${ORACLE_SID} \\
                    standby:\$ORACLE_HOME/dbs/orapw<STANDBY_ORACLE_SID>

NEXT STEP
=========
On the OBSERVER host, run:

  ./02_switch_observer_credentials.sh -u ${OBSERVER_USER}

EOF
