#!/usr/bin/env bash
# =============================================================================
# tests/e2e/lib/drive.sh - run a workflow script on a lab host under answer.py
# =============================================================================
#   run_step TOKEN NAME RULES... -- cmd [args]
#       TOKEN   PRIMARY | STANDBY | HOST3
#       NAME    log name (build/step2 -> logs/<run>/<scenario>/build/step2.*)
#       RULES   rule sources, in priority order: a file under answers/, an
#               absolute path, or an inline "rule:<regex><TAB><answer>[<TAB>flags]"
#               line. answers/common.rules is always appended last.
#       cmd     run from REPO_DIR on the host (./primary/02_... etc.)
#
#   Sets STEP_RC (exit status: the script's, or answer.py's 96/97/98) and
#   STEP_OUT (the full output). Returns STEP_RC.
#   Writes <NAME>.out (output as seen), <NAME>.tty (answer.py log with the
#   [prompt] records) and <NAME>.rules (the rules used, secrets masked).
#
# Rule templates may contain @VAR@ tokens; each is replaced by the value of
# the shell variable VAR (unset -> empty, i.e. "press Enter"). Scenario code
# sets the step-specific ones (STANDBY_NAME, Q1B_ANSWER, ...) before calling.
# =============================================================================

[[ -n "${E2E_DRIVE_LOADED:-}" ]] && return 0
E2E_DRIVE_LOADED=1

STEP_RC=0
STEP_OUT=""

# Expand @VAR@ tokens in a rules text (stdin -> stdout).
_expand_rule_tokens() {
    local line out tok name val
    while IFS= read -r line || [[ -n "$line" ]]; do
        out=""
        while [[ "$line" =~ ^([^@]*)@([A-Z0-9_]+)@(.*)$ ]]; do
            name="${BASH_REMATCH[2]}"
            val="${!name:-}"
            out="${out}${BASH_REMATCH[1]}${val}"
            line="${BASH_REMATCH[3]}"
        done
        printf '%s\n' "${out}${line}"
    done
}

# Compose the rules file for one step into $1 (local path).
_compose_rules() {
    local dest="$1"; shift
    local src
    : > "$dest"
    for src in "$@"; do
        case "$src" in
            rule:*) printf '%s\n' "${src#rule:}" >> "$dest" ;;
            /*)     cat "$src" >> "$dest" ;;
            *)      if [[ -f "${ANSWERS_DIR}/${src}" ]]; then
                        cat "${ANSWERS_DIR}/${src}" >> "$dest"
                    elif [[ -f "${ANSWERS_DIR}/${src}.rules" ]]; then
                        cat "${ANSWERS_DIR}/${src}.rules" >> "$dest"
                    else
                        log_error "drive.sh: no rules source '${src}'"; return 1
                    fi ;;
        esac
        printf '\n' >> "$dest"
    done
    cat "${ANSWERS_DIR}/common.rules" >> "$dest"
    local tmp="${dest}.tmp"
    _expand_rule_tokens < "$dest" > "$tmp" && mv "$tmp" "$dest"
}

# Mask secret answers for the on-disk copy kept with the logs.
_mask_rules() {
    awk -F'\t' 'BEGIN{OFS="\t"} $3 ~ /secret/ {$2="***"} {print}' "$1"
}

run_step() {
    local token="$1" name="$2"; shift 2
    local sources=() cmd=()
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then shift; cmd=("$@"); break; fi
        sources+=("$1"); shift
    done
    [[ ${#cmd[@]} -eq 0 ]] && { log_error "run_step: no command"; return 2; }

    local local_base="${SCN_LOG}/${name}"
    mkdir -p "$(dirname "$local_base")"
    local rules_local="${local_base}.rules.full"
    _compose_rules "$rules_local" ${sources[@]+"${sources[@]}"} || return 2
    _mask_rules "$rules_local" > "${local_base}.rules"

    local remote_rules="${SCN_WORK}/$(basename "$name").rules"
    local remote_tty="${SCN_WORK}/$(basename "$name").tty"
    ssh_cmd "$token" "mkdir -p $(shq "$SCN_WORK") && chmod 700 $(shq "$SCN_WORK")" >/dev/null
    ssh_copy_to "$token" "$rules_local" "$remote_rules"
    rm -f "$rules_local"
    ssh_cmd "$token" "chmod 600 $(shq "$remote_rules"); rm -f $(shq "$remote_tty")" >/dev/null

    local quoted="" a
    for a in "${cmd[@]}"; do quoted="${quoted} $(shq "$a")"; done

    local t0; t0=$(now_s)
    log_info "run_step[${token}] ${cmd[*]}"
    STEP_OUT=$(ssh_cmd "$token" "cd $(shq "$REPO_DIR") && python3 $(shq "${REPO_DIR}/tests/e2e/lib/answer.py") --rules $(shq "$remote_rules") --log $(shq "$remote_tty") --timeout ${STEP_TIMEOUT} --grace ${PROMPT_GRACE:-25} --${quoted}; rc=\$?; rm -f $(shq "$remote_rules"); exit \$rc")
    STEP_RC=$?
    printf '%s\n' "$STEP_OUT" > "${local_base}.out"
    ssh_cmd "$token" "cat $(shq "$remote_tty") 2>/dev/null" > "${local_base}.tty" || true
    local prompts; prompts=$(grep -a -c '^\[prompt\]' "${local_base}.tty" 2>/dev/null; true); prompts=${prompts:-0}
    log_info "run_step[${token}] exit ${STEP_RC} after $(fmt_elapsed $(( $(now_s) - t0 ))), ${prompts} prompt(s) answered"
    case "$STEP_RC" in
        96) log_error "A forbidden prompt appeared: $(grep -a 'FORBIDDEN' "${local_base}.tty" | tail -1)" ;;
        97) log_error "Unanswered prompt: $(grep -a 'UNANSWERED PROMPT' "${local_base}.tty" | tail -1 | sed 's/.*UNANSWERED PROMPT: //')" ;;
        98) log_error "Step timed out after ${STEP_TIMEOUT}s" ;;
    esac
    return "$STEP_RC"
}

# Print the prompts a finished step answered (for the scenario report).
step_prompts() {
    grep -a '^\[prompt\]' "${SCN_LOG}/$1.tty" 2>/dev/null | sed 's/^\[prompt\] //'
}
