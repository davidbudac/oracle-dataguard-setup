#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 2: Generate Standby Configuration
# ============================================================
# Run this script after gathering primary info.
# It generates the standby configuration (single source of truth)
# and displays it for user review.
#
# After editing standby_config_*.env, re-run with --regenerate
# to update all derived files (pfile, TNS, listener, DGMGRL)
# without repeating the interactive prompts.
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source common functions
source "${COMMON_DIR}/dg_functions.sh"
enable_verbose_mode "$@"

# Check for --regenerate flag
REGENERATE=0
for _arg in "$@"; do
    [[ "$_arg" == "--regenerate" ]] && REGENERATE=1
done

# ============================================================
# Main Script
# ============================================================

if [[ "$REGENERATE" == "1" ]]; then

# ============================================================
# REGENERATE MODE
# ============================================================
# Re-read an existing standby_config_*.env file (which the user
# may have edited) and regenerate all derived files: pfile,
# tnsnames, listener configs, and DGMGRL script.
# ============================================================

print_banner "Step 2: Regenerate Config Files"
init_log "02_regenerate_config"

check_nfs_mount || exit 1

if ! select_config_file STANDBY_CONFIG_FILE "standby configuration" "${NFS_SHARE}/standby_config_*.env"; then
    log_error "No standby config file found to regenerate from"
    exit 1
fi

log_info "Regenerating from: $STANDBY_CONFIG_FILE"
source "$STANDBY_CONFIG_FILE"

# Set aliases expected by the file generation code below.
# The generation sections use variable names that come from the
# primary_info file in normal mode; map them from the config.
DB_NAME="$PRIMARY_DB_NAME"
DB_UNIQUE_NAME="$PRIMARY_DB_UNIQUE_NAME"
LISTENER_PORT="${STANDBY_LISTENER_PORT:-${PRIMARY_LISTENER_PORT}}"
RECOMMENDED_STBY_GROUPS="${STANDBY_REDO_GROUPS}"

# Derive service names (same logic as normal flow)
if [[ -n "$DB_DOMAIN" ]]; then
    PRIMARY_SERVICE_NAME="${PRIMARY_DB_UNIQUE_NAME}.${DB_DOMAIN}"
    STANDBY_SERVICE_NAME="${STANDBY_DB_UNIQUE_NAME}.${DB_DOMAIN}"
else
    PRIMARY_SERVICE_NAME="${PRIMARY_DB_UNIQUE_NAME}"
    STANDBY_SERVICE_NAME="${STANDBY_DB_UNIQUE_NAME}"
fi

init_log "02_regenerate_config_${STANDBY_DB_UNIQUE_NAME}"
log_info "Config: ${PRIMARY_DB_UNIQUE_NAME} -> ${STANDBY_DB_UNIQUE_NAME}"

else

# ============================================================
# NORMAL MODE
# ============================================================

print_banner "Step 2: Generate Standby Config"
init_progress 7

# Initialize logging (will reinitialize with DB names later)
init_log "02_generate_standby_config"

# ============================================================
# Pre-flight Checks
# ============================================================

progress_step "Pre-flight Checks"

check_nfs_mount || exit 1

# Check for primary info files - support unique naming
if ! select_config_file PRIMARY_INFO_FILE "primary database info" "${NFS_SHARE}/primary_info_*.env"; then
    log_error "Please run 01_gather_primary_info.sh on the primary server first"
    exit 1
fi

log_info "Loading primary info from: $PRIMARY_INFO_FILE"

# Source primary info
source "$PRIMARY_INFO_FILE"

log_info "Primary database: $DB_UNIQUE_NAME on $PRIMARY_HOSTNAME"

# Reinitialize log with primary DB name
init_log "02_generate_standby_config_${DB_UNIQUE_NAME}"

# ============================================================
# Prompt for Standby Information
# ============================================================

progress_step "Collecting Standby Server Configuration"

echo ""
echo "Please provide the following information for the standby database:"
echo ""

# Standby hostname
prompt_with_default "Standby server hostname" "" STANDBY_HOSTNAME
if [ -z "$STANDBY_HOSTNAME" ]; then
    log_error "Standby hostname cannot be empty"
    exit 1
fi

# Standby DB_UNIQUE_NAME
echo ""
echo "The standby DB_UNIQUE_NAME must be different from primary ($DB_UNIQUE_NAME)"
printf "Standby DB_UNIQUE_NAME: "
read STANDBY_DB_UNIQUE_NAME
if [ -z "$STANDBY_DB_UNIQUE_NAME" ]; then
    log_error "Standby DB_UNIQUE_NAME cannot be empty"
    exit 1
fi

if [[ "$STANDBY_DB_UNIQUE_NAME" == "$DB_UNIQUE_NAME" ]]; then
    log_error "Standby DB_UNIQUE_NAME must be different from primary"
    exit 1
fi

# Standby Oracle SID
echo ""
prompt_with_default "Standby ORACLE_SID" "$PRIMARY_ORACLE_SID" STANDBY_ORACLE_SID

# ============================================================
# Select Standby Storage Mode
# ============================================================
# Two orthogonal questions are asked here:
#   Q1 - Storage layout (Traditional vs OMF)
#   Q2 - Where archived redo logs land (FRA vs explicit path)
# These are independent: Traditional + FRA is a valid combination
# and is the simplest way to put FRA on the standby even when the
# primary does NOT use FRA.
# ============================================================

echo ""
echo "Q1) Storage layout for standby datafiles, redo, control files:"
echo "  1) Traditional  - paths derived from primary (DB_FILE_NAME_CONVERT)"
echo "  2) OMF          - Oracle Managed Files (db_create_file_dest)"
echo ""
prompt_with_default "Storage mode" "1" STORAGE_CHOICE

case "$STORAGE_CHOICE" in
    2|omf|OMF)
        STANDBY_STORAGE_MODE="OMF"
        log_info "Standby storage mode: OMF (Oracle Managed Files)"
        ;;
    *)
        STANDBY_STORAGE_MODE="TRADITIONAL"
        log_info "Standby storage mode: Traditional (path substitution)"
        ;;
