#!/usr/bin/env bash
# =============================================================================
# 03_describe_and_stage.sh  -  Generate the unplug XML manifest and stage the
#                              non-CDB datafiles on the NFS share so that BOTH
#                              the CDB primary AND the CDB standby can read
#                              them at the same path.
# =============================================================================
# Run on: PRIMARY host of the non-CDB (which here is the same host as the CDB
#         primary; on a split layout this script must be run wherever the
#         non-CDB primary lives).
#
# Effects:
#   * DBMS_PDB.DESCRIBE -> writes XML manifest to NFS_SHARE.
#   * Hard-links (or copies) all SYSTEM/SYSAUX/UNDO/USERS/etc. datafiles to
#     ${NFS_SHARE}/migrate/.../datafiles/. Every run re-copies: a staged file
#     left by an earlier run is never trusted on size alone (the source is
#     read-only and frozen, so a re-copy is the only proof it matches).
#   * Records the file map and datafile count so step 04 can build
#     FILE_NAME_CONVERT and prove the stage is complete.
#
# Requires step 02 to have completed (state noncdb_quiesced).
#
# Why stage to NFS instead of using the source paths directly?
#   * The CDB standby host needs to read the same bytes via
#     STANDBY_PDB_SOURCE_FILE_DIRECTORY when it applies the
#     CREATE PLUGGABLE DATABASE redo. The NFS share is mounted with the
#     same path on both hosts, so a single staging dir works.
# =============================================================================

set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"

load_config
init_log "03_describe_and_stage"
trap_err
log_step "03 DESCRIBE + STAGE non-CDB ${SOURCE_DB_NAME}"

require_state noncdb_quiesced 02_quiesce_noncdb.sh

# ---- 0. Sanity: the non-CDB must be OPEN READ ONLY -------------------------
SRC_OPEN_MODE="$(sql_scalar "$SOURCE_ORACLE_SID" "SELECT open_mode FROM v\$database;")"
if [[ "$SRC_OPEN_MODE" != "READONLY" ]]; then
    log_error "Source non-CDB must be OPEN READ ONLY (got '${SRC_OPEN_MODE}'). Run 02_quiesce_noncdb.sh first."
    exit 1
fi

# Start of a new attempt (after the refusal above, which changes nothing):
# the manifest and the stage are rebuilt from here on, so this step's and every
# later step's flags are stale.
clear_state describe_done stage_datafile_count stage_total_bytes create_pdb_done plug_done verify_done verify_failures

# ---- 1. Generate the unplug manifest ---------------------------------------
log_info "Calling DBMS_PDB.DESCRIBE -> ${MIGRATE_MANIFEST}"
# A manifest left by an earlier run must never be mistaken for this run's.
rm -f "$MIGRATE_MANIFEST"
DESCRIBE_OUT="$(run_sql "$SOURCE_ORACLE_SID" "
SET SERVEROUTPUT ON
DECLARE
    success BOOLEAN;
BEGIN
    success := DBMS_PDB.DESCRIBE(pdb_descr_file => '${MIGRATE_MANIFEST}');
    IF success THEN
        DBMS_OUTPUT.PUT_LINE('DESCRIBE_OK');
    ELSE
        DBMS_OUTPUT.PUT_LINE('DESCRIBE_FAIL');
    END IF;
END;
/
")" || { echo "$DESCRIBE_OUT" | tee_into_log; log_error "DBMS_PDB.DESCRIBE failed"; exit 1; }
echo "$DESCRIBE_OUT" | tee_into_log

if echo "$DESCRIBE_OUT" | grep -q 'DESCRIBE_FAIL' || ! echo "$DESCRIBE_OUT" | grep -q 'DESCRIBE_OK'; then
    log_error "DBMS_PDB.DESCRIBE did not report DESCRIBE_OK (DESCRIBE_FAIL or no marker) - refusing to continue."
    exit 1
fi
if [[ ! -s "$MIGRATE_MANIFEST" ]]; then
    log_error "Manifest file not produced or empty: ${MIGRATE_MANIFEST}"
    exit 1
fi

# file_size_bytes: AIX 7.2 has no stat(1) at all (neither the GNU -c%s nor
# the BSD -f%z flavor), so a stat/stat fallback chain still fails there.
# wc -c is POSIX and available everywhere this project targets.
file_size_bytes() {
    wc -c < "$1" 2>/dev/null | tr -d '[:space:]'
}

log_success "Manifest written: $(file_size_bytes "$MIGRATE_MANIFEST") bytes"

# ---- 2. Collect datafile list ---------------------------------------------
log_info "Collecting source datafile list ..."
DF_RAW="$(run_sql "$SOURCE_ORACLE_SID" "
SELECT 'DF|'||name FROM v\$datafile ORDER BY file#;
SELECT 'TF|'||name FROM v\$tempfile ORDER BY file#;
")"
echo "$DF_RAW" | tee_into_log

# Save a clean list (one path per line) to NFS for later steps
DF_FILE="${MIGRATE_STAGE_DIR}/datafile_list.txt"
echo "$DF_RAW" | awk -F'|' '/^DF\|/ {print $2}' | sed 's/[[:space:]]*$//' > "$DF_FILE"
TF_FILE="${MIGRATE_STAGE_DIR}/tempfile_list.txt"
echo "$DF_RAW" | awk -F'|' '/^TF\|/ {print $2}' | sed 's/[[:space:]]*$//' > "$TF_FILE"

