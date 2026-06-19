# Minimal: Migrate `dgnonc` (non-CDB) into `dgcdb` as a PDB

Tailored to the test environment in this repo:

* `dgnonc` (non-CDB)  primary on **poug-dg1**, standby `dgnonc_s` on **poug-dg2**, files at `/u01/app/oracle/oradata/DGNONC/` and `/u01/app/oracle/oradata/DGNONC_S/`
* `dgcdb`  (CDB)      primary on **poug-dg1**, standby `dgcdb_s`  on **poug-dg2**, files at `/u01/app/oracle/oradata/DGCDB/`  and `/u01/app/oracle/oradata/DGCDB_S/`
* ORACLE_HOME `/u01/app/oracle/product/19.0.0/dbhome_1`
* STANDBY_FILE_MANAGEMENT=AUTO on both DGs

The new PDB is `DGNONC_PDB`, datafiles under `/u01/app/oracle/oradata/DGCDB/dgnonc_pdb/` on the primary and `/u01/app/oracle/oradata/DGCDB_S/dgnonc_pdb/` on the standby.

**Trick we lean on:** instead of copying datafiles anywhere, each side of the CDB reads from its already-existing local copy of the non-CDB:

* CDB **primary** (poug-dg1) reads source files from `/u01/app/oracle/oradata/DGNONC/` -- those are the non-CDB primary's datafiles, exact path matches the manifest.
* CDB **standby** (poug-dg2) reads source files from `/u01/app/oracle/oradata/DGNONC_S/` -- those are the non-CDB **standby's** datafiles. We point it there with `STANDBY_PDB_SOURCE_FILE_DIRECTORY`.

So no NFS copy, no RMAN duplicate. The CDB standby builds the new PDB through ordinary redo apply, picking up the source bytes locally.

All Data Guard operations go through `dgmgrl`. The only sqlplus calls left are for things `dgmgrl` does not cover (the plug-in DDL itself, `noncdb_to_pdb.sql`, `DROP DATABASE`).

Run all commands on **poug-dg1** as the `oracle` user.

---

## 1. Quiesce non-CDB and open it READ ONLY

One dgmgrl session does the whole sequence: flush redo, freeze the standby, bounce the primary into READ ONLY.

```bash
ssh poug-dg2 'mkdir -p /u01/app/oracle/oradata/DGCDB_S/dgnonc_pdb'
mkdir -p /u01/app/oracle/oradata/DGCDB/dgnonc_pdb

ORACLE_SID=dgnonc dgmgrl -silent / <<'DG'
SQL "ALTER SYSTEM ARCHIVE LOG CURRENT";
EDIT DATABASE 'dgnonc_s' SET STATE='APPLY-OFF';
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
SQL "ALTER DATABASE OPEN READ ONLY";
DG
```

After this:

* `dgnonc_s` is APPLY-OFF (its files are frozen at a consistent SCN).
* `dgnonc` primary is OPEN READ ONLY.
* The `dgnonc_s` instance stays mounted -- that's fine; it doesn't block the CDB standby from reading the bytes it needs.

## 2. Generate the manifest

```bash
ORACLE_SID=dgnonc sqlplus -L / as sysdba <<'SQL'
BEGIN
  IF DBMS_PDB.DESCRIBE(pdb_descr_file => '/tmp/dgnonc_manifest.xml')
  THEN NULL; END IF;
END;
/
SQL
```

(Manifest is local-only -- only the CDB primary reads it.)

## 3. Tell the CDB standby where its source files live

```bash
ORACLE_SID=dgcdb dgmgrl -silent / <<'DG'
SQL "ALTER SYSTEM SET STANDBY_PDB_SOURCE_FILE_DIRECTORY='/u01/app/oracle/oradata/DGNONC_S/' SCOPE=BOTH";
DG
```

## 4. Plug it in as `DGNONC_PDB`

```bash
ORACLE_SID=dgcdb sqlplus -L / as sysdba <<'SQL'
CREATE PLUGGABLE DATABASE dgnonc_pdb
   USING '/tmp/dgnonc_manifest.xml'
   COPY
   FILE_NAME_CONVERT =
      ('/u01/app/oracle/oradata/DGNONC/',
       '/u01/app/oracle/oradata/DGCDB/dgnonc_pdb/');
SQL
```

The CDB primary reads the source files from `/u01/app/oracle/oradata/DGNONC/` (exists on poug-dg1) and copies them to `DGCDB/dgnonc_pdb/`. When the same redo lands on the CDB standby, it falls back to `STANDBY_PDB_SOURCE_FILE_DIRECTORY` and reads from `/u01/app/oracle/oradata/DGNONC_S/` on poug-dg2.

## 5. Convert it (`noncdb_to_pdb.sql`)

10-30 minutes typical.

```bash
ORACLE_SID=dgcdb sqlplus -L / as sysdba <<'SQL'
ALTER PLUGGABLE DATABASE dgnonc_pdb OPEN UPGRADE;
ALTER SESSION SET CONTAINER=dgnonc_pdb;
@?/rdbms/admin/noncdb_to_pdb.sql
SQL
```

## 6. Open RW and force redo to flow

```bash
ORACLE_SID=dgcdb dgmgrl -silent / <<'DG'
SQL "ALTER PLUGGABLE DATABASE dgnonc_pdb CLOSE IMMEDIATE";
SQL "ALTER PLUGGABLE DATABASE dgnonc_pdb OPEN READ WRITE";
SQL "ALTER PLUGGABLE DATABASE dgnonc_pdb SAVE STATE";
SQL "ALTER SYSTEM ARCHIVE LOG CURRENT";
SHOW DATABASE 'dgcdb_s';
DG
```

`Apply Lag` should fall back to 0s within a minute. The PDB is now part of the existing CDB Data Guard.

## 7. (Optional) Tear down the obsolete `dgnonc` Data Guard

```bash
ORACLE_SID=dgnonc dgmgrl -silent / <<'DG'
REMOVE CONFIGURATION;
SHUTDOWN IMMEDIATE;
DG

# Optional final drop (no dgmgrl form for DROP DATABASE)
ORACLE_SID=dgnonc sqlplus -L / as sysdba <<'SQL'
STARTUP MOUNT EXCLUSIVE RESTRICT
ALTER SYSTEM ENABLE RESTRICTED SESSION;
DROP DATABASE;
SQL
# Then on poug-dg2: rm -rf /u01/app/oracle/oradata/DGNONC_S and clean spfile/orapw under $ORACLE_HOME/dbs/.
```

---

## One-shot script

```bash
bash /home/oracle/dataguard_setup_tests/migrate_noncdb_to_pdb/run_minimal.sh
```
