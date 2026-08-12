#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - NFS Artifact Cleanup
# ============================================================
# Removes sensitive/transient files that the setup scripts stage on
# the NFS share for a given Data Guard build (a primary/standby
# DB_UNIQUE_NAME pair). Run this any time after Data Guard has been
# verified (Step 7) to scrub password file copies, the generated
# standby pfile, and RMAN duplicate cmdfiles/logs off the shared
# filesystem.
#
# By default the build's standby_config_*.env / primary_info_*.env,
# the handoff report, and the application-impact briefing are left
# in place. Pass --all to remove those too (full teardown of the
# build's NFS footprint).
#
# Usage:
#   bash common/cleanup_nfs_artifacts.sh [options]
#   bash common/cleanup_nfs_artifacts.sh -c /path/to/standby_config_X.env [options]
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR"

# Source common functions
source "${COMMON_DIR}/dg_functions.sh"
enable_verbose_mode "$@"

usage() {
    cat <<USAGE
Usage:
  bash common/cleanup_nfs_artifacts.sh [-c FILE] [--all] [-y]

Options:
  -c, --config FILE   Standby config file to use instead of auto-selecting
                      one from ${NFS_SHARE}/standby_config_*.env
      --all           Remove EVERYTHING staged for this build on the NFS
                      share, including the config .env files, the handoff
                      report, and the application-impact briefing.
                      Without --all, only password file copies, the
                      generated standby pfile, and RMAN duplicate
                      cmdfiles/logs are removed.
  -y, --yes           Do not prompt for confirmation (the removal list is
                      still printed first)
  -v, --verbose       Enable bash trace output
  -n, --check, --plan Dry-run: list what would be removed, then stop
  -h, --help          Show this help

Notes:
  - RMAN duplicate cmdfiles/logs (logs/rman_duplicate_*.rcv|.log) are not
    tagged with DB_UNIQUE_NAME in their filename, so ALL such files on the
    share are listed for removal regardless of which build created them.
    Review the printed list before confirming if multiple builds have
    shared this NFS share.
  - Nothing is ever removed without first printing the exact file list and
    (unless -y is given) requiring interactive confirmation.
USAGE
}

# ============================================================
# Parse Arguments
# ============================================================

CONFIG_FILE_ARG=""
REMOVE_ALL=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            if [[ $# -lt 2 ]]; then
                printf "Missing argument for %s\n\n" "$1"
                usage
                exit 1
            fi
            CONFIG_FILE_ARG="$2"; shift 2 ;;
        --all)        REMOVE_ALL=true; shift ;;
        -y|--yes)     ASSUME_YES=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        # Global flags already consumed by enable_verbose_mode - accept as no-ops
        -v|--verbose|--no-verbose|-a|--approval-mode|--no-approval-mode) shift ;;
        -s|--suspicious|--no-suspicious|-n|--check|--plan|--execute)     shift ;;
        *)            printf "Unknown option: %s\n\n" "$1"; usage; exit 1 ;;
    esac
done

# ============================================================
# Main Script
# ============================================================

print_banner "NFS Artifact Cleanup"
init_log "cleanup_nfs_artifacts"

# ============================================================
# Pre-flight Checks
# ============================================================

progress_step "Pre-flight Checks"

check_nfs_mount || exit 1

# ============================================================
# Select / Load Build Configuration
# ============================================================

progress_step "Loading Build Configuration"

if [[ -n "$CONFIG_FILE_ARG" ]]; then
    if [[ ! -f "$CONFIG_FILE_ARG" ]]; then
        log_error "Config file not found: $CONFIG_FILE_ARG"
        exit 1
    fi
    STANDBY_CONFIG_FILE="$CONFIG_FILE_ARG"
    log_info "Using specified config file: $STANDBY_CONFIG_FILE"
else
    if ! select_config_file STANDBY_CONFIG_FILE "standby configuration" "${NFS_SHARE}/standby_config_*.env"; then
        log_error "No standby configuration found on the NFS share."
        log_error "Pass one explicitly with: -c /path/to/standby_config_<NAME>.env"
        exit 1
    fi
fi

source "$STANDBY_CONFIG_FILE"

for req_var in PRIMARY_DB_UNIQUE_NAME STANDBY_DB_UNIQUE_NAME PRIMARY_ORACLE_SID STANDBY_ORACLE_SID PRIMARY_DB_NAME; do
    if [[ -z "${!req_var}" ]]; then
        log_error "Config file is missing required value: $req_var"
        log_error "Is this a valid standby_config_*.env file generated by primary/02_generate_standby_config.sh?"
        exit 1
    fi
