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
`STANDBY_PDB_SOURCE_FILE_DIRECTORY` to that NFS path **on the standby
instance**. The parameter is read by the standby's recovery process and
`ALTER SYSTEM` is not carried in redo, so setting it on the primary (as the
first version of these scripts did) does nothing for the standby; step 04 sets
it through a direct standby connection and reads it back. The standby reads the
files over NFS and copies them into its own PDB location, then continues redo
apply. **No RMAN duplicate, no manual catalog entries.**

What the standby needs on its own side (checked by step 01, not assumed):
`standby_file_management=AUTO`; a way to name the new datafiles
(`db_file_name_convert` covering the PDB directory, or OMF); the resulting
directory on the standby host; and a view of the staging directory
(`STANDBY_STAGE_DIR`, the same path as on the primary when the share is mounted
identically).

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
| `NFS_SHARE` | Path mounted identically on both DB hosts (must be mounted: the scripts refuse a missing/unwritable directory) |
| `TARGET_PDB_DATAFILE_DIR` | Where the PDB's datafiles will live on the CDB **primary**. The standby derives its own directory from its `db_file_name_convert` (or OMF); step 01 computes and checks it |
| `TARGET_CDB_STANDBY_TNS_ALIAS` | (optional) alias for the direct connection to the CDB standby; default `TARGET_CDB_STANDBY_UNIQUE_NAME`. Wallet `/@alias`, or a prompted SYS password |
| `STANDBY_STAGE_DIR` | (optional) path under which the standby host sees the staged datafiles; default = the primary's staging path (identical NFS mount) |
| `STANDBY_SSH_TARGET` | (optional) `user@standbyhost`: step 01 creates/checks the datafile dir and the staging dir over ssh. Without it, step 01 prints the commands and asks you to confirm (or `STANDBY_DIRS_CONFIRMED=yes`) |
| `ALLOW_DROP_NONCDB` | Set to `I_UNDERSTAND` to enable destructive drop in step 06. With `MIGRATE_NONINTERACTIVE=1` the environment variable `MIGRATE_ALLOW_DROP=1` is also required |

All scripts read this file via `_lib.sh` and write logs/state to
`${NFS_SHARE}/logs/migrate_<src>_to_<tgt>/`.

---

## 4. Pre-flight (script `01_preflight.sh`) — read-only

Validates everything before touching anything. Run this whenever you want a
safety check; it only queries.

What it checks:

* `sqlplus` and `dgmgrl` on PATH.
* NFS share exists, staging dir is writable (a warning if the share sits on `/`,
  i.e. may not be mounted).
* **Source non-CDB:** role=PRIMARY, log_mode=ARCHIVELOG, force_logging=YES,
  cdb=NO, character set, version, COMPATIBLE, DG broker SUCCESS, no apply lag.
* **Target CDB:** role=PRIMARY, READWRITE, ARCHIVELOG, FORCE_LOGGING=YES,
  cdb=YES, version ≥ source, COMPATIBLE ≥ source (compared field by field as
  integers), character set matches, DG broker SUCCESS, no apply lag,
  `NEW_PDB_NAME` is unused. `v$database.name` of both SIDs must match the config
  (a wrong `*_ORACLE_SID` is a blocker).
* Disk: target PDB datafile directory exists / can be created, and the staging
  area and the target directory have room for the source datafiles.
* **CDB standby (direct connection):** role PHYSICAL STANDBY of the right CDB
  (DB name and `TARGET_CDB_STANDBY_UNIQUE_NAME`, compared case-insensitively),
  `standby_file_management=AUTO`, `db_file_name_convert` covers the PDB directory
  (or `db_create_file_dest` is set), the resulting directory exists on the
  standby host with room, and the staging dir is visible there. With
  `STANDBY_SSH_TARGET` the directory is created/checked over ssh; otherwise the
  exact `mkdir` is printed and you must confirm it. A standby that cannot be
  reached is a blocker.

Re-running step 01 resets the progress flags in `state.env`
(`noncdb_quiesced`, `describe_done`, `plug_done`, `verify_done`, ...): it is the
start of a migration attempt, not a status check to run mid-way. Every later
step requires its predecessor's flag and refuses otherwise.

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
4. Re-checks that the standby has applied everything the read-only reopen
   produced (apply and transport lag 0), and only then issues
   `EDIT DATABASE 'dgnonc_s' SET STATE='APPLY-OFF'`, so the standby datafiles
   are frozen at the same state. If the lag does not drain the step fails with
   apply still ON; re-running resumes at this point because the source is
   already read-only.
