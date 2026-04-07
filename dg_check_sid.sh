#!/usr/bin/env bash
# =============================================================================
# Oracle Data Guard - Local Status Check
# =============================================================================
#
# Health check that runs directly on a database host (no SSH required).
# Detects the local database role, queries local V$ views and DGMGRL,
# then connects to the peer database over SQL*Net for remote checks.
#
# Prerequisites:
#   - ORACLE_HOME and ORACLE_SID set, sqlplus / as sysdba working
#   - DG Broker running (dg_broker_start = TRUE)
#   - TNS connectivity to peer database (for remote checks)
#
# Remote connection:
#   The script discovers the peer TNS alias from the broker configuration.
#   It tries wallet-based auth first (sqlplus /@tns as sysdba), then
#   prompts for the SYS password. Pass -P to force the password prompt,
#   or -L to skip remote checks entirely (local + broker only).
#
# Usage:
#   bash dg_check_sid.sh            # Auto-detect role, try wallet for remote
#   bash dg_check_sid.sh -P         # Prompt for SYS password for remote
#   bash dg_check_sid.sh -L         # Local + broker only (skip remote SQL)
#
#
# =============================================================================

set -uo pipefail

# -- Colors & symbols --------------------------------------------------------
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';   BOLD='\033[1m'
DIM='\033[2m';       NC='\033[0m'
CHK="${GREEN}OK${NC}"; WARN="${YELLOW}!!${NC}"; FAIL="${RED}XX${NC}"
INFO="${CYAN}..${NC}"

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
PROMPT_PASSWORD=false
LOCAL_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -P|--password) PROMPT_PASSWORD=true; shift ;;
        -L|--local)    LOCAL_ONLY=true; shift ;;
        -h|--help)
            printf "Usage: bash dg_check_sid.sh [-P] [-L]\n"
            printf "  -P, --password   Prompt for SYS password for remote connection\n"
            printf "  -L, --local      Skip remote SQL checks (local + broker only)\n"
            exit 0 ;;
        *) printf "Unknown option: %s\n" "$1"; exit 1 ;;
    esac
done

# -- Verify Oracle environment ------------------------------------------------
if [[ -z "${ORACLE_SID:-}" ]]; then
    printf "ERROR: ORACLE_SID is not set\n"
    exit 1
fi
if [[ -z "${ORACLE_HOME:-}" ]]; then
    printf "ERROR: ORACLE_HOME is not set\n"
    exit 1
fi
export PATH="${ORACLE_HOME}/bin:${PATH}"

printf "\n ${BOLD}${CYAN}Data Guard Status Check${NC}  ${DIM}starting...${NC}\n"
printf " ${DIM}Local SID: %s${NC}\n" "${ORACLE_SID}"

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

run_local_sql() {
    sqlplus -s / as sysdba <<SQL
SET HEADING OFF FEEDBACK OFF LINESIZE 300 PAGESIZE 0 TRIMSPOOL ON
$1
EXIT;
SQL
}

run_remote_sql() {
    local connect="$1" query="$2"
    sqlplus -s "${connect}" as sysdba <<SQL
SET HEADING OFF FEEDBACK OFF LINESIZE 300 PAGESIZE 0 TRIMSPOOL ON
${query}
EXIT;
SQL
}

