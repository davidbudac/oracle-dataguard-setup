# Oracle 19c Data Guard Setup: Script Walkthrough & Manual Equivalent

This document describes what each automation script does and shows the equivalent manual steps a DBA would perform without the scripts.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [NFS Setup](#nfs-setup)
3. [Restartability](#restartability)
4. [Common Flags](#common-flags)
5. [Session Management](#session-management)
6. [Step 1: Gather Primary Information](#step-1-gather-primary-information)
7. [Step 2: Generate Standby Configuration](#step-2-generate-standby-configuration)
8. [Step 3: Setup Standby Environment](#step-3-setup-standby-environment)
9. [Step 4: Prepare Primary for Data Guard](#step-4-prepare-primary-for-data-guard)
10. [Step 5: Clone Standby Database](#step-5-clone-standby-database)
11. [Step 6: Configure Data Guard Broker](#step-6-configure-data-guard-broker)
12. [Step 7: Verify Data Guard](#step-7-verify-data-guard)
13. [Step 8: Security Hardening (Optional)](#step-8-security-hardening-optional)
14. [Step 9: Configure Fast-Start Failover (Optional)](#step-9-configure-fast-start-failover-optional)
15. [Step 10: Observer Setup (Optional)](#step-10-observer-setup-optional)
16. [Step 11: Role-Aware Service Trigger (Optional)](#step-11-role-aware-service-trigger-optional)
17. [Summary](#summary-what-would-be-done-manually-without-scripts)
18. [Common Monitoring Commands](#common-monitoring-commands)

---

## Prerequisites

Before beginning Data Guard setup, ensure:
- Oracle 19c installed on both servers
- Primary database is running in ARCHIVELOG mode
- Password file exists for the primary database
- Network connectivity between primary and standby servers
- Sufficient disk space on standby for database files
- NFS share mounted at `/OINSTALL/_dataguard_setup` on both servers (see [NFS Setup](#nfs-setup))

---

## NFS Setup

The NFS share at `/OINSTALL/_dataguard_setup` is used to exchange files (config files, password files, logs, sessions) between primary and standby servers. **Set this up before running any Data Guard scripts.**

### Step 0a: Setup NFS Server

**Script:** `nfs/01_setup_nfs_server.sh` (requires sudo)

Run this on the server that will host the NFS share (can be primary, standby, or a separate server).

#### What the Script Does

1. Validates root/sudo privileges
2. Prompts for primary and standby server hostnames/IPs
3. Installs NFS server packages (auto-detects yum, dnf, or apt-get)
4. Creates NFS share directory: `/OINSTALL/_dataguard_setup` (with `logs/` subdirectory)
5. Backs up `/etc/exports` and adds export entries for both servers
6. Enables and starts NFS services (`nfs-server`, `rpcbind`)
7. Exports the filesystem (`exportfs -ra`)
8. Configures firewall (firewalld or ufw) for NFS ports 111 and 2049
9. Verifies setup

#### Manual Equivalent

```bash
# Install NFS server
sudo yum install -y nfs-utils

# Create directories
sudo mkdir -p /OINSTALL/_dataguard_setup/logs
sudo chmod 775 /OINSTALL/_dataguard_setup /OINSTALL/_dataguard_setup/logs

# Add exports (replace hostnames)
cat >> /etc/exports << 'EOF'
/OINSTALL/_dataguard_setup primary_host(rw,sync,no_subtree_check,no_root_squash)
/OINSTALL/_dataguard_setup standby_host(rw,sync,no_subtree_check,no_root_squash)
EOF

# Export and start services
sudo exportfs -ra
sudo systemctl enable --now nfs-server rpcbind

# Open firewall
sudo firewall-cmd --permanent --add-service=nfs
sudo firewall-cmd --permanent --add-service=rpc-bind
sudo firewall-cmd --permanent --add-service=mountd
sudo firewall-cmd --reload
```

### Step 0b: Mount NFS on Client

**Script:** `nfs/02_mount_nfs_client.sh` (requires sudo)

Run this on **both** primary and standby servers.

#### What the Script Does

1. Validates root/sudo privileges
2. Checks if NFS is already mounted (exits if working)
3. Prompts for NFS server hostname/IP
4. Installs NFS client packages
5. Creates mount point directory
6. Tests network connectivity to NFS server (ping)
7. Verifies NFS export is available (`showmount -e`)
8. Mounts the NFS share (NFSv4 with options: `rw,bg,hard,nointr,tcp,vers=4,timeo=600,rsize=1048576,wsize=1048576`)
9. Tests write access
10. Adds persistent mount entry to `/etc/fstab` (with backup)
11. Sets ownership to `oracle:oinstall` (or `oracle:dba`)

#### Manual Equivalent

```bash
# Install NFS client
sudo yum install -y nfs-utils

# Create mount point
sudo mkdir -p /OINSTALL/_dataguard_setup

# Test connectivity
ping -c 1 -W 5 nfs-server
showmount -e nfs-server

# Mount
sudo mount -t nfs4 nfs-server:/OINSTALL/_dataguard_setup /OINSTALL/_dataguard_setup \
  -o rw,bg,hard,nointr,tcp,vers=4,timeo=600,rsize=1048576,wsize=1048576

# Verify write access
touch /OINSTALL/_dataguard_setup/.test && rm /OINSTALL/_dataguard_setup/.test

# Persist in fstab
echo "nfs-server:/OINSTALL/_dataguard_setup /OINSTALL/_dataguard_setup nfs4 rw,bg,hard,nointr,tcp,vers=4,timeo=600,rsize=1048576,wsize=1048576 0 0" >> /etc/fstab

# Set permissions
sudo chown oracle:oinstall /OINSTALL/_dataguard_setup
sudo chmod 775 /OINSTALL/_dataguard_setup
```

---

## Restartability

| Steps | Restartable | Notes |
|-------|-------------|-------|
| 0a-0b | **Yes** | NFS scripts detect existing setup and skip if already done. |
| 1-4 | **Yes** | Fully idempotent. Can restart from step 1 at any point. |
| 5 | **No** | Once RMAN duplicate begins, cleanup required before restart. |
| 6-8 | **Yes** | Broker config can be removed and recreated. Steps 7-8 are safe to re-run. |
| 9-10 | **Yes** | FSFO can be disabled/re-enabled. Observer can be stopped/restarted. |
| 11 | **Yes** | Re-running replaces existing PL/SQL objects with updated service list. |

**To restart from Step 5 after a failure:**
1. Shut down the standby instance: `SHUTDOWN ABORT`
2. Remove standby data files: `rm -rf /path/to/standby/oradata/*`
3. Remove standby control files and redo logs
4. Re-run step 5

**To restart from Step 6 after a failure:**
1. Connect to DGMGRL: `dgmgrl /`
2. Remove existing config: `REMOVE CONFIGURATION`
3. Re-run step 6

---

## Common Flags

All setup scripts (steps 1-11) support these flags:

| Flag | Description |
|------|-------------|
| `-v`, `--verbose` | Enable bash trace output (`set -x`) for debugging |
| `-n`, `--check`, `--plan` | **Dry-run mode.** Script stops before making any changes and shows what would be done. |
| `-a`, `--approval-mode`, `-s`, `--suspicious` | **Approval mode.** Every mutating action (database changes, file writes, etc.) requires interactive confirmation before execution. |
| `-S <id>`, `--session <id>` | Restore a previously saved session (skips config file selection). See [Session Management](#session-management). |
| `--list-sessions` | Display all available sessions and exit. |

Flags can be combined:

```bash
# Dry-run with verbose output
./primary/04_prepare_primary_dg.sh -n -v

# Approval mode with a restored session
./standby/05_clone_standby.sh -a -S mydb_stb_a3f1

# All together
./primary/04_prepare_primary_dg.sh -v -a -n -S mydb_stb_a3f1
```

### Check/Plan Mode

When `-n` / `--check` / `--plan` is used, the script runs through validation and information gathering but exits before making any changes. This is useful for:

- Reviewing what a script will do before committing
- Verifying prerequisites are met
- Planning in production environments

### Approval Mode

When `-a` / `--approval-mode` is used, every mutating action displays a prompt showing:

- **Action title** (what will happen)
- **Impact scope** (database change, filesystem change, broker change, etc.)
- **Command preview** (exact command to be executed)

You must type `y` or `yes` to approve each action. Declining skips that action with a warning.

---

## Session Management

Sessions remember your config file selection so you don't have to re-select it on every script run. Sessions are stored on NFS (`${NFS_SHARE}/sessions/`) and work across both primary and standby servers.

### How It Works

1. When you run a script and select a config file, a session is automatically created
2. The session ID is derived from the config filename plus a short random suffix (e.g., `standby_config_MYDB_STB.env` -> session `mydb_stb_a3f1`)
3. On subsequent script runs, you can restore the session to skip file selection

### Usage

```bash
# Run a script - session is created automatically after file selection
./primary/04_prepare_primary_dg.sh

# Restore a session directly (skips file selection)
./primary/04_prepare_primary_dg.sh -S mydb_stb_a3f1
./standby/05_clone_standby.sh -S mydb_stb_a3f1

# List all sessions (from any script or standalone)
./primary/04_prepare_primary_dg.sh --list-sessions
./common/sessions.sh list

# Delete a specific session
./common/sessions.sh delete mydb_stb_a3f1

# Delete all sessions
./common/sessions.sh delete-all
```

### Session File Contents

Each session file in `${NFS_SHARE}/sessions/` stores:

```
SESSION_ID="mydb_stb_a3f1"
SESSION_CONFIG_FILE="/OINSTALL/_dataguard_setup/standby_config_MYDB_STB.env"
SESSION_CREATED="2025-03-29 14:23:45"
SESSION_LAST_USED="2025-03-29 15:10:22"
SESSION_HOSTNAME="primary-host"
```

---

## Step 1: Gather Primary Information

**Script:** `primary/01_gather_primary_info.sh`

### What the Script Does

1. Validates Oracle environment and database connectivity
2. Collects database identity (DB_NAME, DB_UNIQUE_NAME, DBID)
3. Collects configuration (character set, block size, compatible version)
4. Documents redo log configuration (size, groups, paths)
5. Lists data file locations and calculates total database size
6. Checks archive log configuration
7. Validates prerequisites (ARCHIVELOG, FORCE_LOGGING, password file)
8. Detects listener port
9. Copies password file to NFS share
10. Writes all collected info to `primary_info_<DB_UNIQUE_NAME>.env`

### Manual Equivalent

```sql
-- As oracle user, connect to primary database
sqlplus / as sysdba

-- Gather database identity
SELECT name AS db_name FROM v$database;
SELECT value FROM v$parameter WHERE name = 'db_unique_name';
SELECT value FROM v$parameter WHERE name = 'db_domain';
SELECT dbid FROM v$database;
SELECT instance_name FROM v$instance;

-- Check database configuration
SELECT property_value FROM database_properties WHERE property_name = 'NLS_CHARACTERSET';
SELECT value FROM v$parameter WHERE name = 'db_block_size';
SELECT value FROM v$parameter WHERE name = 'compatible';

-- Check redo log configuration
SELECT group#, thread#, bytes/1024/1024 AS size_mb, status
FROM v$log ORDER BY group#;

SELECT group#, member FROM v$logfile ORDER BY group#;

-- Check standby redo logs
SELECT group#, thread#, bytes/1024/1024 AS size_mb, status
FROM v$standby_log ORDER BY group#;

-- Get data file locations
SELECT DISTINCT SUBSTR(name, 1, INSTR(name, '/', -1)) AS directory
FROM v$datafile;

-- Calculate database size
SELECT
    (SELECT SUM(bytes)/1024/1024 FROM v$datafile) +
    (SELECT SUM(bytes)/1024/1024 FROM v$tempfile) +
    (SELECT SUM(bytes)/1024/1024 FROM v$log) AS total_size_mb
FROM dual;

-- Check archive log mode
SELECT log_mode FROM v$database;
SELECT value FROM v$parameter WHERE name = 'log_archive_dest_1';
SELECT value FROM v$parameter WHERE name = 'db_recovery_file_dest';

-- Check prerequisites
SELECT force_logging FROM v$database;
SELECT value FROM v$parameter WHERE name = 'remote_login_passwordfile';

-- Check DG broker status
SELECT value FROM v$parameter WHERE name = 'dg_broker_start';

EXIT;
```

```bash
# Get listener port
lsnrctl status | grep PORT

# Verify password file exists
ls -la $ORACLE_HOME/dbs/orapw$ORACLE_SID

# Copy password file to NFS share
cp $ORACLE_HOME/dbs/orapw$ORACLE_SID /OINSTALL/_dataguard_setup/

# Document all gathered information in a file
# (Manually create primary_info.env with all collected values)
```

---

## Step 2: Generate Standby Configuration

**Script:** `primary/02_generate_standby_config.sh`

### What the Script Does

1. Loads primary information from NFS share
2. Prompts for standby hostname and DB_UNIQUE_NAME
3. Generates path conversion parameters (DB_FILE_NAME_CONVERT, LOG_FILE_NAME_CONVERT)
4. Creates standby parameter file (init.ora)
5. Creates TNS entries for both databases
6. Creates listener configuration with static registration (including _DGMGRL services)
7. Creates DGMGRL script template
8. Writes master configuration file `standby_config_<STANDBY_DB_UNIQUE_NAME>.env`

### Manual Equivalent

```bash
# Create standby parameter file
cat > $ORACLE_HOME/dbs/initSTANDBY.ora << 'EOF'
# Standby Database Parameters
db_name='TESTDB'
db_unique_name='TESTDB_STBY'
db_domain='example.com'

# Memory (will be replaced by RMAN duplicate)
sga_target=0
pga_aggregate_target=0

# Control files
control_files='/u01/app/oracle/oradata/TESTDB_STBY/control01.ctl','/u01/app/oracle/oradata/TESTDB_STBY/control02.ctl'

# Archive destination
log_archive_dest_1='LOCATION=/u01/app/oracle/archive/TESTDB_STBY VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=TESTDB_STBY'

# File name conversions
db_file_name_convert='/u01/app/oracle/oradata/TESTDB','/u01/app/oracle/oradata/TESTDB_STBY'
log_file_name_convert='/u01/app/oracle/oradata/TESTDB','/u01/app/oracle/oradata/TESTDB_STBY'

# Standby specific
standby_file_management='AUTO'
dg_broker_start=TRUE

# Audit
audit_file_dest='/u01/app/oracle/admin/TESTDB_STBY/adump'
EOF
```

```bash
# Create TNS entries (add to tnsnames.ora on BOTH servers)
cat >> $ORACLE_HOME/network/admin/tnsnames.ora << 'EOF'

TESTDB =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = primary_host)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = TESTDB)
    )
  )

TESTDB_STBY =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = standby_host)(PORT = 1521))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = TESTDB_STBY)
    )
  )
EOF
```

```bash
# Create listener configuration for standby with static registration
# Add to listener.ora on standby server
cat >> $ORACLE_HOME/network/admin/listener.ora << 'EOF'

SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = TESTDB_STBY)
      (ORACLE_HOME = /u01/app/oracle/product/19.0.0/dbhome_1)
      (SID_NAME = TESTDB)
    )
    (SID_DESC =
      (GLOBAL_DBNAME = TESTDB_STBY_DGMGRL)
      (ORACLE_HOME = /u01/app/oracle/product/19.0.0/dbhome_1)
      (SID_NAME = TESTDB)
    )
  )
EOF
```

```bash
# Create DGMGRL script
cat > /OINSTALL/_dataguard_setup/configure_broker.dgmgrl << 'EOF'
CREATE CONFIGURATION 'TESTDB_DG' AS PRIMARY DATABASE IS 'TESTDB' CONNECT IDENTIFIER IS 'TESTDB';
ADD DATABASE 'TESTDB_STBY' AS CONNECT IDENTIFIER IS 'TESTDB_STBY' MAINTAINED AS PHYSICAL;
ENABLE CONFIGURATION;
EOF
```

---

## Step 3: Setup Standby Environment

**Script:** `standby/03_setup_standby_env.sh`

### What the Script Does

1. Validates disk space is sufficient
2. Creates directory structure (admin dirs, data, redo, archive)
3. Copies password file from NFS share
4. Copies parameter file
5. Configures listener.ora with static registration
6. Configures tnsnames.ora with both database entries
7. Updates /etc/oratab
8. Starts or reloads listener

### Manual Equivalent

```bash
# As oracle user on STANDBY server

# Create directory structure
mkdir -p /u01/app/oracle/admin/TESTDB_STBY/adump
mkdir -p /u01/app/oracle/admin/TESTDB_STBY/bdump
mkdir -p /u01/app/oracle/admin/TESTDB_STBY/cdump
mkdir -p /u01/app/oracle/admin/TESTDB_STBY/udump
mkdir -p /u01/app/oracle/admin/TESTDB_STBY/pfile
mkdir -p /u01/app/oracle/oradata/TESTDB_STBY
mkdir -p /u01/app/oracle/archive/TESTDB_STBY

# Copy password file
cp /OINSTALL/_dataguard_setup/orapwTESTDB $ORACLE_HOME/dbs/orapwTESTDB
chmod 640 $ORACLE_HOME/dbs/orapwTESTDB

# Copy parameter file
cp /OINSTALL/_dataguard_setup/initTESTDB_TESTDB_STBY.ora $ORACLE_HOME/dbs/initTESTDB.ora
chmod 640 $ORACLE_HOME/dbs/initTESTDB.ora

# Backup and update listener.ora
cp $ORACLE_HOME/network/admin/listener.ora $ORACLE_HOME/network/admin/listener.ora.backup

# Edit listener.ora to add SID_LIST_LISTENER (see Step 2)

# Backup and update tnsnames.ora
cp $ORACLE_HOME/network/admin/tnsnames.ora $ORACLE_HOME/network/admin/tnsnames.ora.backup

# Edit tnsnames.ora to add TNS entries (see Step 2)

# Update /etc/oratab (as root)
echo "TESTDB:/u01/app/oracle/product/19.0.0/dbhome_1:N" >> /etc/oratab

# Reload listener
lsnrctl reload
lsnrctl status
```

---

## Step 4: Prepare Primary for Data Guard

**Script:** `primary/04_prepare_primary_dg.sh`

### What the Script Does

1. Configures TNS names on primary (adds entries for both databases)
2. Configures listener on primary with static registration
3. Enables FORCE_LOGGING if not already enabled
4. Creates standby redo logs (required for switchover)
5. Enables Data Guard Broker (DG_BROKER_START=TRUE)
6. Sets STANDBY_FILE_MANAGEMENT=AUTO
7. Configures RMAN archivelog deletion policy
8. Tests network connectivity to standby

### Manual Equivalent

```bash
# As oracle user on PRIMARY server

# Update tnsnames.ora (see Step 2)
# Update listener.ora with _DGMGRL services (see Step 2)
```

```sql
-- Connect to primary database
sqlplus / as sysdba

-- Enable force logging
ALTER DATABASE FORCE LOGGING;

-- Create standby redo logs (one more group than online redo logs)
-- First, check existing redo log size and count
SELECT bytes/1024/1024 AS size_mb FROM v$log WHERE rownum = 1;
SELECT COUNT(*) FROM v$log;

-- Add standby redo logs (adjust size and paths as needed)
ALTER DATABASE ADD STANDBY LOGFILE GROUP 4 ('/u01/app/oracle/oradata/TESTDB/standby_redo04.log') SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE GROUP 5 ('/u01/app/oracle/oradata/TESTDB/standby_redo05.log') SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE GROUP 6 ('/u01/app/oracle/oradata/TESTDB/standby_redo06.log') SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE GROUP 7 ('/u01/app/oracle/oradata/TESTDB/standby_redo07.log') SIZE 200M;

-- Verify standby redo logs
SELECT group#, thread#, bytes/1024/1024 AS size_mb, status FROM v$standby_log;

-- Enable Data Guard Broker
ALTER SYSTEM SET DG_BROKER_START=TRUE SCOPE=BOTH;

-- Set standby file management
ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT=AUTO SCOPE=BOTH;

EXIT;
```

```bash
# Configure RMAN archivelog deletion policy
rman target /
CONFIGURE ARCHIVELOG DELETION POLICY TO SHIPPED TO ALL STANDBY;
EXIT;

# Test connectivity to standby
tnsping TESTDB_STBY
```

---

## Step 5: Clone Standby Database

**Script:** `standby/05_clone_standby.sh`

### What the Script Does

1. Verifies listener is running with static registration
2. Tests TNS connectivity to both primary and standby
3. Prompts for SYS password (verified against primary)
4. Shuts down any existing instance
5. Starts standby instance in NOMOUNT mode
6. Executes RMAN DUPLICATE FROM ACTIVE DATABASE
7. Creates SPFILE from PFILE if needed
8. Starts Managed Recovery Process (MRP)
9. Configures RMAN archivelog deletion policy on standby
10. Verifies MRP is running and applying redo

### Manual Equivalent

```bash
# As oracle user on STANDBY server

# Verify listener is running
lsnrctl status

# Test TNS connectivity
tnsping TESTDB
tnsping TESTDB_STBY
```

```sql
-- Start standby instance in NOMOUNT
sqlplus / as sysdba
STARTUP NOMOUNT PFILE='/u01/app/oracle/product/19.0.0/dbhome_1/dbs/initTESTDB.ora';
EXIT;
```

```bash
# Execute RMAN duplicate (replace password with actual SYS password)
rman TARGET sys/password@TESTDB AUXILIARY sys/password@TESTDB_STBY << 'EOF'
DUPLICATE TARGET DATABASE
  FOR STANDBY
  FROM ACTIVE DATABASE
  DORECOVER
  SPFILE
    SET DB_UNIQUE_NAME='TESTDB_STBY'
    SET CONTROL_FILES='/u01/app/oracle/oradata/TESTDB_STBY/control01.ctl','/u01/app/oracle/oradata/TESTDB_STBY/control02.ctl'
    SET LOG_ARCHIVE_DEST_1='LOCATION=/u01/app/oracle/archive/TESTDB_STBY VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=TESTDB_STBY'
    SET DB_FILE_NAME_CONVERT='/u01/app/oracle/oradata/TESTDB','/u01/app/oracle/oradata/TESTDB_STBY'
    SET LOG_FILE_NAME_CONVERT='/u01/app/oracle/oradata/TESTDB','/u01/app/oracle/oradata/TESTDB_STBY'
    SET STANDBY_FILE_MANAGEMENT='AUTO'
    SET DG_BROKER_START='TRUE'
    SET AUDIT_FILE_DEST='/u01/app/oracle/admin/TESTDB_STBY/adump'
  NOFILENAMECHECK;
EOF
```

```sql
-- After RMAN duplicate completes, connect and verify
sqlplus / as sysdba

-- Create SPFILE if needed
CREATE SPFILE FROM PFILE='/u01/app/oracle/product/19.0.0/dbhome_1/dbs/initTESTDB.ora';

-- Mount database if not mounted
ALTER DATABASE MOUNT STANDBY DATABASE;

-- Start managed recovery
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;

-- Verify MRP is running
SELECT process, status, sequence# FROM v$managed_standby WHERE process LIKE 'MRP%';

-- Check database status
SELECT database_role, open_mode, protection_mode FROM v$database;

EXIT;
```

```bash
# Configure RMAN deletion policy on standby
rman target /
CONFIGURE ARCHIVELOG DELETION POLICY TO SHIPPED TO ALL STANDBY;
EXIT;
```

---

## Step 6: Configure Data Guard Broker

**Script:** `primary/06_configure_broker.sh`

### What the Script Does

1. Verifies DG Broker is running (DMON process)
2. Tests TNS connectivity to both databases
3. Checks for existing broker configuration
4. Creates new broker configuration
5. Adds standby database to configuration
6. Enables the configuration
7. Verifies configuration status
8. Tests log shipping with forced log switch

### Manual Equivalent

```bash
# As oracle user on PRIMARY server

# Verify DMON process is running
ps -ef | grep dmon

# Connect to DGMGRL
dgmgrl /
```

```
-- In DGMGRL (Data Guard Manager CLI)

-- Check for existing configuration
SHOW CONFIGURATION;

-- If no configuration exists (ORA-16532), create one
CREATE CONFIGURATION 'TESTDB_DG' AS PRIMARY DATABASE IS 'TESTDB' CONNECT IDENTIFIER IS 'TESTDB';

-- Add standby database
ADD DATABASE 'TESTDB_STBY' AS CONNECT IDENTIFIER IS 'TESTDB_STBY' MAINTAINED AS PHYSICAL;

-- Enable the configuration
ENABLE CONFIGURATION;

-- Wait for configuration to stabilize (10-30 seconds)

-- Verify configuration
SHOW CONFIGURATION;

-- Check primary database status
SHOW DATABASE 'TESTDB';

-- Check standby database status
SHOW DATABASE 'TESTDB_STBY';

EXIT;
```

```sql
-- Test log shipping by forcing a log switch
sqlplus / as sysdba
ALTER SYSTEM SWITCH LOGFILE;
EXIT;
```

```
-- Verify log shipping in DGMGRL
dgmgrl /
SHOW DATABASE 'TESTDB_STBY' 'LogXptStatus';
EXIT;
```

---

## Step 7: Verify Data Guard

**Script:** `standby/07_verify_dataguard.sh`

### What the Script Does

1. Checks database role and status (should be PHYSICAL STANDBY)
2. Verifies Managed Recovery Process is running
3. Checks for archive log gaps
4. Compares applied vs received archive logs
5. Displays Data Guard Broker configuration
6. Checks critical DG parameters
7. Verifies archive destination status
8. Tests network connectivity
9. Generates comprehensive health report

### Manual Equivalent

```sql
-- As oracle user on STANDBY server
sqlplus / as sysdba

-- Check database role and status
SELECT database_role, open_mode, protection_mode, switchover_status
FROM v$database;

-- Check MRP is running
SELECT process, status, thread#, sequence#, block#
FROM v$managed_standby
WHERE process LIKE 'MRP%';

-- Check for archive gaps
SELECT thread#, low_sequence#, high_sequence#
FROM v$archive_gap;

-- Check last applied vs received
SELECT MAX(sequence#) AS last_applied FROM v$archived_log WHERE applied = 'YES' AND dest_id = 1;
SELECT MAX(sequence#) AS last_received FROM v$archived_log WHERE dest_id = 1;

-- Check Data Guard parameters
SELECT name, value FROM v$parameter
WHERE name IN ('db_name', 'db_unique_name', 'dg_broker_start',
               'log_archive_dest_1', 'log_archive_dest_2',
               'standby_file_management');

-- Check archive destination status
SELECT dest_id, status, error FROM v$archive_dest WHERE dest_id IN (1, 2);

-- Check standby redo logs
SELECT group#, thread#, bytes/1024/1024 AS size_mb, status, archived
FROM v$standby_log ORDER BY group#;

EXIT;
```

```
-- Check broker configuration
dgmgrl /

SHOW CONFIGURATION;
SHOW DATABASE 'TESTDB';
SHOW DATABASE 'TESTDB_STBY';

-- Validate database
VALIDATE DATABASE 'TESTDB_STBY';

EXIT;
```

```sql
-- Additional monitoring queries
sqlplus / as sysdba

-- Real-time apply lag
SELECT name, value, unit FROM v$dataguard_stats
WHERE name IN ('transport lag', 'apply lag', 'apply finish time');

-- All managed standby processes
SELECT process, pid, status, client_process, sequence#, block#
FROM v$managed_standby;

EXIT;
```

---

## Step 8: Security Hardening (Optional)

**Script:** `primary/08_security_hardening.sh`

### What the Script Does

1. Verifies this is the primary database
2. Checks that Data Guard Broker configuration is healthy
3. Prompts for confirmation before proceeding
4. Generates a random 32-character password for SYS
5. Changes SYS password to the random value (not stored anywhere)
6. Locks the SYS account
7. Verifies OS authentication still works
8. Clears the password from memory

### Why Lock the SYS Account?

After Data Guard is configured:
- The password file is used for redo transport authentication
- DBAs should use OS authentication (`/ as sysdba`) for local connections
- Locking SYS prevents password-based attacks while maintaining functionality

### Manual Equivalent

```sql
-- As oracle user on PRIMARY server
sqlplus / as sysdba

-- Generate a random password (use your preferred method)
-- Then change SYS password and lock the account
ALTER USER SYS IDENTIFIED BY '<random_32_char_password>';
ALTER USER SYS ACCOUNT LOCK;

-- Verify the change
SELECT username, account_status FROM dba_users WHERE username = 'SYS';

EXIT;
```

### Important Notes

- **After running this script:**
  - Use `sqlplus / as sysdba` for all DBA connections
  - Password-based SYS connections will not work
  - Data Guard redo transport continues to work (uses password file)

- **To unlock SYS if needed:**
  ```sql
  sqlplus / as sysdba
  ALTER USER SYS ACCOUNT UNLOCK;
  ALTER USER SYS IDENTIFIED BY '<new_password>';
  ```

- **Consider also locking:**
  ```sql
  ALTER USER SYSTEM ACCOUNT LOCK;
  ```

---

## Step 9: Configure Fast-Start Failover (Optional)

**Script:** `primary/09_configure_fsfo.sh`

### What the Script Does

1. Verifies Data Guard Broker configuration is healthy
2. Prompts for observer username (default: dg_observer)
3. Creates observer user with SYSDG privilege
4. Sets LogXptMode to FASTSYNC for both databases
5. Sets protection mode to MAXIMUM AVAILABILITY
6. Configures FSFO properties (threshold, target)
7. Enables Fast-Start Failover
8. Copies password file to NFS for observer server
9. Outputs wallet setup instructions

### Manual Equivalent

```sql
-- As oracle user on PRIMARY server
sqlplus / as sysdba

-- Create observer user (any name) with SYSDG privilege
CREATE USER dg_observer IDENTIFIED BY <password>;
GRANT SYSDG TO dg_observer;
GRANT CREATE SESSION TO dg_observer;

EXIT;
```

```
-- Configure FSFO in DGMGRL
dgmgrl /

-- Set LogXptMode for both databases (must be done before changing protection mode)
EDIT DATABASE 'PRIMARY_DB' SET PROPERTY LogXptMode='FASTSYNC';
EDIT DATABASE 'STANDBY_DB' SET PROPERTY LogXptMode='FASTSYNC';

-- Set protection mode
EDIT CONFIGURATION SET PROTECTION MODE AS MAXAVAILABILITY;

-- Configure FSFO properties
EDIT CONFIGURATION SET PROPERTY FastStartFailoverThreshold=30;
EDIT CONFIGURATION SET PROPERTY FastStartFailoverTarget='STANDBY_DB';

-- Enable FSFO
ENABLE FAST_START FAILOVER;

SHOW FAST_START FAILOVER;
EXIT;
```

---

## Step 10: Observer Setup (Optional)

**Script:** `fsfo/observer.sh`

### What the Script Does

The observer can run on the **standby server** or a **dedicated 3rd server**.

**Setup command (`./observer.sh setup`):**
1. Creates Oracle Wallet directory
2. Creates auto-login wallet
3. Adds observer user credentials for primary and standby TNS aliases
4. Configures sqlnet.ora with wallet location
5. Tests wallet connectivity

**Start command (`./observer.sh start`):**
1. Verifies wallet exists
2. Verifies FSFO is enabled
3. Starts observer in background using wallet authentication
4. Saves PID for lifecycle management

### Manual Equivalent

```bash
# As oracle user on OBSERVER server

# Create wallet directory
mkdir -p $ORACLE_HOME/network/admin/wallet
chmod 700 $ORACLE_HOME/network/admin/wallet

# Create wallet
mkstore -wrl $ORACLE_HOME/network/admin/wallet -create
# Enter wallet password when prompted

# Enable auto-login
mkstore -wrl $ORACLE_HOME/network/admin/wallet -createSSO
# Enter wallet password when prompted

# Add credentials (use the observer username from Step 9)
mkstore -wrl $ORACLE_HOME/network/admin/wallet -createCredential PRIMARY_TNS dg_observer <password>
mkstore -wrl $ORACLE_HOME/network/admin/wallet -createCredential STANDBY_TNS dg_observer <password>
```

```bash
# Add to sqlnet.ora
cat >> $ORACLE_HOME/network/admin/sqlnet.ora << 'EOF'
WALLET_LOCATION = (SOURCE = (METHOD = FILE) (METHOD_DATA = (DIRECTORY = /path/to/wallet)))
SQLNET.WALLET_OVERRIDE = TRUE
EOF
```

```bash
# Start observer using wallet
nohup dgmgrl /@PRIMARY_TNS "START OBSERVER" > observer.log 2>&1 &
```

### Observer Commands

```bash
# Set up wallet (one-time)
./fsfo/observer.sh setup

# Start observer in background
./fsfo/observer.sh start

# Check observer status
./fsfo/observer.sh status

# Stop observer (before maintenance)
./fsfo/observer.sh stop

# Restart observer
./fsfo/observer.sh restart
```

### Manual DGMGRL Commands

```
-- Show FSFO status
dgmgrl / "SHOW FAST_START FAILOVER"

-- Disable FSFO
dgmgrl / "DISABLE FAST_START FAILOVER"

-- Re-enable FSFO
dgmgrl / "ENABLE FAST_START FAILOVER"

-- Stop observer from DGMGRL
dgmgrl / "STOP OBSERVER"
```

### Important Notes

1. **Observer location**: The observer can run on the standby server or a dedicated 3rd server. A 3rd server is recommended for production as it remains available regardless of which database fails.

2. **Authentication**: Uses Oracle Wallet with SYSDG user for secure authentication. No passwords are stored in scripts.

3. **Protection mode impact**: MAXIMUM AVAILABILITY provides zero data loss but may slightly impact primary performance.

4. **Network requirements**: Observer must have network connectivity to both primary and standby databases.

5. **Maintenance considerations**: Stop the observer before performing database maintenance to prevent unexpected failovers.

6. **Threshold tuning**: The default 30-second threshold can be adjusted:
   ```bash
   FSFO_THRESHOLD=60 ./primary/09_configure_fsfo.sh
   ```

---

## Step 11: Role-Aware Service Trigger (Optional)

**Script:** `trigger/create_role_trigger.sh`

Deploy this after Data Guard setup is complete (after Step 7). It creates PL/SQL objects that automatically start and stop user-defined database services based on the database role (PRIMARY vs STANDBY).

### What the Script Does

1. Validates Oracle environment and database connectivity
2. Loads standby configuration from NFS
3. Verifies the script is running on the PRIMARY database
4. Discovers running user-defined services from the database
5. Presents an interactive service list editor where you can:
   - Accept the discovered services
   - Add new service names manually
   - Remove services from the list
   - Clear and manually enter all services
6. Checks for existing `SYS.DG_SERVICE_MGR` package and prompts before replacing
7. Creates PL/SQL objects:
   - **Package:** `SYS.DG_SERVICE_MGR` with `MANAGE_SERVICES` procedure
   - **Trigger:** `SYS.TRG_MANAGE_SERVICES_ROLE_CHG` (fires `AFTER DB_ROLE_CHANGE`)
   - **Trigger:** `SYS.TRG_MANAGE_SERVICES_STARTUP` (fires `AFTER STARTUP`)
8. Verifies package is VALID and triggers are ENABLED
9. Saves generated SQL to NFS for reference

### How It Works at Runtime

- **On switchover/failover:** The `DB_ROLE_CHANGE` trigger fires and calls `MANAGE_SERVICES`
- **On database startup:** The `STARTUP` trigger fires and calls `MANAGE_SERVICES`
- **PRIMARY role:** All configured services are **started**
- **STANDBY role:** All configured services are **stopped**

Objects replicate to the standby automatically via redo apply, so triggers fire on both databases.

### Manual Equivalent

```sql
-- Connect as SYSDBA on PRIMARY
sqlplus / as sysdba

-- Discover user services currently running
SELECT name FROM v$active_services
WHERE name NOT IN ('SYS$BACKGROUND', 'SYS$USERS')
AND name NOT LIKE '%XDB%';

-- Create the package specification
CREATE OR REPLACE PACKAGE SYS.DG_SERVICE_MGR AS
    PROCEDURE MANAGE_SERVICES;
END DG_SERVICE_MGR;
/

-- Create the package body (adjust service names)
CREATE OR REPLACE PACKAGE BODY SYS.DG_SERVICE_MGR AS

    TYPE service_list_t IS TABLE OF VARCHAR2(64);

    FUNCTION get_service_list RETURN service_list_t IS
        l_services service_list_t := service_list_t();
    BEGIN
        -- BEGIN SERVICE LIST
        l_services.EXTEND; l_services(l_services.COUNT) := 'MY_APP_SERVICE';
        l_services.EXTEND; l_services(l_services.COUNT) := 'MY_REPORTING_SVC';
        -- END SERVICE LIST
        RETURN l_services;
    END get_service_list;

    PROCEDURE MANAGE_SERVICES IS
        l_role     VARCHAR2(30);
        l_services service_list_t;
    BEGIN
        SELECT DATABASE_ROLE INTO l_role FROM V$DATABASE;
        l_services := get_service_list();

        IF l_role = 'PRIMARY' THEN
            FOR i IN 1..l_services.COUNT LOOP
                BEGIN
                    DBMS_SERVICE.START_SERVICE(l_services(i));
                EXCEPTION WHEN OTHERS THEN NULL;
                END;
            END LOOP;
        ELSE
            FOR i IN 1..l_services.COUNT LOOP
                BEGIN
                    DBMS_SERVICE.STOP_SERVICE(l_services(i));
                EXCEPTION WHEN OTHERS THEN NULL;
                END;
            END LOOP;
        END IF;
    END MANAGE_SERVICES;

END DG_SERVICE_MGR;
/

-- Create role-change trigger
CREATE OR REPLACE TRIGGER SYS.TRG_MANAGE_SERVICES_ROLE_CHG
    AFTER DB_ROLE_CHANGE ON DATABASE
BEGIN
    SYS.DG_SERVICE_MGR.MANAGE_SERVICES;
END;
/

-- Create startup trigger
CREATE OR REPLACE TRIGGER SYS.TRG_MANAGE_SERVICES_STARTUP
    AFTER STARTUP ON DATABASE
BEGIN
    SYS.DG_SERVICE_MGR.MANAGE_SERVICES;
END;
/

-- Verify
SELECT object_name, object_type, status
FROM dba_objects
WHERE object_name = 'DG_SERVICE_MGR' AND owner = 'SYS';

SELECT trigger_name, status
FROM dba_triggers
WHERE trigger_name LIKE 'TRG_MANAGE_SERVICES%' AND owner = 'SYS';

-- Test manually
EXEC SYS.DG_SERVICE_MGR.MANAGE_SERVICES;
SELECT name FROM v$active_services;

EXIT;
```

### Updating the Service List

To change which services are managed, re-run the script:

```bash
./trigger/create_role_trigger.sh
```

The script will discover current services and let you edit the list interactively. Re-running replaces the existing PL/SQL objects.

---

## Summary: What Would Be Done Manually Without Scripts

| Step | Script | Manual Effort |
|------|--------|--------------|
| 0a | NFS Server Setup | Install NFS, create exports, configure firewall |
| 0b | NFS Client Mount | Install NFS client, mount share, add to fstab |
| 1 | Gather Primary Info | Run ~20 SQL queries, document values, check prerequisites, copy password file |
| 2 | Generate Config | Create parameter file, TNS entries, listener config, broker script manually |
| 3 | Setup Standby Env | Create directories, copy files, configure listener, tnsnames, oratab |
| 4 | Prepare Primary | Configure TNS, listener, enable force logging, create standby redo logs, enable broker |
| 5 | Clone Standby | Start NOMOUNT, run RMAN duplicate, create SPFILE, start MRP |
| 6 | Configure Broker | Run DGMGRL commands to create config, add database, enable |
| 7 | Verify | Run multiple SQL queries and DGMGRL commands to check health |
| 8 | Security Hardening | Change SYS password to random value, lock account (optional) |
| 9 | Configure FSFO | Create observer user, set FASTSYNC, enable FSFO (optional) |
| 10 | Observer Setup | Create wallet, add credentials, start observer process (optional) |
| 11 | Service Trigger | Write PL/SQL package and triggers, deploy to database (optional) |

**Total Manual Steps:** ~100+ individual commands, queries, and file edits

**Automation Benefits:**
- Consistent configuration across setups
- Built-in validation and prerequisite checking
- Error handling and rollback
- Single source of truth for configuration
- Support for concurrent Data Guard setups
- AIX compatibility (printf instead of echo -e, sed instead of grep -P)
- Comprehensive logging (all output saved to NFS)
- Password security (prompted at runtime, never stored)
- Session management (remember config selections across script runs)
- Dry-run mode (review changes before applying)
- Approval mode (gate every mutating action for high-security environments)

---

## Common Monitoring Commands

After setup, use these commands for ongoing monitoring:

```sql
-- Check apply lag
SELECT name, value, unit FROM v$dataguard_stats;

-- Check managed standby processes
SELECT process, status, sequence# FROM v$managed_standby;

-- Check archive gaps
SELECT * FROM v$archive_gap;
```

```
-- DGMGRL commands
dgmgrl /
SHOW CONFIGURATION;
SHOW DATABASE 'primary_db';
SHOW DATABASE 'standby_db';
VALIDATE DATABASE 'standby_db';
```

```sql
-- Force log switch to test log shipping
ALTER SYSTEM SWITCH LOGFILE;

-- Open standby read-only (requires stopping MRP)
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
ALTER DATABASE OPEN READ ONLY;

-- Restart MRP after read-only access
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
```

```
-- FSFO monitoring
dgmgrl / "SHOW FAST_START FAILOVER"

-- Check active services
SELECT name FROM v$active_services;

-- Manually trigger service management
EXEC SYS.DG_SERVICE_MGR.MANAGE_SERVICES;
```
