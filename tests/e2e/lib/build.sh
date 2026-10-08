#!/usr/bin/env bash
# =============================================================================
# tests/e2e/lib/build.sh - run the walkthrough steps for a build scenario
# =============================================================================
#   build_scenario          steps 1-7, then 13 / 9+10 / services / 11 / wallet /
#                           handoff as the WANT_* keys ask; each step is driven
#                           by answer.py with answers derived here, and
#                           validated right after
#   build_cleanup           step 12 (WANT_CLEANUP), run by e2e.sh at the very end
#
# Every step: optional "-n first" dry run (WANT_CHECK_MODE_FIRST) proving the
# share and the database did not change, then the real run, then assertions.
# BUILD_FROM_STEP=<name> skips earlier steps (resume after a fix).
# =============================================================================

[[ -n "${E2E_BUILD_LOADED:-}" ]] && return 0
E2E_BUILD_LOADED=1

BUILD_FROM_STEP="${BUILD_FROM_STEP:-}"
_build_started=""

_step_wanted() {
    [[ -z "$BUILD_FROM_STEP" ]] && return 0
    [[ -n "$_build_started" ]] && return 0
    if [[ "$1" == "$BUILD_FROM_STEP" ]]; then _build_started=1; return 0; fi
    log_skip "${1} (before BUILD_FROM_STEP=${BUILD_FROM_STEP})"
    return 1
}

# Where the scripts' listener.ora / tnsnames.ora live on a host for this scenario
net_dir() { printf '%s' "${E2E_REMOTE_TNS_ADMIN:-${ORACLE_HOME}/network/admin}"; }

# ---------------------------------------------------------------------------
# Answer variables derived from the scenario (read by the @VAR@ rule tokens)
# ---------------------------------------------------------------------------
derive_answers() {
    SYS_PASSWORD="$TEST_SYS_PASSWORD"
    ANS_STANDBY_HOST=$(oracle_hostname_of STANDBY)
    STANDBY_NAME="$SCN_STANDBY_NAME"
    STANDBY_SID=""
    [[ "$SCN_STANDBY_SID" != "$P_SID" ]] && STANDBY_SID="$SCN_STANDBY_SID"
    STORAGE_CHOICE=""
    [[ "${WANT_STORAGE_MODE:-traditional}" == "omf" ]] && STORAGE_CHOICE="2"
    Q1B_ANSWER=""
    [[ -n "${WANT_FS_MAP:-}" ]] && Q1B_ANSWER="y"
    if [[ -n "${WANT_STANDBY_FRA:-}" && "${WANT_STANDBY_FRA}" != "none" ]]; then
        ARCHIVE_CHOICE="1"
        STANDBY_FRA_PATH="${WANT_STANDBY_FRA%%:*}"
        STANDBY_FRA_SIZE="${WANT_STANDBY_FRA#*:}"; [[ "$STANDBY_FRA_SIZE" == "$WANT_STANDBY_FRA" ]] && STANDBY_FRA_SIZE=""
        [[ -n "$STANDBY_FRA_SIZE" ]] && STANDBY_FRA_SIZE="${STANDBY_FRA_SIZE}G"
    else
        ARCHIVE_CHOICE="2"; STANDBY_FRA_PATH=""; STANDBY_FRA_SIZE=""
    fi
    [[ "${WANT_STORAGE_MODE:-}" == "omf" ]] && ARCHIVE_CHOICE=""   # not asked in OMF mode
    STANDBY_ARCHIVE_DIR="${WANT_STANDBY_ARCHIVE_DIR:-}"
    OMF_FILE_DEST="${WANT_OMF_FILE_DEST:-}"
    SRL_ANSWER=""; STANDBY_SRL_DIR=""
    [[ -n "${WANT_SEPARATE_SRL_DIR:-}" ]] && { SRL_ANSWER="y"; STANDBY_SRL_DIR="$WANT_SEPARATE_SRL_DIR"; }
    STANDBY_ORACLE_BASE="${WANT_STANDBY_ORACLE_BASE:-}"
    CONTROL_FILE_2_DIR="${WANT_CONTROL_FILE_2_DIR:-}"
    OBSERVER_USER="$TEST_OBSERVER_USER"
    OBSERVER_PASSWORD="$TEST_OBSERVER_PASSWORD"
    WALLET_PASSWORD="$TEST_WALLET_PASSWORD"
    OBS_ALREADY="n"
    case "${WANT_OBSERVER:-none}" in
        standby-host) OBS_PLACEMENT="1" ;;
        third-host)   OBS_PLACEMENT="2" ;;
        *)            OBS_PLACEMENT="3" ;;
    esac
    HOST3_NAME=$(oracle_hostname_of HOST3)
    TRIGGER_SCHEMA=""
    TRIGGER_PASSWORD="${TEST_TRIGGER_PASSWORD:-DgAdmin_2024#}"
    PRIMARY_ALIAS="$P_DB_UNIQUE_NAME"; STANDBY_ALIAS="$SCN_STANDBY_NAME"
    export SYS_PASSWORD ANS_STANDBY_HOST STANDBY_NAME STANDBY_SID STORAGE_CHOICE Q1B_ANSWER ARCHIVE_CHOICE \
        STANDBY_FRA_PATH STANDBY_FRA_SIZE STANDBY_ARCHIVE_DIR OMF_FILE_DEST SRL_ANSWER STANDBY_SRL_DIR \
        STANDBY_ORACLE_BASE CONTROL_FILE_2_DIR OBSERVER_USER OBSERVER_PASSWORD WALLET_PASSWORD \
        OBS_ALREADY OBS_PLACEMENT HOST3_NAME TRIGGER_SCHEMA TRIGGER_PASSWORD PRIMARY_ALIAS STANDBY_ALIAS
}

