#!/bin/bash
# ============================================================
# Shared helpers for non-CDB -> PDB migration scripts
# ============================================================
# Sourced by 01..06 scripts. Provides logging, config loading,
# SQL helpers, DGMGRL helpers, and small utilities.
#
# Logs go to:
#   - MIGRATE_LOG_DIR/<script>_<timestamp>.log  (per-script file)
#   - MIGRATE_LOG_DIR/migrate.log               (combined transcript)
# ============================================================

set -u
set -o pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${LIB_DIR}/.." && pwd)"

# Colours (best-effort; suppressed when not on a TTY)
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

# ------------------------------------------------------------
# Config loading
# ------------------------------------------------------------
load_config() {
    local cfg="${MIGRATE_CONFIG:-${LIB_DIR}/config.env}"
    if [[ ! -f "$cfg" ]]; then
        echo "ERROR: config not found at ${cfg}." >&2
        echo "       Copy config.env.template to config.env or set MIGRATE_CONFIG." >&2
        exit 2
    fi
    # shellcheck disable=SC1090
    source "$cfg"
    MIGRATE_CONFIG_FILE="$cfg"

    : "${SOURCE_DB_NAME:?SOURCE_DB_NAME unset in config}"
    : "${SOURCE_DB_UNIQUE_NAME:?SOURCE_DB_UNIQUE_NAME unset in config}"
    : "${TARGET_CDB_NAME:?TARGET_CDB_NAME unset in config}"
    : "${TARGET_CDB_UNIQUE_NAME:?TARGET_CDB_UNIQUE_NAME unset in config}"
    : "${NEW_PDB_NAME:?NEW_PDB_NAME unset in config}"
    : "${ORACLE_HOME:?ORACLE_HOME unset in config}"
    : "${ORACLE_BASE:?ORACLE_BASE unset in config}"
    : "${NFS_SHARE:?NFS_SHARE unset in config}"
    : "${TARGET_PDB_DATAFILE_DIR:?TARGET_PDB_DATAFILE_DIR unset in config}"

    # Derived paths
    MIGRATE_STAGE_DIR="${NFS_SHARE}/migrate/${SOURCE_DB_NAME}_to_${TARGET_CDB_NAME}"
    MIGRATE_MANIFEST="${MIGRATE_STAGE_DIR}/${SOURCE_DB_NAME}_manifest.xml"
    MIGRATE_DATAFILE_STAGE="${MIGRATE_STAGE_DIR}/datafiles"
    MIGRATE_LOG_DIR="${MIGRATE_LOG_DIR:-${NFS_SHARE}/logs/migrate_${SOURCE_DB_NAME}_to_${TARGET_CDB_NAME}}"
    MIGRATE_STATE_FILE="${MIGRATE_STAGE_DIR}/state.env"

    mkdir -p "$MIGRATE_STAGE_DIR" "$MIGRATE_DATAFILE_STAGE" "$MIGRATE_LOG_DIR"

    export ORACLE_HOME ORACLE_BASE
    export PATH="$ORACLE_HOME/bin:$PATH"
}

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------
init_log() {
    local script_name="$1"
    local ts
    ts="$(date '+%Y%m%d_%H%M%S')"
    LOG_FILE="${MIGRATE_LOG_DIR}/${script_name}_${ts}.log"
    COMBINED_LOG="${MIGRATE_LOG_DIR}/migrate.log"
    : > "$LOG_FILE"
    {
        echo "============================================================"
        echo "Script:    ${script_name}"
        echo "Started:   $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Hostname:  $(hostname 2>/dev/null || echo unknown)"
        echo "User:      $(whoami)"
        echo "ORACLE_SID:${ORACLE_SID:-unset}"
        echo "Config:    ${MIGRATE_CONFIG_FILE}"
        echo "============================================================"
    } | tee -a "$LOG_FILE" "$COMBINED_LOG" >/dev/null
}

_log() {
    local level="$1"; shift
    local color="$1"; shift
    local msg="$*"
    local stamp
    stamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "%b[%s]%b %s - %s\n" "$color" "$level" "$NC" "$stamp" "$msg"
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf "[%s] %s - %s\n" "$level" "$stamp" "$msg" >> "$LOG_FILE"
    fi
    if [[ -n "${COMBINED_LOG:-}" ]]; then
        printf "[%s] %s - %s\n" "$level" "$stamp" "$msg" >> "$COMBINED_LOG"
    fi
}
log_info()    { _log INFO    "$GREEN"  "$*"; }
log_warn()    { _log WARN    "$YELLOW" "$*"; }
log_error()   { _log ERROR   "$RED"    "$*"; }
log_success() { _log OK      "$CYAN"   "$*"; }
log_step()    {
    printf "\n%b============================================================%b\n" "$BLUE" "$NC"
    printf "%b  %s%b\n" "$BLUE" "$*" "$NC"
    printf "%b============================================================%b\n\n" "$BLUE" "$NC"
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf "\n============================================================\n  %s\n============================================================\n\n" "$*" >> "$LOG_FILE"
    fi
    if [[ -n "${COMBINED_LOG:-}" ]]; then
        printf "\n============================================================\n  %s\n============================================================\n\n" "$*" >> "$COMBINED_LOG"
    fi
}

