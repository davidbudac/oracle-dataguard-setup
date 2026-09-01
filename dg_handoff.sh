#!/usr/bin/env bash
# ============================================================
# Data Guard Handoff Report - Standalone
# ============================================================
# Generates a Markdown handoff document for an existing Data
# Guard configuration. This is the ONE implementation of the handoff
# report: primary/10_generate_handoff_report.sh (walkthrough step 10)
# is a thin wrapper that feeds it the setup-time standby_config_*.env
# values and writes into the NFS share. On its own this script relies
# on neither - it discovers the topology from the database itself via
# SQL*Plus and DGMGRL.
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
# Optional header metadata (also settable via env for the step-10 variant,
# which takes no arguments): environment label (PROD/UAT/...) and a DBA
# contact line. Both end up as chips in the report header - a shared HTML
# report without an environment label is a mixup waiting to happen.
ENV_LABEL="${DG_HANDOFF_ENV:-}"
CONTACT_INFO="${DG_HANDOFF_CONTACT:-}"
# Optional TNS alias of the standby, resolvable from this host and backed by
# an auto-login wallet (common/setup_dg_wallet.sh). When set, the standby is
# queried directly for OPEN_MODE and V$DATAGUARD_STATS - facts the broker
# cannot supply (it cannot tell MOUNTED apart from "open read-only, no apply",
# and its lag fields can be stale). Best-effort: any failure is ignored.
STANDBY_TNS_ALIAS="${DG_HANDOFF_STANDBY_TNS_ALIAS:-}"
# Emit primary-only and standby-only connect strings in addition to the
# role-aware ones (setup-time step-10 behavior).
ALL_FLAVORS=0
# Path referenced by the "Full application behavior briefing" bullet; when
# empty the locally shipped docs/DG_APPLICATION_IMPACT.html is auto-detected.
IMPACT_REFERENCE_OVERRIDE=""

# ---- Machine-readable sidecar / deliverable pack -----------------------
# The JSON sidecar (<output>.json) records the discovered facts in a
# line-oriented layout that a POSIX-awk reader can parse back, and doubles
# as the baseline for the "Changes Since Last Report" section on the next
# run. --no-json skips it (and therefore the change tracking).
NO_JSON=0
# The deliverable pack (<output>_tnsnames.ora, <output>_jdbc.properties,
# <output>_verify.sh) is what an application team actually installs.
NO_PACK=0
# Explicit previous sidecar to diff against instead of the one at the
# JSON output path.
PREVIOUS_JSON_OVERRIDE=""

# ---- Descriptor retry knobs (single source of truth) -------------------
# The descriptor tables, the worst-case connect-time math, the pool-timeout
# advice, the JDBC strings and the Easy Connect Plus strings are all DERIVED
# from these four values, so overriding them here keeps the prose true.
# Defined before argument parsing so --connect-timeout & co. can override
# them BEFORE the WORST_*/ONE_PASS_MAX_S numbers are computed.
TNS_CT="${DG_HANDOFF_CONNECT_TIMEOUT:-10}"    # CONNECT_TIMEOUT seconds (per address)
TNS_TCT="${DG_HANDOFF_TRANSPORT_TIMEOUT:-3}"  # TRANSPORT_CONNECT_TIMEOUT seconds (per address)
TNS_RC="${DG_HANDOFF_RETRY_COUNT:-3}"         # RETRY_COUNT (extra passes over the ADDRESS_LIST)
TNS_RD="${DG_HANDOFF_RETRY_DELAY:-3}"         # RETRY_DELAY seconds between passes

# ---- Service filter ----------------------------------------------------
# Both accept a bare service name or a "container:service" form, matched
# case-insensitively and exactly. Applied after discovery, before the
# recommended-service / user-service-count derivations.
SERVICE_FILTER=()
SERVICE_EXCLUDE=()

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
      --standby-tns-alias A TNS alias of the standby, used for a best-effort
                            direct query of OPEN_MODE and V\$DATAGUARD_STATS
                            (auto-login wallet only, never prompts)
                            (env: DG_HANDOFF_STANDBY_TNS_ALIAS)
      --all-flavors         Also emit primary-only and standby-only TNS/JDBC
                            strings per service (default: role-aware only)
      --impact-reference P  Path to reference for the application impact
                            briefing instead of the auto-detected local copy
      --env LABEL           Environment label shown in the header (PROD, UAT, ...)
                            (env: DG_HANDOFF_ENV)
      --contact TEXT        DBA contact line shown in the header
                            (env: DG_HANDOFF_CONTACT)
      --service NAME        Restrict the report to this service (repeatable;
                            accepts NAME or CONTAINER:NAME, case-insensitive)
      --exclude-service N   Drop this service from the report (repeatable,
                            same matching rules as --service)
      --connect-timeout N   Descriptor CONNECT_TIMEOUT seconds (default ${TNS_CT})
                            (env: DG_HANDOFF_CONNECT_TIMEOUT)
      --transport-timeout N Descriptor TRANSPORT_CONNECT_TIMEOUT seconds
                            (default ${TNS_TCT}) (env: DG_HANDOFF_TRANSPORT_TIMEOUT)
      --retry-count N       Descriptor RETRY_COUNT (default ${TNS_RC})
                            (env: DG_HANDOFF_RETRY_COUNT)
      --retry-delay N       Descriptor RETRY_DELAY seconds (default ${TNS_RD})
                            (env: DG_HANDOFF_RETRY_DELAY)
      --previous FILE       Previous JSON sidecar to diff against instead of
                            the one at the default JSON output path
      --no-json             Do not write the JSON sidecar (also disables the
                            "Changes Since Last Report" section)
      --no-pack             Do not write the deliverable pack (_tnsnames.ora,
                            _jdbc.properties, _verify.sh)
  -h, --help                Show this help

Topology (DB_UNIQUE_NAMEs, peer hostnames, listener ports) is discovered from
V\$DATABASE, V\$DATAGUARD_CONFIG, V\$LISTENER_NETWORK and DGMGRL SHOW DATABASE.
Use the --*-host / --port flags when broker is not started or discovery
returns the wrong value.

Files written next to the Markdown report (<out> = output path without .md):
  <out>.md  <out>.html  <out>.json  <out>_tnsnames.ora
  <out>_jdbc.properties  <out>_verify.sh

Exit codes: 0 report generated and HEALTHY, 1 report generated with WARNING
verdict, 2 report generated with ERROR verdict, 3 usage or connection error.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)        OUTPUT_FILE="$2"; shift 2 ;;
        --primary-host)     PRIMARY_HOST_OVERRIDE="$2"; shift 2 ;;
        --standby-host)     STANDBY_HOST_OVERRIDE="$2"; shift 2 ;;
        --port)             PORT_OVERRIDE="$2"; shift 2 ;;
        --standby-tns-alias) STANDBY_TNS_ALIAS="$2"; shift 2 ;;
        --all-flavors)      ALL_FLAVORS=1; shift ;;
        --impact-reference) IMPACT_REFERENCE_OVERRIDE="$2"; shift 2 ;;
        --env)              ENV_LABEL="$2"; shift 2 ;;
        --contact)          CONTACT_INFO="$2"; shift 2 ;;
        --service)          SERVICE_FILTER+=("$2"); shift 2 ;;
        --exclude-service)  SERVICE_EXCLUDE+=("$2"); shift 2 ;;
        --connect-timeout)   TNS_CT="$2"; shift 2 ;;
        --transport-timeout) TNS_TCT="$2"; shift 2 ;;
        --retry-count)       TNS_RC="$2"; shift 2 ;;
        --retry-delay)       TNS_RD="$2"; shift 2 ;;
        --previous)         PREVIOUS_JSON_OVERRIDE="$2"; shift 2 ;;
        --no-json)          NO_JSON=1; shift ;;
        --no-pack)          NO_PACK=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 3 ;;
    esac
done

# Descriptor knobs must be non-negative integers: they are used in shell
# arithmetic (the worst-case math) and printed verbatim into descriptors.
for _pair in "CONNECT_TIMEOUT=${TNS_CT}" "TRANSPORT_CONNECT_TIMEOUT=${TNS_TCT}" \
             "RETRY_COUNT=${TNS_RC}" "RETRY_DELAY=${TNS_RD}"; do
    _name="${_pair%%=*}"
    _value="${_pair#*=}"
    case "$_value" in
        ''|*[!0-9]*)
            echo "ERROR: ${_name} must be a non-negative integer (got '${_value}')." >&2
            exit 3
            ;;
    esac
done

# ============================================================
# Pre-flight
# ============================================================

# Exit 3: preflight/usage failures, so monitoring can tell "could not run"
# (3) apart from "ran and found problems" (1 warning / 2 error).
die() { echo "ERROR: $*" >&2; exit 3; }
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

# Pull one lag line out of DGMGRL SHOW DATABASE output. 19c prints e.g.
#   Transport Lag:      0 seconds (computed 1 second ago)
# The value is returned verbatim (everything after the colon, trimmed) - the
# "(computed ...)" part is real information for the reader and is kept.
# $1 = broker output, $2 = label ("Transport Lag" / "Apply Lag").
extract_broker_lag_text() {
    printf '%s\n' "$1" | awk -v want="$2" '
        BEGIN { want = tolower(want) ":" }
        {
            lower = tolower($0)
            idx = index(lower, want)
            if (idx > 0) {
                rest = substr($0, idx + length(want))
                gsub(/^[[:space:]]*/, "", rest)
                gsub(/[[:space:]]*$/, "", rest)
                if (rest != "") { print rest; exit }
            }
        }
    '
}

