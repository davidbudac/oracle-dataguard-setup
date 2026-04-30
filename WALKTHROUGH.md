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

| Step | Server | Command |
|------|--------|---------|
| 1 | PRIMARY | `./primary/01_gather_primary_info.sh` |
| 2 | PRIMARY | `./primary/02_generate_standby_config.sh` |
| 3 | STANDBY | `./standby/03_setup_standby_env.sh` |
| 4 | PRIMARY | `./primary/04_prepare_primary_dg.sh` |
| 5 | STANDBY | `./standby/05_clone_standby.sh` |
| 6 | PRIMARY | `./primary/06_configure_broker.sh` |
| 7 | STANDBY | `./standby/07_verify_dataguard.sh` |
| 10 | PRIMARY | `./primary/10_generate_handoff_report.sh` |

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

**Review the generated summary and file list before confirming.**

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

## Step 10: Generate Handoff Report

**Server:** PRIMARY

```bash
./primary/10_generate_handoff_report.sh
```

Generates a Markdown handoff document for application teams that consume the database. Run this once Data Guard is verified (and ideally after the optional FSFO and role-aware service trigger steps).

**Contents:**
- Topology table (primary/standby host, SID, listener port)
- Status snapshot (role, modes, MRP, apply lag, archive gaps, FSFO state)
- Connection strings per user-visible service in three flavors:
  - **Primary-only** TNS + JDBC (writes / admin)
  - **Standby-only** TNS + JDBC (read-only reporting)
  - **Role-aware failover** TNS + JDBC (recommended for the app tier when the step-14 service trigger is deployed)
- Verification snippets (`tnsping`, `sqlplus`)

**Output file (on NFS):**
- `dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.md` — share this with client teams.

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

`dg_handoff.sh` produces the same Markdown handoff document as Step 10, but works against any existing Data Guard configuration without depending on the setup-time `standby_config_*.env`, `common/dg_functions.sh`, or the NFS share. Topology (peer `DB_UNIQUE_NAME`, hostnames, listener port) is discovered from `V$DATABASE`, `V$DATAGUARD_CONFIG`, `V$LISTENER_NETWORK`, and `DGMGRL SHOW DATABASE VERBOSE`.

**Requirements:**
- Run on the PRIMARY with `ORACLE_SID` and `ORACLE_HOME` set
- `sqlplus '/ as sysdba'` and `dgmgrl` must work locally
- Data Guard Broker should be started for full topology discovery (otherwise use the override flags)

**Override flags** (use when broker is down or discovery returns the wrong value):
- `--primary-host HOST` / `--standby-host HOST` — override hostnames in connect strings
- `--port PORT` — override listener port (default: discover or 1521)
- `--domain DOMAIN` — DB domain to append to the default service name

**Output:** `./dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.md` (or the path passed via `-o`).

Use this when you need to refresh handoff documentation on a system that wasn't built with these scripts, or after the NFS share has been retired.

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
│  PRIMARY:  ./primary/10_generate_handoff_report.sh ← HANDOFF DOC        │
│                                                                         │
│  POST-SETUP / STANDALONE:                                               │
│  ════════════════════════                                               │
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
