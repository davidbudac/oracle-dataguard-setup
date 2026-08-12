#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 10: Generate Handoff Report
# ============================================================
# Run this script on the PRIMARY database server after all
# previous steps (including step 7 verification) are complete.
#
# Produces a Markdown handoff document with:
#   - A short Data Guard configuration & status snapshot
#   - End-user connection info per service (TNS + JDBC), in
#     three flavors: primary-only, standby-only, and role-aware
#     failover (recommended for app tier when the role-aware
#     service trigger (trigger/create_role_trigger.sh) is deployed)
#
# The report is written to the NFS share so it is reachable
# from both primary and standby, and printed to stdout.
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

source "${COMMON_DIR}/dg_functions.sh"
enable_verbose_mode "$@"

# ============================================================
# Helpers
# ============================================================

# Trim leading/trailing whitespace from every line, drop empty lines, then
# join what is left. Internal spaces are preserved on purpose: display fields
# such as "READ WRITE", "MAXIMUM AVAILABILITY" and "FAILED DESTINATION" end up
# verbatim in the customer-facing report.
clean_field() {
    printf '%s\n' "$1" | tr -d '\r' \
        | sed -e 's/^[[:space:]][[:space:]]*//' -e 's/[[:space:]][[:space:]]*$//' -e '/^$/d' \
        | tr -d '\n'
}

field_at() {
    # field_at <pipe-delimited-string> <index>
    echo "$1" | awk -F'|' -v i="$2" '{print $i}'
}

# Render a single-host TNS descriptor block
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

# Render a multi-host (role-aware) TNS descriptor block.
# Both addresses are listed; only the active primary will accept
# the service (the role trigger stops the service on standby).
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
      (FAILOVER_MODE = (TYPE = SELECT)(METHOD = BASIC)(RETRIES = 30)(DELAY = 5))
    )
  )
EOF
}

# JDBC thin URL: simple form
render_jdbc_single() {
    local host="$1" port="$2" service="$3"
    echo "jdbc:oracle:thin:@//${host}:${port}/${service}"
}

# JDBC thin URL with full descriptor (multi-host, role-aware)
render_jdbc_ha() {
    local phost="$1" shost="$2" port="$3" service="$4"
    printf 'jdbc:oracle:thin:@(DESCRIPTION=(CONNECT_TIMEOUT=10)(TRANSPORT_CONNECT_TIMEOUT=3)(RETRY_COUNT=3)(RETRY_DELAY=3)(ADDRESS_LIST=(LOAD_BALANCE=OFF)(ADDRESS=(PROTOCOL=TCP)(HOST=%s)(PORT=%s))(ADDRESS=(PROTOCOL=TCP)(HOST=%s)(PORT=%s)))(CONNECT_DATA=(SERVICE_NAME=%s)(FAILOVER_MODE=(TYPE=SELECT)(METHOD=BASIC)(RETRIES=30)(DELAY=5))))\n' \
        "$phost" "$port" "$shost" "$port" "$service"
}

render_easy_connect_ha() {
    local phost="$1" shost="$2" port="$3" service="$4"
    printf '%s:%s,%s:%s/%s?connect_timeout=5&transport_connect_timeout=3&retry_count=2\n' \
        "$phost" "$port" "$shost" "$port" "$service"
}

