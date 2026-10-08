#!/usr/bin/env bash
# check: dg_status.sh with an unreachable standby exits 2, says UNREACHABLE and
# never renders a healthy-looking IN SYNC
check_status_unreachable() {
    local cfg="${SCN_LOG}/checks/dg_status_unreachable.env"
    write_status_config "$cfg"
    sed -i 's/^STANDBY_HOST=.*/STANDBY_HOST="192.0.2.1"/' "$cfg"
    local out rc
    out=$(DG_REMOTE_TIMEOUT=20 bash "${REPO_ROOT}/dg_status.sh" --no-color -s "$P_SID" --standby-sid "$SCN_STANDBY_SID" -c "$cfg" 2>&1); rc=$?
    printf '%s\n' "$out" > "${SCN_LOG}/checks/status_unreachable.out"
    assert_exit "$rc" 2 "dg_status.sh exit 2 with the standby unreachable" || return 1
    assert_output "$out" "UNREACHABLE" "standby reported UNREACHABLE" || return 1
    assert_no_output "$out" "IN SYNC" "no IN SYNC with an unreachable standby" || return 1
}
