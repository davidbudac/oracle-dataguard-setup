#!/bin/bash
# ============================================================
# Data Guard Handoff Report - Standalone
# ============================================================
# Generates a Markdown handoff document for an existing Data
# Guard configuration. Unlike primary/10_generate_handoff_report.sh,
# this script does NOT rely on the setup-time standby_config_*.env
# file or the NFS share - it discovers the topology from the
# database itself via SQL*Plus and DGMGRL.
#
# Run on the PRIMARY host with:
#   - ORACLE_SID and ORACLE_HOME set
#   - sqlplus '/ as sysdba' working
#   - dgmgrl available (broker should be started for full topology
#     discovery; otherwise pass hostnames via flags)
#
# Usage:
#   ./dg_handoff.sh
#   ./dg_handoff.sh -o /tmp/handoff.md
#   ./dg_handoff.sh --primary-host pri.example.com \
#                   --standby-host stb.example.com \
#                   --port 1521
# ============================================================

set -e
set -o pipefail

OUTPUT_FILE=""
PRIMARY_HOST_OVERRIDE=""
STANDBY_HOST_OVERRIDE=""
PORT_OVERRIDE=""
DB_DOMAIN=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Generates a Data Guard handoff report against the database currently
identified by \$ORACLE_SID, connecting via 'sqlplus / as sysdba'.

Options:
  -o, --output FILE         Output Markdown file (default: ./dg_handoff_<DB>.md)
      --primary-host HOST   Override primary hostname in connect strings
      --standby-host HOST   Override standby hostname in connect strings
      --port PORT           Override listener port (default: discover or 1521)
      --domain DOMAIN       DB domain to append to default service name
  -h, --help                Show this help

Topology (DB_UNIQUE_NAMEs, peer hostnames, listener ports) is discovered from
V\$DATABASE, V\$DATAGUARD_CONFIG, V\$LISTENER_NETWORK and DGMGRL SHOW DATABASE.
Use the --*-host / --port flags when broker is not started or discovery
returns the wrong value.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)        OUTPUT_FILE="$2"; shift 2 ;;
        --primary-host)     PRIMARY_HOST_OVERRIDE="$2"; shift 2 ;;
        --standby-host)     STANDBY_HOST_OVERRIDE="$2"; shift 2 ;;
        --port)             PORT_OVERRIDE="$2"; shift 2 ;;
        --domain)           DB_DOMAIN="$2"; shift 2 ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ============================================================
# Pre-flight
# ============================================================

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }
info() { echo "INFO:  $*" >&2; }

[[ -n "$ORACLE_SID" ]]  || die "ORACLE_SID is not set."
[[ -n "$ORACLE_HOME" ]] || die "ORACLE_HOME is not set."
command -v sqlplus >/dev/null || die "sqlplus not on PATH ($ORACLE_HOME/bin/sqlplus expected)."

# ============================================================
# SQL helpers (inlined - no external SQL files)
# ============================================================

run_sql() {
    # Pipe SQL to sqlplus / as sysdba and strip whitespace from each line
    local sql="$1"
    sqlplus -s -L / as sysdba <<EOF 2>/dev/null
SET HEADING OFF FEEDBACK OFF VERIFY OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
WHENEVER SQLERROR EXIT 1
${sql}
EXIT;
EOF
}

clean() { tr -d ' \r' | sed '/^$/d'; }
field()  { awk -F'|' -v i="$2" '{print $i}' <<< "$1"; }

run_dgmgrl_cmd() {
    # Pipe a single command to dgmgrl /
    local cmd="$1"
    "$ORACLE_HOME/bin/dgmgrl" -silent / <<EOF 2>&1
${cmd}
EXIT;
EOF
}

# ============================================================
# Connectivity check
# ============================================================

if ! run_sql "SELECT 'OK' FROM DUAL;" | clean | grep -q '^OK$'; then
    die "Could not connect via 'sqlplus / as sysdba' (ORACLE_SID=${ORACLE_SID})."
fi

# ============================================================
# Discover topology
# ============================================================

info "Discovering Data Guard topology from ${ORACLE_SID}..."

LOCAL_DB_UNIQUE_NAME=$(run_sql "SELECT DB_UNIQUE_NAME FROM V\$DATABASE;" | clean | head -1)
[[ -n "$LOCAL_DB_UNIQUE_NAME" ]] || die "Could not read local DB_UNIQUE_NAME."

