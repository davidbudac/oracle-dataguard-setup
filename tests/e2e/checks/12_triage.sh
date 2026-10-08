#!/usr/bin/env bash
# check: the local triage/diag tools on both hosts; with a wallet (WANT_WALLET)
# the deep diagnostics reach the peer without a password
check_triage() {
    local rc_ok='^[01]$'
    run_tool PRIMARY checks/triage_primary "bash ./dg_triage_sid.sh --no-color -L"
    [[ "$TOOL_RC" =~ $rc_ok ]] && log_pass "dg_triage_sid.sh -L on the primary: exit ${TOOL_RC}" || { log_fail "dg_triage_sid.sh -L on the primary: exit ${TOOL_RC}"; log_tail 15 "$TOOL_OUT"; return 1; }
    assert_output "$TOOL_OUT" "PRIMARY" "triage sees the PRIMARY role" || return 1
    run_tool STANDBY checks/triage_standby "bash ./dg_triage_sid.sh --no-color -L" "$SCN_STANDBY_SID"
    [[ "$TOOL_RC" =~ $rc_ok ]] && log_pass "dg_triage_sid.sh -L on the standby: exit ${TOOL_RC}" || { log_fail "dg_triage_sid.sh -L on the standby: exit ${TOOL_RC}"; log_tail 15 "$TOOL_OUT"; return 1; }
    assert_output "$TOOL_OUT" "PHYSICAL STANDBY" "triage sees the PHYSICAL STANDBY role" || return 1
    if [[ "${WANT_WALLET:-no}" == "yes" ]]; then
        run_tool PRIMARY checks/diag_primary "bash ./dg_diag_sid.sh --no-color"
        [[ "$TOOL_RC" =~ $rc_ok ]] && log_pass "dg_diag_sid.sh (wallet) on the primary: exit ${TOOL_RC}" || { log_fail "dg_diag_sid.sh on the primary: exit ${TOOL_RC}"; log_tail 15 "$TOOL_OUT"; return 1; }
        assert_no_output "$TOOL_OUT" "ORA-01017" "wallet authenticated the peer connection" || return 1
        run_tool STANDBY checks/triage_standby_wallet "bash ./dg_triage_sid.sh --no-color" "$SCN_STANDBY_SID"
        [[ "$TOOL_RC" =~ $rc_ok ]] && log_pass "dg_triage_sid.sh (wallet) on the standby: exit ${TOOL_RC}" || { log_fail "dg_triage_sid.sh (wallet) on the standby: exit ${TOOL_RC}"; return 1; }
    fi
}
