#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 3: Setup Standby Environment
# ============================================================
# Run this script on the STANDBY database server.
# It prepares the environment for RMAN duplicate.
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

print_banner "Step 3: Setup Standby Environment"
init_progress 9

# Initialize logging (will reinitialize with DB name later)
init_log "03_setup_standby_env"

# ============================================================
# Pre-flight Checks
# ============================================================

progress_step "Pre-flight Checks"

check_nfs_mount || exit 1

# Check for standby config files - support unique naming
if ! select_config_file STANDBY_CONFIG_FILE "standby configuration" "${NFS_SHARE}/standby_config_*.env"; then
    log_error "Please run 02_generate_standby_config.sh first"
    exit 1
fi

log_info "Loading standby configuration..."
source "$STANDBY_CONFIG_FILE"

# Reinitialize log with standby DB name
init_log "03_setup_standby_env_${STANDBY_DB_UNIQUE_NAME}"

# Verify we're on the correct host
# AIX-compatible hostname detection
CURRENT_HOST=$(hostname 2>/dev/null)
log_info "Current hostname: $CURRENT_HOST"
log_info "Expected standby hostname: $STANDBY_HOSTNAME"

if [[ "$CURRENT_HOST" != "$STANDBY_HOSTNAME" ]]; then
    log_warn "Current hostname does not match expected standby hostname"
    if ! confirm_proceed "Continue anyway?"; then
        exit 1
    fi
fi

# ============================================================
# Validate Disk Space
# ============================================================

progress_step "Validating Disk Space"