DB_STATUS=$(run_sql "SELECT DATABASE_ROLE||'|'||OPEN_MODE||'|'||PROTECTION_MODE||'|'||SWITCHOVER_STATUS FROM V\$DATABASE;" | clean | head -1)
DB_ROLE=$(field          "$DB_STATUS" 1)
OPEN_MODE=$(field        "$DB_STATUS" 2)
PROTECTION_MODE=$(field  "$DB_STATUS" 3)
SWITCHOVER_STATUS=$(field "$DB_STATUS" 4)

FORCE_LOGGING=$(run_sql "SELECT FORCE_LOGGING FROM V\$DATABASE;" | clean | head -1)
DG_BROKER_START=$(run_sql "SELECT VALUE FROM V\$PARAMETER WHERE NAME='dg_broker_start';" | clean | head -1)

# Peer DB_UNIQUE_NAME from V$DATAGUARD_CONFIG (everything except local)
PEER_DB_UNIQUE_NAME=$(run_sql "SELECT DB_UNIQUE_NAME FROM V\$DATAGUARD_CONFIG WHERE DB_UNIQUE_NAME <> '${LOCAL_DB_UNIQUE_NAME}' AND ROWNUM=1;" | clean | head -1)

if [[ -z "$PEER_DB_UNIQUE_NAME" ]]; then
    warn "No peer found in V\$DATAGUARD_CONFIG. Report will be primary-only."
fi

# Decide which side is primary/standby for naming purposes
if [[ "$DB_ROLE" == "PRIMARY" ]]; then
    PRIMARY_DB_UNIQUE_NAME="$LOCAL_DB_UNIQUE_NAME"
    STANDBY_DB_UNIQUE_NAME="$PEER_DB_UNIQUE_NAME"
else
    warn "Local role is ${DB_ROLE} (not PRIMARY). Treating local as standby for the report."
    PRIMARY_DB_UNIQUE_NAME="$PEER_DB_UNIQUE_NAME"
    STANDBY_DB_UNIQUE_NAME="$LOCAL_DB_UNIQUE_NAME"
fi

# Apply/gap info (only meaningful on primary or standby with archive history)
APPLY_INFO=$(run_sql "SELECT NVL(MAX(CASE WHEN APPLIED='YES' THEN SEQUENCE# END),0)||'|'||NVL(MAX(SEQUENCE#),0) FROM V\$ARCHIVED_LOG WHERE THREAD#=1;" | clean | head -1)
LAST_APPLIED=$(field  "$APPLY_INFO" 1)
LAST_RECEIVED=$(field "$APPLY_INFO" 2)
APPLY_LAG_SEQ=$(( ${LAST_RECEIVED:-0} - ${LAST_APPLIED:-0} ))

GAP_COUNT=$(run_sql "SELECT COUNT(*) FROM V\$ARCHIVE_GAP;" | clean | head -1)
GAP_COUNT="${GAP_COUNT:-0}"

# FSFO
FSFO_RAW=$(run_sql "SELECT FS_FAILOVER_STATUS||'|'||FS_FAILOVER_OBSERVER_PRESENT||'|'||FS_FAILOVER_OBSERVER_HOST FROM V\$DATABASE;" | clean | head -1)
FSFO_STATUS=$(field        "$FSFO_RAW" 1)
FSFO_OBSERVER=$(field      "$FSFO_RAW" 2)
FSFO_OBSERVER_HOST=$(field "$FSFO_RAW" 3)

# Listener port from V$LISTENER_NETWORK / local_listener
LOCAL_LISTENER_RAW=$(run_sql "SELECT VALUE FROM V\$LISTENER_NETWORK WHERE TYPE='LOCAL LISTENER' AND ROWNUM=1;" | clean | head -1)
DISCOVERED_PORT=$(echo "$LOCAL_LISTENER_RAW" | grep -oE 'PORT *= *[0-9]+' | head -1 | grep -oE '[0-9]+')
PORT="${PORT_OVERRIDE:-${DISCOVERED_PORT:-1521}}"

# ============================================================
# Discover hostnames via DGMGRL (best-effort)
# ============================================================

PRIMARY_HOSTNAME=""
STANDBY_HOSTNAME=""
BROKER_OUTPUT=""

