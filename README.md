# Oracle 19c Data Guard Setup Scripts

Automated scripts for setting up an Oracle 19c Physical Standby database in a Data Guard configuration.

## Overview

These scripts automate the process of creating a physical standby database from an existing primary database using RMAN duplicate. They handle all the configuration, file copying, and validation steps required for a working Data Guard setup.

## Features

- **Automated Information Gathering** - Collects all required parameters from the primary database
- **Single Source of Truth** - Generates a master configuration file (`standby_config_<name>.env`) for consistent setup
- **Concurrent Build Support** - All generated files include DB_UNIQUE_NAME, allowing multiple DG setups simultaneously
- **Data Guard Broker (DGMGRL)** - Centralized management of Data Guard configuration
- **Prerequisite Validation** - Checks archivelog mode, force logging, password files, etc.
- **NFS-Based File Sharing** - Uses shared storage for configuration and file transfer
- **Secure Password Handling** - Passwords prompted at runtime, never stored
- **Comprehensive Logging** - All operations logged with timestamps
- **Health Verification** - Post-setup validation with detailed status reporting

## Prerequisites

### Primary Server
- Oracle 19c database running
- Database in ARCHIVELOG mode
- FORCE_LOGGING enabled (recommended)
- Password file exists (`$ORACLE_HOME/dbs/orapw<SID>`)
- `REMOTE_LOGIN_PASSWORDFILE = EXCLUSIVE`

### Standby Server
- Oracle 19c software installed (same version as primary)
- Same `ORACLE_HOME` path as primary
- Sufficient disk space for database files

### Shared Infrastructure
- NFS mount accessible at `/OINSTALL/_dataguard_setup` on both servers
  - Use `nfs/01_setup_nfs_server.sh` and `nfs/02_mount_nfs_client.sh` to set this up
- Network connectivity between servers (port 1521)

## Directory Structure

```
dataguard_setup/
├── README.md                          # This file
├── CLAUDE.md                          # Project instructions for AI assistants
├── docs/
│   └── DATA_GUARD_WALKTHROUGH.md      # Detailed step-by-step guide
├── nfs/
│   ├── 01_setup_nfs_server.sh         # Setup NFS server and export share
│   └── 02_mount_nfs_client.sh         # Mount NFS share on client
├── primary/
│   ├── 01_gather_primary_info.sh      # Collect DB info from primary
│   ├── 02_generate_standby_config.sh  # Generate standby configuration
│   ├── 04_prepare_primary_dg.sh       # Configure primary for Data Guard
│   ├── 06_configure_broker.sh         # Configure Data Guard Broker (DGMGRL)
│   ├── 08_security_hardening.sh       # Lock SYS account (optional)
│   └── 09_configure_fsfo.sh           # Configure Fast-Start Failover (optional)
├── standby/
│   ├── 03_setup_standby_env.sh        # Prepare standby environment
│   ├── 05_clone_standby.sh            # RMAN duplicate execution
│   └── 07_verify_dataguard.sh         # Validation and health check
├── fsfo/
│   └── observer.sh                    # Observer setup and lifecycle (setup/start/stop/status)
├── common/
│   └── dg_functions.sh                # Shared utility functions
├── templates/
│   ├── init_standby.ora.template      # Reference template
│   ├── listener.ora.template          # Reference template
│   └── tnsnames.ora.template          # Reference template
└── tests/
    └── test_add_sid_to_listener.sh    # Test script for listener functions
```

## Quick Start

### Execution Order

| Step | Server | Command | Restartable |
|------|--------|---------|-------------|
| 1 | PRIMARY | `./primary/01_gather_primary_info.sh` | Yes |
| 2 | PRIMARY | `./primary/02_generate_standby_config.sh` | Yes |
| 3 | STANDBY | `./standby/03_setup_standby_env.sh` | Yes |
| 4 | PRIMARY | `./primary/04_prepare_primary_dg.sh` | Yes |
| 5 | STANDBY | `./standby/05_clone_standby.sh` | No* |
| 6 | PRIMARY | `./primary/06_configure_broker.sh` | Yes |
| 7 | STANDBY | `./standby/07_verify_dataguard.sh` | Yes |
| 8 | PRIMARY | `./primary/08_security_hardening.sh` | Yes** |
| 9 | PRIMARY | `./primary/09_configure_fsfo.sh` | Yes*** |
| 10 | OBSERVER | `./fsfo/observer.sh setup` then `start` | Yes*** |

