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
init_progress 9

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

# Standby Oracle SID (default same as primary)
echo ""
echo "The standby ORACLE_SID usually matches the primary unless you have a naming reason to change it."
prompt_with_default "Standby ORACLE_SID" "$PRIMARY_ORACLE_SID" STANDBY_ORACLE_SID

# ============================================================
# Select Standby Storage Mode
# ============================================================

echo ""
echo "Select the standby storage layout:"
echo ""
echo "  1) Traditional  - Standby uses file paths derived from primary"
echo "                     (DB_FILE_NAME_CONVERT / LOG_FILE_NAME_CONVERT)"
echo "  2) OMF (Oracle Managed Files) - Standby uses db_create_file_dest"
echo "                     and db_recovery_file_dest (no FILE_NAME_CONVERT)"
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

# Initialize OMF-specific variables (empty for Traditional mode)
STANDBY_DB_CREATE_FILE_DEST=""
STANDBY_DB_RECOVERY_FILE_DEST=""
STANDBY_DB_RECOVERY_FILE_DEST_SIZE=""

if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    echo ""
    echo "OMF mode: Oracle will automatically place datafiles, redo logs,"
    echo "and control files under db_create_file_dest."
    echo ""

    prompt_with_default "Standby db_create_file_dest" "" STANDBY_DB_CREATE_FILE_DEST
    if [[ -z "$STANDBY_DB_CREATE_FILE_DEST" ]]; then
        log_error "db_create_file_dest cannot be empty in OMF mode"
        exit 1
    fi

    # Default FRA path: use primary's value if set
    _fra_default=""
    if [[ -n "$DB_RECOVERY_FILE_DEST" ]]; then
        _fra_default="$DB_RECOVERY_FILE_DEST"
    fi
    prompt_with_default "Standby db_recovery_file_dest" "$_fra_default" STANDBY_DB_RECOVERY_FILE_DEST
    if [[ -z "$STANDBY_DB_RECOVERY_FILE_DEST" ]]; then
        log_error "db_recovery_file_dest cannot be empty in OMF mode"
        exit 1
    fi

    # Default size: use primary's value if set
    _fra_size_default="50G"
    if [[ -n "$DB_RECOVERY_FILE_DEST_SIZE" ]]; then
        _fra_size_default="$DB_RECOVERY_FILE_DEST_SIZE"
    fi
    prompt_with_default "Standby db_recovery_file_dest_size" "$_fra_size_default" STANDBY_DB_RECOVERY_FILE_DEST_SIZE

    log_info "OMF db_create_file_dest: $STANDBY_DB_CREATE_FILE_DEST"
    log_info "OMF db_recovery_file_dest: $STANDBY_DB_RECOVERY_FILE_DEST"
    log_info "OMF db_recovery_file_dest_size: $STANDBY_DB_RECOVERY_FILE_DEST_SIZE"
fi

# ============================================================
# Generate Path Conversions
# ============================================================

progress_step "Generating Path Conversions"

if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    # OMF mode: paths are managed by Oracle, no FILE_NAME_CONVERT needed
    # Oracle places all redo logs (ORL and SRL) under db_create_file_dest,
    # so SRL separation is not supported in OMF mode.
    STANDBY_DATA_PATH="${STANDBY_DB_CREATE_FILE_DEST}"
    STANDBY_REDO_PATH="${STANDBY_DB_CREATE_FILE_DEST}"
    PRIMARY_SRL_PATH="${PRIMARY_REDO_PATH}"
    STANDBY_SRL_PATH="${STANDBY_DB_CREATE_FILE_DEST}"
    STANDBY_FRA="${STANDBY_DB_RECOVERY_FILE_DEST}"
    USE_FRA_FOR_STANDBY="YES"
    STANDBY_ARCHIVE_DEST=""
    DB_FILE_NAME_CONVERT=""
    LOG_FILE_NAME_CONVERT=""

    log_info "OMF mode: Oracle will manage file placement"
    log_info "  db_create_file_dest:      $STANDBY_DB_CREATE_FILE_DEST"
    log_info "  db_recovery_file_dest:    $STANDBY_DB_RECOVERY_FILE_DEST"
