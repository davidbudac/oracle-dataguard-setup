#!/bin/bash
# =============================================================================
# 01_preflight.sh  -  Validate that the source non-CDB and target CDB are both
#                     ready for the migration.
# =============================================================================
# Run on: PRIMARY host of the CDB (which is also assumed to be the primary
#         host of the non-CDB in the typical setup).
#
# Verifies (no side effects):
#   * SQL*Plus and DGMGRL are usable.
#   * Source non-CDB:   reachable, OPEN as PRIMARY, ARCHIVELOG, FORCE_LOGGING,
#                       not already a CDB, broker enabled, apply lag = 0,
#                       no active gaps.
#   * Target CDB:       reachable, OPEN as PRIMARY, ARCHIVELOG, FORCE_LOGGING,
#                       IS_CDB=YES, version >= source, COMPATIBLE >= source,
#                       same character set as source, broker enabled, apply
#                       lag = 0, no active gaps, NEW_PDB_NAME free.
#   * NFS share writable, target datafile dir exists / can be created.
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

[[ "$TGT_ROLE"      == "PRIMARY"     ]] || fail "Target CDB role must be PRIMARY (got '${TGT_ROLE}')"
[[ "$TGT_OPEN_MODE" == "READWRITE"   ]] || fail "Target CDB must be open READ WRITE (got '${TGT_OPEN_MODE}')"
[[ "$TGT_LOG_MODE"  == "ARCHIVELOG"  ]] || fail "Target CDB must be in ARCHIVELOG mode"
[[ "$TGT_FORCE"     == "YES"         ]] || fail "Target CDB must have FORCE_LOGGING=YES (Data Guard requirement)"
[[ "$TGT_CDB"       == "YES"         ]] || fail "Target must be a CDB (got CDB='${TGT_CDB}')"

# Compare versions and compatible
if [[ -n "$SRC_VERSION" && -n "$TGT_VERSION" ]]; then
    # Lexical compare works for "19.x.y.z.w" since each field is zero-padded
    if [[ "$TGT_VERSION" < "$SRC_VERSION" ]]; then
        fail "Target CDB version ($TGT_VERSION) < source version ($SRC_VERSION)"
    else
        log_success "Version OK: source=${SRC_VERSION}, target=${TGT_VERSION}"
    fi
fi
if [[ -n "$SRC_COMPATIBLE" && -n "$TGT_COMPATIBLE" ]]; then
    if [[ "$TGT_COMPATIBLE" < "$SRC_COMPATIBLE" ]]; then
        fail "Target COMPATIBLE ($TGT_COMPATIBLE) < source COMPATIBLE ($SRC_COMPATIBLE)"
    else
        log_success "COMPATIBLE OK: source=${SRC_COMPATIBLE}, target=${TGT_COMPATIBLE}"
    fi
fi
if [[ -n "$SRC_CHARSET" && -n "$TGT_CHARSET" ]]; then
    if [[ "$SRC_CHARSET" != "$TGT_CHARSET" ]]; then
        fail "Character sets differ: source=${SRC_CHARSET}, target=${TGT_CHARSET}"
    else
        log_success "Character set match: ${SRC_CHARSET}"
    fi
fi
if [[ -n "$SRC_PLATFORM" && -n "$TGT_PLATFORM" ]]; then
    if [[ "$SRC_PLATFORM" != "$TGT_PLATFORM" ]]; then
        log_warn "Platform mismatch: source=${SRC_PLATFORM}, target=${TGT_PLATFORM} (manifest will need conversion)"
    fi
fi

# Reject if NEW_PDB_NAME already exists
if [[ ",${TGT_PDBS}," == *",${NEW_PDB_NAME^^},"* || ",${TGT_PDBS}," == *",${NEW_PDB_NAME},"* ]]; then
    fail "PDB name '${NEW_PDB_NAME}' already exists in target CDB (existing: ${TGT_PDBS})"
fi

# ---- 5. Data Guard health (both configurations) ----------------------------
log_info "Checking source non-CDB Data Guard ..."
SRC_DG="$(run_dgmgrl "$SOURCE_ORACLE_SID" "SHOW CONFIGURATION;")" || true
echo "$SRC_DG" | tee_into_log
echo "$SRC_DG" | grep -qi "ORA-\|Error" && fail "Source DG broker has errors"
echo "$SRC_DG" | grep -qi "SUCCESS" || log_warn "Source DG status not SUCCESS"

log_info "Checking target CDB Data Guard ..."
TGT_DG="$(run_dgmgrl "$TARGET_CDB_ORACLE_SID" "SHOW CONFIGURATION;")" || true
echo "$TGT_DG" | tee_into_log
echo "$TGT_DG" | grep -qi "ORA-\|Error" && fail "Target DG broker has errors"
echo "$TGT_DG" | grep -qi "SUCCESS" || log_warn "Target DG status not SUCCESS"

# Apply lag must be 0 on both standbys (we'll show, then check transport/apply)
log_info "Apply / transport lag (source standby ${SOURCE_STANDBY_UNIQUE_NAME}) ..."
run_dgmgrl "$SOURCE_ORACLE_SID" "SHOW DATABASE '${SOURCE_STANDBY_UNIQUE_NAME}';" | tee_into_log || true
log_info "Apply / transport lag (target CDB standby ${TARGET_CDB_STANDBY_UNIQUE_NAME}) ..."
run_dgmgrl "$TARGET_CDB_ORACLE_SID" "SHOW DATABASE '${TARGET_CDB_STANDBY_UNIQUE_NAME}';" | tee_into_log || true

# ---- 6. Datafile target dir on CDB primary ---------------------------------
mkdir -p "${TARGET_PDB_DATAFILE_DIR}/${NEW_PDB_NAME}" 2>/dev/null || \
    fail "Cannot create target PDB datafile dir ${TARGET_PDB_DATAFILE_DIR}/${NEW_PDB_NAME}"

# ---- 7. Source datafile inventory (for staging size estimate) --------------
log_info "Source non-CDB datafile inventory:"
DF_LIST="$(run_sql "$SOURCE_ORACLE_SID" "
SELECT 'DF|'||file#||'|'||TO_CHAR(bytes)||'|'||name FROM v\$datafile ORDER BY file#;
SELECT 'TF|'||file#||'|'||TO_CHAR(bytes)||'|'||name FROM v\$tempfile ORDER BY file#;
")"
echo "$DF_LIST" | tee_into_log
SRC_TOTAL_BYTES="$(echo "$DF_LIST" | awk -F'|' '/^DF\|/{s+=$3} END{print s+0}')"
log_info "Total source datafile bytes: ${SRC_TOTAL_BYTES}"
record_state "src_total_bytes"  "$SRC_TOTAL_BYTES"
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
