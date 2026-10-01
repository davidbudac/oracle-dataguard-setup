#!/usr/bin/env bash
# =============================================================================
# 05_verify_pdb_dataguard.sh  -  Confirm the new PDB has been applied on the
#                                CDB standby and the configuration is healthy.
# =============================================================================
# Run on: PRIMARY host of the CDB (DGMGRL for the broker view; a direct
#         connection to the standby for everything that must be true THERE).
#
# This step gates the destructive step 06, so it PASSES only when the PDB is
# provably replicated. verify_done=true is written only on full success.
#
# Checks:
#   * DGMGRL SHOW CONFIGURATION VERBOSE -- no errors, status SUCCESS.
#   * SHOW DATABASE for the standby: apply lag 0, transport lag 0.
#   * Direct standby connection (failure to connect = FAIL, not a warning):
#       - the new PDB is in V$PDBS with RECOVERY_STATUS='ENABLED' (a standby
#         that lacked the plug-in files applies the redo with the PDB's
#         recovery DISABLED, and still shows lag 0);
#       - V$DATAFILE rows for the PDB exist, none is an UNNAMEDnnnnn
#         placeholder, and the count equals the primary's.
#   * Plug-in violations on the new PDB (any ERROR rows fail the step).
#   * Round-trip write on the primary, then the standby's applied SCN must
#     reach an SCN taken AFTER that write (which is after the plug-in).
# =============================================================================

set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

load_config
init_log "05_verify_pdb_dataguard"
trap_err
log_step "05 VERIFY ${NEW_PDB_NAME} on CDB Data Guard"

FAIL=0
fail() { log_error "$*"; FAIL=$((FAIL+1)); }

# Step 06 gates on this flag: it must read false until every check below passed.
record_state "verify_done" "false"
require_state plug_done 04_plug_into_cdb.sh

