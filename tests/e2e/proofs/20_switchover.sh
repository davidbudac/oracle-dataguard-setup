#!/usr/bin/env bash
# proof: switch over, write on the new primary, switch back, read both marks;
# with a role trigger deployed, user services must follow the PRIMARY role
# (PROVE_SWITCHOVER=roundtrip)
_services_on() {   # token sid -> running user services (lowercase, sorted)
    ssh_sql_raw "$1" "SELECT LOWER(s.name) FROM v\$active_services s
WHERE s.name NOT LIKE 'SYS\$%' AND s.name NOT LIKE '%XDB' AND s.name NOT LIKE '%_CFG' AND s.name NOT LIKE '%_DGMGRL'
  AND LOWER(s.name) NOT IN (
    SELECT LOWER(d.name) FROM v\$database d
    UNION SELECT LOWER(d.db_unique_name) FROM v\$database d
    UNION SELECT LOWER(c.name) FROM v\$containers c
    UNION SELECT LOWER(d.name || '.' || p.value) FROM v\$database d, v\$parameter p WHERE p.name = 'db_domain' AND p.value IS NOT NULL
    UNION SELECT LOWER(c.name || '.' || p.value) FROM v\$containers c, v\$parameter p WHERE p.name = 'db_domain' AND p.value IS NOT NULL)
ORDER BY 1;" "$2" | tr '\n' ' '
}
proof_switchover() {
    [[ "${PROVE_SWITCHOVER:-none}" == "roundtrip" ]] || return 2
    local n0 before_svc
    n0=$(mark_count)
    before_svc=$(_services_on PRIMARY "$P_SID")
    log_info "user services on the primary before: ${before_svc:-none}"
    wait_until 120 "broker SUCCESS before the switchover" broker_success || return 1
    local out; out=$(dgmgrl_sys PRIMARY "$(primary_alias)" "SWITCHOVER TO '${SCN_STANDBY_NAME}'")
    printf '%s\n' "$out" > "${SCN_LOG}/proofs/switchover_1.out"
    assert_output "$out" "Switchover succeeded" "switchover to ${SCN_STANDBY_NAME}" || { log_tail 15 "$out"; return 1; }
    wait_until 180 "${SCN_STANDBY_NAME} is PRIMARY" _is_role STANDBY "$SCN_STANDBY_SID" PRIMARY || return 1
    wait_until 180 "${P_DB_UNIQUE_NAME} is PHYSICAL STANDBY" _is_role PRIMARY "$P_SID" "PHYSICAL STANDBY" || return 1
    # write on the new primary
    local scn; scn=$(ssh_sql_raw STANDBY "INSERT INTO ${MARK_USER}.marks (label) VALUES ('after-switchover ${SCN_ID}');
COMMIT;
SELECT TO_CHAR(current_scn) FROM v\$database;" "$SCN_STANDBY_SID" | tail -1 | tr -d '[:space:]')
    [[ "$scn" =~ ^[0-9]+$ ]] && log_pass "row written on the new primary (SCN ${scn})" || { log_fail "write on the new primary failed: ${scn}"; _switch_back; return 1; }
    if [[ "${WANT_ROLE_TRIGGER:-none}" != "none" && -n "$before_svc" ]]; then
        sleep 20
        local new_svc old_svc
        new_svc=$(_services_on STANDBY "$SCN_STANDBY_SID"); old_svc=$(_services_on PRIMARY "$P_SID")
        [[ "$new_svc" == "$before_svc" ]] && log_pass "user services started on the new primary: ${new_svc}" || { log_fail "services on the new primary '${new_svc}' != '${before_svc}'"; _switch_back; return 1; }
        [[ -z "$old_svc" ]] && log_pass "no user service left on the new standby" || { log_fail "services still running on the new standby: ${old_svc}"; _switch_back; return 1; }
    fi
    wait_until 180 "broker SUCCESS after the first switchover" broker_success_from STANDBY "$SCN_STANDBY_SID" || { _switch_back; return 1; }
    out=$(dgmgrl_sys STANDBY "$(standby_alias)" "SWITCHOVER TO '${P_DB_UNIQUE_NAME}'" "$SCN_STANDBY_SID")
    printf '%s\n' "$out" > "${SCN_LOG}/proofs/switchover_2.out"
    assert_output "$out" "Switchover succeeded" "switchover back to ${P_DB_UNIQUE_NAME}" || { log_tail 15 "$out"; return 1; }
    wait_until 180 "${P_DB_UNIQUE_NAME} is PRIMARY again" _is_role PRIMARY "$P_SID" PRIMARY || return 1
    wait_until 180 "${SCN_STANDBY_NAME} is PHYSICAL STANDBY again" _is_role STANDBY "$SCN_STANDBY_SID" "PHYSICAL STANDBY" || return 1
    wait_until 180 "broker SUCCESS after the roundtrip" broker_success || return 1
    local n1; n1=$(mark_count)
    [[ "$n1" == "$(( n0 + 1 ))" ]] && log_pass "both marks readable on the original primary (${n1} rows)" || { log_fail "mark count ${n1}, expected $(( n0 + 1 ))"; return 1; }
    if [[ "${WANT_ROLE_TRIGGER:-none}" != "none" && -n "$before_svc" ]]; then
        sleep 20
        [[ "$(_services_on PRIMARY "$P_SID")" == "$before_svc" ]] && log_pass "user services back on the original primary" || { log_fail "services not restored on the original primary"; return 1; }
    fi
    wait_until 120 "MRP running after the roundtrip" mrp_running || return 1
}
_is_role() { [[ "$(role_of "$1" "$2")" == "$(printf '%s' "$3" | tr -d ' ')" ]]; }
broker_success_from() { ssh_dgmgrl "$1" "SHOW CONFIGURATION" "$2" | grep -A1 'Configuration Status' | grep -q SUCCESS; }
# Best effort after a failure past the first switchover: restore the original
# roles so the rest of the scenario (and teardown) sees the usual layout.
_switch_back() {
    log_warn "switching back to ${P_DB_UNIQUE_NAME} after the failure"
    local out; out=$(dgmgrl_sys STANDBY "$(standby_alias)" "SWITCHOVER TO '${P_DB_UNIQUE_NAME}'" "$SCN_STANDBY_SID")
    printf '%s\n' "$out" > "${SCN_LOG}/proofs/switchover_back_after_failure.out"
    wait_until 180 "${P_DB_UNIQUE_NAME} is PRIMARY again (recovery)" _is_role PRIMARY "$P_SID" PRIMARY || true
}
