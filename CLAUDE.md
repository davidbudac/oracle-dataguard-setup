# Project: Oracle 19c Data Guard Setup Scripts

Automated scripts for setting up Oracle 19c Physical Standby databases using Data Guard Broker (DGMGRL).

## Project Structure

```
dg_status.sh     - Quick Data Guard health dashboard (run from jump host)
dg_triage_sid.sh - Fast local Data Guard triage (run directly on DB host)
dg_diag_sid.sh   - Deep local Data Guard diagnostics (run directly on DB host)
dg_check_sid.sh  - Deprecated wrapper to dg_triage_sid.sh
dg_handoff.sh    - Standalone handoff report generator (post-setup; no NFS/config dependencies)
dg_check_srl.sh  - Standby redo log checker: verifies SRL count/size on both sides and prints fix DDL (flags -p/--prompt-password, -L/--local-only, -d/--srl-path; exit codes 0 compliant / 1 DDL needed / 2 error)
migrate_noncdb_to_pdb/ - Non-CDB to PDB migration subproject: migrate a non-CDB with its own standby into an existing CDB with its own standby, without recreating either standby (has its own README/WALKTHROUGH)
nfs/             - NFS setup scripts (run before Data Guard setup)
primary/         - Scripts to run on PRIMARY server (Steps 1, 2, 4, 6, 8, 9, 10)
standby/         - Scripts to run on STANDBY server (Steps 3, 5, 7)
fsfo/            - Observer scripts (run on observer server - standby or 3rd server)
trigger/         - Role-aware service trigger (run on PRIMARY); two variants: SYS-owned and dedicated-user
common/          - Shared scripts and functions, including setup_dg_wallet.sh, cleanup_nfs_artifacts.sh, dg_render_common.sh (shared render/threshold library for dg_status.sh and the local triage/diag tools), and dg_local_status_common.sh (the engine behind dg_triage_sid.sh/dg_diag_sid.sh)
templates/       - Reference templates (init.ora, listener, tnsnames)
sql/             - SQL/RMAN/DGMGRL command snippets used by the workflow scripts
docs/            - Detailed walkthrough and tool references (DG_STATUS, DG_CHECK, WALLET_SETUP)
tests/           - Test scripts (unit tests and E2E test suite, including CDB variant)
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
15. `primary/10_generate_handoff_report.sh` - Generate end-user handoff report with status snapshot and TNS/JDBC connection strings (on PRIMARY)
16. `common/cleanup_nfs_artifacts.sh` - Remove sensitive/transient setup artifacts (password file copies, generated pfiles, RMAN files) from the NFS share once the build is verified (optional, run from any host with the share mounted)

## Restartability

**Steps 1-4 are fully restartable** - these scripts are idempotent and can be re-run from step 1 if needed. They gather information, generate configs, and apply settings that can be safely overwritten.

**Step 5 (Clone Standby) is NOT directly restartable** - once RMAN duplicate starts, you cannot simply re-run the script. To restart from step 5:
1. Shut down the standby instance
2. Remove all standby data files, control files, and redo logs
3. Re-run step 5

**Post-hardening re-clone limitation:** if `primary/08_security_hardening.sh` has already run, SYS on the primary is locked. `standby/05_clone_standby.sh` detects this at the password-verification step (`ORA-28000`) and prints the fix: temporarily `ALTER USER SYS ACCOUNT UNLOCK` + `IDENTIFIED BY <temp password>` on the primary, re-run step 5, then re-run `primary/08_security_hardening.sh` afterward to re-harden SYS (fresh random password, re-lock) and re-propagate the refreshed password file to the standby.

**Steps 6-7 are restartable** - the broker configuration can be removed with `REMOVE CONFIGURATION` in DGMGRL and recreated. Step 7 is read-only verification.

## Key Design Decisions

- **Use DGMGRL for all Data Guard configuration** - Always prefer Data Guard Broker commands over manual ALTER SYSTEM/ALTER DATABASE commands when configuring anything Data Guard related
- **Data Guard Broker (DGMGRL)** manages DG parameters instead of manual ALTER SYSTEM commands
- **NFS share** at `/OINSTALL/_dataguard_setup` for file exchange between servers
- **Single source of truth**: `standby_config_<STANDBY_DB_UNIQUE_NAME>.env` contains all configuration. After editing it, run `02_generate_standby_config.sh --regenerate` to update derived files (pfile, TNS, listener, DGMGRL)
- **Concurrent builds**: All generated files include DB_UNIQUE_NAME to support multiple DG setups
- **Passwords prompted at runtime**, never stored
- **Filesystem storage** (not ASM), single instance (not RAC)
- **Storage mode choice**: Step 2 offers Traditional (path substitution via `DB_FILE_NAME_CONVERT`) or OMF mode (`db_create_file_dest` + `db_recovery_file_dest`). OMF mode supports mixed-storage scenarios where primary uses regular file paths and standby uses FRA. OMF mode also protects against the post-setup new-PDB/new-datafile convert-pair gap: in Traditional mode a file created in a directory not covered by any `DB_FILE_NAME_CONVERT` pair becomes an `UNNAMED` placeholder on the standby and halts apply with ORA-01274 (see "Life After Setup" in docs/DATA_GUARD_WALKTHROUGH.md)
- **AIX 7.2 compatible**: Uses printf instead of echo -e, sed instead of grep -P

## Common Functions

`common/dg_functions.sh` provides:
- `log_info`, `log_warn`, `log_error` - Logging functions
- `run_sql`, `run_sql_with_header` - SQL execution helpers
- `get_db_parameter` - Get Oracle parameter value
- `check_oracle_env`, `check_nfs_mount`, `check_db_connection` - Validation functions
- `select_config_file` - Config file selection (auto-selects when only one exists)

## Wallet Setup for Peer Connectivity

After Data Guard is configured, you can set up Oracle Wallet on each DB host so that scripts like `dg_triage_sid.sh` and `dg_diag_sid.sh` can connect to the peer database without prompting for a password.

```bash
bash common/setup_dg_wallet.sh              # Run on primary
bash common/setup_dg_wallet.sh              # Run on standby
bash common/setup_dg_wallet.sh -w /path     # Custom wallet directory
```

The script auto-detects the local role, discovers the peer TNS alias from the broker, creates an auto-login wallet with SYS credentials, configures `sqlnet.ora`, and tests the connection. It is idempotent — re-running adds/updates credentials in an existing wallet.

`-A`/`--auto-password` generates the wallet password automatically instead of prompting. Re-running with `-A` against a wallet that already holds credentials (or whose auto-generated password can no longer be supplied) lists the existing credentials and requires typing `RECREATE WALLET` to confirm before rebuilding it - the rebuild happens in a staging directory and is swapped in only after every step succeeds, with the old wallet kept as a timestamped `.bak` copy.

## Validation Checks

Built-in validations:
- ARCHIVELOG mode, FORCE_LOGGING, password file (step 1)
- Disk space on standby (step 3)
- Port connectivity primary → standby (step 4)
- Listener port detection from `lsnrctl status` (step 1)

## Status Dashboard

`dg_status.sh` provides a quick health overview of a running Data Guard configuration. Run it from the jump host (or any machine with SSH access to both DB hosts).

```bash
bash dg_status.sh                    # Uses $ORACLE_SID or auto-detects from pmon
bash dg_status.sh -s cdb1            # Explicit SID
bash dg_status.sh -c myconfig.env    # Custom SSH config
```

**What it checks (both databases):** database role, open mode, protection mode, switchover status, force logging, flashback, DG broker status, currently running services, redo/standby redo log counts, archive destination errors, archive gaps, FRA usage (with 80%/90% thresholds), MRP apply status, transport/apply lag, archived log sequence gaps, UNNAMED datafile detection (ORA-01274: a datafile added outside convert-pair coverage halts redo apply), broker configuration including FSFO and per-member ORA errors, and recent Data Guard-related alert log entries.

**SID resolution:** `-s` flag > `$ORACLE_SID` > auto-detect from `ora_pmon_` process. Standby SID is always auto-detected.

**Exit codes:** `0` healthy, `1` warnings only, `2` errors present - suitable for cron/monitoring wrappers instead of scraping the colored text output. An unreachable host is reported explicitly (`UNREACHABLE`) rather than rendered as blank fields with a healthy status.

**Output control:** `--no-color` (or the `NO_COLOR` env var) disables ANSI color codes.

**Configurable thresholds** (env vars, override by exporting before running): `DG_FRA_WARN_PCT` (default 80), `DG_FRA_CRIT_PCT` (default 90), `DG_SEQ_GAP_WARN` (default 1), `DG_SEQ_GAP_CRIT` (default 5), `DG_LAG_WARN_SECONDS` (default 60).

See [docs/DG_STATUS.md](docs/DG_STATUS.md) for full details.

For local host checks without SSH, use the split commands:

```bash
bash dg_triage_sid.sh         # Fast triage, wallet-only by default
bash dg_diag_sid.sh           # Deep diagnostics, prompts if wallet auth fails
bash dg_triage_sid.sh -L      # Local + broker only (skip remote SQL)
bash dg_diag_sid.sh -P        # Force SYS password prompt for remote
```

`dg_check_sid.sh` is retained as a deprecated wrapper that forwards to `dg_triage_sid.sh` and always exits `0`.

See [docs/DG_CHECK.md](docs/DG_CHECK.md) for full details.

## Testing

### Unit Tests
- `tests/test_add_sid_to_listener.sh` - Tests the `add_sid_to_listener()` function
- `tests/test_file_name_convert.sh` - Tests `DB_FILE_NAME_CONVERT` / `LOG_FILE_NAME_CONVERT` pair generation (multi-directory coverage, dedup)
- `tests/test_path_token_remap.sh` - Tests step 2's per-path, case-aware, substring-safe DB-name token remapping
- `tests/test_counter_increment.sh` - Demonstrates why `((VAR++))` is banned under `set -e` and sweeps the repo for the construct (codebase uses `x=$((x+1))`)
- `tests/test_df_parsing.sh` - Tests `parse_df_available_kb` / `get_available_space_kb`; guards the `df -Pk` (POSIX format) requirement for AIX compatibility
- `tests/test_grep_portability.sh` - Tests broker-output detection patterns and sweeps the repo for GNU-grep-only usage (`grep -P`, `\s`, BRE `\|` alternation)
- `tests/test_sid_detection.sh` - Tests the SID-detection/validation pipeline used by `dg_status.sh` (`_detect_pmon_sid` / `_validate_sid`)

### End-to-End Tests
- `tests/e2e/run_e2e_test.sh` - Full E2E test orchestrator
- `tests/e2e/config.env` - Test environment configuration (jump host, DB hosts, Oracle paths)
- `tests/e2e/TEST_INSTRUCTIONS.md` - Full runbook with known issues and fixes

**To run E2E tests:**
```bash
bash ./tests/e2e/run_e2e_test.sh           # Full run (~20 min)
bash ./tests/e2e/run_e2e_test.sh --from step5  # Resume from a phase
bash ./tests/e2e/run_e2e_test.sh --only cleanup # Clean up
```

The test creates a database (DBCA, no OMF/FRA), runs all walkthrough steps, validates each step, and cleans up. It connects through a jump host via SSH ProxyJump and automates interactive prompts via piped stdin.

**Key gotchas for the test framework:**
- Always run with `bash` explicitly (zsh breaks SSH_OPTS word splitting)
- Config files auto-select when only one exists (no "1" needed in piped input)
- RMAN uses `cmdfile` parameter instead of heredoc (heredoc consumes piped stdin)
- `stty` calls in `prompt_password()` use `2>/dev/null || true` for piped stdin compatibility

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

`observer.sh` validates a pidfile's PID against the process's actual command line (must be a `dgmgrl` process) before trusting it as the running observer; stale or mismatched pidfiles are automatically cleaned up.

## Role-Aware Service Trigger (Optional)

After Data Guard setup is complete, you can deploy triggers that automatically start/stop services based on database role:

**Step 14: Deploy Service Trigger (on PRIMARY)**
```bash
./trigger/create_role_trigger.sh
```
This discovers running user services, creates PL/SQL package `SYS.DG_SERVICE_MGR` and two database triggers. Services are started on PRIMARY and stopped on STANDBY, triggered on both role change (switchover/failover) and database startup.

Standalone: both `create_role_trigger.sh` and `create_role_trigger_dedicated_user.sh` self-discover the primary/standby topology from `V$DATABASE` / `V$DATAGUARD_CONFIG` and do not require `standby_config_*.env`. The NFS share is optional - the generated SQL is written there when available, otherwise falls back to `$PWD`.

**Objects created:**
- `SYS.DG_SERVICE_MGR` - PL/SQL package with `MANAGE_SERVICES` procedure
- `SYS.TRG_MANAGE_SERVICES_ROLE_CHG` - Fires `AFTER DB_ROLE_CHANGE`
- `SYS.TRG_MANAGE_SERVICES_STARTUP` - Fires `AFTER STARTUP`

Objects replicate to standby automatically via redo apply. The script is restartable - re-running replaces existing objects with the updated service list.

**Alternative variant: dedicated user**
```bash
./trigger/create_role_trigger_dedicated_user.sh
```
Same behavior, but creates a dedicated database user (`DG_ADMIN`, or `C##DG_ADMIN` for CDB) with only the privileges required, and places the package and triggers under that user instead of `SYS`. Use this variant when policy disallows adding objects to `SYS`. Since the dedicated user cannot call SYS-only `DBMS_SYSTEM.KSDWRT` for alert-log writes, the script creates a narrow SYS-owned wrapper procedure (`SYS.DG_ALERT_LOG_MSG`) and grants `EXECUTE` on that wrapper only - not on `DBMS_SYSTEM` - to the dedicated user.

