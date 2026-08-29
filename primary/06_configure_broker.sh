#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 6: Configure Data Guard Broker
# ============================================================
# Run this script on the PRIMARY database server.
# It creates and enables the Data Guard Broker configuration
# using DGMGRL.
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source common functions
source "${COMMON_DIR}/dg_functions.sh"
enable_verbose_mode "$@"

# ============================================================
# Main Script
# ============================================================

print_banner "Step 6: Configure Data Guard Broker"
init_progress 10

# Initialize logging (will reinitialize with DB name later)
init_log "06_configure_broker"

# ============================================================
# Pre-flight Checks
# ============================================================

progress_step "Pre-flight Checks"

check_oracle_env || exit 1
check_nfs_mount || exit 1
check_db_connection || exit 1

# Check for standby config files - support unique naming
if ! select_config_file STANDBY_CONFIG_FILE "standby configuration" "${NFS_SHARE}/standby_config_*.env"; then
    log_error "Please run 02_generate_standby_config.sh first"
    exit 1
fi

log_info "Loading standby configuration..."
source "$STANDBY_CONFIG_FILE"

# Reinitialize log with standby DB name
init_log "06_configure_broker_${STANDBY_DB_UNIQUE_NAME}"

# ============================================================
# Review Planned Changes
# ============================================================

progress_step "Reviewing Planned Changes"

print_list_block "This Step Will Change" \
    "Create or recreate the Data Guard Broker configuration ${DG_BROKER_CONFIG_NAME:-${PRIMARY_DB_NAME}_DG}." \
    "Add ${STANDBY_DB_UNIQUE_NAME} as a physical standby in Broker." \
    "Enable the Broker configuration and force a logfile switch test." \
    "Set the primary RMAN archivelog deletion policy to SHIPPED TO ALL STANDBY (only once the configuration is healthy)."

print_list_block "This Step Will Not Change" \
    "It will not run RMAN DUPLICATE." \
    "It will not change filesystem config files on either host." \
    "It will not enable FSFO."

print_list_block "Files and Connections" \
    "Standby config: ${STANDBY_CONFIG_FILE}" \
    "Primary alias: ${PRIMARY_TNS_ALIAS}" \
    "Standby alias: ${STANDBY_TNS_ALIAS}" \
    "Broker command source: ${SQL_DIR}/dgmgrl"

print_list_block "Recovery If This Step Fails" \
    "Run dgmgrl / 'show configuration' to inspect the current broker state." \
    "If needed, remove the partial configuration cleanly before re-running this step." \
    "Use the generated log file to confirm which Broker command failed."

record_next_step "./standby/07_verify_dataguard.sh"

if [[ "$CHECK_ONLY" == "1" ]]; then
    finish_check_mode "Broker configuration preflight complete. No Broker changes were applied."
fi

# ============================================================
# Verify DG Broker is Running
# ============================================================

progress_step "Verifying Data Guard Broker Status"

# Check DG_BROKER_START on primary
DG_BROKER_START=$(get_db_parameter "dg_broker_start")
log_info "Primary DG_BROKER_START: $DG_BROKER_START"

if [[ "$DG_BROKER_START" != "TRUE" ]]; then
    log_error "DG_BROKER_START is not TRUE on primary"
    log_error "Please run 04_prepare_primary_dg.sh first"
    exit 1
fi

# Check DMON process is running
DMON_COUNT=$(run_sql_query "get_dmon_count.sql")
DMON_COUNT=$(echo "$DMON_COUNT" | tr -d '[:space:]')

if [[ "$DMON_COUNT" -eq 0 ]]; then
    log_error "Data Guard Broker process (DMON) is not running"
    log_error "Try: ALTER SYSTEM SET DG_BROKER_START=FALSE; then TRUE;"
    exit 1
fi

log_info "DMON process is running on primary"

# ============================================================
# Verify TNS Connectivity
# ============================================================

progress_step "Verifying Network Connectivity"

