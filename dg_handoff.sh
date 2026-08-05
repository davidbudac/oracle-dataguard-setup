#!/usr/bin/env bash
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
    # Heredoc supplies stdin (no terminal-hang risk). Do not discard stderr:
    # WHENEVER SQLERROR EXIT 1 keeps it silent when healthy, so any ORA- error
    # is surfaced rather than swallowed into a blank field in the report.
    sqlplus -s -L / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF VERIFY OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
WHENEVER SQLERROR EXIT 1
${sql}
EXIT;
EOF
}

clean() { tr -d ' \r' | sed '/^$/d'; }
field()  { awk -F'|' -v i="$2" '{print $i}' <<< "$1"; }

# ============================================================
# Discovery failure tracking
# ============================================================
# The initial connectivity check (below) is the only thing that should
# kill this script. Every discovery query after that point is
# best-effort: a single transient ORA- error must not abort the whole
# report. Each discovery site wraps its `run_sql` call as
# `VAR=$(run_sql ...) || VAR=""` (required because of `set -e` -
# an unwrapped failing command substitution assignment aborts the
# script), renders the missing field as "n/a", and records a note here
# so the report tells the reader what could not be discovered.
DISCOVERY_WARNINGS=()
note_discovery_failure() {
    local label="$1"
    warn "Discovery failed: ${label} (showing n/a in report)"
    DISCOVERY_WARNINGS+=("$label")
}

run_dgmgrl_cmd() {
    # Pipe a single command to dgmgrl /
    local cmd="$1"
    "$ORACLE_HOME/bin/dgmgrl" -silent / <<EOF 2>&1
${cmd}
EXIT;
EOF
}

parse_broker_property() {
    awk -F= '
        /[A-Za-z0-9_]+[[:space:]]*=/ {
            value=$2
            gsub(/^[[:space:]]*'\''?/, "", value)
            gsub(/'\''?[[:space:]]*$/, "", value)
            if (value != "") {
                print value
                exit
            }
        }
    '
}

extract_open_mode_from_broker() {
    awk -F: '
        {
            line=tolower($0)
        }
        line ~ /open[[:space:]]+mode/ {
            value=$2
            gsub(/^[[:space:]]*/, "", value)
            gsub(/[[:space:]]*$/, "", value)
            if (value != "") {
                print value
                exit
            }
        }
    '
}

extract_fsfo_threshold() {
    awk '
        {
            line=tolower($0)
        }
        line ~ /faststartfailoverthreshold/ || line ~ /fast-start failover threshold/ || line ~ /threshold/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9][0-9]*$/) {
                    print $i
                    exit
                }
            }
        }
    '
}

