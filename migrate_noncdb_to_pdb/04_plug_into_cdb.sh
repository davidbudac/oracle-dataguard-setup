#!/usr/bin/env bash
# =============================================================================
# 04_plug_into_cdb.sh  -  Plug the staged non-CDB into the target CDB as a PDB
#                         and run noncdb_to_pdb.sql. The CDB standby applies
#                         this entirely via redo by reading the staged source
#                         files from STANDBY_PDB_SOURCE_FILE_DIRECTORY.
# =============================================================================
# Run on: PRIMARY host of the CDB.
#
# Requires steps 01-03 to have completed (state preflight_ok, noncdb_quiesced,
# describe_done) and the standby prerequisites from step 01 (standby_prereq_ok).
# NOT restartable once the PDB exists (ORA-65012): a leftover PDB is detected up
# front and the exit message says how to proceed.
#
# Effects:
#   * Sets STANDBY_PDB_SOURCE_FILE_DIRECTORY ON THE CDB STANDBY (direct
#     connection; ALTER SYSTEM does not travel in redo) and reads it back, so
#     the standby's recovery can find the source files when it applies the
#     plug-in redo. Also set on the primary (ignored there; keeps a
#     post-switchover standby consistent).
#   * Runs DBMS_PDB.CHECK_PLUG_COMPATIBILITY for diagnostics.
#   * CREATE PLUGGABLE DATABASE <NEW_PDB_NAME> USING '<manifest>'
#         SOURCE_FILE_DIRECTORY = '<staged>'
#         COPY
#         FILE_NAME_CONVERT     = ('<staged>', '<target>',
#                                   '<original source dir>', '<target>' ...)
#     (keyed on BOTH the staging dir and the manifest's original directories,
#     then every new datafile name is checked to be under <target> before
#     noncdb_to_pdb.sql runs - see the placement check below.)
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
require_state preflight_ok       01_preflight.sh
require_state noncdb_quiesced    02_quiesce_noncdb.sh
require_state describe_done      03_describe_and_stage.sh
require_state standby_prereq_ok  01_preflight.sh
require_state standby_dirs_ok    01_preflight.sh
clear_state create_pdb_done plug_done new_pdb_state noncdb_to_pdb_log verify_done verify_failures

# Not restartable: the PDB name must be free in the CDB.
EXISTING_PDB="$(sql_scalar "$TARGET_CDB_ORACLE_SID" "SELECT name FROM v\$pdbs WHERE name=UPPER('${NEW_PDB_NAME}');")"
if [[ -n "$EXISTING_PDB" ]]; then
    log_error "PDB ${EXISTING_PDB} already exists in ${TARGET_CDB_NAME} (a previous run of this step, or a name clash)."
    log_error "This step cannot be resumed (CREATE PLUGGABLE DATABASE would fail with ORA-65012). To go on:"
    log_error "  * plug-in finished and you only need to check replication  -> run 05_verify_pdb_dataguard.sh"
    log_error "  * a failed/partial attempt -> drop it, then re-run this step (the non-CDB is still intact, READ ONLY):"
    log_error "      ALTER PLUGGABLE DATABASE ${NEW_PDB_NAME} CLOSE IMMEDIATE;"
    log_error "      DROP PLUGGABLE DATABASE ${NEW_PDB_NAME} INCLUDING DATAFILES;"
    exit 1
fi

if [[ ! -s "$MIGRATE_MANIFEST" ]]; then
    log_error "Manifest not found at ${MIGRATE_MANIFEST}. Run 03_describe_and_stage.sh first."
    exit 1
fi
# The stage must hold exactly the datafiles step 03 recorded.
EXPECTED_STAGED="$(read_state stage_datafile_count)"
ACTUAL_STAGED=0
[[ -d "$MIGRATE_DATAFILE_STAGE" ]] && \
    ACTUAL_STAGED="$(find "$MIGRATE_DATAFILE_STAGE" -type f ! -name '*.part' 2>/dev/null | wc -l | tr -d '[:space:]')"
