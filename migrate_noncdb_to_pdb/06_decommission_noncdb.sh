#!/usr/bin/env bash
# =============================================================================
# 06_decommission_noncdb.sh  -  Tear down the source non-CDB Data Guard.
# =============================================================================
# Run on: PRIMARY host of the (now-obsolete) non-CDB.
#
# What this does (DESTRUCTIVE):
#   * Refuses to start unless it can PROVE what it is about to shut down:
#       - step 05 recorded a clean verification (verify_done=true, 0 failures);
#       - SOURCE_ORACLE_SID is the non-CDB SOURCE_DB_NAME (v$database.name,
#         cdb=NO, PRIMARY, OPEN READ ONLY - the state step 02 leaves it in -
#         and the DBID recorded by step 01);
#       - the new PDB is OPEN READ WRITE in the target CDB primary.
#   * Removes the non-CDB Data Guard broker configuration (does NOT remove the
#     CDB DG -- that is a separate, working DG).
#   * Defers the non-CDB's redo-transport destination to its standby.
#   * Stops the non-CDB primary instance.
#   * If ALLOW_DROP_NONCDB="I_UNDERSTAND" is set in the config, also issues
#     STARTUP MOUNT EXCLUSIVE RESTRICT; DROP DATABASE; (plain DROP DATABASE:
#     RMAN backups and archived logs outside the database files are NOT
#     removed). Unattended runs (MIGRATE_NONINTERACTIVE=1) must additionally
#     set MIGRATE_ALLOW_DROP=1 or the drop is refused.
#   * Removes the staged datafiles under NFS_SHARE. The manifest, state.env and
#     logs are KEPT (the manifest cannot be regenerated once the source is gone).
#
# It does NOT touch the standby host -- the easiest way to get rid of the
# leftover standby files is to either DROP DATABASE on it once it's mounted,
# or to simply rm the data files now that broker config is gone. The
# walkthrough explains the manual cleanup; this script focuses on the primary.
#
# This step is OPTIONAL. The new PDB inside the CDB is fully functional even
# if you leave the non-CDB instance shut down for a rollback window.
# =============================================================================

set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

load_config
init_log "06_decommission_noncdb"
trap_err
log_step "06 DECOMMISSION non-CDB ${SOURCE_DB_UNIQUE_NAME}"

if [[ "${SKIP_DECOMMISSION:-false}" == "true" ]]; then
    log_warn "SKIP_DECOMMISSION=true -- nothing to do."
    exit 0
fi

# Sanity: do not decommission if the new PDB hasn't been verified
if [[ "$(read_state verify_done)" != "true" ]]; then
    log_error "Step 05 has not been recorded as completed successfully. Refusing to decommission."
    log_error "If you are sure, edit ${MIGRATE_STATE_FILE} or run 05_verify_pdb_dataguard.sh."
    exit 1
fi

# Belt-and-braces: verify_done is only set "true" by 05 when FAIL==0, but
# check verify_failures independently too in case the state file was ever
# hand-edited or written by an older version of 05.
VERIFY_FAILURES="$(read_state verify_failures)"
if [[ "$VERIFY_FAILURES" != "0" ]]; then
    log_error "Step 05 recorded '${VERIFY_FAILURES:-<none>}' verification failure(s) (need exactly 0). Refusing to decommission."
    log_error "Fix the failures and re-run 05_verify_pdb_dataguard.sh until it reports 0 failures."
    exit 1
fi

# Identity of what we are about to act on - checked before ANY change.
# SOURCE_ORACLE_SID is just an environment variable; a typo must not be able to
# shut down (or drop) some other database.
assert_source_identity "READONLY" || {
    log_error "Refusing to decommission."
    exit 1
}
assert_new_pdb_open || {
    log_error "Refusing to decommission: the replacement PDB is not confirmed OPEN READ WRITE."
    exit 1
}

WANT_DROP=false
[[ "${ALLOW_DROP_NONCDB:-no}" == "I_UNDERSTAND" ]] && WANT_DROP=true
# Decide up front, not after the shutdown: an unattended run that asks for the
# drop without the explicit second switch is refused before anything changes.
if [[ "$WANT_DROP" == "true" && "${MIGRATE_NONINTERACTIVE:-0}" == "1" && "${MIGRATE_ALLOW_DROP:-0}" != "1" ]]; then
    log_error "ALLOW_DROP_NONCDB=I_UNDERSTAND with MIGRATE_NONINTERACTIVE=1 needs MIGRATE_ALLOW_DROP=1 as well. Nothing was changed."
    exit 1
fi

confirm_or_abort "About to remove non-CDB DG broker config and shut down ${SOURCE_DB_UNIQUE_NAME}. Continue?"