get_sqlnet_expire_time() {
    local sqlnet="${ORACLE_HOME}/network/admin/sqlnet.ora"
    if [[ ! -f "$sqlnet" ]]; then
        printf 'not set (sqlnet.ora not found)'
        return
    fi
    awk -F= '
        {
            line=tolower($1)
        }
        line ~ /^[[:space:]]*sqlnet[.]expire_time[[:space:]]*$/ {
            value=$2
            sub(/[[:space:]]*#.*/, "", value)
            gsub(/^[[:space:]]*/, "", value)
            gsub(/[[:space:]]*$/, "", value)
            if (value != "") {
                print value " minutes"
                found=1
                exit
            }
        }
        END {
            if (!found) {
                print "not set"
            }
        }
    ' "$sqlnet"
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

if ! LOCAL_DB_UNIQUE_NAME=$(run_sql "SELECT DB_UNIQUE_NAME FROM V\$DATABASE;" | clean | head -1); then
    LOCAL_DB_UNIQUE_NAME=""
    note_discovery_failure "local DB_UNIQUE_NAME"
fi
if [[ -z "$LOCAL_DB_UNIQUE_NAME" ]]; then
    LOCAL_DB_UNIQUE_NAME="$ORACLE_SID"
fi

if ! DB_STATUS=$(run_sql "SELECT DATABASE_ROLE||'|'||OPEN_MODE||'|'||PROTECTION_MODE||'|'||SWITCHOVER_STATUS FROM V\$DATABASE;" | clean | head -1); then
    DB_STATUS=""
    note_discovery_failure "database role/open-mode/protection-mode/switchover-status"
fi
DB_ROLE=$(field          "$DB_STATUS" 1)
OPEN_MODE=$(field        "$DB_STATUS" 2)
PROTECTION_MODE=$(field  "$DB_STATUS" 3)
SWITCHOVER_STATUS=$(field "$DB_STATUS" 4)

if ! FORCE_LOGGING=$(run_sql "SELECT FORCE_LOGGING FROM V\$DATABASE;" | clean | head -1); then
    FORCE_LOGGING=""
    note_discovery_failure "force logging status"
fi

if ! DG_BROKER_START=$(run_sql "SELECT VALUE FROM V\$PARAMETER WHERE NAME='dg_broker_start';" | clean | head -1); then
    DG_BROKER_START=""
    note_discovery_failure "dg_broker_start parameter"
fi

# Peer DB_UNIQUE_NAME from V$DATAGUARD_CONFIG (everything except local).
# An empty result here is a legitimate outcome (no peer registered yet), not
# necessarily a query failure, so it is reported via the existing warn()
# below rather than added to the discovery-failure list.
if ! PEER_DB_UNIQUE_NAME=$(run_sql "SELECT DB_UNIQUE_NAME FROM V\$DATAGUARD_CONFIG WHERE DB_UNIQUE_NAME <> '${LOCAL_DB_UNIQUE_NAME}' AND ROWNUM=1;" | clean | head -1); then
    PEER_DB_UNIQUE_NAME=""
    note_discovery_failure "peer DB_UNIQUE_NAME (V\$DATAGUARD_CONFIG)"
fi

if [[ -z "$PEER_DB_UNIQUE_NAME" ]]; then
    warn "No peer found in V\$DATAGUARD_CONFIG. Report will be primary-only."
fi

# Decide which side is primary/standby for naming purposes
if [[ "$DB_ROLE" == "PRIMARY" ]]; then
    PRIMARY_DB_UNIQUE_NAME="$LOCAL_DB_UNIQUE_NAME"
    STANDBY_DB_UNIQUE_NAME="$PEER_DB_UNIQUE_NAME"
else
    warn "Local role is ${DB_ROLE:-unknown} (not PRIMARY). Treating local as standby for the report."
    PRIMARY_DB_UNIQUE_NAME="$PEER_DB_UNIQUE_NAME"
    STANDBY_DB_UNIQUE_NAME="$LOCAL_DB_UNIQUE_NAME"
fi

# Apply/gap info (only meaningful on primary or standby with archive history)
if ! APPLY_INFO=$(run_sql "SELECT NVL(MAX(CASE WHEN APPLIED='YES' THEN SEQUENCE# END),0)||'|'||NVL(MAX(SEQUENCE#),0) FROM V\$ARCHIVED_LOG WHERE THREAD#=1;" | clean | head -1); then
    APPLY_INFO=""
    note_discovery_failure "archived log apply/receive sequence#"
fi
LAST_APPLIED=$(field  "$APPLY_INFO" 1)
LAST_RECEIVED=$(field "$APPLY_INFO" 2)
APPLY_LAG_SEQ=$(( ${LAST_RECEIVED:-0} - ${LAST_APPLIED:-0} ))

if ! GAP_COUNT=$(run_sql "SELECT COUNT(*) FROM V\$ARCHIVE_GAP;" | clean | head -1); then
    GAP_COUNT=""
    note_discovery_failure "archive gap count"
fi
GAP_COUNT="${GAP_COUNT:-0}"

# FSFO
if ! FSFO_RAW=$(run_sql "SELECT FS_FAILOVER_STATUS||'|'||FS_FAILOVER_OBSERVER_PRESENT||'|'||FS_FAILOVER_OBSERVER_HOST FROM V\$DATABASE;" | clean | head -1); then
    FSFO_RAW=""
    note_discovery_failure "fast-start failover status"
fi
FSFO_STATUS=$(field        "$FSFO_RAW" 1)
FSFO_OBSERVER=$(field      "$FSFO_RAW" 2)
FSFO_OBSERVER_HOST=$(field "$FSFO_RAW" 3)

if ! TRIGGER_STATUS=$(run_sql "
WITH pkg AS (
    SELECT owner
    FROM DBA_OBJECTS
    WHERE OBJECT_NAME = 'DG_SERVICE_MGR'
      AND OBJECT_TYPE IN ('PACKAGE', 'PACKAGE BODY')
      AND STATUS = 'VALID'
),
trg AS (
    SELECT owner, trigger_name, status
    FROM DBA_TRIGGERS
    WHERE trigger_name IN ('TRG_MANAGE_SERVICES_ROLE_CHG', 'TRG_MANAGE_SERVICES_STARTUP')
)
SELECT
    (SELECT COUNT(DISTINCT owner) FROM pkg) || '|' ||
    (SELECT COUNT(*) FROM trg WHERE status = 'ENABLED') || '|' ||
    (SELECT COUNT(*) FROM trg) || '|' ||
    NVL((SELECT LISTAGG(owner, ',') WITHIN GROUP (ORDER BY owner)
         FROM (SELECT DISTINCT owner FROM pkg
               UNION
               SELECT DISTINCT owner FROM trg)), 'NONE')
FROM DUAL;
" | clean | head -1); then
    TRIGGER_STATUS=""
    note_discovery_failure "role-aware service trigger status"
fi
TRIGGER_PACKAGE_COUNT=$(field "$TRIGGER_STATUS" 1)
TRIGGER_ENABLED_COUNT=$(field "$TRIGGER_STATUS" 2)
TRIGGER_TOTAL_COUNT=$(field "$TRIGGER_STATUS" 3)
TRIGGER_OWNERS=$(field "$TRIGGER_STATUS" 4)
ROLE_TRIGGER_READY="NO"
case "$TRIGGER_PACKAGE_COUNT" in ''|*[!0-9]*) TRIGGER_PACKAGE_COUNT=0 ;; esac
case "$TRIGGER_ENABLED_COUNT" in ''|*[!0-9]*) TRIGGER_ENABLED_COUNT=0 ;; esac
case "$TRIGGER_TOTAL_COUNT" in ''|*[!0-9]*) TRIGGER_TOTAL_COUNT=0 ;; esac
if [[ "$TRIGGER_PACKAGE_COUNT" -gt 0 && "$TRIGGER_ENABLED_COUNT" -ge 2 ]]; then
    ROLE_TRIGGER_READY="YES"
