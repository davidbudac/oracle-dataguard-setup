# Walkthrough: Non-CDB → PDB Migration with Both Sides in Data Guard

Detailed, step-by-step procedure used by the scripts in this folder.

> **Audience:** Oracle DBA, 19c. Familiar with Data Guard Broker (DGMGRL).
> **Time budget:** Roughly 5–10 min for steps 01–03, 10–30 min for 04
> (`noncdb_to_pdb.sql`), a few minutes for 05.
> **Outage:** The non-CDB is offline for writes from the start of step 02
> until you cut applications over to the new PDB.

---

## 1. Architecture before and after

### Before

```
  ┌─────────────────────┐                ┌─────────────────────┐
  │ host A              │                │ host B              │
  │   non-CDB dgnonc    │ ── DG ──►      │   non-CDB dgnonc_s  │
  │   CDB     dgcdb     │ ── DG ──►      │   CDB     dgcdb_s   │
  └─────────────────────┘                └─────────────────────┘

           ┌──────────────────────┐
           │ NFS /OINSTALL/_dataguard_setup mounted on both hosts │
           └──────────────────────┘
```

### After

```
  ┌─────────────────────┐                ┌─────────────────────┐
  │ host A              │                │ host B              │
  │   CDB dgcdb         │ ── DG ──►      │   CDB dgcdb_s       │
  │     └─ PDB dgnonc_pdb (RW)            │     └─ PDB dgnonc_pdb (MOUNTED via redo)
  └─────────────────────┘                └─────────────────────┘
```

`dgnonc` is shut down (or dropped) and its DG broker config removed. The
content lives as a PDB inside `dgcdb` and is replicated to `dgcdb_s` via the
existing CDB Data Guard.

---

## 2. Why we don't need to recreate the CDB standby

When the CDB primary executes `CREATE PLUGGABLE DATABASE … USING manifest.xml
COPY`, the resulting redo (datafile create + block writes) is shipped to the
CDB standby as part of the existing Data Guard. The standby's MRP picks it up
and tries to create the new PDB datafiles locally.

For each new datafile, the standby needs the **source bytes**. It looks in:

1. The original path embedded in the manifest (the non-CDB primary path).
2. `STANDBY_PDB_SOURCE_FILE_DIRECTORY` (an init parameter on the CDB).
3. `STANDBY_PDB_SOURCE_FILE_DBLINK` (an init parameter, optional, dblink form).

We use option 2: the migration scripts copy the non-CDB datafiles to the NFS
share (mounted with the same path on both hosts) and set
`STANDBY_PDB_SOURCE_FILE_DIRECTORY` to that NFS path. The standby reads the
files locally over NFS and copies them into its target PDB location, then
continues redo apply. **No RMAN duplicate, no manual catalog entries.**

---

## 3. Configuration

`config.env` (copied from `config.env.template`) is the single source of
truth. The important values:

| Variable | Meaning |
|---|---|
| `SOURCE_DB_NAME` / `SOURCE_DB_UNIQUE_NAME` / `SOURCE_STANDBY_UNIQUE_NAME` | non-CDB names |
| `SOURCE_ORACLE_SID` | ORACLE_SID for the non-CDB primary instance |
| `TARGET_CDB_NAME` / `TARGET_CDB_UNIQUE_NAME` / `TARGET_CDB_STANDBY_UNIQUE_NAME` | CDB names |
| `TARGET_CDB_ORACLE_SID` | ORACLE_SID for the CDB primary instance |
| `NEW_PDB_NAME` | What the migrated database will be called inside the CDB |
| `ORACLE_HOME` / `ORACLE_BASE` | Same on both hosts |
| `NFS_SHARE` | Path mounted identically on both DB hosts |
| `TARGET_PDB_DATAFILE_DIR` | Where the PDB's datafiles will live on the CDB primary |
| `ALLOW_DROP_NONCDB` | Set to `I_UNDERSTAND` to enable destructive drop in step 06 |

All scripts read this file via `_lib.sh` and write logs/state to
`${NFS_SHARE}/logs/migrate_<src>_to_<tgt>/`.

---

## 4. Pre-flight (script `01_preflight.sh`) — read-only

Validates everything before touching anything. Run this whenever you want a
safety check; it only queries.

What it checks:

* `sqlplus` and `dgmgrl` on PATH.
* NFS staging dir is writable.
* **Source non-CDB:** role=PRIMARY, log_mode=ARCHIVELOG, force_logging=YES,
  cdb=NO, character set, version, COMPATIBLE, DG broker SUCCESS, no apply lag.
* **Target CDB:** role=PRIMARY, READWRITE, ARCHIVELOG, FORCE_LOGGING=YES,
  cdb=YES, version ≥ source, COMPATIBLE ≥ source, character set matches, DG
  broker SUCCESS, no apply lag, `NEW_PDB_NAME` is unused.
* Disk: target PDB datafile directory exists / can be created.

If any of those fail, the script exits 1 with a per-check summary. **Do not
proceed** until preflight is clean.

