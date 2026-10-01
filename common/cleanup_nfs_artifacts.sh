#!/usr/bin/env bash
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
# in place. Pass --all to remove those too (everything this script can
# attribute to the build: the generated TNS/listener/broker files, the
# role-trigger SQL, the observer pidfile/logs and the build's own
# DB_UNIQUE_NAME-tagged logs/ and state/ files).
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
# The parser below rejects unknown options itself
DG_SCRIPT_FLAGS='*'
enable_verbose_mode "$@"

usage() {
    cat <<USAGE
Usage:
  bash common/cleanup_nfs_artifacts.sh [-c FILE] [--all] [-y]

Options:
  -c, --config FILE   Standby config file to use instead of auto-selecting
                      one from ${NFS_SHARE}/standby_config_*.env
      --all           Remove everything staged for this build on the NFS
                      share that can be attributed to it: the config .env
                      files, the handoff report (.md/.html/.json plus the
                      _tnsnames.ora, _jdbc.properties and _verify.sh
                      deliverable pack), the application-impact briefing,
                      the generated TNS/listener/broker files, the
                      dg_service_mgr*_<PRIMARY>.sql role-trigger scripts,
                      the FSFO observer pidfile and logs (left alone while
                      the observer is running), and the logs/ and state/
                      files tagged with this build's DB_UNIQUE_NAME.
                      Without --all, only password file copies, the
                      generated standby pfile, and RMAN duplicate
                      cmdfiles/logs are removed.
  -y, --yes           Do not prompt for confirmation (the removal list is
                      still printed first)
  -v, --verbose       Enable bash trace output
  -n, --check, --plan Dry-run: list what would be removed, then stop
  -h, --help          Show this help

Notes:
  - RMAN duplicate logs (logs/rman_duplicate_*.log) are not tagged with
    DB_UNIQUE_NAME in their filename, so ALL such files on the share are
    listed for removal regardless of which build created them. The *.rcv
    pattern is a legacy location (step 5 now keeps its cmdfile in a
    private local temp dir). Review the printed list before confirming if
    multiple builds have shared this NFS share.
  - The password file copy orapw<SID> is shared by every build of the same
    primary SID. If another build's config on the share names the same
    SID, you are asked before it is removed (-y removes it, with a warning).
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
        -s|--suspicious|--no-suspicious|-n|--check|--plan|--execute|--no-color)     shift ;;
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
#   - primary/09_configure_fsfo.sh        : ${NFS_SHARE}/orapw${PRIMARY_ORACLE_SID}
#                                           (refreshes the step-1 copy; builds
#                                           before 2026-10 wrote orapw${PRIMARY_DB_NAME},
#                                           which is still matched below)
#   - primary/02_generate_standby_config.sh: ${NFS_SHARE}/init${STANDBY_ORACLE_SID}_${STANDBY_DB_UNIQUE_NAME}.ora
#   - standby/05_clone_standby.sh         : ${NFS_SHARE}/logs/rman_duplicate_<timestamp>.rcv|.log
#   - primary/01_gather_primary_info.sh   : ${NFS_SHARE}/primary_info_${PRIMARY_DB_UNIQUE_NAME}.env
#   - primary/02_generate_standby_config.sh: ${NFS_SHARE}/standby_config_${STANDBY_DB_UNIQUE_NAME}.env
#   - primary/02_generate_standby_config.sh: ${NFS_SHARE}/tnsnames_entries_${STANDBY_DB_UNIQUE_NAME}.ora
#   - primary/02_generate_standby_config.sh: ${NFS_SHARE}/listener_${STANDBY_DB_UNIQUE_NAME}.ora
#   - primary/02_generate_standby_config.sh: ${NFS_SHARE}/configure_broker_${STANDBY_DB_UNIQUE_NAME}.dgmgrl
#   - primary/10_generate_handoff_report.sh: ${NFS_SHARE}/dg_handoff_${PRIMARY_DB_UNIQUE_NAME}.md
#     plus the .html twin, the .json sidecar and the deliverable pack
#     (_tnsnames.ora, _jdbc.properties, _verify.sh) written by dg_handoff.sh
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
        # Never schedule this run's own log/state file for removal
        if [[ "$f" == "${LOG_FILE:-}" || "$f" == "${STEP_STATE_FILE:-}" ]]; then
            continue
        fi
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
    "${NFS_SHARE}/dg_handoff_${PRIMARY_DB_UNIQUE_NAME}.json"
    "${NFS_SHARE}/dg_handoff_${PRIMARY_DB_UNIQUE_NAME}_tnsnames.ora"
    "${NFS_SHARE}/dg_handoff_${PRIMARY_DB_UNIQUE_NAME}_jdbc.properties"
    "${NFS_SHARE}/dg_handoff_${PRIMARY_DB_UNIQUE_NAME}_verify.sh"
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
    "${NFS_SHARE}/dg_service_mgr_${PRIMARY_DB_UNIQUE_NAME}.sql"
    "${NFS_SHARE}/dg_service_mgr_dedicated_${PRIMARY_DB_UNIQUE_NAME}.sql"
    "${NFS_SHARE}/dg_service_mgr_cdb_${PRIMARY_DB_UNIQUE_NAME}.sql"
)

# This build's own script logs/state files (named <script>_<DB_UNIQUE_NAME>_
# <timestamp>); --all only, and not listed under "kept" (there are many).
BUILD_LOG_PATTERNS=(
    "${NFS_SHARE}/logs/*_${STANDBY_DB_UNIQUE_NAME}_[0-9]*.log"
    "${NFS_SHARE}/state/*_${STANDBY_DB_UNIQUE_NAME}_[0-9]*.state"
)

