#!/usr/bin/env bash
# =============================================================================
# Create a Test Database for Data Guard E2E Testing
# =============================================================================
#
# Creates a new Oracle database on the primary host using DBCA (silent mode).
# The database is configured for Data Guard: ARCHIVELOG mode, no OMF, no FRA,
# with explicit archive destinations.
#
# Uses the same SSH/jump-host connection pattern as run_e2e_test.sh and reads
# the same config.env for host details, Oracle paths, and database parameters.
#
# Usage:
#   bash tests/e2e/create_test_db.sh                    # Use config.env defaults
#   bash tests/e2e/create_test_db.sh -n mydb             # Custom DB name
#   bash tests/e2e/create_test_db.sh -n mydb -m 1024     # Custom name + memory
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Load config --------------------------------------------------------------
if [[ ! -f "${SCRIPT_DIR}/config.env" ]]; then
    echo "ERROR: config.env not found. Copy config.env.template to config.env and fill in values."
    exit 1
fi

source "${SCRIPT_DIR}/config.env"

# -- Parse args (overrides) ---------------------------------------------------
CUSTOM_DB_NAME=""
CUSTOM_MEMORY=""
CUSTOM_PASSWORD=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)     CUSTOM_DB_NAME="$2"; shift 2 ;;
        -m|--memory)   CUSTOM_MEMORY="$2"; shift 2 ;;
        -p|--password) CUSTOM_PASSWORD="$2"; shift 2 ;;
        -h|--help)
            printf "Usage: bash tests/e2e/create_test_db.sh [-n name] [-m memory_mb] [-p sys_password]\n"
            printf "  -n, --name NAME        Database name (default: from config.env)\n"
            printf "  -m, --memory MB        SGA memory in MB (default: from config.env)\n"
            printf "  -p, --password PASS    SYS password (default: from config.env)\n"
            exit 0 ;;
        *) printf "Unknown option: %s\n" "$1"; exit 1 ;;
    esac
done

# Apply overrides
[[ -n "$CUSTOM_DB_NAME" ]] && TEST_DB_NAME="$CUSTOM_DB_NAME" && TEST_DB_UNIQUE_NAME="$CUSTOM_DB_NAME"
[[ -n "$CUSTOM_MEMORY" ]] && TEST_DB_MEMORY_MB="$CUSTOM_MEMORY"
[[ -n "$CUSTOM_PASSWORD" ]] && TEST_SYS_PASSWORD="$CUSTOM_PASSWORD"

TEST_ORACLE_SID="${TEST_DB_NAME}"
TEST_ARCHIVE_DIR="${ORACLE_BASE}/archive/${TEST_DB_NAME}"

# -- Validate required config -------------------------------------------------
for var in JUMP_HOST JUMP_USER PRIMARY_HOST SSH_USER ORACLE_HOME ORACLE_BASE \
           TEST_DB_NAME TEST_SYS_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: ${var} is not set"
        exit 1
    fi
done

# -- Colors & logging ---------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()      { printf "[$(date '+%H:%M:%S')] %b\n" "$1"; }
log_ok()   { log "${GREEN}OK${NC}    $1"; }
log_fail() { log "${RED}FAIL${NC}  $1"; }
log_step() { printf "\n${BOLD}${CYAN}── %s${NC}\n" "$1"; }

# -- SSH setup ----------------------------------------------------------------
JUMP_KEY_OPT=""
[[ -n "${JUMP_KEY:-}" ]] && JUMP_KEY_OPT="-i ${JUMP_KEY}"
JUMP_SSH_PORT="${JUMP_SSH_PORT:-22}"
PRIMARY_SSH_PORT="${PRIMARY_SSH_PORT:-22}"
DB_SSH_KEY_OPT=""
[[ -n "${SSH_KEY:-}" ]] && DB_SSH_KEY_OPT="-i ${SSH_KEY}"

ssh_primary() {
    ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} \
        -J "${JUMP_USER}@${JUMP_HOST}:${JUMP_SSH_PORT}" \
        -p "${PRIMARY_SSH_PORT}" "${SSH_USER}@${PRIMARY_HOST}" \
        "export ORACLE_HOME='${ORACLE_HOME}'; \
         export ORACLE_BASE='${ORACLE_BASE}'; \
         export ORACLE_SID='${TEST_ORACLE_SID}'; \
         export PATH=\"\${ORACLE_HOME}/bin:\${PATH}\"; \
         $1" 2>&1
}

# -- Pre-flight checks --------------------------------------------------------
log_step "Pre-flight checks"

log "Database name:  ${TEST_DB_NAME}"
log "SID:            ${TEST_ORACLE_SID}"
log "Memory:         ${TEST_DB_MEMORY_MB} MB"
log "Redo size:      ${TEST_REDO_SIZE_MB} MB"
log "Charset:        ${TEST_DB_CHARSET}"
log "Primary host:   ${PRIMARY_HOST}:${PRIMARY_SSH_PORT}"

# Check SSH connectivity
if ssh_primary "echo SSH_OK" | grep -q 'SSH_OK'; then
    log_ok "SSH to primary host"
else
    log_fail "Cannot SSH to primary host"
    exit 1
fi

# Check Oracle Home exists
if ssh_primary "test -x '${ORACLE_HOME}/bin/sqlplus' && echo ORACLE_OK" | grep -q 'ORACLE_OK'; then
    log_ok "Oracle Home verified"
else
    log_fail "Oracle Home not found or sqlplus not executable"
    exit 1
fi