Sample tail of the log:

```
[OK]   2026-04-30 18:11:02 - Preflight PASSED. Ready for step 02.
[INFO] 2026-04-30 18:11:02 - State file: /OINSTALL/_dataguard_setup/migrate/dgnonc_to_dgcdb/state.env
[INFO] 2026-04-30 18:11:02 - Log file:   /OINSTALL/_dataguard_setup/logs/migrate_dgnonc_to_dgcdb/01_preflight_*.log
```

---

## 5. Quiesce the non-CDB (script `02_quiesce_noncdb.sh`)

This is the moment you take the outage. The script:

1. Forces a couple of log switches on the non-CDB primary so the standby
   drains down to 0s lag.
2. Bounces the primary into `OPEN READ ONLY` (clean dictionary close + reopen).
3. Verifies `OPEN_MODE=READ ONLY`.
4. Issues `EDIT DATABASE 'dgnonc_s' SET STATE='APPLY-OFF'` so the standby
   datafiles are also frozen at the same SCN.
5. Records the quiesce SCN to the state file.

After this point, no transactions can write to the non-CDB. The standby files
are frozen and can be torn down once you're confident in the new PDB.

If anything goes wrong now, recovery is trivial: re-open the non-CDB
`READ WRITE`, set the standby back to `APPLY-ON`, and you're back to normal.

---

## 6. Describe + stage (script `03_describe_and_stage.sh`)

Generates the unplug XML manifest and copies the non-CDB's datafiles to NFS
so the CDB standby can read them when it applies the plug-in redo.

```
DBMS_PDB.DESCRIBE(pdb_descr_file => '/OINSTALL/.../migrate/.../dgnonc_manifest.xml')
```

Then for each row in `v$datafile`, the script either hard-links (if NFS
happens to be on the same filesystem -- usually no) or `cp`'s the file into
`${MIGRATE_DATAFILE_STAGE}/`. Existing files of the same size are skipped, so
the script is restartable.

Output you should see:

```
[INFO] 2026-04-30 18:13:12 - Calling DBMS_PDB.DESCRIBE -> /OINSTALL/.../dgnonc_manifest.xml
[OK]   2026-04-30 18:13:13 - Manifest written: 18472 bytes
[INFO] 2026-04-30 18:13:13 - Datafile count: 5
[INFO] 2026-04-30 18:13:13 -   copying: /u01/app/oracle/oradata/dgnonc/system01.dbf
…
[OK]   2026-04-30 18:14:55 - Staged 5 datafile(s), ~1340000000 bytes total
```

Disk-space tip: total staging space ≈ size of all SYSTEM/SYSAUX/USERS/UNDO
datafiles combined. Plan the NFS share accordingly, or use a different
staging path via the `MIGRATE_STAGE_DIR` override (edit `_lib.sh`).

---

## 7. Plug into the CDB (script `04_plug_into_cdb.sh`)

This is where the migration actually happens. The script:

1. `ALTER SYSTEM SET STANDBY_PDB_SOURCE_FILE_DIRECTORY='<staged>/' SCOPE=BOTH;`
   on the CDB. The trailing slash matters -- Oracle expects a directory.
2. `DBMS_PDB.CHECK_PLUG_COMPATIBILITY` to surface warnings before commit.
3. ```sql
   CREATE PLUGGABLE DATABASE dgnonc_pdb
       USING '/.../dgnonc_manifest.xml'
       SOURCE_FILE_DIRECTORY = '/.../migrate/dgnonc_to_dgcdb/datafiles/'
       COPY
       FILE_NAME_CONVERT = ('<staged>', '<target_pdb_dir>');
   ```
4. `ALTER PLUGGABLE DATABASE dgnonc_pdb OPEN UPGRADE;`
5. `@?/rdbms/admin/noncdb_to_pdb.sql` inside the PDB. **This is the long one**
   (10–30 minutes typical). Output is captured to its own log file.
6. `CLOSE IMMEDIATE; OPEN READ WRITE; SAVE STATE;`
7. A few `SWITCH LOGFILE; ARCHIVE LOG CURRENT;` calls so redo flows quickly to
   the CDB standby.

`SOURCE_FILE_DIRECTORY` overrides the file paths embedded in the manifest, so
even if the non-CDB datafiles were originally at, say,
`/u01/app/oracle/oradata/dgnonc/`, the primary reads them from the staging
directory we copied them to.

`FILE_NAME_CONVERT` puts the CDB primary's copy of the new PDB datafiles in
`${TARGET_PDB_DATAFILE_DIR}/${NEW_PDB_NAME}/`.

The CDB standby, once it sees the redo, looks up
`STANDBY_PDB_SOURCE_FILE_DIRECTORY`, finds the staged copies, and writes them
into its own equivalent location.

### What can go wrong here

