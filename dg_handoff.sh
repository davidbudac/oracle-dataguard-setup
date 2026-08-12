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

# Trim leading/trailing whitespace (spaces, tabs, CR) from every line and
# drop empty lines. Internal spaces are preserved on purpose: display fields
# such as "READ WRITE", "MAXIMUM AVAILABILITY" and "FAILED DESTINATION" end up
# verbatim in the customer-facing report.
clean() {
    tr -d '\r' \
        | sed -e 's/^[[:space:]][[:space:]]*//' -e 's/[[:space:]][[:space:]]*$//' -e '/^$/d'
}
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

# Local copy of common/dg_functions.sh's dgmgrl_output_has_error() - this
# script is deliberately standalone and does not source dg_functions.sh.
# DGMGRL always exits 0, so the captured text is the only failure signal.
# Returns 0 (true) when the output contains a real broker/Oracle error.
broker_output_has_error() {
    local output="$1"
    if printf '%s\n' "$output" | grep -Eq 'ORA-[0-9]|DGM-[0-9]'; then
        return 0
    fi
    # A standalone "Error:" line with a nonzero code. "Error: 0" is the
    # benign per-member status line in SHOW CONFIGURATION/SHOW DATABASE.
    if printf '%s\n' "$output" | grep -Eiq '^[[:space:]]*Error:[[:space:]]*[1-9]'; then
        return 0
    fi
    if printf '%s\n' "$output" | grep -Eiq '^[[:space:]]*Failed\.[[:space:]]*$'; then
        return 0
    fi
    return 1
}

