#!/usr/bin/env bash
# check: a -v (xtrace) run never prints the SYS password (step 7 reads and
# uses it); checked on the live output and on the pty log
check_verbose_no_password() {
    run_step STANDBY checks/step7_verbose common -- ./standby/07_verify_dataguard.sh -v
    assert_exit "$STEP_RC" 0 "step 7 -v" || { log_tail 15 "$STEP_OUT"; return 1; }
    assert_no_output "$STEP_OUT" "$(printf '%s' "$TEST_SYS_PASSWORD" | sed 's/[][\\.*^$]/\\&/g')" "SYS password absent from the -v output" || return 1
    if grep -a -qF -- "$TEST_SYS_PASSWORD" "${SCN_LOG}/checks/step7_verbose.tty"; then
        log_fail "SYS password found in the pty log of the -v run"; return 1
    fi
    log_pass "SYS password absent from the pty log"
    assert_output "$STEP_OUT" "^[+]+ " "xtrace really was on" || return 1
}