render_driver_table() {
    local service="$1" ez="$2"
    printf '| Client | Form |\n'
    printf '|--------|------|\n'
    printf '| ODP.NET | `User Id=app_user;Password=<pwd>;Data Source=%s` |\n' "$ez"
    printf '| python-oracledb | `oracledb.connect(user="app_user", password="<pwd>", dsn="%s")` |\n' "$ez"
    printf '| SQLAlchemy | `oracle+oracledb://app_user:<pwd>@%s` |\n' "$ez"
    printf '| SQL*Plus | `sqlplus app_user/<pwd>@%s` |\n' "$ez"
    printf '\n'
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
# Kept in step with dg_handoff.sh's copy of the same helper.
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
# Main
# ============================================================

print_banner "Step 10: Generate Handoff Report"
init_progress 6

init_log "10_generate_handoff_report"

# ---- Pre-flight ----
progress_step "Pre-flight Checks"
check_oracle_env || exit 1
check_nfs_mount || exit 1
check_db_connection || exit 1

if ! select_config_file STANDBY_CONFIG_FILE "standby configuration" "${NFS_SHARE}/standby_config_*.env"; then
    log_error "Standby configuration not found. Run the Data Guard setup first."
    exit 1
fi

log_info "Loading standby configuration..."
source "$STANDBY_CONFIG_FILE"

init_log "10_generate_handoff_report_${PRIMARY_DB_UNIQUE_NAME}"

if [[ "$CHECK_ONLY" == "1" ]]; then
    finish_check_mode "Handoff report would be generated at ${NFS_SHARE}/dg_handoff_${PRIMARY_DB_UNIQUE_NAME}.md"
fi

# ---- Verify role ----
progress_step "Verifying Local Role"

LOCAL_ROLE=$(clean_field "$(run_sql_query "get_db_role.sql")")
if [[ "$LOCAL_ROLE" != "PRIMARY" ]]; then
    log_warn "This script expects to run on the PRIMARY (current role: ${LOCAL_ROLE})."
    log_warn "Continuing anyway - report will be generated using the configured topology."
fi

# ---- Collect status ----
progress_step "Collecting Data Guard Status"

DB_STATUS=$(clean_field "$(run_sql_query "get_db_status_pipe.sql")")
DB_ROLE=$(field_at "$DB_STATUS" 1)
OPEN_MODE=$(field_at "$DB_STATUS" 2)
PROTECTION_MODE=$(field_at "$DB_STATUS" 3)
SWITCHOVER_STATUS=$(field_at "$DB_STATUS" 4)

FORCE_LOGGING=$(clean_field "$(run_sql_query "get_force_logging.sql")")
DG_BROKER_START=$(get_db_parameter "dg_broker_start")

APPLY_INFO=$(clean_field "$(run_sql_query "get_apply_info_pipe.sql" || true)")
LAST_APPLIED=$(field_at "$APPLY_INFO" 1)
LAST_RECEIVED=$(field_at "$APPLY_INFO" 2)
case "$LAST_APPLIED" in ''|*[!0-9]*) LAST_APPLIED="" ;; esac
case "$LAST_RECEIVED" in ''|*[!0-9]*) LAST_RECEIVED="" ;; esac
APPLY_LAG_SEQ=$(( ${LAST_RECEIVED:-0} - ${LAST_APPLIED:-0} ))

GAP_COUNT=$(clean_field "$(run_sql_query "get_archive_gap_count.sql")")
GAP_COUNT="${GAP_COUNT:-0}"

FSFO_RAW=$(clean_field "$(run_sql_query "get_fsfo_status.sql")")
FSFO_STATUS=$(field_at "$FSFO_RAW" 1)
FSFO_OBSERVER=$(field_at "$FSFO_RAW" 2)
FSFO_OBSERVER_HOST=$(field_at "$FSFO_RAW" 3)

# Single source of truth for "is FSFO on?" - used to gate threshold discovery,
# the threshold row in the report, and the visualizer payload.
FSFO_STATUS_UPPER=$(printf '%s' "$FSFO_STATUS" | tr '[:lower:]' '[:upper:]')
FSFO_ENABLED="NO"
case "$FSFO_STATUS_UPPER" in
    ''|DISABLED|N/A) ;;
    *) FSFO_ENABLED="YES" ;;
esac

# Broker show (text capture, optional)
BROKER_OUTPUT=""
if [[ "$DG_BROKER_START" == "TRUE" ]]; then
    BROKER_OUTPUT=$(run_dgmgrl "show_configuration.dgmgrl" 2>&1 || true)
fi

