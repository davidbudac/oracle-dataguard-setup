#!/bin/bash
# =============================================================================
# 06_decommission_noncdb.sh  -  Tear down the source non-CDB Data Guard.
# =============================================================================
# Run on: PRIMARY host of the (now-obsolete) non-CDB.
#
# What this does (DESTRUCTIVE):
#   * Removes the non-CDB Data Guard broker configuration (does NOT remove the
#     CDB DG -- that is a separate, working DG).
#   * Stops the non-CDB primary instance.
#   * If ALLOW_DROP_NONCDB="I_UNDERSTAND" is set in the config, also issues
#     STARTUP MOUNT EXCLUSIVE; ALTER SYSTEM ENABLE RESTRICTED SESSION;
#     DROP DATABASE INCLUDING BACKUPS to remove the source completely.
#   * Cleans the staging dir under NFS_SHARE.
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
    log_error "Step 05 has not been recorded as completed. Refusing to decommission."
    log_error "If you are sure, edit ${MIGRATE_STATE_FILE} or run 05_verify_pdb_dataguard.sh."
    exit 1
fi

confirm_or_abort "About to remove non-CDB DG broker config and shut down ${SOURCE_DB_UNIQUE_NAME}. Continue?"

# ---- 1. Remove broker configuration on the non-CDB -------------------------
log_info "Removing Data Guard broker configuration for non-CDB ${SOURCE_DB_UNIQUE_NAME} ..."
run_dgmgrl "$SOURCE_ORACLE_SID" "REMOVE CONFIGURATION;" | tee_into_log || \
    log_warn "REMOVE CONFIGURATION failed (already gone?)"

run_sql "$SOURCE_ORACLE_SID" "
ALTER SYSTEM SET DG_BROKER_START=FALSE SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_2='DISABLE' SCOPE=BOTH;
" | tee_into_log || true

# ---- 2. Shut down the non-CDB primary --------------------------------------
log_info "Shutting down non-CDB primary ..."
run_sql "$SOURCE_ORACLE_SID" "SHUTDOWN IMMEDIATE;" | tee_into_log || \
    log_warn "Primary may already be down."

# ---- 3. Optional: DROP DATABASE on the non-CDB primary ---------------------
if [[ "${ALLOW_DROP_NONCDB:-no}" == "I_UNDERSTAND" ]]; then
    confirm_or_abort "ALLOW_DROP_NONCDB=I_UNDERSTAND -- truly drop the non-CDB now?"

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
    BYTES=$(du -sb "$MIGRATE_DATAFILE_STAGE" 2>/dev/null | awk '{print $1}')
    log_info "Staging dir size: ${BYTES:-?} bytes"
    log_info "Removing staged datafiles ${MIGRATE_DATAFILE_STAGE} ..."
    rm -rf "$MIGRATE_DATAFILE_STAGE"
fi
record_state "decommission_done" "true"

log_success "Decommission step complete."
log_info "Log file: ${LOG_FILE}"