log_info "Testing tnsping to primary ($PRIMARY_TNS_ALIAS)..."
if ! "$ORACLE_HOME/bin/tnsping" "$PRIMARY_TNS_ALIAS" > /dev/null 2>&1; then
    log_error "Cannot reach primary via tnsping"
    exit 1
fi
log_info "tnsping to primary successful"

log_info "Testing tnsping to standby ($STANDBY_TNS_ALIAS)..."
if ! "$ORACLE_HOME/bin/tnsping" "$STANDBY_TNS_ALIAS" > /dev/null 2>&1; then
    log_error "Cannot reach standby via tnsping"
    log_error "Ensure standby listener is running"
    exit 1
fi
log_info "tnsping to standby successful"

# ============================================================
# Check for Existing Broker Configuration
# ============================================================

progress_step "Checking for Existing Broker Configuration"

# Try to connect and check for existing config
EXISTING_CONFIG=$(run_dgmgrl "show_configuration.dgmgrl" 2>&1 || true)

# ORA-16532: configuration does not exist.
# ORA-16596: this database is not part of the broker configuration - seen
#            when stale dr1/dr2 broker config files (e.g. from a dropped
#            and recreated database of the same name) name a different
#            member. CREATE CONFIGURATION overwrites them.
if echo "$EXISTING_CONFIG" | grep -Eq "ORA-16532|ORA-16596"; then
    log_info "No usable broker configuration found - proceeding with creation"
elif echo "$EXISTING_CONFIG" | grep -q "Configuration -"; then
    log_warn "Existing broker configuration detected!"
    echo ""
    echo "$EXISTING_CONFIG"
    echo ""
    if ! confirm_proceed "Do you want to remove the existing configuration and create a new one?"; then
        log_info "Keeping existing configuration"
        exit 0
    fi

    # REMOVE CONFIGURATION fails with ORA-16654 while fast-start
    # failover is enabled, so disable FSFO first when the existing
    # config shows it enabled. Fall back to FORCE (works even when
    # the observer or the standby is unreachable).
    if echo "$EXISTING_CONFIG" | grep -qi "Fast-Start Failover:[[:space:]]*Enabled"; then
        log_info "Fast-Start Failover is enabled - disabling it before removal..."
        log_cmd "dgmgrl /:" "DISABLE FAST_START FAILOVER"
        DISABLE_OUTPUT=$(run_dgmgrl "disable_fsfo.dgmgrl" 2>&1 || true)
        if dgmgrl_output_has_error "$DISABLE_OUTPUT"; then
            log_warn "Normal FSFO disable failed - retrying with FORCE..."
            log_cmd "dgmgrl /:" "DISABLE FAST_START FAILOVER FORCE"
            if ! run_dgmgrl_checked "disable_fsfo_force.dgmgrl"; then
                log_error "Could not disable Fast-Start Failover - cannot remove the configuration"
                exit 1
            fi
        fi
        log_info "Fast-Start Failover disabled"
    fi

    log_info "Removing existing configuration..."
    log_cmd "dgmgrl /:" "REMOVE CONFIGURATION"
    REMOVE_OUTPUT=$(run_dgmgrl "remove_configuration.dgmgrl" 2>&1)
    # DGMGRL routinely emits 'Warning: ORA-16620: one or more members
    # could not be reached for a remove operation' when the standby
    # instance is fenced off (e.g. mid-rebuild). The config is still
    # removed locally, so authoritative success is 'Removed configuration'
    # in the output rather than absence of any ORA- string.
    if ! echo "$REMOVE_OUTPUT" | grep -qi "Removed configuration"; then
        log_error "Failed to remove the existing broker configuration"
        echo ""
        echo "$REMOVE_OUTPUT"
        exit 1
    fi
    if echo "$REMOVE_OUTPUT" | grep -qi "Warning:"; then
        log_warn "REMOVE CONFIGURATION emitted a warning (proceeding):"
        echo "$REMOVE_OUTPUT" | grep -i "Warning:" | while IFS= read -r _line; do
            log_warn "  $_line"
        done
    fi

    POST_REMOVE_STATUS=$(run_dgmgrl "show_configuration.dgmgrl" 2>&1 || true)
    if ! echo "$POST_REMOVE_STATUS" | grep -q "ORA-16532"; then
        log_error "Broker configuration still exists after REMOVE CONFIGURATION"
        echo ""
        echo "$POST_REMOVE_STATUS"
        exit 1
    fi

    log_info "Existing configuration removed"