**Alternative variant: CDB / PDB-aware**
```bash
./trigger/create_role_trigger_cdb.sh
```
SYS-owned variant for **multitenant (CDB)** databases that manages services living inside PDBs as well as user services at the `CDB$ROOT` level. The base `create_role_trigger.sh` only manages services in the current container, which is insufficient when application services belong to PDBs.

Key differences from the base script:
- Verifies `V$DATABASE.CDB = YES` (errors and points to the base script otherwise).
- Discovers services as `(container, service)` pairs via `sql/queries/get_user_services_cdb.sql` (`V$ACTIVE_SERVICES` joined to `V$CONTAINERS`), excluding `PDB$SEED`, system services, and each container's default service.
- The `SYS.DG_SERVICE_MGR` package stores the pairs as records; `MANAGE_SERVICES` switches into the owning PDB (`ALTER SESSION SET CONTAINER`) before calling `DBMS_SERVICE`, then returns to `CDB$ROOT`. Per-service failures (e.g. a PDB only MOUNTED on the standby) are written to the alert log and never abort the others.
- Triggers (`AFTER DB_ROLE_CHANGE` / `AFTER STARTUP ON DATABASE`) still fire in `CDB$ROOT`; the role transition is CDB-wide. A PDB service only starts if the PDB is OPEN, so ensure PDBs auto-open (`SAVE STATE` or an open trigger). Generated SQL: `${NFS_SHARE}/dg_service_mgr_cdb_<PRIMARY_DB_UNIQUE_NAME>.sql`.
- **Active Data Guard (ADG) caveat:** a system trigger cannot switch containers (ORA-65123), so `MANAGE_SERVICES` defers the actual start/stop work to a one-time `DBMS_SCHEDULER.CREATE_JOB`. If the standby is opened read-only (Active Data Guard / real-time query), `CREATE_JOB` cannot write to the data dictionary and fails with `ORA-16000`; this is caught and only logged to the alert log (`DBMS_SYSTEM.KSDWRT`) - services are silently **not** stopped by this trigger on an ADG-opened standby. Watch for `DG_SERVICE_MGR SCHEDULE failed` entries in the alert log and stop such services manually if they must not run against a read-only standby.

