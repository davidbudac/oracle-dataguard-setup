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
#     service trigger from step 14 is deployed)
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
    echo "$1" | tr -d ' \n\r'
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

# JDBC thin URL: simple form
render_jdbc_single() {
    local host="$1" port="$2" service="$3"
    echo "jdbc:oracle:thin:@//${host}:${port}/${service}"
}

# JDBC thin URL with full descriptor (multi-host, role-aware)
render_jdbc_ha() {
    local phost="$1" shost="$2" port="$3" service="$4"
    printf 'jdbc:oracle:thin:@(DESCRIPTION=(CONNECT_TIMEOUT=10)(RETRY_COUNT=3)(RETRY_DELAY=3)(ADDRESS_LIST=(LOAD_BALANCE=OFF)(ADDRESS=(PROTOCOL=TCP)(HOST=%s)(PORT=%s))(ADDRESS=(PROTOCOL=TCP)(HOST=%s)(PORT=%s)))(CONNECT_DATA=(SERVICE_NAME=%s)(FAILOVER_MODE=(TYPE=SELECT)(METHOD=BASIC)(RETRIES=30)(DELAY=5))))\n' \
        "$phost" "$port" "$shost" "$port" "$service"
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

APPLY_INFO=$(clean_field "$(run_sql_query "get_apply_info_pipe.sql")")
LAST_APPLIED=$(field_at "$APPLY_INFO" 1)
LAST_RECEIVED=$(field_at "$APPLY_INFO" 2)
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

# Listener port (prefer primary, fall back to standby)
PORT="${PRIMARY_LISTENER_PORT:-${STANDBY_LISTENER_PORT:-1521}}"

# ---- Discover user-visible services ----
progress_step "Discovering User Services"

SERVICE_OUTPUT=$(run_sql_query "get_user_services.sql" 2>/dev/null || true)
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
GEN_DATE=$(date)
GEN_HOST=$(hostname 2>/dev/null)

# Status verdict
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
        for n in "${VERDICT_NOTES[@]}"; do
            echo "- ${n}"
        done
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
    echo "  for the application tier *when the role-aware service trigger from"
    echo "  step 14 is deployed*: the service is only up on whichever side is"
    echo "  primary, so clients automatically follow the active database after a"
    echo "  switchover or failover."
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
    done

    echo "## 4. Notes for Client Teams"
    echo ""
    echo "- The role-aware descriptor relies on the service being **stopped on"
    echo "  the standby**. This is what the role-aware trigger from step 14"
    echo "  enforces. Without it, clients may attach to a read-only standby"
    echo "  and receive ORA-16000 on writes."
    echo "- TAF settings (\`FAILOVER_MODE\`) reconnect *select* cursors after a"
    echo "  failover. Active transactions still need application-level retry."
    echo "- For Oracle 12c+ clients consider Application Continuity / Transparent"
    echo "  Application Continuity if your driver and license allow it."
    echo "- After a switchover, the primary/standby hostnames in this report are"
    echo "  swapped at the database layer but the role-aware descriptor keeps"
    echo "  working unchanged."
    echo ""
    echo "## 5. Quick Verification"
    echo ""
    echo '```bash'
    echo "tnsping ${PRIMARY_TNS_ALIAS}"
    echo "tnsping ${STANDBY_TNS_ALIAS}"
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
    "The role-aware descriptors require the step-14 service trigger to be deployed." \
    "Re-run this script after schema changes, listener changes, or new services to refresh the report."

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
