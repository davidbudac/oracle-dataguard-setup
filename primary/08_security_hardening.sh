#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 8: Security Hardening
# ============================================================
# Run this script on the PRIMARY database server.
# It randomizes the SYS password and locks the account.
# After this, use OS authentication '/ as sysdba' for DBA tasks.
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source common functions
source "${COMMON_DIR}/dg_functions.sh"
enable_verbose_mode "$@"

# ============================================================
# Main Script
# ============================================================

print_banner "Step 8: Security Hardening"
init_progress 8

# Initialize logging
init_log "08_security_hardening"

# ============================================================
# Pre-flight Checks
# ============================================================

progress_step "Pre-flight Checks"

check_oracle_env || exit 1
check_db_connection || exit 1
check_nfs_mount || exit 1

# Verify this is the primary database
DB_ROLE=$(run_sql_query "get_db_role.sql")
DB_ROLE=$(echo "$DB_ROLE" | tr -d '[:space:]')

if [[ "$DB_ROLE" != "PRIMARY" ]]; then
    log_error "This script must be run on the PRIMARY database"
    log_error "Current database role: $DB_ROLE"
    exit 1
fi

log_info "Confirmed: Running on PRIMARY database"

# Get DB_UNIQUE_NAME for logging
DB_UNIQUE_NAME=$(get_db_parameter "db_unique_name")
init_log "08_security_hardening_${DB_UNIQUE_NAME}"

# Load standby configuration - needed after the password change below to
# propagate the refreshed password file to the standby's ORACLE_SID/paths.
if ! select_config_file STANDBY_CONFIG_FILE "standby configuration" "${NFS_SHARE}/standby_config_*.env"; then
    log_error "Please run the Data Guard setup scripts first (Steps 1-7)"
    exit 1
fi
source "$STANDBY_CONFIG_FILE"

# ============================================================
# Review Planned Changes
# ============================================================

progress_step "Reviewing Planned Changes"

print_list_block "This Step Will Change" \
    "Change the SYS password to a random value that is not retained by the script." \
    "Lock the SYS account on ${DB_UNIQUE_NAME}." \
    "Leave Data Guard transport using the password file in place."

print_list_block "This Step Will Not Change" \
    "It will not modify Broker topology." \
    "It will not unlock or change other accounts." \
    "It will not store the generated SYS password anywhere."

print_list_block "Recovery If This Step Fails" \
    "Use OS authentication: sqlplus / as sysdba." \
    "If SYS must be restored, manually set a new password and unlock the account." \
    "Do not proceed unless OS authentication is available on the host."

record_next_step "./primary/09_configure_fsfo.sh"

if [[ "$CHECK_ONLY" == "1" ]]; then
    finish_check_mode "Security hardening preflight complete. No account changes were applied."
fi

# ============================================================
# Verify Data Guard Configuration
# ============================================================

progress_step "Verifying Data Guard Configuration"

# Check if broker configuration exists and is healthy
CONFIG_STATUS=$(run_dgmgrl "show_configuration.dgmgrl" 2>&1 || true)

if echo "$CONFIG_STATUS" | grep -q "ORA-16532"; then
    log_error "No Data Guard Broker configuration found"
    log_error "Please complete Data Guard setup before running security hardening"
    exit 1
fi

if echo "$CONFIG_STATUS" | grep -q "SUCCESS"; then
    log_info "Data Guard configuration status: SUCCESS"
elif echo "$CONFIG_STATUS" | grep -q "WARNING"; then
    log_warn "Data Guard configuration has warnings - proceeding with caution"
else
    log_error "Data Guard configuration is not healthy"
    log_error "Please resolve issues before running security hardening"
    echo ""
    echo "$CONFIG_STATUS"
    exit 1
fi

# ============================================================
# Confirmation
# ============================================================

progress_step "Reviewing Security Hardening Impact"

echo ""
echo "WARNING: This script will:"
echo "  1. Change the SYS password to a random string (not stored anywhere)"
echo "  2. Lock the SYS account"
echo ""
echo "After this:"
echo "  - You must use OS authentication '/ as sysdba' for DBA connections"
echo "  - Password-based SYS connections will no longer work"
echo "  - The password file will still be used for Data Guard redo transport"
echo ""

TEST_RESULT=$(run_sql_query "check_os_auth.sql")
if echo "$TEST_RESULT" | grep -q "OS_AUTH_OK"; then
    log_info "PASS: OS authentication '/ as sysdba' is working before hardening"