esac

# Initialize storage-related variables
STANDBY_DB_CREATE_FILE_DEST=""
STANDBY_DB_RECOVERY_FILE_DEST=""
STANDBY_DB_RECOVERY_FILE_DEST_SIZE=""
STANDBY_FRA=""
STANDBY_ARCHIVE_DEST=""
USE_FRA_FOR_STANDBY=""

if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    echo ""
    echo "OMF mode: Oracle will place datafiles, redo logs, and control"
    echo "files under db_create_file_dest. A FRA is required for archived"
    echo "redo - choose its path and size below."
    echo ""

    prompt_with_default "Standby db_create_file_dest" "" STANDBY_DB_CREATE_FILE_DEST
    if [[ -z "$STANDBY_DB_CREATE_FILE_DEST" ]]; then
        log_error "db_create_file_dest cannot be empty in OMF mode"
        exit 1
    fi
fi

# ============================================================
# Q2 - Archive log destination on standby
# ============================================================
# Available combinations:
#   Traditional + FRA       -> USE_FRA_FOR_STANDBY=YES (works regardless
#                              of whether primary uses FRA)
#   Traditional + explicit  -> USE_FRA_FOR_STANDBY=NO  (explicit dir)
#   OMF                     -> FRA only (Oracle requires it for OMF apply)
# ============================================================

if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    _archive_choice_default="1"
    _archive_choice_locked="YES"   # OMF requires FRA
else
    # In Traditional mode, default to FRA when the primary already uses
    # it (matches the operator's mental model) - otherwise default to
    # explicit so the operator who has no FRA today doesn't get one by
    # surprise. Either choice is fully supported.
    if [[ "$USE_FRA_FOR_ARCHIVE" == "YES" ]]; then
        _archive_choice_default="1"
    else
        _archive_choice_default="2"
    fi
    _archive_choice_locked="NO"
fi

if [[ "$_archive_choice_locked" == "YES" ]]; then
    log_info "OMF mode: archive logs land in the Fast Recovery Area"
    _archive_choice="1"
else
    echo ""
    echo "Q2) Where should archived redo logs land on the standby?"
    echo "  1) Fast Recovery Area (FRA) - Oracle manages cleanup"
    echo "  2) Explicit filesystem directory"
    echo ""
    prompt_with_default "Archive destination" "$_archive_choice_default" _archive_choice
fi

case "$_archive_choice" in
    1|fra|FRA)
        USE_FRA_FOR_STANDBY="YES"

        # Default FRA path priority: primary FRA (re-mapped to standby
        # DB_UNIQUE_NAME) -> derived from primary archive dest -> empty
        _fra_default=""
        if [[ -n "$DB_RECOVERY_FILE_DEST" ]]; then
            _fra_default=$(echo "$DB_RECOVERY_FILE_DEST" \
                | sed "s|/${DB_UNIQUE_NAME}/|/${STANDBY_DB_UNIQUE_NAME}/|g; s|/${DB_UNIQUE_NAME}$|/${STANDBY_DB_UNIQUE_NAME}|")
            # If no substitution happened, keep primary path (FRA dirs
            # in many setups are not DB_UNIQUE_NAME-scoped at the path
            # level - Oracle creates subdirs under it).
            if [[ "$_fra_default" == "$DB_RECOVERY_FILE_DEST" ]]; then
                _fra_default="$DB_RECOVERY_FILE_DEST"
            fi
        fi
        prompt_with_default "Standby FRA path (db_recovery_file_dest)" "$_fra_default" STANDBY_FRA
        if [[ -z "$STANDBY_FRA" ]]; then
            log_error "FRA path cannot be empty when using FRA"
            exit 1
        fi

        _fra_size_default="${DB_RECOVERY_FILE_DEST_SIZE:-50G}"
        prompt_with_default "Standby FRA size (db_recovery_file_dest_size)" "$_fra_size_default" STANDBY_DB_RECOVERY_FILE_DEST_SIZE

        # Mirror into the OMF-named variable so downstream code that
        # used STANDBY_DB_RECOVERY_FILE_DEST keeps working unchanged.
        STANDBY_DB_RECOVERY_FILE_DEST="$STANDBY_FRA"

        log_info "Standby will archive to FRA: $STANDBY_FRA (${STANDBY_DB_RECOVERY_FILE_DEST_SIZE})"
        ;;
    *)
        USE_FRA_FOR_STANDBY="NO"
        STANDBY_FRA=""
        STANDBY_DB_RECOVERY_FILE_DEST=""
        STANDBY_DB_RECOVERY_FILE_DEST_SIZE=""

        _arch_default=""
        if [[ -n "$PRIMARY_ARCHIVE_DEST" ]]; then
            _arch_default=$(echo "$PRIMARY_ARCHIVE_DEST" \
                | sed "s|/${DB_UNIQUE_NAME}|/${STANDBY_DB_UNIQUE_NAME}|g")
        fi
        prompt_with_default "Standby archive log directory" "$_arch_default" STANDBY_ARCHIVE_DEST
        if [[ -z "$STANDBY_ARCHIVE_DEST" ]]; then
            log_error "Archive log directory cannot be empty"
            exit 1
        fi
        log_info "Standby will archive to explicit path: $STANDBY_ARCHIVE_DEST"
        ;;
esac

# ============================================================
# Generate Path Conversions
# ============================================================

progress_step "Generating Path Conversions"

# Multi-path discovery: derive the FULL set of standby data and redo
# directories from PRIMARY_DATA_PATHS / PRIMARY_REDO_PATHS (collected
# at step 1). Each primary directory needs its own pair in the
# DB_FILE_NAME_CONVERT - without that, datafiles outside the first
# directory get the wrong path and step 5 fails.