# Convert a broker lag text ("0 seconds", "2 minutes 3 seconds") to whole
# seconds. Anything from the first "(" on is dropped first: the trailing
# "(computed 1 second ago)" is not part of the lag. Prints nothing when the
# text carries no <number> <unit> pair (e.g. "(unknown)").
lag_text_to_seconds() {
    printf '%s\n' "$1" | awk '
        {
            s = tolower($0)
            sub(/\(.*$/, "", s)
            total = 0
            found = 0
            n = split(s, w, /[^a-z0-9]+/)
            for (i = 1; i < n; i = i + 1) {
                if (w[i] ~ /^[0-9][0-9]*$/) {
                    mult = 0
                    if (w[i+1] ~ /^second/) mult = 1
                    else if (w[i+1] ~ /^minute/) mult = 60
                    else if (w[i+1] ~ /^hour/) mult = 3600
                    else if (w[i+1] ~ /^day/) mult = 86400
                    if (mult > 0) { total = total + w[i] * mult; found = 1 }
                }
            }
            if (found) print total
            exit
        }
    '
}

# Convert a V$DATAGUARD_STATS interval value ("+00 00:00:03") to seconds.
# Prints nothing when the value is NULL/unparsable.
dg_interval_to_seconds() {
    printf '%s\n' "$1" | awk '
        {
            if (match($0, /[0-9]+ [0-9]+:[0-9]+:[0-9]+/)) {
                v = substr($0, RSTART, RLENGTH)
                split(v, a, / /)
                split(a[2], t, /:/)
                print a[1] * 86400 + t[1] * 3600 + t[2] * 60 + t[3]
            }
            exit
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

if ! run_sql "-- QTAG:connect_check
SELECT 'OK' FROM DUAL;" | clean | grep -q '^OK$'; then
    die "Could not connect via 'sqlplus / as sysdba' (ORACLE_SID=${ORACLE_SID})."
fi

# ============================================================
# Discover topology
# ============================================================

info "Discovering Data Guard topology from ${ORACLE_SID}..."

if ! LOCAL_DB_UNIQUE_NAME=$(run_sql "-- QTAG:local_db_unique_name
SELECT DB_UNIQUE_NAME FROM V\$DATABASE;" | clean | head -1); then
    LOCAL_DB_UNIQUE_NAME=""
    note_discovery_failure "local DB_UNIQUE_NAME"
fi
if [[ -z "$LOCAL_DB_UNIQUE_NAME" ]]; then
    LOCAL_DB_UNIQUE_NAME="$ORACLE_SID"
fi

if ! DB_STATUS=$(run_sql "-- QTAG:db_status
SELECT DATABASE_ROLE||'|'||OPEN_MODE||'|'||PROTECTION_MODE||'|'||SWITCHOVER_STATUS FROM V\$DATABASE;" | clean | head -1); then
    DB_STATUS=""
    note_discovery_failure "database role/open-mode/protection-mode/switchover-status"
fi
DB_ROLE=$(field          "$DB_STATUS" 1)
OPEN_MODE=$(field        "$DB_STATUS" 2)
PROTECTION_MODE=$(field  "$DB_STATUS" 3)
SWITCHOVER_STATUS=$(field "$DB_STATUS" 4)

if ! FORCE_LOGGING=$(run_sql "-- QTAG:force_logging
SELECT FORCE_LOGGING FROM V\$DATABASE;" | clean | head -1); then
    FORCE_LOGGING=""
    note_discovery_failure "force logging status"
fi

if ! DG_BROKER_START=$(run_sql "-- QTAG:dg_broker_start
SELECT VALUE FROM V\$PARAMETER WHERE NAME='dg_broker_start';" | clean | head -1); then
    DG_BROKER_START=""
    note_discovery_failure "dg_broker_start parameter"
fi

# Peer DB_UNIQUE_NAME from V$DATAGUARD_CONFIG (everything except local).
# An empty result here is a legitimate outcome (no peer registered yet), not
# necessarily a query failure, so it is reported via the existing warn()
# below rather than added to the discovery-failure list.
if ! PEER_DB_UNIQUE_NAME=$(run_sql "-- QTAG:peer_db_unique_name
SELECT DB_UNIQUE_NAME FROM V\$DATAGUARD_CONFIG WHERE DB_UNIQUE_NAME <> '${LOCAL_DB_UNIQUE_NAME}' AND ROWNUM=1;" | clean | head -1); then
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
if ! APPLY_INFO=$(run_sql "-- QTAG:apply_info
SELECT NVL(MAX(CASE WHEN APPLIED='YES' THEN SEQUENCE# END),0)||'|'||NVL(MAX(SEQUENCE#),0) FROM V\$ARCHIVED_LOG WHERE THREAD#=1;" | clean | head -1); then
    APPLY_INFO=""
    note_discovery_failure "archived log apply/receive sequence#"
fi
LAST_APPLIED=$(field  "$APPLY_INFO" 1)
LAST_RECEIVED=$(field "$APPLY_INFO" 2)
APPLY_LAG_SEQ=$(( ${LAST_RECEIVED:-0} - ${LAST_APPLIED:-0} ))

if ! GAP_COUNT=$(run_sql "-- QTAG:archive_gap_count
SELECT COUNT(*) FROM V\$ARCHIVE_GAP;" | clean | head -1); then
    GAP_COUNT=""
    note_discovery_failure "archive gap count"
fi
GAP_COUNT="${GAP_COUNT:-0}"

# FSFO
if ! FSFO_RAW=$(run_sql "-- QTAG:fsfo_status
SELECT FS_FAILOVER_STATUS||'|'||FS_FAILOVER_OBSERVER_PRESENT||'|'||FS_FAILOVER_OBSERVER_HOST FROM V\$DATABASE;" | clean | head -1); then
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

if ! TRIGGER_STATUS=$(run_sql "-- QTAG:role_trigger_status
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
if ! LOCAL_LISTENER_RAW=$(run_sql "-- QTAG:local_listener
SELECT VALUE FROM V\$LISTENER_NETWORK WHERE TYPE='LOCAL LISTENER' AND ROWNUM=1;" | clean | head -1); then
    LOCAL_LISTENER_RAW=""
    note_discovery_failure "local listener port (V\$LISTENER_NETWORK)"
fi
DISCOVERED_PORT=$(echo "$LOCAL_LISTENER_RAW" | sed -n 's/.*PORT *= *\([0-9][0-9]*\).*/\1/p' | head -1)
PORT="${PORT_OVERRIDE:-${DISCOVERED_PORT:-1521}}"

# CDB flag, server version, character set, db_domain: all client-facing facts
# (driver choice, NLS handling, alias qualification) - each best-effort.
if ! IS_CDB=$(run_sql "-- QTAG:is_cdb
SELECT CDB FROM V\$DATABASE;" | clean | head -1); then
    IS_CDB=""
    note_discovery_failure "CDB flag (V\$DATABASE.CDB)"
fi
# VERSION_FULL carries the RU (19.23 vs 19.0); older dictionaries only have
# VERSION, so fall back rather than fail.
if ! DB_VERSION=$(run_sql "-- QTAG:db_version_full
SELECT VERSION_FULL FROM V\$INSTANCE;" | clean | head -1); then
    DB_VERSION=$(run_sql "-- QTAG:db_version
SELECT VERSION FROM V\$INSTANCE;" | clean | head -1) || DB_VERSION=""
    [[ -z "$DB_VERSION" ]] && note_discovery_failure "database version (V\$INSTANCE)"
fi
if ! DB_CHARSET=$(run_sql "-- QTAG:db_charset
SELECT VALUE FROM NLS_DATABASE_PARAMETERS WHERE PARAMETER='NLS_CHARACTERSET';" | clean | head -1); then
    DB_CHARSET=""
    note_discovery_failure "database character set (NLS_DATABASE_PARAMETERS)"
fi
# Empty db_domain is a legitimate outcome, not a discovery failure.
DB_DOMAIN=$(run_sql "-- QTAG:db_domain
SELECT VALUE FROM V\$PARAMETER WHERE NAME='db_domain';" | clean | head -1) || DB_DOMAIN=""

# ============================================================
# Discover hostnames via DGMGRL (best-effort)
# ============================================================

PRIMARY_HOSTNAME=""
STANDBY_HOSTNAME=""
BROKER_OUTPUT=""
STANDBY_SHOW_OUTPUT=""
STANDBY_LOGXPTMODE="unknown"
STANDBY_OPEN_MODE="unknown"
FSFO_THRESHOLD="unknown"
# Lag as reported by the broker (works without any standby connection) and,
# when --standby-tns-alias is given, refined from the standby's own
# V$DATAGUARD_STATS. Text is what the report prints; the numeric seconds
# drive the verdict. Empty seconds = not discovered.
APPLY_LAG_TEXT="unknown"
TRANSPORT_LAG_TEXT="unknown"
APPLY_LAG_SECONDS=""
TRANSPORT_LAG_SECONDS=""

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

# ============================================================
# Lag: broker text first, standby's own view second
# ============================================================

# The broker's SHOW DATABASE output carries both lag values and needs no
# connection to the standby, so this works even when no wallet exists.
if [[ -n "$STANDBY_SHOW_OUTPUT" ]]; then
    _t=$(extract_broker_lag_text "$STANDBY_SHOW_OUTPUT" "Transport Lag")
    _a=$(extract_broker_lag_text "$STANDBY_SHOW_OUTPUT" "Apply Lag")
    [[ -n "$_t" ]] && TRANSPORT_LAG_TEXT="$_t"
    [[ -n "$_a" ]] && APPLY_LAG_TEXT="$_a"
    TRANSPORT_LAG_SECONDS=$(lag_text_to_seconds "$TRANSPORT_LAG_TEXT")
    APPLY_LAG_SECONDS=$(lag_text_to_seconds "$APPLY_LAG_TEXT")
fi

# Direct standby query (best effort, never prompts): the broker's Real Time
# Query flag cannot tell MOUNTED apart from "open read-only, apply off", and
# its lag fields can be stale. With an auto-login wallet for the standby TNS
# alias (common/setup_dg_wallet.sh) the standby answers for itself. -L means
# "no retry on failed logon", the heredoc supplies stdin: no password prompt
# is possible. Any failure leaves the broker-derived values in place.
if [[ -n "$STANDBY_TNS_ALIAS" ]]; then
    STANDBY_DIRECT_OUTPUT=$(sqlplus -s -L /@"${STANDBY_TNS_ALIAS}" as sysdba <<'EOSQL' 2>/dev/null || true
SET HEADING OFF FEEDBACK OFF VERIFY OFF PAGESIZE 0 LINESIZE 200 TRIMSPOOL ON
WHENEVER SQLERROR EXIT 1
-- QTAG:standby_direct
SELECT 'OPENMODE=' || OPEN_MODE FROM V$DATABASE;
SELECT 'DGSTAT=' || NAME || '=' || VALUE FROM V$DATAGUARD_STATS
 WHERE NAME IN ('apply lag', 'transport lag');
EXIT;
EOSQL
)
    _direct_open=$( { printf '%s\n' "$STANDBY_DIRECT_OUTPUT" | grep 'OPENMODE=' || true; } \
        | sed 's/.*OPENMODE=//' | head -1 | clean)
    if [[ -n "$_direct_open" ]]; then
        info "Standby OPEN_MODE read directly from ${STANDBY_TNS_ALIAS}: ${_direct_open}"
        STANDBY_OPEN_MODE="$_direct_open"
    else
        warn "Direct standby query via ${STANDBY_TNS_ALIAS} returned no OPEN_MODE (wallet/alias/standby down?); using broker-derived values."
    fi
    # V$DATAGUARD_STATS values are interval strings like '+00 00:00:03'.
    # They come from the standby itself, so they win over the broker text.
    _dg_apply=$( { printf '%s\n' "$STANDBY_DIRECT_OUTPUT" | grep 'DGSTAT=apply lag=' || true; } \
        | sed 's/.*DGSTAT=apply lag=//' | head -1)
    _dg_transport=$( { printf '%s\n' "$STANDBY_DIRECT_OUTPUT" | grep 'DGSTAT=transport lag=' || true; } \
        | sed 's/.*DGSTAT=transport lag=//' | head -1)
    _secs=$(dg_interval_to_seconds "$_dg_apply")
    if [[ -n "$_secs" ]]; then
        APPLY_LAG_SECONDS="$_secs"
        APPLY_LAG_TEXT="${_secs} seconds"
    fi
    _secs=$(dg_interval_to_seconds "$_dg_transport")
    if [[ -n "$_secs" ]]; then
        TRANSPORT_LAG_SECONDS="$_secs"
        TRANSPORT_LAG_TEXT="${_secs} seconds"
    fi
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

# Services are discovered as (container, name, class) triples so the report
# can (a) tell the reader which container - CDB root or which PDB - a service
# lands in, and (b) separate USER services (creatable/stoppable, i.e. what the
# role trigger manages) from DEFAULT services. A container's default service
# (DB_NAME[.DB_DOMAIN], DB_UNIQUE_NAME, instance name for root; the PDB name
# for a PDB) is always registered wherever the container is up - the role
# trigger deliberately excludes it, so it can NEVER be role-aware and must not
# be handed to applications as a failover descriptor.
#
# V$CONTAINERS works on non-CDB too (single CON_ID=0 row), so one query
# covers both architectures. An empty result is a legitimate outcome; only a
# real run_sql failure (ORA- under WHENEVER SQLERROR EXIT 1) is a discovery
# failure.
if ! SERVICE_OUTPUT=$(run_sql "-- QTAG:active_services
SELECT c.NAME || '|' || s.NAME || '|' ||
       CASE WHEN UPPER(s.NAME) IN (
           UPPER(c.NAME),
           UPPER(c.NAME) || '.' || (SELECT UPPER(VALUE) FROM V\$PARAMETER WHERE NAME = 'db_domain'),
           (SELECT UPPER(DB_UNIQUE_NAME) FROM V\$DATABASE),
           (SELECT UPPER(NAME) FROM V\$DATABASE),
           (SELECT UPPER(NAME) || '.' || (SELECT UPPER(VALUE) FROM V\$PARAMETER WHERE NAME = 'db_domain') FROM V\$DATABASE),
           (SELECT UPPER(DB_UNIQUE_NAME) || '.' || (SELECT UPPER(VALUE) FROM V\$PARAMETER WHERE NAME = 'db_domain') FROM V\$DATABASE),
           (SELECT UPPER(INSTANCE_NAME) FROM V\$INSTANCE)
       ) THEN 'DEFAULT' ELSE 'USER' END
FROM V\$ACTIVE_SERVICES s
JOIN V\$CONTAINERS c ON s.CON_ID = c.CON_ID
WHERE s.NAME NOT LIKE 'SYS\$%'
  AND UPPER(s.NAME) NOT LIKE '%XDB%'
  AND UPPER(s.NAME) NOT LIKE '%\_CFG' ESCAPE '\'
  AND UPPER(s.NAME) NOT LIKE '%\_DGMGRL' ESCAPE '\'
  AND c.NAME <> 'PDB\$SEED'
ORDER BY s.CON_ID, s.NAME;
" | clean); then
    SERVICE_OUTPUT=""
    note_discovery_failure "active services list (report will show no per-service connection strings)"
fi

# Parallel indexed arrays (no bash-4 associative arrays - AIX portability),
# ordered USER services first: they are the ones applications should get.
SERVICE_LIST=()
SERVICE_CON=()
SERVICE_CLASS=()
_def_list=()
_def_con=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    _con=$(field "$line" 1)
    _svc=$(field "$line" 2)
    _cls=$(field "$line" 3)
    [[ -z "$_svc" ]] && continue
    if [[ "$_cls" == "USER" ]]; then
        SERVICE_LIST+=("$_svc")
        SERVICE_CON+=("$_con")
        SERVICE_CLASS+=("USER")
    else
        _def_list+=("$_svc")
        _def_con+=("$_con")
    fi
done <<< "$SERVICE_OUTPUT"
_i=0
while [[ $_i -lt ${#_def_list[@]} ]]; do
    SERVICE_LIST+=("${_def_list[$_i]}")
    SERVICE_CON+=("${_def_con[$_i]}")
    SERVICE_CLASS+=("DEFAULT")
    _i=$((_i + 1))
done

# Guarantee at least one entry so the report always carries a connect string,
# even before any service is created: the default db_unique_name service.
if [[ ${#SERVICE_LIST[@]} -eq 0 && -n "$LOCAL_DB_UNIQUE_NAME" ]]; then
    _svc="$LOCAL_DB_UNIQUE_NAME"
    [[ -n "$DB_DOMAIN" ]] && _svc="${_svc}.${DB_DOMAIN}"
    SERVICE_LIST=("$_svc")
    SERVICE_CON=("")
    SERVICE_CLASS=("DEFAULT")
fi

# ------------------------------------------------------------
# Service filter (--service / --exclude-service)
# ------------------------------------------------------------
# Applied here, i.e. after discovery but BEFORE RECOMMENDED_SVC and
# USER_SERVICE_COUNT are derived, so the verdict, the driver examples and
# the deliverable pack all see exactly the filtered set.
SERVICE_FILTER_ACTIVE=0
if [[ ${#SERVICE_FILTER[@]} -gt 0 || ${#SERVICE_EXCLUDE[@]} -gt 0 ]]; then
    SERVICE_FILTER_ACTIVE=1
fi

# Case-insensitive exact match of one filter token against a discovered
# service. A token containing ':' is a CONTAINER:SERVICE pair, used to
# disambiguate the same service name living in two PDBs.
_svc_matches_token() {
    local con="$1" svc="$2" token="$3" t_con="" t_svc="$3"
    case "$token" in
        *:*) t_con="${token%%:*}"; t_svc="${token#*:}" ;;
    esac
    local lc_con lc_svc lt_con lt_svc
    lc_con=$(printf '%s' "$con"   | tr '[:upper:]' '[:lower:]')
    lc_svc=$(printf '%s' "$svc"   | tr '[:upper:]' '[:lower:]')
    lt_con=$(printf '%s' "$t_con" | tr '[:upper:]' '[:lower:]')
    lt_svc=$(printf '%s' "$t_svc" | tr '[:upper:]' '[:lower:]')
    [[ "$lc_svc" == "$lt_svc" ]] || return 1
    [[ -z "$lt_con" || "$lc_con" == "$lt_con" ]]
}

if [[ $SERVICE_FILTER_ACTIVE -eq 1 ]]; then
    _f_list=()
    _f_con=()
    _f_class=()
    _matched_tokens=""
    _i=0
    while [[ $_i -lt ${#SERVICE_LIST[@]} ]]; do
        _svc="${SERVICE_LIST[$_i]}"
        _con="${SERVICE_CON[$_i]}"
        _cls="${SERVICE_CLASS[$_i]}"
        _i=$((_i + 1))
        _keep=1
        if [[ ${#SERVICE_FILTER[@]} -gt 0 ]]; then
            _keep=0
            for _tok in "${SERVICE_FILTER[@]}"; do
                if _svc_matches_token "$_con" "$_svc" "$_tok"; then
                    _keep=1
                    _matched_tokens="${_matched_tokens}|${_tok}|"
                fi
            done
        fi
        if [[ $_keep -eq 1 && ${#SERVICE_EXCLUDE[@]} -gt 0 ]]; then
            for _tok in "${SERVICE_EXCLUDE[@]}"; do
                if _svc_matches_token "$_con" "$_svc" "$_tok"; then
                    _keep=0
                fi
            done
        fi
        if [[ $_keep -eq 1 ]]; then
            _f_list+=("$_svc")
            _f_con+=("$_con")
            _f_class+=("$_cls")
        fi
    done
    SERVICE_LIST=("${_f_list[@]:-}")
    SERVICE_CON=("${_f_con[@]:-}")
    SERVICE_CLASS=("${_f_class[@]:-}")
    # `("${arr[@]:-}")` on an empty array yields one empty element - drop it.
    if [[ ${#SERVICE_LIST[@]} -eq 1 && -z "${SERVICE_LIST[0]}" ]]; then
        SERVICE_LIST=()
        SERVICE_CON=()
        SERVICE_CLASS=()
    fi

    # A --service that matched nothing is a real operator error: report it,
    # record it as a discovery warning, and let the verdict pick it up.
    SERVICE_FILTER_MISSES=()
    if [[ ${#SERVICE_FILTER[@]} -gt 0 ]]; then
        for _tok in "${SERVICE_FILTER[@]}"; do
            case "$_matched_tokens" in
                *"|${_tok}|"*) ;;
                *)
                    SERVICE_FILTER_MISSES+=("$_tok")
                    note_discovery_failure "requested service '${_tok}' not found among active services"
                    ;;
            esac
        done
    fi
    info "Service filter active: ${#SERVICE_LIST[@]} service(s) kept."
fi
[[ -n "${SERVICE_FILTER_MISSES+x}" ]] || SERVICE_FILTER_MISSES=()

# First USER (role-manageable) service, if any - drives the driver examples
# and the verification connect string.
RECOMMENDED_SVC=""
_i=0
while [[ $_i -lt ${#SERVICE_LIST[@]} ]]; do
    if [[ "${SERVICE_CLASS[$_i]}" == "USER" ]]; then
        RECOMMENDED_SVC="${SERVICE_LIST[$_i]}"
        break
    fi
    _i=$((_i + 1))
done
USER_SERVICE_COUNT=0
_i=0
while [[ $_i -lt ${#SERVICE_LIST[@]} ]]; do
    [[ "${SERVICE_CLASS[$_i]}" == "USER" ]] && USER_SERVICE_COUNT=$((USER_SERVICE_COUNT + 1))
    _i=$((_i + 1))
done

info "Services in report: ${SERVICE_LIST[*]} (${USER_SERVICE_COUNT} user service(s))"

# Per-service HA attributes from CDB_SERVICES (= DBA_SERVICES plus CON_ID;
# works on non-CDB too). These decide what the report can promise about TAF,
# Transaction Guard and Application Continuity - stated as discovered facts
# instead of \"where the DBA configured it\" hedging. Best-effort: a failure
# degrades to an 'unknown' row per service.
if ! SERVICE_ATTR_OUTPUT=$(run_sql "-- QTAG:service_ha_attributes
SELECT c.NAME || '|' || s.NAME || '|' ||
       NVL(s.FAILOVER_TYPE, 'NONE') || '|' ||
       NVL(s.FAILOVER_METHOD, '-') || '|' ||
       NVL(TO_CHAR(s.FAILOVER_RETRIES), '-') || '|' ||
       NVL(TO_CHAR(s.FAILOVER_DELAY), '-') || '|' ||
       NVL(s.COMMIT_OUTCOME, 'false') || '|' ||
       NVL(TO_CHAR(s.DRAIN_TIMEOUT), '-') || '|' ||
       NVL(s.FAILOVER_RESTORE, 'NONE')
FROM CDB_SERVICES s
JOIN V\$CONTAINERS c ON s.CON_ID = c.CON_ID
WHERE s.NAME NOT LIKE 'SYS\$%';
" | clean); then
    SERVICE_ATTR_OUTPUT=""
    note_discovery_failure "service HA attributes (CDB_SERVICES: TAF/COMMIT_OUTCOME/DRAIN_TIMEOUT)"
fi

# Print the pipe-joined attribute record for (container, service); empty when
# unknown. Exact-match on both fields (service names may contain dots), but
# case-insensitive: the dictionary stores a PDB default service as 'PDB1'
# while V$ACTIVE_SERVICES registers it as 'pdb1'.
service_attrs() {
    printf '%s\n' "$SERVICE_ATTR_OUTPUT" | awk -F'|' -v c="$1" -v s="$2" '
        BEGIN { c = toupper(c); s = toupper(s) }
        toupper($1) == c && toupper($2) == s { print; exit }
        c == "" && toupper($2) == s { print; exit }
    '
}

SQLNET_EXPIRE_TIME=$(get_sqlnet_expire_time)

RPO_STATEMENT="RPO unknown: protection mode or standby transport mode could not be discovered. Treat every failover as potentially lossy until the DBA team confirms the transport mode."
case "$(printf '%s' "$PROTECTION_MODE" | tr '[:lower:]' '[:upper:]')|$(printf '%s' "$STANDBY_LOGXPTMODE" | tr '[:lower:]' '[:upper:]')" in
    *MAXIMUM*AVAILABILITY*'|'SYNC)
        RPO_STATEMENT="RPO = 0 while synchronized: protection is ${PROTECTION_MODE}, standby transport SYNC. A commit is not acknowledged to the client until the standby has written the redo to its standby redo log on disk, so a failover loses no committed transactions. If the standby becomes unreachable the primary continues alone; a failover during that window loses the redo generated since the disconnect. Cost: every commit carries one primary-to-standby network round trip plus the standby redo disk write."
        ;;
    *MAXIMUM*AVAILABILITY*'|'FASTSYNC)
        RPO_STATEMENT="RPO = 0 while synchronized: protection is ${PROTECTION_MODE}, standby transport FASTSYNC. A commit is not acknowledged to the client until the standby confirms redo receipt into memory (before its disk write - a simultaneous failure of BOTH hosts can lose that in-flight redo, single-host failures cannot), so a failover loses no committed transactions. If the standby becomes unreachable the primary continues alone; a failover during that window loses the redo generated since the disconnect. Cost: every commit carries one primary-to-standby network round trip."
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

# TNS_CT / TNS_TCT / TNS_RC / TNS_RD are the single source of truth for the
# descriptor's retry knobs and are set (with env + --connect-timeout &c.
# overrides) in the defaults block at the top of this script, so the numbers
# below are derived from whatever the caller asked for. The Easy Connect Plus
# form uses the SAME values (it used to differ, which silently gave
# ODP.NET/python/SQLAlchemy clients different behavior than the documented
# TNS descriptor).
# Worst-case time until the driver errors out:
#  - both hosts unreachable: TCP timeout on both addresses, every pass
WORST_BOTH_S=$(( 2 * TNS_TCT * (TNS_RC + 1) + TNS_RC * TNS_RD ))
#  - primary host down, standby listener up but service stopped there:
#    TCP timeout on the primary + immediate ORA-12514 on the standby, per pass
WORST_PRI_S=$(( TNS_TCT * (TNS_RC + 1) + TNS_RC * TNS_RD ))
# One pass over the list with hosts up but hung handshakes is bounded by
# CONNECT_TIMEOUT per address:
ONE_PASS_MAX_S=$(( 2 * TNS_CT ))

render_tns_ha() {
    local alias="$1" phost="$2" shost="$3" port="$4" service="$5"
    cat <<EOF
${alias} =
  (DESCRIPTION =
    (CONNECT_TIMEOUT = ${TNS_CT})(TRANSPORT_CONNECT_TIMEOUT = ${TNS_TCT})(RETRY_COUNT = ${TNS_RC})(RETRY_DELAY = ${TNS_RD})
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

# Single-host descriptors, emitted only with --all-flavors: one address, no
# retry knobs (there is nothing to fail over to). The role-aware descriptor
# above stays the one applications should get.
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

render_jdbc_single() {
    local host="$1" port="$2" service="$3"
    echo "jdbc:oracle:thin:@//${host}:${port}/${service}"
}

render_jdbc_ha() {
    local phost="$1" shost="$2" port="$3" service="$4"
    printf 'jdbc:oracle:thin:@(DESCRIPTION=(CONNECT_TIMEOUT=%s)(TRANSPORT_CONNECT_TIMEOUT=%s)(RETRY_COUNT=%s)(RETRY_DELAY=%s)(ADDRESS_LIST=(LOAD_BALANCE=OFF)(ADDRESS=(PROTOCOL=TCP)(HOST=%s)(PORT=%s))(ADDRESS=(PROTOCOL=TCP)(HOST=%s)(PORT=%s)))(CONNECT_DATA=(SERVICE_NAME=%s)))\n' \
        "$TNS_CT" "$TNS_TCT" "$TNS_RC" "$TNS_RD" "$phost" "$port" "$shost" "$port" "$service"
}

# retry_delay is deliberately omitted: not every 19c client parses it in the
# Easy Connect form, and an unknown parameter aborts the connect. Retries are
# therefore back-to-back here - slightly faster to error than the TNS form.
render_easy_connect_ha() {
    local phost="$1" shost="$2" port="$3" service="$4"
    printf '%s:%s,%s:%s/%s?connect_timeout=%s&transport_connect_timeout=%s&retry_count=%s\n' \
        "$phost" "$port" "$shost" "$port" "$service" "$TNS_CT" "$TNS_TCT" "$TNS_RC"
}

# Driver-specific forms as stacked labeled code blocks (each gets its own
# copy button in the HTML twin; the old table clipped/nowrapped the strings).
render_driver_examples() {
    local ez="$1"
    printf '**ODP.NET**\n\n```\nUser Id=app_user;Password=<pwd>;Data Source=%s\n```\n\n' "$ez"
    printf '**python-oracledb**\n\n```\noracledb.connect(user="app_user", password="<pwd>", dsn="%s")\n```\n\n' "$ez"
    printf '**SQLAlchemy**\n\n```\noracle+oracledb://app_user:<pwd>@%s\n```\n\n' "$ez"
    printf '**SQL*Plus**\n\n```\nsqlplus app_user/<pwd>@'\''%s'\''\n```\n\n' "$ez"
}

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

# ---- begin handoff html renderer ----
# Lives ONLY here: dg_handoff.sh owns the report and its renderer, and
# primary/10_generate_handoff_report.sh is a thin wrapper around this
# script (there is no second copy to keep in sync any more).
# The Markdown emitter stays the single definition of the report;
# handoff_md_to_html converts exactly the Markdown subset it produces
# (h1-h4, pipe tables, bullets with two-space continuations and "- [ ]"
# checklist items, fenced code blocks, blockquotes, **bold**, `code`,
# [text](url) links) into HTML.
# POSIX awk only - no gensub, AIX-safe: AIX 7.2 /usr/bin/awk aborts with
# "0602-558 cannot be used as an array" instead of coping, so every array
# is seeded in BEGIN (no name is first subscripted inside a function body
# or first touched by a read, and no function declares a local array) and
# table cells are keyed with an explicit "row|col" string rather than a
# multi-subscript (SUBSEP) reference.
#
# Presentation upgrades happen here (the Markdown itself is unchanged):
# the meta list under the H1 becomes a chip strip (CSS h1+ul), the
# "**Verdict:** X" paragraph becomes a colored status pill, "**WARNING:**"
# paragraphs and blockquotes become amber callouts, "- [ ]" items render
# as checklist boxes, and every fenced block gets a copy button.
#
# Also emitted here:
#   * Heading anchors + table of contents. Every h2/h3 gets a slugified,
#     de-duplicated id; the whole document is buffered into out[] so a
#     <nav class="toc"> listing the h2s (with their h3s nested) can be
#     spliced in right after the H1 meta chip strip, wrapped with the
#     body in <div class="layout"> - a sticky sidebar at >= 1100px, a
#     collapsible <details> block below that.
#   * A print stylesheet (white ground, no chrome, one h2 per page).
#   * A staleness banner: body carries data-stale-days="N" (from
#     DG_HANDOFF_STALE_DAYS, default 30) and a few lines of inline JS
#     compare it against the "Generated:" meta chip. No JS, no banner.
#   * Overridable branding, all optional, defaults reproduce the previous
#     output byte for byte:
#       DG_HANDOFF_BRAND_NAME        eyebrow text and logo alt
#       DG_HANDOFF_BRAND_LOGO        image file to inline as a data: URI,
#                                    or "none" to drop the logo
#       DG_HANDOFF_BRAND_COLOR       light-theme accent      (#0099CC)
#       DG_HANDOFF_BRAND_INK         dark ink                (#003366)
#       DG_HANDOFF_BRAND_TINT        soft tint               (#DCEFF7)
#       DG_HANDOFF_BRAND_DARK_ACCENT dark-theme accent       (#80CCE6)

handoff_md_to_html() {
    awk '
    function esc(s) {
        gsub(/&/, "\\&amp;", s)
        gsub(/</, "\\&lt;", s)
        gsub(/>/, "\\&gt;", s)
        return s
    }
    function inline_fmt(s,   out2, m, p, txt, url) {
        out2 = ""
        while (match(s, /\[[^\]]+\]\([^)]+\)/)) {
            m = substr(s, RSTART, RLENGTH)
            p = index(m, "](")
            txt = substr(m, 2, p - 2)
            url = substr(m, p + 2, length(m) - p - 2)
            out2 = out2 substr(s, 1, RSTART-1) "<a href=\"" url "\">" txt "</a>"
            s = substr(s, RSTART+RLENGTH)
        }
        s = out2 s
        out2 = ""
        while (match(s, /\*\*[^*]+\*\*/)) {
            out2 = out2 substr(s, 1, RSTART-1) "<strong>" substr(s, RSTART+2, RLENGTH-4) "</strong>"
            s = substr(s, RSTART+RLENGTH)
        }
        s = out2 s
        out2 = ""
        while (match(s, /`[^`]+`/)) {
            out2 = out2 substr(s, 1, RSTART-1) "<code>" substr(s, RSTART+1, RLENGTH-2) "</code>"
            s = substr(s, RSTART+RLENGTH)
        }
        return out2 s
    }
    function trimcell(s) {
        sub(/^[ \t]+/, "", s)
        sub(/[ \t]+$/, "", s)
        return s
    }
    # Output is buffered (out[]/on) so the table of contents can be
    # spliced in after the meta chip strip once every heading is known.
    function emit(s) { on = on + 1; out[on] = s }
    function emitcat(s) { if (on == 0) emit(s); else out[on] = out[on] s }
    # Drop the Markdown markup a heading may carry, keeping the text
    # (and any HTML entity esc() already produced).
    function stripmd(s) {
        while (match(s, /\]\([^)]*\)/))
            s = substr(s, 1, RSTART-1) substr(s, RSTART+RLENGTH)
        gsub(/[][]/, "", s)
        gsub(/\*/, "", s)
        gsub(/`/, "", s)
        sub(/^[ \t]+/, "", s)
        sub(/[ \t]+$/, "", s)
        return s
    }
    function slugify(s,   base, k) {
        s = stripmd(s)
        gsub(/&[a-zA-Z]+;/, " ", s)
        s = tolower(s)
        gsub(/[^a-z0-9]+/, "-", s)
        sub(/^-+/, "", s)
        sub(/-+$/, "", s)
        if (s == "") s = "section"
        base = s
        k = 1
        while (slugseen[s] != "") { k = k + 1; s = base "-" k }
        slugseen[s] = "x"
        return s
    }
    function flush_li() {
        if (li != "") {
            if (li ~ /^\[ \] /)
                emit("<li class=\"task\">" inline_fmt(substr(li, 5)) "</li>")
            else
                emit("<li>" inline_fmt(li) "</li>")
            li = ""
        }
    }
    function flush_p(   status, cls) {
        if (pbuf != "") {
            if (pbuf ~ /^\*\*Verdict:\*\* /) {
                status = substr(pbuf, 14)
                cls = "warning"
                if (status ~ /HEALTHY/) cls = "healthy"
                if (status ~ /ERROR/)   cls = "error"
                emit("<p class=\"verdict\"><strong>Verdict</strong> <span class=\"pill pill-" cls "\">" status "</span></p>")
            } else if (pbuf ~ /^\*\*WARNING:\*\*/) {
                emit("<p class=\"warn\">" inline_fmt(pbuf) "</p>")
            } else {
                emit("<p>" inline_fmt(pbuf) "</p>")
            }
            pbuf = ""
        }
    }
    function flush_bq() {
        if (bqbuf != "") { emit("<blockquote><p>" inline_fmt(bqbuf) "</p></blockquote>"); bqbuf = "" }
    }
    # The first <ul> after the H1 is the meta chip strip: the table of
    # contents goes right after it.
    function end_ul() {
        emit("</ul>")
        inul = 0
        if (wantmeta) { tocpos = on; wantmeta = 0 }
    }
    # Emit the buffered table (buffering distinguishes header rows).
    function emit_table(   r, j, tag, row) {
        if (tnr == 0) return
        emit("<div class=\"twrap\"><table>")
        for (r = 1; r <= tnr; r++) {
            tag = (tsep && r == 1) ? "th" : "td"
            row = "<tr>"
            for (j = 1; j <= tnc[r]; j++)
                row = row "<" tag ">" inline_fmt(tcell[r "|" j]) "</" tag ">"
            emit(row "</tr>")
        }
        emit("</table></div>")
        tnr = 0; tsep = 0
    }
    function close_blocks() {
        flush_li(); flush_p(); flush_bq()
        if (inul) end_ul()
        if (tnr > 0) emit_table()
    }
    function emit_toc(   k, opensub, started) {
        if (tocn == 0) return
        print "<nav class=\"toc\" aria-label=\"Contents\"><details class=\"tocd\" open><summary>Contents</summary><ul>"
        opensub = 0; started = 0
        for (k = 1; k <= tocn; k++) {
            if (toclvl[k] == 2) {
                if (opensub) { print "</ul>"; opensub = 0 }
                if (started) print "</li>"
                print "<li><a href=\"#" tocid[k] "\">" toctxt[k] "</a>"
                started = 1
            } else {
                if (!started) { print "<li>"; started = 1 }
                if (!opensub) { print "<ul>"; opensub = 1 }
                print "<li><a href=\"#" tocid[k] "\">" toctxt[k] "</a></li>"
            }
        }
        if (opensub) print "</ul>"
        if (started) print "</li>"
        print "</ul></details></nav>"
    }
    # Seed every array and counter up front: AIX awk refuses a name it
    # has not already seen subscripted ("cannot be used as an array"),
    # and index 0 is outside every 1..n loop below, so this is inert.
    BEGIN {
        tnr = 0; tsep = 0; inul = 0; infence = 0; fencehead = 0
        li = ""; pbuf = ""; bqbuf = ""
        on = 0; tocn = 0; tocpos = 0; wantmeta = 0
        cells[0] = ""; tnc[0] = 0; tcell["0|0"] = ""
        out[0] = ""; toclvl[0] = 0; tocid[0] = ""; toctxt[0] = ""
        slugseen["-"] = ""
    }
    {
        line = esc($0)

        # fenced code blocks pass through verbatim (escaped, no inline fmt)
        if (line ~ /^```/) {
            if (infence) { emit("</code></pre>"); infence = 0 }
            else { close_blocks(); emit("<pre><code>"); infence = 1; fencehead = 1 }
            next
        }
        if (infence) {
            if (fencehead) { emitcat(line); fencehead = 0 } else emit(line)
            next
        }

        # bullet continuation (two-space indent while a bullet is open)
        if (li != "" && line ~ /^  [^ ]/) {
            sub(/^[ \t]+/, "", line)
            li = li " " line
            next
        }
        if (line ~ /^#### /) { close_blocks(); emit("<h4>" inline_fmt(substr(line,6)) "</h4>"); next }
        if (line ~ /^### /) {
            close_blocks()
            htxt = substr(line,5); hid = slugify(htxt)
            tocn = tocn + 1; toclvl[tocn] = 3; tocid[tocn] = hid; toctxt[tocn] = stripmd(htxt)
            emit("<h3 id=\"" hid "\">" inline_fmt(htxt) "</h3>")
            next
        }
        if (line ~ /^## /) {
            close_blocks()
            wantmeta = 0
            htxt = substr(line,4); hid = slugify(htxt)
            tocn = tocn + 1; toclvl[tocn] = 2; tocid[tocn] = hid; toctxt[tocn] = stripmd(htxt)
            emit("<h2 id=\"" hid "\">" inline_fmt(htxt) "</h2>")
            next
        }
        if (line ~ /^# /) {
            close_blocks()
            emit("<h1>" inline_fmt(substr(line,3)) "</h1>")
            tocpos = on; wantmeta = 1
            next
        }
        if (line ~ /^\|/) {
            flush_li(); flush_p(); flush_bq()
            if (inul) end_ul()
            if (line ~ /^\|[-| :]+\|$/) { if (tnr > 0) tsep = 1; next }
            n = split(line, cells, /\|/)
            tnr = tnr + 1; tnc[tnr] = 0
            for (i = 2; i < n; i++) {
                tnc[tnr] = tnc[tnr] + 1
                tcell[tnr "|" tnc[tnr]] = trimcell(cells[i])
            }
            next
        }
        if (tnr > 0) emit_table()
        if (line ~ /^- /) {
            flush_p(); flush_bq(); flush_li()
            if (!inul) { emit("<ul>"); inul = 1 }
            li = substr(line, 3)
            next
        }
        if (inul) { flush_li(); end_ul() }
        if (line ~ /^&gt; ?/) {
            flush_p()
            sub(/^&gt; ?/, "", line)
            bqbuf = (bqbuf == "") ? line : bqbuf " " line
            next
        }
        flush_bq()
        if (line ~ /^[ \t]*$/) { flush_p(); next }
        pbuf = (pbuf == "") ? line : pbuf " " line
    }
    END {
        if (infence) emit("</code></pre>")
        wantmeta = 0
        close_blocks()
        for (i = 1; i <= tocpos; i++) print out[i]
        if (tocn > 0) {
            print "<div class=\"layout\">"
            emit_toc()
            print "<main>"
        }
        for (i = tocpos + 1; i <= on; i++) print out[i]
        if (tocn > 0) print "</main></div>"
    }
    '
}

# #RRGGBB or nothing.
_dg_handoff_hex_ok() {
    case "$1" in
        '#'[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) return 0 ;;
        *) return 1 ;;
    esac
}

# _dg_handoff_color <env value> <default> <label> -> validated color on stdout
_dg_handoff_color() {
    if [ -z "$1" ]; then printf '%s' "$2"; return 0; fi
    if _dg_handoff_hex_ok "$1"; then printf '%s' "$1"; return 0; fi
    printf 'WARN: ignoring invalid %s (expected #RRGGBB): %s\n' "$3" "$1" >&2
    printf '%s' "$2"
}

# base64 of a file on one line; fails when neither encoder exists.
_dg_handoff_b64() {
    if command -v base64 >/dev/null 2>&1; then
        base64 < "$1" 2>/dev/null | tr -d '\n\r'
    elif command -v openssl >/dev/null 2>&1; then
        openssl base64 < "$1" 2>/dev/null | tr -d '\n\r'
    else
        return 1
    fi
}

# File path -> data: URI (empty + a warning when it cannot be built).
_dg_handoff_logo_data_uri() {
    _dg_logo_file="$1"
    if [ ! -r "$_dg_logo_file" ]; then
        printf 'WARN: DG_HANDOFF_BRAND_LOGO is not readable, omitting the logo: %s\n' "$_dg_logo_file" >&2
        return 0
    fi
    _dg_logo_ext=$(printf '%s' "$_dg_logo_file" | sed 's/.*\.//' | tr '[:upper:]' '[:lower:]')
    case "$_dg_logo_ext" in
        png)      _dg_logo_mime="image/png" ;;
        jpg|jpeg) _dg_logo_mime="image/jpeg" ;;
        svg)      _dg_logo_mime="image/svg+xml" ;;
        gif)      _dg_logo_mime="image/gif" ;;
        webp)     _dg_logo_mime="image/webp" ;;
        *)
            printf 'WARN: unsupported DG_HANDOFF_BRAND_LOGO type (.%s), omitting the logo\n' "$_dg_logo_ext" >&2
            return 0
            ;;
    esac
    _dg_logo_b64=$(_dg_handoff_b64 "$_dg_logo_file") || _dg_logo_b64=""
    if [ -z "$_dg_logo_b64" ]; then
        printf 'WARN: no base64 or openssl available to inline the logo, omitting it\n' >&2
        return 0
    fi
    printf 'data:%s;base64,%s' "$_dg_logo_mime" "$_dg_logo_b64"
}

# Markdown report on stdin -> self-contained styled HTML page on stdout.
render_handoff_html() {
    # Staleness threshold baked into the page (digits only).
    _dg_stale_days="${DG_HANDOFF_STALE_DAYS:-30}"
    case "$_dg_stale_days" in
        ''|*[!0-9]*) _dg_stale_days=30 ;;
    esac

    # Branding: defaults reproduce the previous output exactly.
    _dg_brand_name="${DG_HANDOFF_BRAND_NAME:-Oracle Data Guard}"
    _dg_brand_name_esc=$(printf '%s' "$_dg_brand_name" \
        | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g')
    _dg_brand_color=$(_dg_handoff_color "${DG_HANDOFF_BRAND_COLOR:-}" "#0099CC" "DG_HANDOFF_BRAND_COLOR")
    _dg_brand_ink=$(_dg_handoff_color "${DG_HANDOFF_BRAND_INK:-}" "#003366" "DG_HANDOFF_BRAND_INK")
    _dg_brand_tint=$(_dg_handoff_color "${DG_HANDOFF_BRAND_TINT:-}" "#DCEFF7" "DG_HANDOFF_BRAND_TINT")
    _dg_brand_dark=$(_dg_handoff_color "${DG_HANDOFF_BRAND_DARK_ACCENT:-}" "#80CCE6" "DG_HANDOFF_BRAND_DARK_ACCENT")
    # --br is a slightly darkened accent for light theme; there is no way
    # to darken a color in POSIX shell, so the built-in default keeps its
    # hand-picked value and an explicit brand color takes over verbatim.
    if [ "$_dg_brand_color" = "#0099CC" ]; then
        _dg_brand_link="#007FA9"
    else
        _dg_brand_link="$_dg_brand_color"
    fi

    _dg_logo_src=""
    case "${DG_HANDOFF_BRAND_LOGO:-}" in
        "")     _dg_logo_src="data:image/png;base64,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" ;;
        none)   _dg_logo_src="" ;;
        *)      _dg_logo_src=$(_dg_handoff_logo_data_uri "${DG_HANDOFF_BRAND_LOGO}") ;;
    esac
    _dg_logo_html=""
    if [ -n "$_dg_logo_src" ]; then
        _dg_logo_html="<img class=\"hd-logo\" src=\"${_dg_logo_src}\" alt=\"${_dg_brand_name_esc}\">"
    fi

    cat <<HTMLHEAD
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Data Guard Handoff - ${PRIMARY_DB_UNIQUE_NAME:-report}</title>
<style>
:root{
  --br:${_dg_brand_link};--brs:${_dg_brand_color};--brf:${_dg_brand_tint};--brn:${_dg_brand_ink};
  --bg:#f7fafc;--fg:#16232e;--muted:#5a6b7a;--accent:${_dg_brand_color};--accent-ink:${_dg_brand_ink};
  --line:#d9e4ec;--chipbg:#e9f2f8;--thbg:#ddedf5;--stripe:#f0f6fa;
  --code:#e3eff6;--codefg:#0c4a66;--pre:#0c2938;--prefg:#d8ecf5;--preline:#1d4258;
  --logochip:transparent;
  --ok:#177245;--okbg:#dff1e6;--warn:#8a5a00;--warnbg:#f7eed7;--err:#a8231b;--errbg:#f7e3e1;
}
@media (prefers-color-scheme: dark){
:root{
  --br:${_dg_brand_dark};--brs:${_dg_brand_color};--brf:#0C2938;--brn:${_dg_brand_dark};
  --bg:#0e161c;--fg:#d5e3ec;--muted:#8da3b2;--accent:${_dg_brand_color};--accent-ink:${_dg_brand_dark};
  --line:#24333f;--chipbg:#152430;--thbg:#172935;--stripe:#111d25;
  --code:#192b37;--codefg:#9fd3e8;--pre:#081820;--prefg:#cfe6f1;--preline:#1c3644;
  --logochip:#fff;
  --ok:#63c78d;--okbg:#122a1c;--warn:#d9a13b;--warnbg:#2a2210;--err:#e5776f;--errbg:#2b1513;
}
}
*{box-sizing:border-box}
.brandbar{display:flex;align-items:center;gap:11px;margin:0 0 1.7em}
.hd-logo{height:32px;width:auto;display:block;background:var(--logochip);border-radius:5px;padding:2px 6px}
.eyebrow{
  font-family:ui-monospace,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace;
  font-size:11px;letter-spacing:.16em;text-transform:uppercase;
  color:var(--br);font-weight:600;
}
body{
  font-family:system-ui,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
  max-width:72em;margin:0 auto;padding:2.2em 1.4em 4em;
  line-height:1.6;color:var(--fg);background:var(--bg);
}
h1{
  font-size:2em;font-weight:700;letter-spacing:-.015em;line-height:1.15;
  margin:.2em 0 .55em;padding-bottom:.4em;border-bottom:3px solid var(--accent);
}
h1+ul{
  list-style:none;display:flex;flex-wrap:wrap;gap:.5em;margin:0 0 2em;padding:0;
}
h1+ul li{
  background:var(--chipbg);border:1px solid var(--line);border-radius:999px;
  padding:.28em .95em;font-size:.83em;color:var(--muted);
}
h1+ul li strong{color:var(--fg);font-weight:600}
h1+ul li a{color:var(--br)}
h2{
  font-size:1.28em;font-weight:650;letter-spacing:-.01em;color:var(--accent-ink);
  margin:2.6em 0 .7em;padding-bottom:.3em;border-bottom:1px solid var(--line);
}
h3{font-size:1.05em;font-weight:650;margin:1.9em 0 .5em}
h4{
  font-size:.76em;font-weight:650;text-transform:uppercase;letter-spacing:.09em;
  color:var(--muted);margin:1.7em 0 .45em;
}
main>h2:first-child{margin-top:.2em}
p,ul{max-width:62em}
ul{padding-left:1.3em;margin:.6em 0 1em}
li{margin:.3em 0}
li.task{list-style:none;position:relative;padding-left:.4em}
li.task::before{
  content:"";position:absolute;left:-1.25em;top:.36em;width:.75em;height:.75em;
  border:2px solid var(--accent);border-radius:3px;
}
a{color:var(--br)}
code{
  font-family:ui-monospace,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace;
  font-size:.9em;background:var(--code);color:var(--codefg);
  padding:.08em .35em;border-radius:4px;
}
pre{
  background:var(--pre);color:var(--prefg);
  border:1px solid var(--preline);border-radius:8px;
  padding:.9em 1.1em;margin:.8em 0 1.1em;overflow-x:auto;
  font-size:.86em;line-height:1.5;
}
pre code{background:none;color:inherit;padding:0;border-radius:0;font-size:1em}
.prewrap{position:relative}
.prewrap .copy{
  position:absolute;top:.55em;right:.6em;
  font:inherit;font-size:.8em;letter-spacing:.04em;
  color:var(--prefg);background:var(--pre);border:1px solid var(--preline);
  border-radius:5px;padding:.15em .7em;cursor:pointer;
}
.prewrap .copy:hover,.prewrap .copy:focus-visible{border-color:var(--prefg);outline:none}
.twrap{overflow-x:auto;margin:.8em 0 1.2em}
table{border-collapse:collapse;font-size:.9em;min-width:34em}
th,td{
  border-bottom:1px solid var(--line);padding:.42em .9em;text-align:left;
  vertical-align:top;font-variant-numeric:tabular-nums;
}
th{
  background:var(--thbg);border-bottom:2px solid var(--accent);
  font-weight:650;white-space:nowrap;
}
tr:nth-child(even) td{background:var(--stripe)}
td code{white-space:nowrap}
.verdict{margin:1.2em 0 .6em;font-size:1.02em}
.pill{
  display:inline-block;border-radius:999px;padding:.14em .85em;
  font-weight:650;font-size:.9em;letter-spacing:.02em;
}
.pill-healthy{color:var(--ok);background:var(--okbg)}
.pill-warning{color:var(--warn);background:var(--warnbg)}
.pill-error{color:var(--err);background:var(--errbg)}
p.warn,blockquote{
  border-left:4px solid var(--warn);background:var(--warnbg);
  margin:.9em 0;padding:.65em 1em;border-radius:0 8px 8px 0;max-width:62em;
}
blockquote p{margin:.2em 0}
.stale{
  border-left:4px solid var(--warn);background:var(--warnbg);color:var(--warn);
  margin:0 0 1.5em;padding:.7em 1.05em;border-radius:0 8px 8px 0;
  font-size:.9em;font-weight:600;max-width:62em;
}
main{min-width:0}
.toc{margin:0 0 2.2em;font-size:.88em}
.toc .tocd{
  border:1px solid var(--line);border-radius:8px;
  background:var(--chipbg);padding:.55em .95em;
}
.toc summary{
  cursor:pointer;color:var(--muted);font-weight:650;
  text-transform:uppercase;letter-spacing:.09em;font-size:.82em;
}
.toc ul{list-style:none;margin:.7em 0 .15em;padding:0;max-width:none}
.toc ul ul{
  margin:.25em 0 .55em .55em;padding-left:.75em;
  border-left:1px solid var(--line);
}
.toc li{margin:.24em 0}
.toc a{color:var(--fg);text-decoration:none}
.toc ul ul a{color:var(--muted)}
.toc a:hover,.toc a:focus-visible{color:var(--br);text-decoration:underline}
@media (min-width:1100px){
  body{max-width:86em}
  .layout{display:grid;grid-template-columns:17em minmax(0,1fr);gap:2.6em;align-items:start}
  .toc{
    position:sticky;top:1.2em;margin:0;
    max-height:calc(100vh - 2.6em);overflow:auto;
  }
}
@media (prefers-reduced-motion: no-preference){
  .prewrap .copy{transition:border-color .15s ease}
}
@media print{
  :root{
    --bg:#fff;--fg:#111;--muted:#444;--line:#bbb;--chipbg:#fff;--thbg:#eee;--stripe:#fff;
    --code:#f1f1f1;--codefg:#111;--pre:#f7f7f7;--prefg:#111;--preline:#bbb;--logochip:transparent;
    --warn:#7a5200;--warnbg:#fdf6e3;
  }
  body{background:#fff;color:#111;max-width:none;padding:0;font-size:10.5pt}
  .toc,.stale,.prewrap .copy{display:none}
  .layout{display:block}
  .hd-logo{background:none}
  h2{page-break-before:always;break-before:page}
  h1+ul+*,main>h2:first-child{page-break-before:auto;break-before:auto}
  pre,table,blockquote,p.warn,.twrap{page-break-inside:avoid;break-inside:avoid}
  h1,h2,h3,h4{page-break-after:avoid;break-after:avoid}
  a{color:#111;text-decoration:underline}
  a[href^="http"]::after{content:" (" attr(href) ")";font-size:.85em;color:#444;word-break:break-all}
}
</style>
</head>
<body data-stale-days="${_dg_stale_days}">
<div class="brandbar">${_dg_logo_html}<span class="eyebrow">${_dg_brand_name_esc}</span></div>
HTMLHEAD
    handoff_md_to_html
    cat <<'HTMLFOOT'
<script>
document.querySelectorAll('pre').forEach(function (pre) {
  var codeEl = pre.querySelector('code');
  if (!codeEl) return;
  var wrap = document.createElement('div');
  wrap.className = 'prewrap';
  pre.parentNode.insertBefore(wrap, pre);
  wrap.appendChild(pre);
  var btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'copy';
  btn.textContent = 'Copy';
  btn.addEventListener('click', function () {
    var text = codeEl.innerText.replace(/\n$/, '');
    function done() {
      btn.textContent = 'Copied';
      setTimeout(function () { btn.textContent = 'Copy'; }, 1400);
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () { fallback(); });
    } else {
      fallback();
    }
    function fallback() {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); done(); } catch (e) {}
      document.body.removeChild(ta);
    }
  });
  wrap.appendChild(btn);
});
(function () {
  var limit = parseInt(document.body.getAttribute('data-stale-days'), 10);
  if (!limit || limit < 1) return;
  var chips = document.querySelectorAll('h1+ul li');
  var i, txt, m = null;
  for (i = 0; i < chips.length; i++) {
    txt = chips[i].textContent || '';
    if (txt.replace(/^\s+/, '').indexOf('Generated:') === 0) {
      m = /(\d{4})-(\d{2})-(\d{2})/.exec(txt);
      break;
    }
  }
  if (!m) return;
  var gen = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  var now = new Date();
  var today = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate());
  var age = Math.floor((today - gen) / 86400000);
  if (!(age > limit)) return;
  var box = document.createElement('div');
  box.className = 'stale';
  box.setAttribute('role', 'note');
  box.textContent = 'This report is ' + age + ' days old (generated ' + m[0] +
    '). Hostnames, services and connect strings may have changed — ' +
    'regenerate it with dg_handoff.sh before relying on it.';
  document.body.insertBefore(box, document.body.firstChild);
})();
</script>
</body>
</html>
HTMLFOOT
}
# ---- end handoff html renderer ----

# ============================================================
# JSON sidecar: writer, reader, diff
# ============================================================
# The sidecar is deliberately LINE-ORIENTED: exactly one scalar per line
# ('  "key": "value",') and exactly one service object per line, so the
# reader below (POSIX awk, AIX-safe) can parse it back without a JSON
# library. It is both a machine-readable export of the discovered facts
# and the baseline the NEXT run diffs against for the "Changes Since Last
# Report" section.

# JSON string escaping. Backslash and quote first, then tab, then join
# multi-line values with a literal \n. Replacement strings carry doubled
# backslashes because POSIX awk's gsub() interprets '\\' in a replacement
# as one literal backslash.
json_escape() {
    printf '%s' "$1" | tr -d '\r' | awk -v TAB="$(printf '\t')" '
        BEGIN { first = 1 }
        {
            s = $0
            gsub(/\\/, "\\\\\\\\", s)
            gsub(/"/, "\\\\\"", s)
            gsub(TAB, "\\\\t", s)
            gsub(/[[:cntrl:]]/, " ", s)
            if (!first) printf "\\n"
            printf "%s", s
            first = 0
        }
    '
}

# '  "key": "escaped",'  - or '  "key": null,' for an empty value.
json_str_line() {
    if [[ -z "$2" ]]; then
        printf '  "%s": null,\n' "$1"
    else
        printf '  "%s": "%s",\n' "$1" "$(json_escape "$2")"
    fi
}

# '  "key": true|false,' from a YES/NO/true/false-ish value.
json_bool_line() {
    printf '  "%s": %s,\n' "$1" "$(json_bool_token "$2")"
}

# Normalize a YES/NO/TRUE/FALSE/ENABLED-ish value to the JSON token true or
# false. Used by the writer AND by the diff, so a value stored as "false" is
# never compared against a raw "NO" (19c's CDB_SERVICES.COMMIT_OUTCOME is
# YES/NO; the E2E stub used true/false - both must diff clean).
json_bool_token() {
    local v
    v=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$v" in
        yes|true|enabled|y|1) printf 'true' ;;
        *)                    printf 'false' ;;
    esac
}

# '  "key": [ ... ],' with one string element per line. Remaining args are
# the elements (none = empty array).
json_array_line() {
    local key="$1"
    shift
    if [[ $# -eq 0 ]]; then
        printf '  "%s": [],\n' "$key"
        return 0
    fi
    printf '  "%s": [\n' "$key"
    local n=$# i=0
    for _el in "$@"; do
        i=$((i + 1))
        if [[ $i -lt $n ]]; then
            printf '    "%s",\n' "$(json_escape "$_el")"
        else
            printf '    "%s"\n' "$(json_escape "$_el")"
        fi
    done
    printf '  ],\n'
}

# ---- reader (POSIX awk, one pass per lookup - the file is tiny) --------

# Print the raw JSON token of a top-level (or descriptor) scalar: the
# string CONTENTS without the surrounding quotes, or the literal
# null/true/false. Prints nothing when the key is absent, which the diff
# treats as "not comparable" rather than "changed".
json_prev_scalar() {
    [[ -f "$1" ]] || return 0
    awk -v k="$2" '
        BEGIN { pat = "\"" k "\":" }
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            if (index(line, pat) == 1) {
                v = substr(line, length(pat) + 1)
                sub(/^[ \t]+/, "", v)
                sub(/,$/, "", v)
                sub(/[ \t]+$/, "", v)
                if (substr(v, 1, 1) == "\"")
                    v = substr(v, 2, length(v) - 2)
                print v
                exit
            }
        }
    ' "$1"
}

# Print the elements of a line-oriented string array, one per line.
json_prev_array() {
    [[ -f "$1" ]] || return 0
    awk -v k="$2" '
        BEGIN { pat = "\"" k "\": ["; inarr = 0 }
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            if (inarr) {
                if (index(line, "]") == 1) { inarr = 0; exit }
                sub(/,$/, "", line)
                if (substr(line, 1, 1) == "\"")
                    line = substr(line, 2, length(line) - 2)
                if (line != "") print line
                next
            }
            if (index(line, pat) == 1) {
                if (index(line, "[]") > 0) exit
                inarr = 1
            }
        }
    ' "$1"
}

# Print one pipe-joined record per service object found in the sidecar:
#   name|container|class|role_aware|taf_type|taf_method|commit_outcome|drain_timeout
json_prev_services() {
    [[ -f "$1" ]] || return 0
    awk '
        function jget(line, k,   pat, i, v, j, ch, res, esc) {
            pat = "\"" k "\": "
            i = index(line, pat)
            if (i == 0) return ""
            v = substr(line, i + length(pat))
            if (substr(v, 1, 1) == "\"") {
                res = ""
                esc = 0
                for (j = 2; j <= length(v); j = j + 1) {
                    ch = substr(v, j, 1)
                    if (esc) { res = res ch; esc = 0; continue }
                    if (ch == "\\") { res = res ch; esc = 1; continue }
                    if (ch == "\"") break
                    res = res ch
                }
                return res
            }
            sub(/[,}].*$/, "", v)
            return v
        }
        BEGIN { }
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            if (substr(line, 1, 9) != "{\"name\": ") next
            print jget(line, "name") "|" jget(line, "container") "|" \
                  jget(line, "class") "|" jget(line, "role_aware") "|" \
                  jget(line, "taf_type") "|" jget(line, "taf_method") "|" \
                  jget(line, "commit_outcome") "|" jget(line, "drain_timeout")
        }
    ' "$1"
}

# ============================================================
# Per-service derived facts (shared by JSON, the pack and the DBA actions)
# ============================================================

# Pipe-joined HA attributes for a service, with sane defaults when the
# dictionary lookup found nothing.
#   ftype|fmethod|fretries|fdelay|commit|drain|restore
service_ha_tuple() {
    local attrs
    attrs=$(service_attrs "$1" "$2")
    if [[ -z "$attrs" ]]; then
        printf 'NONE|-|-|-|false|-|NONE\n'
        return 0
    fi
    printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$(field "$attrs" 3)" "$(field "$attrs" 4)" "$(field "$attrs" 5)" \
        "$(field "$attrs" 6)" "$(field "$attrs" 7)" "$(field "$attrs" 8)" \
        "$(field "$attrs" 9)"
}

# TNS alias for a service, matching the one used in section 1.
service_alias() {
    printf '%s' "$1" | tr '.' '_' | tr '[:lower:]' '[:upper:]'
}

# Is this service one the role trigger can actually follow? DEFAULT
# services never are, regardless of trigger deployment.
service_role_aware() {
    if [[ "$1" == "USER" && "$ROLE_TRIGGER_READY" == "YES" ]]; then
        printf 'true'
    else
        printf 'false'
    fi
}

# ============================================================
# Runnable verification script (deliverable pack)
# ============================================================
# Emits a self-contained checker for application hosts, with the topology
# baked in at generation time. It must run on hosts that have neither this
# repository nor an Oracle server install, so every external tool is
# probed with `command -v` and a missing tool SKIPS its check rather than
# failing it. Exit 0 only if every check that could run passed.
#
# Note on quoting: the heredoc below is UNQUOTED so the baked-in values
# expand here; every variable belonging to the generated script is written
# as \$name.
write_verify_script() {
    cat <<EOF
#!/usr/bin/env bash
# ============================================================
# Data Guard connectivity check - generated ${GEN_DATE}
# by dg_handoff.sh for ${PRIMARY_DB_UNIQUE_NAME}${STANDBY_DB_UNIQUE_NAME:+ -> ${STANDBY_DB_UNIQUE_NAME}}
#
# Run from every application host BEFORE go-live, and again after a
# switchover drill (with --expect-db-unique-name <new primary>).
# Exits 0 only when every check that could run passed; checks skipped for
# a missing tool or missing credentials do not fail the run.
# ============================================================

PRIMARY_HOST="${PRIMARY_HOSTNAME}"
STANDBY_HOST="${STANDBY_HOSTNAME}"
DB_PORT="${PORT}"
SERVICE_NAME="${EXAMPLE_SVC}"
EXPECT_DB_UNIQUE_NAME="${PRIMARY_DB_UNIQUE_NAME}"
EZCONNECT="${VERIFY_EZ}"

APP_USER="\${APP_USER:-}"
APP_PASSWORD="\${APP_PASSWORD:-}"

usage() {
    cat <<USAGE
Usage: \$(basename "\$0") [options]

  -u, --user USER/PASS            Credentials for the end-to-end check
                                  (or set APP_USER and APP_PASSWORD)
      --expect-db-unique-name X   Expect this DB_UNIQUE_NAME instead of
                                  ${PRIMARY_DB_UNIQUE_NAME} (use after a switchover)
  -h, --help                      Show this help

Checks: hostname resolution and TCP reachability for both database hosts,
plus - when sqlplus and credentials are available - an end-to-end connect
through the role-aware Easy Connect Plus string asserting
DATABASE_ROLE=PRIMARY and the expected DB_UNIQUE_NAME.
USAGE
}

while [ \$# -gt 0 ]; do
    case "\$1" in
        -u|--user)
            APP_USER="\${2%%/*}"
            APP_PASSWORD="\${2#*/}"
            shift 2 ;;
        --expect-db-unique-name) EXPECT_DB_UNIQUE_NAME="\$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: \$1" >&2; usage >&2; exit 2 ;;
    esac
done

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { echo "PASS  \$*"; PASS_COUNT=\$((PASS_COUNT + 1)); }
fail() { echo "FAIL  \$*"; FAIL_COUNT=\$((FAIL_COUNT + 1)); }
skip() { echo "SKIP  \$*"; SKIP_COUNT=\$((SKIP_COUNT + 1)); }

# ---- 1. Name resolution ----
resolve_host() {
    _h="\$1"
    if command -v getent >/dev/null 2>&1; then
        if getent hosts "\$_h" >/dev/null 2>&1; then pass "resolve \$_h (getent)"; else fail "resolve \$_h (getent found no address)"; fi
        return 0
    fi
    if command -v nslookup >/dev/null 2>&1; then
        if nslookup "\$_h" >/dev/null 2>&1; then pass "resolve \$_h (nslookup)"; else fail "resolve \$_h (nslookup found no address)"; fi
        return 0
    fi
    if command -v ping >/dev/null 2>&1; then
        if ping -c1 -W1 "\$_h" >/dev/null 2>&1; then pass "resolve \$_h (ping)"; else fail "resolve \$_h (ping got no reply - name or host down)"; fi
        return 0
    fi
    skip "resolve \$_h (no getent/nslookup/ping on this host)"
}

# ---- 2. TCP reachability ----
check_port() {
    _h="\$1"
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w 3 "\$_h" "\$DB_PORT" >/dev/null 2>&1; then pass "tcp \$_h:\$DB_PORT (nc)"; else fail "tcp \$_h:\$DB_PORT refused or timed out (nc)"; fi
        return 0
    fi
    if command -v timeout >/dev/null 2>&1; then
        if timeout 3 bash -c "exec 3<>/dev/tcp/\$_h/\$DB_PORT" >/dev/null 2>&1; then pass "tcp \$_h:\$DB_PORT (/dev/tcp)"; else fail "tcp \$_h:\$DB_PORT refused or timed out (/dev/tcp)"; fi
        return 0
    fi
    if command -v tnsping >/dev/null 2>&1; then
        if tnsping "\$_h:\$DB_PORT/\$SERVICE_NAME" >/dev/null 2>&1; then pass "tnsping \$_h:\$DB_PORT/\$SERVICE_NAME"; else fail "tnsping \$_h:\$DB_PORT/\$SERVICE_NAME failed"; fi
        return 0
    fi
    skip "tcp \$_h:\$DB_PORT (no nc, no timeout for /dev/tcp, no tnsping)"
}

echo "Data Guard connectivity check - expecting primary \$EXPECT_DB_UNIQUE_NAME"
echo ""

resolve_host "\$PRIMARY_HOST"
resolve_host "\$STANDBY_HOST"
check_port   "\$PRIMARY_HOST"
check_port   "\$STANDBY_HOST"

# ---- 3. End-to-end role check through the role-aware descriptor ----
if ! command -v sqlplus >/dev/null 2>&1; then
    skip "end-to-end role check (sqlplus not on PATH)"
elif [ -z "\$APP_USER" ] || [ -z "\$APP_PASSWORD" ]; then
    skip "end-to-end role check (set APP_USER/APP_PASSWORD or pass -u user/pass)"
else
    SQL_OUT=\$(sqlplus -s -L "\$APP_USER/\$APP_PASSWORD@\$EZCONNECT" <<'SQLEOF' 2>&1
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200 TRIMSPOOL ON
WHENEVER SQLERROR EXIT 1
SELECT 'DGCHK=' || SYS_CONTEXT('USERENV','DB_UNIQUE_NAME') || '|' ||
       SYS_CONTEXT('USERENV','DATABASE_ROLE') || '|' ||
       SYS_CONTEXT('USERENV','SERVER_HOST') FROM DUAL;
EXIT;
SQLEOF
)
    LINE=\$(printf '%s\n' "\$SQL_OUT" | grep 'DGCHK=' | head -1 | sed 's/.*DGCHK=//' | tr -d '\r ')
    if [ -z "\$LINE" ]; then
        fail "end-to-end connect through \$EZCONNECT"
        printf '%s\n' "\$SQL_OUT" | sed 's/^/      /'
    else
        GOT_NAME=\$(printf '%s' "\$LINE" | awk -F'|' '{print \$1}')
        GOT_ROLE=\$(printf '%s' "\$LINE" | awk -F'|' '{print \$2}')
        GOT_HOST=\$(printf '%s' "\$LINE" | awk -F'|' '{print \$3}')
        pass "connected via \$EZCONNECT (server host \$GOT_HOST)"
        if [ "\$GOT_ROLE" = "PRIMARY" ]; then
            pass "DATABASE_ROLE is PRIMARY"
        else
            fail "DATABASE_ROLE is \$GOT_ROLE, expected PRIMARY - the service is running on a standby"
        fi
        if [ "\$GOT_NAME" = "\$EXPECT_DB_UNIQUE_NAME" ]; then
            pass "DB_UNIQUE_NAME is \$GOT_NAME"
        else
            fail "DB_UNIQUE_NAME is \$GOT_NAME, expected \$EXPECT_DB_UNIQUE_NAME (use --expect-db-unique-name after a switchover)"
        fi
    fi
fi

echo ""
echo "\$PASS_COUNT passed, \$FAIL_COUNT failed, \$SKIP_COUNT skipped."
[ "\$FAIL_COUNT" -eq 0 ] || exit 1
exit 0
EOF
}

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
    VERDICT_NOTES+=("Local role is ${DB_ROLE}, expected PRIMARY — re-run this script on the primary host so service discovery and connect strings are complete")
fi
if [[ "${GAP_COUNT}" -gt 0 ]]; then
    escalate_verdict "ERROR"
    VERDICT_NOTES+=("${GAP_COUNT} archive gap(s) detected — redo transport is broken; run dg_status.sh / check archive destinations before trusting the standby")
fi
if [[ "$DG_BROKER_START" != "TRUE" ]]; then
    escalate_verdict "WARNING"
    VERDICT_NOTES+=("Data Guard Broker is not started — set dg_broker_start=TRUE; broker-derived fields in this report are incomplete")
fi

# Redo apply progress: a standby that is many sequences behind is not a
# usable failover target, no matter what the broker says.
if [[ "$APPLY_LAG_SEQ" -gt "$LAG_CRIT_SEQ" ]]; then
    escalate_verdict "ERROR"
    VERDICT_NOTES+=("Apply lag is ${APPLY_LAG_SEQ} sequences (threshold ${LAG_CRIT_SEQ}) — the standby is not a usable failover target until apply catches up; investigate MRP and transport")
elif [[ "$APPLY_LAG_SEQ" -gt "$LAG_WARN_SEQ" ]]; then
    escalate_verdict "WARNING"
    VERDICT_NOTES+=("Apply lag is ${APPLY_LAG_SEQ} sequences — watch it; a failover now loses roughly this much redo history of reporting freshness")
fi

# Apply lag in TIME (broker, or the standby's own V$DATAGUARD_STATS). This is
# the number an application team actually feels: it bounds how stale an ADG
# read is and how much redo a failover would have to wait for.
LAG_WARN_SECONDS="${DG_LAG_WARN_SECONDS:-60}"
case "$LAG_WARN_SECONDS" in ''|*[!0-9]*) LAG_WARN_SECONDS=60 ;; esac
if [[ -n "$APPLY_LAG_SECONDS" && "$APPLY_LAG_SECONDS" -gt "$LAG_WARN_SECONDS" ]]; then
    escalate_verdict "WARNING"
    VERDICT_NOTES+=("Apply lag is ${APPLY_LAG_TEXT} (threshold ${LAG_WARN_SECONDS}s) — check MRP on the standby and redo transport; run dg_status.sh (or dg_triage_sid.sh on the standby host) to see where apply is stuck")
fi

# Switchover readiness. On a healthy primary this is TO STANDBY / SESSIONS
# ACTIVE; the gap and destination states below mean redo transport is broken.
case "$(printf '%s' "$SWITCHOVER_STATUS" | tr '[:lower:]' '[:upper:]')" in
    *"FAILED DESTINATION"*|*"UNRESOLVABLE GAP"*|*"LOG SWITCH GAP"*)
        escalate_verdict "ERROR"
        VERDICT_NOTES+=("Switchover status is ${SWITCHOVER_STATUS} — redo transport to the standby is broken; fix before any role change (dg_status.sh shows the failing destination)")
        ;;
    *"RESOLVABLE GAP"*|*"RECOVERY NEEDED"*|*"PREPARING"*)
        escalate_verdict "WARNING"
        VERDICT_NOTES+=("Switchover status is ${SWITCHOVER_STATUS} — transient states usually clear on their own; re-check before any planned switchover")
        ;;
esac

# The broker's own verdict. DGMGRL always exits 0, so the captured text is
# the only signal - scan it the same way the setup scripts do.
if [[ -n "$BROKER_OUTPUT" ]]; then
    BROKER_CONFIG_STATUS=$(extract_configuration_status "$BROKER_OUTPUT")
    case "$BROKER_CONFIG_STATUS" in
        ERROR)
            escalate_verdict "ERROR"
            VERDICT_NOTES+=("Broker Configuration Status is ERROR — see the Broker Configuration appendix; run DGMGRL SHOW CONFIGURATION for live detail")
            ;;
        WARNING)
            escalate_verdict "WARNING"
            VERDICT_NOTES+=("Broker Configuration Status is WARNING — see the Broker Configuration appendix; run DGMGRL SHOW CONFIGURATION for live detail")
            ;;
    esac
    if broker_output_has_error "$BROKER_OUTPUT"; then
        escalate_verdict "ERROR"
        VERDICT_NOTES+=("Broker reported ORA-/DGM- errors — see the Broker Configuration appendix for the exact messages")
    fi
fi

# Role-aware descriptors are only safe once the trigger is deployed.
if [[ "$ROLE_TRIGGER_READY" != "YES" ]]; then
    escalate_verdict "WARNING"
    VERDICT_NOTES+=("Role-aware service trigger is not deployed/enabled — run trigger/create_role_trigger.sh (CDB: create_role_trigger_cdb.sh) on the primary before handing role-aware descriptors to applications")
fi

# Default services can never be role-aware; with no user-created service there
# is nothing safe to hand to the application tier.
if [[ "$USER_SERVICE_COUNT" -eq 0 && "$DB_ROLE" == "PRIMARY" ]]; then
    escalate_verdict "WARNING"
    VERDICT_NOTES+=("No user-created service found — only default services exist, and those cannot follow the primary role; create one with trigger/create_pdb_service.sh or trigger/create_cdb_service.sh")
fi

# A --service the operator asked for that does not exist: the report is still
# produced, but it silently covers less than was requested.
if [[ ${#SERVICE_FILTER_MISSES[@]} -gt 0 ]]; then
    for _miss in "${SERVICE_FILTER_MISSES[@]}"; do
        escalate_verdict "WARNING"
        VERDICT_NOTES+=("Requested service ${_miss} not found among active services — check the name (and container, if it lives in a PDB) or drop the --service filter")
    done
fi

if [[ -n "$STANDBY_DB_UNIQUE_NAME" && "$STANDBY_OPEN_MODE" == "unknown" ]]; then
    escalate_verdict "WARNING"
    VERDICT_NOTES+=("Standby readability could not be determined from the broker — verify the standby OPEN_MODE before promising read-only access")
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

GEN_DATE=$(date '+%Y-%m-%d %H:%M:%S %Z')
GEN_HOST=$(hostname 2>/dev/null)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPACT_LOCAL="${SCRIPT_DIR}/DG_APPLICATION_IMPACT.html"
IMPACT_DOCS="${SCRIPT_DIR}/docs/DG_APPLICATION_IMPACT.html"
IMPACT_REFERENCE=""
if [[ -n "$IMPACT_REFERENCE_OVERRIDE" ]]; then
    IMPACT_REFERENCE="$IMPACT_REFERENCE_OVERRIDE"
elif [[ -f "$IMPACT_LOCAL" ]]; then
    IMPACT_REFERENCE="$IMPACT_LOCAL"
elif [[ -f "$IMPACT_DOCS" ]]; then
    IMPACT_REFERENCE="$IMPACT_DOCS"
fi

# Best-effort: no base64/openssl on the host just drops the link
VIZ_URL=$(build_visualizer_url) || VIZ_URL=""

# Service used by the driver examples and the end-to-end verification: the
# first user-created (role-manageable) service, falling back to whatever
# heads the list, falling back to a placeholder.
EXAMPLE_SVC="${RECOMMENDED_SVC:-${SERVICE_LIST[0]:-service_name}}"

# Easy Connect Plus string used by the end-to-end verification example;
# degrades to a primary-only address when the standby host is unknown.
if [[ -n "$STANDBY_HOSTNAME" ]]; then
    VERIFY_EZ=$(render_easy_connect_ha "$PRIMARY_HOSTNAME" "$STANDBY_HOSTNAME" "$PORT" "$EXAMPLE_SVC")
else
    VERIFY_EZ="${PRIMARY_HOSTNAME}:${PORT}/${EXAMPLE_SVC}"
fi

# One-line derived facts for the At a Glance section
case "$(printf '%s' "$PROTECTION_MODE" | tr '[:lower:]' '[:upper:]')|$(printf '%s' "$STANDBY_LOGXPTMODE" | tr '[:lower:]' '[:upper:]')" in
    *MAXIMUM*AVAILABILITY*'|'SYNC|*MAXIMUM*AVAILABILITY*'|'FASTSYNC)
        RPO_SHORT="RPO = 0 while synchronized (${PROTECTION_MODE}, transport ${STANDBY_LOGXPTMODE})" ;;
    *MAXIMUM*PERFORMANCE*'|'ASYNC)
        RPO_SHORT="RPO > 0 (async transport: a failover can lose the last seconds of commits)" ;;
    *)  RPO_SHORT="RPO to be confirmed (protection ${PROTECTION_MODE:-unknown}, transport ${STANDBY_LOGXPTMODE:-unknown})" ;;
esac
if [[ "$FSFO_ENABLED" == "YES" ]]; then
    FAILOVER_SHORT="automatic (FSFO, threshold ${FSFO_THRESHOLD:-unknown} s) — budget 1-3 minutes of connection errors on primary loss"
else
    FAILOVER_SHORT="manual — a DBA must execute the failover; outage lasts until then"
fi
STANDBY_OPEN_UPPER=$(printf '%s' "$STANDBY_OPEN_MODE" | tr '[:lower:]' '[:upper:]')
case "$STANDBY_OPEN_UPPER" in
    *MOUNTED*)          READABILITY_SHORT="not readable (MOUNTED) — no reporting offload today" ;;
    *READ*ONLY*APPLY*)  READABILITY_SHORT="readable (READ ONLY WITH APPLY — Active Data Guard, separately licensed); reads are stale by the apply lag (${APPLY_LAG_TEXT})" ;;
    *)                  READABILITY_SHORT="unknown — verify before promising read-only access" ;;
esac

# Per-service HA attribute bullets, from the discovered CDB_SERVICES facts.
emit_service_attr_lines() {
    local con="$1" svc="$2" attrs ftype fmethod fretries fdelay commit drain restore taf_max
    attrs=$(service_attrs "$con" "$svc")
    if [[ -z "$attrs" ]]; then
        echo "- HA attributes could not be discovered for this service (treat as: no TAF, no Transaction Guard)."
        return 0
    fi
    ftype=$(field "$attrs" 3 | tr '[:lower:]' '[:upper:]')
    fmethod=$(field "$attrs" 4)
    fretries=$(field "$attrs" 5)
    fdelay=$(field "$attrs" 6)
    commit=$(field "$attrs" 7 | tr '[:lower:]' '[:upper:]')
    drain=$(field "$attrs" 8)
    restore=$(field "$attrs" 9)
    case "$ftype" in
        NONE|-|'')
            echo "- TAF: none — after a session drop, reconnecting is the pool's or the application's job." ;;
        TRANSACTION|AUTO)
            echo "- Application Continuity: FAILOVER_TYPE=${ftype} — 12.2+ drivers can replay in-flight work after a failover (driver support and request boundaries still required)." ;;
        *)
            taf_max=""
            case "${fretries}${fdelay}" in *[!0-9]*) ;; *) taf_max=" (max $((fretries * fdelay)) s)"; esac
            echo "- TAF: ${ftype}/${fmethod} — on session loss the client retries every ${fdelay} s, up to ${fretries} attempts${taf_max}. Open SELECT cursors resume; in-flight transactions roll back (ORA-25402)." ;;
    esac
    if [[ "$commit" == "TRUE" || "$commit" == "YES" ]]; then
        echo "- Transaction Guard: enabled (COMMIT_OUTCOME=TRUE) — 12c+ drivers can resolve an in-doubt commit programmatically after a dropped connection."
    else
        echo "- Transaction Guard: not enabled (COMMIT_OUTCOME=FALSE) — an in-doubt commit stays ambiguous; handle with idempotency keys (section 2)."
    fi
    case "$drain" in
        ''|-|0) ;;
        *[!0-9]*) ;;
        *) echo "- DRAIN_TIMEOUT: ${drain} s — planned maintenance waits up to this long for sessions to finish before disconnecting them." ;;
    esac
    case "$(printf '%s' "$restore" | tr '[:lower:]' '[:upper:]')" in
        NONE|-|'') ;;
        *) echo "- FAILOVER_RESTORE: ${restore} — selected session state is restored on failover." ;;
    esac
}

# ============================================================
# Sidecar paths and the per-service fact records
# ============================================================

JSON_FILE="${OUTPUT_FILE%.md}.json"
[[ "$JSON_FILE" == "$OUTPUT_FILE" ]] && JSON_FILE="${OUTPUT_FILE}.json"
PACK_BASE="${OUTPUT_FILE%.md}"
[[ "$PACK_BASE" == "$OUTPUT_FILE" ]] && PACK_BASE="${OUTPUT_FILE}"
TNSNAMES_FILE="${PACK_BASE}_tnsnames.ora"
JDBC_FILE="${PACK_BASE}_jdbc.properties"
VERIFY_FILE="${PACK_BASE}_verify.sh"

PREV_JSON_FILE="${PREVIOUS_JSON_OVERRIDE:-$JSON_FILE}"

GEN_STAMP=$(date '+%Y-%m-%dT%H:%M:%S')
GEN_TZ=$(date '+%Z')

# Per-service records, built once and reused by the JSON sidecar, the
# change diff, the deliverable pack and the DBA action section.
#   SVC_REC_*  parallel arrays, one entry per service in SERVICE_LIST
SVC_REC_ALIAS=()
SVC_REC_ROLE_AWARE=()
SVC_REC_FTYPE=()
SVC_REC_FMETHOD=()
SVC_REC_FRETRIES=()
SVC_REC_FDELAY=()
SVC_REC_COMMIT=()
SVC_REC_DRAIN=()
SVC_REC_RESTORE=()
SVC_REC_EZ=()
SVC_REC_JDBC=()
_i=0
while [[ $_i -lt ${#SERVICE_LIST[@]} ]]; do
    _svc="${SERVICE_LIST[$_i]}"
    _con="${SERVICE_CON[$_i]}"
    _cls="${SERVICE_CLASS[$_i]}"
    _i=$((_i + 1))
    _tuple=$(service_ha_tuple "$_con" "$_svc")
    SVC_REC_ALIAS+=("$(service_alias "$_svc")_HA")
    SVC_REC_ROLE_AWARE+=("$(service_role_aware "$_cls")")
    SVC_REC_FTYPE+=("$(field "$_tuple" 1)")
    SVC_REC_FMETHOD+=("$(field "$_tuple" 2)")
    SVC_REC_FRETRIES+=("$(field "$_tuple" 3)")
    SVC_REC_FDELAY+=("$(field "$_tuple" 4)")
    SVC_REC_COMMIT+=("$(field "$_tuple" 5)")
    SVC_REC_DRAIN+=("$(field "$_tuple" 6)")
    SVC_REC_RESTORE+=("$(field "$_tuple" 7)")
    if [[ -n "$STANDBY_HOSTNAME" ]]; then
        SVC_REC_EZ+=("$(render_easy_connect_ha "$PRIMARY_HOSTNAME" "$STANDBY_HOSTNAME" "$PORT" "$_svc")")
        SVC_REC_JDBC+=("$(render_jdbc_ha "$PRIMARY_HOSTNAME" "$STANDBY_HOSTNAME" "$PORT" "$_svc")")
    else
        SVC_REC_EZ+=("${PRIMARY_HOSTNAME}:${PORT}/${_svc}")
        SVC_REC_JDBC+=("$(render_jdbc_single "$PRIMARY_HOSTNAME" "$PORT" "$_svc")")
    fi
done

# ============================================================
# Changes Since Last Report
# ============================================================
# Diffed against the previous JSON sidecar (which stays readable until the
# new one is moved into place at the very end of this run). Comparison is
# done on the ESCAPED current value against the raw stored token, so no
# unescaping step is needed. A key missing from the previous file is
# "not comparable", never "changed" - that keeps an older sidecar from
# reporting every new field as a change.

CHANGE_ROWS=()
CHANGE_SVC_ADDED=()
CHANGE_SVC_REMOVED=()
CHANGE_SVC_CHANGED=()
CHANGE_NOTES=()
PREV_GENERATED_AT=""
HAVE_PREVIOUS=0
CHANGE_COUNT=0

# Markdown-safe rendering of a stored/escaped token.
_change_display() {
    if [[ -z "$1" || "$1" == "null" ]]; then
        printf '(none)'
        return 0
    fi
    printf '%s' "$1" | sed -e 's/|/\\|/g'
}

diff_scalar() {
    local lbl="$1" key="$2" cur="$3" prev cure
    prev=$(json_prev_scalar "$PREV_JSON_FILE" "$key")
    [[ -z "$prev" ]] && return 0
    if [[ -z "$cur" ]]; then cure="null"; else cure=$(json_escape "$cur"); fi
    [[ "$prev" == "$cure" ]] && return 0
    CHANGE_ROWS+=("| ${lbl} | $(_change_display "$prev") | $(_change_display "$cure") |")
}

if [[ $NO_JSON -eq 0 && -f "$PREV_JSON_FILE" ]]; then
    HAVE_PREVIOUS=1
    PREV_GENERATED_AT=$(json_prev_scalar "$PREV_JSON_FILE" "generated_at")

    diff_scalar "Verdict"                    verdict                   "$VERDICT"
    diff_scalar "Primary DB_UNIQUE_NAME"     primary_db_unique_name    "$PRIMARY_DB_UNIQUE_NAME"
    diff_scalar "Standby DB_UNIQUE_NAME"     standby_db_unique_name    "$STANDBY_DB_UNIQUE_NAME"
    diff_scalar "Primary host"               primary_host              "$PRIMARY_HOSTNAME"
    diff_scalar "Standby host"               standby_host              "$STANDBY_HOSTNAME"
    diff_scalar "Listener port"              port                      "$PORT"
    diff_scalar "Protection mode"            protection_mode           "$PROTECTION_MODE"
    diff_scalar "Standby LogXptMode"         standby_logxptmode        "$STANDBY_LOGXPTMODE"
    diff_scalar "Standby open mode"          standby_open_mode         "$STANDBY_OPEN_MODE"
    diff_scalar "FSFO enabled"               fsfo_enabled              "$(json_bool_token "$FSFO_ENABLED")"
    diff_scalar "FSFO threshold"             fsfo_threshold            "$FSFO_THRESHOLD"
    diff_scalar "Role trigger ready"         role_trigger_ready        "$(json_bool_token "$ROLE_TRIGGER_READY")"
    diff_scalar "Database version"           db_version                "$DB_VERSION"
    diff_scalar "CONNECT_TIMEOUT"            connect_timeout           "$TNS_CT"
    diff_scalar "TRANSPORT_CONNECT_TIMEOUT"  transport_connect_timeout "$TNS_TCT"
    diff_scalar "RETRY_COUNT"                retry_count               "$TNS_RC"
    diff_scalar "RETRY_DELAY"                retry_delay               "$TNS_RD"

    # Service diff - but only when the two runs looked at the same set of
    # services. A changed --service/--exclude-service filter would otherwise
    # report every filtered-out service as "removed", which is a lie.
    _prev_filter=$(json_prev_array "$PREV_JSON_FILE" service_filter | tr '\n' ',')
    _prev_exclude=$(json_prev_array "$PREV_JSON_FILE" service_exclude | tr '\n' ',')
    _cur_filter=""
    for _tok in ${SERVICE_FILTER[@]+"${SERVICE_FILTER[@]}"}; do
        _cur_filter="${_cur_filter}$(json_escape "$_tok"),"
    done
    _cur_exclude=""
    for _tok in ${SERVICE_EXCLUDE[@]+"${SERVICE_EXCLUDE[@]}"}; do
        _cur_exclude="${_cur_exclude}$(json_escape "$_tok"),"
    done
    if [[ "$_prev_filter" != "$_cur_filter" || "$_prev_exclude" != "$_cur_exclude" ]]; then
        CHANGE_NOTES+=("The service filter differs from the previous run (previous: \`${_prev_filter%,}\`, excluding \`${_prev_exclude%,}\`; current: \`${_cur_filter%,}\`, excluding \`${_cur_exclude%,}\` — empty means no filter), so the service lists are not comparable and are not diffed here.")
    else
        _prev_svcs=$(json_prev_services "$PREV_JSON_FILE")
        # removed: in previous, not in current
        while IFS= read -r _pline; do
            [[ -z "$_pline" ]] && continue
            _pname=$(field "$_pline" 1)
            _found=0
            _i=0
            while [[ $_i -lt ${#SERVICE_LIST[@]} ]]; do
                [[ "$(json_escape "${SERVICE_LIST[$_i]}")" == "$_pname" ]] && _found=1
                _i=$((_i + 1))
            done
            [[ $_found -eq 0 ]] && CHANGE_SVC_REMOVED+=("$_pname")
        done <<< "$_prev_svcs"
        # added / changed
        _i=0
        while [[ $_i -lt ${#SERVICE_LIST[@]} ]]; do
            _svc="${SERVICE_LIST[$_i]}"
            _esc=$(json_escape "$_svc")
            _pline=$(printf '%s\n' "$_prev_svcs" | awk -F'|' -v n="$_esc" '$1 == n { print; exit }')
            if [[ -z "$_pline" ]]; then
                CHANGE_SVC_ADDED+=("$_svc")
            else
                _deltas=""
                _cmp() {
                    [[ "$1" == "$2" ]] && return 0
                    _deltas="${_deltas}${_deltas:+, }$3: ${1:-(none)} → ${2:-(none)}"
                }
                _cmp "$(field "$_pline" 2)" "$(json_escape "${SERVICE_CON[$_i]}")"       "container"
                _cmp "$(field "$_pline" 4)" "${SVC_REC_ROLE_AWARE[$_i]}"                 "role-aware"
                _cmp "$(field "$_pline" 5)" "$(json_escape "${SVC_REC_FTYPE[$_i]}")"     "TAF type"
                _cmp "$(field "$_pline" 6)" "$(json_escape "${SVC_REC_FMETHOD[$_i]}")"   "TAF method"
                _cmp "$(field "$_pline" 7)" "$(json_bool_token "${SVC_REC_COMMIT[$_i]}")" "COMMIT_OUTCOME"
                _cmp "$(field "$_pline" 8)" "$(json_escape "${SVC_REC_DRAIN[$_i]}")"     "DRAIN_TIMEOUT"
                [[ -n "$_deltas" ]] && CHANGE_SVC_CHANGED+=("\`${_svc}\` — ${_deltas}")
            fi
            _i=$((_i + 1))
        done
    fi

    CHANGE_COUNT=$(( ${#CHANGE_ROWS[@]} + ${#CHANGE_SVC_ADDED[@]} + ${#CHANGE_SVC_REMOVED[@]} + ${#CHANGE_SVC_CHANGED[@]} ))
    if [[ $CHANGE_COUNT -gt 0 ]]; then
        info "${CHANGE_COUNT} change(s) since ${PREV_GENERATED_AT:-the previous report}"
    else
        info "No changes since ${PREV_GENERATED_AT:-the previous report}"
    fi
fi

{
    echo "# Data Guard Handoff Report"
    echo ""
    echo "- **Generated:** ${GEN_DATE}"
    echo "- **Generated on:** ${GEN_HOST}"
    if [[ -n "$ENV_LABEL" ]]; then
        echo "- **Environment:** ${ENV_LABEL}"
    fi
    if [[ -n "$STANDBY_DB_UNIQUE_NAME" ]]; then
        echo "- **Configuration:** ${PRIMARY_DB_UNIQUE_NAME} → ${STANDBY_DB_UNIQUE_NAME}"
    else
        echo "- **Configuration:** ${PRIMARY_DB_UNIQUE_NAME} (no peer detected)"
    fi
    if [[ -n "$DB_VERSION" ]]; then
        _arch="non-CDB"
        [[ "$IS_CDB" == "YES" ]] && _arch="CDB"
        echo "- **Database:** Oracle ${DB_VERSION} (${_arch}${DB_CHARSET:+, ${DB_CHARSET}})"
    fi
    if [[ -n "$CONTACT_INFO" ]]; then
        echo "- **Contact:** ${CONTACT_INFO}"
    fi
    if [[ -n "$VIZ_URL" ]]; then
        echo "- **Interactive diagram:** [open in the Data Guard visualizer](${VIZ_URL}) - topology only, no credentials"
    fi
    if [[ $SERVICE_FILTER_ACTIVE -eq 1 ]]; then
        _chip=""
        if [[ ${#SERVICE_FILTER[@]} -gt 0 ]]; then
            _chip="only ${SERVICE_FILTER[*]}"
        fi
        if [[ ${#SERVICE_EXCLUDE[@]} -gt 0 ]]; then
            _chip="${_chip}${_chip:+; }excluding ${SERVICE_EXCLUDE[*]}"
        fi
        echo "- **Service filter:** ${_chip} — this report does not cover every service on the database"
    fi
    if [[ $NO_JSON -eq 0 ]]; then
        echo "- **Machine-readable:** \`$(basename "$JSON_FILE")\`"
    fi
    _files="$(basename "$OUTPUT_FILE"), $(basename "${OUTPUT_FILE%.md}.html")"
    [[ $NO_JSON -eq 0 ]] && _files="${_files}, $(basename "$JSON_FILE")"
    if [[ $NO_PACK -eq 0 ]]; then
        _files="${_files}, $(basename "$TNSNAMES_FILE"), $(basename "$JDBC_FILE")"
        [[ -n "$STANDBY_HOSTNAME" ]] && _files="${_files}, $(basename "$VERIFY_FILE")"
    fi
    echo "- **Files:** ${_files}"
    echo ""
    if [[ "$DB_ROLE" != "PRIMARY" ]]; then
        echo "**WARNING:** This report was generated on the ${DB_ROLE:-non-primary} side. Application services only run on the primary, so the service list and connection strings below are incomplete or empty. Re-run this script on the primary host${PRIMARY_HOSTNAME:+ (\`${PRIMARY_HOSTNAME}\`)} before handing the report to anyone."
        echo ""
    fi
    echo "## At a Glance"
    echo ""
    echo "**Verdict:** ${VERDICT}"
    if [[ ${#VERDICT_NOTES[@]} -gt 0 ]]; then
        for n in "${VERDICT_NOTES[@]}"; do echo "- ${n}"; done
    fi
    echo ""
    echo "- **Data protection:** ${RPO_SHORT}. Full semantics in section 2."
    echo "- **Failover:** ${FAILOVER_SHORT}."
    echo "- **Standby readability:** ${READABILITY_SHORT}."
    echo "- **Standby data freshness:** apply lag ${APPLY_LAG_TEXT}, transport lag ${TRANSPORT_LAG_TEXT}."
    if [[ -n "$RECOMMENDED_SVC" ]]; then
        echo "- **Application connect string:** use the role-aware descriptor for service \`${RECOMMENDED_SVC}\` (section 1)."
    else
        echo "- **Application connect string:** no user-created service exists yet — do not hand out the default-service descriptors in section 1; create a dedicated service first."
    fi
    echo "- **Before go-live:** work through the client/pool checklist (section 3) and the verification steps (section 4)."
    echo ""

    if [[ $NO_JSON -eq 0 ]]; then
        echo "## Changes Since Last Report"
        echo ""
        if [[ $HAVE_PREVIOUS -eq 0 ]]; then
            echo "First report for this configuration — no previous run to compare against (the JSON sidecar written by this run becomes the baseline)."
            echo ""
        elif [[ $CHANGE_COUNT -eq 0 && ${#CHANGE_NOTES[@]} -eq 0 ]]; then
            echo "No changes since the previous report (generated ${PREV_GENERATED_AT:-unknown})."
            echo ""
        else
            echo "Compared against the previous JSON sidecar, generated ${PREV_GENERATED_AT:-unknown}."
            echo ""
            if [[ ${#CHANGE_ROWS[@]} -gt 0 ]]; then
                echo "| Item | Previous | Current |"
                echo "|------|----------|---------|"
                for r in "${CHANGE_ROWS[@]}"; do echo "$r"; done
                echo ""
            fi
            if [[ ${#CHANGE_SVC_ADDED[@]} -gt 0 ]]; then
                echo "**Services added:**"
                echo ""
                for s in "${CHANGE_SVC_ADDED[@]}"; do echo "- \`${s}\`"; done
                echo ""
            fi
            if [[ ${#CHANGE_SVC_REMOVED[@]} -gt 0 ]]; then
                echo "**Services removed:**"
                echo ""
                for s in "${CHANGE_SVC_REMOVED[@]}"; do echo "- \`${s}\` — connection strings handed out for it no longer apply"; done
                echo ""
            fi
            if [[ ${#CHANGE_SVC_CHANGED[@]} -gt 0 ]]; then
                echo "**Services changed:**"
                echo ""
                for s in "${CHANGE_SVC_CHANGED[@]}"; do echo "- ${s}"; done
                echo ""
            fi
            if [[ ${#CHANGE_NOTES[@]} -gt 0 ]]; then
                for s in "${CHANGE_NOTES[@]}"; do echo "- ${s}"; done
                echo ""
            fi
        fi
    fi

    echo "## 1. Connection Strings"
    echo ""
    echo "**Role-aware (failover)** descriptors: both hosts in one ADDRESS_LIST. The service runs only on the current primary (stopped on the standby by the role trigger), so clients follow the primary across switchover/failover with no config change. Use this for the application tier."
    echo ""
    if [[ "$ROLE_TRIGGER_READY" == "YES" ]]; then
        echo "**Role-aware trigger status:** deployed and enabled. Role-aware descriptors are safe to hand to applications **for the services the trigger manages** - each service section below states whether it is one of them."
    else
        echo "**WARNING:** The \`DG_SERVICE_MGR\` package and both role-aware triggers are not confirmed enabled. Role-aware descriptors may connect applications to a read-only standby until \`trigger/create_role_trigger.sh\` is deployed."
    fi
    echo ""
    echo "### Descriptor Parameters"
    echo ""
    echo "| Parameter | Value | Effect |"
    echo "|-----------|-------|--------|"
    echo "| LOAD_BALANCE | OFF | Addresses tried in listed order: primary host first, then standby |"
    echo "| TRANSPORT_CONNECT_TIMEOUT | ${TNS_TCT} s | TCP connect budget per address |"
    echo "| CONNECT_TIMEOUT | ${TNS_CT} s | Total budget per address (TCP + listener handshake + session creation) |"
    echo "| RETRY_COUNT / RETRY_DELAY | ${TNS_RC} / ${TNS_RD} s | After the whole ADDRESS_LIST fails, it is retried ${TNS_RC} more times, ${TNS_RD} s apart |"
    echo ""
    echo "The Easy Connect Plus form below carries the same values (retry_delay is omitted there - not every 19c client parses it - so its retries are back-to-back). The descriptor itself configures no TAF (\`FAILOVER_MODE\`); whether the **service** has TAF or Transaction Guard is stated per service below."
    echo ""
    echo "Worst-case connect times these values produce:"
    echo ""
    echo "- Both hosts unreachable (TCP timeout): 2 addresses x ${TNS_TCT} s per pass, $((TNS_RC + 1)) passes, ${TNS_RC} x ${TNS_RD} s delays = **about ${WORST_BOTH_S} s** until the driver returns an error."
    echo "- Primary host down, standby listener up (service stopped there): about ${TNS_TCT} s TCP timeout + immediate ORA-12514 per pass = **about ${WORST_PRI_S} s** until error."
    echo "- Hosts up but hung handshakes: one pass is bounded by ${TNS_CT} s per address = up to ${ONE_PASS_MAX_S} s per pass."
    echo "- Failover in progress: attempts cycle (each bounded as above) until the service registers on the new primary, then the next attempt succeeds."
    echo ""

    svc_idx=0
    while [[ $svc_idx -lt ${#SERVICE_LIST[@]} ]]; do
        svc="${SERVICE_LIST[$svc_idx]}"
        svc_con="${SERVICE_CON[$svc_idx]}"
        svc_class="${SERVICE_CLASS[$svc_idx]}"
        svc_idx=$((svc_idx + 1))
        local_safe=$(echo "$svc" | tr '.' '_' | tr '[:lower:]' '[:upper:]')
        ALIAS_HA="${local_safe}_HA"

        echo "### Service: \`${svc}\`"
        echo ""
        if [[ "$IS_CDB" == "YES" && -n "$svc_con" ]]; then
            if [[ "$svc_con" == 'CDB$ROOT' ]]; then
                echo "Lands in container \`${svc_con}\` — the CDB root. Application schemas normally live in a PDB; check that root-level access is intended."
            else
                echo "Lands in container \`${svc_con}\` (PDB)."
            fi
            echo ""
        fi
        if [[ "$svc_class" == "DEFAULT" ]]; then
            echo "> **Default service — NOT role-aware.** \`${svc}\` is the container's own default service: it is registered wherever the container is up (including an open standby), and \`trigger/create_role_trigger.sh\` deliberately excludes it, so it does **not** follow the primary after a switchover or failover. Keep it for admin/DBA access; give applications a dedicated service (\`trigger/create_pdb_service.sh\` / \`trigger/create_cdb_service.sh\`) instead."
            echo ""
        elif [[ "$ROLE_TRIGGER_READY" == "YES" ]]; then
            echo "Managed by the role trigger - safe to hand to applications."
            echo ""
        else
            echo "**Not yet role-aware:** deploy \`trigger/create_role_trigger.sh\` before handing this descriptor to applications."
            echo ""
        fi
        emit_service_attr_lines "$svc_con" "$svc"
        echo ""

        if [[ $ALL_FLAVORS -eq 1 ]]; then
            echo "#### Role-aware (failover)"
            echo ""
        fi
        if [[ -n "$STANDBY_HOSTNAME" ]]; then
            echo '```'
            render_tns_ha "$ALIAS_HA" "$PRIMARY_HOSTNAME" "$STANDBY_HOSTNAME" "$PORT" "$svc"
            echo '```'
            echo ""
            echo "JDBC (thin driver):"
            echo ""
            echo '```'
            render_jdbc_ha "$PRIMARY_HOSTNAME" "$STANDBY_HOSTNAME" "$PORT" "$svc"
            echo '```'
            echo ""
            echo "Easy Connect Plus (19c+ client libraries${DB_VERSION:+; server is ${DB_VERSION}}):"
            echo ""
            echo '```'
            render_easy_connect_ha "$PRIMARY_HOSTNAME" "$STANDBY_HOSTNAME" "$PORT" "$svc"
            echo '```'
            echo ""
        else
            echo "Standby hostname unknown - only a primary-only string can be offered:"
            echo ""
            echo '```'
            echo "${PRIMARY_HOSTNAME}:${PORT}/${svc}"
            echo '```'
            echo ""
        fi

        if [[ $ALL_FLAVORS -eq 1 ]]; then
            ALIAS_PRI="${local_safe}_PRI"
            ALIAS_STB="${local_safe}_STB"
            echo "#### Primary-only"
            echo ""
            echo "Writes and admin access. Points at one host, so it stops working after a switchover until this report is regenerated."
            echo ""
            echo '```'
            render_tns_single "$ALIAS_PRI" "$PRIMARY_HOSTNAME" "$PORT" "$svc"
            echo '```'
            echo ""
            echo "JDBC (thin driver):"
            echo ""
            echo '```'
            render_jdbc_single "$PRIMARY_HOSTNAME" "$PORT" "$svc"
            echo '```'
            echo ""
            if [[ -n "$STANDBY_HOSTNAME" ]]; then
                echo "#### Standby-only"
                echo ""
                case "$STANDBY_OPEN_UPPER" in
                    *MOUNTED*)
                        echo "**Not currently usable:** the standby is MOUNTED (not open read-only) - these connections fail with ORA-01033 until it is opened READ ONLY WITH APPLY."
                        echo "" ;;
                    *READ*ONLY*APPLY*)
                        echo "Read-only reporting against the open standby (Active Data Guard - separately licensed). Reads are stale by the apply lag (${APPLY_LAG_TEXT}); DML and DDL fail with ORA-16000. Bound staleness per session with \`ALTER SESSION SET STANDBY_MAX_DATA_DELAY = <seconds>\` (ORA-03172 instead of stale data)."
                        echo "" ;;
                    *)
                        echo "Standby readability could not be discovered; verify OPEN_MODE before handing these strings to anyone."
                        echo "" ;;
                esac
                echo '```'
                render_tns_single "$ALIAS_STB" "$STANDBY_HOSTNAME" "$PORT" "$svc"
                echo '```'
                echo ""
                echo "JDBC (thin driver):"
                echo ""
                echo '```'
                render_jdbc_single "$STANDBY_HOSTNAME" "$PORT" "$svc"
                echo '```'
                echo ""
            fi
        fi
    done

    if [[ -n "$STANDBY_HOSTNAME" ]]; then
        echo "### Driver Examples"
        echo ""
        echo "Same Easy Connect Plus string, per driver (shown for \`${EXAMPLE_SVC}\`; substitute another service name as needed):"
        echo ""
        render_driver_examples "$VERIFY_EZ"
    fi

    case "$STANDBY_OPEN_UPPER" in
        *MOUNTED*)
            echo "**Standby readability:** the broker reports Real Time Query OFF - the standby is MOUNTED (or open read-only without apply), so direct standby connections will fail until it is opened READ ONLY WITH APPLY."
            ;;
        *READ*ONLY*APPLY*)
            echo "**Standby readability:** the standby is READ ONLY WITH APPLY (Active Data Guard - separately licensed). Reads see committed data as of the apply point (staleness = apply lag; read-your-writes across the two databases is not guaranteed). Bound staleness per session with \`ALTER SESSION SET STANDBY_MAX_DATA_DELAY = <seconds>\` (queries then raise ORA-03172 instead of returning stale data); \`ALTER SESSION SYNC WITH PRIMARY\` blocks until caught up (requires SYNC transport and real-time apply). DML and DDL fail with ORA-16000 (exception: DML on global temporary tables)."
            ;;
        *)
            echo "**Standby readability:** could not be discovered; verify OPEN_MODE before giving direct standby strings to applications."
            ;;
    esac
    echo ""

    echo "## 2. Application Impact"
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
    echo "| ORA-25402 | TAF (where enabled on the service - see section 1) failed the session over mid-transaction | ROLLBACK, then re-run the transaction |"
    echo "| ORA-16000 | DML sent to a read-only standby | Not retryable: routing bug - service running on the standby without the role trigger, or a standby-only string handed to a writer |"
    echo ""
    echo "**Commit ambiguity:** a dropped connection (e.g. ORA-03113) while a COMMIT is in flight leaves the outcome unknown - the transaction may or may not be committed on the surviving database. Blind re-execution double-applies it. Use idempotency keys / unique business keys and verify state after reconnect. Oracle Transaction Guard resolves the outcome programmatically but requires a service with COMMIT_OUTCOME=TRUE and a 12c+ driver - section 1 states per service whether that is enabled here."
    echo ""

    echo "### Notes for Client Teams"
    echo ""
    if [[ -n "$IMPACT_REFERENCE" ]]; then
        echo "- Full application behavior briefing: \`${IMPACT_REFERENCE}\`."
    fi
    echo "- The role-aware descriptor works only because \`trigger/create_role_trigger.sh\` stops the service on the standby. With the trigger disabled, both hosts accept connections and writers landing on the standby get ORA-16000."
    echo "- Sequences: NOORDER/CACHE sequences (default CACHE 20) discard cached values at role change - expect gaps of up to the CACHE size per sequence, and no ordering guarantee across a failover. Never use sequence values as gapless or strictly-ordered business keys."
    echo "- TAF, Transaction Guard and Application Continuity are per-service settings; section 1 states what each service actually has (discovered from the database, not assumed). Ask the DBA team to change a service's settings if your failure-handling design needs more."
    if [[ -n "$DB_DOMAIN" ]]; then
        echo "- This database sets DB_DOMAIN=\`${DB_DOMAIN}\`. Clients whose \`sqlnet.ora\` sets \`NAMES.DEFAULT_DOMAIN\` append that domain to every unqualified TNS alias - define aliases fully qualified (as printed here) so resolution works with or without a default domain."
    fi
    echo "- After a switchover nothing changes for clients on the role-aware descriptor. Host-specific strings silently point at the wrong database until this report is regenerated."
    echo ""
    echo "## 3. Client and Pool Settings"
    echo ""
    echo "- [ ] Pool connection-wait/checkout timeout of at least $((WORST_PRI_S + 5)) s: one pass over the ADDRESS_LIST can take up to ${ONE_PASS_MAX_S} s, and the descriptor's worst case is ${WORST_BOTH_S} s (section 1). A shorter pool timeout aborts borrowers before the descriptor's retry logic can succeed."
    echo "- [ ] Read/call timeout on every request path (JDBC \`oracle.jdbc.ReadTimeout\`, python-oracledb \`call_timeout\`, ODP.NET \`CommandTimeout\`): without one, a failover can leave in-flight calls hanging until TCP gives up (minutes)."
    echo "- [ ] Dead connection detection: server-side \`SQLNET.EXPIRE_TIME\` is ${SQLNET_EXPIRE_TIME}. Add \`(ENABLE=BROKEN)\` inside DESCRIPTION to enable OS TCP keepalive on the session socket, and tune client keepalive below any firewall idle timeout."
    echo "- [ ] Validate on borrow (JDBC \`isValid()\`, python-oracledb pool \`ping_interval\`, ODP.NET \`Validate Connection=true\`): after a failover every idle pooled connection is dead and must be detected before first use."
    echo "- [ ] Cap pool max size and reconnect concurrency: after a failover all clients reconnect at once, and an uncapped logon storm slows the new primary during the cold-cache window."
    echo "- [ ] Set max connection lifetime/recycle below any firewall or load-balancer idle timeout between the app tier and the database hosts."
    echo ""
    echo "## 4. Verification"
    echo ""
    echo "Reachability - both hosts, from every application host (the standby address is only exercised when it is already an emergency):"
    echo ""
    echo '```bash'
    echo "tnsping ${PRIMARY_HOSTNAME}:${PORT}/${EXAMPLE_SVC}"
    if [[ -n "$STANDBY_HOSTNAME" ]]; then
        echo "tnsping ${STANDBY_HOSTNAME}:${PORT}/${EXAMPLE_SVC}"
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
    echo ""
    if [[ $NO_PACK -eq 0 && -n "$STANDBY_HOSTNAME" ]]; then
        echo "Or run the generated \`$(basename "$VERIFY_FILE")\` from each application host — it performs the same checks (name resolution, TCP reachability on both hosts, and the end-to-end role check when \`sqlplus\` and credentials are available) and exits nonzero if any check that could run failed:"
        echo ""
        echo '```bash'
        echo "./$(basename "$VERIFY_FILE")                       # reachability only"
        echo "APP_USER=app_user APP_PASSWORD=... ./$(basename "$VERIFY_FILE")"
        echo "./$(basename "$VERIFY_FILE") --expect-db-unique-name ${STANDBY_DB_UNIQUE_NAME:-<other side>}   # after a switchover drill"
        echo '```'
        echo ""
    fi

    echo "## Appendix: DBA Snapshot"
    echo ""
    echo "Point-in-time details for the DBA team - application teams can stop reading here. Regenerate this report after listener changes, new services, or any topology change."
    echo ""
    echo "### Topology"
    echo ""
    echo "| Role | DB_UNIQUE_NAME | Hostname | Listener |"
    echo "|------|----------------|----------|----------|"
    echo "| Primary | ${PRIMARY_DB_UNIQUE_NAME} | ${PRIMARY_HOSTNAME} | ${PORT} |"
    if [[ -n "$STANDBY_DB_UNIQUE_NAME" ]]; then
        echo "| Standby | ${STANDBY_DB_UNIQUE_NAME} | ${STANDBY_HOSTNAME:-UNKNOWN} | ${PORT} |"
    fi
    if [[ -n "$FSFO_OBSERVER_HOST" ]]; then
        echo "| Observer | - | ${FSFO_OBSERVER_HOST} | - |"
    fi
    echo ""
    echo "### Status Snapshot"
    echo ""
    echo "| Item | Value |"
    echo "|------|-------|"
    echo "| Local role | ${DB_ROLE:-N/A} |"
    echo "| Open mode | ${OPEN_MODE:-N/A} |"
    echo "| Database version | ${DB_VERSION:-N/A} |"
    echo "| CDB | ${IS_CDB:-N/A} |"
    echo "| Character set | ${DB_CHARSET:-N/A} |"
    echo "| Protection mode | ${PROTECTION_MODE:-N/A} |"
    echo "| Standby LogXptMode | ${STANDBY_LOGXPTMODE:-unknown} |"
    echo "| Standby open mode | ${STANDBY_OPEN_MODE:-unknown} |"
    echo "| Switchover status | ${SWITCHOVER_STATUS:-N/A} |"
    echo "| Force logging | ${FORCE_LOGGING:-N/A} |"
    echo "| Broker started | ${DG_BROKER_START:-N/A} |"
    echo "| Last received seq# | ${LAST_RECEIVED:-N/A} |"
    echo "| Last applied seq# | ${LAST_APPLIED:-N/A} |"
    echo "| Apply lag (sequences) | ${APPLY_LAG_SEQ} |"
    echo "| Apply lag (time) | ${APPLY_LAG_TEXT} |"
    echo "| Transport lag (time) | ${TRANSPORT_LAG_TEXT} |"
    echo "| Archive gaps | ${GAP_COUNT} |"
    echo "| FSFO status | ${FSFO_STATUS:-N/A} |"
    echo "| FSFO observer present | ${FSFO_OBSERVER:-N/A} |"
    if [[ -n "$FSFO_OBSERVER_HOST" ]]; then
        echo "| FSFO observer host | ${FSFO_OBSERVER_HOST} |"
    fi
    if [[ "$FSFO_ENABLED" == "YES" ]]; then
        echo "| FSFO threshold | ${FSFO_THRESHOLD:-unknown} |"
    fi
    echo "| Role trigger ready | ${ROLE_TRIGGER_READY} (${TRIGGER_OWNERS:-unknown}) |"
    echo "| SQLNET.EXPIRE_TIME | ${SQLNET_EXPIRE_TIME} |"
    echo ""

    echo "### Recommended Service Changes (DBA)"
    echo ""
    echo "Recommendations, not requirements: they matter for application pools that use TAF, Transaction Guard or drain-aware maintenance. Suggested values are starting points — tune them to the workload."
    echo ""
    _rec_any=0
    _i=0
    while [[ $_i -lt ${#SERVICE_LIST[@]} ]]; do
        _svc="${SERVICE_LIST[$_i]}"
        _con="${SERVICE_CON[$_i]}"
        _cls="${SERVICE_CLASS[$_i]}"
        _ftype=$(printf '%s' "${SVC_REC_FTYPE[$_i]}" | tr '[:lower:]' '[:upper:]')
        _commit=$(printf '%s' "${SVC_REC_COMMIT[$_i]}" | tr '[:lower:]' '[:upper:]')
        _drain="${SVC_REC_DRAIN[$_i]}"
        _i=$((_i + 1))
        # Default services are never handed to applications, so their HA
        # attributes are not worth changing.
        [[ "$_cls" == "USER" ]] || continue
        _need_taf=0
        _need_tg=0
        _need_drain=0
        case "$_ftype" in NONE|-|'') _need_taf=1 ;; esac
        case "$_commit" in TRUE|YES) ;; *) _need_tg=1 ;; esac
        case "$_drain" in ''|-|0) _need_drain=1 ;; esac
        [[ $((_need_taf + _need_tg + _need_drain)) -eq 0 ]] && continue
        _rec_any=1

        _missing=""
        [[ $_need_taf   -eq 1 ]] && _missing="${_missing}${_missing:+, }TAF"
        [[ $_need_tg    -eq 1 ]] && _missing="${_missing}${_missing:+, }Transaction Guard"
        [[ $_need_drain -eq 1 ]] && _missing="${_missing}${_missing:+, }drain timeout"

        echo "#### \`${_svc}\`"
        echo ""
        echo "Missing: ${_missing}. Run on the PRIMARY as a user with the \`DBMS_SERVICE\` privilege:"
        echo ""
        echo '```sql'
        if [[ "$IS_CDB" == "YES" && -n "$_con" && "$_con" != 'CDB$ROOT' ]]; then
            echo "ALTER SESSION SET CONTAINER = ${_con};"
        fi
        echo "DECLARE"
        echo "  p dbms_service.svc_parameter_array;"
        echo "BEGIN"
        if [[ $_need_taf -eq 1 ]]; then
            echo "  p(dbms_service.failover_type)    := 'SELECT';"
            echo "  p(dbms_service.failover_method)  := 'BASIC';"
            echo "  p(dbms_service.failover_retries) := '30';"
            echo "  p(dbms_service.failover_delay)   := '5';"
        fi
        if [[ $_need_tg -eq 1 ]]; then
            echo "  p(dbms_service.commit_outcome)    := 'true';"
            echo "  p(dbms_service.retention_timeout) := '86400';"
        fi
        if [[ $_need_drain -eq 1 ]]; then
            echo "  p(dbms_service.drain_timeout) := '60';"
        fi
        echo "  dbms_service.modify_service(service_name => '${_svc}', parameter_array => p);"
        echo "END;"
        echo "/"
        echo '```'
        echo ""
        echo "Restart the service for the new TAF attributes to apply to new sessions (\`dbms_service.stop_service('${_svc}');\` then \`dbms_service.start_service('${_svc}');\`) — existing sessions keep the old settings. The service definition replicates to the standby via redo, so no separate change is needed there."
        echo ""
    done
    if [[ $_rec_any -eq 0 ]]; then
        echo "All user services already carry TAF, Transaction Guard and a drain timeout — nothing to do."
        echo ""
    fi

    if [[ -n "$BROKER_OUTPUT" ]]; then
        echo "### Broker Configuration"
        echo ""
        echo '```'
        echo "$BROKER_OUTPUT"
        echo '```'
        echo ""
    fi

    echo "### Adding Datafiles or PDBs After Setup"
    echo ""
    echo "- New datafiles and PDBs replicate to the standby automatically only when their primary-side paths fall under a directory prefix covered by the standby's \`DB_FILE_NAME_CONVERT\` pairs. OMF-mode standbys (\`db_create_file_dest\` set) are immune."
    echo "- A file added in an uncovered directory is created as \`UNNAMEDnnnnn\` in \`\$ORACLE_HOME/dbs\` on the standby; MRP stops with ORA-01274 and redo apply halts until manually repaired."
    echo "- Before creating a PDB or adding a datafile in a new directory, keep paths under a covered prefix, or use \`CREATE PLUGGABLE DATABASE ... FILE_NAME_CONVERT\` / PDB-level OMF."
    echo "- After any addition, verify the standby: \`dg_status.sh\` flags UNNAMED datafiles; also check \`V\$RECOVER_FILE\` and the standby alert log."
    echo "- Repair sequence (\`STANDBY_FILE_MANAGEMENT=MANUAL\`, \`ALTER DATABASE CREATE DATAFILE ... AS ...\`, back to \`AUTO\`, restart apply): see \"Life After Setup: Adding Datafiles and PDBs\" in the repository's \`docs/DATA_GUARD_WALKTHROUGH.md\`."

    if [[ ${#DISCOVERY_WARNINGS[@]} -gt 0 ]]; then
        echo ""
        echo "### Discovery Warnings"
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

# Styled, self-contained HTML twin of the Markdown report
HTML_FILE="${OUTPUT_FILE%.md}.html"
[[ "$HTML_FILE" == "$OUTPUT_FILE" ]] && HTML_FILE="${OUTPUT_FILE}.html"
render_handoff_html < "$OUTPUT_FILE" > "$HTML_FILE"
info "HTML report written: $HTML_FILE"

# ============================================================
# JSON sidecar
# ============================================================
# Written LAST and via a temp file + mv: the previous sidecar (this run's
# diff baseline) stays readable and intact until the new one is complete,
# so a crash mid-run leaves the old baseline usable.
if [[ $NO_JSON -eq 0 ]]; then
    JSON_TMP="${JSON_FILE}.tmp.$$"
    {
        echo "{"
        json_str_line schema_version "1"
        json_str_line generated_at   "$GEN_STAMP"
        json_str_line generated_tz   "$GEN_TZ"
        json_str_line generated_on   "$GEN_HOST"
        json_str_line environment    "$ENV_LABEL"
        json_str_line contact        "$CONTACT_INFO"
        json_str_line verdict        "$VERDICT"
        json_array_line verdict_notes ${VERDICT_NOTES[@]+"${VERDICT_NOTES[@]}"}
        json_str_line primary_db_unique_name "$PRIMARY_DB_UNIQUE_NAME"
        json_str_line standby_db_unique_name "$STANDBY_DB_UNIQUE_NAME"
        json_str_line primary_host   "$PRIMARY_HOSTNAME"
        json_str_line standby_host   "$STANDBY_HOSTNAME"
        json_str_line port           "$PORT"
        json_str_line db_role        "$DB_ROLE"
        json_str_line open_mode      "$OPEN_MODE"
        json_str_line db_version     "$DB_VERSION"
        json_str_line is_cdb         "$IS_CDB"
        json_str_line charset        "$DB_CHARSET"
        json_str_line db_domain      "$DB_DOMAIN"
        json_str_line protection_mode      "$PROTECTION_MODE"
        json_str_line standby_logxptmode   "$STANDBY_LOGXPTMODE"
        json_str_line standby_open_mode    "$STANDBY_OPEN_MODE"
        json_str_line switchover_status    "$SWITCHOVER_STATUS"
        json_str_line force_logging        "$FORCE_LOGGING"
        json_bool_line broker_started      "$DG_BROKER_START"
        json_str_line broker_config_status "${BROKER_CONFIG_STATUS:-}"
        json_str_line last_received_seq    "$LAST_RECEIVED"
        json_str_line last_applied_seq     "$LAST_APPLIED"
        json_str_line apply_lag_seq        "$APPLY_LAG_SEQ"
        json_str_line apply_lag_seconds    "$APPLY_LAG_SECONDS"
        json_str_line apply_lag_text       "$APPLY_LAG_TEXT"
        json_str_line transport_lag_seconds "$TRANSPORT_LAG_SECONDS"
        json_str_line transport_lag_text    "$TRANSPORT_LAG_TEXT"
        json_str_line archive_gaps          "$GAP_COUNT"
        json_bool_line fsfo_enabled         "$FSFO_ENABLED"
        json_str_line fsfo_status           "$FSFO_STATUS"
        json_bool_line fsfo_observer_present "$FSFO_OBSERVER"
        json_str_line fsfo_observer_host    "$FSFO_OBSERVER_HOST"
        json_str_line fsfo_threshold        "$([[ "$FSFO_ENABLED" == "YES" ]] && printf '%s' "$FSFO_THRESHOLD")"
        json_bool_line role_trigger_ready   "$ROLE_TRIGGER_READY"
        json_str_line trigger_owners        "$TRIGGER_OWNERS"
        json_str_line sqlnet_expire_time    "$SQLNET_EXPIRE_TIME"
        json_str_line visualizer_url        "$VIZ_URL"
        printf '  "descriptor": {\n'
        printf '    "connect_timeout": "%s",\n'           "$TNS_CT"
        printf '    "transport_connect_timeout": "%s",\n' "$TNS_TCT"
        printf '    "retry_count": "%s",\n'               "$TNS_RC"
        printf '    "retry_delay": "%s",\n'               "$TNS_RD"
        printf '    "worst_both_hosts_down_s": "%s",\n'   "$WORST_BOTH_S"
        printf '    "worst_primary_down_s": "%s"\n'       "$WORST_PRI_S"
        printf '  },\n'
        json_array_line service_filter  ${SERVICE_FILTER[@]+"${SERVICE_FILTER[@]}"}
        json_array_line service_exclude ${SERVICE_EXCLUDE[@]+"${SERVICE_EXCLUDE[@]}"}
        # One service object per LINE - that is what makes the awk reader
        # above possible.
        if [[ ${#SERVICE_LIST[@]} -eq 0 ]]; then
            printf '  "services": [],\n'
        else
            printf '  "services": [\n'
            _i=0
            while [[ $_i -lt ${#SERVICE_LIST[@]} ]]; do
                _sep=","
                [[ $((_i + 1)) -eq ${#SERVICE_LIST[@]} ]] && _sep=""
                printf '    {"name": "%s", "container": "%s", "class": "%s", "role_aware": %s, "taf_type": "%s", "taf_method": "%s", "taf_retries": "%s", "taf_delay": "%s", "commit_outcome": %s, "drain_timeout": "%s", "failover_restore": "%s", "tns_alias": "%s", "easy_connect": "%s", "jdbc": "%s"}%s\n' \
                    "$(json_escape "${SERVICE_LIST[$_i]}")" \
                    "$(json_escape "${SERVICE_CON[$_i]}")" \
                    "$(json_escape "${SERVICE_CLASS[$_i]}")" \
                    "${SVC_REC_ROLE_AWARE[$_i]}" \
                    "$(json_escape "${SVC_REC_FTYPE[$_i]}")" \
                    "$(json_escape "${SVC_REC_FMETHOD[$_i]}")" \
                    "$(json_escape "${SVC_REC_FRETRIES[$_i]}")" \
                    "$(json_escape "${SVC_REC_FDELAY[$_i]}")" \
                    "$(json_bool_token "${SVC_REC_COMMIT[$_i]}")" \
                    "$(json_escape "${SVC_REC_DRAIN[$_i]}")" \
                    "$(json_escape "${SVC_REC_RESTORE[$_i]}")" \
                    "$(json_escape "${SVC_REC_ALIAS[$_i]}")" \
                    "$(json_escape "${SVC_REC_EZ[$_i]}")" \
                    "$(json_escape "${SVC_REC_JDBC[$_i]}")" \
                    "$_sep"
                _i=$((_i + 1))
            done
            printf '  ],\n'
        fi
        json_array_line discovery_warnings ${DISCOVERY_WARNINGS[@]+"${DISCOVERY_WARNINGS[@]}"}
        # Last member: no trailing comma.
        printf '  "generator": "dg_handoff.sh"\n'
        echo "}"
    } > "$JSON_TMP"
    mv "$JSON_TMP" "$JSON_FILE"
    info "JSON sidecar written: $JSON_FILE"
fi

# ============================================================
# Deliverable pack: tnsnames.ora / jdbc.properties / verify script
# ============================================================
if [[ $NO_PACK -eq 0 ]]; then
    {
        echo "# Data Guard role-aware TNS aliases - generated ${GEN_DATE}"
        echo "# Configuration: ${PRIMARY_DB_UNIQUE_NAME}${STANDBY_DB_UNIQUE_NAME:+ -> ${STANDBY_DB_UNIQUE_NAME}}"
        echo "# Source: $(basename "$OUTPUT_FILE"). Append these entries to the client's tnsnames.ora."
        if [[ -n "$DB_DOMAIN" ]]; then
            echo "# The service names are fully qualified (DB_DOMAIN=${DB_DOMAIN}), so they"
            echo "# resolve identically with or without a client-side NAMES.DEFAULT_DOMAIN."
        fi
        echo ""
        _i=0
        while [[ $_i -lt ${#SERVICE_LIST[@]} ]]; do
            _svc="${SERVICE_LIST[$_i]}"
            _base=$(service_alias "$_svc")
            echo "# service ${_svc} (${SERVICE_CLASS[$_i]}, role-aware: ${SVC_REC_ROLE_AWARE[$_i]})"
            if [[ -n "$STANDBY_HOSTNAME" ]]; then
                render_tns_ha "${_base}_HA" "$PRIMARY_HOSTNAME" "$STANDBY_HOSTNAME" "$PORT" "$_svc"
            else
                render_tns_single "${_base}_HA" "$PRIMARY_HOSTNAME" "$PORT" "$_svc"
            fi
            echo ""
            if [[ $ALL_FLAVORS -eq 1 ]]; then
                render_tns_single "${_base}_PRI" "$PRIMARY_HOSTNAME" "$PORT" "$_svc"
                echo ""
                if [[ -n "$STANDBY_HOSTNAME" ]]; then
                    render_tns_single "${_base}_STB" "$STANDBY_HOSTNAME" "$PORT" "$_svc"
                    echo ""
                fi
            fi
            _i=$((_i + 1))
        done
    } > "$TNSNAMES_FILE"
    info "TNS aliases written: $TNSNAMES_FILE"

    {
        echo "# Data Guard role-aware JDBC URLs - generated ${GEN_DATE}"
        echo "# Configuration: ${PRIMARY_DB_UNIQUE_NAME}${STANDBY_DB_UNIQUE_NAME:+ -> ${STANDBY_DB_UNIQUE_NAME}}"
        echo "# One <SERVICE>_HA.url (full descriptor) and <SERVICE>_HA.easyconnect per service."
        echo ""
        _i=0
        while [[ $_i -lt ${#SERVICE_LIST[@]} ]]; do
            _base=$(service_alias "${SERVICE_LIST[$_i]}")
            echo "${_base}_HA.url=${SVC_REC_JDBC[$_i]}"
            echo "${_base}_HA.easyconnect=${SVC_REC_EZ[$_i]}"
            _i=$((_i + 1))
        done
    } > "$JDBC_FILE"
    info "JDBC properties written: $JDBC_FILE"

    if [[ -n "$STANDBY_HOSTNAME" ]]; then
        write_verify_script > "$VERIFY_FILE"
        chmod +x "$VERIFY_FILE" 2>/dev/null || true
        info "Verification script written: $VERIFY_FILE"
    else
        info "Verification script skipped: no standby hostname (pass --standby-host to generate it)."
    fi
fi

echo ""
cat "$OUTPUT_FILE"
echo ""
if [[ ${#DISCOVERY_WARNINGS[@]} -gt 0 ]]; then
    warn "${#DISCOVERY_WARNINGS[@]} discovery item(s) failed and were rendered as N/A (see 'Discovery Warnings' in the report):"
    for w in "${DISCOVERY_WARNINGS[@]}"; do
        warn "  - ${w}"
    done
fi
info "Verdict: ${VERDICT}  |  Apply lag: ${APPLY_LAG_SEQ} sequences, ${APPLY_LAG_TEXT}  |  Gaps: ${GAP_COUNT}  |  Services: ${#SERVICE_LIST[@]}"
if [[ "$VERDICT" != "HEALTHY" ]]; then
    for n in "${VERDICT_NOTES[@]}"; do
        warn "  ${VERDICT}: ${n}"
    done
fi

# 0 healthy, 1 warnings, 2 errors (3 = usage/connect failure, via die/arg
# parsing) - same convention as dg_status.sh, so monitoring wrappers can
# tell the severities apart without scraping the text.
case "$VERDICT" in
    ERROR)   exit 2 ;;
    WARNING) exit 1 ;;
    *)       exit 0 ;;
esac