fi

# Listener port from V$LISTENER_NETWORK / local_listener. An empty result can
# be legitimate (no network registration recorded yet), so it falls back to
# the default port below without being counted as a discovery failure.
# AIX-portable: avoid GNU `grep -o`; use POSIX BRE sed to extract the port digits.
if ! LOCAL_LISTENER_RAW=$(run_sql "SELECT VALUE FROM V\$LISTENER_NETWORK WHERE TYPE='LOCAL LISTENER' AND ROWNUM=1;" | clean | head -1); then
    LOCAL_LISTENER_RAW=""
    note_discovery_failure "local listener port (V\$LISTENER_NETWORK)"
fi
DISCOVERED_PORT=$(echo "$LOCAL_LISTENER_RAW" | sed -n 's/.*PORT *= *\([0-9][0-9]*\).*/\1/p' | head -1)
PORT="${PORT_OVERRIDE:-${DISCOVERED_PORT:-1521}}"

# ============================================================
# Discover hostnames via DGMGRL (best-effort)
# ============================================================

PRIMARY_HOSTNAME=""
STANDBY_HOSTNAME=""
BROKER_OUTPUT=""
STANDBY_LOGXPTMODE="unknown"
STANDBY_OPEN_MODE="unknown"
FSFO_THRESHOLD="unknown"