# Fallback: if step 1 did not write the *_PATHS arrays (older config
# files), populate from the singular *_PATH so the new code still
# works end-to-end.
if [[ -z "${PRIMARY_DATA_PATHS+x}" || ${#PRIMARY_DATA_PATHS[@]} -eq 0 ]]; then
    PRIMARY_DATA_PATHS=("$PRIMARY_DATA_PATH")
fi
if [[ -z "${PRIMARY_REDO_PATHS+x}" || ${#PRIMARY_REDO_PATHS[@]} -eq 0 ]]; then
    PRIMARY_REDO_PATHS=("$PRIMARY_REDO_PATH")
fi

if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    # OMF mode: paths are managed by Oracle, no FILE_NAME_CONVERT needed
    # Oracle places all redo logs (ORL and SRL) under db_create_file_dest,
    # so SRL separation is not supported in OMF mode.
    STANDBY_DATA_PATH="${STANDBY_DB_CREATE_FILE_DEST}"
    STANDBY_REDO_PATH="${STANDBY_DB_CREATE_FILE_DEST}"
    PRIMARY_SRL_PATH="${PRIMARY_REDO_PATH}"
    STANDBY_SRL_PATH="${STANDBY_DB_CREATE_FILE_DEST}"
    DB_FILE_NAME_CONVERT=""
    LOG_FILE_NAME_CONVERT=""
    STANDBY_DATA_PATHS=("$STANDBY_DB_CREATE_FILE_DEST")
    STANDBY_REDO_PATHS=("$STANDBY_DB_CREATE_FILE_DEST")

    log_info "OMF mode: Oracle will manage file placement"
    log_info "  db_create_file_dest:      $STANDBY_DB_CREATE_FILE_DEST"
    log_info "  db_recovery_file_dest:    $STANDBY_DB_RECOVERY_FILE_DEST"
else
# Detect the actual directory-name token used in PRIMARY paths so we
# can substitute it for STANDBY (case-preserving). The token is
# usually DB_UNIQUE_NAME but may differ in case ('TESTCDB' vs
# 'testcdb') or be entirely custom.
DB_UNIQUE_NAME_UPPER=$(echo "$DB_UNIQUE_NAME" | tr '[:lower:]' '[:upper:]')
DB_UNIQUE_NAME_LOWER=$(echo "$DB_UNIQUE_NAME" | tr '[:upper:]' '[:lower:]')

PRIMARY_DIR_NAME=""
if echo "$PRIMARY_DATA_PATH" | grep -q "/${DB_UNIQUE_NAME_UPPER}"; then
    PRIMARY_DIR_NAME="$DB_UNIQUE_NAME_UPPER"
elif echo "$PRIMARY_DATA_PATH" | grep -q "/${DB_UNIQUE_NAME_LOWER}"; then
    PRIMARY_DIR_NAME="$DB_UNIQUE_NAME_LOWER"
elif echo "$PRIMARY_DATA_PATH" | grep -q "/${DB_UNIQUE_NAME}/"; then
    PRIMARY_DIR_NAME="$DB_UNIQUE_NAME"
fi

if [[ -n "$PRIMARY_DIR_NAME" ]]; then
    if [[ "$PRIMARY_DIR_NAME" == "$DB_UNIQUE_NAME_UPPER" ]]; then
        STANDBY_DIR_NAME=$(echo "$STANDBY_DB_UNIQUE_NAME" | tr '[:lower:]' '[:upper:]')
    else
        STANDBY_DIR_NAME="$STANDBY_DB_UNIQUE_NAME"
    fi
    log_info "Primary directory token in paths: $PRIMARY_DIR_NAME"
    log_info "Standby directory token in paths: $STANDBY_DIR_NAME"
else
    PRIMARY_DIR_NAME="$DB_UNIQUE_NAME"
    STANDBY_DIR_NAME="$STANDBY_DB_UNIQUE_NAME"
    log_warn "Could not detect DB_UNIQUE_NAME token in path - using DB_UNIQUE_NAME literally"
fi

# Derive matching standby paths for each primary directory.
STANDBY_DATA_PATHS=()
for _p in "${PRIMARY_DATA_PATHS[@]}"; do
    STANDBY_DATA_PATHS+=("$(echo "$_p" | sed "s/${PRIMARY_DIR_NAME}/${STANDBY_DIR_NAME}/g")")
done
STANDBY_DATA_PATH="${STANDBY_DATA_PATHS[0]}"

STANDBY_REDO_PATHS=()
for _p in "${PRIMARY_REDO_PATHS[@]}"; do
    STANDBY_REDO_PATHS+=("$(echo "$_p" | sed "s/${PRIMARY_DIR_NAME}/${STANDBY_DIR_NAME}/g")")
done
STANDBY_REDO_PATH="${STANDBY_REDO_PATHS[0]}"

# ============================================================
# Standby Redo Log (SRL) Path Separation
# ============================================================
# By default, SRLs live in the same directory as online redo logs
# on both databases. Optionally place SRLs on a different filesystem.
# ============================================================
echo ""
echo "By default, standby redo logs (SRLs) live in the same directory"
echo "as online redo logs (ORLs) on both databases:"
echo "  Primary SRLs -> $PRIMARY_REDO_PATH"
echo "  Standby SRLs -> $STANDBY_REDO_PATH"
echo ""
printf "Use a SEPARATE directory for standby redo logs? [y/N]: "
read _separate_srl
_separate_srl=$(echo "$_separate_srl" | tr '[:upper:]' '[:lower:]' | tr -d ' \n\r')

if [[ "$_separate_srl" == "y" || "$_separate_srl" == "yes" ]]; then
    prompt_with_default "Primary SRL directory" "$PRIMARY_REDO_PATH" PRIMARY_SRL_PATH
    _stby_srl_default=$(echo "$PRIMARY_SRL_PATH" | sed "s/${PRIMARY_DIR_NAME}/${STANDBY_DIR_NAME}/g")
    prompt_with_default "Standby SRL directory" "$_stby_srl_default" STANDBY_SRL_PATH

    [[ "$PRIMARY_SRL_PATH" != */ ]] && PRIMARY_SRL_PATH="${PRIMARY_SRL_PATH}/"
    [[ "$STANDBY_SRL_PATH" != */ ]] && STANDBY_SRL_PATH="${STANDBY_SRL_PATH}/"

    log_info "Primary SRL path: $PRIMARY_SRL_PATH"
    log_info "Standby SRL path: $STANDBY_SRL_PATH"
else
    PRIMARY_SRL_PATH="$PRIMARY_REDO_PATH"
    STANDBY_SRL_PATH="$STANDBY_REDO_PATH"
    log_info "SRLs will share the ORL directory on both databases"
fi

# Build FILE_NAME_CONVERT covering EVERY primary directory.
# Convention: pairs are 'primary','standby' repeated. Order doesn't
# matter to Oracle as long as the pair counts are even.
_convert_pairs=""
_seen_pairs=" "  # space-bounded list so we can grep for membership

_emit_pair() {
    local primary="$1" standby="$2" key=" ${primary}=>${standby} "
    [[ -z "$primary" || -z "$standby" ]] && return 0
    case "$_seen_pairs" in
        *"$key"*) return 0 ;;
    esac
    _seen_pairs="${_seen_pairs}${key#? }"
    if [[ -z "$_convert_pairs" ]]; then
        _convert_pairs="'${primary}','${standby}'"
    else
        _convert_pairs="${_convert_pairs},'${primary}','${standby}'"
    fi
}

# Datafile pairs - one per distinct primary datafile directory
_idx=0
for _p in "${PRIMARY_DATA_PATHS[@]}"; do
    _emit_pair "$_p" "${STANDBY_DATA_PATHS[$_idx]}"
    _idx=$((_idx + 1))
done

# Redo log pairs - one per distinct primary redo directory
_idx=0
for _p in "${PRIMARY_REDO_PATHS[@]}"; do
    _emit_pair "$_p" "${STANDBY_REDO_PATHS[$_idx]}"
    _idx=$((_idx + 1))
done

# Separate SRL pair when configured
if [[ "$PRIMARY_SRL_PATH" != "$PRIMARY_REDO_PATH" ]]; then
    _emit_pair "$PRIMARY_SRL_PATH" "$STANDBY_SRL_PATH"
fi

DB_FILE_NAME_CONVERT="$_convert_pairs"
LOG_FILE_NAME_CONVERT="$_convert_pairs"

log_info "Primary data paths:"
for _p in "${PRIMARY_DATA_PATHS[@]}"; do log_info "    $_p"; done
log_info "Standby data paths:"
for _p in "${STANDBY_DATA_PATHS[@]}"; do log_info "    $_p"; done
log_info "Primary redo paths:"
for _p in "${PRIMARY_REDO_PATHS[@]}"; do log_info "    $_p"; done
log_info "Standby redo paths:"
for _p in "${STANDBY_REDO_PATHS[@]}"; do log_info "    $_p"; done
log_info "Primary SRL path:  $PRIMARY_SRL_PATH"
log_info "Standby SRL path:  $STANDBY_SRL_PATH"

fi  # end STANDBY_STORAGE_MODE check

# ============================================================
# Generate TNS Aliases
# ============================================================

progress_step "Generating TNS Configuration"

# Use domain-qualified aliases if DB_DOMAIN is set
# This handles NAMES.DEFAULT_DOMAIN in sqlnet.ora
if [[ -n "$DB_DOMAIN" ]]; then
    PRIMARY_TNS_ALIAS="${DB_UNIQUE_NAME}.${DB_DOMAIN}"
    STANDBY_TNS_ALIAS="${STANDBY_DB_UNIQUE_NAME}.${DB_DOMAIN}"
    log_info "Using domain-qualified TNS aliases (DB_DOMAIN: $DB_DOMAIN)"
else
    PRIMARY_TNS_ALIAS="${DB_UNIQUE_NAME}"
    STANDBY_TNS_ALIAS="${STANDBY_DB_UNIQUE_NAME}"
fi

log_info "Primary TNS alias: $PRIMARY_TNS_ALIAS"
log_info "Standby TNS alias: $STANDBY_TNS_ALIAS"

# ============================================================
# Generate Admin Directories
# ============================================================

progress_step "Generating Admin Directories"

# Assume same ORACLE_BASE structure on standby
STANDBY_ORACLE_BASE="$PRIMARY_ORACLE_BASE"
STANDBY_ORACLE_HOME="$PRIMARY_ORACLE_HOME"

STANDBY_ADMIN_DIR="${STANDBY_ORACLE_BASE}/admin/${STANDBY_DB_UNIQUE_NAME}"

log_info "Standby admin directory: $STANDBY_ADMIN_DIR"

# ============================================================
# Calculate Standby Redo Log Groups
# ============================================================

RECOMMENDED_STBY_GROUPS=$((ONLINE_REDO_GROUPS + 1))

log_info "Online redo groups: $ONLINE_REDO_GROUPS"
log_info "Recommended standby redo groups: $RECOMMENDED_STBY_GROUPS"

# ============================================================
# Write Standby Configuration File
# ============================================================

progress_step "Writing Standby Configuration Files"

# Use STANDBY_DB_UNIQUE_NAME in filename to support concurrent builds
STANDBY_CONFIG_FILE="${NFS_SHARE}/standby_config_${STANDBY_DB_UNIQUE_NAME}.env"

cat > "$STANDBY_CONFIG_FILE" <<EOF
# ============================================================
# Oracle Data Guard Standby Configuration
# Generated: $(date)
# Single Source of Truth for Standby Setup
# ============================================================

# --- Primary Database Info ---
PRIMARY_HOSTNAME="$PRIMARY_HOSTNAME"
PRIMARY_DB_NAME="$DB_NAME"
PRIMARY_DB_UNIQUE_NAME="$DB_UNIQUE_NAME"
PRIMARY_ORACLE_SID="$PRIMARY_ORACLE_SID"
PRIMARY_ORACLE_HOME="$PRIMARY_ORACLE_HOME"
PRIMARY_ORACLE_BASE="$PRIMARY_ORACLE_BASE"
PRIMARY_LISTENER_PORT="$LISTENER_PORT"
PRIMARY_TNS_ALIAS="$PRIMARY_TNS_ALIAS"

# --- Standby Database Info ---
STANDBY_HOSTNAME="$STANDBY_HOSTNAME"
STANDBY_DB_NAME="$DB_NAME"
STANDBY_DB_UNIQUE_NAME="$STANDBY_DB_UNIQUE_NAME"
STANDBY_ORACLE_SID="$STANDBY_ORACLE_SID"
STANDBY_ORACLE_HOME="$STANDBY_ORACLE_HOME"
STANDBY_ORACLE_BASE="$STANDBY_ORACLE_BASE"
STANDBY_LISTENER_PORT="$LISTENER_PORT"
STANDBY_TNS_ALIAS="$STANDBY_TNS_ALIAS"

# --- Database Properties ---
DB_DOMAIN="$DB_DOMAIN"
DBID="$DBID"
NLS_CHARACTERSET="$NLS_CHARACTERSET"
DB_BLOCK_SIZE="$DB_BLOCK_SIZE"
COMPATIBLE="$COMPATIBLE"

# --- Storage Mode ---
# TRADITIONAL = path substitution via DB_FILE_NAME_CONVERT / LOG_FILE_NAME_CONVERT
# OMF         = Oracle Managed Files (db_create_file_dest + db_recovery_file_dest)
STANDBY_STORAGE_MODE="$STANDBY_STORAGE_MODE"
# OMF only: base directory for data, redo, and control files (empty in Traditional mode)
STANDBY_DB_CREATE_FILE_DEST="$STANDBY_DB_CREATE_FILE_DEST"

# --- Path Conversions (Traditional mode only) ---
# *_DATA_PATH  = primary/standby's FIRST datafile directory (backward compat)
# *_DATA_PATHS = FULL list of distinct datafile directories (one pair
#                per directory is emitted into DB_FILE_NAME_CONVERT so
#                datafiles in multiple directories all map correctly)
# *_REDO_PATH  = primary/standby's FIRST online redo directory
# *_REDO_PATHS = FULL list of distinct online redo directories
# *_SRL_PATH   = where STANDBY redo log files live on each database
#                (defaults to *_REDO_PATH; can be separated for
#                disk/performance isolation - see the SRL Path
#                Separation prompt at step 2)
PRIMARY_DATA_PATH="$PRIMARY_DATA_PATH"
PRIMARY_DATA_PATHS=(
$(printf '    "%s"\n' "${PRIMARY_DATA_PATHS[@]}")
)
STANDBY_DATA_PATH="$STANDBY_DATA_PATH"
STANDBY_DATA_PATHS=(
$(printf '    "%s"\n' "${STANDBY_DATA_PATHS[@]}")
)
PRIMARY_REDO_PATH="$PRIMARY_REDO_PATH"
PRIMARY_REDO_PATHS=(
$(printf '    "%s"\n' "${PRIMARY_REDO_PATHS[@]}")
)
STANDBY_REDO_PATH="$STANDBY_REDO_PATH"
STANDBY_REDO_PATHS=(
$(printf '    "%s"\n' "${STANDBY_REDO_PATHS[@]}")
)
PRIMARY_SRL_PATH="$PRIMARY_SRL_PATH"
STANDBY_SRL_PATH="$STANDBY_SRL_PATH"
DB_FILE_NAME_CONVERT="${DB_FILE_NAME_CONVERT}"
LOG_FILE_NAME_CONVERT="${LOG_FILE_NAME_CONVERT}"

# --- Archive Log Destination ---
# PRIMARY_ARCHIVE_DEST: primary's current log_archive_dest_1 (informational)
# STANDBY_ARCHIVE_DEST: standby's archive dest; empty when standby archives to FRA
PRIMARY_ARCHIVE_DEST="$PRIMARY_ARCHIVE_DEST"
STANDBY_ARCHIVE_DEST="$STANDBY_ARCHIVE_DEST"

# ============================================================
# Fast Recovery Area (FRA)
# ============================================================
# The FRA stores archived redo, flashback logs, and optionally backups.
# There are THREE groups of variables below:
#
#   1. PRIMARY FRA (inherited from primary, informational only)
#   2. STANDBY FRA (what actually gets applied to the standby)
#   3. FLAGS (which side uses the FRA for archiving)
#
# Variable map by storage mode + Q2 archive choice:
#   Traditional + FRA archive:
#     - STANDBY_FRA                      = chosen FRA path
#     - STANDBY_DB_RECOVERY_FILE_DEST    = mirrors STANDBY_FRA
#     - STANDBY_DB_RECOVERY_FILE_DEST_SIZE = chosen FRA size
#     - STANDBY_ARCHIVE_DEST             = (empty)
#     - USE_FRA_FOR_STANDBY              = YES
#     (NOTE: this combination is valid even when primary does NOT use FRA)
#   Traditional + explicit archive dest:
#     - STANDBY_FRA                      = (empty)
#     - STANDBY_DB_RECOVERY_FILE_DEST    = (empty)
#     - STANDBY_ARCHIVE_DEST             = chosen dir
#     - USE_FRA_FOR_STANDBY              = NO
#   OMF (always uses FRA):
#     - STANDBY_DB_RECOVERY_FILE_DEST    = standby FRA path
#     - STANDBY_FRA                      = same as above (mirror)
#     - STANDBY_DB_RECOVERY_FILE_DEST_SIZE = chosen FRA size
#     - USE_FRA_FOR_STANDBY              = YES
# ============================================================

# 1. Primary FRA (informational - inherited from primary at step 1)
DB_RECOVERY_FILE_DEST="$DB_RECOVERY_FILE_DEST"
DB_RECOVERY_FILE_DEST_SIZE="$DB_RECOVERY_FILE_DEST_SIZE"

# 2. Standby FRA (applied to the standby database)
STANDBY_FRA="$STANDBY_FRA"
STANDBY_DB_RECOVERY_FILE_DEST="$STANDBY_DB_RECOVERY_FILE_DEST"
STANDBY_DB_RECOVERY_FILE_DEST_SIZE="$STANDBY_DB_RECOVERY_FILE_DEST_SIZE"

# 3. Flags
USE_FRA_FOR_ARCHIVE="$USE_FRA_FOR_ARCHIVE"   # YES if PRIMARY archives to FRA
USE_FRA_FOR_STANDBY="$USE_FRA_FOR_STANDBY"   # YES if STANDBY will archive to FRA

# ============================================================
# Redo Logs
# ============================================================
# Oracle Data Guard uses two TYPES of redo logs, and BOTH
# databases (primary and standby) get BOTH types so that either
# side can take over after a switchover or failover:
#
#   - Online Redo Logs (ORLs)  : active redo on the PRIMARY role
#   - Standby Redo Logs (SRLs) : receive shipped redo on the
#                                STANDBY role
#
# Counts and sizes below apply to BOTH databases (symmetry is
# required for role transitions). The physical LOCATION of the
# redo log files is NOT set here - it lives in the Path
# Conversions section above:
#   ORL path: PRIMARY_REDO_PATH / STANDBY_REDO_PATH
#   SRL path: PRIMARY_SRL_PATH  / STANDBY_SRL_PATH
# (In OMF mode everything goes under STANDBY_DB_CREATE_FILE_DEST.)
# By default SRL_PATH == REDO_PATH, but SRLs can be placed in a
# separate directory for disk/performance isolation.
#
# ------------------------------------------------------------
# NAMING NOTE - the word "STANDBY" is overloaded:
# ------------------------------------------------------------
#   STANDBY_DB_UNIQUE_NAME, STANDBY_REDO_PATH, STANDBY_FRA, ...
#     -> "STANDBY" means the STANDBY DATABASE (host / instance)
#
#   STANDBY_REDO_GROUPS, STANDBY_REDO_EXISTS
#     -> "STANDBY" means the TYPE of redo log (SRL)
#     -> These values describe BOTH databases, not just the
#        standby side. Think of them as "SRL_GROUPS" /
#        "SRL_EXISTS".
# ------------------------------------------------------------
# ============================================================

# Applies to both databases (same size, same group counts)
REDO_LOG_SIZE_MB="$REDO_LOG_SIZE_MB"            # Group size in MB (both ORLs and SRLs, both DBs)
ONLINE_REDO_GROUPS="$ONLINE_REDO_GROUPS"        # ORL group count (same on primary and standby)
STANDBY_REDO_GROUPS="$RECOMMENDED_STBY_GROUPS"  # SRL group count (same on primary and standby; typically ORL + 1)
STANDBY_REDO_EXISTS="$STANDBY_REDO_EXISTS"      # YES if SRLs already existed on the primary at step 1 (pre-check, not per-database)

# --- Admin Directories ---
STANDBY_ADMIN_DIR="$STANDBY_ADMIN_DIR"

# --- Data Guard Broker ---
# Note: Data Guard parameters (LOG_ARCHIVE_DEST_2, FAL_SERVER, etc.)
# are managed by Data Guard Broker (DGMGRL), not set manually
DG_BROKER_CONFIG_NAME="${DB_NAME}_DG"
EOF

log_info "Standby configuration written to: $STANDBY_CONFIG_FILE"

fi  # end REGENERATE check

# Backward compatibility: older config files may not have SRL paths.
# If unset, default to the ORL path (original behavior).
PRIMARY_SRL_PATH="${PRIMARY_SRL_PATH:-$PRIMARY_REDO_PATH}"
STANDBY_SRL_PATH="${STANDBY_SRL_PATH:-$STANDBY_REDO_PATH}"

# ############################################################
# FILE GENERATION
# ############################################################
# Everything below runs in both normal and regenerate modes.
# All required variables are set at this point, either from
# the prompts (normal) or from the sourced config (regenerate).
# ############################################################

# ============================================================
# Generate Standby Init Parameter File
# ============================================================

log_success "Standby configuration written to: $STANDBY_CONFIG_FILE"
log_section "Generating Standby Init Parameter File"

# Include DB_UNIQUE_NAME in filename to support concurrent builds
STANDBY_PFILE="${NFS_SHARE}/init${STANDBY_ORACLE_SID}_${STANDBY_DB_UNIQUE_NAME}.ora"

cat > "$STANDBY_PFILE" <<EOF
# ============================================================
# Oracle Data Guard Standby Parameter File
# Generated: $(date)
# Database: $STANDBY_DB_UNIQUE_NAME
# ============================================================

# --- Database Identity ---
*.db_name='${DB_NAME}'
*.db_unique_name='${STANDBY_DB_UNIQUE_NAME}'
$(if [[ -n "$DB_DOMAIN" ]]; then echo "*.db_domain='${DB_DOMAIN}'"; fi)

# --- Memory (adjust as needed) ---
*.memory_target=0
*.sga_target=0
*.pga_aggregate_target=0
# Note: Memory parameters will be copied from primary during RMAN duplicate

# --- Processes ---
*.processes=300

$(if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
echo "# --- OMF File Placement ---"
echo "*.db_create_file_dest='${STANDBY_DB_CREATE_FILE_DEST}'"
echo ""
echo "# --- Archive Log Destination ---"
echo "*.log_archive_dest_1='LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${STANDBY_DB_UNIQUE_NAME}'"
echo "*.db_recovery_file_dest='${STANDBY_DB_RECOVERY_FILE_DEST}'"
echo "*.db_recovery_file_dest_size=${STANDBY_DB_RECOVERY_FILE_DEST_SIZE}"
else
echo "# --- Control Files ---"
echo "*.control_files='${STANDBY_DATA_PATH}/control01.ctl','${STANDBY_DATA_PATH}/control02.ctl'"
echo ""
echo "# --- Archive Log Destination (local only) ---"
if [[ "$USE_FRA_FOR_STANDBY" == "YES" ]]; then
echo "*.log_archive_dest_1='LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${STANDBY_DB_UNIQUE_NAME}'"
echo "*.db_recovery_file_dest='${STANDBY_FRA}'"
echo "*.db_recovery_file_dest_size=${DB_RECOVERY_FILE_DEST_SIZE}"
else
echo "*.log_archive_dest_1='LOCATION=${STANDBY_ARCHIVE_DEST} VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${STANDBY_DB_UNIQUE_NAME}'"
fi
echo ""
echo "# --- File Name Conversions ---"
echo "*.db_file_name_convert=${DB_FILE_NAME_CONVERT}"
echo "*.log_file_name_convert=${LOG_FILE_NAME_CONVERT}"
fi)
*.log_archive_dest_state_1=ENABLE
*.log_archive_format='%t_%s_%r.arc'

# --- Standby File Management ---
*.standby_file_management=AUTO

# --- Data Guard Broker ---
# DG Broker will manage LOG_ARCHIVE_DEST_2, FAL_SERVER, LOG_ARCHIVE_CONFIG, etc.
*.dg_broker_start=TRUE

# --- Diagnostic Destinations ---
*.audit_file_dest='${STANDBY_ADMIN_DIR}/adump'
*.diagnostic_dest='${STANDBY_ORACLE_BASE}'

# --- Block Size ---
*.db_block_size=${DB_BLOCK_SIZE}

# --- Compatibility ---
*.compatible='${COMPATIBLE}'

# --- Remote Login ---
*.remote_login_passwordfile=EXCLUSIVE

# --- Local Listener ---
*.local_listener='(ADDRESS=(PROTOCOL=TCP)(HOST=${STANDBY_HOSTNAME})(PORT=${LISTENER_PORT}))'
EOF

log_info "Standby pfile written to: $STANDBY_PFILE"
log_success "Standby pfile written to: $STANDBY_PFILE"

# ============================================================
# Generate TNS Entries
# ============================================================

log_section "Generating TNS Entries"

# Include standby name in filename to support concurrent builds
TNSNAMES_FILE="${NFS_SHARE}/tnsnames_entries_${STANDBY_DB_UNIQUE_NAME}.ora"

# Generate service names (with domain if set)
if [[ -n "$DB_DOMAIN" ]]; then
    PRIMARY_SERVICE_NAME="${DB_UNIQUE_NAME}.${DB_DOMAIN}"
    STANDBY_SERVICE_NAME="${STANDBY_DB_UNIQUE_NAME}.${DB_DOMAIN}"
else
    PRIMARY_SERVICE_NAME="${DB_UNIQUE_NAME}"
    STANDBY_SERVICE_NAME="${STANDBY_DB_UNIQUE_NAME}"
fi

cat > "$TNSNAMES_FILE" <<EOF
# ============================================================
# Oracle Data Guard TNS Entries
# Generated: $(date)
# Add these entries to tnsnames.ora on BOTH primary and standby
# ============================================================
# Note: If NAMES.DEFAULT_DOMAIN is set in sqlnet.ora, Oracle appends
# that domain to any alias without a domain. These entries include
# the domain suffix to ensure consistent resolution.
# ============================================================

${PRIMARY_TNS_ALIAS} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${PRIMARY_HOSTNAME})(PORT = ${LISTENER_PORT}))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${PRIMARY_SERVICE_NAME})
    )
  )

