#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Create Role-Aware Service Trigger
# ============================================================
# Run this script on the PRIMARY database server after
# Data Guard setup is complete (Step 7 verification passes).
#
# This script:
# - Discovers user-defined services running on the database
# - Allows you to review/edit the service list
# - Creates PL/SQL package SYS.DG_SERVICE_MGR
# - Creates trigger TRG_MANAGE_SERVICES_ROLE_CHG (AFTER DB_ROLE_CHANGE)
# - Creates trigger TRG_MANAGE_SERVICES_STARTUP (AFTER STARTUP)
#
# Services are automatically started on PRIMARY and stopped on STANDBY.
# Objects are created on PRIMARY and replicate to standby via redo.
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

print_banner "Create Role-Aware Service Trigger"

# Initialize logging
init_log "create_role_trigger"

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
init_log "create_role_trigger_${PRIMARY_DB_UNIQUE_NAME}"

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
# Discover User-Defined Services
# ============================================================

log_section "Discovering User-Defined Services"

log_info "Querying active services (excluding system services)..."

SERVICE_OUTPUT=$(run_sql_query "get_user_services.sql" 2>/dev/null || true)

# Parse services into an array
SERVICE_LIST=()
while IFS= read -r line; do
    line=$(echo "$line" | tr -d ' \n\r')
    if [[ -n "$line" ]]; then
        SERVICE_LIST+=("$line")
    fi
done <<< "$SERVICE_OUTPUT"

