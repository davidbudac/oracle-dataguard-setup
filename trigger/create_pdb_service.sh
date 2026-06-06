#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Create a Role-Aware PDB Service
# ============================================================
# Run this script on the PRIMARY database server.
#
# Creates a database service INSIDE a pluggable database (PDB) so
# it can be used as a Data Guard switchover / failover service:
# the service runs only on whichever side currently holds the
# PRIMARY role and follows the database after a role change.
#
# What this script does:
#   - Verifies it is running on the PRIMARY of a CDB
#   - Verifies the target PDB exists and is OPEN READ WRITE
#   - Creates the service in that PDB (idempotent; skips if present)
#   - Starts the service on the primary
#   - Optionally sets basic TAF attributes (--taf)
#
# Role-awareness itself is provided by the DG_SERVICE_MGR trigger
# (trigger/create_role_trigger_cdb.sh): it starts the service on
# PRIMARY and stops it on STANDBY. This script does NOT save PDB
# state, so the service does not auto-start independently of role.
# After creating the service, (re-)run create_role_trigger_cdb.sh
# so the trigger manages it across switchover/failover.
#
# The service definition is stored in the PDB data dictionary and
# replicates to the standby via redo apply.
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source common functions
source "${COMMON_DIR}/dg_functions.sh"
enable_verbose_mode "$@"

usage() {
    cat <<USAGE
Usage:
  bash trigger/create_pdb_service.sh --pdb <PDB_NAME> --service <SERVICE_NAME> [options]
  bash trigger/create_pdb_service.sh <PDB_NAME> <SERVICE_NAME> [options]

Required:
  -p, --pdb NAME         Target pluggable database name
      --service NAME     Service (network) name to create

Options:
      --no-start         Create the service but do not start it
      --taf              Set basic TAF (FAILOVER_TYPE=SELECT, METHOD=BASIC)
  -v, --verbose          Verbose output
  -h, --help             Show this help

Notes:
  - Run on the PRIMARY of a CDB; the PDB must be OPEN READ WRITE.
  - After creating, (re-)run trigger/create_role_trigger_cdb.sh so the
    service is started on PRIMARY and stopped on STANDBY automatically.
USAGE
}

# ============================================================
# Parse Arguments
# ============================================================

PDB_NAME=""
SERVICE_NAME=""
DO_START=true
ENABLE_TAF=false
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--pdb)     PDB_NAME="$2"; shift 2 ;;
        --service)    SERVICE_NAME="$2"; shift 2 ;;
        --no-start)   DO_START=false; shift ;;
        --taf)        ENABLE_TAF=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        # Global flags consumed by enable_verbose_mode - accept as no-ops
        -v|--verbose|--no-verbose|-a|--approval-mode|--no-approval-mode) shift ;;
        -s|--suspicious|--no-suspicious|-n|--check|--plan|--execute)     shift ;;
        -*)           printf "Unknown option: %s\n\n" "$1"; usage; exit 1 ;;
        *)            POSITIONAL+=("$1"); shift ;;
    esac
done