${STANDBY_TNS_ALIAS} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${STANDBY_HOSTNAME})(PORT = ${LISTENER_PORT}))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${STANDBY_SERVICE_NAME})
    )
  )
EOF

log_info "TNS entries written to: $TNSNAMES_FILE"
log_success "TNS entries written to: $TNSNAMES_FILE"

# ============================================================
# Generate Listener Entry for Standby
# ============================================================

log_section "Generating Listener Configuration for Standby"

# Include standby name in filename to support concurrent builds
LISTENER_FILE="${NFS_SHARE}/listener_${STANDBY_DB_UNIQUE_NAME}.ora"

cat > "$LISTENER_FILE" <<EOF
# ============================================================
# Oracle Data Guard Listener Entry for Standby
# Generated: $(date)
# Add this SID_LIST entry to listener.ora on STANDBY server
# Static registration required for RMAN duplicate (DB in NOMOUNT)
# ============================================================

# Add this to your existing SID_LIST_LISTENER or create new:
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = ${STANDBY_SERVICE_NAME})
      (ORACLE_HOME = ${STANDBY_ORACLE_HOME})
      (SID_NAME = ${STANDBY_ORACLE_SID})
    )
    (SID_DESC =
      (GLOBAL_DBNAME = ${STANDBY_DB_UNIQUE_NAME}_DGMGRL${DB_DOMAIN:+.${DB_DOMAIN}})
      (ORACLE_HOME = ${STANDBY_ORACLE_HOME})
      (SID_NAME = ${STANDBY_ORACLE_SID})
    )
  )