if [[ "$DG_BROKER_START" == "TRUE" ]]; then
    BROKER_OUTPUT=$(run_dgmgrl_cmd "SHOW CONFIGURATION;" || true)

    extract_host_from_show_db() {
        # SHOW DATABASE VERBOSE prints a "DGConnectIdentifier = '...'" line.
        # That value is either an easy-connect string (host:port/service) or
        # a TNS alias. Extract the first hostname-looking token.
        # AIX-portable: avoid GNU regex extensions; use POSIX BRE
        # with [[:space:]] character classes and `\(...\)` capture groups.
        local db="$1" out
        out=$(run_dgmgrl_cmd "SHOW DATABASE VERBOSE '${db}';" 2>/dev/null || true)
        # Try DGConnectIdentifier easy-connect form
        local dgci
        dgci=$(echo "$out" | grep -i "DGConnectIdentifier" | head -1 \
            | sed -e "s/.*=[[:space:]]*//" \
                  -e "s/^'//" \
                  -e "s/'[[:space:]]*$//" \
                  -e "s/[[:space:]]*$//")
        if [[ "$dgci" =~ ^([A-Za-z0-9._-]+)(:[0-9]+)?(/.*)?$ ]] && [[ "$dgci" == *.* || "$dgci" == *:* || "$dgci" == */* ]]; then
            echo "${BASH_REMATCH[1]}"
            return
        fi
        # Fallback: parse "Host Name:" or "(HOST = ...)" lines
        echo "$out" | grep -i -E "Host Name|HOST *=" | head -1 \
            | sed -e "s/.*[Hh]ost *[Nn]ame[: ]*//" \
                  -e "s/.*HOST *= *\([A-Za-z0-9._-][A-Za-z0-9._-]*\).*/\1/" \
            | tr -d ' '
    }

    [[ -n "$PRIMARY_DB_UNIQUE_NAME" ]] && PRIMARY_HOSTNAME=$(extract_host_from_show_db "$PRIMARY_DB_UNIQUE_NAME")
    [[ -n "$STANDBY_DB_UNIQUE_NAME" ]] && STANDBY_HOSTNAME=$(extract_host_from_show_db "$STANDBY_DB_UNIQUE_NAME")
    if [[ -n "$STANDBY_DB_UNIQUE_NAME" ]]; then
        STANDBY_LOGXPTMODE=$(run_dgmgrl_cmd "SHOW DATABASE '${STANDBY_DB_UNIQUE_NAME}' 'LogXptMode';" | parse_broker_property || true)
        if [[ -z "$STANDBY_LOGXPTMODE" ]]; then
            STANDBY_LOGXPTMODE="unknown"
            note_discovery_failure "standby LogXptMode (broker)"
        fi
        STANDBY_SHOW_OUTPUT=$(run_dgmgrl_cmd "SHOW DATABASE '${STANDBY_DB_UNIQUE_NAME}';" || true)
        STANDBY_OPEN_MODE=$(printf '%s\n' "$STANDBY_SHOW_OUTPUT" | extract_open_mode_from_broker)
        if [[ -z "$STANDBY_OPEN_MODE" ]]; then
            STANDBY_OPEN_MODE="unknown"
            note_discovery_failure "standby open mode (broker)"
        fi
    fi
    if [[ -n "$PRIMARY_DB_UNIQUE_NAME" ]]; then
        FSFO_THRESHOLD=$(run_dgmgrl_cmd "SHOW DATABASE '${PRIMARY_DB_UNIQUE_NAME}' 'FastStartFailoverThreshold';" | parse_broker_property || true)
    fi
    if [[ -z "$FSFO_THRESHOLD" || "$FSFO_THRESHOLD" == "unknown" ]]; then
        FSFO_THRESHOLD=$(run_dgmgrl_cmd "SHOW FAST_START FAILOVER;" | extract_fsfo_threshold || true)
    fi
    if [[ -z "$FSFO_THRESHOLD" ]]; then
        FSFO_THRESHOLD="unknown"
        note_discovery_failure "fast-start failover threshold (broker)"
    fi
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

# An empty result here is a legitimate outcome (no user-facing services
# active yet), not necessarily a query failure - only a real run_sql failure
# (non-zero exit, e.g. an ORA- error under WHENEVER SQLERROR EXIT 1) is
# counted as a discovery failure below.
if ! SERVICE_OUTPUT=$(run_sql "
SELECT NAME FROM V\$ACTIVE_SERVICES
WHERE UPPER(NAME) NOT IN (
    SELECT UPPER(DB_UNIQUE_NAME) FROM V\$DATABASE
    UNION ALL SELECT UPPER(NAME) FROM V\$DATABASE
    UNION ALL SELECT UPPER(INSTANCE_NAME) FROM V\$INSTANCE
)
AND NAME NOT LIKE 'SYS\$%'
AND UPPER(NAME) NOT LIKE '%XDB%'
AND UPPER(NAME) NOT LIKE '%\_CFG' ESCAPE '\'
AND UPPER(NAME) NOT LIKE '%\_DGMGRL' ESCAPE '\'
ORDER BY NAME;
" | clean); then
    SERVICE_OUTPUT=""
    note_discovery_failure "active services list (report will show no per-service connection strings)"
fi

SERVICE_LIST=()
while IFS= read -r line; do
    [[ -n "$line" ]] && SERVICE_LIST+=("$line")
done <<< "$SERVICE_OUTPUT"

info "Services in report: ${SERVICE_LIST[*]}"

SQLNET_EXPIRE_TIME=$(get_sqlnet_expire_time)

RPO_STATEMENT="Data-loss exposure is unknown because protection mode or standby transport mode could not be discovered."
case "$(printf '%s' "$PROTECTION_MODE" | tr '[:lower:]' '[:upper:]')|$(printf '%s' "$STANDBY_LOGXPTMODE" | tr '[:lower:]' '[:upper:]')" in
    *MAXIMUM*AVAILABILITY*'|'SYNC|*MAXIMUM*AVAILABILITY*'|'FASTSYNC)
        RPO_STATEMENT="Protection is ${PROTECTION_MODE} with standby transport ${STANDBY_LOGXPTMODE}: a failover loses no committed transactions. SYNC/FASTSYNC can add commit latency, which is most visible for chatty transaction patterns."
        ;;
    *MAXIMUM*PERFORMANCE*'|'ASYNC)
        RPO_STATEMENT="Protection is ${PROTECTION_MODE} with standby transport ${STANDBY_LOGXPTMODE}: a failover may lose the last few seconds of committed transactions - design idempotency and reconciliation accordingly."
        ;;
    *)
        if [[ "$STANDBY_LOGXPTMODE" != "unknown" ]]; then
            RPO_STATEMENT="Protection is ${PROTECTION_MODE:-unknown} with standby transport ${STANDBY_LOGXPTMODE}; confirm exact RPO with the DBA team. SYNC/FASTSYNC can add commit latency for chatty transaction patterns."
        fi
        ;;
esac

FSFO_STATUS_UPPER=$(printf '%s' "$FSFO_STATUS" | tr '[:lower:]' '[:upper:]')
if [[ -n "$FSFO_STATUS_UPPER" && "$FSFO_STATUS_UPPER" != "DISABLED" && "$FSFO_STATUS_UPPER" != "N/A" ]]; then
    if [[ "$FSFO_THRESHOLD" != "unknown" ]]; then
        OUTAGE_STATEMENT="FSFO is enabled: automatic failover begins after approximately ${FSFO_THRESHOLD}s of primary unreachability. Expect connection errors for roughly that window plus driver reconnect time, followed by a cold-cache brownout after the role change."
    else
        OUTAGE_STATEMENT="FSFO is enabled, but the failover threshold could not be discovered. Expect connection errors for the configured threshold plus driver reconnect time, followed by a cold-cache brownout after the role change."
    fi
else
    OUTAGE_STATEMENT="FSFO is not enabled or could not be confirmed: failover is a manual DBA action, so outage lasts until it is performed. Expect a cold-cache brownout after the role change."
