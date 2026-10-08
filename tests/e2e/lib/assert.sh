#!/usr/bin/env bash
# =============================================================================
# tests/e2e/lib/assert.sh - assertions against the lab (PASS/FAIL lines)
# =============================================================================
# Every assert_* logs one PASS or FAIL line and returns 0/1. Callers decide
# whether a FAIL aborts the phase (|| return 1) or is merely recorded.
#
#   assert_sql      TOKEN "SQL" EXPECTED "label" [SID]  substring match, whitespace stripped
#   assert_sql_eq   TOKEN "SQL" EXPECTED "label" [SID]  exact match, whitespace stripped
#   assert_sql_num  TOKEN "SQL" OP N "label" [SID]      numeric compare (-gt/-ge/-eq/-lt/-le)
#   assert_dgmgrl   TOKEN "CMD" ERE "label" [SID]       ERE (case-insensitive) in dgmgrl output
#   assert_file     TOKEN PATH "label"
#   assert_no_file  TOKEN PATH "label"
#   assert_grep     TOKEN ERE FILE "label"
#   assert_no_grep  TOKEN ERE FILE "label"
#   assert_output   "captured" ERE "label"              ERE in a string
#   assert_no_output "captured" ERE "label"
#   assert_exit     RC EXPECTED "label"
#   assert_path_under TOKEN "SQL listing files" DIR "label" [SID]
#       every row of the query output starts with DIR/
#   assert_no_path_under TOKEN "SQL" DIR "label" [SID]
#       no row starts with DIR/
#   wait_until      SECONDS "label" cmd...              poll cmd (0 = done) every 5 s
#
# The asserts pipe captured output into grep -q. Never run them under
# pipefail: grep -q exits at the first match, the writer gets SIGPIPE, and
# a true match turns into a failed pipeline on any large capture.
# =============================================================================

[[ -n "${E2E_ASSERT_LOADED:-}" ]] && return 0
E2E_ASSERT_LOADED=1

assert_sql() {
    local token="$1" sql="$2" expected="$3" label="$4" sid="${5:-}"
    local got; got=$(ssh_sql "$token" "$sql" "$sid")
    local want; want=$(printf '%s' "$expected" | tr -d '[:space:]')
    if [[ "$got" == *"$want"* ]]; then
        log_pass "${label}: ${expected}"
    else
        log_fail "${label}: expected '${expected}', got '${got}'"
        return 1
    fi
}

assert_sql_eq() {
    local token="$1" sql="$2" expected="$3" label="$4" sid="${5:-}"
    local got; got=$(ssh_sql "$token" "$sql" "$sid")
    local want; want=$(printf '%s' "$expected" | tr -d '[:space:]')
    if [[ "$got" == "$want" ]]; then
        log_pass "${label}: ${expected}"
    else
        log_fail "${label}: expected exactly '${expected}', got '${got}'"
        return 1
    fi
}

assert_sql_num() {
    local token="$1" sql="$2" op="$3" n="$4" label="$5" sid="${6:-}"
    local got; got=$(ssh_sql "$token" "$sql" "$sid")
    if [[ "$got" =~ ^[0-9]+$ ]] && [ "$got" "$op" "$n" ]; then
        log_pass "${label}: ${got} ${op} ${n}"
    else
        log_fail "${label}: got '${got}', wanted ${op} ${n}"
        return 1
    fi
}

assert_dgmgrl() {
    local token="$1" cmd="$2" ere="$3" label="$4" sid="${5:-}"
    local out; out=$(ssh_dgmgrl "$token" "$cmd" "$sid")
    if printf '%s\n' "$out" | grep -qiE "$ere"; then
        log_pass "${label}"
    else
        log_fail "${label}: '${ere}' not in dgmgrl output"
        log_tail 6 "$out"
        return 1
    fi
}