# Ensure LISTENER section exists:
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = ${STANDBY_HOSTNAME})(PORT = ${LISTENER_PORT}))
    )
  )
EOF

log_info "Listener entries written to: $LISTENER_FILE"
log_success "Standby listener snippet written to: $LISTENER_FILE"

# ============================================================
# Generate Listener Entry for Primary
# ============================================================

log_section "Generating Listener Configuration for Primary"

# Include primary DB_UNIQUE_NAME in filename
LISTENER_PRIMARY_FILE="${NFS_SHARE}/listener_primary_${DB_UNIQUE_NAME}.ora"

cat > "$LISTENER_PRIMARY_FILE" <<EOF
# ============================================================
# Oracle Data Guard Listener Entry for Primary
# Generated: $(date)
# Add this SID_LIST entry to listener.ora on PRIMARY server
# Static registration ensures connectivity during switchover
# ============================================================

# Add this to your existing SID_LIST_LISTENER or create new:
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = ${PRIMARY_SERVICE_NAME})
      (ORACLE_HOME = ${PRIMARY_ORACLE_HOME})
      (SID_NAME = ${PRIMARY_ORACLE_SID})
    )
    (SID_DESC =
      (GLOBAL_DBNAME = ${DB_UNIQUE_NAME}_DGMGRL${DB_DOMAIN:+.${DB_DOMAIN}})
      (ORACLE_HOME = ${PRIMARY_ORACLE_HOME})
      (SID_NAME = ${PRIMARY_ORACLE_SID})
    )
  )