# Scenario-specific rules for step 2 (prepended, so they outrank the generic ones)
_step2_scenario_rules() {
    local m from to d n
    # Q1b: per-filesystem renames ("/home=/tmp" means first component /home -> /tmp)
    for m in ${WANT_FS_MAP:-}; do
        from="${m%%=*}"; to="${m#*=}"
        printf 'rule:Standby filesystem for %s \\([^)]*\\) \\[[^]]*\\]:\t%s\n' "$(printf '%s' "$from" | sed 's/[][\\.*^$]/\\&/g')" "$to"
    done
    # Review table: pick the row by its primary path, answer its number, then the new directory
    for m in ${WANT_PATH_OVERRIDES:-}; do
        from="${m%%=*}"; to="${m#*=}"
        local esc; esc=$(printf '%s' "$from" | sed 's/[][\\.*^$]/\\&/g')
        printf 'rule:^ *([0-9]+)\\) \\[(data|redo)\\] %s -> [^\\n]*\\n(?:.*\\n)*?Accept all mappings \\[Enter\\], or enter a number to edit:\t\\1\tonce\n' "$esc"
        printf "rule:New standby (data|redo) directory for '%s' \\\\[[^]]*\\\\]:\t%s\n" "$esc" "$to"
    done
    # A deliberate mistake (s11): same mechanism, wrong directory
    if [[ -n "${WANT_STEP2_MISTAKE:-}" ]]; then
        from="${WANT_STEP2_MISTAKE%%=*}"; to="${WANT_STEP2_MISTAKE#*=}"
        local esc; esc=$(printf '%s' "$from" | sed 's/[][\\.*^$]/\\&/g')
        printf 'rule:^ *([0-9]+)\\) \\[(data|redo)\\] %s -> [^\\n]*\\n(?:.*\\n)*?Accept all mappings \\[Enter\\], or enter a number to edit:\t\\1\tonce\n' "$esc"
        printf "rule:New standby (data|redo) directory for '%s' \\\\[[^]]*\\\\]:\t%s\n" "$esc" "$to"
    fi
    # OMF online-log destinations
    for m in ${WANT_ONLINE_LOG_DESTS:-}; do
        n="${m%%=*}"; d="${m#*=}"
        printf 'rule:Standby db_create_online_log_dest_%s \\(primary: [^)]*\\) \\[[^]]*\\]:\t%s\n' "$n" "$d"
    done
}

# ---------------------------------------------------------------------------
# "-n first": the dry run must change nothing
# ---------------------------------------------------------------------------
_state_fingerprint() {
    local token="$1"
    ssh_cmd "$token" "
cd $(shq "$NFS_SHARE") 2>/dev/null && find . -type f ! -path './logs/*' ! -path './state/*' -exec md5sum {} + 2>/dev/null | sort | md5sum
sqlplus -s / as sysdba <<'SQLEOF' 2>/dev/null | md5sum
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT name || '=' || value FROM v\$parameter WHERE isdefault = 'FALSE' ORDER BY name;
SELECT 'srl=' || COUNT(*) FROM v\$standby_log;
SELECT 'fl=' || force_logging FROM v\$database;
EXIT;
SQLEOF
ls -la $(shq "$(net_dir)") 2>/dev/null | md5sum
ps -eo args | grep -c '[o]ra_pmon_' " | tr '\n' ' '
}

