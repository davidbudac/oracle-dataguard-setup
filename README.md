# Oracle 19c Data Guard Setup Scripts

Automated scripts for building, verifying, and operating an Oracle 19c Physical Standby database with Data Guard Broker (DGMGRL).

## What's Included

- **Setup workflow** (steps 1-7) — gather primary info, generate config, prepare both sides, RMAN duplicate, broker setup, verification.
- **Optional hardening** — security hardening (step 8), Fast-Start Failover + observer (steps 9-10), role-aware service trigger (step 11), NFS artifact cleanup (step 12), Maximum Availability without FSFO (step 13).
- **Handoff report** (recommended, any time after step 7) — Markdown + styled HTML doc with topology, status, verdict, and per-service TNS/JDBC strings for application teams.
- **Operational tools** — SSH dashboard, local triage/diagnostics, standby-redo-log audit, SYNC commit-cost report, wallet setup for password-free peer access, standalone handoff regenerator.

## Prerequisites

**Primary**
- Oracle 19c, ARCHIVELOG mode, FORCE_LOGGING enabled
- Password file at `$ORACLE_HOME/dbs/orapw<SID>`, `REMOTE_LOGIN_PASSWORDFILE = EXCLUSIVE`

**Standby**
- Oracle 19c installed, same `ORACLE_HOME` path as primary
- Sufficient disk for database files

**Shared**
- NFS mount at `/OINSTALL/_dataguard_setup` on both hosts (use `nfs/01_setup_nfs_server.sh` and `nfs/02_mount_nfs_client.sh`)
- TCP 1521 reachable both ways

Filesystem storage only (no ASM); single-instance only (no RAC).

## Project Structure

```
dataguard_setup/
├── README.md                    # This file
├── WALKTHROUGH.md               # Concise step-by-step setup guide
├── CLAUDE.md                    # Project notes for AI assistants
│
├── nfs/                         # NFS server + client setup (run first)
├── primary/                     # PRIMARY-side steps (1, 2, 4, 6, 8, 9, 13) + the handoff report (10_...)
├── standby/                     # STANDBY-side steps (3, 5, 7)
├── fsfo/                        # observer.sh - lifecycle for FSFO observer
├── trigger/                     # Role-aware service triggers (SYS or dedicated user variant) + CDB/PDB service creation
│
├── migrate_noncdb_to_pdb/       # Non-CDB → PDB migration subproject (own README/WALKTHROUGH)
├── observer_sys_to_sysdg/       # Side kit: convert a SYS-authenticated FSFO observer to SYSDG (own README)
│
├── common/                      # Shared functions, wallet setup, status helpers
├── templates/                   # Reference templates (init, listener, tnsnames)
├── sql/                         # SQL/RMAN/DGMGRL command snippets used by the scripts
│
├── dg_status.sh                 # SSH dashboard - run from jump host against both DBs
├── dg_triage_sid.sh             # Fast local triage (run on DB host)
├── dg_diag_sid.sh               # Deep local diagnostics (run on DB host)
├── dg_check_sid.sh              # Deprecated wrapper - prefer triage/diag
├── dg_handoff.sh                # Standalone handoff report (no setup-time deps)
├── get_dg_config_url.sh         # Standalone interactive-diagram link for an existing configuration
├── dg_check_srl.sh              # Standby redo log checker - prints fix DDL for missing/undersized SRLs
├── dg_sync_impact.sh            # Standalone SYNC/FASTSYNC commit-latency impact report (ASH/AWR + histogram model)
│
├── docs/
│   ├── DATA_GUARD_WALKTHROUGH.md   # Detailed walkthrough with manual equivalents
│   ├── DG_STATUS.md                # dg_status.sh reference
│   ├── DG_CHECK.md                 # dg_triage / dg_diag reference
│   ├── DG_SYNC_IMPACT.md           # dg_sync_impact.sh reference + methodology
│   └── WALLET_SETUP.md             # Oracle Wallet for peer connectivity
│
└── tests/                       # Unit tests + E2E test suite
    └── e2e/                     # SSH-orchestrated end-to-end tests
```

## Quick Start