EOF

log_info "Primary listener entries written to: $LISTENER_PRIMARY_FILE"
log_success "Primary listener snippet written to: $LISTENER_PRIMARY_FILE"

# ============================================================
# Generate Data Guard Broker Configuration Script
# ============================================================

progress_step "Generating Broker Bootstrap Script"

DG_BROKER_CONFIG_NAME="${DB_NAME}_DG"
# Include standby name in filename to support concurrent builds
DGMGRL_SCRIPT="${NFS_SHARE}/configure_broker_${STANDBY_DB_UNIQUE_NAME}.dgmgrl"

cat > "$DGMGRL_SCRIPT" <<EOF
# ============================================================
# Data Guard Broker Configuration Script
# Generated: $(date)
# Run this script using: dgmgrl / @configure_broker.dgmgrl
# ============================================================

# Create the Data Guard Broker configuration
CREATE CONFIGURATION '${DG_BROKER_CONFIG_NAME}' AS PRIMARY DATABASE IS '${DB_UNIQUE_NAME}' CONNECT IDENTIFIER IS '${PRIMARY_TNS_ALIAS}';

# Add the standby database to the configuration
ADD DATABASE '${STANDBY_DB_UNIQUE_NAME}' AS CONNECT IDENTIFIER IS '${STANDBY_TNS_ALIAS}' MAINTAINED AS PHYSICAL;

