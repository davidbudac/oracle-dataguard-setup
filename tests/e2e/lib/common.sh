#!/usr/bin/env bash
# =============================================================================
# tests/e2e/lib/common.sh - configuration, logging and result tracking
# =============================================================================
# Sourced by e2e.sh and by every lib/, checks/ and proofs/ script. Never run
# directly. Expects E2E_DIR (tests/e2e) to be set by the caller; everything
# else is derived here.
# =============================================================================

[[ -n "${E2E_COMMON_LOADED:-}" ]] && return 0
E2E_COMMON_LOADED=1

# Some interactive environments export shell FUNCTIONS named grep/sed/awk
# (Claude Code wraps grep in its bundled ugrep, for one); a runner inherits
# them and the tools it drives then grep with something else than grep.
# Shed them: the suite and the scripts it runs use the real binaries.
unset -f grep egrep fgrep sed awk 2>/dev/null || true

E2E_DIR="${E2E_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT="$(cd "${E2E_DIR}/../.." && pwd)"
LIB_DIR="${E2E_DIR}/lib"
SCENARIO_DIR="${E2E_DIR}/scenarios"
ANSWERS_DIR="${E2E_DIR}/answers"
CHECKS_DIR="${E2E_DIR}/checks"
PROOFS_DIR="${E2E_DIR}/proofs"
LOG_ROOT="${E2E_DIR}/logs"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
load_config() {
    local cfg="${E2E_CONFIG:-${E2E_DIR}/config.env}"
    if [[ ! -f "$cfg" ]]; then
        echo "ERROR: ${cfg} not found. Copy config.env.template to config.env and fill it in." >&2
        return 1
    fi
    # shellcheck disable=SC1090
    source "$cfg"

    local var
    for var in PRIMARY_HOST STANDBY_HOST SSH_USER ORACLE_HOME ORACLE_BASE NFS_SHARE REPO_DIR; do
        if [[ -z "${!var:-}" ]]; then
            echo "ERROR: ${var} is not set in ${cfg}" >&2
            return 1
        fi
    done
    if [[ -n "${JUMP_HOST:-}" && -z "${JUMP_USER:-}" ]]; then
        echo "ERROR: JUMP_USER must be set when JUMP_HOST is set" >&2
        return 1
    fi

    JUMP_SSH_PORT="${JUMP_SSH_PORT:-22}"
    PRIMARY_SSH_PORT="${PRIMARY_SSH_PORT:-22}"
    STANDBY_SSH_PORT="${STANDBY_SSH_PORT:-22}"
    HOST3_SSH_PORT="${HOST3_SSH_PORT:-22}"
    HOST3_ORACLE_HOME="${HOST3_ORACLE_HOME:-$ORACLE_HOME}"
    SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR}"
    LAB_FS_SLOTS="${LAB_FS_SLOTS:-${ORACLE_BASE} ${HOME_FS:-/home/${SSH_USER}} /var/tmp}"
    LAB_SCRATCH="${LAB_SCRATCH:-/home/${SSH_USER}/e2e}"
    TEST_SYS_PASSWORD="${TEST_SYS_PASSWORD:-DgTest_2024#}"
    TEST_OBSERVER_USER="${TEST_OBSERVER_USER:-DG_OBSERVER}"
    TEST_OBSERVER_PASSWORD="${TEST_OBSERVER_PASSWORD:-ObsTest_2024#}"
    TEST_WALLET_PASSWORD="${TEST_WALLET_PASSWORD:-WalletTest_2024#}"
    TEST_DB_MEMORY_MB="${TEST_DB_MEMORY_MB:-1024}"
    TEST_DB_CHARSET="${TEST_DB_CHARSET:-AL32UTF8}"
    FSFO_THRESHOLD="${FSFO_THRESHOLD:-30}"
    LOCAL_DEPLOY="${LOCAL_DEPLOY:-true}"
    STEP_TIMEOUT="${STEP_TIMEOUT:-3600}"
    DBCA_TIMEOUT="${DBCA_TIMEOUT:-2400}"

    JUMP_OPT=""
    [[ -n "${JUMP_HOST:-}" ]] && JUMP_OPT="-J ${JUMP_USER}@${JUMP_HOST}:${JUMP_SSH_PORT}"
    DB_SSH_KEY_OPT=""
    [[ -n "${SSH_KEY:-}" ]] && DB_SSH_KEY_OPT="-i ${SSH_KEY}"
    return 0
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; DIM=''; NC=''
fi

RUN_LOG="${RUN_LOG:-}"        # full transcript of the whole run (set by e2e.sh)
RESULTS_FILE="${RESULTS_FILE:-}"  # one PASS/FAIL/SKIP line per assertion

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    printf '%b\n' "$msg"
    [[ -n "$RUN_LOG" ]] && printf '%b\n' "$msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$RUN_LOG"
    return 0
}
log_phase() {
    log ""
    log "${BLUE}============================================================${NC}"
    log "${BLUE}  $*${NC}"
    log "${BLUE}============================================================${NC}"
}
log_section() { log "${CYAN}--- $*${NC}"; }
log_info()    { log "${CYAN}  [INFO]${NC} $*"; }
log_warn()    { log "${YELLOW}  [WARN]${NC} $*"; }
log_error()   { log "${RED}  [ERROR]${NC} $*"; }
log_pass() {
    log "${GREEN}  [PASS]${NC} $*"
    [[ -n "$RESULTS_FILE" ]] && echo "[PASS] $*" >> "$RESULTS_FILE"
    PASS_COUNT=$((PASS_COUNT + 1))
}
log_fail() {
    log "${RED}  [FAIL]${NC} $*"
    [[ -n "$RESULTS_FILE" ]] && echo "[FAIL] $*" >> "$RESULTS_FILE"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}
log_skip() {
    log "${YELLOW}  [SKIP]${NC} $*"
    [[ -n "$RESULTS_FILE" ]] && echo "[SKIP] $*" >> "$RESULTS_FILE"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}
# Print the last N lines of a captured output block, indented, into the log.
log_tail() {
    local n="$1"; shift
    printf '%s\n' "$*" | tail -n "$n" | while IFS= read -r line; do log_info "  $line"; done
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
# Shell-quote a string for embedding in a remote command (single quotes).
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# upper/lower without bash 4 syntax (the runner may be macOS bash 3.2)
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# First path component of an absolute path: /u01/app -> /u01
fs_of() { local p="${1#/}"; printf '/%s' "${p%%/*}"; }

# Is $1 in the space-separated list $2?
in_list() {
    local needle="$1" item
    for item in $2; do [[ "$item" == "$needle" ]] && return 0; done
    return 1
}

# Portable "seconds since epoch"
now_s() { date +%s; }

# Elapsed as mm:ss
fmt_elapsed() { printf '%02d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }
