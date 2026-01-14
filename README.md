# Oracle 19c Data Guard Setup Scripts

Automated scripts for setting up an Oracle 19c Physical Standby database in a Data Guard configuration.

## Overview

These scripts automate the process of creating a physical standby database from an existing primary database using RMAN duplicate. They handle all the configuration, file copying, and validation steps required for a working Data Guard setup.

## Features

- **Automated Information Gathering** - Collects all required parameters from the primary database
- **Single Source of Truth** - Generates a master configuration file (`standby_config.env`) for consistent setup
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
- Network connectivity between servers (port 1521)

## Directory Structure

```
dataguard_setup/
├── README.md                          # This file
├── WALKTHROUGH.md                     # Detailed step-by-step guide
├── primary/
│   ├── 01_gather_primary_info.sh      # Collect DB info from primary
│   └── 04_prepare_primary_dg.sh       # Configure primary for Data Guard
├── standby/
│   ├── 03_setup_standby_env.sh        # Prepare standby environment
│   ├── 05_clone_standby.sh            # RMAN duplicate execution
│   └── 06_verify_dataguard.sh         # Validation and health check
├── common/
│   ├── 02_generate_standby_config.sh  # Generate standby configuration
│   └── dg_functions.sh                # Shared utility functions
└── templates/
    ├── init_standby.ora.template      # Reference template
    ├── listener.ora.template          # Reference template
    └── tnsnames.ora.template          # Reference template
```

## Quick Start

### Execution Order

| Step | Server | Command |
|------|--------|---------|
| 1 | PRIMARY | `./primary/01_gather_primary_info.sh` |
| 2 | PRIMARY | `./common/02_generate_standby_config.sh` |
| 3 | STANDBY | `./standby/03_setup_standby_env.sh` |
| 4 | PRIMARY | `./primary/04_prepare_primary_dg.sh` |
| 5 | STANDBY | `./standby/05_clone_standby.sh` |
| 6 | STANDBY | `./standby/06_verify_dataguard.sh` |

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
                                                      ▼
                                          Step 6: Verify Setup
```

## Configuration

### Environment Assumptions

- **Storage**: Filesystem-based (not ASM)
- **Architecture**: Single Instance (not RAC)
- **Protection Mode**: Maximum Performance (async redo transport)
- **Path Differences**: DB_UNIQUE_NAME embedded in paths

### Key Configuration File

After running Step 2, review `/OINSTALL/_dataguard_setup/standby_config.env`:

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

**See [WALKTHROUGH.md](WALKTHROUGH.md)**

## Post-Setup Monitoring

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

## Troubleshooting

Common issues are documented in [WALKTHROUGH.md](WALKTHROUGH.md#7-troubleshooting-guide), including:

- TNS connectivity failures
- RMAN duplicate errors
- MRP not running
- Archive log gaps
- Archive destination errors

## Requirements

- Oracle Database 19c
- Bash shell
- `sqlplus`, `rman`, `lsnrctl` in PATH
- NFS mount at `/OINSTALL/_dataguard_setup`

## License

MIT License - See LICENSE file for details.

## Contributing

Contributions welcome. Please test changes in a non-production environment first.
