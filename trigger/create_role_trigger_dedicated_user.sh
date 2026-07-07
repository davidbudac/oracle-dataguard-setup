#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Create Role-Aware Service Trigger
#                           (Dedicated User - Non-SYS)
# ============================================================
# Run this script on the PRIMARY database server after
# Data Guard setup is complete (Step 7 verification passes).
#
# This is an alternative to create_role_trigger.sh that creates
# a dedicated database user instead of placing objects in SYS.
#
# Standalone: this script does NOT require the setup-time
# standby_config_*.env file or the NFS share. It discovers the
# topology (primary/standby DB_UNIQUE_NAME) from the database itself,
# the same way trigger/create_role_trigger_cdb.sh does. If a
# standby_config_*.env file happens to be present on the NFS share it
# is used only as a fallback label when self-discovery cannot find a
# peer. The generated SQL is written to the NFS share when one is
# available, otherwise to the current directory.
#
# This script:
# - Creates a dedicated user (DG_ADMIN or C##DG_ADMIN for CDB)
# - Grants only the required privileges
# - Discovers user-defined services running on the database
# - Allows you to review/edit the service list
# - Creates PL/SQL package <USER>.DG_SERVICE_MGR
# - Creates trigger <USER>.TRG_MANAGE_SERVICES_ROLE_CHG
# - Creates trigger <USER>.TRG_MANAGE_SERVICES_STARTUP
#
# Services are automatically started on PRIMARY and stopped
# on STANDBY. Objects replicate to standby via redo.
#
# ALERT LOG WRITES (least-privilege trade-off):
# DG_SERVICE_MGR needs to record failures (e.g. a service that
# would not start) in the alert log. The only supported way to do
# that is SYS.DBMS_SYSTEM.KSDWRT - an undocumented package with
# broad, unrelated capabilities. Granting EXECUTE on DBMS_SYSTEM
# directly to the dedicated user would defeat the least-privilege
# purpose of this script variant. Instead, this script creates a
# single-purpose, SYS-owned, definer-rights wrapper procedure,
# SYS.DG_ALERT_LOG_MSG(p_msg VARCHAR2), whose body only calls
# SYS.DBMS_SYSTEM.KSDWRT(2, p_msg), and grants EXECUTE on that
# narrow wrapper (not on DBMS_SYSTEM) to the dedicated user. If
# SYS.DG_ALERT_LOG_MSG is ever dropped, service start/stop still
# works, but log_service_issue's WHEN OTHERS THEN NULL handler
# silently swallows the resulting error - failed attempts would
# then leave no alert log trail.
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

print_banner "Create Role-Aware Service Trigger (Dedicated User)"

# Initialize logging
init_log "create_role_trigger_dedicated"

# ============================================================
# Pre-flight Checks
# ============================================================

log_section "Pre-flight Checks"

check_oracle_env || exit 1
check_db_connection || exit 1

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
# Discover Topology (standalone - no config file required)
# ============================================================

log_section "Discovering Data Guard Topology"

PRIMARY_DB_UNIQUE_NAME=$(sqlplus -s / as sysdba << 'EOSQL'
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT DB_UNIQUE_NAME FROM V$DATABASE;
EXIT;
EOSQL
)
PRIMARY_DB_UNIQUE_NAME=$(echo "$PRIMARY_DB_UNIQUE_NAME" | tr -d ' \n\r')

if [[ -z "$PRIMARY_DB_UNIQUE_NAME" ]]; then
    log_error "Could not determine the primary DB_UNIQUE_NAME from V\$DATABASE"
    exit 1
fi

# The peer (standby) name comes from V$DATAGUARD_CONFIG and is used only to
# label the generated SQL file, so it is optional.
STANDBY_DB_UNIQUE_NAME=$(sqlplus -s / as sysdba << EOSQL
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT DB_UNIQUE_NAME FROM V\$DATAGUARD_CONFIG
WHERE DB_UNIQUE_NAME <> '${PRIMARY_DB_UNIQUE_NAME}' AND ROWNUM = 1;
EXIT;
EOSQL
)
STANDBY_DB_UNIQUE_NAME=$(echo "$STANDBY_DB_UNIQUE_NAME" | tr -d ' \n\r')

