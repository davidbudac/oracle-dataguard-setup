# Project: Oracle 19c Data Guard Setup Scripts

Automated scripts for setting up Oracle 19c Physical Standby databases using Data Guard Broker (DGMGRL).

## Project Structure

```
nfs/           - NFS setup scripts (run before Data Guard setup)
primary/       - Scripts to run on PRIMARY server
standby/       - Scripts to run on STANDBY server
fsfo/          - Fast-Start Failover scripts (optional, run on STANDBY)
common/        - Shared scripts and functions
templates/     - Reference templates
docs/          - Detailed walkthrough documentation
tests/         - Test scripts
```

## Execution Order

1. `nfs/01_setup_nfs_server.sh` - Setup NFS (on NFS server, requires sudo)
2. `nfs/02_mount_nfs_client.sh` - Mount NFS (on both servers, requires sudo)
3. `primary/01_gather_primary_info.sh` - Collect primary DB info
4. `primary/02_generate_standby_config.sh` - Generate standby config (user reviews)
5. `standby/03_setup_standby_env.sh` - Prepare standby environment
6. `primary/04_prepare_primary_dg.sh` - Configure primary for DG
7. `standby/05_clone_standby.sh` - RMAN duplicate (prompts for SYS password)
8. `primary/06_configure_broker.sh` - Configure DGMGRL
9. `standby/07_verify_dataguard.sh` - Verify setup
10. `primary/08_security_hardening.sh` - Lock SYS account (optional)

## Restartability

**Steps 1-4 are fully restartable** - these scripts are idempotent and can be re-run from step 1 if needed. They gather information, generate configs, and apply settings that can be safely overwritten.

**Step 5 (Clone Standby) is NOT directly restartable** - once RMAN duplicate starts, you cannot simply re-run the script. To restart from step 5:
1. Shut down the standby instance
2. Remove all standby data files, control files, and redo logs
3. Re-run step 5

**Steps 6-7 are restartable** - the broker configuration can be removed with `REMOVE CONFIGURATION` in DGMGRL and recreated. Step 7 is read-only verification.

## Key Design Decisions

- **Use DGMGRL for all Data Guard configuration** - Always prefer Data Guard Broker commands over manual ALTER SYSTEM/ALTER DATABASE commands when configuring anything Data Guard related
- **Data Guard Broker (DGMGRL)** manages DG parameters instead of manual ALTER SYSTEM commands
- **NFS share** at `/OINSTALL/_dataguard_setup` for file exchange between servers
- **Single source of truth**: `standby_config_<STANDBY_DB_UNIQUE_NAME>.env` contains all configuration
- **Concurrent builds**: All generated files include DB_UNIQUE_NAME to support multiple DG setups
- **Passwords prompted at runtime**, never stored
- **Filesystem storage** (not ASM), single instance (not RAC)
- **AIX 7.2 compatible**: Uses printf instead of echo -e, sed instead of grep -P

## Common Functions

`common/dg_functions.sh` provides:
- `log_info`, `log_warn`, `log_error` - Logging functions
- `run_sql`, `run_sql_with_header` - SQL execution helpers
- `get_db_parameter` - Get Oracle parameter value
- `check_oracle_env`, `check_nfs_mount`, `check_db_connection` - Validation functions

## Validation Checks

Built-in validations:
- ARCHIVELOG mode, FORCE_LOGGING, password file (step 1)
- Disk space on standby (step 3)
- Port connectivity primary → standby (step 4)
- Listener port detection from `lsnrctl status` (step 1)

## Testing

Scripts are designed for Oracle 19c on Linux with filesystem storage. Test in non-production first.

## Fast-Start Failover (Optional)

After Data Guard setup is complete, you can optionally configure Fast-Start Failover (FSFO) for automatic failover:

```
fsfo/configure_fsfo.sh  - Configure FSFO (run once on STANDBY)
fsfo/observer.sh        - Observer lifecycle: start/stop/status/restart
```

**FSFO Configuration:**
- Sets protection mode to MAXIMUM AVAILABILITY
- Sets LogXptMode to FASTSYNC
- Enables Fast-Start Failover with 30-second threshold

**Observer Management:**
```bash
./fsfo/observer.sh start    # Start observer in background
./fsfo/observer.sh status   # Check observer status
./fsfo/observer.sh stop     # Stop observer
./fsfo/observer.sh restart  # Restart observer
```

The observer must be running for automatic failover to occur.
