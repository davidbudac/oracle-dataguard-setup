#!/usr/bin/env bash
# =============================================================================
# tests/e2e/lib/refusal.sh - run a refusal scenario's numbered cases
# =============================================================================
# A refusal case: put the primary (or the build's config) into a state the
# scripts must refuse, run the step, assert the exit code and message, and
# prove nothing changed. CASE_n_* keys (see scenarios/_template.scenario.env).
#
#   run_refusal_cases       every case 1..CASE_COUNT on the provisioned primary
# =============================================================================

[[ -n "${E2E_REFUSAL_LOADED:-}" ]] && return 0
E2E_REFUSAL_LOADED=1

_case() { local v="CASE_${1}_${2}"; printf '%s' "${!v:-}"; }

# CASE_n_ANSWERS ("regex<TAB>answer[<TAB>flags]" entries separated by |) as
# run_step rule: arguments, one per line
case_rules() {
    local extra; extra=$(_case "$1" ANSWERS)
    [[ -n "$extra" ]] || return 0
    printf '%s\n' "$extra" | tr '|' '\n' | sed 's/<TAB>/\t/g' | sed '/^$/d; s/^/rule:/'
}

# Primary toggles (applied before the case, restored after)
_toggle_apply() {
    case "$1" in
        none|"") ;;
        noarchivelog)
            ssh_cmd PRIMARY "sqlplus -s / as sysdba <<'SQLEOF'
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE NOARCHIVELOG;
ALTER DATABASE OPEN;
EXIT;
SQLEOF" >/dev/null ;;
        no-force-logging)
            ssh_sql PRIMARY "ALTER DATABASE NO FORCE LOGGING;" >/dev/null ;;
        pwfile-shared)
            ssh_cmd PRIMARY "sqlplus -s / as sysdba <<'SQLEOF'
ALTER SYSTEM SET remote_login_passwordfile = SHARED SCOPE=SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP;
EXIT;
SQLEOF" >/dev/null ;;
        *) log_fail "unknown CASE toggle '$1'"; return 1 ;;
    esac
}
_toggle_restore() {
    case "$1" in
        none|"") ;;
        noarchivelog)
            ssh_cmd PRIMARY "sqlplus -s / as sysdba <<'SQLEOF'
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
EXIT;
SQLEOF" >/dev/null ;;
        no-force-logging)
            ssh_sql PRIMARY "ALTER DATABASE FORCE LOGGING;" >/dev/null ;;
        pwfile-shared)
            ssh_cmd PRIMARY "sqlplus -s / as sysdba <<'SQLEOF'
ALTER SYSTEM SET remote_login_passwordfile = EXCLUSIVE SCOPE=SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP;
EXIT;
SQLEOF" >/dev/null ;;
    esac
}

# Config tampering (the build's standby_config_*.env on the share)
_tamper_apply() {
    local env="${NFS_SHARE}/standby_config_${SCN_STANDBY_NAME}.env"
    case "$1" in
        none|"") ;;
        wrong-dbid)
            ssh_cmd PRIMARY "cp -p $(shq "$env") $(shq "${env}.e2e_orig") && sed -i 's/^PRIMARY_DBID=.*/PRIMARY_DBID=\"1234567890\"/; s/^DBID=.*/DBID=\"1234567890\"/' $(shq "$env") && grep -c 1234567890 $(shq "$env")" | grep -q '^[1-9]' \
                || { log_fail "could not tamper the DBID in ${env}"; return 1; } ;;
        *) log_fail "unknown CASE tamper '$1'"; return 1 ;;
    esac
}
_tamper_restore() {
    local env="${NFS_SHARE}/standby_config_${SCN_STANDBY_NAME}.env"
    [[ "$1" == "wrong-dbid" ]] && ssh_cmd PRIMARY "[[ -f $(shq "${env}.e2e_orig") ]] && mv -f $(shq "${env}.e2e_orig") $(shq "$env"); true" >/dev/null
    return 0
}