# Extract the "Configuration Status:" verdict (the value is printed on the
# FOLLOWING line by 19c DGMGRL). Prints the upper-cased status or nothing.
extract_configuration_status() {
    printf '%s\n' "$1" | awk '
        found && $0 !~ /^[[:space:]]*$/ {
            gsub(/^[[:space:]]*/, "")
            gsub(/[[:space:]].*$/, "")
            print toupper($0)
            exit
        }
        tolower($0) ~ /^[[:space:]]*configuration status:/ {
            rest = $0
            sub(/^[^:]*:[[:space:]]*/, "", rest)
            gsub(/[[:space:]].*$/, "", rest)
            if (rest != "") { print toupper(rest); exit }
            found = 1
        }
    '
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

# Derive the standby's readability from DGMGRL SHOW DATABASE output.
# 19c DGMGRL does NOT print an "Open Mode" line for a standby - it prints
# "Real Time Query: ON|OFF". ON means the standby is open READ ONLY WITH
# APPLY (Active Data Guard); OFF means it is not readable (MOUNTED, or open
# read-only without apply). Prints nothing when the line is absent.
extract_standby_open_mode_from_broker() {
    awk -F: '
        {
            line=tolower($0)
        }
        line ~ /real[[:space:]]+time[[:space:]]+query/ {
            value=tolower($2)
            gsub(/[^a-z]/, "", value)
            if (value == "on") {
                print "READ ONLY WITH APPLY"
                exit
            }
            if (value == "off") {
                print "MOUNTED"
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

# Single source of truth for "is FSFO on?" - used to gate threshold discovery,
# the threshold row in the report, and the visualizer payload.
FSFO_STATUS_UPPER=$(printf '%s' "$FSFO_STATUS" | tr '[:lower:]' '[:upper:]')
FSFO_ENABLED="NO"
case "$FSFO_STATUS_UPPER" in
    ''|DISABLED|N/A) ;;
    *) FSFO_ENABLED="YES" ;;
esac

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
        # SHOW DATABASE VERBOSE prints the broker's own "HostName = '...'"
        # property - that is the authoritative hostname and the only value
        # that belongs in a connect descriptor.
        #
        # It also prints "DGConnectIdentifier = '...'", which is USUALLY a
        # TNS alias (e.g. 'cdb1_stby.world'). A TNS alias is not a hostname:
        # using it produced fully unusable TNS/JDBC strings. It is therefore
        # only accepted when it is genuinely an easy-connect string, i.e. it
        # carries a ":port" and/or a "/service" part.
        #
        # AIX-portable: avoid GNU regex extensions; use POSIX BRE with
        # [[:space:]] character classes and `\(...\)` capture groups.
        local db="$1" out host dgci
        out=$(run_dgmgrl_cmd "SHOW DATABASE VERBOSE '${db}';" 2>/dev/null || true)

        # 1. HostName property (preferred)
        host=$(printf '%s\n' "$out" \
            | grep -i '^[[:space:]]*HostName[[:space:]]*=' | head -1 \
            | sed -e "s/^[^=]*=[[:space:]]*//" \
                  -e "s/^'//" \
                  -e "s/'.*$//" \
                  -e "s/[[:space:]]*$//")
        if [[ -n "$host" ]]; then
            printf '%s\n' "$host"
            return 0
        fi

        # 2. DGConnectIdentifier, only in genuine easy-connect form
        dgci=$(printf '%s\n' "$out" \
            | grep -i '^[[:space:]]*DGConnectIdentifier[[:space:]]*=' | head -1 \
            | sed -e "s/^[^=]*=[[:space:]]*//" \
                  -e "s/^'//" \
                  -e "s/'.*$//" \
                  -e "s/[[:space:]]*$//")
        case "$dgci" in
            *:[0-9]*|*/?*)
                printf '%s\n' "${dgci%%[:/]*}"
                return 0
                ;;
        esac

        # 3. Fallback: "Host Name:" text or an embedded "(HOST = ...)"
        printf '%s\n' "$out" | grep -i -E "Host Name|HOST[[:space:]]*=" | head -1 \
            | sed -e "s/.*[Hh]ost *[Nn]ame[: ]*//" \
                  -e "s/.*HOST *= *\([A-Za-z0-9._-][A-Za-z0-9._-]*\).*/\1/" \
            | tr -d ' '
        return 0
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
        # 19c prints "Real Time Query: ON|OFF", never an "Open Mode" line.
        # An absent line is a legitimate outcome (broker cannot reach the
        # standby), so it is reported inline in the report rather than as a
        # discovery failure.
        STANDBY_OPEN_MODE=$(printf '%s\n' "$STANDBY_SHOW_OUTPUT" | extract_standby_open_mode_from_broker)
        if [[ -z "$STANDBY_OPEN_MODE" ]]; then
            STANDBY_OPEN_MODE="unknown"
        fi
    fi
    # The failover threshold is only meaningful while FSFO is enabled;
    # querying (and reporting) it otherwise produced a spurious value and a
    # spurious discovery warning on every non-FSFO configuration.
    if [[ "$FSFO_ENABLED" == "YES" ]]; then
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

RPO_STATEMENT="RPO unknown: protection mode or standby transport mode could not be discovered. Treat every failover as potentially lossy until the DBA team confirms the transport mode."
case "$(printf '%s' "$PROTECTION_MODE" | tr '[:lower:]' '[:upper:]')|$(printf '%s' "$STANDBY_LOGXPTMODE" | tr '[:lower:]' '[:upper:]')" in
    *MAXIMUM*AVAILABILITY*'|'SYNC|*MAXIMUM*AVAILABILITY*'|'FASTSYNC)
        RPO_STATEMENT="RPO = 0 while synchronized: protection is ${PROTECTION_MODE}, standby transport ${STANDBY_LOGXPTMODE}. A commit is not acknowledged to the client until the standby confirms redo receipt (FASTSYNC acknowledges on receipt into standby memory, before the standby disk write), so a failover loses no committed transactions. If the standby becomes unreachable the primary continues alone; a failover during that window loses the redo generated since the disconnect. Cost: every commit carries one primary-to-standby network round trip."
        ;;
    *MAXIMUM*PERFORMANCE*'|'ASYNC)
        RPO_STATEMENT="RPO > 0: protection is ${PROTECTION_MODE}, standby transport ${STANDBY_LOGXPTMODE}. Redo ships asynchronously, so a failover loses whatever had not reached the standby at failure time - normally a few seconds, unbounded if transport falls behind. Committed, client-acknowledged transactions can disappear in a failover: exactly-once workflows need idempotency keys or post-failover reconciliation."
        ;;
    *)
        if [[ "$STANDBY_LOGXPTMODE" != "unknown" ]]; then
            RPO_STATEMENT="Protection is ${PROTECTION_MODE:-unknown} with standby transport ${STANDBY_LOGXPTMODE}; confirm the exact RPO with the DBA team. SYNC/FASTSYNC adds a standby round trip to every commit; ASYNC allows data loss bounded by transport lag at failover."
        fi
        ;;