run_remote_sql_timeout() {
    local timeout_secs="$1" connect="$2" query="$3"
    if command -v timeout >/dev/null 2>&1; then
        timeout "${timeout_secs}"s sqlplus -s "${connect}" as sysdba <<SQL
SET HEADING OFF FEEDBACK OFF LINESIZE 300 PAGESIZE 0 TRIMSPOOL ON
${query}
EXIT;
SQL
    else
        run_remote_sql "$connect" "$query"
    fi
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

# -- Minimal local identity ---------------------------------------------------
LOCAL_ID_SQL=$(run_local_sql "
SELECT 'DBSTATUS|' || DATABASE_ROLE || '|' || DB_UNIQUE_NAME FROM V\$DATABASE;
")

LOC_ID_STATUS=$(printf '%s\n' "$LOCAL_ID_SQL" | grep '^DBSTATUS|' | head -1 | sed 's/^DBSTATUS|//')
LOC_ROLE=$(printf '%s' "$LOC_ID_STATUS" | awk -F'|' '{print $1}' | xargs)
LOC_DBUNIQ=$(printf '%s' "$LOC_ID_STATUS" | awk -F'|' '{print $2}' | xargs)

if printf '%s' "$LOC_ROLE" | grep -qi "PRIMARY"; then
    IS_PRIMARY=true
    LOC_LABEL="PRIMARY"
    PEER_LABEL="STANDBY"
else
    IS_PRIMARY=false
    LOC_LABEL="STANDBY"
    PEER_LABEL="PRIMARY"
fi

# -- Collect broker data ------------------------------------------------------
DGMGRL_CONFIG=$(dgmgrl -silent / 'SHOW CONFIGURATION' 2>&1)
DGMGRL_FSFO=$(dgmgrl -silent / 'SHOW FAST_START FAILOVER' 2>&1)

BROKER_CFG_NAME=$(printf '%s\n' "$DGMGRL_CONFIG" | grep 'Configuration -' | sed 's/.*Configuration - //' | xargs)
BROKER_OVERALL=$(printf '%s\n' "$DGMGRL_CONFIG" | tail -5 | extract_first_status)

# Find peer DB unique name from broker config
# Members lines look like: "  cdb1_stby - Physical standby database"
if $IS_PRIMARY; then
    PEER_DBUNIQ=$(printf '%s\n' "$DGMGRL_CONFIG" | grep -i 'Physical standby' | head -1 | awk '{print $1}')
else
    PEER_DBUNIQ=$(printf '%s\n' "$DGMGRL_CONFIG" | grep -i 'Primary database' | head -1 | awk '{print $1}')
fi

# Get peer TNS alias from broker
PEER_TNS=""
if [[ -n "${PEER_DBUNIQ:-}" ]]; then
    PEER_TNS_RAW=$(dgmgrl -silent / "SHOW DATABASE '${PEER_DBUNIQ}' 'DGConnectIdentifier'" 2>&1)
    PEER_TNS=$(printf '%s\n' "$PEER_TNS_RAW" | grep 'DGConnectIdentifier' | sed "s/.*= *'//" | sed "s/'.*//")
fi

# Get broker detail for peer database
DGMGRL_PEER=""
if [[ -n "${PEER_DBUNIQ:-}" ]]; then
    DGMGRL_PEER=$(dgmgrl -silent / "SHOW DATABASE '${PEER_DBUNIQ}'" 2>&1)
fi

# -- Remote connection to peer ------------------------------------------------
REMOTE_SQL=""
REMOTE_CONNECTED=false
REMOTE_TEST_TIMEOUT="${REMOTE_TEST_TIMEOUT:-5}"

if [[ "$LOCAL_ONLY" != true ]] && [[ -n "${PEER_TNS:-}" ]]; then
    printf " ${DIM}Peer database: %s (TNS: %s)${NC}\n" "${PEER_DBUNIQ}" "${PEER_TNS}"
    # Try wallet-based connection first
    if [[ "$PROMPT_PASSWORD" != true ]]; then
        printf " ${DIM}Checking wallet authentication (timeout: %ss)...${NC}\n" "$REMOTE_TEST_TIMEOUT"
        WALLET_TEST=$(run_remote_sql_timeout "$REMOTE_TEST_TIMEOUT" "/@${PEER_TNS}" "
SELECT 'WALLET_OK' FROM DUAL;
" 2>&1)
        if printf '%s' "$WALLET_TEST" | grep -q 'WALLET_OK'; then
            REMOTE_CONNECT="/@${PEER_TNS}"
            REMOTE_CONNECTED=true
        fi
    fi

    # Prompt for SYS password if wallet failed or -P was given
    if [[ "$REMOTE_CONNECTED" != true ]]; then
        if [[ "$PROMPT_PASSWORD" == true ]] || [[ "$REMOTE_CONNECTED" != true ]]; then
            printf " Enter SYS password for remote connection (or press Enter to skip): "
            stty -echo 2>/dev/null || true
            read -r SYS_PASS
            stty echo 2>/dev/null || true
            printf "\n"

            if [[ -n "$SYS_PASS" ]]; then
                REMOTE_CONNECT="sys/${SYS_PASS}@${PEER_TNS}"
                # Test connection
                PASS_TEST=$(run_remote_sql_timeout "$REMOTE_TEST_TIMEOUT" "$REMOTE_CONNECT" "SELECT 'PASS_OK' FROM DUAL;" 2>&1)
                if printf '%s' "$PASS_TEST" | grep -q 'PASS_OK'; then
                    REMOTE_CONNECTED=true
                else
                    printf " ${RED}Remote connection failed${NC} - continuing with local + broker only\n"
                fi
            fi
        fi
    fi

    # Collect remote data
    if [[ "$REMOTE_CONNECTED" == true ]]; then
        REMOTE_SQL=$(run_remote_sql "$REMOTE_CONNECT" "
SELECT 'DBSTATUS|' || DATABASE_ROLE || '|' || OPEN_MODE || '|' || PROTECTION_MODE || '|' || SWITCHOVER_STATUS || '|' || FORCE_LOGGING || '|' || FLASHBACK_ON || '|' || DB_UNIQUE_NAME FROM V\$DATABASE;
SELECT 'REDOLOG|' || COUNT(*) || '|' || ROUND(SUM(BYTES)/1024/1024) FROM V\$LOG;
SELECT 'SRLCOUNT|' || COUNT(*) FROM V\$STANDBY_LOG;
SELECT 'ARCHGAP|' || COUNT(*) FROM V\$ARCHIVE_GAP;
SELECT 'FRA|' || NAME || '|' || ROUND(SPACE_LIMIT/1024/1024/1024,1) || '|' || ROUND(SPACE_USED/1024/1024/1024,1) || '|' || ROUND(SPACE_RECLAIMABLE/1024/1024/1024,1) || '|' || NUMBER_OF_FILES FROM V\$RECOVERY_FILE_DEST;
SELECT 'SERVICE|' || NAME
  FROM (
    SELECT NAME
      FROM V\$ACTIVE_SERVICES
     WHERE NAME NOT LIKE 'SYS$%'
       AND UPPER(NAME) NOT LIKE '%XDB%'
     ORDER BY NAME
  );
SELECT 'MRP|' || PROCESS || '|' || STATUS || '|' || SEQUENCE# FROM V\$MANAGED_STANDBY WHERE PROCESS = 'MRP0';
SELECT 'DGSTATS|' || NAME || '|' || VALUE FROM V\$DATAGUARD_STATS WHERE NAME IN ('transport lag','apply lag','apply finish time');
SELECT 'APPLYINFO|' || NVL(MAX(CASE WHEN APPLIED='YES' THEN SEQUENCE# END),0) || '|' || NVL(MAX(SEQUENCE#),0) FROM V\$ARCHIVED_LOG WHERE THREAD#=1;
" 2>&1)
    fi
fi

# -- Collect full local data --------------------------------------------------
printf " ${DIM}Collecting local database data...${NC}\n"
LOCAL_SQL=$(run_local_sql "
SELECT 'DBSTATUS|' || DATABASE_ROLE || '|' || OPEN_MODE || '|' || PROTECTION_MODE || '|' || SWITCHOVER_STATUS || '|' || FORCE_LOGGING || '|' || FLASHBACK_ON || '|' || DB_UNIQUE_NAME FROM V\$DATABASE;
SELECT 'DGPARAMS|' || NAME || '|' || VALUE FROM V\$PARAMETER WHERE NAME IN ('dg_broker_start') ORDER BY NAME;
SELECT 'REDOLOG|' || COUNT(*) || '|' || ROUND(SUM(BYTES)/1024/1024) FROM V\$LOG;
SELECT 'SRLCOUNT|' || COUNT(*) FROM V\$STANDBY_LOG;
SELECT 'ARCHGAP|' || COUNT(*) FROM V\$ARCHIVE_GAP;
SELECT 'ARCHDEST|' || DEST_ID || '|' || STATUS || '|' || DB_UNIQUE_NAME || '|' || ERROR FROM V\$ARCHIVE_DEST WHERE DEST_ID IN (1,2);
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
SELECT 'MRP|' || PROCESS || '|' || STATUS || '|' || SEQUENCE# FROM V\$MANAGED_STANDBY WHERE PROCESS = 'MRP0';
SELECT 'DGSTATS|' || NAME || '|' || VALUE FROM V\$DATAGUARD_STATS WHERE NAME IN ('transport lag','apply lag','apply finish time');
SELECT 'APPLYINFO|' || NVL(MAX(CASE WHEN APPLIED='YES' THEN SEQUENCE# END),0) || '|' || NVL(MAX(SEQUENCE#),0) FROM V\$ARCHIVED_LOG WHERE THREAD#=1;
")

LOC_DBSTATUS=$(printf '%s\n' "$LOCAL_SQL" | grep '^DBSTATUS|' | head -1 | sed 's/^DBSTATUS|//')
LOC_ROLE=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $1}' | xargs)
LOC_OPEN=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $2}' | xargs)
LOC_PROTECT=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $3}' | xargs)
LOC_SWITCH=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $4}' | xargs)
LOC_FORCE=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $5}' | xargs)
LOC_FLASH=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $6}' | xargs)
LOC_DBUNIQ=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $7}' | xargs)
LOC_BROKER=$(printf '%s\n' "$LOCAL_SQL" | grep 'dg_broker_start' | awk -F'|' '{print $3}' | xargs)
LOC_ARCHGAP=$(printf '%s\n' "$LOCAL_SQL" | grep '^ARCHGAP|' | awk -F'|' '{print $2}' | xargs)
LOC_REDO=$(printf '%s\n' "$LOCAL_SQL" | grep '^REDOLOG|' | sed 's/^REDOLOG|//')
LOC_REDO_CNT=$(printf '%s' "$LOC_REDO" | awk -F'|' '{print $1}' | xargs)
LOC_REDO_MB=$(printf '%s' "$LOC_REDO" | awk -F'|' '{print $2}' | xargs)
LOC_SRL=$(printf '%s\n' "$LOCAL_SQL" | grep '^SRLCOUNT|' | awk -F'|' '{print $2}' | xargs)
LOC_DEST2_STATUS=$(printf '%s\n' "$LOCAL_SQL" | grep '^ARCHDEST|2|' | awk -F'|' '{print $3}' | xargs)
LOC_DEST2_DBUNIQ=$(printf '%s\n' "$LOCAL_SQL" | grep '^ARCHDEST|2|' | awk -F'|' '{print $4}' | xargs)
LOC_DEST2_ERROR=$(printf '%s\n' "$LOCAL_SQL" | grep '^ARCHDEST|2|' | awk -F'|' '{print $5}' | xargs)

LOC_FRA=$(printf '%s\n' "$LOCAL_SQL" | grep '^FRA|' | head -1 | sed 's/^FRA|//')
LOC_FRA_PATH=$(printf '%s' "$LOC_FRA" | awk -F'|' '{print $1}' | xargs)
LOC_FRA_SIZE=$(printf '%s' "$LOC_FRA" | awk -F'|' '{print $2}' | xargs)
LOC_FRA_USED=$(printf '%s' "$LOC_FRA" | awk -F'|' '{print $3}' | xargs)
LOC_FRA_RECLAIM=$(printf '%s' "$LOC_FRA" | awk -F'|' '{print $4}' | xargs)
LOC_FRA_FILES=$(printf '%s' "$LOC_FRA" | awk -F'|' '{print $5}' | xargs)
LOC_SERVICES=$(format_services "$(printf '%s\n' "$LOCAL_SQL" | grep '^SERVICE|' | sed 's/^SERVICE|//')")

LOC_MRP=$(printf '%s\n' "$LOCAL_SQL" | grep '^MRP|' | head -1 | sed 's/^MRP|//')
LOC_MRP_STATUS=$(printf '%s' "$LOC_MRP" | awk -F'|' '{print $2}' | xargs)
LOC_MRP_SEQ=$(printf '%s' "$LOC_MRP" | awk -F'|' '{print $3}' | xargs)

LOC_TRANSPORT_LAG=$(printf '%s\n' "$LOCAL_SQL" | grep 'transport lag' | awk -F'|' '{print $3}' | xargs)
LOC_APPLY_LAG=$(printf '%s\n' "$LOCAL_SQL" | grep 'apply lag' | awk -F'|' '{print $3}' | xargs)

LOC_APPLYINFO=$(printf '%s\n' "$LOCAL_SQL" | grep '^APPLYINFO|' | sed 's/^APPLYINFO|//')
LOC_LAST_APPLIED=$(printf '%s' "$LOC_APPLYINFO" | awk -F'|' '{print $1}' | xargs)
LOC_LAST_RECEIVED=$(printf '%s' "$LOC_APPLYINFO" | awk -F'|' '{print $2}' | xargs)

# -- Parse remote data -------------------------------------------------------
REM_ROLE=""; REM_OPEN=""; REM_PROTECT=""; REM_SWITCH=""; REM_FORCE=""; REM_FLASH=""; REM_DBUNIQ=""
REM_REDO_CNT=""; REM_REDO_MB=""; REM_SRL=""; REM_ARCHGAP=""
REM_FRA_PATH=""; REM_FRA_SIZE=""; REM_FRA_USED=""; REM_FRA_RECLAIM=""; REM_FRA_FILES=""
REM_MRP_STATUS=""; REM_MRP_SEQ=""
REM_TRANSPORT_LAG=""; REM_APPLY_LAG=""
REM_LAST_APPLIED=""; REM_LAST_RECEIVED=""
REM_SERVICES=""

if [[ -n "$REMOTE_SQL" ]]; then
    REM_DBSTATUS=$(printf '%s\n' "$REMOTE_SQL" | grep '^DBSTATUS|' | head -1 | sed 's/^DBSTATUS|//')
    REM_ROLE=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $1}' | xargs)
    REM_OPEN=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $2}' | xargs)
    REM_PROTECT=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $3}' | xargs)
    REM_SWITCH=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $4}' | xargs)
    REM_FORCE=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $5}' | xargs)
    REM_FLASH=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $6}' | xargs)
    REM_DBUNIQ=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $7}' | xargs)

    REM_REDO=$(printf '%s\n' "$REMOTE_SQL" | grep '^REDOLOG|' | sed 's/^REDOLOG|//')
    REM_REDO_CNT=$(printf '%s' "$REM_REDO" | awk -F'|' '{print $1}' | xargs)
    REM_REDO_MB=$(printf '%s' "$REM_REDO" | awk -F'|' '{print $2}' | xargs)
    REM_SRL=$(printf '%s\n' "$REMOTE_SQL" | grep '^SRLCOUNT|' | awk -F'|' '{print $2}' | xargs)
    REM_ARCHGAP=$(printf '%s\n' "$REMOTE_SQL" | grep '^ARCHGAP|' | awk -F'|' '{print $2}' | xargs)

    REM_FRA=$(printf '%s\n' "$REMOTE_SQL" | grep '^FRA|' | head -1 | sed 's/^FRA|//')
    REM_FRA_PATH=$(printf '%s' "$REM_FRA" | awk -F'|' '{print $1}' | xargs)
    REM_FRA_SIZE=$(printf '%s' "$REM_FRA" | awk -F'|' '{print $2}' | xargs)
    REM_FRA_USED=$(printf '%s' "$REM_FRA" | awk -F'|' '{print $3}' | xargs)
    REM_FRA_RECLAIM=$(printf '%s' "$REM_FRA" | awk -F'|' '{print $4}' | xargs)
    REM_FRA_FILES=$(printf '%s' "$REM_FRA" | awk -F'|' '{print $5}' | xargs)
    REM_SERVICES=$(format_services "$(printf '%s\n' "$REMOTE_SQL" | grep '^SERVICE|' | sed 's/^SERVICE|//')")

    REM_MRP=$(printf '%s\n' "$REMOTE_SQL" | grep '^MRP|' | head -1 | sed 's/^MRP|//')
    REM_MRP_STATUS=$(printf '%s' "$REM_MRP" | awk -F'|' '{print $2}' | xargs)
    REM_MRP_SEQ=$(printf '%s' "$REM_MRP" | awk -F'|' '{print $3}' | xargs)

    REM_TRANSPORT_LAG=$(printf '%s\n' "$REMOTE_SQL" | grep 'transport lag' | awk -F'|' '{print $3}' | xargs)
    REM_APPLY_LAG=$(printf '%s\n' "$REMOTE_SQL" | grep 'apply lag' | awk -F'|' '{print $3}' | xargs)

    REM_APPLYINFO=$(printf '%s\n' "$REMOTE_SQL" | grep '^APPLYINFO|' | sed 's/^APPLYINFO|//')
    REM_LAST_APPLIED=$(printf '%s' "$REM_APPLYINFO" | awk -F'|' '{print $1}' | xargs)
    REM_LAST_RECEIVED=$(printf '%s' "$REM_APPLYINFO" | awk -F'|' '{print $2}' | xargs)