if [[ ! "$EXPECTED_STAGED" =~ ^[0-9]+$ || "$EXPECTED_STAGED" -eq 0 || "$ACTUAL_STAGED" != "$EXPECTED_STAGED" ]]; then
    log_error "Staged datafile count in ${MIGRATE_DATAFILE_STAGE} is ${ACTUAL_STAGED}; step 03 recorded '${EXPECTED_STAGED}'. Re-run 03_describe_and_stage.sh."
    exit 1
fi
TARGET_DIR="${TARGET_PDB_DATAFILE_DIR}/${NEW_PDB_NAME}"
mkdir -p "$TARGET_DIR"

# ---- 1. STANDBY_PDB_SOURCE_FILE_DIRECTORY ----------------------------------
# Tells the CDB standby where to find the source bytes when it applies the
# CREATE PLUGGABLE DATABASE redo (it looks for each manifest file BY NAME in
# this directory). The parameter is read by the standby's recovery process, so
# it has to be set on the STANDBY instance - ALTER SYSTEM on the primary does
# not travel in redo. The value is the path the STANDBY HOST uses to reach the
# staged files (STANDBY_STAGE_DIR; the primary's staging path by default,
# since the share is mounted identically on both hosts).
log_info "Setting STANDBY_PDB_SOURCE_FILE_DIRECTORY='${STANDBY_STAGE_DIR}/' on the CDB standby (${STANDBY_TNS_ALIAS}) ..."
if ! standby_connect_init; then
    log_error "Cannot connect to the CDB standby '${STANDBY_TNS_ALIAS}' (wallet or SYS password). Without the parameter on the standby the plug-in redo cannot be applied there. Refusing to plug."
    exit 1
fi
run_sql_standby "
ALTER SYSTEM SET STANDBY_PDB_SOURCE_FILE_DIRECTORY='${STANDBY_STAGE_DIR}/' SCOPE=BOTH;
" | tee_into_log
STBY_PARAM="$(run_sql_standby "SELECT 'VAL=' || value FROM v\$parameter WHERE name='standby_pdb_source_file_directory';")" || STBY_PARAM=""
STBY_VAL="$(kv_get VAL "$STBY_PARAM")"
if [[ "${STBY_VAL%/}" != "${STANDBY_STAGE_DIR}" ]]; then
    log_error "Read back standby_pdb_source_file_directory='${STBY_VAL}' on the standby, expected '${STANDBY_STAGE_DIR}/'. Refusing to plug."
    exit 1
fi
log_success "Standby standby_pdb_source_file_directory = ${STBY_VAL}"

# Re-assert the other standby parameters now, right before the DDL.
STBY_FAILS=0
fail() { log_error "$*"; STBY_FAILS=$((STBY_FAILS+1)); }
standby_param_prereqs || true
if (( STBY_FAILS > 0 )); then
    log_error "CDB standby prerequisites no longer hold. Refusing to plug."
    exit 1
fi

log_info "Setting STANDBY_PDB_SOURCE_FILE_DIRECTORY on the CDB primary (not read there) ..."
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
 WHERE name=UPPER('${NEW_PDB_NAME}')
   AND status<>'RESOLVED';
")"
echo "$COMPAT_OUT" | tee_into_log

# Non-fatal violations (e.g. APEX, common user warnings) are usually present
# for non-CDB -> PDB. We log them but do not abort: noncdb_to_pdb.sql resolves
# the dictionary-shape ones, and ERROR-type rows are surfaced in step 05.
echo "$COMPAT_OUT" | grep -q "COMPAT=YES" || log_warn "CHECK_PLUG_COMPATIBILITY=NO -- non-fatal for non-CDB plug-in; continuing."

# ---- 3. CREATE PLUGGABLE DATABASE ------------------------------------------
# FILE_NAME_CONVERT keys. With SOURCE_FILE_DIRECTORY the files are FOUND in the
# staging dir by name, but it is not documented (and not lab-confirmed) whether
# FILE_NAME_CONVERT is then matched against the staging path or against the
# manifest's original <path> entries - the lab-tested minimal flow
# (run_minimal.sh) keys on the original directories. Listing both is harmless
# (an unmatched pair is ignored) and correct under either reading; the
# placement check after the CREATE proves where the files actually landed.
CONVERT_PAIRS="'${MIGRATE_DATAFILE_STAGE}/', '${TARGET_DIR}/'"
while IFS= read -r odir; do
    [[ -z "$odir" ]] && continue
    CONVERT_PAIRS="${CONVERT_PAIRS}, '${odir}/', '${TARGET_DIR}/'"
