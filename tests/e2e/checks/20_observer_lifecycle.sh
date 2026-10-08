#!/usr/bin/env bash
# check: fsfo/observer.sh stop/start/restart/status round trip, and -n start
# changes nothing (observer on the standby host only)
check_observer_lifecycle() {
    [[ "${WANT_FSFO:-no}" == "yes" && "${WANT_OBSERVER:-none}" == "standby-host" ]] || return 2
    local saved="$E2E_REMOTE_SID"; E2E_REMOTE_SID="$SCN_STANDBY_SID"
    run_step STANDBY checks/observer_stop observer -- ./fsfo/observer.sh stop
    assert_exit "$STEP_RC" 0 "observer.sh stop" || { E2E_REMOTE_SID="$saved"; return 1; }
    wait_until 60 "broker reports no observer" _observer_absent || { E2E_REMOTE_SID="$saved"; return 1; }
    run_step STANDBY checks/observer_status_down observer -- ./fsfo/observer.sh status
    [[ "$STEP_RC" -ne 0 ]] && log_pass "observer.sh status exits non-zero while stopped" || { log_fail "observer.sh status exited 0 with no observer"; E2E_REMOTE_SID="$saved"; return 1; }
    local pid_before; pid_before=$(ssh_cmd STANDBY "ls -la \$HOME/fsfo_observer* 2>/dev/null | md5sum")
    run_step STANDBY checks/observer_check_start observer -- ./fsfo/observer.sh -n start
    assert_exit "$STEP_RC" 0 "observer.sh -n start" || { E2E_REMOTE_SID="$saved"; return 1; }
    [[ "$(ssh_cmd STANDBY "ls -la \$HOME/fsfo_observer* 2>/dev/null | md5sum")" == "$pid_before" ]] && log_pass "-n start changed nothing" || { log_fail "-n start touched the observer directory"; E2E_REMOTE_SID="$saved"; return 1; }
    _observer_absent && log_pass "-n start did not start an observer" || { log_fail "-n start started an observer"; E2E_REMOTE_SID="$saved"; return 1; }
    run_step STANDBY checks/observer_start observer -- ./fsfo/observer.sh start
    assert_exit "$STEP_RC" 0 "observer.sh start" || { E2E_REMOTE_SID="$saved"; return 1; }
    wait_until 90 "observer present again" _observer_present || { E2E_REMOTE_SID="$saved"; return 1; }
    run_step STANDBY checks/observer_restart observer -- ./fsfo/observer.sh restart
    assert_exit "$STEP_RC" 0 "observer.sh restart" || { E2E_REMOTE_SID="$saved"; return 1; }
    wait_until 90 "observer present after the restart" _observer_present || { E2E_REMOTE_SID="$saved"; return 1; }
    run_step STANDBY checks/observer_status observer -- ./fsfo/observer.sh status
    E2E_REMOTE_SID="$saved"
    assert_exit "$STEP_RC" 0 "observer.sh status" || return 1
}
_observer_absent() { ! _observer_present; }