# Enable the configuration
ENABLE CONFIGURATION;

# Show the configuration status
SHOW CONFIGURATION;

# Show database details
SHOW DATABASE '${DB_UNIQUE_NAME}';
SHOW DATABASE '${STANDBY_DB_UNIQUE_NAME}';
EOF

log_info "DGMGRL script written to: $DGMGRL_SCRIPT"
log_success "DGMGRL script written to: $DGMGRL_SCRIPT"

# ============================================================
# Display Configuration for Review
# ============================================================

progress_step "Reviewing Generated Configuration"

print_status_block "Primary Database" \
    "Hostname" "$PRIMARY_HOSTNAME" \
    "DB_UNIQUE_NAME" "$DB_UNIQUE_NAME" \
    "ORACLE_SID" "$PRIMARY_ORACLE_SID" \
    "TNS Alias" "$PRIMARY_TNS_ALIAS" \
    "Data Path" "$PRIMARY_DATA_PATH"

if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    print_status_block "Standby Database (OMF)" \
        "Hostname" "$STANDBY_HOSTNAME" \
        "DB_UNIQUE_NAME" "$STANDBY_DB_UNIQUE_NAME" \
        "ORACLE_SID" "$STANDBY_ORACLE_SID" \
        "TNS Alias" "$STANDBY_TNS_ALIAS" \
        "Storage Mode" "OMF" \
        "db_create_file_dest" "$STANDBY_DB_CREATE_FILE_DEST" \
        "db_recovery_file_dest" "$STANDBY_DB_RECOVERY_FILE_DEST" \
        "db_recovery_file_dest_size" "$STANDBY_DB_RECOVERY_FILE_DEST_SIZE"

    print_status_block "Key Settings" \
        "File Name Convert" "(not used - OMF mode)" \
        "Redo Log Size" "${REDO_LOG_SIZE_MB} MB" \
        "Standby Redo Groups" "$RECOMMENDED_STBY_GROUPS" \
        "Broker Config" "$DG_BROKER_CONFIG_NAME"
