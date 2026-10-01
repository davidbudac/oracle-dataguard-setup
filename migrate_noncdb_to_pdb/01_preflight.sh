#!/usr/bin/env bash
# =============================================================================
# 01_preflight.sh  -  Validate that the source non-CDB and target CDB are both
#                     ready for the migration.
# =============================================================================
# Run on: PRIMARY host of the CDB (which is also assumed to be the primary
#         host of the non-CDB in the typical setup).
#
# Verifies (no database changes; the only side effects are creating the new
# PDB's datafile directory on the primary and, when STANDBY_SSH_TARGET is set,
# on the standby host):
#   * SQL*Plus and DGMGRL are usable.
#   * Source non-CDB:   reachable, OPEN as PRIMARY, ARCHIVELOG, FORCE_LOGGING,
#                       not already a CDB, broker enabled, apply lag = 0,
#                       no active gaps.
#   * Target CDB:       reachable, OPEN as PRIMARY, ARCHIVELOG, FORCE_LOGGING,
#                       IS_CDB=YES, version >= source, COMPATIBLE >= source,
#                       same character set as source, broker enabled, apply
#                       lag = 0, no active gaps, NEW_PDB_NAME free.
#   * NFS share writable, target datafile dir exists / can be created, and
#     both it and the staging area have room for the source datafiles.
#   * CDB STANDBY (direct connection): standby_file_management=AUTO,
#     db_file_name_convert (or OMF) covers the new PDB's directory, that
#     directory exists on the standby host, and the staging dir is visible
#     there. These cannot be checked through the primary.
#
# Re-running this step resets the migration progress flags in state.env
# (quiesce/describe/plug/verify), so no stale flag from an earlier run can
# satisfy a later step's gate.
#
# All output is mirrored to MIGRATE_LOG_DIR.
# =============================================================================

set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

load_config
init_log "01_preflight"
trap_err
log_step "01 PREFLIGHT - non-CDB to PDB migration"

FAIL=0
fail() { log_error "$*"; FAIL=$((FAIL+1)); }

# Start of a migration attempt: drop every progress flag a previous run left.
clear_state preflight_ok noncdb_quiesced quiesce_scn describe_done manifest_path \
    stage_datafile_dir stage_datafile_count stage_total_bytes create_pdb_done \
    plug_done new_pdb_state noncdb_to_pdb_log verify_done verify_failures \
    decommission_done standby_prereq_ok standby_dirs_ok standby_pdb_dir src_dbid

# ---- 1. Tools available ----------------------------------------------------
log_info "Checking sqlplus / dgmgrl ..."
command -v sqlplus >/dev/null || { fail "sqlplus not on PATH ($PATH)"; }
command -v dgmgrl  >/dev/null || { fail "dgmgrl not on PATH ($PATH)"; }

# ---- 2. NFS share writable -------------------------------------------------
log_info "Checking NFS share ${NFS_SHARE} ..."
if ! touch "${MIGRATE_STAGE_DIR}/.write_test" 2>/dev/null; then
    fail "Cannot write to ${MIGRATE_STAGE_DIR}"
else
    rm -f "${MIGRATE_STAGE_DIR}/.write_test"
    log_success "NFS staging dir writable: ${MIGRATE_STAGE_DIR}"
fi
# load_config already refused a missing/unwritable share. What it cannot tell
# is a share that is simply not mounted here (the mountpoint dir is a plain
# local directory): then the staged files never reach the standby.
SHARE_MOUNT="$(df -Pk "$NFS_SHARE" 2>/dev/null | tail -1 | awk '{print $NF}')"
if [[ "$SHARE_MOUNT" == "/" ]]; then
    log_warn "NFS_SHARE ${NFS_SHARE} sits on the root filesystem of this host: either this host IS the NFS server, or the share is NOT mounted. The standby only sees the staged files if it mounts this same export."
fi