# Append a key=value to the shared state file (idempotent: replaces existing key)
record_state() {
    local key="$1"; local value="$2"
    local tmp="${MIGRATE_STATE_FILE}.tmp.$$"
    if [[ -f "$MIGRATE_STATE_FILE" ]]; then
        grep -v "^${key}=" "$MIGRATE_STATE_FILE" > "$tmp" || true
    else
        : > "$tmp"
    fi
    printf '%s=%q\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$MIGRATE_STATE_FILE"
}

read_state() {
    local key="$1"
    [[ -f "$MIGRATE_STATE_FILE" ]] || { echo ""; return; }
    # shellcheck disable=SC1090
    ( source "$MIGRATE_STATE_FILE" 2>/dev/null; eval "printf '%s' \"\${${key}:-}\"" )
}

# ------------------------------------------------------------
# SQL / DGMGRL helpers
# Run as the local Oracle owner (OS auth).
# ------------------------------------------------------------

# run_sql <sid> <sql ...>     (single connection, OS auth, returns stdout)
run_sql() {
    local sid="$1"; shift
    local sql="$*"
    ORACLE_SID="$sid" sqlplus -s -L / as sysdba <<EOF 2>&1
SET PAGESIZE 0 LINESIZE 32767 FEEDBACK OFF HEADING OFF VERIFY OFF TRIMSPOOL ON
WHENEVER SQLERROR EXIT SQL.SQLCODE
${sql}
EXIT;
EOF
}

# run_sql_script <sid> <script-path>
run_sql_script() {
    local sid="$1"; local path="$2"
    # </dev/null: if the script errors before EXIT, sqlplus must get EOF and
    # exit rather than fall through to its SQL> prompt and hang on the terminal.
    ORACLE_SID="$sid" sqlplus -s -L / as sysdba @"$path" </dev/null
}

# Run a one-line scalar query and trim whitespace
sql_scalar() {
    local sid="$1"; shift
    local sql="$*"
    run_sql "$sid" "$sql" | tr -d '[:space:]'
}

# Inspect captured DGMGRL output for failure patterns. dgmgrl scripts always
# end in EXIT; below, so the process exit code is 0 even when a command
# inside the script failed - the only reliable signal is the text DGMGRL
# printed. Matches real ORA-/DGM- error codes and "Error:"/"Failed." lines,
# while deliberately NOT matching benign broker report lines such as
# "Error: 0" (no error) that appear in SHOW CONFIGURATION / SHOW DATABASE
# output, or property names/values that merely contain the word "error".
#
# This mirrors common/dg_functions.sh's dgmgrl_output_has_error() - kept as
# a manual copy (not sourced) because this subproject is deliberately
# standalone (see README/WALKTHROUGH); keep both in sync if either changes.
# Usage: dgmgrl_output_has_error <output>
dgmgrl_output_has_error() {
    local output="$1"
    # Real Oracle/broker error codes anywhere in the output.
    if printf '%s\n' "$output" | grep -Eq 'ORA-[0-9]|DGM-[0-9]'; then
        return 0
    fi
    # A standalone "Error:" line with a nonzero code. "Error: 0" is the
    # benign per-member status line in SHOW CONFIGURATION/SHOW DATABASE.
    if printf '%s\n' "$output" | grep -Eiq '^[[:space:]]*Error:[[:space:]]*[1-9]'; then
        return 0
    fi
    # DGMGRL prints a standalone "Failed." line for some failed operations.
    if printf '%s\n' "$output" | grep -Eiq '^[[:space:]]*Failed\.[[:space:]]*$'; then
        return 0
    fi
    return 1
}

# Run a DGMGRL script. dgmgrl scripts always end in EXIT; so the process's
# own exit code is 0 even when a command inside the script failed (e.g. an
# EDIT DATABASE / REMOVE CONFIGURATION that errored) - scan the captured
# output for failure patterns and return non-zero when found, so callers
# relying on the return code (and existing "|| log_warn" fallbacks) work.
run_dgmgrl() {
    local sid="$1"; shift
    local script="$*"
    local output
    output=$(ORACLE_SID="$sid" "$ORACLE_HOME/bin/dgmgrl" -silent / <<EOF 2>&1
${script}
EXIT;
EOF
)
    printf '%s\n' "$output"
    if dgmgrl_output_has_error "$output"; then
        return 1
    fi
    return 0
}

# Mirror text into the log (and through stdout)
tee_into_log() {
    if [[ -n "${LOG_FILE:-}" ]]; then
        tee -a "$LOG_FILE" "$COMBINED_LOG"
    else
        cat
    fi
}

# Boilerplate confirmation prompt for destructive actions
confirm_or_abort() {
    local prompt="$1"
    if [[ "${MIGRATE_NONINTERACTIVE:-0}" == "1" ]]; then
        log_warn "Non-interactive mode: assuming YES for: ${prompt}"
        return 0
    fi
    printf "%b%s [type YES to continue]:%b " "$YELLOW" "$prompt" "$NC"
    local ans
    read -r ans || ans=""
    if [[ "$ans" != "YES" ]]; then
        log_error "Aborted by operator."
        exit 1
    fi
}

# Standard error trap for migration scripts
on_err() {
    local rc=$?
    log_error "Aborting (exit $rc) at line $1: $2"
    exit "$rc"
}
trap_err() {
    trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
}
