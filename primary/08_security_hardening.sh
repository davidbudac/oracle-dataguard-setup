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
if command -v openssl >/dev/null 2>&1; then
    RANDOM_PWD=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-32)
else
    RANDOM_PWD=$(od -An -tx1 -N 16 /dev/urandom | tr -d '[:space:]' | cut -c1-32)
fi

log_info "Changing SYS password and locking account..."
log_cmd "sqlplus / as sysdba:" "ALTER USER SYS IDENTIFIED BY '********'"
log_cmd "sqlplus / as sysdba:" "ALTER USER SYS ACCOUNT LOCK"

# Change SYS password and lock the account. WHENEVER SQLERROR EXIT
# SQL.SQLCODE ensures a failed password change (e.g. rejected by a password
# verify function) aborts BEFORE the ACCOUNT LOCK statement runs, so we
# never lock SYS while leaving the old password in place. The exit code
# (not a 'SUCCESS' marker in captured output) is the authoritative result.
confirm_approval_action "Run SQL command" "ALTER USER SYS IDENTIFIED BY ******** ; ALTER USER SYS ACCOUNT LOCK" || exit 1
pause_verbose_trace
SECURE_SYS_RC=0
sqlplus -s / as sysdba <<EOF || SECURE_SYS_RC=$?
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF VERIFY OFF
ALTER USER SYS IDENTIFIED BY "${RANDOM_PWD}";
ALTER USER SYS ACCOUNT LOCK;
EXIT SUCCESS;
EOF
resume_verbose_trace
if [[ "$SECURE_SYS_RC" -eq 0 ]]; then
    log_success "SYS account secured successfully"
else
    log_error "Failed to secure SYS account"
    log_error "Please secure manually:"
    log_error "  ALTER USER SYS IDENTIFIED BY '<random_password>';"
    log_error "  ALTER USER SYS ACCOUNT LOCK;"
    RANDOM_PWD=""
    unset RANDOM_PWD
    exit 1
fi

# Clear the password variable immediately
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

if [[ -f "$ORAPW_FILE" ]]; then
    log_info "Staging refreshed password file on the NFS share..."
    confirm_approval_action "Copy refreshed primary password file to NFS share" "cp $ORAPW_FILE $NFS_ORAPW_STAGING && chmod 600 $NFS_ORAPW_STAGING" || exit 1
    ( umask 077; cp "$ORAPW_FILE" "$NFS_ORAPW_STAGING" )
    chmod 600 "$NFS_ORAPW_STAGING"
    log_success "Password file staged at: $NFS_ORAPW_STAGING"
    record_artifact "password_file_hardened:${NFS_ORAPW_STAGING}"

    print_list_block "ACTION REQUIRED on STANDBY (${STANDBY_DB_UNIQUE_NAME})" \
        "Copy the refreshed password file from the NFS share to the standby's dbs directory:" \
        "  cp ${NFS_ORAPW_STAGING} <STANDBY_ORACLE_HOME>/dbs/orapw${STANDBY_ORACLE_SID}" \
        "  chmod 640 <STANDBY_ORACLE_HOME>/dbs/orapw${STANDBY_ORACLE_SID}" \
        "Until this is done, redo transport will fail with ORA-16191 on the next reconnect or restart."
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
    log_info "PASS: No ORA-16191 transport errors detected"
fi

# ============================================================
# Summary
# ============================================================

if [[ "$TRANSPORT_STATUS" == "ORA-16191" ]]; then
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

print_list_block "Completed Actions" \
    "Changed the SYS password to a random value that is not stored." \
    "Locked the SYS account." \
    "Staged the refreshed password file on the NFS share for the standby."

if [[ "$TRANSPORT_STATUS" == "ORA-16191" ]]; then
    print_list_block "Important Notes" \
        "Use OS authentication for future DBA access: sqlplus / as sysdba" \
        "Redo transport is currently BROKEN (ORA-16191) - install the staged password file on the standby now (see ACTION REQUIRED above)." \
        "To unlock SYS later: ALTER USER SYS ACCOUNT UNLOCK; ALTER USER SYS IDENTIFIED BY '<new_password>';" \
        "Consider locking other privileged accounts such as SYSTEM."
else
    print_list_block "Important Notes" \
        "Use OS authentication for future DBA access: sqlplus / as sysdba" \
        "Data Guard redo transport still works through the password file." \
        "To unlock SYS later: ALTER USER SYS ACCOUNT UNLOCK; ALTER USER SYS IDENTIFIED BY '<new_password>';" \
        "Consider locking other privileged accounts such as SYSTEM."
fi

# Fail loudly (non-zero exit) when redo transport is confirmed broken so
# automation/orchestration notices immediately, even though the account
# change itself already succeeded and cannot be rolled back from here.
if [[ "$TRANSPORT_STATUS" == "ORA-16191" ]]; then
    exit 1
fi
