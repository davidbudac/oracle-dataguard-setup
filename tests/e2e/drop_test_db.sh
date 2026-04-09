#!/usr/bin/env bash
# =============================================================================
# Drop a Test Database and Clean Up
# =============================================================================
#
# Drops a database created by create_test_db.sh (or run_e2e_test.sh) and
# removes all associated files: data files, archive logs, config files,
# DG broker files, TNS entries, and oratab entries.
#
# Cleanup is best-effort: individual failures don't abort the script.
#
# Uses the same SSH/jump-host connection pattern as the other E2E scripts.
#
# Usage:
#   bash tests/e2e/drop_test_db.sh                  # Drop config.env default DB
#   bash tests/e2e/drop_test_db.sh -n mydb           # Drop specific database
#   bash tests/e2e/drop_test_db.sh --standby-too     # Also clean standby host
#
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Load config --------------------------------------------------------------
if [[ ! -f "${SCRIPT_DIR}/config.env" ]]; then
    echo "ERROR: config.env not found. Copy config.env.template to config.env and fill in values."
    exit 1
fi

source "${SCRIPT_DIR}/config.env"

# -- Parse args ---------------------------------------------------------------
CUSTOM_DB_NAME=""
CUSTOM_PASSWORD=""
CLEAN_STANDBY=false
CLEAN_NFS=false
FORCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)          CUSTOM_DB_NAME="$2"; shift 2 ;;
        -p|--password)      CUSTOM_PASSWORD="$2"; shift 2 ;;
        --standby-too)      CLEAN_STANDBY=true; shift ;;
        --nfs-too)          CLEAN_NFS=true; shift ;;
        -f|--force)         FORCE=true; shift ;;
        -h|--help)
            printf "Usage: bash tests/e2e/drop_test_db.sh [-n name] [--standby-too] [--nfs-too] [-f]\n"
            printf "  -n, --name NAME        Database name to drop (default: from config.env)\n"
            printf "  -p, --password PASS    SYS password (default: from config.env)\n"
            printf "  --standby-too          Also clean up standby host\n"
            printf "  --nfs-too              Also clean up NFS share files\n"
            printf "  -f, --force            Skip confirmation prompt\n"
            exit 0 ;;
        *) printf "Unknown option: %s\n" "$1"; exit 1 ;;
    esac
done

# Apply overrides
[[ -n "$CUSTOM_DB_NAME" ]] && TEST_DB_NAME="$CUSTOM_DB_NAME" && TEST_DB_UNIQUE_NAME="$CUSTOM_DB_NAME"
[[ -n "$CUSTOM_PASSWORD" ]] && TEST_SYS_PASSWORD="$CUSTOM_PASSWORD"

TEST_ORACLE_SID="${TEST_DB_NAME}"
TEST_STANDBY_DB_UNIQUE_NAME="${TEST_STANDBY_DB_UNIQUE_NAME:-${TEST_DB_NAME}_s}"

# -- Validate ------------------------------------------------------------------
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
log_warn() { log "${YELLOW}!!${NC}    $1"; }
log_step() { printf "\n${BOLD}${CYAN}── %s${NC}\n" "$1"; }

# -- SSH setup ----------------------------------------------------------------
JUMP_KEY_OPT=""
[[ -n "${JUMP_KEY:-}" ]] && JUMP_KEY_OPT="-i ${JUMP_KEY}"
JUMP_SSH_PORT="${JUMP_SSH_PORT:-22}"
PRIMARY_SSH_PORT="${PRIMARY_SSH_PORT:-22}"
STANDBY_SSH_PORT="${STANDBY_SSH_PORT:-22}"
DB_SSH_KEY_OPT=""
[[ -n "${SSH_KEY:-}" ]] && DB_SSH_KEY_OPT="-i ${SSH_KEY}"

_ssh_hop() {
    local host="$1" port="$2" cmd="$3"
    ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} \
        -J "${JUMP_USER}@${JUMP_HOST}:${JUMP_SSH_PORT}" \
        -p "${port}" "${SSH_USER}@${host}" \
        "export ORACLE_HOME='${ORACLE_HOME}'; \
         export ORACLE_BASE='${ORACLE_BASE}'; \
         export ORACLE_SID='${TEST_ORACLE_SID}'; \
         export PATH=\"\${ORACLE_HOME}/bin:\${PATH}\"; \
         export NFS_SHARE='${NFS_SHARE}'; \
         $cmd" 2>&1
}

ssh_primary() { _ssh_hop "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}" "$1"; }
ssh_standby() { _ssh_hop "${STANDBY_HOST}" "${STANDBY_SSH_PORT}" "$1"; }

# -- Confirmation -------------------------------------------------------------
log_step "Drop database: ${TEST_DB_NAME}"

