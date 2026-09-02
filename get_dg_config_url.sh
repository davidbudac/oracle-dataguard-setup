#!/usr/bin/env bash
# ============================================================
# Data Guard Visualizer Link - Standalone
# ============================================================
# Prints the interactive Data Guard configuration explorer link
# (https://github.com/davidbudac/dataguard-doc, published at
# https://davidbudac.cz/dataguard/) for the Data Guard
# configuration this database belongs to.
#
# Same link the handoff reports embed, but generated on demand
# against any existing configuration - no standby_config_*.env,
# no NFS share, no report file.
#
# Run on either DB host (primary or standby) with:
#   - ORACLE_SID and ORACLE_HOME set
#   - sqlplus '/ as sysdba' working
#   - dgmgrl available (broker started) for hostname / LogXptMode /
#     FSFO threshold discovery; otherwise pass them via flags
#
# The URL is printed on stdout, the discovery summary on stderr, so
#   URL=$(./get_dg_config_url.sh)
# captures just the link.
#
# Only topology is encoded (DB unique names, hosts, port, first
# service, protection mode, transport mode, FSFO threshold and
# observer placement) - never credentials.
#
# Usage:
#   ./get_dg_config_url.sh
#   ./get_dg_config_url.sh -q
#   ./get_dg_config_url.sh --standby-host stb.example.com --port 1521
# ============================================================

set -e
set -o pipefail

PRIMARY_HOST_OVERRIDE=""
STANDBY_HOST_OVERRIDE=""
OBSERVER_HOST_OVERRIDE=""
PORT_OVERRIDE=""
SERVICE_OVERRIDE=""
QUIET="NO"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Generates the interactive Data Guard visualizer link for the configuration
the local database belongs to, connecting via 'sqlplus / as sysdba'.

Options:
      --primary-host HOST   Override the primary hostname
      --standby-host HOST   Override the standby hostname
      --observer-host HOST  Override the FSFO observer hostname
      --port PORT           Override the listener port (default: discover or 1521)
      --service NAME        Override the service name shown in the diagram
      --base-url URL        Override the visualizer base URL
                            (default: \$DG_DOC_BASE_URL or https://davidbudac.cz/dataguard/)
  -q, --quiet               Print only the URL (suppress the discovery summary)
  -h, --help                Show this help

Topology is discovered from V\$DATABASE, V\$DATAGUARD_CONFIG,
V\$LISTENER_NETWORK, V\$ACTIVE_SERVICES and DGMGRL SHOW DATABASE.
Fields that cannot be discovered are omitted from the link, so the page
falls back to its own defaults - use the override flags to fill them in.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --primary-host)     PRIMARY_HOST_OVERRIDE="$2"; shift 2 ;;
        --standby-host)     STANDBY_HOST_OVERRIDE="$2"; shift 2 ;;
        --observer-host)    OBSERVER_HOST_OVERRIDE="$2"; shift 2 ;;
        --port)             PORT_OVERRIDE="$2"; shift 2 ;;
        --service)          SERVICE_OVERRIDE="$2"; shift 2 ;;
        --base-url)         DG_DOC_BASE_URL="$2"; export DG_DOC_BASE_URL; shift 2 ;;
        -q|--quiet)         QUIET="YES"; shift ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ============================================================
# Pre-flight
# ============================================================

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { [[ "$QUIET" == "YES" ]] || echo "WARN:  $*" >&2; }
info() { [[ "$QUIET" == "YES" ]] || echo "INFO:  $*" >&2; }

info "Starting: ORACLE_SID=${ORACLE_SID:-unset}, ORACLE_HOME=${ORACLE_HOME:-unset}"

[[ -n "$ORACLE_SID" ]]  || die "ORACLE_SID is not set."
[[ -n "$ORACLE_HOME" ]] || die "ORACLE_HOME is not set."
command -v sqlplus >/dev/null || die "sqlplus not on PATH ($ORACLE_HOME/bin/sqlplus expected)."
info "Pre-flight checks passed."