else
    log_error "OS authentication verification failed before hardening"
    exit 1
fi

# Locking SYS requires a format 12.2 password file. On a legacy (format 12)
# file, "ALTER USER SYS ACCOUNT LOCK" raises ORA-40365 - but the password
# change would already have run, leaving SYS with an unknown random password
# and unlocked. Check the format up front and stop BEFORE touching SYS.
HARDEN_ORAPW_FILE="${ORACLE_HOME}/dbs/orapw${ORACLE_SID}"
if command -v orapwd >/dev/null 2>&1 && [[ -f "$HARDEN_ORAPW_FILE" ]]; then
    PWFILE_FORMAT=$(orapwd describe file="$HARDEN_ORAPW_FILE" 2>/dev/null | sed -n 's/.*format=\([0-9.]*\).*/\1/p')
    if [[ -n "$PWFILE_FORMAT" && "$PWFILE_FORMAT" != "12.2" ]]; then
        log_error "Password file ${HARDEN_ORAPW_FILE} is format=${PWFILE_FORMAT}, not 12.2."
        log_error "Locking SYS requires a format 12.2 password file (otherwise ORA-40365)."
        log_error "Migrate it first (this preserves existing entries), then re-run this step:"
        log_error "  cd ${ORACLE_HOME}/dbs"
        log_error "  orapwd file=orapw${ORACLE_SID}.new input_file=orapw${ORACLE_SID} format=12.2"
        log_error "  mv orapw${ORACLE_SID} orapw${ORACLE_SID}.fmt12.bak && mv orapw${ORACLE_SID}.new orapw${ORACLE_SID}"
        log_error "Then propagate the migrated file to the standby before re-running."
        exit 1
    fi
fi

if ! confirm_typed_value "This will change and lock SYS on ${DB_UNIQUE_NAME}." "SECURE ${DB_UNIQUE_NAME}"; then
    log_info "Security hardening cancelled by user"
    exit 0
fi

# ============================================================
# Security Hardening
# ============================================================

progress_step "Applying Security Hardening"

log_info "Generating random password..."

# Generate a random password (not displayed or logged anywhere).
# Primary path: openssl (widely available, gives mixed-case + digits).
# Fallback: od against /dev/urandom - AIX 7.2 base install has neither
# `base64` nor a `head -c` that accepts -c, so the original
# dd|base64|head -c pipeline is not portable. /dev/urandom never reaches
# EOF, so the byte count is bounded with `-N 16` (16 bytes = 32 hex chars)
# rather than an unbounded `od ... /dev/urandom`, which would hang forever
# reading from an infinite device.
# Oracle caps a password (quoted identifier) at 30 bytes; 32 chars raises
# ORA-00972: identifier is too long. Keep it at 30 - still ~178 bits of
# entropy from the A-Za-z0-9 alphabet.
if command -v openssl >/dev/null 2>&1; then
    RANDOM_PWD=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-30)
else
    RANDOM_PWD=$(od -An -tx1 -N 16 /dev/urandom | tr -d '[:space:]' | cut -c1-30)
fi

log_info "Changing SYS password..."
log_cmd "sqlplus / as sysdba:" "ALTER USER SYS IDENTIFIED BY '********'"

# H6: password rotation and account lock run as two SEPARATE sqlplus calls
# with separate exit codes, so a failure after rotation can be told apart
# from a failure before anything changed. WHENEVER SQLERROR EXIT
# SQL.SQLCODE makes each call's exit code the authoritative result.
confirm_approval_action "Run SQL command" "ALTER USER SYS IDENTIFIED BY ********" || exit 1
pause_verbose_trace
PASSWORD_CHANGE_RC=0
sqlplus -s / as sysdba <<EOF || PASSWORD_CHANGE_RC=$?
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF
ALTER USER SYS IDENTIFIED BY "${RANDOM_PWD}";
EXIT SUCCESS;
EOF
resume_verbose_trace

if [[ "$PASSWORD_CHANGE_RC" -ne 0 ]]; then
    # Nothing changed: SYS still has its previous password and is still
    # unlocked. Safe to wipe the never-applied random password and bail
    # out before touching the account lock or standby propagation.
    log_error "Failed to change the SYS password (rc=${PASSWORD_CHANGE_RC}) - SYS account is UNCHANGED"
    log_error "SYS still has its previous password and is still unlocked; nothing was propagated to the standby."
    log_error "Please investigate and secure manually if desired:"
    log_error "  ALTER USER SYS IDENTIFIED BY '<random_password>';"
    log_error "  ALTER USER SYS ACCOUNT LOCK;"
    RANDOM_PWD=""
    unset RANDOM_PWD
    exit 1
