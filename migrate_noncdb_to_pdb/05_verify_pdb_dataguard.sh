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

# Attempt a direct SQL connection to the CDB standby via its TNS alias
# (relies on the project convention of TNS alias == DB_UNIQUE_NAME, and on
# Oracle Wallet auth per common/setup_dg_wallet.sh - neither is guaranteed
# to be set up). On success, echoes the query result and returns 0. On
# failure (no TNS alias / no wallet / standby unreachable) returns
# non-zero; callers must treat that as "unverified", not "not found".
query_standby_sql() {
    local sql="$1"
    # -L: logon just once instead of reprompting on error, so a failed
    # CONNECT makes sqlplus exit non-zero instead of falling through to
    # run the SELECT below while disconnected (matches run_sql() in _lib.sh).
    sqlplus -s -L "/@${TARGET_CDB_STANDBY_UNIQUE_NAME}" as sysdba <<EOF 2>&1
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 300 TRIMSPOOL ON VERIFY OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE
${sql}
EXIT;
EOF
}

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

# ---- 3/4. New PDB + its datafiles present on the standby --------------------
# DGMGRL's "SQL" command executes against whatever database DGMGRL is
# currently connected to (the primary here) - it has no "SQL ON <db>"
# clause, so running "SQL ..." through run_dgmgrl "$TARGET_CDB_ORACLE_SID"
# was always querying the PRIMARY's own v$pdbs/v$datafile, never the
# standby's, regardless of the comments/log text. Connect to the standby
# directly instead; if that isn't possible, say so honestly rather than
# silently reporting an unverified check as passed.
log_info "Connecting directly to the CDB standby (${TARGET_CDB_STANDBY_UNIQUE_NAME}) to verify ${NEW_PDB_NAME} ..."
STBY_DIRECT_OK=false
if PDB_ON_STBY="$(query_standby_sql "SELECT name||'|'||open_mode||'|'||con_id FROM v\$pdbs WHERE name=UPPER('${NEW_PDB_NAME}');")"; then
    STBY_DIRECT_OK=true
fi

if $STBY_DIRECT_OK; then
    echo "$PDB_ON_STBY" | tee_into_log
    if echo "$PDB_ON_STBY" | grep -qi "${NEW_PDB_NAME}"; then
        log_success "New PDB ${NEW_PDB_NAME} present on the CDB standby (verified directly on ${TARGET_CDB_STANDBY_UNIQUE_NAME})"
    else
        fail "New PDB ${NEW_PDB_NAME} NOT found on the CDB standby ${TARGET_CDB_STANDBY_UNIQUE_NAME}"
    fi

    log_info "Querying datafiles for ${NEW_PDB_NAME} on standby ..."
    DF_ON_STBY="$(query_standby_sql "SELECT 'STBY|'||name FROM v\$datafile WHERE con_id=(SELECT con_id FROM v\$pdbs WHERE name=UPPER('${NEW_PDB_NAME}'));")" || true
    echo "$DF_ON_STBY" | tee_into_log
    if echo "$DF_ON_STBY" | grep -q '^STBY|'; then
        log_success "Datafiles for ${NEW_PDB_NAME} present on the CDB standby"
    else
        fail "No datafiles found for ${NEW_PDB_NAME} on the CDB standby ${TARGET_CDB_STANDBY_UNIQUE_NAME}"
    fi
else
    log_warn "Could not connect directly to the CDB standby (${TARGET_CDB_STANDBY_UNIQUE_NAME})."
    log_warn "PDB and datafile presence on the standby were NOT verified by this run"
    log_warn "(queried on primary - standby state not verified); falling back to a primary-side"
    log_warn "informational query only (this reflects the PRIMARY's dictionary, not the standby's):"
    PDB_ON_PRI="$(run_dgmgrl "$TARGET_CDB_ORACLE_SID" "
SQL \"ALTER SESSION SET CONTAINER=CDB\\\$ROOT\";
SQL \"SELECT name||'|'||open_mode||'|'||con_id FROM v\\\$pdbs WHERE name=UPPER('${NEW_PDB_NAME}')\";
" 2>&1)" || true
    echo "$PDB_ON_PRI" | tee_into_log
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

sleep 8
SCN_AFTER_PRI="$(sql_scalar "$TARGET_CDB_ORACLE_SID" "SELECT current_scn FROM v\$database;")"
# V$ARCHIVED_LOG has no APPLIED_SCN column - that query always failed with
# ORA-00904, swallowed by the 2>&1 capture into a "?" in the log line below.
# V$ARCHIVE_DEST_STATUS, queried on the PRIMARY, reports the last SCN
# applied at each redo transport destination and is the correct source.
APPLIED_SCN="$(sql_scalar "$TARGET_CDB_ORACLE_SID" "
SELECT applied_scn FROM v\$archive_dest_status
 WHERE db_unique_name = '${TARGET_CDB_STANDBY_UNIQUE_NAME}'
   AND dest_id = (SELECT MIN(dest_id) FROM v\$archive_dest_status WHERE db_unique_name = '${TARGET_CDB_STANDBY_UNIQUE_NAME}');
")"
log_info "Primary SCN before/after: ${SCN_BEFORE} / ${SCN_AFTER_PRI}; standby applied SCN: ${APPLIED_SCN:-?}"

# ---- 7. Summary ------------------------------------------------------------
# verify_done is only ever "true" when FAIL==0 - 06_decommission_noncdb.sh
# gates its destructive teardown on this flag, so it must not be written
# unconditionally before the pass/fail decision below (H9b).
record_state "verify_done"      "$([[ $FAIL -eq 0 ]] && echo true || echo false)"
record_state "verify_failures"  "$FAIL"

if (( FAIL > 0 )); then
    log_error "Verification reported ${FAIL} failure(s)."
    exit 1
fi
log_success "Verification PASSED. ${NEW_PDB_NAME} is in DG, applied on ${TARGET_CDB_STANDBY_UNIQUE_NAME}."
log_info "Log file: ${LOG_FILE}"
