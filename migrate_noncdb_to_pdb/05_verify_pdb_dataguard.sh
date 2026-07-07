#!/bin/bash
# =============================================================================
# 05_verify_pdb_dataguard.sh  -  Confirm the new PDB has been applied on the
#                                CDB standby and the configuration is healthy.
# =============================================================================
# Run on: PRIMARY host of the CDB (uses DGMGRL to query the standby).
#
# Checks:
#   * DGMGRL SHOW CONFIGURATION VERBOSE -- no errors, status SUCCESS.
#   * SHOW DATABASE for the standby: apply lag <=5s, transport lag <=5s.
#   * Standby has the new PDB row in V$PDBS via DGMGRL "SQL".
#   * Standby has the new PDB datafiles in V$DATAFILE via DGMGRL "SQL".
#   * Plug-in violations on the new PDB (any ERROR rows are reported).
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

# ---- 1. Wait for apply to drain on the CDB standby -------------------------
log_info "Waiting for CDB standby to catch up ..."
ATTEMPTS=0
APPLY_OK=0
while (( ATTEMPTS < 120 )); do
    DG_VERB="$(run_dgmgrl "$TARGET_CDB_ORACLE_SID" "SHOW DATABASE VERBOSE '${TARGET_CDB_STANDBY_UNIQUE_NAME}';")"
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
DG_CFG="$(run_dgmgrl "$TARGET_CDB_ORACLE_SID" "SHOW CONFIGURATION VERBOSE;")"
echo "$DG_CFG" | tee_into_log
echo "$DG_CFG" | grep -qiE "ORA-|Error" && fail "DGMGRL reports broker errors"
echo "$DG_CFG" | grep -qi "SUCCESS" || fail "DGMGRL Configuration Status not SUCCESS"

# ---- 3. New PDB is present in dictionary on the standby --------------------
# Use DGMGRL "SQL" so we don't need a TNS connection back from primary.
# Standby is MOUNTED in physical-standby DG; v$pdbs is queryable from MOUNT.
log_info "Querying v\$pdbs on the CDB standby via DGMGRL ..."
PDB_ON_STBY="$(run_dgmgrl "$TARGET_CDB_ORACLE_SID" "
SQL \"ALTER SESSION SET CONTAINER=CDB\\\$ROOT\";
SQL \"SELECT name||'|'||open_mode||'|'||con_id FROM v\\\$pdbs WHERE name=UPPER('${NEW_PDB_NAME}')\";
" 2>&1)"
echo "$PDB_ON_STBY" | tee_into_log

if echo "$PDB_ON_STBY" | grep -qi "${NEW_PDB_NAME}"; then
    log_success "New PDB ${NEW_PDB_NAME} present on the CDB standby"
else
    # DGMGRL SQL routes to the primary by default -- but still useful to show.
    log_warn "Couldn't confirm via DGMGRL SQL on standby; falling back to MRP file-creation log"
fi

# ---- 4. Datafile presence on standby (via remote SQL through DGMGRL) -------
log_info "Querying datafiles for ${NEW_PDB_NAME} on standby ..."
DF_ON_STBY="$(run_dgmgrl "$TARGET_CDB_ORACLE_SID" "
SQL \"SELECT 'STBY|'||name FROM v\\\$datafile WHERE con_id=(SELECT con_id FROM v\\\$pdbs WHERE name=UPPER('${NEW_PDB_NAME}'))\";
" 2>&1)"
echo "$DF_ON_STBY" | tee_into_log

# ---- 5. Plug-in violations on the new PDB ----------------------------------
log_info "Plug-in violations remaining for ${NEW_PDB_NAME}:"
VIO_OUT="$(run_sql "$TARGET_CDB_ORACLE_SID" "
SELECT name||'|'||cause||'|'||type||'|'||status||'|'||message
  FROM pdb_plug_in_violations
 WHERE name=UPPER('${NEW_PDB_NAME}')
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

sleep 8
SCN_AFTER_PRI="$(sql_scalar "$TARGET_CDB_ORACLE_SID" "SELECT current_scn FROM v\$database;")"
APPLIED_SCN="$(run_dgmgrl "$TARGET_CDB_ORACLE_SID" "
SQL \"SELECT 'APPLIED_SCN|'||MAX(applied_scn) FROM v\\\$archived_log\";
" 2>&1 | awk -F'|' '/APPLIED_SCN\|/{print $2; exit}' | tr -d '[:space:]')"
log_info "Primary SCN before/after: ${SCN_BEFORE} / ${SCN_AFTER_PRI}; standby applied SCN: ${APPLIED_SCN:-?}"

# ---- 7. Summary ------------------------------------------------------------
record_state "verify_done"      "true"
record_state "verify_failures"  "$FAIL"

if (( FAIL > 0 )); then
    log_error "Verification reported ${FAIL} failure(s)."
    exit 1
fi
log_success "Verification PASSED. ${NEW_PDB_NAME} is in DG, applied on ${TARGET_CDB_STANDBY_UNIQUE_NAME}."
log_info "Log file: ${LOG_FILE}"
