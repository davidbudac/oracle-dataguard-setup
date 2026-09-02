#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 10: Generate Handoff Report
# ============================================================
# Run this script on the PRIMARY database server after all
# previous steps (including step 7 verification) are complete.
#
# This step is a THIN WRAPPER around the standalone dg_handoff.sh
# in the repository root, which is the single implementation of
# the handoff report (emitter, HTML twin, visualizer link, verdict).
# The wrapper only adds what the setup workflow knows and the
# standalone script cannot discover on its own:
#
#   - the build's standby_config_<NAME>.env (hostnames, listener
#     port, standby TNS alias)
#   - the NFS share as the output location, reachable from both hosts
#   - the docs/DG_APPLICATION_IMPACT.html copy next to the report
#   - the setup-step banner/progress/summary chrome and exit-code
#     convention (nonzero only when Data Guard errors were found)
#
# Report:  ${NFS_SHARE}/dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.md
# HTML:    ${NFS_SHARE}/dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.html
# JSON:    ${NFS_SHARE}/dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.json
# Pack:    ..._tnsnames.ora, ..._jdbc.properties, ..._verify.sh
#
# Header metadata via environment: DG_HANDOFF_ENV (PROD/UAT/...) and
# DG_HANDOFF_CONTACT (DBA contact line) become chips in the report.
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
COMMON_DIR="${REPO_DIR}/common"

source "${COMMON_DIR}/dg_functions.sh"
enable_verbose_mode "$@"

HANDOFF_SCRIPT="${REPO_DIR}/dg_handoff.sh"

# ============================================================
# Main
# ============================================================

print_banner "Step 10: Generate Handoff Report"
init_progress 3

init_log "10_generate_handoff_report"

# ---- Pre-flight ----
progress_step "Pre-flight Checks"
check_oracle_env || exit 1
check_nfs_mount || exit 1
check_db_connection || exit 1

if [[ ! -f "$HANDOFF_SCRIPT" ]]; then
    log_error "Handoff report generator not found: ${HANDOFF_SCRIPT}"
    exit 1
fi

if ! select_config_file STANDBY_CONFIG_FILE "standby configuration" "${NFS_SHARE}/standby_config_*.env"; then
    log_error "Standby configuration not found. Run the Data Guard setup first."
    exit 1
fi

log_info "Loading standby configuration..."
source "$STANDBY_CONFIG_FILE"

init_log "10_generate_handoff_report_${PRIMARY_DB_UNIQUE_NAME}"

REPORT_FILE="${NFS_SHARE}/dg_handoff_${PRIMARY_DB_UNIQUE_NAME}.md"
HTML_REPORT_FILE="${NFS_SHARE}/dg_handoff_${PRIMARY_DB_UNIQUE_NAME}.html"
# Companion files dg_handoff.sh writes next to the Markdown: the JSON
# sidecar (also the baseline for the next run's change diff) and the
# deliverable pack an application team installs.
JSON_REPORT_FILE="${NFS_SHARE}/dg_handoff_${PRIMARY_DB_UNIQUE_NAME}.json"
TNSNAMES_PACK_FILE="${NFS_SHARE}/dg_handoff_${PRIMARY_DB_UNIQUE_NAME}_tnsnames.ora"
JDBC_PACK_FILE="${NFS_SHARE}/dg_handoff_${PRIMARY_DB_UNIQUE_NAME}_jdbc.properties"
VERIFY_PACK_FILE="${NFS_SHARE}/dg_handoff_${PRIMARY_DB_UNIQUE_NAME}_verify.sh"

if [[ "$CHECK_ONLY" == "1" ]]; then
    finish_check_mode "Handoff report would be generated at ${REPORT_FILE}"
fi

# ---- Application impact briefing ----
progress_step "Staging Application Impact Briefing"

IMPACT_SOURCE="${REPO_DIR}/docs/DG_APPLICATION_IMPACT.html"
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

# ---- Generate the report ----
progress_step "Generating Handoff Report"

# Everything the standalone script cannot discover comes from the build's
# .env; everything else it discovers itself. --all-flavors keeps the
# setup-time three-flavor output (primary-only / standby-only / role-aware).
HANDOFF_ARGS=(
    -o "$REPORT_FILE"
    --primary-host "$PRIMARY_HOSTNAME"
    --standby-host "$STANDBY_HOSTNAME"
    --port "${PRIMARY_LISTENER_PORT:-${STANDBY_LISTENER_PORT:-1521}}"
    --all-flavors
)
if [[ -n "$STANDBY_TNS_ALIAS" ]]; then
    HANDOFF_ARGS+=(--standby-tns-alias "$STANDBY_TNS_ALIAS")
fi
if [[ "$IMPACT_COPIED" == "YES" ]]; then
    HANDOFF_ARGS+=(--impact-reference "$IMPACT_TARGET")
fi
# dg_handoff.sh also reads these from the environment; passing them
# explicitly keeps the wrapper's behavior independent of export scope.
if [[ -n "$DG_HANDOFF_ENV" ]]; then
    HANDOFF_ARGS+=(--env "$DG_HANDOFF_ENV")
fi
if [[ -n "$DG_HANDOFF_CONTACT" ]]; then
    HANDOFF_ARGS+=(--contact "$DG_HANDOFF_CONTACT")
fi

log_info "Running dg_handoff.sh (report is printed below)..."
echo ""
# The report goes to stdout from dg_handoff.sh itself. Its exit code carries
# the verdict (0 healthy / 1 warning / 2 error / 3 usage-or-connect failure),
# so it must not trip `set -e` here.
HANDOFF_RC=0
bash "$HANDOFF_SCRIPT" "${HANDOFF_ARGS[@]}" || HANDOFF_RC=$?
echo ""

if [[ "$HANDOFF_RC" -eq 3 ]]; then
    log_error "dg_handoff.sh could not run (usage or connection error). No report was generated."
    print_summary "ERROR" "Handoff report generation failed"
    exit 1
fi

VERDICT="HEALTHY"
case "$HANDOFF_RC" in
    1) VERDICT="WARNING" ;;
    2) VERDICT="ERROR" ;;
esac

print_status_block "Handoff Report" \
    "Configuration"   "${PRIMARY_DB_UNIQUE_NAME} -> ${STANDBY_DB_UNIQUE_NAME}" \
    "Verdict"         "$VERDICT" \
    "Report file"     "$REPORT_FILE" \
    "HTML report"     "$HTML_REPORT_FILE" \
    "JSON sidecar"    "$JSON_REPORT_FILE" \
    "TNS aliases"     "$TNSNAMES_PACK_FILE" \
    "JDBC properties" "$JDBC_PACK_FILE" \
    "Verify script"   "$VERIFY_PACK_FILE"

print_list_block "Distribution" \
    "Share ${REPORT_FILE} (or the styled HTML twin ${HTML_REPORT_FILE}) with the application teams that connect to this database." \
    "Hand the application teams the pack alongside it: ${TNSNAMES_PACK_FILE} (append to their tnsnames.ora), ${JDBC_PACK_FILE}, and ${VERIFY_PACK_FILE} (run it on every application host before go-live, and again after a switchover drill with --expect-db-unique-name)." \
    "${JSON_REPORT_FILE} is the machine-readable snapshot; keep it in place - the next run diffs against it to produce the report's 'Changes Since Last Report' section." \
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
