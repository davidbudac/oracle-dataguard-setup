#!/usr/bin/env bash
# =============================================================================
# tests/e2e/e2e.sh - Oracle Data Guard scenario E2E suite
# =============================================================================
#   e2e.sh doctor                         probe the lab, list what each scenario needs
#   e2e.sh list [--tier smoke|core|full]  show the catalog
#   e2e.sh run  [--tier T] [--scenario ID ...] [--from PHASE] [--from-step STEP]
#               [--only PHASE] [--keep] [--no-doctor]
#   e2e.sh clean --scenario ID            tear a scenario's databases/files down
#
# Phases of a build scenario: provision reshape build checks proofs cleanup teardown
# Phases of a refusal scenario: provision reshape cases teardown
# (provision = network + DBCA; reshape = the profile's post-SQL + shape check)
#
# One config file: tests/e2e/config.env (copy config.env.template). Logs:
# tests/e2e/logs/<run>/<scenario>/. Always run with bash.
# =============================================================================
# -u only: with pipefail, `printf '%s' "$big" | grep -q X` fails whenever grep
# exits at its first match before printf is done (SIGPIPE, 141) - which is
# exactly what the asserts do on a multi-MB xtrace capture.
set -u

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${E2E_DIR}/lib/common.sh"
for f in ssh assert scenario doctor provision teardown drive build refusal checks report; do
    # shellcheck disable=SC1090
    source "${E2E_DIR}/lib/${f}.sh"
done

usage() {
    sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

cmd="${1:-}"; shift || true
[[ -z "$cmd" || "$cmd" == "-h" || "$cmd" == "--help" ]] && usage 0

load_config || exit 3

TIER="full"; SCENARIOS=""; FROM_PHASE=""; ONLY_PHASE=""; KEEP="false"; NO_DOCTOR="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tier)      TIER="$2"; shift 2 ;;
        --scenario)  SCENARIOS="$SCENARIOS $2"; shift 2 ;;
        --from)      FROM_PHASE="$2"; shift 2 ;;
        --from-step) BUILD_FROM_STEP="$2"; FROM_PHASE="${FROM_PHASE:-build}"; shift 2 ;;
        --only)      ONLY_PHASE="$2"; shift 2 ;;
        --keep)      KEEP="true"; shift ;;
        --no-doctor) NO_DOCTOR="true"; shift ;;
        -h|--help)   usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 2 ;;
    esac
done
export BUILD_FROM_STEP

case "$cmd" in
    doctor)
        log_phase "DOCTOR: probing the lab"
        doctor_probe
        doctor_basics
        doctor_report
        exit 0 ;;
    list)
        printf '  %-5s %-6s %-9s %-4s %s\n' ID TIER KIND PRI TITLE
        for id in $(scenario_ids "$TIER"); do
            load_scenario "$id" >/dev/null 2>&1 || continue
            printf '  %-5s %-6s %-9s %-4s %s\n' "$id" "$SCN_TIER" "$SCN_KIND" "$P_ID" "${S_TITLE:-}"
        done
        exit 0 ;;
    clean)
        [[ -n "$SCENARIOS" ]] || { echo "clean needs --scenario ID" >&2; exit 2; }
        RUN_DIR="${LOG_ROOT}/clean_$(date +%Y%m%d_%H%M%S)"; mkdir -p "$RUN_DIR"
        for id in $SCENARIOS; do
            load_scenario "$id" || continue
            SCN_LOG="${RUN_DIR}/${id}"; mkdir -p "$SCN_LOG"
            RUN_LOG="${SCN_LOG}/run.log"; RESULTS_FILE="${SCN_LOG}/results.log"
            deploy_tree PRIMARY >/dev/null 2>&1 || true
            teardown_scenario
        done
        exit 0 ;;
    run) ;;
    *) echo "Unknown command: $cmd" >&2; usage 2 ;;
esac

