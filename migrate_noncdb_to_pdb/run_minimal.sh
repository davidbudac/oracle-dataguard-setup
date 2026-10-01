#!/usr/bin/env bash
# =============================================================================
# LAB-ONLY - NOT FOR PRODUCTION.
# =============================================================================
# Minimal end-to-end migration of dgnonc -> dgcdb.dgnonc_pdb for the poug-dg1 /
# poug-dg2 test lab. Hard-coded hosts, SIDs and paths; none of the safety
# checks of the numbered scripts 01-06 (no preflight, no lag re-check, no
# identity check, no replication verification afterwards). For anything real
# use 01_preflight.sh ... 05_verify_pdb_dataguard.sh.
#
# Run on poug-dg1 as oracle. See MINIMAL_STEPS.md for the spelled-out version.
#
# Source bytes flow without any copy:
#   CDB primary  reads /u01/app/oracle/oradata/DGNONC/   (poug-dg1, dgnonc primary files)
#   CDB standby  reads /u01/app/oracle/oradata/DGNONC_S/ (poug-dg2, dgnonc_s standby files)
#                via STANDBY_PDB_SOURCE_FILE_DIRECTORY, set ON THE STANDBY instance
#
# Pre-req: ssh poug-dg2 works for the oracle user (passwordless).
# It takes the non-CDB offline (SHUTDOWN IMMEDIATE) - you are asked to confirm.

set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OH=/u01/app/oracle/product/19.0.0/dbhome_1
export ORACLE_HOME=$OH PATH=$OH/bin:$PATH
# shellcheck source=_lib.sh
source "${HERE}/_lib.sh"      # dgmgrl_output_has_error only; load_config is not called

STB_HOST="${STB_HOST:-poug-dg2}"
STB_SID="${STB_SID:-dgcdb}"                       # CDB standby instance on $STB_HOST
MANIFEST=/tmp/dgnonc_manifest.xml
SRC_DIR_PRI=/u01/app/oracle/oradata/DGNONC      # path on poug-dg1
SRC_DIR_STB=/u01/app/oracle/oradata/DGNONC_S    # path on $STB_HOST
PDB_DIR=/u01/app/oracle/oradata/DGCDB/dgnonc_pdb
PDB_DIR_STB=/u01/app/oracle/oradata/DGCDB_S/dgnonc_pdb

# mdg <sid>   - run the dgmgrl script on stdin; stop on any DGM-/ORA-/Error: output
# (dgmgrl exits 0 even when a command inside the script failed).
mdg() {
    local out
    out="$(ORACLE_SID="$1" dgmgrl -silent / 2>&1)" || true
    printf '%s\n' "$out"
    if dgmgrl_output_has_error "$out"; then
        echo "ERROR: dgmgrl reported an error (see above) - stopping." >&2
        exit 1
    fi
}

echo "LAB-ONLY script. This will, on $(hostname):"
echo "  - set dgnonc_s APPLY-OFF and SHUTDOWN IMMEDIATE the non-CDB 'dgnonc' (outage)"
echo "  - plug it into the CDB 'dgcdb' as dgnonc_pdb"
echo "  - touch $STB_HOST (mkdir, STANDBY_PDB_SOURCE_FILE_DIRECTORY on SID $STB_SID)"
if [[ "${MINIMAL_ASSUME_YES:-0}" != "1" ]]; then
    if [[ ! -t 0 ]]; then
        echo "ERROR: no terminal to confirm on (set MINIMAL_ASSUME_YES=1 to run unattended)." >&2
        exit 1
    fi
    printf "Type YES to continue: "
    read -r ans || ans=""
    [[ "$ans" == "YES" ]] || { echo "Aborted."; exit 1; }
fi

mkdir -p "$PDB_DIR"
ssh "$STB_HOST" "mkdir -p '$PDB_DIR_STB'"

echo ">> 1. flush redo, freeze dgnonc_s, bounce dgnonc into READ ONLY"
mdg dgnonc <<'DG'
SQL "ALTER SYSTEM ARCHIVE LOG CURRENT";
EDIT DATABASE 'dgnonc_s' SET STATE='APPLY-OFF';
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
SQL "ALTER DATABASE OPEN READ ONLY";
DG

echo ">> 2. describe non-CDB -> $MANIFEST"
rm -f "$MANIFEST"
ORACLE_SID=dgnonc sqlplus -L / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
BEGIN
  IF DBMS_PDB.DESCRIBE(pdb_descr_file => '$MANIFEST') THEN NULL; END IF;
END;
/
EXIT;
SQL
[[ -s "$MANIFEST" ]] || { echo "ERROR: manifest $MANIFEST not produced." >&2; exit 1; }

echo ">> 3. tell the CDB STANDBY where to find source bytes (parameter lives on the standby instance)"
# ALTER SYSTEM does not travel in redo, and dgmgrl's SQL command runs on the
# primary side only - set it on the standby itself and read it back.
STB_OUT="$(ssh "$STB_HOST" "ORACLE_HOME='$OH' ORACLE_SID='$STB_SID' '$OH/bin/sqlplus' -s -L / as sysdba" <<SQL 2>&1
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SYSTEM SET STANDBY_PDB_SOURCE_FILE_DIRECTORY='$SRC_DIR_STB/' SCOPE=BOTH;
SELECT 'VAL=' || value FROM v\$parameter WHERE name='standby_pdb_source_file_directory';
EXIT;
SQL
)"
printf '%s\n' "$STB_OUT"
printf '%s\n' "$STB_OUT" | grep -q "^VAL=$SRC_DIR_STB/\$" || { echo "ERROR: could not set/verify the parameter on $STB_HOST." >&2; exit 1; }

echo ">> 4. CREATE PLUGGABLE DATABASE dgnonc_pdb"
ORACLE_SID=dgcdb sqlplus -L / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
CREATE PLUGGABLE DATABASE dgnonc_pdb
   USING '$MANIFEST'
   COPY
   FILE_NAME_CONVERT = ('$SRC_DIR_PRI/', '$PDB_DIR/');
EXIT;
SQL

echo ">> 5. noncdb_to_pdb.sql (long)"
ORACLE_SID=dgcdb sqlplus -L / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER PLUGGABLE DATABASE dgnonc_pdb OPEN UPGRADE;
ALTER SESSION SET CONTAINER=dgnonc_pdb;
@?/rdbms/admin/noncdb_to_pdb.sql
EXIT;
SQL

echo ">> 6. open RW + save state + flush redo + show standby"
mdg dgcdb <<'DG'
SQL "ALTER PLUGGABLE DATABASE dgnonc_pdb CLOSE IMMEDIATE";
SQL "ALTER PLUGGABLE DATABASE dgnonc_pdb OPEN READ WRITE";
SQL "ALTER PLUGGABLE DATABASE dgnonc_pdb SAVE STATE";
SQL "ALTER SYSTEM ARCHIVE LOG CURRENT";
SHOW DATABASE 'dgcdb_s';
DG

echo ">> done. NOT verified - check the standby: v\$pdbs.recovery_status = ENABLED, no UNNAMED datafiles."
