#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Create Role-Aware Service Trigger
#                           (CDB / PDB-aware, SYS-owned)
# ============================================================
# Run this script on the PRIMARY database server after
# Data Guard setup is complete (Step 7 verification passes).
#
# This is the CDB-aware counterpart of create_role_trigger.sh.
# It manages services that live INSIDE pluggable databases as
# well as user services at the CDB$ROOT level.
#
# This script:
# - Verifies the database is a CDB
# - Discovers user-defined services as (CONTAINER, SERVICE) pairs
# - Allows you to review/edit the service list
# - Creates PL/SQL package SYS.DG_SERVICE_MGR
# - Creates trigger TRG_MANAGE_SERVICES_ROLE_CHG (AFTER DB_ROLE_CHANGE)
# - Creates trigger TRG_MANAGE_SERVICES_STARTUP (AFTER STARTUP)
#
# The role-change / startup triggers fire in CDB$ROOT. For each
# managed service the package switches into the owning PDB
# (ALTER SESSION SET CONTAINER) before calling DBMS_SERVICE, then
# returns to CDB$ROOT. Services are STARTED on PRIMARY, STOPPED on
# STANDBY. Per-service failures (e.g. a PDB only MOUNTED on the
# standby) are logged to the alert log and never abort the others.
#
# Objects are created on PRIMARY and replicate to standby via redo.
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

print_banner "Create Role-Aware Service Trigger (CDB / PDB-aware)"

# Initialize logging
init_log "create_role_trigger_cdb"

# ============================================================
# Pre-flight Checks
# ============================================================

log_section "Pre-flight Checks"

check_oracle_env || exit 1
check_nfs_mount || exit 1
check_db_connection || exit 1

# ============================================================
# Load Configuration
# ============================================================

log_section "Loading Configuration"

# Find standby config file
if ! select_config_file STANDBY_CONFIG_FILE "standby configuration" "${NFS_SHARE}/standby_config_*.env"; then
    log_error "Please run the Data Guard setup scripts first (Steps 1-7)"
    exit 1
fi

source "$STANDBY_CONFIG_FILE"

# Re-initialize log with DB name
init_log "create_role_trigger_cdb_${PRIMARY_DB_UNIQUE_NAME}"

# ============================================================
# Verify Database Role
# ============================================================

log_section "Verifying Database Role"

DB_ROLE=$(run_sql_query "get_db_role.sql")
DB_ROLE=$(echo "$DB_ROLE" | tr -d ' \n\r')

if [[ "$DB_ROLE" != "PRIMARY" ]]; then
    log_error "This script must be run on the PRIMARY database"
    log_error "Current database role: $DB_ROLE"
    exit 1
fi

log_info "Confirmed: Running on PRIMARY database"

# ============================================================
# Verify This Is a CDB
# ============================================================

log_section "Verifying Multitenant (CDB)"

IS_CDB=$(sqlplus -s / as sysdba << 'EOSQL'
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT CDB FROM V$DATABASE;
EXIT;
EOSQL
)
IS_CDB=$(echo "$IS_CDB" | tr -d ' \n\r')

if [[ "$IS_CDB" != "YES" ]]; then
    log_error "This database is not a CDB (V\$DATABASE.CDB = ${IS_CDB:-unknown})"
    log_error "Use create_role_trigger.sh for non-CDB (single-container) databases."
    exit 1
fi

log_info "Confirmed: Container Database (CDB)"

# ============================================================
# Discover User-Defined Services (per container)
# ============================================================

log_section "Discovering User-Defined Services"

log_info "Querying active services across all containers (excluding system services)..."

SERVICE_OUTPUT=$(run_sql_query "get_user_services_cdb.sql" 2>/dev/null || true)

# Parse "CONTAINER|SERVICE" pairs into two parallel arrays.
# (AIX-compatible: no associative arrays.)
PDB_LIST=()
SVC_LIST=()
while IFS= read -r line; do
    line=$(echo "$line" | tr -d ' \n\r')
    if [[ -n "$line" && "$line" == *"|"* ]]; then
        PDB_LIST+=("${line%%|*}")
        SVC_LIST+=("${line#*|}")
    fi
done <<< "$SERVICE_OUTPUT"