if [[ ${#SERVICE_LIST[@]} -eq 0 ]]; then
    log_warn "No user-defined services found running on this database"
    echo ""
    echo "You can still enter service names manually."
    echo "Services must already exist in the database (this script does not create services)."
    echo ""
else
    echo ""
    echo "Discovered ${#SERVICE_LIST[@]} user-defined service(s):"
    echo ""
    local_i=1
    for svc in "${SERVICE_LIST[@]}"; do
        printf "  %d) %s\n" "$local_i" "$svc"
        local_i=$((local_i + 1))
    done
    echo ""
fi

# ============================================================
# Allow User to Edit Service List
# ============================================================

log_section "Review Service List"

echo "You can modify the service list before deployment."
echo ""
echo "Current services:"
if [[ ${#SERVICE_LIST[@]} -eq 0 ]]; then
    echo "  (none)"
else
    for svc in "${SERVICE_LIST[@]}"; do
        printf "  - %s\n" "$svc"
    done
fi
echo ""
echo "Options:"
echo "  [Enter]  Accept the current list"
echo "  [a]      Add a service"
echo "  [r]      Remove a service"
echo "  [c]      Clear all and enter manually"
echo ""

while true; do
    printf "Action [Enter/a/r/c]: "
    read action
    action=$(echo "$action" | tr '[:upper:]' '[:lower:]')

    case "$action" in
        "")
            # Accept current list
            break
            ;;
        a)
            printf "Enter service name to add: "
            read new_svc
            new_svc=$(echo "$new_svc" | tr -d ' \n\r')
            if [[ -n "$new_svc" ]]; then
                # Validate service name
                if echo "$new_svc" | grep -q '^[A-Za-z0-9_.$]*$'; then
                    SERVICE_LIST+=("$new_svc")
                    log_info "Added service: $new_svc"
                else
                    log_error "Invalid service name: $new_svc"
                    log_error "Service names may only contain letters, numbers, underscore, dot, and dollar sign"
                fi
            fi
            echo ""
            echo "Current services:"
            for svc in "${SERVICE_LIST[@]}"; do
                printf "  - %s\n" "$svc"
            done
            echo ""
            ;;
        r)
            if [[ ${#SERVICE_LIST[@]} -eq 0 ]]; then
                log_warn "No services to remove"
            else
                echo "Select service to remove:"
                local_i=1
                for svc in "${SERVICE_LIST[@]}"; do
                    printf "  %d) %s\n" "$local_i" "$svc"
                    local_i=$((local_i + 1))
                done
                printf "Number: "
                read remove_num
                if [[ "$remove_num" =~ ^[0-9]+$ ]] && [[ "$remove_num" -ge 1 ]] && [[ "$remove_num" -le ${#SERVICE_LIST[@]} ]]; then
                    removed="${SERVICE_LIST[$((remove_num - 1))]}"
                    # Remove element from array - AIX compatible
                    new_list=()
                    local_i=0
                    for svc in "${SERVICE_LIST[@]}"; do
                        if [[ $local_i -ne $((remove_num - 1)) ]]; then
                            new_list+=("$svc")
                        fi
                        local_i=$((local_i + 1))
                    done
                    SERVICE_LIST=("${new_list[@]}")
                    log_info "Removed service: $removed"
                else
                    log_error "Invalid selection"
                fi
            fi
            echo ""
            echo "Current services:"
            if [[ ${#SERVICE_LIST[@]} -eq 0 ]]; then
                echo "  (none)"
            else
                for svc in "${SERVICE_LIST[@]}"; do
                    printf "  - %s\n" "$svc"
                done
            fi
            echo ""
            ;;
        c)
            SERVICE_LIST=()
            echo ""
            echo "List cleared. Enter service names one per line (empty line to finish):"
            while true; do
                printf "  Service name: "
                read new_svc
                new_svc=$(echo "$new_svc" | tr -d ' \n\r')
                if [[ -z "$new_svc" ]]; then
                    break
                fi
                if echo "$new_svc" | grep -q '^[A-Za-z0-9_.$]*$'; then
                    SERVICE_LIST+=("$new_svc")
                    log_info "Added service: $new_svc"
                else
                    log_error "Invalid service name: $new_svc"
                    log_error "Service names may only contain letters, numbers, underscore, dot, and dollar sign"
                fi
            done
            echo ""
            echo "Current services:"
            if [[ ${#SERVICE_LIST[@]} -eq 0 ]]; then
                echo "  (none)"
            else
                for svc in "${SERVICE_LIST[@]}"; do
                    printf "  - %s\n" "$svc"
                done
            fi
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

if [[ ${#SERVICE_LIST[@]} -eq 0 ]]; then
    log_error "No services specified. At least one service is required."
    exit 1
fi

# Final validation of all service names
for svc in "${SERVICE_LIST[@]}"; do
    if ! echo "$svc" | grep -q '^[A-Za-z0-9_.$]*$'; then
        log_error "Invalid service name: $svc"
        log_error "Service names may only contain letters, numbers, underscore, dot, and dollar sign"
        exit 1
    fi
    if [[ ${#svc} -gt 64 ]]; then
        log_error "Service name too long (max 64 chars): $svc"
        exit 1
    fi
done

log_info "Validated ${#SERVICE_LIST[@]} service name(s)"

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
echo "The following objects will be created in the SYS schema:"
echo ""
echo "  Package : SYS.DG_SERVICE_MGR"
echo "  Trigger : SYS.TRG_MANAGE_SERVICES_ROLE_CHG (AFTER DB_ROLE_CHANGE)"
echo "  Trigger : SYS.TRG_MANAGE_SERVICES_STARTUP  (AFTER STARTUP)"
echo ""
echo "Services managed (started on PRIMARY, stopped on STANDBY):"
echo ""
for svc in "${SERVICE_LIST[@]}"; do
    printf "  - %s\n" "$svc"
done
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

# Build the PL/SQL collection initialization for the service list
PLSQL_SERVICE_LINES=""
for svc in "${SERVICE_LIST[@]}"; do
    PLSQL_SERVICE_LINES="${PLSQL_SERVICE_LINES}
            l_services.EXTEND;
            l_services(l_services.COUNT) := '${svc}';"
done

# ============================================================
# Deploy PL/SQL Package and Triggers
# ============================================================

log_section "Deploying PL/SQL Objects"

log_info "Creating package SYS.DG_SERVICE_MGR..."
log_cmd "sqlplus / as sysdba:" "CREATE OR REPLACE PACKAGE SYS.DG_SERVICE_MGR ..."

DEPLOY_RESULT=$(sqlplus -s / as sysdba << EOSQL
SET HEADING OFF FEEDBACK ON VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON SERVEROUTPUT ON

-- ============================================================
-- Package Specification
-- ============================================================
CREATE OR REPLACE PACKAGE SYS.DG_SERVICE_MGR AS
    -- --------------------------------------------------------
    -- DG_SERVICE_MGR: Manages database services based on role.
    -- Services are started on PRIMARY, stopped on STANDBY.
    -- Called by database triggers on role change and startup.
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
    -- Returns the list of services to manage.
    -- ========================================================
    -- TO EDIT THE SERVICE LIST:
    --   Modify the entries below between the BEGIN/END markers.
    --   Each service needs:
    --     l_services.EXTEND;
    --     l_services(l_services.COUNT) := 'SERVICE_NAME';
    -- ========================================================
    -- --------------------------------------------------------
    TYPE service_list_t IS TABLE OF VARCHAR2(64);

    FUNCTION get_service_list RETURN service_list_t IS
        l_services service_list_t := service_list_t();
    BEGIN
        -- ===== BEGIN SERVICE LIST =====${PLSQL_SERVICE_LINES}
        -- ===== END SERVICE LIST =====
        RETURN l_services;
    END get_service_list;

    -- --------------------------------------------------------
    -- MANAGE_SERVICES: Start or stop services based on role
    -- --------------------------------------------------------
    PROCEDURE MANAGE_SERVICES IS
        l_role     VARCHAR2(30);
        l_services service_list_t;
    BEGIN
        SELECT DATABASE_ROLE INTO l_role FROM V\$DATABASE;
        l_services := get_service_list();

        IF l_role = 'PRIMARY' THEN
            -- Start services on PRIMARY
            FOR i IN 1..l_services.COUNT LOOP
                BEGIN
                    DBMS_SERVICE.START_SERVICE(l_services(i));
                EXCEPTION
                    WHEN OTHERS THEN NULL;
                END;
            END LOOP;
        ELSE
            -- Stop services on STANDBY (any non-PRIMARY role)
            FOR i IN 1..l_services.COUNT LOOP
                BEGIN
                    DBMS_SERVICE.STOP_SERVICE(l_services(i));
                EXCEPTION
                    WHEN OTHERS THEN NULL;
                END;
            END LOOP;
        END IF;
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

# Check package status
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

SQL_OUTPUT_FILE="${NFS_SHARE}/dg_service_mgr_${PRIMARY_DB_UNIQUE_NAME}.sql"

cat > "$SQL_OUTPUT_FILE" << EOSQLFILE
-- ============================================================
-- DG_SERVICE_MGR: Role-Aware Service Management
-- ============================================================
-- Generated: $(date '+%Y-%m-%d %H:%M:%S')
-- Primary DB: ${PRIMARY_DB_UNIQUE_NAME}
-- Standby DB: ${STANDBY_DB_UNIQUE_NAME}
--
-- Services are started on PRIMARY, stopped on STANDBY.
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

    TYPE service_list_t IS TABLE OF VARCHAR2(64);

    FUNCTION get_service_list RETURN service_list_t IS
        l_services service_list_t := service_list_t();
    BEGIN
        -- ===== BEGIN SERVICE LIST =====${PLSQL_SERVICE_LINES}
        -- ===== END SERVICE LIST =====
        RETURN l_services;
    END get_service_list;

    PROCEDURE MANAGE_SERVICES IS
        l_role     VARCHAR2(30);
        l_services service_list_t;
    BEGIN
        SELECT DATABASE_ROLE INTO l_role FROM V\$DATABASE;
        l_services := get_service_list();

        IF l_role = 'PRIMARY' THEN
            FOR i IN 1..l_services.COUNT LOOP
                BEGIN
                    DBMS_SERVICE.START_SERVICE(l_services(i));
                EXCEPTION
                    WHEN OTHERS THEN NULL;
                END;
            END LOOP;
        ELSE
            FOR i IN 1..l_services.COUNT LOOP
                BEGIN
                    DBMS_SERVICE.STOP_SERVICE(l_services(i));
                EXCEPTION
                    WHEN OTHERS THEN NULL;
                END;
            END LOOP;
        END IF;
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

print_summary "SUCCESS" "Role-aware service trigger deployed"

echo ""
echo "DEPLOYMENT COMPLETE"
echo "==================="
echo ""
echo "  Package : SYS.DG_SERVICE_MGR           (VALID)"
echo "  Trigger : SYS.TRG_MANAGE_SERVICES_ROLE_CHG (ENABLED)"
echo "  Trigger : SYS.TRG_MANAGE_SERVICES_STARTUP  (ENABLED)"
echo ""
echo "  Services managed:"
for svc in "${SERVICE_LIST[@]}"; do
    printf "    - %s\n" "$svc"
done
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
echo "    SELECT NAME FROM V\$ACTIVE_SERVICES;"
echo ""