log "Database:     ${TEST_DB_NAME} (SID: ${TEST_ORACLE_SID})"
log "Primary host: ${PRIMARY_HOST}:${PRIMARY_SSH_PORT}"
$CLEAN_STANDBY && log "Standby host: ${STANDBY_HOST}:${STANDBY_SSH_PORT}"
$CLEAN_NFS && log "NFS share:    ${NFS_SHARE}"

if ! $FORCE; then
    printf "\n ${YELLOW}This will permanently drop the database and remove all files.${NC}\n"
    printf " Continue? [y/N] "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log "Cancelled"
        exit 0
    fi
fi

# =============================================================================
# Clean up primary
# =============================================================================
log_step "Cleaning up primary host"

RESULT=$(ssh_primary "set +e

    # Remove DG broker config (if broker is running)
    dgmgrl -silent / 'REMOVE CONFIGURATION' 2>/dev/null || true

    # Check if database is running
    pmon_check=\$(ps -ef | grep -w 'ora_pmon_${TEST_ORACLE_SID}' | grep -v grep || true)
    if [[ -n \"\${pmon_check}\" ]]; then
        # Try DBCA drop first (clean)
        dbca -silent -deleteDatabase \
            -sourceDB '${TEST_DB_NAME}' \
            -sysDBAUserName sys \
            -sysDBAPassword '${TEST_SYS_PASSWORD}' 2>&1 || {
            # Fallback: manual drop
            sqlplus -s / as sysdba << 'SQLEOF'
SHUTDOWN ABORT;
STARTUP MOUNT EXCLUSIVE RESTRICT;
DROP DATABASE;
EXIT;
SQLEOF
        }
    fi

    # Remove data files
    rm -rf '${ORACLE_BASE}/oradata/${TEST_DB_NAME}' 2>/dev/null || true
    rm -rf '${ORACLE_BASE}/oradata/${TEST_DB_UNIQUE_NAME}' 2>/dev/null || true

    # Remove admin directories
    rm -rf '${ORACLE_BASE}/admin/${TEST_DB_NAME}' 2>/dev/null || true
    rm -rf '${ORACLE_BASE}/admin/${TEST_DB_UNIQUE_NAME}' 2>/dev/null || true

    # Remove archive logs
    rm -rf '${ORACLE_BASE}/archive/${TEST_DB_NAME}' 2>/dev/null || true
    rm -rf '${ORACLE_BASE}/archive/${TEST_DB_UNIQUE_NAME}' 2>/dev/null || true

    # Remove Oracle config files for this SID
    rm -f '${ORACLE_HOME}/dbs/init${TEST_ORACLE_SID}.ora' 2>/dev/null || true
    rm -f '${ORACLE_HOME}/dbs/spfile${TEST_ORACLE_SID}.ora' 2>/dev/null || true
    rm -f '${ORACLE_HOME}/dbs/orapw${TEST_ORACLE_SID}' 2>/dev/null || true
    rm -f '${ORACLE_HOME}/dbs/hc_${TEST_ORACLE_SID}.dat' 2>/dev/null || true

    # Remove DG broker files
    rm -f '${ORACLE_BASE}/oradata/dg_broker_config_'*.dat 2>/dev/null || true
    rm -f '${ORACLE_HOME}/dbs/dr1'*.dat 2>/dev/null || true
    rm -f '${ORACLE_HOME}/dbs/dr2'*.dat 2>/dev/null || true

    # Remove DG TNS entries from tnsnames.ora and listener.ora
    for f in tnsnames.ora listener.ora; do
        local_f='${ORACLE_HOME}/network/admin/'\${f}
        if [[ -f \"\${local_f}\" ]]; then
            sed -i '/^# Data Guard TNS entries/,\$d' \"\${local_f}\" 2>/dev/null || true
            sed -i '/^# DG Listener/,\$d' \"\${local_f}\" 2>/dev/null || true
        fi
    done
    sed -i '/${TEST_ORACLE_SID}/d' '${ORACLE_HOME}/network/admin/listener.ora' 2>/dev/null || true

    # Remove oratab entry
    if [[ -f /etc/oratab ]]; then
        grep -v '^${TEST_ORACLE_SID}:' /etc/oratab > /tmp/oratab_clean 2>/dev/null || true
        cp /tmp/oratab_clean /etc/oratab 2>/dev/null || true
        rm -f /tmp/oratab_clean
    fi

    # Reload listener
    lsnrctl reload 2>/dev/null || lsnrctl start 2>/dev/null || true

    echo 'PRIMARY_CLEANUP_OK'
")

if printf '%s' "$RESULT" | grep -q 'PRIMARY_CLEANUP_OK'; then
    log_ok "Primary cleanup complete"
else
    log_warn "Primary cleanup completed with warnings"
    printf '%s\n' "$RESULT" | tail -10
fi

# =============================================================================
# Clean up standby (optional)
# =============================================================================
if $CLEAN_STANDBY; then
    log_step "Cleaning up standby host"

    RESULT=$(ssh_standby "set +e

        # Stop observer if running
        pkill -f 'dgmgrl.*observer' 2>/dev/null || true

        # Shutdown standby database
        sqlplus -s / as sysdba << 'SQLEOF' 2>/dev/null || true
SHUTDOWN ABORT;
EXIT;
SQLEOF

        # Remove database files
        rm -rf '${ORACLE_BASE}/oradata/${TEST_STANDBY_DB_UNIQUE_NAME}' 2>/dev/null || true
        rm -rf '${ORACLE_BASE}/oradata/${TEST_DB_NAME}' 2>/dev/null || true
        rm -rf '${ORACLE_BASE}/admin/${TEST_STANDBY_DB_UNIQUE_NAME}' 2>/dev/null || true
        rm -rf '${ORACLE_BASE}/admin/${TEST_DB_NAME}' 2>/dev/null || true
        rm -rf '${ORACLE_BASE}/archive/${TEST_STANDBY_DB_UNIQUE_NAME}' 2>/dev/null || true
        rm -rf '${ORACLE_BASE}/archive/${TEST_DB_NAME}' 2>/dev/null || true

        # Remove Oracle config files
        rm -f '${ORACLE_HOME}/dbs/init${TEST_ORACLE_SID}.ora' 2>/dev/null || true
        rm -f '${ORACLE_HOME}/dbs/spfile${TEST_ORACLE_SID}.ora' 2>/dev/null || true
        rm -f '${ORACLE_HOME}/dbs/orapw${TEST_ORACLE_SID}' 2>/dev/null || true
        rm -f '${ORACLE_HOME}/dbs/hc_${TEST_ORACLE_SID}.dat' 2>/dev/null || true

        # Remove DG broker files
        rm -f '${ORACLE_BASE}/oradata/dg_broker_config_'*.dat 2>/dev/null || true
        rm -f '${ORACLE_HOME}/dbs/dr1'*.dat 2>/dev/null || true
        rm -f '${ORACLE_HOME}/dbs/dr2'*.dat 2>/dev/null || true

        # Remove wallet
        rm -rf '${ORACLE_HOME}/network/admin/wallet' 2>/dev/null || true

        # Remove DG TNS entries
        for f in tnsnames.ora listener.ora; do
            local_f='${ORACLE_HOME}/network/admin/'\${f}
            if [[ -f \"\${local_f}\" ]]; then
                sed -i '/^# Data Guard TNS entries/,\$d' \"\${local_f}\" 2>/dev/null || true
                sed -i '/^# DG Listener/,\$d' \"\${local_f}\" 2>/dev/null || true
            fi
        done
        sed -i '/${TEST_ORACLE_SID}/d' '${ORACLE_HOME}/network/admin/listener.ora' 2>/dev/null || true

        # Remove oratab entry
        if [[ -f /etc/oratab ]]; then
            grep -v '^${TEST_ORACLE_SID}:' /etc/oratab > /tmp/oratab_clean 2>/dev/null || true
            cp /tmp/oratab_clean /etc/oratab 2>/dev/null || true
            rm -f /tmp/oratab_clean
        fi

        # Reload listener
        lsnrctl reload 2>/dev/null || lsnrctl start 2>/dev/null || true

        echo 'STANDBY_CLEANUP_OK'
    ")

    if printf '%s' "$RESULT" | grep -q 'STANDBY_CLEANUP_OK'; then
        log_ok "Standby cleanup complete"
    else
        log_warn "Standby cleanup completed with warnings"
        printf '%s\n' "$RESULT" | tail -10
    fi
fi

# =============================================================================
# Clean up NFS (optional)
# =============================================================================
if $CLEAN_NFS; then
    log_step "Cleaning up NFS share"

    RESULT=$(ssh_primary "set +e
        rm -f '${NFS_SHARE}'/*.env 2>/dev/null
        rm -f '${NFS_SHARE}'/*.ora 2>/dev/null
        rm -f '${NFS_SHARE}'/*.dgmgrl 2>/dev/null
        rm -f '${NFS_SHARE}'/*.sql 2>/dev/null
        rm -f '${NFS_SHARE}'/orapw* 2>/dev/null
        rm -f '${NFS_SHARE}'/fsfo_observer_* 2>/dev/null
        rm -rf '${NFS_SHARE}/logs/' 2>/dev/null
        rm -rf '${NFS_SHARE}/state/' 2>/dev/null
        echo 'NFS_CLEANUP_OK'
    ")

    if printf '%s' "$RESULT" | grep -q 'NFS_CLEANUP_OK'; then
        log_ok "NFS cleanup complete"
    else
        log_warn "NFS cleanup completed with warnings"
    fi
fi

# =============================================================================
# Summary
# =============================================================================
log_step "Done"

printf "\n"
log "${GREEN}Database '${TEST_DB_NAME}' dropped and cleaned up${NC}"
printf "\n"
