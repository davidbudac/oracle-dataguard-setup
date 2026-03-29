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
init_progress 5

# Initialize logging
init_log "08_security_hardening"

# ============================================================
# Pre-flight Checks
# ============================================================

progress_step "Pre-flight Checks"

check_oracle_env || exit 1
check_db_connection || exit 1

# Verify this is the primary database
DB_ROLE=$(run_sql_query "get_db_role.sql")
DB_ROLE=$(echo "$DB_ROLE" | tr -d ' \n\r')

if [[ "$DB_ROLE" != "PRIMARY" ]]; then
    log_error "This script must be run on the PRIMARY database"
    log_error "Current database role: $DB_ROLE"
    exit 1
fi

log_info "Confirmed: Running on PRIMARY database"

# Get DB_UNIQUE_NAME for logging
DB_UNIQUE_NAME=$(get_db_parameter "db_unique_name")
init_log "08_security_hardening_${DB_UNIQUE_NAME}"

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

# Generate a random password (not displayed or logged anywhere)
# Using /dev/urandom for randomness, base64 for encoding, remove special chars
RANDOM_PWD=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -dc 'A-Za-z0-9' | head -c 32)

log_info "Changing SYS password and locking account..."
log_cmd "sqlplus / as sysdba:" "ALTER USER SYS IDENTIFIED BY '********'"
log_cmd "sqlplus / as sysdba:" "ALTER USER SYS ACCOUNT LOCK"

# Change SYS password and lock the account
SECURE_RESULT=$(run_sql_command "secure_sys_account.sql" "$RANDOM_PWD")

# Clear the password variable immediately
RANDOM_PWD=""
unset RANDOM_PWD

if echo "$SECURE_RESULT" | grep -q "SUCCESS"; then
log_success "SYS account secured successfully"
else
    log_error "Failed to secure SYS account"
    log_error "Please secure manually:"
    log_error "  ALTER USER SYS IDENTIFIED BY '<random_password>';"
    log_error "  ALTER USER SYS ACCOUNT LOCK;"
    exit 1
fi

# ============================================================
# Verify Changes
# ============================================================

progress_step "Verifying Security Changes"

# Check account status
ACCOUNT_STATUS=$(run_sql_query "get_sys_account_status.sql")
ACCOUNT_STATUS=$(echo "$ACCOUNT_STATUS" | tr -d ' \n\r')

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
# Summary
# ============================================================

print_summary "SUCCESS" "Security hardening complete"
print_status_block "Security State" \
    "Database" "$DB_UNIQUE_NAME" \
    "Database Role" "$DB_ROLE" \
    "SYS Account Status" "$ACCOUNT_STATUS" \
    "OS Authentication" "$(if echo "$TEST_RESULT" | grep -q "OS_AUTH_OK"; then echo OK; else echo CHECK_MANUALLY; fi)"

print_list_block "Completed Actions" \
    "Changed the SYS password to a random value that is not stored." \
    "Locked the SYS account."

print_list_block "Important Notes" \
    "Use OS authentication for future DBA access: sqlplus / as sysdba" \
    "Data Guard redo transport still works through the password file." \
    "To unlock SYS later: ALTER USER SYS ACCOUNT UNLOCK; ALTER USER SYS IDENTIFIED BY '<new_password>';" \
    "Consider locking other privileged accounts such as SYSTEM."
