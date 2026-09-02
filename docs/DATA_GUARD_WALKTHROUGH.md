# Oracle 19c Data Guard Setup: Script Walkthrough & Manual Equivalent

This document describes what each automation script does and shows the equivalent manual steps a DBA would perform without the scripts.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [NFS Setup](#nfs-setup)
3. [Restartability](#restartability)
4. [Common Flags](#common-flags)
5. [Step 1: Gather Primary Information](#step-1-gather-primary-information)
6. [Step 2: Generate Standby Configuration](#step-2-generate-standby-configuration)
7. [Step 3: Setup Standby Environment](#step-3-setup-standby-environment)
8. [Step 4: Prepare Primary for Data Guard](#step-4-prepare-primary-for-data-guard)
9. [Step 5: Clone Standby Database](#step-5-clone-standby-database)
10. [Step 6: Configure Data Guard Broker](#step-6-configure-data-guard-broker)
11. [Step 7: Verify Data Guard](#step-7-verify-data-guard)
12. [Step 9: Configure Fast-Start Failover (Optional)](#step-9-configure-fast-start-failover-optional)
13. [Step 10: Observer Setup (Optional)](#step-10-observer-setup-optional)
14. [Step 11: Role-Aware Service Trigger (Optional)](#step-11-role-aware-service-trigger-optional)
15. [Step 12: NFS Artifact Cleanup (Optional)](#step-12-nfs-artifact-cleanup-optional)
16. [Step 13: Set Maximum Availability Protection (Optional)](#step-13-set-maximum-availability-protection-optional)
17. [Handoff Report (Recommended, Any Time After Step 7)](#handoff-report-recommended-any-time-after-step-7)
18. [Peer Wallet Setup (Recommended, Any Time After Step 7)](#peer-wallet-setup-recommended-any-time-after-step-7)
19. [Post-Setup Tooling](#post-setup-tooling)
20. [Side Toolkits (Outside the Numbered Workflow)](#side-toolkits-outside-the-numbered-workflow)
21. [Summary](#summary-what-would-be-done-manually-without-scripts)
22. [Life After Setup: Adding Datafiles and PDBs](#life-after-setup-adding-datafiles-and-pdbs)
23. [Common Monitoring Commands](#common-monitoring-commands)

> Step numbering follows the script filenames. There is no step 8 — the former
> security-hardening step was removed from the project — so the sequence jumps
> from 7 to 9.

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

The NFS share at `/OINSTALL/_dataguard_setup` is used to exchange files (config files, password files, logs) between primary and standby servers. **Set this up before running any Data Guard scripts.**

### Step 0a: Setup NFS Server

**Script:** `nfs/01_setup_nfs_server.sh` (requires sudo)

Run this on the server that will host the NFS share (can be primary, standby, or a separate server).

#### What the Script Does

1. Validates root/sudo privileges
2. Prompts for primary and standby server hostnames/IPs
3. Prompts for the OS user:group that should own the share (default `oracle:oinstall`) - its UID/GID must match on both DB hosts, since NFS maps ownership by number, not by name
4. Installs NFS server packages (auto-detects yum, dnf, or apt-get)
5. Creates NFS share directory: `/OINSTALL/_dataguard_setup` (with `logs/` subdirectory), `chown`s it to the specified owner, and `chmod`s it `750`
6. Backs up `/etc/exports` and adds export entries for both servers (`rw,sync,no_subtree_check` - no `no_root_squash`, since everything in this workflow runs as the oracle OS user)
7. Enables and starts NFS services (`nfs-server`, `rpcbind`)
8. Exports the filesystem (`exportfs -ra`)
9. Configures firewall (firewalld or ufw) for NFS ports 111 and 2049
10. Verifies setup

#### Manual Equivalent

```bash
# Install NFS server
sudo yum install -y nfs-utils

# Create directories
sudo mkdir -p /OINSTALL/_dataguard_setup/logs
sudo chown oracle:oinstall /OINSTALL/_dataguard_setup /OINSTALL/_dataguard_setup/logs
sudo chmod 750 /OINSTALL/_dataguard_setup /OINSTALL/_dataguard_setup/logs

# Add exports (replace hostnames). no_root_squash is intentionally omitted:
# everything in this workflow runs as the oracle OS user, never root.
cat >> /etc/exports << 'EOF'
/OINSTALL/_dataguard_setup primary_host(rw,sync,no_subtree_check)
/OINSTALL/_dataguard_setup standby_host(rw,sync,no_subtree_check)
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
8. Mounts the NFS share (NFSv4 with options: `rw,bg,hard,tcp,vers=4,timeo=600,rsize=1048576,wsize=1048576`)
9. Tests write access
10. Adds persistent mount entry to `/etc/fstab` (with backup)
11. Sets ownership to `oracle:oinstall` (or `oracle:dba`) and `chmod`s the mount point `750`

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
  -o rw,bg,hard,tcp,vers=4,timeo=600,rsize=1048576,wsize=1048576

# Verify write access
touch /OINSTALL/_dataguard_setup/.test && rm /OINSTALL/_dataguard_setup/.test

# Persist in fstab
echo "nfs-server:/OINSTALL/_dataguard_setup /OINSTALL/_dataguard_setup nfs4 rw,bg,hard,tcp,vers=4,timeo=600,rsize=1048576,wsize=1048576 0 0" >> /etc/fstab

# Set permissions (750, not 775 - the mount point IS the exported share
# directory, so a wider mode here would undo the 750 set by
# nfs/01_setup_nfs_server.sh for every client that mounts it)
sudo chown oracle:oinstall /OINSTALL/_dataguard_setup
sudo chmod 750 /OINSTALL/_dataguard_setup
```

---

## Restartability

| Steps | Restartable | Notes |
|-------|-------------|-------|
| 0a-0b | **Yes** | NFS scripts detect existing setup and skip if already done. |
| 1-4 | **Yes** | Fully idempotent. Can restart from step 1 at any point. |
| 5 | **No** | Once RMAN duplicate begins, cleanup required before restart. |
| 6-7 | **Yes** | Broker config can be removed and recreated. Step 7 is safe to re-run. |
| 9-10 | **Yes** | FSFO can be disabled/re-enabled. Observer can be stopped/restarted. |
| 11 | **Yes** | Re-running replaces existing PL/SQL objects with updated service list. |

**To restart from Step 5 after a failure:**
1. Shut down the standby instance: `SHUTDOWN ABORT`
2. Remove standby data files: `rm -rf /path/to/standby/oradata/*`
3. Remove standby control files and redo logs
4. Re-run step 5

**Re-cloning with a locked SYS account:** if SYS on the primary has been locked (e.g. by a site hardening policy), `standby/05_clone_standby.sh` detects this during its password check (`ORA-28000`) and prints the fix: temporarily `ALTER USER SYS ACCOUNT UNLOCK` + `IDENTIFIED BY <temp password>` on the primary, re-run step 5, then re-apply the lockdown and make sure the standby's password file matches the primary's.

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

Flags can be combined:

```bash
# Dry-run with verbose output
./primary/04_prepare_primary_dg.sh -n -v

# Approval mode with verbose
./primary/04_prepare_primary_dg.sh -v -a -n
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

## Step 1: Gather Primary Information

**Script:** `primary/01_gather_primary_info.sh`

### What the Script Does

1. Validates Oracle environment and database connectivity
2. Collects database identity (DB_NAME, DB_UNIQUE_NAME, DBID)
3. Collects configuration (character set, block size, compatible version)
4. Documents redo log configuration (size, groups, paths)
5. Lists data file locations and calculates total database size
6. Checks archive log configuration
7. Reports archive log inventory and redo generation statistics (see [Redo Generation Statistics](#redo-generation-statistics) below)
8. Validates prerequisites (ARCHIVELOG, FORCE_LOGGING, password file)
9. Detects listener port
10. Copies password file to NFS share
11. Writes all collected info to `primary_info_<DB_UNIQUE_NAME>.env`

### Redo Generation Statistics

Redo volume is the number the rest of the build depends on: it sets the bandwidth the redo transport needs between the two hosts, how much archive space the standby has to hold, and whether the online redo logs — which the standby redo logs are sized from — are big enough. The step reports:

- **Archive Log Overview** — log mode, resolved archive destination, whether archives go to the FRA, how many archived logs are on disk right now and how much space they take, the sequence range, and the oldest/newest archive timestamps.
- **Daily redo generation** (last 14 days) — logs, MB/GB, average size per log, plus the busiest single hour within each day. The daily average hides bursts; the peak hour is what the link actually has to survive.
- **Redo by hour of day** (last 7 days) — average and peak MB per clock hour, so batch windows are visible.
- **Redo Generation Statistics** — observed window, total redo, average and peak per day and per hour, log switch rates, the **minimum redo transport bandwidth** (peak hour + 30% headroom), and archive space needed per day of retention.

Two sanity checks run off these numbers:

- **Log switch rate.** More than 12 switches in the peak hour is warned about (Oracle's guidance is a switch every 15–20 minutes). Fix this *before* the standby is built — standby redo logs must match the online log size, so resizing afterwards means recreating them on both sides.
- **FRA size.** If `db_recovery_file_dest_size` is smaller than one day of redo, the step warns; the standby needs the same headroom.

All of this is informational and never fails the step. Two caveats worth knowing:

- The history comes from `V$ARCHIVED_LOG`, which only retains what `CONTROL_FILE_RECORD_KEEP_TIME` allows (7 days by default) — the actual observed window is printed next to the numbers rather than assumed.
- On a database with no archive history at all (freshly created or freshly restarted), the step falls back to redo generated since instance startup (`V$SYSSTAT`), marks the values `INSTANCE_STARTUP`, and reports the peak as an estimate equal to the average. Re-run the step after a representative workload period if you want the numbers to mean anything for sizing.

The values are persisted into `primary_info_<DB_UNIQUE_NAME>.env` under `# --- Archive Log Inventory ---` and `# --- Redo Generation Statistics ---`.

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

-- Archived logs currently on disk
SELECT COUNT(*)                                AS logs_on_disk,
       ROUND(SUM(blocks*block_size)/1024/1024) AS mb_on_disk,
       MIN(sequence#)                          AS oldest_seq,
       MAX(sequence#)                          AS newest_seq
FROM   v$archived_log
WHERE  standby_dest = 'NO' AND deleted = 'NO' AND status = 'A';

-- Daily redo generation, with the busiest hour of each day.
-- The inner GROUP BY de-duplicates: one archived log has one row per
-- destination, so a plain SUM() multiplies the volume by the number of
-- local destinations.
WITH logs AS (
    SELECT thread#, sequence#, resetlogs_id,
           MIN(first_time) AS first_time, MAX(blocks*block_size) AS bytes
    FROM   v$archived_log
    WHERE  standby_dest = 'NO' AND first_time >= TRUNC(SYSDATE) - 13
    GROUP  BY thread#, sequence#, resetlogs_id
), hourly AS (
    SELECT TRUNC(first_time,'HH24') AS hr, SUM(bytes) AS bytes, COUNT(*) AS switches
    FROM   logs GROUP BY TRUNC(first_time,'HH24')
)
SELECT TO_CHAR(TRUNC(hr),'YYYY-MM-DD')  AS day,
       SUM(switches)                    AS logs,
       ROUND(SUM(bytes)/1024/1024)      AS redo_mb,
       ROUND(MAX(bytes)/1024/1024)      AS peak_hr_mb,
       MAX(switches)                    AS peak_hr_logs
FROM   hourly GROUP BY TRUNC(hr) ORDER BY 1;

-- Fallback when there is no archive history: redo since instance startup
SELECT ROUND(s.value/1024/1024)                AS redo_mb,
       ROUND((SYSDATE - i.startup_time)*24, 2) AS uptime_hours
FROM   v$sysstat s, v$instance i
WHERE  s.name = 'redo size';

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
2. Prompts for standby hostname, DB_UNIQUE_NAME, and ORACLE_SID
3. Prompts for standby storage mode:
   - **Traditional** (default): derives standby paths from primary via path substitution (`DB_FILE_NAME_CONVERT`)
   - **OMF**: prompts for `db_create_file_dest` and `db_recovery_file_dest` — no FILE_NAME_CONVERT needed. Use this when the standby has a different storage layout (e.g., FRA) than the primary.
4. **Q1b — standby filesystems** (Traditional mode, interactive terminals only): the script lists the distinct filesystems (the **first path component**, labeled with what lives on each — datafiles, redo logs, archive logs, FRA) found across the primary's paths, and asks whether any are named differently on the standby host. Answer **N** (default) if the mounts are named identically on both hosts. Answer **y** and you are prompted once per filesystem for its standby name — accept the default to keep a name unchanged, or type the standby's (`/ora_1 → /ora_1_s`; a multi-component target like `/mnt/oracle/ora_1` also works). The remap applies to every derived location on that filesystem and composes with the DB-name rename (`/ora_1/oradata/PROD → /ora_1_s/oradata/PRODSTBY`)
5. Derives each standby directory from its primary counterpart by applying the Q1b filesystem remap (if any) and swapping the DB-name path component, then (Traditional mode) walks you through the result — see [Reviewing the derived path mappings](#reviewing-the-derived-path-mappings) below
6. Prompts for the standby `ORACLE_BASE` / `ORACLE_HOME` (defaults: the primary's values — the Q1b remap deliberately does not touch the software mount; override here if the standby's differs)
7. Generates path conversion parameters (Traditional mode) or OMF configuration
8. Creates standby parameter file (init.ora)
9. Creates TNS entries for both databases
10. Creates listener configuration with static registration (including _DGMGRL services)
11. Creates DGMGRL script template
12. Writes master configuration file `standby_config_<STANDBY_DB_UNIQUE_NAME>.env`

### Reviewing the Derived Path Mappings

Standby directories are derived by applying the Q1b filesystem remap (if you declared one) and replacing the DB-name component of each primary path (`/u01/oradata/PROD` → `/u01/oradata/PRODSTBY`; with a remap, `/ora_1/oradata/PROD` → `/ora_1_s/oradata/PRODSTBY`). That is correct when both hosts share a layout up to those two rules, but a standby with a genuinely **different layout** needs corrections. Traditional mode surfaces them through:

1. **Unmapped-path confirmation** (only when Q1b was *not* asked — piped/non-interactive runs). A path with no DB-name component in it (in any case) — typically redo or temp on its own mount — cannot be auto-derived and is left pointing at the *primary's* directory, with a warning. When Q1b ran, this per-path confirmation is skipped entirely: you already declared, filesystem by filesystem, whether the standby's names differ, so an identical derived path is a stated choice rather than an ambiguity. Leaving a wrong path in place makes the Step 5 RMAN duplicate fail with `ORA-17502` / `ORA-19504`, because the directory is never created on the standby.
2. **Mapping review table.** A numbered table of every derived `primary -> standby` directory mapping. Press Enter to accept all, or enter a number to override that entry. This is where you redirect an *asymmetric* standby — one where the derivation succeeded but a directory's target differs in a way neither rule can express (`/u01/oradata/PROD` → `/oracle/data/PRODSTBY`) — and your final checkpoint after a Q1b remap, so it is worth an actual look before accepting.

Both run **before** the convert pairs and the `.env` are written, so corrections propagate into every generated file.

#### One split the standby cannot make on its own

If the **primary** keeps datafiles and redo logs in the *same* directory, the standby cannot split them into two. Step 2 warns when you ask for it (`Data/redo path collision`) and tells you which standby directory will go unused.

The reason is structural: a convert pair remaps a primary *filename*, and when ORLs and datafiles share one primary directory, nothing in the filename distinguishes them. Both pairs end up with an identical primary path, so Oracle's first-prefix match takes the datafile pair and every redo log follows the datafiles to the standby's data directory. The result is functional — the standby is correct and applies redo — but the split you configured silently doesn't happen.

To genuinely split redo on the standby, give the **primary** a distinct redo directory as well, then re-run Step 2. This is the same root cause as the SRL-contradiction warning (`PRIMARY_SRL_PATH` equal to `PRIMARY_REDO_PATH` with a differing standby SRL path).

> **Non-interactive runs (piped stdin):** Q1b and both review prompts are TTY-gated. Q1b is skipped entirely (identical filesystems, empty remap), the mapping table is still printed for the log, but the derived defaults are accepted silently and unmapped paths keep the identical primary path with a warning. To change a path afterwards, edit `standby_config_<STANDBY_DB_UNIQUE_NAME>.env` and re-run with `--regenerate` (see below).

### Regenerating After Editing the Config

```bash
./primary/02_generate_standby_config.sh --regenerate
```

`--regenerate` re-derives the `DB_FILE_NAME_CONVERT` / `LOG_FILE_NAME_CONVERT` pairs from the `PRIMARY_*_PATHS` / `STANDBY_*_PATHS` arrays in the `.env`, rewrites the derived files (pfile, TNS, listener, DGMGRL), **and persists the rebuilt convert strings back into the `.env` itself**. That last part matters: Step 5 feeds RMAN's `SPFILE SET` clause from the `.env`, and the `SPFILE SET` value overrides the regenerated pfile — so a stale string there would silently override your edited layout.

Edit the **path arrays**, not the convert strings — the arrays are the source of truth. If the arrays are missing or their lengths don't match, the pairs are *not* re-derived and the stored convert strings are used verbatim (the script warns when this happens).

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
4. Creates standby redo logs (required for switchover), one group more than the
   number of online redo log groups, sized to the largest online redo log, with
   an explicit `THREAD` clause
5. Enables Data Guard Broker (DG_BROKER_START=TRUE)
6. Sets STANDBY_FILE_MANAGEMENT=AUTO
7. Tests network connectivity to standby

> The RMAN archivelog deletion policy (`SHIPPED TO ALL STANDBY`) is **not** set
> here. With no standby yet receiving redo, that policy would make every
> archived log non-deletable to RMAN/FRA maintenance — on a busy primary with a
> tight FRA this can fill the FRA and hang the database (ORA-00257) before the
> clone finishes. Step 6 sets it after the broker configuration is healthy and
> transport is confirmed shipping.

> Standby redo logs are also needed on the **standby** side (for the post-switchover
> primary role). Step 5's RMAN duplicate recreates them there from the primary's
> definition. To audit both sides at any point - including builds this repo did not
> create - run `./dg_check_srl.sh`; it prints the exact fix DDL and never executes it.
> See [Post-Setup Tooling](#post-setup-tooling).

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

-- Find the instance's redo thread (single instance: almost always 1)
SELECT thread# FROM v$instance;

-- Add standby redo logs (adjust size and paths as needed).
-- Always give an explicit THREAD: an SRL created without one sits at
-- THREAD#=0 until RFS first uses it, and DGMGRL VALIDATE DATABASE then
-- reports it as "not configured for thread N" - which blocks the Step 13
-- MAXAVAILABILITY preflight and confuses per-thread SRL accounting.
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 4 ('/u01/app/oracle/oradata/TESTDB/standby_redo04.log') SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 5 ('/u01/app/oracle/oradata/TESTDB/standby_redo05.log') SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 6 ('/u01/app/oracle/oradata/TESTDB/standby_redo06.log') SIZE 200M;
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1 GROUP 7 ('/u01/app/oracle/oradata/TESTDB/standby_redo07.log') SIZE 200M;

-- Verify standby redo logs
SELECT group#, thread#, bytes/1024/1024 AS size_mb, status FROM v$standby_log;

-- Enable Data Guard Broker
ALTER SYSTEM SET DG_BROKER_START=TRUE SCOPE=BOTH;

-- Set standby file management
ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT=AUTO SCOPE=BOTH;

EXIT;
```

```bash
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
9. Sets the primary's RMAN archivelog deletion policy to `SHIPPED TO ALL
   STANDBY` — done here (not in Step 4) because the policy blocks archivelog
   deletion until a standby has received the logs; setting it before transport
   works risks filling the FRA (ORA-00257). Skipped (with the manual command
   printed) if the broker configuration did not reach SUCCESS/WARNING

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

```bash
# Only once SHOW CONFIGURATION is SUCCESS and log shipping works:
# configure the RMAN archivelog deletion policy on the primary
rman target /
CONFIGURE ARCHIVELOG DELETION POLICY TO SHIPPED TO ALL STANDBY;
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
9. Checks whether an observer is already connected
   (`FS_FAILOVER_OBSERVER_PRESENT`) and, interactively, asks where the
   observer will run:
   - **already set up elsewhere** - reminds you to start it and verify the
     broker sees it
   - **standby host (or any host with this repo + NFS share)** - prints the
     `fsfo/observer.sh setup` / `start` walkthrough (Step 10)
   - **dedicated third host** - runs `add_observer/01_prepare_primary.sh`
     for you on the spot (it runs on the primary anyway), generating the
     self-contained bundle to copy to that host
   - piped/non-interactive runs skip the questions and get the printed
     walkthrough, exactly as before

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
-- Threshold is a CONFIGURATION property; Target is a DATABASE property
-- (EDIT CONFIGURATION ... FastStartFailoverTarget fails with ORA-16568).
EDIT CONFIGURATION SET PROPERTY FastStartFailoverThreshold=30;
EDIT DATABASE 'PRIMARY_DB' SET PROPERTY FastStartFailoverTarget='STANDBY_DB';
EDIT DATABASE 'STANDBY_DB' SET PROPERTY FastStartFailoverTarget='PRIMARY_DB';

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
Step 9 asks which one it will be at the end of its run: for a host with this
repository and the NFS share it prints this step's walkthrough; for a third
host without the repository it offers to generate the `add_observer/` bundle
immediately (in that case follow the bundle's `RUN_ON_OBSERVER_HOST.md`
instead of this step).

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

2. **Authentication**: Uses Oracle Wallet with SYSDG user for secure authentication. No passwords are stored in scripts. If you are adopting an *existing* configuration whose observer still authenticates as SYS, convert it with the `observer_sys_to_sysdg/` kit - see [Side Toolkits](#side-toolkits-outside-the-numbered-workflow).

3. **Protection mode impact**: MAXIMUM AVAILABILITY provides zero data loss but adds the remote-write acknowledgement to every commit. Quantify the cost on a live system with `./dg_sync_impact.sh` - see [Post-Setup Tooling](#post-setup-tooling).

4. **Network requirements**: Observer must have network connectivity to both primary and standby databases.

5. **Maintenance considerations**: Stop the observer before performing database maintenance to prevent unexpected failovers.

6. **Threshold tuning**: The default 30-second threshold can be adjusted:
   ```bash
   FSFO_THRESHOLD=60 ./primary/09_configure_fsfo.sh
   ```

7. **Retrofitting an observer onto an existing configuration**: this step resolves its inputs from the build's `standby_config_*.env` on the NFS share. For a configuration that already exists and already works - especially one this repo did not build, or one where the observer must live on a **third host** - use the standalone `add_observer/` kit instead. It discovers the topology from the broker and never changes the protection mode. See [Side Toolkits](#side-toolkits-outside-the-numbered-workflow).

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

### Variants

`create_role_trigger.sh` is the baseline: SYS-owned objects, non-CDB database. Three
variants cover the cases it refuses to handle.

| Script | Use when | Objects created |
|--------|----------|-----------------|
| `trigger/create_role_trigger.sh` | Non-CDB, SYS objects allowed | `SYS.DG_SERVICE_MGR` + 2 triggers |
| `trigger/create_role_trigger_dedicated_user.sh` | Non-CDB, policy forbids adding objects to `SYS` | `DG_ADMIN` user (least privilege) owning the package and triggers, plus a narrow `SYS.DG_ALERT_LOG_MSG` wrapper (the dedicated user cannot call SYS-only `DBMS_SYSTEM.KSDWRT`; only `EXECUTE` on the wrapper is granted, never on `DBMS_SYSTEM`) |
| `trigger/create_role_trigger_cdb.sh` | Multitenant (`V$DATABASE.CDB = YES`) | `SYS.DG_SERVICE_MGR` storing `(container, service)` pairs; switches container before each `DBMS_SERVICE` call |

**Both non-CDB scripts refuse to run on a CDB** and point at the CDB variant - their
container-blind `DBMS_SERVICE` calls would silently mismanage PDB services. There is
currently **no CDB-aware dedicated-user variant**: a shop that runs CDBs *and* forbids
SYS objects has no supported path here yet.

**CDB variant specifics:**

- Services are discovered as `(container, service)` pairs from `V$ACTIVE_SERVICES`
  joined to `V$CONTAINERS`, excluding `PDB$SEED`, system services, and each
  container's default service.
- The triggers still fire in `CDB$ROOT` (the role transition is CDB-wide);
  `MANAGE_SERVICES` does `ALTER SESSION SET CONTAINER` per service and returns to
  `CDB$ROOT`. A per-service failure (e.g. a PDB only MOUNTED on the standby) is
  written to the alert log and never aborts the others.
- A PDB service only starts if the PDB is OPEN, so ensure PDBs auto-open
  (`ALTER PLUGGABLE DATABASE ... SAVE STATE` or an open trigger).
- **Active Data Guard caveat:** a system trigger cannot switch containers
  (`ORA-65123`), so the work is deferred to a one-time `DBMS_SCHEDULER.CREATE_JOB`.
  On a standby opened READ ONLY WITH APPLY, `CREATE_JOB` cannot write to the data
  dictionary and fails with `ORA-16000`; this is caught and only logged, so services
  are **not** stopped by the trigger on an ADG-opened standby. Watch the alert log
  for `DG_SERVICE_MGR SCHEDULE failed` and stop such services manually.

### Creating Role-Aware Services (Multitenant)

The trigger manages services that already exist. To create one in the first place on a
CDB, use one of these instead of hand-writing `DBMS_SERVICE` calls (both run on the
PRIMARY, are idempotent, and replicate to the standby via redo):

```bash
# Service inside a PDB (the PDB must be OPEN READ WRITE)
./trigger/create_pdb_service.sh --pdb SALESPDB --service sales_rw
./trigger/create_pdb_service.sh SALESPDB sales_rw            # positional form
./trigger/create_pdb_service.sh --pdb SALESPDB --service sales_ro --taf --no-start

# Service in CDB$ROOT
./trigger/create_cdb_service.sh --service admin_svc
./trigger/create_cdb_service.sh admin_svc --taf
```

`--taf` adds basic TAF attributes (`FAILOVER_TYPE=SELECT`, `FAILOVER_METHOD=BASIC`);
`--no-start` creates without starting. Note `-s` is reserved (approval mode) by the
shared argument parser, so the service flag is the long `--service` only.

Neither script saves PDB state, so role-awareness comes entirely from the trigger:
**after creating a service, re-run `create_role_trigger_cdb.sh`** so the new service is
started on PRIMARY and stopped on STANDBY automatically.

---

## Step 12: NFS Artifact Cleanup (Optional)

**Script:** `common/cleanup_nfs_artifacts.sh`

Run this once Data Guard has been verified (Step 7), and ideally after the [handoff report](#handoff-report-recommended-any-time-after-step-7) (`primary/10_generate_handoff_report.sh`) has been reviewed, to scrub sensitive/transient artifacts for a build off the group-readable NFS share.

### What the Script Does

1. Selects (or accepts via `-c`/`--config`) the `standby_config_*.env` file for the build and derives its primary/standby `DB_UNIQUE_NAME`s
2. Scans the NFS share for that build's password file copies (`orapw*`), the generated standby pfile, and RMAN duplicate cmdfiles/logs
3. Prints the exact list of files that will be removed, and the files that will be left in place
4. Prompts for confirmation (unless `-y`/`--yes` is given) before deleting anything
5. By default, keeps the config `.env` files, the handoff report and its companion files (HTML, JSON sidecar, `_tnsnames.ora`, `_jdbc.properties`, `_verify.sh`), and the application-impact briefing; `--all` removes those too (with a stronger, typed confirmation)

### Manual Equivalent

```bash
# As oracle user, on any host with the NFS share mounted
rm -f /OINSTALL/_dataguard_setup/orapw<PRIMARY_SID>
rm -f /OINSTALL/_dataguard_setup/orapw<PRIMARY_DB_NAME>
rm -f /OINSTALL/_dataguard_setup/init<STANDBY_SID>_<STANDBY_DB_UNIQUE_NAME>.ora
rm -f /OINSTALL/_dataguard_setup/logs/rman_duplicate_*.rcv
rm -f /OINSTALL/_dataguard_setup/logs/rman_duplicate_*.log
```

### Important Notes

- RMAN duplicate cmdfiles/logs are not tagged with `DB_UNIQUE_NAME` in their filename, so if multiple builds have shared the same NFS share, review the printed list carefully before confirming.
- Use `--all` for a full teardown of a build's NFS footprint once the handoff report and any application-impact briefing have been distributed and are no longer needed from the share.

---

## Step 13: Set Maximum Availability Protection (Optional)

**Script:** `primary/13_set_max_availability.sh`

Raises the configuration to zero-data-loss protection — protection mode `MAXIMUM AVAILABILITY` with `LogXptMode=FASTSYNC` — **without** enabling Fast-Start Failover. Step 9 (FSFO) already applies these same two settings as part of enabling FSFO, so this step is for setups that want synchronous, zero-data-loss redo transport but no automatic failover.

Run it on the **PRIMARY** any time after Step 7 verification passes. It needs the build's `standby_config_*.env` on the NFS share, so run it before a `cleanup_nfs_artifacts.sh --all` teardown (the default Step 12 cleanup keeps the `.env`).

### What the Script Does

Everything is validated **before** any change is made:

1. Verifies the local database role is PRIMARY
2. Verifies the broker configuration exists and reports SUCCESS (warnings require explicit confirmation)
3. Checks the current protection mode and both databases' `LogXptMode` — if everything already matches the target, exits successfully without prompting (idempotent)
4. Checks Fast-Start Failover state: if FSFO is enabled but the settings don't match (a mixed state), it refuses — the broker rejects `LogXptMode` edits on FSFO members. Disable FSFO first, or re-run Step 9
5. Runs `VALIDATE DATABASE` for both databases and checks for `Ready for Switchover: Yes` (this also surfaces missing/insufficient standby redo logs, which FASTSYNC requires)
6. Reports transport/apply lag from `V$DATAGUARD_STATS` and checks `V$ARCHIVE_DEST` for destination errors
7. Prints a change summary; `-n`/`--check` mode stops here

Then, after confirmation:

8. Sets `LogXptMode=FASTSYNC` on both databases (skipped if already set)
9. Sets protection mode to `MAXIMUM AVAILABILITY` and verifies it took effect in `V$DATABASE`
10. Polls `SHOW CONFIGURATION` (up to ~30 s) until the broker returns SUCCESS

### Manual Equivalent

```
dgmgrl /

-- Validate first
SHOW CONFIGURATION;
VALIDATE DATABASE 'PRIMARY_DB';
VALIDATE DATABASE 'STANDBY_DB';

-- LogXptMode must be synchronous before raising the protection mode
EDIT DATABASE 'PRIMARY_DB' SET PROPERTY LogXptMode='FASTSYNC';
EDIT DATABASE 'STANDBY_DB' SET PROPERTY LogXptMode='FASTSYNC';

EDIT CONFIGURATION SET PROTECTION MODE AS MAXAVAILABILITY;

SHOW CONFIGURATION;
EXIT;
```

### Important Notes

- **Commit latency increases**: with FASTSYNC the primary waits for the standby to acknowledge redo *receipt* (not disk write) on every commit — expect roughly one network round-trip added per commit. The Step 1 redo statistics report the minimum transport bandwidth the link needs.
- **`ORA-16627` on the mode change** means the standby is not synchronized — the broker itself is the final validator; fix transport and re-run.
- **Availability is preserved**: in MAXIMUM AVAILABILITY the primary keeps running if the standby becomes unreachable, and resynchronizes automatically when it returns.
- **Rollback**: `EDIT CONFIGURATION SET PROTECTION MODE AS MAXPERFORMANCE;` then set `LogXptMode='ASYNC'` on both databases.
- To add automatic failover later, run Step 9 — an FSFO-enabled configuration already satisfies this step, and re-running it then is a no-op.

---

## Handoff Report (Recommended, Any Time After Step 7)

**Script:** `primary/10_generate_handoff_report.sh` (run on PRIMARY)

Not part of the numbered 1-13 sequence, but worth generating before Step 12's cleanup -
`--all` cleanup removes the report from the share. Generate it after Data Guard is
verified, and ideally after Step 9/10 (FSFO) and Step 11 (service trigger) are in
place, so the report describes the finished topology.

```bash
./primary/10_generate_handoff_report.sh
```

Step 10 is a **thin wrapper** around `dg_handoff.sh` in the repository root, which is
the single implementation of the report. The wrapper adds only what the setup workflow
knows and the standalone script cannot discover: the build's `standby_config_<NAME>.env`
(hostnames, listener port, standby TNS alias), the NFS share as the output location, the
`docs/DG_APPLICATION_IMPACT.html` copy next to the report, and the setup-step
banner/`-n` check mode/summary chrome. It passes `--all-flavors`, so the step-10 output
keeps the primary-only / standby-only / role-aware connect strings.

### What the Script Does

1. Discovers the topology (hostnames prefer the broker's `HostName` property;
   `DGConnectIdentifier` is trusted only when it is a genuine easy-connect string,
   never a TNS alias)
2. Collects a status snapshot: roles, open modes, protection mode, standby
   `LogXptMode`, MRP/apply lag, archive gaps, FSFO state (threshold shown only when
   FSFO is enabled), broker config, role-trigger deployment status, server-side
   `SQLNET.EXPIRE_TIME`
3. Derives the standby's open mode from the broker's `Real Time Query` field (19c
   DGMGRL prints no "Open Mode" line) plus, when a standby TNS alias is known, a
   best-effort auto-login-wallet connect to the standby, which also yields apply and
   transport **lag in seconds** from `V$DATAGUARD_STATS` (otherwise the lag is parsed
   from the broker's `Apply Lag:` line)
4. Discovers user-visible services from `V$ACTIVE_SERVICES` (same logic as the role
   trigger), always including the default `<DB_UNIQUE_NAME>` service - which is
   flagged as **not** managed by the role trigger - and reads each service's HA
   attributes from the dictionary (TAF type/method/retries/delay, Transaction Guard
   `COMMIT_OUTCOME`, `DRAIN_TIMEOUT`, `FAILOVER_RESTORE`), so the report states what
   each service actually has instead of hedging
5. Computes a **Verdict** with each reason named *and an action attached to every
   finding*: ERROR on broker-config errors/ORA- diagnostics, failure-state
   switchover status, or apply lag beyond `DG_SEQ_GAP_CRIT` sequences; WARNING on
   lesser findings (broker warnings, role trigger not deployed, standby readability
   unknown, no user-created service, apply lag in time beyond `DG_LAG_WARN_SECONDS`,
   default 60); HEALTHY only when nothing fired
6. Writes the Markdown report, a styled self-contained HTML twin, a JSON sidecar and a
   TNS/JDBC/verify pack (see **Output** below), and copies
   `docs/DG_APPLICATION_IMPACT.html` to the share when available

The report opens with an **At a Glance** section (verdict pill + finding/action
list, one-line RPO, failover mode, standby readability, standby data freshness,
which connect string to hand out, go-live pointers), followed by **Changes Since
Last Report** - a diff against the previous run's JSON sidecar (verdict, DB unique
names, hosts, port, protection mode, `LogXptMode`, standby open mode, FSFO, role
trigger, DB version, descriptor timeouts, and services added/removed/changed), which
degrades to a one-liner on the first run or when nothing changed; the
application-facing sections follow (1 Connection
Strings, 2 Application Impact, 3 Client and Pool Settings, 4 Verification), and all
DBA-only material (topology, status snapshot, broker output, the datafile/PDB
convert-pair note, discovery warnings) moves to a closing **Appendix: DBA
Snapshot**, which also carries **Recommended Service Changes (DBA)**: for every
user-created service missing TAF, Transaction Guard or a drain timeout, a ready
`DBMS_SERVICE.MODIFY_SERVICE` block (prefixed with `ALTER SESSION SET CONTAINER` for a
PDB service) with suggested starting values and a reminder that the service must be
restarted for new TAF attributes to apply. Set `DG_HANDOFF_ENV` / `DG_HANDOFF_CONTACT` in the environment to add
an environment label (PROD/UAT/...) and a DBA contact chip to the header.

### Connection Strings

Role-aware strings are always emitted; step 10 passes `--all-flavors`, so its report
carries three flavors per service:

- **Primary-only** TNS + JDBC - writes / admin.
- **Standby-only** TNS + JDBC - read-only reporting. If the standby is `MOUNTED` the
  report marks these as not currently usable; if it is `READ ONLY WITH APPLY` it adds
  the Active Data Guard licensing note, the apply-lag / read-your-writes caveat, and
  the ORA-16000 no-DML warning.
- **Role-aware failover** TNS + JDBC + Easy Connect Plus - one descriptor with both
  hosts in `ADDRESS_LIST`. This is the recommendation for the application tier once
  Step 11's trigger is deployed: the service runs only on whichever side currently
  holds the PRIMARY role, so clients follow the active database across a switchover or
  failover without a config change.

The report is written for application engineers: per-mode RPO semantics (SYNC/FASTSYNC
ack point, the standby-disconnected loss window, ASYNC loss bounds), an outage-budget
breakdown (FSFO threshold + failover execution + service startup + reconnect), an ORA-
error table for role transitions (12514/12541/01033/03113/25402/16000 with
retryability) plus commit-ambiguity guidance, a descriptor-parameter reference with
worst-case connect math derived from the actual TNS values - `CONNECT_TIMEOUT`,
`TRANSPORT_CONNECT_TIMEOUT`, `RETRY_COUNT` and `RETRY_DELAY`, tunable per run with
`--connect-timeout` / `--transport-timeout` / `--retry-count` / `--retry-delay`, and
the prose follows the values you set (the Easy Connect Plus strings carry the same
connect/retry values as the TNS descriptor, so every driver gets the documented
behavior). The descriptors configure **no** `FAILOVER_MODE`: TAF is reported per
service as a dictionary fact, not baked into the connect string. The report also
covers ADG read-staleness controls
(`STANDBY_MAX_DATA_DELAY`/ORA-03172, `SYNC WITH PRIMARY`), sequence-cache gap and
NOLOGGING/ORA-26040 specifics, driver mapping examples (ODP.NET, python-oracledb,
SQLAlchemy), a client/pool settings checklist, and a verification section whose
end-to-end `SYS_CONTEXT('USERENV', ...)` role check doubles as the switchover-drill
pass criterion.

### Output

| File | Notes |
|------|-------|
| `${NFS_SHARE}/dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.md` | The report; also printed to stdout |
| `${NFS_SHARE}/dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.html` | Styled, self-contained twin of the same content (ČSOB palette, light/dark, table of contents, print stylesheet, staleness banner, copy buttons on descriptor blocks) |
| `${NFS_SHARE}/dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.json` | Machine-readable sidecar (`schema_version` 1) with every discovered fact, the verdict and its notes, the descriptor timeouts and the per-service HA attributes - also the baseline the next run diffs for "Changes Since Last Report" |
| `${NFS_SHARE}/dg_handoff_<PRIMARY_DB_UNIQUE_NAME>_tnsnames.ora` | Ready-to-append TNS aliases (`<SERVICE>_HA`, plus `_PRI` / `_STB` under `--all-flavors`) |
| `${NFS_SHARE}/dg_handoff_<PRIMARY_DB_UNIQUE_NAME>_jdbc.properties` | One `<SERVICE>_HA.url` (full descriptor) and `<SERVICE>_HA.easyconnect` per service |
| `${NFS_SHARE}/dg_handoff_<PRIMARY_DB_UNIQUE_NAME>_verify.sh` | Runnable check for application hosts: name resolution and TCP reachability for both hosts, plus an end-to-end `SYS_CONTEXT` role assertion through the role-aware Easy Connect string. Needs no repository and no Oracle server install - a missing tool SKIPs its check. Credentials via `-u user/pass` or `APP_USER`/`APP_PASSWORD`; `--expect-db-unique-name <new primary>` turns it into the switchover-drill pass criterion |
| `${NFS_SHARE}/dg_application_impact.html` | Copy of `docs/DG_APPLICATION_IMPACT.html`, linked from "Notes for Client Teams" (supplementary - the Markdown is self-contained) |

The report header lists these files in a **Files** chip. The Markdown emitter is the
single definition of the report; the HTML is rendered from it by a built-in POSIX-awk
converter, so the two never diverge in content. The HTML branding (eyebrow name, logo,
accent/ink/tint colors) can be overridden with the `DG_HANDOFF_BRAND_*` environment
variables, and its staleness banner threshold with `DG_HANDOFF_STALE_DAYS` (default 30).

The report header also carries an **Interactive diagram** link in the report header: the
discovered topology (DB unique names, hosts, observer placement, first service, port,
protection mode, `LogXptMode`, FSFO threshold - **never credentials**) is encoded as
`#cfg=<base64url(JSON)>` for the interactive configuration explorer at
`https://davidbudac.cz/dataguard/` (override with `DG_DOC_BASE_URL`). Undiscovered
fields are omitted so the page falls back to its defaults; the link is skipped entirely
on a host with neither `base64` nor `openssl`.

Re-run after listener changes, new services, or topology changes.

### Running It Standalone

`./dg_handoff.sh` (repo root) is the same generator, run directly against **any**
existing Data Guard configuration, with no dependency on `standby_config_*.env`,
`common/dg_functions.sh`, or the NFS share:

```bash
./dg_handoff.sh
./dg_handoff.sh -o /tmp/handoff.md
./dg_handoff.sh --primary-host pri --standby-host stb --port 1521
./dg_handoff.sh --env PROD --contact "DBA team <dba@example.com>"
./dg_handoff.sh --standby-tns-alias STB_ALIAS --all-flavors
./dg_handoff.sh --service APP_SVC --exclude-service PDB1:OLD_SVC
./dg_handoff.sh --connect-timeout 5 --retry-count 2
./dg_handoff.sh --previous /tmp/last.json --no-pack
```

Output defaults to `./dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.md`, with the HTML twin, the
JSON sidecar and the TNS/JDBC/verify pack written next to it. Useful flags:

| Flag | Effect |
|------|--------|
| `--primary-host` / `--standby-host` / `--port` | Override discovery when the broker is down or returns the wrong value |
| `--standby-tns-alias A` | Query the standby directly (auto-login wallet only, never prompts) for its `OPEN_MODE` and `V$DATAGUARD_STATS` lag (env: `DG_HANDOFF_STANDBY_TNS_ALIAS`) |
| `--all-flavors` | Also emit primary-only and standby-only strings (what step 10 does) |
| `--impact-reference PATH` | What the "Full application behavior briefing" bullet points at |
| `--env` / `--contact` | Header chips (env: `DG_HANDOFF_ENV` / `DG_HANDOFF_CONTACT`) |
| `--service NAME` / `--exclude-service NAME` | Repeatable, case-insensitive, `CONTAINER:NAME` accepted. An active filter is stated in the header; a `--service` that matches nothing is a WARNING |
| `--connect-timeout` / `--transport-timeout` / `--retry-count` / `--retry-delay N` | Descriptor knobs the tables, worst-case math, pool checklist and Easy Connect strings all derive from (env: `DG_HANDOFF_CONNECT_TIMEOUT` and friends) |
| `--previous FILE` | Diff against this JSON sidecar instead of the one at the default path |
| `--no-json` / `--no-pack` | Skip the sidecar (and therefore the change tracking) / skip the TNS/JDBC/verify pack |

Service discovery is container-aware: services are
discovered as (container, service) pairs from `V$ACTIVE_SERVICES` joined to
`V$CONTAINERS`, each service section names the container it lands in (with a
warning for `CDB$ROOT`), and every **default** service (a container's own
`DB_NAME[.DB_DOMAIN]` / PDB-name service) is flagged as NOT role-aware - those are
registered wherever the container is up, including the standby, so they must never
be handed to applications as failover descriptors. User-created services sort
first, and a run with no user-created service at all is a WARNING of its own.

Exit codes: `0` HEALTHY, `1` WARNING, `2` ERROR, `3` usage/connection failure -
cron-friendly, same convention as `dg_status.sh`. (The step-10 wrapper keeps the
setup-step convention: nonzero only on ERROR.)

### Manual Equivalent

There is no concise manual equivalent - the report is a document, not a database
change. Producing it by hand means running the Step 7 verification queries, then
`DGMGRL SHOW CONFIGURATION` / `SHOW DATABASE ... VERBOSE`, then `V$ACTIVE_SERVICES`,
then hand-writing a TNS descriptor per service per flavor, a JDBC URL per service and a
per-host connectivity check, and keeping all of it in sync
with the configuration. That is exactly the work the script exists to avoid.

---

## Peer Wallet Setup (Recommended, Any Time After Step 7)

**Script:** `common/setup_dg_wallet.sh` (run on **each** DB host)

Creates an auto-login Oracle Wallet holding SYS credentials for the *peer* database, so
`dg_triage_sid.sh`, `dg_diag_sid.sh`, and `dg_check_srl.sh` can query the other side
without prompting for a password.

```bash
bash common/setup_dg_wallet.sh              # on primary
bash common/setup_dg_wallet.sh              # on standby
bash common/setup_dg_wallet.sh -w /path     # custom wallet directory
bash common/setup_dg_wallet.sh -A           # generate the wallet password automatically
```

The script auto-detects the local role, discovers the peer TNS alias from the broker,
creates the wallet, configures `sqlnet.ora`, and tests the connection. It is idempotent
- re-running adds or updates credentials in an existing wallet.

Re-running with `-A` against a wallet that already holds credentials (or whose
auto-generated password can no longer be supplied) lists the existing credentials and
requires typing `RECREATE WALLET` to confirm. The rebuild happens in a staging directory
and is swapped in only after every step succeeds, with the old wallet kept as a
timestamped `.bak`.

Full reference: [WALLET_SETUP.md](WALLET_SETUP.md).

### Manual Equivalent

```bash
# On each DB host, as oracle
mkstore -wrl /u01/app/oracle/wallet -create
mkstore -wrl /u01/app/oracle/wallet -createCredential <PEER_TNS_ALIAS> sys <sys_password>
orapki wallet create -wallet /u01/app/oracle/wallet -auto_login -pwd <wallet_password>
```

```
# Add to $ORACLE_HOME/network/admin/sqlnet.ora
WALLET_LOCATION =
  (SOURCE = (METHOD = FILE)
            (METHOD_DATA = (DIRECTORY = /u01/app/oracle/wallet)))
SQLNET.WALLET_OVERRIDE = TRUE
```

```bash
# Verify
sqlplus /@<PEER_TNS_ALIAS> as sysdba
```

---

## Post-Setup Tooling

These are standalone operational tools, not workflow steps. None of them changes the
database; `dg_check_srl.sh` prints DDL but never executes it.

| Tool | Where it runs | What it answers |
|------|---------------|-----------------|
| `dg_status.sh` | Jump host (SSH to both DB hosts) | Is the whole configuration healthy right now? |
| `dg_triage_sid.sh` | On a DB host | Fast local triage - what is wrong with this side? |
| `dg_diag_sid.sh` | On a DB host | Deep local diagnostics when triage is not enough |
| `dg_check_srl.sh` | On a DB host | Are standby redo logs right on both sides? What DDL fixes them? |
| `dg_sync_impact.sh` | On the PRIMARY | What is SYNC/FASTSYNC transport costing commits? |
| `get_dg_config_url.sh` | On a DB host | Link to the interactive diagram of this configuration |

### Health Dashboard

```bash
bash dg_status.sh                    # $ORACLE_SID, or auto-detect from ora_pmon_
bash dg_status.sh -s cdb1            # explicit primary SID
bash dg_status.sh -c myconfig.env    # custom SSH config
bash dg_status.sh --no-color         # or set NO_COLOR
```

Checks both databases: role, open mode, protection mode, switchover status, force
logging, flashback, broker status, running services, redo/SRL counts, archive
destination errors, archive gaps, FRA usage, MRP apply status, transport/apply lag,
archived-log sequence gaps, UNNAMED datafiles, broker config including FSFO and
per-member ORA errors, and recent DG-related alert log entries.

Exit codes: `0` healthy, `1` warnings, `2` errors, `3` usage/config error - use these in
cron rather than scraping the colored output. An unreachable host is reported as
`UNREACHABLE`, and an unreachable standby renders replication state as `UNKNOWN`, never
`IN SYNC`. Thresholds are env-overridable: `DG_FRA_WARN_PCT` (80), `DG_FRA_CRIT_PCT`
(90), `DG_SEQ_GAP_WARN` (1), `DG_SEQ_GAP_CRIT` (5), `DG_LAG_WARN_SECONDS` (60).

Full reference: [DG_STATUS.md](DG_STATUS.md).

### Local Triage and Diagnostics

No SSH needed - run directly on the DB host.

```bash
bash dg_triage_sid.sh        # fast triage, wallet-only auth by default
bash dg_diag_sid.sh          # deep diagnostics, prompts if wallet auth fails
bash dg_triage_sid.sh -L     # local + broker only, skip remote SQL
bash dg_diag_sid.sh -P       # force SYS password prompt for the remote side
```

`dg_check_sid.sh` is a deprecated wrapper that forwards to `dg_triage_sid.sh` and always
exits `0`. Full reference: [DG_CHECK.md](DG_CHECK.md).

### Standby Redo Log Audit

```bash
./dg_check_srl.sh                     # both sides, peer via wallet
./dg_check_srl.sh -p                  # prompt for SYS password for the peer
./dg_check_srl.sh -L                  # local only (run separately on each host)
./dg_check_srl.sh -d /u02/oradata/srl # override the directory in generated DDL
```

Verifies at least (online redo groups + 1) SRL groups per thread, each sized to the
largest online redo log, on **both** sides, and prints the exact fix DDL for whatever is
missing or undersized. It executes nothing.

SRLs created without a `THREAD` clause sit at `THREAD#=0` until first use (this repo's
Step 4 created them that way before 2026-08; it now assigns `THREAD` explicitly). The
checker counts `THREAD#=0` SRLs as a shared pool toward each thread's requirement rather
than demanding duplicates, so old and new builds both check out correctly. On a
multi-thread database that pooling is flagged, because Oracle hands each group to
whichever thread claims it first.

Exit codes: `0` compliant, `1` DDL needed (or a peer exists but was not checked), `2`
argument / pre-flight / data-collection error.

### Synchronous Transport Impact

```bash
./dg_sync_impact.sh                                   # ASH 24h, AWR 7 days
./dg_sync_impact.sh --auto-baseline                   # detect the pre-SYNC baseline from AWR
./dg_sync_impact.sh --baseline-begin 12000 --baseline-end 12168
./dg_sync_impact.sh --no-pack                         # no Diagnostics Pack license
./dg_sync_impact.sh --html -o impact.html             # self-contained HTML page
```

Answers "what is SYNC costing us" with a model rather than a guess. Since 11g R2 the
local redo write (`log file parallel write`, L) and the remote send/ack (`SYNC Remote
Write`, R) run **in parallel**, so a commit's redo-write phase is `max(L,R)` and the
per-write overhead is `E[max(L,R)] - E[L]` - a number averages alone cannot produce. The
script cross-joins the two `V$EVENT_HISTOGRAM_MICRO` distributions, brackets the result
with the assumption-free bounds `max(0, avgR-avgL) <= overhead <= avgR`, and scales it to
added ms/commit, s/hour, and % of DB time.

Run it on the PRIMARY. Not being a primary is fatal (exit 1); having no SYNC destination
is not - it reports current `log file sync` and L as an ASYNC-side baseline. Every
section names its source views and prints the exact query that produced each table.

Full methodology, flags, and the `--auto-baseline` detection heuristic:
[DG_SYNC_IMPACT.md](DG_SYNC_IMPACT.md).

### Interactive Diagram Link

```bash
./get_dg_config_url.sh                                # summary on stderr, URL on stdout
./get_dg_config_url.sh -q                             # URL only: URL=$(./get_dg_config_url.sh -q)
./get_dg_config_url.sh --standby-host stb --port 1521 # fill in what discovery missed
```

Produces the same visualizer link the handoff report embeds, without generating a
report. Standalone (no `standby_config_*.env`, no `common/dg_functions.sh`, no NFS
share) and runnable from either side - on a standby it swaps the roles and reports the
local host as the standby. Overrides: `--primary-host`, `--standby-host`,
`--observer-host`, `--port`, `--service`, `--base-url`. Every query is best-effort; only
a failed `sqlplus / as sysdba` connection, or a host with neither `base64` nor
`openssl`, is fatal.

---

## Side Toolkits (Outside the Numbered Workflow)

Three self-contained subprojects live in this repo but are not part of the 1-13 sequence.

### Add an FSFO Observer on a Third Host

**Directory:** `add_observer/` (see its own `README.md`)

For a Data Guard configuration that **already exists and already works** - built by this
repo or not - that needs an FSFO observer placed on a **third host** rather than on
either database host. Steps 9 and 10 cannot do this: both resolve their inputs from this
build's `standby_config_*.env` on the NFS share, and Step 9 additionally forces
`MAXIMUM AVAILABILITY` + `LogXptMode=FASTSYNC`, which is an unwanted change to a running
configuration. This kit resolves everything from the broker instead and leaves the
protection mode alone.

| Script | Runs on | Does |
|--------|---------|------|
| `01_prepare_primary.sh` | PRIMARY | Discovers the topology, reports FSFO readiness, creates/verifies the dedicated `SYSDG` observer user (CDB-aware), optionally enables FSFO (`--enable-fsfo`), writes the bundle for the third host |
| `02_setup_observer_host.sh` | THIRD HOST | TNS entries + auto-login wallet, then proves the observer user can log in `AS SYSDG` to **both** databases |
| `03_observer_ctl.sh` | THIRD HOST | `start` / `stop` / `restart` / `status` / `log` / `boot` |
| `04_verify_observer.sh` | THIRD HOST (or anywhere) | End-state verification + placement check. Exit `0` = observer present and FSFO ready |

```bash
# 1. on the PRIMARY
./add_observer/01_prepare_primary.sh --observer-host obs1
#    ... reports readiness, creates the observer user, writes the bundle

# 2. copy the bundle to the third host
scp -r ./observer_bundle_<PRIMARY_DB_UNIQUE_NAME> obs1:~/

# 3. on the THIRD host
cd ~/observer_bundle_<PRIMARY_DB_UNIQUE_NAME>
./02_setup_observer_host.sh      # TNS + wallet + connectivity proof
./03_observer_ctl.sh start
./04_verify_observer.sh
./03_observer_ctl.sh boot        # systemd unit + cron @reboot + watchdog
```

The generated bundle carries `RUN_ON_OBSERVER_HOST.md` - the same runbook with the
discovered values already substituted in - so the person working on the third host does
not need this document or a copy of the repository.

Add `--enable-fsfo` to script 01 to have it enable Fast-Start Failover as well; without
the flag it only prints the DGMGRL commands it would have run, so an existing FSFO
setup (or a change window) is never disturbed.

**Why a third host.** An observer on the standby host cannot distinguish "the primary is
down" from "the network between the sites is down", and an observer on the primary host
dies with the very failure it is supposed to react to. A third host - ideally in a third
location, or at least on separate power and network - is what makes the observer a
tie-breaker rather than a participant.

**Prerequisites on the third host:** an Oracle **Administrator**-type client or a full
database home. The Instant Client is not sufficient - it ships neither `dgmgrl` nor
`mkstore`, and script 02 refuses to continue on one. TCP to both databases' listener
ports must be open.

Design notes:

- **Discovery over assumption.** Each member's host, port, and service name come from
  running `tnsping` on the broker's `DGConnectIdentifier` for that member - that is what
  the databases themselves use to reach each other - with the broker `HostName` property
  and `V$LISTENER_NETWORK` as fallbacks. `--primary-host`, `--standby-host`, `--port`
  override anything discovery gets wrong.
- **The protection mode is never changed.** The FSFO flavour adapts to whatever is
  configured instead: `MAXIMUM AVAILABILITY` / `MAXIMUM PROTECTION` use
  `FastStartFailoverThreshold` (zero data loss); `MAXIMUM PERFORMANCE` uses
  `FastStartFailoverLagLimit`, which is asynchronous FSFO and **can lose transactions** -
  the script says so rather than silently upgrading the mode.
- **Both connections are proven before anything starts.** Script 02 aborts if the
  observer user cannot log in `AS SYSDG` to the *standby*, which is usually `ORA-01017`
  from a password file that was never propagated. An observer the standby rejects can
  watch a failure but cannot complete the failover.
- **Named observers** (12.2+) are used when available, falling back to the unnamed form
  if `START OBSERVER <name>` fails, rather than leaving no observer running at all.
- **Reboot survival is explicit.** A background observer is a detached `dgmgrl` process
  that nothing restarts. `03_observer_ctl.sh boot` prints a systemd unit
  (`Type=oneshot` + `RemainAfterExit=yes`, because the real observer is a detached
  child), a cron `@reboot` line, and a watchdog driven by `status` - which exits `0`
  only when the primary reports `FS_FAILOVER_OBSERVER_PRESENT=YES`.

**Rollback** is `03_observer_ctl.sh stop` (plus `DISABLE FAST_START FAILOVER` in DGMGRL
if script 01 enabled it). The databases keep running; only automatic failover goes away.

### Convert an FSFO Observer from SYS to SYSDG

**Directory:** `observer_sys_to_sysdg/` (see its own `README.md`)

For **existing** configurations - built by hand or by other tooling - where the observer
still authenticates as SYS. Moves it to a dedicated user holding only `SYSDG` +
`CREATE SESSION`. New builds through Step 9 + `fsfo/observer.sh` already have this
shape; this kit retrofits it.

| Script | Runs on | Does |
|--------|---------|------|
| `01_create_sysdg_user.sh` | PRIMARY | Creates/verifies the dedicated user with exactly `CREATE SESSION` + `SYSDG`. CDB-aware (auto-prefixes `C##`). Idempotent |
| `02_switch_observer_credentials.sh` | OBSERVER host | Replaces SYS credentials in the existing wallet (or creates one if the observer used `sys/password@alias` directly), tests both databases, then optionally restarts the observer under the new identity |
| `03_verify_conversion.sh` | anywhere | `SHOW CONFIGURATION` / `SHOW FAST_START FAILOVER` / `SHOW OBSERVER` + `V$DATABASE` observer columns + `V$PWFILE_USERS`. Exit `0` = observer present |

Why it matters: an observer running as SYS breaks on every SYS password rotation, holds
full SYSDBA power in a long-lived unattended process, and muddies the audit trail. No
dependency on `common/`, the NFS share, or `standby_config_*.env` - copy the one
directory to the hosts involved. All passwords are prompted at runtime, never accepted
via argv, env, or files.

Before starting, identify how the observer authenticates today:

```bash
# On the observer host
ps -eo args | grep -i dgmgrl | grep -iv grep
```

`dgmgrl /@alias START OBSERVER` means a wallet (which most likely holds SYS
credentials); anything else means credentials passed directly.

### Migrate a Non-CDB into a CDB, Keeping Both Standbys

**Directory:** `migrate_noncdb_to_pdb/` (own `README.md`, `WALKTHROUGH.md`,
`MINIMAL_STEPS.md`, and tests)

Migrates a non-CDB that has its own standby into an existing CDB that has its own
standby, **without recreating either standby**. Six numbered scripts
(`01_preflight.sh` through `06_decommission_noncdb.sh`), a `config.env.template`, and a
`run_minimal.sh` driver. Read that subproject's own docs before running any of it.

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
| 9 | Configure FSFO | Create observer user, set FASTSYNC, enable FSFO (optional) |
| 10 | Observer Setup | Create wallet, add credentials, start observer process (optional) |
| 11 | Service Trigger | Write PL/SQL package and triggers, deploy to database (optional) |
| 12 | NFS Cleanup | Track down and remove password file copies, pfiles, RMAN artifacts (optional) |
| 13 | Max Availability | Validate readiness, set FASTSYNC + MAXAVAILABILITY, verify (optional) |
| - | Handoff Report | Re-run every verification query, then hand-write a TNS/JDBC descriptor per service per flavor and keep it in sync (recommended) |
| - | Peer Wallet | `mkstore`/`orapki` per host, edit `sqlnet.ora`, test (recommended) |

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
- Dry-run mode (review changes before applying)
- Approval mode (gate every mutating action for high-security environments)

---

## Life After Setup: Adding Datafiles and PDBs

Step 2 captures `DB_FILE_NAME_CONVERT` / `LOG_FILE_NAME_CONVERT` pairs for the datafile directories that exist **at build time**. In Traditional (path-substitution) mode those pairs are the standby's only way to translate a primary-side file path into a local one - and `standby_file_management=AUTO` does not help for paths the pairs don't cover: `AUTO` creates files in *derivable* locations, it never invents a new directory mapping.

**OMF-mode standbys are immune to this entire section.** If the standby was built in OMF mode (`db_create_file_dest` set - the Step 2 storage-mode choice), every new file lands under the OMF destination regardless of its primary-side path, and the failure below cannot occur.

### Which Directories Are Safe

Any new datafile (or PDB) whose primary-side path starts with a prefix already covered by the standby's convert pairs replicates without intervention. Check the current pairs before adding files in a new location:

```sql
-- On the STANDBY
SELECT value FROM v$parameter WHERE name = 'db_file_name_convert';
```

```
-- Or via the broker
dgmgrl / "SHOW DATABASE '<standby_db_unique_name>' DbFileNameConvert;"
```

If the target directory is not under a covered prefix, either place the files under one that is, or extend the convert pairs first. Note that `DB_FILE_NAME_CONVERT` is not dynamic: changing it requires `SCOPE=SPFILE` and a standby restart (use the broker property `DbFileNameConvert`, then restart the standby instance), so plan this ahead of the datafile addition, not after apply has already broken.

### Creating a PDB Safely (CDB Builds)

`CREATE PLUGGABLE DATABASE` copies the seed (or clone source) files to a new directory on the primary - which is exactly the "new directory not covered at build time" case. Two safe options:

```sql
-- Option 1: per-statement FILE_NAME_CONVERT, keeping the target under a
-- directory prefix that the standby's convert pairs already cover
CREATE PLUGGABLE DATABASE newpdb ADMIN USER pdbadmin IDENTIFIED BY "..."
  FILE_NAME_CONVERT = ('/u02/oradata/PRIM/pdbseed/', '/u02/oradata/PRIM/newpdb/');

-- Option 2: PDB-level OMF - files are created under an OMF destination,
-- which the standby handles without any convert pair
CREATE PLUGGABLE DATABASE newpdb ADMIN USER pdbadmin IDENTIFIED BY "..."
  CREATE_FILE_DEST = '/u02/oradata';
```

(If `db_create_file_dest` is already set at the CDB level on both sides, plain `CREATE PLUGGABLE DATABASE` is safe too.)

### How the Failure Manifests

If a datafile is added on the primary in a directory no convert pair covers, redo apply on the standby cannot create it (often surfacing `ORA-01119: error in creating database file` for the missing directory). Instead, the standby registers a placeholder file named `UNNAMEDnnnnn` in `$ORACLE_HOME/dbs`, MRP stops with `ORA-01274: cannot add data file that was created as ...`, and **redo apply halts** - the standby silently falls behind until someone notices. To check:

```sql
-- On the STANDBY: placeholder files and files needing recovery
SELECT file#, name FROM v$datafile WHERE name LIKE '%UNNAMED%';
SELECT * FROM v$recover_file;
```

Also check the standby alert log for `ORA-01274` / `ORA-01119`. `dg_status.sh`, `dg_triage_sid.sh`, and `dg_diag_sid.sh` all flag UNNAMED datafiles as an error.

### The Repair

Standard 19c procedure, on the **standby**:

```
-- 1. Ensure redo apply is stopped (MRP has usually already died with
--    ORA-01274; make the state explicit via the broker)
dgmgrl / "EDIT DATABASE '<standby_db_unique_name>' SET STATE='APPLY-OFF';"
```

```sql
-- 2. Switch to manual file management (the CREATE DATAFILE below fails
--    with ORA-01275 while standby_file_management is AUTO)
ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT=MANUAL;

-- 3. Re-create each placeholder at its correct local path
--    (use the exact UNNAMED name from v$datafile)
ALTER DATABASE CREATE DATAFILE
  '/u01/app/oracle/product/19.0.0/dbhome_1/dbs/UNNAMED00012'
  AS '/u02/oradata/STBY/newpdb/users01.dbf';
--   On an OMF standby, use "AS NEW" instead of an explicit path.

-- 4. Back to automatic file management
ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT=AUTO;
```

```
-- 5. Restart redo apply
dgmgrl / "EDIT DATABASE '<standby_db_unique_name>' SET STATE='APPLY-ON';"
```

Then confirm apply catches up (`v$dataguard_stats`, `v$recover_file` now empty, `dg_status.sh` clean). If more than one file was added, repeat step 3 for every `UNNAMED` entry before restarting apply.

### Preventing It

- Prefer OMF mode for new standby builds when there is any chance of future PDBs or new datafile directories.
- On Traditional-mode builds, treat "new datafile directory on the primary" as a change that **first** requires extending the standby's `DbFileNameConvert` (broker property, `SCOPE=SPFILE`, standby restart).
- Run `dg_status.sh` (or the local triage tools) after any tablespace/PDB addition - they detect UNNAMED datafiles before the apply lag becomes an incident.

---

## Common Monitoring Commands

For day-to-day monitoring, prefer the packaged tools in
[Post-Setup Tooling](#post-setup-tooling) - `dg_status.sh` from a jump host,
`dg_triage_sid.sh` / `dg_diag_sid.sh` on a DB host. The raw commands below are the
building blocks, useful when those tools are not available or when you need one
specific answer:

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
