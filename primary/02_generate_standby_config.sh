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
# Convert-pair builder (shared by NORMAL and REGENERATE modes)
# ============================================================
# Builds DB_FILE_NAME_CONVERT / LOG_FILE_NAME_CONVERT from the four
# path arrays whose NAMES are passed as arguments:
#   $1 = primary data array name    $2 = standby data array name
#   $3 = primary redo array name    $4 = standby redo array name
# Also reads the PRIMARY_SRL_PATH / STANDBY_SRL_PATH /
# PRIMARY_REDO_PATH / STANDBY_REDO_PATH globals for the optional
# separate-SRL pair.
#
# Convention: pairs are 'primary','standby' repeated. ORDER MATTERS:
# Oracle applies the FIRST pair whose primary string prefix-matches a
# filename, so a short path like /u01/oradata listed before
# /u01/oradata2 would shadow it (every /u01/oradata2 file would be
# mis-remapped through the /u01/oradata pair). Pairs are therefore
# sorted by primary-path length DESCENDING (longest, most specific
# first). Each side is also emitted with a single trailing slash
# ('/u01/oradata2/','/stby/data2/') so the prefix match is bounded at
# a path-component boundary and a parent dir can never swallow a
# sibling whose name merely starts with the same characters.
# (standby/03_setup_standby_env.sh's add_convert_standby_dirs strips
# the quotes and mkdir -p's each standby side - trailing slashes are
# harmless there, and Oracle/RMAN accept them in the convert string.)
build_convert_pairs() {
    local _pd_arr="$1"
    local _sd_arr="$2"
    local _pr_arr="$3"
    local _sr_arr="$4"
    local _seen_pairs=" "  # space-bounded list so we can test membership
    _cp_pri=()
    _cp_stby=()

    # Normalize both sides to exactly one trailing slash, dedup, and
    # collect into the parallel _cp_pri/_cp_stby arrays.
    # NOTE: separate `local` statements - declaring on one line as
    # `local a="$1" b="$2" key="...${a}...${b}..."` evaluates ${a}
    # and ${b} BEFORE local assigns them, so key would be empty and
    # the dedup membership check would collapse every pair into one.
    _collect_pair() {
        local primary="$1"
        local standby="$2"
        [[ -z "$primary" || -z "$standby" ]] && return 0
        # "${p%/}/" maps /a -> /a/, /a/ -> /a/, and / -> / unchanged.
        primary="${primary%/}/"
        standby="${standby%/}/"
        local key=" ${primary}=>${standby} "
        case "$_seen_pairs" in
            *"$key"*) return 0 ;;
        esac
        _seen_pairs="${_seen_pairs}${primary}=>${standby} "
        _cp_pri+=("$primary")
        _cp_stby+=("$standby")
    }

    # Walk two index-parallel arrays by NAME (eval indirection keeps
    # this bash 3.2 / AIX compatible - no namerefs).
    _collect_from_arrays() {
        local _pa="$1"
        local _sa="$2"
        local _k=0 _cnt _p _s
        eval "_cnt=\${#${_pa}[@]}"
        while [[ $_k -lt $_cnt ]]; do
            eval "_p=\${${_pa}[$_k]}"
            eval "_s=\${${_sa}[$_k]}"
            _collect_pair "$_p" "$_s"
            _k=$(( _k + 1 ))
        done
    }

    # Datafile pairs, then redo log pairs - one per distinct directory
    _collect_from_arrays "$_pd_arr" "$_sd_arr"
    _collect_from_arrays "$_pr_arr" "$_sr_arr"

    # Separate SRL pair when configured. When the PRIMARY side is NOT
    # separated (PRIMARY_SRL_PATH == PRIMARY_REDO_PATH) no SRL pair is
    # emitted - so a standby-only separation is unreachable: no pair
    # maps anything INTO that standby SRL directory, and SRLs will be
    # created under STANDBY_REDO_PATH via the ordinary redo pair.
    # Detect and warn about that contradiction instead of silently
    # shipping a directory that never gets used.
    if [[ -n "${PRIMARY_SRL_PATH:-}" && "${PRIMARY_SRL_PATH}" != "${PRIMARY_REDO_PATH:-}" ]]; then
        _collect_pair "$PRIMARY_SRL_PATH" "${STANDBY_SRL_PATH:-}"
    elif [[ -n "${STANDBY_SRL_PATH:-}" && "${STANDBY_SRL_PATH}" != "${STANDBY_REDO_PATH:-}" ]]; then
        log_warn "SRL path contradiction: PRIMARY_SRL_PATH equals PRIMARY_REDO_PATH, but"
        log_warn "  STANDBY_SRL_PATH (${STANDBY_SRL_PATH}) differs from STANDBY_REDO_PATH (${STANDBY_REDO_PATH:-})."
        log_warn "  Convert pairs remap primary filenames, and no primary SRL filename is"
        log_warn "  distinguishable from an ORL filename when both share one directory - so"
        log_warn "  no pair can target the standby SRL directory. SRLs will be created under"
        log_warn "  ${STANDBY_REDO_PATH:-} on the standby. To separate SRLs on the standby,"
        log_warn "  set PRIMARY_SRL_PATH to a distinct primary directory as well."
    fi

    # Stable insertion sort by primary-path length DESCENDING (see the
    # ordering rationale in the function header). Pair counts are tiny
    # (a handful of directories), so O(n^2) in pure bash is fine.
    local _n=${#_cp_pri[@]}
    local _i=1 _j _kp _ks
    while [[ $_i -lt $_n ]]; do
        _kp="${_cp_pri[$_i]}"
        _ks="${_cp_stby[$_i]}"
        _j=$(( _i - 1 ))
        while [[ $_j -ge 0 && ${#_cp_pri[$_j]} -lt ${#_kp} ]]; do
            _cp_pri[$(( _j + 1 ))]="${_cp_pri[$_j]}"
            _cp_stby[$(( _j + 1 ))]="${_cp_stby[$_j]}"
            _j=$(( _j - 1 ))
        done
        _cp_pri[$(( _j + 1 ))]="$_kp"
        _cp_stby[$(( _j + 1 ))]="$_ks"
        _i=$(( _i + 1 ))
    done

    # Assemble the quoted, comma-separated convert string
    local _pairs=""
    _i=0
    while [[ $_i -lt $_n ]]; do
        if [[ -z "$_pairs" ]]; then
            _pairs="'${_cp_pri[$_i]}','${_cp_stby[$_i]}'"
        else
            _pairs="${_pairs},'${_cp_pri[$_i]}','${_cp_stby[$_i]}'"
        fi
        _i=$(( _i + 1 ))
    done
    DB_FILE_NAME_CONVERT="$_pairs"
    LOG_FILE_NAME_CONVERT="$_pairs"

    if [[ $_n -gt 20 || ${#_pairs} -gt 2000 ]]; then
        log_warn "DB_FILE_NAME_CONVERT holds ${_n} pairs (${#_pairs} chars). Very long"
        log_warn "  convert strings are fragile (parameter length limits, easy to miss a"
        log_warn "  directory). For many-PDB CDBs consider OMF mode instead (storage mode"
        log_warn "  2 at step 2: db_create_file_dest, no convert strings needed)."
    fi
}

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

# ------------------------------------------------------------
# Re-derive the convert pairs from the (possibly user-edited)
# path arrays. Without this, editing STANDBY_DATA_PATHS in the
# .env and regenerating would silently ship the STALE
# DB_FILE_NAME_CONVERT / LOG_FILE_NAME_CONVERT strings stored at
# generation time into the pfile and RMAN cmdfile.
# ------------------------------------------------------------
_can_rebuild_pairs=0
if [[ -n "${PRIMARY_DATA_PATHS+x}" && -n "${STANDBY_DATA_PATHS+x}" \
   && -n "${PRIMARY_REDO_PATHS+x}" && -n "${STANDBY_REDO_PATHS+x}" ]]; then
    if [[ ${#PRIMARY_DATA_PATHS[@]} -gt 0 \
       && ${#PRIMARY_DATA_PATHS[@]} -eq ${#STANDBY_DATA_PATHS[@]} \
       && ${#PRIMARY_REDO_PATHS[@]} -eq ${#STANDBY_REDO_PATHS[@]} ]]; then
        _can_rebuild_pairs=1
    fi
fi

if [[ "$STANDBY_STORAGE_MODE" == "OMF" ]]; then
    # OMF mode never uses convert pairs - keep them empty as stored.
    :
elif [[ "$_can_rebuild_pairs" == "1" ]]; then
    # Backward compat for pre-SRL configs (same defaulting as below)
    PRIMARY_SRL_PATH="${PRIMARY_SRL_PATH:-$PRIMARY_REDO_PATH}"
    STANDBY_SRL_PATH="${STANDBY_SRL_PATH:-$STANDBY_REDO_PATH}"
    build_convert_pairs PRIMARY_DATA_PATHS STANDBY_DATA_PATHS PRIMARY_REDO_PATHS STANDBY_REDO_PATHS
    log_info "Rebuilt convert pairs from the path arrays in the config:"
    log_info "  DB_FILE_NAME_CONVERT:  $DB_FILE_NAME_CONVERT"
    log_info "  LOG_FILE_NAME_CONVERT: $LOG_FILE_NAME_CONVERT"
else
    log_warn "PRIMARY_*/STANDBY_* path arrays are missing or length-mismatched in"
    log_warn "  $STANDBY_CONFIG_FILE"
    log_warn "  Convert pairs were NOT re-derived - using the stored"
    log_warn "  DB_FILE_NAME_CONVERT / LOG_FILE_NAME_CONVERT strings verbatim."
fi

else

# ============================================================
# NORMAL MODE
# ============================================================

print_banner "Step 2: Generate Standby Config"
init_progress 8

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
# Token remapping helpers (case-aware, substring-safe)
# ============================================================
# Primary file directories normally embed the DB-name as a path
# COMPONENT (e.g. /u01/oradata/DGNONC). The standby equivalent is the
# same path with that component swapped to the standby DB name.
#
# Each path is remapped INDEPENDENTLY: a datafile mount using one case
# (.../DGNONC) and a redo mount using another (.../dgnonc) both remap
# correctly. The previous logic detected a single token from the
# datafile path only and applied it to every path, so a case-mismatched
# redo path came back unchanged and fell to the operator-confirm step.
#
# Replacement is bounded to whole, slash-delimited path components, so a
# token that also appears as a SUBSTRING of a mount name (e.g. token
# PROD inside /prod_archive/) is never corrupted - the old unbounded
# `sed s/tok/rep/g` would have rewritten it.
#
# Defined here (before the storage/archive prompts) because the
# archive-destination default below also uses remap_path_token.
DB_UNIQUE_NAME_UPPER=$(echo "$DB_UNIQUE_NAME" | tr '[:lower:]' '[:upper:]')
DB_UNIQUE_NAME_LOWER=$(echo "$DB_UNIQUE_NAME" | tr '[:upper:]' '[:lower:]')
STANDBY_DIR_NAME_UPPER=$(echo "$STANDBY_DB_UNIQUE_NAME" | tr '[:lower:]' '[:upper:]')
STANDBY_DIR_NAME_LOWER=$(echo "$STANDBY_DB_UNIQUE_NAME" | tr '[:upper:]' '[:lower:]')

# True when $2 occurs as a whole, slash-delimited component of path $1.
# Wrapping in slashes makes the first/last components match the same
# `/token/` pattern as interior ones.
_path_has_component() {
    case "/$1/" in
        *"/$2/"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Echo path $1 with every whole-component occurrence of token $2 swapped
# to $3. Components are slash-delimited, so a token embedded inside a
# larger directory name is left untouched. Two sed passes (interior
# `/tok/`, then a trailing `/tok` at end of string) keep this portable
# to AIX / bash 3.2 - no GNU regex alternation.
_replace_path_component() {
    local _p="$1" _tok="$2" _rep="$3"
    _p=$(printf '%s' "$_p" | sed "s|/${_tok}/|/${_rep}/|g")
    _p=$(printf '%s' "$_p" | sed "s|/${_tok}\$|/${_rep}|")
    printf '%s' "$_p"
}

# Echo the standby path for a primary path by swapping whichever case
# variant of DB_UNIQUE_NAME appears as a path component (upper, then
# lower, then the literal mixed case). A path containing no token
# variant is echoed unchanged so the operator-confirm step below can
# surface it instead of silently mis-mapping it.
remap_path_token() {
    local _p="$1"
    if   _path_has_component "$_p" "$DB_UNIQUE_NAME_UPPER"; then
        _replace_path_component "$_p" "$DB_UNIQUE_NAME_UPPER" "$STANDBY_DIR_NAME_UPPER"
    elif _path_has_component "$_p" "$DB_UNIQUE_NAME_LOWER"; then
        _replace_path_component "$_p" "$DB_UNIQUE_NAME_LOWER" "$STANDBY_DIR_NAME_LOWER"
    elif _path_has_component "$_p" "$DB_UNIQUE_NAME"; then
        _replace_path_component "$_p" "$DB_UNIQUE_NAME" "$STANDBY_DB_UNIQUE_NAME"
    else
        printf '%s' "$_p"
    fi
}

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
            # Component-bounded remap: only a whole /<DB_UNIQUE_NAME>/
            # path component is swapped, so a directory that merely
            # CONTAINS the name (e.g. /arch/PROD_ARCH with DB name PROD)
            # is left intact - the old unbounded sed corrupted it.
            _arch_default=$(remap_path_token "$PRIMARY_ARCHIVE_DEST")
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
# ============================================================
# Per-path token remapping (case-aware, substring-safe)
# ============================================================
# remap_path_token and its helpers are defined above (right after the
# STANDBY_DB_UNIQUE_NAME prompt) because the archive-destination
# default also uses them. Each path below is remapped INDEPENDENTLY.

# Derive matching standby paths for each primary directory.
STANDBY_DATA_PATHS=()
for _p in "${PRIMARY_DATA_PATHS[@]}"; do
    STANDBY_DATA_PATHS+=("$(remap_path_token "$_p")")
done
STANDBY_DATA_PATH="${STANDBY_DATA_PATHS[0]}"

STANDBY_REDO_PATHS=()
for _p in "${PRIMARY_REDO_PATHS[@]}"; do
    STANDBY_REDO_PATHS+=("$(remap_path_token "$_p")")
done
STANDBY_REDO_PATH="${STANDBY_REDO_PATHS[0]}"

# ============================================================
# Confirm / repair any path the token substitution could not remap
# ============================================================
# The substitution above only rewrites paths that contain a case
# variant of DB_UNIQUE_NAME as a path component. Datafiles or - more
# commonly - redo logs that live on a SEPARATE MOUNT without the token
# come back unchanged, which silently points the standby at the
# PRIMARY's directory. That is correct when both hosts share an
# identical mount layout, but wrong when the standby uses a different
# path, and it makes RMAN DUPLICATE fail later (ORA-17502 / ORA-19504)
# because the redo directory never gets created on the standby.
#
# Surface each unmapped path and let the operator confirm (accept the
# identical default) or override it with the correct standby directory.
# Uses eval-based array indirection for bash 3.2 / AIX compatibility.
_confirm_unmapped_paths() {
    # $1 = human label, $2 = primary array name, $3 = standby array name
    local _label="$1" _pri_arr="$2" _stby_arr="$3"
    local _n _i=0 _pri _stby _ans
    eval "_n=\${#${_pri_arr}[@]}"
    while [[ $_i -lt $_n ]]; do
        eval "_pri=\${${_pri_arr}[$_i]}"
        eval "_stby=\${${_stby_arr}[$_i]}"
        if [[ -n "$_pri" && "$_stby" == "$_pri" ]]; then
            echo ""
            log_warn "Standby ${_label} directory could not be auto-derived from: $_pri"
            echo "  This path has no '${DB_UNIQUE_NAME}' directory component (in any"
            echo "  case), so it was left unchanged. If the standby host uses the"
            echo "  SAME path, accept the default. If it differs, enter"
            echo "  the correct standby directory now (RMAN will fail later otherwise)."
            # TTY-gated: with piped stdin (E2E fixed input sequence) no
            # input may be consumed - keep the identical default and rely
            # on the operator editing the .env + --regenerate if needed.
            if [[ -t 0 ]]; then
                prompt_with_default "Standby ${_label} directory for '$_pri'" "$_pri" _ans
                eval "${_stby_arr}[$_i]=\"\$_ans\""
            else
                log_warn "Non-interactive run: keeping the identical path on the standby (edit the .env and run --regenerate to change it)"
            fi
        fi
        _i=$(( _i + 1 ))
    done
}
_confirm_unmapped_paths "datafile" PRIMARY_DATA_PATHS STANDBY_DATA_PATHS
_confirm_unmapped_paths "redo log" PRIMARY_REDO_PATHS STANDBY_REDO_PATHS

# ============================================================
# Interactive mapping review (interactive terminals only)
# ============================================================
# Token remapping handles the symmetric case (same base mount, DB-name
# component swapped). The asymmetric case - the token IS present but
# the standby uses a different base mount entirely, e.g.
# /u01/oradata/PROD -> /oracle/data/STBY - auto-remaps to
# /u01/oradata/STBY without ever surfacing, and previously required
# hand-editing the .env afterwards. Show the operator the full derived
# mapping table and let them correct any entry BEFORE the convert
# pairs and the .env are built, so corrections flow everywhere.
#
# The edit prompt fires ONLY on a real terminal ([[ -t 0 ]]). With
# piped stdin (the E2E suite drives this script with a fixed input
# line sequence) the table is printed for the log and the derived
# defaults are accepted silently - no input is consumed.
_review_path_mappings() {
    local _n_data _n_redo _total _i _idx _pri _stby _num _ans _label
    local _pri_arr _stby_arr
    _n_data=${#PRIMARY_DATA_PATHS[@]}
    _n_redo=${#PRIMARY_REDO_PATHS[@]}
    _total=$(( _n_data + _n_redo ))
    while :; do
        echo ""
        echo "Derived primary -> standby directory mappings:"
        _i=0
        while [[ $_i -lt $_n_data ]]; do
            printf "  %2d) [data] %s -> %s\n" $(( _i + 1 )) \
                "${PRIMARY_DATA_PATHS[$_i]}" "${STANDBY_DATA_PATHS[$_i]}"
            _i=$(( _i + 1 ))
        done
        _i=0
        while [[ $_i -lt $_n_redo ]]; do
            printf "  %2d) [redo] %s -> %s\n" $(( _n_data + _i + 1 )) \
                "${PRIMARY_REDO_PATHS[$_i]}" "${STANDBY_REDO_PATHS[$_i]}"
            _i=$(( _i + 1 ))
        done
        # Non-interactive (piped stdin): table is informational only.
        if [[ ! -t 0 ]]; then
            return 0
        fi
        printf "Accept all mappings [Enter], or enter a number to edit: "
        read _num || _num=""
        _num=$(echo "$_num" | tr -d '[:space:]')
        [[ -z "$_num" ]] && return 0
        case "$_num" in
            *[!0-9]*) echo "Invalid selection: $_num"; continue ;;
        esac
        if [[ "$_num" -lt 1 || "$_num" -gt $_total ]]; then
            echo "Selection out of range (1-${_total})"
            continue
        fi
        if [[ "$_num" -le $_n_data ]]; then
            _label="data"
            _pri_arr=PRIMARY_DATA_PATHS
            _stby_arr=STANDBY_DATA_PATHS
            _idx=$(( _num - 1 ))
        else
            _label="redo"
            _pri_arr=PRIMARY_REDO_PATHS
            _stby_arr=STANDBY_REDO_PATHS
            _idx=$(( _num - _n_data - 1 ))
        fi
        eval "_pri=\${${_pri_arr}[$_idx]}"
        eval "_stby=\${${_stby_arr}[$_idx]}"
        prompt_with_default "New standby ${_label} directory for '$_pri'" "$_stby" _ans
        # Keep the no-trailing-slash convention used by every other path
        [[ "$_ans" != "/" ]] && _ans="${_ans%/}"
        eval "${_stby_arr}[$_idx]=\"\$_ans\""
    done
}
_review_path_mappings

STANDBY_DATA_PATH="${STANDBY_DATA_PATHS[0]}"
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
_separate_srl=$(echo "$_separate_srl" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

if [[ "$_separate_srl" == "y" || "$_separate_srl" == "yes" ]]; then
    prompt_with_default "Primary SRL directory" "$PRIMARY_REDO_PATH" PRIMARY_SRL_PATH
    _stby_srl_default=$(remap_path_token "$PRIMARY_SRL_PATH")
    prompt_with_default "Standby SRL directory" "$_stby_srl_default" STANDBY_SRL_PATH

    # Strip any trailing slash so SRL paths follow the same
    # no-trailing-slash convention as every other directory path.
    # Step 4 and dg_check_srl.sh re-add the slash when they build a
    # member filename, and FILE_NAME_CONVERT prefix-matches either way.
    [[ "$PRIMARY_SRL_PATH" != "/" ]] && PRIMARY_SRL_PATH="${PRIMARY_SRL_PATH%/}"
    [[ "$STANDBY_SRL_PATH" != "/" ]] && STANDBY_SRL_PATH="${STANDBY_SRL_PATH%/}"

    log_info "Primary SRL path: $PRIMARY_SRL_PATH"
    log_info "Standby SRL path: $STANDBY_SRL_PATH"
else
    PRIMARY_SRL_PATH="$PRIMARY_REDO_PATH"
    STANDBY_SRL_PATH="$STANDBY_REDO_PATH"
    log_info "SRLs will share the ORL directory on both databases"
fi

# Build FILE_NAME_CONVERT covering EVERY primary directory (data,
# redo, and the optional separate SRL directory). Pair ORDER matters -
# Oracle uses the first prefix match - so build_convert_pairs (defined
# at the top of this script, shared with --regenerate mode) sorts the
# pairs longest-primary-first and emits trailing slashes on both sides
# to keep prefix matches component-safe.
build_convert_pairs PRIMARY_DATA_PATHS STANDBY_DATA_PATHS PRIMARY_REDO_PATHS STANDBY_REDO_PATHS

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

# Default: same ORACLE_BASE / ORACLE_HOME structure on the standby.
# On a real terminal, let the operator override both (the standby's
# pfile derives audit_file_dest and diagnostic_dest from
# STANDBY_ORACLE_BASE, and the listener snippet uses
# STANDBY_ORACLE_HOME). With piped stdin (E2E suite's fixed input
# sequence) the primary's values are kept silently - no input is read.
STANDBY_ORACLE_BASE="$PRIMARY_ORACLE_BASE"
STANDBY_ORACLE_HOME="$PRIMARY_ORACLE_HOME"
if [[ -t 0 ]]; then
    prompt_with_default "Standby ORACLE_BASE" "$STANDBY_ORACLE_BASE" STANDBY_ORACLE_BASE
    prompt_with_default "Standby ORACLE_HOME" "$STANDBY_ORACLE_HOME" STANDBY_ORACLE_HOME
fi

STANDBY_ADMIN_DIR="${STANDBY_ORACLE_BASE}/admin/${STANDBY_DB_UNIQUE_NAME}"

log_info "Standby admin directory: $STANDBY_ADMIN_DIR"

# ============================================================
# Calculate Standby Redo Log Groups
# ============================================================

if ! is_numeric "${ONLINE_REDO_GROUPS:-}"; then
    log_error "ONLINE_REDO_GROUPS from the primary info file is not numeric: '${ONLINE_REDO_GROUPS:-}' (re-run step 1)"
    exit 1
fi
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
$(if [[ -n "${PRIMARY_DATA_PATH_SIZES_MB+x}" ]] \
   && [[ ${#PRIMARY_DATA_PATH_SIZES_MB[@]} -eq ${#PRIMARY_DATA_PATHS[@]} ]] \
   && [[ ${#STANDBY_DATA_PATHS[@]} -eq ${#PRIMARY_DATA_PATHS[@]} ]]; then
printf '# STANDBY_DATA_PATH_SIZES_MB = required size (MB) per directory,\n'
printf '# index-parallel to STANDBY_DATA_PATHS (values carried over from\n'
printf '# PRIMARY_DATA_PATH_SIZES_MB gathered at step 1; step 3 uses them\n'
printf '# for per-filesystem disk space checks on the standby).\n'
printf 'STANDBY_DATA_PATH_SIZES_MB=(\n'
printf '    "%s"\n' "${PRIMARY_DATA_PATH_SIZES_MB[@]}"
printf ')\n'
fi)
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

# ============================================================
# Control File Multiplexing (Traditional mode only)
# ============================================================
# By default both standby control file copies land in STANDBY_DATA_PATH,
# i.e. on a single filesystem - one mount failure destroys every copy.
# Warn about this, and when running interactively, offer to place the
# second copy on a separate filesystem. Non-interactive runs and config
# files that already set STANDBY_CONTROL_FILE_2_DIR are unaffected -
# default behavior (both copies in STANDBY_DATA_PATH) is unchanged
# unless the user opts in.
if [[ "$STANDBY_STORAGE_MODE" != "OMF" && -z "${STANDBY_CONTROL_FILE_2_DIR:-}" ]]; then
    log_warn "Both standby control file copies will be created in the same directory: $STANDBY_DATA_PATH"
    log_warn "A single filesystem/mount failure could take out every control file copy."
    log_warn "Consider multiplexing control files across separate filesystems."
    if [[ -t 0 ]]; then
        printf "Enter a SEPARATE directory for the second control file copy (blank to keep both in %s): " "$STANDBY_DATA_PATH"
        read -r _control_file_2_dir
        if [[ -n "$_control_file_2_dir" ]]; then
            [[ "$_control_file_2_dir" != "/" ]] && _control_file_2_dir="${_control_file_2_dir%/}"
            STANDBY_CONTROL_FILE_2_DIR="$_control_file_2_dir"
            log_info "Second control file copy will be created in: $STANDBY_CONTROL_FILE_2_DIR"
            printf 'STANDBY_CONTROL_FILE_2_DIR="%s"\n' "$STANDBY_CONTROL_FILE_2_DIR" >> "$STANDBY_CONFIG_FILE"
        fi
    fi
fi

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
echo "*.control_files='${STANDBY_DATA_PATH}/control01.ctl','${STANDBY_CONTROL_FILE_2_DIR:-$STANDBY_DATA_PATH}/control02.ctl'"
echo ""
echo "# --- Archive Log Destination (local only) ---"
if [[ "$USE_FRA_FOR_STANDBY" == "YES" ]]; then
echo "*.log_archive_dest_1='LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${STANDBY_DB_UNIQUE_NAME}'"
echo "*.db_recovery_file_dest='${STANDBY_FRA}'"
echo "*.db_recovery_file_dest_size=${STANDBY_DB_RECOVERY_FILE_DEST_SIZE:-${DB_RECOVERY_FILE_DEST_SIZE}}"
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

# Note: no separate "listener entry for primary" snippet is generated here.
# primary/04_prepare_primary_dg.sh builds the primary's actual listener.ora
# SID_DESC entries itself (via TEMP_SID_DESC/add_sid_to_listener), so a
# standalone listener_primary_*.ora reference file would go unused - unlike
# the standby snippet above, which standby/03_setup_standby_env.sh checks
# for as a precondition gate.

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
        "DGMGRL script: $DGMGRL_SCRIPT"

    print_summary "SUCCESS" "Files regenerated from $STANDBY_CONFIG_FILE"
else
    print_list_block "Generated Files" \
        "Standby config: $STANDBY_CONFIG_FILE" \
        "Standby pfile: $STANDBY_PFILE" \
        "TNS entries: $TNSNAMES_FILE" \
        "Standby listener: $LISTENER_FILE" \
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
