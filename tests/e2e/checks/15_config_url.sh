#!/usr/bin/env bash
# check: get_dg_config_url.sh produces a visualizer link whose payload names
# both members; run from either side
check_config_url() {
    run_tool PRIMARY checks/config_url_primary "bash ./get_dg_config_url.sh -q 2>/dev/null"
    assert_exit "$TOOL_RC" 0 "get_dg_config_url.sh -q on the primary" || { log_tail 10 "$TOOL_OUT"; return 1; }
    local url; url=$(printf '%s\n' "$TOOL_OUT" | grep -E '^https?://' | tail -1)
    assert_output "$url" "#cfg=" "URL carries a #cfg payload" || return 1
    local payload="${url#*#cfg=}"
    local json; json=$(printf '%s' "$payload" | tr '_-' '/+' | awk '{ n = length($0) % 4; if (n) $0 = $0 substr("====", 1, 4 - n); print }' | base64 -d 2>/dev/null)
    assert_output "$json" "${SCN_STANDBY_NAME}" "payload names the standby" || return 1
    assert_output "$json" "${P_DB_UNIQUE_NAME}" "payload names the primary" || return 1
    assert_no_output "$json" "${TEST_SYS_PASSWORD}" "payload carries no password" || return 1
    run_tool STANDBY checks/config_url_standby "bash ./get_dg_config_url.sh -q 2>/dev/null" "$SCN_STANDBY_SID"
    assert_exit "$TOOL_RC" 0 "get_dg_config_url.sh -q on the standby (role swap)" || return 1
}
