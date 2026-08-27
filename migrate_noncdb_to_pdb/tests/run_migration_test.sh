#!/usr/bin/env bash
# =============================================================================
# E2E test driver for the non-CDB -> PDB migration.
# =============================================================================
# Pre-conditions on the test environment:
#   * dgnonc (non-CDB) primary on PRIMARY_HOST, with dgnonc_s standby on
#     STANDBY_HOST -- already in working Data Guard.
#   * dgcdb  (CDB)     primary on PRIMARY_HOST, with dgcdb_s   standby on
#     STANDBY_HOST -- already in working Data Guard.
#   * NFS share /OINSTALL/_dataguard_setup mounted on both hosts.
#   * tests/e2e/config.env (the dgnonc one) is filled in -- we only reuse it
#     for the SSH/jump-host parameters and ORACLE_HOME / ORACLE_BASE.
#
# What this driver does:
#   1. SSH to primary host through the jump host.
#   2. Verify both dgnonc and dgcdb are PRIMARY and READ WRITE.
#   3. git pull / clone the repo on primary host (same pattern as run_e2e_test.sh).
#   4. Render a migration config.env on the remote and run scripts 01..05.
#   5. Smoke-test the new PDB and confirm it is applied on the CDB standby.
#
# By default, step 06 (decommission / drop non-CDB) is skipped. Pass
# --decommission to enable, --drop to actually drop.
#
# Usage:
#   bash ./run_migration_test.sh                   # safe end-to-end
#   bash ./run_migration_test.sh --from plug       # resume from step 04
#   bash ./run_migration_test.sh --decommission    # also run step 06 (no DROP)
#   bash ./run_migration_test.sh --decommission --drop   # destructive!
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="${ROOT_DIR}/tests/e2e/logs"
mkdir -p "$LOG_DIR"
RESULTS_FILE="${LOG_DIR}/migration_results_${TIMESTAMP}.log"
ISSUES_FILE="${LOG_DIR}/migration_issues_${TIMESTAMP}.md"
FULL_LOG="${LOG_DIR}/migration_full_${TIMESTAMP}.log"

# We inherit jump-host & ORACLE_HOME values from the dgnonc test config.
CONFIG_ENV="${CONFIG_ENV:-${ROOT_DIR}/tests/e2e/config.env}"
if [[ ! -f "$CONFIG_ENV" ]]; then
    echo "ERROR: ${CONFIG_ENV} not found." >&2
    exit 2
fi
# shellcheck disable=SC1090
source "$CONFIG_ENV"

# Migration-specific defaults (override via env)
SOURCE_DB_NAME="${SOURCE_DB_NAME:-dgnonc}"
SOURCE_DB_UNIQUE_NAME="${SOURCE_DB_UNIQUE_NAME:-dgnonc}"
SOURCE_STANDBY_UNIQUE_NAME="${SOURCE_STANDBY_UNIQUE_NAME:-dgnonc_s}"
SOURCE_ORACLE_SID="${SOURCE_ORACLE_SID:-dgnonc}"
TARGET_CDB_NAME="${TARGET_CDB_NAME:-dgcdb}"
TARGET_CDB_UNIQUE_NAME="${TARGET_CDB_UNIQUE_NAME:-dgcdb}"
TARGET_CDB_STANDBY_UNIQUE_NAME="${TARGET_CDB_STANDBY_UNIQUE_NAME:-dgcdb_s}"
TARGET_CDB_ORACLE_SID="${TARGET_CDB_ORACLE_SID:-dgcdb}"
NEW_PDB_NAME="${NEW_PDB_NAME:-dgnonc_pdb}"

REPO_DIR="${REPO_DIR:-/home/oracle/dataguard_setup_tests}"
NFS_SHARE="${NFS_SHARE:-/OINSTALL/_dataguard_setup}"
TARGET_PDB_DATAFILE_DIR="${TARGET_PDB_DATAFILE_DIR:-${ORACLE_BASE}/oradata/${TARGET_CDB_NAME}}"