else
# Detect the actual directory name used in paths (may differ in case from DB_UNIQUE_NAME)
# DB_UNIQUE_NAME might be 'testcdb' but directory might be 'TESTCDB'
PRIMARY_DIR_NAME=""
DB_UNIQUE_NAME_UPPER=$(echo "$DB_UNIQUE_NAME" | tr '[:lower:]' '[:upper:]')
DB_UNIQUE_NAME_LOWER=$(echo "$DB_UNIQUE_NAME" | tr '[:upper:]' '[:lower:]')

# Check for uppercase version in path
if echo "$PRIMARY_DATA_PATH" | grep -q "/${DB_UNIQUE_NAME_UPPER}"; then
    PRIMARY_DIR_NAME="$DB_UNIQUE_NAME_UPPER"
# Check for lowercase version in path
elif echo "$PRIMARY_DATA_PATH" | grep -q "/${DB_UNIQUE_NAME_LOWER}"; then
    PRIMARY_DIR_NAME="$DB_UNIQUE_NAME_LOWER"
# Check for exact match (mixed case)
elif echo "$PRIMARY_DATA_PATH" | grep -q "/${DB_UNIQUE_NAME}/"; then
    PRIMARY_DIR_NAME="$DB_UNIQUE_NAME"
fi

# Generate the standby directory name (preserve case pattern from primary)
if [[ -n "$PRIMARY_DIR_NAME" ]]; then
    # Match the case pattern of the primary
    if [[ "$PRIMARY_DIR_NAME" == "$DB_UNIQUE_NAME_UPPER" ]]; then
        STANDBY_DIR_NAME=$(echo "$STANDBY_DB_UNIQUE_NAME" | tr '[:lower:]' '[:upper:]')
    else
        STANDBY_DIR_NAME="$STANDBY_DB_UNIQUE_NAME"
    fi
    log_info "Primary directory name in path: $PRIMARY_DIR_NAME"
    log_info "Standby directory name for path: $STANDBY_DIR_NAME"
else
    # Fallback: use DB_UNIQUE_NAME as-is
    PRIMARY_DIR_NAME="$DB_UNIQUE_NAME"
    STANDBY_DIR_NAME="$STANDBY_DB_UNIQUE_NAME"
    log_warn "Could not detect directory name case in path, using DB_UNIQUE_NAME directly"
fi

# ============================================================
# Path substitution helper (traditional mode)
# ============================================================
# Replace a primary directory-name segment with the standby
# directory-name segment, anchored by slashes so unrelated
# matches elsewhere in the path are left alone:
#   /u01/app/oracle/oradata/PROD/          -> /u01/app/oracle/oradata/STBY/
#   /u01/app/oracle/oradata/PROD           -> /u01/app/oracle/oradata/STBY
# Uses `|` as the sed delimiter so paths don't collide with the
# delimiter. The $_subst_label argument is used only for warnings
# when the substitution would leave the input unchanged.
# ============================================================
_substitute_dir_name() {
    local input="$1"
    local subst_label="$2"
    local output

    output=$(printf '%s' "$input" | sed \
        -e "s|/${PRIMARY_DIR_NAME}/|/${STANDBY_DIR_NAME}/|g" \
        -e "s|/${PRIMARY_DIR_NAME}\$|/${STANDBY_DIR_NAME}|")

    if [[ "$output" == "$input" && -n "$input" ]]; then
        log_warn "Path substitution for ${subst_label} produced no change: $input"
        log_warn "  Primary '${PRIMARY_DIR_NAME}' not found as a path segment."
        log_warn "  Primary and standby will share this location - edit the"
        log_warn "  generated config (standby_config_*.env) before proceeding."
    fi
    printf '%s' "$output"
}