assert_file() {
    local token="$1" path="$2" label="${3:-$2}"
    if ssh_cmd "$token" "test -e $(shq "$path") && echo __YES__" | grep -q __YES__; then
        log_pass "File exists: ${label}"
    else
        log_fail "File missing: ${label} (${path})"
        return 1
    fi
}

assert_no_file() {
    local token="$1" path="$2" label="${3:-$2}"
    if ssh_cmd "$token" "test -e $(shq "$path") && echo __YES__" | grep -q __YES__; then
        log_fail "File should not exist: ${label} (${path})"
        return 1
    else
        log_pass "File absent: ${label}"
    fi
}

assert_grep() {
    local token="$1" ere="$2" file="$3" label="${4:-$2 in $3}"
    if ssh_cmd "$token" "grep -qE $(shq "$ere") $(shq "$file") 2>/dev/null && echo __YES__" | grep -q __YES__; then
        log_pass "Found: ${label}"
    else
        log_fail "Not found: ${label}"
        return 1
    fi
}

assert_no_grep() {
    local token="$1" ere="$2" file="$3" label="${4:-$2 in $3}"
    if ssh_cmd "$token" "grep -qE $(shq "$ere") $(shq "$file") 2>/dev/null && echo __YES__" | grep -q __YES__; then
        log_fail "Unexpectedly found: ${label}"
        return 1
    else
        log_pass "Absent: ${label}"
    fi
}

assert_output() {
    local out="$1" ere="$2" label="$3"
    if printf '%s\n' "$out" | grep -qE "$ere"; then
        log_pass "${label}"
    else
        log_fail "${label}: '${ere}' not in output"
        return 1
    fi
}

assert_no_output() {
    local out="$1" ere="$2" label="$3"
    if printf '%s\n' "$out" | grep -qE "$ere"; then
        log_fail "${label}: '${ere}' found in output"
        return 1
    else
        log_pass "${label}"
    fi
}

assert_exit() {
    local rc="$1" expected="$2" label="$3"
    if [[ "$rc" == "$expected" ]]; then
        log_pass "${label}: exit ${rc}"
    else
        log_fail "${label}: exit ${rc}, expected ${expected}"
        return 1
    fi
}

# Every row of the query must start with DIR/
assert_path_under() {
    local token="$1" sql="$2" dir="$3" label="$4" sid="${5:-}"
    local rows bad
    rows=$(ssh_sql_raw "$token" "$sql" "$sid")
    bad=$(printf '%s\n' "$rows" | grep -v "^${dir}/" | grep -v '^$' || true)
    if [[ -z "$rows" ]]; then
        log_fail "${label}: query returned no rows"
        return 1
    elif [[ -z "$bad" ]]; then
        log_pass "${label}: $(printf '%s\n' "$rows" | grep -c .) file(s) under ${dir}"
    else
        log_fail "${label}: file(s) outside ${dir}:"
        log_tail 5 "$bad"
        return 1
    fi
}

assert_no_path_under() {
    local token="$1" sql="$2" dir="$3" label="$4" sid="${5:-}"
    local bad
    bad=$(ssh_sql_raw "$token" "$sql" "$sid" | grep "^${dir}/" || true)
    if [[ -z "$bad" ]]; then
        log_pass "${label}: nothing under ${dir}"
    else
        log_fail "${label}: file(s) under primary-only ${dir}:"
        log_tail 5 "$bad"
        return 1
    fi
}

# wait_until SECONDS "label" cmd args...  -> 0 when cmd succeeds in time
wait_until() {
    local secs="$1" label="$2"; shift 2
    local t0; t0=$(now_s)
    while :; do
        if "$@" >/dev/null 2>&1; then
            log_pass "${label} (after $(( $(now_s) - t0 ))s)"
            return 0
        fi
        if (( $(now_s) - t0 >= secs )); then
            log_fail "${label}: not reached within ${secs}s"
            return 1
        fi
        sleep 5
    done
}