fi

# ============================================================
# Renderers (same shape as the setup-time script)
# ============================================================

render_tns_ha() {
    local alias="$1" phost="$2" shost="$3" port="$4" service="$5"
    cat <<EOF
${alias} =
  (DESCRIPTION =
    (CONNECT_TIMEOUT = 10)(TRANSPORT_CONNECT_TIMEOUT = 3)(RETRY_COUNT = 3)(RETRY_DELAY = 3)
    (ADDRESS_LIST =
      (LOAD_BALANCE = OFF)
      (ADDRESS = (PROTOCOL = TCP)(HOST = ${phost})(PORT = ${port}))
      (ADDRESS = (PROTOCOL = TCP)(HOST = ${shost})(PORT = ${port}))
    )
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${service})
    )
  )
EOF
}

render_jdbc_ha() {
    local phost="$1" shost="$2" port="$3" service="$4"
    printf 'jdbc:oracle:thin:@(DESCRIPTION=(CONNECT_TIMEOUT=10)(TRANSPORT_CONNECT_TIMEOUT=3)(RETRY_COUNT=3)(RETRY_DELAY=3)(ADDRESS_LIST=(LOAD_BALANCE=OFF)(ADDRESS=(PROTOCOL=TCP)(HOST=%s)(PORT=%s))(ADDRESS=(PROTOCOL=TCP)(HOST=%s)(PORT=%s)))(CONNECT_DATA=(SERVICE_NAME=%s)))\n' \
        "$phost" "$port" "$shost" "$port" "$service"
}

render_easy_connect_ha() {
    local phost="$1" shost="$2" port="$3" service="$4"
    printf '%s:%s,%s:%s/%s?connect_timeout=5&transport_connect_timeout=3&retry_count=2\n' \
        "$phost" "$port" "$shost" "$port" "$service"
}

render_driver_table() {
    local ez="$1"
    printf '| Client | Form |\n'
    printf '|--------|------|\n'
    printf '| ODP.NET | `User Id=app_user;Password=<pwd>;Data Source=%s` |\n' "$ez"
    printf '| python-oracledb | `oracledb.connect(user="app_user", password="<pwd>", dsn="%s")` |\n' "$ez"
    printf '| SQLAlchemy | `oracle+oracledb://app_user:<pwd>@%s` |\n' "$ez"
    printf '| SQL*Plus | `sqlplus app_user/<pwd>@%s` |\n' "$ez"
    printf '\n'
}

# ---- begin dataguard-doc visualizer helpers ----
# Kept byte-identical in dg_handoff.sh and
# primary/10_generate_handoff_report.sh (tests/test_visualizer_url.sh
# diffs the two copies). The handoff report links the discovered
# topology into the interactive Data Guard configuration explorer
# (source: https://github.com/davidbudac/dataguard-doc, published at
# https://davidbudac.cz/dataguard/). The page restores its state from
# "#cfg=<base64url(JSON)>"; a partial config is valid - keys we omit
# fall back to the page defaults and unknown keys are ignored. Only
# topology already printed in this report is encoded (names, hosts,
# port, service) - never credentials.

DG_DOC_BASE_URL="${DG_DOC_BASE_URL:-https://davidbudac.cz/dataguard/}"

# stdin -> base64url (URL-safe alphabet, no padding, no newlines).
# Returns 1 when no encoder exists; the caller then omits the link.
b64url_encode() {
    if command -v base64 >/dev/null 2>&1; then
        base64 | tr -d '\n=' | tr '+/' '-_'
    elif command -v openssl >/dev/null 2>&1; then
        openssl enc -base64 -A | tr -d '\n=' | tr '+/' '-_'
    else
        return 1
    fi
}

# Append one JSON member to the object fragment named by $1, skipping
# empty/unknown values so omitted keys keep the page defaults.
# viz_add <fragment-var> <key> <value> [num]
viz_add() {
    local _var="$1" _key="$2" _val="$3" _kind="${4:-str}" _frag
    case "$_val" in
        ''|unknown|UNKNOWN|N/A|n/a) return 0 ;;
    esac
    if [[ "$_kind" == "num" ]]; then
        case "$_val" in *[!0-9]*) return 0 ;; esac
        _frag="\"${_key}\":${_val}"
    else
        _val=$(printf '%s' "$_val" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
        _frag="\"${_key}\":\"${_val}\""
    fi
    eval "${_var}=\"\${${_var}:+\${${_var}},}\${_frag}\""
}

# Case-insensitive short-hostname comparison (FQDN vs short name safe)
viz_same_host() {
    local a b
    a=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'); a="${a%%.*}"
    b=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]'); b="${b%%.*}"
    [[ -n "$a" && "$a" == "$b" ]]
}