# Replace primary directory name with standby directory name in paths
STANDBY_DATA_PATH=$(_substitute_dir_name "$PRIMARY_DATA_PATH" "STANDBY_DATA_PATH")
STANDBY_REDO_PATH=$(_substitute_dir_name "$PRIMARY_REDO_PATH" "STANDBY_REDO_PATH")

# ============================================================
# Standby Redo Log (SRL) Path Separation
# ============================================================
# By default, SRLs live in the same directory as online redo logs
# on both databases. You can optionally place SRLs in a separate
# directory (e.g., a different disk) for performance isolation.
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
    # Derive standby SRL default via directory-name substitution
    _stby_srl_default=$(_substitute_dir_name "$PRIMARY_SRL_PATH" "STANDBY_SRL_PATH")
    prompt_with_default "Standby SRL directory" "$_stby_srl_default" STANDBY_SRL_PATH

    # Ensure trailing slash for LOG_FILE_NAME_CONVERT consistency
    [[ "$PRIMARY_SRL_PATH" != */ ]] && PRIMARY_SRL_PATH="${PRIMARY_SRL_PATH}/"
    [[ "$STANDBY_SRL_PATH" != */ ]] && STANDBY_SRL_PATH="${STANDBY_SRL_PATH}/"

    log_info "Primary SRL path: $PRIMARY_SRL_PATH"
    log_info "Standby SRL path: $STANDBY_SRL_PATH"
else
    PRIMARY_SRL_PATH="$PRIMARY_REDO_PATH"
    STANDBY_SRL_PATH="$STANDBY_REDO_PATH"
    log_info "SRLs will share the ORL directory on both databases"
fi

# Handle archive destination - may use FRA
if [[ "$USE_FRA_FOR_ARCHIVE" == "YES" || -z "$PRIMARY_ARCHIVE_DEST" ]]; then
    # Use FRA for archiving on standby
    if [[ -n "$DB_RECOVERY_FILE_DEST" ]]; then
        STANDBY_FRA=$(_substitute_dir_name "$DB_RECOVERY_FILE_DEST" "STANDBY_FRA")
        STANDBY_ARCHIVE_DEST=""  # Will use USE_DB_RECOVERY_FILE_DEST
        USE_FRA_FOR_STANDBY="YES"
        log_info "Standby will use FRA for archive logs: $STANDBY_FRA"
    else
        log_error "FRA is used for archiving but DB_RECOVERY_FILE_DEST is not set"
        log_error "Please configure archive destination manually"
        exit 1
    fi
else
    STANDBY_ARCHIVE_DEST=$(_substitute_dir_name "$PRIMARY_ARCHIVE_DEST" "STANDBY_ARCHIVE_DEST")
    USE_FRA_FOR_STANDBY="NO"
fi

# Generate FILE_NAME_CONVERT parameters
# Always include the ORL path conversion pair
DB_FILE_NAME_CONVERT="'${PRIMARY_DATA_PATH}','${STANDBY_DATA_PATH}'"
LOG_FILE_NAME_CONVERT="'${PRIMARY_REDO_PATH}','${STANDBY_REDO_PATH}'"

# If data and redo are in different paths with DB_UNIQUE_NAME, include both
if [[ "$PRIMARY_DATA_PATH" != "$PRIMARY_REDO_PATH" ]]; then
    DB_FILE_NAME_CONVERT="'${PRIMARY_DATA_PATH}','${STANDBY_DATA_PATH}','${PRIMARY_REDO_PATH}','${STANDBY_REDO_PATH}'"
    LOG_FILE_NAME_CONVERT="'${PRIMARY_DATA_PATH}','${STANDBY_DATA_PATH}','${PRIMARY_REDO_PATH}','${STANDBY_REDO_PATH}'"
fi