5. Records the quiesce SCN to the state file.

Before the bounce it also proves `SOURCE_ORACLE_SID` is the non-CDB
`SOURCE_DB_NAME` (name, `cdb=NO`, PRIMARY).

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
`${MIGRATE_DATAFILE_STAGE}/`. Every run re-copies (to `<name>.part`, renamed
when complete): a file left by an earlier attempt is never trusted on size
alone, and stale files in the stage are removed. The manifest from an earlier
run is deleted before `DBMS_PDB.DESCRIBE`, and the step requires the
`DESCRIBE_OK` marker. The datafile count is recorded; step 04 refuses to plug
unless the stage holds exactly that many files.

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

1. `ALTER SYSTEM SET STANDBY_PDB_SOURCE_FILE_DIRECTORY='<STANDBY_STAGE_DIR>/' SCOPE=BOTH;`
   **on the CDB standby** (direct connection), read back from
   `v$parameter`, and the standby prerequisites from step 01 re-checked. The
   trailing slash matters -- Oracle expects a directory. (It is also set on the
   primary, where it is not read.) The step refuses to continue if it cannot
   connect to the standby or the read-back differs.
2. `DBMS_PDB.CHECK_PLUG_COMPATIBILITY` to surface warnings before commit.
3. ```sql
   CREATE PLUGGABLE DATABASE dgnonc_pdb
       USING '/.../dgnonc_manifest.xml'
       SOURCE_FILE_DIRECTORY = '/.../migrate/dgnonc_to_dgcdb/datafiles/'
       COPY
       FILE_NAME_CONVERT = ('<staged>', '<target_pdb_dir>',
                            '<original source dir>', '<target_pdb_dir>');
   ```
   The convert is keyed on both the staging directory and the original
   directories from the manifest; see "FILE_NAME_CONVERT keys" below.
   Afterwards every `v$datafile` row of the new PDB must be under
   `<target_pdb_dir>` or the step stops before `noncdb_to_pdb.sql`.
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

**FILE_NAME_CONVERT keys (needs lab confirmation).** With
`SOURCE_FILE_DIRECTORY`, Oracle finds the files in that directory by name; it is
not documented whether `FILE_NAME_CONVERT` is then matched against the staging
path or against the original paths in the manifest. The lab-tested
`run_minimal.sh` keys on the original directories (and has no
`SOURCE_FILE_DIRECTORY`). Step 04 lists both, which is correct under either
reading (an unmatched pair is ignored), and the placement check above proves
where the files really landed. Confirm on the lab that the pairs behave as
intended and, if the original-directory pairs turn out to be unnecessary, drop
them.

Step 04 cannot be resumed once the PDB exists (`ORA-65012`): it detects that and
tells you whether to run step 05 or to drop the leftover PDB first. All of its
refusals (existing PDB, missing manifest, incomplete stage, unreachable standby)
come before it clears the `plug_done`/`verify_done` flags, so an accidental
re-run after a successful plug-in leaves `state.env` as it was and step 05 still
runs.

The CDB standby, once it sees the redo, looks up
`STANDBY_PDB_SOURCE_FILE_DIRECTORY`, finds the staged copies, and writes them
into its own equivalent location.

### What can go wrong here

| Symptom | Cause | Fix |
|---|---|---|
| `ORA-65122: pluggable database GUID conflicts` | Reusing a manifest from a prior run, or a PDB with the same GUID exists | drop the prior PDB; re-run `03_describe_and_stage.sh` to generate a fresh manifest |
| `noncdb_to_pdb.sql` exits with `ORA-65106` | Component invalid (e.g. APEX) in the source non-CDB | Address violations in `pdb_plug_in_violations`; usually you re-run the script after the fix |
| Standby never picks up the PDB / PDB recovery DISABLED on the standby | `STANDBY_PDB_SOURCE_FILE_DIRECTORY` not set on the standby, or the path not visible from the standby host (different mount path) | Set `STANDBY_STAGE_DIR` to the standby's path of the share; re-check with step 01; if the PDB already exists, drop it and re-run step 04 |

---

## 8. Verify (script `05_verify_pdb_dataguard.sh`)

Gates the destructive step 06, so it passes only when the PDB is provably
replicated. It loops `SHOW DATABASE VERBOSE` on the standby until both lags are
`0 seconds`, then:

* Prints the broker `SHOW CONFIGURATION VERBOSE` snapshot.
* Connects **directly to the standby** (a failed connection is a failure, not a
  warning) and requires the new PDB in `v$pdbs` with `RECOVERY_STATUS=ENABLED`
  (a standby that lacked the plug-in files applies the redo with the PDB's
  recovery disabled and still shows lag 0), no `UNNAMED` datafile names, and the
  same datafile count as the primary.
* Checks `pdb_plug_in_violations` for any open `ERROR` rows.
* Performs a write smoke test inside the new PDB (CREATE TABLE / INSERT /
  COMMIT / DROP), takes an SCN after it, forces log switches and requires the
  standby's applied SCN to reach that SCN. The applied SCN is read **on the
  standby** through the direct connection: its own `V$DATABASE.CURRENT_SCN`
  (on a physical standby, mounted or open read-only, the SCN recovery has
  applied through), with `DATABASE_ROLE` and `DB_UNIQUE_NAME` in the same query
  - an alias that reaches the primary or another database is a failure, since
  its `CURRENT_SCN` would pass trivially. `V$ARCHIVE_DEST_STATUS` has no
  `APPLIED_SCN` column in 19c, and the primary's `V$ARCHIVE_DEST.APPLIED_SCN`
  is refreshed lazily and trails the standby. The SCN is taken after the
  write, hence after the plug-in redo, so reaching it proves the plug-in was
  applied; "the SCN a few seconds later" would be the wrong gate because the
  SCN advances without redo on an idle system. Three outcomes are reported as
  what they are: reached; **apply lag** (connected, still behind after
  `MIGRATE_SCN_WAIT_SECS`, default 120 s, polled every `MIGRATE_SCN_POLL_SECS`,
  default 5 s - both SCNs are logged); **error** (the ORA-/SP2- text, after
  two retries - not waited out as if it were lag).

`verify_done` is `false` from the start of the step and set to `true` only when
every check passed.

A successful tail looks like:

```
[OK]   2026-04-30 18:36:11 - CDB standby fully caught up (apply=0s, transport=0s)
…
[OK]   2026-04-30 18:36:24 - Standby applied SCN 20030716 >= gate SCN 20030700 (everything up to and including the PDB round-trip write is applied)
[OK]   2026-04-30 18:36:25 - Verification PASSED. dgnonc_pdb is in DG, applied on dgcdb_s.
```

---

## 9. Decommission the non-CDB (script `06_decommission_noncdb.sh`, OPTIONAL)

This is destructive. Before changing anything it proves what it acts on:
`verify_done=true` with 0 failures from step 05; `SOURCE_ORACLE_SID` is the
non-CDB `SOURCE_DB_NAME` (`v$database.name`, `cdb=NO`, PRIMARY, OPEN READ ONLY,
and the DBID step 01 recorded); and the new PDB is OPEN READ WRITE in the target
CDB primary. If the source instance is down it cannot prove this and refuses.

* `REMOVE CONFIGURATION;` on the non-CDB DG.
* `DG_BROKER_START=FALSE`; the `LOG_ARCHIVE_DEST_STATE_n` of the destination
  that ships to the non-CDB standby (looked up in `v$archive_dest`, not assumed
  to be 2) is set to `DEFER`.
* `SHUTDOWN IMMEDIATE` on the non-CDB primary.
* If `ALLOW_DROP_NONCDB="I_UNDERSTAND"`:
  * `STARTUP MOUNT EXCLUSIVE RESTRICT; ALTER SYSTEM ENABLE RESTRICTED SESSION;
    DROP DATABASE;` -- a plain `DROP DATABASE`: RMAN backups and archived logs
    outside the database files are not removed.
  * Asks for a YES. `MIGRATE_NONINTERACTIVE=1` does **not** answer it; an
    unattended drop also needs `MIGRATE_ALLOW_DROP=1` in the environment, and is
    refused up front (before any shutdown) without it.
* `rm -rf` the staged datafiles under the NFS staging directory. The manifest,
  `state.env` and the logs are **kept**: the manifest cannot be regenerated once
  the source is gone.

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

`state.env` is what each step inspects to refuse to run before its predecessor
has completed (step 06 additionally requires a clean step 05). Step 01 resets
the flags, so an old `verify_done=true` cannot survive into a new attempt.
Steps 02-04 clear their own and later flags only once a new attempt begins
(after their refusal checks, before their first change), so a refused re-run
changes nothing; step 05 sets `verify_done=false` first thing, on purpose. You can also `cat` it to see SCNs, timings, and
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