# Print the current (container, service) list with 1-based numbering.
print_service_list() {
    if [[ ${#SVC_LIST[@]} -eq 0 ]]; then
        echo "  (none)"
        return
    fi
    local i=0
    while [[ $i -lt ${#SVC_LIST[@]} ]]; do
        printf "  %d) %-30s [%s]\n" "$((i + 1))" "${SVC_LIST[$i]}" "${PDB_LIST[$i]}"
        i=$((i + 1))
    done
}

# Append a (container, service) pair after validating both names.
# Returns 0 on success, 1 on validation failure.
add_service_pair() {
    local pdb="$1"
    local svc="$2"
    pdb=$(echo "$pdb" | tr -d ' \n\r')
    svc=$(echo "$svc" | tr -d ' \n\r')
    if [[ -z "$pdb" ]]; then
        pdb="CDB\$ROOT"
    fi
    if ! echo "$svc" | grep -q '^[A-Za-z0-9_.$]*$' || [[ -z "$svc" ]]; then
        log_error "Invalid service name: $svc"
        log_error "Service names may only contain letters, numbers, underscore, dot, and dollar sign"
        return 1
    fi
    # Container names: letters, numbers, underscore, dollar, hash (plus the literal CDB$ROOT)
    if ! echo "$pdb" | grep -q '^[A-Za-z0-9_$#]*$'; then
        log_error "Invalid container name: $pdb"
        return 1
    fi
    if [[ ${#svc} -gt 64 ]]; then
        log_error "Service name too long (max 64 chars): $svc"
        return 1
    fi
    PDB_LIST+=("$pdb")
    SVC_LIST+=("$svc")
    log_info "Added service: ${svc} [${pdb}]"
    return 0
}

if [[ ${#SVC_LIST[@]} -eq 0 ]]; then
    log_warn "No user-defined services found running in any container"
    echo ""
    echo "You can still enter service names manually."
    echo "Services must already exist in the database (this script does not create services)."
    echo ""
else
    echo ""
    echo "Discovered ${#SVC_LIST[@]} user-defined service(s):"
    echo ""
    print_service_list
    echo ""
fi

# ============================================================
# Allow User to Edit Service List
# ============================================================

log_section "Review Service List"

echo "You can modify the service list before deployment."
echo "Each entry is a SERVICE within a CONTAINER (PDB name, or CDB\$ROOT)."
echo ""
echo "Current services:"
print_service_list
echo ""
echo "Options:"
echo "  [Enter]  Accept the current list"
echo "  [a]      Add a service"
echo "  [r]      Remove a service"
echo "  [c]      Clear all and enter manually"
echo ""

# Remove the entry at 0-based index $1 from both parallel arrays.
remove_pair_at() {
    local target="$1"
    local new_pdb=()
    local new_svc=()
    local i=0
    while [[ $i -lt ${#SVC_LIST[@]} ]]; do
        if [[ $i -ne $target ]]; then
            new_pdb+=("${PDB_LIST[$i]}")
            new_svc+=("${SVC_LIST[$i]}")
        fi
        i=$((i + 1))
    done
    PDB_LIST=("${new_pdb[@]}")
    SVC_LIST=("${new_svc[@]}")
}

while true; do
    printf "Action [Enter/a/r/c]: "
    read action
    action=$(echo "$action" | tr '[:upper:]' '[:lower:]')

    case "$action" in
        "")
            break
            ;;
        a)
            printf "Enter container (PDB name, or CDB\$ROOT) [CDB\$ROOT]: "
            read new_pdb
            printf "Enter service name to add: "
            read new_svc
            add_service_pair "$new_pdb" "$new_svc" || true
            echo ""
            echo "Current services:"
            print_service_list
            echo ""
            ;;
        r)
            if [[ ${#SVC_LIST[@]} -eq 0 ]]; then
                log_warn "No services to remove"
            else
                echo "Select service to remove:"
                print_service_list
                printf "Number: "
                read remove_num
                if [[ "$remove_num" =~ ^[0-9]+$ ]] && [[ "$remove_num" -ge 1 ]] && [[ "$remove_num" -le ${#SVC_LIST[@]} ]]; then
                    idx=$((remove_num - 1))
                    removed="${SVC_LIST[$idx]} [${PDB_LIST[$idx]}]"
                    remove_pair_at "$idx"
                    log_info "Removed service: $removed"
                else
                    log_error "Invalid selection"
                fi
            fi
            echo ""
            echo "Current services:"
            print_service_list
            echo ""
            ;;
        c)
            PDB_LIST=()
            SVC_LIST=()
            echo ""
            echo "List cleared. Enter services one per line (empty service name to finish)."
            while true; do
                printf "  Container (PDB name, or CDB\$ROOT) [CDB\$ROOT]: "
                read new_pdb
                printf "  Service name: "
                read new_svc
                new_svc_trimmed=$(echo "$new_svc" | tr -d ' \n\r')
                if [[ -z "$new_svc_trimmed" ]]; then
                    break
                fi
                add_service_pair "$new_pdb" "$new_svc" || true
            done
            echo ""
            echo "Current services:"
            print_service_list
            echo ""
            ;;
        *)
            log_error "Invalid option: $action"
            ;;
    esac
done

# ============================================================
# Validate Final Service List
# ============================================================

if [[ ${#SVC_LIST[@]} -eq 0 ]]; then
    log_error "No services specified. At least one service is required."
    exit 1
fi

# Final validation of all (container, service) pairs
i=0
while [[ $i -lt ${#SVC_LIST[@]} ]]; do
    svc="${SVC_LIST[$i]}"
    pdb="${PDB_LIST[$i]}"
    if ! echo "$svc" | grep -q '^[A-Za-z0-9_.$]*$'; then
        log_error "Invalid service name: $svc"
        exit 1
    fi
    if [[ ${#svc} -gt 64 ]]; then
        log_error "Service name too long (max 64 chars): $svc"
        exit 1
    fi
    if ! echo "$pdb" | grep -q '^[A-Za-z0-9_$#]*$'; then
        log_error "Invalid container name: $pdb"
        exit 1
    fi
    i=$((i + 1))
done

log_info "Validated ${#SVC_LIST[@]} service entry(ies)"

# ============================================================
# Check for Existing Package
# ============================================================

log_section "Checking for Existing Objects"

PKG_EXISTS=$(sqlplus -s / as sysdba << 'EOSQL'
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT COUNT(*) FROM DBA_OBJECTS WHERE OBJECT_NAME = 'DG_SERVICE_MGR' AND OWNER = 'SYS';
EXIT;
EOSQL
)
PKG_EXISTS=$(echo "$PKG_EXISTS" | tr -d ' \n\r')

if [[ "$PKG_EXISTS" != "0" ]]; then
    log_warn "Package SYS.DG_SERVICE_MGR already exists"
    echo ""
    echo "Existing objects will be replaced with the new definition."
    echo "This is safe - the new package will contain the updated service list."
    echo ""
    if ! confirm_proceed "Replace existing DG_SERVICE_MGR package and triggers?"; then
        log_info "Deployment cancelled by user"
        exit 0
    fi
fi

# ============================================================
# Deployment Summary
# ============================================================

log_section "Deployment Summary"

echo ""
echo "The following objects will be created in the SYS schema (CDB\$ROOT):"
echo ""
echo "  Package : SYS.DG_SERVICE_MGR"
echo "  Trigger : SYS.TRG_MANAGE_SERVICES_ROLE_CHG (AFTER DB_ROLE_CHANGE)"
echo "  Trigger : SYS.TRG_MANAGE_SERVICES_STARTUP  (AFTER STARTUP)"
echo ""
echo "Services managed (started on PRIMARY, stopped on STANDBY):"
echo ""
print_service_list
echo ""
echo "Objects will replicate to standby via redo apply."
echo ""

if ! confirm_proceed "Deploy DG_SERVICE_MGR package and triggers?"; then
    log_info "Deployment cancelled by user"
    exit 0
fi

# ============================================================
# Build PL/SQL Service List
# ============================================================

# Build the PL/SQL collection initialization for the (container, service) list.
PLSQL_SERVICE_LINES=""
i=0
while [[ $i -lt ${#SVC_LIST[@]} ]]; do
    PLSQL_SERVICE_LINES="${PLSQL_SERVICE_LINES}
            l_services.EXTEND;
            l_services(l_services.COUNT).pdb := '${PDB_LIST[$i]}';
            l_services(l_services.COUNT).svc := '${SVC_LIST[$i]}';"
    i=$((i + 1))
done

# ============================================================
# Deploy PL/SQL Package and Triggers
# ============================================================

log_section "Deploying PL/SQL Objects"

log_info "Creating package SYS.DG_SERVICE_MGR..."
log_cmd "sqlplus / as sysdba:" "CREATE OR REPLACE PACKAGE SYS.DG_SERVICE_MGR ..."
confirm_approval_action "Deploy DG_SERVICE_MGR package and role-change triggers" "sqlplus -s / as sysdba <deploy DG_SERVICE_MGR package and triggers>" || exit 1

DEPLOY_RESULT=$(sqlplus -s / as sysdba << EOSQL
SET HEADING OFF FEEDBACK ON VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON SERVEROUTPUT ON

-- ============================================================
-- Package Specification
-- ============================================================
CREATE OR REPLACE PACKAGE SYS.DG_SERVICE_MGR AS
    -- --------------------------------------------------------
    -- DG_SERVICE_MGR: Manages database services based on role.
    -- CDB / PDB-aware: switches into the owning container before
    -- starting/stopping each service. Services are started on
    -- PRIMARY, stopped on STANDBY. Called by database triggers
    -- on role change and startup.
    -- --------------------------------------------------------
    PROCEDURE MANAGE_SERVICES;
END DG_SERVICE_MGR;
/

-- ============================================================
-- Package Body
-- ============================================================
CREATE OR REPLACE PACKAGE BODY SYS.DG_SERVICE_MGR AS

    -- --------------------------------------------------------
    -- Service List Function
    -- Returns the list of (container, service) pairs to manage.
    -- ========================================================
    -- TO EDIT THE SERVICE LIST:
    --   Modify the entries below between the BEGIN/END markers.
    --   Each service needs three lines:
    --     l_services.EXTEND;
    --     l_services(l_services.COUNT).pdb := 'CONTAINER_NAME';
    --     l_services(l_services.COUNT).svc := 'SERVICE_NAME';
    --   Use CDB\$ROOT as the container for root-level services.
    -- ========================================================
    -- --------------------------------------------------------
    TYPE service_rec_t IS RECORD (
        pdb VARCHAR2(128),
        svc VARCHAR2(64)
    );
    TYPE service_list_t IS TABLE OF service_rec_t;

    FUNCTION get_service_list RETURN service_list_t IS
        l_services service_list_t := service_list_t();
    BEGIN
        -- ===== BEGIN SERVICE LIST =====${PLSQL_SERVICE_LINES}
        -- ===== END SERVICE LIST =====
        RETURN l_services;
    END get_service_list;

    PROCEDURE log_service_issue(
        p_action  IN VARCHAR2,
        p_service IN VARCHAR2,
        p_error   IN VARCHAR2
    ) IS
    BEGIN
        DBMS_SYSTEM.KSDWRT(
            2,
            'DG_SERVICE_MGR ' || p_action || ' failed for service ' || p_service || ': ' || SUBSTR(p_error, 1, 300)
        );
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END log_service_issue;

    -- --------------------------------------------------------
    -- manage_one: start/stop a single service in its container.
    -- For PDB services, switches container, acts, then returns
    -- to CDB\$ROOT. Failures are logged, never raised.
    -- --------------------------------------------------------
    PROCEDURE manage_one(
        p_pdb   IN VARCHAR2,
        p_svc   IN VARCHAR2,
        p_start IN BOOLEAN
    ) IS
        l_action VARCHAR2(10) := CASE WHEN p_start THEN 'START' ELSE 'STOP' END;
        l_label  VARCHAR2(200) := NVL(p_pdb, 'CDB\$ROOT') || '.' || p_svc;
    BEGIN
        IF p_pdb IS NULL OR UPPER(p_pdb) = 'CDB\$ROOT' THEN
            -- Root-level service: act in the current (root) container.
            IF p_start THEN
                DBMS_SERVICE.START_SERVICE(p_svc);
            ELSE
                DBMS_SERVICE.STOP_SERVICE(p_svc);
            END IF;
        ELSE
            -- PDB service: switch in, act, switch back.
            EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = "' || p_pdb || '"';
            BEGIN
                IF p_start THEN
                    DBMS_SERVICE.START_SERVICE(p_svc);
                ELSE
                    DBMS_SERVICE.STOP_SERVICE(p_svc);
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    log_service_issue(l_action, l_label, SQLERRM);
            END;
            EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = CDB\$ROOT';
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- Make sure we are back in the root even if the switch failed.
            BEGIN
                EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = CDB\$ROOT';
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
            log_service_issue(l_action, l_label, SQLERRM);
    END manage_one;

    -- --------------------------------------------------------
    -- MANAGE_SERVICES: Start or stop services based on role
    -- --------------------------------------------------------
    PROCEDURE MANAGE_SERVICES IS
        l_role     VARCHAR2(30);
        l_services service_list_t;
        l_start    BOOLEAN;
    BEGIN
        SELECT DATABASE_ROLE INTO l_role FROM V\$DATABASE;
        l_services := get_service_list();
        l_start := (l_role = 'PRIMARY');

        FOR i IN 1..l_services.COUNT LOOP
            manage_one(l_services(i).pdb, l_services(i).svc, l_start);
        END LOOP;
    END MANAGE_SERVICES;

END DG_SERVICE_MGR;
/

-- ============================================================
-- Trigger: AFTER DB_ROLE_CHANGE (fires on switchover/failover)
-- ============================================================
CREATE OR REPLACE TRIGGER SYS.TRG_MANAGE_SERVICES_ROLE_CHG
    AFTER DB_ROLE_CHANGE ON DATABASE
BEGIN
    SYS.DG_SERVICE_MGR.MANAGE_SERVICES;
END;
/

-- ============================================================
-- Trigger: AFTER STARTUP (fires when database opens)
-- ============================================================
CREATE OR REPLACE TRIGGER SYS.TRG_MANAGE_SERVICES_STARTUP
    AFTER STARTUP ON DATABASE
BEGIN
    SYS.DG_SERVICE_MGR.MANAGE_SERVICES;
END;
/

-- Verification
SELECT 'PKG_STATUS=' || STATUS FROM DBA_OBJECTS WHERE OBJECT_NAME = 'DG_SERVICE_MGR' AND OBJECT_TYPE = 'PACKAGE BODY' AND OWNER = 'SYS';
SELECT 'TRG_ROLE_CHG=' || STATUS FROM DBA_TRIGGERS WHERE TRIGGER_NAME = 'TRG_MANAGE_SERVICES_ROLE_CHG' AND OWNER = 'SYS';
SELECT 'TRG_STARTUP=' || STATUS FROM DBA_TRIGGERS WHERE TRIGGER_NAME = 'TRG_MANAGE_SERVICES_STARTUP' AND OWNER = 'SYS';

EXIT;
EOSQL
)

echo "$DEPLOY_RESULT" | while IFS= read -r line; do
    [ -n "$LOG_FILE" ] && echo "  $line" >> "$LOG_FILE" || :
done

# ============================================================
# Verify Deployment
# ============================================================

log_section "Verifying Deployment"

PKG_STATUS=$(echo "$DEPLOY_RESULT" | grep "PKG_STATUS=" | sed 's/PKG_STATUS=//' | tr -d ' \n\r')
TRG_ROLE_STATUS=$(echo "$DEPLOY_RESULT" | grep "TRG_ROLE_CHG=" | sed 's/TRG_ROLE_CHG=//' | tr -d ' \n\r')
TRG_STARTUP_STATUS=$(echo "$DEPLOY_RESULT" | grep "TRG_STARTUP=" | sed 's/TRG_STARTUP=//' | tr -d ' \n\r')

DEPLOY_OK=true

if [[ "$PKG_STATUS" == "VALID" ]]; then
    log_info "Package SYS.DG_SERVICE_MGR: VALID"
else
    log_error "Package SYS.DG_SERVICE_MGR: ${PKG_STATUS:-NOT FOUND}"
    DEPLOY_OK=false
fi

if [[ "$TRG_ROLE_STATUS" == "ENABLED" ]]; then
    log_info "Trigger SYS.TRG_MANAGE_SERVICES_ROLE_CHG: ENABLED"
else
    log_error "Trigger SYS.TRG_MANAGE_SERVICES_ROLE_CHG: ${TRG_ROLE_STATUS:-NOT FOUND}"
    DEPLOY_OK=false
fi

if [[ "$TRG_STARTUP_STATUS" == "ENABLED" ]]; then
    log_info "Trigger SYS.TRG_MANAGE_SERVICES_STARTUP: ENABLED"
else
    log_error "Trigger SYS.TRG_MANAGE_SERVICES_STARTUP: ${TRG_STARTUP_STATUS:-NOT FOUND}"
    DEPLOY_OK=false
fi

if [[ "$DEPLOY_OK" != "true" ]]; then
    log_error "Deployment verification failed"
    echo ""
    echo "Check for compilation errors:"
    echo "  SELECT * FROM DBA_ERRORS WHERE OWNER = 'SYS' AND NAME = 'DG_SERVICE_MGR';"
    echo ""
    exit 1
fi

# ============================================================
# Save Generated SQL to NFS
# ============================================================

log_section "Saving Generated SQL"

SQL_OUTPUT_FILE="${NFS_SHARE}/dg_service_mgr_cdb_${PRIMARY_DB_UNIQUE_NAME}.sql"

cat > "$SQL_OUTPUT_FILE" << EOSQLFILE
-- ============================================================
-- DG_SERVICE_MGR: Role-Aware Service Management (CDB / PDB-aware)
-- ============================================================
-- Generated: $(date '+%Y-%m-%d %H:%M:%S')
-- Primary DB: ${PRIMARY_DB_UNIQUE_NAME}
-- Standby DB: ${STANDBY_DB_UNIQUE_NAME}
--
-- Services are started on PRIMARY, stopped on STANDBY. For PDB
-- services the package switches into the owning container before
-- calling DBMS_SERVICE, then returns to CDB\$ROOT.
--
-- To modify the service list, edit the get_service_list function
-- in the package body between the BEGIN/END SERVICE LIST markers.
-- ============================================================

-- Package Specification
CREATE OR REPLACE PACKAGE SYS.DG_SERVICE_MGR AS
    PROCEDURE MANAGE_SERVICES;
END DG_SERVICE_MGR;
/

-- Package Body
CREATE OR REPLACE PACKAGE BODY SYS.DG_SERVICE_MGR AS

    TYPE service_rec_t IS RECORD (
        pdb VARCHAR2(128),
        svc VARCHAR2(64)
    );
    TYPE service_list_t IS TABLE OF service_rec_t;

    FUNCTION get_service_list RETURN service_list_t IS
        l_services service_list_t := service_list_t();
    BEGIN
        -- ===== BEGIN SERVICE LIST =====${PLSQL_SERVICE_LINES}
        -- ===== END SERVICE LIST =====
        RETURN l_services;
    END get_service_list;

    PROCEDURE log_service_issue(
        p_action  IN VARCHAR2,
        p_service IN VARCHAR2,
        p_error   IN VARCHAR2
    ) IS
    BEGIN
        DBMS_SYSTEM.KSDWRT(
            2,
            'DG_SERVICE_MGR ' || p_action || ' failed for service ' || p_service || ': ' || SUBSTR(p_error, 1, 300)
        );
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END log_service_issue;

    PROCEDURE manage_one(
        p_pdb   IN VARCHAR2,
        p_svc   IN VARCHAR2,
        p_start IN BOOLEAN
    ) IS
        l_action VARCHAR2(10) := CASE WHEN p_start THEN 'START' ELSE 'STOP' END;
        l_label  VARCHAR2(200) := NVL(p_pdb, 'CDB\$ROOT') || '.' || p_svc;
    BEGIN
        IF p_pdb IS NULL OR UPPER(p_pdb) = 'CDB\$ROOT' THEN
            IF p_start THEN
                DBMS_SERVICE.START_SERVICE(p_svc);
            ELSE
                DBMS_SERVICE.STOP_SERVICE(p_svc);
            END IF;
        ELSE
            EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = "' || p_pdb || '"';
            BEGIN
                IF p_start THEN
                    DBMS_SERVICE.START_SERVICE(p_svc);
                ELSE
                    DBMS_SERVICE.STOP_SERVICE(p_svc);
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    log_service_issue(l_action, l_label, SQLERRM);
            END;
            EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = CDB\$ROOT';
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            BEGIN
                EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = CDB\$ROOT';
            EXCEPTION
                WHEN OTHERS THEN NULL;
            END;
            log_service_issue(l_action, l_label, SQLERRM);
    END manage_one;

    PROCEDURE MANAGE_SERVICES IS
        l_role     VARCHAR2(30);
        l_services service_list_t;
        l_start    BOOLEAN;
    BEGIN
        SELECT DATABASE_ROLE INTO l_role FROM V\$DATABASE;
        l_services := get_service_list();
        l_start := (l_role = 'PRIMARY');

        FOR i IN 1..l_services.COUNT LOOP
            manage_one(l_services(i).pdb, l_services(i).svc, l_start);
        END LOOP;
    END MANAGE_SERVICES;

END DG_SERVICE_MGR;
/

-- Trigger: AFTER DB_ROLE_CHANGE
CREATE OR REPLACE TRIGGER SYS.TRG_MANAGE_SERVICES_ROLE_CHG
    AFTER DB_ROLE_CHANGE ON DATABASE
BEGIN
    SYS.DG_SERVICE_MGR.MANAGE_SERVICES;
END;
/

-- Trigger: AFTER STARTUP
CREATE OR REPLACE TRIGGER SYS.TRG_MANAGE_SERVICES_STARTUP
    AFTER STARTUP ON DATABASE
BEGIN
    SYS.DG_SERVICE_MGR.MANAGE_SERVICES;
END;
/

-- ============================================================
-- Removal Commands (if needed):
-- ============================================================
-- DROP TRIGGER SYS.TRG_MANAGE_SERVICES_ROLE_CHG;
-- DROP TRIGGER SYS.TRG_MANAGE_SERVICES_STARTUP;
-- DROP PACKAGE SYS.DG_SERVICE_MGR;
-- ============================================================
EOSQLFILE

log_info "Generated SQL saved to: $SQL_OUTPUT_FILE"

# ============================================================
# Summary
# ============================================================

print_summary "SUCCESS" "Role-aware service trigger deployed (CDB / PDB-aware)"

echo ""
echo "DEPLOYMENT COMPLETE"
echo "==================="
echo ""
echo "  Package : SYS.DG_SERVICE_MGR               (VALID)"
echo "  Trigger : SYS.TRG_MANAGE_SERVICES_ROLE_CHG (ENABLED)"
echo "  Trigger : SYS.TRG_MANAGE_SERVICES_STARTUP  (ENABLED)"
echo ""
echo "  Services managed (service [container]):"
print_service_list
echo ""
echo "  Generated SQL: $SQL_OUTPUT_FILE"
echo ""
echo "HOW IT WORKS"
echo "============"
echo ""
echo "  - On switchover/failover: trigger fires and starts/stops services"
echo "  - On database startup: trigger fires and starts/stops services"
echo "  - PRIMARY role: services are STARTED"
echo "  - STANDBY role: services are STOPPED"
echo "  - PDB services: the package switches into the owning container"
echo "    (ALTER SESSION SET CONTAINER) before start/stop, then returns"
echo "    to CDB\$ROOT. Per-service failures are written to the alert log."
echo ""
echo "  NOTE: a PDB service can only START if the PDB is OPEN. On startup,"
echo "  ensure your PDBs auto-open (SAVE STATE, or an AFTER STARTUP open"
echo "  trigger) so the service start succeeds."
echo ""
echo "MODIFY SERVICE LIST"
echo "==================="
echo ""
echo "  To change which services are managed, edit the package body:"
echo ""
echo "    sqlplus / as sysdba"
echo "    -- Edit between the BEGIN/END SERVICE LIST markers"
echo "    -- Or re-run this script to regenerate"
echo ""
echo "  Alternatively, re-deploy from the saved SQL:"
echo "    sqlplus / as sysdba @${SQL_OUTPUT_FILE}"
echo ""
echo "REMOVE ALL OBJECTS"
echo "=================="
echo ""
echo "    DROP TRIGGER SYS.TRG_MANAGE_SERVICES_ROLE_CHG;"
echo "    DROP TRIGGER SYS.TRG_MANAGE_SERVICES_STARTUP;"
echo "    DROP PACKAGE SYS.DG_SERVICE_MGR;"
echo ""
echo "TEST MANUALLY"
echo "============="
echo ""
echo "    EXEC SYS.DG_SERVICE_MGR.MANAGE_SERVICES;"
echo "    -- Check per container, e.g.:"
echo "    ALTER SESSION SET CONTAINER = <PDB>;"
echo "    SELECT NAME FROM V\$ACTIVE_SERVICES;"
echo ""