# ---- 3. Source non-CDB checks ---------------------------------------------
log_info "Querying source non-CDB (${SOURCE_DB_NAME}, SID=${SOURCE_ORACLE_SID}) ..."
SRC_OUT="$(run_sql "$SOURCE_ORACLE_SID" "
SELECT 'NAME='        || name        FROM v\$database;
SELECT 'OPEN_MODE='   || open_mode   FROM v\$database;
SELECT 'ROLE='        || database_role FROM v\$database;
SELECT 'LOG_MODE='    || log_mode    FROM v\$database;
SELECT 'FORCE_LOG='   || force_logging FROM v\$database;
SELECT 'CDB='         || cdb         FROM v\$database;
SELECT 'CHARSET='     || value\$ FROM sys.props\$ WHERE name='NLS_CHARACTERSET';
SELECT 'VERSION='     || version_full FROM v\$instance;
SELECT 'COMPATIBLE='  || value FROM v\$parameter WHERE name='compatible';
SELECT 'PROTECTION='  || protection_mode FROM v\$database;
SELECT 'GUID='        || dbid FROM v\$database;
SELECT 'PLATFORM='    || platform_name FROM v\$database;
" )" || { fail "Could not query source non-CDB"; SRC_OUT=""; }

echo "$SRC_OUT" | tee_into_log

src() { echo "$SRC_OUT" | awk -F= "/^$1=/{print \$2; exit}" | tr -d '[:space:]'; }
SRC_OPEN_MODE="$(src OPEN_MODE)"
SRC_ROLE="$(src ROLE)"
SRC_LOG_MODE="$(src LOG_MODE)"
SRC_FORCE="$(src FORCE_LOG)"
SRC_CDB="$(src CDB)"
SRC_CHARSET="$(src CHARSET)"
SRC_VERSION="$(src VERSION)"
SRC_COMPATIBLE="$(src COMPATIBLE)"
SRC_PLATFORM="$(src PLATFORM)"
SRC_NAME="$(src NAME)"
SRC_DBID="$(src GUID)"

# SOURCE_ORACLE_SID is only an environment variable: prove it is the database
# the config names before any later step shuts it down.
if [[ -z "$SRC_NAME" ]]; then
    fail "Could not read v\$database.name for SOURCE_ORACLE_SID=${SOURCE_ORACLE_SID}"
elif [[ "$(upper "$SRC_NAME")" != "$(upper "$SOURCE_DB_NAME")" ]]; then
    fail "SOURCE_ORACLE_SID=${SOURCE_ORACLE_SID} is database '${SRC_NAME}', not SOURCE_DB_NAME '${SOURCE_DB_NAME}'"
fi

[[ "$SRC_ROLE"      == "PRIMARY"        ]] || fail "Source role must be PRIMARY (got '${SRC_ROLE}')"
[[ "$SRC_OPEN_MODE" == "READWRITE"      ]] || log_warn "Source open_mode is '${SRC_OPEN_MODE}' (expected READWRITE; will be moved to READ ONLY in step 02)"
[[ "$SRC_LOG_MODE"  == "ARCHIVELOG"     ]] || fail "Source must be in ARCHIVELOG mode"
[[ "$SRC_FORCE"     == "YES"            ]] || log_warn "Source FORCE_LOGGING is '${SRC_FORCE}' (recommended YES)"
[[ "$SRC_CDB"       == "NO"             ]] || fail "Source must be a non-CDB (CDB column = '${SRC_CDB}')"

