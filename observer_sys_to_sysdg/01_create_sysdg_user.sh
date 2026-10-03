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
# Password expiry: a new user lands in the DEFAULT profile, whose
# PASSWORD_LIFE_TIME is 180 days on a stock 19c database. When the
# observer's password expires its logins fail with ORA-28001 and FSFO
# silently stops working, so the script reports the user's effective
# PASSWORD_LIFE_TIME and (TTY only, default NO) offers a dedicated profile
# with UNLIMITED life time. It never changes a profile without asking.
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
    # The password is embedded as IDENTIFIED BY "..." (run_sql sets DEFINE OFF,
    # so '&' is safe); an embedded double quote would end the identifier.
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
    # Observed on 19.27 with a MOUNTED physical standby: create + grant do not
    # reach the standby's password file, but a password change does. Set the same
    # password again, after the grant; a failure is only a warning (step 02 proves
    # the standby login).
    if ! REPW_OUT=$(run_sql "alter user ${OBSERVER_USER} identified by \"${OBSERVER_PASSWORD}\";"); then
        REPW_OUT=${REPW_OUT//"$OBSERVER_PASSWORD"/********}
        log_warn "Could not set the password again: $(printf '%s\n' "$REPW_OUT" | grep -E '(ORA|SP2)-[0-9]+' | tail -1)"
        log_warn "The standby's password file will not receive $OBSERVER_USER until the password is changed to a NEW value"
        log_warn "or the primary's password file is copied to the standby."
    fi
    unset OBSERVER_PASSWORD REPW_OUT
    log_info "User created with CREATE SESSION + SYSDG."
else
    log_info "User $OBSERVER_USER already exists."

    # SYSDG is a password-file/administrative privilege: it shows up in
    # V$PWFILE_USERS, never in DBA_ROLE_PRIVS / DBA_SYS_PRIVS.
    HAS_SYSDG=$(run_sql "select count(*) from v\$pwfile_users where username = '${OBSERVER_USER}' and sysdg = 'TRUE';" | tr -d ' \t\r')

    SYSDG_GRANTED_NOW=0
    if [[ "$HAS_SYSDG" == "1" ]]; then
        log_info "User already has SYSDG."
    else
        SYSDG_GRANTED_NOW=1
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
        if [[ "$SYSDG_GRANTED_NOW" == "1" ]]; then
            # Observed on 19.27 with a MOUNTED physical standby.
            log_warn "SYSDG was granted just now, and a GRANT alone does not reach a mounted standby's password file."
            log_warn "$OBSERVER_USER cannot log in to the standby until its password is set again on the primary"
            log_warn "(re-run this script and answer yes to the password reset) or the primary's password file is copied to the standby."
        fi
    fi
fi

# ============================================================
# Password expiry (PASSWORD_LIFE_TIME)
# ============================================================

log_section "Password Expiry Check"

# Effective PASSWORD_LIFE_TIME of the user's profile (a profile limit of
# DEFAULT defers to the DEFAULT profile). Informational: a failed query
# degrades to a warning, never a failed step.
USER_PROFILE=$(run_sql "select profile from dba_users where username = '${OBSERVER_USER}';" | tr -d ' \t\r') || USER_PROFILE=""
LIFE_TIME=""
if [[ -n "$USER_PROFILE" ]]; then
    LIFE_TIME=$(run_sql "select limit from dba_profiles where profile = '${USER_PROFILE}' and resource_name = 'PASSWORD_LIFE_TIME';" | tr -d ' \t\r') || LIFE_TIME=""
    if [[ "$LIFE_TIME" == "DEFAULT" ]]; then
        LIFE_TIME=$(run_sql "select limit from dba_profiles where profile = 'DEFAULT' and resource_name = 'PASSWORD_LIFE_TIME';" | tr -d ' \t\r') || LIFE_TIME=""
    fi
fi

OBSERVER_PROFILE="DG_OBSERVER_PROFILE"
PROFILE_CONTAINER_CLAUSE=""
if [[ "$IS_CDB" == "YES" ]]; then
    # A common user needs a common profile (C## prefix, created CONTAINER=ALL).
    OBSERVER_PROFILE="C##DG_OBSERVER_PROFILE"
    PROFILE_CONTAINER_CLAUSE=" container = all"
fi
PROFILE_SQL="create profile ${OBSERVER_PROFILE} limit password_life_time unlimited${PROFILE_CONTAINER_CLAUSE};
alter user ${OBSERVER_USER} profile ${OBSERVER_PROFILE};"

if [[ -z "$LIFE_TIME" ]]; then
    log_warn "Could not read PASSWORD_LIFE_TIME for $OBSERVER_USER - check it yourself:"
    log_warn "  select p.limit from dba_profiles p, dba_users u where u.username = '${OBSERVER_USER}'"
    log_warn "    and p.profile = u.profile and p.resource_name = 'PASSWORD_LIFE_TIME';"
elif [[ "$LIFE_TIME" == "UNLIMITED" ]]; then
    log_info "Profile $USER_PROFILE: PASSWORD_LIFE_TIME is UNLIMITED - the password will not expire."
else
    log_warn "Profile $USER_PROFILE has PASSWORD_LIFE_TIME = $LIFE_TIME (days)."
    log_warn "When $OBSERVER_USER's password expires the observer's logins fail with"
    log_warn "ORA-28001 and Fast-Start Failover stops working WITHOUT any obvious alarm."
    log_warn "Fix: give the observer user a dedicated profile with an unlimited life time:"
    printf '%s\n' "$PROFILE_SQL" | sed 's/^/      /' >&2
    if [[ -t 0 ]] && confirm_proceed "Create profile ${OBSERVER_PROFILE} (if missing) and assign it to $OBSERVER_USER now?"; then
        PROFILE_EXISTS=$(run_sql "select count(*) from dba_profiles where profile = '${OBSERVER_PROFILE}';" | tr -d ' \t\r') || PROFILE_EXISTS="0"
        if [[ "$PROFILE_EXISTS" == "0" ]]; then
            run_sql_or_die "create profile ${OBSERVER_PROFILE} limit password_life_time unlimited${PROFILE_CONTAINER_CLAUSE};" \
                "Failed to create profile $OBSERVER_PROFILE."
        else
            log_info "Profile $OBSERVER_PROFILE already exists - assigning it as is."
        fi
        run_sql_or_die "alter user ${OBSERVER_USER} profile ${OBSERVER_PROFILE};" \
            "Failed to assign profile $OBSERVER_PROFILE to $OBSERVER_USER."
        log_info "$OBSERVER_USER now uses profile $OBSERVER_PROFILE (PASSWORD_LIFE_TIME inherited from it)."
    else
        log_warn "Profile left unchanged - schedule a password rotation (and a wallet update) before it expires."
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
standby's password file must contain this user too. A GRANT alone does
not reach a mounted standby (verified on 19.27); setting the password
does, so a newly created user's password was set a second time above.

  - If the wallet connection test to the standby in step 02 fails
    with ORA-01017, set the user's password on the primary again
    (ALTER USER ${OBSERVER_USER} IDENTIFIED BY ...; re-run this script
    and answer yes to the reset), or copy the file manually:

      primary>  scp \$ORACLE_HOME/dbs/orapw${ORACLE_SID} \\
                    standby:\$ORACLE_HOME/dbs/orapw<STANDBY_ORACLE_SID>

NEXT STEP
=========
On the OBSERVER host, run:

  ./02_switch_observer_credentials.sh -u ${OBSERVER_USER}

EOF
