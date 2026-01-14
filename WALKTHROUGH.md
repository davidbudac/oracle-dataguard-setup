# Oracle 19c Data Guard Setup - Complete Walkthrough

A step-by-step guide for DBAs to set up a physical standby database using these automation scripts.

---

## Table of Contents

1. [What is Oracle Data Guard?](#1-what-is-oracle-data-guard)
2. [Architecture Overview](#2-architecture-overview)
3. [Prerequisites Checklist](#3-prerequisites-checklist)
4. [Understanding the Scripts](#4-understanding-the-scripts)
5. [Step-by-Step Setup](#5-step-by-step-setup)
   - [Step 1: Gather Primary Information](#step-1-gather-primary-information)
   - [Step 2: Generate Standby Configuration](#step-2-generate-standby-configuration)
   - [Step 3: Setup Standby Environment](#step-3-setup-standby-environment)
   - [Step 4: Prepare Primary for Data Guard](#step-4-prepare-primary-for-data-guard)
   - [Step 5: Clone the Standby Database](#step-5-clone-the-standby-database)
   - [Step 6: Verify Data Guard](#step-6-verify-data-guard)
6. [Post-Setup Operations](#6-post-setup-operations)
7. [Troubleshooting Guide](#7-troubleshooting-guide)
8. [Glossary](#8-glossary)

---

## 1. What is Oracle Data Guard?

Oracle Data Guard is a disaster recovery and high availability solution that maintains one or more synchronized copies (standby databases) of a production database (primary database).

### Why Use Data Guard?

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        BENEFITS OF DATA GUARD                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ✓ DISASTER RECOVERY     If primary fails, standby can take over       │
│                                                                         │
│  ✓ ZERO/MINIMAL DATA     Redo logs shipped continuously ensure         │
│    LOSS                  minimal or no data loss                        │
│                                                                         │
│  ✓ OFFLOAD REPORTING     Standby can be opened read-only for           │
│                          reports (Active Data Guard)                    │
│                                                                         │
│  ✓ PLANNED MAINTENANCE   Switchover allows role reversal for           │
│                          patching/upgrades                              │
│                                                                         │
│  ✓ DATA PROTECTION       Protection against corruption, user           │
│                          errors, and site failures                      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### How Does It Work?

```
┌─────────────────────┐                      ┌─────────────────────┐
│   PRIMARY SERVER    │                      │   STANDBY SERVER    │
│                     │                      │                     │
│  ┌───────────────┐  │    Redo Transport    │  ┌───────────────┐  │
│  │   Primary     │  │  ─────────────────►  │  │   Standby     │  │
│  │   Database    │  │    (Network)         │  │   Database    │  │
│  │               │  │                      │  │               │  │
│  │  ┌─────────┐  │  │                      │  │  ┌─────────┐  │  │
│  │  │ Redo    │  │  │   Archive Logs       │  │  │ Redo    │  │  │
│  │  │ Logs    │──┼──┼──────────────────►───┼──┼──│ Apply   │  │  │
│  │  └─────────┘  │  │                      │  │  └─────────┘  │  │
│  │               │  │                      │  │               │  │
│  └───────────────┘  │                      │  └───────────────┘  │
│                     │                      │                     │
└─────────────────────┘                      └─────────────────────┘
        │                                            │
        │           1. Transaction commits           │
        │           2. Redo generated                │
        │           3. Redo shipped to standby       │
        │           4. Standby applies redo          │
        │           5. Databases stay synchronized   │
        ▼                                            ▼
```

**In simple terms:**
1. When you make changes to the primary database, Oracle records these changes in "redo logs"
2. These redo logs are automatically sent to the standby database over the network
3. The standby database applies these changes to stay synchronized
4. If the primary fails, the standby can be activated to take over

---

## 2. Architecture Overview

### Our Setup Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│                          DATA GUARD ARCHITECTURE                            │
│                                                                             │
│   ┌─────────────────────┐              ┌─────────────────────┐              │
│   │   PRIMARY SERVER    │              │   STANDBY SERVER    │              │
│   │                     │              │                     │              │
│   │   ┌─────────────┐   │              │   ┌─────────────┐   │              │
│   │   │  Database   │   │              │   │  Database   │   │              │
│   │   │  (PROD)     │   │   ◄──────►   │   │  (PRODSTBY) │   │              │
│   │   └─────────────┘   │   Network    │   └─────────────┘   │              │
│   │                     │              │                     │              │
│   │   ┌─────────────┐   │              │   ┌─────────────┐   │              │
│   │   │  Listener   │   │              │   │  Listener   │   │              │
│   │   │  (1521)     │   │              │   │  (1521)     │   │              │
│   │   └─────────────┘   │              │   └─────────────┘   │              │
│   │                     │              │                     │              │
│   └──────────┬──────────┘              └──────────┬──────────┘              │
│              │                                    │                         │
│              │         ┌──────────────────┐       │                         │
│              │         │                  │       │                         │
│              └────────►│   NFS SHARE      │◄──────┘                         │
│                        │ /OINSTALL/       │                                 │
│                        │ _dataguard_setup │                                 │
│                        │                  │                                 │
│                        │ - Config files   │                                 │
│                        │ - Password file  │                                 │
│                        │ - Log files      │                                 │
│                        │                  │                                 │
│                        └──────────────────┘                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key Concepts

| Term | Description |
|------|-------------|
| **Primary Database** | Your production database that handles all transactions |
| **Standby Database** | A synchronized copy that receives and applies redo data |
| **Redo Logs** | Records of all changes made to the database |
| **Archive Logs** | Redo logs that have been archived (saved) for recovery |
| **DB_UNIQUE_NAME** | Unique identifier for each database in Data Guard |
| **TNS** | Oracle's network naming service for database connections |
| **RMAN** | Recovery Manager - Oracle's backup and recovery tool |
| **MRP** | Managed Recovery Process - applies redo on standby |

---

## 3. Prerequisites Checklist

Before starting, ensure all prerequisites are met:

### On PRIMARY Server

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      PRIMARY SERVER CHECKLIST                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  □  Oracle 19c database is installed and running                        │
│                                                                         │
│  □  Database is in ARCHIVELOG mode                                      │
│      Check: SELECT LOG_MODE FROM V$DATABASE;                            │
│      Expected: ARCHIVELOG                                               │
│                                                                         │
│  □  FORCE LOGGING is enabled (recommended)                              │
│      Check: SELECT FORCE_LOGGING FROM V$DATABASE;                       │
│      Expected: YES                                                      │
│                                                                         │
│  □  Password file exists                                                │
│      Location: $ORACLE_HOME/dbs/orapw<SID>                              │
│                                                                         │
│  □  REMOTE_LOGIN_PASSWORDFILE = EXCLUSIVE                               │
│      Check: SHOW PARAMETER REMOTE_LOGIN_PASSWORDFILE                    │
│                                                                         │
│  □  NFS mount is accessible at /OINSTALL/_dataguard_setup               │
│                                                                         │
│  □  Oracle environment variables are set (ORACLE_HOME, ORACLE_SID)      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### On STANDBY Server

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      STANDBY SERVER CHECKLIST                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  □  Oracle 19c software is installed (same version as primary)          │
│      Note: Database does NOT need to exist - we will create it          │
│                                                                         │
│  □  ORACLE_HOME matches primary server                                  │
│                                                                         │
│  □  Sufficient disk space for database files                            │
│      Tip: Check primary data file sizes first                           │
│                                                                         │
│  □  NFS mount is accessible at /OINSTALL/_dataguard_setup               │
│                                                                         │
│  □  Network connectivity to primary server (port 1521)                  │
│                                                                         │
│  □  Oracle user can create directories in data file locations           │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Quick Prerequisite Checks

Run these commands on the **PRIMARY** to verify prerequisites:

```bash
# Connect as oracle user
sqlplus / as sysdba

-- Check ARCHIVELOG mode (must be ARCHIVELOG)
SELECT LOG_MODE FROM V$DATABASE;

-- Check FORCE LOGGING (should be YES)
SELECT FORCE_LOGGING FROM V$DATABASE;

-- Check password file setting (must be EXCLUSIVE)
SHOW PARAMETER REMOTE_LOGIN_PASSWORDFILE;

-- Check if password file exists (run in shell)
ls -la $ORACLE_HOME/dbs/orapw$ORACLE_SID
```

**If database is NOT in ARCHIVELOG mode**, enable it:

```sql
-- CAUTION: This requires a database restart
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;

-- Verify
SELECT LOG_MODE FROM V$DATABASE;
```

**If FORCE LOGGING is not enabled:**

```sql
ALTER DATABASE FORCE LOGGING;
```

---

## 4. Understanding the Scripts

### Script Execution Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SCRIPT EXECUTION FLOW                             │
└─────────────────────────────────────────────────────────────────────────────┘

    PRIMARY SERVER                              STANDBY SERVER
    ══════════════                              ══════════════

    ┌─────────────────────┐
    │ STEP 1              │
    │ 01_gather_primary   │
    │ _info.sh            │
    │                     │
    │ • Collects DB info  │
    │ • Checks prereqs    │
    │ • Copies pwd file   │
    └─────────┬───────────┘
              │
              │  Writes to NFS:
              │  • primary_info.env
              │  • orapw<SID>
              ▼
    ┌─────────────────────┐
    │ STEP 2              │
    │ 02_generate_standby │
    │ _config.sh          │
    │                     │
    │ • Prompts for       │
    │   standby info      │
    │ • Generates config  │
    │ • USER REVIEWS      │
    └─────────┬───────────┘
              │
              │  Writes to NFS:
              │  • standby_config.env  ◄── SINGLE SOURCE OF TRUTH
              │  • init<SID>.ora
              │  • tnsnames_entries.ora
              │  • listener_standby.ora
              │
              ├─────────────────────────────────┐
              │                                 │
              │                                 ▼
              │                     ┌─────────────────────┐
              │                     │ STEP 3              │
              │                     │ 03_setup_standby    │
              │                     │ _env.sh             │
              │                     │                     │
              │                     │ • Creates dirs      │
              │                     │ • Copies pwd file   │
              │                     │ • Configures        │
              │                     │   listener/tns      │
              │                     └─────────┬───────────┘
              │                               │
              ▼                               │
    ┌─────────────────────┐                   │
    │ STEP 4              │                   │
    │ 04_prepare_primary  │                   │
    │ _dg.sh              │                   │
    │                     │                   │
    │ • Adds standby      │                   │
    │   redo logs         │                   │
    │ • Enables DG Broker │                   │
    │ • Configures tns    │                   │
    └─────────────────────┘                   │
                                              │
              ┌───────────────────────────────┘
              │
              ▼
    ┌─────────────────────┐
    │ STEP 5              │
    │ 05_clone_standby.sh │
    │                     │
    │ • RMAN duplicate    │
    │ • Creates standby   │
    │ • Starts recovery   │
    └─────────────────────┘
              │
              │
    ┌─────────┴───────────┐
    │ STEP 6              │
    │ 06_configure        │
    │ _broker.sh          │
    │ (on PRIMARY)        │
    │                     │
    │ • Creates DG config │
    │ • Adds databases    │
    │ • Enables broker    │
    └─────────┬───────────┘
              │
              ▼
    ┌─────────────────────┐
    │ STEP 7              │
    │ 07_verify           │
    │ _dataguard.sh       │
    │                     │
    │ • Validates setup   │
    │ • DGMGRL status     │
    └─────────────────────┘
```

### What Each Script Does

| Script | Location | Purpose |
|--------|----------|---------|
| `01_gather_primary_info.sh` | primary/ | Collects all database information from primary and validates prerequisites |
| `02_generate_standby_config.sh` | common/ | Creates the master configuration file - **this is where you review and approve settings** |
| `03_setup_standby_env.sh` | standby/ | Prepares the standby server (directories, files, network config) |
| `04_prepare_primary_dg.sh` | primary/ | Enables DG Broker, creates standby redo logs, configures tnsnames |
| `05_clone_standby.sh` | standby/ | Performs the actual database duplication using RMAN |
| `06_configure_broker.sh` | primary/ | Creates and enables Data Guard Broker configuration using DGMGRL |
| `07_verify_dataguard.sh` | standby/ | Validates the Data Guard setup using DGMGRL and reports status |

---

## 5. Step-by-Step Setup

### Step 1: Gather Primary Information

**Server:** PRIMARY
**Script:** `./primary/01_gather_primary_info.sh`

#### What This Step Does

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     STEP 1: GATHER PRIMARY INFO                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  This script connects to your primary database and collects:            │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  DATABASE IDENTITY                                               │   │
│  │  • DB_NAME (e.g., PROD)                                          │   │
│  │  • DB_UNIQUE_NAME (e.g., PROD)                                   │   │
│  │  • DBID (unique database identifier)                             │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  STORAGE CONFIGURATION                                           │   │
│  │  • Data file locations                                           │   │
│  │  • Redo log locations and sizes                                  │   │
│  │  • Archive log destination                                       │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  PREREQUISITES CHECK                                             │   │
│  │  • ARCHIVELOG mode enabled?                                      │   │
│  │  • FORCE LOGGING enabled?                                        │   │
│  │  • Password file exists?                                         │   │
│  │  • Standby redo logs exist?                                      │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Instructions

1. **Log in to the PRIMARY server** as the `oracle` user

2. **Set Oracle environment variables:**
   ```bash
   export ORACLE_SID=PROD          # Replace with your SID
   export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1  # Your Oracle home
   export PATH=$ORACLE_HOME/bin:$PATH
   ```

3. **Navigate to the scripts directory:**
   ```bash
   cd /path/to/dataguard_setup
   ```

4. **Run the script:**
   ```bash
   ./primary/01_gather_primary_info.sh
   ```

#### Expected Output

```
============================================================
     Oracle Data Guard Setup - Step 1: Gather Primary Info
============================================================

============================================================
Pre-flight Checks
============================================================

[INFO] 2024-01-15 10:30:00 - Checking Oracle environment variables...
[INFO] 2024-01-15 10:30:00 - ORACLE_HOME: /u01/app/oracle/product/19.0.0/dbhome_1
[INFO] 2024-01-15 10:30:00 - ORACLE_SID: PROD
[INFO] 2024-01-15 10:30:00 - Checking NFS mount at /OINSTALL/_dataguard_setup...
[INFO] 2024-01-15 10:30:00 - NFS share is accessible and writable
[INFO] 2024-01-15 10:30:00 - Checking database connection...
[INFO] 2024-01-15 10:30:00 - Successfully connected to database

============================================================
Gathering Database Identity Information
============================================================

[INFO] 2024-01-15 10:30:01 - DB_NAME: PROD
[INFO] 2024-01-15 10:30:01 - DB_UNIQUE_NAME: PROD
[INFO] 2024-01-15 10:30:01 - DBID: 1234567890

... (more output) ...

============================================================
Data Guard Prerequisites Check
============================================================

[INFO] 2024-01-15 10:30:05 - PASS: Database is in ARCHIVELOG mode
[INFO] 2024-01-15 10:30:05 - PASS: FORCE_LOGGING is enabled
[INFO] 2024-01-15 10:30:05 - PASS: REMOTE_LOGIN_PASSWORDFILE is EXCLUSIVE
[INFO] 2024-01-15 10:30:05 - PASS: Password file exists

============================================================
SUCCESS: Primary information gathered successfully
============================================================

Output files:
  - Primary info: /OINSTALL/_dataguard_setup/primary_info.env
  - Password file: /OINSTALL/_dataguard_setup/orapwPROD

Next step: Run 02_generate_standby_config.sh to generate standby configuration
```

#### If Prerequisites Fail

If you see errors like these, fix them before proceeding:

| Error | Solution |
|-------|----------|
| "Database is NOT in ARCHIVELOG mode" | Enable archivelog mode (see Prerequisites section) |
| "FORCE_LOGGING is not enabled" | Run: `ALTER DATABASE FORCE LOGGING;` |
| "Password file not found" | Create it: `orapwd file=$ORACLE_HOME/dbs/orapw$ORACLE_SID password=<sys_password>` |

---

### Step 2: Generate Standby Configuration

**Server:** PRIMARY (or any server with NFS access)
**Script:** `./common/02_generate_standby_config.sh`

#### What This Step Does

This is the most important step - it creates the **single source of truth** configuration file that all other scripts will use.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                  STEP 2: GENERATE STANDBY CONFIGURATION                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  INPUT: You will be prompted for:                                       │
│                                                                         │
│    ┌───────────────────────────────────────────────────────────────┐   │
│    │  1. Standby server hostname                                    │   │
│    │     Example: standby-server.example.com                        │   │
│    │                                                                │   │
│    │  2. Standby DB_UNIQUE_NAME                                     │   │
│    │     Example: PRODSTBY (must be different from primary)         │   │
│    │                                                                │   │
│    │  3. Standby ORACLE_SID (optional, defaults to primary SID)     │   │
│    │     Example: PROD                                              │   │
│    └───────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  OUTPUT: Generated configuration files on NFS:                          │
│                                                                         │
│    • standby_config.env    - Master configuration (all variables)       │
│    • init<SID>.ora         - Standby parameter file                     │
│    • tnsnames_entries.ora  - Network configuration entries              │
│    • listener_standby.ora  - Listener configuration for standby         │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Understanding DB_UNIQUE_NAME

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    DB_NAME vs DB_UNIQUE_NAME                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  DB_NAME: The name of your database (same on primary AND standby)       │
│           Example: PROD                                                 │
│                                                                         │
│  DB_UNIQUE_NAME: A unique identifier for EACH database in Data Guard    │
│                  This MUST be different on primary and standby          │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                                                                  │   │
│  │   PRIMARY                          STANDBY                       │   │
│  │   ════════                          ═══════                      │   │
│  │   DB_NAME = PROD                   DB_NAME = PROD                │   │
│  │   DB_UNIQUE_NAME = PROD            DB_UNIQUE_NAME = PRODSTBY     │   │
│  │                                                                  │   │
│  │          ▲                                  ▲                    │   │
│  │          │                                  │                    │   │
│  │       Same!                             Different!               │   │
│  │                                                                  │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  Common naming conventions:                                             │
│  • PROD / PRODSTBY                                                      │
│  • PROD / PROD_DR                                                       │
│  • ORCL / ORCLSBY                                                       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Instructions

1. **Run the script:**
   ```bash
   ./common/02_generate_standby_config.sh
   ```

2. **Answer the prompts:**
   ```
   Please provide the following information for the standby database:

   Standby server hostname: standby-server.example.com

   The standby DB_UNIQUE_NAME must be different from primary (PROD)
   Standby DB_UNIQUE_NAME: PRODSTBY

   The standby ORACLE_SID (default: PROD)
   Standby ORACLE_SID [PROD]: <press Enter to accept default>
   ```

3. **Review the generated configuration:**

   The script will display a summary like this:

   ```
   ================================================================
                    STANDBY CONFIGURATION SUMMARY
   ================================================================

   PRIMARY DATABASE:
     Hostname:        primary-server.example.com
     DB_UNIQUE_NAME:  PROD
     ORACLE_SID:      PROD
     TNS Alias:       PROD
     Data Path:       /u01/oradata/PROD

   STANDBY DATABASE:
     Hostname:        standby-server.example.com
     DB_UNIQUE_NAME:  PRODSTBY
     ORACLE_SID:      PROD
     TNS Alias:       PRODSTBY
     Data Path:       /u01/oradata/PRODSTBY

   PATH CONVERSIONS:
     DB_FILE_NAME_CONVERT:  '/u01/oradata/PROD','/u01/oradata/PRODSTBY'
     LOG_FILE_NAME_CONVERT: '/u01/oradata/PROD','/u01/oradata/PRODSTBY'

   ================================================================

   Please review the configuration above.
   Do you want to proceed? [y/N]:
   ```

4. **Verify the path conversions are correct!**

   This is crucial - the `DB_FILE_NAME_CONVERT` and `LOG_FILE_NAME_CONVERT` tell Oracle how to translate primary paths to standby paths.

5. **Type `y` to accept** or `n` to cancel and re-run with different values.

#### Generated Files Explained

| File | Purpose |
|------|---------|
| `standby_config.env` | Contains all variables - source this file to get configuration |
| `init<SID>.ora` | Standby database parameter file - will be placed in $ORACLE_HOME/dbs/ |
| `tnsnames_entries.ora` | TNS entries to add to tnsnames.ora on both servers |
| `listener_standby.ora` | Listener configuration to add on standby server |

---

### Step 3: Setup Standby Environment

**Server:** STANDBY
**Script:** `./standby/03_setup_standby_env.sh`

#### What This Step Does

```
┌─────────────────────────────────────────────────────────────────────────┐
│                   STEP 3: SETUP STANDBY ENVIRONMENT                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  This script prepares the standby server:                               │
│                                                                         │
│  1. CREATE DIRECTORIES                                                  │
│     ┌──────────────────────────────────────────────────────────────┐   │
│     │  /u01/oradata/PRODSTBY/           ← Data files will go here  │   │
│     │  /u01/app/oracle/admin/PRODSTBY/  ← Admin directory          │   │
│     │    ├── adump/                     ← Audit files              │   │
│     │    ├── bdump/                     ← Background dumps         │   │
│     │    ├── cdump/                     ← Core dumps               │   │
│     │    └── udump/                     ← User dumps               │   │
│     │  /u01/archive/PRODSTBY/           ← Archive logs             │   │
│     └──────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  2. COPY FILES FROM NFS                                                 │
│     • Password file → $ORACLE_HOME/dbs/orapw<SID>                       │
│     • Parameter file → $ORACLE_HOME/dbs/init<SID>.ora                   │
│                                                                         │
│  3. CONFIGURE LISTENER                                                  │
│     • Add static registration (required for RMAN duplicate)             │
│     • Start/reload listener                                             │
│                                                                         │
│  4. CONFIGURE TNSNAMES                                                  │
│     • Add entries for primary and standby                               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Why Static Listener Registration?

```
┌─────────────────────────────────────────────────────────────────────────┐
│               STATIC vs DYNAMIC LISTENER REGISTRATION                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  DYNAMIC REGISTRATION (Normal):                                         │
│  • Database registers itself with listener when OPEN                    │
│  • Listener knows about database automatically                          │
│                                                                         │
│  STATIC REGISTRATION (Required for RMAN duplicate):                     │
│  • Entry manually added to listener.ora                                 │
│  • Works even when database is NOT open (NOMOUNT state)                 │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                                                                   │  │
│  │   RMAN Duplicate Process:                                         │  │
│  │                                                                   │  │
│  │   1. Standby starts in NOMOUNT ← Database is NOT open             │  │
│  │   2. RMAN connects to standby  ← Needs static registration!       │  │
│  │   3. Files are copied          │                                  │  │
│  │   4. Database is restored      │                                  │  │
│  │   5. Database opens            ← Dynamic registration works now   │  │
│  │                                                                   │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Instructions

1. **Log in to the STANDBY server** as the `oracle` user

2. **Set Oracle environment variables:**
   ```bash
   export ORACLE_SID=PROD          # Same as primary SID (unless you specified different)
   export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
   export PATH=$ORACLE_HOME/bin:$PATH
   ```

3. **Navigate to the scripts directory:**
   ```bash
   cd /path/to/dataguard_setup
   ```

4. **Run the script:**
   ```bash
   ./standby/03_setup_standby_env.sh
   ```

#### Expected Output

```
============================================================
     Oracle Data Guard Setup - Step 3: Setup Standby Environment
============================================================

[INFO] Loading standby configuration...
[INFO] Current hostname: standby-server.example.com
[INFO] Expected standby hostname: standby-server.example.com

============================================================
Creating Directory Structure
============================================================

[INFO] Creating directory: /u01/app/oracle/admin/PRODSTBY/adump
[INFO] Creating directory: /u01/app/oracle/admin/PRODSTBY/bdump
[INFO] Creating directory: /u01/oradata/PRODSTBY
[INFO] Creating directory: /u01/archive/PRODSTBY
[INFO] Directory structure created successfully

============================================================
Copying Password File
============================================================

[INFO] Password file copied to: /u01/app/oracle/product/19.0.0/dbhome_1/dbs/orapwPROD

============================================================
Configuring Listener
============================================================

[INFO] Adding SID_LIST_LISTENER to listener.ora
[INFO] Listener entry added successfully

============================================================
Starting Listener
============================================================

[INFO] Listener is running, reloading...
LSNRCTL> reload
The command completed successfully

============================================================
SUCCESS: Standby environment setup complete
============================================================

NEXT STEPS:
===========

1. On PRIMARY server:
   Run: ./04_prepare_primary_dg.sh

2. Then return to STANDBY and run:
   ./05_clone_standby.sh
```

#### Verify Listener Configuration

After the script completes, verify the listener is configured correctly:

```bash
lsnrctl status
```

You should see output including:

```
Service "PRODSTBY" has 1 instance(s).
  Instance "PROD", status UNKNOWN, has 1 handler(s) for this service...
```

The status `UNKNOWN` indicates static registration (this is expected and correct).

---

### Step 4: Prepare Primary for Data Guard

**Server:** PRIMARY
**Script:** `./primary/04_prepare_primary_dg.sh`

#### What This Step Does

```
┌─────────────────────────────────────────────────────────────────────────┐
│                 STEP 4: PREPARE PRIMARY FOR DATA GUARD                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  This script configures the primary database:                           │
│                                                                         │
│  1. CONFIGURE TNSNAMES                                                  │
│     • Adds entry for standby database                                   │
│     • Enables primary to connect to standby                             │
│                                                                         │
│  2. CREATE STANDBY REDO LOGS (if not present)                           │
│     ┌──────────────────────────────────────────────────────────────┐   │
│     │  Standby redo logs are used to receive redo from primary     │   │
│     │  during switchover/failover operations.                      │   │
│     │                                                              │   │
│     │  Rule: Number of standby redo log groups =                   │   │
│     │        Number of online redo log groups + 1                  │   │
│     │                                                              │   │
│     │  Example: If you have 3 online redo log groups,              │   │
│     │           create 4 standby redo log groups                   │   │
│     └──────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  3. ENABLE DATA GUARD BROKER                                            │
│     • Sets DG_BROKER_START=TRUE                                         │
│     • Starts DMON (Data Guard Monitor) process                          │
│     • Note: DG parameters will be set by DGMGRL in Step 6               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### About Data Guard Broker

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      DATA GUARD BROKER (DGMGRL)                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Data Guard Broker is Oracle's centralized management framework for     │
│  Data Guard configurations. Instead of manually setting parameters      │
│  like LOG_ARCHIVE_DEST_2, FAL_SERVER, etc., the broker manages them     │
│  automatically.                                                         │
│                                                                         │
│  BENEFITS OF USING BROKER:                                              │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  • Centralized management - one place to configure everything    │  │
│  │  • Automatic parameter management - no manual ALTER SYSTEM       │  │
│  │  • Easy switchover/failover - single command operations          │  │
│  │  • Health monitoring - continuous validation of configuration    │  │
│  │  • Consistent configuration - prevents parameter mismatches      │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  KEY COMPONENTS:                                                        │
│                                                                         │
│  DG_BROKER_START=TRUE                                                   │
│  └──────────────────┘                                                   │
│    Enables the Data Guard Broker on this database                       │
│                                                                         │
│  DMON Process                                                           │
│  └───────────┘                                                          │
│    Data Guard Monitor - background process that manages DG              │
│                                                                         │
│  DGMGRL (Command-line tool)                                             │
│  └─────────────────────────┘                                            │
│    Used to create configuration, add databases, enable/disable          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Instructions

1. **On the PRIMARY server**, run:
   ```bash
   ./primary/04_prepare_primary_dg.sh
   ```

#### Expected Output

```
============================================================
     Oracle Data Guard Setup - Step 4: Prepare Primary for DG
============================================================

============================================================
Configuring TNS Names on Primary
============================================================

[INFO] Adding TNS entries to tnsnames.ora
[INFO] TNS entries added successfully

============================================================
Checking Force Logging
============================================================

[INFO] FORCE LOGGING is already enabled

============================================================
Checking Standby Redo Logs
============================================================

[INFO] Current standby redo groups: 0
[INFO] Required standby redo groups: 4
[INFO] Creating standby redo logs...
[INFO] Creating standby redo log group 4: /u01/oradata/PROD/standby_redo4.log
[INFO] Creating standby redo log group 5: /u01/oradata/PROD/standby_redo5.log
[INFO] Creating standby redo log group 6: /u01/oradata/PROD/standby_redo6.log
[INFO] Creating standby redo log group 7: /u01/oradata/PROD/standby_redo7.log
[INFO] Standby redo logs created successfully

============================================================
Enabling Data Guard Broker
============================================================

[INFO] Current DG_BROKER_START: FALSE
[INFO] Enabling DG_BROKER_START...
[INFO] DG_BROKER_START enabled
[INFO] Waiting for Data Guard Broker processes to start...
[INFO] Data Guard Broker process (DMON) is running
[INFO] Setting STANDBY_FILE_MANAGEMENT=AUTO...
[INFO] Data Guard Broker enabled successfully
[INFO] Note: LOG_ARCHIVE_DEST_2, FAL_SERVER, etc. will be configured by DGMGRL

============================================================
Verifying Network Connectivity
============================================================

[INFO] Testing tnsping to standby (PRODSTBY)...
[INFO] tnsping PRODSTBY successful

============================================================
SUCCESS: Primary configured for Data Guard
============================================================

NEXT STEPS:
===========

On STANDBY server:
   Run: ./standby/05_clone_standby.sh

After cloning, run the broker configuration:
   ./primary/06_configure_broker.sh
```

#### Verify Configuration

You can verify the settings with:

```sql
-- Connect to primary
sqlplus / as sysdba

-- Check Data Guard Broker is enabled
SHOW PARAMETER DG_BROKER_START;

-- Check standby redo logs
SELECT GROUP#, BYTES/1024/1024 AS SIZE_MB, STATUS FROM V$STANDBY_LOG;
```

---

### Step 5: Clone the Standby Database

**Server:** STANDBY
**Script:** `./standby/05_clone_standby.sh`

#### What This Step Does

This is the main step that creates the standby database using RMAN (Recovery Manager).

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    STEP 5: CLONE STANDBY DATABASE                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  RMAN DUPLICATE FOR STANDBY FROM ACTIVE DATABASE:                       │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                                                                   │  │
│  │   PRIMARY                              STANDBY                    │  │
│  │   ════════                              ═══════                   │  │
│  │                                                                   │  │
│  │   ┌─────────┐                          ┌─────────┐               │  │
│  │   │ RMAN    │◄─── TARGET connection ───│ RMAN    │               │  │
│  │   │ Channel │                          │         │               │  │
│  │   └────┬────┘                          └────┬────┘               │  │
│  │        │                                    │                    │  │
│  │        │  1. Read data files                │                    │  │
│  │        ├──────────────────────────────────►│                    │  │
│  │        │  2. Transfer over network          │                    │  │
│  │        │                                    │                    │  │
│  │        │                                    ▼                    │  │
│  │        │                          3. Write to standby            │  │
│  │        │                             data files                  │  │
│  │        │                                                         │  │
│  │   ┌─────────┐                          ┌─────────┐               │  │
│  │   │ Data    │                          │ Data    │               │  │
│  │   │ Files   │ ═══════════════════════► │ Files   │               │  │
│  │   └─────────┘    Network Transfer      └─────────┘               │  │
│  │                                                                   │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  This process:                                                          │
│  • Copies ALL data files from primary to standby                        │
│  • Creates control file for standby                                     │
│  • Recovers standby to current point in time                            │
│  • Sets up standby-specific parameters                                  │
│                                                                         │
│  Duration: Depends on database size (can take hours for large DBs)      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Instructions

1. **On the STANDBY server**, run:
   ```bash
   ./standby/05_clone_standby.sh
   ```

2. **Enter the SYS password** when prompted:
   ```
   Enter SYS password for primary database: <your password>
   ```

   > **Note:** This password is used to connect to both primary and standby databases. It is not stored anywhere.

3. **Wait for RMAN duplicate to complete**

   This step can take a significant amount of time depending on your database size:
   - Small DB (< 50 GB): ~15-30 minutes
   - Medium DB (50-500 GB): ~1-4 hours
   - Large DB (> 500 GB): Several hours

   You can monitor progress in the RMAN log file shown in the output.

#### Expected Output

```
============================================================
     Oracle Data Guard Setup - Step 5: Clone Standby Database
============================================================

============================================================
Pre-flight Checks
============================================================

[INFO] Loading standby configuration...
[INFO] Checking listener status...
[INFO] Listener is running with static registration

============================================================
Testing Network Connectivity
============================================================

[INFO] Testing tnsping to primary (PROD)...
[INFO] tnsping to primary successful
[INFO] Testing tnsping to standby (PRODSTBY)...
[INFO] tnsping to standby successful

============================================================
Authentication
============================================================

Enter SYS password for primary database: ********
[INFO] Verifying SYS password against primary...
[INFO] Password verified successfully

============================================================
Starting Standby Instance
============================================================

[INFO] Starting instance in NOMOUNT mode...

============================================================
Executing RMAN Duplicate
============================================================

================================================================
Starting RMAN duplicate from active database...
This process may take a while depending on database size.
================================================================

[INFO] RMAN script created: /OINSTALL/_dataguard_setup/logs/rman_duplicate_20240115_103500.rcv
[INFO] Starting RMAN duplicate (logging to: /OINSTALL/_dataguard_setup/logs/rman_duplicate_20240115_103500.log)...

... RMAN output (this takes time) ...

[INFO] RMAN duplicate completed successfully

============================================================
Starting Managed Recovery
============================================================

[INFO] Starting managed recovery process (MRP)...
[INFO] Managed Recovery Process (MRP) is running
[INFO] Status: MRP0:APPLYING_LOG

============================================================
Standby Database Status
============================================================

Database Role and Status:
DATABASE_ROLE    OPEN_MODE       PROTECTION_MODE     SWITCHOVER_STATUS
---------------- --------------- ------------------- -----------------
PHYSICAL STANDBY MOUNTED         MAXIMUM PERFORMANCE NOT ALLOWED

Managed Standby Processes:
PROCESS   STATUS          THREAD# SEQUENCE#    BLOCK#
--------- --------------- ------- ---------- --------
ARCH      CONNECTED             0          0        0
ARCH      CONNECTED             0          0        0
MRP0      APPLYING_LOG          1        145   102400
RFS       IDLE                  1        146        1

============================================================
SUCCESS: Standby database created successfully
============================================================

RMAN LOG: /OINSTALL/_dataguard_setup/logs/rman_duplicate_20240115_103500.log

NEXT STEPS:
===========

IMPORTANT: Configure Data Guard Broker to enable log shipping:

On PRIMARY server:
   Run: ./primary/06_configure_broker.sh

After broker configuration, verify the setup:
   Run: ./standby/07_verify_dataguard.sh

Note: Log shipping will not work until the broker is configured!
```

#### Understanding the Output

| Process | Status | Meaning |
|---------|--------|---------|
| `MRP0` | `APPLYING_LOG` | Managed Recovery Process is applying redo - this is good! |
| `RFS` | `IDLE` | Remote File Server waiting for redo from primary |
| `ARCH` | `CONNECTED` | Archiver process connected and ready |

---

### Step 6: Configure Data Guard Broker

**Server:** PRIMARY
**Script:** `./primary/06_configure_broker.sh`

#### What This Step Does

The Data Guard Broker (DGMGRL) provides centralized management of your Data Guard configuration.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                 STEP 6: CONFIGURE DATA GUARD BROKER                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Why use Data Guard Broker?                                             │
│  • Centralized management of primary and standby databases              │
│  • Automatic configuration of redo transport (LOG_ARCHIVE_DEST_2)       │
│  • Easy switchover and failover operations                              │
│  • Unified monitoring and health checks                                 │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                                                                   │  │
│  │   PRIMARY                              STANDBY                    │  │
│  │   ════════                              ═══════                   │  │
│  │                                                                   │  │
│  │   ┌─────────────────┐                  ┌─────────────────┐       │  │
│  │   │  DG Broker      │◄────────────────►│  DG Broker      │       │  │
│  │   │  (DMON process) │   Configuration  │  (DMON process) │       │  │
│  │   └────────┬────────┘   Sync           └────────┬────────┘       │  │
│  │            │                                    │                │  │
│  │            ▼                                    ▼                │  │
│  │   ┌─────────────────┐                  ┌─────────────────┐       │  │
│  │   │  Database       │ ════════════════►│  Database       │       │  │
│  │   │  Instance       │   Redo Transport │  Instance       │       │  │
│  │   └─────────────────┘                  └─────────────────┘       │  │
│  │                                                                   │  │
│  │   DGMGRL automatically configures:                                │  │
│  │   • LOG_ARCHIVE_DEST_2 (redo shipping)                            │  │
│  │   • FAL_SERVER (gap resolution)                                   │  │
│  │   • LOG_ARCHIVE_CONFIG                                            │  │
│  │                                                                   │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Instructions

1. **On the PRIMARY server**, run:
   ```bash
   ./primary/06_configure_broker.sh
   ```

2. **Review the configuration** shown in the output

#### Expected Output

```
============================================================
     Oracle Data Guard Setup - Step 6: Configure Data Guard Broker
============================================================

============================================================
Pre-flight Checks
============================================================

[INFO] Loading standby configuration...
[INFO] Primary DG_BROKER_START: TRUE
[INFO] DMON process is running on primary

============================================================
Verifying Network Connectivity
============================================================

[INFO] Testing tnsping to primary (PROD)...
[INFO] tnsping to primary successful
[INFO] Testing tnsping to standby (PRODSTBY)...
[INFO] tnsping to standby successful

============================================================
Creating Data Guard Broker Configuration
============================================================

[INFO] Configuration name: PROD_DG
[INFO] Primary database: PROD
[INFO] Standby database: PRODSTBY
[INFO] Creating broker configuration...
[INFO] Configuration created successfully
[INFO] Adding standby database to configuration...
[INFO] Standby database added successfully

============================================================
Enabling Data Guard Broker Configuration
============================================================

[INFO] Enabling configuration...
[INFO] Waiting for configuration to stabilize...

============================================================
Verifying Broker Configuration
============================================================

Data Guard Broker Configuration:
=================================

Configuration - PROD_DG

  Protection Mode: MaxPerformance
  Members:
  PROD     - Primary database
    PRODSTBY - Physical standby database

Fast-Start Failover: DISABLED

Configuration Status:
SUCCESS   (status updated 5 seconds ago)

Primary Database Details:
=========================

Database - PROD

  Role:               PRIMARY
  Intended State:     TRANSPORT-ON
  Instance(s):
    PROD

Database Status:
SUCCESS

Standby Database Details:
=========================

Database - PRODSTBY

  Role:               PHYSICAL STANDBY
  Intended State:     APPLY-ON
  Transport Lag:      0 seconds
  Apply Lag:          0 seconds
  Average Apply Rate: 1.00 KByte/s
  Real Time Query:    OFF
  Instance(s):
    PRODSTBY

Database Status:
SUCCESS

============================================================
Testing Log Shipping
============================================================

[INFO] Forcing log switch to test redo transport...
[INFO] Checking log shipping status...

============================================================
SUCCESS: Data Guard Broker configured successfully
============================================================

BROKER MANAGEMENT COMMANDS:
===========================

  # Show configuration status:
  dgmgrl / "show configuration"

  # Show database details:
  dgmgrl / "show database 'PROD'"
  dgmgrl / "show database 'PRODSTBY'"

  # Switchover to standby:
  dgmgrl / "switchover to 'PRODSTBY'"

  # Failover to standby (if primary is down):
  dgmgrl / "failover to 'PRODSTBY'"

NEXT STEPS:
===========

Run verification script:
   ./standby/07_verify_dataguard.sh
```

#### Understanding DGMGRL Output

| Field | Expected Value | Meaning |
|-------|----------------|---------|
| Configuration Status | SUCCESS | Broker is working correctly |
| Protection Mode | MaxPerformance | Async redo transport (no data loss vs. performance trade-off) |
| Primary Role | PRIMARY | Database is serving as primary |
| Standby Role | PHYSICAL STANDBY | Database is receiving and applying redo |
| Intended State | TRANSPORT-ON / APPLY-ON | Redo transport and apply are enabled |
| Transport Lag | 0 seconds | No delay in shipping redo |
| Apply Lag | 0 seconds (or low) | Standby is caught up |

#### Troubleshooting

| Issue | Solution |
|-------|----------|
| `ORA-16625: cannot reach database` | Check TNS connectivity and listener status |
| `ORA-16698: member has a LOG_ARCHIVE_DEST_n parameter conflict` | Broker needs exclusive control - let it manage destinations |
| Configuration shows WARNING | Run `SHOW DATABASE 'dbname' 'StatusReport'` for details |
| DMON process not running | Check `DG_BROKER_START=TRUE` and restart if needed |

---

### Step 7: Verify Data Guard

**Server:** STANDBY (or PRIMARY)
**Script:** `./standby/07_verify_dataguard.sh`

#### What This Step Does

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     STEP 7: VERIFY DATA GUARD                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  This script validates that Data Guard is working correctly:            │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  CHECKS PERFORMED                                                 │  │
│  │                                                                   │  │
│  │  ✓ Database role is PHYSICAL STANDBY                              │  │
│  │  ✓ Managed Recovery Process (MRP) is running                      │  │
│  │  ✓ No archive log gaps                                            │  │
│  │  ✓ Redo is being received from primary                            │  │
│  │  ✓ Redo is being applied                                          │  │
│  │  ✓ Network connectivity to primary                                │  │
│  │  ✓ Archive destinations are healthy                               │  │
│  │  ✓ Data Guard Broker configuration status                         │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  OUTPUT: Health report with status of each check                        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Instructions

1. **On the STANDBY server**, run:
   ```bash
   ./standby/07_verify_dataguard.sh
   ```

#### Expected Output (Healthy Configuration)

```
============================================================
     Oracle Data Guard Setup - Step 7: Verify Data Guard
============================================================

============================================================
Database Role and Status
============================================================

Database Configuration:
  Database Role:      PHYSICAL STANDBY
  Open Mode:          MOUNTED
  Protection Mode:    MAXIMUM PERFORMANCE
  Switchover Status:  NOT ALLOWED

[INFO] PASS: Database role is PHYSICAL STANDBY
[INFO] PASS: Database open mode is correct (MOUNTED)

============================================================
Managed Recovery Process (MRP)
============================================================

MRP Status:
  Process:   MRP0
  Status:    APPLYING_LOG
  Sequence:  147

[INFO] PASS: MRP is running and healthy

============================================================
Archive Log Gap Analysis
============================================================

[INFO] PASS: No archive log gaps detected

============================================================
Archive Log Apply Status
============================================================

Archive Log Sequences:
  Last Received:  148
  Last Applied:   147
  Apply Lag:      1 sequence(s)

[INFO] Minor apply lag: 1 sequence(s) - this is normal during activity

============================================================
Data Guard Broker Configuration
============================================================

Broker Configuration Status:

Configuration - PROD_DG

  Protection Mode: MaxPerformance
  Members:
  PROD     - Primary database
    PRODSTBY - Physical standby database

Fast-Start Failover: DISABLED

Configuration Status:
SUCCESS   (status updated 3 seconds ago)

Primary Database Status:

Database - PROD

  Role:               PRIMARY
  Intended State:     TRANSPORT-ON

Database Status:
SUCCESS

Standby Database Status:

Database - PRODSTBY

  Role:               PHYSICAL STANDBY
  Intended State:     APPLY-ON
  Transport Lag:      0 seconds
  Apply Lag:          0 seconds

Database Status:
SUCCESS

============================================================
Data Guard Health Summary
============================================================

================================================================
                 DATA GUARD HEALTH REPORT
================================================================

  Primary Database:     PROD @ primary-server.example.com
  Standby Database:     PRODSTBY @ standby-server.example.com

  Database Role:        PHYSICAL STANDBY
  Open Mode:            MOUNTED
  Protection Mode:      MAXIMUM PERFORMANCE

  MRP Status:           APPLYING_LOG
  Last Applied Seq:     147
  Archive Gaps:         0

  Errors:               0
  Warnings:             0

  OVERALL STATUS: HEALTHY

============================================================
SUCCESS: Data Guard configuration is healthy
============================================================
```

#### Reading the Health Report

| Field | Expected Value | Meaning |
|-------|----------------|---------|
| Database Role | PHYSICAL STANDBY | Correct role for standby |
| Open Mode | MOUNTED | Normal for physical standby (or READ ONLY with Active Data Guard) |
| Protection Mode | MAXIMUM PERFORMANCE | Our configured mode (async redo transport) |
| MRP Status | APPLYING_LOG or WAIT_FOR_LOG | MRP is actively applying redo |
| Archive Gaps | 0 | No missing archive logs |
| Apply Lag | 0-5 sequences | Normal lag during activity |

---

## 6. Post-Setup Operations

### Testing Log Shipping

To verify redo is being shipped and applied, force a log switch on the primary:

```sql
-- On PRIMARY
ALTER SYSTEM SWITCH LOGFILE;
```

Then check on standby:

```sql
-- On STANDBY
SELECT PROCESS, STATUS, SEQUENCE# FROM V$MANAGED_STANDBY;
```

The `SEQUENCE#` should increment.

### Monitoring Commands

#### Using DGMGRL (Recommended)

```bash
# Show overall configuration status
dgmgrl / "show configuration"

# Show detailed status of a database
dgmgrl / "show database 'PROD'"
dgmgrl / "show database 'PRODSTBY'"

# Validate configuration (comprehensive check)
dgmgrl / "validate database 'PRODSTBY'"

# Show lag information
dgmgrl / "show database 'PRODSTBY' 'TransportLag'"
dgmgrl / "show database 'PRODSTBY' 'ApplyLag'"
```

#### Using SQL

```sql
-- Check apply lag (on standby)
SELECT NAME, VALUE, TIME_COMPUTED
FROM V$DATAGUARD_STATS
WHERE NAME LIKE '%lag%';

-- Check for gaps (on standby)
SELECT * FROM V$ARCHIVE_GAP;

-- Check last applied log (on standby)
SELECT MAX(SEQUENCE#) AS LAST_APPLIED
FROM V$ARCHIVED_LOG
WHERE APPLIED = 'YES';

-- Check shipped logs (on primary)
SELECT DEST_ID, STATUS, DESTINATION, ERROR
FROM V$ARCHIVE_DEST
WHERE DEST_ID = 2;
```

### Opening Standby for Read-Only (Active Data Guard)

If you have Active Data Guard license, you can open the standby for queries:

```sql
-- On STANDBY
-- First, cancel managed recovery
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;

-- Open read only
ALTER DATABASE OPEN READ ONLY;

-- Restart managed recovery (will apply redo while open)
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
```

### Switchover (Planned Role Reversal)

A switchover is a planned role reversal where primary becomes standby and vice versa:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         SWITCHOVER PROCESS                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  BEFORE:                           AFTER:                               │
│                                                                         │
│  PRIMARY ───────► STANDBY          STANDBY ───────► PRIMARY             │
│  (PROD)          (PRODSTBY)        (PROD)          (PRODSTBY)           │
│                                                                         │
│  Use cases:                                                             │
│  • Planned maintenance on primary server                                │
│  • Testing failover capability                                          │
│  • Upgrading primary server                                             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

With Data Guard Broker, switchover is simple:

```bash
# Check if switchover is possible
dgmgrl / "validate database 'PRODSTBY'"

# Perform switchover (from either server)
dgmgrl / "switchover to 'PRODSTBY'"
```

The broker will:
1. Verify all redo has been applied
2. Convert primary to standby
3. Convert standby to primary
4. Update all parameters automatically

### Failover (Unplanned)

If the primary is unavailable, you can fail over to the standby:

```bash
# Failover (use only when primary is down!)
dgmgrl / "failover to 'PRODSTBY'"
```

> **Warning:** Failover may result in data loss in Maximum Performance mode. After failover, the old primary must be reinstated or rebuilt.

---

## 7. Troubleshooting Guide

### Common Issues and Solutions

#### Issue: "tnsping fails to standby"

```
┌─────────────────────────────────────────────────────────────────────────┐
│  SYMPTOM: tnsping PRODSTBY fails                                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  POSSIBLE CAUSES:                                                       │
│                                                                         │
│  1. Listener not running on standby                                     │
│     Solution: lsnrctl start                                             │
│                                                                         │
│  2. tnsnames.ora entry incorrect                                        │
│     Solution: Verify hostname and port in tnsnames.ora                  │
│                                                                         │
│  3. Firewall blocking port 1521                                         │
│     Solution: Open port 1521 between servers                            │
│                                                                         │
│  4. Hostname not resolving                                              │
│     Solution: Use IP address instead, or fix DNS/hosts                  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Issue: "RMAN duplicate fails with ORA-01017"

```
┌─────────────────────────────────────────────────────────────────────────┐
│  SYMPTOM: ORA-01017: invalid username/password                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  CAUSE: Password file mismatch or incorrect password                    │
│                                                                         │
│  SOLUTIONS:                                                             │
│                                                                         │
│  1. Verify password file was copied correctly:                          │
│     ls -la $ORACLE_HOME/dbs/orapw$ORACLE_SID                            │
│                                                                         │
│  2. Ensure password files are identical:                                │
│     # On both servers, check file size/md5sum                           │
│                                                                         │
│  3. Try connecting manually:                                            │
│     sqlplus sys/<password>@PRODSTBY as sysdba                           │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Issue: "MRP is not running"

```
┌─────────────────────────────────────────────────────────────────────────┐
│  SYMPTOM: No MRP0 process in V$MANAGED_STANDBY                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  SOLUTIONS:                                                             │
│                                                                         │
│  1. Check if database is mounted:                                       │
│     SELECT STATUS FROM V$INSTANCE;                                      │
│     -- Should be MOUNTED                                                │
│                                                                         │
│  2. Start managed recovery:                                             │
│     ALTER DATABASE RECOVER MANAGED STANDBY DATABASE                     │
│       USING CURRENT LOGFILE DISCONNECT FROM SESSION;                    │
│                                                                         │
│  3. Check alert log for errors:                                         │
│     tail -100 $ORACLE_BASE/diag/rdbms/<db>/<sid>/trace/alert*.log       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Issue: "Archive gap detected"

```
┌─────────────────────────────────────────────────────────────────────────┐
│  SYMPTOM: V$ARCHIVE_GAP shows missing logs                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  CAUSE: Network issue prevented redo shipping                           │
│                                                                         │
│  SOLUTIONS:                                                             │
│                                                                         │
│  1. Check FAL (Fetch Archive Log) is configured:                        │
│     SHOW PARAMETER FAL_SERVER;                                          │
│                                                                         │
│  2. Verify network connectivity to primary                              │
│                                                                         │
│  3. Check if archive logs exist on primary:                             │
│     SELECT SEQUENCE#, ARCHIVED, DELETED                                 │
│     FROM V$ARCHIVED_LOG                                                 │
│     WHERE SEQUENCE# BETWEEN <low> AND <high>;                           │
│                                                                         │
│  4. If logs exist on primary, FAL should fetch them automatically       │
│     Check alert log for FAL activity                                    │
│                                                                         │
│  5. If logs were deleted from primary, you may need to rebuild          │
│     the standby from backup                                             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Issue: "LOG_ARCHIVE_DEST_2 shows ERROR status"

```
┌─────────────────────────────────────────────────────────────────────────┐
│  SYMPTOM: SELECT STATUS FROM V$ARCHIVE_DEST WHERE DEST_ID=2             │
│           shows ERROR                                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  DIAGNOSIS:                                                             │
│  SELECT ERROR FROM V$ARCHIVE_DEST WHERE DEST_ID=2;                      │
│                                                                         │
│  COMMON ERRORS:                                                         │
│                                                                         │
│  "ORA-12541: TNS:no listener"                                           │
│    → Standby listener is down. Start it: lsnrctl start                  │
│                                                                         │
│  "ORA-12170: TNS:Connect timeout"                                       │
│    → Network issue or firewall. Check connectivity.                     │
│                                                                         │
│  "ORA-16191: Primary log shipping client not logged on standby"         │
│    → Password file issue. Recopy from primary.                          │
│                                                                         │
│  TO RESET DESTINATION:                                                  │
│  ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_2=DEFER;                       │
│  ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_2=ENABLE;                      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Useful Diagnostic Queries

```sql
-- Check Data Guard status summary
SELECT DATABASE_ROLE, PROTECTION_MODE, PROTECTION_LEVEL,
       SWITCHOVER_STATUS, DATAGUARD_BROKER
FROM V$DATABASE;

-- Check all archive destinations
SELECT DEST_ID, DEST_NAME, STATUS, TARGET,
       ARCHIVER, TRANSMIT_MODE, AFFIRM
FROM V$ARCHIVE_DEST
WHERE STATUS != 'INACTIVE';

-- Check apply lag
SELECT NAME, VALUE, UNIT, TIME_COMPUTED
FROM V$DATAGUARD_STATS
WHERE NAME IN ('transport lag', 'apply lag', 'apply finish time');

-- Check redo apply rate
SELECT SOFAR, UNITS, TIMESTAMP
FROM V$RECOVERY_PROGRESS
WHERE ITEM = 'Active Apply Rate';
```

---

## 8. Glossary

| Term | Definition |
|------|------------|
| **Archive Log** | A copy of a filled online redo log, saved for recovery purposes |
| **ARCHIVELOG Mode** | Database mode where redo logs are archived before being overwritten |
| **Data Guard** | Oracle's disaster recovery solution maintaining synchronized copies of a database |
| **Data Guard Broker** | Centralized management framework for Data Guard configurations |
| **DB_NAME** | The name of the database (same on primary and standby) |
| **DB_UNIQUE_NAME** | Unique identifier for each database in a Data Guard configuration |
| **DGMGRL** | Data Guard Manager Command Line Interface - tool for managing Data Guard Broker |
| **DMON** | Data Guard Monitor process - background process for broker communication |
| **Failover** | Unplanned transition where standby becomes primary (primary is unavailable) |
| **FAL (Fetch Archive Log)** | Mechanism for standby to request missing archive logs from primary |
| **MRP (Managed Recovery Process)** | Background process that applies redo to the standby database |
| **Physical Standby** | Exact block-for-block copy of the primary database |
| **Primary Database** | The production database that handles all transactions |
| **Redo Log** | Records of all changes made to the database |
| **RMAN** | Recovery Manager - Oracle's backup and recovery utility |
| **RFS (Remote File Server)** | Process that receives redo data from the primary |
| **Standby Database** | A synchronized copy of the primary database |
| **Standby Redo Log** | Special redo logs on standby used to receive redo from primary |
| **Switchover** | Planned role reversal between primary and standby |
| **TNS** | Transparent Network Substrate - Oracle's network naming service |

---

## Quick Reference Card

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     DATA GUARD QUICK REFERENCE                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  EXECUTION ORDER:                                                       │
│  ════════════════                                                       │
│                                                                         │
│  PRIMARY:  ./primary/01_gather_primary_info.sh                          │
│  PRIMARY:  ./common/02_generate_standby_config.sh  ← REVIEW CONFIG      │
│  STANDBY:  ./standby/03_setup_standby_env.sh                            │
│  PRIMARY:  ./primary/04_prepare_primary_dg.sh                           │
│  STANDBY:  ./standby/05_clone_standby.sh           ← ENTER PASSWORD     │
│  PRIMARY:  ./primary/06_configure_broker.sh        ← ENABLES SHIPPING   │
│  STANDBY:  ./standby/07_verify_dataguard.sh                             │
│                                                                         │
│  KEY DGMGRL COMMANDS (RECOMMENDED):                                     │
│  ══════════════════════════════════                                     │
│                                                                         │
│  dgmgrl / "show configuration"                                          │
│  dgmgrl / "show database 'PRODSTBY'"                                    │
│  dgmgrl / "validate database 'PRODSTBY'"                                │
│  dgmgrl / "switchover to 'PRODSTBY'"                                    │
│                                                                         │
│  KEY SQL COMMANDS:                                                      │
│  ═════════════════                                                      │
│                                                                         │
│  -- Check MRP status                                                    │
│  SELECT PROCESS, STATUS, SEQUENCE# FROM V$MANAGED_STANDBY;              │
│                                                                         │
│  -- Check for gaps                                                      │
│  SELECT * FROM V$ARCHIVE_GAP;                                           │
│                                                                         │
│  -- Force log switch (on primary)                                       │
│  ALTER SYSTEM SWITCH LOGFILE;                                           │
│                                                                         │
│  LOG FILES:                                                             │
│  ══════════                                                             │
│  /OINSTALL/_dataguard_setup/logs/                                       │
│                                                                         │
│  CONFIG FILES:                                                          │
│  ═════════════                                                          │
│  /OINSTALL/_dataguard_setup/standby_config.env    ← Single source of    │
│  /OINSTALL/_dataguard_setup/primary_info.env         truth              │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

*Document generated for Oracle 19c Data Guard Setup Scripts*