STANDBY_LOGXPTMODE="unknown"
STANDBY_OPEN_MODE="unknown"
FSFO_THRESHOLD="unknown"
if [[ "$DG_BROKER_START" == "TRUE" && -n "$STANDBY_DB_UNIQUE_NAME" ]]; then
    STANDBY_LOGXPTMODE=$(run_dgmgrl "show_database_property.dgmgrl" "$STANDBY_DB_UNIQUE_NAME" "LogXptMode" 2>&1 | parse_broker_property || true)
    STANDBY_LOGXPTMODE=$(clean_field "${STANDBY_LOGXPTMODE:-unknown}")

    # 19c prints "Real Time Query: ON|OFF" for a standby, never an
    # "Open Mode" line.
    STANDBY_BROKER_OUTPUT=$(run_dgmgrl "show_database.dgmgrl" "$STANDBY_DB_UNIQUE_NAME" 2>&1 || true)
    STANDBY_OPEN_MODE=$(printf '%s\n' "$STANDBY_BROKER_OUTPUT" | extract_standby_open_mode_from_broker)
    STANDBY_OPEN_MODE="${STANDBY_OPEN_MODE:-unknown}"

    # The failover threshold is only meaningful while FSFO is enabled.
    if [[ "$FSFO_ENABLED" == "YES" ]]; then
        FSFO_THRESHOLD=$(run_dgmgrl "show_database_property.dgmgrl" "$PRIMARY_DB_UNIQUE_NAME" "FastStartFailoverThreshold" 2>&1 | parse_broker_property || true)
        if [[ -z "$FSFO_THRESHOLD" || "$FSFO_THRESHOLD" == "unknown" ]]; then
            FSFO_THRESHOLD=$(run_dgmgrl "show_fsfo_threshold.dgmgrl" 2>&1 | extract_fsfo_threshold || true)
        fi
        FSFO_THRESHOLD=$(clean_field "${FSFO_THRESHOLD:-unknown}")
    fi
fi

# Direct standby query (best effort): the broker's Real Time Query flag
# cannot tell MOUNTED apart from "open read-only, apply off". When an
# auto-login wallet for the standby TNS alias exists (common/setup_dg_wallet.sh),
# ask the standby itself. Any failure leaves the broker-derived value in place.
if [[ -n "$STANDBY_TNS_ALIAS" ]]; then
    STANDBY_OPEN_MODE_DIRECT=$(sqlplus -s -L /@"${STANDBY_TNS_ALIAS}" as sysdba <<'EOSQL' 2>/dev/null || true
SET HEADING OFF FEEDBACK OFF VERIFY OFF PAGESIZE 0 LINESIZE 200 TRIMSPOOL ON
WHENEVER SQLERROR EXIT 1
SELECT 'OPENMODE=' || OPEN_MODE FROM V$DATABASE;
EXIT;
EOSQL
)
    STANDBY_OPEN_MODE_DIRECT=$( { printf '%s\n' "$STANDBY_OPEN_MODE_DIRECT" | grep 'OPENMODE=' || true; } \
        | sed 's/.*OPENMODE=//' | head -1)
    STANDBY_OPEN_MODE_DIRECT=$(clean_field "$STANDBY_OPEN_MODE_DIRECT")
    if [[ -n "$STANDBY_OPEN_MODE_DIRECT" ]]; then
        log_info "Standby OPEN_MODE read directly from ${STANDBY_TNS_ALIAS}: ${STANDBY_OPEN_MODE_DIRECT}"
        STANDBY_OPEN_MODE="$STANDBY_OPEN_MODE_DIRECT"
    fi
fi

TRIGGER_STATUS=$(clean_field "$(run_sql_query "get_role_trigger_status.sql" || true)")
TRIGGER_PACKAGE_COUNT=$(field_at "$TRIGGER_STATUS" 1)
TRIGGER_ENABLED_COUNT=$(field_at "$TRIGGER_STATUS" 2)
TRIGGER_TOTAL_COUNT=$(field_at "$TRIGGER_STATUS" 3)
TRIGGER_OWNERS=$(field_at "$TRIGGER_STATUS" 4)
ROLE_TRIGGER_READY="NO"
case "$TRIGGER_PACKAGE_COUNT" in ''|*[!0-9]*) TRIGGER_PACKAGE_COUNT=0 ;; esac
case "$TRIGGER_ENABLED_COUNT" in ''|*[!0-9]*) TRIGGER_ENABLED_COUNT=0 ;; esac
case "$TRIGGER_TOTAL_COUNT" in ''|*[!0-9]*) TRIGGER_TOTAL_COUNT=0 ;; esac
if [[ "$TRIGGER_PACKAGE_COUNT" -gt 0 && "$TRIGGER_ENABLED_COUNT" -ge 2 ]]; then
    ROLE_TRIGGER_READY="YES"
fi

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

