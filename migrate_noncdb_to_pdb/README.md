# Non-CDB → PDB Migration with Both Sides Already in Data Guard

Scripts for migrating an existing Oracle 19c **non-CDB** (with its own physical
standby) into an existing Oracle 19c **multitenant CDB** (with its own physical
standby), **without recreating either standby**.

The CDB standby is rebuilt for the new PDB **automatically through redo apply**
by pointing it at a staging copy of the non-CDB datafiles via
`STANDBY_PDB_SOURCE_FILE_DIRECTORY` -- no RMAN duplicate, no RESTORE, no manual
file copy on the standby host. That parameter is set **on the CDB standby
instance** (it is not carried in redo), so the scripts need a direct connection
to the standby (wallet `/@<alias>`, or a prompted SYS password) and the share
must be visible from the standby host (`STANDBY_STAGE_DIR`). The prompted
password goes to sqlplus on stdin with substitution off (`&` is safe); a
password containing a double quote cannot be passed through a CONNECT string
and is refused at the prompt - use the wallet then.

The scripts are conservative: where a precondition cannot be proven (standby
unreachable, wrong database behind `SOURCE_ORACLE_SID`, PDB not replicated) they
refuse rather than warn. Step 06 is the destructive one; see "Safety gates".

## When to use this

You have:

* `dgnonc` -- a non-CDB primary on host A, with `dgnonc_s` standby on host B
* `dgcdb`  -- a multitenant CDB primary on host A, with `dgcdb_s` standby on host B
* Both Data Guard configurations are healthy and managed by Data Guard Broker
* You want `dgnonc` to become a PDB inside `dgcdb` (e.g. `dgnonc_pdb`)

You don't have to redo Data Guard. The CDB Data Guard keeps running; the new
PDB just shows up on its standby once redo apply catches up.

## Files in this folder

```
migrate_noncdb_to_pdb/
├── _lib.sh                      shared logging, config, sql/dgmgrl helpers
├── config.env.template          copy → config.env, edit values
├── 01_preflight.sh              read-only checks of both DBs and both DGs
├── 02_quiesce_noncdb.sh         non-CDB primary → READ ONLY, stop standby apply
├── 03_describe_and_stage.sh     DBMS_PDB.DESCRIBE + copy datafiles to NFS
├── 04_plug_into_cdb.sh          CREATE PLUGGABLE DATABASE + noncdb_to_pdb.sql
├── 05_verify_pdb_dataguard.sh   confirm PDB is applied on the CDB standby
├── 06_decommission_noncdb.sh    optional: shut down + drop the old non-CDB
├── run_minimal.sh               LAB-ONLY shortcut for the poug-dg1/dg2 lab (see MINIMAL_STEPS.md)
├── tests/
│   └── run_migration_test.sh    end-to-end test driver (jump host → DB hosts)
├── README.md
└── WALKTHROUGH.md
```

All script logs go to `${NFS_SHARE}/logs/migrate_<src>_to_<tgt>/` and a combined
transcript at `migrate.log` in the same directory.

## Quick start

```bash
cp migrate_noncdb_to_pdb/config.env.template migrate_noncdb_to_pdb/config.env
$EDITOR migrate_noncdb_to_pdb/config.env

cd migrate_noncdb_to_pdb
./01_preflight.sh
./02_quiesce_noncdb.sh
./03_describe_and_stage.sh
./04_plug_into_cdb.sh
./05_verify_pdb_dataguard.sh
# Optional, destructive:
# ./06_decommission_noncdb.sh
```