else
    print_status_block "Standby Database" \
        "Hostname" "$STANDBY_HOSTNAME" \
        "DB_UNIQUE_NAME" "$STANDBY_DB_UNIQUE_NAME" \
        "ORACLE_SID" "$STANDBY_ORACLE_SID" \
        "TNS Alias" "$STANDBY_TNS_ALIAS" \
        "Data Path" "$STANDBY_DATA_PATH"

    print_status_block "Key Conversions" \
        "DB_FILE_NAME_CONVERT" "$DB_FILE_NAME_CONVERT" \
        "LOG_FILE_NAME_CONVERT" "$LOG_FILE_NAME_CONVERT" \
        "Redo Log Size" "${REDO_LOG_SIZE_MB} MB" \
        "Standby Redo Groups" "$RECOMMENDED_STBY_GROUPS" \
        "Broker Config" "$DG_BROKER_CONFIG_NAME"
fi

if [[ "$REGENERATE" == "1" ]]; then
    print_list_block "Regenerated Files" \
        "Standby pfile: $STANDBY_PFILE" \
        "TNS entries: $TNSNAMES_FILE" \
        "Standby listener: $LISTENER_FILE" \
        "Primary listener: $LISTENER_PRIMARY_FILE" \
        "DGMGRL script: $DGMGRL_SCRIPT"

    print_summary "SUCCESS" "Files regenerated from $STANDBY_CONFIG_FILE"
else
    print_list_block "Generated Files" \
        "Standby config: $STANDBY_CONFIG_FILE" \
        "Standby pfile: $STANDBY_PFILE" \
        "TNS entries: $TNSNAMES_FILE" \
        "Standby listener: $LISTENER_FILE" \
        "Primary listener: $LISTENER_PRIMARY_FILE" \
        "DGMGRL script: $DGMGRL_SCRIPT"

    # ============================================================
    # User Confirmation
    # ============================================================

    echo ""
    if ! confirm_proceed "Please review the configuration above."; then
        log_warn "User cancelled. Configuration files have been saved for review."
        echo ""
        echo "You can edit the configuration files manually and re-run, or"
        echo "run this script again with different parameters."
        exit 0
    fi

    print_summary "SUCCESS" "Standby configuration generated successfully"
    print_list_block "Next Steps" \
        "On STANDBY, run ./standby/03_setup_standby_env.sh." \
        "On PRIMARY, run ./primary/04_prepare_primary_dg.sh." \
        "Back on STANDBY, run ./standby/05_clone_standby.sh." \
        "On PRIMARY, run ./primary/06_configure_broker.sh." \
        "On either server, run ./standby/07_verify_dataguard.sh."
fi
