# Project: Oracle 19c Data Guard Setup Scripts

Automated scripts for setting up Oracle 19c Physical Standby databases using Data Guard Broker (DGMGRL).

## Project Structure

```
dg_status.sh     - Quick Data Guard health dashboard (run from jump host)
dg_triage_sid.sh - Fast local Data Guard triage (run directly on DB host)
dg_diag_sid.sh   - Deep local Data Guard diagnostics (run directly on DB host)
dg_check_sid.sh  - Deprecated wrapper to dg_triage_sid.sh
dg_handoff.sh    - Standalone handoff report generator (post-setup; no NFS/config dependencies); writes the Markdown report plus a styled self-contained HTML twin next to it
get_dg_config_url.sh    - Standalone generator for the interactive dataguard-doc visualizer link of an existing configuration (sqlplus / as sysdba; flags --primary-host/--standby-host/--observer-host/--port/--service/--base-url, -q for URL-only output)
dg_sync_impact.sh - Standalone SYNC/FASTSYNC commit-latency impact report (run on PRIMARY): estimates the added latency per commit as E[max(L,R)]-E[L] from V$EVENT_HISTOGRAM_MICRO (L='log file parallel write', R='SYNC Remote Write'), brackets it with avg-based bounds, scales it via AWR/ASH, and ranks the top-10 latency spikes both ways - slowest V$REDO_DEST_RESP_HISTOGRAM response buckets (with last-seen time) and worst AWR snapshots by lower-bound added ms/commit (flags --ash-hours/--days/--baseline-begin/--baseline-end/--auto-baseline/--no-pack/--html/-o; exit codes 0 report, 1 fatal/not-primary, 2 bad args). All durations are reported in milliseconds (rates and uptime excepted); every section opens with a one-line `Source:` naming its views, and every table is followed by the exact query that produced it (recorded verbatim by `run_sql` into a temp dir, emitted as a fenced ```sql block, rendered as a collapsed `<details>` in HTML). Markdown by default; --html renders the same emitter through a built-in POSIX-awk converter into a self-contained page with KPI cards for the headline numbers and, below each table, a strip of charts (one per plottable column, each on its own scale; a snapshot/hour axis with >= 6 points becomes a time-series column chart) while the cells themselves stay plain; if the converter's awk fails anyway, the page still ships with the Markdown embedded verbatim instead of being truncated mid-report. See docs/DG_SYNC_IMPACT.md
dg_check_srl.sh  - Standby redo log checker: verifies SRL count/size on both sides and prints fix DDL (flags -p/--prompt-password, -L/--local-only, -d/--srl-path; exit codes 0 compliant / 1 DDL needed / 2 argument, pre-flight, or data-collection error). SRLs created without a THREAD clause sit at THREAD#=0 until first use (step 4 created them that way before 2026-08; it now assigns THREAD explicitly); the checker counts THREAD#=0 SRLs as a shared pool toward each thread's requirement instead of demanding duplicates, so both old and new builds check out correctly
migrate_noncdb_to_pdb/ - Non-CDB to PDB migration subproject: migrate a non-CDB with its own standby into an existing CDB with its own standby, without recreating either standby (has its own README/WALKTHROUGH)
observer_sys_to_sysdg/ - Standalone side toolkit (NOT part of the numbered workflow): convert an existing FSFO observer that authenticates as SYS to a dedicated SYSDG-only user - create the user on the primary (01), swap/create the observer wallet credentials and restart the observer (02), verify (03); self-contained (no common/ or NFS dependencies), see its README.md
add_observer/    - Standalone side toolkit (NOT part of the numbered workflow): add an FSFO observer on a THIRD host to an existing, already-working Data Guard configuration (built by this repo or not). `01_prepare_primary.sh` runs on the PRIMARY - discovers the topology (peer DB_UNIQUE_NAME, hostnames, and host/port/service by running `tnsping` on each member's broker `DGConnectIdentifier`), reports FSFO readiness (SHOW CONFIGURATION, VALIDATE DATABASE, Flashback Database on both members, protection mode, SRLs), creates/verifies the dedicated SYSDG observer user (CDB-aware), optionally enables FSFO (`--enable-fsfo`), and writes a self-contained bundle for the third host. `02_setup_observer_host.sh` / `03_observer_ctl.sh` / `04_verify_observer.sh` run there: TNS entries + auto-login wallet + both-database connectivity proof; start/stop/restart/status/log/boot lifecycle; end-state verification. Never changes protection mode, LogXptMode or transport. Self-contained (no common/ or NFS dependencies), see its README.md
nfs/             - NFS setup scripts (run before Data Guard setup)
primary/         - Scripts to run on PRIMARY server (Steps 1, 2, 4, 6, 8, 9, 10, 13)
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

Numbering matches `docs/DATA_GUARD_WALKTHROUGH.md` (the authoritative step reference): NFS setup is Step 0a/0b (prerequisite, not counted in the main 1-13 sequence), and observer wallet setup + start are both part of Step 10.

0a. `nfs/01_setup_nfs_server.sh` - Setup NFS (on NFS server, requires sudo)
0b. `nfs/02_mount_nfs_client.sh` - Mount NFS (on both servers, requires sudo). On the host that *is* the NFS server it detects itself and skips the mount - the export path and mount path are the same directory, and an NFS self-mount would shadow the export and make `rpc.mountd` refuse every other client ("fsid= required"). The write test runs as the share owner (oracle), since root is squashed to nobody on the 750 export
1. `primary/01_gather_primary_info.sh` - Collect primary DB info
2. `primary/02_generate_standby_config.sh` - Generate standby config (user reviews)
3. `standby/03_setup_standby_env.sh` - Prepare standby environment
4. `primary/04_prepare_primary_dg.sh` - Configure primary for DG
5. `standby/05_clone_standby.sh` - RMAN duplicate (prompts for SYS password)
6. `primary/06_configure_broker.sh` - Configure DGMGRL
7. `standby/07_verify_dataguard.sh` - Verify setup
8. `primary/08_security_hardening.sh` - Lock SYS account (optional)
9. `primary/09_configure_fsfo.sh` - Configure Fast-Start Failover (optional)
10. `fsfo/observer.sh setup` then `fsfo/observer.sh start` - Set up and start the observer (on observer server, optional)
11. `trigger/create_role_trigger.sh` - Deploy role-aware service trigger (on PRIMARY, optional)
12. `common/cleanup_nfs_artifacts.sh` - Remove sensitive/transient setup artifacts (password file copies, generated pfiles, RMAN files) from the NFS share once the build is verified (optional, run from any host with the share mounted)
13. `primary/13_set_max_availability.sh` - Validate the configuration is healthy, then set protection mode MAXIMUM AVAILABILITY + LogXptMode=FASTSYNC (on PRIMARY, optional). For zero-data-loss protection *without* FSFO — Step 9 already applies both settings when enabling FSFO, so skip this if Step 9 was run. Needs the `standby_config_*.env` from the NFS share, so run it before Step 12's `--all` cleanup (the default cleanup keeps the .env)

Recommended, run any time after Step 7 (not part of the walkthrough's numbered sequence, but worth doing before Step 12 cleanup since cleanup can remove it): `primary/10_generate_handoff_report.sh` - Generate end-user handoff report with status snapshot and TNS/JDBC connection strings (on PRIMARY).

## Restartability

**Steps 1-4 are fully restartable** - these scripts are idempotent and can be re-run from step 1 if needed. They gather information, generate configs, and apply settings that can be safely overwritten.

**Step 5 (Clone Standby) is NOT directly restartable** - once RMAN duplicate starts, you cannot simply re-run the script. To restart from step 5:
1. Shut down the standby instance
2. Remove all standby data files, control files, and redo logs
3. Re-run step 5

**Step 8 hardening runs in two phases** - the SYS password rotation and the ACCOUNT LOCK are separate sqlplus calls with separate exit codes. If rotation succeeds but the lock fails, the script keeps going (the primary is already rotated, so the standby's password file copy is stale either way): it stages the refreshed password file, prints an ACTION REQUIRED block with the exact state SYS is in, and exits 1. It also refreshes the step-1 staged copy `orapw<PRIMARY_ORACLE_SID>` on the NFS share (not just the `_hardened` name), so a re-run of step 3 after hardening installs the *rotated* password file. The absence of ORA-16191 immediately after rotation is expected (existing transport connections stay authenticated until they reconnect) and is reported as such, not as proof transport survived.

**Post-hardening re-clone limitation:** if `primary/08_security_hardening.sh` has already run, SYS on the primary is locked. `standby/05_clone_standby.sh` detects this at the password-verification step (`ORA-28000`) and prints the fix: temporarily `ALTER USER SYS ACCOUNT UNLOCK` + `IDENTIFIED BY <temp password>` on the primary, re-run step 5, then re-run `primary/08_security_hardening.sh` afterward to re-harden SYS (fresh random password, re-lock) and re-propagate the refreshed password file to the standby.

**Steps 6-7 are restartable** - the broker configuration can be removed with `REMOVE CONFIGURATION` in DGMGRL and recreated. Step 7 is read-only verification.

**Step 13 is idempotent** - if the configuration is already MAXIMUM AVAILABILITY with LogXptMode=FASTSYNC on both databases, it reports that and exits successfully without prompting.

## Key Design Decisions

- **Use DGMGRL for all Data Guard configuration** - Always prefer Data Guard Broker commands over manual ALTER SYSTEM/ALTER DATABASE commands when configuring anything Data Guard related
- **Data Guard Broker (DGMGRL)** manages DG parameters instead of manual ALTER SYSTEM commands
- **NFS share** at `/OINSTALL/_dataguard_setup` for file exchange between servers
- **Single source of truth**: `standby_config_<STANDBY_DB_UNIQUE_NAME>.env` contains all configuration. After editing it, run `02_generate_standby_config.sh --regenerate` to update derived files (pfile, TNS, listener, DGMGRL). Regenerate re-derives the convert pairs from the `PRIMARY_*_PATHS`/`STANDBY_*_PATHS` arrays (via the shared `build_convert_pairs()`, used by both normal and regenerate modes) and **persists the rebuilt `DB_FILE_NAME_CONVERT`/`LOG_FILE_NAME_CONVERT` strings back into the .env** — step 5 feeds RMAN's `SPFILE SET` from the .env and that overrides the regenerated pfile, so stale strings there would silently defeat an edited layout. Edit the path arrays, not the convert strings; mismatched/missing arrays skip re-derivation and the stored strings are used verbatim (with a warning)
- **Asymmetric standby layouts**: step 2 (Traditional mode) surfaces the derived layout twice before anything is written — a per-path confirmation for paths with no DB-name component to substitute (redo/temp on their own mount, otherwise left pointing at the primary → `ORA-17502`/`ORA-19504` in step 5), and `_review_path_mappings()`'s numbered override table for the case where substitution worked but the standby base mount differs entirely. Standby `ORACLE_BASE`/`ORACLE_HOME` are prompted rather than assumed equal to the primary's. All three are TTY-gated (`[[ -t 0 ]]`) — **any new prompt must be**, or it desynchronizes the E2E suite's fixed piped-stdin input sequence. Non-interactive runs take the derived defaults; use edit-env + `--regenerate` instead
  - Known limitation (**now warned about, not silent**): primary with data+redo in ONE directory and a standby that splits them puts ORLs/SRLs in the standby data dir — both pairs share the same primary path, so the length sort can't separate them and Oracle's first-prefix match takes the datafile pair. `build_convert_pairs()` detects this (primary redo dir == a primary data dir, but their standby targets differ) and warns that the standby redo dir will stay unused. Unfixable by pair ordering: a convert pair remaps a primary *filename*, and nothing distinguishes an ORL from a datafile when they share one primary directory — a split standby needs a distinct primary redo dir too. Same root cause as the existing SRL-contradiction warning
  - `build_convert_pairs()` is **duplicated verbatim** in `tests/test_file_name_convert.sh`; the script is the source of truth and Test 11 fails on any drift (it diffs the two copies). Edit the script, then re-copy into the test
- **Concurrent builds**: All generated files include DB_UNIQUE_NAME to support multiple DG setups
- **TNS alias domain qualification**: step 2 qualifies the generated TNS aliases with `NAMES.DEFAULT_DOMAIN` from the primary's sqlnet.ora when set (falling back to `DB_DOMAIN`) - sqlnet appends its default domain to every unqualified alias at resolution time, so unqualified generated entries would be unresolvable on such hosts (surfaces as ORA-17627/ORA-12154 mid-RMAN-duplicate in step 5). A qualified alias name resolves exactly whether or not the resolving host sets a default domain
- **Passwords prompted at runtime**, never stored
- **Filesystem storage** (not ASM), single instance (not RAC)
- **Storage mode choice**: Step 2 offers Traditional (path substitution via `DB_FILE_NAME_CONVERT`) or OMF mode (`db_create_file_dest` + `db_recovery_file_dest`). OMF mode supports mixed-storage scenarios where primary uses regular file paths and standby uses FRA. OMF mode also protects against the post-setup new-PDB/new-datafile convert-pair gap: in Traditional mode a file created in a directory not covered by any `DB_FILE_NAME_CONVERT` pair becomes an `UNNAMED` placeholder on the standby and halts apply with ORA-01274 (see "Life After Setup" in docs/DATA_GUARD_WALKTHROUGH.md)
- **AIX 7.2 compatible**: Uses printf instead of echo -e, sed instead of grep -P, POSIX BRE only (no `\+`/`\?`), `df -Pk`, `du -sk`, and no bash 4 syntax. Linux-only binaries (`timeout`, `nc`, `systemctl`, `mktemp`, `base64`, `tput`) are always behind a `command -v` guard with a working fallback - e.g. step 4's port check falls back to `tnsping` against a raw descriptor, since AIX ships neither `nc` nor `timeout`. Enforced by `tests/test_aix_portability.sh`.
  The two `nfs/` scripts are the deliberate exception: they are Linux-only (yum/dnf/apt, systemd, `exportfs`, `mount -t nfs4`, `/etc/fstab`) and now stop on AIX with the AIX-native sequence (`mknfs`/`chnfsdom`/`mknfsexp`, `mknfsmnt`) printed instead of half-running Linux commands as root

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

## Redo Generation Statistics (Step 1)

Step 1 reports an archive log overview (mode, destination, logs on disk, sequence range) plus redo generation statistics derived from `V$ARCHIVED_LOG`: daily volume for the last 14 days with each day's busiest hour, an hour-of-day profile for the last 7 days, and averages/peaks per day and per hour. From the peak hour it derives the **minimum redo transport bandwidth** (peak hour + 30% headroom) and the archive space needed per day of retention. It warns when the peak log switch rate exceeds 12/hour (fix online redo log size *before* the standby exists — standby redo logs must match it) and when the FRA is smaller than one day of redo.

Design notes:
- `V$ARCHIVED_LOG` rows are de-duplicated by `(THREAD#, SEQUENCE#, RESETLOGS_ID)` — one archived log has a row per destination, so a plain `SUM()` multiplies the volume by the number of local destinations. `STANDBY_DEST='NO'` excludes shipped logs on re-runs.
- History is bounded by `CONTROL_FILE_RECORD_KEEP_TIME` (7 days by default); the observed window is reported rather than assumed.
- With no archive history (fresh or freshly restarted DB — including the E2E test), it falls back to `V$SYSSTAT` "redo size" since startup, sets `REDO_STATS_SOURCE=INSTANCE_STARTUP`, and reports peak == average.
- The whole section is informational: a failed or empty query degrades to zeros plus a warning, never a failed step.
- Values are persisted to `primary_info_<DB_UNIQUE_NAME>.env` (`ARCHIVE_*`, `REDO_*`). Since that file is sourced by later steps, label fields are sanitized to shell-safe characters and no value contains a `$`.

## Status Dashboard

`dg_status.sh` provides a quick health overview of a running Data Guard configuration. Run it from the jump host (or any machine with SSH access to both DB hosts).

```bash
bash dg_status.sh                    # Uses $ORACLE_SID or auto-detects from pmon
bash dg_status.sh -s cdb1            # Explicit SID
bash dg_status.sh -c myconfig.env    # Custom SSH config
```

**What it checks (both databases):** database role, open mode, protection mode, switchover status, force logging, flashback, DG broker status, currently running services, redo/standby redo log counts, archive destination errors, archive gaps, FRA usage (with 80%/90% thresholds), MRP apply status, transport/apply lag, archived log sequence gaps, UNNAMED datafile detection (ORA-01274: a datafile added outside convert-pair coverage halts redo apply), broker configuration including FSFO and per-member ORA errors, and recent Data Guard-related alert log entries.

**SID resolution:** `-s` flag > `$ORACLE_SID` > auto-detect from `ora_pmon_` process. Standby SID is always auto-detected.

**Exit codes:** `0` healthy, `1` warnings only, `2` errors present, `3` usage/config error (bad flag, missing option argument, missing config keys, invalid SID) - suitable for cron/monitoring wrappers instead of scraping the colored text output. An unreachable host is reported explicitly (`UNREACHABLE`) rather than rendered as blank fields with a healthy status; an unreachable standby (or one returning no lag data) renders the replication state as `UNKNOWN`, never `IN SYNC`. When FSFO is enabled, a missing observer (`FS_FAILOVER_OBSERVER_PRESENT`) is an error. `JUMP_HOST` may be empty in the config - the DB hosts are then reached directly (same convention as the E2E harness).

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
- `tests/test_aix_portability.sh` - Repo-wide AIX 7.2 sweep of the shipped (non-test) scripts: GNU-only sed/coreutils flags and GNU BRE extensions, bash 4+ syntax (`mapfile`, `declare -A`, `${v^^}`), Linux-only binaries (`timeout`, `nc`, `systemctl`, `base64`, `mktemp`, `tput`) used without a `command -v` guard - heredocs and `echo`/`printf` lines are excluded so printed command *examples* don't trip it - and the AIX platform guard in both `nfs/` scripts. `nfs/01`/`nfs/02` and `tests/**` are out of scope by design (see the header)
- `tests/test_sid_detection.sh` - Tests the SID-detection/validation pipeline used by `dg_status.sh` (`_detect_pmon_sid` / `_validate_sid`)
- `tests/test_visualizer_url.sh` - Tests the dataguard-doc visualizer link helpers embedded in both handoff scripts and `get_dg_config_url.sh` (block-drift diff across all three copies, base64url payload, field mapping/omission, JSON escaping)
- `tests/test_handoff_html.sh` - Tests the handoff HTML renderer embedded in both handoff scripts (block-drift diff between the two copies, full Markdown-subset conversion fixture: headings, tables, fences, checklist items, verdict pill classes, callouts, escaping, tag balance, AIX-awk array rules)
- `tests/test_sync_impact.sh` - Tests `dg_sync_impact.sh` with a stubbed `sqlplus` dispatching on the `-- QTAG:` markers embedded in every query (argument validation, fatal paths, derived-number math, the top-latency-spike rankings and their ordering, per-section degradation, `--no-pack`, no-SYNC-destination mode, and the `--auto-baseline` scenarios: happy-path window pick, all-SYNC / no-SYNC-snapshots retention edges, flag conflicts, degradation). Also guards the `--html` renderer's AIX-awk portability rules (no function-local arrays, globals seeded in `BEGIN`, no `arr[i,j]` multi-subscripts — AIX 7.2 awk aborts with `0602-558 cannot be used as an array`) and the Markdown-verbatim fallback when the converter's awk dies

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
This creates an observer user with SYSDG privilege, sets MAXIMUM AVAILABILITY mode, enables FSFO. On a multitenant primary (`V$DATABASE.CDB = YES`) the observer user must be a common user: the script detects this, accepts `#` in usernames, and auto-prefixes `C##` (TTY-confirmed; logged and applied automatically in non-interactive runs). SYSDG possession is checked via `V$PWFILE_USERS` (administrative privileges never appear in `DBA_ROLE_PRIVS`).

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

## Adding an Observer to an Existing Configuration (Third Host)

`add_observer/` retrofits an FSFO observer onto a Data Guard configuration that
already exists and already works, placing it on a **third host** rather than on
either database host. It is standalone - no `standby_config_*.env`, no NFS share,
no `common/dg_functions.sh` - so the generated bundle can be copied to a host that
has never seen this repository.

```bash
# on the PRIMARY
./add_observer/01_prepare_primary.sh --observer-host obs1 [--enable-fsfo]
scp -r ./observer_bundle_<PRIMARY_DB_UNIQUE_NAME> obs1:~/

# on the THIRD host (Oracle client, Administrator type, or a DB home)
./02_setup_observer_host.sh && ./03_observer_ctl.sh start && ./04_verify_observer.sh
./03_observer_ctl.sh boot     # systemd unit + cron @reboot + watchdog
```

Design notes:
- **Discovery over assumption.** Host/port/service come from `tnsping` on each
  member's broker `DGConnectIdentifier` (what the members actually use to reach
  each other), with the broker `HostName` property and `V$LISTENER_NETWORK` as
  fallbacks and `--primary-host`/`--standby-host`/`--port` as overrides.
- **The protection mode is never changed.** The FSFO flavour adapts to it instead:
  `MAXIMUM AVAILABILITY`/`PROTECTION` -> `FastStartFailoverThreshold`;
  `MAXIMUM PERFORMANCE` -> `FastStartFailoverLagLimit` (asynchronous FSFO, not
  zero-data-loss - stated as such in the output).
- **Both connections are proven before anything starts.** Script 02 aborts if the
  observer user cannot log in `AS SYSDG` to the *standby* (usually ORA-01017 from a
  password file that never propagated) - an observer the standby rejects cannot
  complete a failover.
- **Named observers** (12.2+) are used when available; `START OBSERVER <name>`
  failing falls back to the unnamed form rather than leaving no observer at all.
- **Reboot survival is explicit.** `03_observer_ctl.sh boot` prints a systemd unit
  (`Type=oneshot` + `RemainAfterExit`, because the real observer is a detached
  child), a cron `@reboot` line, and a watchdog driven by `status`, which exits 0
  only when the primary reports `FS_FAILOVER_OBSERVER_PRESENT=YES`.

## Maximum Availability Without FSFO (Optional)

**Step 13: Set Maximum Availability Protection (on PRIMARY)**
```bash
./primary/13_set_max_availability.sh
```
Raises the configuration to zero-data-loss protection without enabling Fast-Start Failover: validates first (broker `SHOW CONFIGURATION` health, `VALIDATE DATABASE` readiness on both members via `sql/dgmgrl/validate_database.dgmgrl`, transport/apply lag, archive destination errors), then sets `LogXptMode=FASTSYNC` on both databases and `EDIT CONFIGURATION SET PROTECTION MODE AS MAXAVAILABILITY`, and finally polls `SHOW CONFIGURATION` until it returns SUCCESS.

- Skip this step if Step 9 (FSFO) was run — FSFO setup already applies both settings; the script detects that and exits as a no-op.
- If FSFO is enabled but the settings don't match (mixed state), the script refuses and points to `DISABLE FAST_START FAILOVER` / re-running Step 9, since the broker rejects `LogXptMode` edits on FSFO members.
- Validation findings (not "Ready for Switchover: Yes", archive dest errors, broker warnings) require explicit confirmation to proceed; `-n`/`--check` runs stop at the preflight summary without changing anything.
- The broker itself is the last validator: `ORA-16627` on the mode change means the standby is not synchronized.

## Role-Aware Service Trigger (Optional)

After Data Guard setup is complete, you can deploy triggers that automatically start/stop services based on database role:

**Step 11: Deploy Service Trigger (on PRIMARY)**
```bash
./trigger/create_role_trigger.sh
```
This discovers running user services, creates PL/SQL package `SYS.DG_SERVICE_MGR` and two database triggers. Services are started on PRIMARY and stopped on STANDBY, triggered on both role change (switchover/failover) and database startup.

Standalone: both `create_role_trigger.sh` and `create_role_trigger_dedicated_user.sh` self-discover the primary/standby topology from `V$DATABASE` / `V$DATAGUARD_CONFIG` and do not require `standby_config_*.env`. The NFS share is optional - the generated SQL is written there when available, otherwise falls back to `$PWD`.

**Multitenant guard:** both scripts refuse to run on a CDB (`V$DATABASE.CDB = YES`) and point to `create_role_trigger_cdb.sh` - on a CDB their container-blind `DBMS_SERVICE` calls would silently mismanage PDB services. This makes the SYS-owned CDB variant the only multitenant path; a CDB-aware *dedicated-user* variant does not exist yet (known gap for shops that both run CDBs and disallow SYS objects). Manually entered service names are resolved case-insensitively against `DBA_SERVICES`/`V$ACTIVE_SERVICES` (canonical casing is used; unknown names need TTY confirmation), and hyphens are allowed for domain-qualified names.

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

**Generate Handoff Report (on PRIMARY, recommended - see note in Execution Order above)**
```bash
./primary/10_generate_handoff_report.sh
```

The script collects a status snapshot for both DBAs and application teams: roles, open modes, protection mode, standby `LogXptMode`, MRP/apply lag, archive gaps, FSFO state (threshold shown only when FSFO is enabled), broker config, role-trigger deployment status, and server-side `SQLNET.EXPIRE_TIME`. The report opens with an **At a Glance** section (verdict + one-line RPO/failover/readability facts + which connect string to hand out), then the application-facing sections (1 Connection Strings, 2 Application Impact, 3 Client and Pool Settings, 4 Verification); all DBA-only material (topology, status snapshot, broker output, datafile/PDB convert-pair note, discovery warnings) lives in a closing **Appendix: DBA Snapshot**. The **Verdict** is computed with each reason named *and an action attached* (e.g. which script to run): ERROR on broker-config errors/ORA- diagnostics, failure-state switchover status, or apply lag beyond `DG_SEQ_GAP_CRIT` sequences; WARNING on lesser findings (broker warnings, role trigger not deployed, standby readability unknown, no user-created service in the standalone variant); HEALTHY only when nothing fired. `DG_HANDOFF_ENV` / `DG_HANDOFF_CONTACT` (env vars; `--env`/`--contact` flags on `dg_handoff.sh`) add an environment label and DBA-contact chip to the header. Each service's HA attributes are read from the dictionary (`sql/queries/get_service_ha_attributes.sql` in step 10, an inline `CDB_SERVICES` query in `dg_handoff.sh` - both case-insensitive on the name, since the dictionary stores a PDB default service uppercased) and stated per service as facts: TAF type/method/retries/delay, Transaction Guard `COMMIT_OUTCOME` (`TRUE`/`YES` both mean enabled), `DRAIN_TIMEOUT`, `FAILOVER_RESTORE`. The standby's open mode is derived from the broker's `Real Time Query` field (19c DGMGRL prints no "Open Mode" line) plus, in the step-10 variant, a best-effort wallet connect. Hostname discovery prefers the broker's `HostName` property; `DGConnectIdentifier` is only trusted when it is a genuine easy-connect string, never a TNS alias. The default `<DB_UNIQUE_NAME>` service is flagged as NOT managed by the role trigger. The step-10 variant emits per-service connection info in three flavors:

- **Primary-only** TNS + JDBC — writes / admin
- **Standby-only** TNS + JDBC — read-only reporting against an open standby. If the standby is `MOUNTED`, the report marks these strings as not currently usable; if it is `READ ONLY WITH APPLY`, it includes the Active Data Guard licensing note, apply-lag/read-your-writes caveat, and ORA-16000 no-DML warning
- **Role-aware failover** TNS + JDBC + Easy Connect Plus — single descriptor with both hosts in `ADDRESS_LIST`. Recommended for the application tier when `trigger/create_role_trigger.sh` is deployed and enabled: the service is only running on whichever side is primary, so clients automatically follow the active database after a switchover or failover

The report is written for application engineers, technical and fluff-free: precise RPO semantics per protection/transport mode (stated separately for SYNC - ack after the standby redo disk write - and FASTSYNC - ack on receipt into standby memory; the standby-disconnected loss window; ASYNC loss bounds), an outage-budget breakdown (FSFO threshold + failover execution + service startup + reconnect), an "Errors During Role Transitions" ORA- table (12514/12541/01033/03113/25402/16000 with retryability) plus commit-ambiguity guidance (in-doubt COMMIT, idempotency, Transaction Guard prerequisites), a descriptor-parameter reference with worst-case connect math DERIVED from the `TNS_CT`/`TNS_TCT`/`TNS_RC`/`TNS_RD` (and step-10 `TAF_*`) shell variables that also render the descriptors - edit the variables and the prose stays true (33 s both-hosts-down, 21 s primary-down, TAF 150 s at the defaults); the Easy Connect Plus strings carry the same connect/retry values as the TNS descriptor (retry_delay omitted - not every 19c client parses it; EZ+ cannot express `FAILOVER_MODE` either, so TAF there comes only from the service), ADG read-staleness controls (`STANDBY_MAX_DATA_DELAY`/ORA-03172, `SYNC WITH PRIMARY`), sequence-cache gap and NOLOGGING/ORA-26040 specifics, Easy Connect Plus and driver mapping examples for ODP.NET / python-oracledb / SQLAlchemy (one set of labeled copy-button code blocks for the first role-manageable service, not a clipped table per service), a concrete client/pool settings checklist (checkout timeout derived from the descriptor math, read/call timeouts, `(ENABLE=BROKEN)` keepalive, validate-on-borrow, logon-storm cap), and a verification section: `tnsping`/`nc -z` against both hosts plus an end-to-end `SYS_CONTEXT('USERENV', ...)` role check through the role-aware descriptor that doubles as the switchover-drill pass criterion.

It also copies `docs/DG_APPLICATION_IMPACT.html` to `${NFS_SHARE}/dg_application_impact.html` when available and links it from "Notes for Client Teams". The Markdown remains self-contained: the "Application Impact Summary" bullets cover commit-latency/RPO, outage budget, cold-cache brownout, NOLOGGING/ORA-26040, and the reach-both-hosts prerequisite, so the HTML briefing is supplementary, not required reading.

User-visible services are discovered from `V$ACTIVE_SERVICES` (same logic as the role trigger), with the default `<DB_UNIQUE_NAME>` service always included. Output: `${NFS_SHARE}/dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.md` plus stdout, and a **styled self-contained HTML twin** at `${NFS_SHARE}/dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.html` (dg_handoff.sh writes it next to its `-o` output). The Markdown emitter stays the single definition of the report; a built-in POSIX-awk converter (`handoff_md_to_html` + `render_handoff_html`, between `# ---- begin/end handoff html renderer ----` markers, duplicated **byte-identically** in both scripts — `tests/test_handoff_html.sh` diffs the copies, so edit the `dg_handoff.sh` copy and re-copy) renders it into a light/dark-theme page (ČSOB brand palette — Pacific Blue `#0099CC`, Seagull `#80CCE6`, Midnight `#003366` via the same `--br`/`--brs`/`--brf`/`--brn` tokens as the ČSOB variant in the dataguard-doc repo, with the ČSOB logo as an inline `data:` PNG in a mono uppercase eyebrow, sitting on a white chip in dark theme; `prefers-color-scheme`) with the report meta as a chip strip, the verdict as a colored pill, WARNING/blockquote amber callouts, checklist boxes for `- [ ]` items, and terminal-styled descriptor blocks with clipboard copy buttons. Step 12 cleanup's `--all` removes the HTML twin along with the Markdown. Re-run after listener changes, new services, or topology changes to refresh the report.

Both handoff scripts also emit an **"Interactive diagram"** link in the report header: the discovered topology (DB unique names, hosts, observer host/placement, first service, port, protection mode, LogXptMode, FSFO threshold — never credentials) is encoded as `#cfg=<base64url(JSON)>` for the interactive Data Guard configuration explorer (source repo `davidbudac/dataguard-doc`, published at `https://davidbudac.cz/dataguard/`; base overridable via `DG_DOC_BASE_URL`). Unknown/undiscovered fields are omitted so the page falls back to its defaults; the link is skipped entirely if neither `base64` nor `openssl` exists on the host. The helper block is duplicated **byte-identically** in `dg_handoff.sh`, `primary/10_generate_handoff_report.sh` and `get_dg_config_url.sh` between `# ---- begin/end dataguard-doc visualizer helpers ----` markers — `tests/test_visualizer_url.sh` diffs every copy against the one in `dg_handoff.sh` (the reference) and fails on drift, so edit that one and re-copy into the others.

**Link only, on demand: `get_dg_config_url.sh`** (root of repo)
```bash
./get_dg_config_url.sh                                   # summary on stderr, URL on stdout
./get_dg_config_url.sh -q                                # URL only (URL=$(./get_dg_config_url.sh -q))
./get_dg_config_url.sh --standby-host stb --port 1521    # fill in what discovery missed
```
Generates the same visualizer link for **any existing** Data Guard configuration without producing a handoff report. Connects with `sqlplus / as sysdba` and discovers the topology from `V$DATABASE`, `V$DATAGUARD_CONFIG`, `V$LISTENER_NETWORK`, `V$ACTIVE_SERVICES` and `DGMGRL SHOW DATABASE`; standalone (no `standby_config_*.env`, no `common/dg_functions.sh`, no NFS share), so it can be copied to a DB host on its own. Runs from either side — on a standby it swaps the roles and reports the local host as the standby. Overrides: `--primary-host`, `--standby-host`, `--observer-host`, `--port`, `--service`, `--base-url`. Undiscovered fields are omitted (page defaults apply) and every query is best-effort; only a failed `sqlplus / as sysdba` connection or a host with neither `base64` nor `openssl` is fatal.

**Standalone variant: `dg_handoff.sh`** (root of repo)
```bash
./dg_handoff.sh
./dg_handoff.sh -o /tmp/handoff.md
./dg_handoff.sh --primary-host pri --standby-host stb --port 1521
```
Produces the same Markdown report against any existing Data Guard configuration without depending on `standby_config_*.env`, `common/dg_functions.sh`, or the NFS share. Topology (peer `DB_UNIQUE_NAME`, hostnames, listener port) is discovered from `V$DATABASE`, `V$DATAGUARD_CONFIG`, `V$LISTENER_NETWORK`, and `DGMGRL SHOW DATABASE VERBOSE`, plus version/CDB/charset/`db_domain` for the header and client notes. Use the `--*-host` / `--port` flags when broker is down or discovery returns the wrong value; `--env`/`--contact` fill the header chips. Output defaults to `./dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.md`. Unlike step 10, this variant is **container-aware**: services come from `V$ACTIVE_SERVICES` joined to `V$CONTAINERS` (works on non-CDB - single CON_ID=0 row), each service section names its container (warning for `CDB$ROOT`), every container **default** service (`DB_NAME[.DB_DOMAIN]`, `DB_UNIQUE_NAME`, instance name, PDB name) is flagged NOT role-aware (registered wherever the container is up, incl. the standby - never a failover descriptor), user-created services sort first, and zero user-created services is a WARNING. It emits role-aware descriptors only (no primary-only/standby-only flavors; the standby-readability note is stated once). Exit codes: `0` HEALTHY, `1` WARNING, `2` ERROR, `3` usage/connect failure (the step-10 variant keeps the setup-step convention: nonzero only on ERROR). A run on a non-primary emits a prominent in-report warning (service discovery is incomplete there). The standalone report references `DG_APPLICATION_IMPACT.html` only when the file is present next to the script or under `docs/`.

## Synchronous Transport Impact Report

`dg_sync_impact.sh` (root of repo, standalone like `dg_handoff.sh`) quantifies what SYNC/FASTSYNC transport costs commits on the PRIMARY. Core model: since 11g R2 the local redo write (L, `log file parallel write`) and the remote send/ack (R, `SYNC Remote Write`) run **in parallel**, so a commit's redo-write phase is `max(L,R)` — the per-write overhead is `E[max(L,R)] - E[L]`, which averages alone cannot give. The script computes it by cross-joining the two `V$EVENT_HISTOGRAM_MICRO` distributions (geometric bucket midpoints `upper/sqrt(2)`, independence assumed), brackets it with assumption-free bounds `max(0, avgR-avgL) <= overhead <= avgR`, and scales it to added-ms-per-commit / s-per-hour / % of DB time. `V$REDO_DEST_RESP_HISTOGRAM` is shown as corroboration.

```bash
./dg_sync_impact.sh                                       # ASH 24h, AWR 7 days
./dg_sync_impact.sh --baseline-begin 12000 --baseline-end 12168   # or 'YYYY-MM-DD HH24:MI' dates
./dg_sync_impact.sh --auto-baseline                       # detect the pre-SYNC baseline from AWR
./dg_sync_impact.sh --no-pack                             # skip Diagnostics Pack views
```

Design notes:
- **Diagnostics Pack gate**: the AWR trend (`DBA_HIST_SYSTEM_EVENT`/`DBA_HIST_SYSSTAT`/`DBA_HIST_SYS_TIME_MODEL` deltas with `LAG`, negative deltas from restarts nulled), the baseline before/after comparison, and the ASH attribution (top SQL/modules/services/hourly, foreground only) all need the pack; `--no-pack` keeps the report to free V$ views (the E[max] model itself needs no pack). The AWR trend's per-snapshot overhead column uses the **lower-bound** estimator, not E[max] — AWR histograms are ms-resolution, too coarse for a sub-ms LAN.
- **Baseline comparison** (`--baseline-begin/--baseline-end`, both-or-neither, snap-IDs or dates): puts the empirical per-commit delta (current vs pre-SYNC avg `log file sync`) next to the model estimate; warns when windows aren't comparable (commit rate differs >2x, or avg L also shifted — storage change). `--auto-baseline` detects the window instead: it classifies every retained AWR snapshot by the ratio of `SYNC Remote Write` waits to redo writes (~1 under sync transport, ~0 without; thresholds env-overridable via `DG_SI_SYNC_RATIO`/`DG_SI_NOSYNC_RATIO`/`DG_SI_MIN_WRITES`) and picks the most recent run of >= 2 consecutive no-sync snapshots before the last SYNC one, then reuses the same comparison machinery. Detection is behavioral, not configurational (a SYNC-configured-but-standby-down period counts as no-sync — the report discloses this); mutually exclusive with the manual `--baseline-*` flags and with `--no-pack`.
- **`redo synch time overhead (usec)`** is reported separately: the scheduling/post share of log file sync that is *not* transport — high values mean CPU starvation, don't blame DG.
- Every query carries a `-- QTAG:<name>` comment (the unit test's stub `sqlplus` dispatches on it); collectors are best-effort (`_out=$(run_sql ...) || { _out=""; degraded ...; }`) so one failed query degrades one section, never the run. Not-PRIMARY is fatal (exit 1); no-SYNC-destination is not (reports current lfs/L as an ASYNC-side baseline).

## NFS Artifact Cleanup

`primary/01_gather_primary_info.sh` and `primary/09_configure_fsfo.sh` stage `orapw*` password file copies (SYS password hash) on the group-readable NFS share, and `primary/08_security_hardening.sh` stages a refreshed `orapw*_hardened` copy; `primary/02_generate_standby_config.sh` and `standby/05_clone_standby.sh` leave a generated pfile and RMAN duplicate cmdfiles/logs behind. None of this is ever cleaned up automatically.

**Step 12: Clean Up NFS Artifacts (on any host with the share mounted, optional)**
```bash
./common/cleanup_nfs_artifacts.sh                 # default: password files, pfile, RMAN cmdfiles/logs
./common/cleanup_nfs_artifacts.sh -c /path/to/standby_config_<NAME>.env
./common/cleanup_nfs_artifacts.sh --all           # also remove config .env, handoff report, app-impact HTML
./common/cleanup_nfs_artifacts.sh -y              # skip the confirmation prompt
```

Run this once Data Guard has been verified (Step 7) and the handoff report has been reviewed. It selects (or accepts via `-c`/`--config`) the build's `standby_config_*.env`, prints exactly what will be removed and what will be kept, and requires confirmation before deleting anything.
