#!/usr/bin/env bash
# check: dg_sync_impact.sh - free-views mode on the primary (SYNC/FASTSYNC
# report when the protection mode is MAXAVAILABILITY, ASYNC baseline
# otherwise), HTML output, fatal on a standby
check_sync_impact() {
    run_tool PRIMARY checks/sync_impact "bash ./dg_sync_impact.sh --no-pack -o $(shq "${SCN_WORK}/sync_impact.md")"
    assert_exit "$TOOL_RC" 0 "dg_sync_impact.sh --no-pack" || { log_tail 20 "$TOOL_OUT"; return 1; }
    if [[ "${WANT_PROTECTION:-maxperf}" == "maxavail" || "${WANT_FSFO:-no}" == "yes" ]]; then
        assert_output "$TOOL_OUT" "FASTSYNC|SYNC" "synchronous destination reported" || return 1
    else
        assert_output "$TOOL_OUT" "no .*SYNC|ASYNC|no synchronous" "ASYNC-side baseline reported" || return 1
    fi
    run_tool PRIMARY checks/sync_impact_html "bash ./dg_sync_impact.sh --no-pack --html -o $(shq "${SCN_WORK}/sync_impact.html") >/dev/null && head -c 200 $(shq "${SCN_WORK}/sync_impact.html")"
    assert_exit "$TOOL_RC" 0 "dg_sync_impact.sh --html" || return 1
    assert_output "$TOOL_OUT" "<!DOCTYPE html|<html" "HTML page written" || return 1
    run_tool STANDBY checks/sync_impact_standby "bash ./dg_sync_impact.sh --no-pack -o /dev/null" "$SCN_STANDBY_SID"
    assert_exit "$TOOL_RC" 1 "dg_sync_impact.sh on the standby is fatal (not primary)" || return 1
}