# If SRL path differs from ORL path, append the SRL conversion pair so
# RMAN DUPLICATE remaps standby redo logs to the separate directory.
if [[ "$PRIMARY_SRL_PATH" != "$PRIMARY_REDO_PATH" ]]; then
    LOG_FILE_NAME_CONVERT="${LOG_FILE_NAME_CONVERT},'${PRIMARY_SRL_PATH}','${STANDBY_SRL_PATH}'"
    DB_FILE_NAME_CONVERT="${DB_FILE_NAME_CONVERT},'${PRIMARY_SRL_PATH}','${STANDBY_SRL_PATH}'"
fi

log_info "Primary data path: $PRIMARY_DATA_PATH"
log_info "Standby data path: $STANDBY_DATA_PATH"
log_info "Primary redo path: $PRIMARY_REDO_PATH"
log_info "Standby redo path: $STANDBY_REDO_PATH"
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
# Extended Path Parameters (diagnostic_dest, audit_file_dest)
# ============================================================
# These are path-like spfile parameters that live outside the
# DATA / REDO / FRA locations handled above. The primary value
# is read at step 1; offer the user a chance to override each
# one for the standby. Defaults are derived by substituting the
# primary DB_UNIQUE_NAME for the standby DB_UNIQUE_NAME when the
# primary value contains it.
# ============================================================

progress_step "Customizing Extended Path Parameters"

# Substitution names work in both Traditional and OMF modes.
# (PRIMARY_DIR_NAME/STANDBY_DIR_NAME are only set in Traditional
# mode; fall back to DB_UNIQUE_NAME in OMF mode.)
_ext_pri_name="${PRIMARY_DIR_NAME:-$DB_UNIQUE_NAME}"
_ext_stby_name="${STANDBY_DIR_NAME:-$STANDBY_DB_UNIQUE_NAME}"

# Derive a standby default for a path parameter by substituting
# primary DB_UNIQUE_NAME -> standby DB_UNIQUE_NAME. If the primary
# value is empty, return the supplied fallback. Substitution is
# anchored by slashes (or end-of-string) so unrelated substrings
# elsewhere in the path are not rewritten.
_derive_ext_path() {
    local primary_val="$1"
    local fallback="$2"
    local out

    if [[ -z "$primary_val" ]]; then
        printf "%s" "$fallback"
        return
    fi

    out=$(printf '%s' "$primary_val" | sed \
        -e "s|/${_ext_pri_name}/|/${_ext_stby_name}/|g" \
        -e "s|/${_ext_pri_name}\$|/${_ext_stby_name}|")
    printf '%s' "$out"
}

echo ""
echo "The following path parameters will be written to the standby spfile."
echo "Press ENTER to accept each default, or type a new value to override."
echo ""

# --- diagnostic_dest (ADR base) ---
_diag_default=$(_derive_ext_path "$PRIMARY_DIAGNOSTIC_DEST" "$STANDBY_ORACLE_BASE")
if [[ -n "$PRIMARY_DIAGNOSTIC_DEST" ]]; then
    echo "  Primary diagnostic_dest: $PRIMARY_DIAGNOSTIC_DEST"
fi
prompt_with_default "Standby diagnostic_dest" "$_diag_default" STANDBY_DIAGNOSTIC_DEST
if [[ -z "$STANDBY_DIAGNOSTIC_DEST" ]]; then
    log_error "Standby diagnostic_dest cannot be empty"
    exit 1
fi
echo ""

# --- audit_file_dest (audit .aud files) ---
_audit_default=$(_derive_ext_path "$PRIMARY_AUDIT_FILE_DEST" "${STANDBY_ADMIN_DIR}/adump")
if [[ -n "$PRIMARY_AUDIT_FILE_DEST" ]]; then
    echo "  Primary audit_file_dest: $PRIMARY_AUDIT_FILE_DEST"