# ----------------------------------------------------------------------------
# run
# ----------------------------------------------------------------------------
RUN_DIR="${LOG_ROOT}/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN_DIR"
: > "${RUN_DIR}/summary.rows"
RUN_LOG="${RUN_DIR}/campaign.log"
log "E2E campaign $(basename "$RUN_DIR") - tier ${TIER}${SCENARIOS:+, scenarios:${SCENARIOS}}"
log "primary ${SSH_USER}@${PRIMARY_HOST}:${PRIMARY_SSH_PORT}  standby ${SSH_USER}@${STANDBY_HOST}:${STANDBY_SSH_PORT}${HOST3:+  host3 ${SSH_USER}@${HOST3}:${HOST3_SSH_PORT}}${JUMP_HOST:+  via ${JUMP_USER}@${JUMP_HOST}}"

if [[ "$NO_DOCTOR" == "true" ]]; then
    doctor_load || { log_error "no logs/lab.caps yet - run 'e2e.sh doctor' first or drop --no-doctor"; exit 3; }
else
    log_phase "DOCTOR"
    doctor_probe
    doctor_basics || { log_error "the lab basics are not met; fix the FAIL lines above"; exit 3; }
fi

log_phase "DEPLOY: working tree -> ${REPO_DIR} on both hosts"
for t in PRIMARY STANDBY; do
    deploy_tree "$t" && log_pass "${t}: deployed" || { log_fail "${t}: deploy failed"; exit 3; }
done
[[ -n "${HOST3:-}" ]] && ssh_reachable HOST3 && { deploy_tree HOST3 && log_pass "HOST3: deployed" || log_warn "HOST3: deploy failed"; }

[[ -z "$SCENARIOS" ]] && SCENARIOS=$(scenario_ids "$TIER" | tr '\n' ' ')

phase_wanted() {
    local phase="$1"
    [[ -n "$ONLY_PHASE" ]] && { [[ "$ONLY_PHASE" == "$phase" ]]; return; }
    [[ -z "$FROM_PHASE" ]] && return 0
    local order="provision reshape build cases checks proofs cleanup teardown" seen=0 p
    for p in $order; do
        [[ "$p" == "$FROM_PHASE" ]] && seen=1
        [[ "$p" == "$phase" ]] && { [[ $seen -eq 1 ]]; return; }
    done
    return 0
}