# ---- Logging --------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0; SKIP=0; ISSUE=0
log()   { local m="[$(date '+%H:%M:%S')] $*"; printf '%b\n' "$m"; printf '%b\n' "$m" >> "$FULL_LOG"; }
log_phase() { log ""; log "${BLUE}============================================================${NC}";
              log "${BLUE}  $*${NC}"; log "${BLUE}============================================================${NC}"; }
log_pass()  { log "${GREEN}  [PASS]${NC} $*"; echo "[PASS] $*" >> "$RESULTS_FILE"; PASS=$((PASS+1)); }
log_fail()  { log "${RED}  [FAIL]${NC} $*"; echo "[FAIL] $*" >> "$RESULTS_FILE"; FAIL=$((FAIL+1)); }
log_skip()  { log "${YELLOW}  [SKIP]${NC} $*"; echo "[SKIP] $*" >> "$RESULTS_FILE"; SKIP=$((SKIP+1)); }
log_info()  { log "${CYAN}  [INFO]${NC} $*"; }
record_issue() {
    local phase="$1"; local desc="$2"; local details="${3:-}"
    ISSUE=$((ISSUE+1))
    {
        echo
        echo "### Issue #${ISSUE}: ${phase}"
        echo
        echo "**Description:** ${desc}"
        if [[ -n "$details" ]]; then
            echo
            echo "\`\`\`"
            echo "${details}"
            echo "\`\`\`"
        fi
        echo "---"
    } >> "$ISSUES_FILE"
    log "${RED}  [ISSUE #${ISSUE}]${NC} ${desc}"
}

# ---- SSH helpers (same pattern as tests/e2e/run_e2e_test.sh) --------------
DB_SSH_KEY_OPT=""; [[ -n "${SSH_KEY:-}" ]] && DB_SSH_KEY_OPT="-i ${SSH_KEY}"
JUMP_KEY_OPT="";   [[ -n "${JUMP_KEY:-}" ]] && JUMP_KEY_OPT="-i ${JUMP_KEY}"

_ssh_hop() {
    local host="$1"; local port="$2"; local cmd="$3"
    ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} \
        -J "${JUMP_USER}@${JUMP_HOST}:${JUMP_SSH_PORT}" \
        -p "${port}" "${SSH_USER}@${host}" \
        "export ORACLE_HOME='${ORACLE_HOME}'; \
         export ORACLE_BASE='${ORACLE_BASE}'; \
         export PATH=\"\${ORACLE_HOME}/bin:\${PATH}\"; \
         export NFS_SHARE='${NFS_SHARE}'; \
         ${cmd}" 2>&1
}
ssh_primary() { _ssh_hop "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}" "$1"; }
ssh_standby() { _ssh_hop "${STANDBY_HOST}" "${STANDBY_SSH_PORT}" "$1"; }

# Save a small ssh wrapper script on disk so we can spawn migration scripts
# with a timeout and stream the output line-by-line into FULL_LOG.
ssh_run_capture() {
    local label="$1"; shift
    local cmd="$*"
    log_info "[${label}] $ ${cmd}"
    if [[ "$label" == "PRIMARY" ]]; then
        ssh_primary "${cmd}" | tee -a "$FULL_LOG"
        return ${PIPESTATUS[0]}
    else
        ssh_standby "${cmd}" | tee -a "$FULL_LOG"
        return ${PIPESTATUS[0]}
    fi
}

# =============================================================================
# Phases
# =============================================================================