fi

log_info "SYS password changed. Locking the account..."
log_cmd "sqlplus / as sysdba:" "ALTER USER SYS ACCOUNT LOCK"
pause_verbose_trace
LOCK_RC=0
sqlplus -s / as sysdba <<EOF || LOCK_RC=$?
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF
ALTER USER SYS ACCOUNT LOCK;
EXIT SUCCESS;
EOF
resume_verbose_trace

# H6: SYS_LOCK_FAILED tracks the partial-failure state (password rotated,
# lock did not apply) through the rest of the script - propagation and the
# ACTION REQUIRED block below must still run either way, since the primary
# side is already rotated and the standby's copy is already stale
# regardless of whether the lock succeeded.
SYS_LOCK_FAILED=0
if [[ "$LOCK_RC" -eq 0 ]]; then
    log_success "SYS account secured successfully (password rotated and locked)"
else
    SYS_LOCK_FAILED=1
    log_error "SYS password was changed successfully, but ACCOUNT LOCK failed (rc=${LOCK_RC})"
    log_error "CURRENT STATE OF SYS: password has been ROTATED to a new random value (never stored or"
    log_error "displayed) and the account is still UNLOCKED. No one can authenticate as SYS with a"
    log_error "password until you lock it below (OS authentication - '/ as sysdba' - still works)."
    log_error "Run this manually on the primary as soon as possible:"
    log_error "  sqlplus / as sysdba"
    log_error "  ALTER USER SYS ACCOUNT LOCK;"
    log_warn "Continuing: the password file will still be propagated to the standby below, since the"
    log_warn "password was already rotated on the primary and the standby's copy is stale either way."
fi

# Clear the password variable immediately - it is never needed again
# regardless of the lock outcome above (H6: the password itself is never
# printed, logged, or stored anywhere).
RANDOM_PWD=""
unset RANDOM_PWD

# ============================================================
# Verify Changes
# ============================================================

progress_step "Verifying Security Changes"

# Check account status
ACCOUNT_STATUS=$(run_sql_query "get_sys_account_status.sql")
ACCOUNT_STATUS=$(echo "$ACCOUNT_STATUS" | tr -d '[:space:]')

if [[ "$ACCOUNT_STATUS" == *"LOCKED"* ]]; then
    log_info "PASS: SYS account is locked (status: $ACCOUNT_STATUS)"
else
    log_warn "SYS account may not be fully locked (status: $ACCOUNT_STATUS)"
fi

# Verify OS authentication still works
log_info "Verifying OS authentication..."
TEST_RESULT=$(run_sql_query "check_os_auth.sql")

if echo "$TEST_RESULT" | grep -q "OS_AUTH_OK"; then
    log_info "PASS: OS authentication '/ as sysdba' is working"
else
    log_error "OS authentication may not be working - please verify manually"
fi

# ============================================================
# Propagate Password File to Standby
# ============================================================
# The SYS password change above regenerates this instance's local
# orapw${ORACLE_SID} (Oracle re-syncs it automatically on ALTER USER SYS
# IDENTIFIED BY). Data Guard redo transport authenticates via the password
# file, and the standby's copy was made BEFORE this change, so it is now
# stale - the next reconnect/restart of redo transport will fail with
# ORA-16191 until the standby's password file is refreshed too.

progress_step "Propagating Password File to Standby"

ORAPW_FILE="${ORACLE_HOME}/dbs/orapw${ORACLE_SID}"
NFS_ORAPW_STAGING="${NFS_SHARE}/orapw${STANDBY_ORACLE_SID}_hardened"
# L6: step 1 also staged the primary's password file under this name
# (orapw<PRIMARY_ORACLE_SID> - see 01_gather_primary_info.sh), and step 3
# reads exactly that filename when (re-)installing the standby's password
# file. Refresh it here too, not just the _hardened copy - otherwise a
# re-run of step 3 after hardening silently re-installs the PRE-rotation
# password file on the standby.
NFS_ORAPW_CANONICAL="${NFS_SHARE}/orapw${PRIMARY_ORACLE_SID:-}"

