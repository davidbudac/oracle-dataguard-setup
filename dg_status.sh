#!/usr/bin/env bash
# =============================================================================
# Oracle Data Guard - Quick Status Dashboard
# =============================================================================
#
# Single-command health check for an Oracle 19c Data Guard configuration.
# Connects to primary and standby over SSH, queries V$ views and DGMGRL,
# and prints a colour-coded dashboard with OK / !! / XX indicators.
#
# Prerequisites:
#   - SSH access to both primary and standby DB hosts (directly or via jump)
#   - Oracle OS authentication (sqlplus / as sysdba) on both hosts
#   - DG Broker running (dg_broker_start = TRUE)
#   - A config file providing SSH connection details (see tests/e2e/config.env)
#
# SID resolution order:
#   1. -s / --sid flag
#   2. $ORACLE_SID environment variable
#   3. Auto-detect from running ora_pmon_ process on primary host
#   The standby SID is always auto-detected from its pmon process.
#
# Usage:
#   bash dg_status.sh                           # Use $ORACLE_SID or auto-detect
#   bash dg_status.sh -s cdb1                   # Specify Oracle SID explicitly
#   bash dg_status.sh -c /path/to/config.env    # Use custom SSH config file
#
#
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Colors & symbols --------------------------------------------------------
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';   BOLD='\033[1m'
DIM='\033[2m';       NC='\033[0m'
CHK="${GREEN}OK${NC}"; WARN="${YELLOW}!!${NC}"; FAIL="${RED}XX${NC}"

if command -v tput >/dev/null 2>&1; then
    TERM_WIDTH=$(tput cols 2>/dev/null || printf '100')
else
    TERM_WIDTH=100
fi
[[ "$TERM_WIDTH" =~ ^[0-9]+$ ]] || TERM_WIDTH=100
(( TERM_WIDTH < 80 )) && TERM_WIDTH=80

LABEL_W=24
STATUS_W=4
ROW_VALUE_W=$((TERM_WIDTH - LABEL_W - STATUS_W - 6))
(( ROW_VALUE_W < 28 )) && ROW_VALUE_W=28

HLINE=$(printf '%*s' $((TERM_WIDTH - 2)) '')
HLINE=${HLINE// /─}

# -- Parse args ---------------------------------------------------------------
CONFIG_FILE="${SCRIPT_DIR}/tests/e2e/config.env"
ORACLE_SID_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        -s|--sid)    ORACLE_SID_OVERRIDE="$2"; shift 2 ;;
        -h|--help)
            printf "Usage: bash dg_status.sh [-c config.env] [-s SID]\n"
            printf "  -c, --config FILE   SSH connection config (default: tests/e2e/config.env)\n"
            printf "  -s, --sid SID       Oracle SID (default: \$ORACLE_SID, then auto-detect)\n"
            exit 0 ;;
        *) printf "Unknown option: %s\n" "$1"; exit 1 ;;
    esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
    printf "ERROR: Config file not found: %s\n" "$CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

# -- SSH setup ----------------------------------------------------------------
JUMP_SSH_PORT="${JUMP_SSH_PORT:-22}"
PRIMARY_SSH_PORT="${PRIMARY_SSH_PORT:-22}"
STANDBY_SSH_PORT="${STANDBY_SSH_PORT:-22}"
DB_SSH_KEY_OPT=""
[[ -n "${SSH_KEY:-}" ]] && DB_SSH_KEY_OPT="-i ${SSH_KEY}"

# Skip ProxyJump if we're already on the jump host
_CURRENT_HOST=$(hostname 2>/dev/null || uname -n 2>/dev/null || printf 'unknown')
_CURRENT_HOST=${_CURRENT_HOST%%.*}
if [[ "$_CURRENT_HOST" == "${JUMP_HOST}"* ]]; then
    _JUMP_OPT=""
else
    _JUMP_OPT="-J ${JUMP_USER}@${JUMP_HOST}:${JUMP_SSH_PORT}"
fi

_ssh_raw() {
    local host="$1" port="$2" cmd="$3"
    ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} ${_JUMP_OPT} \
        -p "${port}" "${SSH_USER}@${host}" "${cmd}" 2>&1
}

_ssh_ora() {
    local host="$1" port="$2" sid="$3" cmd="$4"
    ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} ${_JUMP_OPT} \
        -p "${port}" "${SSH_USER}@${host}" \
        "export ORACLE_HOME='${ORACLE_HOME}'; \
         export ORACLE_BASE='${ORACLE_BASE}'; \
         export ORACLE_SID='${sid}'; \
         export PATH=\"\${ORACLE_HOME}/bin:\${PATH}\"; \
         ${cmd}" 2>&1
}

# -- Helpers ------------------------------------------------------------------
repeat_char() {
    local char="$1" count="$2" out=""
    while (( count > 0 )); do
        out="${out}${char}"
        count=$((count - 1))
    done
    printf '%s' "$out"
}

short_hostname() {
    local host
    host=$(hostname 2>/dev/null || uname -n 2>/dev/null || printf 'unknown')
    printf '%s' "${host%%.*}"
}

extract_first_status() {
    awk '
        match($0, /(SUCCESS|WARNING|ERROR)/) {
            print substr($0, RSTART, RLENGTH)
            exit
        }
    '
}

make_temp_dir() {
    if command -v mktemp >/dev/null 2>&1; then
        mktemp -d 2>/dev/null && return
    fi
    local dir="${TMPDIR:-/tmp}/dg_status.$$"
    mkdir -p "$dir" && printf '%s\n' "$dir"
}