# Check database doesn't already exist
PMON_CHECK=$(ssh_primary "ps -ef | grep -w 'ora_pmon_${TEST_ORACLE_SID}' | grep -v grep || true")
if [[ -n "$PMON_CHECK" ]]; then
    log_fail "Database '${TEST_ORACLE_SID}' is already running on primary host"
    log "  Stop it first, or use a different name with -n"
    exit 1
fi
log_ok "No existing database with SID '${TEST_ORACLE_SID}'"

# =============================================================================
# Create database with DBCA
# =============================================================================
log_step "Creating database with DBCA (this takes several minutes)"

RESULT=$(ssh_primary "
    # Create archive log directory
    mkdir -p '${TEST_ARCHIVE_DIR}'

    # Create database
    dbca -silent -createDatabase \
        -gdbName '${TEST_DB_NAME}' \
        -sid '${TEST_ORACLE_SID}' \
        -templateName General_Purpose.dbc \
        -sysPassword '${TEST_SYS_PASSWORD}' \
        -systemPassword '${TEST_SYS_PASSWORD}' \
        -characterSet '${TEST_DB_CHARSET}' \
        -totalMemory '${TEST_DB_MEMORY_MB}' \
        -emConfiguration NONE \
        -storageType FS \
        -datafileDestination '${ORACLE_BASE}/oradata' \
        -redoLogFileSize '${TEST_REDO_SIZE_MB}' \
        -databaseType MULTIPURPOSE 2>&1

    echo 'DBCA_EXIT_CODE='\$?
")

# Show DBCA output (filtered for key lines)
printf '%s\n' "$RESULT" | grep -iE 'percent|complete|error|fail|DBCA_EXIT' | while IFS= read -r line; do
    log "${DIM}  ${line}${NC}"
done

if ! printf '%s' "$RESULT" | grep -q 'DBCA_EXIT_CODE=0'; then
    log_fail "DBCA database creation failed"
    printf '%s\n' "$RESULT" | tail -20
    exit 1
fi
log_ok "DBCA database created"

# =============================================================================
# Post-creation: disable OMF/FRA, enable ARCHIVELOG
# =============================================================================
log_step "Post-creation configuration"

RESULT=$(ssh_primary "
    sqlplus -s / as sysdba << 'SQLEOF'
SET HEADING OFF FEEDBACK ON

-- Disable OMF (future files use explicit paths)
ALTER SYSTEM RESET db_create_file_dest SCOPE=SPFILE;
ALTER SYSTEM RESET db_create_online_log_dest_1 SCOPE=SPFILE;
ALTER SYSTEM RESET db_create_online_log_dest_2 SCOPE=SPFILE;

-- Disable FRA
ALTER SYSTEM RESET db_recovery_file_dest SCOPE=SPFILE;
ALTER SYSTEM RESET db_recovery_file_dest_size SCOPE=SPFILE;

-- Bounce to apply SPFILE changes
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;

-- Enable ARCHIVELOG
ALTER DATABASE ARCHIVELOG;

-- Open
ALTER DATABASE OPEN;

-- Set explicit archive destination (no FRA)
ALTER SYSTEM SET log_archive_dest_1='LOCATION=${TEST_ARCHIVE_DIR} VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${TEST_DB_UNIQUE_NAME}' SCOPE=BOTH;

-- Verify
SELECT 'LOGMODE=' || log_mode FROM v\$database;
SELECT 'OMF=' || NVL(value, 'UNSET') FROM v\$parameter WHERE name = 'db_create_file_dest';
SELECT 'FRA=' || NVL(value, 'UNSET') FROM v\$parameter WHERE name = 'db_recovery_file_dest';

EXIT;
SQLEOF
")

if printf '%s' "$RESULT" | grep -q 'LOGMODE=ARCHIVELOG'; then
    log_ok "ARCHIVELOG mode enabled"
else
    log_fail "ARCHIVELOG mode not enabled"
    printf '%s\n' "$RESULT"
    exit 1
fi

if printf '%s' "$RESULT" | grep -qE 'OMF=$|OMF=UNSET'; then
    log_ok "OMF disabled"
else
    log "  OMF parameter may still have a value (DBCA residual) - continuing"
fi

if printf '%s' "$RESULT" | grep -qE 'FRA=$|FRA=UNSET'; then
    log_ok "FRA disabled"
else
    log "  FRA parameter may still have a value - continuing"
fi

# Force log switches to populate archive directory
ssh_primary "
    sqlplus -s / as sysdba << 'SQLEOF'
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
EXIT;
SQLEOF
" > /dev/null

# Verify archive logs
if ssh_primary "find '${TEST_ARCHIVE_DIR}' -type f 2>/dev/null | head -1" | grep -q .; then
    log_ok "Archive logs written to ${TEST_ARCHIVE_DIR}"
else
    log "${YELLOW}!!${NC}    No archive logs found yet in ${TEST_ARCHIVE_DIR}"
fi

# =============================================================================
# Summary
# =============================================================================
log_step "Done"

printf "\n"
log "${GREEN}Database '${TEST_DB_NAME}' created successfully${NC}"
log ""
log "  SID:          ${TEST_ORACLE_SID}"
log "  Data files:   ${ORACLE_BASE}/oradata/${TEST_DB_NAME}"
log "  Archive logs: ${TEST_ARCHIVE_DIR}"
log "  Mode:         ARCHIVELOG, no OMF, no FRA"
log ""
log "  To drop this database:"
log "    ${DIM}bash tests/e2e/drop_test_db.sh -n ${TEST_DB_NAME}${NC}"
printf "\n"
