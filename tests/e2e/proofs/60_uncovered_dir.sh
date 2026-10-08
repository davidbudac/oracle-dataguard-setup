#!/usr/bin/env bash
# proof (Traditional mode): a datafile created in a directory no convert pair
# covers becomes an UNNAMED placeholder, dg_status.sh reports it (exit 2), and
# the walkthrough's fix (CREATE DATAFILE ... AS, restart apply) recovers
# (PROVE_UNCOVERED_DIR)
proof_uncovered_dir() {
    [[ "${PROVE_UNCOVERED_DIR:-no}" == "yes" ]] || return 2
    [[ "${WANT_STORAGE_MODE:-traditional}" == "traditional" ]] || { log_skip "OMF standby: convert pairs do not apply"; return 2; }
    local dir="${SCN_WORK}/uncovered"
    ssh_cmd PRIMARY "mkdir -p $(shq "$dir")" >/dev/null
    # 19c recovery creates a missing directory when its parent is writable
    # (seen: "Recovery created file ..."), so "not covered by a convert pair"
    # alone does not reproduce ORA-01274. Make the standby-side path
    # unplaceable instead: the same directory, mode 000.
    ssh_cmd STANDBY "mkdir -p $(shq "$dir") && chmod 000 $(shq "$dir")" "$SCN_STANDBY_SID" >/dev/null
    # idempotent: a previous attempt may have left the tablespace behind
    ssh_sql_raw PRIMARY "BEGIN EXECUTE IMMEDIATE 'DROP TABLESPACE e2e_unc INCLUDING CONTENTS AND DATAFILES'; EXCEPTION WHEN OTHERS THEN IF SQLCODE <> -959 THEN RAISE; END IF; END;
/" >/dev/null
    local scn; scn=$(ssh_sql_raw PRIMARY "CREATE TABLESPACE e2e_unc DATAFILE '${dir}/e2e_unc01.dbf' SIZE 20M;
SELECT TO_CHAR(MAX(sequence#)) FROM v\$log WHERE status = 'CURRENT' AND thread# = 1;" | tail -1 | tr -d '[:space:]')
    [[ "$scn" =~ ^[0-9]+$ ]] || { log_fail "CREATE TABLESPACE failed: ${scn}"; return 1; }
    ssh_sql PRIMARY "ALTER SYSTEM ARCHIVE LOG CURRENT;" >/dev/null
    wait_until 240 "standby shows an UNNAMED placeholder and apply stopped" _unnamed_and_stopped || { _unc_cleanup; return 1; }
    local cfg="${SCN_LOG}/proofs/dg_status.env"; write_status_config "$cfg"
    local out; out=$(bash "${REPO_ROOT}/dg_status.sh" --no-color -s "$P_SID" --standby-sid "$SCN_STANDBY_SID" -c "$cfg" 2>&1); local rc=$?
    printf '%s\n' "$out" > "${SCN_LOG}/proofs/uncovered_dg_status.out"
    assert_exit "$rc" 2 "dg_status.sh reports an error" || return 1
    assert_output "$out" "UNNAMED" "dg_status.sh names the UNNAMED datafile" || return 1
    # the documented fix
    local unnamed stby_dir
    unnamed=$(ssh_sql STANDBY "SELECT name FROM v\$datafile WHERE name LIKE '%UNNAMED%' AND ROWNUM = 1;" "$SCN_STANDBY_SID")
    stby_dir="${SCN_WORK}/uncovered_stby"
    ssh_cmd STANDBY "mkdir -p $(shq "$stby_dir")" >/dev/null
    ssh_cmd STANDBY "sqlplus -s / as sysdba <<SQLEOF
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
ALTER SYSTEM SET standby_file_management = MANUAL;
ALTER DATABASE CREATE DATAFILE '${unnamed}' AS '${stby_dir}/e2e_unc01.dbf';
ALTER SYSTEM SET standby_file_management = AUTO;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;
EXIT;
SQLEOF" "$SCN_STANDBY_SID" >/dev/null
    wait_until 120 "MRP running again after the fix" mrp_running || return 1
    wait_applied_past "$scn" 300 && log_pass "apply caught up after the fix" || { log_fail "apply did not catch up"; return 1; }
    assert_sql_eq STANDBY "SELECT COUNT(*) FROM v\$datafile WHERE name LIKE '%UNNAMED%';" "0" "no UNNAMED file left" "$SCN_STANDBY_SID" || { _unc_cleanup; return 1; }
    _unc_cleanup
}
_unc_cleanup() {
    ssh_cmd STANDBY "chmod 750 $(shq "${SCN_WORK}/uncovered") 2>/dev/null; true" "$SCN_STANDBY_SID" >/dev/null
    ssh_sql PRIMARY "DROP TABLESPACE e2e_unc INCLUDING CONTENTS AND DATAFILES;" >/dev/null 2>&1 || true
}
_unnamed_and_stopped() {
    [[ "$(ssh_sql STANDBY "SELECT COUNT(*) FROM v\$datafile WHERE name LIKE '%UNNAMED%';" "$SCN_STANDBY_SID")" != "0" ]] && ! mrp_running
}