# ---- 4. Target CDB checks --------------------------------------------------
log_info "Querying target CDB (${TARGET_CDB_NAME}, SID=${TARGET_CDB_ORACLE_SID}) ..."
TGT_OUT="$(run_sql "$TARGET_CDB_ORACLE_SID" "
SELECT 'NAME='        || name        FROM v\$database;
SELECT 'OPEN_MODE='   || open_mode   FROM v\$database;
SELECT 'ROLE='        || database_role FROM v\$database;
SELECT 'LOG_MODE='    || log_mode    FROM v\$database;
SELECT 'FORCE_LOG='   || force_logging FROM v\$database;
SELECT 'CDB='         || cdb         FROM v\$database;
SELECT 'CHARSET='     || value\$ FROM sys.props\$ WHERE name='NLS_CHARACTERSET';
SELECT 'VERSION='     || version_full FROM v\$instance;
SELECT 'COMPATIBLE='  || value FROM v\$parameter WHERE name='compatible';
SELECT 'PROTECTION='  || protection_mode FROM v\$database;
SELECT 'PLATFORM='    || platform_name FROM v\$database;
SELECT 'PDB_NAMES='   || LISTAGG(name,',') WITHIN GROUP (ORDER BY name) FROM v\$pdbs;
" )" || { fail "Could not query target CDB"; TGT_OUT=""; }

echo "$TGT_OUT" | tee_into_log

tgt() { echo "$TGT_OUT" | awk -F= "/^$1=/{print \$2; exit}" | tr -d '[:space:]'; }
TGT_OPEN_MODE="$(tgt OPEN_MODE)"
TGT_ROLE="$(tgt ROLE)"
TGT_LOG_MODE="$(tgt LOG_MODE)"
TGT_FORCE="$(tgt FORCE_LOG)"
TGT_CDB="$(tgt CDB)"
TGT_CHARSET="$(tgt CHARSET)"
TGT_VERSION="$(tgt VERSION)"
TGT_COMPATIBLE="$(tgt COMPATIBLE)"
TGT_PLATFORM="$(tgt PLATFORM)"
TGT_PDBS="$(tgt PDB_NAMES)"
TGT_NAME="$(tgt NAME)"

if [[ -z "$TGT_NAME" ]]; then
    fail "Could not read v\$database.name for TARGET_CDB_ORACLE_SID=${TARGET_CDB_ORACLE_SID}"
elif [[ "$(upper "$TGT_NAME")" != "$(upper "$TARGET_CDB_NAME")" ]]; then
    fail "TARGET_CDB_ORACLE_SID=${TARGET_CDB_ORACLE_SID} is database '${TGT_NAME}', not TARGET_CDB_NAME '${TARGET_CDB_NAME}'"
fi

[[ "$TGT_ROLE"      == "PRIMARY"     ]] || fail "Target CDB role must be PRIMARY (got '${TGT_ROLE}')"
[[ "$TGT_OPEN_MODE" == "READWRITE"   ]] || fail "Target CDB must be open READ WRITE (got '${TGT_OPEN_MODE}')"
[[ "$TGT_LOG_MODE"  == "ARCHIVELOG"  ]] || fail "Target CDB must be in ARCHIVELOG mode"
[[ "$TGT_FORCE"     == "YES"         ]] || fail "Target CDB must have FORCE_LOGGING=YES (Data Guard requirement)"
[[ "$TGT_CDB"       == "YES"         ]] || fail "Target must be a CDB (got CDB='${TGT_CDB}')"

# Compare versions and compatible. Fields are compared as integers (a string
# compare puts 19.3.0.0.0 above 19.21.0.0.0). An unreadable value is a blocker,
# not a skipped check.
if [[ -n "$SRC_VERSION" && -n "$TGT_VERSION" ]]; then
    if [[ "$(version_cmp "$TGT_VERSION" "$SRC_VERSION")" == "-1" ]]; then
        fail "Target CDB version ($TGT_VERSION) < source version ($SRC_VERSION)"
    else
        log_success "Version OK: source=${SRC_VERSION}, target=${TGT_VERSION}"
    fi
else
    fail "Could not determine version_full of source ('${SRC_VERSION}') and/or target ('${TGT_VERSION}')"
