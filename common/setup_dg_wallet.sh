#!/usr/bin/env bash
# =============================================================================
# Oracle Data Guard - Wallet Setup for Primary/Standby Connectivity
# =============================================================================
#
# Creates (or updates) an Oracle auto-login wallet with SYS credentials
# for connecting to the peer database. Run this on each DB host (primary
# and standby) so that scripts like dg_check_sid.sh can connect to the
# peer without prompting for a password.
#
# What it does:
#   1. Detects the local database role (primary or standby) from V$DATABASE
#   2. Discovers the peer TNS alias from the DG Broker
#   3. Creates an auto-login wallet (or adds to an existing one)
#   4. Stores SYS credentials for both local and peer TNS aliases
#   5. Configures sqlnet.ora to use the wallet
#   6. Tests the wallet connection to the peer
#
# Prerequisites:
#   - ORACLE_HOME and ORACLE_SID set, sqlplus / as sysdba working
#   - DG Broker running (dg_broker_start = TRUE)
#   - TNS entries for both databases in tnsnames.ora
#   - mkstore available in $ORACLE_HOME/bin
#
# Usage:
#   bash common/setup_dg_wallet.sh              # Default wallet location
#   bash common/setup_dg_wallet.sh -w /path     # Custom wallet directory
#
# =============================================================================

set -uo pipefail

# -- Colors & helpers ---------------------------------------------------------
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
CYAN='\033[0;36m';   BOLD='\033[1m';      DIM='\033[2m';  NC='\033[0m'

info()  { printf " ${GREEN}[INFO]${NC}  %s\n" "$1"; }
warn()  { printf " ${YELLOW}[WARN]${NC}  %s\n" "$1"; }
error() { printf " ${RED}[ERROR]${NC} %s\n" "$1"; }
step()  { printf "\n ${BOLD}${CYAN}── %s${NC}\n" "$1"; }

prompt_password() {
    local prompt_text="$1"
    printf " ${YELLOW}%s${NC}: " "$prompt_text" >&2
    stty -echo 2>/dev/null || true
    local password
    read -r password
    stty echo 2>/dev/null || true
    printf "\n" >&2
    printf '%s' "$password"
}

run_local_sql() {
    sqlplus -s / as sysdba <<SQL
SET HEADING OFF FEEDBACK OFF LINESIZE 300 PAGESIZE 0 TRIMSPOOL ON
$1
EXIT;
SQL
}

# -- Parse args ---------------------------------------------------------------
WALLET_DIR=""
AUTO_PASSWORD=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--wallet-dir) WALLET_DIR="$2"; shift 2 ;;
        -A|--auto-password) AUTO_PASSWORD=true; shift ;;
        -h|--help)
            printf "Usage: bash common/setup_dg_wallet.sh [-w wallet_dir] [-A]\n"
            printf "  -w, --wallet-dir DIR   Wallet directory (default: \$ORACLE_HOME/network/admin)\n"
            printf "  -A, --auto-password    Generate wallet password automatically (no prompt)\n"
            printf "                         The auto-login wallet handles all connections;\n"
            printf "                         to modify the wallet later, re-run this script\n"
            exit 0 ;;
        *) printf "Unknown option: %s\n" "$1"; exit 1 ;;
    esac
done

generate_random_password() {
    # Generate a random 24-char password (AIX compatible — no /dev/urandom dependency)
    local pw=""
    pw=$(printf '%s%s%s' "$(date '+%N%s')" "$$" "${RANDOM:-0}" | cksum | awk '{print $1}')
    pw="Wlt_${pw}_$(printf '%05d' "$$")Aa1"
    printf '%s' "$pw"
}

# -- Verify Oracle environment ------------------------------------------------
if [[ -z "${ORACLE_SID:-}" ]]; then
    error "ORACLE_SID is not set"
    exit 1
fi
if [[ -z "${ORACLE_HOME:-}" ]]; then
    error "ORACLE_HOME is not set"
    exit 1
fi
export PATH="${ORACLE_HOME}/bin:${PATH}"