fi
prompt_with_default "Standby audit_file_dest" "$_audit_default" STANDBY_AUDIT_FILE_DEST
if [[ -z "$STANDBY_AUDIT_FILE_DEST" ]]; then
    log_error "Standby audit_file_dest cannot be empty"
    exit 1
fi

log_info "Standby diagnostic_dest: $STANDBY_DIAGNOSTIC_DEST"
log_info "Standby audit_file_dest: $STANDBY_AUDIT_FILE_DEST"

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
# *_DATA_PATH = where datafiles live on each database
# *_REDO_PATH = where ONLINE redo log files live on each database
# *_SRL_PATH  = where STANDBY redo log files live on each database
#               (defaults to *_REDO_PATH; can be separated for
#                disk/performance isolation - see the SRL Path
#                Separation prompt at step 2)
PRIMARY_DATA_PATH="$PRIMARY_DATA_PATH"
STANDBY_DATA_PATH="$STANDBY_DATA_PATH"
PRIMARY_REDO_PATH="$PRIMARY_REDO_PATH"
STANDBY_REDO_PATH="$STANDBY_REDO_PATH"
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
# Variable map by storage mode:
#   Traditional + FRA archive:
#     - STANDBY_FRA                      = derived from primary path
#     - STANDBY_DB_RECOVERY_FILE_DEST    = (empty, not used)
#     - USE_FRA_FOR_STANDBY              = YES
#   Traditional + explicit archive dest:
#     - STANDBY_FRA                      = (empty)
#     - STANDBY_ARCHIVE_DEST             = set
#     - USE_FRA_FOR_STANDBY              = NO
#   OMF (always uses FRA):
#     - STANDBY_DB_RECOVERY_FILE_DEST    = standby FRA path
#     - STANDBY_FRA                      = same as above (mirror)
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

# --- Database Sizes (inherited from primary at step 1) ---
# Used by the storage summary at end of step 2 and by the disk
# space preflight at step 3.
DATAFILE_SIZE_MB="$DATAFILE_SIZE_MB"
TEMPFILE_SIZE_MB="$TEMPFILE_SIZE_MB"
REDOLOG_SIZE_MB="$REDOLOG_SIZE_MB"
REQUIRED_SPACE_MB="$REQUIRED_SPACE_MB"
STANDBY_REDO_COUNT="$STANDBY_REDO_COUNT"

# --- Admin Directories ---
STANDBY_ADMIN_DIR="$STANDBY_ADMIN_DIR"

# --- Extended Path Parameters ---
# Path-like spfile parameters customizable for the standby.
# Edit and run with --regenerate to update the pfile.
STANDBY_DIAGNOSTIC_DEST="$STANDBY_DIAGNOSTIC_DEST"
STANDBY_AUDIT_FILE_DEST="$STANDBY_AUDIT_FILE_DEST"

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

# Backward compatibility: older config files may not have the extended
# path parameters. Fall back to the values that used to be hardcoded
# in the pfile generation block below.
STANDBY_DIAGNOSTIC_DEST="${STANDBY_DIAGNOSTIC_DEST:-$STANDBY_ORACLE_BASE}"
STANDBY_AUDIT_FILE_DEST="${STANDBY_AUDIT_FILE_DEST:-${STANDBY_ADMIN_DIR}/adump}"

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
*.audit_file_dest='${STANDBY_AUDIT_FILE_DEST}'
*.diagnostic_dest='${STANDBY_DIAGNOSTIC_DEST}'

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

# ============================================================
# Storage Summary
# ============================================================
# Shows what will be stored where, with filesystem info for the
# primary (the host this script runs on) and configured paths
# for the standby (filesystems there are validated at step 3).
# ============================================================

# Helpers (local to this section)
_mb_to_gb() {
    local mb="${1:-0}"
    [[ -z "$mb" || "$mb" == "0" ]] && { printf "0.0"; return; }
    awk -v mb="$mb" 'BEGIN { printf "%.1f", mb/1024 }'
}