if [[ -f "$ORAPW_FILE" ]]; then
    log_info "Staging refreshed password file on the NFS share..."
    confirm_approval_action "Copy refreshed primary password file to NFS share" "cp $ORAPW_FILE $NFS_ORAPW_STAGING && chmod 600 $NFS_ORAPW_STAGING" || exit 1
    ( umask 077; cp "$ORAPW_FILE" "$NFS_ORAPW_STAGING" )
    chmod 600 "$NFS_ORAPW_STAGING"
    log_success "Password file staged at: $NFS_ORAPW_STAGING"
    record_artifact "password_file_hardened:${NFS_ORAPW_STAGING}"

    if [[ -n "${PRIMARY_ORACLE_SID:-}" ]]; then
        confirm_approval_action "Refresh step-1 staged primary password file on NFS share" "cp $ORAPW_FILE $NFS_ORAPW_CANONICAL && chmod 600 $NFS_ORAPW_CANONICAL" || exit 1
        ( umask 077; cp "$ORAPW_FILE" "$NFS_ORAPW_CANONICAL" )
        chmod 600 "$NFS_ORAPW_CANONICAL"
        log_success "Refreshed step-1 staged copy: $NFS_ORAPW_CANONICAL"
        record_artifact "password_file_refreshed:${NFS_ORAPW_CANONICAL}"
    else
        log_warn "PRIMARY_ORACLE_SID not set in the config file - could not refresh the step-1 staged password file (${NFS_SHARE}/orapw<PRIMARY_ORACLE_SID>)"
    fi

    print_list_block "ACTION REQUIRED on STANDBY (${STANDBY_DB_UNIQUE_NAME})" \
        "Copy the refreshed password file from the NFS share to the standby's dbs directory:" \
        "  cp ${NFS_ORAPW_STAGING} <STANDBY_ORACLE_HOME>/dbs/orapw${STANDBY_ORACLE_SID}" \
        "  chmod 640 <STANDBY_ORACLE_HOME>/dbs/orapw${STANDBY_ORACLE_SID}" \
        "Until this is done, redo transport will fail with ORA-16191 on the next reconnect or restart."

    if [[ "$SYS_LOCK_FAILED" -eq 1 ]]; then
        print_list_block "ACTION REQUIRED on PRIMARY (${DB_UNIQUE_NAME})" \
            "SYS is UNLOCKED with a freshly-rotated, unrecorded password - nobody can authenticate as SYS via" \
            "password until you act (OS authentication still works)." \
            "Run: sqlplus / as sysdba, then: ALTER USER SYS ACCOUNT LOCK;" \
            "Re-run this step afterward if you want the checks below to re-confirm the locked state."
    fi
else
    log_error "Primary password file not found: $ORAPW_FILE"
    log_error "Cannot stage a refreshed password file for the standby."
    log_error "Redo transport WILL fail with ORA-16191 until orapw${STANDBY_ORACLE_SID} is refreshed on the standby manually."
fi

# ============================================================
# Verify Redo Transport After the Password Change
# ============================================================

progress_step "Verifying Redo Transport"

TRANSPORT_STATUS="OK"

BROKER_CONFIG_OUTPUT=$(run_dgmgrl "show_configuration.dgmgrl" 2>&1 || true)
if echo "$BROKER_CONFIG_OUTPUT" | grep -q "ORA-16191"; then
    TRANSPORT_STATUS="ORA-16191"
fi

# V$ARCHIVE_DEST_STATUS carries the live transport error text (ORA-16191
# specifically means the standby rejected the primary's login credentials -
# i.e. exactly the password-file mismatch this step can introduce).
ARCHIVE_DEST_ERRORS=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT DEST_ID || ':' || ERROR FROM V\$ARCHIVE_DEST_STATUS WHERE ERROR IS NOT NULL;
EXIT;
EOF
)

if echo "$ARCHIVE_DEST_ERRORS" | grep -q "ORA-16191"; then
    TRANSPORT_STATUS="ORA-16191"
fi

if [[ "$TRANSPORT_STATUS" == "ORA-16191" ]]; then
    log_error "Redo transport is reporting ORA-16191 (password file / login credentials rejected)"
    log_error "This is the expected symptom until the standby's password file is refreshed - see the"
    log_error "ACTION REQUIRED instructions above. Copy the staged password file to the standby now."
    if [[ -n "$ARCHIVE_DEST_ERRORS" ]]; then
        echo ""
        echo "Archive destination errors:"
        echo "$ARCHIVE_DEST_ERRORS"
    fi