if [[ -z "$STANDBY_DB_UNIQUE_NAME" ]]; then
    # Self-discovery could not find a peer in V$DATAGUARD_CONFIG. Fall back to
    # a setup-time standby_config_*.env file if one happens to exist on the
    # NFS share - purely for this label; nothing else in this script depends
    # on it. Quiet and non-interactive: this is a best-effort label only.
    CONFIG_CANDIDATE=$(ls -1t "${NFS_SHARE}"/standby_config_*.env 2>/dev/null | head -1) || true
    if [[ -n "$CONFIG_CANDIDATE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_CANDIDATE"
        log_info "Standby DB_UNIQUE_NAME (from ${CONFIG_CANDIDATE}): ${STANDBY_DB_UNIQUE_NAME:-UNKNOWN}"
    fi
fi

log_info "Primary DB_UNIQUE_NAME: $PRIMARY_DB_UNIQUE_NAME"
if [[ -n "$STANDBY_DB_UNIQUE_NAME" ]]; then
    log_info "Standby DB_UNIQUE_NAME: $STANDBY_DB_UNIQUE_NAME"
else
    log_warn "No peer found in V\$DATAGUARD_CONFIG (and no standby_config_*.env available) - standby will be labelled UNKNOWN in the generated SQL"
    STANDBY_DB_UNIQUE_NAME="UNKNOWN"
fi

# Re-initialize log now that the DB name is known
init_log "create_role_trigger_dedicated_${PRIMARY_DB_UNIQUE_NAME}"

# ============================================================
# Detect CDB and Determine Schema Name
# ============================================================

log_section "Determining Schema Name"

IS_CDB=$(sqlplus -s / as sysdba << 'EOSQL'
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT CDB FROM V$DATABASE;
EXIT;
EOSQL
)
IS_CDB=$(echo "$IS_CDB" | tr -d ' \n\r')

if [[ "$IS_CDB" == "YES" ]]; then
    DEFAULT_SCHEMA="C##DG_ADMIN"
    log_info "CDB detected - common user prefix C## required"
else
    DEFAULT_SCHEMA="DG_ADMIN"
fi

echo ""
printf "Enter schema name for DG service objects [%s]: " "$DEFAULT_SCHEMA"
read USER_SCHEMA
USER_SCHEMA=$(echo "$USER_SCHEMA" | tr -d ' \n\r')
if [[ -z "$USER_SCHEMA" ]]; then
    USER_SCHEMA="$DEFAULT_SCHEMA"
fi
USER_SCHEMA=$(echo "$USER_SCHEMA" | tr '[:lower:]' '[:upper:]')

# Reject SYS/SYSTEM - this script is the non-SYS alternative
if [[ "$USER_SCHEMA" == "SYS" ]] || [[ "$USER_SCHEMA" == "SYSTEM" ]]; then
    log_error "$USER_SCHEMA is a reserved schema. Use create_role_trigger.sh for SYS deployment."
    exit 1
fi

# Validate CDB naming
if [[ "$IS_CDB" == "YES" ]] && [[ "$USER_SCHEMA" != C##* ]]; then
    log_error "CDB requires common user prefix C## (e.g., C##DG_ADMIN)"
    exit 1
fi

# Validate schema name format: this value is interpolated directly into
# CREATE USER / GRANT statements and package/trigger DDL below, so it must
# be a well-formed Oracle identifier before it ever reaches sqlplus. Strip
# an already-verified C## common-user prefix first, then apply the same
# leading-alpha identifier rule used for service/container names.
SCHEMA_NAME_TO_CHECK="$USER_SCHEMA"
if [[ "$IS_CDB" == "YES" ]]; then
    SCHEMA_NAME_TO_CHECK="${USER_SCHEMA#C##}"
fi
if ! echo "$SCHEMA_NAME_TO_CHECK" | grep -q '^[A-Za-z][A-Za-z0-9_$]*$'; then
    log_error "Invalid schema name: $USER_SCHEMA"
    log_error "Schema names must start with a letter and contain only letters, numbers, underscore, and dollar sign"
    exit 1
fi
if [[ ${#USER_SCHEMA} -gt 128 ]]; then
    log_error "Schema name too long (max 128 chars): $USER_SCHEMA"
    exit 1
fi

# Set CONTAINER=ALL clause for CDB common user operations
if [[ "$IS_CDB" == "YES" ]]; then
    CONTAINER_CLAUSE=" CONTAINER=ALL"
else
    CONTAINER_CLAUSE=""
fi

log_info "Schema: $USER_SCHEMA"

# ============================================================
# Check if User Already Exists
# ============================================================

log_section "Checking for Existing User"

USER_EXISTS=$(sqlplus -s / as sysdba << EOSQL
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT COUNT(*) FROM DBA_USERS WHERE USERNAME = '${USER_SCHEMA}';
EXIT;
EOSQL
)
USER_EXISTS=$(echo "$USER_EXISTS" | tr -d ' \n\r')

CREATE_USER=true
if [[ "$USER_EXISTS" != "0" ]]; then
    log_info "User $USER_SCHEMA already exists"

    # Check if it has the required privileges
    PRIV_COUNT=$(sqlplus -s / as sysdba << EOSQL
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT COUNT(*) FROM DBA_SYS_PRIVS WHERE GRANTEE = '${USER_SCHEMA}' AND PRIVILEGE = 'ADMINISTER DATABASE TRIGGER';
EXIT;
EOSQL
    )
    PRIV_COUNT=$(echo "$PRIV_COUNT" | tr -d ' \n\r')

    if [[ "$PRIV_COUNT" != "0" ]]; then
        log_info "User already has required privileges"
    else
        log_warn "User exists but may be missing required privileges - grants will be applied"
    fi
    CREATE_USER=false
fi

# ============================================================
# Create/Replace SYS Alert Log Helper Procedure
# ============================================================
# Narrow, single-purpose, definer-rights wrapper around
# SYS.DBMS_SYSTEM.KSDWRT so the dedicated user only ever needs
# EXECUTE on this procedure, never on DBMS_SYSTEM itself. Created
# idempotently (CREATE OR REPLACE) on every run, in the current
# container (CDB$ROOT for a CDB), matching where the triggers run.

log_section "SYS Alert Log Helper Procedure"

log_info "Creating/replacing SYS.DG_ALERT_LOG_MSG (idempotent)..."
confirm_approval_action "Create/replace SYS.DG_ALERT_LOG_MSG helper procedure" "sqlplus -s / as sysdba <create SYS.DG_ALERT_LOG_MSG>" || exit 1

# Capture status explicitly: under `set -e` a bare assignment followed by a
# `$?` check would abort before the check ever ran.
HELPER_RC=0
HELPER_RESULT=$(sqlplus -s / as sysdba << 'EOSQL'
SET HEADING OFF FEEDBACK ON VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

CREATE OR REPLACE PROCEDURE SYS.DG_ALERT_LOG_MSG (p_msg IN VARCHAR2) AS
BEGIN
    SYS.DBMS_SYSTEM.KSDWRT(2, p_msg);
END DG_ALERT_LOG_MSG;
/

SELECT 'HELPER_STATUS=' || STATUS FROM DBA_OBJECTS WHERE OBJECT_NAME = 'DG_ALERT_LOG_MSG' AND OBJECT_TYPE = 'PROCEDURE' AND OWNER = 'SYS';

EXIT;
EOSQL
) || HELPER_RC=$?
echo "$HELPER_RESULT" | while IFS= read -r line; do
    [ -n "$LOG_FILE" ] && echo "  $line" >> "$LOG_FILE" || :
done
if [[ $HELPER_RC -ne 0 ]] || echo "$HELPER_RESULT" | grep -q "^ORA-"; then
    log_error "Failed to create SYS.DG_ALERT_LOG_MSG helper procedure"
    echo "$HELPER_RESULT"
    exit 1
fi

HELPER_STATUS=$(echo "$HELPER_RESULT" | grep "HELPER_STATUS=" | sed 's/HELPER_STATUS=//' | tr -d ' \n\r')
if [[ "$HELPER_STATUS" == "VALID" ]]; then
    log_info "SYS.DG_ALERT_LOG_MSG: VALID"
else
    log_error "SYS.DG_ALERT_LOG_MSG: ${HELPER_STATUS:-NOT FOUND}"
    exit 1
fi

# ============================================================
# Create User and Grant Privileges
# ============================================================

log_section "User and Privileges"

if [[ "$CREATE_USER" == "true" ]]; then
    log_info "Creating user $USER_SCHEMA..."
    USER_PASSWORD=$(prompt_password "Enter password for $USER_SCHEMA")
    if [[ -z "$USER_PASSWORD" ]]; then
        log_error "Password cannot be empty"
        exit 1
    fi

    confirm_approval_action "Create user $USER_SCHEMA and grant privileges" "sqlplus -s / as sysdba <create user and grant privileges>" || exit 1

    CREATE_RESULT=$(sqlplus -s / as sysdba << EOSQL
SET HEADING OFF FEEDBACK ON VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

CREATE USER ${USER_SCHEMA} IDENTIFIED BY "${USER_PASSWORD}"
    DEFAULT TABLESPACE SYSTEM
    TEMPORARY TABLESPACE TEMP
    QUOTA 0 ON SYSTEM${CONTAINER_CLAUSE};

GRANT CREATE SESSION TO ${USER_SCHEMA}${CONTAINER_CLAUSE};
GRANT CREATE PROCEDURE TO ${USER_SCHEMA}${CONTAINER_CLAUSE};
GRANT ADMINISTER DATABASE TRIGGER TO ${USER_SCHEMA}${CONTAINER_CLAUSE};
GRANT EXECUTE ON DBMS_SERVICE TO ${USER_SCHEMA}${CONTAINER_CLAUSE};
GRANT SELECT ON V_\$DATABASE TO ${USER_SCHEMA}${CONTAINER_CLAUSE};
GRANT EXECUTE ON SYS.DG_ALERT_LOG_MSG TO ${USER_SCHEMA}${CONTAINER_CLAUSE};

EXIT;
EOSQL
    )
    CREATE_RC=$?
    echo "$CREATE_RESULT" | while IFS= read -r line; do
        [ -n "$LOG_FILE" ] && echo "  $line" >> "$LOG_FILE" || :
    done
    if [[ $CREATE_RC -ne 0 ]] || echo "$CREATE_RESULT" | grep -q "^ORA-"; then
        log_error "Failed to create user or grant privileges"
        echo "$CREATE_RESULT"
        exit 1
    fi
    log_info "User $USER_SCHEMA created with required privileges"
else
    log_info "Applying grants to existing user $USER_SCHEMA..."

    confirm_approval_action "Grant privileges to $USER_SCHEMA" "sqlplus -s / as sysdba <grant privileges>" || exit 1

    GRANT_RESULT=$(sqlplus -s / as sysdba << EOSQL
SET HEADING OFF FEEDBACK ON VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE

GRANT CREATE SESSION TO ${USER_SCHEMA}${CONTAINER_CLAUSE};
GRANT CREATE PROCEDURE TO ${USER_SCHEMA}${CONTAINER_CLAUSE};
GRANT ADMINISTER DATABASE TRIGGER TO ${USER_SCHEMA}${CONTAINER_CLAUSE};
GRANT EXECUTE ON DBMS_SERVICE TO ${USER_SCHEMA}${CONTAINER_CLAUSE};
GRANT SELECT ON V_\$DATABASE TO ${USER_SCHEMA}${CONTAINER_CLAUSE};
GRANT EXECUTE ON SYS.DG_ALERT_LOG_MSG TO ${USER_SCHEMA}${CONTAINER_CLAUSE};

EXIT;
EOSQL
    )
    GRANT_RC=$?
    echo "$GRANT_RESULT" | while IFS= read -r line; do
        [ -n "$LOG_FILE" ] && echo "  $line" >> "$LOG_FILE" || :
    done
    if [[ $GRANT_RC -ne 0 ]] || echo "$GRANT_RESULT" | grep -q "^ORA-"; then
        log_error "Failed to grant privileges to $USER_SCHEMA"
        echo "$GRANT_RESULT"
        exit 1
    fi
    log_info "Privileges applied to $USER_SCHEMA"
fi

# ============================================================
# Discover User-Defined Services
# ============================================================

log_section "Discovering User-Defined Services"

log_info "Querying active services (excluding system services)..."

# Keep stderr visible: $(...) captures only stdout (the service names), so a
# missing-script (SP2-0310) or ORA- error now shows on the terminal instead of
# being silently swallowed into an empty result.
SERVICE_OUTPUT=$(run_sql_query "get_user_services.sql" || true)

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
                if echo "$new_svc" | grep -q '^[A-Za-z][A-Za-z0-9_.$]*$'; then
                    SERVICE_LIST+=("$new_svc")
                    log_info "Added service: $new_svc"
                else
                    log_error "Invalid service name: $new_svc"
                    log_error "Service names must start with a letter and contain only letters, numbers, underscore, dot, and dollar sign"
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
                if echo "$new_svc" | grep -q '^[A-Za-z][A-Za-z0-9_.$]*$'; then
                    SERVICE_LIST+=("$new_svc")
                    log_info "Added service: $new_svc"
                else
                    log_error "Invalid service name: $new_svc"
                    log_error "Service names must start with a letter and contain only letters, numbers, underscore, dot, and dollar sign"
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
    if ! echo "$svc" | grep -q '^[A-Za-z][A-Za-z0-9_.$]*$'; then
        log_error "Invalid service name: $svc"
        log_error "Service names must start with a letter and contain only letters, numbers, underscore, dot, and dollar sign"
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

PKG_EXISTS=$(sqlplus -s / as sysdba << EOSQL
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
SELECT COUNT(*) FROM DBA_OBJECTS WHERE OBJECT_NAME = 'DG_SERVICE_MGR' AND OWNER = '${USER_SCHEMA}';
EXIT;
EOSQL
)
PKG_EXISTS=$(echo "$PKG_EXISTS" | tr -d ' \n\r')

if [[ "$PKG_EXISTS" != "0" ]]; then
    log_warn "Package ${USER_SCHEMA}.DG_SERVICE_MGR already exists"
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
echo "The following objects will be created in the ${USER_SCHEMA} schema:"
echo ""
echo "  Package : ${USER_SCHEMA}.DG_SERVICE_MGR"
echo "  Trigger : ${USER_SCHEMA}.TRG_MANAGE_SERVICES_ROLE_CHG (AFTER DB_ROLE_CHANGE)"
echo "  Trigger : ${USER_SCHEMA}.TRG_MANAGE_SERVICES_STARTUP  (AFTER STARTUP)"
echo ""
echo "  (SYS.DG_ALERT_LOG_MSG - a narrow alert-log helper procedure - was"
echo "   created/replaced as SYS earlier in this run; see above.)"
echo ""
echo "  Privileges granted:"
echo "    CREATE SESSION, CREATE PROCEDURE, ADMINISTER DATABASE TRIGGER,"
echo "    EXECUTE ON DBMS_SERVICE, SELECT ON V_\$DATABASE,"
echo "    EXECUTE ON SYS.DG_ALERT_LOG_MSG (not DBMS_SYSTEM)"
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

log_info "Creating package ${USER_SCHEMA}.DG_SERVICE_MGR..."
log_cmd "sqlplus / as sysdba:" "CREATE OR REPLACE PACKAGE ${USER_SCHEMA}.DG_SERVICE_MGR ..."
confirm_approval_action "Deploy DG_SERVICE_MGR package and role-change triggers" "sqlplus -s / as sysdba <deploy ${USER_SCHEMA}.DG_SERVICE_MGR package and triggers>" || exit 1

DEPLOY_RESULT=$(sqlplus -s / as sysdba << EOSQL
SET HEADING OFF FEEDBACK ON VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON SERVEROUTPUT ON

-- ============================================================
-- Package Specification
-- ============================================================
CREATE OR REPLACE PACKAGE ${USER_SCHEMA}.DG_SERVICE_MGR AS
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
CREATE OR REPLACE PACKAGE BODY ${USER_SCHEMA}.DG_SERVICE_MGR AS

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

    PROCEDURE log_service_issue(
        p_action  IN VARCHAR2,
        p_service IN VARCHAR2,
        p_error   IN VARCHAR2
    ) IS
    BEGIN
        SYS.DG_ALERT_LOG_MSG(
            'DG_SERVICE_MGR ' || p_action || ' failed for service ' || p_service || ': ' || SUBSTR(p_error, 1, 300)
        );
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END log_service_issue;

    -- --------------------------------------------------------
    -- MANAGE_SERVICES: Start or stop services based on role
    -- --------------------------------------------------------
    PROCEDURE MANAGE_SERVICES IS
        l_role     VARCHAR2(30);
        l_services service_list_t;
    BEGIN
        SELECT DATABASE_ROLE INTO l_role FROM SYS.V_\$DATABASE;
        l_services := get_service_list();

        IF l_role = 'PRIMARY' THEN
            -- Start services on PRIMARY
            FOR i IN 1..l_services.COUNT LOOP
                BEGIN
                    SYS.DBMS_SERVICE.START_SERVICE(l_services(i));
                EXCEPTION
                    WHEN OTHERS THEN
                        log_service_issue('START', l_services(i), SQLERRM);
                END;
            END LOOP;
        ELSE
            -- Stop services on STANDBY (any non-PRIMARY role)
            FOR i IN 1..l_services.COUNT LOOP
                BEGIN
                    SYS.DBMS_SERVICE.STOP_SERVICE(l_services(i));
                EXCEPTION
                    WHEN OTHERS THEN
                        log_service_issue('STOP', l_services(i), SQLERRM);
                END;
            END LOOP;
        END IF;
    END MANAGE_SERVICES;

END DG_SERVICE_MGR;
/

-- ============================================================
-- Trigger: AFTER DB_ROLE_CHANGE (fires on switchover/failover)
-- ============================================================
CREATE OR REPLACE TRIGGER ${USER_SCHEMA}.TRG_MANAGE_SERVICES_ROLE_CHG
    AFTER DB_ROLE_CHANGE ON DATABASE
BEGIN
    ${USER_SCHEMA}.DG_SERVICE_MGR.MANAGE_SERVICES;
END;
/

-- ============================================================
-- Trigger: AFTER STARTUP (fires when database opens)
-- ============================================================
CREATE OR REPLACE TRIGGER ${USER_SCHEMA}.TRG_MANAGE_SERVICES_STARTUP
    AFTER STARTUP ON DATABASE
BEGIN
    ${USER_SCHEMA}.DG_SERVICE_MGR.MANAGE_SERVICES;
END;
/

-- Verification
SELECT 'PKG_STATUS=' || STATUS FROM DBA_OBJECTS WHERE OBJECT_NAME = 'DG_SERVICE_MGR' AND OBJECT_TYPE = 'PACKAGE BODY' AND OWNER = '${USER_SCHEMA}';
SELECT 'TRG_ROLE_CHG=' || STATUS FROM DBA_TRIGGERS WHERE TRIGGER_NAME = 'TRG_MANAGE_SERVICES_ROLE_CHG' AND OWNER = '${USER_SCHEMA}';
SELECT 'TRG_STARTUP=' || STATUS FROM DBA_TRIGGERS WHERE TRIGGER_NAME = 'TRG_MANAGE_SERVICES_STARTUP' AND OWNER = '${USER_SCHEMA}';

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
    log_info "Package ${USER_SCHEMA}.DG_SERVICE_MGR: VALID"
else
    log_error "Package ${USER_SCHEMA}.DG_SERVICE_MGR: ${PKG_STATUS:-NOT FOUND}"
    DEPLOY_OK=false
fi

if [[ "$TRG_ROLE_STATUS" == "ENABLED" ]]; then
    log_info "Trigger ${USER_SCHEMA}.TRG_MANAGE_SERVICES_ROLE_CHG: ENABLED"
else
    log_error "Trigger ${USER_SCHEMA}.TRG_MANAGE_SERVICES_ROLE_CHG: ${TRG_ROLE_STATUS:-NOT FOUND}"
    DEPLOY_OK=false
fi

if [[ "$TRG_STARTUP_STATUS" == "ENABLED" ]]; then
    log_info "Trigger ${USER_SCHEMA}.TRG_MANAGE_SERVICES_STARTUP: ENABLED"
else
    log_error "Trigger ${USER_SCHEMA}.TRG_MANAGE_SERVICES_STARTUP: ${TRG_STARTUP_STATUS:-NOT FOUND}"
    DEPLOY_OK=false
fi

if [[ "$DEPLOY_OK" != "true" ]]; then
    log_error "Deployment verification failed"
    echo ""
    echo "Check for compilation errors:"
    echo "  SELECT * FROM DBA_ERRORS WHERE OWNER = '${USER_SCHEMA}' AND NAME = 'DG_SERVICE_MGR';"
    echo ""
    exit 1
fi

# ============================================================
# Save Generated SQL to NFS
# ============================================================

log_section "Saving Generated SQL"

# Write to the NFS share when one is mounted and writable (keeps parity with
# the previous config-driven workflow); otherwise fall back to the current
# directory with a clear notice, since this script no longer requires NFS.
if [[ -d "$NFS_SHARE" && -w "$NFS_SHARE" ]]; then
    SQL_OUTPUT_FILE="${NFS_SHARE}/dg_service_mgr_dedicated_${PRIMARY_DB_UNIQUE_NAME}.sql"
else
    SQL_OUTPUT_FILE="./dg_service_mgr_dedicated_${PRIMARY_DB_UNIQUE_NAME}.sql"
    log_warn "NFS share (${NFS_SHARE}) not available/writable - writing generated SQL to the current directory instead"
fi

cat > "$SQL_OUTPUT_FILE" << EOSQLFILE
-- ============================================================
-- DG_SERVICE_MGR: Role-Aware Service Management (Dedicated User)
-- ============================================================
-- Generated: $(date '+%Y-%m-%d %H:%M:%S')
-- Schema:     ${USER_SCHEMA}
-- Primary DB: ${PRIMARY_DB_UNIQUE_NAME}
-- Standby DB: ${STANDBY_DB_UNIQUE_NAME}
--
-- Services are started on PRIMARY, stopped on STANDBY.
-- To modify the service list, edit the get_service_list function
-- in the package body between the BEGIN/END SERVICE LIST markers.
-- ============================================================

-- ============================================================
-- User and Privileges (run as SYS if user does not exist)
-- ============================================================
-- CREATE USER ${USER_SCHEMA} IDENTIFIED BY "<password>"
--     DEFAULT TABLESPACE SYSTEM
--     TEMPORARY TABLESPACE TEMP
--     QUOTA 0 ON SYSTEM${CONTAINER_CLAUSE};

-- SYS-owned, definer-rights alert-log helper (idempotent). Lets the
-- dedicated user log to the alert log without EXECUTE on DBMS_SYSTEM.
CREATE OR REPLACE PROCEDURE SYS.DG_ALERT_LOG_MSG (p_msg IN VARCHAR2) AS
BEGIN
    SYS.DBMS_SYSTEM.KSDWRT(2, p_msg);
END DG_ALERT_LOG_MSG;
/

GRANT CREATE SESSION TO ${USER_SCHEMA}${CONTAINER_CLAUSE};
GRANT CREATE PROCEDURE TO ${USER_SCHEMA}${CONTAINER_CLAUSE};
GRANT ADMINISTER DATABASE TRIGGER TO ${USER_SCHEMA}${CONTAINER_CLAUSE};
GRANT EXECUTE ON DBMS_SERVICE TO ${USER_SCHEMA}${CONTAINER_CLAUSE};
GRANT SELECT ON V_\$DATABASE TO ${USER_SCHEMA}${CONTAINER_CLAUSE};
GRANT EXECUTE ON SYS.DG_ALERT_LOG_MSG TO ${USER_SCHEMA}${CONTAINER_CLAUSE};

-- Package Specification
CREATE OR REPLACE PACKAGE ${USER_SCHEMA}.DG_SERVICE_MGR AS
    PROCEDURE MANAGE_SERVICES;
END DG_SERVICE_MGR;
/

-- Package Body
CREATE OR REPLACE PACKAGE BODY ${USER_SCHEMA}.DG_SERVICE_MGR AS

    TYPE service_list_t IS TABLE OF VARCHAR2(64);

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
        SYS.DG_ALERT_LOG_MSG(
            'DG_SERVICE_MGR ' || p_action || ' failed for service ' || p_service || ': ' || SUBSTR(p_error, 1, 300)
        );
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END log_service_issue;

    PROCEDURE MANAGE_SERVICES IS
        l_role     VARCHAR2(30);
        l_services service_list_t;
    BEGIN
        SELECT DATABASE_ROLE INTO l_role FROM SYS.V_\$DATABASE;
        l_services := get_service_list();

        IF l_role = 'PRIMARY' THEN
            FOR i IN 1..l_services.COUNT LOOP
                BEGIN
                    SYS.DBMS_SERVICE.START_SERVICE(l_services(i));
                EXCEPTION
                    WHEN OTHERS THEN
                        log_service_issue('START', l_services(i), SQLERRM);
                END;
            END LOOP;
        ELSE
            FOR i IN 1..l_services.COUNT LOOP
                BEGIN
                    SYS.DBMS_SERVICE.STOP_SERVICE(l_services(i));
                EXCEPTION
                    WHEN OTHERS THEN
                        log_service_issue('STOP', l_services(i), SQLERRM);
                END;
            END LOOP;
        END IF;
    END MANAGE_SERVICES;

END DG_SERVICE_MGR;
/

-- Trigger: AFTER DB_ROLE_CHANGE
CREATE OR REPLACE TRIGGER ${USER_SCHEMA}.TRG_MANAGE_SERVICES_ROLE_CHG
    AFTER DB_ROLE_CHANGE ON DATABASE
BEGIN
    ${USER_SCHEMA}.DG_SERVICE_MGR.MANAGE_SERVICES;
END;
/

-- Trigger: AFTER STARTUP
CREATE OR REPLACE TRIGGER ${USER_SCHEMA}.TRG_MANAGE_SERVICES_STARTUP
    AFTER STARTUP ON DATABASE
BEGIN
    ${USER_SCHEMA}.DG_SERVICE_MGR.MANAGE_SERVICES;
END;
/

-- ============================================================
-- Removal Commands (if needed):
-- ============================================================
-- DROP TRIGGER ${USER_SCHEMA}.TRG_MANAGE_SERVICES_ROLE_CHG;
-- DROP TRIGGER ${USER_SCHEMA}.TRG_MANAGE_SERVICES_STARTUP;
-- DROP PACKAGE ${USER_SCHEMA}.DG_SERVICE_MGR;
-- DROP USER ${USER_SCHEMA};
-- Note: SYS.DG_ALERT_LOG_MSG may be shared by other DG deployments
-- on this database. Only drop it if this is the last consumer:
-- DROP PROCEDURE SYS.DG_ALERT_LOG_MSG;
-- ============================================================
EOSQLFILE

log_info "Generated SQL saved to: $SQL_OUTPUT_FILE"

# ============================================================
# Summary
# ============================================================

print_summary "SUCCESS" "Role-aware service trigger deployed (dedicated user)"

echo ""
echo "DEPLOYMENT COMPLETE"
echo "==================="
echo ""
echo "  Schema  : ${USER_SCHEMA}"
echo "  Package : ${USER_SCHEMA}.DG_SERVICE_MGR           (VALID)"
echo "  Trigger : ${USER_SCHEMA}.TRG_MANAGE_SERVICES_ROLE_CHG (ENABLED)"
echo "  Trigger : ${USER_SCHEMA}.TRG_MANAGE_SERVICES_STARTUP  (ENABLED)"
echo "  Helper  : SYS.DG_ALERT_LOG_MSG                    (VALID)"
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
echo "PRIVILEGES GRANTED"
echo "==================="
echo ""
echo "  CREATE SESSION                - Allow login"
echo "  CREATE PROCEDURE              - Package compilation"
echo "  ADMINISTER DATABASE TRIGGER   - Database event triggers"
echo "  EXECUTE ON DBMS_SERVICE       - Start/stop services"
echo "  SELECT ON V_\$DATABASE         - Read database role"
echo "  EXECUTE ON SYS.DG_ALERT_LOG_MSG - Alert log writes (narrow wrapper,"
echo "                                  NOT DBMS_SYSTEM itself)"
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
echo "    DROP TRIGGER ${USER_SCHEMA}.TRG_MANAGE_SERVICES_ROLE_CHG;"
echo "    DROP TRIGGER ${USER_SCHEMA}.TRG_MANAGE_SERVICES_STARTUP;"
echo "    DROP PACKAGE ${USER_SCHEMA}.DG_SERVICE_MGR;"
echo "    DROP USER ${USER_SCHEMA};  -- only if no longer needed"
echo ""
echo "TEST MANUALLY"
echo "============="
echo ""
echo "    EXEC ${USER_SCHEMA}.DG_SERVICE_MGR.MANAGE_SERVICES;"
echo "    SELECT NAME FROM V\$ACTIVE_SERVICES;"
echo ""
