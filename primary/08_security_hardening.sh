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

# ============================================================
# Main Script
# ============================================================

print_banner "Step 8: Security Hardening"

# Initialize logging
init_log "08_security_hardening"

# ============================================================
# Pre-flight Checks
# ============================================================

log_section "Pre-flight Checks"

check_oracle_env || exit 1
check_db_connection || exit 1

# Verify this is the primary database
DB_ROLE=$(run_sql "SELECT DATABASE_ROLE FROM V\$DATABASE;")
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
# Verify Data Guard Configuration
# ============================================================

log_section "Verifying Data Guard Configuration"

# Check if broker configuration exists and is healthy
CONFIG_STATUS=$("$ORACLE_HOME/bin/dgmgrl" -silent / "show configuration" 2>&1 || true)

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

log_section "Security Hardening Confirmation"

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

if ! confirm_proceed "Are you sure you want to proceed with security hardening?"; then
    log_info "Security hardening cancelled by user"
    exit 0
fi

# ============================================================
# Security Hardening
# ============================================================

log_section "Applying Security Hardening"

log_info "Generating random password..."

# Generate a random password (not displayed or logged anywhere)
# Using /dev/urandom for randomness, base64 for encoding, remove special chars
RANDOM_PWD=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -dc 'A-Za-z0-9' | head -c 32)

log_info "Changing SYS password and locking account..."
log_cmd "sqlplus / as sysdba:" "ALTER USER SYS IDENTIFIED BY '********'"
log_cmd "sqlplus / as sysdba:" "ALTER USER SYS ACCOUNT LOCK"

# Change SYS password and lock the account
SECURE_RESULT=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF VERIFY OFF
ALTER USER SYS IDENTIFIED BY "${RANDOM_PWD}";
ALTER USER SYS ACCOUNT LOCK;
SELECT 'SUCCESS' FROM DUAL;
EXIT;
EOF
)

# Clear the password variable immediately
RANDOM_PWD=""
unset RANDOM_PWD

if echo "$SECURE_RESULT" | grep -q "SUCCESS"; then
    log_info "SYS account secured successfully"
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

log_section "Verifying Security Changes"

# Check account status
ACCOUNT_STATUS=$(run_sql "SELECT ACCOUNT_STATUS FROM DBA_USERS WHERE USERNAME='SYS';")
ACCOUNT_STATUS=$(echo "$ACCOUNT_STATUS" | tr -d ' \n\r')

if [[ "$ACCOUNT_STATUS" == *"LOCKED"* ]]; then
    log_info "PASS: SYS account is locked (status: $ACCOUNT_STATUS)"
else
    log_warn "SYS account may not be fully locked (status: $ACCOUNT_STATUS)"
fi

# Verify OS authentication still works
log_info "Verifying OS authentication..."
TEST_RESULT=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF
SELECT 'OS_AUTH_OK' FROM DUAL;
EXIT;
EOF
)

if echo "$TEST_RESULT" | grep -q "OS_AUTH_OK"; then
    log_info "PASS: OS authentication '/ as sysdba' is working"
else
    log_error "OS authentication may not be working - please verify manually"
fi

# ============================================================
# Summary
# ============================================================

print_summary "SUCCESS" "Security hardening complete"

echo ""
echo "COMPLETED ACTIONS:"
echo "=================="
echo "  - Changed SYS password to random value (not stored)"
echo "  - Locked SYS account"
echo ""
echo "IMPORTANT NOTES:"
echo "================"
echo ""
echo "  1. Use OS authentication for all future DBA connections:"
echo "     sqlplus / as sysdba"
echo ""
echo "  2. Data Guard redo transport will continue to work"
echo "     (uses password file, not account password)"
echo ""
echo "  3. To unlock SYS if needed (requires OS authentication):"
echo "     ALTER USER SYS ACCOUNT UNLOCK;"
echo "     ALTER USER SYS IDENTIFIED BY '<new_password>';"
echo ""
echo "  4. Consider also locking other privileged accounts:"
echo "     ALTER USER SYSTEM ACCOUNT LOCK;"
echo ""