# Parse a size value (bytes, or "50G", "200M", etc.) to GB
_size_to_gb() {
    local val="${1:-}"
    [[ -z "$val" ]] && { printf "N/A"; return; }
    awk -v v="$val" 'BEGIN {
        gsub(/[[:space:]]/, "", v)
        if (v == "") { print "N/A"; exit }
        suffix = toupper(substr(v, length(v), 1))
        num = substr(v, 1, length(v) - 1)
        if (suffix == "G")      { printf "%.1f", num }
        else if (suffix == "T") { printf "%.1f", num * 1024 }
        else if (suffix == "M") { printf "%.1f", num / 1024 }
        else if (suffix == "K") { printf "%.1f", num / 1024 / 1024 }
        else if (v ~ /^[0-9]+$/) { printf "%.1f", v / 1073741824 }
        else                    { print "N/A" }
    }'
}

# Look up filesystem mount point for a path (walks up to nearest
# existing parent). Returns "-" if not found.
_fs_mount() {
    local path="${1:-}"
    [[ -z "$path" ]] && { printf "-"; return; }
    while [[ ! -d "$path" && "$path" != "/" ]]; do
        path=$(dirname "$path")
    done
    local fs
    fs=$(df -P "$path" 2>/dev/null | tail -1 | awk '{print $NF}')
    printf "%s" "${fs:--}"
}

echo ""
echo "============================================================"
echo " STORAGE SUMMARY"
echo "============================================================"
echo ""

# ---- Primary: newly added files ----
# The only files the workflow CREATES on the primary are standby
# redo logs (step 4). Everything else (datafiles, ORLs, FRA) is
# pre-existing primary state.
echo " Primary  (newly added files)"
echo " ------------------------------------------------------------"

_pri_srl_path="${PRIMARY_SRL_PATH:-$PRIMARY_REDO_PATH}"
_pri_srl_fs=$(_fs_mount "$_pri_srl_path")

# How many SRLs will actually be added?
if [[ "${STANDBY_REDO_EXISTS:-NO}" == "YES" ]]; then
    _srl_to_add=$(( STANDBY_REDO_GROUPS - ${STANDBY_REDO_COUNT:-0} ))
    [[ $_srl_to_add -lt 0 ]] && _srl_to_add=0
else
    _srl_to_add=$STANDBY_REDO_GROUPS
fi

if [[ $_srl_to_add -gt 0 ]]; then
    _pri_srl_new_mb=$(( REDO_LOG_SIZE_MB * _srl_to_add ))
    _pri_srl_new_gb=$(_mb_to_gb "$_pri_srl_new_mb")
    printf "  %-18s  %-36s  %-12s  %7s GB\n" "Standby Redo Logs" "$_pri_srl_path" "$_pri_srl_fs" "$_pri_srl_new_gb"
    printf "  %-18s  %d group(s) x %d MB each\n" "" "$_srl_to_add" "$REDO_LOG_SIZE_MB"
else
    echo "  (no new files - standby redo logs already provisioned)"
fi

echo ""

# ---- Standby: all files ----
echo " Standby  (all files on the standby database)"
echo " ------------------------------------------------------------"

# Datafiles
_stby_data_gb=$(_mb_to_gb "${DATAFILE_SIZE_MB:-0}")
printf "  %-18s  %-50s  %7s GB\n" "Datafiles" "${STANDBY_DATA_PATH:-N/A}" "$_stby_data_gb"

# Tempfiles (live under data path)
_stby_temp_gb=$(_mb_to_gb "${TEMPFILE_SIZE_MB:-0}")
printf "  %-18s  %-50s  %7s GB\n" "Tempfiles" "${STANDBY_DATA_PATH:-N/A}" "$_stby_temp_gb"