if [[ "$DG_BROKER_START" == "TRUE" ]]; then
    BROKER_OUTPUT=$(run_dgmgrl_cmd "SHOW CONFIGURATION;" || true)

    extract_host_from_show_db() {
        # SHOW DATABASE VERBOSE prints a "DGConnectIdentifier = '...'" line.
        # That value is either an easy-connect string (host:port/service) or
        # a TNS alias. Extract the first hostname-looking token.
        local db="$1" out
        out=$(run_dgmgrl_cmd "SHOW DATABASE VERBOSE '${db}';" 2>/dev/null || true)
        # Try DGConnectIdentifier easy-connect form
        local dgci
        dgci=$(echo "$out" | grep -i "DGConnectIdentifier" | head -1 | sed -E "s/.*=\s*'?([^']*)'?\s*$/\1/")
        if [[ "$dgci" =~ ^([A-Za-z0-9._-]+)(:[0-9]+)?(/.*)?$ ]] && [[ "$dgci" == *.* || "$dgci" == *:* || "$dgci" == */* ]]; then
            echo "${BASH_REMATCH[1]}"
            return
        fi
        # Fallback: parse "Host Name:" or "(HOST = ...)" lines
        echo "$out" | grep -iE "Host Name|HOST *=" | head -1 | \
            sed -E "s/.*[Hh]ost *[Nn]ame[: ]*//; s/.*HOST *= *([A-Za-z0-9._-]+).*/\1/" | tr -d ' '
    }

    [[ -n "$PRIMARY_DB_UNIQUE_NAME" ]] && PRIMARY_HOSTNAME=$(extract_host_from_show_db "$PRIMARY_DB_UNIQUE_NAME")
    [[ -n "$STANDBY_DB_UNIQUE_NAME" ]] && STANDBY_HOSTNAME=$(extract_host_from_show_db "$STANDBY_DB_UNIQUE_NAME")
else
    warn "DG broker is not started (dg_broker_start=${DG_BROKER_START:-FALSE}); cannot auto-discover peer hostname."
fi

# Local hostname from OS as fallback for the local side
OS_HOSTNAME=$(hostname 2>/dev/null)
if [[ "$DB_ROLE" == "PRIMARY" ]]; then
    [[ -z "$PRIMARY_HOSTNAME" ]] && PRIMARY_HOSTNAME="$OS_HOSTNAME"
else
    [[ -z "$STANDBY_HOSTNAME" ]] && STANDBY_HOSTNAME="$OS_HOSTNAME"
fi

# Apply explicit overrides
[[ -n "$PRIMARY_HOST_OVERRIDE" ]] && PRIMARY_HOSTNAME="$PRIMARY_HOST_OVERRIDE"
[[ -n "$STANDBY_HOST_OVERRIDE" ]] && STANDBY_HOSTNAME="$STANDBY_HOST_OVERRIDE"

if [[ -z "$PRIMARY_HOSTNAME" ]]; then
    die "Primary hostname could not be determined. Pass --primary-host."
fi
if [[ -z "$STANDBY_HOSTNAME" && -n "$STANDBY_DB_UNIQUE_NAME" ]]; then
    warn "Standby hostname could not be determined; standby/role-aware connect strings will be omitted. Pass --standby-host to include them."
fi

# ============================================================
# Discover services
# ============================================================

SERVICE_OUTPUT=$(run_sql "
SELECT NAME FROM V\$ACTIVE_SERVICES
WHERE NAME NOT IN (
    SELECT DB_UNIQUE_NAME FROM V\$DATABASE
    UNION ALL SELECT NAME FROM V\$DATABASE
    UNION ALL SELECT INSTANCE_NAME FROM V\$INSTANCE
)
AND NAME NOT LIKE 'SYS\$%'
AND UPPER(NAME) NOT LIKE '%XDB%'
ORDER BY NAME;
" | clean)

SERVICE_LIST=()
while IFS= read -r line; do
    [[ -n "$line" ]] && SERVICE_LIST+=("$line")
done <<< "$SERVICE_OUTPUT"

DEFAULT_SVC="$PRIMARY_DB_UNIQUE_NAME"
[[ -n "$DB_DOMAIN" ]] && DEFAULT_SVC="${PRIMARY_DB_UNIQUE_NAME}.${DB_DOMAIN}"

found_default=0
for s in "${SERVICE_LIST[@]}"; do
    [[ "$s" == "$DEFAULT_SVC" ]] && found_default=1
done
if [[ $found_default -eq 0 ]]; then
    SERVICE_LIST=("$DEFAULT_SVC" "${SERVICE_LIST[@]}")
fi

info "Services in report: ${SERVICE_LIST[*]}"

# ============================================================
# Renderers (same shape as the setup-time script)
# ============================================================

render_tns_single() {
    local alias="$1" host="$2" port="$3" service="$4"
    cat <<EOF
${alias} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${host})(PORT = ${port}))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${service})
    )
  )
EOF
}