else
    log_error "Unexpected output from SHOW CONFIGURATION - cannot determine broker state"
    echo ""
    echo "$EXISTING_CONFIG"
    echo ""
    log_error "Check that the broker (DMON) is started on the primary and that TNS connectivity works, then re-run this script"
    exit 1
fi

# ============================================================
# Create Broker Configuration
# ============================================================

progress_step "Creating Data Guard Broker Configuration"

DG_BROKER_CONFIG_NAME="${DG_BROKER_CONFIG_NAME:-${PRIMARY_DB_NAME}_DG}"

log_info "Configuration name: $DG_BROKER_CONFIG_NAME"
log_info "Primary database: $PRIMARY_DB_UNIQUE_NAME"
log_info "Standby database: $STANDBY_DB_UNIQUE_NAME"

# Create configuration
log_info "Creating broker configuration..."
log_cmd "dgmgrl /:" "CREATE CONFIGURATION '${DG_BROKER_CONFIG_NAME}' AS PRIMARY DATABASE IS '${PRIMARY_DB_UNIQUE_NAME}' CONNECT IDENTIFIER IS '${PRIMARY_TNS_ALIAS}'"
if ! run_dgmgrl_checked "create_configuration.dgmgrl" "$DG_BROKER_CONFIG_NAME" "$PRIMARY_DB_UNIQUE_NAME" "$PRIMARY_TNS_ALIAS"; then
    log_error "Failed to create broker configuration"
    exit 1
fi
log_info "Configuration created successfully"

# Add standby database
log_info "Adding standby database to configuration..."
log_cmd "dgmgrl /:" "ADD DATABASE '${STANDBY_DB_UNIQUE_NAME}' AS CONNECT IDENTIFIER IS '${STANDBY_TNS_ALIAS}' MAINTAINED AS PHYSICAL"
if ! run_dgmgrl_checked "add_database.dgmgrl" "$STANDBY_DB_UNIQUE_NAME" "$STANDBY_TNS_ALIAS"; then
    log_error "Failed to add standby database"
    exit 1
fi
log_info "Standby database added successfully"

# ============================================================
# Verify _DGMGRL Static Service Registration
# ============================================================
# The StaticConnectIdentifier set below points at the _DGMGRL service
# registered in listener.ora by step 4 (primary) / step 3 (standby).
# Step 4 deliberately does not reload the listener, so if nobody ran
# 'lsnrctl reload' since then, the service is configured on disk but
# NOT actually being served yet - StaticConnectIdentifier will look
# correct but every switchover/FSFO connect attempt fails with
# ORA-12514 the first time it's needed, weeks later (M15). Only the
# PRIMARY's own listener can be checked from here; warn about the
# standby too since the same gap applies there.
# ============================================================

progress_step "Verifying _DGMGRL Static Service Registration"

_primary_dgmgrl_service="${PRIMARY_DB_UNIQUE_NAME}_DGMGRL${DB_DOMAIN:+.${DB_DOMAIN}}"
_standby_dgmgrl_service="${STANDBY_DB_UNIQUE_NAME}_DGMGRL${DB_DOMAIN:+.${DB_DOMAIN}}"

