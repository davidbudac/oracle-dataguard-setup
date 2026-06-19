#!/bin/bash
# =============================================================================
# 04_plug_into_cdb.sh  -  Plug the staged non-CDB into the target CDB as a PDB
#                         and run noncdb_to_pdb.sql. The CDB standby applies
#                         this entirely via redo by reading the staged source
#                         files from STANDBY_PDB_SOURCE_FILE_DIRECTORY.
# =============================================================================
# Run on: PRIMARY host of the CDB.
#
# Effects on CDB primary:
#   * Sets STANDBY_PDB_SOURCE_FILE_DIRECTORY (so the standby can re-create
#     the new PDB's files when it applies the redo).
#   * Runs DBMS_PDB.CHECK_PLUG_COMPATIBILITY for diagnostics.
#   * CREATE PLUGGABLE DATABASE <NEW_PDB_NAME> USING '<manifest>'
#         SOURCE_FILE_DIRECTORY = '<staged>'
#         COPY
#         FILE_NAME_CONVERT     = ('<staged>', '<target>')
#   * ALTER PLUGGABLE DATABASE <NEW> OPEN UPGRADE  (required for noncdb_to_pdb.sql)
#   * Runs ?/rdbms/admin/noncdb_to_pdb.sql in the new PDB.
#   * ALTER PLUGGABLE DATABASE <NEW> CLOSE; OPEN READ WRITE;
#   * ALTER PLUGGABLE DATABASE <NEW> SAVE STATE;  (auto-open on startup)
#
# After this script completes, the CDB standby still needs to apply the redo;
# step 05 verifies that.
# =============================================================================

set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

load_config
init_log "04_plug_into_cdb"
trap_err
log_step "04 PLUG ${SOURCE_DB_NAME} INTO ${TARGET_CDB_NAME} AS PDB ${NEW_PDB_NAME}"

# ---- 0. Sanity checks ------------------------------------------------------
if [[ ! -s "$MIGRATE_MANIFEST" ]]; then
    log_error "Manifest not found at ${MIGRATE_MANIFEST}. Run 03_describe_and_stage.sh first."
    exit 1
fi
if [[ ! -d "$MIGRATE_DATAFILE_STAGE" ]] || [[ -z "$(ls -A "$MIGRATE_DATAFILE_STAGE" 2>/dev/null)" ]]; then
    log_error "Staged datafile dir empty: ${MIGRATE_DATAFILE_STAGE}"
    exit 1
fi
TARGET_DIR="${TARGET_PDB_DATAFILE_DIR}/${NEW_PDB_NAME}"
mkdir -p "$TARGET_DIR"

# ---- 1. STANDBY_PDB_SOURCE_FILE_DIRECTORY ----------------------------------
# Tells the CDB standby where to find the original (source) bytes when it
# applies the CREATE PLUGGABLE DATABASE redo. The directory must contain the
# files referenced by the manifest's <fname> entries -- which here are the
# original non-CDB paths. We also point it at the staged copy as a fallback.
#
# In Oracle 19c this parameter accepts a single directory; the standby looks
# there for any file whose original name matches a basename in that dir.
log_info "Setting STANDBY_PDB_SOURCE_FILE_DIRECTORY on the CDB ..."
run_sql "$TARGET_CDB_ORACLE_SID" "
ALTER SYSTEM SET STANDBY_PDB_SOURCE_FILE_DIRECTORY='${MIGRATE_DATAFILE_STAGE}/' SCOPE=BOTH;
" | tee_into_log

# ---- 2. Plug-in compatibility check ----------------------------------------
log_info "Running DBMS_PDB.CHECK_PLUG_COMPATIBILITY ..."
COMPAT_OUT="$(run_sql "$TARGET_CDB_ORACLE_SID" "
SET SERVEROUTPUT ON
DECLARE
    compat BOOLEAN;
BEGIN
    compat := DBMS_PDB.CHECK_PLUG_COMPATIBILITY(
                pdb_descr_file => '${MIGRATE_MANIFEST}',
                pdb_name       => '${NEW_PDB_NAME}');
    DBMS_OUTPUT.PUT_LINE('COMPAT='||CASE WHEN compat THEN 'YES' ELSE 'NO' END);
END;
/
SELECT 'PDB_PLUG_VIOLATION|'||name||'|'||cause||'|'||type||'|'||message
  FROM pdb_plug_in_violations
 WHERE name='${NEW_PDB_NAME}'
   AND status<>'RESOLVED';
