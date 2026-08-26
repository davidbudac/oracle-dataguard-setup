# Oracle 19c Data Guard Setup - Walkthrough

Step-by-step guide for setting up a physical standby database.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   ┌─────────────────────┐              ┌─────────────────────┐              │
│   │   PRIMARY SERVER    │              │   STANDBY SERVER    │              │
│   │                     │              │                     │              │
│   │   ┌─────────────┐   │              │   ┌─────────────┐   │              │
│   │   │  Database   │   │   ◄──────►   │   │  Database   │   │              │
│   │   │  (PROD)     │   │   Network    │   │  (PRODSTBY) │   │              │
│   │   └─────────────┘   │              │   └─────────────┘   │              │
│   │                     │              │                     │              │
│   └──────────┬──────────┘              └──────────┬──────────┘              │
│              │                                    │                         │
│              │         ┌──────────────────┐       │                         │
│              └────────►│   NFS SHARE      │◄──────┘                         │
│                        │ /OINSTALL/       │                                 │
│                        │ _dataguard_setup │                                 │
│                        └──────────────────┘                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

### Primary Server

- [ ] Oracle 19c database running in ARCHIVELOG mode
- [ ] FORCE_LOGGING enabled
- [ ] Password file exists (`$ORACLE_HOME/dbs/orapw<SID>`)
- [ ] `REMOTE_LOGIN_PASSWORDFILE = EXCLUSIVE`

### Standby Server

- [ ] Oracle 19c software installed (same version, same ORACLE_HOME path)
- [ ] Sufficient disk space for database files
- [ ] Network connectivity to primary (port 1521)

### NFS Setup (both servers)

```bash
# On NFS server (can be primary, standby, or dedicated server):
sudo ./nfs/01_setup_nfs_server.sh

# On PRIMARY and STANDBY servers:
sudo ./nfs/02_mount_nfs_client.sh
```

### Quick Checks (on Primary)

```sql
-- Must be ARCHIVELOG
SELECT LOG_MODE FROM V$DATABASE;

-- Should be YES
SELECT FORCE_LOGGING FROM V$DATABASE;

-- Must be EXCLUSIVE
SHOW PARAMETER REMOTE_LOGIN_PASSWORDFILE;
```

---

## Execution Flow

```
    PRIMARY SERVER                              STANDBY SERVER
    ══════════════                              ══════════════

    Step 1: Gather Info
        │
        ▼
    Step 2: Generate Config ──────────────────► Step 3: Setup Environment
        │                        (NFS)                    │
        │                                                 │
    Step 4: Prepare Primary ◄─────────────────────────────┘
        │
        └────────────────────────────────────► Step 5: RMAN Clone
                                                         │
    Step 6: Configure Broker ◄───────────────────────────┘
        │
        └────────────────────────────────────► Step 7: Verify Setup
```

| Step | Server | Command | Notes |
|------|--------|---------|-------|
| 1 | PRIMARY | `./primary/01_gather_primary_info.sh` | |
| 2 | PRIMARY | `./primary/02_generate_standby_config.sh` | |
| 3 | STANDBY | `./standby/03_setup_standby_env.sh` | |
| 4 | PRIMARY | `./primary/04_prepare_primary_dg.sh` | |
| 5 | STANDBY | `./standby/05_clone_standby.sh` | |
| 6 | PRIMARY | `./primary/06_configure_broker.sh` | |
| 7 | STANDBY | `./standby/07_verify_dataguard.sh` | |
| 8 | PRIMARY | `./primary/08_security_hardening.sh` | optional |
| 9 | PRIMARY | `./primary/09_configure_fsfo.sh` | optional |
| 10 | OBSERVER | `./fsfo/observer.sh setup` then `start` | optional, required for FSFO |
| 11 | PRIMARY | `./trigger/create_role_trigger.sh` | optional |
| 12 | any host | `./common/cleanup_nfs_artifacts.sh` | optional |
| 13 | PRIMARY | `./primary/13_set_max_availability.sh` | optional, **skip if Step 9 ran** |