| Step | Server | Command | Notes |
|------|--------|---------|-------|
| 1  | PRIMARY  | `./primary/01_gather_primary_info.sh`    | Restartable |
| 2  | PRIMARY  | `./primary/02_generate_standby_config.sh`| Review config before continuing |
| 3  | STANDBY  | `./standby/03_setup_standby_env.sh`      | |
| 4  | PRIMARY  | `./primary/04_prepare_primary_dg.sh`     | |
| 5  | STANDBY  | `./standby/05_clone_standby.sh`          | RMAN duplicate; **not directly restartable** |
| 6  | PRIMARY  | `./primary/06_configure_broker.sh`       | |
| 7  | STANDBY  | `./standby/07_verify_dataguard.sh`       | Health check |
| 8  | PRIMARY  | `./primary/08_security_hardening.sh`     | Optional: lock SYS |
| 9  | PRIMARY  | `./primary/09_configure_fsfo.sh`         | Optional: enable FSFO |
| 10 | OBSERVER | `./fsfo/observer.sh setup` then `start`  | Optional: required for FSFO |
| 11 | PRIMARY  | `./trigger/create_role_trigger.sh`       | Optional: role-aware service start/stop |
| 12 | any host | `./common/cleanup_nfs_artifacts.sh`      | Optional: scrub password files / pfiles / RMAN artifacts off the share |
| 13 | PRIMARY  | `./primary/13_set_max_availability.sh`   | Optional: zero data loss **without** FSFO — skip if step 9 ran |

Recommended, any time after step 7 — run both **before** step 12's `--all` cleanup:

| Server | Command | Notes |
|--------|---------|-------|
| PRIMARY | `./primary/10_generate_handoff_report.sh` | Markdown + HTML handoff for app teams |
| BOTH    | `bash common/setup_dg_wallet.sh`          | Password-free peer access for the local tools |

`./trigger/create_role_trigger_dedicated_user.sh` is an alternative to step 11 that puts trigger objects under a dedicated user instead of `SYS`. For multitenant databases, `./trigger/create_role_trigger_cdb.sh` manages PDB services, and `./trigger/create_cdb_service.sh` / `./trigger/create_pdb_service.sh` create role-aware services at the `CDB$ROOT` or PDB level.

See [`WALKTHROUGH.md`](WALKTHROUGH.md) for prompts, outputs, and verification per step. See [`docs/DATA_GUARD_WALKTHROUGH.md`](docs/DATA_GUARD_WALKTHROUGH.md) for the manual-equivalent commands.

### Restartability

- **Steps 1-4** — idempotent, re-runnable.
- **Step 5** — once RMAN duplicate starts, you must shut down the standby instance and remove its data files / control files / redo logs before re-running. The script requires you to retype the standby `DB_UNIQUE_NAME` before starting, to reduce accidental execution.
- **Steps 6-7** — re-runnable; remove the broker config with `REMOVE CONFIGURATION` first if needed.
- **Step 8** — rotation and lock are separate calls with separate exit codes; a partial run prints an ACTION REQUIRED block and exits `1`. After it runs, SYS is locked and step 5 can no longer clone until SYS is temporarily unlocked.
- **Step 13** — idempotent; a no-op if step 9 already set MAXAVAILABILITY + FASTSYNC.
- **Handoff report** — re-run any time; refreshes the doc.

## Runtime Modes

All workflow scripts that source `common/dg_functions.sh` accept:

| Flag | Env var | Effect |
|------|---------|--------|
| `--check`, `--plan`     | —              | Preflight only; print plan and exit before changes |
| `--verbose`             | `VERBOSE=1`    | Trace shell commands (suppressed around password prompts) |
| `--approval-mode`       | `APPROVAL_MODE=1` | Pause before mutating actions with action/impact/log preview |
| `--suspicious`          | `SUSPICIOUS=1` | Backward-compatible alias for `--approval-mode` |

```bash
./standby/03_setup_standby_env.sh --check
./standby/05_clone_standby.sh --approval-mode
APPROVAL_MODE=1 VERBOSE=1 ./primary/09_configure_fsfo.sh
```

Each step writes a state file under `${NFS_SHARE}/state/` alongside logs in `${NFS_SHARE}/logs/`. The state file records current step, final status, generated artifacts, and the suggested next step.

## Operational Tools

After Data Guard is running, use these to monitor and document the configuration.