done

init_log "cleanup_nfs_artifacts_${STANDBY_DB_UNIQUE_NAME}"

log_info "Build: ${PRIMARY_DB_UNIQUE_NAME} (primary) -> ${STANDBY_DB_UNIQUE_NAME} (standby)"

# ============================================================
# Compile Artifact Patterns
#
# Filename patterns below were taken directly from the scripts that
# write them (not guessed):
#   - primary/01_gather_primary_info.sh   : ${NFS_SHARE}/orapw${PRIMARY_ORACLE_SID}
#   - primary/09_configure_fsfo.sh        : ${NFS_SHARE}/orapw${PRIMARY_DB_NAME}
#   - primary/08_security_hardening.sh    : ${NFS_SHARE}/orapw${STANDBY_ORACLE_SID}_hardened
#   - primary/02_generate_standby_config.sh: ${NFS_SHARE}/init${STANDBY_ORACLE_SID}_${STANDBY_DB_UNIQUE_NAME}.ora
#   - standby/05_clone_standby.sh         : ${NFS_SHARE}/logs/rman_duplicate_<timestamp>.rcv|.log
#   - primary/01_gather_primary_info.sh   : ${NFS_SHARE}/primary_info_${PRIMARY_DB_UNIQUE_NAME}.env
#   - primary/02_generate_standby_config.sh: ${NFS_SHARE}/standby_config_${STANDBY_DB_UNIQUE_NAME}.env
#   - primary/02_generate_standby_config.sh: ${NFS_SHARE}/tnsnames_entries_${STANDBY_DB_UNIQUE_NAME}.ora
#   - primary/02_generate_standby_config.sh: ${NFS_SHARE}/listener_${STANDBY_DB_UNIQUE_NAME}.ora
#   - primary/02_generate_standby_config.sh: ${NFS_SHARE}/configure_broker_${STANDBY_DB_UNIQUE_NAME}.dgmgrl
#   - primary/10_generate_handoff_report.sh: ${NFS_SHARE}/dg_handoff_${PRIMARY_DB_UNIQUE_NAME}.md (+ .html twin)
# ============================================================

progress_step "Scanning NFS Share for Build Artifacts"

REMOVE_LIST=()

# Append every existing file matching a glob pattern to REMOVE_LIST,
# skipping anything already present (keeps the list free of duplicates
# when PRIMARY_ORACLE_SID and PRIMARY_DB_NAME happen to be identical).
add_matches() {
    local pattern="$1"
    local matches f existing already

    matches=$(ls -1 $pattern 2>/dev/null) || true
    [[ -z "$matches" ]] && return 0

    while IFS= read -r f; do
        already=0
        for existing in "${REMOVE_LIST[@]:-}"; do
            if [[ "$existing" == "$f" ]]; then
                already=1
                break
            fi
        done
        if [[ $already -eq 0 ]]; then
            REMOVE_LIST+=("$f")
        fi
    done <<< "$matches"
}

# Sensitive/transient artifacts removed by default (password file copies,
# the generated pfile, and RMAN duplicate cmdfiles/logs).
add_matches "${NFS_SHARE}/orapw${PRIMARY_ORACLE_SID}"
add_matches "${NFS_SHARE}/orapw${PRIMARY_DB_NAME}"
add_matches "${NFS_SHARE}/orapw${STANDBY_ORACLE_SID}_hardened"
add_matches "${NFS_SHARE}/init${STANDBY_ORACLE_SID}_${STANDBY_DB_UNIQUE_NAME}.ora"
add_matches "${NFS_SHARE}/logs/rman_duplicate_*.rcv"
add_matches "${NFS_SHARE}/logs/rman_duplicate_*.log"

# Files kept by default (config .env, handoff report, application-impact
# briefing). --all also removes these.
KEEP_BY_DEFAULT_PATTERNS=(
    "${NFS_SHARE}/standby_config_${STANDBY_DB_UNIQUE_NAME}.env"
    "${NFS_SHARE}/primary_info_${PRIMARY_DB_UNIQUE_NAME}.env"
    "${NFS_SHARE}/dg_handoff_${PRIMARY_DB_UNIQUE_NAME}.md"
    "${NFS_SHARE}/dg_handoff_${PRIMARY_DB_UNIQUE_NAME}.html"
    "${NFS_SHARE}/dg_application_impact.html"
    "${NFS_SHARE}/dg_application_impact_${PRIMARY_DB_UNIQUE_NAME}.html"
)

