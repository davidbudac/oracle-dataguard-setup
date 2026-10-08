#!/usr/bin/env bash
# check: the handoff pack's _verify.sh, run from an "application host" (HOST3
# when available, else the standby host) with only the pack's tnsnames.ora
check_handoff_verify() {
    [[ "${WANT_HANDOFF:-yes}" == "yes" ]] || return 2
    local base="dg_handoff_${P_DB_UNIQUE_NAME}" token="STANDBY" sid="$SCN_STANDBY_SID"
    [[ -n "${HOST3:-}" && "$(_cap SSH_HOST3)" == "yes" && "$(_cap HOST3_DGMGRL)" == "yes" ]] && { token="HOST3"; sid=""; }
    local dir="${SCN_WORK}/apphost"
    ssh_cmd "$token" "mkdir -p $(shq "$dir")" "$sid" >/dev/null
    # the pack as it sits on the share (a resumed run has no build/ copies)
    ssh_cmd PRIMARY "cat $(shq "${NFS_SHARE}/${base}_verify.sh")" > "${SCN_LOG}/checks/pack_verify.sh"
    ssh_cmd PRIMARY "cat $(shq "${NFS_SHARE}/${base}_tnsnames.ora")" > "${SCN_LOG}/checks/pack_tnsnames.ora"
    ssh_cmd PRIMARY "cat $(shq "${NFS_SHARE}/${base}.json")" > "${SCN_LOG}/checks/pack.json"
    [[ -s "${SCN_LOG}/checks/pack_verify.sh" && -s "${SCN_LOG}/checks/pack_tnsnames.ora" ]] || { log_fail "handoff pack not found on the share (${base}_verify.sh / _tnsnames.ora)"; return 1; }
    ssh_copy_to "$token" "${SCN_LOG}/checks/pack_verify.sh" "${dir}/verify.sh"
    ssh_copy_to "$token" "${SCN_LOG}/checks/pack_tnsnames.ora" "${dir}/tnsnames.ora"
    local saved="$E2E_REMOTE_TNS_ADMIN"; E2E_REMOTE_TNS_ADMIN="$dir"
    run_tool "$token" checks/handoff_verify "cd $(shq "$dir") && bash ./verify.sh -u ${MARK_USER}/${MARK_PASSWORD} --expect-db-unique-name $(shq "$P_DB_UNIQUE_NAME")" "$sid"
    E2E_REMOTE_TNS_ADMIN="$saved"
    assert_exit "$TOOL_RC" 0 "_verify.sh from ${token}" || { log_tail 25 "$TOOL_OUT"; return 1; }
    assert_output "$TOOL_OUT" "PASS" "_verify.sh reports PASS lines" || return 1
    assert_output "$TOOL_OUT" "$(upper "$P_DB_UNIQUE_NAME")|${P_DB_UNIQUE_NAME}" "role check landed on ${P_DB_UNIQUE_NAME}" || return 1
    # the JSON sidecar is machine-readable and names the standby
    assert_output "$(cat "${SCN_LOG}/checks/pack.json")" "\"standby_db_unique_name\": *\"${SCN_STANDBY_NAME}\"" "JSON sidecar names the standby" || return 1
    assert_output "$(cat "${SCN_LOG}/checks/pack.json")" "\"verdict\": *\"(HEALTHY|WARNING)\"" "JSON sidecar verdict HEALTHY/WARNING" || return 1
}