```bash
# Cross-host dashboard from a jump host (or anywhere with SSH to both DBs)
bash dg_status.sh                # Auto-detects SID from $ORACLE_SID or pmon
bash dg_status.sh -s cdb1        # Explicit primary SID
bash dg_status.sh -c myconfig    # Custom SSH config

# Local checks on a DB host
bash dg_triage_sid.sh            # Fast triage (wallet-only by default)
bash dg_diag_sid.sh              # Deep diagnostics (prompts if wallet auth fails)
bash dg_triage_sid.sh -L         # Skip remote SQL
bash dg_diag_sid.sh -P           # Force SYS password prompt for remote

# Wallet setup for password-free peer connections (run on each host)
bash common/setup_dg_wallet.sh

# Handoff report regeneration (no NFS / no setup config required)
./dg_handoff.sh
./dg_handoff.sh --primary-host pri --standby-host stb --port 1521

# Interactive diagram link for an existing configuration (run on a DB host)
./get_dg_config_url.sh           # summary on stderr, URL on stdout
./get_dg_config_url.sh -q        # URL only

# Standby redo log audit - prints fix DDL, executes nothing
./dg_check_srl.sh                # both sides, peer via wallet
./dg_check_srl.sh -p             # prompt for SYS password for the peer
./dg_check_srl.sh -L             # local only

# What is synchronous transport costing commits? (run on PRIMARY)
./dg_sync_impact.sh                          # ASH last 24h, AWR last 7 days
./dg_sync_impact.sh --baseline-begin '2026-07-01 00:00' --baseline-end '2026-07-08 00:00'
./dg_sync_impact.sh --auto-baseline          # detect the pre-SYNC baseline from AWR
./dg_sync_impact.sh --no-pack                # no Diagnostics Pack license
./dg_sync_impact.sh --html -o impact.html    # self-contained HTML report
```

References: [`docs/DG_STATUS.md`](docs/DG_STATUS.md), [`docs/DG_CHECK.md`](docs/DG_CHECK.md), [`docs/DG_SYNC_IMPACT.md`](docs/DG_SYNC_IMPACT.md), [`docs/WALLET_SETUP.md`](docs/WALLET_SETUP.md).

## Side Toolkits

Self-contained subprojects with their own docs, outside the numbered workflow:

- [`observer_sys_to_sysdg/`](observer_sys_to_sysdg/README.md) — convert an existing FSFO observer that authenticates as SYS to a dedicated SYSDG-only user. For configurations built by hand or by other tooling; builds made with steps 9-10 here already use SYSDG.
- [`migrate_noncdb_to_pdb/`](migrate_noncdb_to_pdb/README.md) — migrate a non-CDB with its own standby into an existing CDB with its own standby, without recreating either standby.

## Common DGMGRL Commands

```bash
dgmgrl / "show configuration"
dgmgrl / "show database 'PRODSTBY'"
dgmgrl / "validate database 'PRODSTBY'"
dgmgrl / "switchover to 'PRODSTBY'"
dgmgrl / "show fast_start failover"
```

Bounce apply / transport when MRP stalls or gaps appear:

```bash
dgmgrl / "edit database 'PRODSTBY' set state=apply-off"
dgmgrl / "edit database 'PRODSTBY' set state=apply-on"

dgmgrl / "edit database 'PROD' set state=transport-off"
dgmgrl / "edit database 'PROD' set state=transport-on"
```

## Testing

```bash
# Unit tests (see CLAUDE.md for what each suite covers)
for t in tests/test_*.sh; do bash "$t"; done

# End-to-end (creates a test DB, runs steps 1-7, validates, cleans up; ~20 min)
cp tests/e2e/config.env.template tests/e2e/config.env   # then edit
bash ./tests/e2e/run_e2e_test.sh
bash ./tests/e2e/run_e2e_test.sh --from step5
bash ./tests/e2e/run_e2e_test.sh --only cleanup
```

`tests/e2e/run_e2e_test_cdb.sh` is the CDB variant. See `tests/e2e/TEST_INSTRUCTIONS.md` for the full runbook and known issues.

## Requirements

- Oracle Database 19c
- Bash
- `sqlplus`, `rman`, `lsnrctl`, `dgmgrl` on `PATH`
- NFS mount at `/OINSTALL/_dataguard_setup`
- AIX 7.2 / Linux compatible (uses `printf` and POSIX `sed`)

## License

MIT — see [`LICENSE`](LICENSE).