# ============================================================
# SQL / broker helpers
# ============================================================
# These mirror the discovery helpers in dg_handoff.sh; this script is
# deliberately standalone (no common/dg_functions.sh dependency) so it
# can be copied to a DB host on its own.

run_sql() {
    local sql="$1"
    sqlplus -s -L / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF VERIFY OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
WHENEVER SQLERROR EXIT 1
${sql}
EXIT;
EOF
}

clean() { tr -d ' \r' | sed '/^$/d'; }
# Like clean(), but keeps embedded spaces - used for values that contain
# them ("MAXIMUM AVAILABILITY", "PHYSICAL STANDBY") so the summary reads
# correctly; the visualizer mapping matches on substrings either way.
trim()  { tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d'; }
field() { awk -F'|' -v i="$2" '{print $i}' <<< "$1"; }

run_dgmgrl_cmd() {
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

# ============================================================
# Connectivity check
# ============================================================

info "Checking connectivity via 'sqlplus / as sysdba'..."
if ! run_sql "SELECT 'OK' FROM DUAL;" | clean | grep -q '^OK$'; then
    die "Could not connect via 'sqlplus / as sysdba' (ORACLE_SID=${ORACLE_SID})."
fi
info "Connected."

# ============================================================
# Discover topology
# ============================================================
# Every query below is best-effort: an undiscovered field is omitted from
# the link (the page then uses its own default), never a hard failure.
# `set -e` aborts on an unwrapped failing command substitution, hence the
# `|| { VAR=""; ... }` on each assignment.

failed() { warn "Discovery failed: $* (field omitted from the link)"; }

info "Discovering Data Guard topology from ${ORACLE_SID}..."

LOCAL_DB_UNIQUE_NAME=$(run_sql "SELECT DB_UNIQUE_NAME FROM V\$DATABASE;" | clean | head -1) \
    || { LOCAL_DB_UNIQUE_NAME=""; failed "local DB_UNIQUE_NAME"; }
[[ -n "$LOCAL_DB_UNIQUE_NAME" ]] || LOCAL_DB_UNIQUE_NAME="$ORACLE_SID"

DB_STATUS=$(run_sql "SELECT DATABASE_ROLE||'|'||PROTECTION_MODE FROM V\$DATABASE;" | trim | head -1) \
    || { DB_STATUS=""; failed "database role / protection mode"; }
DB_ROLE=$(field         "$DB_STATUS" 1)
PROTECTION_MODE=$(field "$DB_STATUS" 2)

DG_BROKER_START=$(run_sql "SELECT VALUE FROM V\$PARAMETER WHERE NAME='dg_broker_start';" | clean | head -1) \
    || { DG_BROKER_START=""; failed "dg_broker_start parameter"; }

# An empty peer is a legitimate outcome (no peer registered yet), so it is
# warned about below rather than treated as a discovery failure.
PEER_DB_UNIQUE_NAME=$(run_sql "SELECT DB_UNIQUE_NAME FROM V\$DATAGUARD_CONFIG WHERE DB_UNIQUE_NAME <> '${LOCAL_DB_UNIQUE_NAME}' AND ROWNUM=1;" | clean | head -1) \
    || { PEER_DB_UNIQUE_NAME=""; failed "peer DB_UNIQUE_NAME (V\$DATAGUARD_CONFIG)"; }
[[ -n "$PEER_DB_UNIQUE_NAME" ]] || warn "No peer found in V\$DATAGUARD_CONFIG; the diagram will show the primary only."

if [[ "$DB_ROLE" == "PRIMARY" ]]; then
    PRIMARY_DB_UNIQUE_NAME="$LOCAL_DB_UNIQUE_NAME"
    STANDBY_DB_UNIQUE_NAME="$PEER_DB_UNIQUE_NAME"
else
    warn "Local role is ${DB_ROLE:-unknown} (not PRIMARY); treating the local database as the standby."
    PRIMARY_DB_UNIQUE_NAME="$PEER_DB_UNIQUE_NAME"
    STANDBY_DB_UNIQUE_NAME="$LOCAL_DB_UNIQUE_NAME"
fi

# FSFO status + observer host (observer host is only populated while FSFO is on)
FSFO_RAW=$(run_sql "SELECT FS_FAILOVER_STATUS||'|'||FS_FAILOVER_OBSERVER_HOST FROM V\$DATABASE;" | clean | head -1) \
    || { FSFO_RAW=""; failed "fast-start failover status / observer host"; }
FSFO_STATUS=$(field        "$FSFO_RAW" 1)
FSFO_OBSERVER_HOST=$(field "$FSFO_RAW" 2)

# Listener port from the local listener registration. An empty result is
# legitimate (nothing registered yet) and falls back to the default port.
LOCAL_LISTENER_RAW=$(run_sql "SELECT VALUE FROM V\$LISTENER_NETWORK WHERE TYPE='LOCAL LISTENER' AND ROWNUM=1;" | clean | head -1) \
    || { LOCAL_LISTENER_RAW=""; failed "local listener port (V\$LISTENER_NETWORK)"; }
DISCOVERED_PORT=$(echo "$LOCAL_LISTENER_RAW" | sed -n 's/.*PORT *= *\([0-9][0-9]*\).*/\1/p' | head -1)
PORT="${PORT_OVERRIDE:-${DISCOVERED_PORT:-1521}}"

# First user-visible service (same exclusion list as the handoff reports)
SERVICE_OUTPUT=$(run_sql "
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
" | clean) || { SERVICE_OUTPUT=""; failed "active services list"; }

SERVICE_LIST=()
while IFS= read -r line; do
    [[ -n "$line" ]] && SERVICE_LIST+=("$line")
done <<< "$SERVICE_OUTPUT"
if [[ -n "$SERVICE_OVERRIDE" ]]; then
    SERVICE_LIST=("$SERVICE_OVERRIDE")
fi
info "Topology discovered: primary=${PRIMARY_DB_UNIQUE_NAME:-unknown}, standby=${STANDBY_DB_UNIQUE_NAME:-unknown}, port=${PORT}."

# ============================================================
# Broker-only fields (hostnames, transport mode, FSFO threshold)
# ============================================================

PRIMARY_HOSTNAME=""
STANDBY_HOSTNAME=""
STANDBY_LOGXPTMODE="unknown"
FSFO_THRESHOLD="unknown"

if [[ "$DG_BROKER_START" == "TRUE" ]]; then
    info "DG broker is running; querying dgmgrl for hostnames, LogXptMode and FSFO threshold..."
    [[ -n "$PRIMARY_DB_UNIQUE_NAME" ]] && PRIMARY_HOSTNAME=$(extract_host_from_show_db "$PRIMARY_DB_UNIQUE_NAME")
    [[ -n "$STANDBY_DB_UNIQUE_NAME" ]] && STANDBY_HOSTNAME=$(extract_host_from_show_db "$STANDBY_DB_UNIQUE_NAME")

    if [[ -n "$STANDBY_DB_UNIQUE_NAME" ]]; then
        STANDBY_LOGXPTMODE=$(run_dgmgrl_cmd "SHOW DATABASE '${STANDBY_DB_UNIQUE_NAME}' 'LogXptMode';" | parse_broker_property || true)
        [[ -n "$STANDBY_LOGXPTMODE" ]] || STANDBY_LOGXPTMODE="unknown"
    fi

    if [[ -n "$PRIMARY_DB_UNIQUE_NAME" ]]; then
        FSFO_THRESHOLD=$(run_dgmgrl_cmd "SHOW DATABASE '${PRIMARY_DB_UNIQUE_NAME}' 'FastStartFailoverThreshold';" | parse_broker_property || true)
    fi
    if [[ -z "$FSFO_THRESHOLD" || "$FSFO_THRESHOLD" == "unknown" ]]; then
        FSFO_THRESHOLD=$(run_dgmgrl_cmd "SHOW FAST_START FAILOVER;" | extract_fsfo_threshold || true)
    fi
    [[ -n "$FSFO_THRESHOLD" ]] || FSFO_THRESHOLD="unknown"
else
    warn "DG broker is not started (dg_broker_start=${DG_BROKER_START:-FALSE}); hostnames, LogXptMode and FSFO threshold cannot be auto-discovered."
fi

# Local OS hostname fills in the local side when the broker could not
OS_HOSTNAME=$(hostname 2>/dev/null) || OS_HOSTNAME=""
if [[ "$DB_ROLE" == "PRIMARY" ]]; then
    [[ -z "$PRIMARY_HOSTNAME" ]] && PRIMARY_HOSTNAME="$OS_HOSTNAME"
else
    [[ -z "$STANDBY_HOSTNAME" ]] && STANDBY_HOSTNAME="$OS_HOSTNAME"
fi

[[ -n "$PRIMARY_HOST_OVERRIDE" ]]  && PRIMARY_HOSTNAME="$PRIMARY_HOST_OVERRIDE"
[[ -n "$STANDBY_HOST_OVERRIDE" ]]  && STANDBY_HOSTNAME="$STANDBY_HOST_OVERRIDE"
[[ -n "$OBSERVER_HOST_OVERRIDE" ]] && FSFO_OBSERVER_HOST="$OBSERVER_HOST_OVERRIDE"

[[ -n "$PRIMARY_HOSTNAME" ]] || warn "Primary hostname unknown; pass --primary-host to show it in the diagram."
if [[ -z "$STANDBY_HOSTNAME" && -n "$STANDBY_DB_UNIQUE_NAME" ]]; then
    warn "Standby hostname unknown; pass --standby-host to show it in the diagram."
fi

# ---- begin dataguard-doc visualizer helpers ----
# Kept byte-identical in dg_handoff.sh and get_dg_config_url.sh
# (tests/test_visualizer_url.sh diffs the copies against the
# dg_handoff.sh reference). The handoff report links the discovered
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
# Output
# ============================================================

info "Building the visualizer link..."
if ! VIZ_URL=$(build_visualizer_url); then
    die "Could not build the link: neither 'base64' nor 'openssl' is available to encode the payload."
fi

if [[ "$QUIET" != "YES" ]]; then
    printf '\n' >&2
    printf 'Data Guard visualizer link\n' >&2
    printf '==========================\n' >&2
    printf '  %-18s %s\n' "Primary DB:"       "${PRIMARY_DB_UNIQUE_NAME:-n/a}" >&2
    printf '  %-18s %s\n' "Standby DB:"       "${STANDBY_DB_UNIQUE_NAME:-n/a}" >&2
    printf '  %-18s %s\n' "Primary host:"     "${PRIMARY_HOSTNAME:-n/a}" >&2
    printf '  %-18s %s\n' "Standby host:"     "${STANDBY_HOSTNAME:-n/a}" >&2
    printf '  %-18s %s\n' "Observer host:"    "${FSFO_OBSERVER_HOST:-n/a}" >&2
    printf '  %-18s %s\n' "Service:"          "${SERVICE_LIST[0]:-n/a}" >&2
    printf '  %-18s %s\n' "Listener port:"    "${PORT:-n/a}" >&2
    printf '  %-18s %s\n' "Protection mode:"  "${PROTECTION_MODE:-n/a}" >&2
    printf '  %-18s %s\n' "LogXptMode:"       "${STANDBY_LOGXPTMODE:-n/a}" >&2
    printf '  %-18s %s\n' "FSFO status:"      "${FSFO_STATUS:-n/a}" >&2
    printf '  %-18s %s\n' "FSFO threshold:"   "${FSFO_THRESHOLD:-n/a}" >&2
    printf '\n' >&2
    printf 'Open this configuration in the interactive Data Guard explorer:\n' >&2
    printf '\n' >&2
fi

printf '%s\n' "$VIZ_URL"