# ---- 1. Remove broker configuration on the non-CDB -------------------------
# Find the archive destination that ships to the standby BEFORE the broker is
# removed (it is not necessarily LOG_ARCHIVE_DEST_2).
# (one-row result required: whitespace-stripping a multi-row result would glue
# the ids together)
STBY_DEST_RAW="$(run_sql "$SOURCE_ORACLE_SID" "
SELECT 'DEST_ID=' || dest_id FROM v\$archive_dest
 WHERE UPPER(db_unique_name) = UPPER('${SOURCE_STANDBY_UNIQUE_NAME}')
   AND target = 'STANDBY' AND status <> 'INACTIVE';
")" || STBY_DEST_RAW=""
STBY_DEST_ID=""
if [[ "$(printf '%s\n' "$STBY_DEST_RAW" | grep -c '^DEST_ID=')" == "1" ]]; then
    STBY_DEST_ID="$(kv_get DEST_ID "$STBY_DEST_RAW")"
fi

log_info "Removing Data Guard broker configuration for non-CDB ${SOURCE_DB_UNIQUE_NAME} ..."
run_dgmgrl "$SOURCE_ORACLE_SID" "REMOVE CONFIGURATION;" | tee_into_log || \
    log_warn "REMOVE CONFIGURATION failed (already gone?)"

run_sql "$SOURCE_ORACLE_SID" "
ALTER SYSTEM SET DG_BROKER_START=FALSE SCOPE=BOTH;
" | tee_into_log || true
if [[ "$STBY_DEST_ID" =~ ^[0-9]+$ ]]; then
    log_info "Deferring LOG_ARCHIVE_DEST_STATE_${STBY_DEST_ID} (destination of ${SOURCE_STANDBY_UNIQUE_NAME}) ..."
    run_sql "$SOURCE_ORACLE_SID" "
ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_${STBY_DEST_ID}='DEFER' SCOPE=BOTH;
" | tee_into_log || log_warn "Could not defer LOG_ARCHIVE_DEST_STATE_${STBY_DEST_ID}"
else
    log_warn "Could not identify the redo destination of ${SOURCE_STANDBY_UNIQUE_NAME} (got '${STBY_DEST_ID}'); no LOG_ARCHIVE_DEST_STATE_n changed. Check the parameter by hand if the instance is ever restarted."
fi

# ---- 2. Shut down the non-CDB primary --------------------------------------
log_info "Shutting down non-CDB primary ..."
run_sql "$SOURCE_ORACLE_SID" "SHUTDOWN IMMEDIATE;" | tee_into_log || \
    log_warn "Primary may already be down."

# ---- 3. Optional: DROP DATABASE on the non-CDB primary ---------------------
if [[ "$WANT_DROP" == "true" ]]; then
    confirm_drop_or_abort "ALLOW_DROP_NONCDB=I_UNDERSTAND -- truly drop the non-CDB ${SOURCE_DB_NAME} now?"

    log_warn "Issuing DROP DATABASE on ${SOURCE_DB_UNIQUE_NAME} ..."
    run_sql "$SOURCE_ORACLE_SID" "
STARTUP MOUNT EXCLUSIVE RESTRICT;
ALTER SYSTEM ENABLE RESTRICTED SESSION;
DROP DATABASE;
" | tee_into_log

    log_warn "non-CDB ${SOURCE_DB_NAME} has been dropped. Datafiles, controlfiles, and online logs are gone."
    log_warn "On the standby host you must remove leftover datafiles and the standby spfile/orapw manually,"
    log_warn "or run STARTUP MOUNT; DROP DATABASE; on the standby instance."
else
    log_info "ALLOW_DROP_NONCDB is not 'I_UNDERSTAND'. Leaving non-CDB shut down (no DROP)."
    log_info "If you want to keep it as a rollback option, that's fine -- it has no broker config now."
fi

# ---- 4. Tidy up staging on NFS ---------------------------------------------
if [[ -d "$MIGRATE_DATAFILE_STAGE" ]]; then
    # du -sk (POSIX), not du -sb: -b is a GNU extension AIX 7.2 lacks.
    BYTES=$(du -sk "$MIGRATE_DATAFILE_STAGE" 2>/dev/null | awk '{print $1*1024}')
    log_info "Staging dir size: ${BYTES:-?} bytes"
    log_info "Removing staged datafiles ${MIGRATE_DATAFILE_STAGE} (manifest and state.env are kept) ..."
    rm -rf "$MIGRATE_DATAFILE_STAGE"
fi
record_state "decommission_done" "true"

log_success "Decommission step complete."
log_info "Log file: ${LOG_FILE}"
