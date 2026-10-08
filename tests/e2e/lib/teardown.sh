#!/usr/bin/env bash
# =============================================================================
# tests/e2e/lib/teardown.sh - remove everything a scenario created
# =============================================================================
#   teardown_scenario       standby host, primary host, third host, NFS share
#
# Best effort: nothing here aborts. Removes ONLY what belongs to the loaded
# scenario: its SIDs/unique names, the directories its profile and WANT_*
# keys name, its scratch TNS_ADMIN, its scratch work dir, its NFS artifacts.
# The shared $ORACLE_HOME/network/admin is edited only in S_NET=shared mode
# (DG blocks and the scenario's SID_DESC entries removed), and the shared
# wallet directory is never touched - on some labs it holds a TDE keystore.
# =============================================================================

[[ -n "${E2E_TEARDOWN_LOADED:-}" ]] && return 0
E2E_TEARDOWN_LOADED=1

# Directories the standby side may have derived from the profile: the primary
# paths with the DB-name component swapped for the standby name (both cases),
# plus every explicit WANT_* directory.
_standby_dirs() {
    local d p u l su sl out=""
    u=$(upper "$P_DB_UNIQUE_NAME"); l=$(lower "$P_DB_UNIQUE_NAME")
    su=$(upper "$SCN_STANDBY_NAME"); sl=$(lower "$SCN_STANDBY_NAME")
    for d in ${P_DATA_DIRS:-} ${P_REDO_DIRS:-} ${P_TEMP_DIR:-} ${P_OMF_FILE_DEST:-} ${P_FRA_DIR:-} ${P_ARCHIVE_DEST:-} ${P_BROKER_FILE_DIR:-}; do
        [[ "$d" == "FRA" ]] && continue
        p="${d//\/${u}\//\/${su}\/}"; p="${p//\/${l}\//\/${sl}\/}"
        [[ "$p" == */"$u" ]] && p="${p%/*}/${su}"
        [[ "$p" == */"$l" ]] && p="${p%/*}/${sl}"
        out="$out $p"
        # a renamed-filesystem map moves the first component
        local m from to
        for m in ${WANT_FS_MAP:-}; do
            from="${m%%=*}"; to="${m#*=}"
            [[ "$p" == "$from"/* ]] && out="$out ${to}${p#$from}"
        done
        for m in ${WANT_PATH_OVERRIDES:-}; do
            [[ "$d" == "${m%%=*}" ]] && out="$out ${m#*=}"
        done
    done
    local fra="${WANT_STANDBY_FRA:-}"; fra="${fra%%:*}"; [[ "$fra" == "none" ]] && fra=""
    out="$out ${WANT_SEPARATE_SRL_DIR:-} ${WANT_CONTROL_FILE_2_DIR:-} ${WANT_OMF_FILE_DEST:-} ${fra}"
    [[ -n "${WANT_STANDBY_ORACLE_BASE:-}" ]] && out="$out ${WANT_STANDBY_ORACLE_BASE}"
    local ob="${WANT_STANDBY_ORACLE_BASE:-$ORACLE_BASE}"
    out="$out ${ob}/oradata/${su} ${ob}/oradata/${sl} ${ob}/admin/${su} ${ob}/admin/${sl} ${ob}/fast_recovery_area/${su} ${ob}/fast_recovery_area/${sl} ${ob}/archive/${su} ${ob}/archive/${sl} ${ob}/diag/rdbms/${sl}"
    for d in ${WANT_ONLINE_LOG_DESTS:-}; do out="$out ${d#*=}"; done
    printf '%s' "$out"
}

_primary_dirs() {
    local d u l out=""
    u=$(upper "$P_DB_UNIQUE_NAME"); l=$(lower "$P_DB_UNIQUE_NAME")
    for d in ${P_DATA_DIRS:-} ${P_REDO_DIRS:-} ${P_TEMP_DIR:-} ${P_OMF_FILE_DEST:-} ${P_FRA_DIR:-} ${P_ARCHIVE_DEST:-} ${P_BROKER_FILE_DIR:-}; do
        [[ "$d" == "FRA" ]] && continue
        out="$out $d"
    done
    local cf; for cf in ${P_CONTROL_FILES:-}; do out="$out $(dirname "$cf")"; done
    out="$out ${ORACLE_BASE}/oradata/${u} ${ORACLE_BASE}/oradata/${l} ${ORACLE_BASE}/admin/${u} ${ORACLE_BASE}/admin/${l} ${ORACLE_BASE}/fast_recovery_area/${u} ${ORACLE_BASE}/fast_recovery_area/${l} ${ORACLE_BASE}/archive/${u} ${ORACLE_BASE}/archive/${l} ${ORACLE_BASE}/diag/rdbms/${l}"
    printf '%s' "$out"
}

# Only directories that are safe to rm -rf: absolute, at least three
# components deep, not a bare slot/ORACLE_BASE, and containing one of the
# scenario's names or living under its scratch area.
_rm_list() {
    local d out="" names
    names="$(upper "$P_DB_UNIQUE_NAME") $(lower "$P_DB_UNIQUE_NAME") $(upper "$P_DB_NAME") $(lower "$P_DB_NAME") $(upper "$SCN_STANDBY_NAME") $(lower "$SCN_STANDBY_NAME") $(upper "$P_SID") $(lower "$P_SID")"
    for d in "$@"; do
        [[ "$d" == /*/*/* ]] || continue
        [[ "$d" == "$ORACLE_BASE" || "$d" == "$ORACLE_HOME"* ]] && continue
        local n hit=0
        for n in $names; do [[ "$d" == *"$n"* ]] && hit=1; done
        [[ "$d" == "${LAB_SCRATCH}"/* ]] && hit=1
        [[ "$d" == *"/e2e"* ]] && hit=1
        [[ $hit -eq 1 ]] && out="$out $(shq "$d")"
    done
    printf '%s' "$out"
}

_remote_shared_net_cleanup() {
    # Strip the DG blocks and this scenario's SID_DESC entries from the SHARED
    # listener/tnsnames (what steps 3/4 appended), then reload. Shared mode only.
    cat <<REMOTE
NA="\${ORACLE_HOME}/network/admin"
for f in tnsnames.ora listener.ora; do
    [[ -f "\$NA/\$f" ]] || continue
    sed -i '/^# Data Guard TNS entries/,\$d' "\$NA/\$f" 2>/dev/null || true
    sed -i '/^# DG Listener/,\$d' "\$NA/\$f" 2>/dev/null || true
done
if [[ -f "\$NA/listener.ora" ]]; then
    awk -v sids="$(upper "$P_SID") $(upper "$SCN_STANDBY_SID") $(upper "$P_DB_UNIQUE_NAME") $(upper "$SCN_STANDBY_NAME")" '
        BEGIN { n = split(sids, S, " ") }
        /^[[:space:]]*\\(SID_DESC/ && blk==0 { blk=1; depth=0; drop=0; hasname=0; c=0 }
        blk==1 {
            buf[++c]=\$0
            for (i=1;i<=length(\$0);i++) { ch=substr(\$0,i,1); if (ch=="(") depth++; else if (ch==")") depth-- }
            for (k=1;k<=n;k++) if (index(toupper(\$0), S[k]) > 0) drop=1
            if (tolower(\$0) ~ /sid_name/) hasname=1
            if (depth<=0) { blk=0; if (!drop && hasname) for (i=1;i<=c;i++) print buf[i] }
            next
        }
        { print }
    ' "\$NA/listener.ora" > "\$NA/listener.ora.e2e" && mv "\$NA/listener.ora.e2e" "\$NA/listener.ora"
    sed -i '/^NAMES.DEFAULT_DOMAIN/d' "\$NA/sqlnet.ora" 2>/dev/null || true
fi
lsnrctl reload >/dev/null 2>&1 || lsnrctl start >/dev/null 2>&1 || true
REMOTE
}

_remote_db_cleanup() {
    # $1 = role (primary|standby), $2 = SID, $3 = unique name, $4 = dirs (quoted list)
    local role="$1" sid="$2" uniq="$3" dirs="$4"
    cat <<REMOTE
set +e
export ORACLE_SID=$(shq "$sid")
# observers started from this scenario's scratch area or for its configuration
for pid in \$(ps -eo pid,args | grep -i 'dgmgrl' | grep -i 'observer' | grep -E "${SCN_WORK}|${SCN_STANDBY_NAME}|${P_DB_UNIQUE_NAME}" | grep -v grep | awk '{print \$1}'); do kill "\$pid" 2>/dev/null; done
if ps -eo args | grep -q "[o]ra_pmon_${sid}\$"; then
    if [[ "$role" == "primary" ]]; then
        dgmgrl -silent / 'REMOVE CONFIGURATION' >/dev/null 2>&1
        dbca -silent -deleteDatabase -sourceDB $(shq "$uniq") -sid $(shq "$sid") -sysDBAUserName sys -sysDBAPassword $(shq "$TEST_SYS_PASSWORD") 2>&1 | tail -3
    fi
    if ps -eo args | grep -q "[o]ra_pmon_${sid}\$"; then
        sqlplus -s / as sysdba <<'SQLEOF' >/dev/null 2>&1
SHUTDOWN ABORT;
EXIT;
SQLEOF
    fi
fi
rm -rf ${dirs} 2>/dev/null
rm -f "\${ORACLE_HOME}/dbs/init${sid}.ora" "\${ORACLE_HOME}/dbs/spfile${sid}.ora" "\${ORACLE_HOME}/dbs/orapw${sid}" "\${ORACLE_HOME}/dbs/hc_${sid}.dat" "\${ORACLE_HOME}/dbs/lk$(upper "$sid")" "\${ORACLE_HOME}/dbs/lk$(upper "$uniq")" 2>/dev/null
rm -f "\${ORACLE_HOME}/dbs/dr1${uniq}.dat" "\${ORACLE_HOME}/dbs/dr2${uniq}.dat" "\${ORACLE_HOME}/dbs/dr1$(upper "$uniq").dat" "\${ORACLE_HOME}/dbs/dr2$(upper "$uniq").dat" 2>/dev/null
rm -rf "\${ORACLE_BASE}/diag/rdbms/$(lower "$uniq")" "\${ORACLE_BASE}/admin/${uniq}" "\${ORACLE_BASE}/audit/${sid}" 2>/dev/null
if [[ -f /etc/oratab ]]; then
    grep -v "^${sid}:" /etc/oratab > /tmp/oratab.e2e.\$\$ 2>/dev/null && cp /tmp/oratab.e2e.\$\$ /etc/oratab 2>/dev/null; rm -f /tmp/oratab.e2e.\$\$
fi
$( if [[ "$SCN_NET" == "scratch" ]]; then
    printf 'if [[ -d %s ]]; then (export TNS_ADMIN=%s; lsnrctl stop >/dev/null 2>&1); rm -rf %s; fi\n' "$(shq "$E2E_REMOTE_TNS_ADMIN")" "$(shq "$E2E_REMOTE_TNS_ADMIN")" "$(shq "$E2E_REMOTE_TNS_ADMIN")"
  else
    _remote_shared_net_cleanup
  fi )
rm -rf $(shq "$SCN_WORK") 2>/dev/null
rm -rf "\$HOME/fsfo_observer_${SCN_STANDBY_NAME}" "\$HOME/observer_bundle_${P_DB_UNIQUE_NAME}" 2>/dev/null
echo __CLEAN_${role}_OK__
REMOTE
}

teardown_scenario() {
    local script out
    mkdir -p "${SCN_LOG}/teardown"
    log_phase "TEARDOWN: ${SCN_ID} (${P_DB_NAME} / ${SCN_STANDBY_NAME})"

    script="${SCN_LOG}/teardown/standby.sh"
    _remote_db_cleanup standby "$SCN_STANDBY_SID" "$SCN_STANDBY_NAME" "$(_rm_list $(_standby_dirs))" > "$script"
    out=$(ssh_script "STANDBY" "$script" "$SCN_STANDBY_SID" 2>&1 | tee "${SCN_LOG}/teardown/standby.log")
    printf '%s' "$out" | grep -q __CLEAN_standby_OK__ && log_info "standby host cleaned" || log_warn "standby cleanup did not finish (see teardown/standby.log)"

    script="${SCN_LOG}/teardown/primary.sh"
    _remote_db_cleanup primary "$P_SID" "$P_DB_UNIQUE_NAME" "$(_rm_list $(_primary_dirs))" > "$script"
    out=$(ssh_script "PRIMARY" "$script" "$P_SID" 2>&1 | tee "${SCN_LOG}/teardown/primary.log")
    printf '%s' "$out" | grep -q __CLEAN_primary_OK__ && log_info "primary host cleaned" || log_warn "primary cleanup did not finish (see teardown/primary.log)"

    if [[ -n "${HOST3:-}" && "${WANT_OBSERVER:-none}" == "third-host" ]] && ssh_reachable HOST3; then
        out=$(ssh_cmd "HOST3" "
set +e
B=\"\$HOME/observer_bundle_${P_DB_UNIQUE_NAME}\"
if [[ -d \"\$B\" ]]; then (cd \"\$B\" && ./03_observer_ctl.sh stop >/dev/null 2>&1); fi
for pid in \$(ps -eo pid,args | grep -i dgmgrl | grep -i observer | grep -E \"${P_DB_UNIQUE_NAME}|${SCN_STANDBY_NAME}\" | grep -v grep | awk '{print \$1}'); do kill \"\$pid\" 2>/dev/null; done
rm -rf \"\$B\" \"\$HOME/observer_bundle_${P_DB_UNIQUE_NAME}.tar\" 2>/dev/null
echo __CLEAN_host3_OK__" 2>&1 | tee "${SCN_LOG}/teardown/host3.log")
        printf '%s' "$out" | grep -q __CLEAN_host3_OK__ && log_info "third host cleaned" || log_warn "third-host cleanup did not finish"
    fi

    out=$(ssh_cmd "PRIMARY" "
set +e
cd $(shq "$NFS_SHARE") || exit 0
rm -f *_${SCN_STANDBY_NAME}.* *_${SCN_STANDBY_NAME}_* primary_info_${P_DB_UNIQUE_NAME}.env orapw${P_SID} orapw$(upper "$P_SID") \
      dg_handoff_${P_DB_UNIQUE_NAME}* dg_service_mgr*_${P_DB_UNIQUE_NAME}* dg_application_impact.html init${SCN_STANDBY_SID}_${SCN_STANDBY_NAME}.ora 2>/dev/null
rm -rf logs/*${SCN_STANDBY_NAME}* logs/*${P_DB_UNIQUE_NAME}* state/*${SCN_STANDBY_NAME}* state/*${P_DB_UNIQUE_NAME}* 2>/dev/null
echo __CLEAN_nfs_OK__")
    printf '%s' "$out" | grep -q __CLEAN_nfs_OK__ && log_info "NFS artifacts removed" || log_warn "NFS cleanup did not finish"
    log_pass "Teardown of ${SCN_ID} done"
    return 0
}

# Wipe EVERY generated file from the share (used before provisioning so a
# stale standby_config_*.env from another build cannot turn the scripts'
# auto-selection into a menu).
nfs_wipe_generated() {
    ssh_cmd "PRIMARY" "
set +e
cd $(shq "$NFS_SHARE") || exit 0
rm -f *.env *.ora *.dgmgrl *.sql orapw* dg_handoff_* dg_application_impact.html 2>/dev/null
rm -rf logs state 2>/dev/null
echo __WIPE_OK__" | grep -q __WIPE_OK__ && log_info "NFS share generated files wiped" || log_warn "NFS wipe failed"
}
