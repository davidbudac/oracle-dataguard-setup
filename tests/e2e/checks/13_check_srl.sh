#!/usr/bin/env bash
# check: dg_check_srl.sh - compliant (0) on a normal build; on the quirks
# profile (undersized SRLs created without THREAD) it must exit 1 with DDL and
# never drop anything by itself
check_check_srl() {
    local want=0
    [[ "$P_PRE_SRL" == "undersized" ]] && want=1
    run_tool PRIMARY checks/check_srl_local "bash ./dg_check_srl.sh -L"
    assert_exit "$TOOL_RC" "$want" "dg_check_srl.sh -L" || { log_tail 20 "$TOOL_OUT"; return 1; }
    if [[ $want -eq 1 ]]; then
        assert_output "$TOOL_OUT" "ALTER DATABASE ADD STANDBY LOGFILE" "fix DDL printed" || return 1
        assert_sql_num PRIMARY "SELECT COUNT(*) FROM v\$standby_log WHERE thread# = 0;" -ge 1 "THREAD#=0 SRLs still present (nothing dropped)" || return 1
    else
        assert_output "$TOOL_OUT" "compliant|COMPLIANT|OK" "SRLs reported compliant" || return 1
    fi
    # peer check through the broker's DGConnectIdentifier, password prompted
    run_step PRIMARY checks/check_srl_peer common -- ./dg_check_srl.sh -p
    assert_exit "$STEP_RC" "$want" "dg_check_srl.sh -p (both members)" || { log_tail 20 "$STEP_OUT"; return 1; }
    assert_output "$STEP_OUT" "${SCN_STANDBY_NAME}" "peer ${SCN_STANDBY_NAME} checked" || return 1
}
