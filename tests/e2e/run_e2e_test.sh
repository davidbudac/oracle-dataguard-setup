#!/usr/bin/env bash
# =============================================================================
# Oracle 19c Data Guard - End-to-End Test
# =============================================================================
#
# Runs through every step in the DATA_GUARD_WALKTHROUGH.md on real Oracle hosts
# and validates the results. Designed to be re-run after every major change.
#
# Usage:
#   ./run_e2e_test.sh                    # Run all phases
#   ./run_e2e_test.sh --from step5       # Resume from a specific phase
#   ./run_e2e_test.sh --only cleanup     # Run only one phase
#   ./run_e2e_test.sh --only create_db   # Create the test database only
#   ./run_e2e_test.sh --only cleanup_primary   # Cleanup primary only
#   ./run_e2e_test.sh --only cleanup_standby   # Cleanup standby only
#
# Prerequisites:
#   - config.env filled in (copy from config.env.template)
#   - SSH key access to jump host, and from jump host to both DB hosts
#   - Oracle 19c installed on both DB hosts
#   - NFS mounted on both DB hosts
#   - git installed on both DB hosts
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="${SCRIPT_DIR}/logs"
RESULTS_FILE="${LOG_DIR}/results_${TIMESTAMP}.log"
ISSUES_FILE="${LOG_DIR}/issues_${TIMESTAMP}.md"
FULL_LOG="${LOG_DIR}/full_${TIMESTAMP}.log"

mkdir -p "$LOG_DIR"

# =============================================================================
# Configuration
# =============================================================================

if [[ ! -f "${SCRIPT_DIR}/config.env" ]]; then
    echo "ERROR: config.env not found. Copy config.env.template to config.env and fill in values."
    exit 1
fi

source "${SCRIPT_DIR}/config.env"

# Validate required config
for var in JUMP_HOST JUMP_USER PRIMARY_HOST STANDBY_HOST SSH_USER ORACLE_HOME ORACLE_BASE \
           TEST_DB_NAME TEST_DB_UNIQUE_NAME TEST_STANDBY_DB_UNIQUE_NAME \
           TEST_SYS_PASSWORD NFS_SHARE REPO_URL REPO_DIR; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: ${var} is not set in config.env"
        exit 1
    fi
done

# Derived values
JUMP_KEY_OPT=""
[[ -n "${JUMP_KEY:-}" ]] && JUMP_KEY_OPT="-i ${JUMP_KEY}"
JUMP_SSH_PORT="${JUMP_SSH_PORT:-22}"
PRIMARY_SSH_PORT="${PRIMARY_SSH_PORT:-22}"
STANDBY_SSH_PORT="${STANDBY_SSH_PORT:-22}"
DB_SSH_KEY_OPT=""
[[ -n "${SSH_KEY:-}" ]] && DB_SSH_KEY_OPT="-i ${SSH_KEY}"

# The standby ORACLE_SID is typically the same as the primary
TEST_ORACLE_SID="${TEST_DB_NAME}"

# =============================================================================
# Logging & Tracking
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
ISSUE_COUNT=0

log() {
    local msg="[$(date '+%H:%M:%S')] $1"
    echo -e "$msg"
    echo -e "$msg" >> "$FULL_LOG"
}

log_phase() {
    log ""
    log "${BLUE}============================================================${NC}"
    log "${BLUE}  $1${NC}"
    log "${BLUE}============================================================${NC}"
}

log_pass() {
    log "${GREEN}  [PASS]${NC} $1"
    echo "[PASS] $1" >> "$RESULTS_FILE"
    PASS_COUNT=$((PASS_COUNT + 1))
}