log_info "Checking primary listener for the ${_primary_dgmgrl_service} static service..."
_lsnrctl_status=$("$ORACLE_HOME/bin/lsnrctl" status 2>/dev/null || true)
if echo "$_lsnrctl_status" | grep -qi "$_primary_dgmgrl_service"; then
    log_info "Primary listener is serving ${_primary_dgmgrl_service}"
else
    log_warn "Primary listener does NOT show the ${_primary_dgmgrl_service} static service."
    log_warn "listener.ora was updated in step 4, but the listener has not been reloaded since -"
    log_warn "without it, DGMGRL switchover/failover connect attempts to this database will fail"
    log_warn "with ORA-12514. Also confirm the standby listener serves ${_standby_dgmgrl_service}."
    log_warn "Fix: lsnrctl reload   (run on both the primary and standby listeners)"
    if [[ -t 0 ]]; then
        if confirm_proceed "Continue setting up the broker configuration anyway?"; then
            log_warn "Proceeding without a confirmed _DGMGRL registration - re-run 'lsnrctl reload' if switchover/FSFO later fails with ORA-12514."
        else
            log_error "Aborted. Run 'lsnrctl reload' on the primary (and standby) listener, then re-run this step."
            exit 1
        fi
    else
        log_warn "Non-interactive run: continuing. Run 'lsnrctl reload' on both listeners if switchover later fails with ORA-12514."
    fi
fi

# ============================================================
# Set Explicit StaticConnectIdentifier
# ============================================================
# DGMGRL auto-derives StaticConnectIdentifier from the local
# listener entries, but in setups where DGMGRL guesses the wrong
# hostname, port, or domain the resulting descriptor will not
# resolve at switchover/FSFO time. Set it explicitly here so the
# broker uses the same host+port+_DGMGRL service registered in
# listener.ora (see 03_setup_standby_env.sh static SID_LIST).
# ============================================================

progress_step "Setting StaticConnectIdentifier on Both Databases"

PRIMARY_STATIC_CONNECT="(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${PRIMARY_HOSTNAME})(PORT=${PRIMARY_LISTENER_PORT}))(CONNECT_DATA=(SERVICE_NAME=${_primary_dgmgrl_service})(INSTANCE_NAME=${PRIMARY_ORACLE_SID})(SERVER=DEDICATED)))"
STANDBY_STATIC_CONNECT="(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${STANDBY_HOSTNAME})(PORT=${STANDBY_LISTENER_PORT}))(CONNECT_DATA=(SERVICE_NAME=${_standby_dgmgrl_service})(INSTANCE_NAME=${STANDBY_ORACLE_SID})(SERVER=DEDICATED)))"

log_info "Primary StaticConnectIdentifier:"
log_info "  $PRIMARY_STATIC_CONNECT"
log_info "Standby StaticConnectIdentifier:"
log_info "  $STANDBY_STATIC_CONNECT"

log_cmd "dgmgrl /:" "EDIT DATABASE '${PRIMARY_DB_UNIQUE_NAME}' SET PROPERTY StaticConnectIdentifier='...'"
if ! run_dgmgrl_checked "set_static_connect_identifier.dgmgrl" "$PRIMARY_DB_UNIQUE_NAME" "$PRIMARY_STATIC_CONNECT"; then
    log_error "Failed to set StaticConnectIdentifier on $PRIMARY_DB_UNIQUE_NAME"
    exit 1
fi

log_cmd "dgmgrl /:" "EDIT DATABASE '${STANDBY_DB_UNIQUE_NAME}' SET PROPERTY StaticConnectIdentifier='...'"
if ! run_dgmgrl_checked "set_static_connect_identifier.dgmgrl" "$STANDBY_DB_UNIQUE_NAME" "$STANDBY_STATIC_CONNECT"; then
    log_error "Failed to set StaticConnectIdentifier on $STANDBY_DB_UNIQUE_NAME"
    exit 1
fi

# ============================================================
# Enable Configuration
# ============================================================

progress_step "Enabling Data Guard Broker Configuration"