fit_text() {
    local text="$1" width="$2" plain
    plain=$(printf '%b' "$text" | sed $'s/\033\\[[0-9;]*m//g')
    if [[ ${#plain} -le $width ]]; then
        printf '%s' "$text"
    elif (( width > 3 )); then
        printf '%s...' "${plain:0:$((width - 3))}"
    else
        printf '%s' "${plain:0:$width}"
    fi
}

wrap_text() {
    local text="$1" width="$2"
    text=$(printf '%s' "$text" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
    [[ -z "$text" ]] && text="-"
    printf '%s\n' "$text" | fold -s -w "$width"
}

format_services() {
    local input="$1" formatted
    formatted=$(printf '%s\n' "$input" | sed '/^$/d' | awk 'BEGIN{ORS=""} {if (NR>1) printf ", "; printf "%s", $0}')
    if [[ -n "$formatted" ]]; then
        printf '%s' "$formatted"
    else
        printf 'NONE'
    fi
}

row() {
    local label="$1" value="$2" status="${3:-}"
    local first=true line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if $first; then
            printf "  ${DIM}%-*s${NC} %-*s %b\n" "$LABEL_W" "$label" "$ROW_VALUE_W" "$line" "$status"
            first=false
        else
            printf "  ${DIM}%-*s${NC} %-*s\n" "$LABEL_W" "" "$ROW_VALUE_W" "$line"
        fi
    done < <(wrap_text "$value" "$ROW_VALUE_W")
}

header() {
    printf "\n ${BOLD}${BLUE}%s${NC}\n" "$1"
    printf " ${DIM}%s${NC}\n" "$HLINE"
}

subheader() {
    printf " ${BOLD}${CYAN}%s${NC}\n" "$1"
}

status_icon() {
    local value="$1"; shift
    for p in "$@"; do
        if printf '%s' "$value" | grep -qi "$p"; then
            printf '%b' "$CHK"; return
        fi
    done
    printf '%b' "$FAIL"
}

warn_icon() {
    local value="$1"; shift
    for p in "$@"; do
        if printf '%s' "$value" | grep -qi "$p"; then
            printf '%b' "$CHK"; return
        fi
    done
    printf '%b' "$WARN"
}

ERRORS=0; WARNINGS=0

err()  { ERRORS=$((ERRORS+1)); }
warn() { WARNINGS=$((WARNINGS+1)); }

declare -a SUMMARY_ERRORS=()
declare -a SUMMARY_WARNINGS=()

add_summary_error() {
    local message="$1"
    SUMMARY_ERRORS+=("$message")
    err
}

add_summary_warning() {
    local message="$1"
    SUMMARY_WARNINGS+=("$message")
    warn
}

# -- Resolve SID --------------------------------------------------------------
# Priority: -s flag > $ORACLE_SID > auto-detect from pmon
if [[ -n "$ORACLE_SID_OVERRIDE" ]]; then
    DETECTED_SID="$ORACLE_SID_OVERRIDE"
elif [[ -n "${ORACLE_SID:-}" ]]; then
    DETECTED_SID="$ORACLE_SID"
else
    PMON=$(_ssh_raw "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}" "ps -ef | grep ora_pmon_ | grep -v grep | head -1")
    DETECTED_SID=$(printf '%s' "$PMON" | sed 's/.*ora_pmon_//')
    if [[ -z "$DETECTED_SID" ]]; then
        printf "ERROR: No Oracle instance detected on primary (%s:%s)\n" "$PRIMARY_HOST" "$PRIMARY_SSH_PORT"
        exit 1
    fi
fi

# Detect standby SID (may differ)
PMON_STB=$(_ssh_raw "${STANDBY_HOST}" "${STANDBY_SSH_PORT}" "ps -ef | grep ora_pmon_ | grep -v grep | head -1")
DETECTED_SID_STB=$(printf '%s' "$PMON_STB" | sed 's/.*ora_pmon_//')
if [[ -z "$DETECTED_SID_STB" ]]; then
    DETECTED_SID_STB="$DETECTED_SID"
fi

# -- Title --------------------------------------------------------------------
printf "\n ${BOLD}${CYAN}Data Guard Status Dashboard${NC}  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')${NC}\n"
printf " ${DIM}Primary: ${PRIMARY_ORACLE_HOSTNAME} (SID: ${DETECTED_SID})  |  Standby: ${STANDBY_ORACLE_HOSTNAME} (SID: ${DETECTED_SID_STB})${NC}\n"

# -- Collect data in parallel -------------------------------------------------
TMP=$(make_temp_dir)
trap 'rm -rf "$TMP"' EXIT

# Primary: SQL data + DGMGRL
_ssh_ora "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}" "${DETECTED_SID}" "sqlplus -s / as sysdba <<'SQL'
SET HEADING OFF FEEDBACK OFF LINESIZE 300 PAGESIZE 0 TRIMSPOOL ON
SELECT 'DBSTATUS|' || DATABASE_ROLE || '|' || OPEN_MODE || '|' || PROTECTION_MODE || '|' || SWITCHOVER_STATUS || '|' || FORCE_LOGGING || '|' || FLASHBACK_ON || '|' || DB_UNIQUE_NAME FROM V\$DATABASE;
SELECT 'DGPARAMS|' || NAME || '|' || VALUE FROM V\$PARAMETER WHERE NAME IN ('dg_broker_start') ORDER BY NAME;
SELECT 'REDOLOG|' || COUNT(*) || '|' || ROUND(SUM(BYTES)/1024/1024) FROM V\$LOG;
SELECT 'SRLCOUNT|' || COUNT(*) FROM V\$STANDBY_LOG;
SELECT 'ARCHGAP|' || COUNT(*) FROM V\$ARCHIVE_GAP;
SELECT 'ARCHDEST|' || DEST_ID || '|' || STATUS || '|' || ERROR FROM V\$ARCHIVE_DEST WHERE DEST_ID IN (1,2);
SELECT 'FSFODB|' || FS_FAILOVER_STATUS || '|' || FS_FAILOVER_OBSERVER_PRESENT || '|' || FS_FAILOVER_OBSERVER_HOST FROM V\$DATABASE;
SELECT 'FRA|' || NAME || '|' || ROUND(SPACE_LIMIT/1024/1024/1024,1) || '|' || ROUND(SPACE_USED/1024/1024/1024,1) || '|' || ROUND(SPACE_RECLAIMABLE/1024/1024/1024,1) || '|' || NUMBER_OF_FILES FROM V\$RECOVERY_FILE_DEST;
SELECT 'SERVICE|' || NAME
  FROM (
    SELECT NAME
      FROM V\$ACTIVE_SERVICES
     WHERE NAME NOT LIKE 'SYS$%'
       AND UPPER(NAME) NOT LIKE '%XDB%'
     ORDER BY NAME
  );
EXIT;
SQL" > "$TMP/primary_sql" &

_ssh_ora "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}" "${DETECTED_SID}" \
    "dgmgrl -silent / 'SHOW CONFIGURATION'" > "$TMP/dgmgrl_config" &

_ssh_ora "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}" "${DETECTED_SID}" \
    "dgmgrl -silent / 'SHOW FAST_START FAILOVER'" > "$TMP/dgmgrl_fsfo" 2>/dev/null &

# Standby: SQL data
_ssh_ora "${STANDBY_HOST}" "${STANDBY_SSH_PORT}" "${DETECTED_SID_STB}" "sqlplus -s / as sysdba <<'SQL'
SET HEADING OFF FEEDBACK OFF LINESIZE 300 PAGESIZE 0 TRIMSPOOL ON
SELECT 'DBSTATUS|' || DATABASE_ROLE || '|' || OPEN_MODE || '|' || PROTECTION_MODE || '|' || SWITCHOVER_STATUS || '|' || DB_UNIQUE_NAME FROM V\$DATABASE;
SELECT 'MRP|' || PROCESS || '|' || STATUS || '|' || SEQUENCE# FROM V\$MANAGED_STANDBY WHERE PROCESS = 'MRP0';
SELECT 'DGSTATS|' || NAME || '|' || VALUE FROM V\$DATAGUARD_STATS WHERE NAME IN ('transport lag','apply lag','apply finish time');
SELECT 'ARCHGAP|' || COUNT(*) FROM V\$ARCHIVE_GAP;
SELECT 'APPLYINFO|' || NVL(MAX(CASE WHEN APPLIED='YES' THEN SEQUENCE# END),0) || '|' || NVL(MAX(SEQUENCE#),0) FROM V\$ARCHIVED_LOG WHERE THREAD#=1;
SELECT 'SRLCOUNT|' || COUNT(*) FROM V\$STANDBY_LOG;
SELECT 'FRA|' || NAME || '|' || ROUND(SPACE_LIMIT/1024/1024/1024,1) || '|' || ROUND(SPACE_USED/1024/1024/1024,1) || '|' || ROUND(SPACE_RECLAIMABLE/1024/1024/1024,1) || '|' || NUMBER_OF_FILES FROM V\$RECOVERY_FILE_DEST;
SELECT 'SERVICE|' || NAME
  FROM (
    SELECT NAME
      FROM V\$ACTIVE_SERVICES
     WHERE NAME NOT LIKE 'SYS$%'
       AND UPPER(NAME) NOT LIKE '%XDB%'
     ORDER BY NAME
  );
EXIT;
SQL" > "$TMP/standby_sql" &

# Alert log: primary (get diag trace path, then extract DG-related entries with timestamps)
# Oracle 19c alert log has ISO timestamps on their own line (e.g. 2024-01-15T10:30:45.123+00:00)
# awk tracks the last timestamp and prepends it to matching DG lines
_ssh_ora "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}" "${DETECTED_SID}" "
TRACE_DIR=\$(sqlplus -s / as sysdba <<'SQLT'
SET HEADING OFF FEEDBACK OFF LINESIZE 500 PAGESIZE 0 TRIMSPOOL ON
SELECT VALUE FROM V\$DIAG_INFO WHERE NAME = 'Diag Trace';
EXIT;
SQLT
)
TRACE_DIR=\$(printf '%s' \"\$TRACE_DIR\" | xargs)
ALERT_FILE=\"\${TRACE_DIR}/alert_${DETECTED_SID}.log\"
if [ -f \"\$ALERT_FILE\" ]; then
    tail -2000 \"\$ALERT_FILE\" | awk '
/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ { ts = substr(\$0, 1, 19); gsub(/T/, \" \", ts); next }
{ low = tolower(\$0) }
low ~ /ora-16[0-9][0-9][0-9]|ora-01034|ora-03113|ora-12541|switchover|failover|data guard|mrp0|fal\[|rfs\[|lns[0-9]|broker|dgmgrl|role.change|arch.*gap|apply_lag|transport_lag/ {
    if (ts != \"\") printf \"%s  %s\n\", ts, \$0; else print \$0
}' | tail -15
fi
" > "$TMP/primary_alert" 2>/dev/null &

# Alert log: standby
_ssh_ora "${STANDBY_HOST}" "${STANDBY_SSH_PORT}" "${DETECTED_SID_STB}" "
TRACE_DIR=\$(sqlplus -s / as sysdba <<'SQLT'
SET HEADING OFF FEEDBACK OFF LINESIZE 500 PAGESIZE 0 TRIMSPOOL ON
SELECT VALUE FROM V\$DIAG_INFO WHERE NAME = 'Diag Trace';
EXIT;
SQLT
)
TRACE_DIR=\$(printf '%s' \"\$TRACE_DIR\" | xargs)
ALERT_FILE=\"\${TRACE_DIR}/alert_${DETECTED_SID_STB}.log\"
if [ -f \"\$ALERT_FILE\" ]; then
    tail -2000 \"\$ALERT_FILE\" | awk '
/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ { ts = substr(\$0, 1, 19); gsub(/T/, \" \", ts); next }
{ low = tolower(\$0) }
low ~ /ora-16[0-9][0-9][0-9]|ora-01034|ora-03113|ora-12541|switchover|failover|data guard|mrp0|fal\[|rfs\[|lns[0-9]|broker|dgmgrl|role.change|arch.*gap|apply_lag|transport_lag/ {
    if (ts != \"\") printf \"%s  %s\n\", ts, \$0; else print \$0
}' | tail -15
fi
" > "$TMP/standby_alert" 2>/dev/null &

# Broker log (drc<SID>.log): primary
_ssh_ora "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}" "${DETECTED_SID}" "
TRACE_DIR=\$(sqlplus -s / as sysdba <<'SQLT'
SET HEADING OFF FEEDBACK OFF LINESIZE 500 PAGESIZE 0 TRIMSPOOL ON
SELECT VALUE FROM V\$DIAG_INFO WHERE NAME = 'Diag Trace';
EXIT;
SQLT
)
TRACE_DIR=\$(printf '%s' \"\$TRACE_DIR\" | xargs)
DRC_FILE=\"\${TRACE_DIR}/drc${DETECTED_SID}.log\"
if [ -f \"\$DRC_FILE\" ]; then
    tail -500 \"\$DRC_FILE\" | awk '
/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ { ts = substr(\$0, 1, 19); gsub(/T/, \" \", ts); next }
{ low = tolower(\$0) }
low ~ /ora-|error|warning|fail|switchover|failover|role change|fsfo|reinstate|disable|enable|nsv|broker/ {
    if (ts != \"\") printf \"%s  %s\n\", ts, \$0; else print \$0
}' | tail -10
fi
" > "$TMP/primary_drc" 2>/dev/null &

# Broker log (drc<SID>.log): standby
_ssh_ora "${STANDBY_HOST}" "${STANDBY_SSH_PORT}" "${DETECTED_SID_STB}" "
TRACE_DIR=\$(sqlplus -s / as sysdba <<'SQLT'
SET HEADING OFF FEEDBACK OFF LINESIZE 500 PAGESIZE 0 TRIMSPOOL ON
SELECT VALUE FROM V\$DIAG_INFO WHERE NAME = 'Diag Trace';
EXIT;
SQLT
)
TRACE_DIR=\$(printf '%s' \"\$TRACE_DIR\" | xargs)
DRC_FILE=\"\${TRACE_DIR}/drc${DETECTED_SID_STB}.log\"
if [ -f \"\$DRC_FILE\" ]; then
    tail -500 \"\$DRC_FILE\" | awk '
/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ { ts = substr(\$0, 1, 19); gsub(/T/, \" \", ts); next }
{ low = tolower(\$0) }
low ~ /ora-|error|warning|fail|switchover|failover|role change|fsfo|reinstate|disable|enable|nsv|broker/ {
    if (ts != \"\") printf \"%s  %s\n\", ts, \$0; else print \$0
}' | tail -10
fi
" > "$TMP/standby_drc" 2>/dev/null &

wait

# -- Parse primary SQL --------------------------------------------------------
PRI_SQL=$(cat "$TMP/primary_sql")

PRI_DBSTATUS=$(printf '%s\n' "$PRI_SQL" | grep '^DBSTATUS|' | head -1 | sed 's/^DBSTATUS|//')
PRI_ROLE=$(printf '%s' "$PRI_DBSTATUS" | awk -F'|' '{print $1}' | xargs)
PRI_OPEN=$(printf '%s' "$PRI_DBSTATUS" | awk -F'|' '{print $2}' | xargs)
PRI_PROTECT=$(printf '%s' "$PRI_DBSTATUS" | awk -F'|' '{print $3}' | xargs)
PRI_SWITCH=$(printf '%s' "$PRI_DBSTATUS" | awk -F'|' '{print $4}' | xargs)
PRI_FORCE=$(printf '%s' "$PRI_DBSTATUS" | awk -F'|' '{print $5}' | xargs)
PRI_FLASH=$(printf '%s' "$PRI_DBSTATUS" | awk -F'|' '{print $6}' | xargs)
PRI_DBUNIQ=$(printf '%s' "$PRI_DBSTATUS" | awk -F'|' '{print $7}' | xargs)

PRI_BROKER=$(printf '%s\n' "$PRI_SQL" | grep 'dg_broker_start' | awk -F'|' '{print $3}' | xargs)
PRI_ARCHGAP=$(printf '%s\n' "$PRI_SQL" | grep '^ARCHGAP|' | awk -F'|' '{print $2}' | xargs)
PRI_REDO=$(printf '%s\n' "$PRI_SQL" | grep '^REDOLOG|' | sed 's/^REDOLOG|//')
PRI_REDO_CNT=$(printf '%s' "$PRI_REDO" | awk -F'|' '{print $1}' | xargs)
PRI_REDO_MB=$(printf '%s' "$PRI_REDO" | awk -F'|' '{print $2}' | xargs)
PRI_SRL=$(printf '%s\n' "$PRI_SQL" | grep '^SRLCOUNT|' | awk -F'|' '{print $2}' | xargs)
PRI_DEST2_STATUS=$(printf '%s\n' "$PRI_SQL" | grep '^ARCHDEST|2|' | awk -F'|' '{print $3}' | xargs)
PRI_DEST2_ERROR=$(printf '%s\n' "$PRI_SQL" | grep '^ARCHDEST|2|' | awk -F'|' '{print $4}' | xargs)

# FRA
PRI_FRA=$(printf '%s\n' "$PRI_SQL" | grep '^FRA|' | head -1 | sed 's/^FRA|//')
PRI_FRA_PATH=$(printf '%s' "$PRI_FRA" | awk -F'|' '{print $1}' | xargs)
PRI_FRA_SIZE=$(printf '%s' "$PRI_FRA" | awk -F'|' '{print $2}' | xargs)
PRI_FRA_USED=$(printf '%s' "$PRI_FRA" | awk -F'|' '{print $3}' | xargs)
PRI_FRA_RECLAIM=$(printf '%s' "$PRI_FRA" | awk -F'|' '{print $4}' | xargs)
PRI_FRA_FILES=$(printf '%s' "$PRI_FRA" | awk -F'|' '{print $5}' | xargs)
PRI_SERVICES=$(format_services "$(printf '%s\n' "$PRI_SQL" | grep '^SERVICE|' | sed 's/^SERVICE|//')")

# -- Parse standby SQL --------------------------------------------------------
STB_SQL=$(cat "$TMP/standby_sql")

STB_DBSTATUS=$(printf '%s\n' "$STB_SQL" | grep '^DBSTATUS|' | head -1 | sed 's/^DBSTATUS|//')
STB_ROLE=$(printf '%s' "$STB_DBSTATUS" | awk -F'|' '{print $1}' | xargs)
STB_OPEN=$(printf '%s' "$STB_DBSTATUS" | awk -F'|' '{print $2}' | xargs)
STB_PROTECT=$(printf '%s' "$STB_DBSTATUS" | awk -F'|' '{print $3}' | xargs)
STB_SWITCH=$(printf '%s' "$STB_DBSTATUS" | awk -F'|' '{print $4}' | xargs)
STB_DBUNIQ=$(printf '%s' "$STB_DBSTATUS" | awk -F'|' '{print $5}' | xargs)

STB_MRP=$(printf '%s\n' "$STB_SQL" | grep '^MRP|' | head -1 | sed 's/^MRP|//')
STB_MRP_STATUS=$(printf '%s' "$STB_MRP" | awk -F'|' '{print $2}' | xargs)
STB_MRP_SEQ=$(printf '%s' "$STB_MRP" | awk -F'|' '{print $3}' | xargs)

STB_TRANSPORT_LAG=$(printf '%s\n' "$STB_SQL" | grep 'transport lag' | awk -F'|' '{print $3}' | xargs)
STB_APPLY_LAG=$(printf '%s\n' "$STB_SQL" | grep 'apply lag' | awk -F'|' '{print $3}' | xargs)

STB_ARCHGAP=$(printf '%s\n' "$STB_SQL" | grep '^ARCHGAP|' | awk -F'|' '{print $2}' | xargs)
STB_APPLYINFO=$(printf '%s\n' "$STB_SQL" | grep '^APPLYINFO|' | sed 's/^APPLYINFO|//')
STB_LAST_APPLIED=$(printf '%s' "$STB_APPLYINFO" | awk -F'|' '{print $1}' | xargs)
STB_LAST_RECEIVED=$(printf '%s' "$STB_APPLYINFO" | awk -F'|' '{print $2}' | xargs)
STB_SRL=$(printf '%s\n' "$STB_SQL" | grep '^SRLCOUNT|' | awk -F'|' '{print $2}' | xargs)

# FRA
STB_FRA=$(printf '%s\n' "$STB_SQL" | grep '^FRA|' | head -1 | sed 's/^FRA|//')
STB_FRA_PATH=$(printf '%s' "$STB_FRA" | awk -F'|' '{print $1}' | xargs)
STB_FRA_SIZE=$(printf '%s' "$STB_FRA" | awk -F'|' '{print $2}' | xargs)
STB_FRA_USED=$(printf '%s' "$STB_FRA" | awk -F'|' '{print $3}' | xargs)
STB_FRA_RECLAIM=$(printf '%s' "$STB_FRA" | awk -F'|' '{print $4}' | xargs)
STB_FRA_FILES=$(printf '%s' "$STB_FRA" | awk -F'|' '{print $5}' | xargs)
STB_SERVICES=$(format_services "$(printf '%s\n' "$STB_SQL" | grep '^SERVICE|' | sed 's/^SERVICE|//')")

# -- Parse DGMGRL output -----------------------------------------------------
DGMGRL_CONFIG=$(cat "$TMP/dgmgrl_config")
DGMGRL_FSFO=$(cat "$TMP/dgmgrl_fsfo" 2>/dev/null)

BROKER_CFG_NAME=$(printf '%s\n' "$DGMGRL_CONFIG" | grep 'Configuration -' | sed 's/.*Configuration - //' | xargs)
BROKER_OVERALL=$(printf '%s\n' "$DGMGRL_CONFIG" | tail -5 | extract_first_status)

# =============================================================================
# Display
# =============================================================================

# -- Summary box --------------------------------------------------------------
_W=29
_BAR=$(repeat_char '─' "$_W")

box_row() {
    local left="$1" right="$2"
    local lp rp
    left=$(fit_text "$left" "$_W")
    right=$(fit_text "$right" "$_W")
    lp=$(printf '%b' "$left" | sed $'s/\033\\[[0-9;]*m//g')
    rp=$(printf '%b' "$right" | sed $'s/\033\\[[0-9;]*m//g')
    local lpad=$((_W - ${#lp})); [[ $lpad -lt 0 ]] && lpad=0
    local rpad=$((_W - ${#rp})); [[ $rpad -lt 0 ]] && rpad=0
    printf ' │ %b%*s│ %b%*s│\n' "$left" "$lpad" "" "$right" "$rpad" ""
}

# Quick health check for summary dots
PRI_OK=true; STB_OK=true
printf '%s' "${PRI_ROLE:-}" | grep -qi "PRIMARY" || PRI_OK=false
printf '%s' "${PRI_OPEN:-}" | grep -qi "READ WRITE" || PRI_OK=false
printf '%s' "${STB_ROLE:-}" | grep -qi "PHYSICAL STANDBY" || STB_OK=false
if [[ -z "${STB_MRP_STATUS:-}" ]]; then
    STB_OK=false
else
    printf '%s' "$STB_MRP_STATUS" | grep -qiE "APPLYING_LOG|WAIT_FOR_LOG" || STB_OK=false
fi
if $PRI_OK; then PRI_DOT="${GREEN}●${NC}"; else PRI_DOT="${RED}●${NC}"; fi
if $STB_OK; then STB_DOT="${GREEN}●${NC}"; else STB_DOT="${RED}●${NC}"; fi

printf '\n ┌%s┬%s┐\n' "$_BAR" "$_BAR"
box_row "${PRI_DOT} ${BOLD}PRIMARY${NC}" "${STB_DOT} ${BOLD}PHYSICAL STANDBY${NC}"
box_row "${PRI_DBUNIQ:-?} @ ${PRIMARY_ORACLE_HOSTNAME}" "${STB_DBUNIQ:-?} @ ${STANDBY_ORACLE_HOSTNAME}"
box_row "${PRI_OPEN:-?}" "${STB_OPEN:-?} / MRP: ${STB_MRP_STATUS:-NOT RUNNING}"
printf ' └%s┴%s┘\n' "$_BAR" "$_BAR"

# -- Primary Database ---------------------------------------------------------
header "PRIMARY DATABASE  (${PRIMARY_ORACLE_HOSTNAME} / ${PRI_DBUNIQ:-?})"
subheader "Identity"

icon=$(status_icon "$PRI_ROLE" "PRIMARY")
[[ "$icon" == *"XX"* ]] && add_summary_error "Primary role is '$PRI_ROLE' (expected PRIMARY)"
row "Role" "$PRI_ROLE" "$icon"

icon=$(status_icon "$PRI_OPEN" "READ WRITE")
[[ "$icon" == *"XX"* ]] && add_summary_error "Primary open mode is '$PRI_OPEN' (expected READ WRITE)"
row "Open Mode" "$PRI_OPEN" "$icon"

row "Protection Mode" "$PRI_PROTECT"

icon=$(warn_icon "$PRI_SWITCH" "TO STANDBY" "SESSIONS ACTIVE")
[[ "$icon" == *"!!"* ]] && add_summary_warning "Primary switchover status is '$PRI_SWITCH'"
row "Switchover Status" "$PRI_SWITCH" "$icon"

icon=$(status_icon "$PRI_FORCE" "YES")
[[ "$icon" == *"XX"* ]] && add_summary_error "Force logging is '$PRI_FORCE' on primary"
row "Force Logging" "$PRI_FORCE" "$icon"

icon=$(warn_icon "$PRI_FLASH" "YES")
[[ "$icon" == *"!!"* ]] && add_summary_warning "Flashback is '$PRI_FLASH' on primary"
row "Flashback" "$PRI_FLASH" "$icon"

subheader "Services"

icon=$(status_icon "${PRI_BROKER:-FALSE}" "TRUE")
[[ "$icon" == *"XX"* ]] && add_summary_error "DG Broker is '${PRI_BROKER:-FALSE}' on primary"
row "DG Broker" "${PRI_BROKER:-FALSE}" "$icon"
row "Running Services" "${PRI_SERVICES:-NONE}"

subheader "Redo / Archive"

row "Online Redo Logs" "${PRI_REDO_CNT:-?} groups (${PRI_REDO_MB:-?} MB total)"
if [[ -n "${PRI_SRL:-}" ]] && [[ "${PRI_SRL:-0}" -gt 0 ]]; then
    row "Standby Redo Logs" "${PRI_SRL} groups" "$CHK"
else
    row "Standby Redo Logs" "NONE" "$WARN"; add_summary_warning "Primary has no standby redo logs configured"
fi

if [[ "${PRI_DEST2_STATUS:-}" == "VALID" ]]; then
    row "Archive Dest 2 (Standby)" "$PRI_DEST2_STATUS" "$CHK"
elif [[ -n "${PRI_DEST2_STATUS:-}" ]]; then
    row "Archive Dest 2 (Standby)" "${PRI_DEST2_STATUS} ${PRI_DEST2_ERROR:-}" "$FAIL"; add_summary_error "Archive destination 2 is '${PRI_DEST2_STATUS}' ${PRI_DEST2_ERROR:-}"
fi

if [[ -n "${PRI_ARCHGAP:-}" ]] && [[ "${PRI_ARCHGAP:-0}" -gt 0 ]]; then
    row "Archive Gaps" "${PRI_ARCHGAP} gap(s)!" "$FAIL"; add_summary_error "Primary reports ${PRI_ARCHGAP} archive gap(s)"
fi

subheader "Recovery Area"

if [[ -n "${PRI_FRA_PATH:-}" ]]; then
    PRI_FRA_EFFECTIVE_USED=$(awk "BEGIN {effective=${PRI_FRA_USED:-0}-${PRI_FRA_RECLAIM:-0}; if (effective < 0) effective=0; printf \"%.1f\", effective}")
    PRI_FRA_PCT=$(awk "BEGIN {if (${PRI_FRA_SIZE:-0} > 0) {effective=${PRI_FRA_USED:-0}-${PRI_FRA_RECLAIM:-0}; if (effective < 0) effective=0; printf \"%.0f\", (effective/${PRI_FRA_SIZE})*100} else print 0}")
    if [[ "$PRI_FRA_PCT" -ge 90 ]]; then
        icon="$FAIL"; add_summary_error "Primary FRA usage is ${PRI_FRA_PCT}%"
    elif [[ "$PRI_FRA_PCT" -ge 80 ]]; then
        icon="$WARN"; add_summary_warning "Primary FRA usage is ${PRI_FRA_PCT}%"
    else
        icon="$CHK"
    fi
    row "FRA Usage" "${PRI_FRA_EFFECTIVE_USED}/${PRI_FRA_SIZE} GB effective (${PRI_FRA_PCT}%), reclaimable ${PRI_FRA_RECLAIM} GB" "$icon"
    row "FRA Location" "${PRI_FRA_PATH} (${PRI_FRA_FILES:-0} files)"
fi

# -- Standby Database ---------------------------------------------------------
header "STANDBY DATABASE  (${STANDBY_ORACLE_HOSTNAME} / ${STB_DBUNIQ:-?})"
subheader "Identity"

icon=$(status_icon "$STB_ROLE" "PHYSICAL STANDBY")
[[ "$icon" == *"XX"* ]] && add_summary_error "Standby role is '$STB_ROLE' (expected PHYSICAL STANDBY)"
row "Role" "$STB_ROLE" "$icon"

icon=$(warn_icon "$STB_OPEN" "MOUNTED" "READ ONLY")
[[ "$icon" == *"!!"* ]] && add_summary_warning "Standby open mode is '$STB_OPEN'"
row "Open Mode" "$STB_OPEN" "$icon"

row "Protection Mode" "$STB_PROTECT"

icon=$(warn_icon "$STB_SWITCH" "NOT ALLOWED" "SWITCHOVER PENDING")
row "Switchover Status" "$STB_SWITCH" "$icon"

subheader "Services"

row "Running Services" "${STB_SERVICES:-NONE}"

subheader "Recovery / Apply"

# MRP (Managed Recovery Process)
if [[ -n "${STB_MRP_STATUS:-}" ]]; then
    icon=$(status_icon "$STB_MRP_STATUS" "APPLYING_LOG" "WAIT_FOR_LOG")
    [[ "$icon" == *"XX"* ]] && add_summary_error "MRP status is '$STB_MRP_STATUS'"
    row "MRP Status" "${STB_MRP_STATUS} (seq# ${STB_MRP_SEQ:-?})" "$icon"
else
    row "MRP Status" "NOT RUNNING" "$FAIL"; add_summary_error "MRP is not running on standby"
fi

# Lag
if [[ -n "${STB_TRANSPORT_LAG:-}" ]]; then
    if [[ "$STB_TRANSPORT_LAG" == "+00 00:00:00" ]] || [[ "$STB_TRANSPORT_LAG" == "0" ]]; then
        row "Transport Lag" "none" "$CHK"
    else
        row "Transport Lag" "$STB_TRANSPORT_LAG" "$WARN"; add_summary_warning "Transport lag is $STB_TRANSPORT_LAG"
    fi
else
    row "Transport Lag" "N/A (standby mounted)"
fi

if [[ -n "${STB_APPLY_LAG:-}" ]]; then
    if [[ "$STB_APPLY_LAG" == "+00 00:00:00" ]] || [[ "$STB_APPLY_LAG" == "0" ]]; then
        row "Apply Lag" "none" "$CHK"
    else
        row "Apply Lag" "$STB_APPLY_LAG" "$WARN"; add_summary_warning "Apply lag is $STB_APPLY_LAG"
    fi
else
    row "Apply Lag" "N/A (standby mounted)"
fi

# Sequence gap
if [[ -n "${STB_LAST_APPLIED:-}" ]] && [[ -n "${STB_LAST_RECEIVED:-}" ]] && [[ "${STB_LAST_RECEIVED:-0}" -gt 0 ]]; then
    SEQ_LAG=$((STB_LAST_RECEIVED - STB_LAST_APPLIED))
    if [[ "$SEQ_LAG" -le 1 ]]; then
        row "Sequences" "applied=${STB_LAST_APPLIED}  received=${STB_LAST_RECEIVED}" "$CHK"
    elif [[ "$SEQ_LAG" -le 5 ]]; then
        row "Sequences" "applied=${STB_LAST_APPLIED}  received=${STB_LAST_RECEIVED}  (lag: ${SEQ_LAG})" "$WARN"; add_summary_warning "Standby sequence lag is ${SEQ_LAG}"
    else
        row "Sequences" "applied=${STB_LAST_APPLIED}  received=${STB_LAST_RECEIVED}  (lag: ${SEQ_LAG})" "$FAIL"; add_summary_error "Standby sequence lag is ${SEQ_LAG}"
    fi
fi

subheader "Redo / Archive"

if [[ -n "${STB_SRL:-}" ]] && [[ "${STB_SRL:-0}" -gt 0 ]]; then
    row "Standby Redo Logs" "${STB_SRL} groups" "$CHK"
else
    row "Standby Redo Logs" "NONE" "$FAIL"; add_summary_error "Standby has no standby redo logs configured"
fi

if [[ -n "${STB_ARCHGAP:-}" ]] && [[ "${STB_ARCHGAP:-0}" -gt 0 ]]; then
    row "Archive Gaps" "${STB_ARCHGAP} gap(s)!" "$FAIL"; add_summary_error "Standby reports ${STB_ARCHGAP} archive gap(s)"
fi

subheader "Recovery Area"

if [[ -n "${STB_FRA_PATH:-}" ]]; then
    STB_FRA_EFFECTIVE_USED=$(awk "BEGIN {effective=${STB_FRA_USED:-0}-${STB_FRA_RECLAIM:-0}; if (effective < 0) effective=0; printf \"%.1f\", effective}")
    STB_FRA_PCT=$(awk "BEGIN {if (${STB_FRA_SIZE:-0} > 0) {effective=${STB_FRA_USED:-0}-${STB_FRA_RECLAIM:-0}; if (effective < 0) effective=0; printf \"%.0f\", (effective/${STB_FRA_SIZE})*100} else print 0}")
    if [[ "$STB_FRA_PCT" -ge 90 ]]; then
        icon="$FAIL"; add_summary_error "Standby FRA usage is ${STB_FRA_PCT}%"
    elif [[ "$STB_FRA_PCT" -ge 80 ]]; then
        icon="$WARN"; add_summary_warning "Standby FRA usage is ${STB_FRA_PCT}%"
    else
        icon="$CHK"
    fi
    row "FRA Usage" "${STB_FRA_EFFECTIVE_USED}/${STB_FRA_SIZE} GB effective (${STB_FRA_PCT}%), reclaimable ${STB_FRA_RECLAIM} GB" "$icon"
    row "FRA Location" "${STB_FRA_PATH} (${STB_FRA_FILES:-0} files)"
fi

# -- Broker Configuration ----------------------------------------------------
header "DATA GUARD BROKER"

if printf '%s' "$DGMGRL_CONFIG" | grep -q "ORA-16532\|not yet available\|not exist"; then
    row "Configuration" "NOT CONFIGURED" "$FAIL"; add_summary_error "Data Guard Broker configuration is not configured or not available"
else
    row "Configuration" "${BROKER_CFG_NAME:-unknown}"

    if [[ -n "${BROKER_OVERALL:-}" ]]; then
        icon=$(status_icon "$BROKER_OVERALL" "SUCCESS")
        [[ "$icon" == *"XX"* ]] && add_summary_error "Broker overall status is '$BROKER_OVERALL'"
        row "Overall Status" "$BROKER_OVERALL" "$icon"
    fi

    # Show members and their ORA errors/warnings from SHOW CONFIGURATION
    while IFS= read -r line; do
        line_trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
        if printf '%s' "$line" | grep -qE '^\s+\S+\s+-\s+'; then
            # Member line (e.g. "cdb1 - Primary database")
            if printf '%s' "$line_trimmed" | grep -qi "Error"; then
                add_summary_error "Broker member issue: $line_trimmed"
                row "" "$line_trimmed" "$FAIL"
            elif printf '%s' "$line_trimmed" | grep -qi "Warning"; then
                add_summary_warning "Broker member warning: $line_trimmed"
                row "" "$line_trimmed" "$WARN"
            else
                row "" "$line_trimmed" "$CHK"
            fi
        elif printf '%s' "$line" | grep -qi 'ORA-'; then
            # ORA error/warning detail line
            printf "  ${DIM}%-24s${NC} ${RED}%s${NC}\n" "" "$line_trimmed"
        fi
    done <<< "$DGMGRL_CONFIG"

    # FSFO status
    FSFO_MODE=$(printf '%s\n' "$DGMGRL_FSFO" | grep -i 'Fast-Start Failover:' | head -1 | sed 's/.*: *//' | xargs)
    if [[ -n "${FSFO_MODE:-}" ]]; then
        if printf '%s' "$FSFO_MODE" | grep -qi "Enabled"; then
            row "Fast-Start Failover" "$FSFO_MODE" "$CHK"
            FSFO_TARGET=$(printf '%s\n' "$DGMGRL_FSFO" | grep -i 'Target:' | sed 's/.*: *//' | xargs)
            FSFO_OBS=$(printf '%s\n' "$DGMGRL_FSFO" | grep -i 'Observer:' | sed 's/.*: *//' | xargs)
            FSFO_THRESHOLD=$(printf '%s\n' "$DGMGRL_FSFO" | grep -i 'Threshold:' | sed 's/.*: *//' | xargs)
            [[ -n "${FSFO_TARGET:-}" ]] && row "  Target" "$FSFO_TARGET"
            [[ -n "${FSFO_OBS:-}" ]] && row "  Observer" "$FSFO_OBS"
            [[ -n "${FSFO_THRESHOLD:-}" ]] && row "  Threshold" "$FSFO_THRESHOLD"
        else
            row "Fast-Start Failover" "${FSFO_MODE}" "${DIM}disabled${NC}"
            add_summary_warning "Fast-Start Failover is ${FSFO_MODE}"
        fi
    fi
fi

# -- Recent Alert Log (DG-related) --------------------------------------------
header "RECENT ALERT LOG (Data Guard)"

_show_alert_entries() {
    local label="$1" file="$2"
    local entries
    entries=$(cat "$file" 2>/dev/null | sed '/^$/d')
    if [[ -z "$entries" ]]; then
        row "$label" "No recent DG-related entries"
    else
        row "$label" ""
        while IFS= read -r line; do
            # Format: "YYYY-MM-DD HH:MM:SS  message" or just "message" (no timestamp)
            local ts="" msg="$line"
            if printf '%s' "$line" | grep -q '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] '; then
                ts="${line:0:19}"
                msg="${line:21}"
            fi
            if printf '%s' "$msg" | grep -qiE 'ORA-|error|fail'; then
                if [[ -n "$ts" ]]; then
                    printf "  %-*s ${DIM}%s${NC}  ${RED}%s${NC}\n" "$LABEL_W" "" "$ts" "$msg"
                else
                    printf "  %-*s ${RED}%s${NC}\n" "$LABEL_W" "" "$msg"
                fi
            else
                if [[ -n "$ts" ]]; then
                    printf "  %-*s ${DIM}%s${NC}  %s\n" "$LABEL_W" "" "$ts" "$msg"
                else
                    printf "  %-*s %s\n" "$LABEL_W" "" "$msg"
                fi
            fi
        done <<< "$entries"
    fi
}

subheader "Primary (${PRIMARY_ORACLE_HOSTNAME})"
_show_alert_entries "Alert Log" "$TMP/primary_alert"
_show_alert_entries "Broker Log" "$TMP/primary_drc"

subheader "Standby (${STANDBY_ORACLE_HOSTNAME})"
_show_alert_entries "Alert Log" "$TMP/standby_alert"
_show_alert_entries "Broker Log" "$TMP/standby_drc"

# =============================================================================
# Summary
# =============================================================================
printf "\n ${DIM}────────────────────────────────────────────────────────────${NC}\n"

if [[ $ERRORS -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
    printf " ${BOLD}${GREEN} HEALTHY${NC}  ${DIM}No issues detected${NC}\n"
elif [[ $ERRORS -eq 0 ]]; then
    printf " ${BOLD}${YELLOW} WARNING${NC}  ${DIM}${WARNINGS} warning(s)${NC}\n"
else
    printf " ${BOLD}${RED} ISSUES ${NC}  ${RED}${ERRORS} error(s)${NC}"
    [[ $WARNINGS -gt 0 ]] && printf "  ${YELLOW}${WARNINGS} warning(s)${NC}"
    printf "\n"
fi

if [[ $ERRORS -gt 0 ]]; then
    OVERALL_STATE="${RED}CRITICAL${NC}"
elif [[ $WARNINGS -gt 0 ]]; then
    OVERALL_STATE="${YELLOW}ATTENTION${NC}"
else
    OVERALL_STATE="${GREEN}HEALTHY${NC}"
fi

if $PRI_OK; then
    PRIMARY_STATE="${GREEN}OK${NC}"
else
    PRIMARY_STATE="${RED}CHECK${NC}"
fi

if $STB_OK; then
    STANDBY_STATE="${GREEN}OK${NC}"
else
    STANDBY_STATE="${RED}CHECK${NC}"
fi

if [[ "${BROKER_OVERALL:-}" == "SUCCESS" ]]; then
    BROKER_STATE="${GREEN}${BROKER_OVERALL}${NC}"
elif [[ -n "${BROKER_OVERALL:-}" ]]; then
    BROKER_STATE="${RED}${BROKER_OVERALL}${NC}"
else
    BROKER_STATE="${YELLOW}UNKNOWN${NC}"
fi

if [[ -n "${STB_TRANSPORT_LAG:-}" && "$STB_TRANSPORT_LAG" != "+00 00:00:00" && "$STB_TRANSPORT_LAG" != "0" ]]; then
    REPL_STATE="${YELLOW}LAGGING${NC}"
elif [[ -n "${STB_APPLY_LAG:-}" && "$STB_APPLY_LAG" != "+00 00:00:00" && "$STB_APPLY_LAG" != "0" ]]; then
    REPL_STATE="${YELLOW}LAGGING${NC}"
elif [[ -n "${SEQ_LAG:-}" && "$SEQ_LAG" -gt 5 ]]; then
    REPL_STATE="${RED}BEHIND${NC}"
elif [[ -n "${SEQ_LAG:-}" && "$SEQ_LAG" -gt 1 ]]; then
    REPL_STATE="${YELLOW}BEHIND${NC}"
else
    REPL_STATE="${GREEN}IN SYNC${NC}"
fi

header "FINAL SUMMARY"
row "Overall" "errors=${ERRORS} warnings=${WARNINGS}" "$OVERALL_STATE"
row "Primary" "${PRI_DBUNIQ:-?} / ${PRI_OPEN:-unknown}" "$PRIMARY_STATE"
row "Standby" "${STB_DBUNIQ:-?} / MRP ${STB_MRP_STATUS:-NOT RUNNING}" "$STANDBY_STATE"
row "Broker" "${BROKER_CFG_NAME:-not configured}" "$BROKER_STATE"
row "Redo Apply" "transport=${STB_TRANSPORT_LAG:-n/a}, apply=${STB_APPLY_LAG:-n/a}" "$REPL_STATE"

if [[ $ERRORS -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
    row "Status" "No problems detected" "$CHK"
else
    if [[ ${#SUMMARY_ERRORS[@]} -gt 0 ]]; then
        for item in "${SUMMARY_ERRORS[@]}"; do
            row "Error" "$item" "$FAIL"
        done
    fi
    if [[ ${#SUMMARY_WARNINGS[@]} -gt 0 ]]; then
        for item in "${SUMMARY_WARNINGS[@]}"; do
            row "Warning" "$item" "$WARN"
        done
    fi
fi

printf "\n"
