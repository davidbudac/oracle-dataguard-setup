# Data Guard Local Status Check

`dg_check_sid.sh` is a health check that runs directly on an Oracle database host -- no SSH or external config file required. It detects the local database role (primary or standby), queries local V$ views and DGMGRL, then automatically discovers and connects to the peer database over SQL*Net for a complete picture.

## Quick Start

```bash
# Run on any DG host - auto-detects everything
export ORACLE_SID=cdb1
bash dg_check_sid.sh

# Local + broker only (no remote SQL connection)
bash dg_check_sid.sh -L

# Force password prompt for remote connection
bash dg_check_sid.sh -P
```

## How It Works

1. **Local detection** -- reads `$ORACLE_SID`, connects with `sqlplus / as sysdba`, queries `V$DATABASE` to determine role (PRIMARY or STANDBY)
2. **Broker discovery** -- runs `SHOW CONFIGURATION` via `dgmgrl -silent /` to find the peer database name, then `SHOW DATABASE` to get its TNS connect identifier
3. **Remote connection** -- tries wallet-based auth (`/@tns as sysdba`) first; if that fails, prompts for the SYS password; skipped entirely with `-L`
4. **Display** -- shows both databases in primary-then-standby order regardless of which host the script runs on

### Graceful Degradation

If the remote connection is unavailable (TNS error, no password, `-L` flag), the peer database section falls back to a **broker view** showing what DGMGRL knows: role, intended state, lag estimates, and any ORA errors. A hint directs the user to use `-P` for full remote checks.

## What It Checks

The checks are identical to [`dg_status.sh`](DG_STATUS.md) -- see that document for the full table of checks and thresholds. The only difference is the data source:

| Data | `dg_status.sh` (SSH-based) | `dg_check_sid.sh` (local) |
|---|---|---|
| Local database | SSH + sqlplus | Direct sqlplus |
| Peer database | SSH + sqlplus | SQL*Net via TNS |
| Broker | SSH + dgmgrl | Direct dgmgrl |
| Config source | `config.env` (SSH details) | `$ORACLE_SID` + auto-discovery |
| Authentication | OS auth on both hosts | OS auth local, wallet/password remote |

### Checks performed on each database

- Database role, open mode, protection mode, switchover status
- Force logging, flashback
- DG broker enabled
- Online redo log and standby redo log counts
- Archive destination status and errors (primary)
- Archive gaps
- FRA usage with 80%/90% thresholds
- MRP apply status and sequence (standby)
- Transport lag, apply lag (standby)
- Archived log sequence comparison (standby)

### Broker checks

- Configuration name and overall status (SUCCESS/WARNING/ERROR)
- Per-member status with ORA error details
- Fast-Start Failover status (enabled/disabled, target, observer, threshold)

## Command-Line Options

| Flag | Description |
|---|---|
| `-P`, `--password` | Prompt for SYS password for remote connection |
| `-L`, `--local` | Skip remote SQL checks (local + broker only) |
| `-h`, `--help` | Show usage |

## Prerequisites

- `ORACLE_HOME` and `ORACLE_SID` environment variables set
- `sqlplus / as sysdba` working (OS authentication)
- DG Broker running (`dg_broker_start = TRUE`)
- For remote checks: TNS connectivity to peer database, plus either an Oracle Wallet or SYS password

## Remote Authentication

The script tries to connect to the peer database in this order:

1. **Wallet** -- `sqlplus /@<tns_alias> as sysdba` (no password needed if a wallet is configured)
2. **Password prompt** -- if the wallet fails, the script prompts for the SYS password interactively (press Enter to skip)
3. **Skip** -- use `-L` to bypass remote checks entirely

The `-P` flag forces the password prompt even if a wallet might work.

## Exit Code

The script always exits with 0. It is an informational tool -- the colour-coded indicators in the output show what needs attention.

## Example Output

### From Primary (with -L)

```
 Data Guard Status Check  2026-04-02 12:07:59
 Local: poug-dg1 (SID: cdb1, role: PRIMARY)  |  Remote: skipped (-L)

 PRIMARY DATABASE  (cdb1)
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
  FRA Usage                14.2/20 GB (71%), reclaimable 13.7 GB OK
  FRA Location             /u01/app/oracle/fast_recovery_area (317 files)

 STANDBY DATABASE  (cdb1_stby)
 ────────────────────────────────────────────────────────────
  Role                     PHYSICAL STANDBY                     OK
  Intended State           APPLY-ON
  Transport Lag            +00 00:00:00
  Apply Lag                +00 00:00:00
  (broker view only - use -P for full remote checks)

 DATA GUARD BROKER
 ────────────────────────────────────────────────────────────
  Configuration            my_dg_config
  Overall Status           SUCCESS                              OK
  Fast-Start Failover      Disabled                             disabled

 ────────────────────────────────────────────────────────────
  HEALTHY  No issues detected
```

### From Standby (with -L)

```
 Data Guard Status Check  2026-04-02 12:07:41
 Local: poug-dg2 (SID: cdb1, role: STANDBY)  |  Remote: skipped (-L)

 PRIMARY DATABASE  (cdb1)
 ────────────────────────────────────────────────────────────
  Role                     PRIMARY                              OK
  Intended State           TRANSPORT-ON
  (broker view only - use -P for full remote checks)

 STANDBY DATABASE  (cdb1_stby)
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
