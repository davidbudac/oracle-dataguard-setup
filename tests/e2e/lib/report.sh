#!/usr/bin/env bash
# =============================================================================
# tests/e2e/lib/report.sh - per-scenario result.json and the campaign summary
# =============================================================================

[[ -n "${E2E_REPORT_LOADED:-}" ]] && return 0
E2E_REPORT_LOADED=1

_json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r'; }

# write_result VERDICT "reason" SECONDS
write_result() {
    local verdict="$1" reason="$2" secs="$3"
    local fails passes skips prompts
    passes=$(grep -c '^\[PASS\]' "$RESULTS_FILE" 2>/dev/null; true); passes=${passes:-0}
    fails=$(grep -c '^\[FAIL\]' "$RESULTS_FILE" 2>/dev/null; true); fails=${fails:-0}
    skips=$(grep -c '^\[SKIP\]' "$RESULTS_FILE" 2>/dev/null; true); skips=${skips:-0}
    prompts=$(cat "${SCN_LOG}"/build/*.tty 2>/dev/null | grep -a -c '^\[prompt\]'; true)
    {
        printf '{\n'
        printf '  "scenario": "%s",\n' "$(_json_str "$SCN_ID")"
        printf '  "title": "%s",\n' "$(_json_str "${S_TITLE:-}")"
        printf '  "tier": "%s",\n' "$(_json_str "$SCN_TIER")"
        printf '  "primary_profile": "%s",\n' "$(_json_str "${P_ID:-}")"
        printf '  "verdict": "%s",\n' "$verdict"
        printf '  "reason": "%s",\n' "$(_json_str "$reason")"
        printf '  "seconds": %s,\n' "${secs:-0}"
        printf '  "pass": %s, "fail": %s, "skip": %s,\n' "$passes" "$fails" "$skips"
        printf '  "prompts_answered": %s,\n' "$prompts"
        printf '  "failed_assertions": [\n'
        grep '^\[FAIL\]' "$RESULTS_FILE" 2>/dev/null | sed 's/^\[FAIL\] //' | while IFS= read -r l; do printf '    "%s",\n' "$(_json_str "$l")"; done | sed '$ s/,$//'
        printf '  ],\n'
        printf '  "log_dir": "%s"\n' "$(_json_str "$SCN_LOG")"
        printf '}\n'
    } > "${SCN_LOG}/result.json"
}

# summary line for the campaign table
summary_line() {
    local verdict="$1" secs="$2"
    local fails; fails=$(grep -c '^\[FAIL\]' "$RESULTS_FILE" 2>/dev/null; true); fails=${fails:-0}
    local color="$GREEN"
    [[ "$verdict" == "FAIL" ]] && color="$RED"
    [[ "$verdict" == "SKIP" || "$verdict" == "BLOCKED" ]] && color="$YELLOW"
    printf '  %-5s %-6s %b%-8s%b %6s  %3s fail  %s\n' "$SCN_ID" "$SCN_TIER" "$color" "$verdict" "$NC" "$(fmt_elapsed "${secs:-0}")" "$fails" "${S_TITLE:-}"
}

write_campaign_summary() {
    local file="${RUN_DIR}/summary.md" line
    {
        printf '# E2E campaign %s\n\n' "$(basename "$RUN_DIR")"
        printf '| ID | Tier | Verdict | Time | Fail | Title |\n|---|---|---|---|---|---|\n'
        while IFS= read -r line; do printf '%s\n' "$line"; done < "${RUN_DIR}/summary.rows"
        printf '\nLogs: `%s`\n' "$RUN_DIR"
    } > "$file"
    printf '\n%s\n' "Summary: $file"
}