log_info "Enabling configuration..."
log_cmd "dgmgrl /:" "ENABLE CONFIGURATION"
if ! run_dgmgrl_checked "enable_configuration.dgmgrl"; then
    log_error "Failed to enable broker configuration"
    exit 1
fi

# M4: a fixed 'sleep 10' here routinely reported a healthy configuration
# as ERROR, because the broker often needs 30-60s (ORA-16610, "one or
# more members are working on their tasks") to converge after ENABLE
# CONFIGURATION. Poll SHOW CONFIGURATION instead, mirroring
# 13_set_max_availability.sh's reference poll loop: every 10s, up to
# ~120s, accepting SUCCESS or WARNING as stable and treating
# ORA-16610/"in progress" (or any other transient output) as "keep
# waiting" rather than a final verdict.
log_info "Waiting for configuration to stabilize..."
CONFIG_STATUS=""
BROKER_STATUS=""
_poll_attempt=0
_poll_max_attempts=12   # 12 * 10s = ~120s
while [[ $_poll_attempt -lt $_poll_max_attempts ]]; do
    CONFIG_STATUS=$(run_dgmgrl "show_configuration.dgmgrl" 2>&1 || true)
    if echo "$CONFIG_STATUS" | grep -q "SUCCESS"; then
        BROKER_STATUS="SUCCESS"
        break
    elif echo "$CONFIG_STATUS" | grep -q "WARNING"; then
        BROKER_STATUS="WARNING"
        break
    fi
    _poll_attempt=$((_poll_attempt + 1))
    if [[ $_poll_attempt -lt $_poll_max_attempts ]]; then
        if echo "$CONFIG_STATUS" | grep -Eqi "ORA-16610|in progress"; then
            log_info "Broker configuration still converging (attempt ${_poll_attempt}/${_poll_max_attempts}) - retrying in 10s..."
        else
            log_info "Configuration not yet SUCCESS/WARNING (attempt ${_poll_attempt}/${_poll_max_attempts}) - retrying in 10s..."
        fi
        sleep 10
    fi
done
if [[ -z "$BROKER_STATUS" ]]; then
    BROKER_STATUS="ERROR"
fi

# ============================================================
# Verify Configuration
# ============================================================

progress_step "Verifying Broker Configuration"

echo ""
echo "Data Guard Broker Configuration:"
echo "================================="
echo "$CONFIG_STATUS"

echo ""
echo "Primary Database Details:"
echo "========================="
run_dgmgrl "show_database.dgmgrl" "$PRIMARY_DB_UNIQUE_NAME"

echo ""
echo "Standby Database Details:"
echo "========================="
run_dgmgrl "show_database.dgmgrl" "$STANDBY_DB_UNIQUE_NAME"

# ============================================================
# Check Configuration Status
# ============================================================

log_section "Configuration Status Check"

case "$BROKER_STATUS" in
    SUCCESS)
        log_info "Configuration status: SUCCESS"
        ;;
    WARNING)
        log_warn "Configuration status: WARNING"
        log_warn "Check the configuration details above for warnings"
        ;;
    *)
        log_error "Configuration status: ERROR or UNKNOWN (did not reach SUCCESS/WARNING after ~120s)"
        log_error "Please check configuration details above"
        ;;
esac

# ============================================================
# Force Log Switch to Test
# ============================================================

log_section "Testing Log Shipping"

log_info "Forcing log switch to test redo transport..."
log_cmd "sqlplus / as sysdba:" "ALTER SYSTEM SWITCH LOGFILE"
# Non-fatal: this is a post-configuration transport test, not a core broker
# action. A failure here is real and downgrades the reported status, but
# must not (via set -e) abort the script before the final summary is shown.
if ! run_sql_command "switch_logfile.sql"; then
    log_error "Failed to switch log file - redo transport test could not be run"
    BROKER_STATUS="ERROR"
fi

sleep 5