DF_COUNT=$(wc -l < "$DF_FILE" | tr -d '[:space:]')
log_info "Datafile count: ${DF_COUNT}"
[[ "$DF_COUNT" == "0" ]] && { log_error "No datafiles found"; exit 1; }

# ---- 2b. Detect duplicate basenames -----------------------------------------
# Staging is a flat directory keyed by basename (stage_one() below). Two
# datafiles with the same basename from different source directories would
# silently clobber or skip each other there, plugging the PDB from a
# mismatched datafile image. Catch it up front, before touching the stage.
DUP_BASENAMES="$(awk -F/ '{print $NF}' "$DF_FILE" | sort | uniq -d)"
if [[ -n "$DUP_BASENAMES" ]]; then
    log_error "Duplicate datafile basenames found across different source directories:"
    while IFS= read -r dup; do
        [[ -z "$dup" ]] && continue
        log_error "  ${dup}:"
        grep -F "/${dup}" "$DF_FILE" | while IFS= read -r full; do
            log_error "    ${full}"
        done
    done <<< "$DUP_BASENAMES"
    log_error "Flat staging cannot disambiguate these - rename/relocate one of each pair on the"
    log_error "source before re-running, or extend stage_one() to preserve a directory-qualified name."
    exit 1
fi

# ---- 3. Stage datafiles to NFS ---------------------------------------------
log_info "Staging datafiles to ${MIGRATE_DATAFILE_STAGE} ..."

stage_one() {
    local src="$1"
    local base
    base="$(basename "$src")"
    local dst="${MIGRATE_DATAFILE_STAGE}/${base}"
    # Never reuse what is already there: a same-size file may be a stale copy
    # from an earlier attempt. Copy to <name>.part and rename, so a final name
    # only ever holds a complete copy.
    rm -f "$dst" "${dst}.part"
    # Try hard-link first (instant, no extra space) - only works if NFS is on
    # the same filesystem as the source datafile, which is rarely the case.
    # Fall back to plain cp.
    if ln "$src" "$dst" 2>/dev/null; then
        log_info "  hard-linked: ${base}"
    else
        log_info "  copying: ${src}"
        cp -f "$src" "${dst}.part"
        mv -f "${dst}.part" "$dst"
    fi
    local s_size d_size
    s_size=$(file_size_bytes "$src")
    d_size=$(file_size_bytes "$dst")
    if [[ -z "$s_size" || "$s_size" != "$d_size" ]]; then
        log_error "Staged copy of ${base} is ${d_size:-?} bytes, source is ${s_size:-?} bytes"
        exit 1
    fi
}

# Drop anything in the stage that is not one of this run's datafiles (stale
# files and .part leftovers from earlier attempts), so step 04's file count
# means something.
EXPECTED_BASES="$(awk -F/ '{print $NF}' "$DF_FILE")"
for stale in "${MIGRATE_DATAFILE_STAGE}"/* "${MIGRATE_DATAFILE_STAGE}"/.[!.]*; do
    [[ -e "$stale" || -L "$stale" ]] || continue
    if ! printf '%s\n' "$EXPECTED_BASES" | grep -Fxq -- "$(basename "$stale")"; then
        log_warn "  removing stale staged file: $(basename "$stale")"
        rm -rf "$stale"
    fi
done

while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ ! -r "$f" ]]; then
        log_error "Source datafile not readable: ${f}"
        exit 1
    fi
    stage_one "$f"
done < "$DF_FILE"

# du -sk (POSIX), not du -sb: -b is a GNU extension AIX 7.2 does not have.
# KB granularity is plenty for a staging-size log line.
STAGED_BYTES=$(du -sk "$MIGRATE_DATAFILE_STAGE" 2>/dev/null | awk '{print $1*1024}')
STAGED_COUNT=$(find "$MIGRATE_DATAFILE_STAGE" -type f ! -name '*.part' 2>/dev/null | wc -l | tr -d '[:space:]')
if [[ "$STAGED_COUNT" != "$DF_COUNT" ]]; then
    log_error "Staged file count (${STAGED_COUNT}) differs from the source datafile count (${DF_COUNT})"
    exit 1
fi
log_success "Staged ${DF_COUNT} datafile(s), ~${STAGED_BYTES} bytes total"

# ---- 4. Record SOURCE_FILE_NAME_CONVERT and FILE_NAME_CONVERT --------------
# The CREATE PLUGGABLE DATABASE statement in step 04 needs:
#   SOURCE_FILE_NAME_CONVERT  (manifest path  -> staged path on NFS)
#   FILE_NAME_CONVERT         (staged path    -> target PDB datafile path)
# We just save the directory mapping; the plug step builds the convert pairs.
record_state "manifest_path"        "$MIGRATE_MANIFEST"
record_state "stage_datafile_dir"   "$MIGRATE_DATAFILE_STAGE"
record_state "stage_datafile_count" "$DF_COUNT"
record_state "stage_total_bytes"    "${STAGED_BYTES:-0}"
record_state "describe_done"        "true"

log_success "Describe + stage complete."
log_info "Manifest: ${MIGRATE_MANIFEST}"
log_info "Staged datafiles: ${MIGRATE_DATAFILE_STAGE}"
log_info "Log file: ${LOG_FILE}"