check_mode_first() {
    # $1 token, $2 step name, rest: rules + -- cmd
    [[ "${WANT_CHECK_MODE_FIRST:-no}" == "yes" ]] || return 0
    local token="$1" name="$2"; shift 2
    local before after
    before=$(_state_fingerprint "$token")
    local args=() a cmd_seen=0
    for a in "$@"; do
        args+=("$a")
        if [[ $cmd_seen -eq 0 && "$a" == "--" ]]; then cmd_seen=1; fi
    done
    # append -n to the command (after the script path, before its args)
    local out=() i=0 script_done=0
    for a in "${args[@]}"; do
        out+=("$a")
        if [[ $script_done -eq 0 && $cmd_seen -eq 1 && "$a" == ./* ]]; then out+=("-n"); script_done=1; fi
    done
    run_step "$token" "${name}_check" "${out[@]}"
    local rc=$STEP_RC
    after=$(_state_fingerprint "$token")
    if [[ "$rc" -eq 0 ]]; then log_pass "${name} -n: exit 0"; else log_fail "${name} -n: exit ${rc}"; return 1; fi
    if [[ "$before" == "$after" ]]; then log_pass "${name} -n: nothing changed (share, parameters, SRLs, net files, instances)"; else log_fail "${name} -n: state changed during check mode"; return 1; fi
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
step1() {
    _step_wanted step1 || return 0
    log_phase "STEP 1: gather primary info"
    check_mode_first PRIMARY build/step1 common -- ./primary/01_gather_primary_info.sh || return 1
    run_step PRIMARY build/step1 common -- ./primary/01_gather_primary_info.sh
    assert_exit "$STEP_RC" 0 "step 1" || { log_tail 25 "$STEP_OUT"; return 1; }
    assert_file PRIMARY "${NFS_SHARE}/primary_info_${P_DB_UNIQUE_NAME}.env" "primary_info on the share" || return 1
    assert_file PRIMARY "${NFS_SHARE}/orapw${P_SID}" "password file copy on the share" || return 1
    assert_grep PRIMARY "^LOG_MODE=.*ARCHIVELOG" "${NFS_SHARE}/primary_info_${P_DB_UNIQUE_NAME}.env" "ARCHIVELOG recorded" || return 1
    assert_grep PRIMARY "^LISTENER_PORT=\"?${SCN_PORT}\"?" "${NFS_SHARE}/primary_info_${P_DB_UNIQUE_NAME}.env" "listener port ${SCN_PORT} detected" || return 1
    if [[ "$P_PRE_SRL" == "undersized" ]]; then
        assert_output "$STEP_OUT" "UNDERSIZED|undersized|smaller than" "step 1 warns about undersized SRLs" || true
    fi
}

step2() {
    _step_wanted step2 || return 0
    log_phase "STEP 2: generate standby configuration (${WANT_STORAGE_MODE:-traditional})"
    local rules=()
    while IFS= read -r l || [[ -n "$l" ]]; do [[ -n "$l" ]] && rules+=("$l"); done < <(_step2_scenario_rules)
    check_mode_first PRIMARY build/step2 ${rules[@]+"${rules[@]}"} step2 -- ./primary/02_generate_standby_config.sh || return 1
    run_step PRIMARY build/step2 ${rules[@]+"${rules[@]}"} step2 -- ./primary/02_generate_standby_config.sh
    assert_exit "$STEP_RC" 0 "step 2" || { log_tail 25 "$STEP_OUT"; return 1; }
    local env="${NFS_SHARE}/standby_config_${SCN_STANDBY_NAME}.env"
    assert_file PRIMARY "$env" "standby_config on the share" || return 1
    assert_file PRIMARY "${NFS_SHARE}/tnsnames_entries_${SCN_STANDBY_NAME}.ora" "TNS entries on the share" || return 1
    assert_grep PRIMARY "^STANDBY_HOSTNAME=.*${ANS_STANDBY_HOST}" "$env" "standby hostname" || return 1
    assert_grep PRIMARY "^STANDBY_DB_UNIQUE_NAME=.*${SCN_STANDBY_NAME}" "$env" "standby DB_UNIQUE_NAME" || return 1
    if [[ "${WANT_STORAGE_MODE:-}" == "omf" ]]; then
        assert_grep PRIMARY "^STANDBY_STORAGE_MODE=.*OMF" "$env" "OMF mode recorded" || return 1
        assert_grep PRIMARY "^STANDBY_DB_CREATE_FILE_DEST=.*${WANT_OMF_FILE_DEST}" "$env" "db_create_file_dest" || return 1
    else
        local m
        for m in ${WANT_FS_MAP:-}; do
            assert_grep PRIMARY "^STANDBY_FS_MAP=.*${m%%=*}=${m#*=}" "$env" "Q1b map ${m} persisted" || return 1
        done
        for m in ${WANT_PATH_OVERRIDES:-}; do
            assert_grep PRIMARY "${m%%=*},${m#*=}" "$env" "convert pair ${m%%=*} -> ${m#*=}" || return 1
        done
        [[ -n "${WANT_SEPARATE_SRL_DIR:-}" ]] && { assert_grep PRIMARY "^STANDBY_SRL_PATH=.*${WANT_SEPARATE_SRL_DIR}" "$env" "separate SRL dir" || return 1; }
        [[ -n "${WANT_CONTROL_FILE_2_DIR:-}" ]] && { assert_grep PRIMARY "^STANDBY_CONTROL_FILE_2_DIR=.*${WANT_CONTROL_FILE_2_DIR}" "$env" "second control file dir" || return 1; }
        if [[ -n "${WANT_STANDBY_FRA:-}" && "$WANT_STANDBY_FRA" != "none" ]]; then
            assert_grep PRIMARY "^USE_FRA_FOR_STANDBY=.*YES" "$env" "standby archives into a FRA" || return 1
        else
            assert_grep PRIMARY "^USE_FRA_FOR_STANDBY=.*NO" "$env" "standby archives to a directory" || return 1
        fi
    fi
    [[ -n "${WANT_STANDBY_ORACLE_BASE:-}" ]] && { assert_grep PRIMARY "^STANDBY_ORACLE_BASE=.*${WANT_STANDBY_ORACLE_BASE}" "$env" "standby ORACLE_BASE override" || return 1; }
    return 0
}

# s11: fix a wrong directory by editing the .env arrays and --regenerate
step2_regenerate_fix() {
    [[ -n "${WANT_STEP2_MISTAKE:-}" ]] || return 0
    log_section "Correcting the step 2 mistake: edit the .env path arrays, then --regenerate"
    local env="${NFS_SHARE}/standby_config_${SCN_STANDBY_NAME}.env"
    local wrong="${WANT_STEP2_MISTAKE#*=}" right="${WANT_STEP2_MISTAKE_FIX:?WANT_STEP2_MISTAKE_FIX must name the correct directory}"
    ssh_cmd PRIMARY "sed -i 's#${wrong}#${right}#g' $(shq "$env")" >/dev/null
    run_step PRIMARY build/step2_regen step2 -- ./primary/02_generate_standby_config.sh --regenerate
    assert_exit "$STEP_RC" 0 "step 2 --regenerate" || return 1
    assert_no_grep PRIMARY "${wrong}" "$env" "wrong directory gone from the .env" || return 1
    assert_grep PRIMARY "${right}" "$env" "corrected directory in the convert pairs" || return 1
}

step3() {
    _step_wanted step3 || return 0
    log_phase "STEP 3: set up the standby environment"
    check_mode_first STANDBY build/step3 step3 -- ./standby/03_setup_standby_env.sh || return 1
    run_step STANDBY build/step3 step3 -- ./standby/03_setup_standby_env.sh
    assert_exit "$STEP_RC" 0 "step 3" || { log_tail 25 "$STEP_OUT"; return 1; }
    assert_file STANDBY "${ORACLE_HOME}/dbs/orapw${SCN_STANDBY_SID}" "password file on the standby" || return 1
    assert_file STANDBY "${ORACLE_HOME}/dbs/init${SCN_STANDBY_SID}.ora" "pfile on the standby" || return 1
    assert_grep STANDBY "${SCN_STANDBY_NAME}" "$(net_dir)/listener.ora" "standby static registration" || return 1
    assert_grep STANDBY "${P_DB_UNIQUE_NAME}" "$(net_dir)/tnsnames.ora" "primary TNS entry on the standby" || return 1
    assert_grep STANDBY "${SCN_STANDBY_NAME}" "$(net_dir)/tnsnames.ora" "standby TNS entry on the standby" || return 1
    local d
    for d in ${WANT_SEPARATE_SRL_DIR:-} ${WANT_CONTROL_FILE_2_DIR:-}; do assert_file STANDBY "$d" "standby directory ${d}" || return 1; done
    local m; for m in ${WANT_PATH_OVERRIDES:-}; do assert_file STANDBY "${m#*=}" "overridden standby directory ${m#*=}" || return 1; done
    for m in ${WANT_ONLINE_LOG_DESTS:-}; do assert_file STANDBY "${m#*=}" "online log dest ${m#*=}" || return 1; done
}

step4() {
    _step_wanted step4 || return 0
    log_phase "STEP 4: prepare the primary for Data Guard"
    check_mode_first PRIMARY build/step4 common -- ./primary/04_prepare_primary_dg.sh || return 1
    run_step PRIMARY build/step4 common -- ./primary/04_prepare_primary_dg.sh
    assert_exit "$STEP_RC" 0 "step 4" || { log_tail 25 "$STEP_OUT"; return 1; }
    assert_sql PRIMARY "SELECT force_logging FROM v\$database;" "YES" "FORCE_LOGGING" || return 1
    assert_sql PRIMARY "SELECT value FROM v\$parameter WHERE name = 'dg_broker_start';" "TRUE" "dg_broker_start" || return 1
    assert_sql PRIMARY "SELECT value FROM v\$parameter WHERE name = 'standby_file_management';" "AUTO" "standby_file_management" || return 1
    assert_sql_num PRIMARY "SELECT COUNT(*) FROM v\$standby_log;" -ge $(( P_REDO_GROUPS + 1 )) "standby redo logs on the primary" || return 1
    assert_grep PRIMARY "${SCN_STANDBY_NAME}" "$(net_dir)/tnsnames.ora" "standby TNS entry on the primary" || return 1
    assert_grep PRIMARY "${P_DB_UNIQUE_NAME}" "$(net_dir)/listener.ora" "primary static registration" || return 1
    if [[ "$P_PRE_SRL" == "undersized" ]]; then
        assert_output "$STEP_OUT" "UNDERSIZED|undersized" "undersized pre-existing SRLs reported" || return 1
        assert_sql_num PRIMARY "SELECT COUNT(*) FROM v\$standby_log WHERE bytes < ${P_REDO_SIZE_MB} * 1048576;" -ge 1 "undersized SRLs NOT dropped automatically" || return 1
    fi
    local out; out=$(ssh_cmd PRIMARY "tnsping ${SCN_STANDBY_NAME} 2>&1 | tail -2")
    assert_output "$out" "OK \(" "tnsping standby alias from the primary" || true
}

# Light DML during the clone (P_LOAD_DURING_CLONE): runs until a stop file appears
_start_clone_load() {
    [[ "${P_LOAD_DURING_CLONE:-no}" == "yes" ]] || return 0
    ssh_cmd PRIMARY "
rm -f $(shq "$SCN_WORK")/load.stop
nohup bash -c '
i=0
while [[ ! -f $(shq "$SCN_WORK")/load.stop && \$i -lt 2000 ]]; do
  sqlplus -s ${MARK_USER}/${MARK_PASSWORD} <<SQLEOF >/dev/null 2>&1
INSERT INTO ${MARK_USER}.filler SELECT 900000 + level, RPAD(\x27l\x27, 1000, \x27l\x27) FROM dual CONNECT BY level <= 200;
COMMIT;
EXIT;
SQLEOF
  i=\$((i+1)); sleep 1
done' > $(shq "$SCN_WORK")/load.log 2>&1 &
echo started" >/dev/null
    log_info "DML load started on the primary (stops with ${SCN_WORK}/load.stop)"
}
_stop_clone_load() {
    [[ "${P_LOAD_DURING_CLONE:-no}" == "yes" ]] || return 0
    ssh_cmd PRIMARY "touch $(shq "$SCN_WORK")/load.stop" >/dev/null
    log_info "DML load stopped"
}

_step5_args() {
    local a=""
    [[ -n "${WANT_CLONE_CHANNELS:-}" ]] && a="$a --channels ${WANT_CLONE_CHANNELS}"
    [[ -n "${WANT_CLONE_RATE:-}" ]] && a="$a --rate ${WANT_CLONE_RATE}"
    printf '%s' "$a"
}

_assert_standby_up() {
    assert_sql STANDBY "SELECT database_role FROM v\$database;" "PHYSICAL STANDBY" "standby role" "$SCN_STANDBY_SID" || return 1
    assert_sql STANDBY "SELECT db_unique_name FROM v\$database;" "$SCN_STANDBY_NAME" "standby DB_UNIQUE_NAME" "$SCN_STANDBY_SID" || return 1
    wait_until 120 "MRP0 running on the standby" ssh_sql_is STANDBY "SELECT COUNT(*) FROM v\$managed_standby WHERE process = 'MRP0';" "1" "$SCN_STANDBY_SID" || return 1
}
ssh_sql_is() { [[ "$(ssh_sql "$1" "$2" "$4")" == "$3" ]]; }

step5() {
    _step_wanted step5 || return 0
    log_phase "STEP 5: clone the standby (RMAN duplicate)"
    local args; args=$(_step5_args)
    # -n must not even start the duplicate (nothing to assert beyond "no instance")
    check_mode_first STANDBY build/step5 step5 -- ./standby/05_clone_standby.sh $args || return 1

    if in_list lock-sys-before-step5 "${INJECT_FAULTS:-}"; then
        log_section "Fault: SYS locked on the primary before the first step 5"
        ssh_sql PRIMARY "ALTER USER sys ACCOUNT LOCK;" >/dev/null
        run_step STANDBY build/step5_locked step5 -- ./standby/05_clone_standby.sh $args
        assert_exit "$STEP_RC" 1 "step 5 refuses with SYS locked" || return 1
        assert_output "$STEP_OUT" "ORA-28000|LOCKED" "locked SYS named in the output with the fix" || return 1
        ssh_sql PRIMARY "ALTER USER sys ACCOUNT UNLOCK;" >/dev/null
        log_info "SYS unlocked; re-running step 5"
    fi
    if in_list kill-rman-during-step5 "${INJECT_FAULTS:-}"; then
        log_section "Fault: RMAN killed mid-duplicate"
        ssh_cmd STANDBY "nohup bash -c 'for i in \$(seq 1 300); do if pgrep -f \"rman.*cmdfile\" >/dev/null; then sleep 25; pkill -9 -f \"rman.*cmdfile\"; echo killed; exit 0; fi; sleep 2; done' > $(shq "$SCN_WORK")/killer.log 2>&1 &" >/dev/null
        run_step STANDBY build/step5_killed step5 -- ./standby/05_clone_standby.sh $args
        assert_exit "$STEP_RC" 1 "step 5 fails when RMAN dies" || return 1
        assert_output "$STEP_OUT" "RMAN duplicate failed|duplicate failed" "failure reported with the restart procedure" || return 1
        log_info "Restart procedure: shut down the half-built standby and remove its files, then re-run step 5"
        ssh_cmd STANDBY "sqlplus -s / as sysdba <<'SQLEOF' >/dev/null 2>&1
SHUTDOWN ABORT;
EXIT;
SQLEOF
rm -rf $(_rm_list $(_standby_dirs)) 2>/dev/null; true" "$SCN_STANDBY_SID" >/dev/null
    fi

    _start_clone_load
    run_step STANDBY build/step5 step5 -- ./standby/05_clone_standby.sh $args
    local rc=$STEP_RC
    _stop_clone_load
    assert_exit "$rc" 0 "step 5" || { log_tail 40 "$STEP_OUT"; return 1; }
    _assert_standby_up || return 1
    if [[ "${WANT_STORAGE_MODE:-}" != "omf" && -n "${WANT_STANDBY_FRA:-}" && "$WANT_STANDBY_FRA" != "none" ]]; then
        assert_sql STANDBY "SELECT value FROM v\$parameter WHERE name = 'db_recovery_file_dest';" "${WANT_STANDBY_FRA%%:*}" "standby FRA" "$SCN_STANDBY_SID" || return 1
    elif [[ "${WANT_STORAGE_MODE:-}" != "omf" ]]; then
        assert_sql_eq STANDBY "SELECT NVL(value, 'UNSET') FROM v\$parameter WHERE name = 'db_recovery_file_dest';" "UNSET" "standby has no FRA (primary's not inherited)" "$SCN_STANDBY_SID" || return 1
    fi
}

step6() {
    _step_wanted step6 || return 0
    log_phase "STEP 6: configure the broker"
    check_mode_first PRIMARY build/step6 step6 -- ./primary/06_configure_broker.sh || return 1
    run_step PRIMARY build/step6 step6 -- ./primary/06_configure_broker.sh
    assert_exit "$STEP_RC" 0 "step 6" || { log_tail 25 "$STEP_OUT"; return 1; }
    wait_until 240 "broker configuration SUCCESS" _broker_success || return 1
    assert_dgmgrl PRIMARY "SHOW DATABASE '${P_DB_UNIQUE_NAME}'" "Role: +PRIMARY" "primary in the broker" || return 1
    assert_dgmgrl PRIMARY "SHOW DATABASE '${SCN_STANDBY_NAME}'" "Role: +PHYSICAL STANDBY" "standby in the broker" || return 1
}
_broker_success() { ssh_dgmgrl PRIMARY "SHOW CONFIGURATION" | grep -A1 'Configuration Status' | grep -q SUCCESS; }

step7() {
    _step_wanted step7 || return 0
    log_phase "STEP 7: verify Data Guard"
    check_mode_first STANDBY build/step7 common -- ./standby/07_verify_dataguard.sh || return 1
    run_step STANDBY build/step7 common -- ./standby/07_verify_dataguard.sh
    assert_exit "$STEP_RC" 0 "step 7" || { log_tail 25 "$STEP_OUT"; return 1; }
    assert_output "$STEP_OUT" "HEALTHY|WARNING" "step 7 verdict HEALTHY or WARNING" || return 1
    ssh_sql PRIMARY "ALTER SYSTEM SWITCH LOGFILE;" >/dev/null
    sleep 5
    assert_sql_eq STANDBY "SELECT COUNT(*) FROM v\$archive_gap;" "0" "no archive gap" "$SCN_STANDBY_SID" || true
}

step13() {
    [[ "${WANT_PROTECTION:-maxperf}" == "maxavail" && "${WANT_FSFO:-no}" != "yes" ]] || return 0
    _step_wanted step13 || return 0
    log_phase "STEP 13: maximum availability without FSFO"
    check_mode_first PRIMARY build/step13 step13 -- ./primary/13_set_max_availability.sh || return 1
    run_step PRIMARY build/step13 step13 -- ./primary/13_set_max_availability.sh
    assert_exit "$STEP_RC" 0 "step 13" || { log_tail 25 "$STEP_OUT"; return 1; }
    assert_sql PRIMARY "SELECT protection_mode FROM v\$database;" "MAXIMUM AVAILABILITY" "protection mode" || return 1
    assert_dgmgrl PRIMARY "SHOW DATABASE '${P_DB_UNIQUE_NAME}' 'LogXptMode'" "FASTSYNC" "LogXptMode=FASTSYNC on the primary" || return 1
    assert_dgmgrl PRIMARY "SHOW DATABASE '${SCN_STANDBY_NAME}' 'LogXptMode'" "FASTSYNC" "LogXptMode=FASTSYNC on the standby" || return 1
    wait_until 180 "broker SUCCESS after the mode change" _broker_success || return 1
    run_step PRIMARY build/step13_rerun step13 -- ./primary/13_set_max_availability.sh
    assert_exit "$STEP_RC" 0 "step 13 re-run" || return 1
    assert_output "$STEP_OUT" "already MAXIMUM AVAILABILITY" "idempotent re-run reports the compliant state" || return 1
    [[ "$(step_prompts build/step13_rerun | wc -l | tr -d ' ')" == "0" ]] && log_pass "step 13 re-run asked no question" || { log_fail "step 13 re-run prompted"; return 1; }
}

step9() {
    [[ "${WANT_FSFO:-no}" == "yes" ]] || return 0
    _step_wanted step9 || return 0
    log_phase "STEP 9: configure Fast-Start Failover"
    check_mode_first PRIMARY build/step9 step9 -- ./primary/09_configure_fsfo.sh || return 1
    run_step PRIMARY build/step9 step9 -- env FSFO_THRESHOLD="$FSFO_THRESHOLD" ./primary/09_configure_fsfo.sh
    assert_exit "$STEP_RC" 0 "step 9" || { log_tail 30 "$STEP_OUT"; return 1; }
    assert_dgmgrl PRIMARY "SHOW CONFIGURATION" "Fast-Start Failover: *Enabled" "FSFO enabled" || return 1
    assert_sql PRIMARY "SELECT protection_mode FROM v\$database;" "MAXIMUM AVAILABILITY" "protection mode" || return 1
    local u; u=$(upper "$TEST_OBSERVER_USER"); [[ "$P_CDB" == "yes" && "$u" != C##* ]] && u="C##${u}"
    OBSERVER_USER_EFFECTIVE="$u"; export OBSERVER_USER_EFFECTIVE
    assert_sql PRIMARY "SELECT username FROM v\$pwfile_users WHERE username = '${u}' AND sysdg = 'TRUE';" "$u" "observer user holds SYSDG" || return 1
    assert_file PRIMARY "${NFS_SHARE}/orapw${P_SID}" "refreshed password file copy on the share" || return 1
    if [[ "${WANT_OBSERVER:-none}" == "third-host" ]]; then
        assert_file PRIMARY "${REPO_DIR}/observer_bundle_${P_DB_UNIQUE_NAME}/02_setup_observer_host.sh" "add_observer bundle generated" || return 1
    fi
}

step10() {
    [[ "${WANT_FSFO:-no}" == "yes" && "${WANT_OBSERVER:-none}" != "none" ]] || return 0
    _step_wanted step10 || return 0
    if [[ "${WANT_OBSERVER}" == "standby-host" ]]; then
        log_phase "STEP 10: observer on the standby host (fsfo/observer.sh)"
        check_mode_first STANDBY build/step10_setup observer -- ./fsfo/observer.sh setup || return 1
        run_step STANDBY build/step10_setup observer -- ./fsfo/observer.sh setup
        assert_exit "$STEP_RC" 0 "observer.sh setup" || { log_tail 25 "$STEP_OUT"; return 1; }
        run_step STANDBY build/step10_start observer -- ./fsfo/observer.sh start
        assert_exit "$STEP_RC" 0 "observer.sh start" || { log_tail 25 "$STEP_OUT"; return 1; }
        run_step STANDBY build/step10_status observer -- ./fsfo/observer.sh status
        assert_exit "$STEP_RC" 0 "observer.sh status" || return 1
    else
        log_phase "STEP 10: observer on the third host (add_observer bundle)"
        local bundle="observer_bundle_${P_DB_UNIQUE_NAME}"
        ssh_cmd PRIMARY "cd $(shq "$REPO_DIR") && tar cf - ${bundle}" > "${SCN_LOG}/build/${bundle}.tar" || { log_fail "bundle tar"; return 1; }
        ssh_copy_to HOST3 "${SCN_LOG}/build/${bundle}.tar" "/home/${SSH_USER}/${bundle}.tar"
        ssh_cmd HOST3 "cd && rm -rf ${bundle} && tar xf ${bundle}.tar && chmod +x ${bundle}/*.sh && echo ok" | grep -q ok || { log_fail "bundle unpacked on HOST3"; return 1; }
        local saved_repo="$REPO_DIR"; REPO_DIR="/home/${SSH_USER}/${bundle}"
        run_step HOST3 build/step10_host3_setup add_observer -- ./02_setup_observer_host.sh
        local rc=$STEP_RC
        [[ $rc -eq 0 ]] && { run_step HOST3 build/step10_host3_start add_observer -- ./03_observer_ctl.sh start; rc=$STEP_RC; }
        [[ $rc -eq 0 ]] && { run_step HOST3 build/step10_host3_verify add_observer -- ./04_verify_observer.sh; rc=$STEP_RC; }
        [[ $rc -eq 0 ]] && { run_step HOST3 build/step10_host3_status add_observer -- ./03_observer_ctl.sh status; rc=$STEP_RC; }
        REPO_DIR="$saved_repo"
        assert_exit "$rc" 0 "third-host observer setup/start/verify/status" || { log_tail 25 "$STEP_OUT"; return 1; }
    fi
    wait_until 90 "broker reports the observer present" _observer_present || return 1
}
_observer_present() { ssh_sql PRIMARY "SELECT fs_failover_observer_present FROM v\$database;" | grep -q YES; }

step_services() {
    [[ -n "${WANT_NEW_SERVICES:-}" ]] || return 0
    _step_wanted services || return 0
    log_phase "SERVICES: create role-aware services (${WANT_NEW_SERVICES})"
    local spec cont svc
    for spec in $WANT_NEW_SERVICES; do
        cont="${spec%%:*}"; svc="${spec#*:}"
        if [[ "$(lower "$cont")" == "cdb" ]]; then
            run_step PRIMARY "build/service_${svc}" service -- ./trigger/create_cdb_service.sh --service "$svc" --taf
        else
            run_step PRIMARY "build/service_${svc}" service -- ./trigger/create_pdb_service.sh --pdb "$cont" --service "$svc" --taf
        fi
        assert_exit "$STEP_RC" 0 "service ${spec}" || { log_tail 20 "$STEP_OUT"; return 1; }
        assert_sql_num PRIMARY "SELECT COUNT(*) FROM v\$active_services WHERE LOWER(name) = LOWER('${svc}');" -ge 1 "service ${svc} running on the primary" || return 1
    done
}

step11() {
    [[ "${WANT_ROLE_TRIGGER:-none}" != "none" ]] || return 0
    _step_wanted step11 || return 0
    local script owner
    case "$WANT_ROLE_TRIGGER" in
        sys)       script=./trigger/create_role_trigger.sh; owner=SYS ;;
        dedicated) script=./trigger/create_role_trigger_dedicated_user.sh; owner=DG_ADMIN ;;
        cdb)       script=./trigger/create_role_trigger_cdb.sh; owner=SYS ;;
        *) log_fail "unknown WANT_ROLE_TRIGGER=${WANT_ROLE_TRIGGER}"; return 1 ;;
    esac
    log_phase "STEP 11: role-aware service trigger (${WANT_ROLE_TRIGGER})"
    check_mode_first PRIMARY build/step11 step11 -- "$script" || return 1
    run_step PRIMARY build/step11 step11 -- "$script"
    assert_exit "$STEP_RC" 0 "step 11" || { log_tail 25 "$STEP_OUT"; return 1; }
    assert_sql PRIMARY "SELECT status FROM dba_objects WHERE object_name = 'DG_SERVICE_MGR' AND object_type = 'PACKAGE BODY' AND owner = '${owner}';" "VALID" "${owner}.DG_SERVICE_MGR body VALID" || return 1
    assert_sql PRIMARY "SELECT status FROM dba_triggers WHERE trigger_name = 'TRG_MANAGE_SERVICES_ROLE_CHG' AND owner = '${owner}';" "ENABLED" "role-change trigger ENABLED" || return 1
    assert_sql PRIMARY "SELECT status FROM dba_triggers WHERE trigger_name = 'TRG_MANAGE_SERVICES_STARTUP' AND owner = '${owner}';" "ENABLED" "startup trigger ENABLED" || return 1
    # re-run: replaces in place
    run_step PRIMARY build/step11_rerun step11 -- "$script"
    assert_exit "$STEP_RC" 0 "step 11 re-run (replace)" || return 1
    ROLE_TRIGGER_OWNER="$owner"; export ROLE_TRIGGER_OWNER
}

step_wallet() {
    [[ "${WANT_WALLET:-no}" == "yes" ]] || return 0
    _step_wanted wallet || return 0
    log_phase "WALLET: common/setup_dg_wallet.sh on both hosts"
    run_step PRIMARY build/wallet_primary wallet -- ./common/setup_dg_wallet.sh -w "${SCN_WORK}/wallet"
    assert_exit "$STEP_RC" 0 "wallet on the primary" || { log_tail 20 "$STEP_OUT"; return 1; }
    local saved="$E2E_REMOTE_SID"; E2E_REMOTE_SID="$SCN_STANDBY_SID"
    run_step STANDBY build/wallet_standby wallet -- ./common/setup_dg_wallet.sh -w "${SCN_WORK}/wallet"
    E2E_REMOTE_SID="$saved"
    assert_exit "$STEP_RC" 0 "wallet on the standby" || { log_tail 20 "$STEP_OUT"; return 1; }
    assert_grep PRIMARY "WALLET_LOCATION" "$(net_dir)/sqlnet.ora" "sqlnet.ora points at the wallet (primary)" || return 1
}

step_handoff() {
    [[ "${WANT_HANDOFF:-yes}" == "yes" ]] || return 0
    _step_wanted handoff || return 0
    log_phase "HANDOFF: primary/10_generate_handoff_report.sh"
    check_mode_first PRIMARY build/handoff common -- ./primary/10_generate_handoff_report.sh || return 1
    run_step PRIMARY build/handoff common -- ./primary/10_generate_handoff_report.sh
    assert_exit "$STEP_RC" 0 "handoff report" || { log_tail 25 "$STEP_OUT"; return 1; }
    local base="${NFS_SHARE}/dg_handoff_${P_DB_UNIQUE_NAME}" f
    for f in .md .html .json _tnsnames.ora _jdbc.properties _verify.sh; do
        assert_file PRIMARY "${base}${f}" "handoff ${f}" || return 1
    done
    ssh_cmd PRIMARY "cat $(shq "${base}.md")" > "${SCN_LOG}/build/handoff.md"
    ssh_cmd PRIMARY "cat $(shq "${base}.json")" > "${SCN_LOG}/build/handoff.json"
    ssh_cmd PRIMARY "cat $(shq "${base}_verify.sh")" > "${SCN_LOG}/build/handoff_verify.sh"
    assert_output "$(cat "${SCN_LOG}/build/handoff.md")" "^\*\*Verdict:?\*\*.*(HEALTHY|WARNING)|Verdict.*(HEALTHY|WARNING)" "handoff verdict HEALTHY/WARNING" || true
}

build_scenario() {
    mkdir -p "${SCN_LOG}/build"
    derive_answers
    log_phase "BUILD: ${SCN_TITLE:-$SCN_ID}"
    step1 && step2 && step2_regenerate_fix && step3 && step4 && step5 && step6 && step7 || return 1
    if [[ -n "${WANT_STEP2_MISTAKE:-}" ]]; then
        log_section "s11: re-run step 6 over the existing configuration"
        run_step PRIMARY build/step6_rerun step6 -- ./primary/06_configure_broker.sh
        assert_exit "$STEP_RC" 0 "step 6 re-run" || return 1
        wait_until 240 "broker SUCCESS after the re-run" _broker_success || return 1
    fi
    if [[ "${WANT_STANDBY_FLASHBACK:-no}" == "yes" ]]; then
        log_section "Operator action: Flashback Database on the standby (no setup script does this)"
        ssh_cmd STANDBY "sqlplus -s / as sysdba <<'SQLEOF'
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
ALTER DATABASE FLASHBACK ON;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;
EXIT;
SQLEOF" "$SCN_STANDBY_SID" >/dev/null
        assert_sql STANDBY "SELECT flashback_on FROM v\$database;" "YES" "flashback on the standby" "$SCN_STANDBY_SID" || return 1
    fi
    step13 && step9 && step10 && step_services && step11 && step_wallet && step_handoff || return 1
    log_pass "BUILD complete for ${SCN_ID}"
}

build_cleanup() {
    derive_answers
    case "${WANT_CLEANUP:-default}" in
        none) return 0 ;;
        all)  log_phase "STEP 12: cleanup_nfs_artifacts.sh --all"
              run_step PRIMARY build/step12 cleanup -- ./common/cleanup_nfs_artifacts.sh --all -c "${NFS_SHARE}/standby_config_${SCN_STANDBY_NAME}.env"
              assert_exit "$STEP_RC" 0 "step 12 --all" || return 1
              assert_no_file PRIMARY "${NFS_SHARE}/standby_config_${SCN_STANDBY_NAME}.env" "config .env removed by --all" || return 1
              assert_no_file PRIMARY "${NFS_SHARE}/dg_handoff_${P_DB_UNIQUE_NAME}.md" "handoff removed by --all" || return 1 ;;
        *)    log_phase "STEP 12: cleanup_nfs_artifacts.sh (default)"
              run_step PRIMARY build/step12 cleanup -- ./common/cleanup_nfs_artifacts.sh -c "${NFS_SHARE}/standby_config_${SCN_STANDBY_NAME}.env"
              assert_exit "$STEP_RC" 0 "step 12" || return 1
              assert_no_file PRIMARY "${NFS_SHARE}/orapw${P_SID}" "password file copy removed" || return 1
              assert_file PRIMARY "${NFS_SHARE}/standby_config_${SCN_STANDBY_NAME}.env" "config .env kept by the default cleanup" || return 1 ;;
    esac
}