phase_preflight_local() {
    log_phase "LOCAL PREFLIGHT"
    log_info "Project root: ${ROOT_DIR}"
    log_info "Log files:    ${RESULTS_FILE}, ${FULL_LOG}, ${ISSUES_FILE}"

    # Reachability
    if ssh ${SSH_OPTS} ${JUMP_KEY_OPT} -p "${JUMP_SSH_PORT}" "${JUMP_USER}@${JUMP_HOST}" "echo ok" 2>/dev/null | grep -q ok; then
        log_pass "SSH to jump host (${JUMP_HOST})"
    else
        log_fail "SSH to jump host (${JUMP_HOST})"; return 1
    fi
    if ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} -J "${JUMP_USER}@${JUMP_HOST}:${JUMP_SSH_PORT}" \
        -p "${PRIMARY_SSH_PORT}" "${SSH_USER}@${PRIMARY_HOST}" "echo ok" 2>/dev/null | grep -q ok; then
        log_pass "SSH to PRIMARY (${PRIMARY_HOST}:${PRIMARY_SSH_PORT})"
    else
        log_fail "SSH to PRIMARY"; return 1
    fi
    if ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} -J "${JUMP_USER}@${JUMP_HOST}:${JUMP_SSH_PORT}" \
        -p "${STANDBY_SSH_PORT}" "${SSH_USER}@${STANDBY_HOST}" "echo ok" 2>/dev/null | grep -q ok; then
        log_pass "SSH to STANDBY (${STANDBY_HOST}:${STANDBY_SSH_PORT})"
    else
        log_fail "SSH to STANDBY"; return 1
    fi
}