render_tns_ha() {
    local alias="$1" phost="$2" shost="$3" port="$4" service="$5"
    cat <<EOF
${alias} =
  (DESCRIPTION =
    (CONNECT_TIMEOUT = 10)(RETRY_COUNT = 3)(RETRY_DELAY = 3)
    (ADDRESS_LIST =
      (LOAD_BALANCE = OFF)
      (ADDRESS = (PROTOCOL = TCP)(HOST = ${phost})(PORT = ${port}))
      (ADDRESS = (PROTOCOL = TCP)(HOST = ${shost})(PORT = ${port}))
    )
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${service})
      (FAILOVER_MODE = (TYPE = SELECT)(METHOD = BASIC)(RETRIES = 30)(DELAY = 5))
    )
  )
EOF
}

render_jdbc_single() {
    echo "jdbc:oracle:thin:@//$1:$2/$3"
}

render_jdbc_ha() {
    local phost="$1" shost="$2" port="$3" service="$4"
    printf 'jdbc:oracle:thin:@(DESCRIPTION=(CONNECT_TIMEOUT=10)(RETRY_COUNT=3)(RETRY_DELAY=3)(ADDRESS_LIST=(LOAD_BALANCE=OFF)(ADDRESS=(PROTOCOL=TCP)(HOST=%s)(PORT=%s))(ADDRESS=(PROTOCOL=TCP)(HOST=%s)(PORT=%s)))(CONNECT_DATA=(SERVICE_NAME=%s)(FAILOVER_MODE=(TYPE=SELECT)(METHOD=BASIC)(RETRIES=30)(DELAY=5))))\n' \
        "$phost" "$port" "$shost" "$port" "$service"
}

# ============================================================
# Verdict
# ============================================================

VERDICT="HEALTHY"
VERDICT_NOTES=()
if [[ "$DB_ROLE" != "PRIMARY" ]]; then
    VERDICT="WARNING"
    VERDICT_NOTES+=("Local role is ${DB_ROLE}, expected PRIMARY")
fi
if [[ "${GAP_COUNT}" -gt 0 ]]; then
    VERDICT="ERROR"
    VERDICT_NOTES+=("${GAP_COUNT} archive gap(s) detected")
fi
if [[ "$DG_BROKER_START" != "TRUE" ]]; then
    VERDICT="WARNING"
    VERDICT_NOTES+=("Data Guard Broker is not started")
fi

# ============================================================
# Render report
# ============================================================

if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="./dg_handoff_${PRIMARY_DB_UNIQUE_NAME:-${LOCAL_DB_UNIQUE_NAME}}.md"
fi

GEN_DATE=$(date)
GEN_HOST=$(hostname 2>/dev/null)

