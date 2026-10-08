#!/usr/bin/env bash
# check: file placement on the standby matches what the scenario asked for -
# every datafile, tempfile, online/standby redo log and control file sits under
# a directory the brief named, and none under a primary-only path
_standby_files() { # kind -> paths, one per line
    local sql
    case "$1" in
        data) sql="SELECT name FROM v\$datafile UNION ALL SELECT name FROM v\$tempfile;" ;;
        redo) sql="SELECT member FROM v\$logfile WHERE type = 'ONLINE';" ;;
        srl)  sql="SELECT member FROM v\$logfile WHERE type = 'STANDBY';" ;;
        ctl)  sql="SELECT name FROM v\$controlfile;" ;;
    esac
    ssh_sql_raw STANDBY "$sql" "$SCN_STANDBY_SID"
}
_all_under() { # "allowed dirs" <<< paths -> 0 when every path starts with one of them
    local allowed="$1" p d ok
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        ok=0; for d in $allowed; do [[ "$p" == "$d"/* ]] && ok=1; done
        [[ $ok -eq 1 ]] || { printf '%s\n' "$p"; }
    done
}
check_standby_layout() {
    local files bad allowed kind label
    if [[ "${WANT_STORAGE_MODE:-traditional}" == "omf" ]]; then
        allowed="${WANT_OMF_FILE_DEST}"
        [[ -n "${WANT_STANDBY_FRA:-}" && "$WANT_STANDBY_FRA" != "none" ]] && allowed="$allowed ${WANT_STANDBY_FRA%%:*}"
        local m; for m in ${WANT_ONLINE_LOG_DESTS:-}; do allowed="$allowed ${m#*=}"; done
        for kind in data redo srl ctl; do
            files=$(_standby_files "$kind")
            bad=$(printf '%s\n' "$files" | _all_under "$allowed")
            if [[ -z "$files" ]]; then log_fail "layout: no ${kind} files found on the standby"; return 1; fi
            [[ -z "$bad" ]] && log_pass "layout: ${kind} files under the OMF destinations ($(printf '%s\n' "$files" | grep -c .))" || { log_fail "layout: ${kind} file(s) outside ${allowed}: $(printf '%s' "$bad" | tr '\n' ' ')"; return 1; }
        done
        # the primary's explicit control-file paths must not have been inherited
        local cf; for cf in ${P_CONTROL_FILES:-}; do
            printf '%s\n' "$(_standby_files ctl)" | grep -qx "$cf" && { log_fail "layout: standby inherited the primary control file path ${cf}"; return 1; }
        done
        [[ -n "${P_CONTROL_FILES:-}" ]] && log_pass "layout: primary control_files not inherited"
        # redo in the mapped online-log destinations
        for m in ${WANT_ONLINE_LOG_DESTS:-}; do
            printf '%s\n' "$(_standby_files redo)" | grep -q "^${m#*=}/" && log_pass "layout: redo member in db_create_online_log_dest_${m%%=*} ${m#*=}" || { log_fail "layout: no redo member under ${m#*=}"; return 1; }
        done
        return 0
    fi
    # Traditional: derive the standby directories the brief implies
    local stby_dirs="" pri_only="" d p u l su sl m from to
    u=$(upper "$P_DB_UNIQUE_NAME"); l=$(lower "$P_DB_UNIQUE_NAME"); su=$(upper "$SCN_STANDBY_NAME"); sl=$(lower "$SCN_STANDBY_NAME")
    for d in ${P_DATA_DIRS:-} ${P_REDO_DIRS:-} ${P_TEMP_DIR:-}; do
        p="$d"
        for m in ${WANT_PATH_OVERRIDES:-}; do [[ "$d" == "${m%%=*}" ]] && p="${m#*=}"; done
        if [[ "$p" == "$d" ]]; then
            for m in ${WANT_FS_MAP:-}; do from="${m%%=*}"; to="${m#*=}"; [[ "$p" == "$from"/* ]] && p="${to}${p#$from}"; done
            p="${p//\/${u}\//\/${su}\/}"; p="${p//\/${l}\//\/${sl}\/}"
            [[ "$p" == */"$u" ]] && p="${p%/*}/${su}"
            [[ "$p" == */"$l" ]] && p="${p%/*}/${sl}"
        fi
        stby_dirs="$stby_dirs $p"
        [[ "$p" != "$d" ]] && pri_only="$pri_only $d"
    done
    stby_dirs="$stby_dirs ${WANT_SEPARATE_SRL_DIR:-} ${WANT_CONTROL_FILE_2_DIR:-}"
    [[ -n "${WANT_STANDBY_FRA:-}" && "$WANT_STANDBY_FRA" != "none" ]] && stby_dirs="$stby_dirs ${WANT_STANDBY_FRA%%:*}"
    local cf; for cf in ${P_CONTROL_FILES:-}; do
        d=$(dirname "$cf"); p="$d"
        for m in ${WANT_FS_MAP:-}; do from="${m%%=*}"; to="${m#*=}"; [[ "$p" == "$from"/* ]] && p="${to}${p#$from}"; done
        p="${p//\/${u}\//\/${su}\/}"; p="${p//\/${l}\//\/${sl}\/}"; [[ "$p" == */"$u" ]] && p="${p%/*}/${su}"
        stby_dirs="$stby_dirs $p"
    done
    for kind in data redo srl ctl; do
        case "$kind" in data) label="datafiles/tempfiles" ;; redo) label="online redo" ;; srl) label="standby redo" ;; ctl) label="control files" ;; esac
        files=$(_standby_files "$kind")
        [[ -z "$files" ]] && { log_fail "layout: no ${label} found on the standby"; return 1; }
        bad=$(printf '%s\n' "$files" | _all_under "$stby_dirs")
        [[ -z "$bad" ]] && log_pass "layout: ${label} under the requested standby directories ($(printf '%s\n' "$files" | grep -c .))" || { log_fail "layout: ${label} outside the requested directories: $(printf '%s' "$bad" | tr '\n' ' ')"; return 1; }
        if [[ -n "$pri_only" ]]; then
            bad=""; for d in $pri_only; do bad="$bad $(printf '%s\n' "$files" | grep "^${d}/" | tr '\n' ' ')"; done
            [[ -z "${bad// /}" ]] && log_pass "layout: no ${label} under a primary-only directory" || { log_fail "layout: ${label} under a primary-only directory:${bad}"; return 1; }
        fi
    done
    [[ -n "${WANT_SEPARATE_SRL_DIR:-}" ]] && { printf '%s\n' "$(_standby_files srl)" | grep -q "^${WANT_SEPARATE_SRL_DIR}/" && log_pass "layout: SRLs in ${WANT_SEPARATE_SRL_DIR}" || { log_fail "layout: no SRL under ${WANT_SEPARATE_SRL_DIR}"; return 1; }; }
    [[ -n "${WANT_CONTROL_FILE_2_DIR:-}" ]] && { printf '%s\n' "$(_standby_files ctl)" | grep -q "^${WANT_CONTROL_FILE_2_DIR}/" && log_pass "layout: a control file copy in ${WANT_CONTROL_FILE_2_DIR}" || { log_fail "layout: no control file under ${WANT_CONTROL_FILE_2_DIR}"; return 1; }; }
    return 0
}