| Symptom | Cause | Fix |
|---|---|---|
| `ORA-65122: pluggable database GUID conflicts` | Reusing a manifest from a prior run, or a PDB with the same GUID exists | drop the prior PDB; re-run `03_describe_and_stage.sh` to generate a fresh manifest |
| `noncdb_to_pdb.sql` exits with `ORA-65106` | Component invalid (e.g. APEX) in the source non-CDB | Address violations in `pdb_plug_in_violations`; usually you re-run the script after the fix |
| Standby never picks up the PDB | `STANDBY_PDB_SOURCE_FILE_DIRECTORY` not visible from the standby host (different mount path) | Make sure NFS has the same path on both hosts; correct the parameter; trigger a log switch |

---

## 8. Verify (script `05_verify_pdb_dataguard.sh`)

Loops `SHOW DATABASE VERBOSE` on the standby until both lags are `0 seconds`,
then:

* Prints the broker `SHOW CONFIGURATION VERBOSE` snapshot.
* Checks `pdb_plug_in_violations` for any open `ERROR` rows.
* Performs a write smoke test inside the new PDB (CREATE TABLE / INSERT /
  COMMIT / DROP), forces a log switch, and confirms the standby's
  `applied_scn` advances past the SCN we just produced.

A successful tail looks like:

```
[OK]   2026-04-30 18:36:11 - CDB standby fully caught up (apply=0s, transport=0s)
…
[OK]   2026-04-30 18:36:25 - Verification PASSED. dgnonc_pdb is in DG, applied on dgcdb_s.
```

---

## 9. Decommission the non-CDB (script `06_decommission_noncdb.sh`, OPTIONAL)

This is purely housekeeping:

* `REMOVE CONFIGURATION;` on the non-CDB DG.
* `DG_BROKER_START=FALSE`, disable archivelog dest 2.
* `SHUTDOWN IMMEDIATE` on the non-CDB primary.
* If `ALLOW_DROP_NONCDB="I_UNDERSTAND"`:
  * `STARTUP MOUNT EXCLUSIVE RESTRICT; ALTER SYSTEM ENABLE RESTRICTED SESSION;
    DROP DATABASE;`
* `rm -rf` the NFS staging directory (manifest + staged datafiles).

The standby host still has `dgnonc_s` data files. Either:

* `STARTUP MOUNT;` and `DROP DATABASE;` on the standby instance, or
* simply remove the spfile/orapw and the data files manually.

The walkthrough chooses to leave that step manual because it's cheap to do
once you're fully confident the new PDB is good, and conservative to leave
in place for a few days as a rollback insurance.

---

## 10. Rollback strategies

**Pre step 04 — easy.** The non-CDB is just `READ ONLY` and the standby's
apply is OFF. Re-open `READ WRITE` on the non-CDB primary, `EDIT DATABASE
'<standby>' SET STATE='APPLY-ON'`, you're back to normal.

```sql
ALTER DATABASE CLOSE;
ALTER DATABASE OPEN;
```

```
DGMGRL> EDIT DATABASE 'dgnonc_s' SET STATE='APPLY-ON';
```

**Mid step 04 (CREATE PLUGGABLE DATABASE failed).** The CDB has either no
new PDB, or one in `MOUNTED` state. Drop it:

```sql
ALTER PLUGGABLE DATABASE dgnonc_pdb CLOSE IMMEDIATE;
DROP PLUGGABLE DATABASE dgnonc_pdb INCLUDING DATAFILES;
```

The standby will see the matching DROP redo and clean up its copy too.

**Post step 04 / mid noncdb_to_pdb.sql.** Same: drop the PDB, fix the
underlying issue, re-run from `04_plug_into_cdb.sh`. The non-CDB is still
intact (READ ONLY).

**After verification.** If you've run the verify and everything is fine, the
rollback is to leave the non-CDB shut down (do **not** run step 06) and
either application-route back to it or do a separate point-in-time recovery.
Step 06 is the point of no return only if `ALLOW_DROP_NONCDB="I_UNDERSTAND"`.

---

## 11. Logs and state

Every script appends to:

* `${MIGRATE_LOG_DIR}/<scriptname>_<timestamp>.log` -- per-script transcript
* `${MIGRATE_LOG_DIR}/migrate.log` -- combined transcript across all scripts
* `${MIGRATE_STAGE_DIR}/state.env` -- machine-readable key=value state

`state.env` is what step 06 inspects to refuse decommissioning if step 05
hasn't recorded a clean run. You can also `cat` it to see SCNs, timings, and
pointers to each step's log file.

---

## 12. Operational notes for the test environment

The `dataguard_setup` repo creates `dgnonc` (non-CDB) via
`tests/e2e/run_e2e_test.sh` and `dgcdb` (CDB) via
`tests/e2e/run_e2e_test_cdb.sh`. Both end up with:

* Datafiles under `/u01/app/oracle/oradata/<db>/`
* Archive logs under `/u01/app/oracle/archive/<db>/`
* Listener on default port 1521
* DG Broker enabled, role-aware service trigger deployed
* NFS share at `/OINSTALL/_dataguard_setup` mounted on both hosts

Those defaults match `config.env.template` -- you only need to verify that
both DGs are up before running `tests/run_migration_test.sh`.