phase_check_dbs_running() {
    log_phase "CHECK: dgnonc and dgcdb both running and PRIMARY"
    local out

    out=$(ssh_primary "
        export ORACLE_SID='${SOURCE_ORACLE_SID}'
        sqlplus -s -L / as sysdba <<SQL
SET PAGESIZE 0 LINESIZE 200 FEEDBACK OFF HEADING OFF
SELECT 'NONC|'||name||'|'||open_mode||'|'||database_role||'|'||cdb FROM v\\\$database;
EXIT;
SQL
    ")
    if echo "$out" | grep -qE "^NONC[|]$(printf %s "$SOURCE_DB_NAME" | tr "[:lower:]" "[:upper:]")[|]READ WRITE[|]PRIMARY[|]NO"; then
        log_pass "Source non-CDB ${SOURCE_DB_NAME} is PRIMARY READ WRITE"
    else
        log_fail "Source non-CDB ${SOURCE_DB_NAME} not in expected state"
        record_issue "check_dbs" "Source non-CDB unhealthy" "$out"
        return 1
    fi

    out=$(ssh_primary "
        export ORACLE_SID='${TARGET_CDB_ORACLE_SID}'
        sqlplus -s -L / as sysdba <<SQL
SET PAGESIZE 0 LINESIZE 200 FEEDBACK OFF HEADING OFF
SELECT 'CDB|'||name||'|'||open_mode||'|'||database_role||'|'||cdb FROM v\\\$database;
EXIT;
SQL
    ")
    if echo "$out" | grep -qE "^CDB[|]$(printf %s "$TARGET_CDB_NAME" | tr "[:lower:]" "[:upper:]")[|]READ WRITE[|]PRIMARY[|]YES"; then
        log_pass "Target CDB ${TARGET_CDB_NAME} is PRIMARY READ WRITE"
    else
        log_fail "Target CDB ${TARGET_CDB_NAME} not in expected state"
        record_issue "check_dbs" "Target CDB unhealthy" "$out"
        return 1
    fi
}

phase_deploy() {
    log_phase "DEPLOY: pulling latest repo on PRIMARY"
    local result
    result=$(ssh_primary "
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
        chmod +x '${REPO_DIR}'/migrate_noncdb_to_pdb/*.sh
    ")
    if echo "$result" | grep -q 'DEPLOY_.*_OK'; then
        log_pass "Repo deployed to ${REPO_DIR}"
    else
        log_fail "Repo deploy failed"; record_issue "deploy" "Repo deploy failed" "$result"; return 1
    fi
}

phase_render_config() {
    log_phase "RENDER: generating migration config.env on PRIMARY"
    local cfg_path="${REPO_DIR}/migrate_noncdb_to_pdb/config.env"
    ssh_primary "cat > '${cfg_path}' <<'EOF'
SOURCE_DB_NAME=\"${SOURCE_DB_NAME}\"
SOURCE_DB_UNIQUE_NAME=\"${SOURCE_DB_UNIQUE_NAME}\"
SOURCE_STANDBY_UNIQUE_NAME=\"${SOURCE_STANDBY_UNIQUE_NAME}\"
SOURCE_ORACLE_SID=\"${SOURCE_ORACLE_SID}\"
TARGET_CDB_NAME=\"${TARGET_CDB_NAME}\"
TARGET_CDB_UNIQUE_NAME=\"${TARGET_CDB_UNIQUE_NAME}\"
TARGET_CDB_STANDBY_UNIQUE_NAME=\"${TARGET_CDB_STANDBY_UNIQUE_NAME}\"
TARGET_CDB_ORACLE_SID=\"${TARGET_CDB_ORACLE_SID}\"
NEW_PDB_NAME=\"${NEW_PDB_NAME}\"
ORACLE_HOME=\"${ORACLE_HOME}\"
ORACLE_BASE=\"${ORACLE_BASE}\"
NFS_SHARE=\"${NFS_SHARE}\"
TARGET_PDB_DATAFILE_DIR=\"${TARGET_PDB_DATAFILE_DIR}\"
SKIP_DECOMMISSION=\"${SKIP_DECOMMISSION:-true}\"
ALLOW_DROP_NONCDB=\"${ALLOW_DROP_NONCDB:-no}\"
EOF
    cat '${cfg_path}'"
    log_pass "Migration config rendered to ${cfg_path}"
}

run_remote_step() {
    local script="$1"
    local label="$2"
    log_phase "STEP: ${label}"
    if ssh_run_capture PRIMARY "MIGRATE_NONINTERACTIVE=1 bash '${REPO_DIR}/migrate_noncdb_to_pdb/${script}'"; then
        log_pass "${label}"
    else
        log_fail "${label}"
        record_issue "${script}" "${label} failed"
        return 1
    fi
}

phase_collect_logs() {
    log_phase "COLLECT: pulling migration logs from PRIMARY"
    local rdir="${NFS_SHARE}/logs/migrate_${SOURCE_DB_NAME}_to_${TARGET_CDB_NAME}"
    local local_target="${LOG_DIR}/migrate_${SOURCE_DB_NAME}_to_${TARGET_CDB_NAME}_${TIMESTAMP}"
    mkdir -p "$local_target"
    # Copy via SSH cat (no scp through nested jump complications)
    local files
    files=$(ssh_primary "ls -1 '${rdir}'/ 2>/dev/null") || true
    if [[ -z "$files" ]]; then
        log_skip "No remote migration logs at ${rdir}"; return 0
    fi
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        ssh_primary "cat '${rdir}/${f}'" > "${local_target}/${f}" 2>/dev/null || true
        log_info "  fetched ${f}"
    done <<< "$files"
    log_pass "Migration logs in ${local_target}"
}

phase_smoke_pdb() {
    log_phase "SMOKE: confirm new PDB ${NEW_PDB_NAME} on primary and standby"
    local out
    out=$(ssh_primary "
        export ORACLE_SID='${TARGET_CDB_ORACLE_SID}'
        sqlplus -s -L / as sysdba <<SQL
SET PAGESIZE 0 LINESIZE 200 FEEDBACK OFF HEADING OFF
SELECT 'PRI|'||name||'|'||open_mode FROM v\\\$pdbs WHERE name=UPPER('${NEW_PDB_NAME}');
EXIT;
SQL
    ")
    if echo "$out" | grep -q "^PRI|.*|READ WRITE"; then
        log_pass "PDB ${NEW_PDB_NAME} OPEN READ WRITE on primary"
    else
        log_fail "PDB ${NEW_PDB_NAME} not READ WRITE on primary"
        record_issue "smoke" "PDB not READ WRITE on primary" "$out"
        return 1
    fi
    out=$(ssh_standby "
        export ORACLE_SID='${TARGET_CDB_ORACLE_SID}'
        sqlplus -s -L / as sysdba <<SQL
SET PAGESIZE 0 LINESIZE 200 FEEDBACK OFF HEADING OFF
SELECT 'STBY|'||name||'|'||open_mode FROM v\\\$pdbs WHERE name=UPPER('${NEW_PDB_NAME}');
EXIT;
SQL
    ")
    if echo "$out" | grep -q "^STBY|"; then
        log_pass "PDB ${NEW_PDB_NAME} present on standby ($(echo "$out" | grep '^STBY|' | head -1))"
    else
        log_fail "PDB ${NEW_PDB_NAME} not visible on standby"
        record_issue "smoke" "PDB not visible on standby" "$out"
        return 1
    fi
}

# =============================================================================
# Main
# =============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --from <step>     Resume from a specific step. Steps:
                       preflight, check, deploy, config,
                       s01, s02, s03, s04, s05, smoke, s06
  --decommission    Run step 06 (remove non-CDB DG broker, shutdown).
  --drop            With --decommission, also DROP DATABASE on the non-CDB.
  --help            This help.

By default the test runs preflight..smoke (no decommission, no drop).

Pre-conditions:
  * dgnonc + dgnonc_s already in working DG
  * dgcdb  + dgcdb_s  already in working DG
  * /OINSTALL/_dataguard_setup mounted on both hosts
  * tests/e2e/config.env filled (jump host etc.)
EOF
}

main() {
    local from_step=""
    local decommission="false"
    local drop="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from) from_step="$2"; shift 2 ;;
            --decommission) decommission="true"; shift ;;
            --drop) drop="true"; shift ;;
            --help|-h) usage; exit 0 ;;
            *) echo "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    SKIP_DECOMMISSION="true"
    ALLOW_DROP_NONCDB="no"
    if [[ "$decommission" == "true" ]]; then
        SKIP_DECOMMISSION="false"
        [[ "$drop" == "true" ]] && ALLOW_DROP_NONCDB="I_UNDERSTAND"
    fi
    export SKIP_DECOMMISSION ALLOW_DROP_NONCDB

    cat > "$ISSUES_FILE" <<EOF
# Migration test issues — ${TIMESTAMP}

EOF
    : > "$RESULTS_FILE"
    : > "$FULL_LOG"

    local should_run="true"
    [[ -n "$from_step" ]] && should_run="false"

    declare -a steps=(preflight check deploy config s01 s02 s03 s04 s05 smoke s06 collect)
    for s in "${steps[@]}"; do
        if [[ -n "$from_step" && "$s" == "$from_step" ]]; then should_run="true"; fi
        [[ "$should_run" == "true" ]] || { log_skip "skip ${s}"; continue; }
        case "$s" in
            preflight) phase_preflight_local ;;
            check)     phase_check_dbs_running ;;
            deploy)    phase_deploy ;;
            config)    phase_render_config ;;
            s01)       run_remote_step "01_preflight.sh"             "01 preflight" ;;
            s02)       run_remote_step "02_quiesce_noncdb.sh"        "02 quiesce non-CDB" ;;
            s03)       run_remote_step "03_describe_and_stage.sh"    "03 describe + stage" ;;
            s04)       run_remote_step "04_plug_into_cdb.sh"         "04 plug into CDB" ;;
            s05)       run_remote_step "05_verify_pdb_dataguard.sh"  "05 verify PDB DG" ;;
            smoke)     phase_smoke_pdb ;;
            s06)
                if [[ "$decommission" == "true" ]]; then
                    run_remote_step "06_decommission_noncdb.sh" "06 decommission non-CDB"
                else
                    log_skip "06 decommission (use --decommission to enable)"
                fi
                ;;
            collect)   phase_collect_logs ;;
        esac || true
    done

    log_phase "RESULT: PASS=${PASS}  FAIL=${FAIL}  SKIP=${SKIP}  ISSUES=${ISSUE}"
    log_info "Results:  ${RESULTS_FILE}"
    log_info "Full log: ${FULL_LOG}"
    log_info "Issues:   ${ISSUES_FILE}"
    [[ "$FAIL" -eq 0 ]]
}

main "$@"