if [[ -n "$REQUIRED_SPACE_MB" && "$REQUIRED_SPACE_MB" -gt 0 ]]; then
    log_info "Primary database requires approximately ${REQUIRED_SPACE_MB} MB (including 20% buffer)"
    log_info "  Datafiles:  ${DATAFILE_SIZE_MB:-N/A} MB"
    log_info "  Tempfiles:  ${TEMPFILE_SIZE_MB:-N/A} MB"
    log_info "  Redo logs:  ${REDOLOG_SIZE_MB:-N/A} MB"

    # ------------------------------------------------------------
    # Per-filesystem data check (preferred)
    # ------------------------------------------------------------
    # When step 2 recorded STANDBY_DATA_PATH_SIZES_MB (per-directory
    # datafile+tempfile MB, parallel to STANDBY_DATA_PATHS), validate
    # each standby data filesystem individually. The aggregate check
    # in the else-branch sizes only the mount holding
    # STANDBY_DATA_PATHS[0]: it falsely fails when the data
    # intentionally spans several standby mounts, and falsely passes
    # when a secondary mount is too small. Older config files do not
    # carry the sizes array - fall back to the aggregate check then.
    PER_DIR_SIZES_OK=0
    if [[ -n "${STANDBY_DATA_PATH_SIZES_MB+x}" && -n "${STANDBY_DATA_PATHS+x}" ]] \
       && [[ ${#STANDBY_DATA_PATH_SIZES_MB[@]} -gt 0 ]] \
       && [[ ${#STANDBY_DATA_PATH_SIZES_MB[@]} -eq ${#STANDBY_DATA_PATHS[@]} ]]; then
        PER_DIR_SIZES_OK=1
        # Every entry must be a plain integer MB value.
        for _sz in "${STANDBY_DATA_PATH_SIZES_MB[@]}"; do
            case "$_sz" in
                ''|*[!0-9]*) PER_DIR_SIZES_OK=0; break ;;
            esac
        done
    fi

    if [[ "$PER_DIR_SIZES_OK" -eq 1 ]]; then
        log_info "Per-directory sizes available - checking each standby data filesystem individually"

        # Group the data directories by filesystem mount point and sum
        # the required MB per mount. bash 3.2 / AIX safe: parallel
        # arrays instead of declare -A. Mount point comes from `df -Pk`
        # (POSIX format) so the column layout is identical on Linux and
        # AIX - same idiom as the SRL check below and
        # get_available_space_kb in common/dg_functions.sh.
        MOUNT_POINTS=()
        MOUNT_REQUIRED_MB=()
        MOUNT_CHECK_PATHS=()
        _idx=0
        while [[ $_idx -lt ${#STANDBY_DATA_PATHS[@]} ]]; do
            _dir="${STANDBY_DATA_PATHS[$_idx]}"
            _dir_mb="${STANDBY_DATA_PATH_SIZES_MB[$_idx]}"

            # Find the nearest EXISTING parent for df (the standby data
            # directories themselves are created later in this script).
            _check_path="$_dir"
            while [[ ! -d "$_check_path" && "$_check_path" != "/" ]]; do
                _check_path=$(dirname "$_check_path")
            done

            _mount=$(df -Pk "$_check_path" 2>/dev/null | tail -1 | awk '{print $NF}')
            [[ -z "$_mount" ]] && _mount="$_check_path"
            log_info "  ${_dir}: ${_dir_mb} MB (filesystem: ${_mount})"

            _found=0
            _m=0
            while [[ $_m -lt ${#MOUNT_POINTS[@]} ]]; do
                if [[ "${MOUNT_POINTS[$_m]}" == "$_mount" ]]; then
                    MOUNT_REQUIRED_MB[$_m]=$(( ${MOUNT_REQUIRED_MB[$_m]} + _dir_mb ))
                    _found=1
                    break
                fi
                _m=$(( _m + 1 ))
            done
            if [[ $_found -eq 0 ]]; then
                MOUNT_POINTS+=("$_mount")
                MOUNT_REQUIRED_MB+=("$_dir_mb")
                MOUNT_CHECK_PATHS+=("$_check_path")
            fi
            _idx=$(( _idx + 1 ))
        done

        # Check every mount with the same +20% headroom factor the
        # aggregate REQUIRED_SPACE_MB carries, and report ALL
        # insufficient mounts before failing - not just the first.
        INSUFFICIENT_MOUNTS=()
        _m=0
        while [[ $_m -lt ${#MOUNT_POINTS[@]} ]]; do
            _mount_required_mb=$(( ${MOUNT_REQUIRED_MB[$_m]} * 12 / 10 ))
            _mount_available_kb=$(get_available_space_kb "${MOUNT_CHECK_PATHS[$_m]}")
            _mount_available_mb=$(( ${_mount_available_kb:-0} / 1024 ))

            if [[ "$_mount_available_mb" -lt "$_mount_required_mb" ]]; then
                log_error "  ${MOUNT_POINTS[$_m]}: required ${_mount_required_mb} MB (incl. 20% buffer), available ${_mount_available_mb} MB - SHORTFALL $(( _mount_required_mb - _mount_available_mb )) MB"
                INSUFFICIENT_MOUNTS+=("${MOUNT_POINTS[$_m]}")
            else
                log_info "  ${MOUNT_POINTS[$_m]}: required ${_mount_required_mb} MB (incl. 20% buffer), available ${_mount_available_mb} MB - OK"
            fi
            _m=$(( _m + 1 ))
        done

        if [[ ${#INSUFFICIENT_MOUNTS[@]} -gt 0 ]]; then
            log_error "INSUFFICIENT DISK SPACE on ${#INSUFFICIENT_MOUNTS[@]} filesystem(s): ${INSUFFICIENT_MOUNTS[*]}"
            log_error ""
            log_error "Please free up space or add storage before proceeding."
            exit 1
        fi
        log_info "PASS: Sufficient disk space available on all data filesystems"
        log_info "Note: per-directory sizes cover datafiles and tempfiles; redo/SRL space is validated separately below"
    else
        if [[ -n "${STANDBY_DATA_PATH_SIZES_MB+x}" ]]; then
            log_info "STANDBY_DATA_PATH_SIZES_MB does not match STANDBY_DATA_PATHS - using single-filesystem aggregate check"
        else
            log_info "Config predates per-directory sizes (STANDBY_DATA_PATH_SIZES_MB not set) - using single-filesystem aggregate check"
            log_info "Re-run steps 1 and 2 to enable per-filesystem validation"
        fi

        # Get the parent directory of standby data path
        STANDBY_DATA_PARENT=$(dirname "$STANDBY_DATA_PATH")

        # Ensure the parent directory exists for df check
        if [[ -d "$STANDBY_DATA_PARENT" ]]; then
            CHECK_PATH="$STANDBY_DATA_PARENT"
        elif [[ -d "$STANDBY_DATA_PATH" ]]; then
            CHECK_PATH="$STANDBY_DATA_PATH"
        else
            # Find the closest existing parent
            CHECK_PATH="$STANDBY_DATA_PARENT"
            while [[ ! -d "$CHECK_PATH" && "$CHECK_PATH" != "/" ]]; do
                CHECK_PATH=$(dirname "$CHECK_PATH")
            done
        fi

        log_info "Checking available space on: $CHECK_PATH"

        # Get available space in MB (AIX-compatible: df -Pk normalizes the
        # column layout so field 4 is always available KB, not %Used)
        AVAILABLE_SPACE_KB=$(get_available_space_kb "$CHECK_PATH")
        AVAILABLE_SPACE_MB=$((AVAILABLE_SPACE_KB / 1024))

        log_info "Available space: ${AVAILABLE_SPACE_MB} MB"
        log_info "Required space:  ${REQUIRED_SPACE_MB} MB"

        if [[ "$AVAILABLE_SPACE_MB" -lt "$REQUIRED_SPACE_MB" ]]; then
            log_error "INSUFFICIENT DISK SPACE!"
            log_error "  Available: ${AVAILABLE_SPACE_MB} MB"
            log_error "  Required:  ${REQUIRED_SPACE_MB} MB"
            log_error "  Shortfall: $((REQUIRED_SPACE_MB - AVAILABLE_SPACE_MB)) MB"
            log_error ""
            log_error "Please free up space or add storage before proceeding."
            exit 1
        else
            SPACE_REMAINING=$((AVAILABLE_SPACE_MB - REQUIRED_SPACE_MB))
            log_info "PASS: Sufficient disk space available"
            log_info "  Space remaining after clone: ${SPACE_REMAINING} MB"
        fi
    fi
else
    log_warn "Database size information not available in config file"
    log_warn "Skipping disk space validation - please verify manually"
fi

# ------------------------------------------------------------
# Separate SRL Filesystem Check
# ------------------------------------------------------------
# If the operator configured STANDBY_SRL_PATH on a different
# filesystem than STANDBY_DATA_PATH, the check above only sized
# the data mount. Run a second df against the SRL path when it
# lives on a distinct filesystem.
# ------------------------------------------------------------
if [[ "$STANDBY_STORAGE_MODE" != "OMF" ]] \
   && [[ -n "${STANDBY_SRL_PATH:-}" ]] \
   && [[ "$STANDBY_SRL_PATH" != "$STANDBY_REDO_PATH" ]] \
   && [[ -n "${REDO_LOG_SIZE_MB:-}" ]] \
   && [[ -n "${STANDBY_REDO_GROUPS:-}" ]]; then

    # Find the closest existing parent for df (the SRL dir may not
    # be created yet - step 3 creates it later in this script).
    SRL_CHECK_PATH="$STANDBY_SRL_PATH"
    while [[ ! -d "$SRL_CHECK_PATH" && "$SRL_CHECK_PATH" != "/" ]]; do
        SRL_CHECK_PATH=$(dirname "$SRL_CHECK_PATH")
    done

    # Compute the data filesystem mount point independently (the
    # earlier REQUIRED_SPACE_MB block may have been skipped).
    DATA_CHECK_PATH="$STANDBY_DATA_PATH"
    while [[ ! -d "$DATA_CHECK_PATH" && "$DATA_CHECK_PATH" != "/" ]]; do
        DATA_CHECK_PATH=$(dirname "$DATA_CHECK_PATH")
    done

    # Determine whether SRL path is on a different filesystem than
    # STANDBY_DATA_PATH. If the same filesystem, the earlier df
    # already covered it (or REQUIRED_SPACE_MB was missing and the
    # operator accepted the manual-verification warning).
    DATA_FS=$(df -P "$DATA_CHECK_PATH" 2>/dev/null | tail -1 | awk '{print $NF}')
    SRL_FS=$(df -P "$SRL_CHECK_PATH" 2>/dev/null | tail -1 | awk '{print $NF}')

    if [[ -n "$DATA_FS" && "$DATA_FS" == "$SRL_FS" ]]; then
        log_info "SRL path shares the data filesystem ($DATA_FS) - space already covered"
    else
        # SRL storage needed = redo group size x group count x 1.2 (safety margin)
        SRL_REQUIRED_MB=$(( REDO_LOG_SIZE_MB * STANDBY_REDO_GROUPS * 12 / 10 ))
        log_info "Checking available space on separate SRL filesystem: $SRL_CHECK_PATH"
        log_info "SRL storage required: ${SRL_REQUIRED_MB} MB (${REDO_LOG_SIZE_MB} MB x ${STANDBY_REDO_GROUPS} groups + 20% buffer)"

        SRL_AVAILABLE_KB=$(get_available_space_kb "$SRL_CHECK_PATH")
        SRL_AVAILABLE_MB=$(( SRL_AVAILABLE_KB / 1024 ))
        log_info "SRL filesystem available: ${SRL_AVAILABLE_MB} MB"

        if [[ "$SRL_AVAILABLE_MB" -lt "$SRL_REQUIRED_MB" ]]; then
            log_error "INSUFFICIENT SPACE ON SRL FILESYSTEM!"
            log_error "  Path:      $SRL_CHECK_PATH"
            log_error "  Available: ${SRL_AVAILABLE_MB} MB"
            log_error "  Required:  ${SRL_REQUIRED_MB} MB"
            log_error "  Shortfall: $(( SRL_REQUIRED_MB - SRL_AVAILABLE_MB )) MB"
            log_error ""
            log_error "Free up space on the SRL mount or reconfigure STANDBY_SRL_PATH."
            exit 1
        else
            log_info "PASS: Sufficient space on SRL filesystem"
        fi
    fi
fi

# Check Oracle environment
if [[ -z "$ORACLE_HOME" ]]; then
    # Try to set from config
    export ORACLE_HOME="$STANDBY_ORACLE_HOME"
fi

if [[ -z "$ORACLE_SID" ]]; then
    export ORACLE_SID="$STANDBY_ORACLE_SID"
fi

check_oracle_env || exit 1

# ============================================================
# Review Planned Changes
# ============================================================

progress_step "Reviewing Planned Changes"

if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    _dir_summary="Create any missing standby directories under ${STANDBY_DB_CREATE_FILE_DEST}, ${STANDBY_DB_RECOVERY_FILE_DEST}, and ${STANDBY_ADMIN_DIR}."
else
    _dir_summary="Create any missing standby directories under ${STANDBY_DATA_PATH}, ${STANDBY_REDO_PATH}, and ${STANDBY_ADMIN_DIR}."
    if [[ -n "${STANDBY_SRL_PATH:-}" ]] && [[ "$STANDBY_SRL_PATH" != "$STANDBY_REDO_PATH" ]]; then
        _dir_summary="${_dir_summary} Also create a separate SRL directory at ${STANDBY_SRL_PATH}."
    fi
fi
print_list_block "This Step Will Change" \
    "$_dir_summary" \
    "Install the standby password file at ${ORACLE_HOME}/dbs/orapw${STANDBY_ORACLE_SID}." \
    "Install the standby pfile at ${ORACLE_HOME}/dbs/init${STANDBY_ORACLE_SID}.ora." \
    "Update ${ORACLE_HOME}/network/admin/listener.ora and ${ORACLE_HOME}/network/admin/tnsnames.ora." \
    "Append ${STANDBY_ORACLE_SID}:${ORACLE_HOME}:N to /etc/oratab when missing."

print_list_block "This Step Will Not Change" \
    "It will not run RMAN DUPLICATE." \
    "It will not start or stop the database instance." \
    "It will not configure Data Guard Broker."

print_list_block "Files and Paths" \
    "Config source: ${STANDBY_CONFIG_FILE}" \
    "Password file source: ${NFS_SHARE}/orapw${PRIMARY_ORACLE_SID}" \
    "Pfile source: ${NFS_SHARE}/init${STANDBY_ORACLE_SID}_${STANDBY_DB_UNIQUE_NAME}.ora" \
    "Listener file: ${ORACLE_HOME}/network/admin/listener.ora" \
    "TNS file: ${ORACLE_HOME}/network/admin/tnsnames.ora"

print_list_block "Recovery If This Step Fails" \
    "Restore any .bak timestamped files created for listener.ora, tnsnames.ora, or the dbs files." \
    "Remove any directories created for the standby if you need to reset the host." \
    "Re-run this step after correcting the reported problem."

record_next_step "./primary/04_prepare_primary_dg.sh"

if [[ "$CHECK_ONLY" == "1" ]]; then
    finish_check_mode "Standby environment preflight complete. No changes were applied."
fi

# ============================================================
# Create Directory Structure
# ============================================================

progress_step "Creating Directory Structure"

# Admin directories (always needed regardless of storage mode)
DIRS_TO_CREATE=(
    "${STANDBY_ADMIN_DIR}/adump"
    "${STANDBY_ADMIN_DIR}/bdump"
    "${STANDBY_ADMIN_DIR}/cdump"
    "${STANDBY_ADMIN_DIR}/udump"
    "${STANDBY_ADMIN_DIR}/pfile"
)

if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    # OMF mode: create base directories only; Oracle creates subdirs automatically
    DIRS_TO_CREATE+=("${STANDBY_DB_CREATE_FILE_DEST}")
    DIRS_TO_CREATE+=("${STANDBY_DB_RECOVERY_FILE_DEST}")
    log_info "OMF mode: creating base OMF directories"
    log_info "  db_create_file_dest:   ${STANDBY_DB_CREATE_FILE_DEST}"
    log_info "  db_recovery_file_dest: ${STANDBY_DB_RECOVERY_FILE_DEST}"
else
    # Traditional mode: create explicit data, redo, archive directories.
    # Cover EVERY distinct directory the convert params remap to - not
    # just the first one - so datafiles spread across multiple primary
    # directories land on existing standby directories.
    if [[ -n "${STANDBY_DATA_PATHS+x}" && ${#STANDBY_DATA_PATHS[@]} -gt 0 ]]; then
        DIRS_TO_CREATE+=( "${STANDBY_DATA_PATHS[@]}" )
    else
        DIRS_TO_CREATE+=( "${STANDBY_DATA_PATH}" )
    fi
    if [[ -n "${STANDBY_REDO_PATHS+x}" && ${#STANDBY_REDO_PATHS[@]} -gt 0 ]]; then
        DIRS_TO_CREATE+=( "${STANDBY_REDO_PATHS[@]}" )
    else
        DIRS_TO_CREATE+=( "${STANDBY_REDO_PATH}" )
    fi

    # Add SRL directory if configured separately from ORL path
    if [[ -n "${STANDBY_SRL_PATH:-}" ]] && [[ "$STANDBY_SRL_PATH" != "$STANDBY_REDO_PATH" ]]; then
        DIRS_TO_CREATE+=("${STANDBY_SRL_PATH}")
        log_info "Separate SRL directory configured: $STANDBY_SRL_PATH"
    fi

    # ------------------------------------------------------------
    # Authoritative redo/data coverage from the *_FILE_NAME_CONVERT
    # pairs.
    # ------------------------------------------------------------
    # LOG_FILE_NAME_CONVERT and DB_FILE_NAME_CONVERT hold the EXACT
    # path prefixes Oracle uses to place the standby's datafiles and
    # its online + standby redo logs during RMAN DUPLICATE. The
    # STANDBY_*_PATHS arrays above are derived by token substitution
    # in step 2, which silently leaves a path unmapped when it does
    # not contain the DB-name token (common when redo logs live on a
    # separate mount). Creating the standby side of every convert
    # pair guarantees the target directories exist regardless of how
    # they were derived - this is what prevents RMAN DUPLICATE from
    # failing with ORA-17502 / ORA-19504 on the redo logs.
    add_convert_standby_dirs() {
        # $1 = a *_FILE_NAME_CONVERT value: 'pri1','stby1','pri2','stby2'
        local _convert="$1"
        [[ -z "$_convert" ]] && return 0
        local _i=0 _tok
        # Split on commas, strip the surrounding single quotes. Tokens at
        # odd indices (0-based) are the standby destinations.
        while IFS= read -r _tok; do
            _tok="${_tok#\'}"; _tok="${_tok%\'}"
            _tok="$(strip_whitespace "$_tok")"
            if [[ $(( _i % 2 )) -eq 1 && -n "$_tok" ]]; then
                DIRS_TO_CREATE+=("$_tok")
            fi
            _i=$(( _i + 1 ))
        done <<EOF
$(printf '%s' "$_convert" | tr ',' '\n')
EOF
    }
    add_convert_standby_dirs "$LOG_FILE_NAME_CONVERT"
    add_convert_standby_dirs "$DB_FILE_NAME_CONVERT"

    # The standby pfile points control_files at the standby data path,
    # so ensure that directory is covered even if no convert pair did.
    [[ -n "${STANDBY_DATA_PATH:-}" ]] && DIRS_TO_CREATE+=("${STANDBY_DATA_PATH}")

    # Add archive destination if configured (may be empty if using FRA)
    if [[ -n "$STANDBY_ARCHIVE_DEST" ]]; then
        DIRS_TO_CREATE+=("$STANDBY_ARCHIVE_DEST")
    else
        log_info "STANDBY_ARCHIVE_DEST not set - assuming FRA is used for archive logs"
    fi

    # Add FRA if configured (STANDBY_FRA is set in the config when using FRA)
    if [[ -n "$STANDBY_FRA" ]]; then
        DIRS_TO_CREATE+=("$STANDBY_FRA")
        log_info "Using Fast Recovery Area: $STANDBY_FRA"
    elif [[ -n "$DB_RECOVERY_FILE_DEST" && "$DB_RECOVERY_FILE_DEST" != "USE_DB_RECOVERY_FILE_DEST" ]]; then
        # Fallback: calculate from DB_RECOVERY_FILE_DEST if STANDBY_FRA not set.
        # The DB-name swap is bounded to whole, slash-delimited path
        # components (mirrors remap_path_token in
        # primary/02_generate_standby_config.sh), so a token that also
        # appears as a SUBSTRING of a mount name (e.g. token PROD inside
        # /prod_archive/) is never corrupted - the old unbounded
        # `sed s/tok/rep/g` would have rewritten it.

        # True when $2 occurs as a whole, slash-delimited component of path $1.
        _path_has_component() {
            case "/$1/" in
                *"/$2/"*) return 0 ;;
                *) return 1 ;;
            esac
        }

        # Echo path $1 with every whole-component occurrence of token $2
        # swapped to $3. Two sed passes (interior `/tok/`, then a trailing
        # `/tok` at end of string) keep this portable to AIX / bash 3.2.
        _replace_path_component() {
            local _p="$1" _tok="$2" _rep="$3"
            _p=$(printf '%s' "$_p" | sed "s|/${_tok}/|/${_rep}/|g")
            _p=$(printf '%s' "$_p" | sed "s|/${_tok}\$|/${_rep}|")
            printf '%s' "$_p"
        }

        # Echo the standby path for a primary path by swapping whichever
        # case variant of PRIMARY_DB_UNIQUE_NAME appears as a path
        # component (upper, then lower, then the literal mixed case).
        # A path containing no variant is echoed unchanged.
        _remap_dbname_component() {
            local _p="$1"
            local _tok_upper _tok_lower _rep_upper _rep_lower
            _tok_upper=$(printf '%s' "$PRIMARY_DB_UNIQUE_NAME" | tr '[:lower:]' '[:upper:]')
            _tok_lower=$(printf '%s' "$PRIMARY_DB_UNIQUE_NAME" | tr '[:upper:]' '[:lower:]')
            _rep_upper=$(printf '%s' "$STANDBY_DB_UNIQUE_NAME" | tr '[:lower:]' '[:upper:]')
            _rep_lower=$(printf '%s' "$STANDBY_DB_UNIQUE_NAME" | tr '[:upper:]' '[:lower:]')
            if   _path_has_component "$_p" "$_tok_upper"; then
                _replace_path_component "$_p" "$_tok_upper" "$_rep_upper"
            elif _path_has_component "$_p" "$_tok_lower"; then
                _replace_path_component "$_p" "$_tok_lower" "$_rep_lower"
            elif _path_has_component "$_p" "$PRIMARY_DB_UNIQUE_NAME"; then
                _replace_path_component "$_p" "$PRIMARY_DB_UNIQUE_NAME" "$STANDBY_DB_UNIQUE_NAME"
            else
                printf '%s' "$_p"
            fi
        }

        STANDBY_FRA_CALC=$(_remap_dbname_component "$DB_RECOVERY_FILE_DEST")
        DIRS_TO_CREATE+=("$STANDBY_FRA_CALC")
    fi
fi

# Deduplicate. The path arrays and the convert pairs intentionally
# overlap, and redo vs datafile directories can differ only by a
# trailing slash ('/x' vs '/x/') while naming the same directory.
# Collapse both so the approval prompt and creation log list each
# real directory once.
DIRS_DEDUPED=()
_seen_dirs=$'\n'
for dir in "${DIRS_TO_CREATE[@]}"; do
    [[ -z "$dir" ]] && continue
    _key="$dir"
    # Strip a single trailing slash for comparison, but never reduce "/".
    [[ "$_key" != "/" ]] && _key="${_key%/}"
    case "$_seen_dirs" in
        *$'\n'"$_key"$'\n'*) continue ;;
    esac
    _seen_dirs="${_seen_dirs}${_key}"$'\n'
    DIRS_DEDUPED+=("$dir")
done
DIRS_TO_CREATE=( "${DIRS_DEDUPED[@]}" )

DIRS_MISSING=()
for dir in "${DIRS_TO_CREATE[@]}"; do
    [[ -z "$dir" ]] && continue
    if [[ ! -d "$dir" ]]; then
        DIRS_MISSING+=("$dir")
    fi
done

if [[ ${#DIRS_MISSING[@]} -gt 0 ]]; then
    confirm_approval_action "Create standby directories" "mkdir -p $(shell_join "${DIRS_MISSING[@]}")" || exit 1
fi

for dir in "${DIRS_TO_CREATE[@]}"; do
    # Skip empty entries
    [[ -z "$dir" ]] && continue

    if [[ ! -d "$dir" ]]; then
        log_info "Creating directory: $dir"
        mkdir -p "$dir"
    else
        log_info "Directory exists: $dir"
    fi
done

log_success "Directory structure created successfully"
record_artifact "directory_tree:${STANDBY_ADMIN_DIR}"

# ============================================================
# Copy Password File
# ============================================================

progress_step "Installing Password File"

SOURCE_PWD_FILE="${NFS_SHARE}/orapw${PRIMARY_ORACLE_SID}"
DEST_PWD_FILE="${ORACLE_HOME}/dbs/orapw${STANDBY_ORACLE_SID}"

if [[ ! -f "$SOURCE_PWD_FILE" ]]; then
    log_error "Password file not found on NFS: $SOURCE_PWD_FILE"
    log_error "Please ensure 01_gather_primary_info.sh copied the password file"
    exit 1
fi

if [[ -f "$DEST_PWD_FILE" ]]; then
    backup_file "$DEST_PWD_FILE"
fi

log_cmd "COMMAND:" "cp $SOURCE_PWD_FILE $DEST_PWD_FILE"
confirm_approval_action "Install standby password file" "cp $SOURCE_PWD_FILE $DEST_PWD_FILE && chmod 640 $DEST_PWD_FILE" || exit 1
cp "$SOURCE_PWD_FILE" "$DEST_PWD_FILE"
chmod 640 "$DEST_PWD_FILE"
log_success "Password file copied to: $DEST_PWD_FILE"
record_artifact "password_file:${DEST_PWD_FILE}"

# ============================================================
# Copy Standby Init File
# ============================================================

progress_step "Installing Parameter File"

SOURCE_PFILE="${NFS_SHARE}/init${STANDBY_ORACLE_SID}_${STANDBY_DB_UNIQUE_NAME}.ora"
DEST_PFILE="${ORACLE_HOME}/dbs/init${STANDBY_ORACLE_SID}.ora"

if [[ ! -f "$SOURCE_PFILE" ]]; then
    log_error "Standby pfile not found on NFS: $SOURCE_PFILE"
    log_error "Please ensure 02_generate_standby_config.sh generated the pfile"
    exit 1
fi

if [[ -f "$DEST_PFILE" ]]; then
    backup_file "$DEST_PFILE"
fi

log_cmd "COMMAND:" "cp $SOURCE_PFILE $DEST_PFILE"
confirm_approval_action "Install standby parameter file" "cp $SOURCE_PFILE $DEST_PFILE && chmod 640 $DEST_PFILE" || exit 1
cp "$SOURCE_PFILE" "$DEST_PFILE"
chmod 640 "$DEST_PFILE"
log_success "Parameter file copied to: $DEST_PFILE"
record_artifact "pfile:${DEST_PFILE}"

# ============================================================
# Configure Listener
# ============================================================

progress_step "Configuring Listener"

LISTENER_ORA="${ORACLE_HOME}/network/admin/listener.ora"
LISTENER_ENTRY_FILE="${NFS_SHARE}/listener_${STANDBY_DB_UNIQUE_NAME}.ora"

if [[ ! -f "$LISTENER_ENTRY_FILE" ]]; then
    log_error "Listener entry file not found: $LISTENER_ENTRY_FILE"
    exit 1
fi

# Static services required for RMAN duplicate and broker switchover
# Private temp dir + EXIT-trap cleanup: create_temp_dir prefers `mktemp -d`,
# falling back to a mode-700 directory on AIX images without mktemp - safer
# than a predictable /tmp/..._$$ filename. No pre-existing EXIT trap in this
# script, so it is safe to install one here.
TEMP_SID_DESC_DIR=$(create_temp_dir) || { log_error "Could not create temp directory"; exit 1; }
trap 'rm -rf "$TEMP_SID_DESC_DIR"' EXIT
TEMP_SID_DESC="${TEMP_SID_DESC_DIR}/dg_sid_desc_standby.$$"
STANDBY_STATIC_GLOBAL_NAME="${STANDBY_DB_UNIQUE_NAME}${DB_DOMAIN:+.${DB_DOMAIN}}"
STANDBY_DGMGRL_GLOBAL_NAME="${STANDBY_DB_UNIQUE_NAME}_DGMGRL${DB_DOMAIN:+.${DB_DOMAIN}}"
MISSING_GLOBAL_NAMES=()

# Check if listener.ora exists
if [[ -f "$LISTENER_ORA" ]]; then
    backup_file "$LISTENER_ORA"

    if ! listener_has_global_dbname "$LISTENER_ORA" "$STANDBY_STATIC_GLOBAL_NAME"; then
        MISSING_GLOBAL_NAMES+=("$STANDBY_STATIC_GLOBAL_NAME")
    fi
    if ! listener_has_global_dbname "$LISTENER_ORA" "$STANDBY_DGMGRL_GLOBAL_NAME"; then
        MISSING_GLOBAL_NAMES+=("$STANDBY_DGMGRL_GLOBAL_NAME")
    fi

    if [[ ${#MISSING_GLOBAL_NAMES[@]} -eq 0 ]]; then
        log_info "Required standby static listener entries already exist"
    elif grep -q "SID_LIST_LISTENER" "$LISTENER_ORA"; then
        write_sid_desc_entries "$TEMP_SID_DESC" "$STANDBY_ORACLE_SID" "$ORACLE_HOME" "${MISSING_GLOBAL_NAMES[@]}"
        log_info "SID_LIST_LISTENER exists - adding missing static registration entries"
        confirm_approval_action "Update standby listener.ora" "Insert standby SID_DESC entries into $LISTENER_ORA" || exit 1
        if add_sid_to_listener "$LISTENER_ORA" "$TEMP_SID_DESC"; then
            log_info "Missing SID_DESC entries added to existing SID_LIST_LISTENER"
        else
            log_warn "Could not auto-insert the standby static registration entries"
            log_warn "Please manually add the following entry to SID_LIST_LISTENER:"
            echo ""
            cat "$TEMP_SID_DESC"
            echo ""
        fi
    else
        write_sid_desc_entries "$TEMP_SID_DESC" "$STANDBY_ORACLE_SID" "$ORACLE_HOME" "${MISSING_GLOBAL_NAMES[@]}"
        log_info "Adding SID_LIST_LISTENER to listener.ora"
        confirm_approval_action "Append standby SID_LIST_LISTENER to listener.ora" "append Data Guard standby listener block to $LISTENER_ORA" || exit 1
        cat >> "$LISTENER_ORA" <<EOF

# Data Guard standby static registration - Added $(date)
# Includes _DGMGRL service for Data Guard Broker switchover
SID_LIST_LISTENER =
  (SID_LIST =
$(cat "$TEMP_SID_DESC")
  )
EOF
        log_info "Listener entry added successfully"
    fi
else
    # Create new listener.ora
    log_info "Creating new listener.ora"
    confirm_approval_action "Create standby listener.ora" "write $LISTENER_ORA" || exit 1
    write_sid_desc_entries "$TEMP_SID_DESC" "$STANDBY_ORACLE_SID" "$ORACLE_HOME" "$STANDBY_STATIC_GLOBAL_NAME" "$STANDBY_DGMGRL_GLOBAL_NAME"
    cat > "$LISTENER_ORA" <<EOF
# Listener configuration for Data Guard standby
# Created: $(date)

LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = ${STANDBY_HOSTNAME})(PORT = ${STANDBY_LISTENER_PORT}))
    )
  )

# Includes _DGMGRL service for Data Guard Broker switchover
SID_LIST_LISTENER =
  (SID_LIST =
$(cat "$TEMP_SID_DESC")
  )
EOF
    log_info "listener.ora created successfully"
fi

rm -rf "$TEMP_SID_DESC_DIR"
record_artifact "listener:${LISTENER_ORA}"

# ============================================================
# Configure TNS Names
# ============================================================

progress_step "Configuring TNS Names"

TNSNAMES_ORA="${ORACLE_HOME}/network/admin/tnsnames.ora"
TNSNAMES_ENTRY_FILE="${NFS_SHARE}/tnsnames_entries_${STANDBY_DB_UNIQUE_NAME}.ora"

if [[ ! -f "$TNSNAMES_ENTRY_FILE" ]]; then
    log_error "TNS entries file not found: $TNSNAMES_ENTRY_FILE"
    exit 1
fi

# Check if tnsnames.ora exists
if [[ -f "$TNSNAMES_ORA" ]]; then
    backup_file "$TNSNAMES_ORA"

    # Check if entries already exist (anchor on an alias definition line;
    # aliases may contain dots, so escape them for the regex)
    PRIMARY_ALIAS_RE=$(printf '%s' "$PRIMARY_TNS_ALIAS" | sed 's/[.]/\\./g')
    STANDBY_ALIAS_RE=$(printf '%s' "$STANDBY_TNS_ALIAS" | sed 's/[.]/\\./g')
    if grep -qiE "^[[:space:]]*${PRIMARY_ALIAS_RE}[[:space:]]*=" "$TNSNAMES_ORA" && grep -qiE "^[[:space:]]*${STANDBY_ALIAS_RE}[[:space:]]*=" "$TNSNAMES_ORA"; then
        log_warn "TNS entries already exist for both primary and standby"
        log_info "Please verify tnsnames.ora manually if needed"
    else
        # Append entries
        log_info "Adding TNS entries to tnsnames.ora"
        confirm_approval_action "Append Data Guard TNS entries" "append Data Guard entries to $TNSNAMES_ORA" || exit 1
        echo "" >> "$TNSNAMES_ORA"
        echo "# Data Guard TNS entries - Added $(date)" >> "$TNSNAMES_ORA"
        cat "$TNSNAMES_ENTRY_FILE" >> "$TNSNAMES_ORA"
        log_info "TNS entries added successfully"
    fi
else
    # Create new tnsnames.ora
    log_info "Creating new tnsnames.ora"
    confirm_approval_action "Create standby tnsnames.ora" "write $TNSNAMES_ORA" || exit 1
    echo "# TNS Names for Data Guard" > "$TNSNAMES_ORA"
    echo "# Created: $(date)" >> "$TNSNAMES_ORA"
    echo "" >> "$TNSNAMES_ORA"
    cat "$TNSNAMES_ENTRY_FILE" >> "$TNSNAMES_ORA"
    log_info "tnsnames.ora created successfully"
fi
record_artifact "tnsnames:${TNSNAMES_ORA}"

# ============================================================
# Update oratab
# ============================================================

progress_step "Updating oratab"

ORATAB="/etc/oratab"
if [[ -f "$ORATAB" ]]; then
    if grep -q "^${STANDBY_ORACLE_SID}:" "$ORATAB"; then
        log_info "Entry for $STANDBY_ORACLE_SID already exists in oratab"
    else
        log_info "Adding $STANDBY_ORACLE_SID to oratab"
        confirm_approval_action "Update /etc/oratab" "append ${STANDBY_ORACLE_SID}:${ORACLE_HOME}:N to $ORATAB" || exit 1
        echo "${STANDBY_ORACLE_SID}:${ORACLE_HOME}:N" >> "$ORATAB"
    fi
else
    log_warn "oratab not found at $ORATAB"
fi

# ============================================================
# Start/Reload Listener
# ============================================================

progress_step "Starting or Reloading Listener"

# Check if listener is running
if "$ORACLE_HOME/bin/lsnrctl" status > /dev/null 2>&1; then
    log_info "Listener is running, reloading..."
    log_cmd "COMMAND:" "lsnrctl reload"
    confirm_approval_action "Reload Oracle listener" "$ORACLE_HOME/bin/lsnrctl reload" || exit 1
    "$ORACLE_HOME/bin/lsnrctl" reload
else
    log_info "Starting listener..."
    log_cmd "COMMAND:" "lsnrctl start"
    confirm_approval_action "Start Oracle listener" "$ORACLE_HOME/bin/lsnrctl start" || exit 1
    "$ORACLE_HOME/bin/lsnrctl" start
fi

# Show listener status
echo ""
"$ORACLE_HOME/bin/lsnrctl" status

# ============================================================
# Verify Static Registration
# ============================================================

progress_step "Verifying Listener Registration"

echo ""
log_info "Checking listener services..."
"$ORACLE_HOME/bin/lsnrctl" services

# Look for our service
if "$ORACLE_HOME/bin/lsnrctl" status 2>&1 | grep -q "$STANDBY_DB_UNIQUE_NAME"; then
    log_info "Static registration verified for $STANDBY_DB_UNIQUE_NAME"
else
    log_warn "Could not verify static registration - please check listener status"
fi

# ============================================================
# Summary
# ============================================================

print_summary "SUCCESS" "Standby environment setup complete"
if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    print_status_block "Standby Environment" \
        "Host" "$CURRENT_HOST" \
        "DB_UNIQUE_NAME" "$STANDBY_DB_UNIQUE_NAME" \
        "ORACLE_SID" "$STANDBY_ORACLE_SID" \
        "Storage Mode" "OMF" \
        "db_create_file_dest" "$STANDBY_DB_CREATE_FILE_DEST" \
        "Listener Port" "$STANDBY_LISTENER_PORT"
else
    print_status_block "Standby Environment" \
        "Host" "$CURRENT_HOST" \
        "DB_UNIQUE_NAME" "$STANDBY_DB_UNIQUE_NAME" \
        "ORACLE_SID" "$STANDBY_ORACLE_SID" \
        "Data Path" "$STANDBY_DATA_PATH" \
        "Listener Port" "$STANDBY_LISTENER_PORT"
fi

print_list_block "Completed Actions" \
    "Created the standby directory structure." \
    "Installed the password file and parameter file." \
    "Configured listener static registration." \
    "Updated tnsnames.ora and oratab." \
    "Started or reloaded the listener."

print_list_block "Next Steps" \
    "On PRIMARY, run ./primary/04_prepare_primary_dg.sh." \
    "Then return to STANDBY and run ./standby/05_clone_standby.sh."
