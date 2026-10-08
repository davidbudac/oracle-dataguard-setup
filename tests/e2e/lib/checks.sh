#!/usr/bin/env bash
# =============================================================================
# tests/e2e/lib/checks.sh - run checks/*.sh and proofs/*.sh for a scenario
# =============================================================================
# Each file under checks/ (proofs/) is sourced and must define ONE function
# named after the file without its numeric prefix and extension:
#     checks/10_status.sh      ->  check_status()
#     proofs/20_switchover.sh  ->  proof_switchover()
# The function returns 0 (pass), 1 (fail) or 2 (not applicable: logged as
# SKIP). It runs in the runner's shell with the scenario loaded, so every
# SCN_*, P_*, WANT_* variable and every lib function is available.
# Output of the tools a check runs goes to $SCN_LOG/checks/<name>.* via run_tool.
# =============================================================================

[[ -n "${E2E_CHECKS_LOADED:-}" ]] && return 0
E2E_CHECKS_LOADED=1

TOOL_RC=0
TOOL_OUT=""

# run_tool TOKEN NAME "shell snippet" [SID] - run a tool on a host, capture + log
run_tool() {
    local token="$1" name="$2" snippet="$3" sid="${4:-}"
    local t0; t0=$(now_s)
    # the marker goes on its own line even when the tool's output ends without a newline
    TOOL_OUT=$(ssh_cmd "$token" "cd $(shq "$REPO_DIR") && { ${snippet}; }; __rc=\$?; printf '\\n__TOOL_RC=%s\\n' \"\$__rc\"" "$sid")
    TOOL_RC=$(printf '%s\n' "$TOOL_OUT" | sed -n 's/^__TOOL_RC=\([0-9]*\)$/\1/p' | tail -1)
    TOOL_RC="${TOOL_RC:-255}"
    TOOL_OUT=$(printf '%s\n' "$TOOL_OUT" | grep -v '^__TOOL_RC=')
    printf '%s\n' "$TOOL_OUT" > "${SCN_LOG}/${name}.out"
    log_info "run_tool[${token}] ${snippet%% *}... exit ${TOOL_RC} after $(( $(now_s) - t0 ))s"
    return 0
}

_run_dir_of() {
    # Deliberately odd local names: the check functions run in this shell, and
    # bash's dynamic scoping lets a check's plain "kind"/"name"/"rc" variable
    # overwrite ours (it happened: a read -r kind ... loop renamed the next
    # three checks).
    local _rd_dir="$1" _rd_kind="$2" _rd_f _rd_fn _rd_rc _rd_name _rd_any=0 _rd_failed=0
    mkdir -p "${SCN_LOG}/${_rd_kind}"
    for _rd_f in "${_rd_dir}"/[0-9][0-9]_*.sh; do
        [[ -f "$_rd_f" ]] || continue
        _rd_name=$(basename "$_rd_f" .sh); _rd_name="${_rd_name#[0-9][0-9]_}"
        _rd_fn="${_rd_kind%s}_${_rd_name}"
        # shellcheck disable=SC1090
        source "$_rd_f"
        if ! declare -F "$_rd_fn" >/dev/null; then log_fail "${_rd_f} does not define ${_rd_fn}()"; _rd_failed=1; continue; fi
        _rd_any=1
        log_section "${_rd_kind}: ${_rd_name}"
        "$_rd_fn"; _rd_rc=$?
        case "$_rd_rc" in
            0) log_pass "${_rd_kind%s} ${_rd_name}" ;;
            2) log_skip "${_rd_kind%s} ${_rd_name}: not applicable" ;;
            *) log_fail "${_rd_kind%s} ${_rd_name}"; _rd_failed=1 ;;
        esac
    done
    [[ $_rd_any -eq 1 ]] || log_info "no ${_rd_kind} found under ${_rd_dir}"
    [[ $_rd_failed -eq 0 ]]
}

# derive_answers (build.sh) fills the @VAR@ tokens the rule files use; a run
# resumed at checks/proofs never went through build_scenario, so do it here.
run_checks() { derive_answers; log_phase "CHECKS: standalone tools against the built configuration"; _run_dir_of "$CHECKS_DIR" checks; }
run_proofs() { derive_answers; log_phase "PROOFS: the standby is usable"; _run_dir_of "$PROOFS_DIR" proofs; }

