#!/usr/bin/env bash
# check: dg_status.sh from the runner host. Exit code must be
# EXPECT_STATUS_EXIT (0 healthy; 1 when the build legitimately leaves
# warnings, e.g. no flashback / FSFO disabled), replication IN SYNC, and
# EVERY warning in the final summary must match EXPECT_WARNINGS - an
# unexpected warning is a finding. A sequence-lag warning right after the
# build's log switches is transient: retried until it clears.
check_status() {
    local cfg="${SCN_LOG}/checks/dg_status.env"
    write_status_config "$cfg"
    local out rc attempt=0 warnings unexpected ok
    # Right after a build step, a role transition or an apply restart the
    # broker needs a minute to settle (ORA-16854 "apply lag could not be
    # determined", a sequence lag of a few logs). Retry while the picture is
    # not the expected one; a finding that persists for 2 minutes is real.
    while :; do
        attempt=$((attempt + 1))
        out=$(bash "${REPO_ROOT}/dg_status.sh" --no-color -s "$P_SID" --standby-sid "$SCN_STANDBY_SID" -c "$cfg" 2>&1); rc=$?
        warnings=$(printf '%s\n' "$out" | sed -n 's/^ *Warning  *\(.*[^ !]\) *!*$/\1/p')
        unexpected=""
        [[ -n "$warnings" ]] && unexpected=$(printf '%s\n' "$warnings" | grep -vE "${EXPECT_WARNINGS:-^\$}" || true)
        ok=1
        [[ "$rc" == "${EXPECT_STATUS_EXIT:-0}" ]] || ok=0
        [[ -z "$unexpected" ]] || ok=0
        printf '%s\n' "$out" | grep -q "IN SYNC" || ok=0
        [[ $ok -eq 1 || $attempt -ge 7 ]] && break
        log_info "dg_status.sh not settled yet (exit ${rc}; unexpected: $(printf '%s' "$unexpected" | tr '\n' ';')) - attempt ${attempt}, retrying in 20 s"
        ssh_sql PRIMARY "ALTER SYSTEM ARCHIVE LOG CURRENT;" >/dev/null
        sleep 20
    done
    printf '%s\n' "$out" > "${SCN_LOG}/checks/status.out"
    assert_exit "$rc" "${EXPECT_STATUS_EXIT:-0}" "dg_status.sh exit code (after ${attempt} attempt(s))" || { log_tail 20 "$out"; return 1; }
    assert_output "$out" "IN SYNC" "replication state IN SYNC" || return 1
    assert_no_output "$out" "UNREACHABLE" "both hosts reached" || return 1
    if [[ -n "$warnings" ]]; then
        if [[ -z "$unexpected" ]]; then
            log_pass "every warning is expected: $(printf '%s' "$warnings" | tr '\n' ';')"
        else
            log_fail "unexpected dg_status.sh warning(s): $(printf '%s' "$unexpected" | tr '\n' ';')"
            return 1
        fi
    else
        log_pass "no warnings in the summary"
    fi
    if [[ "${WANT_FSFO:-no}" == "yes" ]]; then
        assert_output "$out" "Fast-Start Failover.*(ENABLED|Enabled)" "FSFO shown enabled" || return 1
    fi
}