# Other build-generated files (TNS/listener/broker exchange files) that
# are not sensitive but aren't needed once the build is verified either.
# Left alone by default; removed under --all.
OTHER_BUILD_PATTERNS=(
    "${NFS_SHARE}/tnsnames_entries_${STANDBY_DB_UNIQUE_NAME}.ora"
    "${NFS_SHARE}/listener_${STANDBY_DB_UNIQUE_NAME}.ora"
    "${NFS_SHARE}/configure_broker_${STANDBY_DB_UNIQUE_NAME}.dgmgrl"
)

if [[ "$REMOVE_ALL" == "true" ]]; then
    for pattern in "${KEEP_BY_DEFAULT_PATTERNS[@]}" "${OTHER_BUILD_PATTERNS[@]}"; do
        add_matches "$pattern"
    done
fi

if [[ ${#REMOVE_LIST[@]} -eq 0 ]]; then
    print_summary "SUCCESS" "No matching artifacts found on the NFS share for ${STANDBY_DB_UNIQUE_NAME} - nothing to remove."
    exit 0
fi

print_list_block "Files That WILL BE REMOVED" "${REMOVE_LIST[@]}"

# Compute what is present but being left alone, purely for the summary.
KEPT_LIST=()
for pattern in "${KEEP_BY_DEFAULT_PATTERNS[@]}" "${OTHER_BUILD_PATTERNS[@]}"; do
    matches=$(ls -1 $pattern 2>/dev/null) || true
    [[ -z "$matches" ]] && continue
    while IFS= read -r f; do
        in_remove=0
        for r in "${REMOVE_LIST[@]}"; do
            if [[ "$r" == "$f" ]]; then
                in_remove=1
                break
            fi
        done
        if [[ $in_remove -eq 0 ]]; then
            KEPT_LIST+=("$f")
        fi
    done <<< "$matches"
done

if [[ ${#KEPT_LIST[@]} -gt 0 ]]; then
    print_list_block "Files That Will Be Kept" "${KEPT_LIST[@]}"
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
    finish_check_mode "Dry run only - ${#REMOVE_LIST[@]} artifact(s) would be removed for ${STANDBY_DB_UNIQUE_NAME}. No files were deleted."
fi

# ============================================================
# Confirmation
# ============================================================

progress_step "Confirming Removal"

if [[ "$ASSUME_YES" == "true" ]]; then
    log_warn "-y/--yes specified: skipping confirmation prompt"
elif [[ "$REMOVE_ALL" == "true" ]]; then
    if ! confirm_typed_value "This will permanently remove ALL NFS-share artifacts for ${STANDBY_DB_UNIQUE_NAME}, including the config .env files, handoff report, and generated TNS/listener/broker files." "DELETE ${STANDBY_DB_UNIQUE_NAME}"; then
        log_info "Cleanup cancelled by user"
        exit 0
    fi
else
    if ! confirm_proceed "This will permanently remove the ${#REMOVE_LIST[@]} file(s) listed above from the NFS share."; then
        log_info "Cleanup cancelled by user"
        exit 0
    fi
fi

# ============================================================
# Remove Artifacts
# ============================================================

progress_step "Removing Artifacts"

REMOVED_COUNT=0
REMOVED_FILES=()

for f in "${REMOVE_LIST[@]}"; do
    if confirm_approval_action "Remove NFS artifact" "rm -f $f"; then
        rm -f "$f"
        log_info "Removed: $f"
        record_artifact "removed:${f}"
        REMOVED_COUNT=$((REMOVED_COUNT + 1))
        REMOVED_FILES+=("$f")
    else
        log_warn "Skipped (declined in approval mode): $f"
    fi
done

# ============================================================
# Summary
# ============================================================

if [[ "$REMOVE_ALL" == "true" ]]; then
    print_summary "SUCCESS" "Removed ${REMOVED_COUNT} artifact(s) for ${STANDBY_DB_UNIQUE_NAME} (--all)"
else
    print_summary "SUCCESS" "Removed ${REMOVED_COUNT} artifact(s) for ${STANDBY_DB_UNIQUE_NAME}"
fi

if [[ ${#REMOVED_FILES[@]} -gt 0 ]]; then
    print_list_block "Removed" "${REMOVED_FILES[@]}"
fi

if [[ ${#KEPT_LIST[@]} -gt 0 && "$REMOVE_ALL" != "true" ]]; then
    print_list_block "Kept (re-run with --all to remove these too)" "${KEPT_LIST[@]}"
fi