DISCOVERY_NOTES=()
[[ "$STANDBY_LOGXPTMODE" == "unknown" ]] && DISCOVERY_NOTES+=("Standby LogXptMode could not be discovered from broker; RPO text is conservative.")
[[ "$STANDBY_OPEN_MODE" == "unknown" ]] && DISCOVERY_NOTES+=("Standby OPEN_MODE could not be discovered from broker; verify standby readability before using standby-only strings.")
[[ "$FSFO_ENABLED" == "YES" && "$FSFO_THRESHOLD" == "unknown" ]] && DISCOVERY_NOTES+=("FastStartFailoverThreshold could not be discovered from broker; outage text uses the configured-threshold wording.")
if [[ -z "$TRIGGER_STATUS" ]]; then
    DISCOVERY_NOTES+=("Role-trigger status query returned no data; role-aware descriptor readiness is treated as not confirmed.")
fi

# Listener port (prefer primary, fall back to standby)
PORT="${PRIMARY_LISTENER_PORT:-${STANDBY_LISTENER_PORT:-1521}}"

# ---- Discover user-visible services ----
progress_step "Discovering User Services"

# Keep stderr visible: $(...) captures only stdout (the service names), so a
# missing-script (SP2-0310) or ORA- error surfaces instead of an empty result.
SERVICE_OUTPUT=$(run_sql_query "get_user_services.sql" || true)
SERVICE_LIST=()
# Parallel array: YES when the role trigger actually manages this service
# (i.e. it came out of the same discovery query the trigger scripts use).
SERVICE_ROLE_AWARE=()
while IFS= read -r line; do
    line=$(clean_field "$line")
    if [[ -n "$line" ]]; then
        SERVICE_LIST+=("$line")
        SERVICE_ROLE_AWARE+=("YES")
    fi
done <<< "$SERVICE_OUTPUT"

# Always include the default db_unique_name service so users have at
# least one entry, even before any user services are created. This service
# is EXCLUDED by get_user_services.sql (and therefore by the role trigger),
# so its descriptors are admin/default only - they do not follow the primary
# after a switchover.
DEFAULT_SVC="$PRIMARY_DB_UNIQUE_NAME"
[[ -n "$DB_DOMAIN" ]] && DEFAULT_SVC="${PRIMARY_DB_UNIQUE_NAME}.${DB_DOMAIN}"

DEFAULT_PRESENT="NO"
for s in "${SERVICE_LIST[@]}"; do
    if [[ "$s" == "$DEFAULT_SVC" ]]; then
        DEFAULT_PRESENT="YES"
        break
    fi
done
if [[ "$DEFAULT_PRESENT" == "NO" ]]; then
    SERVICE_LIST=("$DEFAULT_SVC" "${SERVICE_LIST[@]}")
    SERVICE_ROLE_AWARE=("NO" "${SERVICE_ROLE_AWARE[@]}")
fi