Recommended, any time after Step 7 (run before Step 12's `--all` cleanup):

| What | Server | Command |
|------|--------|---------|
| Handoff report | PRIMARY | `./primary/10_generate_handoff_report.sh` |
| Peer wallet | BOTH | `bash common/setup_dg_wallet.sh` |

### Optional Runtime Modes

All workflow scripts that use `common/dg_functions.sh` support:

```bash
./standby/03_setup_standby_env.sh --check
./primary/06_configure_broker.sh --verbose
./standby/05_clone_standby.sh --approval-mode
APPROVAL_MODE=1 VERBOSE=1 ./primary/09_configure_fsfo.sh
```

- `--check` or `--plan`
  Runs a preflight-only pass for steps 3-9 and exits before making changes.
- `--verbose`
  Prints exact shell command tracing.
- `--approval-mode`
  Pauses before mutating actions and shows an approval block with action, impact, log file, and command preview.
- `--suspicious`
  Backward-compatible alias for `--approval-mode`.

Each workflow step writes a state file under `${NFS_SHARE}/state/` that records the current step, final status, generated artifacts, and next-step hint.

---

## Step 1: Gather Primary Information

**Server:** PRIMARY

```bash
export ORACLE_SID=PROD
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
./primary/01_gather_primary_info.sh
# Optional:
./primary/01_gather_primary_info.sh --verbose --approval-mode
```

**Output files (on NFS):**
- `primary_info_<DB_UNIQUE_NAME>.env` - Database configuration
- `orapw<SID>` - Password file copy

---

## Step 2: Generate Standby Configuration

**Server:** PRIMARY

```bash
./primary/02_generate_standby_config.sh
```

**Prompts:**
- Standby server hostname
- Standby DB_UNIQUE_NAME (e.g., `PRODSTBY`) — must differ from primary
- Standby ORACLE_SID (default: same as primary)
- Storage mode: `1` Traditional (path substitution via `DB_FILE_NAME_CONVERT`) or `2` OMF (`db_create_file_dest` + `db_recovery_file_dest`)
- If OMF: `db_create_file_dest`, `db_recovery_file_dest`, `db_recovery_file_dest_size`
- If Traditional: optionally use a SEPARATE directory for standby redo logs; if yes, the primary and standby SRL paths
- If Traditional: confirmation for each path that could NOT be auto-derived (no DB-name component — usually redo/temp on its own mount). Accept the identical path, or enter the correct standby directory
- If Traditional: a numbered `primary -> standby` mapping table — Enter to accept all, or a number to override one entry. Use this when the standby's layout differs from the primary's
- Standby ORACLE_BASE and ORACLE_HOME (default: the primary's values)

**Review the generated summary and file list before confirming.**

**Different filesystem layout on the standby?** Correct it in the two path prompts above — they run before anything is generated. Afterwards, edit the `PRIMARY_*_PATHS` / `STANDBY_*_PATHS` arrays in the `.env` and re-run `./primary/02_generate_standby_config.sh --regenerate` (edit the arrays, not the convert strings — `--regenerate` rebuilds those from the arrays and writes them back to the `.env`).

> Both path prompts appear on an interactive terminal only. Piped/non-interactive runs accept the derived defaults, so use the edit-env + `--regenerate` route there.

**Output files (on NFS):**
- `standby_config_<STANDBY_DB_UNIQUE_NAME>.env` - Master configuration (single source of truth)
- `init<SID>_<STANDBY_DB_UNIQUE_NAME>.ora` - Standby parameter file
- `tnsnames_entries_<STANDBY_DB_UNIQUE_NAME>.ora` - Network entries
- `listener_<STANDBY_DB_UNIQUE_NAME>.ora` - Listener configuration
- `configure_broker_<STANDBY_DB_UNIQUE_NAME>.dgmgrl` - Broker configuration script

---

## Step 3: Setup Standby Environment

**Server:** STANDBY

```bash
export ORACLE_SID=PROD
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
./standby/03_setup_standby_env.sh
```

**Actions:**
- Creates directory structure
- Copies password file
- Configures listener (static registration)
- Configures tnsnames.ora

**Approval mode note:** with `--approval-mode`, filesystem and listener changes are shown for confirmation before they run.

**Verify listener:**
```bash
lsnrctl status
# Should show service with status UNKNOWN (static registration)
```

---

## Step 4: Prepare Primary for Data Guard

**Server:** PRIMARY

```bash
./primary/04_prepare_primary_dg.sh
```

**Actions:**
- Adds TNS entries for standby
- Creates standby redo logs (if needed)
- Enables DG_BROKER_START
- Validates network connectivity to standby

---

## Step 5: Clone the Standby Database

**Server:** STANDBY

```bash
./standby/05_clone_standby.sh
```

**Prompts:**
- SYS password (used for RMAN connection, not stored)
- Type the standby `DB_UNIQUE_NAME` before the RMAN duplicate begins
- If `--approval-mode` is enabled, approval before RMAN duplicate and other mutating actions

**Duration:** Depends on database size (can take hours for large databases)

**Monitor progress:**
```bash
tail -f /OINSTALL/_dataguard_setup/logs/rman_duplicate_*.log
```

---

## Step 6: Configure Data Guard Broker

**Server:** PRIMARY

```bash
./primary/06_configure_broker.sh
```

**Actions:**
- Creates DGMGRL configuration
- Adds primary and standby databases
- Enables configuration
- Tests log shipping

**Output:** numbered progress sections, broker summary, and next-step guidance.

---

## Step 7: Verify Data Guard

**Server:** STANDBY

```bash
./standby/07_verify_dataguard.sh
```

**Expected results:**
- Database role: PHYSICAL STANDBY
- MRP status: APPLYING_LOG
- Archive gaps: 0
- Broker status: SUCCESS
- Clear health summary with errors, warnings, and key sequence numbers

---

## Step 8: Security Hardening (Optional)

**Server:** PRIMARY

```bash
./primary/08_security_hardening.sh
```

Rotates the SYS password to a random value and locks the SYS account. Rotation and lock
are two separate sqlplus calls: if rotation succeeds but the lock fails, the script
keeps going (the primary is rotated either way), stages the refreshed password file,
prints an ACTION REQUIRED block, and exits `1`.

It also refreshes the Step 1 staged copy `orapw<PRIMARY_ORACLE_SID>` on the NFS share -
not just the `_hardened` name - so a re-run of Step 3 after hardening installs the
**rotated** password file.

> The absence of `ORA-16191` right after rotation is expected (existing transport
> connections stay authenticated until they reconnect) and is reported as such, not as
> proof transport survived.

> **After this runs, Step 5 can no longer clone.** `05_clone_standby.sh` detects the
> locked SYS (`ORA-28000`) and prints the fix: temporarily
> `ALTER USER SYS ACCOUNT UNLOCK` + `IDENTIFIED BY <temp>` on the primary, re-run Step 5,
> then re-run Step 8 to re-harden and re-propagate the password file.

---

## Step 9: Configure Fast-Start Failover (Optional)

**Server:** PRIMARY

```bash
./primary/09_configure_fsfo.sh
```

Creates an observer user with `SYSDG`, sets protection mode MAXIMUM AVAILABILITY and
`LogXptMode=FASTSYNC`, and enables FSFO (default threshold 30 s, override with
`FSFO_THRESHOLD`).

- **On a CDB** the observer user must be a common user: the script detects
  `V$DATABASE.CDB = YES`, accepts `#` in usernames, and auto-prefixes `C##` (confirmed
  on a TTY; logged and applied automatically otherwise).
- SYSDG possession is checked via `V$PWFILE_USERS` - administrative privileges never
  appear in `DBA_ROLE_PRIVS`.
- **This step already applies both MAXAVAILABILITY and FASTSYNC**, so Step 13 is a no-op
  afterwards.

---

## Step 10: Observer Setup (Optional)

**Server:** OBSERVER (the standby host, or a dedicated 3rd host - 3rd host recommended
for production, since it survives the loss of either database)

```bash
./fsfo/observer.sh setup     # create the wallet with SYSDG credentials
./fsfo/observer.sh start     # start the observer in the background
./fsfo/observer.sh status
./fsfo/observer.sh stop
./fsfo/observer.sh restart
```

The observer connects with `dgmgrl /@PRIMARY_TNS_ALIAS` using the wallet - no stored
passwords. **Automatic failover only happens while the observer is running**; stop it
before planned database maintenance.

`observer.sh` validates a pidfile's PID against the process's actual command line (it
must be a `dgmgrl` process) before trusting it, and cleans up stale or mismatched
pidfiles automatically.

**Adding an observer later, on a third host?** Steps 9-10 need this build's
`standby_config_*.env` on the NFS share. To retrofit an observer onto a configuration
that already exists and already works - including one this repo did not build - use the
standalone `add_observer/` kit instead (see [Side Toolkits](#side-toolkits)).

---

## Step 11: Role-Aware Service Trigger (Optional)

**Server:** PRIMARY

```bash
./trigger/create_role_trigger.sh
```

Discovers running user services, then creates `SYS.DG_SERVICE_MGR` plus two triggers
(`AFTER DB_ROLE_CHANGE` and `AFTER STARTUP`). Services are started on PRIMARY and stopped
on STANDBY. The objects replicate to the standby via redo, so they fire on both sides.
Re-run any time to refresh the service list.

**Pick the right variant:**

| Script | Use when |
|--------|----------|
| `create_role_trigger.sh` | Non-CDB, SYS objects allowed |
| `create_role_trigger_dedicated_user.sh` | Non-CDB, policy forbids SYS objects (creates `DG_ADMIN`) |
| `create_role_trigger_cdb.sh` | Multitenant - manages services inside PDBs as well as `CDB$ROOT` |

Both non-CDB scripts refuse to run on a CDB. There is no CDB-aware dedicated-user
variant yet.

To create the services themselves on a CDB:

```bash
./trigger/create_pdb_service.sh --pdb SALESPDB --service sales_rw
./trigger/create_cdb_service.sh --service admin_svc
```

Then re-run `create_role_trigger_cdb.sh` so the new service becomes role-aware.

> **ADG caveat (CDB variant):** on a standby opened READ ONLY WITH APPLY, the deferred
> `DBMS_SCHEDULER` job fails with `ORA-16000` and services are **not** stopped by the
> trigger. Watch the alert log for `DG_SERVICE_MGR SCHEDULE failed`.

See [docs/DATA_GUARD_WALKTHROUGH.md](docs/DATA_GUARD_WALKTHROUGH.md#step-11-role-aware-service-trigger-optional)
for the full variant comparison.

---

## Step 12: NFS Artifact Cleanup (Optional)

**Server:** any host with the share mounted

```bash
./common/cleanup_nfs_artifacts.sh                 # password files, pfile, RMAN cmdfiles/logs
./common/cleanup_nfs_artifacts.sh -c /path/to/standby_config_<NAME>.env
./common/cleanup_nfs_artifacts.sh --all           # also the config .env, handoff report + HTML, app-impact HTML
./common/cleanup_nfs_artifacts.sh -y              # skip the confirmation prompt
```

Steps 1, 8, and 9 stage `orapw*` password file copies (SYS password hash) on the
group-readable share; Steps 2 and 5 leave a generated pfile and RMAN cmdfiles/logs.
Nothing is cleaned up automatically. The script prints exactly what it will remove and
what it will keep, and requires confirmation.

> Run Step 13 **before** an `--all` cleanup - it needs the `standby_config_*.env`.
> Generate and review the handoff report first, too.

> RMAN cmdfiles/logs are not tagged with `DB_UNIQUE_NAME`, so if several builds shared
> the share, review the printed list before confirming.

---

## Step 13: Set Maximum Availability Protection (Optional)

**Server:** PRIMARY

```bash
./primary/13_set_max_availability.sh
./primary/13_set_max_availability.sh --check      # preflight only, changes nothing
```

Zero-data-loss protection **without** FSFO. Validates first (broker
`SHOW CONFIGURATION` health, `VALIDATE DATABASE` on both members, transport/apply lag,
archive destination errors), then sets `LogXptMode=FASTSYNC` on both databases and
`EDIT CONFIGURATION SET PROTECTION MODE AS MAXAVAILABILITY`, then polls until
`SHOW CONFIGURATION` returns SUCCESS.

- **Skip this if Step 9 ran** - FSFO setup already applies both settings. The script
  detects that and exits as a no-op.
- If FSFO is enabled but the settings do not match, the script refuses: the broker
  rejects `LogXptMode` edits on FSFO members. Use `DISABLE FAST_START FAILOVER` or
  re-run Step 9.
- Validation findings require explicit confirmation to proceed.
- `ORA-16627` on the mode change means the standby is not synchronized.

Idempotent - if the configuration is already MAXAVAILABILITY + FASTSYNC on both sides,
it says so and exits successfully.

---

## Generate the Handoff Report (Recommended)

**Server:** PRIMARY — run any time after Step 7, and before Step 12's `--all` cleanup.

```bash
./primary/10_generate_handoff_report.sh
```

Generates a handoff document for application teams that consume the database. Run it once Data Guard is verified, and ideally after the optional FSFO (Steps 9-10) and role-aware service trigger (Step 11) steps, so it describes the finished topology.

**Contents:**
- Connection strings per user-visible service in three flavors:
  - **Primary-only** TNS + JDBC (writes / admin)
  - **Standby-only** TNS + JDBC (read-only reporting; marked unusable when the standby is MOUNTED, with ADG licensing/staleness/ORA-16000 caveats when it is READ ONLY WITH APPLY)
  - **Role-aware failover** TNS + JDBC + Easy Connect Plus — one descriptor with both hosts in `ADDRESS_LIST`. Recommended for the app tier once the Step 11 trigger is deployed: the service only runs on whichever side is currently primary, so clients follow the active database across a switchover or failover
- Topology table (primary/standby host, SID, listener port) and an **Interactive diagram** link encoding the discovered topology — never credentials — for `https://davidbudac.cz/dataguard/` (override with `DG_DOC_BASE_URL`)
- Status snapshot (roles, open modes, protection mode, standby `LogXptMode`, MRP, apply lag, archive gaps, FSFO state, broker config, role-trigger deployment, `SQLNET.EXPIRE_TIME`)
- A computed **Verdict** (HEALTHY / WARNING / ERROR) with every reason named
- Application-engineering detail: per-mode RPO semantics, outage-budget breakdown, an ORA- error table for role transitions with retryability, descriptor-parameter reference with worst-case connect math, ADG read-staleness controls, driver mapping examples, a client/pool checklist, and verification snippets (`tnsping`, `nc -z`, and a `SYS_CONTEXT` role check that doubles as the switchover-drill pass criterion)

**Output files (on NFS):**
- `dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.md` — share this with client teams
- `dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.html` — styled, self-contained twin of the same content (rendered from the Markdown, so the two never diverge)
- `dg_application_impact.html` — copy of `docs/DG_APPLICATION_IMPACT.html` when available; supplementary, the Markdown stands on its own

Re-run the script after listener changes, new services, or topology changes to refresh the report.

---

## Standalone Handoff Report (Post-Setup)

**Server:** PRIMARY

```bash
./dg_handoff.sh
./dg_handoff.sh -o /tmp/handoff.md
./dg_handoff.sh --primary-host pri.example.com \
                --standby-host stb.example.com \
                --port 1521
```

`dg_handoff.sh` produces the same handoff document as `primary/10_generate_handoff_report.sh`, but works against any existing Data Guard configuration without depending on the setup-time `standby_config_*.env`, `common/dg_functions.sh`, or the NFS share. Topology (peer `DB_UNIQUE_NAME`, hostnames, listener port) is discovered from `V$DATABASE`, `V$DATAGUARD_CONFIG`, `V$LISTENER_NETWORK`, and `DGMGRL SHOW DATABASE VERBOSE`.

**Requirements:**
- Run on the PRIMARY with `ORACLE_SID` and `ORACLE_HOME` set
- `sqlplus '/ as sysdba'` and `dgmgrl` must work locally
- Data Guard Broker should be started for full topology discovery (otherwise use the override flags)

**Override flags** (use when broker is down or discovery returns the wrong value):
- `--primary-host HOST` / `--standby-host HOST` — override hostnames in connect strings
- `--port PORT` — override listener port (default: discover or 1521)
- `-o FILE` — output path (default `./dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.md`)

**Output:** the Markdown file above, plus the HTML twin written next to it.

Use this when you need to refresh handoff documentation on a system that wasn't built with these scripts, or after the NFS share has been retired.

---

## Operational Tools

None of these change the database. `dg_check_srl.sh` prints DDL but never runs it.

### Peer Wallet (do this first)

```bash
bash common/setup_dg_wallet.sh          # on EACH DB host
bash common/setup_dg_wallet.sh -A       # generate the wallet password automatically
```

Creates an auto-login wallet with the peer's SYS credentials so the local tools below
can query the other side without prompting. Idempotent. See
[docs/WALLET_SETUP.md](docs/WALLET_SETUP.md).

### Health Dashboard (from a jump host)

```bash
bash dg_status.sh                # $ORACLE_SID or auto-detect from ora_pmon_
bash dg_status.sh -s cdb1
bash dg_status.sh --no-color
```

Checks both databases over SSH: roles, modes, broker status, services, SRL counts,
archive gaps and destination errors, FRA usage, MRP, transport/apply lag, UNNAMED
datafiles, FSFO, and recent DG alert log entries. Exit `0` healthy / `1` warnings /
`2` errors / `3` usage error — use those in cron instead of scraping the output.
See [docs/DG_STATUS.md](docs/DG_STATUS.md).

### Local Triage / Diagnostics (on a DB host)

```bash
bash dg_triage_sid.sh            # fast, wallet-only auth
bash dg_diag_sid.sh              # deep, prompts if wallet auth fails
bash dg_triage_sid.sh -L         # local + broker only
bash dg_diag_sid.sh -P           # force SYS password prompt for the remote side
```

See [docs/DG_CHECK.md](docs/DG_CHECK.md).

### Standby Redo Log Audit

```bash
./dg_check_srl.sh                # both sides, peer via wallet
./dg_check_srl.sh -p             # prompt for SYS password for the peer
./dg_check_srl.sh -L             # local only
```

Verifies (online redo groups + 1) SRL groups per thread at the size of the largest
online redo log, on both sides, and prints the exact fix DDL. Exit `0` compliant /
`1` DDL needed / `2` argument or data error.

### What Is SYNC Costing Commits? (on the PRIMARY)

```bash
./dg_sync_impact.sh                          # ASH 24h, AWR 7 days
./dg_sync_impact.sh --auto-baseline          # detect the pre-SYNC baseline from AWR
./dg_sync_impact.sh --no-pack                # no Diagnostics Pack license
./dg_sync_impact.sh --html -o impact.html
```

Models the added per-commit latency as `E[max(L,R)] - E[L]` from
`V$EVENT_HISTOGRAM_MICRO` — the local redo write and the remote ack run in parallel, so
averages alone cannot give this number. See
[docs/DG_SYNC_IMPACT.md](docs/DG_SYNC_IMPACT.md).

### Interactive Diagram Link

```bash
./get_dg_config_url.sh           # summary on stderr, URL on stdout
./get_dg_config_url.sh -q        # URL only
```

Same link the handoff report embeds, without generating a report. Runs from either side.

---

## Side Toolkits

Self-contained subprojects with their own docs, outside the numbered workflow:

- **`add_observer/`** — add an FSFO observer on a **third host** to an already-working
  configuration (`01_prepare_primary.sh` on the primary builds a bundle;
  `02_setup_observer_host.sh` / `03_observer_ctl.sh` / `04_verify_observer.sh` run on the
  third host). Works against configurations this repo did not build. Never changes
  protection mode, `LogXptMode`, or transport.
- **`observer_sys_to_sysdg/`** — convert an existing FSFO observer that authenticates as
  SYS to a dedicated SYSDG-only user (create the user on the primary, swap the wallet
  credentials and restart the observer, verify). For configurations built by hand or by
  other tooling; new builds through Steps 9-10 already have this shape.
- **`migrate_noncdb_to_pdb/`** — migrate a non-CDB with its own standby into an existing
  CDB with its own standby, without recreating either standby.

---

## Post-Setup Commands

### DGMGRL (Recommended)

```bash
# Check configuration status
dgmgrl / "show configuration"

# Check database details
dgmgrl / "show database 'PRODSTBY'"

# Validate standby
dgmgrl / "validate database 'PRODSTBY'"

# Switchover
dgmgrl / "switchover to 'PRODSTBY'"

# Failover (only if primary is down)
dgmgrl / "failover to 'PRODSTBY'"
```

### SQL

```sql
-- Check MRP status (on standby)
SELECT PROCESS, STATUS, SEQUENCE# FROM V$MANAGED_STANDBY;

-- Check for gaps (on standby)
SELECT * FROM V$ARCHIVE_GAP;

-- Force log switch (on primary)
ALTER SYSTEM SWITCH LOGFILE;
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| tnsping fails | Check listener, hostname, firewall |
| ORA-01017 during RMAN | Verify password file copied correctly |
| MRP not running | Bounce apply on the standby: `dgmgrl / "edit database 'PRODSTBY' set state=apply-off"` then `dgmgrl / "edit database 'PRODSTBY' set state=apply-on"` |
| Archive gaps | Bounce transport on the primary: `dgmgrl / "edit database 'PROD' set state=transport-off"` then `dgmgrl / "edit database 'PROD' set state=transport-on"` |
| Broker shows WARNING | `dgmgrl / "show database 'PRODSTBY' 'StatusReport'"` |

---

## Quick Reference

```
┌─────────────────────────────────────────────────────────────────────────┐
│  EXECUTION ORDER:                                                       │
│  ════════════════                                                       │
│  PRIMARY:  ./primary/01_gather_primary_info.sh                          │
│  PRIMARY:  ./primary/02_generate_standby_config.sh ← REVIEW CONFIG      │
│  STANDBY:  ./standby/03_setup_standby_env.sh                            │
│  PRIMARY:  ./primary/04_prepare_primary_dg.sh                           │
│  STANDBY:  ./standby/05_clone_standby.sh           ← ENTER PASSWORD     │
│  PRIMARY:  ./primary/06_configure_broker.sh        ← ENABLES SHIPPING   │
│  STANDBY:  ./standby/07_verify_dataguard.sh                             │
│                                                                         │
│  OPTIONAL (in order):                                                   │
│  ════════════════════                                                   │
│  PRIMARY:  ./primary/08_security_hardening.sh      ← LOCKS SYS          │
│  PRIMARY:  ./primary/09_configure_fsfo.sh          ← MAXAVAIL+FASTSYNC  │
│  OBSERVER: ./fsfo/observer.sh setup && ... start                        │
│  PRIMARY:  ./trigger/create_role_trigger.sh                             │
│  ANY:      ./common/cleanup_nfs_artifacts.sh       ← SCRUB NFS SHARE    │
│  PRIMARY:  ./primary/13_set_max_availability.sh    ← SKIP IF 9 RAN      │
│                                                                         │
│  RECOMMENDED (after step 7, before --all cleanup):                      │
│  ═════════════════════════════════════════════════                      │
│  PRIMARY:  ./primary/10_generate_handoff_report.sh ← HANDOFF DOC        │
│  BOTH:     bash common/setup_dg_wallet.sh          ← PEER WALLET        │
│                                                                         │
│  POST-SETUP / STANDALONE:                                               │
│  ════════════════════════                                               │
│  JUMPHOST: bash dg_status.sh                       ← HEALTH DASHBOARD   │
│  DB HOST:  bash dg_triage_sid.sh / dg_diag_sid.sh                       │
│  DB HOST:  ./dg_check_srl.sh                       ← SRL AUDIT + DDL    │
│  PRIMARY:  ./dg_sync_impact.sh                     ← SYNC COMMIT COST   │
│  PRIMARY:  ./dg_handoff.sh                         ← REFRESH HANDOFF    │
│                                                                         │
│  KEY COMMANDS:                                                          │
│  ═════════════                                                          │
│  dgmgrl / "show configuration"                                          │
│  dgmgrl / "show database 'PRODSTBY'"                                    │
│  dgmgrl / "switchover to 'PRODSTBY'"                                    │
│                                                                         │
│  CONFIG FILES (include DB_UNIQUE_NAME for concurrent builds):           │
│  ═════════════                                                          │
│  /OINSTALL/_dataguard_setup/standby_config_<STBY_NAME>.env              │
│  /OINSTALL/_dataguard_setup/primary_info_<PRI_NAME>.env                 │
└─────────────────────────────────────────────────────────────────────────┘
```
