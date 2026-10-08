#!/usr/bin/env bash
# proof: a PDB created after the setup arrives on the standby with all its
# files and apply keeps running (PROVE_NEW_PDB, CDB only)
proof_new_pdb() {
    [[ "${PROVE_NEW_PDB:-no}" == "yes" ]] || return 2
    [[ "$P_CDB" == "yes" ]] || { log_fail "PROVE_NEW_PDB on a non-CDB"; return 1; }
    local sql
    if [[ "$P_STORAGE" == "omf" ]]; then
        sql="CREATE PLUGGABLE DATABASE pdbnew ADMIN USER pdbadmin IDENTIFIED BY \"${TEST_SYS_PASSWORD}\";"
    else
        local d1; d1=$(set -- $P_DATA_DIRS; printf '%s' "$1")
        sql="DECLARE v VARCHAR2(512); BEGIN SELECT SUBSTR(name, 1, INSTR(name, '/', -1)) INTO v FROM v\$datafile WHERE con_id = 2 AND ROWNUM = 1;
EXECUTE IMMEDIATE 'CREATE PLUGGABLE DATABASE pdbnew ADMIN USER pdbadmin IDENTIFIED BY \"${TEST_SYS_PASSWORD}\" FILE_NAME_CONVERT = (''' || v || ''', ''${d1}/PDBNEW/'')'; END;
/"
    fi
    local scn; scn=$(ssh_sql_raw PRIMARY "${sql}
ALTER PLUGGABLE DATABASE pdbnew OPEN;
ALTER PLUGGABLE DATABASE pdbnew SAVE STATE;
SELECT TO_CHAR(MAX(sequence#)) FROM v\$log WHERE status = 'CURRENT' AND thread# = 1;" | tail -1 | tr -d '[:space:]')
    [[ "$scn" =~ ^[0-9]+$ ]] || { log_fail "CREATE PLUGGABLE DATABASE failed: ${scn}"; return 1; }
    wait_applied_past "$scn" 420 || { log_fail "standby did not apply the PDB creation"; return 1; }
    assert_sql STANDBY "SELECT name FROM v\$pdbs WHERE name = 'PDBNEW';" "PDBNEW" "PDBNEW known on the standby" "$SCN_STANDBY_SID" || return 1
    local np ns
    np=$(ssh_sql PRIMARY "SELECT COUNT(*) FROM v\$datafile d JOIN v\$pdbs p ON p.con_id = d.con_id WHERE p.name = 'PDBNEW';")
    ns=$(ssh_sql STANDBY "SELECT COUNT(*) FROM v\$datafile d JOIN v\$pdbs p ON p.con_id = d.con_id WHERE p.name = 'PDBNEW';" "$SCN_STANDBY_SID")
    [[ "$np" == "$ns" && "$np" != "0" ]] && log_pass "PDBNEW datafiles on the standby: ${ns}/${np}" || { log_fail "PDBNEW datafiles standby ${ns} vs primary ${np}"; return 1; }
    assert_sql_eq STANDBY "SELECT COUNT(*) FROM v\$datafile WHERE name LIKE '%UNNAMED%';" "0" "no UNNAMED placeholder" "$SCN_STANDBY_SID" || return 1
    mrp_running && log_pass "MRP running after the PDB creation" || { log_fail "MRP stopped"; return 1; }
}