log_info "Checking log shipping status..."
run_dgmgrl "show_log_status.dgmgrl" "$STANDBY_DB_UNIQUE_NAME"

# ============================================================
# Configure RMAN Archivelog Deletion Policy (Primary)
# ============================================================
# Deliberately done HERE and not in step 4: SHIPPED TO ALL STANDBY makes
# archived logs non-deletable to RMAN/FRA maintenance until a standby has
# received them. Set before transport works, it can fill the FRA and hang
# the primary (ORA-00257). By this point the broker configuration is
# SUCCESS/WARNING and a test log switch has shipped, so the policy is safe.
# Non-fatal: a failure here must not mask the broker result in the summary.

log_section "Configuring RMAN Archivelog Deletion Policy"

if [[ "$BROKER_STATUS" == "SUCCESS" || "$BROKER_STATUS" == "WARNING" ]]; then
    log_info "Setting archivelog deletion policy to SHIPPED TO ALL STANDBY..."
    log_cmd "rman target /" "CONFIGURE ARCHIVELOG DELETION POLICY TO SHIPPED TO ALL STANDBY"
    if run_rman "configure_archivelog_deletion.rman"; then
        log_success "RMAN archivelog deletion policy configured"
    else
        log_warn "Failed to set the RMAN archivelog deletion policy"
        log_warn "Set it manually once transport is confirmed:"
        log_warn "  rman target / <<< \"CONFIGURE ARCHIVELOG DELETION POLICY TO SHIPPED TO ALL STANDBY;\""
    fi
else
    log_warn "Broker status is ${BROKER_STATUS} - skipping the deletion policy change"
    log_warn "Without working transport the policy would block all archivelog deletion (FRA fill / ORA-00257 risk)"
    log_warn "After the configuration is healthy, set it manually:"
    log_warn "  rman target / <<< \"CONFIGURE ARCHIVELOG DELETION POLICY TO SHIPPED TO ALL STANDBY;\""
fi

# ============================================================
# Summary
# ============================================================

if [[ "$BROKER_STATUS" == "SUCCESS" ]]; then
    print_summary "SUCCESS" "Data Guard Broker configured successfully"
elif [[ "$BROKER_STATUS" == "WARNING" ]]; then
    print_summary "WARNING" "Data Guard Broker configured with warnings"
else
    print_summary "ERROR" "Data Guard Broker configuration has issues"
fi
print_status_block "Broker Configuration" \
    "Configuration Name" "$DG_BROKER_CONFIG_NAME" \
    "Primary Database" "$PRIMARY_DB_UNIQUE_NAME" \
    "Standby Database" "$STANDBY_DB_UNIQUE_NAME" \
    "Broker Status" "$BROKER_STATUS"

print_list_block "Completed Actions" \
    "Created the broker configuration." \
    "Added the primary and standby databases." \
    "Enabled the configuration." \
    "Forced a log switch to test redo transport." \
    "Set the primary RMAN archivelog deletion policy (when the configuration was healthy)."

print_list_block "Broker Management Commands" \
    "dgmgrl / \"show configuration\"" \
    "dgmgrl / \"show database '$PRIMARY_DB_UNIQUE_NAME'\"" \
    "dgmgrl / \"show database '$STANDBY_DB_UNIQUE_NAME'\"" \
    "dgmgrl / \"switchover to '$STANDBY_DB_UNIQUE_NAME'\"" \
    "dgmgrl / \"failover to '$STANDBY_DB_UNIQUE_NAME'\""

print_list_block "Next Step" \
    "Run ./standby/07_verify_dataguard.sh."

# M3: this step previously always exited 0, even with BROKER_STATUS=ERROR -
# any wrapper (E2E, cron, a plain "06 && 07") would proceed against a
# broken broker configuration. Print every block above first so the
# operator sees the full picture, then fail loudly.
if [[ "$BROKER_STATUS" != "SUCCESS" && "$BROKER_STATUS" != "WARNING" ]]; then
    exit 1
fi