# What must be unchanged: a fingerprint per keyword
_unchanged_fp() {
    local what="$1" out=""
    case " $what " in
        *" share "*) out="$out $(ssh_cmd PRIMARY "cd $(shq "$NFS_SHARE") 2>/dev/null && find . -type f ! -path './logs/*' ! -path './state/*' ! -name '*.e2e_orig' -exec md5sum {} + | sort | md5sum")" ;;
    esac
    case " $what " in
        *" primary-params "*) out="$out $(ssh_cmd PRIMARY "sqlplus -s / as sysdba <<'SQLEOF' | md5sum
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT name || '=' || value FROM v\$parameter WHERE isdefault = 'FALSE' ORDER BY name;
SELECT 'srl=' || COUNT(*) FROM v\$standby_log;
SELECT 'fl=' || force_logging || 'lm=' || log_mode FROM v\$database;
EXIT;
SQLEOF")" ;;
    esac
    case " $what " in
        *" standby-instance "*) out="$out $(ssh_cmd STANDBY "ps -eo args | grep -c '[o]ra_pmon_${SCN_STANDBY_SID}\$'")" ;;
    esac
    printf '%s' "$out"
}

# Prerequisite steps run non-interactively (the normal build answers)
_prereq_steps() {
    local s
    derive_answers
    for s in $1; do
        case "$s" in
            1) step1 || return 1 ;;
            2) step2 || return 1 ;;
            3) step3 || return 1 ;;
            4) step4 || return 1 ;;
            *) log_fail "unsupported CASE prereq step '$s'"; return 1 ;;
        esac
    done
}

run_refusal_cases() {
    mkdir -p "${SCN_LOG}/cases"
    local n total ok=1
    total="${CASE_COUNT:-0}"
    [[ "$total" -gt 0 ]] || { log_fail "refusal scenario without CASE_COUNT"; return 1; }
    local prereq_done=""
    for n in $(seq 1 "$total"); do
        local title toggle tamper prereq host step args exit_want match unchanged notes
        title=$(_case "$n" TITLE); toggle=$(_case "$n" PRIMARY_TOGGLE); tamper=$(_case "$n" CONFIG_TAMPER)
        prereq=$(_case "$n" PREREQ_STEPS); host=$(upper "$(_case "$n" HOST)"); step=$(_case "$n" STEP); args=$(_case "$n" ARGS)
        exit_want=$(_case "$n" EXIT); match=$(_case "$n" MATCH); unchanged=$(_case "$n" UNCHANGED); notes=$(_case "$n" OPERATOR_NOTES)
        log_phase "CASE ${n}/${total}: ${title}"
        [[ -n "$notes" ]] && log_info "$notes"
        if [[ -n "$prereq" && "$prereq" != "$prereq_done" ]]; then
            nfs_wipe_generated
            _prereq_steps "$prereq" || { log_fail "case ${n}: prerequisite steps ${prereq} failed"; ok=0; continue; }
            prereq_done="$prereq"
        fi
        _toggle_apply "$toggle" || { ok=0; continue; }
        _tamper_apply "$tamper" || { _toggle_restore "$toggle"; ok=0; continue; }
        local before after rules=() extra
        before=$(_unchanged_fp "$unchanged")
        # case-specific answers: a declined hostname check, an OMF choice, ...
        local l; while IFS= read -r l || [[ -n "$l" ]]; do [[ -n "$l" ]] && rules+=("$l"); done < <(case_rules "$n")
        local rulefile="common"
        case "$step" in
            */02_*) rulefile="step2" ;; */03_*) rulefile="step3" ;; */05_*) rulefile="step5" ;;
            */06_*) rulefile="step6" ;; */09_*) rulefile="step9" ;; */13_*) rulefile="step13" ;;
        esac
        local sid=""; [[ "$host" == "STANDBY" ]] && sid="$SCN_STANDBY_SID"
        local saved="$E2E_REMOTE_SID"; [[ -n "$sid" ]] && E2E_REMOTE_SID="$sid"
        run_step "$host" "cases/case${n}" ${rules[@]+"${rules[@]}"} "$rulefile" -- "$step" $args
        E2E_REMOTE_SID="$saved"
        assert_exit "$STEP_RC" "$exit_want" "case ${n}: exit code" || ok=0
        assert_output "$STEP_OUT" "$match" "case ${n}: message '${match}'" || ok=0
        after=$(_unchanged_fp "$unchanged")
        if [[ "$before" == "$after" ]]; then log_pass "case ${n}: unchanged (${unchanged})"; else log_fail "case ${n}: state changed (${unchanged})"; ok=0; fi
        _tamper_restore "$tamper"
        _toggle_restore "$toggle"
    done
    [[ $ok -eq 1 ]]
}