esac

if [[ "$FSFO_ENABLED" == "YES" ]]; then
    if [[ "$FSFO_THRESHOLD" != "unknown" ]]; then
        OUTAGE_STATEMENT="Automatic failover (FSFO) is enabled with a ${FSFO_THRESHOLD}s threshold. App-visible outage on primary loss = ${FSFO_THRESHOLD}s detection + failover execution (typically under 60s) + service startup on the new primary + client reconnect (bounded by the descriptor retry window, section 1). Budget 1-3 minutes of connection errors."
    else
        OUTAGE_STATEMENT="Automatic failover (FSFO) is enabled but the threshold could not be discovered. App-visible outage = detection threshold + failover execution (typically under 60s) + service startup on the new primary + client reconnect (bounded by the descriptor retry window, section 1)."
    fi
else
    OUTAGE_STATEMENT="FSFO is not enabled or could not be confirmed: failover is a manual DBA action and the outage lasts until it is executed and the service starts on the new primary. A planned switchover interrupts connections for the role transition (typically 1-2 minutes) plus client reconnect."
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

    # Observer placement: the page models the primary site as dc1, the
    # standby site as dc2, a third site as dc3; 'none' = no observer.
    # The failover threshold is only encoded while FSFO is actually
    # enabled - otherwise the page would show a threshold for a
    # configuration that has none.
    case "$(printf '%s' "${FSFO_STATUS:-}" | tr '[:lower:]' '[:upper:]')" in
        ''|DISABLED|N/A) obs_tok="none" ;;
        *)
            viz_add par threshold "$FSFO_THRESHOLD" num
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
# Apply-lag thresholds (sequences). Same env vars as dg_status.sh so a site
# only has to tune them in one place.
LAG_WARN_SEQ="${DG_SEQ_GAP_WARN:-1}"
LAG_CRIT_SEQ="${DG_SEQ_GAP_CRIT:-5}"
case "$LAG_WARN_SEQ" in ''|*[!0-9]*) LAG_WARN_SEQ=1 ;; esac
case "$LAG_CRIT_SEQ" in ''|*[!0-9]*) LAG_CRIT_SEQ=5 ;; esac

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

# Redo apply progress: a standby that is many sequences behind is not a
# usable failover target, no matter what the broker says.
if [[ "$APPLY_LAG_SEQ" -gt "$LAG_CRIT_SEQ" ]]; then
    escalate_verdict "ERROR"
    VERDICT_NOTES+=("Apply lag is ${APPLY_LAG_SEQ} sequences (threshold ${LAG_CRIT_SEQ})")
elif [[ "$APPLY_LAG_SEQ" -gt "$LAG_WARN_SEQ" ]]; then
    escalate_verdict "WARNING"
    VERDICT_NOTES+=("Apply lag is ${APPLY_LAG_SEQ} sequences")
fi

# Switchover readiness. On a healthy primary this is TO STANDBY / SESSIONS
# ACTIVE; the gap and destination states below mean redo transport is broken.
case "$(printf '%s' "$SWITCHOVER_STATUS" | tr '[:lower:]' '[:upper:]')" in
    *"FAILED DESTINATION"*|*"UNRESOLVABLE GAP"*|*"LOG SWITCH GAP"*)
        escalate_verdict "ERROR"
        VERDICT_NOTES+=("Switchover status is ${SWITCHOVER_STATUS}")
        ;;
    *"RESOLVABLE GAP"*|*"RECOVERY NEEDED"*|*"PREPARING"*)
        escalate_verdict "WARNING"
        VERDICT_NOTES+=("Switchover status is ${SWITCHOVER_STATUS}")
        ;;
esac