build_visualizer_url() {
    local dep="" par="" sim="" json enc mode_tok="" xpt_tok="" obs_tok=""

    viz_add dep name         "$PRIMARY_DB_UNIQUE_NAME"
    viz_add dep dbPrimary    "$PRIMARY_DB_UNIQUE_NAME"
    viz_add dep dbStandby    "$STANDBY_DB_UNIQUE_NAME"
    viz_add dep hostPrimary  "$PRIMARY_HOSTNAME"
    viz_add dep hostStandby  "$STANDBY_HOSTNAME"
    viz_add dep hostObserver "$FSFO_OBSERVER_HOST"
    viz_add dep service      "${SERVICE_LIST[0]:-}"
    viz_add dep port         "$PORT" num

    # The page models MaxAvailability and MaxPerformance only;
    # anything else (e.g. MaxProtection) is omitted -> page default.
    case "$(printf '%s' "$PROTECTION_MODE" | tr '[:lower:]' '[:upper:]')" in
        *AVAILABILITY*) mode_tok="maxavail" ;;
        *PERFORMANCE*)  mode_tok="maxperf" ;;
    esac
    viz_add par mode "$mode_tok"
    case "$(printf '%s' "$STANDBY_LOGXPTMODE" | tr '[:upper:]' '[:lower:]')" in
        sync)     xpt_tok="sync" ;;
        fastsync) xpt_tok="fastsync" ;;
        async)    xpt_tok="async" ;;
    esac
    viz_add par logXptMode "$xpt_tok"
    viz_add par threshold "$FSFO_THRESHOLD" num

    # Observer placement: the page models the primary site as dc1, the
    # standby site as dc2, a third site as dc3; 'none' = no observer.
    case "$(printf '%s' "${FSFO_STATUS:-}" | tr '[:lower:]' '[:upper:]')" in
        ''|DISABLED|N/A) obs_tok="none" ;;
        *)
            if viz_same_host "$FSFO_OBSERVER_HOST" "$PRIMARY_HOSTNAME"; then
                obs_tok="dc1"
            elif viz_same_host "$FSFO_OBSERVER_HOST" "$STANDBY_HOSTNAME"; then
                obs_tok="dc2"
            elif [[ -n "$FSFO_OBSERVER_HOST" ]]; then
                obs_tok="dc3"
            fi
            ;;
    esac
    viz_add sim observerLoc "$obs_tok"

    json="{\"v\":1"
    [[ -n "$dep" ]] && json="${json},\"deployment\":{${dep}}"
    [[ -n "$par" ]] && json="${json},\"params\":{${par}}"
    [[ -n "$sim" ]] && json="${json},\"sim\":{${sim}}"
    json="${json}}"

    enc=$(printf '%s' "$json" | b64url_encode) || return 1
    [[ -n "$enc" ]] || return 1
    printf '%s#cfg=%s' "$DG_DOC_BASE_URL" "$enc"
}
# ---- end dataguard-doc visualizer helpers ----

# ============================================================
# Verdict
# ============================================================

# Escalate-only: HEALTHY -> WARNING -> ERROR, never lowered
VERDICT="HEALTHY"
VERDICT_NOTES=()
escalate_verdict() {
    case "$1" in
        ERROR)   VERDICT="ERROR" ;;
        WARNING) if [[ "$VERDICT" != "ERROR" ]]; then VERDICT="WARNING"; fi ;;
    esac
}
if [[ "$DB_ROLE" != "PRIMARY" ]]; then
    escalate_verdict "WARNING"
    VERDICT_NOTES+=("Local role is ${DB_ROLE}, expected PRIMARY")
fi
if [[ "${GAP_COUNT}" -gt 0 ]]; then
    escalate_verdict "ERROR"
    VERDICT_NOTES+=("${GAP_COUNT} archive gap(s) detected")
fi
if [[ "$DG_BROKER_START" != "TRUE" ]]; then
    escalate_verdict "WARNING"
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPACT_LOCAL="${SCRIPT_DIR}/DG_APPLICATION_IMPACT.html"
IMPACT_DOCS="${SCRIPT_DIR}/docs/DG_APPLICATION_IMPACT.html"
IMPACT_REFERENCE=""
if [[ -f "$IMPACT_LOCAL" ]]; then
    IMPACT_REFERENCE="$IMPACT_LOCAL"
elif [[ -f "$IMPACT_DOCS" ]]; then
    IMPACT_REFERENCE="$IMPACT_DOCS"
fi