campaign_rc=0
for id in $SCENARIOS; do
    SCN_LOG="${RUN_DIR}/${id}"; mkdir -p "$SCN_LOG"
    RUN_LOG="${SCN_LOG}/run.log"; RESULTS_FILE="${SCN_LOG}/results.log"; : > "$RESULTS_FILE"
    PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0; _build_started=""
    t0=$(now_s)
    if ! load_scenario "$id"; then
        verdict="BLOCKED"; reason="scenario cannot be loaded"
        printf '| %s | ? | BLOCKED | - | - | cannot load |\n' "$id" >> "${RUN_DIR}/summary.rows"
        campaign_rc=1; continue
    fi
    scenario_dump > "${SCN_LOG}/scenario.resolved"
    log_phase "SCENARIO ${id}: ${S_TITLE:-} [${SCN_TIER}, ${SCN_KIND}, primary ${P_ID}]"
    # Resumed runs (--from/--from-step/--only) already own their databases:
    # the memory/space gates are about provisioning, not about continuing.
    needs="$S_NEEDS"
    if [[ -n "$FROM_PHASE" || -n "$ONLY_PHASE" || -n "${BUILD_FROM_STEP:-}" ]]; then
        needs=$(printf '%s\n' $needs | grep -vE '^(mem1g|mem2g|flashback-space)$' | tr '\n' ' ')
    fi
    unmet=$(doctor_unmet "$needs")
    if [[ -n "$unmet" ]]; then
        log_skip "${id}: prerequisites not met:"
        printf '%s\n' "$unmet" | while IFS= read -r l; do log_info "    $l"; done
        write_result SKIP "$(printf '%s' "$unmet" | head -1)" 0
        summary_line SKIP 0 | tee -a "${RUN_DIR}/summary.rows.txt"
        printf '| %s | %s | SKIP | - | - | %s |\n' "$id" "$SCN_TIER" "$(printf '%s' "$unmet" | head -1)" >> "${RUN_DIR}/summary.rows"
        continue
    fi
    verdict="PASS"; reason=""
    run_phases() {
        if phase_wanted provision; then
            nfs_wipe_generated
            teardown_scenario >/dev/null 2>&1 || true
            provision_create || { reason="provision failed"; return 1; }
        fi
        phase_wanted reshape && { provision_finish || { reason="reshape failed"; return 1; }; }
        if [[ "$SCN_KIND" == "refusal" ]]; then
            phase_wanted cases && { run_refusal_cases || { reason="refusal case failed"; return 1; }; }
            return 0
        fi
        phase_wanted build  && { build_scenario || { reason="build failed"; return 1; }; }
        phase_wanted checks && { run_checks || reason="check(s) failed"; }
        phase_wanted proofs && { run_proofs || reason="proof(s) failed"; }
        phase_wanted cleanup && { build_cleanup || reason="${reason:-step 12 failed}"; }
        [[ -z "$reason" ]]
    }
    run_phases || verdict="FAIL"
    [[ "$verdict" == "PASS" && "$FAIL_COUNT" -gt 0 ]] && { verdict="FAIL"; reason="${reason:-${FAIL_COUNT} assertion(s) failed}"; }
    secs=$(( $(now_s) - t0 ))
    if [[ "$KEEP" == "true" || ( "$verdict" == "FAIL" && "${CLEANUP_ON_FAILURE:-false}" != "true" ) ]]; then
        log_warn "${id}: databases left in place (${KEEP:+--keep} ${verdict}); clean with: bash tests/e2e/e2e.sh clean --scenario ${id}"
    elif phase_wanted teardown; then
        teardown_scenario
    fi
    write_result "$verdict" "$reason" "$secs"
    summary_line "$verdict" "$secs"
    printf '| %s | %s | %s | %s | %s | %s |\n' "$id" "$SCN_TIER" "$verdict" "$(fmt_elapsed "$secs")" "$FAIL_COUNT" "${S_TITLE:-}" >> "${RUN_DIR}/summary.rows"
    [[ "$verdict" == "PASS" ]] || campaign_rc=1
done

RUN_LOG="${RUN_DIR}/campaign.log"
log_phase "CAMPAIGN RESULT"
printf '  %-5s %-6s %-8s %6s  %-9s %s\n' ID TIER VERDICT TIME FAILS TITLE
for id in $SCENARIOS; do
    [[ -f "${RUN_DIR}/${id}/result.json" ]] || continue
    v=$(sed -n 's/^  "verdict": "\([A-Z]*\)",/\1/p' "${RUN_DIR}/${id}/result.json")
    s=$(sed -n 's/^  "seconds": \([0-9]*\),/\1/p' "${RUN_DIR}/${id}/result.json")
    f=$(sed -n 's/^  "pass": [0-9]*, "fail": \([0-9]*\),.*/\1/p' "${RUN_DIR}/${id}/result.json")
    t=$(sed -n 's/^  "title": "\(.*\)",/\1/p' "${RUN_DIR}/${id}/result.json")
    c="$GREEN"; [[ "$v" == "FAIL" ]] && c="$RED"; [[ "$v" == "SKIP" ]] && c="$YELLOW"
    printf '  %-5s %-6s %b%-8s%b %6s  %-9s %s\n' "$id" "$(load_scenario "$id" >/dev/null 2>&1; printf '%s' "$SCN_TIER")" "$c" "$v" "$NC" "$(fmt_elapsed "${s:-0}")" "${f:-0} fail" "$t"
done
write_campaign_summary
exit $campaign_rc