else
    # M12: absence of ORA-16191 immediately after rotation is EXPECTED, not
    # proof the standby's copy is already refreshed - existing transport
    # connections stay authenticated on the password already in use and
    # only fail on the *next* reconnect/restart. Word this so it doesn't
    # contradict the ACTION REQUIRED block above.
    log_info "No ORA-16191 transport errors detected yet - expected right after rotation, since existing"
    log_info "transport connections stay authenticated until they reconnect. Install the staged password"
    log_info "file on the standby (see ACTION REQUIRED above) before the next reconnect or restart."
fi

# ============================================================
# Summary
# ============================================================

if [[ "$SYS_LOCK_FAILED" -eq 1 ]]; then
    print_summary "ERROR" "SYS password rotated but ACCOUNT LOCK failed - SYS is UNLOCKED with an unrecorded password; run 'ALTER USER SYS ACCOUNT LOCK;' manually (see ACTION REQUIRED above)"
elif [[ "$TRANSPORT_STATUS" == "ORA-16191" ]]; then
    print_summary "ERROR" "Security hardening applied, but redo transport is failing with ORA-16191 until the standby's password file is refreshed"
else
    print_summary "SUCCESS" "Security hardening complete"
fi
print_status_block "Security State" \
    "Database" "$DB_UNIQUE_NAME" \
    "Database Role" "$DB_ROLE" \
    "SYS Account Status" "$ACCOUNT_STATUS" \
    "OS Authentication" "$(if echo "$TEST_RESULT" | grep -q "OS_AUTH_OK"; then echo OK; else echo CHECK_MANUALLY; fi)" \
    "Redo Transport" "$TRANSPORT_STATUS"

if [[ "$SYS_LOCK_FAILED" -eq 1 ]]; then
    print_list_block "Completed Actions" \
        "Changed the SYS password to a random value that is not stored." \
        "ACCOUNT LOCK failed - SYS is still unlocked (see ACTION REQUIRED above)." \
        "Staged the refreshed password file on the NFS share for the standby."
else
    print_list_block "Completed Actions" \
        "Changed the SYS password to a random value that is not stored." \
        "Locked the SYS account." \
        "Staged the refreshed password file on the NFS share for the standby."
fi

if [[ "$SYS_LOCK_FAILED" -eq 1 ]]; then
    print_list_block "Important Notes" \
        "Use OS authentication for DBA access right now: sqlplus / as sysdba" \
        "SYS is UNLOCKED with a freshly-rotated, unrecorded password - lock it manually (see ACTION REQUIRED above)." \
        "Redo transport will fail with ORA-16191 on the next reconnect/restart until the standby's password file is refreshed." \
        "Consider locking other privileged accounts such as SYSTEM."
elif [[ "$TRANSPORT_STATUS" == "ORA-16191" ]]; then
    print_list_block "Important Notes" \
        "Use OS authentication for future DBA access: sqlplus / as sysdba" \
        "Redo transport is currently BROKEN (ORA-16191) - install the staged password file on the standby now (see ACTION REQUIRED above)." \
        "To unlock SYS later: ALTER USER SYS ACCOUNT UNLOCK; ALTER USER SYS IDENTIFIED BY '<new_password>';" \
        "Consider locking other privileged accounts such as SYSTEM."
else
    print_list_block "Important Notes" \
        "Use OS authentication for future DBA access: sqlplus / as sysdba" \
        "Redo transport will fail with ORA-16191 on the next reconnect/restart until the standby's password file is refreshed (see ACTION REQUIRED above)." \
        "To unlock SYS later: ALTER USER SYS ACCOUNT UNLOCK; ALTER USER SYS IDENTIFIED BY '<new_password>';" \
        "Consider locking other privileged accounts such as SYSTEM."
fi

# Fail loudly (non-zero exit) when redo transport is confirmed broken, or
# when SYS was rotated but left unlocked, so automation/orchestration
# notices immediately - even though the account change itself already
# succeeded (fully or partially) and cannot be rolled back from here.
if [[ "$SYS_LOCK_FAILED" -eq 1 || "$TRANSPORT_STATUS" == "ORA-16191" ]]; then
    exit 1
fi