fi
if [[ -n "$SRC_COMPATIBLE" && -n "$TGT_COMPATIBLE" ]]; then
    if [[ "$(version_cmp "$TGT_COMPATIBLE" "$SRC_COMPATIBLE")" == "-1" ]]; then
        fail "Target COMPATIBLE ($TGT_COMPATIBLE) < source COMPATIBLE ($SRC_COMPATIBLE)"
    else
        log_success "COMPATIBLE OK: source=${SRC_COMPATIBLE}, target=${TGT_COMPATIBLE}"
    fi
else
    fail "Could not determine COMPATIBLE of source ('${SRC_COMPATIBLE}') and/or target ('${TGT_COMPATIBLE}')"
fi
if [[ -n "$SRC_CHARSET" && -n "$TGT_CHARSET" ]]; then
    if [[ "$SRC_CHARSET" != "$TGT_CHARSET" ]]; then
        fail "Character sets differ: source=${SRC_CHARSET}, target=${TGT_CHARSET}"
    else
        log_success "Character set match: ${SRC_CHARSET}"
    fi
else
    fail "Could not determine NLS_CHARACTERSET of source ('${SRC_CHARSET}') and/or target ('${TGT_CHARSET}')"
fi
if [[ -n "$SRC_PLATFORM" && -n "$TGT_PLATFORM" ]]; then
    if [[ "$SRC_PLATFORM" != "$TGT_PLATFORM" ]]; then
        log_warn "Platform mismatch: source=${SRC_PLATFORM}, target=${TGT_PLATFORM} (manifest will need conversion)"
    fi
fi

# Reject if NEW_PDB_NAME already exists
NEW_PDB_NAME_UC="$(printf '%s' "$NEW_PDB_NAME" | tr '[:lower:]' '[:upper:]')"
if [[ ",${TGT_PDBS}," == *",${NEW_PDB_NAME_UC},"* || ",${TGT_PDBS}," == *",${NEW_PDB_NAME},"* ]]; then
    fail "PDB name '${NEW_PDB_NAME}' already exists in target CDB (existing: ${TGT_PDBS})"
fi

# ---- 5. Data Guard health (both configurations) ----------------------------
log_info "Checking source non-CDB Data Guard ..."
SRC_DG="$(run_dgmgrl "$SOURCE_ORACLE_SID" "SHOW CONFIGURATION;")" || true
echo "$SRC_DG" | tee_into_log
dgmgrl_output_has_error "$SRC_DG" && fail "Source DG broker has errors"
echo "$SRC_DG" | grep -qi "SUCCESS" || log_warn "Source DG status not SUCCESS"

log_info "Checking target CDB Data Guard ..."
TGT_DG="$(run_dgmgrl "$TARGET_CDB_ORACLE_SID" "SHOW CONFIGURATION;")" || true
echo "$TGT_DG" | tee_into_log
dgmgrl_output_has_error "$TGT_DG" && fail "Target DG broker has errors"
echo "$TGT_DG" | grep -qi "SUCCESS" || log_warn "Target DG status not SUCCESS"