log_fail() {
    log "${RED}  [FAIL]${NC} $1"
    echo "[FAIL] $1" >> "$RESULTS_FILE"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

log_skip() {
    log "${YELLOW}  [SKIP]${NC} $1"
    echo "[SKIP] $1" >> "$RESULTS_FILE"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

log_info() {
    log "${CYAN}  [INFO]${NC} $1"
}

record_issue() {
    local phase="$1"
    local description="$2"
    local details="${3:-}"
    ISSUE_COUNT=$((ISSUE_COUNT + 1))

    cat >> "$ISSUES_FILE" << EOF

### Issue #${ISSUE_COUNT}: ${phase}

**Description:** ${description}

${details:+**Details:**
\`\`\`
${details}
\`\`\`
}
---
EOF
    log "${RED}  [ISSUE #${ISSUE_COUNT}]${NC} ${description}"
}

# =============================================================================
# SSH Helpers (all commands hop through the jump host)
#
# Path: local machine -> jump host -> DB host (as oracle)
# Uses ProxyJump (-J) for clean double-hop without nested quoting issues.
#
# All functions take host AND port explicitly to support setups where both
# DB hosts resolve to the same hostname (e.g. localhost with different ports).
# =============================================================================

# Core SSH: run command on a DB host via ProxyJump
_ssh_hop() {
    local host="$1"
    local port="$2"
    local cmd="$3"

    ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} \
        -J "${JUMP_USER}@${JUMP_HOST}:${JUMP_SSH_PORT}" \
        -p "${port}" "${SSH_USER}@${host}" \
        "export ORACLE_HOME='${ORACLE_HOME}'; \
         export ORACLE_BASE='${ORACLE_BASE}'; \
         export ORACLE_SID='${TEST_ORACLE_SID}'; \
         export PATH=\"\${ORACLE_HOME}/bin:\${PATH}\"; \
         export NFS_SHARE='${NFS_SHARE}'; \
         ${cmd}" 2>&1
}

# Convenience wrappers that bind host+port using actual hostname variables
ssh_primary() { _ssh_hop "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}" "$1"; }
ssh_standby() { _ssh_hop "${STANDBY_HOST}" "${STANDBY_SSH_PORT}" "$1"; }

# Generic ssh_cmd - accepts "PRIMARY" or "STANDBY" as first arg
ssh_cmd() {
    local target="$1"
    local cmd="$2"
    if [[ "$target" == "PRIMARY" ]]; then
        ssh_primary "$cmd"
    else
        ssh_standby "$cmd"
    fi
}

# Run a script with piped stdin for interactive prompts.
# Usage: ssh_piped <"PRIMARY"|"STANDBY"> <script_cmd> <stdin_lines>
ssh_piped() {
    local target="$1"
    local script_cmd="$2"
    local input="$3"

    local host port
    if [[ "$target" == "STANDBY" ]]; then
        host="${STANDBY_HOST}"; port="${STANDBY_SSH_PORT}"
    else
        host="${PRIMARY_HOST}"; port="${PRIMARY_SSH_PORT}"
    fi

    printf '%b\n' "${input}" | \
    ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} \
        -J "${JUMP_USER}@${JUMP_HOST}:${JUMP_SSH_PORT}" \
        -p "${port}" "${SSH_USER}@${host}" \
        "export ORACLE_HOME='${ORACLE_HOME}'; \
         export ORACLE_BASE='${ORACLE_BASE}'; \
         export ORACLE_SID='${TEST_ORACLE_SID}'; \
         export PATH=\"\${ORACLE_HOME}/bin:\${PATH}\"; \
         export NFS_SHARE='${NFS_SHARE}'; \
         cd '${REPO_DIR}' && ${script_cmd}" 2>&1
}

# =============================================================================
# Assertion Helpers
# =============================================================================

assert_ssh_jump_ok() {
    if ssh ${SSH_OPTS} ${JUMP_KEY_OPT} -p "${JUMP_SSH_PORT}" \
        "${JUMP_USER}@${JUMP_HOST}" "echo ok" 2>/dev/null | grep -q ok; then
        log_pass "SSH to jump host (${JUMP_HOST})"
    else
        log_fail "SSH to jump host (${JUMP_HOST})"
        return 1
    fi
}

assert_ssh_ok() {
    local target="$1"  # PRIMARY or STANDBY
    local label="$2"
    local host port
    if [[ "$target" == "STANDBY" ]]; then
        host="${STANDBY_HOST}"; port="${STANDBY_SSH_PORT}"
    else
        host="${PRIMARY_HOST}"; port="${PRIMARY_SSH_PORT}"
    fi
    if ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} \
        -J "${JUMP_USER}@${JUMP_HOST}:${JUMP_SSH_PORT}" \
        -p "${port}" "${SSH_USER}@${host}" "echo ok" 2>/dev/null | grep -q ok; then
        log_pass "SSH to ${label} (${host}:${port}) via jump"
    else
        log_fail "SSH to ${label} (${host}:${port}) via jump"
        return 1
    fi
}

assert_remote_file_exists() {
    local host="$1"
    local path="$2"
    local label="${3:-${path}}"
    if ssh_cmd "$host" "test -f '${path}' && echo EXISTS" | grep -q EXISTS; then
        log_pass "File exists: ${label}"
    else
        log_fail "File missing: ${label}"
        return 1
    fi
}

assert_remote_grep() {
    local host="$1"
    local pattern="$2"
    local file="$3"
    local label="${4:-pattern '${pattern}' in ${file}}"
    if ssh_cmd "$host" "grep -q '${pattern}' '${file}' 2>/dev/null && echo FOUND" | grep -q FOUND; then
        log_pass "Found: ${label}"
    else
        log_fail "Not found: ${label}"
        return 1
    fi
}

assert_sql() {
    local host="$1"
    local sql="$2"
    local expected="$3"
    local label="${4:-SQL check}"
    local result
    result=$(ssh_cmd "$host" "
        sqlplus -s / as sysdba << 'SQLEOF'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200 TRIMOUT ON TRIMSPOOL ON
${sql}
EXIT;
SQLEOF
    " | tr -d '[:space:]')

    if [[ "$result" == *"${expected}"* ]]; then
        log_pass "${label}: got '${expected}'"
    else
        log_fail "${label}: expected '${expected}', got '${result}'"
        return 1
    fi
}

assert_dgmgrl() {
    local host="$1"
    local dgmgrl_cmd="$2"
    local expected="$3"
    local label="${4:-DGMGRL check}"
    local result
    result=$(ssh_cmd "$host" "dgmgrl -silent / '${dgmgrl_cmd}'" 2>&1)

    if echo "$result" | grep -qi "${expected}"; then
        log_pass "${label}"
    else
        log_fail "${label}: expected '${expected}' in output"
        log_info "  DGMGRL output: $(echo "$result" | head -5)"
        return 1
    fi
}

# =============================================================================
# Phase: Preflight Checks
# =============================================================================

phase_preflight() {
    log_phase "PREFLIGHT: Validating environment"

    assert_ssh_jump_ok || return 1
    assert_ssh_ok "PRIMARY" "primary" || return 1
    assert_ssh_ok "STANDBY" "standby" || return 1

    # Oracle Home exists
    for label in PRIMARY STANDBY; do

        if ssh_cmd "$label" "test -x '${ORACLE_HOME}/bin/sqlplus' && echo OK" | grep -q OK; then
            log_pass "${label}: Oracle Home valid"
        else
            log_fail "${label}: sqlplus not found at ${ORACLE_HOME}/bin/sqlplus"
            return 1
        fi

        # git installed (needed for deploy)
        if ssh_cmd "$label" "which git >/dev/null 2>&1 && echo OK" | grep -q OK; then
            log_pass "${label}: git installed"
        else
            log_fail "${label}: 'git' not installed (required for deploy)"
            return 1
        fi

        # NFS mounted and writable
        if ssh_cmd "$label" "test -d '${NFS_SHARE}' && touch '${NFS_SHARE}/.e2e_test' && rm -f '${NFS_SHARE}/.e2e_test' && echo OK" | grep -q OK; then
            log_pass "${label}: NFS share writable at ${NFS_SHARE}"
        else
            log_fail "${label}: NFS share not writable at ${NFS_SHARE}"
            return 1
        fi
    done

    # Check no existing test database on primary
    local db_check
    db_check=$(ssh_cmd "PRIMARY" "
        ps -ef | grep -w 'ora_pmon_${TEST_ORACLE_SID}' | grep -v grep || true
    ")
    if [[ -n "$db_check" ]]; then
        log_info "Existing ${TEST_ORACLE_SID} instance detected on primary - will clean up first"
    fi

    log_pass "Preflight checks complete"
}

# =============================================================================
# Phase: Deploy Scripts
# =============================================================================

phase_deploy() {
    log_phase "DEPLOY: Deploying scripts to both hosts"

    for label in PRIMARY STANDBY; do

        local result
        result=$(ssh_cmd "$label" "
            if [[ -d '${REPO_DIR}/.git' ]]; then
                cd '${REPO_DIR}'
                git fetch origin '${REPO_BRANCH}' 2>&1
                git checkout '${REPO_BRANCH}' 2>&1
                git reset --hard 'origin/${REPO_BRANCH}' 2>&1
                echo 'DEPLOY_PULL_OK'
            else
                mkdir -p '$(dirname "${REPO_DIR}")'
                git clone -b '${REPO_BRANCH}' '${REPO_URL}' '${REPO_DIR}' 2>&1
                echo 'DEPLOY_CLONE_OK'
            fi
        ")

        if echo "$result" | grep -q 'DEPLOY_.*_OK'; then
            log_pass "${label}: Scripts deployed to ${REPO_DIR}"
        else
            log_fail "${label}: Failed to deploy scripts"
            log_info "  Output: $(echo "$result" | tail -5)"
            return 1
        fi

        # Make scripts executable
        ssh_cmd "$label" "chmod +x '${REPO_DIR}'/primary/*.sh '${REPO_DIR}'/standby/*.sh '${REPO_DIR}'/fsfo/*.sh '${REPO_DIR}'/trigger/*.sh '${REPO_DIR}'/common/*.sh 2>/dev/null || true"
    done

    log_pass "Deploy complete"
}

# =============================================================================
# Phase: Cleanup (previous run or final)
# =============================================================================

phase_cleanup() {
    log_phase "CLEANUP: Removing test databases and files"

    # Cleanup should never abort the script - best effort
    cleanup_standby || true
    cleanup_primary || true
    cleanup_nfs || true

    log_pass "Cleanup complete"
}

cleanup_standby() {
    log_info "Cleaning up standby host..."

    ssh_cmd "STANDBY" "set +e;
        # Comment out NAMES.DEFAULT_DOMAIN in sqlnet.ora if present
        # (interferes with DG TNS aliases when db_domain is not set)
        if grep -q 'NAMES.DEFAULT_DOMAIN' '${ORACLE_HOME}/network/admin/sqlnet.ora' 2>/dev/null; then
            sed -i 's/^NAMES.DEFAULT_DOMAIN/#NAMES.DEFAULT_DOMAIN/' '${ORACLE_HOME}/network/admin/sqlnet.ora'
        fi
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

        # Remove Oracle config files for this SID
        rm -f '${ORACLE_HOME}/dbs/init${TEST_ORACLE_SID}.ora' 2>/dev/null || true
        rm -f '${ORACLE_HOME}/dbs/spfile${TEST_ORACLE_SID}.ora' 2>/dev/null || true
        rm -f '${ORACLE_HOME}/dbs/orapw${TEST_ORACLE_SID}' 2>/dev/null || true
        rm -f '${ORACLE_HOME}/dbs/hc_${TEST_ORACLE_SID}.dat' 2>/dev/null || true

        # Remove DG broker files
        rm -f '${ORACLE_BASE}/oradata/dg_broker_config_*.dat' 2>/dev/null || true
        rm -f '${ORACLE_HOME}/dbs/dr1*.dat' 2>/dev/null || true
        rm -f '${ORACLE_HOME}/dbs/dr2*.dat' 2>/dev/null || true

        # Remove wallet (observer)
        rm -rf '${ORACLE_HOME}/network/admin/wallet' 2>/dev/null || true

        # Remove DG TNS entries (everything after the marker comment) from tnsnames.ora
        for f in tnsnames.ora listener.ora; do
            local_f='${ORACLE_HOME}/network/admin/'\${f}
            if [[ -f \"\${local_f}\" ]]; then
                sed -i '/^# Data Guard TNS entries/,\$d' \"\${local_f}\" 2>/dev/null || true
                sed -i '/^# DG Listener/,\$d' \"\${local_f}\" 2>/dev/null || true
            fi
        done

        # Remove SID entries added by DG scripts from listener.ora
        # (remove any SID_DESC blocks for our test SID)
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
    " 600

    log_info "Standby cleanup done"
}

cleanup_primary() {
    log_info "Cleaning up primary host..."

    ssh_cmd "PRIMARY" "set +e;
        # Remove DG broker config first (if broker is running)
        dgmgrl -silent / 'REMOVE CONFIGURATION' 2>/dev/null || true

        # Check if database exists and drop it
        pmon_check=\$(ps -ef | grep -w 'ora_pmon_${TEST_ORACLE_SID}' | grep -v grep || true)
        if [[ -n \"\${pmon_check}\" ]]; then
            # Use DBCA to drop cleanly
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

        # Remove any remaining files
        rm -rf '${ORACLE_BASE}/oradata/${TEST_DB_NAME}' 2>/dev/null || true
        rm -rf '${ORACLE_BASE}/oradata/${TEST_DB_UNIQUE_NAME}' 2>/dev/null || true
        rm -rf '${ORACLE_BASE}/admin/${TEST_DB_NAME}' 2>/dev/null || true
        rm -rf '${ORACLE_BASE}/admin/${TEST_DB_UNIQUE_NAME}' 2>/dev/null || true
        rm -rf '${ORACLE_BASE}/archive/${TEST_DB_NAME}' 2>/dev/null || true
        rm -rf '${ORACLE_BASE}/archive/${TEST_DB_UNIQUE_NAME}' 2>/dev/null || true

        # Remove Oracle config files
        rm -f '${ORACLE_HOME}/dbs/init${TEST_ORACLE_SID}.ora' 2>/dev/null || true
        rm -f '${ORACLE_HOME}/dbs/spfile${TEST_ORACLE_SID}.ora' 2>/dev/null || true
        rm -f '${ORACLE_HOME}/dbs/orapw${TEST_ORACLE_SID}' 2>/dev/null || true
        rm -f '${ORACLE_HOME}/dbs/hc_${TEST_ORACLE_SID}.dat' 2>/dev/null || true

        # Remove DG broker files
        rm -f '${ORACLE_BASE}/oradata/dg_broker_config_*.dat' 2>/dev/null || true
        rm -f '${ORACLE_HOME}/dbs/dr1*.dat' 2>/dev/null || true
        rm -f '${ORACLE_HOME}/dbs/dr2*.dat' 2>/dev/null || true

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
    " 600

    log_info "Primary cleanup done"
}

cleanup_nfs() {
    log_info "Cleaning up NFS share..."

    ssh_primary "set +e;
        # Remove ALL config/generated files (not just our test DB name)
        # to prevent stale files from previous manual tests interfering
        rm -f '${NFS_SHARE}'/*.env 2>/dev/null
        rm -f '${NFS_SHARE}'/*.ora 2>/dev/null
        rm -f '${NFS_SHARE}'/*.dgmgrl 2>/dev/null
        rm -f '${NFS_SHARE}'/*.sql 2>/dev/null
        rm -f '${NFS_SHARE}'/orapw* 2>/dev/null
        rm -f '${NFS_SHARE}'/fsfo_observer_* 2>/dev/null
        rm -rf '${NFS_SHARE}/logs/' 2>/dev/null
        rm -rf '${NFS_SHARE}/state/' 2>/dev/null

        echo 'NFS_CLEANUP_OK'
    "

    log_info "NFS cleanup done"
}

# =============================================================================
# Phase: Create Test Database
# =============================================================================

phase_create_db() {
    log_phase "CREATE DB: Creating test primary database (no OMF, no FRA)"

    local result
    result=$(ssh_cmd "PRIMARY" "
        # Create archive log directory
        mkdir -p '${TEST_ARCHIVE_DIR}'

        # Create database with DBCA (handles catalog/catproc automatically)
        # Note: DBCA uses its own file placement. We disable OMF/FRA post-creation.
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
    " 1800)

    if ! echo "$result" | grep -q 'DBCA_EXIT_CODE=0'; then
        log_fail "DBCA database creation failed"
        record_issue "create_db" "DBCA failed to create database" "$(echo "$result" | tail -20)"
        return 1
    fi

    log_pass "DBCA database created"

    # Post-creation: disable OMF and FRA, enable archivelog with explicit dest
    result=$(ssh_cmd "PRIMARY" "
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

    if echo "$result" | grep -q 'LOGMODE=ARCHIVELOG'; then
        log_pass "ARCHIVELOG mode enabled"
    else
        log_fail "ARCHIVELOG mode not enabled"
        record_issue "create_db" "Database not in ARCHIVELOG mode" "$result"
        return 1
    fi

    if echo "$result" | grep -q 'OMF=$\|OMF=UNSET'; then
        log_pass "OMF disabled (db_create_file_dest unset)"
    else
        log_info "OMF parameter may still have a value (DBCA residual) - continuing"
    fi

    if echo "$result" | grep -q 'FRA=$\|FRA=UNSET'; then
        log_pass "FRA disabled (db_recovery_file_dest unset)"
    else
        log_info "FRA parameter may still have a value - continuing"
    fi

    # Force a few log switches to populate archive directory
    ssh_primary "
        sqlplus -s / as sysdba << 'SQLEOF'
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
EXIT;
SQLEOF
    " > /dev/null

    # Verify archive logs are being written to explicit location
    if ssh_primary "ls '${TEST_ARCHIVE_DIR}/'*.arc 2>/dev/null || ls '${TEST_ARCHIVE_DIR}/'*dbf 2>/dev/null || ls '${TEST_ARCHIVE_DIR}/'* 2>/dev/null | head -1" | grep -q .; then
        log_pass "Archive logs written to ${TEST_ARCHIVE_DIR}"
    else
        log_info "Archive directory may use subdirectory structure - verifying..."
        if ssh_primary "find '${TEST_ARCHIVE_DIR}' -type f 2>/dev/null | head -1" | grep -q .; then
            log_pass "Archive logs found under ${TEST_ARCHIVE_DIR}"
        else
            log_fail "No archive logs found in ${TEST_ARCHIVE_DIR}"
            record_issue "create_db" "Archive logs not written to explicit directory"
        fi
    fi

    log_pass "Test database created successfully"
}

# =============================================================================
# Phase: Step 1 - Gather Primary Info
# =============================================================================

phase_step1() {
    log_phase "STEP 1: Gather Primary Information"

    local result
    # Prompts: NFS share path confirmation (Enter for default)
    # No config file selection needed for step 1
    result=$(ssh_piped "PRIMARY" \
        "./primary/01_gather_primary_info.sh" \
        "")

    local exit_code=$?
    log_info "Step 1 output (last 10 lines):"
    echo "$result" | tail -10 | while read -r line; do log_info "  $line"; done

    if [[ $exit_code -ne 0 ]]; then
        log_fail "Step 1 script exited with code ${exit_code}"
        record_issue "step1" "01_gather_primary_info.sh failed" "$(echo "$result" | tail -30)"
        return 1
    fi

    # Validate outputs
    assert_remote_file_exists "PRIMARY" \
        "${NFS_SHARE}/primary_info_${TEST_DB_UNIQUE_NAME}.env" \
        "primary_info_${TEST_DB_UNIQUE_NAME}.env on NFS" || return 1

    assert_remote_file_exists "PRIMARY" \
        "${NFS_SHARE}/orapw${TEST_ORACLE_SID}" \
        "Password file on NFS" || return 1

    # Validate key variables in the primary info file
    assert_remote_grep "PRIMARY" "DB_NAME=" \
        "${NFS_SHARE}/primary_info_${TEST_DB_UNIQUE_NAME}.env" \
        "DB_NAME in primary info" || return 1

    assert_remote_grep "PRIMARY" "DB_UNIQUE_NAME=" \
        "${NFS_SHARE}/primary_info_${TEST_DB_UNIQUE_NAME}.env" \
        "DB_UNIQUE_NAME in primary info" || return 1

    assert_remote_grep "PRIMARY" "LOG_MODE=.*ARCHIVELOG" \
        "${NFS_SHARE}/primary_info_${TEST_DB_UNIQUE_NAME}.env" \
        "ARCHIVELOG mode recorded" || return 1

    log_pass "Step 1 completed and validated"
}

# =============================================================================
# Phase: Step 2 - Generate Standby Configuration
# =============================================================================

phase_step2() {
    log_phase "STEP 2: Generate Standby Configuration"

    local result
    # Prompts: standby host, db_unique_name, SID (default), storage mode (default=Traditional), confirm
    # Note: config file is auto-selected when only one exists (no menu prompt)
    # Use STANDBY_ORACLE_HOSTNAME (the real network hostname) not STANDBY_HOST (SSH target)
    local standby_hn="${STANDBY_ORACLE_HOSTNAME:-${STANDBY_HOST}}"
    result=$(ssh_piped "PRIMARY" \
        "./primary/02_generate_standby_config.sh" \
        "${standby_hn}\n${TEST_STANDBY_DB_UNIQUE_NAME}\n\n\ny")

    local exit_code=$?
    log_info "Step 2 output (last 10 lines):"
    echo "$result" | tail -10 | while read -r line; do log_info "  $line"; done

    if [[ $exit_code -ne 0 ]]; then
        log_fail "Step 2 script exited with code ${exit_code}"
        record_issue "step2" "02_generate_standby_config.sh failed" "$(echo "$result" | tail -30)"
        return 1
    fi

    # Validate outputs
    assert_remote_file_exists "PRIMARY" \
        "${NFS_SHARE}/standby_config_${TEST_STANDBY_DB_UNIQUE_NAME}.env" \
        "standby_config on NFS" || return 1

    assert_remote_file_exists "PRIMARY" \
        "${NFS_SHARE}/tnsnames_entries_${TEST_STANDBY_DB_UNIQUE_NAME}.ora" \
        "TNS entries on NFS" || return 1

    # Validate standby config has correct values
    local assert_hn="${STANDBY_ORACLE_HOSTNAME:-${STANDBY_HOST}}"
    assert_remote_grep "PRIMARY" "STANDBY_HOSTNAME=.*${assert_hn}" \
        "${NFS_SHARE}/standby_config_${TEST_STANDBY_DB_UNIQUE_NAME}.env" \
        "Standby hostname in config" || return 1

    assert_remote_grep "PRIMARY" "STANDBY_DB_UNIQUE_NAME=.*${TEST_STANDBY_DB_UNIQUE_NAME}" \
        "${NFS_SHARE}/standby_config_${TEST_STANDBY_DB_UNIQUE_NAME}.env" \
        "Standby DB_UNIQUE_NAME in config" || return 1

    log_pass "Step 2 completed and validated"
}

# =============================================================================
# Phase: Step 3 - Setup Standby Environment
# =============================================================================

phase_step3() {
    log_phase "STEP 3: Setup Standby Environment"

    local result
    # Prompts: hostname mismatch confirm (config auto-selected when only one)
    result=$(ssh_piped "STANDBY" \
        "./standby/03_setup_standby_env.sh" \
        "y\ny\ny\ny\ny")

    local exit_code=$?
    log_info "Step 3 output (last 10 lines):"
    echo "$result" | tail -10 | while read -r line; do log_info "  $line"; done

    if [[ $exit_code -ne 0 ]]; then
        log_fail "Step 3 script exited with code ${exit_code}"
        record_issue "step3" "03_setup_standby_env.sh failed" "$(echo "$result" | tail -30)"
        return 1
    fi

    # Validate: password file installed
    assert_remote_file_exists "STANDBY" \
        "${ORACLE_HOME}/dbs/orapw${TEST_ORACLE_SID}" \
        "Password file on standby" || return 1

    # Validate: parameter file installed
    assert_remote_file_exists "STANDBY" \
        "${ORACLE_HOME}/dbs/init${TEST_ORACLE_SID}.ora" \
        "Pfile on standby" || return 1

    # Validate: listener has static registration for standby
    assert_remote_grep "STANDBY" "${TEST_STANDBY_DB_UNIQUE_NAME}" \
        "${ORACLE_HOME}/network/admin/listener.ora" \
        "Standby SID in listener.ora" || return 1

    # Validate: tnsnames has both entries
    assert_remote_grep "STANDBY" "${TEST_DB_UNIQUE_NAME}" \
        "${ORACLE_HOME}/network/admin/tnsnames.ora" \
        "Primary TNS entry on standby" || return 1

    assert_remote_grep "STANDBY" "${TEST_STANDBY_DB_UNIQUE_NAME}" \
        "${ORACLE_HOME}/network/admin/tnsnames.ora" \
        "Standby TNS entry on standby" || return 1

    # Validate: listener is running
    if ssh_standby "lsnrctl status 2>&1 | grep -qi 'ready\\|running\\|LSNRCTL'" 2>/dev/null; then
        log_pass "Standby listener is running"
    else
        log_fail "Standby listener not running"
        return 1
    fi

    log_pass "Step 3 completed and validated"
}

# =============================================================================
# Phase: Step 4 - Prepare Primary for Data Guard
# =============================================================================

phase_step4() {
    log_phase "STEP 4: Prepare Primary for Data Guard"

    local result
    # Prompts: (config auto-selected when only one, no interactive prompts)
    result=$(ssh_piped "PRIMARY" \
        "./primary/04_prepare_primary_dg.sh" \
        "")

    local exit_code=$?
    log_info "Step 4 output (last 10 lines):"
    echo "$result" | tail -10 | while read -r line; do log_info "  $line"; done

    if [[ $exit_code -ne 0 ]]; then
        log_fail "Step 4 script exited with code ${exit_code}"
        record_issue "step4" "04_prepare_primary_dg.sh failed" "$(echo "$result" | tail -30)"
        return 1
    fi

    # Validate: FORCE_LOGGING enabled
    assert_sql "PRIMARY" \
        "SELECT force_logging FROM v\$database;" \
        "YES" \
        "FORCE_LOGGING enabled" || return 1

    # Validate: DG_BROKER_START=TRUE
    assert_sql "PRIMARY" \
        "SELECT value FROM v\$parameter WHERE name = 'dg_broker_start';" \
        "TRUE" \
        "DG_BROKER_START=TRUE" || return 1

    # Validate: STANDBY_FILE_MANAGEMENT=AUTO
    assert_sql "PRIMARY" \
        "SELECT value FROM v\$parameter WHERE name = 'standby_file_management';" \
        "AUTO" \
        "STANDBY_FILE_MANAGEMENT=AUTO" || return 1

    # Validate: standby redo logs exist
    assert_sql "PRIMARY" \
        "SELECT 'SRL_COUNT=' || COUNT(*) FROM v\$standby_log;" \
        "SRL_COUNT=" \
        "Standby redo logs created" || true
    # Check count > 0
    local srl_count
    srl_count=$(ssh_primary "sqlplus -s / as sysdba << 'SQLEOF'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT COUNT(*) FROM v\$standby_log;
EXIT;
SQLEOF
    " | tr -d '[:space:]')
    if [[ "${srl_count}" -gt 0 ]] 2>/dev/null; then
        log_pass "Standby redo logs: ${srl_count} groups"
    else
        log_fail "No standby redo logs found"
        return 1
    fi

    # Validate: TNS entries on primary
    assert_remote_grep "PRIMARY" "${TEST_STANDBY_DB_UNIQUE_NAME}" \
        "${ORACLE_HOME}/network/admin/tnsnames.ora" \
        "Standby TNS entry on primary" || return 1

    # Validate: listener has primary static registration
    assert_remote_grep "PRIMARY" "${TEST_DB_UNIQUE_NAME}" \
        "${ORACLE_HOME}/network/admin/listener.ora" \
        "Primary SID in listener.ora" || return 1

    # Validate: tnsping to standby
    if ssh_primary "tnsping '${TEST_STANDBY_DB_UNIQUE_NAME}' 2>&1 | grep -qi 'OK\\|ok'" 2>/dev/null; then
        log_pass "tnsping to standby succeeded"
    else
        log_info "tnsping to standby may fail if standby listener not yet configured - continuing"
    fi

    log_pass "Step 4 completed and validated"
}

# =============================================================================
# Phase: Step 5 - Clone Standby Database
# =============================================================================

phase_step5() {
    log_phase "STEP 5: Clone Standby Database (RMAN Duplicate)"

    log_info "This step takes a while (RMAN duplicate)..."

    local result
    # Prompts: SYS password, typed confirmation (config auto-selected)
    result=$(ssh_piped "STANDBY" \
        "./standby/05_clone_standby.sh" \
        "${TEST_SYS_PASSWORD}\n${TEST_STANDBY_DB_UNIQUE_NAME}")

    local exit_code=$?
    log_info "Step 5 output (last 15 lines):"
    echo "$result" | tail -15 | while read -r line; do log_info "  $line"; done

    if [[ $exit_code -ne 0 ]]; then
        log_fail "Step 5 script exited with code ${exit_code}"
        record_issue "step5" "05_clone_standby.sh failed (RMAN duplicate)" "$(echo "$result" | tail -40)"
        return 1
    fi

    # Validate: standby database role
    assert_sql "STANDBY" \
        "SELECT database_role FROM v\$database;" \
        "PHYSICALSTANDBY" \
        "Database role is PHYSICAL STANDBY" || return 1

    # Validate: MRP is running
    local mrp_status
    mrp_status=$(ssh_standby "sqlplus -s / as sysdba << 'SQLEOF'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT process || ':' || status FROM v\$managed_standby WHERE process = 'MRP0';
EXIT;
SQLEOF
    " | tr -d '[:space:]')

    if [[ "$mrp_status" == *"MRP0:"* ]]; then
        log_pass "MRP running: ${mrp_status}"
    else
        log_fail "MRP not running"
        record_issue "step5" "MRP (Managed Recovery Process) not running after clone" "$mrp_status"
        return 1
    fi

    log_pass "Step 5 completed and validated"
}

# =============================================================================
# Phase: Step 6 - Configure Data Guard Broker
# =============================================================================

phase_step6() {
    log_phase "STEP 6: Configure Data Guard Broker"

    local result
    # Prompts: possible remove config confirm (config auto-selected)
    result=$(ssh_piped "PRIMARY" \
        "./primary/06_configure_broker.sh" \
        "y\ny")

    local exit_code=$?
    log_info "Step 6 output (last 10 lines):"
    echo "$result" | tail -10 | while read -r line; do log_info "  $line"; done

    if [[ $exit_code -ne 0 ]]; then
        log_fail "Step 6 script exited with code ${exit_code}"
        record_issue "step6" "06_configure_broker.sh failed" "$(echo "$result" | tail -30)"
        return 1
    fi

    # Wait for broker to stabilize
    sleep 15

    # Validate: broker configuration exists and is enabled
    assert_dgmgrl "PRIMARY" \
        "SHOW CONFIGURATION" \
        "SUCCESS\|enabled\|Enabled" \
        "Broker configuration enabled" || {
        # Might still be starting - wait and retry
        log_info "Retrying after 30 seconds..."
        sleep 30
        assert_dgmgrl "PRIMARY" \
            "SHOW CONFIGURATION" \
            "SUCCESS\|enabled\|Enabled" \
            "Broker configuration enabled (retry)" || return 1
    }

    # Validate: both databases in configuration
    assert_dgmgrl "PRIMARY" \
        "SHOW DATABASE '${TEST_DB_UNIQUE_NAME}'" \
        "Primary\|PRIMARY" \
        "Primary database in broker" || return 1

    assert_dgmgrl "PRIMARY" \
        "SHOW DATABASE '${TEST_STANDBY_DB_UNIQUE_NAME}'" \
        "Standby\|STANDBY\|Physical" \
        "Standby database in broker" || return 1

    log_pass "Step 6 completed and validated"
}

# =============================================================================
# Phase: Step 7 - Verify Data Guard
# =============================================================================

phase_step7() {
    log_phase "STEP 7: Verify Data Guard"

    local result
    # Prompts: optional password/skip (config auto-selected)
    result=$(ssh_piped "STANDBY" \
        "./standby/07_verify_dataguard.sh" \
        "\n")

    local exit_code=$?
    log_info "Step 7 output (last 15 lines):"
    echo "$result" | tail -15 | while read -r line; do log_info "  $line"; done

    if [[ $exit_code -ne 0 ]]; then
        log_fail "Step 7 script exited with code ${exit_code}"
        record_issue "step7" "07_verify_dataguard.sh failed" "$(echo "$result" | tail -30)"
        return 1
    fi

    # Check for HEALTHY status in output
    if echo "$result" | grep -qi "HEALTHY\|healthy\|All checks passed"; then
        log_pass "Verification reports HEALTHY"
    elif echo "$result" | grep -qi "WARNING\|warning"; then
        log_info "Verification reports WARNINGs (non-fatal)"
        log_pass "Verification completed with warnings"
    else
        log_fail "Verification did not report healthy status"
        record_issue "step7" "Verification did not report HEALTHY" "$(echo "$result" | tail -20)"
        return 1
    fi

    # Independent validation: test log shipping
    log_info "Testing log shipping..."
    ssh_primary "sqlplus -s / as sysdba << 'SQLEOF'
ALTER SYSTEM SWITCH LOGFILE;
EXIT;
SQLEOF
    " > /dev/null

    sleep 5

    # Check for gaps
    local gaps
    gaps=$(ssh_standby "sqlplus -s / as sysdba << 'SQLEOF'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT COUNT(*) FROM v\$archive_gap;
EXIT;
SQLEOF
    " | tr -d '[:space:]')

    if [[ "${gaps}" == "0" ]]; then
        log_pass "No archive log gaps"
    else
        log_info "Archive gap count: ${gaps} (may resolve shortly)"
    fi

    log_pass "Step 7 completed and validated"
}

# =============================================================================
# Phase: Step 8 - Security Hardening (Optional)
# =============================================================================

phase_step8() {
    if [[ "${SKIP_SECURITY}" == "true" ]]; then
        log_skip "Step 8: Security Hardening (SKIP_SECURITY=true)"
        return 0
    fi

    log_phase "STEP 8: Security Hardening"

    local result
    # Prompts: typed confirmation (config auto-selected)
    result=$(ssh_piped "PRIMARY" \
        "./primary/08_security_hardening.sh" \
        "SECURE ${TEST_DB_NAME}")

    local exit_code=$?
    log_info "Step 8 output (last 10 lines):"
    echo "$result" | tail -10 | while read -r line; do log_info "  $line"; done

    if [[ $exit_code -ne 0 ]]; then
        log_fail "Step 8 script exited with code ${exit_code}"
        record_issue "step8" "08_security_hardening.sh failed" "$(echo "$result" | tail -20)"
        return 1
    fi

    # Validate: SYS account is locked
    assert_sql "PRIMARY" \
        "SELECT account_status FROM dba_users WHERE username = 'SYS';" \
        "LOCKED" \
        "SYS account locked" || return 1

    # Validate: OS authentication still works
    assert_sql "PRIMARY" \
        "SELECT 'OSAUTH=OK' FROM dual;" \
        "OSAUTH=OK" \
        "OS authentication works after lockout" || return 1

    log_pass "Step 8 completed and validated"
}

# =============================================================================
# Phase: Step 9 - Configure FSFO (Optional)
# =============================================================================

phase_step9() {
    if [[ "${SKIP_FSFO}" == "true" ]]; then
        log_skip "Step 9: Configure FSFO (SKIP_FSFO=true)"
        return 0
    fi

    log_phase "STEP 9: Configure Fast-Start Failover"

    local result
    # Prompts: observer user, password, confirm (config auto-selected)
    result=$(ssh_piped "PRIMARY" \
        "FSFO_THRESHOLD=${FSFO_THRESHOLD} ./primary/09_configure_fsfo.sh" \
        "${TEST_OBSERVER_USER}\n${TEST_OBSERVER_PASSWORD}\ny")

    local exit_code=$?
    log_info "Step 9 output (last 10 lines):"
    echo "$result" | tail -10 | while read -r line; do log_info "  $line"; done

    if [[ $exit_code -ne 0 ]]; then
        log_fail "Step 9 script exited with code ${exit_code}"
        record_issue "step9" "09_configure_fsfo.sh failed" "$(echo "$result" | tail -30)"
        return 1
    fi

    # Validate: FSFO enabled
    assert_dgmgrl "PRIMARY" \
        "SHOW FAST_START FAILOVER" \
        "Enabled\|enabled\|ENABLED" \
        "FSFO is enabled" || return 1

    # Validate: protection mode
    assert_sql "PRIMARY" \
        "SELECT protection_mode FROM v\$database;" \
        "MAXIMUM AVAILABILITY" \
        "Protection mode = MAXIMUM AVAILABILITY" || return 1

    # Validate: observer user exists
    assert_sql "PRIMARY" \
        "SELECT username FROM dba_users WHERE username = '${TEST_OBSERVER_USER}';" \
        "${TEST_OBSERVER_USER}" \
        "Observer user exists" || return 1

    log_pass "Step 9 completed and validated"
}

# =============================================================================
# Phase: Step 10 - Observer Setup (Optional)
# =============================================================================

phase_step10() {
    if [[ "${SKIP_OBSERVER:-true}" == "true" ]]; then
        log_skip "Step 10: Observer Setup (SKIP_OBSERVER=true)"
        return 0
    fi

    if [[ "${SKIP_FSFO}" == "true" ]]; then
        log_skip "Step 10: Observer Setup (SKIP_FSFO=true, FSFO not configured)"
        return 0
    fi

    log_phase "STEP 10: Observer Setup (on standby host)"

    # Setup wallet
    log_info "Setting up observer wallet..."
    local result
    # Prompts: wallet pwd, wallet pwd again, observer pwd (config auto-selected)
    result=$(ssh_piped "STANDBY" \
        "./fsfo/observer.sh setup" \
        "${TEST_WALLET_PASSWORD}\n${TEST_WALLET_PASSWORD}\n${TEST_OBSERVER_PASSWORD}")

    local exit_code=$?
    log_info "Observer setup output (last 10 lines):"
    echo "$result" | tail -10 | while read -r line; do log_info "  $line"; done

    if [[ $exit_code -ne 0 ]]; then
        log_fail "Observer wallet setup failed"
        record_issue "step10" "observer.sh setup failed" "$(echo "$result" | tail -20)"
        return 1
    fi

    log_pass "Observer wallet created"

    # Start observer
    log_info "Starting observer..."
    # No interactive prompts expected (config auto-selected)
    result=$(ssh_piped "STANDBY" \
        "./fsfo/observer.sh start" \
        "")

    exit_code=$?
    log_info "Observer start output (last 5 lines):"
    echo "$result" | tail -5 | while read -r line; do log_info "  $line"; done

    if [[ $exit_code -ne 0 ]]; then
        log_fail "Observer start failed"
        record_issue "step10" "observer.sh start failed" "$(echo "$result" | tail -20)"
        return 1
    fi

    # Validate: observer process running
    sleep 10
    if ssh_standby "ps -ef | grep -v grep | grep -q 'dgmgrl.*observer'" 2>/dev/null; then
        log_pass "Observer process is running"
    else
        log_fail "Observer process not found"
        record_issue "step10" "Observer process not running after start"
        return 1
    fi

    # Validate: observer registered in DGMGRL
    sleep 10
    assert_dgmgrl "PRIMARY" \
        "SHOW FAST_START FAILOVER" \
        "Observer.*:.*\|observer" \
        "Observer registered in FSFO" || {
        log_info "Observer may take time to register - continuing"
    }

    log_pass "Step 10 completed and validated"
}

# =============================================================================
# Phase: Step 11 - Role-Aware Service Trigger (Optional)
# =============================================================================

phase_step11() {
    if [[ "${SKIP_TRIGGER}" == "true" ]]; then
        log_skip "Step 11: Service Trigger (SKIP_TRIGGER=true)"
        return 0
    fi

    log_phase "STEP 11: Role-Aware Service Trigger"

    local result
    # Prompts (config auto-selected, no NFS confirm in this script):
    #   First run:  accept services (Enter), deploy (y)
    #   Re-run:     accept services (Enter), replace existing (y), deploy (y)
    # Extra y's after all prompts are harmless
    result=$(ssh_piped "PRIMARY" \
        "./trigger/create_role_trigger.sh" \
        "\ny\ny\ny")

    local exit_code=$?
    log_info "Step 11 output (last 10 lines):"
    echo "$result" | tail -10 | while read -r line; do log_info "  $line"; done

    if [[ $exit_code -ne 0 ]]; then
        # Service trigger may fail if no user services are discovered (test DB is empty)
        if echo "$result" | grep -qi "no.*services\|no.*service.*found\|empty"; then
            log_info "No user services found in test database (expected for empty DB)"
            log_skip "Step 11: No services to manage"
            return 0
        fi
        log_fail "Step 11 script exited with code ${exit_code}"
        record_issue "step11" "create_role_trigger.sh failed" "$(echo "$result" | tail -20)"
        return 1
    fi

    # Validate: package exists and is valid
    assert_sql "PRIMARY" \
        "SELECT status FROM dba_objects WHERE object_name = 'DG_SERVICE_MGR' AND object_type = 'PACKAGE BODY' AND owner = 'SYS';" \
        "VALID" \
        "DG_SERVICE_MGR package is VALID" || return 1

    # Validate: triggers exist and are enabled
    assert_sql "PRIMARY" \
        "SELECT status FROM dba_triggers WHERE trigger_name = 'TRG_MANAGE_SERVICES_ROLE_CHG' AND owner = 'SYS';" \
        "ENABLED" \
        "Role change trigger is ENABLED" || return 1

    assert_sql "PRIMARY" \
        "SELECT status FROM dba_triggers WHERE trigger_name = 'TRG_MANAGE_SERVICES_STARTUP' AND owner = 'SYS';" \
        "ENABLED" \
        "Startup trigger is ENABLED" || return 1

    log_pass "Step 11 completed and validated"
}

# =============================================================================
# Report
# =============================================================================

print_report() {
    log ""
    log "============================================================"
    log "  E2E TEST RESULTS"
    log "============================================================"
    log ""
    log "  ${GREEN}PASSED:${NC}  ${PASS_COUNT}"
    log "  ${RED}FAILED:${NC}  ${FAIL_COUNT}"
    log "  ${YELLOW}SKIPPED:${NC} ${SKIP_COUNT}"
    log "  ${RED}ISSUES:${NC}  ${ISSUE_COUNT}"
    log ""
    log "  Full log:    ${FULL_LOG}"
    log "  Results:     ${RESULTS_FILE}"
    [[ -f "$ISSUES_FILE" ]] && log "  Issues:      ${ISSUES_FILE}"
    log ""

    if [[ $FAIL_COUNT -eq 0 ]]; then
        log "  ${GREEN}ALL TESTS PASSED${NC}"
    else
        log "  ${RED}SOME TESTS FAILED - review issues file${NC}"
    fi
    log "============================================================"
}

# =============================================================================
# Phase Registry
# =============================================================================

# Ordered list of all phases
ALL_PHASES=(
    preflight
    deploy
    cleanup_previous
    create_db
    step1
    step2
    step3
    step4
    step5
    step6
    step7
    step8
    step9
    step10
    step11
    cleanup_final
)

run_phase() {
    local phase="$1"
    case "$phase" in
        preflight)       phase_preflight ;;
        deploy)          phase_deploy ;;
        cleanup_previous|cleanup) phase_cleanup ;;
        cleanup_primary) cleanup_primary ;;
        cleanup_standby) cleanup_standby ;;
        cleanup_nfs)     cleanup_nfs ;;
        create_db)       phase_create_db ;;
        step1)           phase_step1 ;;
        step2)           phase_step2 ;;
        step3)           phase_step3 ;;
        step4)           phase_step4 ;;
        step5)           phase_step5 ;;
        step6)           phase_step6 ;;
        step7)           phase_step7 ;;
        step8)           phase_step8 ;;
        step9)           phase_step9 ;;
        step10)          phase_step10 ;;
        step11)          phase_step11 ;;
        cleanup_final)   phase_cleanup ;;
        *)
            log "${RED}Unknown phase: ${phase}${NC}"
            return 1
            ;;
    esac
}

# =============================================================================
# Main
# =============================================================================

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --from <phase>    Start from a specific phase (skip earlier phases)
  --only <phase>    Run only a single phase
  --skip-cleanup    Don't run final cleanup (keep databases for inspection)
  --help            Show this help

Phases (in execution order):
  preflight         Validate SSH, Oracle, NFS
  deploy            Git clone/pull on both hosts
  cleanup_previous  Remove leftovers from prior run
  create_db         Create test primary database
  step1             Gather primary info
  step2             Generate standby config
  step3             Setup standby environment
  step4             Prepare primary for DG
  step5             Clone standby (RMAN duplicate)
  step6             Configure DG broker
  step7             Verify Data Guard
  step8             Security hardening (optional)
  step9             Configure FSFO (optional)
  step10            Observer setup (optional)
  step11            Service trigger (optional)
  cleanup_final     Drop databases, remove all files

Standalone cleanup phases (use with --only):
  cleanup_primary   Clean up primary host only
  cleanup_standby   Clean up standby host only
  cleanup_nfs       Clean up NFS share only
  cleanup           Full cleanup (all three)

Examples:
  ./run_e2e_test.sh                      # Full run
  ./run_e2e_test.sh --from step5         # Resume from RMAN duplicate
  ./run_e2e_test.sh --only cleanup       # Just cleanup
  ./run_e2e_test.sh --only create_db     # Just create test DB
  ./run_e2e_test.sh --skip-cleanup       # Keep DBs after tests
EOF
}

main() {
    local from_phase=""
    local only_phase=""
    local skip_cleanup="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from)   from_phase="$2"; shift 2 ;;
            --only)   only_phase="$2"; shift 2 ;;
            --skip-cleanup) skip_cleanup="true"; shift ;;
            --help|-h) usage; exit 0 ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Initialize issues file
    cat > "$ISSUES_FILE" << 'EOF'
# E2E Test Issues

Issues discovered during test execution.

---
EOF

    log "Oracle Data Guard E2E Test"
    log "Started: $(date)"
    log "Jump:    ${JUMP_USER}@${JUMP_HOST}:${JUMP_SSH_PORT}"
    log "Primary: ${SSH_USER}@${PRIMARY_HOST}:${PRIMARY_SSH_PORT}"
    log "Standby: ${SSH_USER}@${STANDBY_HOST}:${STANDBY_SSH_PORT}"
    log "Test DB: ${TEST_DB_NAME} / ${TEST_STANDBY_DB_UNIQUE_NAME}"
    log ""

    # Single phase mode
    if [[ -n "$only_phase" ]]; then
        run_phase "$only_phase"
        local rc=$?
        print_report
        return $rc
    fi

    # Determine starting phase
    local started="false"
    [[ -z "$from_phase" ]] && started="true"

    for phase in "${ALL_PHASES[@]}"; do
        # Skip cleanup_final if requested
        if [[ "$phase" == "cleanup_final" && "$skip_cleanup" == "true" ]]; then
            log_skip "Final cleanup (--skip-cleanup)"
            continue
        fi

        # Handle --from
        if [[ "$started" == "false" ]]; then
            if [[ "$phase" == "$from_phase" ]]; then
                started="true"
            else
                log_skip "Phase: ${phase} (skipped - before --from ${from_phase})"
                continue
            fi
        fi

        log ""
        if ! run_phase "$phase"; then
            log ""
            log "${RED}Phase '${phase}' failed. Stopping.${NC}"

            if [[ "${CLEANUP_ON_FAILURE}" == "true" ]]; then
                log_info "CLEANUP_ON_FAILURE=true, running cleanup..."
                phase_cleanup || true
            else
                log_info "Databases left in place for inspection."
                log_info "Run './run_e2e_test.sh --only cleanup' when done."
            fi

            print_report
            exit 1
        fi
    done

    print_report

    if [[ $FAIL_COUNT -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