**Create a role-aware PDB service**
```bash
./trigger/create_pdb_service.sh --pdb <PDB_NAME> --service <SERVICE_NAME> [--no-start] [--taf]
./trigger/create_pdb_service.sh <PDB_NAME> <SERVICE_NAME>          # positional form
```
Creates a service *inside* a PDB to be used as a Data Guard switchover/failover service (runs only on the side currently holding the PRIMARY role). Must run on the PRIMARY of a CDB; verifies the target PDB exists and is OPEN READ WRITE, then creates the service via `DBMS_SERVICE.CREATE_SERVICE` (idempotent — skips if it already exists) and starts it. `--taf` adds basic TAF attributes (`FAILOVER_TYPE=SELECT`, `FAILOVER_METHOD=BASIC`); `--no-start` creates without starting. The service definition replicates to the standby via redo. It does **not** save PDB state, so role-awareness comes from the `DG_SERVICE_MGR` trigger — after creating, (re-)run `create_role_trigger_cdb.sh` so the service is started on PRIMARY and stopped on STANDBY automatically. Note: `-s` is reserved (approval mode) by the shared arg parser, so the service flag is the long `--service` only.

**Create a role-aware CDB-level service**
```bash
./trigger/create_cdb_service.sh --service <SERVICE_NAME> [--no-start] [--taf]
./trigger/create_cdb_service.sh <SERVICE_NAME>                     # positional form
```
Creates a service in the ROOT container (`CDB$ROOT`) of a multitenant database for use as a Data Guard switchover/failover service. Must run on the PRIMARY of a CDB; creates the service via `DBMS_SERVICE` (idempotent — skips if it already exists) and starts it (`--no-start` to skip; `--taf` for basic TAF attributes). The definition replicates to the standby via redo. Role-awareness comes from the `DG_SERVICE_MGR` trigger — after creating, (re-)run `create_role_trigger_cdb.sh` so the service follows the PRIMARY role. For a service inside a PDB, use `create_pdb_service.sh` instead.