if [[ ! -x "${ORACLE_HOME}/bin/mkstore" ]]; then
    error "mkstore not found: ${ORACLE_HOME}/bin/mkstore"
    exit 1
fi

# Default wallet location
if [[ -z "$WALLET_DIR" ]]; then
    WALLET_DIR="${ORACLE_HOME}/network/admin"
fi

printf "\n ${BOLD}${CYAN}Data Guard Wallet Setup${NC}\n"
printf " ${DIM}SID: %s  |  ORACLE_HOME: %s${NC}\n" "$ORACLE_SID" "$ORACLE_HOME"
printf " ${DIM}Wallet: %s${NC}\n" "$WALLET_DIR"

# =============================================================================
# 1. Detect local role and peer from broker
# =============================================================================
step "Detecting Data Guard configuration"

LOCAL_SQL=$(run_local_sql "
SELECT 'DBSTATUS|' || DATABASE_ROLE || '|' || DB_UNIQUE_NAME FROM V\$DATABASE;
SELECT 'BROKER|' || VALUE FROM V\$PARAMETER WHERE NAME = 'dg_broker_start';
")

LOC_ROLE=$(printf '%s\n' "$LOCAL_SQL" | grep '^DBSTATUS|' | head -1 | awk -F'|' '{print $2}' | xargs)
LOC_DBUNIQ=$(printf '%s\n' "$LOCAL_SQL" | grep '^DBSTATUS|' | head -1 | awk -F'|' '{print $3}' | xargs)
LOC_BROKER=$(printf '%s\n' "$LOCAL_SQL" | grep '^BROKER|' | head -1 | awk -F'|' '{print $2}' | xargs)

if [[ -z "${LOC_ROLE:-}" ]]; then
    error "Cannot determine database role from V\$DATABASE"
    exit 1
fi

info "Local database: ${LOC_DBUNIQ} (role: ${LOC_ROLE})"

if ! printf '%s' "${LOC_BROKER:-}" | grep -qi "TRUE"; then
    error "DG Broker is not running (dg_broker_start = ${LOC_BROKER:-FALSE})"
    error "Start the broker first: ALTER SYSTEM SET dg_broker_start = TRUE"
    exit 1
fi

# Get broker configuration
DGMGRL_CONFIG=$(dgmgrl -silent / 'SHOW CONFIGURATION' 2>&1)

if printf '%s' "$DGMGRL_CONFIG" | grep -q "ORA-16532\|not yet available\|not exist"; then
    error "No broker configuration found"
    error "Configure the broker first (primary/06_configure_broker.sh)"
    exit 1
fi

# Find peer database unique name
if printf '%s' "$LOC_ROLE" | grep -qi "PRIMARY"; then
    PEER_DBUNIQ=$(printf '%s\n' "$DGMGRL_CONFIG" | grep -i 'Physical standby' | head -1 | awk '{print $1}')
    PEER_LABEL="standby"
else
    PEER_DBUNIQ=$(printf '%s\n' "$DGMGRL_CONFIG" | grep -i 'Primary database' | head -1 | awk '{print $1}')
    PEER_LABEL="primary"
fi

if [[ -z "${PEER_DBUNIQ:-}" ]]; then
    error "Cannot find peer database in broker configuration"
    exit 1
fi

# Get TNS aliases from broker (DGConnectIdentifier)
LOC_TNS_RAW=$(dgmgrl -silent / "SHOW DATABASE '${LOC_DBUNIQ}' 'DGConnectIdentifier'" 2>&1)
LOC_TNS=$(printf '%s\n' "$LOC_TNS_RAW" | grep 'DGConnectIdentifier' | sed "s/.*= *'//" | sed "s/'.*//")

PEER_TNS_RAW=$(dgmgrl -silent / "SHOW DATABASE '${PEER_DBUNIQ}' 'DGConnectIdentifier'" 2>&1)
PEER_TNS=$(printf '%s\n' "$PEER_TNS_RAW" | grep 'DGConnectIdentifier' | sed "s/.*= *'//" | sed "s/'.*//")

if [[ -z "${PEER_TNS:-}" ]]; then
    error "Cannot determine peer TNS alias from broker"
    exit 1
fi

info "Peer database: ${PEER_DBUNIQ} (${PEER_LABEL}, TNS: ${PEER_TNS})"
[[ -n "${LOC_TNS:-}" ]] && info "Local TNS alias: ${LOC_TNS}"

# =============================================================================
# 2. Verify SYS password against peer
# =============================================================================
step "Verifying SYS credentials"

SYS_PASSWORD=$(prompt_password "Enter SYS password (for both databases)")

if [[ -z "$SYS_PASSWORD" ]]; then
    error "SYS password cannot be empty"
    exit 1
fi

info "Testing connection to ${PEER_LABEL} (${PEER_TNS})..."
PEER_TEST=$(printf "SET HEADING OFF FEEDBACK OFF\nSELECT 'PEER_OK' FROM DUAL;\nEXIT;\n" | \
    sqlplus -s "sys/${SYS_PASSWORD}@${PEER_TNS} as sysdba" 2>&1)

if ! printf '%s' "$PEER_TEST" | grep -q 'PEER_OK'; then
    error "Cannot connect to ${PEER_LABEL} via sys@${PEER_TNS}"
    error "Check that the TNS entry exists in tnsnames.ora and the password is correct"
    printf " ${DIM}sqlplus output: %s${NC}\n" "$(printf '%s' "$PEER_TEST" | head -3)"
    unset SYS_PASSWORD
    exit 1
fi
info "Connection to ${PEER_LABEL} verified"

# Also test local TNS alias if available
if [[ -n "${LOC_TNS:-}" ]]; then
    info "Testing connection to local TNS alias (${LOC_TNS})..."
    LOC_TEST=$(printf "SET HEADING OFF FEEDBACK OFF\nSELECT 'LOC_OK' FROM DUAL;\nEXIT;\n" | \
        sqlplus -s "sys/${SYS_PASSWORD}@${LOC_TNS} as sysdba" 2>&1)

    if ! printf '%s' "$LOC_TEST" | grep -q 'LOC_OK'; then
        warn "Cannot connect via local TNS alias (${LOC_TNS})"
        warn "Local credential will be added but may not work until TNS is fixed"
    else
        info "Local TNS connection verified"
    fi
fi

# =============================================================================
# 3. Create or open wallet
# =============================================================================
step "Setting up wallet"

WALLET_PASSWORD=""

CREATE_NEW_WALLET=false

if [[ -f "${WALLET_DIR}/ewallet.p12" ]]; then
    info "Existing wallet found at: ${WALLET_DIR}"

    if $AUTO_PASSWORD; then
        info "Auto-password mode: recreating wallet (existing wallet requires its password)"
        BACKUP_DIR="${WALLET_DIR}.bak.$(date '+%Y%m%d_%H%M%S')"
        mv "$WALLET_DIR" "$BACKUP_DIR"
        info "Backed up existing wallet to: ${BACKUP_DIR}"
        CREATE_NEW_WALLET=true
    else
        info "Credentials will be added/updated in the existing wallet"

        WALLET_PASSWORD=$(prompt_password "Enter existing wallet password")

        if [[ -z "$WALLET_PASSWORD" ]]; then
            error "Wallet password cannot be empty"
            unset SYS_PASSWORD
            exit 1
        fi

        # Verify wallet password by listing contents
        VERIFY_OUT=$("$ORACLE_HOME/bin/mkstore" -wrl "$WALLET_DIR" -listCredential <<EOF 2>&1
${WALLET_PASSWORD}
EOF
        )
        if printf '%s' "$VERIFY_OUT" | grep -qi "error\|failed\|incorrect\|denied"; then
            error "Invalid wallet password"
            unset SYS_PASSWORD WALLET_PASSWORD
            exit 1
        fi
        info "Wallet password verified"

        # Show existing credentials
        info "Current wallet entries:"
        printf '%s\n' "$VERIFY_OUT" | grep -i 'oracle.security.client.connect_string' | while IFS= read -r line; do
            printf "   ${DIM}%s${NC}\n" "$line"
        done
    fi
else
    CREATE_NEW_WALLET=true
fi

if $CREATE_NEW_WALLET; then
    info "Creating new auto-login wallet"

    mkdir -p "$WALLET_DIR"
    chmod 700 "$WALLET_DIR"

    if $AUTO_PASSWORD; then
        WALLET_PASSWORD=$(generate_random_password)
        info "Auto-generated wallet password (auto-login; password not needed for connections)"
        info "To modify this wallet later, re-run with -A to recreate it"
    else
        WALLET_PASSWORD=$(prompt_password "Enter new wallet password (protects the wallet file)")
        if [[ -z "$WALLET_PASSWORD" ]]; then
            error "Wallet password cannot be empty"
            unset SYS_PASSWORD
            exit 1
        fi

        WALLET_PASSWORD_CONFIRM=$(prompt_password "Confirm wallet password")
        if [[ "$WALLET_PASSWORD" != "$WALLET_PASSWORD_CONFIRM" ]]; then
            error "Passwords do not match"
            unset SYS_PASSWORD WALLET_PASSWORD WALLET_PASSWORD_CONFIRM
            exit 1
        fi
        unset WALLET_PASSWORD_CONFIRM
    fi

    # Create the wallet (ewallet.p12)
    "$ORACLE_HOME/bin/mkstore" -wrl "$WALLET_DIR" -create <<EOF
${WALLET_PASSWORD}
${WALLET_PASSWORD}
EOF

    if [[ $? -ne 0 ]]; then
        error "Failed to create wallet"
        unset SYS_PASSWORD WALLET_PASSWORD
        exit 1
    fi

    # Enable auto-login (creates cwallet.sso — no password needed at connect time)
    "$ORACLE_HOME/bin/mkstore" -wrl "$WALLET_DIR" -createSSO <<EOF
${WALLET_PASSWORD}
EOF

    info "Auto-login wallet created at: ${WALLET_DIR}"
fi

# =============================================================================
# 4. Add credentials
# =============================================================================
step "Adding credentials"

add_credential() {
    local tns_alias="$1" username="$2" password="$3" label="$4"

    # Try to delete existing entry (ignore errors if it doesn't exist)
    "$ORACLE_HOME/bin/mkstore" -wrl "$WALLET_DIR" -deleteCredential "$tns_alias" <<EOF 2>/dev/null
${WALLET_PASSWORD}
EOF

    # Add the credential
    "$ORACLE_HOME/bin/mkstore" -wrl "$WALLET_DIR" -createCredential "$tns_alias" "$username" "$password" <<EOF
${WALLET_PASSWORD}
EOF

    if [[ $? -ne 0 ]]; then
        error "Failed to add credential for ${tns_alias}"
        return 1
    fi
    info "Added credential: ${tns_alias} (${label}, user: ${username})"
}

# Add peer credential
add_credential "$PEER_TNS" "sys" "$SYS_PASSWORD" "${PEER_LABEL}" || {
    unset SYS_PASSWORD WALLET_PASSWORD
    exit 1
}

# Add local credential (if TNS alias is available and different from peer)
if [[ -n "${LOC_TNS:-}" ]] && [[ "$LOC_TNS" != "$PEER_TNS" ]]; then
    add_credential "$LOC_TNS" "sys" "$SYS_PASSWORD" "local" || {
        unset SYS_PASSWORD WALLET_PASSWORD
        exit 1
    }
fi

# Clear passwords from memory
unset SYS_PASSWORD WALLET_PASSWORD

# =============================================================================
# 5. Configure sqlnet.ora
# =============================================================================
step "Configuring sqlnet.ora"

SQLNET_FILE="${ORACLE_HOME}/network/admin/sqlnet.ora"

WALLET_CONFIG="
# Oracle Wallet Configuration (added for Data Guard connectivity)
WALLET_LOCATION = (SOURCE = (METHOD = FILE) (METHOD_DATA = (DIRECTORY = ${WALLET_DIR})))
SQLNET.WALLET_OVERRIDE = TRUE
"

if [[ -f "$SQLNET_FILE" ]]; then
    if grep -q "WALLET_LOCATION" "$SQLNET_FILE"; then
        # Check if it points to our wallet directory
        EXISTING_DIR=$(grep "DIRECTORY" "$SQLNET_FILE" | sed 's/.*DIRECTORY *= *//' | sed 's/[)].*//' | xargs)
        if [[ "$EXISTING_DIR" == "$WALLET_DIR" ]]; then
            info "sqlnet.ora already configured for: ${WALLET_DIR}"
        else
            warn "sqlnet.ora has WALLET_LOCATION pointing to: ${EXISTING_DIR}"
            warn "Expected: ${WALLET_DIR}"
            warn "Please update manually if needed"
        fi
    else
        # Backup and append
        cp "$SQLNET_FILE" "${SQLNET_FILE}.bak.$(date '+%Y%m%d_%H%M%S')"
        printf '%s\n' "$WALLET_CONFIG" >> "$SQLNET_FILE"
        info "Added wallet configuration to sqlnet.ora"
        info "Backup saved: ${SQLNET_FILE}.bak.*"
    fi
else
    printf '%s\n' "$WALLET_CONFIG" > "$SQLNET_FILE"
    info "Created sqlnet.ora with wallet configuration"
fi

# =============================================================================
# 6. Test wallet connection
# =============================================================================
step "Testing wallet connection"

info "Connecting to ${PEER_LABEL} via wallet: sqlplus /@${PEER_TNS} as sysdba"
WALLET_TEST=$(printf "SET HEADING OFF FEEDBACK OFF\nSELECT 'WALLET_OK' FROM DUAL;\nEXIT;\n" | \
    sqlplus -s "/@${PEER_TNS}" as sysdba 2>&1)

if printf '%s' "$WALLET_TEST" | grep -q 'WALLET_OK'; then
    info "Wallet connection to ${PEER_LABEL} (${PEER_TNS}) successful"
else
    warn "Wallet connection to ${PEER_LABEL} (${PEER_TNS}) failed"
    warn "This may be expected if SQLNET.WALLET_OVERRIDE was just added"
    warn "Try reconnecting or restart the listener, then test with:"
    printf "   ${DIM}sqlplus /@%s as sysdba${NC}\n" "$PEER_TNS"
fi

if [[ -n "${LOC_TNS:-}" ]] && [[ "$LOC_TNS" != "$PEER_TNS" ]]; then
    info "Connecting to local via wallet: sqlplus /@${LOC_TNS} as sysdba"
    LOC_WALLET_TEST=$(printf "SET HEADING OFF FEEDBACK OFF\nSELECT 'WALLET_OK' FROM DUAL;\nEXIT;\n" | \
        sqlplus -s "/@${LOC_TNS}" as sysdba 2>&1)

    if printf '%s' "$LOC_WALLET_TEST" | grep -q 'WALLET_OK'; then
        info "Wallet connection to local (${LOC_TNS}) successful"
    else
        warn "Wallet connection to local (${LOC_TNS}) failed"
    fi
fi

# =============================================================================
# Summary
# =============================================================================
step "Summary"

printf "\n"
info "Wallet directory: ${WALLET_DIR}"
info "Credentials stored for:"
printf "   ${GREEN}%-25s${NC} %s (SYS)\n" "${PEER_TNS}" "${PEER_LABEL} - ${PEER_DBUNIQ}"
if [[ -n "${LOC_TNS:-}" ]] && [[ "$LOC_TNS" != "$PEER_TNS" ]]; then
    printf "   ${GREEN}%-25s${NC} %s (SYS)\n" "${LOC_TNS}" "local - ${LOC_DBUNIQ}"
fi
printf "\n"
info "You can now connect without a password:"
printf "   ${DIM}sqlplus /@%s as sysdba${NC}\n" "$PEER_TNS"
[[ -n "${LOC_TNS:-}" ]] && [[ "$LOC_TNS" != "$PEER_TNS" ]] && \
    printf "   ${DIM}sqlplus /@%s as sysdba${NC}\n" "$LOC_TNS"
printf "\n"
info "Run this script on the ${PEER_LABEL} host too for bidirectional wallet auth"
printf "\n"