# Positional fallback: fill any slot not already set by a flag, in the
# order <PDB_NAME> then <SERVICE_NAME>.
pos_idx=0
if [[ -z "$PDB_NAME" && $pos_idx -lt ${#POSITIONAL[@]} ]]; then
    PDB_NAME="${POSITIONAL[$pos_idx]}"; pos_idx=$((pos_idx + 1))
fi
if [[ -z "$SERVICE_NAME" && $pos_idx -lt ${#POSITIONAL[@]} ]]; then
    SERVICE_NAME="${POSITIONAL[$pos_idx]}"; pos_idx=$((pos_idx + 1))
fi

PDB_NAME=$(echo "$PDB_NAME" | tr -d ' \n\r')
SERVICE_NAME=$(echo "$SERVICE_NAME" | tr -d ' \n\r')

# ============================================================
# Main Script
# ============================================================

print_banner "Create Role-Aware PDB Service"

init_log "create_pdb_service"

# ============================================================
# Validate Arguments
# ============================================================

log_section "Validating Arguments"

if [[ -z "$PDB_NAME" ]] || [[ -z "$SERVICE_NAME" ]]; then
    log_error "Both a PDB name and a service name are required"
    echo ""
    usage
    exit 1
fi

# Service names: letters, numbers, underscore, dot, dollar
if ! echo "$SERVICE_NAME" | grep -q '^[A-Za-z0-9_.$]*$'; then
    log_error "Invalid service name: $SERVICE_NAME"
    log_error "Service names may only contain letters, numbers, underscore, dot, and dollar sign"
    exit 1
fi
if [[ ${#SERVICE_NAME} -gt 64 ]]; then
    log_error "Service name too long (max 64 chars): $SERVICE_NAME"
    exit 1
fi

# Container names: letters, numbers, underscore, dollar, hash
if ! echo "$PDB_NAME" | grep -q '^[A-Za-z0-9_$#]*$'; then
    log_error "Invalid PDB name: $PDB_NAME"
    exit 1
fi

log_info "PDB:     $PDB_NAME"
log_info "Service: $SERVICE_NAME"

# ============================================================
# Pre-flight Checks
# ============================================================

log_section "Pre-flight Checks"

check_oracle_env || exit 1
check_db_connection || exit 1

# ============================================================
# Verify Role, CDB, and Target PDB
# ============================================================

log_section "Verifying Database Role and Target PDB"

DB_ROLE=$(run_sql_query "get_db_role.sql")
DB_ROLE=$(echo "$DB_ROLE" | tr -d ' \n\r')

if [[ "$DB_ROLE" != "PRIMARY" ]]; then
    log_error "This script must be run on the PRIMARY database"
    log_error "Current database role: $DB_ROLE"
    log_error "Services for Data Guard must be created on the primary; they replicate via redo."
    exit 1
fi
log_info "Confirmed: Running on PRIMARY database"

IS_CDB=$(sqlplus -s / as sysdba << 'EOSQL'
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT CDB FROM V$DATABASE;
EXIT;
EOSQL
)
IS_CDB=$(echo "$IS_CDB" | tr -d ' \n\r')

if [[ "$IS_CDB" != "YES" ]]; then
    log_error "This database is not a CDB (V\$DATABASE.CDB = ${IS_CDB:-unknown})"
    log_error "This script creates services inside a PDB; it requires a multitenant database."
    exit 1
fi
log_info "Confirmed: Container Database (CDB)"

# Discover the canonical PDB name and its open mode
PDB_INFO=$(sqlplus -s / as sysdba << EOSQL
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT 'PDBNAME=' || NAME || '|OPENMODE=' || OPEN_MODE
FROM V\$PDBS
WHERE UPPER(NAME) = UPPER('${PDB_NAME}');
EXIT;
EOSQL
)
PDB_ACTUAL_NAME=$(echo "$PDB_INFO" | sed -n 's/.*PDBNAME=\([^|]*\)|.*/\1/p' | tr -d ' \n\r')
# OPEN_MODE contains an internal space ("READ WRITE", "READ ONLY") that must
# be preserved for display. Strip CR/LF, then trim leading/trailing spaces
# with literal-space BRE (AIX 7.2 sed has no PCRE / \s).
PDB_OPEN_MODE=$(echo "$PDB_INFO" | sed -n 's/.*OPENMODE=//p' | tr -d '\r\n' | sed 's/^ *//;s/ *$//')
# Space-normalized form for a robust comparison (avoids the internal-space trap).
PDB_OPEN_MODE_NORM=$(echo "$PDB_OPEN_MODE" | tr -d ' \r\n')

if [[ -z "$PDB_ACTUAL_NAME" ]]; then
    log_error "PDB '$PDB_NAME' not found in this CDB"
    log_error "Available PDBs:"
    sqlplus -s / as sysdba << 'EOSQL'
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT '  - ' || NAME || ' (' || OPEN_MODE || ')' FROM V$PDBS WHERE NAME <> 'PDB$SEED' ORDER BY NAME;
EXIT;
EOSQL
    exit 1
fi

log_info "Found PDB: $PDB_ACTUAL_NAME (open mode: $PDB_OPEN_MODE)"

if [[ "$PDB_OPEN_MODE_NORM" != "READWRITE" ]]; then
    log_error "PDB $PDB_ACTUAL_NAME is not OPEN READ WRITE (current: $PDB_OPEN_MODE)"
    log_error "Open it first:  ALTER PLUGGABLE DATABASE ${PDB_ACTUAL_NAME} OPEN READ WRITE;"
    exit 1
fi

# ============================================================
# Check Whether the Service Already Exists
# ============================================================

log_section "Checking for Existing Service"

SVC_EXISTS=$(sqlplus -s / as sysdba << EOSQL
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
ALTER SESSION SET CONTAINER = "${PDB_ACTUAL_NAME}";
SELECT 'SVCCOUNT=' || COUNT(*) FROM DBA_SERVICES WHERE NAME = '${SERVICE_NAME}';
EXIT;
EOSQL
)
# Extract only the tagged count, ignoring any noise from ALTER SESSION etc.
SVC_EXISTS=$(echo "$SVC_EXISTS" | sed -n 's/.*SVCCOUNT=//p' | tr -dc '0-9')

if [[ -z "$SVC_EXISTS" || "$SVC_EXISTS" == "0" ]]; then
    log_info "Service '$SERVICE_NAME' does not exist in $PDB_ACTUAL_NAME - it will be created"
    CREATE_SERVICE=true
else
    # Not an error: the create/start step below is idempotent and will simply
    # ensure the service is defined and (unless --no-start) running.
    log_info "Service '$SERVICE_NAME' is already defined in $PDB_ACTUAL_NAME - will ensure it is started"
    CREATE_SERVICE=false
fi

# ============================================================
# Deployment Summary
# ============================================================

log_section "Summary"

echo ""
echo "  Container DB : $(echo "$ORACLE_SID")"
echo "  PDB          : $PDB_ACTUAL_NAME"
echo "  Service      : $SERVICE_NAME"
if [[ "$CREATE_SERVICE" == "true" ]]; then
    echo "  Action       : CREATE service in PDB"
else
    echo "  Action       : service already exists (skip create)"
fi
if [[ "$DO_START" == "true" ]]; then
    echo "  Start        : YES (started on this PRIMARY)"
else
    echo "  Start        : NO (--no-start)"
fi
if [[ "$ENABLE_TAF" == "true" ]]; then
    echo "  TAF          : FAILOVER_TYPE=SELECT, FAILOVER_METHOD=BASIC"
fi
echo ""

if ! confirm_proceed "Proceed with creating/configuring the service?"; then
    log_info "Cancelled by user"
    exit 0
fi

# ============================================================
# Build the PL/SQL Action Block
# ============================================================

# All actions are check-then-act so the block is idempotent and safe to
# re-run: create only if the service is not already defined, start only if it
# is not already active. This avoids relying on exact ORA- codes and prevents
# "already exists / already running" from turning into a hard failure under
# WHENEVER SQLERROR EXIT. Any genuine error still propagates.

# CREATE (always attempted; no-op if the service already exists)
PLSQL_CREATE="    SELECT COUNT(*) INTO l_cnt FROM dba_services WHERE name = '${SERVICE_NAME}';
    IF l_cnt = 0 THEN
        DBMS_SERVICE.CREATE_SERVICE(
            service_name => '${SERVICE_NAME}',
            network_name => '${SERVICE_NAME}');
    END IF;"

PLSQL_TAF=""
if [[ "$ENABLE_TAF" == "true" ]]; then
    PLSQL_TAF="    DBMS_SERVICE.MODIFY_SERVICE(
        service_name      => '${SERVICE_NAME}',
        failover_method   => DBMS_SERVICE.FAILOVER_METHOD_BASIC,
        failover_type     => DBMS_SERVICE.FAILOVER_TYPE_SELECT,
        failover_retries  => 180,
        failover_delay    => 5);"
fi

PLSQL_START=""
if [[ "$DO_START" == "true" ]]; then
    PLSQL_START="    SELECT COUNT(*) INTO l_cnt FROM v\$active_services WHERE name = '${SERVICE_NAME}';
    IF l_cnt = 0 THEN
        DBMS_SERVICE.START_SERVICE('${SERVICE_NAME}');
    END IF;"
fi

# ============================================================
# Create / Configure / Start the Service
# ============================================================

log_section "Configuring Service in PDB"

confirm_approval_action "Create/start service ${SERVICE_NAME} in PDB ${PDB_ACTUAL_NAME}" "sqlplus -s / as sysdba <DBMS_SERVICE in ${PDB_ACTUAL_NAME}>" || exit 1

# Disable set -e around the call: WHENEVER SQLERROR EXIT makes sqlplus return
# a non-zero code on any ORA- error, which would otherwise abort the script at
# this assignment before we can capture and display the actual error.
set +e
DEPLOY_RESULT=$(sqlplus -s / as sysdba << EOSQL
SET HEADING OFF FEEDBACK ON VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

ALTER SESSION SET CONTAINER = "${PDB_ACTUAL_NAME}";

DECLARE
    l_cnt NUMBER;
BEGIN
${PLSQL_CREATE}
${PLSQL_TAF}
${PLSQL_START}
    NULL;
END;
/

-- Verification (within the PDB container)
SELECT 'SVC_DEFINED=' || COUNT(*) FROM DBA_SERVICES WHERE NAME = '${SERVICE_NAME}';
SELECT 'SVC_ACTIVE='  || COUNT(*) FROM V\$ACTIVE_SERVICES WHERE NAME = '${SERVICE_NAME}';

EXIT;
EOSQL
)
DEPLOY_RC=$?
set -e

echo "$DEPLOY_RESULT" | while IFS= read -r line; do
    [ -n "$LOG_FILE" ] && echo "  $line" >> "$LOG_FILE" || :
done

if [[ $DEPLOY_RC -ne 0 ]] || echo "$DEPLOY_RESULT" | grep -q "^ORA-"; then
    log_error "Failed to create/configure the service"
    log_error "SQL output:"
    echo "$DEPLOY_RESULT"
    exit 1
fi

# ============================================================
# Verify
# ============================================================

log_section "Verifying"

SVC_DEFINED=$(echo "$DEPLOY_RESULT" | grep "SVC_DEFINED=" | sed 's/.*SVC_DEFINED=//' | tr -d ' \n\r')
SVC_ACTIVE=$(echo "$DEPLOY_RESULT" | grep "SVC_ACTIVE=" | sed 's/.*SVC_ACTIVE=//' | tr -d ' \n\r')

DEPLOY_OK=true

if [[ "$SVC_DEFINED" == "1" ]]; then
    log_info "Service $SERVICE_NAME is DEFINED in $PDB_ACTUAL_NAME"
else
    log_error "Service $SERVICE_NAME was not found after creation"
    DEPLOY_OK=false
fi

if [[ "$DO_START" == "true" ]]; then
    if [[ "$SVC_ACTIVE" == "1" ]]; then
        log_info "Service $SERVICE_NAME is RUNNING"
    else
        log_error "Service $SERVICE_NAME is not running after start attempt"
        DEPLOY_OK=false
    fi
else
    log_info "Service $SERVICE_NAME created (not started; --no-start)"
fi

if [[ "$DEPLOY_OK" != "true" ]]; then
    log_error "Service configuration did not complete successfully"
    exit 1
fi

# ============================================================
# Check Role Trigger Integration
# ============================================================

log_section "Role-Aware Management"

TRG_EXISTS=$(sqlplus -s / as sysdba << 'EOSQL'
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT COUNT(*) FROM DBA_OBJECTS WHERE OBJECT_NAME = 'DG_SERVICE_MGR' AND OWNER = 'SYS' AND OBJECT_TYPE = 'PACKAGE';
EXIT;
EOSQL
)
TRG_EXISTS=$(echo "$TRG_EXISTS" | tr -d ' \n\r')

# ============================================================
# Summary
# ============================================================

print_summary "SUCCESS" "PDB service configured"

echo ""
echo "SERVICE READY"
echo "============="
echo ""
echo "  PDB     : $PDB_ACTUAL_NAME"
echo "  Service : $SERVICE_NAME  (DEFINED$( [[ "$DO_START" == "true" ]] && echo ", RUNNING"))"
echo ""
echo "NEXT STEP - MAKE IT ROLE-AWARE (switchover/failover)"
echo "===================================================="
echo ""
if [[ "$TRG_EXISTS" != "0" ]]; then
    echo "  The DG_SERVICE_MGR role trigger is already deployed. Re-run the CDB"
    echo "  trigger script so it includes this service (it is now discoverable):"
else
    echo "  No role trigger found yet. Deploy the CDB role trigger so this service"
    echo "  is STARTED on PRIMARY and STOPPED on STANDBY automatically:"
fi
echo ""
echo "      bash trigger/create_role_trigger_cdb.sh"
echo ""
echo "  When prompted, confirm that '$SERVICE_NAME [$PDB_ACTUAL_NAME]' is in the list."
echo ""
echo "CLIENT CONNECT STRING"
echo "====================="
echo ""
echo "  Use service_name = $SERVICE_NAME in your TNS/JDBC descriptor."
echo "  For a connection that follows the primary after switchover/failover,"
echo "  list BOTH hosts in an ADDRESS_LIST (see primary/10_generate_handoff_report.sh)."
echo ""
echo "MANUAL CHECKS"
echo "============="
echo ""
echo "    sqlplus / as sysdba"
echo "    ALTER SESSION SET CONTAINER = $PDB_ACTUAL_NAME;"
echo "    SELECT NAME, NETWORK_NAME FROM DBA_SERVICES WHERE NAME = '$SERVICE_NAME';"
echo "    SELECT NAME FROM V\$ACTIVE_SERVICES WHERE NAME = '$SERVICE_NAME';"
echo ""
echo "REMOVE THE SERVICE"
echo "=================="
echo ""
echo "    ALTER SESSION SET CONTAINER = $PDB_ACTUAL_NAME;"
echo "    EXEC DBMS_SERVICE.STOP_SERVICE('$SERVICE_NAME');"
echo "    EXEC DBMS_SERVICE.DELETE_SERVICE('$SERVICE_NAME');"
echo ""