")"
echo "$COMPAT_OUT" | tee_into_log

# Non-fatal violations (e.g. APEX, common user warnings) are usually present
# for non-CDB -> PDB. We log them but do not abort: noncdb_to_pdb.sql resolves
# the dictionary-shape ones, and ERROR-type rows are surfaced in step 05.
echo "$COMPAT_OUT" | grep -q "COMPAT=YES" || log_warn "CHECK_PLUG_COMPATIBILITY=NO -- non-fatal for non-CDB plug-in; continuing."

# ---- 3. CREATE PLUGGABLE DATABASE ------------------------------------------
log_info "Creating PDB ${NEW_PDB_NAME} from manifest (COPY into ${TARGET_DIR})"
run_sql "$TARGET_CDB_ORACLE_SID" "
ALTER SESSION SET CONTAINER=CDB\$ROOT;
CREATE PLUGGABLE DATABASE ${NEW_PDB_NAME}
   USING '${MIGRATE_MANIFEST}'
   SOURCE_FILE_DIRECTORY = '${MIGRATE_DATAFILE_STAGE}/'
   COPY
   FILE_NAME_CONVERT = ('${MIGRATE_DATAFILE_STAGE}/', '${TARGET_DIR}/');
" | tee_into_log

# Confirm it's mounted
PDB_STATE="$(sql_scalar "$TARGET_CDB_ORACLE_SID" "
SELECT open_mode FROM v\$pdbs WHERE name=UPPER('${NEW_PDB_NAME}');
")"
log_info "PDB ${NEW_PDB_NAME} state after create: ${PDB_STATE:-<missing>}"
[[ -n "$PDB_STATE" ]] || { log_error "PDB not visible in v\$pdbs"; exit 1; }
record_state "create_pdb_done" "true"

# ---- 4. OPEN UPGRADE and run noncdb_to_pdb.sql -----------------------------
log_info "Opening ${NEW_PDB_NAME} in UPGRADE mode ..."
run_sql "$TARGET_CDB_ORACLE_SID" "
ALTER PLUGGABLE DATABASE ${NEW_PDB_NAME} OPEN UPGRADE;
" | tee_into_log

NONCDB_SQL="${ORACLE_HOME}/rdbms/admin/noncdb_to_pdb.sql"
if [[ ! -f "$NONCDB_SQL" ]]; then
    log_error "Missing ${NONCDB_SQL}"
    exit 1
fi

log_info "Running noncdb_to_pdb.sql inside ${NEW_PDB_NAME} (this can take 10-30 minutes) ..."
NONCDB_LOG="${MIGRATE_LOG_DIR}/noncdb_to_pdb_$(date '+%Y%m%d_%H%M%S').log"
ORACLE_SID="$TARGET_CDB_ORACLE_SID" sqlplus -L / as sysdba <<EOF | tee -a "$NONCDB_LOG" | tee_into_log
SET ECHO ON TIMING ON
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER=${NEW_PDB_NAME};
@${NONCDB_SQL}
EXIT;
EOF

log_info "noncdb_to_pdb.sql output written to ${NONCDB_LOG}"
record_state "noncdb_to_pdb_log" "$NONCDB_LOG"

# ---- 5. Restart the new PDB cleanly ----------------------------------------
log_info "Closing and re-opening ${NEW_PDB_NAME} READ WRITE ..."
run_sql "$TARGET_CDB_ORACLE_SID" "
ALTER PLUGGABLE DATABASE ${NEW_PDB_NAME} CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE ${NEW_PDB_NAME} OPEN READ WRITE;
ALTER PLUGGABLE DATABASE ${NEW_PDB_NAME} SAVE STATE;
" | tee_into_log

# Force log switch so the standby gets apply triggers quickly
log_info "Forcing redo to flow to the CDB standby ..."
run_sql "$TARGET_CDB_ORACLE_SID" "
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM ARCHIVE LOG CURRENT;
" | tee_into_log

# Final state
PDB_STATE="$(sql_scalar "$TARGET_CDB_ORACLE_SID" "
SELECT open_mode FROM v\$pdbs WHERE name=UPPER('${NEW_PDB_NAME}');
")"
log_success "PDB ${NEW_PDB_NAME} on primary is now ${PDB_STATE}"
record_state "plug_done"     "true"
record_state "new_pdb_state" "$PDB_STATE"

log_success "Plug-in complete on the CDB primary."
log_info "Run 05_verify_pdb_dataguard.sh to confirm standby caught up."
log_info "Log file: ${LOG_FILE}"