# FSFO observer pidfile and logs (fsfo/observer.sh). Removing the pidfile of
# a running observer would orphan it for `observer.sh stop|status`, so these
# are only offered under --all and only when the recorded PID is not alive.
OBSERVER_PID_FILE="${NFS_SHARE}/fsfo_observer_${STANDBY_DB_UNIQUE_NAME}.pid"
OBSERVER_PATTERNS=(
    "$OBSERVER_PID_FILE"
    "${NFS_SHARE}/logs/fsfo_observer_${STANDBY_DB_UNIQUE_NAME}.log"
    "${NFS_SHARE}/logs/fsfo_observer_${STANDBY_DB_UNIQUE_NAME}_script.log"
)
OBSERVER_RUNNING=false
if [[ -f "$OBSERVER_PID_FILE" ]]; then
    OBSERVER_PID=$(head -1 "$OBSERVER_PID_FILE" 2>/dev/null | tr -cd '0-9')
    if [[ -n "$OBSERVER_PID" ]] && kill -0 "$OBSERVER_PID" 2>/dev/null; then
        OBSERVER_RUNNING=true
    fi
fi

if [[ "$REMOVE_ALL" == "true" ]]; then
    for pattern in "${KEEP_BY_DEFAULT_PATTERNS[@]}" "${OTHER_BUILD_PATTERNS[@]}" "${BUILD_LOG_PATTERNS[@]}"; do
        add_matches "$pattern"
    done
    if [[ "$OBSERVER_RUNNING" == "true" ]]; then
        log_warn "FSFO observer appears to be running (PID ${OBSERVER_PID}) - leaving its pidfile and logs in place"
    else
        for pattern in "${OBSERVER_PATTERNS[@]}"; do
            add_matches "$pattern"
        done
    fi
fi

# The orapw<SID> copy is named by the primary SID only, so every build of
# the same primary (e.g. a second standby) shares one file. Find the other
# builds on the share whose config names the same SID or DB name.
config_value() {
    sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*\$/\1/p" "$1" 2>/dev/null | head -1
}
ORAPW_SHARED_WITH=""
for other_cfg in "${NFS_SHARE}"/standby_config_*.env; do
    [[ -f "$other_cfg" && "$other_cfg" != "$STANDBY_CONFIG_FILE" ]] || continue
    other_sid=$(config_value "$other_cfg" PRIMARY_ORACLE_SID)
    other_dbname=$(config_value "$other_cfg" PRIMARY_DB_NAME)
    if [[ ( -n "$other_sid" && "$other_sid" == "$PRIMARY_ORACLE_SID" ) || ( -n "$other_dbname" && "$other_dbname" == "$PRIMARY_DB_NAME" ) ]]; then
        ORAPW_SHARED_WITH="${ORAPW_SHARED_WITH}${ORAPW_SHARED_WITH:+, }$(config_value "$other_cfg" STANDBY_DB_UNIQUE_NAME)"
    fi
done

if [[ ${#REMOVE_LIST[@]} -eq 0 ]]; then
    print_summary "SUCCESS" "No matching artifacts found on the NFS share for ${STANDBY_DB_UNIQUE_NAME} - nothing to remove."
    exit 0
fi

print_list_block "Files That WILL BE REMOVED" "${REMOVE_LIST[@]}"

SHARED_ORAPW_FILES=()
if [[ -n "$ORAPW_SHARED_WITH" ]]; then
    for f in "${REMOVE_LIST[@]}"; do
        case "$(basename "$f")" in
            orapw*) SHARED_ORAPW_FILES+=("$f") ;;
        esac
    done
    if [[ ${#SHARED_ORAPW_FILES[@]} -gt 0 ]]; then
        log_warn "Password file copy is shared with other build(s) on this share: ${ORAPW_SHARED_WITH}"
        log_warn "Their step 3 / step 5 would need it again if re-run."
    fi
fi

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

# Shared password file copy: another build's .env on the share may still
# point at it. Warn, and (without -y) ask before including it.
if [[ -n "$ORAPW_SHARED_WITH" ]]; then
    if [[ ${#SHARED_ORAPW_FILES[@]} -gt 0 && "$ASSUME_YES" != "true" ]]; then
        if ! confirm_proceed "Remove the shared password file copy anyway?"; then
            NEW_REMOVE_LIST=()
            for f in "${REMOVE_LIST[@]}"; do
                case "$(basename "$f")" in
                    orapw*) log_info "Keeping shared password file copy: $f" ;;
                    *) NEW_REMOVE_LIST+=("$f") ;;
                esac
            done
            REMOVE_LIST=("${NEW_REMOVE_LIST[@]}")
        fi
    fi
fi

if [[ ${#REMOVE_LIST[@]} -eq 0 ]]; then
    print_summary "SUCCESS" "Nothing left to remove for ${STANDBY_DB_UNIQUE_NAME}."
    exit 0
fi

if [[ "$ASSUME_YES" == "true" ]]; then
    log_warn "-y/--yes specified: skipping confirmation prompt"
elif [[ "$REMOVE_ALL" == "true" ]]; then
    if ! confirm_typed_value "This will permanently remove every NFS-share artifact attributable to ${STANDBY_DB_UNIQUE_NAME}, including the config .env files, handoff report, role-trigger SQL, observer files and generated TNS/listener/broker files." "DELETE ${STANDBY_DB_UNIQUE_NAME}"; then
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
