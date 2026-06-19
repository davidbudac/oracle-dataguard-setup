# Non-CDB → PDB Migration with Both Sides Already in Data Guard

Scripts for migrating an existing Oracle 19c **non-CDB** (with its own physical
standby) into an existing Oracle 19c **multitenant CDB** (with its own physical
standby), **without recreating either standby**.

The CDB standby is rebuilt for the new PDB **automatically through redo apply**
by pointing it at a staging copy of the non-CDB datafiles via
`STANDBY_PDB_SOURCE_FILE_DIRECTORY` -- no RMAN duplicate, no RESTORE, no manual
file copy on the standby host.

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