# ---------------------------------------------------------------------------
# Shared helpers for checks and proofs
# ---------------------------------------------------------------------------
# Progress is measured in LOG SEQUENCES, not SCNs: on a MOUNTED standby every
# SCN view (V$DATABASE.CURRENT_SCN, V$RECOVERY_PROGRESS) lags real-time apply
# by a refresh interval, so a quiet primary never "catches up" by those
# numbers. The sequence current at commit time, archived right away, is
# applied exactly when the standby's applied sequence reaches it - the same
# definition dg_status.sh uses (applied YES/IN-MEMORY, floor MRP0's current - 1).
primary_seq() { ssh_sql PRIMARY "SELECT TO_CHAR(MAX(sequence#)) FROM v\$log WHERE status = 'CURRENT' AND thread# = 1;"; }
standby_applied_seq() {
    ssh_sql STANDBY "SELECT TO_CHAR(GREATEST(NVL(MAX(CASE WHEN a.applied IN ('YES','IN-MEMORY') THEN a.sequence# END), 0), NVL(MAX(m.mrp_prev), 0))) FROM v\$archived_log a, (SELECT MAX(sequence#) - 1 AS mrp_prev FROM v\$managed_standby WHERE process = 'MRP0' AND sequence# > 0) m WHERE a.thread# = 1;" "$SCN_STANDBY_SID"
}
# wait until the standby has applied log sequence $1 (seconds $2)
wait_applied_past() {
    local target="$1" secs="${2:-300}" t0 s n=0
    t0=$(now_s)
    ssh_sql PRIMARY "ALTER SYSTEM ARCHIVE LOG CURRENT;" >/dev/null
    while :; do
        s=$(standby_applied_seq)
        [[ "$s" =~ ^[0-9]+$ && "$s" -ge "$target" ]] && return 0
        (( $(now_s) - t0 >= secs )) && { log_info "standby applied sequence ${s} < ${target} after ${secs}s"; return 1; }
        n=$((n + 1)); (( n % 6 == 0 )) && ssh_sql PRIMARY "ALTER SYSTEM ARCHIVE LOG CURRENT;" >/dev/null
        sleep 5
    done
}

# insert a marker row on the primary; prints the log sequence current after the commit
mark() {
    local label="$1"
    ssh_sql_raw PRIMARY "INSERT INTO ${MARK_USER}.marks (label) VALUES ('${label}');
COMMIT;
SELECT TO_CHAR(MAX(sequence#)) FROM v\$log WHERE status = 'CURRENT' AND thread# = 1;" | tail -1 | tr -d '[:space:]'
}

mark_count() { ssh_sql PRIMARY "SELECT COUNT(*) FROM ${MARK_USER}.marks;"; }

# TNS aliases as the build's .env names them (the scripts may domain-qualify them)
_env_key() { ssh_cmd PRIMARY "sed -n 's/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}.*/\1/p' $(shq "${NFS_SHARE}/standby_config_${SCN_STANDBY_NAME}.env") 2>/dev/null | head -1"; }
primary_alias() { local a; a=$(_env_key PRIMARY_TNS_ALIAS); printf '%s' "${a:-$P_DB_UNIQUE_NAME}"; }
standby_alias() { local a; a=$(_env_key STANDBY_TNS_ALIAS); printf '%s' "${a:-$SCN_STANDBY_NAME}"; }

mrp_running() { [[ "$(ssh_sql STANDBY "SELECT COUNT(*) FROM v\$managed_standby WHERE process = 'MRP0';" "$SCN_STANDBY_SID")" == "1" ]]; }
broker_success() { ssh_dgmgrl PRIMARY "SHOW CONFIGURATION" | grep -A1 'Configuration Status' | grep -q SUCCESS; }
role_of() { ssh_sql "$1" "SELECT database_role FROM v\$database;" "$2"; }

# dgmgrl as SYS over the network (needed for role transitions that restart instances)
dgmgrl_sys() {
    local token="$1" alias="$2" cmd="$3" sid="${4:-}"
    ssh_cmd "$token" "dgmgrl -silent /nolog <<'DGEOF' 2>&1
CONNECT sys/\"${TEST_SYS_PASSWORD}\"@${alias}
${cmd}
EXIT
DGEOF" "$sid"
}

# Generate a dg_status.sh config for this lab (runs from the runner host)
write_status_config() {
    local out="$1"
    cat > "$out" <<EOF
JUMP_HOST="${JUMP_HOST:-}"
JUMP_SSH_PORT="${JUMP_SSH_PORT}"
JUMP_USER="${JUMP_USER:-}"
JUMP_KEY="${JUMP_KEY:-}"
PRIMARY_HOST="${PRIMARY_HOST}"
PRIMARY_SSH_PORT="${PRIMARY_SSH_PORT}"
STANDBY_HOST="${STANDBY_HOST}"
STANDBY_SSH_PORT="${STANDBY_SSH_PORT}"
SSH_USER="${SSH_USER}"
SSH_KEY="${SSH_KEY:-}"
SSH_OPTS="${SSH_OPTS}"
ORACLE_HOME="${ORACLE_HOME}"
ORACLE_BASE="${ORACLE_BASE}"
PRIMARY_ORACLE_HOSTNAME="$(oracle_hostname_of PRIMARY)"
STANDBY_ORACLE_HOSTNAME="$(oracle_hostname_of STANDBY)"
EOF
}
