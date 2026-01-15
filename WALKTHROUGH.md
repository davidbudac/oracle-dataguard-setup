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
| 2 | PRIMARY | `./common/02_generate_standby_config.sh` |
| 3 | STANDBY | `./standby/03_setup_standby_env.sh` |
| 4 | PRIMARY | `./primary/04_prepare_primary_dg.sh` |
| 5 | STANDBY | `./standby/05_clone_standby.sh` |
| 6 | PRIMARY | `./primary/06_configure_broker.sh` |
| 7 | STANDBY | `./standby/07_verify_dataguard.sh` |
| 8 | PRIMARY | `./primary/08_security_hardening.sh` (Optional) |

---

## Step 1: Gather Primary Information

**Server:** PRIMARY

```bash
export ORACLE_SID=PROD
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
./primary/01_gather_primary_info.sh
```

**Output files (on NFS):**
- `primary_info_<DB_UNIQUE_NAME>.env` - Database configuration
- `orapw<SID>` - Password file copy

---

## Step 2: Generate Standby Configuration

**Server:** PRIMARY

```bash
./common/02_generate_standby_config.sh
```

**Prompts:**
- Standby server hostname
- Standby DB_UNIQUE_NAME (e.g., `PRODSTBY`)
- Standby ORACLE_SID (default: same as primary)

**Review the configuration summary and confirm.**

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

---

## Step 8: Security Hardening (Optional)

**Server:** PRIMARY

```bash
./primary/08_security_hardening.sh
```

**Actions:**
- Changes SYS password to a random value (not stored anywhere)
- Locks the SYS account

**After running this script:**
- Use OS authentication `/ as sysdba` for all DBA connections
- Data Guard redo transport continues to work (uses password file)

**Note:** This step is optional but recommended for production environments.

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
| tnsping fails | Check listener, hostname, firewall (port 1521) |
| ORA-01017 during RMAN | Verify password file copied correctly |
| MRP not running | `ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;` |
| Archive gaps | Check FAL_SERVER, network connectivity; broker should auto-resolve |
| Broker shows WARNING | `dgmgrl / "show database 'PRODSTBY' 'StatusReport'"` |

---

## Quick Reference

```
┌─────────────────────────────────────────────────────────────────────────┐
│  EXECUTION ORDER:                                                       │
│  ════════════════                                                       │
│  PRIMARY:  ./primary/01_gather_primary_info.sh                          │
│  PRIMARY:  ./common/02_generate_standby_config.sh  ← REVIEW CONFIG      │
│  STANDBY:  ./standby/03_setup_standby_env.sh                            │
│  PRIMARY:  ./primary/04_prepare_primary_dg.sh                           │
│  STANDBY:  ./standby/05_clone_standby.sh           ← ENTER PASSWORD     │
│  PRIMARY:  ./primary/06_configure_broker.sh        ← ENABLES SHIPPING   │
│  STANDBY:  ./standby/07_verify_dataguard.sh                             │
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
