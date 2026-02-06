# Project: Oracle 19c Data Guard Setup Scripts

Automated scripts for setting up Oracle 19c Physical Standby databases using Data Guard Broker (DGMGRL).

## Project Structure

```
nfs/           - NFS setup scripts (run before Data Guard setup)
primary/       - Scripts to run on PRIMARY server (Steps 1,2,4,6,8,9)
standby/       - Scripts to run on STANDBY server (Steps 3,5,7)
fsfo/          - Observer scripts (run on observer server - standby or 3rd server)
trigger/       - Role-aware service trigger (run on PRIMARY)
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
11. `primary/09_configure_fsfo.sh` - Configure Fast-Start Failover (optional)
12. `fsfo/observer.sh setup` - Set up observer wallet (on observer server)
13. `fsfo/observer.sh start` - Start observer (on observer server)
14. `trigger/create_role_trigger.sh` - Deploy role-aware service trigger (on PRIMARY, optional)

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

**Step 9: Configure FSFO (on PRIMARY)**
```bash
./primary/09_configure_fsfo.sh
```
This creates an observer user with SYSDG privilege, sets MAXIMUM AVAILABILITY mode, enables FSFO.

**Step 10: Observer Setup (on OBSERVER server - can be standby or 3rd server)**
```bash
./fsfo/observer.sh setup   # Create Oracle Wallet with SYSDG credentials
./fsfo/observer.sh start   # Start observer in background
./fsfo/observer.sh status  # Check observer status
./fsfo/observer.sh stop    # Stop observer
./fsfo/observer.sh restart # Restart observer
```

**Authentication:**
- Uses Oracle Wallet for secure authentication (no stored passwords)
- User-specified username with SYSDG privilege for observer connections
- Observer connects via: `dgmgrl /@PRIMARY_TNS_ALIAS`

**FSFO Configuration:**
- Protection mode: MAXIMUM AVAILABILITY
- LogXptMode: FASTSYNC
- Default threshold: 30 seconds (configurable via FSFO_THRESHOLD)

The observer must be running for automatic failover to occur.

## Role-Aware Service Trigger (Optional)

After Data Guard setup is complete, you can deploy triggers that automatically start/stop services based on database role:

**Step 14: Deploy Service Trigger (on PRIMARY)**
```bash
./trigger/create_role_trigger.sh
```
This discovers running user services, creates PL/SQL package `SYS.DG_SERVICE_MGR` and two database triggers. Services are started on PRIMARY and stopped on STANDBY, triggered on both role change (switchover/failover) and database startup.

**Objects created:**
- `SYS.DG_SERVICE_MGR` - PL/SQL package with `MANAGE_SERVICES` procedure
- `SYS.TRG_MANAGE_SERVICES_ROLE_CHG` - Fires `AFTER DB_ROLE_CHANGE`
- `SYS.TRG_MANAGE_SERVICES_STARTUP` - Fires `AFTER STARTUP`

Objects replicate to standby automatically via redo apply. The script is restartable - re-running replaces existing objects with the updated service list.
