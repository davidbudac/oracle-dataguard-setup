#!/usr/bin/env bash
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
    : "${SOURCE_ORACLE_SID:?SOURCE_ORACLE_SID unset in config}"
    : "${TARGET_CDB_ORACLE_SID:?TARGET_CDB_ORACLE_SID unset in config}"
    : "${TARGET_CDB_STANDBY_UNIQUE_NAME:?TARGET_CDB_STANDBY_UNIQUE_NAME unset in config}"

    # The share must already exist and be writable BEFORE anything is created
    # under it: on a host where it is not mounted, mkdir -p would quietly build
    # the whole tree on the local disk and the standby would never see it.
    if [[ ! -d "$NFS_SHARE" || ! -w "$NFS_SHARE" ]]; then
        echo "ERROR: NFS_SHARE ${NFS_SHARE} is not an existing, writable directory (share not mounted?)." >&2
        exit 2
    fi

    # Derived paths
    MIGRATE_STAGE_DIR="${NFS_SHARE}/migrate/${SOURCE_DB_NAME}_to_${TARGET_CDB_NAME}"
    MIGRATE_MANIFEST="${MIGRATE_STAGE_DIR}/${SOURCE_DB_NAME}_manifest.xml"
    MIGRATE_DATAFILE_STAGE="${MIGRATE_STAGE_DIR}/datafiles"
    MIGRATE_LOG_DIR="${MIGRATE_LOG_DIR:-${NFS_SHARE}/logs/migrate_${SOURCE_DB_NAME}_to_${TARGET_CDB_NAME}}"
    MIGRATE_STATE_FILE="${MIGRATE_STAGE_DIR}/state.env"

    mkdir -p "$MIGRATE_STAGE_DIR" "$MIGRATE_DATAFILE_STAGE" "$MIGRATE_LOG_DIR" || {
        echo "ERROR: cannot create the migration directories under ${NFS_SHARE}." >&2
        exit 2
    }

    # Standby-side settings (all optional; see config.env.template).
    # STANDBY_STAGE_DIR is the path the CDB STANDBY host uses to reach the
    # staged datafiles - the same path as on this host when the share is
    # mounted identically (the default).
    STANDBY_STAGE_DIR="${STANDBY_STAGE_DIR:-$MIGRATE_DATAFILE_STAGE}"
    STANDBY_STAGE_DIR="${STANDBY_STAGE_DIR%/}"
    STANDBY_TNS_ALIAS="${TARGET_CDB_STANDBY_TNS_ALIAS:-$TARGET_CDB_STANDBY_UNIQUE_NAME}"

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

# Remove keys from the state file (so a stale flag from an earlier run cannot
# satisfy a later step's gate).
clear_state() {
    [[ -f "$MIGRATE_STATE_FILE" ]] || return 0
    local k tmp="${MIGRATE_STATE_FILE}.tmp.$$"
    cp "$MIGRATE_STATE_FILE" "$tmp"
    for k in "$@"; do
        grep -v "^${k}=" "$tmp" > "${tmp}.2" || true
        mv "${tmp}.2" "$tmp"
    done
    mv "$tmp" "$MIGRATE_STATE_FILE"
}

