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

clean_field() {
    echo "$1" | tr -d ' \t\n\r'
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

    STANDBY_BROKER_OUTPUT=$(run_dgmgrl "show_database.dgmgrl" "$STANDBY_DB_UNIQUE_NAME" 2>&1 || true)
    STANDBY_OPEN_MODE=$(printf '%s\n' "$STANDBY_BROKER_OUTPUT" | extract_open_mode_from_broker)
    STANDBY_OPEN_MODE="${STANDBY_OPEN_MODE:-unknown}"

    FSFO_THRESHOLD=$(run_dgmgrl "show_database_property.dgmgrl" "$PRIMARY_DB_UNIQUE_NAME" "FastStartFailoverThreshold" 2>&1 | parse_broker_property || true)
    if [[ -z "$FSFO_THRESHOLD" || "$FSFO_THRESHOLD" == "unknown" ]]; then
        FSFO_THRESHOLD=$(run_dgmgrl "show_fsfo_threshold.dgmgrl" 2>&1 | extract_fsfo_threshold || true)
    fi
    FSFO_THRESHOLD=$(clean_field "${FSFO_THRESHOLD:-unknown}")
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

DISCOVERY_NOTES=()
[[ "$STANDBY_LOGXPTMODE" == "unknown" ]] && DISCOVERY_NOTES+=("Standby LogXptMode could not be discovered from broker; RPO text is conservative.")
[[ "$STANDBY_OPEN_MODE" == "unknown" ]] && DISCOVERY_NOTES+=("Standby OPEN_MODE could not be discovered from broker; verify standby readability before using standby-only strings.")
[[ "$FSFO_THRESHOLD" == "unknown" ]] && DISCOVERY_NOTES+=("FastStartFailoverThreshold could not be discovered from broker; outage text uses the configured-threshold wording.")
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
while IFS= read -r line; do
    line=$(clean_field "$line")
    [[ -n "$line" ]] && SERVICE_LIST+=("$line")
done <<< "$SERVICE_OUTPUT"

# Always include the default db_unique_name service so users have at
# least one entry, even before any user services are created.
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
fi

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

# Status verdict (escalate-only: HEALTHY -> WARNING -> ERROR, never lowered)
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

{
    echo "# Data Guard Handoff Report"
    echo ""
    echo "- **Generated:** ${GEN_DATE}"
    echo "- **Generated on:** ${GEN_HOST}"
    echo "- **Configuration:** ${PRIMARY_DB_UNIQUE_NAME} → ${STANDBY_DB_UNIQUE_NAME}"
    echo ""
    echo "## 1. Topology"
    echo ""
    echo "| Role    | DB_UNIQUE_NAME              | Hostname              | SID                   | Listener |"
    echo "|---------|-----------------------------|-----------------------|-----------------------|----------|"
    echo "| Primary | ${PRIMARY_DB_UNIQUE_NAME}   | ${PRIMARY_HOSTNAME}   | ${PRIMARY_ORACLE_SID} | ${PORT}  |"
    echo "| Standby | ${STANDBY_DB_UNIQUE_NAME}   | ${STANDBY_HOSTNAME}   | ${STANDBY_ORACLE_SID} | ${PORT}  |"
    echo ""
    echo "## 2. Status Snapshot"
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
    echo "| FSFO threshold        | ${FSFO_THRESHOLD:-unknown} |"
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
    echo "- FORCE LOGGING is ${FORCE_LOGGING:-unknown}; NOLOGGING batch jobs can still create unrecoverable standby gaps if force logging is disabled for maintenance."
    echo "- Sequence values can have gaps after switchover/failover because cached values on the old primary are discarded."
    echo "- Application firewalls must allow the app tier to reach both database hosts on listener port ${PORT} before go-live."
    if [[ ${#DISCOVERY_NOTES[@]} -gt 0 ]]; then
        echo ""
        echo "Discovery notes:"
        for n in "${DISCOVERY_NOTES[@]}"; do
            echo "- ${n}"
        done
    fi
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
    echo "## 3. Connection Strings"
    echo ""
    echo "Three flavors are provided per service:"
    echo ""
    echo "- **Primary-only** — points directly at the primary host. Use for"
    echo "  workloads that must always hit the primary (writes, admin)."
    echo "- **Standby-only** — points directly at the standby host. Use for"
    echo "  read-only reporting workloads against an open standby."
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
        # Build per-service alias names. Strip dots for alias use.
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
        echo "#### Standby-only"
        echo ""
        STANDBY_OPEN_UPPER=$(printf '%s' "$STANDBY_OPEN_MODE" | tr '[:lower:]' '[:upper:]')
        if [[ "$STANDBY_OPEN_UPPER" == *MOUNTED* ]]; then
            echo "**Not currently usable:** standby is MOUNTED - these connections will fail until it is opened READ ONLY."
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
                echo "Active Data Guard note: READ ONLY WITH APPLY requires the appropriate license. Reads can lag primary commits, read-your-writes is not guaranteed, and DML fails with ORA-16000."
                echo ""
            elif [[ "$STANDBY_OPEN_MODE" == "unknown" ]]; then
                echo "Standby readability could not be discovered; verify OPEN_MODE before giving standby-only strings to applications."
                echo ""
            fi
        fi
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
        EASY_HA=$(render_easy_connect_ha "$PRIMARY_HOSTNAME" "$STANDBY_HOSTNAME" "$PORT" "$svc")
        echo "Easy Connect Plus (19c+ clients):"
        echo ""
        echo '```'
        echo "$EASY_HA"
        echo '```'
        echo ""
        render_driver_table "$svc" "$EASY_HA"
    done

    echo "## 4. Notes for Client Teams"
    echo ""
    if [[ "$IMPACT_COPIED" == "YES" ]]; then
        echo "- Full application behavior briefing: \`dg_application_impact.html\` next to this report."
    else
        echo "- Full application behavior briefing was not copied; see \`docs/DG_APPLICATION_IMPACT.html\` in the repository."
    fi
    echo "- What changes for your application: SYNC/FASTSYNC can add commit latency; NOLOGGING batch jobs need DBA review; sequence caches can create gaps after role change; expect a cold-cache brownout; firewalls must reach both hosts."
    echo "- The role-aware descriptor relies on the service being **stopped on"
    echo "  the standby** by \`trigger/create_role_trigger.sh\`. Without it,"
    echo "  clients may attach to a read-only standby and receive ORA-16000 on writes."
    echo "- TAF settings (\`FAILOVER_MODE\`) reconnect *select* cursors after a"
    echo "  failover. Active DML transactions still need application-level retry."
    echo "- For Oracle 12c+ clients consider Application Continuity / Transparent"
    echo "  Application Continuity if your driver and license allow it."
    echo "- After a switchover, the primary/standby hostnames in this report are"
    echo "  swapped at the database layer but the role-aware descriptor keeps"
    echo "  working unchanged."
    echo ""
    echo "## 5. Recommended Client and Pool Settings"
    echo ""
    echo "- [ ] Use the provided descriptor timeouts: \`CONNECT_TIMEOUT=10\`, \`TRANSPORT_CONNECT_TIMEOUT=3\` where present, and retry counts to bound connect hangs."
    echo "- [ ] Set driver connection timeout to 5-10 seconds and read/call timeout to the smallest value your request SLO allows."
    echo "- [ ] Dead connection detection: server-side \`SQLNET.EXPIRE_TIME\` is ${SQLNET_EXPIRE_TIME}; also enable TCP keepalive on client hosts."
    echo "- [ ] Enable pool validation on borrow or an equivalent lightweight connection check before handing out idle connections."
    echo "- [ ] TAF is SELECT-only replay; in-flight DML, commits, and non-idempotent calls require application retry/reconciliation."
    echo ""
    echo "## 6. Quick Verification"
    echo ""
    echo '```bash'
    echo "tnsping ${PRIMARY_TNS_ALIAS}"
    echo "tnsping ${STANDBY_TNS_ALIAS}"
    echo "tnsping ${PRIMARY_HOSTNAME}:${PORT}/${SERVICE_LIST[0]}"
    echo "tnsping ${STANDBY_HOSTNAME}:${PORT}/${SERVICE_LIST[0]}"
    echo "nc -z ${PRIMARY_HOSTNAME} ${PORT}"
    echo "nc -z ${STANDBY_HOSTNAME} ${PORT}"
    echo "sqlplus app_user/<pwd>@${SERVICE_LIST[0]}"
    echo '```'
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
