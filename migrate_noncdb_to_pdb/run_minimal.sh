#!/bin/bash
# Minimal end-to-end migration of dgnonc -> dgcdb.dgnonc_pdb.
# Run on poug-dg1 as oracle. See MINIMAL_STEPS.md for the spelled-out version.
#
# Source bytes flow without any copy:
#   CDB primary  reads /u01/app/oracle/oradata/DGNONC/   (poug-dg1, dgnonc primary files)
#   CDB standby  reads /u01/app/oracle/oradata/DGNONC_S/ (poug-dg2, dgnonc_s standby files)
#                via STANDBY_PDB_SOURCE_FILE_DIRECTORY
#
# Pre-req: ssh poug-dg2 works for the oracle user (passwordless).

set -e

OH=/u01/app/oracle/product/19.0.0/dbhome_1
export ORACLE_HOME=$OH PATH=$OH/bin:$PATH

MANIFEST=/tmp/dgnonc_manifest.xml
SRC_DIR_PRI=/u01/app/oracle/oradata/DGNONC      # path on poug-dg1
SRC_DIR_STB=/u01/app/oracle/oradata/DGNONC_S    # path on poug-dg2
PDB_DIR=/u01/app/oracle/oradata/DGCDB/dgnonc_pdb
PDB_DIR_STB=/u01/app/oracle/oradata/DGCDB_S/dgnonc_pdb

mkdir -p "$PDB_DIR"
ssh poug-dg2 "mkdir -p '$PDB_DIR_STB'"

echo ">> 1. flush redo, freeze dgnonc_s, bounce dgnonc into READ ONLY"
ORACLE_SID=dgnonc dgmgrl -silent / <<'DG'
SQL "ALTER SYSTEM ARCHIVE LOG CURRENT";
EDIT DATABASE 'dgnonc_s' SET STATE='APPLY-OFF';
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
SQL "ALTER DATABASE OPEN READ ONLY";
DG

echo ">> 2. describe non-CDB -> $MANIFEST"
ORACLE_SID=dgnonc sqlplus -L / as sysdba <<SQL
BEGIN
  IF DBMS_PDB.DESCRIBE(pdb_descr_file => '$MANIFEST') THEN NULL; END IF;
END;
/
EXIT;
SQL

echo ">> 3. tell CDB standby where to find source bytes"
ORACLE_SID=dgcdb dgmgrl -silent / <<DG
SQL "ALTER SYSTEM SET STANDBY_PDB_SOURCE_FILE_DIRECTORY='$SRC_DIR_STB/' SCOPE=BOTH";
DG

echo ">> 4. CREATE PLUGGABLE DATABASE dgnonc_pdb"
ORACLE_SID=dgcdb sqlplus -L / as sysdba <<SQL
CREATE PLUGGABLE DATABASE dgnonc_pdb
   USING '$MANIFEST'
   COPY
   FILE_NAME_CONVERT = ('$SRC_DIR_PRI/', '$PDB_DIR/');
EXIT;
SQL

echo ">> 5. noncdb_to_pdb.sql (long)"
ORACLE_SID=dgcdb sqlplus -L / as sysdba <<SQL
ALTER PLUGGABLE DATABASE dgnonc_pdb OPEN UPGRADE;
ALTER SESSION SET CONTAINER=dgnonc_pdb;
@?/rdbms/admin/noncdb_to_pdb.sql
EXIT;
SQL

echo ">> 6. open RW + save state + flush redo + show standby"
ORACLE_SID=dgcdb dgmgrl -silent / <<'DG'
SQL "ALTER PLUGGABLE DATABASE dgnonc_pdb CLOSE IMMEDIATE";
SQL "ALTER PLUGGABLE DATABASE dgnonc_pdb OPEN READ WRITE";
SQL "ALTER PLUGGABLE DATABASE dgnonc_pdb SAVE STATE";
SQL "ALTER SYSTEM ARCHIVE LOG CURRENT";
SHOW DATABASE 'dgcdb_s';
DG

echo ">> done."