# require_state <key> <step script>  -  exit 1 unless <key> is recorded "true".
require_state() {
    if [[ "$(read_state "$1")" != "true" ]]; then
        log_error "Predecessor step not completed: state '$1' is not 'true'. Run $2 first."
        exit 1
    fi
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

# kv_get <KEY> <text>  -  value of the first "KEY=value" line, whitespace-stripped
kv_get() {
    printf '%s\n' "$2" | awk -v k="$1=" 'index($0,k)==1{print substr($0,length(k)+1); exit}' | tr -d '[:space:]'
}

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# df_avail_kb <path>  -  free KB on the filesystem holding <path> (POSIX df -Pk
# so the column layout is the same on Linux and AIX); empty when unknown.
df_avail_kb() {
    df -Pk "$1" 2>/dev/null | tail -1 | awk '{print $4}'
}

# version_cmp <a> <b>  -  compare dotted versions field by field AS INTEGERS
# (19.3.0.0.0 < 19.21.0.0.0; a plain string compare gets that backwards).
# Prints -1, 0 or 1.
version_cmp() {
    local i=0 x y
    local -a A B
    IFS=. read -r -a A <<< "$1"
    IFS=. read -r -a B <<< "$2"
    while (( i < ${#A[@]} || i < ${#B[@]} )); do
        x="${A[i]:-0}"; y="${B[i]:-0}"
        x="${x//[!0-9]/}"; y="${y//[!0-9]/}"
        x=$((10#${x:-0})); y=$((10#${y:-0}))
        if (( x < y )); then echo -1; return 0; fi
        if (( x > y )); then echo 1; return 0; fi
        i=$((i+1))
    done
    echo 0
}

# convert_path <convert-list> <path>  -  apply the first matching pair of a
# DB_FILE_NAME_CONVERT-style list (as V$PARAMETER prints it: 'a', 'b', 'c', 'd')
# to <path>. Prints the converted path; returns 1 when no pair matches.
convert_path() {
    local list="$1" path="$2" i=0 from to
    local -a P
    IFS=, read -r -a P <<< "$list"
    while (( i + 1 < ${#P[@]} )); do
        from="$(_unquote "${P[i]}")"; to="$(_unquote "${P[i+1]}")"
        if [[ -n "$from" && "$path" == *"$from"* ]]; then
            printf '%s' "${path%%"$from"*}${to}${path#*"$from"}"
            return 0
        fi
        i=$((i+2))
    done
    return 1
}
_unquote() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
    s="${s#\'}"; s="${s%\'}"
    printf '%s' "$s"
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

# Confirmation for the irreversible DROP DATABASE. Unlike confirm_or_abort,
# MIGRATE_NONINTERACTIVE=1 alone never answers this: an unattended run must
# also set MIGRATE_ALLOW_DROP=1, or it is refused.
confirm_drop_or_abort() {
    local prompt="$1"
    if [[ "${MIGRATE_NONINTERACTIVE:-0}" == "1" ]]; then
        if [[ "${MIGRATE_ALLOW_DROP:-0}" == "1" ]]; then
            log_warn "Non-interactive mode with MIGRATE_ALLOW_DROP=1: assuming YES for: ${prompt}"
            return 0
        fi
        log_error "Refusing to DROP DATABASE unattended: MIGRATE_NONINTERACTIVE=1 requires MIGRATE_ALLOW_DROP=1 as well."
        exit 1
    fi
    confirm_or_abort "$prompt"
}

# ------------------------------------------------------------
# Identity checks - prove the instance a destructive step is about to act
# on is the one the config names (SOURCE_ORACLE_SID is just an env var).
# ------------------------------------------------------------

# assert_source_identity <allowed OPEN_MODEs, '|'-separated, spaces removed>
# Logs the reason and returns 1 unless SOURCE_ORACLE_SID is the non-CDB
# SOURCE_DB_NAME (not a CDB, PRIMARY, an allowed open mode, DBID matching the
# one preflight recorded).
assert_source_identity() {
    local allowed="$1" out name cdb role mode dbid want
    if [[ "$SOURCE_ORACLE_SID" == "$TARGET_CDB_ORACLE_SID" ]]; then
        log_error "SOURCE_ORACLE_SID and TARGET_CDB_ORACLE_SID are both '${SOURCE_ORACLE_SID}'."
        return 1
    fi
    out="$(run_sql "$SOURCE_ORACLE_SID" "
SELECT 'NAME='      || name          FROM v\$database;
SELECT 'CDB='       || cdb           FROM v\$database;
SELECT 'ROLE='      || database_role FROM v\$database;
SELECT 'OPEN_MODE=' || open_mode     FROM v\$database;
SELECT 'DBID='      || dbid          FROM v\$database;
")" || { log_error "Cannot query v\$database on SOURCE_ORACLE_SID=${SOURCE_ORACLE_SID} (instance down?). Cannot prove it is ${SOURCE_DB_NAME}."; return 1; }
    name="$(kv_get NAME "$out")"; cdb="$(kv_get CDB "$out")"; role="$(kv_get ROLE "$out")"
    mode="$(kv_get OPEN_MODE "$out")"; dbid="$(kv_get DBID "$out")"
    if [[ "$(upper "$name")" != "$(upper "$SOURCE_DB_NAME")" ]]; then
        log_error "SOURCE_ORACLE_SID=${SOURCE_ORACLE_SID} is database '${name:-?}', not SOURCE_DB_NAME '${SOURCE_DB_NAME}'."
        return 1
    fi
    if [[ "$cdb" != "NO" ]]; then
        log_error "Source ${name} reports CDB='${cdb:-?}' - expected a non-CDB (NO)."
        return 1
    fi
    if [[ "$role" != "PRIMARY" ]]; then
        log_error "Source ${name} role is '${role:-?}', expected PRIMARY."
        return 1
    fi
    if [[ "|${allowed}|" != *"|${mode}|"* ]]; then
        log_error "Source ${name} open_mode is '${mode:-?}', expected one of: ${allowed}."
        return 1
    fi
    want="$(read_state src_dbid)"
    if [[ -n "$want" && "$want" != "$dbid" ]]; then
        log_error "Source DBID ${dbid:-?} differs from the DBID preflight recorded (${want}) - a different database."
        return 1
    fi
    [[ -n "$want" ]] || log_warn "No src_dbid in state (preflight not run on this state file) - DBID not cross-checked."
    log_success "Source identity OK: ${name}, non-CDB, ${role}, ${mode}, DBID ${dbid}"
    return 0
}

# assert_new_pdb_open  -  the new PDB must exist and be OPEN READ WRITE in the
# target CDB primary (the copy that makes dropping the source safe).
assert_new_pdb_open() {
    local out name cdb role mode
    out="$(run_sql "$TARGET_CDB_ORACLE_SID" "
SELECT 'NAME='     || name          FROM v\$database;
SELECT 'CDB='      || cdb           FROM v\$database;
SELECT 'ROLE='     || database_role FROM v\$database;
SELECT 'PDB_MODE=' || open_mode     FROM v\$pdbs WHERE name=UPPER('${NEW_PDB_NAME}');
")" || { log_error "Cannot query the target CDB (TARGET_CDB_ORACLE_SID=${TARGET_CDB_ORACLE_SID})."; return 1; }
    name="$(kv_get NAME "$out")"; cdb="$(kv_get CDB "$out")"; role="$(kv_get ROLE "$out")"
    mode="$(kv_get PDB_MODE "$out")"
    if [[ "$(upper "$name")" != "$(upper "$TARGET_CDB_NAME")" || "$cdb" != "YES" || "$role" != "PRIMARY" ]]; then
        log_error "TARGET_CDB_ORACLE_SID=${TARGET_CDB_ORACLE_SID} is '${name:-?}' (CDB=${cdb:-?}, ${role:-?}), expected PRIMARY CDB ${TARGET_CDB_NAME}."
        return 1
    fi
    if [[ "$mode" != "READWRITE" ]]; then
        log_error "PDB ${NEW_PDB_NAME} in ${name} is '${mode:-<missing>}', expected OPEN READ WRITE."
        return 1
    fi
    log_success "PDB ${NEW_PDB_NAME} is OPEN READ WRITE in ${name}"
    return 0
}

# ------------------------------------------------------------
# Direct access to the CDB STANDBY
# ------------------------------------------------------------
# ALTER SYSTEM and the broker's SQL command only act on the primary side and
# never travel in redo, so anything that must be true ON the standby (the
# STANDBY_PDB_SOURCE_FILE_DIRECTORY parameter, the PDB's recovery state, its
# datafile names) is set and read through a direct connection to it.
# Wallet first (/@alias; project convention alias == DB_UNIQUE_NAME, see
# common/setup_dg_wallet.sh); on failure with a TTY, the standby SYS password
# is prompted once and handed to sqlplus on stdin (never argv).
STANDBY_SYS_PW=""

_standby_sqlplus() {
    local sql="$1"
    if [[ -n "$STANDBY_SYS_PW" ]]; then
        sqlplus -s /nolog <<EOF 2>&1
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON VERIFY OFF
CONNECT sys/"${STANDBY_SYS_PW}"@${STANDBY_TNS_ALIAS} AS SYSDBA
WHENEVER SQLERROR EXIT SQL.SQLCODE
SELECT 'STBY_CONNECTED' FROM dual;
${sql}
EXIT;
EOF
    else
        sqlplus -s -L "/@${STANDBY_TNS_ALIAS}" as sysdba <<EOF 2>&1
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON VERIFY OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE
SELECT 'STBY_CONNECTED' FROM dual;
${sql}
EXIT;
EOF
    fi
}

# run_sql_standby <sql>  -  returns 0 only when the connection succeeded AND the
# statements ran without a SQL error. A failed connect returns 1, so callers
# must treat it as "unverified", never "not found".
run_sql_standby() {
    local out rc=0
    out="$(_standby_sqlplus "$1")" || rc=$?
    if ! printf '%s\n' "$out" | grep -q '^STBY_CONNECTED$'; then
        printf '%s\n' "$out"
        return 1
    fi
    { printf '%s\n' "$out" | grep -v '^STBY_CONNECTED$'; } || true
    return "$rc"
}

# standby_connect_init  -  establish (once) a working standby connection.
STANDBY_CONNECTED=0
standby_connect_init() {
    [[ "$STANDBY_CONNECTED" == "1" ]] && return 0
    if run_sql_standby "SELECT 1 FROM dual;" >/dev/null 2>&1; then
        STANDBY_CONNECTED=1; return 0
    fi
    if [[ -t 0 && "${MIGRATE_NONINTERACTIVE:-0}" != "1" ]]; then
        log_warn "Wallet connect to the standby (/@${STANDBY_TNS_ALIAS}) failed."
        printf "SYS password for %s (not echoed, not stored): " "$STANDBY_TNS_ALIAS"
        stty -echo 2>/dev/null || true
        read -r STANDBY_SYS_PW || STANDBY_SYS_PW=""
        stty echo 2>/dev/null || true
        printf '\n'
        if [[ -n "$STANDBY_SYS_PW" && "$STANDBY_SYS_PW" != *'"'* ]] && \
           run_sql_standby "SELECT 1 FROM dual;" >/dev/null 2>&1; then
            STANDBY_CONNECTED=1; return 0
        fi
        STANDBY_SYS_PW=""
    fi
    return 1
}

# standby_param_prereqs  -  parameters on the CDB standby the plug-in depends
# on. Needs a fail() from the caller. Sets STBY_PDB_DIR to the directory the
# standby will create the new PDB's datafiles in ('' under OMF). Returns 1 when
# the standby cannot be queried at all.
STBY_PDB_DIR=""
standby_param_prereqs() {
    local out role dbn cdb sfm dbfnc dest sample conv
    if ! standby_connect_init; then
        fail "Cannot connect to the CDB standby '${STANDBY_TNS_ALIAS}' (wallet /@${STANDBY_TNS_ALIAS} or SYS password). Its parameters and the PDB's replication cannot be verified, so the migration is refused."
        return 1
    fi
    out="$(run_sql_standby "
SELECT 'ROLE='   || database_role FROM v\$database;
SELECT 'DBNAME=' || name          FROM v\$database;
SELECT 'CDB='    || cdb           FROM v\$database;
SELECT 'SFM='    || value FROM v\$parameter WHERE name='standby_file_management';
SELECT 'DBFNC='  || value FROM v\$parameter WHERE name='db_file_name_convert';
SELECT 'DEST='   || value FROM v\$parameter WHERE name='db_create_file_dest';
")" || { fail "Querying the CDB standby failed: ${out}"; return 1; }
    role="$(kv_get ROLE "$out")"; dbn="$(kv_get DBNAME "$out")"; cdb="$(kv_get CDB "$out")"
    sfm="$(kv_get SFM "$out")"
    dbfnc="$(printf '%s\n' "$out" | sed -n 's/^DBFNC=//p' | head -1)"
    dest="$(kv_get DEST "$out")"
    if [[ "$role" != "PHYSICALSTANDBY" ]]; then
        fail "'${STANDBY_TNS_ALIAS}' is role '${role:-?}', expected PHYSICAL STANDBY."
    fi
    if [[ "$(upper "$dbn")" != "$(upper "$TARGET_CDB_NAME")" || "$cdb" != "YES" ]]; then
        fail "'${STANDBY_TNS_ALIAS}' is database '${dbn:-?}' (CDB=${cdb:-?}), expected the standby of CDB ${TARGET_CDB_NAME}."
    fi
    if [[ "$(upper "$sfm")" != "AUTO" ]]; then
        fail "CDB standby standby_file_management='${sfm:-?}', must be AUTO (else the new PDB's datafiles are not created on the standby)."
    else
        log_success "CDB standby: standby_file_management=AUTO"
    fi
    STBY_PDB_DIR=""
    sample="${TARGET_PDB_DATAFILE_DIR}/${NEW_PDB_NAME}/probe.dbf"
    if conv="$(convert_path "$dbfnc" "$sample")"; then
        STBY_PDB_DIR="$(dirname "$conv")"
        log_success "CDB standby db_file_name_convert maps ${TARGET_PDB_DATAFILE_DIR}/${NEW_PDB_NAME}/ -> ${STBY_PDB_DIR}/"
    elif [[ -n "$dest" ]]; then
        log_success "CDB standby uses OMF (db_create_file_dest=${dest}); db_file_name_convert does not cover the PDB directory, Oracle names and creates the files itself"
    else
        fail "CDB standby db_file_name_convert ('${dbfnc}') does not cover ${TARGET_PDB_DATAFILE_DIR} and db_create_file_dest is unset: the new PDB's datafiles cannot be named on the standby (ORA-01274/ORA-01119)."
    fi
    return 0
}

# _standby_ssh <remote command>  (only used when STANDBY_SSH_TARGET is set)
_standby_ssh() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$STANDBY_SSH_TARGET" "$1" </dev/null 2>&1
}

# standby_dir_prereqs <bytes needed>  -  host-level prerequisites on the
# STANDBY HOST: the datafile directory STBY_PDB_DIR exists/is writable/has room,
# and STANDBY_STAGE_DIR (the staged files) is visible there. With
# STANDBY_SSH_TARGET it checks (and creates the directory) over ssh; without it
# the exact commands are printed and the operator must confirm them (TTY
# prompt, or STANDBY_DIRS_CONFIRMED=yes for unattended runs) - never assumed.
# Needs fail() from the caller.
standby_dir_prereqs() {
    local need_bytes="${1:-0}" out avail ans
    if [[ -n "${STANDBY_SSH_TARGET:-}" ]] && command -v ssh >/dev/null 2>&1; then
        log_info "Checking the standby host over ssh (${STANDBY_SSH_TARGET}) ..."
        if [[ -n "$STBY_PDB_DIR" ]]; then
            if out="$(_standby_ssh "mkdir -p '${STBY_PDB_DIR}' && test -d '${STBY_PDB_DIR}' && test -w '${STBY_PDB_DIR}'")"; then
                log_success "Standby datafile directory ready: ${STBY_PDB_DIR}"
                avail="$(_standby_ssh "df -Pk '${STBY_PDB_DIR}' | tail -1 | awk '{print \$4}'")" || avail=""
                if [[ "$avail" =~ ^[0-9]+$ ]]; then
                    if (( avail < (need_bytes + 1023) / 1024 )); then
                        fail "Standby ${STBY_PDB_DIR} has ${avail} KB free, need about $(( (need_bytes + 1023) / 1024 )) KB."
                    fi
                else
                    fail "Could not determine free space of ${STBY_PDB_DIR} on the standby host."
                fi
            else
                fail "Standby datafile directory ${STBY_PDB_DIR} cannot be created/written over ssh: ${out}"
            fi
        fi
        if out="$(_standby_ssh "test -d '${STANDBY_STAGE_DIR}' && test -r '${STANDBY_STAGE_DIR}'")"; then
            log_success "Staging directory visible on the standby host: ${STANDBY_STAGE_DIR}"
        else
            fail "Staging directory ${STANDBY_STAGE_DIR} is not visible/readable on the standby host (NFS share not mounted there, or set STANDBY_STAGE_DIR to its path on that host): ${out}"
        fi
        return 0
    fi

    log_warn "No STANDBY_SSH_TARGET configured - the standby HOST cannot be checked from here."
    log_warn "On the standby host, as the Oracle owner, make sure that:"
    [[ -z "$STBY_PDB_DIR" ]] || log_warn "  mkdir -p '${STBY_PDB_DIR}'      # exists, writable, ~$(( (need_bytes + 1048575) / 1048576 )) MB free"
    log_warn "  ls -ld '${STANDBY_STAGE_DIR}'      # the staging dir is visible and readable there"
    if [[ "${STANDBY_DIRS_CONFIRMED:-}" == "yes" ]]; then
        log_warn "STANDBY_DIRS_CONFIRMED=yes - taking the operator's word for the standby directories."
    elif [[ -t 0 && "${MIGRATE_NONINTERACTIVE:-0}" != "1" ]]; then
        printf "%bType YES once both are in place on the standby host:%b " "$YELLOW" "$NC"
        read -r ans || ans=""
        if [[ "$ans" != "YES" ]]; then
            fail "Standby host directories not confirmed."
        fi
    else
        fail "Standby host directories unverified: set STANDBY_SSH_TARGET (ssh check) or STANDBY_DIRS_CONFIRMED=yes after creating them."
    fi
    return 0
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