{
    echo "# Data Guard Handoff Report"
    echo ""
    echo "- **Generated:** ${GEN_DATE}"
    echo "- **Generated on:** ${GEN_HOST}"
    if [[ -n "$STANDBY_DB_UNIQUE_NAME" ]]; then
        echo "- **Configuration:** ${PRIMARY_DB_UNIQUE_NAME} → ${STANDBY_DB_UNIQUE_NAME}"
    else
        echo "- **Configuration:** ${PRIMARY_DB_UNIQUE_NAME} (no peer detected)"
    fi
    echo ""
    echo "## 1. Topology"
    echo ""
    echo "| Role    | DB_UNIQUE_NAME              | Hostname              | Listener |"
    echo "|---------|-----------------------------|-----------------------|----------|"
    echo "| Primary | ${PRIMARY_DB_UNIQUE_NAME}   | ${PRIMARY_HOSTNAME}   | ${PORT}  |"
    if [[ -n "$STANDBY_DB_UNIQUE_NAME" ]]; then
        echo "| Standby | ${STANDBY_DB_UNIQUE_NAME}   | ${STANDBY_HOSTNAME:-UNKNOWN} | ${PORT}  |"
    fi
    echo ""
    echo "## 2. Status Snapshot"
    echo ""
    echo "| Item                  | Value |"
    echo "|-----------------------|-------|"
    echo "| Local role            | ${DB_ROLE} |"
    echo "| Open mode             | ${OPEN_MODE} |"
    echo "| Protection mode       | ${PROTECTION_MODE} |"
    echo "| Switchover status     | ${SWITCHOVER_STATUS} |"
    echo "| Force logging         | ${FORCE_LOGGING} |"
    echo "| Broker started        | ${DG_BROKER_START} |"
    echo "| Last received seq#    | ${LAST_RECEIVED:-N/A} |"
    echo "| Last applied seq#     | ${LAST_APPLIED:-N/A} |"
    echo "| Apply lag (sequences) | ${APPLY_LAG_SEQ} |"
    echo "| Archive gaps          | ${GAP_COUNT} |"
    echo "| FSFO status           | ${FSFO_STATUS:-N/A} |"
    echo "| FSFO observer present | ${FSFO_OBSERVER:-N/A} |"
    if [[ -n "$FSFO_OBSERVER_HOST" ]]; then
        echo "| FSFO observer host    | ${FSFO_OBSERVER_HOST} |"
    fi
    echo ""
    echo "**Verdict:** ${VERDICT}"
    if [[ ${#VERDICT_NOTES[@]} -gt 0 ]]; then
        for n in "${VERDICT_NOTES[@]}"; do echo "- ${n}"; done
    fi

    if [[ -n "$BROKER_OUTPUT" ]]; then
        echo ""
        echo "### Broker Configuration"
        echo ""
        echo '```'
        echo "$BROKER_OUTPUT"
        echo '```'
    fi

    echo ""
    echo "## 3. Connection Strings"
    echo ""
    echo "Three flavors are provided per service:"
    echo ""
    echo "- **Primary-only** — points directly at the primary host. Use for"
    echo "  workloads that must always hit the primary (writes, admin)."
    echo "- **Standby-only** — points directly at the standby host. Use for"
    echo "  read-only reporting workloads against an open standby."
    echo "- **Role-aware (failover)** — single descriptor with both hosts. Best"
    echo "  for the application tier *when a role-aware service trigger is"
    echo "  deployed*: the service is only up on whichever side is primary, so"
    echo "  clients automatically follow the active database after a switchover"
    echo "  or failover."
    echo ""

    for svc in "${SERVICE_LIST[@]}"; do
        local_safe=$(echo "$svc" | tr '.' '_' | tr '[:lower:]' '[:upper:]')
        ALIAS_PRI="${local_safe}_PRIMARY"
        ALIAS_STB="${local_safe}_STANDBY"
        ALIAS_HA="${local_safe}_HA"

        echo "### Service: \`${svc}\`"
        echo ""
        echo "#### Primary-only"
        echo ""
        echo '```'
        render_tns_single "$ALIAS_PRI" "$PRIMARY_HOSTNAME" "$PORT" "$svc"
        echo '```'
        echo ""
        echo '```'
        echo "JDBC: $(render_jdbc_single "$PRIMARY_HOSTNAME" "$PORT" "$svc")"
        echo '```'
        echo ""

        if [[ -n "$STANDBY_HOSTNAME" ]]; then
            echo "#### Standby-only"
            echo ""
            echo '```'
            render_tns_single "$ALIAS_STB" "$STANDBY_HOSTNAME" "$PORT" "$svc"
            echo '```'
            echo ""
            echo '```'
            echo "JDBC: $(render_jdbc_single "$STANDBY_HOSTNAME" "$PORT" "$svc")"
            echo '```'
            echo ""
            echo "#### Role-aware (failover)"
            echo ""
            echo '```'
            render_tns_ha "$ALIAS_HA" "$PRIMARY_HOSTNAME" "$STANDBY_HOSTNAME" "$PORT" "$svc"
            echo '```'
            echo ""
            echo '```'
            echo "JDBC: $(render_jdbc_ha "$PRIMARY_HOSTNAME" "$STANDBY_HOSTNAME" "$PORT" "$svc")"
            echo '```'
            echo ""
        fi
    done

    echo "## 4. Notes for Client Teams"
    echo ""
    echo "- The role-aware descriptor relies on the service being **stopped on"
    echo "  the standby**. Without a role-aware service trigger, clients may"
    echo "  attach to a read-only standby and receive ORA-16000 on writes."
    echo "- TAF settings (\`FAILOVER_MODE\`) reconnect *select* cursors after a"
    echo "  failover. Active transactions still need application-level retry."
    echo "- After a switchover, the primary/standby hostnames swap at the"
    echo "  database layer; the role-aware descriptor keeps working unchanged."
    echo ""
    echo "## 5. Quick Verification"
    echo ""
    echo '```bash'
    echo "sqlplus app_user/<pwd>@${SERVICE_LIST[0]}"
    echo '```'
    echo ""
} > "$OUTPUT_FILE"

info "Report written: $OUTPUT_FILE"
echo ""
cat "$OUTPUT_FILE"
echo ""
info "Verdict: ${VERDICT}  |  Apply lag: ${APPLY_LAG_SEQ}  |  Gaps: ${GAP_COUNT}  |  Services: ${#SERVICE_LIST[@]}"

case "$VERDICT" in
    ERROR)   exit 1 ;;
    *)       exit 0 ;;
esac