## Handoff Report (End-User Documentation)

After Data Guard is verified (and ideally after FSFO and the role-aware service trigger are in place), generate a Markdown handoff document for application teams that consume the database:

**Step 15: Generate Handoff Report (on PRIMARY)**
```bash
./primary/10_generate_handoff_report.sh
```

The script collects a status snapshot for both DBAs and application teams: roles, open modes, protection mode, standby `LogXptMode`, MRP/apply lag, archive gaps, FSFO state and threshold, broker config, role-trigger deployment status, and server-side `SQLNET.EXPIRE_TIME`. It emits per-service connection info in three flavors:

- **Primary-only** TNS + JDBC — writes / admin
- **Standby-only** TNS + JDBC — read-only reporting against an open standby. If the standby is `MOUNTED`, the report marks these strings as not currently usable; if it is `READ ONLY WITH APPLY`, it includes the Active Data Guard licensing note, apply-lag/read-your-writes caveat, and ORA-16000 no-DML warning
- **Role-aware failover** TNS + JDBC + Easy Connect Plus — single descriptor with both hosts in `ADDRESS_LIST`. Recommended for the application tier when `trigger/create_role_trigger.sh` is deployed and enabled: the service is only running on whichever side is primary, so clients automatically follow the active database after a switchover or failover