# The broker's own verdict. DGMGRL always exits 0, so the captured text is
# the only signal - scan it the same way the setup scripts do.
if [[ -n "$BROKER_OUTPUT" ]]; then
    BROKER_CONFIG_STATUS=$(extract_configuration_status "$BROKER_OUTPUT")
    case "$BROKER_CONFIG_STATUS" in
        ERROR)
            escalate_verdict "ERROR"
            VERDICT_NOTES+=("Broker Configuration Status is ERROR")
            ;;
        WARNING)
            escalate_verdict "WARNING"
            VERDICT_NOTES+=("Broker Configuration Status is WARNING")
            ;;
    esac
    if broker_output_has_error "$BROKER_OUTPUT"; then
        escalate_verdict "ERROR"
        VERDICT_NOTES+=("Broker reported ORA-/DGM- errors (see Broker Configuration section)")
    fi
fi

# Role-aware descriptors are only safe once the trigger is deployed.
if [[ "$ROLE_TRIGGER_READY" != "YES" ]]; then
    escalate_verdict "WARNING"
    VERDICT_NOTES+=("Role-aware service trigger is not deployed/enabled")
fi

if [[ -n "$STANDBY_DB_UNIQUE_NAME" && "$STANDBY_OPEN_MODE" == "unknown" ]]; then
    escalate_verdict "WARNING"
    VERDICT_NOTES+=("Standby readability could not be determined from the broker")
fi

