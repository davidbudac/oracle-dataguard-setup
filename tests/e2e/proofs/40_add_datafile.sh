#!/usr/bin/env bash
# proof: a datafile added on the primary (in a covered directory, or OMF)
# arrives on the standby and apply keeps running (PROVE_ADD_DATAFILE)
proof_add_datafile() {
    [[ "${PROVE_ADD_DATAFILE:-no}" == "yes" ]] || return 2
    local ddl
    if [[ "$P_STORAGE" == "omf" ]]; then
        ddl="CREATE TABLESPACE e2e_add DATAFILE SIZE 50M;"
    else
        ddl="CREATE TABLESPACE e2e_add DATAFILE '$(set -- $P_DATA_DIRS; printf '%s' "$1")/e2e_add01.dbf' SIZE 50M;"
    fi
    local scn; scn=$(ssh_sql_raw PRIMARY "${ddl}
SELECT TO_CHAR(MAX(sequence#)) FROM v\$log WHERE status = 'CURRENT' AND thread# = 1;" | tail -1 | tr -d '[:space:]')
    [[ "$scn" =~ ^[0-9]+$ ]] || { log_fail "CREATE TABLESPACE failed: ${scn}"; return 1; }
    wait_applied_past "$scn" 300 || { log_fail "standby did not apply the datafile creation"; return 1; }
    assert_sql_num STANDBY "SELECT COUNT(*) FROM v\$datafile WHERE LOWER(name) LIKE '%e2e_add%';" -eq 1 "new datafile present on the standby" "$SCN_STANDBY_SID" || return 1
    assert_sql_eq STANDBY "SELECT COUNT(*) FROM v\$datafile WHERE name LIKE '%UNNAMED%';" "0" "no UNNAMED placeholder" "$SCN_STANDBY_SID" || return 1
    if [[ "$P_STORAGE" != "omf" ]]; then
        local m; for m in ${WANT_PATH_OVERRIDES:-}; do
            [[ "${m%%=*}" == "$(set -- $P_DATA_DIRS; printf '%s' "$1")" ]] && { assert_sql STANDBY "SELECT name FROM v\$datafile WHERE LOWER(name) LIKE '%e2e_add%';" "${m#*=}/" "new datafile under the overridden standby directory" "$SCN_STANDBY_SID" || return 1; }
        done
    fi
    mrp_running && log_pass "MRP running after the datafile add" || { log_fail "MRP stopped"; return 1; }
    ssh_sql PRIMARY "DROP TABLESPACE e2e_add INCLUDING CONTENTS AND DATAFILES;" >/dev/null
}