fi

# -- Collect alert log entries (DG-related) -----------------------------------
# Oracle 19c alert log has ISO timestamps on their own line (e.g. 2024-01-15T10:30:45.123+00:00)
# awk tracks the last timestamp and prepends it to matching DG lines
LOC_ALERT_TRACE=$(run_local_sql "SELECT VALUE FROM V\$DIAG_INFO WHERE NAME = 'Diag Trace';" | xargs)
LOC_ALERT_FILE="${LOC_ALERT_TRACE}/alert_${ORACLE_SID}.log"
LOC_ALERT_ENTRIES=""
if [[ -f "$LOC_ALERT_FILE" ]]; then
    LOC_ALERT_ENTRIES=$(tail -2000 "$LOC_ALERT_FILE" | awk '
/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ { ts = substr($0, 1, 19); gsub(/T/, " ", ts); next }
{ low = tolower($0) }
low ~ /ora-16[0-9][0-9][0-9]|ora-01034|ora-03113|ora-12541|switchover|failover|data guard|mrp0|fal\[|rfs\[|lns[0-9]|broker|dgmgrl|role.change|arch.*gap|apply_lag|transport_lag/ {
    if (ts != "") printf "%s  %s\n", ts, $0; else print $0
}' 2>/dev/null | tail -15)
fi

# Broker log (drc<SID>.log) - contains DGMGRL and broker internal messages
LOC_DRC_FILE="${LOC_ALERT_TRACE}/drc${ORACLE_SID}.log"
LOC_DRC_ENTRIES=""
if [[ -f "$LOC_DRC_FILE" ]]; then
    LOC_DRC_ENTRIES=$(tail -500 "$LOC_DRC_FILE" | awk '
/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ { ts = substr($0, 1, 19); gsub(/T/, " ", ts); next }
{ low = tolower($0) }
low ~ /ora-|error|warning|fail|switchover|failover|role change|fsfo|reinstate|disable|enable|nsv|broker/ {
    if (ts != "") printf "%s  %s\n", ts, $0; else print $0
}' 2>/dev/null | tail -10)
fi

# =============================================================================
# Assign to PRIMARY / STANDBY variables based on detected role
# =============================================================================
if $IS_PRIMARY; then
    PRI_ROLE="$LOC_ROLE";       PRI_OPEN="$LOC_OPEN";       PRI_PROTECT="$LOC_PROTECT"
    PRI_SWITCH="$LOC_SWITCH";   PRI_FORCE="$LOC_FORCE";     PRI_FLASH="$LOC_FLASH"
    PRI_DBUNIQ="$LOC_DBUNIQ";   PRI_BROKER="$LOC_BROKER"
    PRI_REDO_CNT="$LOC_REDO_CNT"; PRI_REDO_MB="$LOC_REDO_MB"; PRI_SRL="$LOC_SRL"
    PRI_DEST2_STATUS="$LOC_DEST2_STATUS"; PRI_DEST2_ERROR="${LOC_DEST2_ERROR:-}"
    PRI_ARCHGAP="$LOC_ARCHGAP"
    PRI_FRA_PATH="$LOC_FRA_PATH"; PRI_FRA_SIZE="$LOC_FRA_SIZE"
    PRI_FRA_USED="$LOC_FRA_USED"; PRI_FRA_RECLAIM="$LOC_FRA_RECLAIM"; PRI_FRA_FILES="$LOC_FRA_FILES"
    PRI_SERVICES="$LOC_SERVICES"
    PRI_HOST=$(short_hostname)

    STB_ROLE="$REM_ROLE";       STB_OPEN="$REM_OPEN";       STB_PROTECT="$REM_PROTECT"
    STB_SWITCH="$REM_SWITCH";   STB_FORCE="$REM_FORCE";     STB_FLASH="$REM_FLASH"
    STB_DBUNIQ="${REM_DBUNIQ:-${PEER_DBUNIQ:-?}}"
    STB_REDO_CNT="$REM_REDO_CNT"; STB_REDO_MB="$REM_REDO_MB"; STB_SRL="$REM_SRL"
    STB_ARCHGAP="$REM_ARCHGAP"
    STB_MRP_STATUS="$REM_MRP_STATUS"; STB_MRP_SEQ="$REM_MRP_SEQ"
    STB_TRANSPORT_LAG="$REM_TRANSPORT_LAG"; STB_APPLY_LAG="$REM_APPLY_LAG"
    STB_LAST_APPLIED="$REM_LAST_APPLIED"; STB_LAST_RECEIVED="$REM_LAST_RECEIVED"
    STB_FRA_PATH="$REM_FRA_PATH"; STB_FRA_SIZE="$REM_FRA_SIZE"
    STB_FRA_USED="$REM_FRA_USED"; STB_FRA_RECLAIM="$REM_FRA_RECLAIM"; STB_FRA_FILES="$REM_FRA_FILES"
    STB_SERVICES="$REM_SERVICES"
    STB_HOST="${PEER_TNS:-unknown}"
else
    STB_ROLE="$LOC_ROLE";       STB_OPEN="$LOC_OPEN";       STB_PROTECT="$LOC_PROTECT"
    STB_SWITCH="$LOC_SWITCH";   STB_FORCE="$LOC_FORCE";     STB_FLASH="$LOC_FLASH"
    STB_DBUNIQ="$LOC_DBUNIQ"
    STB_REDO_CNT="$LOC_REDO_CNT"; STB_REDO_MB="$LOC_REDO_MB"; STB_SRL="$LOC_SRL"
    STB_ARCHGAP="$LOC_ARCHGAP"
    STB_MRP_STATUS="$LOC_MRP_STATUS"; STB_MRP_SEQ="$LOC_MRP_SEQ"
    STB_TRANSPORT_LAG="$LOC_TRANSPORT_LAG"; STB_APPLY_LAG="$LOC_APPLY_LAG"
    STB_LAST_APPLIED="$LOC_LAST_APPLIED"; STB_LAST_RECEIVED="$LOC_LAST_RECEIVED"
    STB_FRA_PATH="$LOC_FRA_PATH"; STB_FRA_SIZE="$LOC_FRA_SIZE"
    STB_FRA_USED="$LOC_FRA_USED"; STB_FRA_RECLAIM="$LOC_FRA_RECLAIM"; STB_FRA_FILES="$LOC_FRA_FILES"
    STB_SERVICES="$LOC_SERVICES"
    STB_HOST=$(short_hostname)

    PRI_ROLE="$REM_ROLE";       PRI_OPEN="$REM_OPEN";       PRI_PROTECT="$REM_PROTECT"
    PRI_SWITCH="$REM_SWITCH";   PRI_FORCE="$REM_FORCE";     PRI_FLASH="$REM_FLASH"
    PRI_DBUNIQ="${REM_DBUNIQ:-${PEER_DBUNIQ:-?}}"
    PRI_BROKER="${LOC_BROKER}"
    PRI_REDO_CNT="$REM_REDO_CNT"; PRI_REDO_MB="$REM_REDO_MB"; PRI_SRL="$REM_SRL"
    PRI_DEST2_STATUS=""; PRI_DEST2_ERROR=""
    PRI_ARCHGAP="$REM_ARCHGAP"
    PRI_FRA_PATH="$REM_FRA_PATH"; PRI_FRA_SIZE="$REM_FRA_SIZE"
    PRI_FRA_USED="$REM_FRA_USED"; PRI_FRA_RECLAIM="$REM_FRA_RECLAIM"; PRI_FRA_FILES="$REM_FRA_FILES"
    PRI_SERVICES="$REM_SERVICES"
    PRI_HOST="${PEER_TNS:-unknown}"
fi

# Helper: show a row or "n/a" when remote data is missing
row_or_na() {
    local label="$1" value="$2" status="${3:-}"
    if [[ -z "$value" ]]; then
        row "$label" "${DIM}n/a (no remote connection)${NC}"
    else
        row "$label" "$value" "$status"
    fi
}

# =============================================================================
# Display
# =============================================================================

# -- Title
printf "\n ${BOLD}${CYAN}Data Guard Status Check${NC}  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')${NC}\n"
printf " ${DIM}Local: $(short_hostname) (SID: ${ORACLE_SID}, role: ${LOC_LABEL})"
if [[ "$REMOTE_CONNECTED" == true ]]; then
    printf "  |  Remote: ${PEER_DBUNIQ} via ${PEER_TNS}"
elif [[ "$LOCAL_ONLY" == true ]]; then
    printf "  |  Remote: skipped (-L)"
else
    printf "  |  Remote: not connected"
fi
printf "${NC}\n"

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
if [[ -n "${PRI_ROLE:-}" ]]; then
    printf '%s' "$PRI_ROLE" | grep -qi "PRIMARY" || PRI_OK=false
    printf '%s' "${PRI_OPEN:-}" | grep -qi "READ WRITE" || PRI_OK=false
else
    PRI_OK=unknown
fi
if [[ -n "${STB_ROLE:-}" ]]; then
    printf '%s' "$STB_ROLE" | grep -qi "PHYSICAL STANDBY" || STB_OK=false
    if [[ -z "${STB_MRP_STATUS:-}" ]]; then
        STB_OK=false
    else
        printf '%s' "$STB_MRP_STATUS" | grep -qiE "APPLYING_LOG|WAIT_FOR_LOG" || STB_OK=false
    fi
else
    STB_OK=unknown
fi

if [[ "$PRI_OK" == true ]]; then PRI_DOT="${GREEN}●${NC}"
elif [[ "$PRI_OK" == false ]]; then PRI_DOT="${RED}●${NC}"
else PRI_DOT="${DIM}●${NC}"; fi

if [[ "$STB_OK" == true ]]; then STB_DOT="${GREEN}●${NC}"
elif [[ "$STB_OK" == false ]]; then STB_DOT="${RED}●${NC}"
else STB_DOT="${DIM}●${NC}"; fi

# Determine display values for summary
_PRI_MODE="${PRI_OPEN:-${DIM}(broker only)${NC}}"
_STB_MODE="${STB_OPEN:-${DIM}(broker only)${NC}}"
_STB_MRP="${STB_MRP_STATUS:-${DIM}n/a${NC}}"

printf '\n ┌%s┬%s┐\n' "$_BAR" "$_BAR"
box_row "${PRI_DOT} ${BOLD}PRIMARY${NC}" "${STB_DOT} ${BOLD}PHYSICAL STANDBY${NC}"
box_row "${PRI_DBUNIQ:-?}" "${STB_DBUNIQ:-?}"
box_row "$_PRI_MODE" "${_STB_MODE} / MRP: ${_STB_MRP}"
printf ' └%s┴%s┘\n' "$_BAR" "$_BAR"

# -- Primary Database ---------------------------------------------------------
header "PRIMARY DATABASE  (${PRI_DBUNIQ:-?})"

if [[ -n "${PRI_ROLE:-}" ]]; then
    subheader "Identity"

    icon=$(status_icon "$PRI_ROLE" "PRIMARY")
    [[ "$icon" == *"XX"* ]] && err
    row "Role" "$PRI_ROLE" "$icon"

    icon=$(status_icon "$PRI_OPEN" "READ WRITE")
    [[ "$icon" == *"XX"* ]] && err
    row "Open Mode" "$PRI_OPEN" "$icon"

    row "Protection Mode" "$PRI_PROTECT"

    icon=$(warn_icon "$PRI_SWITCH" "TO STANDBY" "SESSIONS ACTIVE")
    [[ "$icon" == *"!!"* ]] && warn
    row "Switchover Status" "$PRI_SWITCH" "$icon"

    icon=$(status_icon "$PRI_FORCE" "YES")
    [[ "$icon" == *"XX"* ]] && err
    row "Force Logging" "$PRI_FORCE" "$icon"

    icon=$(warn_icon "$PRI_FLASH" "YES")
    [[ "$icon" == *"!!"* ]] && warn
    row "Flashback" "$PRI_FLASH" "$icon"

    subheader "Services"

    icon=$(status_icon "${PRI_BROKER:-FALSE}" "TRUE")
    [[ "$icon" == *"XX"* ]] && err
    row "DG Broker" "${PRI_BROKER:-FALSE}" "$icon"
    row "Running Services" "${PRI_SERVICES:-NONE}"

    subheader "Redo / Archive"

    row "Online Redo Logs" "${PRI_REDO_CNT:-?} groups (${PRI_REDO_MB:-?} MB total)"
    if [[ -n "${PRI_SRL:-}" ]] && [[ "${PRI_SRL:-0}" -gt 0 ]]; then
        row "Standby Redo Logs" "${PRI_SRL} groups" "$CHK"
    else
        row "Standby Redo Logs" "${PRI_SRL:-NONE}" "$WARN"; warn
    fi

    if [[ "${PRI_DEST2_STATUS:-}" == "VALID" ]]; then
        row "Archive Dest 2 (Standby)" "$PRI_DEST2_STATUS" "$CHK"
    elif [[ -n "${PRI_DEST2_STATUS:-}" ]]; then
        row "Archive Dest 2 (Standby)" "${PRI_DEST2_STATUS} ${PRI_DEST2_ERROR:-}" "$FAIL"; err
    fi

    if [[ -n "${PRI_ARCHGAP:-}" ]] && [[ "${PRI_ARCHGAP:-0}" -gt 0 ]]; then
        row "Archive Gaps" "${PRI_ARCHGAP} gap(s)!" "$FAIL"; err
    fi

    subheader "Recovery Area"

    if [[ -n "${PRI_FRA_PATH:-}" ]]; then
        PRI_FRA_EFFECTIVE_USED=$(awk "BEGIN {effective=${PRI_FRA_USED:-0}-${PRI_FRA_RECLAIM:-0}; if (effective < 0) effective=0; printf \"%.1f\", effective}")
        PRI_FRA_PCT=$(awk "BEGIN {if (${PRI_FRA_SIZE:-0} > 0) {effective=${PRI_FRA_USED:-0}-${PRI_FRA_RECLAIM:-0}; if (effective < 0) effective=0; printf \"%.0f\", (effective/${PRI_FRA_SIZE})*100} else print 0}")
        if [[ "$PRI_FRA_PCT" -ge 90 ]]; then
            icon="$FAIL"; err
        elif [[ "$PRI_FRA_PCT" -ge 80 ]]; then
            icon="$WARN"; warn
        else
            icon="$CHK"
        fi
        row "FRA Usage" "${PRI_FRA_EFFECTIVE_USED}/${PRI_FRA_SIZE} GB effective (${PRI_FRA_PCT}%), reclaimable ${PRI_FRA_RECLAIM} GB" "$icon"
        row "FRA Location" "${PRI_FRA_PATH} (${PRI_FRA_FILES:-0} files)"
    fi
else
    # No remote SQL to primary - show what broker knows
    if [[ -n "${PEER_DBUNIQ:-}" ]] && [[ -n "$DGMGRL_PEER" ]]; then
        subheader "Broker View"

        PEER_ROLE=$(printf '%s\n' "$DGMGRL_PEER" | grep 'Role:' | sed 's/.*Role: *//' | xargs)
        PEER_STATE=$(printf '%s\n' "$DGMGRL_PEER" | grep 'Intended State:' | sed 's/.*Intended State: *//' | xargs)
        PEER_DB_STATUS=$(printf '%s\n' "$DGMGRL_PEER" | tail -3 | extract_first_status)

        row "Role" "${PEER_ROLE:-?}" "$(status_icon "${PEER_ROLE:-}" "PRIMARY")"
        row "Intended State" "${PEER_STATE:-?}"
        if [[ -n "${PEER_DB_STATUS:-}" ]]; then
            icon=$(status_icon "$PEER_DB_STATUS" "SUCCESS")
            [[ "$icon" == *"XX"* ]] && err
            row "Broker Status" "$PEER_DB_STATUS" "$icon"
        fi
        printf '%s\n' "$DGMGRL_PEER" | grep -i 'ORA-' | while IFS= read -r line; do
            line_trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
            printf "  ${DIM}%-24s${NC} ${RED}%s${NC}\n" "" "$line_trimmed"
        done
        printf "  ${DIM}%-24s${NC} ${DIM}%s${NC}\n" "" "(broker view only - use -P for full remote checks)"
    else
        printf "  ${DIM}%-24s${NC} ${DIM}%s${NC}\n" "" "n/a (no remote connection to primary)"
    fi
fi

# -- Standby Database ---------------------------------------------------------
header "STANDBY DATABASE  (${STB_DBUNIQ:-?})"

if [[ -n "${STB_ROLE:-}" ]]; then
    subheader "Identity"

    icon=$(status_icon "$STB_ROLE" "PHYSICAL STANDBY")
    [[ "$icon" == *"XX"* ]] && err
    row "Role" "$STB_ROLE" "$icon"

    icon=$(warn_icon "$STB_OPEN" "MOUNTED" "READ ONLY")
    [[ "$icon" == *"!!"* ]] && warn
    row "Open Mode" "$STB_OPEN" "$icon"

    row "Protection Mode" "${STB_PROTECT:-$LOC_PROTECT}"

    icon=$(warn_icon "$STB_SWITCH" "NOT ALLOWED" "SWITCHOVER PENDING")
    row "Switchover Status" "$STB_SWITCH" "$icon"

    subheader "Services"

    row "Running Services" "${STB_SERVICES:-NONE}"

    subheader "Recovery / Apply"

    # MRP
    if [[ -n "${STB_MRP_STATUS:-}" ]]; then
        icon=$(status_icon "$STB_MRP_STATUS" "APPLYING_LOG" "WAIT_FOR_LOG")
        [[ "$icon" == *"XX"* ]] && err
        row "MRP Status" "${STB_MRP_STATUS} (seq# ${STB_MRP_SEQ:-?})" "$icon"
    else
        row "MRP Status" "NOT RUNNING" "$FAIL"; err
    fi

    # Lag
    if [[ -n "${STB_TRANSPORT_LAG:-}" ]]; then
        if [[ "$STB_TRANSPORT_LAG" == "+00 00:00:00" ]] || [[ "$STB_TRANSPORT_LAG" == "0" ]]; then
            row "Transport Lag" "none" "$CHK"
        else
            row "Transport Lag" "$STB_TRANSPORT_LAG" "$WARN"; warn
        fi
    else
        row "Transport Lag" "N/A (standby mounted)"
    fi

    if [[ -n "${STB_APPLY_LAG:-}" ]]; then
        if [[ "$STB_APPLY_LAG" == "+00 00:00:00" ]] || [[ "$STB_APPLY_LAG" == "0" ]]; then
            row "Apply Lag" "none" "$CHK"
        else
            row "Apply Lag" "$STB_APPLY_LAG" "$WARN"; warn
        fi
    else
        row "Apply Lag" "N/A (standby mounted)"
    fi

    # Sequences
    if [[ -n "${STB_LAST_APPLIED:-}" ]] && [[ -n "${STB_LAST_RECEIVED:-}" ]] && [[ "${STB_LAST_RECEIVED:-0}" -gt 0 ]]; then
        SEQ_LAG=$((STB_LAST_RECEIVED - STB_LAST_APPLIED))
        if [[ "$SEQ_LAG" -le 1 ]]; then
            row "Sequences" "applied=${STB_LAST_APPLIED}  received=${STB_LAST_RECEIVED}" "$CHK"
        elif [[ "$SEQ_LAG" -le 5 ]]; then
            row "Sequences" "applied=${STB_LAST_APPLIED}  received=${STB_LAST_RECEIVED}  (lag: ${SEQ_LAG})" "$WARN"; warn
        else
            row "Sequences" "applied=${STB_LAST_APPLIED}  received=${STB_LAST_RECEIVED}  (lag: ${SEQ_LAG})" "$FAIL"; err
        fi
    fi

    subheader "Redo / Archive"

    if [[ -n "${STB_SRL:-}" ]] && [[ "${STB_SRL:-0}" -gt 0 ]]; then
        row "Standby Redo Logs" "${STB_SRL} groups" "$CHK"
    else
        row "Standby Redo Logs" "${STB_SRL:-NONE}" "$FAIL"; err
    fi

    if [[ -n "${STB_ARCHGAP:-}" ]] && [[ "${STB_ARCHGAP:-0}" -gt 0 ]]; then
        row "Archive Gaps" "${STB_ARCHGAP} gap(s)!" "$FAIL"; err
    fi

    subheader "Recovery Area"

    if [[ -n "${STB_FRA_PATH:-}" ]]; then
        STB_FRA_EFFECTIVE_USED=$(awk "BEGIN {effective=${STB_FRA_USED:-0}-${STB_FRA_RECLAIM:-0}; if (effective < 0) effective=0; printf \"%.1f\", effective}")
        STB_FRA_PCT=$(awk "BEGIN {if (${STB_FRA_SIZE:-0} > 0) {effective=${STB_FRA_USED:-0}-${STB_FRA_RECLAIM:-0}; if (effective < 0) effective=0; printf \"%.0f\", (effective/${STB_FRA_SIZE})*100} else print 0}")
        if [[ "$STB_FRA_PCT" -ge 90 ]]; then
            icon="$FAIL"; err
        elif [[ "$STB_FRA_PCT" -ge 80 ]]; then
            icon="$WARN"; warn
        else
            icon="$CHK"
        fi
        row "FRA Usage" "${STB_FRA_EFFECTIVE_USED}/${STB_FRA_SIZE} GB effective (${STB_FRA_PCT}%), reclaimable ${STB_FRA_RECLAIM} GB" "$icon"
        row "FRA Location" "${STB_FRA_PATH} (${STB_FRA_FILES:-0} files)"
    fi
else
    # No remote SQL - show what broker knows
    if [[ -n "${PEER_DBUNIQ:-}" ]] && [[ -n "$DGMGRL_PEER" ]]; then
        subheader "Broker View"

        PEER_ROLE=$(printf '%s\n' "$DGMGRL_PEER" | grep 'Role:' | sed 's/.*Role: *//' | xargs)
        PEER_STATE=$(printf '%s\n' "$DGMGRL_PEER" | grep 'Intended State:' | sed 's/.*Intended State: *//' | xargs)
        PEER_TLAG=$(printf '%s\n' "$DGMGRL_PEER" | grep 'Transport Lag:' | sed 's/.*Transport Lag: *//' | xargs)
        PEER_ALAG=$(printf '%s\n' "$DGMGRL_PEER" | grep 'Apply Lag:' | sed 's/.*Apply Lag: *//' | xargs)
        PEER_DB_STATUS=$(printf '%s\n' "$DGMGRL_PEER" | tail -3 | extract_first_status)

        row "Role" "${PEER_ROLE:-?}" "$(status_icon "${PEER_ROLE:-}" "PHYSICAL STANDBY" "PRIMARY")"
        row "Intended State" "${PEER_STATE:-?}"
        row "Transport Lag" "${PEER_TLAG:-?}"
        row "Apply Lag" "${PEER_ALAG:-?}"
        if [[ -n "${PEER_DB_STATUS:-}" ]]; then
            icon=$(status_icon "$PEER_DB_STATUS" "SUCCESS")
            [[ "$icon" == *"XX"* ]] && err
            row "Broker Status" "$PEER_DB_STATUS" "$icon"
        fi
        # Show warnings/errors from broker
        printf '%s\n' "$DGMGRL_PEER" | grep -i 'ORA-' | while IFS= read -r line; do
            line_trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
            printf "  ${DIM}%-24s${NC} ${RED}%s${NC}\n" "" "$line_trimmed"
        done
        printf "  ${DIM}%-24s${NC} ${DIM}%s${NC}\n" "" "(broker view only - use -P for full remote checks)"
    else
        printf "  ${DIM}%-24s${NC} ${DIM}%s${NC}\n" "" "n/a (no remote connection to ${PEER_LABEL,,})"
    fi
fi

# -- Broker Configuration ----------------------------------------------------
header "DATA GUARD BROKER"

if printf '%s' "$DGMGRL_CONFIG" | grep -q "ORA-16532\|not yet available\|not exist"; then
    row "Configuration" "NOT CONFIGURED" "$FAIL"; err
else
    row "Configuration" "${BROKER_CFG_NAME:-unknown}"

    if [[ -n "${BROKER_OVERALL:-}" ]]; then
        icon=$(status_icon "$BROKER_OVERALL" "SUCCESS")
        [[ "$icon" == *"XX"* ]] && err
        row "Overall Status" "$BROKER_OVERALL" "$icon"
    fi

    # Show members and their ORA errors/warnings
    while IFS= read -r line; do
        line_trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
        if printf '%s' "$line" | grep -qE '^\s+\S+\s+-\s+'; then
            if printf '%s' "$line_trimmed" | grep -qi "Error"; then
                row "" "$line_trimmed" "$FAIL"
            elif printf '%s' "$line_trimmed" | grep -qi "Warning"; then
                row "" "$line_trimmed" "$WARN"
            else
                row "" "$line_trimmed" "$CHK"
            fi
        elif printf '%s' "$line" | grep -qi 'ORA-'; then
            printf "  ${DIM}%-24s${NC} ${RED}%s${NC}\n" "" "$line_trimmed"
        fi
    done <<< "$DGMGRL_CONFIG"

    # FSFO
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
        fi
    fi
fi

# -- Recent Alert Log (DG-related) --------------------------------------------
header "RECENT ALERT LOG (Data Guard)"

_show_alert_entries() {
    local label="$1" entries="$2"
    if [[ -z "$entries" ]]; then
        printf "  ${DIM}%-24s${NC} ${DIM}%s${NC}\n" "$label" "No recent DG-related entries"
    else
        local first=true
        while IFS= read -r line; do
            # Format: "YYYY-MM-DD HH:MM:SS  message" or just "message" (no timestamp)
            local ts="" msg="$line"
            if printf '%s' "$line" | grep -q '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] '; then
                ts="${line:0:19}"
                msg="${line:21}"
            fi
            local display_label=""
            if $first; then display_label="$label"; first=false; fi
            if printf '%s' "$msg" | grep -qiE 'ORA-|error|fail'; then
                if [[ -n "$ts" ]]; then
                    printf "  ${DIM}%-24s${NC} ${DIM}%s${NC}  ${RED}%s${NC}\n" "$display_label" "$ts" "$msg"
                else
                    printf "  ${DIM}%-24s${NC} ${RED}%s${NC}\n" "$display_label" "$msg"
                fi
            else
                if [[ -n "$ts" ]]; then
                    printf "  ${DIM}%-24s${NC} ${DIM}%s${NC}  %s\n" "$display_label" "$ts" "$msg"
                else
                    printf "  ${DIM}%-24s${NC} %s\n" "$display_label" "$msg"
                fi
            fi
        done <<< "$entries"
    fi
}

subheader "Local ($(short_hostname) / ${ORACLE_SID})"
_show_alert_entries "Alert Log" "$LOC_ALERT_ENTRIES"
_show_alert_entries "Broker Log" "$LOC_DRC_ENTRIES"

# =============================================================================
# Summary
# =============================================================================
printf "\n ${DIM}%s${NC}\n" "$HLINE"

if [[ $ERRORS -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
    printf " ${BOLD}${GREEN} HEALTHY${NC}  ${DIM}No issues detected${NC}\n"
elif [[ $ERRORS -eq 0 ]]; then
    printf " ${BOLD}${YELLOW} WARNING${NC}  ${DIM}${WARNINGS} warning(s)${NC}\n"
else
    printf " ${BOLD}${RED} ISSUES ${NC}  ${RED}${ERRORS} error(s)${NC}"
    [[ $WARNINGS -gt 0 ]] && printf "  ${YELLOW}${WARNINGS} warning(s)${NC}"
    printf "\n"
fi

printf "\n"