done <<EOF
$(awk '{n=split($0,a,"/"); d=""; for(i=1;i<n;i++) d=d (i>1?"/":"") a[i]; print d}' "${MIGRATE_STAGE_DIR}/datafile_list.txt" | sort -u)
EOF

log_info "Creating PDB ${NEW_PDB_NAME} from manifest (COPY into ${TARGET_DIR})"
log_info "  FILE_NAME_CONVERT = (${CONVERT_PAIRS})"
run_sql "$TARGET_CDB_ORACLE_SID" "
ALTER SESSION SET CONTAINER=CDB\$ROOT;
CREATE PLUGGABLE DATABASE ${NEW_PDB_NAME}
   USING '${MIGRATE_MANIFEST}'
   SOURCE_FILE_DIRECTORY = '${MIGRATE_DATAFILE_STAGE}/'
   COPY
   FILE_NAME_CONVERT = (${CONVERT_PAIRS});
" | tee_into_log

# Confirm it's mounted
PDB_STATE="$(sql_scalar "$TARGET_CDB_ORACLE_SID" "
SELECT open_mode FROM v\$pdbs WHERE name=UPPER('${NEW_PDB_NAME}');
")"
log_info "PDB ${NEW_PDB_NAME} state after create: ${PDB_STATE:-<missing>}"
[[ -n "$PDB_STATE" ]] || { log_error "PDB not visible in v\$pdbs"; exit 1; }

# Placement check: every datafile of the new PDB must have landed under
# TARGET_DIR. If the convert did not match, the files sit somewhere else (OMF
# area, the source directory) and the standby cannot name them either - catch it
# now, before the long noncdb_to_pdb.sql run.
PDB_FILES="$(run_sql "$TARGET_CDB_ORACLE_SID" "
SELECT 'PDBFILE|' || name FROM v\$datafile
 WHERE con_id = (SELECT con_id FROM v\$pdbs WHERE name=UPPER('${NEW_PDB_NAME}'));
")"
echo "$PDB_FILES" | tee_into_log
NORM_TARGET="$(printf '%s/' "$TARGET_DIR" | sed 's#//*#/#g')"
PDB_FILE_COUNT=0; PDB_FILE_BAD=0
while IFS= read -r pf; do
    [[ -z "$pf" ]] && continue
    pf="${pf#PDBFILE|}"
    pf="$(printf '%s' "$pf" | sed 's#//*#/#g')"
    PDB_FILE_COUNT=$((PDB_FILE_COUNT+1))
    if [[ "$pf" != "$NORM_TARGET"* ]]; then
        log_error "  datafile outside ${NORM_TARGET}: ${pf}"
        PDB_FILE_BAD=$((PDB_FILE_BAD+1))
    fi
done <<EOF
$(printf '%s\n' "$PDB_FILES" | grep '^PDBFILE|')
EOF
if (( PDB_FILE_COUNT == 0 || PDB_FILE_BAD > 0 )); then
    log_error "PDB ${NEW_PDB_NAME} datafile placement is not as configured (${PDB_FILE_COUNT} file(s), ${PDB_FILE_BAD} outside ${NORM_TARGET}). Not running noncdb_to_pdb.sql."
    log_error "Drop the PDB (ALTER PLUGGABLE DATABASE ${NEW_PDB_NAME} CLOSE IMMEDIATE; DROP PLUGGABLE DATABASE ${NEW_PDB_NAME} INCLUDING DATAFILES;), fix FILE_NAME_CONVERT / TARGET_PDB_DATAFILE_DIR and re-run."
    exit 1
fi
log_success "All ${PDB_FILE_COUNT} PDB datafile(s) are under ${NORM_TARGET}"
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