Each step requires its predecessor (`state.env` flags `preflight_ok`,
`noncdb_quiesced`, `describe_done`, `plug_done`, `verify_done`) and clears its own
and later flags when a new attempt really begins - after its refusal checks, just
before its first change - and `01_preflight.sh` resets all of them, so a stale
flag from an earlier run cannot gate step 06. A refused re-run leaves `state.env`
untouched: re-running step 04 after a successful plug-in is refused ("PDB already
exists") and step 05 still runs. Step 04 cannot be resumed once the PDB exists
(it says how to proceed).

**Unattended runs** set `MIGRATE_NONINTERACTIVE=1`, which auto-answers the YES
prompts. It does **not** authorise `DROP DATABASE`: that also needs
`ALLOW_DROP_NONCDB="I_UNDERSTAND"` in the config **and** `MIGRATE_ALLOW_DROP=1`
in the environment. Without a terminal, standby host directories are only
accepted via `STANDBY_SSH_TARGET` (checked over ssh) or
`STANDBY_DIRS_CONFIRMED=yes`.

## Safety gates

* **01** checks the CDB standby directly: `standby_file_management=AUTO`,
  `db_file_name_convert` (or OMF `db_create_file_dest`) covers the PDB
  directory, the resulting directory exists on the standby host, and the staging
  dir is visible there. Also versions/COMPATIBLE as integers, DBNAME of both SIDs,
  free space for the staged copy and the PDB's COPY.
* **04** sets `STANDBY_PDB_SOURCE_FILE_DIRECTORY` on the standby, reads it back,
  and after `CREATE PLUGGABLE DATABASE` checks every PDB datafile landed under
  `TARGET_PDB_DATAFILE_DIR/<PDB>/`.
* **05** passes only if the standby (direct connection) has the PDB with
  `RECOVERY_STATUS=ENABLED`, no `UNNAMED` datafiles, the same datafile count as
  the primary, and its applied SCN - the standby's own `V$DATABASE.CURRENT_SCN`,
  read with its role in the same query - has reached an SCN taken after a write
  inside the PDB. An unreachable standby, an alias that does not answer as the
  configured `PHYSICAL STANDBY`, and a query error are failures; a query error
  is reported with its ORA- text, never as apply lag (wait/poll:
  `MIGRATE_SCN_WAIT_SECS`/`MIGRATE_SCN_POLL_SECS`, default 120/5).
* **06** proves, before touching anything, that `SOURCE_ORACLE_SID` is the
  non-CDB `SOURCE_DB_NAME` (not a CDB, PRIMARY, OPEN READ ONLY, same DBID as
  preflight recorded) and that the new PDB is OPEN READ WRITE in the CDB.

See `WALKTHROUGH.md` for the full step-by-step explanation, expected output,
rollback procedure, and troubleshooting.

## How it works in one diagram

```
   non-CDB primary (READ ONLY)             CDB primary
   ──────────────────────────              ───────────
   1. DBMS_PDB.DESCRIBE  ──┐                │
                           │                │ 4. CREATE PLUGGABLE DATABASE
                           ▼                │     USING manifest.xml
                    ┌──────────────┐        │     SOURCE_FILE_DIRECTORY =
                    │  NFS share   │  ◄─────┘       <NFS staging dir>
                    │              │                COPY
   2. cp datafiles ►│  manifest +  │        │
                    │  staged DBFs │        │ 5. noncdb_to_pdb.sql
                    └──────┬───────┘        │ 6. OPEN READ WRITE
                           │                │ 7. SAVE STATE
                           │                │
                           │                ▼
                           │       redo  ─────────►  CDB standby
                           │                         8. MRP applies
                           └──── reads source ─────► CREATE PLUGGABLE DATABASE
                                via STANDBY_PDB_       redo, copies the staged
                                SOURCE_FILE_DIRECTORY  datafiles into target
                                                       location, joins DG
```

The non-CDB Data Guard is just frozen at READ ONLY for the duration. After the
migration its DG can be torn down (step 06) or left as a rollback option.

## What the scripts do NOT do

* **No application changes.** Connection strings, services, etc. are out of
  scope. Step 04 prints the new PDB's name; you'll point applications at it.
* **No automatic rollback.** If something fails in step 04 (e.g.
  `noncdb_to_pdb.sql` errors), you'll do `DROP PLUGGABLE DATABASE … INCLUDING
  DATAFILES` and re-run -- see WALKTHROUGH.md.
* **No standby host cleanup of dropped non-CDB files.** Step 06 removes the
  broker config and shuts down (or drops) the non-CDB primary, but you may
  still want to delete the leftover standby datafiles by hand.