# Best-effort: no base64/openssl on the host just drops the link
VIZ_URL=$(build_visualizer_url) || VIZ_URL=""

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
    if [[ -n "$VIZ_URL" ]]; then
        echo "- **Interactive diagram:** [open this configuration in the Data Guard visualizer](${VIZ_URL})"
        echo "  (the link encodes only the topology shown in this report - no credentials)"
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
    echo "| Local role            | ${DB_ROLE:-N/A} |"
    echo "| Open mode             | ${OPEN_MODE:-N/A} |"
    echo "| Protection mode       | ${PROTECTION_MODE:-N/A} |"
    echo "| Standby LogXptMode    | ${STANDBY_LOGXPTMODE:-unknown} |"
    echo "| Standby open mode     | ${STANDBY_OPEN_MODE:-unknown} |"
    echo "| Switchover status     | ${SWITCHOVER_STATUS:-N/A} |"
    echo "| Force logging         | ${FORCE_LOGGING:-N/A} |"
    echo "| Broker started        | ${DG_BROKER_START:-N/A} |"
    echo "| Last received seq#    | ${LAST_RECEIVED:-N/A} |"
    echo "| Last applied seq#     | ${LAST_APPLIED:-N/A} |"
    echo "| Apply lag (sequences) | ${APPLY_LAG_SEQ} |"
    echo "| Archive gaps          | ${GAP_COUNT} |"
    echo "| FSFO status           | ${FSFO_STATUS:-N/A} |"
    echo "| FSFO observer present | ${FSFO_OBSERVER:-N/A} |"
    if [[ -n "$FSFO_OBSERVER_HOST" ]]; then
        echo "| FSFO observer host    | ${FSFO_OBSERVER_HOST} |"
    fi
    echo "| FSFO threshold        | ${FSFO_THRESHOLD:-unknown} |"
    echo "| Role trigger ready    | ${ROLE_TRIGGER_READY} (${TRIGGER_OWNERS:-unknown}) |"
    echo "| SQLNET.EXPIRE_TIME    | ${SQLNET_EXPIRE_TIME} |"
    echo ""
    echo "**Verdict:** ${VERDICT}"
    if [[ ${#VERDICT_NOTES[@]} -gt 0 ]]; then
        for n in "${VERDICT_NOTES[@]}"; do echo "- ${n}"; done
    fi

    echo ""
    echo "### Application Impact Summary"
    echo ""
    echo "- ${RPO_STATEMENT}"
    echo "- ${OUTAGE_STATEMENT}"
    echo "- FORCE LOGGING is ${FORCE_LOGGING:-unknown}; NOLOGGING batch jobs can still create unrecoverable standby gaps if force logging is disabled for maintenance."
    echo "- Sequence values can have gaps after switchover/failover because cached values on the old primary are discarded."
    echo "- Application firewalls must allow the app tier to reach both database hosts on listener port ${PORT} before go-live."
    echo ""

    echo "### Adding Datafiles or PDBs After Setup (DBA Note)"
    echo ""
    echo "- New datafiles and PDBs replicate to the standby automatically only when their primary-side paths fall under a directory prefix covered by the standby's \`DB_FILE_NAME_CONVERT\` pairs. OMF-mode standbys (\`db_create_file_dest\` set) are immune."
    echo "- A file added in an uncovered directory is created as \`UNNAMEDnnnnn\` in \`\$ORACLE_HOME/dbs\` on the standby; MRP stops with ORA-01274 and redo apply halts until manually repaired."
    echo "- Before creating a PDB or adding a datafile in a new directory, keep paths under a covered prefix, or use \`CREATE PLUGGABLE DATABASE ... FILE_NAME_CONVERT\` / PDB-level OMF."
    echo "- After any addition, verify the standby: \`dg_status.sh\` flags UNNAMED datafiles; also check \`V\$RECOVER_FILE\` and the standby alert log."
    echo "- Repair sequence (\`STANDBY_FILE_MANAGEMENT=MANUAL\`, \`ALTER DATABASE CREATE DATAFILE ... AS ...\`, back to \`AUTO\`, restart apply): see \"Life After Setup: Adding Datafiles and PDBs\" in the repository's \`docs/DATA_GUARD_WALKTHROUGH.md\`."
    echo ""

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
    echo "- **Role-aware (failover)** — single descriptor with both hosts. Best"
    echo "  for the application tier when the role-aware service trigger"
    echo "  (\`trigger/create_role_trigger.sh\`) is deployed and enabled: the"
    echo "  service is only up on whichever side is primary, so clients"
    echo "  automatically follow the active database after a switchover or failover."
    echo ""
    if [[ "$ROLE_TRIGGER_READY" == "YES" ]]; then
        echo "**Role-aware trigger status:** deployed and enabled. The role-aware descriptor is safe to hand to applications."
    else
        echo "**WARNING:** The \`DG_SERVICE_MGR\` package and both role-aware triggers are not confirmed enabled. Role-aware descriptors may connect applications to a read-only standby until \`trigger/create_role_trigger.sh\` is deployed."
    fi
    echo ""

    for svc in "${SERVICE_LIST[@]}"; do
        local_safe=$(echo "$svc" | tr '.' '_' | tr '[:lower:]' '[:upper:]')
        ALIAS_HA="${local_safe}_HA"

        echo "### Service: \`${svc}\`"
        echo ""

        if [[ -n "$STANDBY_HOSTNAME" ]]; then
            echo '```'
            render_tns_ha "$ALIAS_HA" "$PRIMARY_HOSTNAME" "$STANDBY_HOSTNAME" "$PORT" "$svc"
            echo '```'
            echo ""
            echo '```'
            echo "JDBC: $(render_jdbc_ha "$PRIMARY_HOSTNAME" "$STANDBY_HOSTNAME" "$PORT" "$svc")"
            echo '```'
            echo ""
            EASY_HA=$(render_easy_connect_ha "$PRIMARY_HOSTNAME" "$STANDBY_HOSTNAME" "$PORT" "$svc")
            echo "Easy Connect Plus (19c+ clients):"
            echo ""
            echo '```'
            echo "$EASY_HA"
            echo '```'
            echo ""
            render_driver_table "$EASY_HA"
            STANDBY_OPEN_UPPER=$(printf '%s' "$STANDBY_OPEN_MODE" | tr '[:lower:]' '[:upper:]')
            if [[ "$STANDBY_OPEN_UPPER" == *MOUNTED* ]]; then
                echo "Standby-only note: standby is MOUNTED - direct standby connections will fail until it is opened READ ONLY."
                echo ""
            elif [[ "$STANDBY_OPEN_UPPER" == *READ*ONLY*APPLY* ]]; then
                echo "Standby-only note: READ ONLY WITH APPLY requires the appropriate Active Data Guard license. Reads can lag primary commits, read-your-writes is not guaranteed, and DML fails with ORA-16000."
                echo ""
            elif [[ "$STANDBY_OPEN_MODE" == "unknown" ]]; then
                echo "Standby-only note: standby readability could not be discovered; verify OPEN_MODE before giving direct standby strings to applications."
                echo ""
            fi
        fi
    done

    echo "## 4. Notes for Client Teams"
    echo ""
    if [[ -n "$IMPACT_REFERENCE" ]]; then
        echo "- Full application behavior briefing: \`${IMPACT_REFERENCE}\`."
    fi
    echo "- What changes for your application: SYNC/FASTSYNC can add commit latency; NOLOGGING batch jobs need DBA review; sequence caches can create gaps after role change; expect a cold-cache brownout; firewalls must reach both hosts."
    echo "- The role-aware descriptor relies on the service being **stopped on"
    echo "  the standby** by \`trigger/create_role_trigger.sh\`. Without it,"
    echo "  clients may attach to a read-only standby and receive ORA-16000 on writes."
    echo "- TAF settings reconnect SELECT cursors only when configured by the service or descriptor; active DML transactions still need application-level retry."
    echo ""
    echo "## 5. Recommended Client and Pool Settings"
    echo ""
    echo "- [ ] Use the provided descriptor timeouts: \`CONNECT_TIMEOUT=10\`, \`TRANSPORT_CONNECT_TIMEOUT=3\`, and retry counts to bound connect hangs."
    echo "- [ ] Set driver connection timeout to 5-10 seconds and read/call timeout to the smallest value your request SLO allows."
    echo "- [ ] Dead connection detection: server-side \`SQLNET.EXPIRE_TIME\` is ${SQLNET_EXPIRE_TIME}; also enable TCP keepalive on client hosts."
    echo "- [ ] Enable pool validation on borrow or an equivalent lightweight connection check before handing out idle connections."
    echo "- [ ] TAF is SELECT-only replay; in-flight DML, commits, and non-idempotent calls require application retry/reconciliation."
    echo ""
    echo "## 6. Quick Verification"
    echo ""
    echo '```bash'
    echo "tnsping ${PRIMARY_HOSTNAME}:${PORT}/${SERVICE_LIST[0]:-service_name}"
    if [[ -n "$STANDBY_HOSTNAME" ]]; then
        echo "tnsping ${STANDBY_HOSTNAME}:${PORT}/${SERVICE_LIST[0]:-service_name}"
    fi
    echo "nc -z ${PRIMARY_HOSTNAME} ${PORT}"
    if [[ -n "$STANDBY_HOSTNAME" ]]; then
        echo "nc -z ${STANDBY_HOSTNAME} ${PORT}"
    fi
    echo '```'

    if [[ ${#DISCOVERY_WARNINGS[@]} -gt 0 ]]; then
        echo ""
        echo "## Discovery Warnings"
        echo ""
        echo "The following items could not be discovered (shown as N/A above) - this is"
        echo "usually a transient ORA- error; re-run the report if the field is needed:"
        echo ""
        for w in "${DISCOVERY_WARNINGS[@]}"; do
            echo "- ${w}"
        done
    fi

} > "$OUTPUT_FILE"

info "Report written: $OUTPUT_FILE"
echo ""
cat "$OUTPUT_FILE"
echo ""
if [[ ${#DISCOVERY_WARNINGS[@]} -gt 0 ]]; then
    warn "${#DISCOVERY_WARNINGS[@]} discovery item(s) failed and were rendered as N/A (see 'Discovery Warnings' in the report):"
    for w in "${DISCOVERY_WARNINGS[@]}"; do
        warn "  - ${w}"
    done
fi
info "Verdict: ${VERDICT}  |  Apply lag: ${APPLY_LAG_SEQ}  |  Gaps: ${GAP_COUNT}  |  Services: ${#SERVICE_LIST[@]}"

case "$VERDICT" in
    ERROR)   exit 1 ;;
    *)       exit 0 ;;
esac