if [[ ${#VERDICT_NOTES[@]} -eq 0 ]]; then
    VERDICT_NOTES+=("No role, transport, apply, broker or trigger issues detected")
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

# Easy Connect Plus string used by the end-to-end verification example;
# degrades to a primary-only address when the standby host is unknown.
if [[ -n "$STANDBY_HOSTNAME" ]]; then
    VERIFY_EZ=$(render_easy_connect_ha "$PRIMARY_HOSTNAME" "$STANDBY_HOSTNAME" "$PORT" "${SERVICE_LIST[0]:-service_name}")
else
    VERIFY_EZ="${PRIMARY_HOSTNAME}:${PORT}/${SERVICE_LIST[0]:-service_name}"
fi

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
    echo "## 1. Connection Strings"
    echo ""
    echo "**Role-aware (failover)** descriptors: both hosts in one ADDRESS_LIST. The service runs only on the current primary (stopped on the standby by the role trigger), so clients follow the primary across switchover/failover with no config change. Use this for the application tier."
    echo ""
    if [[ "$ROLE_TRIGGER_READY" == "YES" ]]; then
        echo "**Role-aware trigger status:** deployed and enabled. The role-aware descriptor is safe to hand to applications."
    else
        echo "**WARNING:** The \`DG_SERVICE_MGR\` package and both role-aware triggers are not confirmed enabled. Role-aware descriptors may connect applications to a read-only standby until \`trigger/create_role_trigger.sh\` is deployed."
    fi
    echo ""
    echo "### Descriptor Parameters"
    echo ""
    echo "| Parameter | Value | Effect |"
    echo "|-----------|-------|--------|"
    echo "| LOAD_BALANCE | OFF | Addresses tried in listed order: primary host first, then standby |"
    echo "| TRANSPORT_CONNECT_TIMEOUT | 3 s | TCP connect budget per address |"
    echo "| CONNECT_TIMEOUT | 10 s | Total budget per address (TCP + listener handshake + session creation) |"
    echo "| RETRY_COUNT / RETRY_DELAY | 3 / 3 s | After the whole ADDRESS_LIST fails, it is retried 3 more times, 3 s apart |"
    echo ""
    echo "This descriptor configures no TAF (\`FAILOVER_MODE\`): after a session drop, reconnecting is the pool's or application's job unless the DBA has set TAF attributes on the service itself."
    echo ""
    echo "Worst-case connect times these values produce:"
    echo ""
    echo "- Both hosts unreachable (TCP timeout): 2 addresses x 3 s per pass, 4 passes, 3 x 3 s delays = **about 33 s** until the driver returns an error."
    echo "- Primary host down, standby listener up (service stopped there): about 3 s TCP timeout + immediate ORA-12514 per pass = **about 21 s** until error."
    echo "- Failover in progress: attempts cycle (each bounded as above) until the service registers on the new primary, then the next attempt succeeds."
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
                echo "Standby-only note: the broker reports Real Time Query OFF - the standby is MOUNTED (or open read-only without apply), so direct standby connections will fail until it is opened READ ONLY WITH APPLY."
                echo ""
            elif [[ "$STANDBY_OPEN_UPPER" == *READ*ONLY*APPLY* ]]; then
                echo "Standby-only note: the standby is READ ONLY WITH APPLY (Active Data Guard - separately licensed). Reads see committed data as of the apply point (staleness = apply lag; read-your-writes across the two databases is not guaranteed). Bound staleness per session with \`ALTER SESSION SET STANDBY_MAX_DATA_DELAY = <seconds>\` (queries then raise ORA-03172 instead of returning stale data); \`ALTER SESSION SYNC WITH PRIMARY\` blocks until caught up (requires SYNC transport and real-time apply). DML and DDL fail with ORA-16000 (exception: DML on global temporary tables)."
                echo ""
            elif [[ "$STANDBY_OPEN_MODE" == "unknown" ]]; then
                echo "Standby-only note: standby readability could not be discovered; verify OPEN_MODE before giving direct standby strings to applications."
                echo ""
            fi
        fi
    done
    echo ""
    echo "## 2. Topology"
    echo ""
    echo "| Role    | DB_UNIQUE_NAME              | Hostname              | Listener |"
    echo "|---------|-----------------------------|-----------------------|----------|"
    echo "| Primary | ${PRIMARY_DB_UNIQUE_NAME}   | ${PRIMARY_HOSTNAME}   | ${PORT}  |"
    if [[ -n "$STANDBY_DB_UNIQUE_NAME" ]]; then
        echo "| Standby | ${STANDBY_DB_UNIQUE_NAME}   | ${STANDBY_HOSTNAME:-UNKNOWN} | ${PORT}  |"
    fi
    echo ""
    echo "## 3. Status Snapshot"
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
    if [[ "$FSFO_ENABLED" == "YES" ]]; then
        echo "| FSFO threshold        | ${FSFO_THRESHOLD:-unknown} |"
    fi
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
    echo "- After any role change the new primary starts with a largely cold buffer cache and shared pool: elevated physical reads and hard parsing for the first minutes. Queries succeed but latency degrades (brownout, not blackout)."
    echo "- FORCE LOGGING is ${FORCE_LOGGING:-unknown}. Direct-path/NOLOGGING loads generate no redo when force logging is off: the affected blocks are unrecoverable on the standby and raise ORA-26040 when read after a failover. Any NOLOGGING batch job needs DBA sign-off."
    echo "- Every application host must resolve and reach BOTH database hosts on port ${PORT} before go-live - the standby address is only exercised when it is already an emergency."
    echo ""

    echo "### Errors During Role Transitions"
    echo ""
    echo "| Error | When it appears | Client action |"
    echo "|-------|-----------------|---------------|"
    echo "| ORA-12514 | Listener up, service not registered - normal on the standby address, and on both hosts mid-failover | Retryable: driver moves to the next address / retry pass |"
    echo "| ORA-12541, ORA-12170, ORA-12535 | No listener / TCP connect timeout - host or listener down | Retryable: next address |"
    echo "| ORA-01033 | Instance starting or mounting (mid-role-change) | Retryable with backoff |"
    echo "| ORA-03113, ORA-03114, ORA-01089 | Existing session killed by failover/shutdown | Reconnect; the role-aware descriptor re-routes to the surviving side |"
    echo "| ORA-25402 | TAF (where the DBA configured it on the service) failed the session over mid-transaction | ROLLBACK, then re-run the transaction |"
    echo "| ORA-16000 | DML sent to a read-only standby | Not retryable: routing bug - service running on the standby without the role trigger, or a standby-only string handed to a writer |"
    echo ""
    echo "**Commit ambiguity:** a dropped connection (e.g. ORA-03113) while a COMMIT is in flight leaves the outcome unknown - the transaction may or may not be committed on the surviving database. Blind re-execution double-applies it. Use idempotency keys / unique business keys and verify state after reconnect. Oracle Transaction Guard resolves the outcome programmatically but requires a service with COMMIT_OUTCOME=TRUE and a 12c+ driver - not configured by this setup; request it from the DBA team if you need it."
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

    echo "## 4. Notes for Client Teams"
    echo ""
    if [[ -n "$IMPACT_REFERENCE" ]]; then
        echo "- Full application behavior briefing: \`${IMPACT_REFERENCE}\`."
    fi
    echo "- The role-aware descriptor works only because \`trigger/create_role_trigger.sh\` stops the service on the standby. With the trigger disabled, both hosts accept connections and writers landing on the standby get ORA-16000."
    echo "- Sequences: NOORDER/CACHE sequences (default CACHE 20) discard cached values at role change - expect gaps of up to the CACHE size per sequence, and no ordering guarantee across a failover. Never use sequence values as gapless or strictly-ordered business keys."
    echo "- TAF (where configured on the service) replays SELECTs only. In-flight transactions roll back (ORA-25402); commits and non-idempotent calls need application retry with the commit-ambiguity handling in section 3."
    echo "- Application Continuity (12.2+ drivers) can replay in-flight transactions, but requires \`FAILOVER_TYPE=TRANSACTION\` and \`COMMIT_OUTCOME=TRUE\` on the service - not configured by this setup; coordinate with the DBA team."
    echo "- After a switchover nothing changes for clients on the role-aware descriptor. Host-specific strings silently point at the wrong database until this report is regenerated."
    echo ""
    echo "## 5. Client and Pool Settings"
    echo ""
    echo "- [ ] Pool connection-wait/checkout timeout of at least 15 s: one full descriptor pass takes up to 12 s, worst case 33 s (section 1). A shorter pool timeout aborts borrowers before the descriptor's retry logic can succeed."
    echo "- [ ] Read/call timeout on every request path (JDBC \`oracle.jdbc.ReadTimeout\`, python-oracledb \`call_timeout\`, ODP.NET \`CommandTimeout\`): without one, a failover can leave in-flight calls hanging until TCP gives up (minutes)."
    echo "- [ ] Dead connection detection: server-side \`SQLNET.EXPIRE_TIME\` is ${SQLNET_EXPIRE_TIME}. Add \`(ENABLE=BROKEN)\` inside DESCRIPTION to enable OS TCP keepalive on the session socket, and tune client keepalive below any firewall idle timeout."
    echo "- [ ] Validate on borrow (JDBC \`isValid()\`, python-oracledb pool \`ping_interval\`, ODP.NET \`Validate Connection=true\`): after a failover every idle pooled connection is dead and must be detected before first use."
    echo "- [ ] Cap pool max size and reconnect concurrency: after a failover all clients reconnect at once, and an uncapped logon storm slows the new primary during the cold-cache window."
    echo "- [ ] Set max connection lifetime/recycle below any firewall or load-balancer idle timeout between the app tier and the database hosts."
    echo ""
    echo "## 6. Verification"
    echo ""
    echo "Reachability - both hosts, from every application host (the standby address is only exercised when it is already an emergency):"
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
    echo ""
    echo "\`tnsping\` and \`nc\` prove listener reachability only. End-to-end check - also the pass criterion for a switchover drill (re-run it after the switchover; DB_UNIQUE_NAME and SERVER_HOST must swap while DATABASE_ROLE stays PRIMARY):"
    echo ""
    echo '```'
    echo "sqlplus app_user/<pwd>@'${VERIFY_EZ}'"
    echo ""
    echo "SELECT SYS_CONTEXT('USERENV','DB_UNIQUE_NAME') db_unique_name,"
    echo "       SYS_CONTEXT('USERENV','DATABASE_ROLE')  database_role,"
    echo "       SYS_CONTEXT('USERENV','SERVER_HOST')    server_host"
    echo "FROM dual;"
    echo '```'
    echo ""
    echo "Expected now: \`${PRIMARY_DB_UNIQUE_NAME}\` / \`PRIMARY\` / \`${PRIMARY_HOSTNAME}\`."

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
if [[ "$VERDICT" != "HEALTHY" ]]; then
    for n in "${VERDICT_NOTES[@]}"; do
        warn "  ${VERDICT}: ${n}"
    done
fi

case "$VERDICT" in
    ERROR)   exit 1 ;;
    *)       exit 0 ;;
esac