# Apply lag must be 0 on both standbys before we call this ready. Previously
# SHOW DATABASE output was printed and discarded here - the banner promised
# "apply lag = 0, no active gaps" but nothing actually checked it.
log_info "Apply / transport lag (source standby ${SOURCE_STANDBY_UNIQUE_NAME}) ..."
SRC_STBY_DG="$(run_dgmgrl "$SOURCE_ORACLE_SID" "SHOW DATABASE '${SOURCE_STANDBY_UNIQUE_NAME}';")" || true
echo "$SRC_STBY_DG" | tee_into_log
SRC_APPLY_LAG=$(echo "$SRC_STBY_DG" | awk -F: '/Apply Lag/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
SRC_TPT_LAG=$(echo "$SRC_STBY_DG" | awk -F: '/Transport Lag/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
if [[ -z "$SRC_APPLY_LAG" || -z "$SRC_TPT_LAG" ]]; then
    fail "Could not parse apply/transport lag for source standby ${SOURCE_STANDBY_UNIQUE_NAME} from broker output"
elif ! echo "$SRC_APPLY_LAG" | grep -qE "^0 second|^00:00:00" || ! echo "$SRC_TPT_LAG" | grep -qE "^0 second|^00:00:00"; then
    fail "Source standby ${SOURCE_STANDBY_UNIQUE_NAME} is not caught up (apply='${SRC_APPLY_LAG}', transport='${SRC_TPT_LAG}')"
else
    log_success "Source standby is caught up (apply=0, transport=0)"
fi

log_info "Apply / transport lag (target CDB standby ${TARGET_CDB_STANDBY_UNIQUE_NAME}) ..."
TGT_STBY_DG="$(run_dgmgrl "$TARGET_CDB_ORACLE_SID" "SHOW DATABASE '${TARGET_CDB_STANDBY_UNIQUE_NAME}';")" || true
echo "$TGT_STBY_DG" | tee_into_log
TGT_APPLY_LAG=$(echo "$TGT_STBY_DG" | awk -F: '/Apply Lag/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
TGT_TPT_LAG=$(echo "$TGT_STBY_DG" | awk -F: '/Transport Lag/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
if [[ -z "$TGT_APPLY_LAG" || -z "$TGT_TPT_LAG" ]]; then
    fail "Could not parse apply/transport lag for target CDB standby ${TARGET_CDB_STANDBY_UNIQUE_NAME} from broker output"
elif ! echo "$TGT_APPLY_LAG" | grep -qE "^0 second|^00:00:00" || ! echo "$TGT_TPT_LAG" | grep -qE "^0 second|^00:00:00"; then
    fail "Target CDB standby ${TARGET_CDB_STANDBY_UNIQUE_NAME} is not caught up (apply='${TGT_APPLY_LAG}', transport='${TGT_TPT_LAG}')"
else
    log_success "Target CDB standby is caught up (apply=0, transport=0)"
fi

# ---- 6. Datafile target dir on CDB primary ---------------------------------
mkdir -p "${TARGET_PDB_DATAFILE_DIR}/${NEW_PDB_NAME}" 2>/dev/null || \
    fail "Cannot create target PDB datafile dir ${TARGET_PDB_DATAFILE_DIR}/${NEW_PDB_NAME}"
[[ -w "${TARGET_PDB_DATAFILE_DIR}/${NEW_PDB_NAME}" ]] || \
    fail "Target PDB datafile dir ${TARGET_PDB_DATAFILE_DIR}/${NEW_PDB_NAME} is not writable"

# ---- 7. Source datafile inventory (for staging size estimate) --------------
log_info "Source non-CDB datafile inventory:"
DF_LIST="$(run_sql "$SOURCE_ORACLE_SID" "
SELECT 'DF|'||file#||'|'||TO_CHAR(bytes)||'|'||name FROM v\$datafile ORDER BY file#;
SELECT 'TF|'||file#||'|'||TO_CHAR(bytes)||'|'||name FROM v\$tempfile ORDER BY file#;
")"
echo "$DF_LIST" | tee_into_log
SRC_TOTAL_BYTES="$(echo "$DF_LIST" | awk -F'|' '/^DF\|/{s+=$3} END{print s+0}')"
log_info "Total source datafile bytes: ${SRC_TOTAL_BYTES}"

# ---- 8. Free space: staged copy + the PDB's own COPY on the primary ---------
# Both copies are made in full (the stage for the standby, the COPY for the
# CDB primary), so the sizes must be proven, not assumed.
if [[ "$SRC_TOTAL_BYTES" =~ ^[0-9]+$ && "$SRC_TOTAL_BYTES" -gt 0 ]]; then
    NEED_KB=$(( (SRC_TOTAL_BYTES + 1023) / 1024 ))
    STAGED_KB="$(du -sk "$MIGRATE_DATAFILE_STAGE" 2>/dev/null | awk '{print $1}')"
    STAGE_NEED_KB=$(( NEED_KB - ${STAGED_KB:-0} )); (( STAGE_NEED_KB > 0 )) || STAGE_NEED_KB=0
    AVAIL_STAGE_KB="$(df_avail_kb "$MIGRATE_DATAFILE_STAGE")"
    AVAIL_TGT_KB="$(df_avail_kb "${TARGET_PDB_DATAFILE_DIR}/${NEW_PDB_NAME}")"
    if [[ ! "$AVAIL_STAGE_KB" =~ ^[0-9]+$ ]]; then
        fail "Could not determine free space on the staging area ${MIGRATE_DATAFILE_STAGE}"
    elif (( AVAIL_STAGE_KB < STAGE_NEED_KB )); then
        fail "Staging area ${MIGRATE_DATAFILE_STAGE} has ${AVAIL_STAGE_KB} KB free, needs ~${STAGE_NEED_KB} KB for the datafile copies"
    else
        log_success "Staging area has room: ${AVAIL_STAGE_KB} KB free, ~${STAGE_NEED_KB} KB needed"
    fi
    if [[ ! "$AVAIL_TGT_KB" =~ ^[0-9]+$ ]]; then
        fail "Could not determine free space under ${TARGET_PDB_DATAFILE_DIR}"
    elif (( AVAIL_TGT_KB < NEED_KB )); then
        fail "${TARGET_PDB_DATAFILE_DIR} has ${AVAIL_TGT_KB} KB free, needs ~${NEED_KB} KB for the PDB's datafiles (CREATE PLUGGABLE DATABASE ... COPY)"
    else
        log_success "Target datafile dir has room: ${AVAIL_TGT_KB} KB free, ~${NEED_KB} KB needed"
    fi
else
    fail "Could not size the source datafiles (got '${SRC_TOTAL_BYTES}')"
    NEED_KB=0
fi

# ---- 9. CDB standby prerequisites (direct connection) -----------------------
# The standby applies CREATE PLUGGABLE DATABASE from redo and needs, on ITS
# side: standby_file_management=AUTO, a way to name the new datafiles
# (db_file_name_convert covering the PDB dir, or OMF), the datafile directory
# on its host, and a view of the staged source files. None of that is visible
# from the primary.
log_info "Checking CDB standby ${TARGET_CDB_STANDBY_UNIQUE_NAME} (alias ${STANDBY_TNS_ALIAS}) ..."
FAIL_BEFORE_STBY=$FAIL
standby_param_prereqs || true
if (( FAIL == FAIL_BEFORE_STBY )); then
    record_state "standby_pdb_dir" "$STBY_PDB_DIR"
    standby_dir_prereqs "$SRC_TOTAL_BYTES"
fi
if (( FAIL == FAIL_BEFORE_STBY )); then
    record_state "standby_prereq_ok" "true"
    record_state "standby_dirs_ok"   "true"
else
    record_state "standby_prereq_ok" "false"
fi

record_state "src_total_bytes"  "$SRC_TOTAL_BYTES"
record_state "src_dbid"         "$SRC_DBID"
record_state "src_charset"      "$SRC_CHARSET"
record_state "src_version"      "$SRC_VERSION"
record_state "tgt_version"      "$TGT_VERSION"
record_state "preflight_ok"     "$([[ $FAIL -eq 0 ]] && echo true || echo false)"

# ---- Wrap up ---------------------------------------------------------------
if (( FAIL > 0 )); then
    log_error "Preflight FAILED with ${FAIL} blocker(s). Fix and re-run."
    exit 1
fi
log_success "Preflight PASSED. Ready for step 02."
log_info "State file: ${MIGRATE_STATE_FILE}"
log_info "Log file:   ${LOG_FILE}"