The report now includes application-facing sections for RPO/data-loss expectations, expected outage behavior with or without FSFO, role-trigger readiness warnings, Easy Connect Plus and driver mapping examples for ODP.NET / python-oracledb / SQLAlchemy, a concrete client/pool settings checklist, and quick verification commands that test both database hosts with `tnsping` and `nc -z`.

It also copies `docs/DG_APPLICATION_IMPACT.html` to `${NFS_SHARE}/dg_application_impact.html` when available and links it from "Notes for Client Teams". The Markdown remains self-contained with a 5-bullet "What changes for your application" summary covering commit latency, NOLOGGING jobs, sequence gaps, cold-cache brownout, and the reach-both-hosts firewall prerequisite.

User-visible services are discovered from `V$ACTIVE_SERVICES` (same logic as the role trigger), with the default `<DB_UNIQUE_NAME>` service always included. Output: `${NFS_SHARE}/dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.md` plus stdout. Re-run after listener changes, new services, or topology changes to refresh the report.

**Standalone variant: `dg_handoff.sh`** (root of repo)
```bash
./dg_handoff.sh
./dg_handoff.sh -o /tmp/handoff.md
./dg_handoff.sh --primary-host pri --standby-host stb --port 1521
```
Produces the same Markdown report against any existing Data Guard configuration without depending on `standby_config_*.env`, `common/dg_functions.sh`, or the NFS share. Topology (peer `DB_UNIQUE_NAME`, hostnames, listener port) is discovered from `V$DATABASE`, `V$DATAGUARD_CONFIG`, `V$LISTENER_NETWORK`, and `DGMGRL SHOW DATABASE VERBOSE`. Use the `--*-host` / `--port` flags when broker is down or discovery returns the wrong value. Output defaults to `./dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.md`. The standalone report references `DG_APPLICATION_IMPACT.html` only when the file is present next to the script or under `docs/`.

## NFS Artifact Cleanup

`primary/01_gather_primary_info.sh` and `primary/09_configure_fsfo.sh` stage `orapw*` password file copies (SYS password hash) on the group-readable NFS share, and `primary/08_security_hardening.sh` stages a refreshed `orapw*_hardened` copy; `primary/02_generate_standby_config.sh` and `standby/05_clone_standby.sh` leave a generated pfile and RMAN duplicate cmdfiles/logs behind. None of this is ever cleaned up automatically.

**Step 16: Clean Up NFS Artifacts (on any host with the share mounted, optional)**
```bash
./common/cleanup_nfs_artifacts.sh                 # default: password files, pfile, RMAN cmdfiles/logs
./common/cleanup_nfs_artifacts.sh -c /path/to/standby_config_<NAME>.env
./common/cleanup_nfs_artifacts.sh --all           # also remove config .env, handoff report, app-impact HTML
./common/cleanup_nfs_artifacts.sh -y              # skip the confirmation prompt
```

Run this once Data Guard has been verified (Step 7) and the handoff report (Step 15) has been reviewed. It selects (or accepts via `-c`/`--config`) the build's `standby_config_*.env`, prints exactly what will be removed and what will be kept, and requires confirmation before deleting anything.
