#!/usr/bin/env bash
# check: re-running step 5 on the healthy standby and declining the typed
# confirmation changes nothing - no SHUTDOWN ABORT, same instance, MRP on
# (PROVE_STEP5_DECLINE)
check_step5_decline() {
    [[ "${PROVE_STEP5_DECLINE:-no}" == "yes" ]] || return 2
    local start0 files0
    start0=$(ssh_sql STANDBY "SELECT TO_CHAR(startup_time, 'YYYYMMDDHH24MISS') FROM v\$instance;" "$SCN_STANDBY_SID")
    files0=$(ssh_sql STANDBY "SELECT COUNT(*) FROM v\$datafile;" "$SCN_STANDBY_SID")
    local saved="$E2E_REMOTE_SID"; E2E_REMOTE_SID="$SCN_STANDBY_SID"
    run_step STANDBY checks/step5_decline "rule:Type '${SCN_STANDBY_NAME}' to continue:	no" step5 -- ./standby/05_clone_standby.sh
    E2E_REMOTE_SID="$saved"
    assert_exit "$STEP_RC" 1 "declined step 5 exits 1" || { log_tail 15 "$STEP_OUT"; return 1; }
    assert_sql_eq STANDBY "SELECT TO_CHAR(startup_time, 'YYYYMMDDHH24MISS') FROM v\$instance;" "$start0" "standby instance not restarted" "$SCN_STANDBY_SID" || return 1
    assert_sql_eq STANDBY "SELECT COUNT(*) FROM v\$datafile;" "$files0" "datafile count unchanged" "$SCN_STANDBY_SID" || return 1
    assert_sql STANDBY "SELECT database_role FROM v\$database;" "PHYSICAL STANDBY" "still a physical standby" "$SCN_STANDBY_SID" || return 1
    mrp_running && log_pass "MRP still running" || { log_fail "MRP not running after the declined re-run"; return 1; }
}