# Online redo logs (size = per-group * group count)
if [[ -n "${REDO_LOG_SIZE_MB:-}" && -n "${ONLINE_REDO_GROUPS:-}" ]]; then
    _stby_orl_mb=$(( REDO_LOG_SIZE_MB * ONLINE_REDO_GROUPS ))
    _stby_orl_gb=$(_mb_to_gb "$_stby_orl_mb")
else
    _stby_orl_gb="N/A"
fi
printf "  %-18s  %-50s  %7s GB\n" "Online Redo Logs" "${STANDBY_REDO_PATH:-N/A}" "$_stby_orl_gb"

# Standby redo logs
_stby_srl_path="${STANDBY_SRL_PATH:-$STANDBY_REDO_PATH}"
if [[ -n "${REDO_LOG_SIZE_MB:-}" && -n "${STANDBY_REDO_GROUPS:-}" ]]; then
    _stby_srl_mb=$(( REDO_LOG_SIZE_MB * STANDBY_REDO_GROUPS ))
    _stby_srl_gb=$(_mb_to_gb "$_stby_srl_mb")
else
    _stby_srl_gb="N/A"
fi
printf "  %-18s  %-50s  %7s GB\n" "Standby Redo Logs" "$_stby_srl_path" "$_stby_srl_gb"

# Archive logs
if [[ "${USE_FRA_FOR_STANDBY:-NO}" == "YES" ]]; then
    printf "  %-18s  %-50s  %7s\n" "Archive Logs" "(routed to FRA)" "-"
else
    printf "  %-18s  %-50s  %7s\n" "Archive Logs" "${STANDBY_ARCHIVE_DEST:-N/A}" "-"
fi

# Fast Recovery Area
# In OMF mode the standby user entered a fresh size; otherwise
# we mirror the primary's db_recovery_file_dest_size.
if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    _fra_size_raw="$STANDBY_DB_RECOVERY_FILE_DEST_SIZE"
else
    _fra_size_raw="$DB_RECOVERY_FILE_DEST_SIZE"
fi
_fra_path="${STANDBY_FRA:-${STANDBY_DB_RECOVERY_FILE_DEST:-N/A}}"
if [[ -n "$_fra_path" && "$_fra_path" != "N/A" ]]; then
    _fra_gb=$(_size_to_gb "$_fra_size_raw")
    printf "  %-18s  %-50s  %7s GB\n" "Fast Recovery Area" "$_fra_path" "$_fra_gb"
fi

# Admin directories (size is minimal / dump files grow slowly)
printf "  %-18s  %-50s  %7s\n" "Admin (dumps)" "${STANDBY_ADMIN_DIR:-N/A}" "-"

# Audit file destination (only shown if set outside the admin dir)
if [[ -n "${STANDBY_AUDIT_FILE_DEST:-}" && "${STANDBY_AUDIT_FILE_DEST}" != "${STANDBY_ADMIN_DIR}/adump" ]]; then
    printf "  %-18s  %-50s  %7s\n" "Audit files" "$STANDBY_AUDIT_FILE_DEST" "-"
fi

# Diagnostic destination (only shown if set outside the Oracle base)
if [[ -n "${STANDBY_DIAGNOSTIC_DEST:-}" && "${STANDBY_DIAGNOSTIC_DEST}" != "${STANDBY_ORACLE_BASE}" ]]; then
    printf "  %-18s  %-50s  %7s\n" "Diagnostic (ADR)" "$STANDBY_DIAGNOSTIC_DEST" "-"
fi

echo " ------------------------------------------------------------"
if [[ -n "${REQUIRED_SPACE_MB:-}" ]]; then
    _required_gb=$(_mb_to_gb "$REQUIRED_SPACE_MB")
    printf "  %-18s  %-50s  %7s GB\n" "Clone footprint" "(datafiles + temp + redo, +20% buffer)" "$_required_gb"
fi
echo ""
echo "  NOTE: Standby filesystems will be validated at step 3."
echo "============================================================"
echo ""

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