# ---- 1. Wait for apply to drain on the CDB standby -------------------------
log_info "Waiting for CDB standby to catch up ..."
ATTEMPTS=0
APPLY_OK=0
while (( ATTEMPTS < 120 )); do
    # || true: polling loop - a transient broker hiccup should be retried,
    # not abort the whole verification (see run_dgmgrl in _lib.sh, M35).
    DG_VERB="$(run_dgmgrl "$TARGET_CDB_ORACLE_SID" "SHOW DATABASE VERBOSE '${TARGET_CDB_STANDBY_UNIQUE_NAME}';")" || true
    APPLY_LAG=$(echo "$DG_VERB" | awk -F: '/Apply Lag/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
    TPT_LAG=$(  echo "$DG_VERB" | awk -F: '/Transport Lag/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
    log_info "  apply='${APPLY_LAG}' transport='${TPT_LAG}' (attempt $((ATTEMPTS+1)))"
    if echo "$APPLY_LAG" | grep -qE "^0 second|^00:00:00" && \
       echo "$TPT_LAG"   | grep -qE "^0 second|^00:00:00"; then
        APPLY_OK=1
        break
    fi
    sleep 5
    ATTEMPTS=$((ATTEMPTS+1))
done
if (( APPLY_OK == 1 )); then
    log_success "CDB standby fully caught up (apply=0s, transport=0s)"
else
    fail "CDB standby did not reach 0s lag within 10 minutes"
fi

# ---- 2. Configuration health ----------------------------------------------
log_info "DGMGRL SHOW CONFIGURATION VERBOSE:"
DG_CFG="$(run_dgmgrl "$TARGET_CDB_ORACLE_SID" "SHOW CONFIGURATION VERBOSE;")" || true
echo "$DG_CFG" | tee_into_log
dgmgrl_output_has_error "$DG_CFG" && fail "DGMGRL reports broker errors"
echo "$DG_CFG" | grep -qi "SUCCESS" || fail "DGMGRL Configuration Status not SUCCESS"

# ---- 3/4. New PDB + its datafiles + recovery state on the standby -----------
# DGMGRL's "SQL" command only ever runs on the database DGMGRL is connected to
# (the primary here), so the standby is queried through a direct connection
# (run_sql_standby: wallet /@alias, or a prompted SYS password). If that is not
# possible the replication is UNVERIFIED, which is a failure - this step gates
# the drop of the only other complete copy.
log_info "Connecting directly to the CDB standby (${STANDBY_TNS_ALIAS}) to verify ${NEW_PDB_NAME} ..."
PDB_CON_ID=""
if ! standby_connect_init; then
    fail "Could not connect to the CDB standby ${STANDBY_TNS_ALIAS}: ${NEW_PDB_NAME} on the standby is UNVERIFIED (set up the wallet with common/setup_dg_wallet.sh or run interactively to enter the SYS password)."
else
    PDB_ON_STBY="$(run_sql_standby "SELECT 'PDB|'||name||'|'||open_mode||'|'||con_id||'|'||recovery_status FROM v\$pdbs WHERE name=UPPER('${NEW_PDB_NAME}');")" || true
    echo "$PDB_ON_STBY" | tee_into_log
    PDB_ROW="$(printf '%s\n' "$PDB_ON_STBY" | grep '^PDB|' | head -1)" || true
    if [[ -z "$PDB_ROW" ]]; then
        fail "New PDB ${NEW_PDB_NAME} NOT found on the CDB standby ${TARGET_CDB_STANDBY_UNIQUE_NAME}"
    else
        PDB_CON_ID="$(printf '%s' "$PDB_ROW" | awk -F'|' '{gsub(/[[:space:]]/,"",$4); print $4}')"
        PDB_RECOVERY="$(printf '%s' "$PDB_ROW" | awk -F'|' '{gsub(/[[:space:]]/,"",$5); print $5}')"
        log_success "New PDB ${NEW_PDB_NAME} present on the CDB standby (con_id ${PDB_CON_ID}; verified directly on ${TARGET_CDB_STANDBY_UNIQUE_NAME})"
        if [[ "$PDB_RECOVERY" == "ENABLED" ]]; then
            log_success "PDB recovery on the standby is ENABLED"
        else
            fail "PDB ${NEW_PDB_NAME} recovery_status on the standby is '${PDB_RECOVERY:-?}', expected ENABLED - the standby did not get the plug-in files (check STANDBY_PDB_SOURCE_FILE_DIRECTORY and the standby alert log); the PDB is NOT replicated."
        fi
    fi

    if [[ "$PDB_CON_ID" =~ ^[0-9]+$ ]]; then
        log_info "Querying datafiles for ${NEW_PDB_NAME} on standby ..."
        DF_ON_STBY="$(run_sql_standby "SELECT 'STBY|'||file#||'|'||name FROM v\$datafile WHERE con_id=${PDB_CON_ID};")" || true
        echo "$DF_ON_STBY" | tee_into_log
        STBY_DF_ROWS="$(printf '%s\n' "$DF_ON_STBY" | grep '^STBY|' || true)"
        STBY_DF_COUNT=0
        [[ -z "$STBY_DF_ROWS" ]] || STBY_DF_COUNT="$(printf '%s\n' "$STBY_DF_ROWS" | wc -l | tr -d '[:space:]')"
        PRI_DF_COUNT="$(sql_scalar "$TARGET_CDB_ORACLE_SID" "SELECT COUNT(*) FROM v\$datafile WHERE con_id=(SELECT con_id FROM v\$pdbs WHERE name=UPPER('${NEW_PDB_NAME}'));")"
        if (( STBY_DF_COUNT == 0 )); then
            fail "No datafiles found for ${NEW_PDB_NAME} on the CDB standby ${TARGET_CDB_STANDBY_UNIQUE_NAME}"
        elif printf '%s\n' "$STBY_DF_ROWS" | grep -qi 'UNNAMED'; then
            fail "Standby has UNNAMED placeholder datafile(s) for ${NEW_PDB_NAME} (ORA-01274: files were not created on the standby, apply is or will be stuck)"
        elif [[ ! "$PRI_DF_COUNT" =~ ^[0-9]+$ || "$PRI_DF_COUNT" -eq 0 || "$STBY_DF_COUNT" != "$PRI_DF_COUNT" ]]; then
            fail "Datafile count for ${NEW_PDB_NAME} differs: primary=${PRI_DF_COUNT:-?}, standby=${STBY_DF_COUNT}"
        else
            log_success "Standby has all ${STBY_DF_COUNT} datafile(s) of ${NEW_PDB_NAME}, none UNNAMED (primary has ${PRI_DF_COUNT})"
        fi
    fi
fi

# ---- 5. Plug-in violations on the new PDB ----------------------------------
log_info "Plug-in violations remaining for ${NEW_PDB_NAME}:"
VIO_OUT="$(run_sql "$TARGET_CDB_ORACLE_SID" "
SELECT name||'|'||cause||'|'||type||'|'||status||'|'||message
  FROM pdb_plug_in_violations
 WHERE name=UPPER('${NEW_PDB_NAME}')
   AND status<>'RESOLVED'
 ORDER BY type DESC, time;
")"
echo "$VIO_OUT" | tee_into_log
if echo "$VIO_OUT" | awk -F'|' '{print $3}' | grep -q '^ERROR$'; then
    fail "Open ERROR violations remain in pdb_plug_in_violations (see log)"
fi

# ---- 6. Round-trip write test -----------------------------------------------
log_info "Round-trip test: create + drop a small table inside ${NEW_PDB_NAME} on primary, verify redo flows."
SCN_BEFORE="$(sql_scalar "$TARGET_CDB_ORACLE_SID" "SELECT current_scn FROM v\$database;")"
run_sql "$TARGET_CDB_ORACLE_SID" "
ALTER SESSION SET CONTAINER=${NEW_PDB_NAME};
CREATE TABLE migrate_smoke_test (n NUMBER, ts TIMESTAMP);
INSERT INTO migrate_smoke_test VALUES (1, SYSTIMESTAMP);
COMMIT;
DROP TABLE migrate_smoke_test PURGE;
" | tee_into_log
run_sql "$TARGET_CDB_ORACLE_SID" "
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM ARCHIVE LOG CURRENT;
" | tee_into_log

# SCN taken AFTER the smoke-test commit (and therefore after the plug-in and
# noncdb_to_pdb.sql redo, which all precede it): once the standby's applied SCN
# reaches it, the plug-in has been applied there. A bare "current SCN a few
# seconds later" would be the wrong gate - the SCN advances without redo on an
# idle system, so the applied SCN could never catch up with it.
SCN_GATE="$(sql_scalar "$TARGET_CDB_ORACLE_SID" "SELECT current_scn FROM v\$database;")"
run_sql "$TARGET_CDB_ORACLE_SID" "
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM ARCHIVE LOG CURRENT;
" | tee_into_log

# V$ARCHIVED_LOG has no APPLIED_SCN column - that query always failed with
# ORA-00904, swallowed by the 2>&1 capture into a "?" in the log line below.
# V$ARCHIVE_DEST_STATUS, queried on the PRIMARY, reports the last SCN
# applied at each redo transport destination and is the correct source.
APPLIED_SCN=""
ATTEMPTS=0
while (( ATTEMPTS < 24 )); do
    APPLIED_SCN="$(sql_scalar "$TARGET_CDB_ORACLE_SID" "
SELECT applied_scn FROM v\$archive_dest_status
 WHERE db_unique_name = '${TARGET_CDB_STANDBY_UNIQUE_NAME}'
   AND dest_id = (SELECT MIN(dest_id) FROM v\$archive_dest_status WHERE db_unique_name = '${TARGET_CDB_STANDBY_UNIQUE_NAME}');
")" || APPLIED_SCN=""
    if [[ "$APPLIED_SCN" =~ ^[0-9]+$ && "$SCN_GATE" =~ ^[0-9]+$ ]] && (( APPLIED_SCN >= SCN_GATE )); then
        break
    fi
    sleep 5
    ATTEMPTS=$((ATTEMPTS+1))
done
SCN_AFTER_PRI="$(sql_scalar "$TARGET_CDB_ORACLE_SID" "SELECT current_scn FROM v\$database;")"
log_info "Primary SCN before smoke test / gate / now: ${SCN_BEFORE} / ${SCN_GATE} / ${SCN_AFTER_PRI}; standby applied SCN: ${APPLIED_SCN:-?}"
if [[ "$APPLIED_SCN" =~ ^[0-9]+$ && "$SCN_GATE" =~ ^[0-9]+$ ]] && (( APPLIED_SCN >= SCN_GATE )); then
    log_success "Standby applied SCN ${APPLIED_SCN} >= ${SCN_GATE} (everything up to and including the PDB round-trip write is applied)"
else
    fail "Standby applied SCN '${APPLIED_SCN:-?}' did not reach ${SCN_GATE:-?} within 2 minutes - the plug-in redo is not confirmed applied"
fi

# ---- 7. Summary ------------------------------------------------------------
# verify_done is only ever "true" when FAIL==0 - 06_decommission_noncdb.sh
# gates its destructive teardown on this flag, so it is false from the start of
# this step and only flipped here, after every check above (H9b).
record_state "verify_done"      "$([[ $FAIL -eq 0 ]] && echo true || echo false)"
record_state "verify_failures"  "$FAIL"

if (( FAIL > 0 )); then
    log_error "Verification reported ${FAIL} failure(s)."
    exit 1
fi
log_success "Verification PASSED. ${NEW_PDB_NAME} is in DG, applied on ${TARGET_CDB_STANDBY_UNIQUE_NAME}."
log_info "Log file: ${LOG_FILE}"
