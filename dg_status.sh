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
# Exit codes:
#   0   All checks passed (may have warnings)
#   N   Number of errors detected
#
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Colors & symbols --------------------------------------------------------
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';   BOLD='\033[1m'
DIM='\033[2m';       NC='\033[0m'
CHK="${GREEN}OK${NC}"; WARN="${YELLOW}!!${NC}"; FAIL="${RED}XX${NC}"

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
_CURRENT_HOST=$(hostname -s 2>/dev/null || hostname)
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
row() {
    local label="$1" value="$2" status="${3:-}"
    printf "  ${DIM}%-24s${NC} %-36s %b\n" "$label" "$value" "$status"
}

header() {
    printf "\n ${BOLD}${BLUE}%-60s${NC}\n" "$1"
    printf " ${DIM}────────────────────────────────────────────────────────────${NC}\n"
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
TMP=$(mktemp -d)
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
EXIT;
SQL" > "$TMP/standby_sql" &

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

# -- Parse DGMGRL output -----------------------------------------------------
DGMGRL_CONFIG=$(cat "$TMP/dgmgrl_config")
DGMGRL_FSFO=$(cat "$TMP/dgmgrl_fsfo" 2>/dev/null)

BROKER_CFG_NAME=$(printf '%s\n' "$DGMGRL_CONFIG" | grep 'Configuration -' | sed 's/.*Configuration - //' | xargs)
BROKER_OVERALL=$(printf '%s\n' "$DGMGRL_CONFIG" | tail -5 | grep -oE '(SUCCESS|WARNING|ERROR)' | head -1)

# =============================================================================
# Display
# =============================================================================

# -- Primary Database ---------------------------------------------------------
header "PRIMARY DATABASE  (${PRIMARY_ORACLE_HOSTNAME} / ${PRI_DBUNIQ:-?})"

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

icon=$(status_icon "${PRI_BROKER:-FALSE}" "TRUE")
[[ "$icon" == *"XX"* ]] && err
row "DG Broker" "${PRI_BROKER:-FALSE}" "$icon"

row "Online Redo Logs" "${PRI_REDO_CNT:-?} groups (${PRI_REDO_MB:-?} MB total)"
if [[ -n "${PRI_SRL:-}" ]] && [[ "${PRI_SRL:-0}" -gt 0 ]]; then
    row "Standby Redo Logs" "${PRI_SRL} groups" "$CHK"
else
    row "Standby Redo Logs" "NONE" "$WARN"; warn
fi

if [[ "${PRI_DEST2_STATUS:-}" == "VALID" ]]; then
    row "Archive Dest 2 (Standby)" "$PRI_DEST2_STATUS" "$CHK"
elif [[ -n "${PRI_DEST2_STATUS:-}" ]]; then
    row "Archive Dest 2 (Standby)" "${PRI_DEST2_STATUS} ${PRI_DEST2_ERROR:-}" "$FAIL"; err
fi

if [[ -n "${PRI_ARCHGAP:-}" ]] && [[ "${PRI_ARCHGAP:-0}" -gt 0 ]]; then
    row "Archive Gaps" "${PRI_ARCHGAP} gap(s)!" "$FAIL"; err
fi

if [[ -n "${PRI_FRA_PATH:-}" ]]; then
    PRI_FRA_PCT=$(awk "BEGIN {if (${PRI_FRA_SIZE:-0} > 0) printf \"%.0f\", (${PRI_FRA_USED:-0}/${PRI_FRA_SIZE})*100; else print 0}")
    if [[ "$PRI_FRA_PCT" -ge 90 ]]; then
        icon="$FAIL"; err
    elif [[ "$PRI_FRA_PCT" -ge 80 ]]; then
        icon="$WARN"; warn
    else
        icon="$CHK"
    fi
    row "FRA Usage" "${PRI_FRA_USED}/${PRI_FRA_SIZE} GB (${PRI_FRA_PCT}%), reclaimable ${PRI_FRA_RECLAIM} GB" "$icon"
    row "FRA Location" "${PRI_FRA_PATH} (${PRI_FRA_FILES:-0} files)"
fi

# -- Standby Database ---------------------------------------------------------
header "STANDBY DATABASE  (${STANDBY_ORACLE_HOSTNAME} / ${STB_DBUNIQ:-?})"

icon=$(status_icon "$STB_ROLE" "PHYSICAL STANDBY")
[[ "$icon" == *"XX"* ]] && err
row "Role" "$STB_ROLE" "$icon"

icon=$(warn_icon "$STB_OPEN" "MOUNTED" "READ ONLY")
[[ "$icon" == *"!!"* ]] && warn
row "Open Mode" "$STB_OPEN" "$icon"

row "Protection Mode" "$STB_PROTECT"

icon=$(warn_icon "$STB_SWITCH" "NOT ALLOWED" "SWITCHOVER PENDING")
row "Switchover Status" "$STB_SWITCH" "$icon"

# MRP (Managed Recovery Process)
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

# Sequence gap
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

if [[ -n "${STB_SRL:-}" ]] && [[ "${STB_SRL:-0}" -gt 0 ]]; then
    row "Standby Redo Logs" "${STB_SRL} groups" "$CHK"
else
    row "Standby Redo Logs" "NONE" "$FAIL"; err
fi

if [[ -n "${STB_ARCHGAP:-}" ]] && [[ "${STB_ARCHGAP:-0}" -gt 0 ]]; then
    row "Archive Gaps" "${STB_ARCHGAP} gap(s)!" "$FAIL"; err
fi

if [[ -n "${STB_FRA_PATH:-}" ]]; then
    STB_FRA_PCT=$(awk "BEGIN {if (${STB_FRA_SIZE:-0} > 0) printf \"%.0f\", (${STB_FRA_USED:-0}/${STB_FRA_SIZE})*100; else print 0}")
    if [[ "$STB_FRA_PCT" -ge 90 ]]; then
        icon="$FAIL"; err
    elif [[ "$STB_FRA_PCT" -ge 80 ]]; then
        icon="$WARN"; warn
    else
        icon="$CHK"
    fi
    row "FRA Usage" "${STB_FRA_USED}/${STB_FRA_SIZE} GB (${STB_FRA_PCT}%), reclaimable ${STB_FRA_RECLAIM} GB" "$icon"
    row "FRA Location" "${STB_FRA_PATH} (${STB_FRA_FILES:-0} files)"
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

    # Show members and their ORA errors/warnings from SHOW CONFIGURATION
    while IFS= read -r line; do
        line_trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
        if printf '%s' "$line" | grep -qE '^\s+\S+\s+-\s+'; then
            # Member line (e.g. "cdb1 - Primary database")
            if printf '%s' "$line_trimmed" | grep -qi "Error"; then
                row "" "$line_trimmed" "$FAIL"
            elif printf '%s' "$line_trimmed" | grep -qi "Warning"; then
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
        fi
    fi
fi

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

printf "\n"
exit $ERRORS