# Look up the role-aware flag for a service name (prints YES/NO)
service_is_role_aware() {
    local want="$1" i=0
    while [[ $i -lt ${#SERVICE_LIST[@]} ]]; do
        if [[ "${SERVICE_LIST[$i]}" == "$want" ]]; then
            printf '%s\n' "${SERVICE_ROLE_AWARE[$i]}"
            return 0
        fi
        i=$((i + 1))
    done
    printf 'NO\n'
}

log_info "Services in report: ${SERVICE_LIST[*]}"

# ---- Write report ----
progress_step "Writing Handoff Report"

REPORT_FILE="${NFS_SHARE}/dg_handoff_${PRIMARY_DB_UNIQUE_NAME}.md"
IMPACT_SOURCE="$(dirname "$SCRIPT_DIR")/docs/DG_APPLICATION_IMPACT.html"
IMPACT_TARGET="${NFS_SHARE}/dg_application_impact.html"
IMPACT_COPIED="NO"
if [[ -f "$IMPACT_SOURCE" ]]; then
    if cp "$IMPACT_SOURCE" "$IMPACT_TARGET"; then
        IMPACT_COPIED="YES"
        log_info "Application impact briefing copied: $IMPACT_TARGET"
    else
        log_warn "Could not copy application impact briefing to ${IMPACT_TARGET}"
    fi
else
    log_warn "Application impact briefing not found: ${IMPACT_SOURCE}"
fi
GEN_DATE=$(date)
GEN_HOST=$(hostname 2>/dev/null)

# Best-effort: no base64/openssl on the host just drops the link
VIZ_URL=$(build_visualizer_url) || VIZ_URL=""

# Easy Connect Plus string used by the end-to-end verification example
VERIFY_EZ=$(render_easy_connect_ha "$PRIMARY_HOSTNAME" "$STANDBY_HOSTNAME" "$PORT" "${SERVICE_LIST[0]}")

# Status verdict (escalate-only: HEALTHY -> WARNING -> ERROR, never lowered)
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
# the only signal - dgmgrl_output_has_error() comes from dg_functions.sh.
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
    if dgmgrl_output_has_error "$BROKER_OUTPUT"; then
        escalate_verdict "ERROR"
        VERDICT_NOTES+=("Broker reported ORA-/DGM- errors (see Broker Configuration section)")
    fi
fi

# Role-aware descriptors are only safe once the trigger is deployed.
if [[ "$ROLE_TRIGGER_READY" != "YES" ]]; then
    escalate_verdict "WARNING"
    VERDICT_NOTES+=("Role-aware service trigger is not deployed/enabled")
fi

if [[ "$STANDBY_OPEN_MODE" == "unknown" ]]; then
    escalate_verdict "WARNING"
    VERDICT_NOTES+=("Standby readability could not be determined")
fi

if [[ ${#VERDICT_NOTES[@]} -eq 0 ]]; then
    VERDICT_NOTES+=("No role, transport, apply, broker or trigger issues detected")
fi

{
    echo "# Data Guard Handoff Report"
    echo ""
    echo "- **Generated:** ${GEN_DATE}"
    echo "- **Generated on:** ${GEN_HOST}"
    echo "- **Configuration:** ${PRIMARY_DB_UNIQUE_NAME} → ${STANDBY_DB_UNIQUE_NAME}"
    if [[ -n "$VIZ_URL" ]]; then
        echo "- **Interactive diagram:** [open this configuration in the Data Guard visualizer](${VIZ_URL})"
        echo "  (the link encodes only the topology shown in this report - no credentials)"
    fi
    echo ""
    echo "## 1. Connection Strings"
    echo ""
    echo "Three flavors per service:"
    echo ""
    echo "- **Primary-only** — fixed to the primary host. Writes/admin tooling. No failover: dies with the primary."
    echo "- **Standby-only** — fixed to the standby host. Read-only reporting against an open standby."
    echo "- **Role-aware (failover)** — both hosts in one ADDRESS_LIST. The service runs only on the current primary (stopped on the standby by the role trigger), so clients follow the primary across switchover/failover with no config change. Use this for the application tier."
    echo ""
    if [[ "$ROLE_TRIGGER_READY" == "YES" ]]; then
        echo "**Role-aware trigger status:** deployed and enabled. Role-aware descriptors are safe to hand to applications **for the services the trigger manages** - each service section below states whether it is one of them."
    else
        echo "**WARNING:** The \`DG_SERVICE_MGR\` package and both role-aware triggers are not confirmed enabled. Role-aware descriptors may connect applications to a read-only standby until \`trigger/create_role_trigger.sh\` is deployed."
    fi
    echo ""
    echo "### Descriptor Parameters (role-aware descriptor)"
    echo ""
    echo "| Parameter | Value | Effect |"
    echo "|-----------|-------|--------|"
    echo "| LOAD_BALANCE | OFF | Addresses tried in listed order: primary host first, then standby |"
    echo "| TRANSPORT_CONNECT_TIMEOUT | 3 s | TCP connect budget per address |"
    echo "| CONNECT_TIMEOUT | 10 s | Total budget per address (TCP + listener handshake + session creation) |"
    echo "| RETRY_COUNT / RETRY_DELAY | 3 / 3 s | After the whole ADDRESS_LIST fails, it is retried 3 more times, 3 s apart |"
    echo "| FAILOVER_MODE | SELECT / BASIC / RETRIES=30 / DELAY=5 | TAF: on session loss, reconnect every 5 s for up to 30 attempts (max 150 s). Open SELECT cursors resume; in-flight transactions roll back (ORA-25402) |"
    echo ""
    echo "Worst-case connect times these values produce:"
    echo ""
    echo "- Both hosts unreachable (TCP timeout): 2 addresses x 3 s per pass, 4 passes, 3 x 3 s delays = **about 33 s** until the driver returns an error."
    echo "- Primary host down, standby listener up (service stopped there): about 3 s TCP timeout + immediate ORA-12514 per pass = **about 21 s** until error."
    echo "- Failover in progress: attempts cycle (each bounded as above) until the service registers on the new primary, then the next attempt succeeds."
    echo ""

    for svc in "${SERVICE_LIST[@]}"; do
        SVC_ROLE_AWARE=$(service_is_role_aware "$svc")
        # Build per-service alias names. Strip dots for alias use.
        local_safe=$(echo "$svc" | tr '.' '_' | tr '[:lower:]' '[:upper:]')
        ALIAS_PRI="${local_safe}_PRIMARY"
        ALIAS_STB="${local_safe}_STANDBY"
        ALIAS_HA="${local_safe}_HA"

        echo "### Service: \`${svc}\`"
        echo ""
        if [[ "$SVC_ROLE_AWARE" != "YES" ]]; then
            echo "> **Admin/default service — NOT managed by the role trigger.** \`${svc}\` is the database's own default service; \`trigger/create_role_trigger.sh\` deliberately excludes it, so it stays running on BOTH sides and does **not** follow the primary after a switchover or failover. Use the primary-only descriptor for admin/DBA access, and create a dedicated application service (see \`trigger/create_cdb_service.sh\` / \`trigger/create_pdb_service.sh\`) for anything handed to applications."
            echo ""
        fi
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
        echo "#### Standby-only"
        echo ""
        STANDBY_OPEN_UPPER=$(printf '%s' "$STANDBY_OPEN_MODE" | tr '[:lower:]' '[:upper:]')
        if [[ "$STANDBY_OPEN_UPPER" == *MOUNTED* ]]; then
            echo "**Not currently usable:** the standby is MOUNTED (not open read-only) - these connections will fail until it is opened READ ONLY WITH APPLY."
            echo ""
            echo '```'
            render_tns_single "$ALIAS_STB" "$STANDBY_HOSTNAME" "$PORT" "$svc"
            echo '```'
            echo ""
            echo '```'
            echo "JDBC: $(render_jdbc_single "$STANDBY_HOSTNAME" "$PORT" "$svc")"
            echo '```'
            echo ""
        else
            echo '```'
            render_tns_single "$ALIAS_STB" "$STANDBY_HOSTNAME" "$PORT" "$svc"
            echo '```'
            echo ""
            echo '```'
            echo "JDBC: $(render_jdbc_single "$STANDBY_HOSTNAME" "$PORT" "$svc")"
            echo '```'
            echo ""
            if [[ "$STANDBY_OPEN_UPPER" == *READ*ONLY*APPLY* ]]; then
                echo "The standby is READ ONLY WITH APPLY (Active Data Guard - separately licensed). Technical limits:"
                echo ""
                echo "- Reads see committed data as of the apply point: staleness = current apply lag. Read-your-writes across the two databases is not guaranteed."
                echo "- Bound staleness per session with \`ALTER SESSION SET STANDBY_MAX_DATA_DELAY = <seconds>\` - queries then raise ORA-03172 instead of returning stale data. \`ALTER SESSION SYNC WITH PRIMARY\` blocks until caught up (requires SYNC transport and real-time apply)."
                echo "- DML and DDL fail with ORA-16000 (exception: DML on global temporary tables, which uses temporary undo on the standby)."
                echo ""
            elif [[ "$STANDBY_OPEN_MODE" == "unknown" ]]; then
                echo "Standby readability could not be discovered; verify OPEN_MODE before giving standby-only strings to applications."
                echo ""
            fi
        fi
        echo "#### Role-aware (failover)"
        echo ""
        if [[ "$SVC_ROLE_AWARE" == "YES" && "$ROLE_TRIGGER_READY" == "YES" ]]; then
            echo "Managed by the role trigger - safe to hand to applications."
        elif [[ "$SVC_ROLE_AWARE" != "YES" ]]; then
            echo "**Not role-aware:** \`${svc}\` is not in the role trigger's service list, so this descriptor can land on the standby and return ORA-16000 on writes. Do not hand it to applications."
        else
            echo "**Not yet role-aware:** deploy \`trigger/create_role_trigger.sh\` before handing this descriptor to applications."
        fi
        echo ""
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
        render_driver_table "$svc" "$EASY_HA"
    done
    echo ""
    echo "## 2. Topology"
    echo ""
    echo "| Role    | DB_UNIQUE_NAME              | Hostname              | SID                   | Listener |"
    echo "|---------|-----------------------------|-----------------------|-----------------------|----------|"
    echo "| Primary | ${PRIMARY_DB_UNIQUE_NAME}   | ${PRIMARY_HOSTNAME}   | ${PRIMARY_ORACLE_SID} | ${PORT}  |"
    echo "| Standby | ${STANDBY_DB_UNIQUE_NAME}   | ${STANDBY_HOSTNAME}   | ${STANDBY_ORACLE_SID} | ${PORT}  |"
    echo ""
    echo "## 3. Status Snapshot"
    echo ""
    echo "| Item                  | Value |"
    echo "|-----------------------|-------|"
    echo "| Local role            | ${DB_ROLE} |"
    echo "| Open mode             | ${OPEN_MODE} |"
    echo "| Protection mode       | ${PROTECTION_MODE} |"
    echo "| Standby LogXptMode    | ${STANDBY_LOGXPTMODE:-unknown} |"
    echo "| Standby open mode     | ${STANDBY_OPEN_MODE:-unknown} |"
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
    if [[ "$FSFO_ENABLED" == "YES" ]]; then
        echo "| FSFO threshold        | ${FSFO_THRESHOLD:-unknown} |"
    fi
    echo "| Role trigger ready    | ${ROLE_TRIGGER_READY} (${TRIGGER_OWNERS:-unknown}) |"
    echo "| SQLNET.EXPIRE_TIME    | ${SQLNET_EXPIRE_TIME} |"
    echo ""
    echo "**Verdict:** ${VERDICT}"
    if [[ ${#VERDICT_NOTES[@]} -gt 0 ]]; then
        for n in "${VERDICT_NOTES[@]}"; do
            echo "- ${n}"
        done
    fi

    echo ""
    echo "### Application Impact Summary"
    echo ""
    echo "- ${RPO_STATEMENT}"
    echo "- ${OUTAGE_STATEMENT}"
    echo "- After any role change the new primary starts with a largely cold buffer cache and shared pool: elevated physical reads and hard parsing for the first minutes. Queries succeed but latency degrades (brownout, not blackout)."
    echo "- FORCE LOGGING is ${FORCE_LOGGING:-unknown}. Direct-path/NOLOGGING loads generate no redo when force logging is off: the affected blocks are unrecoverable on the standby and raise ORA-26040 when read after a failover. Any NOLOGGING batch job needs DBA sign-off."
    echo "- Every application host must resolve and reach BOTH database hosts on port ${PORT} before go-live - the standby address is only exercised when it is already an emergency."
    if [[ ${#DISCOVERY_NOTES[@]} -gt 0 ]]; then
        echo ""
        echo "Discovery notes:"
        for n in "${DISCOVERY_NOTES[@]}"; do
            echo "- ${n}"
        done
    fi
    echo ""

    echo "### Errors During Role Transitions"
    echo ""
    echo "| Error | When it appears | Client action |"
    echo "|-------|-----------------|---------------|"
    echo "| ORA-12514 | Listener up, service not registered - normal on the standby address, and on both hosts mid-failover | Retryable: driver moves to the next address / retry pass |"
    echo "| ORA-12541, ORA-12170, ORA-12535 | No listener / TCP connect timeout - host or listener down | Retryable: next address |"
    echo "| ORA-01033 | Instance starting or mounting (mid-role-change) | Retryable with backoff |"
    echo "| ORA-03113, ORA-03114, ORA-01089 | Existing session killed by failover/shutdown | Reconnect; the role-aware descriptor re-routes to the surviving side |"
    echo "| ORA-25402 | TAF failed the session over mid-transaction | ROLLBACK, then re-run the transaction |"
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
    echo "- Repair sequence (\`STANDBY_FILE_MANAGEMENT=MANUAL\`, \`ALTER DATABASE CREATE DATAFILE ... AS ...\`, back to \`AUTO\`, restart apply): see \"Life After Setup: Adding Datafiles and PDBs\" in \`docs/DATA_GUARD_WALKTHROUGH.md\`."
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
    if [[ "$IMPACT_COPIED" == "YES" ]]; then
        echo "- Full application behavior briefing: \`dg_application_impact.html\` next to this report."
    else
        echo "- Full application behavior briefing was not copied; see \`docs/DG_APPLICATION_IMPACT.html\` in the repository."
    fi
    echo "- The role-aware descriptor works only because \`trigger/create_role_trigger.sh\` stops the service on the standby. With the trigger disabled, both hosts accept connections and writers landing on the standby get ORA-16000."
    echo "- Sequences: NOORDER/CACHE sequences (default CACHE 20) discard cached values at role change - expect gaps of up to the CACHE size per sequence, and no ordering guarantee across a failover. Never use sequence values as gapless or strictly-ordered business keys."
    echo "- TAF replays SELECTs only. In-flight transactions roll back (ORA-25402); commits and non-idempotent calls need application retry with the commit-ambiguity handling in section 3."
    echo "- Application Continuity (12.2+ drivers) can replay in-flight transactions, but requires \`FAILOVER_TYPE=TRANSACTION\` and \`COMMIT_OUTCOME=TRUE\` on the service - not configured by this setup; coordinate with the DBA team."
    echo "- After a switchover nothing changes for clients on the role-aware descriptor. Primary-only and standby-only strings silently point at the wrong database until this report is regenerated."
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
    echo "tnsping ${PRIMARY_TNS_ALIAS}"
    echo "tnsping ${STANDBY_TNS_ALIAS}"
    echo "tnsping ${PRIMARY_HOSTNAME}:${PORT}/${SERVICE_LIST[0]}"
    echo "tnsping ${STANDBY_HOSTNAME}:${PORT}/${SERVICE_LIST[0]}"
    echo "nc -z ${PRIMARY_HOSTNAME} ${PORT}"
    echo "nc -z ${STANDBY_HOSTNAME} ${PORT}"
    echo '```'
    echo ""
    echo "\`tnsping\` and \`nc\` prove listener reachability only. End-to-end check through the role-aware descriptor - this is also the pass criterion for a switchover drill (re-run it after the switchover; DB_UNIQUE_NAME and SERVER_HOST must swap while DATABASE_ROLE stays PRIMARY):"
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
} > "$REPORT_FILE"

log_success "Report written: $REPORT_FILE"

# ---- Display ----
progress_step "Displaying Report"

echo ""
cat "$REPORT_FILE"
echo ""

print_status_block "Handoff Report" \
    "Configuration"   "${PRIMARY_DB_UNIQUE_NAME} -> ${STANDBY_DB_UNIQUE_NAME}" \
    "Verdict"         "$VERDICT" \
    "Apply lag (seq)" "$APPLY_LAG_SEQ" \
    "Archive gaps"    "$GAP_COUNT" \
    "Services"        "${#SERVICE_LIST[@]}" \
    "Report file"     "$REPORT_FILE"

print_list_block "Distribution" \
    "Share ${REPORT_FILE} with the application teams that connect to this database." \
    "The role-aware descriptors require the role-aware service trigger (trigger/create_role_trigger.sh) to be deployed." \
    "Re-run this script after schema changes, listener changes, or new services to refresh the report." \
    "Once this handoff report has been verified, run common/cleanup_nfs_artifacts.sh to remove sensitive setup artifacts (password file copies, generated pfiles, RMAN files) from the NFS share."

if [[ "$VERDICT" != "HEALTHY" ]]; then
    for n in "${VERDICT_NOTES[@]}"; do
        log_warn "${VERDICT}: ${n}"
    done
fi

if [[ "$VERDICT" == "ERROR" ]]; then
    print_summary "ERROR" "Handoff report generated, but Data Guard issues were detected"
    exit 1
elif [[ "$VERDICT" == "WARNING" ]]; then
    print_summary "WARNING" "Handoff report generated with warnings"
    exit 0
else
    print_summary "SUCCESS" "Handoff report generated successfully"
    exit 0
fi
