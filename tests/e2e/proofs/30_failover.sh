#!/usr/bin/env bash
# proof: SHUTDOWN ABORT the primary; the observer fails over within the
# threshold; the old primary is reinstated once mounted; then switch back
# (PROVE_FAILOVER=yes, needs FSFO + observer + flashback on both)
proof_failover() {
    [[ "${PROVE_FAILOVER:-no}" == "yes" ]] || return 2
    [[ "${WANT_FSFO:-no}" == "yes" ]] || { log_fail "PROVE_FAILOVER without WANT_FSFO"; return 1; }
    assert_sql PRIMARY "SELECT fs_failover_status FROM v\$database;" "SYNCHRONIZED" "FSFO synchronized before the failover" || return 1
    assert_sql PRIMARY "SELECT fs_failover_observer_present FROM v\$database;" "YES" "observer present" || return 1
    local n0; n0=$(mark_count)
    local t0; t0=$(now_s)
    log_info "SHUTDOWN ABORT on the primary ${P_DB_UNIQUE_NAME}"
    ssh_cmd PRIMARY "sqlplus -s / as sysdba <<'SQLEOF'
SHUTDOWN ABORT;
EXIT;
SQLEOF" >/dev/null
    local budget=$(( FSFO_THRESHOLD + 180 ))
    wait_until "$budget" "automatic failover: ${SCN_STANDBY_NAME} became PRIMARY" _is_role STANDBY "$SCN_STANDBY_SID" PRIMARY || return 1
    log_info "failover completed $(( $(now_s) - t0 ))s after the abort (threshold ${FSFO_THRESHOLD}s)"
    local scn; scn=$(ssh_sql_raw STANDBY "INSERT INTO ${MARK_USER}.marks (label) VALUES ('after-failover ${SCN_ID}');
COMMIT;
SELECT TO_CHAR(current_scn) FROM v\$database;" "$SCN_STANDBY_SID" | tail -1 | tr -d '[:space:]')
    [[ "$scn" =~ ^[0-9]+$ ]] && log_pass "row written on the failover primary" || { log_fail "write on the failover primary failed: ${scn}"; return 1; }
    log_info "STARTUP MOUNT the old primary so the observer can reinstate it"
    ssh_cmd PRIMARY "sqlplus -s / as sysdba <<'SQLEOF'
STARTUP MOUNT;
EXIT;
SQLEOF" >/dev/null
    wait_until 600 "old primary reinstated as PHYSICAL STANDBY" _is_role PRIMARY "$P_SID" "PHYSICAL STANDBY" || return 1
    wait_until 300 "broker SUCCESS after the reinstate" broker_success_from STANDBY "$SCN_STANDBY_SID" || return 1
    # restore the original roles so the rest of the scenario (and teardown) sees the usual layout
    local out; out=$(dgmgrl_sys STANDBY "$(standby_alias)" "SWITCHOVER TO '${P_DB_UNIQUE_NAME}'" "$SCN_STANDBY_SID")
    printf '%s\n' "$out" > "${SCN_LOG}/proofs/failover_switchback.out"
    assert_output "$out" "Switchover succeeded" "switchover back to ${P_DB_UNIQUE_NAME}" || { log_tail 15 "$out"; return 1; }
    wait_until 180 "${P_DB_UNIQUE_NAME} is PRIMARY again" _is_role PRIMARY "$P_SID" PRIMARY || return 1
    wait_until 300 "broker SUCCESS after the switchback" broker_success || return 1
    local n1; n1=$(mark_count)
    [[ "$n1" == "$(( n0 + 1 ))" ]] && log_pass "the failover-time row survived the reinstate (${n1} rows)" || { log_fail "mark count ${n1}, expected $(( n0 + 1 ))"; return 1; }
    assert_sql PRIMARY "SELECT fs_failover_observer_present FROM v\$database;" "YES" "observer still present after the roundtrip" || return 1
}
_is_role() { [[ "$(role_of "$1" "$2")" == "$(printf '%s' "$3" | tr -d ' ')" ]]; }
broker_success_from() { ssh_dgmgrl "$1" "SHOW CONFIGURATION" "$2" | grep -A1 'Configuration Status' | grep -q SUCCESS; }