**\*** Step 5 requires cleanup before restart (see [Restartability](#restartability)).

**\*\*** Step 8 is optional. Locks SYS account after setup is verified.

**\*\*\*** Steps 9-10 are optional. Configures Fast-Start Failover for automatic failover.

### Workflow Diagram

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
Step 6: Configure Broker ◄────────────────────────────┘
    │
    └────────────────────────────────────► Step 7: Verify Setup

Step 8: Security Hardening (optional)

                        OBSERVER SERVER (optional - can be standby or 3rd server)
                        ══════════════════════════════════════════════════════
Step 9: Configure FSFO ─────────────────► Step 10: Observer Setup & Start
    (creates SYSDG user,                    (wallet setup, start observer)
     enables FSFO)
```

### Restartability

**Steps 1-4 are fully restartable** - these scripts are idempotent and can be re-run from step 1 if needed.

**Step 5 is NOT directly restartable** - once RMAN duplicate starts, cleanup is required:
1. Shut down standby instance: `SHUTDOWN ABORT`
2. Remove standby data files, control files, and redo logs
3. Re-run step 5

**Steps 6-7 are restartable** - broker config can be removed with `REMOVE CONFIGURATION` in DGMGRL.

## Configuration

### Environment Assumptions

- **Storage**: Filesystem-based (not ASM)
- **Architecture**: Single Instance (not RAC)
- **Protection Mode**: Maximum Performance (async redo transport)
- **Path Differences**: DB_UNIQUE_NAME embedded in paths

### Key Configuration File

After running Step 2, review `/OINSTALL/_dataguard_setup/standby_config_<STANDBY_DB_UNIQUE_NAME>.env`:

```bash
# Primary Database Info
PRIMARY_HOSTNAME="primary-server"
PRIMARY_DB_UNIQUE_NAME="PROD"

# Standby Database Info
STANDBY_HOSTNAME="standby-server"
STANDBY_DB_UNIQUE_NAME="PRODSTBY"

# Path Conversions
DB_FILE_NAME_CONVERT="'/u01/oradata/PROD','/u01/oradata/PRODSTBY'"
```

## Documentation

For a detailed walkthrough with explanations, diagrams, and troubleshooting:

**See [docs/DATA_GUARD_WALKTHROUGH.md](docs/DATA_GUARD_WALKTHROUGH.md)**

## Post-Setup Monitoring

### Using DGMGRL (Recommended)

```bash
# Show overall configuration status
dgmgrl / "show configuration"

# Show detailed status of standby
dgmgrl / "show database 'PRODSTBY'"

# Validate configuration (comprehensive check)
dgmgrl / "validate database 'PRODSTBY'"

# Perform switchover
dgmgrl / "switchover to 'PRODSTBY'"
```

### Using SQL

```sql
-- Check MRP status (on standby)
SELECT PROCESS, STATUS, SEQUENCE# FROM V$MANAGED_STANDBY;

-- Check for archive gaps (on standby)
SELECT * FROM V$ARCHIVE_GAP;

-- Check apply lag (on standby)
SELECT NAME, VALUE FROM V$DATAGUARD_STATS WHERE NAME LIKE '%lag%';

-- Force log switch for testing (on primary)
ALTER SYSTEM SWITCH LOGFILE;
```

## Fast-Start Failover (Optional)

After Data Guard setup is complete and verified (Steps 1-8), you can optionally configure Fast-Start Failover (FSFO) for automatic failover capability.

### Step 9: Configure FSFO

Run on the **PRIMARY** server after Step 7 verification passes:

```bash
./primary/09_configure_fsfo.sh
```

This configures:
- Creates observer user with SYSDG privilege (username is configurable)
- Protection mode: MAXIMUM AVAILABILITY
- LogXptMode: FASTSYNC
- FSFO threshold: 30 seconds (configurable via FSFO_THRESHOLD)
- Enables Fast-Start Failover

### Step 10: Observer Setup

The observer can run on the **standby server** or a **dedicated 3rd server**. On the observer server:

```bash
# Set up Oracle Wallet for secure authentication
./fsfo/observer.sh setup

# Start the observer
./fsfo/observer.sh start

# Check observer status
./fsfo/observer.sh status

# Stop the observer (before maintenance)
./fsfo/observer.sh stop

# Restart the observer
./fsfo/observer.sh restart
```

The wallet provides secure authentication without storing passwords. When running `setup`, you will be prompted for the observer user password created in Step 9.

### FSFO Commands (DGMGRL)

```bash
# Show FSFO status
dgmgrl / "show fast_start failover"

# Disable FSFO (if needed)
dgmgrl / "disable fast_start failover"

# Re-enable FSFO
dgmgrl / "enable fast_start failover"
```

## Troubleshooting

Common issues are documented in [docs/DATA_GUARD_WALKTHROUGH.md](docs/DATA_GUARD_WALKTHROUGH.md), including:

- TNS connectivity failures
- RMAN duplicate errors
- MRP not running
- Archive log gaps
- Archive destination errors

## Requirements

- Oracle Database 19c
- Bash shell
- `sqlplus`, `rman`, `lsnrctl`, `dgmgrl` in PATH
- NFS mount at `/OINSTALL/_dataguard_setup`

## License

MIT License - See LICENSE file for details.

## Contributing

Contributions welcome. Please test changes in a non-production environment first.
