# Data Guard Status Dashboard

`dg_status.sh` is a single-command health check for an Oracle 19c Data Guard configuration. It connects to both the primary and standby databases over SSH, queries key V$ views and DGMGRL, and prints a colour-coded dashboard that highlights issues at a glance.

## Quick Start

```bash
# Uses $ORACLE_SID (or auto-detects from running pmon)
bash dg_status.sh

# Explicit SID
bash dg_status.sh -s cdb1

# Custom SSH config
bash dg_status.sh -c /path/to/config.env
```

## What It Checks

### Primary Database

| Check | Source | OK | Warning | Error |
|---|---|---|---|---|
| Role | `V$DATABASE.DATABASE_ROLE` | PRIMARY | - | Anything else |
| Open Mode | `V$DATABASE.OPEN_MODE` | READ WRITE | - | Anything else |
| Protection Mode | `V$DATABASE.PROTECTION_MODE` | _(displayed, not graded)_ | | |
| Switchover Status | `V$DATABASE.SWITCHOVER_STATUS` | TO STANDBY / SESSIONS ACTIVE | Anything else | - |
| Force Logging | `V$DATABASE.FORCE_LOGGING` | YES | - | NO |
| Flashback | `V$DATABASE.FLASHBACK_ON` | YES | NO | - |
| DG Broker | `V$PARAMETER (dg_broker_start)` | TRUE | - | FALSE |
| Online Redo Logs | `V$LOG` | _(displayed, not graded)_ | | |
| Standby Redo Logs | `V$STANDBY_LOG` | Count > 0 | NONE | - |
| Archive Dest 2 | `V$ARCHIVE_DEST` | VALID | - | ERROR (with ORA message) |
| Archive Gaps | `V$ARCHIVE_GAP` | 0 | - | > 0 |
| FRA Usage | `V$RECOVERY_FILE_DEST` | < 80% | 80-89% | >= 90% |

### Standby Database

| Check | Source | OK | Warning | Error |
|---|---|---|---|---|
| Role | `V$DATABASE.DATABASE_ROLE` | PHYSICAL STANDBY | - | Anything else |
| Open Mode | `V$DATABASE.OPEN_MODE` | MOUNTED / READ ONLY | Anything else | - |
| Protection Mode | `V$DATABASE.PROTECTION_MODE` | _(displayed, not graded)_ | | |
| Switchover Status | `V$DATABASE.SWITCHOVER_STATUS` | NOT ALLOWED / SWITCHOVER PENDING | Anything else | - |
| MRP Status | `V$MANAGED_STANDBY (MRP0)` | APPLYING_LOG / WAIT_FOR_LOG | - | Not running / other |
| Transport Lag | `V$DATAGUARD_STATS` | +00 00:00:00 | Any lag | - |
| Apply Lag | `V$DATAGUARD_STATS` | +00 00:00:00 | Any lag | - |
| Sequences | `V$ARCHIVED_LOG` | Lag <= 1 | Lag 2-5 | Lag > 5 |
| Standby Redo Logs | `V$STANDBY_LOG` | Count > 0 | - | NONE |
| Archive Gaps | `V$ARCHIVE_GAP` | 0 | - | > 0 |
| FRA Usage | `V$RECOVERY_FILE_DEST` | < 80% | 80-89% | >= 90% |

### Data Guard Broker

| Check | Source | OK | Warning | Error |
|---|---|---|---|---|
| Configuration | `SHOW CONFIGURATION` | Exists | - | ORA-16532 (not configured) |
| Overall Status | `SHOW CONFIGURATION` | SUCCESS | WARNING | ERROR |
| Per-member status | `SHOW CONFIGURATION` | No errors | Warning on member | Error on member |
| ORA errors | `SHOW CONFIGURATION` | _(displayed in red)_ | | |
| Fast-Start Failover | `SHOW FAST_START FAILOVER` | Enabled (with target/observer) | - | _(shown as disabled)_ |

## Prerequisites

- **SSH access** to both primary and standby database hosts, either directly or via a jump host
- **Oracle OS authentication** (`sqlplus / as sysdba`) working on both hosts
- **DG Broker** running (`dg_broker_start = TRUE`)
- A **config file** providing SSH connection details (defaults to `tests/e2e/config.env`)

## Config File

The script uses the same config format as the E2E test suite. Required variables:

```bash
# Jump host (set JUMP_HOST to the local hostname to skip ProxyJump)
JUMP_HOST="bastion"
JUMP_USER="db"
JUMP_SSH_PORT="22"

# Primary DB host (reachable from jump host)
PRIMARY_HOST="localhost"
PRIMARY_SSH_PORT="2201"
PRIMARY_ORACLE_HOSTNAME="primary-host"    # Display name

# Standby DB host (reachable from jump host)
STANDBY_HOST="localhost"
STANDBY_SSH_PORT="2202"
STANDBY_ORACLE_HOSTNAME="standby-host"   # Display name

# SSH to DB hosts
SSH_USER="oracle"
SSH_KEY=""       # Empty = default key
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

# Oracle environment (same on both hosts)
ORACLE_HOME="/u01/app/oracle/product/19.0.0/dbhome_1"
ORACLE_BASE="/u01/app/oracle"
```

## SID Resolution

The Oracle SID is resolved in this order:

1. **`-s` / `--sid` flag** -- explicit override
2. **`$ORACLE_SID` environment variable** -- uses whatever is set in your shell
3. **Auto-detect** -- finds the running `ora_pmon_<SID>` process on the primary host

The standby SID is always auto-detected from its own pmon process (it may differ from the primary SID).

## Exit Code

The script always exits with 0. It is an informational tool -- the colour-coded indicators in the output show what needs attention.

## How It Works

The script runs all SSH connections in parallel (5 concurrent sessions) to minimise wall-clock time:

1. **Primary SQL** -- single `sqlplus` session querying `V$DATABASE`, `V$PARAMETER`, `V$LOG`, `V$STANDBY_LOG`, `V$ARCHIVE_GAP`, `V$ARCHIVE_DEST`, `V$RECOVERY_FILE_DEST`
2. **Primary DGMGRL** -- `SHOW CONFIGURATION` and `SHOW FAST_START FAILOVER`
3. **Standby SQL** -- single `sqlplus` session querying `V$DATABASE`, `V$MANAGED_STANDBY`, `V$DATAGUARD_STATS`, `V$ARCHIVE_GAP`, `V$ARCHIVED_LOG`, `V$STANDBY_LOG`, `V$RECOVERY_FILE_DEST`

Results are parsed and displayed with colour-coded status indicators:
- **OK** (green) -- check passed
- **!!** (yellow) -- warning, review recommended
- **XX** (red) -- error, action needed

## Example Output

```
 Data Guard Status Dashboard  2026-04-02 12:53:09
 Primary: poug-dg1 (SID: cdb1)  |  Standby: poug-dg2 (SID: cdb1)

 PRIMARY DATABASE  (poug-dg1 / cdb1)
 ────────────────────────────────────────────────────────────
  Role                     PRIMARY                              OK
  Open Mode                READ WRITE                           OK
  Protection Mode          MAXIMUM AVAILABILITY
  Switchover Status        TO STANDBY                           OK
  Force Logging            YES                                  OK
  Flashback                YES                                  OK
  DG Broker                TRUE                                 OK
  Online Redo Logs         3 groups (150 MB total)
  Standby Redo Logs        4 groups                             OK
  Archive Dest 2 (Standby) VALID                                OK
  FRA Usage                14.1/20 GB (70%), reclaimable 13.7 GB OK
  FRA Location             /u01/app/oracle/fast_recovery_area (316 files)

 STANDBY DATABASE  (poug-dg2 / cdb1_stby)
 ────────────────────────────────────────────────────────────
  Role                     PHYSICAL STANDBY                     OK
  Open Mode                MOUNTED                              OK
  Protection Mode          MAXIMUM AVAILABILITY
  Switchover Status        NOT ALLOWED                          OK
  MRP Status               APPLYING_LOG (seq# 1295)             OK
  Transport Lag            none                                 OK
  Apply Lag                none                                 OK
  Sequences                applied=1294  received=1294          OK
  Standby Redo Logs        4 groups                             OK
  FRA Usage                .5/20 GB (2%), reclaimable .5 GB     OK
  FRA Location             /u01/app/oracle/fast_recovery_area (12 files)

 DATA GUARD BROKER
 ────────────────────────────────────────────────────────────
  Configuration            my_dg_config
  Overall Status           SUCCESS                              OK
  Fast-Start Failover      Disabled                             disabled

 ────────────────────────────────────────────────────────────
  HEALTHY  No issues detected
```
