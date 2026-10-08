#!/usr/bin/env bash
# check: every script honours -h (exit 0) and the documented usage-error exit
# code for an unknown option (2 shared parser, 3 dg_status/dg_handoff,
# 64 triage/diag); needs no database
check_cli_contract() {
    local ok=1 s
    local shared="primary/01_gather_primary_info.sh primary/02_generate_standby_config.sh standby/03_setup_standby_env.sh primary/04_prepare_primary_dg.sh standby/05_clone_standby.sh primary/06_configure_broker.sh standby/07_verify_dataguard.sh primary/09_configure_fsfo.sh primary/10_generate_handoff_report.sh primary/13_set_max_availability.sh trigger/create_role_trigger.sh trigger/create_role_trigger_dedicated_user.sh fsfo/observer.sh"
    local own="trigger/create_role_trigger_cdb.sh trigger/create_pdb_service.sh trigger/create_cdb_service.sh common/cleanup_nfs_artifacts.sh common/setup_dg_wallet.sh"
    local out
    out=$(ssh_cmd PRIMARY "cd $(shq "$REPO_DIR") && for s in $shared $own dg_status.sh dg_handoff.sh dg_triage_sid.sh dg_diag_sid.sh dg_sync_impact.sh dg_check_srl.sh get_dg_config_url.sh; do bash \$s -h >/dev/null 2>&1; echo \"H \$s \$?\"; done; for s in $shared; do bash \$s --no-such-flag >/dev/null 2>&1; echo \"U \$s \$?\"; done; for s in dg_status.sh dg_handoff.sh; do bash \$s --no-such-flag >/dev/null 2>&1; echo \"U3 \$s \$?\"; done; for s in dg_triage_sid.sh dg_diag_sid.sh; do bash \$s --no-such-flag >/dev/null 2>&1; echo \"U64 \$s \$?\"; done; for s in dg_sync_impact.sh dg_check_srl.sh get_dg_config_url.sh; do bash \$s --no-such-flag >/dev/null 2>&1; echo \"U2 \$s \$?\"; done")
    printf '%s\n' "$out" > "${SCN_LOG}/checks/cli_contract.out"
    local _k _script _rc
    while read -r _k _script _rc; do
        [[ -n "$_k" ]] || continue
        case "$_k" in
            H)   [[ "$_rc" == "0" ]]  && log_pass "${_script} -h exits 0" || { log_fail "${_script} -h exited ${_rc}"; ok=0; } ;;
            U|U2) [[ "$_rc" == "2" ]] && log_pass "${_script} unknown flag exits 2" || { log_fail "${_script} unknown flag exited ${_rc}, expected 2"; ok=0; } ;;
            U3)  [[ "$_rc" == "3" ]]  && log_pass "${_script} unknown flag exits 3" || { log_fail "${_script} unknown flag exited ${_rc}, expected 3"; ok=0; } ;;
            U64) [[ "$_rc" == "64" ]] && log_pass "${_script} unknown flag exits 64" || { log_fail "${_script} unknown flag exited ${_rc}, expected 64"; ok=0; } ;;
        esac
    done <<< "$out"
    [[ $ok -eq 1 ]]
}
