# Project: Oracle 19c Data Guard Setup Scripts

Automated scripts for setting up Oracle 19c Physical Standby databases using Data Guard Broker (DGMGRL).

## Project Structure

```
dg_status.sh     - Quick Data Guard health dashboard (run from jump host)
dg_triage_sid.sh - Fast local Data Guard triage (run directly on DB host)
dg_diag_sid.sh   - Deep local Data Guard diagnostics (run directly on DB host)
dg_check_sid.sh  - Deprecated wrapper to dg_triage_sid.sh
dg_handoff.sh    - THE handoff report generator (post-setup; no NFS/config dependencies) - `primary/10_generate_handoff_report.sh` is a thin wrapper around it. Writes the Markdown report plus, next to it, a styled self-contained HTML twin, a JSON sidecar (also the baseline for the next run's "Changes Since Last Report"), and a deliverable pack (`_tnsnames.ora`, `_jdbc.properties`, `_verify.sh`)
get_dg_config_url.sh    - Standalone generator for the interactive dataguard-doc visualizer link of an existing configuration (sqlplus / as sysdba; flags --primary-host/--standby-host/--observer-host/--port/--service/--base-url, -q for URL-only output)
dg_sync_impact.sh - Standalone SYNC/FASTSYNC commit-latency impact report (run on PRIMARY): estimates the added latency per commit as E[max(L,R)]-E[L] from V$EVENT_HISTOGRAM_MICRO (L='log file parallel write', R='SYNC Remote Write'), brackets it with avg-based bounds, scales it via AWR/ASH, and ranks the top-10 latency spikes both ways - slowest V$REDO_DEST_RESP_HISTOGRAM response buckets (with last-seen time) and worst AWR snapshots by lower-bound added ms/commit (flags --ash-hours/--days/--baseline-begin/--baseline-end/--auto-baseline/--no-pack/--html/-o; exit codes 0 report, 1 fatal/not-primary, 2 bad args). All durations are reported in milliseconds (rates, uptime and the NET_TIMEOUT configuration setting - shown in seconds under the header `NET_TIMEOUT (s)` - excepted); only `STATUS='VALID'` SYNC/FASTSYNC destinations count as active synchronous transport (DEFERRED/ERROR ones are listed separately); AWR deltas are partitioned by instance `STARTUP_TIME`, so restart intervals drop out of both the deltas and the elapsed time; a date-only `--baseline-begin/--baseline-end` means 00:00 / end of that day; every section opens with a one-line `Source:` naming its views, and every table is followed by the exact query that produced it (recorded verbatim by `run_sql` into a temp dir, emitted as a fenced ```sql block, rendered as a collapsed `<details>` in HTML). Markdown by default; --html renders the same emitter through a built-in POSIX-awk converter into a self-contained page with KPI cards for the headline numbers and, below each table, a strip of charts (one per plottable column, each on its own scale; a snapshot/hour axis with >= 6 points becomes a time-series column chart) while the cells themselves stay plain; if the converter's awk fails anyway, the page still ships with the Markdown embedded verbatim instead of being truncated mid-report. See docs/DG_SYNC_IMPACT.md
dg_check_srl.sh  - Standby redo log checker: verifies SRL count/size on both sides and prints fix DDL (flags -p/--prompt-password, -L/--local-only, -d/--srl-path; exit codes 0 compliant / 1 DDL needed / 2 argument, pre-flight, or data-collection error). SRLs created without a THREAD clause sit at THREAD#=0 until first use (step 4 created them that way before 2026-08; it now assigns THREAD explicitly); the checker counts THREAD#=0 SRLs as a shared pool toward each thread's requirement instead of demanding duplicates, so both old and new builds check out correctly. An SRL at least as large as the largest ORL is compliant (only a smaller one is a finding); sizes are compared in exact bytes (never truncated MiB - a 100 MB SRL under a 100.5 MB ORL is a finding) and the fix DDL rounds the size UP to whole MiB; every peer in `V$DATAGUARD_CONFIG` is checked, reached via its broker `DGConnectIdentifier` (falling back to its `DB_UNIQUE_NAME`); an unreadable ORL size exits 2 with no DDL
migrate_noncdb_to_pdb/ - Non-CDB to PDB migration subproject: migrate a non-CDB with its own standby into an existing CDB with its own standby, without recreating either standby (has its own README/WALKTHROUGH). Each step refuses unless its predecessor's `state.env` flag is set (step 01 clears them all; steps 02-04 clear later flags only when a new attempt really begins, so a refused re-run leaves `state.env` untouched); step 01 checks the CDB standby directly (`standby_file_management=AUTO`, convert/OMF coverage of the PDB datafile directory, the directory itself); step 04 sets `STANDBY_PDB_SOURCE_FILE_DIRECTORY` on the standby instance; step 05 fails unless the standby is verified directly (PDB `RECOVERY_STATUS=ENABLED`, no `UNNAMED` files, matching datafile count, applied SCN caught up - the gate reads the standby's own `V$DATABASE.CURRENT_SCN` through the direct connection (`V$ARCHIVE_DEST_STATUS` has no `APPLIED_SCN` in 19c), must come from the configured `PHYSICAL STANDBY`, and reports a query error as an error rather than waiting it out as lag; `MIGRATE_SCN_WAIT_SECS`/`MIGRATE_SCN_POLL_SECS` tune the wait); SCNs are read with `TO_CHAR` (a bare SCN wider than 10 digits prints in scientific notation); the standby password fallback sets `SET DEFINE OFF` before `CONNECT` and refuses a password containing `"`; step 06 proves the source's identity (name, DBID, non-CDB, READ ONLY) and the new PDB's state before any shutdown, and an unattended DROP needs `MIGRATE_ALLOW_DROP=1` on top of `MIGRATE_NONINTERACTIVE=1`. `run_minimal.sh` is LAB-ONLY
observer_sys_to_sysdg/ - Standalone side toolkit (NOT part of the numbered workflow): convert an existing FSFO observer that authenticates as SYS to a dedicated SYSDG-only user - create the user on the primary (01), swap/create the observer wallet credentials and restart the observer (02), verify (03). 02 backs up the wallet before editing, refuses a `-w` that differs from sqlnet.ora's `WALLET_LOCATION`, proves the wallet login with `SYS_CONTEXT('USERENV','AUTHENTICATED_IDENTITY')` (in an `AS SYSDG` session `USER`/`SESSION_USER` both read `SYSDG`; only `AUTHENTICATED_IDENTITY` names the login user - verified on 19c), checks each member's `DGConnectIdentifier` against the wallet, warns about leftover SYS credentials, and exits non-zero if no observer registers after the restart; 01 warns when the user's profile has a finite `PASSWORD_LIFE_TIME`, and sets a new user's password a second time after the grants (verified on 19.27 with a MOUNTED physical standby: `CREATE USER` + `GRANT SYSDG` do not reach the standby's password file, a password change does; failure there is a warning, 02 proves the standby login); self-contained (no common/ or NFS dependencies), see its README.md
add_observer/    - Standalone side toolkit (NOT part of the numbered workflow): add an FSFO observer on a THIRD host to an existing, already-working Data Guard configuration (built by this repo or not). `01_prepare_primary.sh` runs on the PRIMARY - discovers the topology (peer DB_UNIQUE_NAME, hostnames, and host/port/service by running `tnsping` on each member's broker `DGConnectIdentifier`), reports FSFO readiness (SHOW CONFIGURATION, VALIDATE DATABASE, Flashback Database on both members, protection mode, SRLs), creates/verifies the dedicated SYSDG observer user (CDB-aware; a new user's password is set a second time after the grants so the entry reaches a mounted standby's password file - warning, not failure, if that ALTER is refused), optionally enables FSFO (`--enable-fsfo`), and writes a self-contained bundle for the third host. `02_setup_observer_host.sh` / `03_observer_ctl.sh` / `04_verify_observer.sh` run there: TNS entries + auto-login wallet + both-database connectivity proof; start/stop/restart/status/log/boot lifecycle (`status`/`start` judge THIS observer by name/host in `SHOW OBSERVER`, falling back to the standby alias when the primary is down - registration alone is not liveness: the observer is up only when it is listed, its own `Last Ping` is at most `DG_OBS_MAX_PING_AGE` seconds old (default 60) and its pidfile process is not known dead; a registered-but-dead observer is restarted with its existing `.dat` file, deregistering the stale entry by name only when the broker refuses the start; `boot` prints systemd, Linux-only cron, and AIX `mkitab`/`rc2.d` options - AIX cron has neither `@reboot` nor `*/N`); end-state verification. Never changes protection mode, LogXptMode or transport. Self-contained (no common/ or NFS dependencies), see its README.md
nfs/             - NFS setup scripts (run before Data Guard setup)
primary/         - Scripts to run on PRIMARY server (Steps 1, 2, 4, 6, 9, 10, 13)
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
9. `primary/09_configure_fsfo.sh` - Configure Fast-Start Failover (optional)

There is no step 8: the former security-hardening step was removed from the project, and the remaining scripts keep their filename numbering (the sequence jumps from 7 to 9).

Every numbered script (and `trigger/`, `fsfo/observer.sh`, `common/cleanup_nfs_artifacts.sh`) parses its flags through the shared `enable_verbose_mode`: `-h/--help` prints usage and exits 0, an unknown option or stray positional exits 2. `-n/--check` runs discovery, validation and prompts, then stops before the first write or database change (steps 1 and 2 log what they would write; step 1 exits 1 if a prerequisite failed; the trigger scripts print their plan; `fsfo/observer.sh -n setup|start|stop|restart` runs read-only broker queries, prints the plan and changes nothing - no wallet write, no START/STOP OBSERVER, no signal, stale pidfiles left in place - while `status` runs normally). In approval mode (`-a`) `fsfo/observer.sh` asks before every mutating action and a declined action exits 1.
10. `fsfo/observer.sh setup` then `fsfo/observer.sh start` - Set up and start the observer (on observer server, optional)
11. `trigger/create_role_trigger.sh` - Deploy role-aware service trigger (on PRIMARY, optional)
12. `common/cleanup_nfs_artifacts.sh` - Remove sensitive/transient setup artifacts (password file copies, generated pfiles, RMAN files) from the NFS share once the build is verified (optional, run from any host with the share mounted)
13. `primary/13_set_max_availability.sh` - Validate the configuration is healthy, then set protection mode MAXIMUM AVAILABILITY + LogXptMode=FASTSYNC (on PRIMARY, optional). For zero-data-loss protection *without* FSFO — Step 9 already applies both settings when enabling FSFO, so skip this if Step 9 was run. Needs the `standby_config_*.env` from the NFS share, so run it before Step 12's `--all` cleanup (the default cleanup keeps the .env)

Recommended, run any time after Step 7 (not part of the walkthrough's numbered sequence, but worth doing before Step 12 cleanup since cleanup can remove it): `primary/10_generate_handoff_report.sh` - Generate the end-user handoff report with status snapshot and TNS/JDBC connection strings (on PRIMARY); a thin wrapper around `dg_handoff.sh` that feeds it the build's `standby_config_*.env` and writes into the NFS share.

## Restartability

**Steps 1-4 are fully restartable** - these scripts are idempotent and can be re-run from step 1 if needed. They gather information, generate configs, and apply settings that can be safely overwritten.

**Step 5 (Clone Standby) is NOT directly restartable** - once RMAN duplicate starts, you cannot simply re-run the script. To restart from step 5:
1. Shut down the standby instance
2. Remove all standby data files, control files, and redo logs
3. Re-run step 5

Step 5's typed confirmation comes **before** any `SHUTDOWN ABORT`; a running instance is only aborted if it is NOMOUNT (the leftover auxiliary) or reports `PHYSICAL STANDBY`, the host must match `STANDBY_HOSTNAME`, and declining exits 1 with nothing changed. The RMAN `SPFILE SET` list also carries `CONTROL_FILES` (honouring `STANDBY_CONTROL_FILE_2_DIR`), `DIAGNOSTIC_DEST`, and - only when the primary's are non-default - `DG_BROKER_CONFIG_FILE1/2`. `--channels N` allocates N target plus N auxiliary channels (19c active duplication is "push"/target-driven unless auxiliary channels >= target channels). A missing spfile after DUPLICATE fails the step instead of building one from the minimal pfile. **Inherited FRA:** in Traditional mode with `USE_FRA_FOR_STANDBY=NO` the live primary is queried before anything changes (a failed query refuses the step); when it has `db_recovery_file_dest` set, the SPFILE clause carries `RESET DB_RECOVERY_FILE_DEST` / `RESET DB_RECOVERY_FILE_DEST_SIZE` (syntax confirmed with `rman checksyntax` on 19c; emitted only when the primary has an FRA). After the DUPLICATE the standby's effective FRA settings are read back: a contradiction is recorded, the remaining post-clone actions (broker start, MRP, deletion policy) still run, and the step then exits 1 with the manual fix printed. **Open (not yet lab-verified):** in OMF mode the DUPLICATE sets no `CONTROL_FILES`, so a primary with explicit `control_files` probably hands the standby its control-file paths - the same class of inheritance problem as `DB_CREATE_ONLINE_LOG_DEST_n`; needs an OMF-mode lab run before relying on OMF mode with a non-OMF primary.

**Locked-SYS re-clone limitation:** if SYS on the primary has been locked (e.g. by a site hardening policy), `standby/05_clone_standby.sh` detects this at the password-verification step (`ORA-28000`) and prints the fix: temporarily `ALTER USER SYS ACCOUNT UNLOCK` + `IDENTIFIED BY <temp password>` on the primary, re-run step 5, then re-apply the lockdown and keep the standby's password file in sync with the primary's.

**Steps 6-7 are restartable** - the broker configuration can be removed with `REMOVE CONFIGURATION` in DGMGRL and recreated. Before removing an existing configuration, step 6 names any broker member that is not in the selected config, refuses non-interactively, and asks for a typed `REMOVE CONFIGURATION` on a TTY. Step 7 is read-only verification; it grades the broker with `dgmgrl_status_value` (SUCCESS passes, WARNING warns, ERROR/DISABLED/unreadable fail) instead of treating any ORA- text as an error.

**Step 13 is idempotent** - if the configuration is already MAXIMUM AVAILABILITY with LogXptMode=FASTSYNC on both databases, it reports that and exits successfully without prompting.

## Key Design Decisions

- **Use DGMGRL for all Data Guard configuration** - Always prefer Data Guard Broker commands over manual ALTER SYSTEM/ALTER DATABASE commands when configuring anything Data Guard related
- **Data Guard Broker (DGMGRL)** manages DG parameters instead of manual ALTER SYSTEM commands
- **NFS share** at `/OINSTALL/_dataguard_setup` for file exchange between servers
- **Single source of truth**: `standby_config_<STANDBY_DB_UNIQUE_NAME>.env` contains all configuration. After editing it, run `02_generate_standby_config.sh --regenerate` to update derived files (pfile, TNS, listener, DGMGRL). Regenerate re-derives the convert pairs from the `PRIMARY_*_PATHS`/`STANDBY_*_PATHS` arrays (via the shared `build_convert_pairs()`, used by both normal and regenerate modes) and **persists the rebuilt `DB_FILE_NAME_CONVERT`/`LOG_FILE_NAME_CONVERT` strings back into the .env**, together with the re-derived singular `STANDBY_DATA_PATH`/`STANDBY_REDO_PATH` (the standby array entry paired with `PRIMARY_DATA_PATH`/`PRIMARY_REDO_PATH` - the primary's SYSTEM-datafile and first ONLINE redo directories; they drive control files, step 3 and step 5) — step 5 feeds RMAN's `SPFILE SET` from the .env and that overrides the regenerated pfile, so stale strings there would silently defeat an edited layout. Edit the path arrays, not the convert strings; mismatched/missing arrays skip re-derivation and the stored strings are used verbatim (with a warning)
- **Standby filesystems (Q1b)**: step 2 (Traditional mode, TTY only) lists the distinct filesystems (FIRST path component, labeled with what lives there) found across the primary's datafile/redo/archive/FRA paths and asks whether any are named differently on the standby; if yes, the operator supplies each one's standby counterpart (default keeps the name; multi-component targets like `/ora_1 -> /mnt/oracle/ora_1` are allowed). Only changed entries land in the `STANDBY_FS_MAP_FROM`/`_TO` parallel arrays consulted by `derive_standby_path()` = `apply_fs_map()` (keys are the PRIMARY fs names as shown) then `remap_path_token()` — applied to datafiles, redo, SRLs, archive dest, and FRA defaults. `ORACLE_BASE` is deliberately NOT touched (software mount typically not renamed; its own TTY prompt allows override). Because Q1b explicitly settles the filesystem question, the per-path "could not be auto-derived" confirmation (`_confirm_unmapped_paths`) is **skipped whenever Q1b was asked** — it now fires only in non-Q1b runs (piped stdin), and the review table stays the safety net. The whole Q1b block is TTY-gated, so piped/E2E runs get an empty map (= pre-Q1b behavior, byte-identical stdin sequence). `STANDBY_FS_MAP` ("/from=/to" entries) is persisted to the .env as a record only — the path arrays are the truth and `--regenerate` never re-applies it. `apply_fs_map`/`derive_standby_path` are duplicated verbatim in `tests/test_fs_remap.sh`, whose drift guard diffs the copies (script is the source of truth; keep the function header and closing `}` at column 0)
- **Asymmetric standby layouts**: step 2 (Traditional mode) surfaces the derived layout before anything is written — a per-path confirmation for paths with no DB-name component to substitute (redo/temp on their own mount, otherwise left pointing at the primary → `ORA-17502`/`ORA-19504` in step 5; skipped when Q1b was asked, since the filesystem question is then already answered), and `_review_path_mappings()`'s numbered override table for the case where substitution worked but the standby base mount differs entirely. Standby `ORACLE_BASE`/`ORACLE_HOME` are prompted rather than assumed equal to the primary's. All three are TTY-gated (`[[ -t 0 ]]`) — **any new prompt must be**, or it desynchronizes the E2E suite's fixed piped-stdin input sequence. Non-interactive runs take the derived defaults; use edit-env + `--regenerate` instead
  - Known limitation (**now warned about, not silent**): primary with data+redo in ONE directory and a standby that splits them puts ORLs/SRLs in the standby data dir — both pairs share the same primary path, so the length sort can't separate them and Oracle's first-prefix match takes the datafile pair. `build_convert_pairs()` detects this (primary redo dir == a primary data dir, but their standby targets differ) and warns that the standby redo dir will stay unused. Unfixable by pair ordering: a convert pair remaps a primary *filename*, and nothing distinguishes an ORL from a datafile when they share one primary directory — a split standby needs a distinct primary redo dir too. Same root cause as the existing SRL-contradiction warning
  - `build_convert_pairs()` is **duplicated verbatim** in `tests/test_file_name_convert.sh`; the script is the source of truth and Test 11 fails on any drift (it diffs the two copies). Edit the script, then re-copy into the test
- **Concurrent builds**: All generated files include DB_UNIQUE_NAME to support multiple DG setups
- **TNS alias domain qualification**: step 2 qualifies the generated TNS aliases with `NAMES.DEFAULT_DOMAIN` from the primary's sqlnet.ora when set (falling back to `DB_DOMAIN`) - sqlnet appends its default domain to every unqualified alias at resolution time, so unqualified generated entries would be unresolvable on such hosts (surfaces as ORA-17627/ORA-12154 mid-RMAN-duplicate in step 5). A qualified alias name resolves exactly whether or not the resolving host sets a default domain
- **Passwords prompted at runtime**, never stored
- **Filesystem storage** (not ASM), single instance (not RAC)
- **Storage mode choice**: Step 2 offers Traditional (path substitution via `DB_FILE_NAME_CONVERT`) or OMF mode (`db_create_file_dest` + `db_recovery_file_dest`). OMF mode supports mixed-storage scenarios where primary uses regular file paths and standby uses FRA. OMF mode also protects against the post-setup new-PDB/new-datafile convert-pair gap: in Traditional mode a file created in a directory not covered by any `DB_FILE_NAME_CONVERT` pair becomes an `UNNAMED` placeholder on the standby and halts apply with ORA-01274 (see "Life After Setup" in docs/DATA_GUARD_WALKTHROUGH.md)
  - **Inherited file-placement parameters (OMF)**: RMAN `DUPLICATE ... SPFILE` copies the primary's spfile and overrides only the `SET` list, so the primary's `DB_CREATE_ONLINE_LOG_DEST_1..5` (outrank `db_create_file_dest` for redo logs/OMF control files) and `LOG_FILE_NAME_CONVERT`/`DB_FILE_NAME_CONVERT` (outrank the OMF parameters) would be inherited silently, failing the non-restartable step 5 with ORA-19504/ORA-27040. Step 1 records them (`PRIMARY_DB_CREATE_ONLINE_LOG_DEST_1..5`, `PRIMARY_{LOG,DB}_FILE_NAME_CONVERT_SET`, `PRIMARY_ONLINE_LOG_DEST_UNSAFE`); step 2 in OMF mode refuses (before prompting/writing) when a convert parameter is set, and maps each set dest to `STANDBY_DB_CREATE_ONLINE_LOG_DEST_n` (OMF-mode .env only; TTY-gated override prompt, defaults n=1,3-5 -> file dest, n=2 -> FRA); step 3 creates those directories; step 5 runs an authoritative preflight against the live primary before any shutdown/RMAN (refuses on convert parameters or a failed query, requires the directories to exist and be writable) and `SET`s `DB_CREATE_ONLINE_LOG_DEST_n`. The pure logic lives in `common/dg_functions.sh` (`is_safe_omf_dest_path`, `omf_default_online_log_dest`, `build_rman_online_log_dest_set_lines`, `build_pfile_online_log_dest_lines`, `parse_omf_placement_params`).
- **AIX 7.2 compatible**: Uses printf instead of echo -e, sed instead of grep -P, POSIX BRE only (no `\+`/`\?`), `df -Pk`, `du -sk`, and no bash 4 syntax. Linux-only binaries (`timeout`, `nc`, `systemctl`, `mktemp`, `base64`, `tput`) are always behind a `command -v` guard with a working fallback - e.g. step 4's port check falls back to `tnsping` against a raw descriptor, since AIX ships neither `nc` nor `timeout`. Enforced by `tests/test_aix_portability.sh`. The supported shell is **Bash 3.2 or later**: the unit suites must pass when both the driver and every inner `bash` are 3.2 (recipe at the top of `tests/test_counter_increment.sh`).
  The two `nfs/` scripts are the deliberate exception: they are Linux-only (yum/dnf/apt, systemd, `exportfs`, `mount -t nfs4`, `/etc/fstab`) and now stop on AIX with the AIX-native sequence (`mknfs`/`chnfsdom`/`mknfsexp`, `mknfsmnt`) printed instead of half-running Linux commands as root

## Common Functions

`common/dg_functions.sh` provides:
- `log_info`, `log_warn`, `log_error` - Logging functions
- `run_sql`, `run_sql_with_header` - SQL execution helpers (`dg_sqlplus_bin` picks `$ORACLE_HOME/bin/sqlplus` when executable, else PATH, so sqlplus comes from the same home as rman/dgmgrl)
- `get_db_parameter` - Get Oracle parameter value (trims leading/trailing whitespace only)
- `check_oracle_env`, `check_nfs_mount`, `check_db_connection` - Validation functions
- `select_config_file` - Config file selection (auto-selects when only one exists)
- `enable_verbose_mode "$@"` - the shared flag parser (`-v`, `-a`, `-n/--check`, `--no-color`, `-h/--help`). It rejects unknown options and stray positionals with exit 2; a script declares its own options in `DG_SCRIPT_FLAGS` before the call (a trailing `=` marks a value flag, e.g. `--channels=`; `'*'` disables the check for scripts with a complete parser of their own) and allows positionals with `DG_SCRIPT_POSITIONAL=1`
- `pause_verbose_trace` / `resume_verbose_trace` - nest (depth counter); wrap every block that reads, holds or uses a password so `-v` xtrace never prints it (`prompt_password` does this internally and restores terminal echo on INT/TERM/HUP)
- `dgmgrl_status_value` - the `Configuration Status:`/`Database Status:` value (SUCCESS/WARNING/ERROR/DISABLED; 19c prints it on the NEXT line), nothing + rc 1 when absent; `dgmgrl_has_error_lines` - `Error: <nonzero>` lines or ORA-/DGM- codes not on a `Warning:` line. Use these to grade broker output; an ORA- under a member's `Warning:` line is a warning, and empty output is a failure
- `dg_net_admin_dir` - `${TNS_ADMIN:-$ORACLE_HOME/network/admin}`; use it for every listener.ora/tnsnames.ora/sqlnet.ora read or edit (the standalone toolkits inline the same expression)
- `assert_db_matches_config primary|member` - identity guard: compares the connected database's `DB_UNIQUE_NAME`, `DATABASE_ROLE` and `DBID` (`sql/queries/get_db_identity_pipe.sql`) with the sourced `standby_config_*.env` and returns 1 on a mismatch or a failed query. Steps 4 and 6 use `primary` (must be the config's primary); steps 9, 10 and 13 use `member` (either member, as long as it holds the PRIMARY role - sets `DG_CONFIG_ROLES_SWAPPED=1` after a switchover). Call it right after sourcing the config, before the `-n` stop. The comparison itself is the pure `compare_db_identity`
- `dgmgrl_config_members` / `dgmgrl_foreign_members` - member names of a captured `SHOW CONFIGURATION`, and those that are none of the given `DB_UNIQUE_NAME`s
- `create_temp_dir` - private mode-700 temp directory: `mktemp -d`, else exclusive `mkdir` on `dg_tmp_<pid>_<n>_<random>` candidates with bounded retries (distinct per allocation, so two can be live at once; an existing path is never reused)
- `hostnames_match` - short-name comparison for hostnames; dotted-quad IPv4 is compared in full, and an IP vs. a name matches only when the IP is one of this host's addresses (`ifconfig -a`)

Usage-error exit codes differ by tool (each is documented with the tool): numbered workflow scripts and `trigger/` 2 (shared parser), `dg_status.sh` and `dg_handoff.sh` 3, `dg_triage_sid.sh`/`dg_diag_sid.sh` 64, `dg_sync_impact.sh`/`dg_check_srl.sh`/`get_dg_config_url.sh`/`add_observer/` 2.

## Wallet Setup for Peer Connectivity

After Data Guard is configured, you can set up Oracle Wallet on each DB host so that scripts like `dg_triage_sid.sh` and `dg_diag_sid.sh` can connect to the peer database without prompting for a password.

```bash
bash common/setup_dg_wallet.sh              # Run on primary
bash common/setup_dg_wallet.sh              # Run on standby
bash common/setup_dg_wallet.sh -w /path     # Custom wallet directory
```

The script auto-detects the local role, discovers the peer TNS alias from the broker, creates an auto-login wallet with SYS credentials, configures `sqlnet.ora` (in `$TNS_ADMIN` when set; adds `SQLNET.WALLET_OVERRIDE = TRUE`), and tests the connection. A failed wallet login is a failed setup: exit 1, no summary, the new wallet left in place, and the previous wallet's backup named with the exact restore command. The local alias credential is stored only when its SYS password check passes. The staging directory is `mktemp -d` or an exclusive, verified private `mkdir`; if neither works the script exits 1 before any `mkstore` call. It is idempotent — re-running adds/updates credentials in an existing wallet, after backing the wallet up to a timestamped `.bak`.

**mkstore and passwords:** every `mkstore -createCredential <alias> <user>` call in the repo leaves the secret off argv; mkstore then reads secret, secret again, wallet password from stdin (verified on 19c), so no password appears in `ps -ef`.

**Wallet lookups match the connect string text exactly** (verified on 19c): a credential stored under alias `X` is found for `/@X`, and NOT for `/@(DESCRIPTION=...)` resolving to the same address (ORA-01017). Never rewrite a `/@alias` connect into a descriptor (e.g. to inject timeouts); bound it with a shell watchdog instead, as `common/dg_local_status_common.sh` does.

`-A`/`--auto-password` generates the wallet password automatically instead of prompting. Re-running with `-A` against a wallet that already holds credentials (or whose auto-generated password can no longer be supplied) lists the existing credentials and requires typing `RECREATE WALLET` to confirm before rebuilding it - the rebuild happens in a staging directory and is swapped in only after every step succeeds, with the old wallet kept as a timestamped `.bak` copy.

## Validation Checks

Built-in validations:
- ARCHIVELOG mode, FORCE_LOGGING, password file (step 1)
- Disk space on standby (step 3)
- Port connectivity primary → standby (step 4)
- Pre-existing standby redo logs (step 4): smallest `V$STANDBY_LOG` vs largest `V$LOG` in exact bytes from the live primary (`sql/queries/get_standby_redo_min_size.sql` returns `min_srl_bytes|max_orl_bytes`), the same rule as `dg_check_srl.sh`; undersized ones get a warning with fix DDL, never an automatic drop
- Static listener registration (step 4): entries that cannot be inserted automatically end the step in ERROR (exit 1) after the rest of the step has run, with the entries printed for manual insertion
- Identity of the connected database (steps 4, 6, 9, 10, 13): `assert_db_matches_config` (see Common Functions)
- Listener port detection (step 1): `V$LISTENER_NETWORK`, then `local_listener`, then `lsnrctl status` last; the numeric `PORT=` is extracted and range-checked
- Password file location (step 1): `V$PASSWORDFILE_INFO.FILE_NAME`, falling back to `orapw<SID>`/`orapw<DB_NAME>` under `$ORACLE_HOME/dbs` and the read-only-home `dbs`; `REMOTE_LOGIN_PASSWORDFILE` must be EXCLUSIVE (steps 1 and 2 agree)
- FQDN detection (step 1): `host` output in both the Linux (`has address`) and AIX (`is a.b.c.d`) forms, then `nslookup`, then `/etc/hosts`

## Redo Generation Statistics (Step 1)

Step 1 reports an archive log overview (mode, destination, logs on disk, sequence range) plus redo generation statistics derived from `V$ARCHIVED_LOG`: daily volume for the last 14 days with each day's busiest hour, an hour-of-day profile for the last 7 days, and averages/peaks per day and per hour. From the peak hour it derives the **minimum redo transport bandwidth** (peak hour + 30% headroom) and the archive space needed per day of retention. It warns when the peak log switch rate exceeds 12/hour (fix online redo log size *before* the standby exists — standby redo logs must match it) and when the FRA is smaller than one day of redo.

Design notes:
- `V$ARCHIVED_LOG` rows are de-duplicated by `(THREAD#, SEQUENCE#, RESETLOGS_ID)` — one archived log has a row per destination, so a plain `SUM()` multiplies the volume by the number of local destinations. `STANDBY_DEST='NO'` excludes shipped logs on re-runs.
- History is bounded by `CONTROL_FILE_RECORD_KEEP_TIME` (7 days by default); the observed window is reported rather than assumed.
- With no archive history (fresh or freshly restarted DB — including the E2E test), it falls back to `V$SYSSTAT` "redo size" since startup, sets `REDO_STATS_SOURCE=INSTANCE_STARTUP`, and reports peak == average.
- With under one day of history (archive history or the instance-startup fallback) the per-day figures are the observed totals, flagged in the output, not rates extrapolated to 24 hours.
- The space estimate counts every ORL member (`BYTES * MEMBERS`) plus the SRLs (`V$STANDBY_LOG`, or the planned groups+1 of the largest ORL size when none exist).
- The whole section is informational: a failed or empty query degrades to zeros plus a warning, never a failed step.
- Values are persisted to `primary_info_<DB_UNIQUE_NAME>.env` (`ARCHIVE_*`, `REDO_*`). Since that file is sourced by later steps, label fields are sanitized to shell-safe characters and no value contains a `$`.

## Status Dashboard

`dg_status.sh` provides a quick health overview of a running Data Guard configuration. Run it from the jump host (or any machine with SSH access to both DB hosts).

```bash
bash dg_status.sh                    # Uses $ORACLE_SID or auto-detects from pmon
bash dg_status.sh -s cdb1            # Explicit SID
bash dg_status.sh -c myconfig.env    # Custom SSH config
```

**What it checks (both databases):** database role, open mode, protection mode, switchover status, force logging, flashback, DG broker status, currently running services, redo/standby redo log counts, archive destination errors, archive gaps, FRA usage (with 80%/90% thresholds), MRP apply status, transport/apply lag, archived log sequence gaps, UNNAMED datafile detection (ORA-01274: a datafile added outside convert-pair coverage halts redo apply), broker configuration including FSFO and per-member ORA errors, standby flashback and `dg_broker_start`, and recent Data Guard-related alert log entries. The replication state (`IN SYNC`/`LAGGING`/`UNKNOWN`) and broker colouring come from shared functions in `dg_render_common.sh` (`dg_repl_state`, `dg_broker_overall_icon`), so `dg_status.sh` and the local triage/diag engine grade the same state the same way. The dgmgrl output is parsed from the `Configuration -` line on, with ssh's own stderr dropped, so ssh banners never count as broker warnings.

**SID resolution:** `-s` flag > `$ORACLE_SID` > auto-detect from `ora_pmon_` process. The standby SID is `--standby-sid`, else auto-detected (with several pmon processes, the one whose `DB_NAME` matches the primary's; otherwise the first, with a warning).

**Remote timeout:** ssh runs with `ServerAliveInterval=15`/`ServerAliveCountMax=3`/`ConnectTimeout=15` (values in `SSH_OPTS` win), and a local watchdog kills any remote collection still running after `DG_REMOTE_TIMEOUT` seconds (default 120), records an error naming the host and exits 2 - a hung sqlplus/dgmgrl never hangs the dashboard. Discovery is bounded the same way: the reachability probes, pmon detection and the standby `DB_NAME` queries each get `DG_REMOTE_TIMEOUT`, all of discovery together `2 x DG_REMOTE_TIMEOUT`, and a host is not asked again after its first timeout - worst case for a whole run is about `3 x DG_REMOTE_TIMEOUT`. A discovery timeout is an error (exit 2), never a healthy-looking dashboard. The remote environment also exports `LIBPATH` for AIX.

**Exit codes:** `0` healthy, `1` warnings only, `2` errors present, `3` usage/config error (bad flag, missing option argument, missing config keys, invalid SID, malformed threshold or `DG_REMOTE_TIMEOUT`) - suitable for cron/monitoring wrappers instead of scraping the colored text output. An unreachable host is reported explicitly (`UNREACHABLE`) rather than rendered as blank fields with a healthy status; an unreachable standby (or one returning no lag data) renders the replication state as `UNKNOWN`, never `IN SYNC`. When FSFO is enabled, a missing observer (`FS_FAILOVER_OBSERVER_PRESENT`) is an error. `JUMP_HOST` may be empty in the config - the DB hosts are then reached directly (same convention as the E2E harness).

**Output control:** `--no-color` (or the `NO_COLOR` env var) disables ANSI color codes.

**Configurable thresholds** (env vars, override by exporting before running): `DG_FRA_WARN_PCT` (default 80), `DG_FRA_CRIT_PCT` (default 90), `DG_SEQ_GAP_WARN` (default 1), `DG_SEQ_GAP_CRIT` (default 5), `DG_LAG_WARN_SECONDS` (default 60). Values must be non-negative integers (exit 3 in `dg_status.sh`, 64 in the local tools otherwise). FRA numbers are formatted with `NLS_NUMERIC_CHARACTERS='.,'` in SQL and passed to awk with `-v` under `LC_ALL=C`, so a comma-decimal `NLS_LANG` (CZECH, GERMAN) cannot silently disable the FRA checks.

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
- `tests/test_add_sid_to_listener.sh` - Tests `add_sid_to_listener()` and `listener_has_global_dbname()` (whole-value, case-insensitive, comment-aware matching; anchored `SID_LIST_LISTENER`; one-line definitions refused; file mode and symlinks preserved)
- `tests/test_shared_helpers.sh` - Tests the shared helpers in `common/dg_functions.sh`: the `enable_verbose_mode` flag contract (`--help`, unknown options/positionals, `DG_SCRIPT_FLAGS` value flags and `'*'`), nested trace pausing, `dgmgrl_status_value`/`dgmgrl_has_error_lines` on real 19c SHOW CONFIGURATION samples, `hostnames_match` with IPs, the `create_temp_dir` fallback (two live allocations, pre-existing paths skipped, nested allocation inside `add_sid_to_listener`), the identity guard (`compare_db_identity` in both modes, `assert_db_matches_config`, steps 4 and 6 end to end refusing a mismatched database with no mutating call), the broker member parser, `get_db_parameter` trimming, `dg_net_admin_dir`, `dg_sqlplus_bin`
- `tests/test_step9_observer_user.sh` - Tests step 9's observer-user standby propagation: `prove_observer_standby_login` extracted from the script and run against a stub `sqlplus` (first-try success, success after ORA-01017 answers, failure after the bounded poll with the ORA- line reported, `DG_OBSERVER_STANDBY_LOGIN_WAIT_SECS` override, password absent from output and from a `-v` xtrace of the failure path, `CONNECT` on stdin with `/nolog`), and static checks that the new-user path runs `ALTER USER ... IDENTIFIED BY` after `GRANT SYSDG`, that the alias is `STANDBY_TNS_ALIAS` or `PRIMARY_TNS_ALIAS` under `DG_CONFIG_ROLES_SWAPPED=1`, and that the proof sits after the `-n` stop and before LogXptMode
- `tests/test_steps_1_2_helpers.sh` - Tests the step 1/2 helpers extracted from the scripts (`resolve_fqdn`, `extract_port`, the standby name/SID/hostname validators, `pick_standby_for_primary`) plus step 2 end to end against a scratch share with piped stdin: `-n/--check` writes nothing (normal and `--regenerate`), `STANDBY_DATA_PATH` follows the SYSTEM-datafile directory, `--regenerate` re-derives and persists the singular paths and keeps a hand-edited `DG_BROKER_CONFIG_NAME`, SHARED password file refused, invalid names refused non-interactively
- `tests/test_status_tools.sh` - Stubbed ssh/sqlplus/dgmgrl end-to-end tests of `dg_status.sh` and `dg_triage_sid.sh`: shared replication state (no lag data → UNKNOWN), the hung-job watchdog (no orphans; these checks skip where `ps` is unavailable), wallet CONNECT alias left untouched, `SET DEFINE OFF`, locale-safe FRA maths, spaced `SSH_KEY` paths
- `tests/test_check_srl.sh` - Tests `dg_check_srl.sh` with stubbed sqlplus/dgmgrl: `SET DEFINE OFF` first, `"`-in-password refusal, unreadable ORL → exit 2 with no DDL, larger vs smaller SRLs, `DGConnectIdentifier` alias resolution and fallback, multi-peer checking, byte-exact size grading (fractional-MiB ORLs, one byte smaller/larger, 20 GiB logs)
- `tests/test_add_observer_lib.sh` - Tests `add_observer/_lib.sh` and the toolkit's parsers: `broker_property` no-match under `set -e` (H2) end to end through `01_prepare_primary.sh`, `dgmgrl_failed` (Warning-line ORA- codes ignored, empty output = failure), `set define off`, case-insensitive `descriptor_part`, the per-alias TNS block extractor, `SHOW OBSERVER` matching, and the bounded `/dev/tcp` probe Also asserts (on the script text, the password prompts need a TTY) that the new-user path runs `create user` -> `grant sysdg` -> `alter user ... identified by`
- `tests/test_observer_sys_to_sysdg_lib.sh` - Tests `observer_sys_to_sysdg/_lib.sh` (`set define off`/`set tab off` in `run_sql`, the anchored dgmgrl failure detector) and the 02 credential flow against stubbed mkstore/sqlplus/dgmgrl (no password on argv, AUTHENTICATED_IDENTITY check) Also asserts (on the script text, the password prompts need a TTY) that the new-user path runs `create user` -> `grant sysdg` -> `alter user ... identified by`
- `tests/test_fsfo_observer.sh` - Tests `fsfo/observer.sh` with stubbed dgmgrl/sqlplus/mkstore/orapki: `-n` on setup/start/stop/restart changes nothing (no mkstore, no START/STOP OBSERVER, pidfile and wallet byte-identical), approval-mode declines, member selection when the primary alias hangs or is down, failed wallet login on either alias exits 1 with the restore hint, no `mkstore` without a private staging directory (live-process checks skip where `ps` is unavailable)
- `tests/test_setup_dg_wallet.sh` - Tests `common/setup_dg_wallet.sh` with stubbed Oracle binaries: staging without `mktemp` / with a failing `mktemp`, pre-existing directories and symlinks refused, zero `mkstore` calls when no private directory can be made, failed wallet login (peer or local, including an ORA- error with exit 0) exits 1
- `tests/test_migrate_lib.sh` - Tests `migrate_noncdb_to_pdb/`: `SET DEFINE OFF` before `CONNECT` and a literal `&` in the standby password, the applied-SCN gate (reached / apply lag / query error / wrong role), a static guard against `applied_scn` on `v$archive_dest_status`, and refused re-runs of steps 02-04 leaving `state.env` byte-identical
- `tests/test_step5_fra_reset.sh` - Tests step 5's inherited-FRA helpers (extracted from the script): RESET lines only when the primary has an FRA and the standby has none, never together with a SET of the same parameter, the read-back verdict, and no `exit` between the read-back and the MRP start
- `tests/test_step4_srl_size.sh` - Tests step 4's pre-existing-SRL size check (extracted from the script): byte-exact verdicts (100.4 vs 100.5 MiB is undersized), unverifiable input never reads as adequate, a failed query does not abort the step, and the query applies no rounding
- `tests/test_file_name_convert.sh` - Tests `DB_FILE_NAME_CONVERT` / `LOG_FILE_NAME_CONVERT` pair generation (multi-directory coverage, dedup)
- `tests/test_path_token_remap.sh` - Tests step 2's per-path, case-aware, substring-safe DB-name token remapping
- `tests/test_fs_remap.sh` - Tests step 2's Q1b per-filesystem remap (`apply_fs_map`/`derive_standby_path`: first-component map lookup, whole-component matching, composition order map-then-token-remap, multi-component targets, empty-map no-op) with a drift guard diffing both functions against the script
- `tests/test_counter_increment.sh` - Demonstrates why `((VAR++))` is banned under `set -e` and sweeps the repo for the construct (codebase uses `x=$((x+1))`); the demonstrations run with the shell under test and assert what that Bash version really does (before 4.1 `((x++))` does not trip `set -e`), and a sweep that cannot run fails instead of printing PASS
- `tests/test_df_parsing.sh` - Tests `parse_df_available_kb` / `get_available_space_kb`; guards the `df -Pk` (POSIX format) requirement for AIX compatibility
- `tests/test_grep_portability.sh` - Tests broker-output detection patterns and sweeps the repo for GNU-grep-only usage (`grep -P`, `\s`, BRE `\|` alternation)
- `tests/test_aix_portability.sh` - Repo-wide AIX 7.2 sweep of the shipped (non-test) scripts: GNU-only sed/coreutils flags and GNU BRE extensions, bash 4+ syntax (`mapfile`, `declare -A`, `${v^^}`), Linux-only binaries (`timeout`, `nc`, `systemctl`, `base64`, `mktemp`, `tput`) used without a `command -v` guard - heredocs and `echo`/`printf` lines are excluded so printed command *examples* don't trip it - and the AIX platform guard in both `nfs/` scripts. `nfs/01`/`nfs/02` and `tests/**` are out of scope by design (see the header)
- `tests/test_omf_online_log_dest.sh` - Tests the OMF inherited-parameter helpers in `common/dg_functions.sh` (default `STANDBY_DB_CREATE_ONLINE_LOG_DEST_n` derivation for n=1..5, the safe-path validator accepting `/u01/oradata`/`+DATA` and rejecting relative paths, spaces, quotes, `$`, backticks, `;`, the RMAN `SET`/pfile line builders for none/one/two dests, and the parser for the step 1/5 placement query output)
- `tests/test_sid_detection.sh` - Extracts and tests the real SID-detection/validation pipeline from `dg_status.sh` (`_pmon_sids_from_stream` / `_select_sid_by_dbname` / `_validate_sid`) - no mirrored copies
- `tests/test_visualizer_url.sh` - Tests the dataguard-doc visualizer link helpers embedded in `dg_handoff.sh` and `get_dg_config_url.sh` (block-drift diff between those two copies, base64url payload, field mapping/omission, JSON escaping)
- `tests/test_handoff_html.sh` - Tests the handoff HTML renderer embedded in `dg_handoff.sh` (the only copy - step 10 is a wrapper, so there is no block-drift diff any more; full Markdown-subset conversion fixture: headings, tables, fences, checklist items, verdict pill classes, callouts, escaping, tag balance, AIX-awk array rules)
- `tests/test_sync_impact.sh` - Tests `dg_sync_impact.sh` with a stubbed `sqlplus` dispatching on the `-- QTAG:` markers embedded in every query (argument validation, fatal paths, derived-number math, the top-latency-spike rankings and their ordering, per-section degradation, `--no-pack`, no-SYNC-destination mode, and the `--auto-baseline` scenarios: happy-path window pick, all-SYNC / no-SYNC-snapshots retention edges, flag conflicts, degradation). Also guards the `--html` renderer's AIX-awk portability rules (no function-local arrays, globals seeded in `BEGIN`, no `arr[i,j]` multi-subscripts — AIX 7.2 awk aborts with `0602-558 cannot be used as an array`) and the Markdown-verbatim fallback when the converter's awk dies
- `tests/test_handoff.sh` - Tests `dg_handoff.sh` with a stubbed `sqlplus` dispatching on the `-- QTAG:` markers (including the `standby_direct` query issued through `--standby-tns-alias`) and a stubbed `$ORACLE_HOME/bin/dgmgrl` dispatching on the piped command: happy-path HEALTHY report plus the full deliverable pack (`.html`/`.json`/`_tnsnames.ora`/`_jdbc.properties`/executable `_verify.sh`, JSON validated with python3), the "Changes Since Last Report" diff across consecutive runs and against an explicit `--previous` baseline, verdict escalation (archive gaps, apply lag, broker ERROR, missing role trigger, non-primary host, broker down), service filters, flag handling and exit code 3 paths, per-query degradation into "Discovery Warnings", the descriptor/pool math derived from `--connect-timeout`, the generated `_verify.sh` run against stub `getent`/`nc`/`sqlplus`, and a byte-identical HTML render under `mawk`/`busybox awk` (skipped when neither exists)

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
This creates an observer user with SYSDG privilege, sets MAXIMUM AVAILABILITY mode, enables FSFO. It ends with an **observer placement** section: it checks `FS_FAILOVER_OBSERVER_PRESENT` (already connected = nothing to do) and otherwise asks (TTY-gated - piped/E2E runs just get the printed walkthrough) whether an observer is already set up elsewhere, and if not, where it will run - a repo/NFS host gets the `fsfo/observer.sh` walkthrough, a dedicated third host gets `add_observer/01_prepare_primary.sh` run on the spot (reusing the observer user via `-u`) to generate the bundle. On a multitenant primary (`V$DATABASE.CDB = YES`) the observer user must be a common user: the script detects this, accepts `#` in usernames, and auto-prefixes `C##` (TTY-confirmed; logged and applied automatically in non-interactive runs). After a new user's CREATE/GRANT the script sets the same password again with a separate `ALTER USER ... IDENTIFIED BY` (a failure, e.g. ORA-28007, is a warning): verified on 19.27 with a MOUNTED physical standby, `CREATE USER` + `GRANT SYSDG` do not reach the standby's password file (the observer then gets ORA-01017 there), while the password change carries the entry within seconds. When this run holds the password (new user or reset), `prove_observer_standby_login` then logs in `AS SYSDG` to the other member (`STANDBY_TNS_ALIAS`, or `PRIMARY_TNS_ALIAS` when `DG_CONFIG_ROLES_SWAPPED=1`) through `sqlplus -s -L /nolog` with the password on stdin, polling up to `DG_OBSERVER_STANDBY_LOGIN_WAIT_SECS` (default 30) and exiting 1 before LogXptMode/protection mode/FSFO are touched; an existing user granted SYSDG whose password is kept gets a warning naming the two fixes instead. SYSDG possession is checked via `V$PWFILE_USERS` (administrative privileges never appear in `DBA_ROLE_PRIVS`), and that check is the authoritative post-condition: the CREATE/ALTER USER and GRANT SYSDG heredocs run under `WHENEVER SQLERROR EXIT` + `SET DEFINE OFF`, and any failure (ORA-65096, ORA-28003, a failed grant) stops the step before FSFO is enabled. FSFO enable is verified positively (anchored `Fast-Start Failover: Enabled` in SHOW CONFIGURATION, no error lines); empty dgmgrl output is a failure. The refreshed password file copy goes to the share as `orapw<PRIMARY_ORACLE_SID>`, the same name step 1 writes and step 3 reads. Non-interactive cancels exit 1.

**Step 10: Observer Setup (on OBSERVER server - can be standby or 3rd server; step 9's closing prompt routes you here or to `add_observer/`)**
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

`observer.sh` validates a pidfile's PID against the process's actual command line (must be a `dgmgrl` process, checked with `ps -p`, so an observer owned by another OS user is not mistaken for a dead one) before trusting it as the running observer; stale or mismatched pidfiles are automatically cleaned up, and another host's pidfile is ignored only when the broker reports no observer. `start` passes `FILE IS`/`LOGFILE IS` into `$OBSERVER_DIR` (default `$HOME/fsfo_observer`) and succeeds only once `FS_FAILOVER_OBSERVER_PRESENT` turns YES (30 s poll); `status` exits 0 only when the broker reports the observer present. `setup` refuses (non-TTY) or asks (TTY) before pointing sqlnet.ora away from an existing `WALLET_LOCATION`, adds `SQLNET.WALLET_OVERRIDE = TRUE`, backs the wallet up before editing it, and checks `AUTHENTICATED_IDENTITY` so a SYS credential cannot pass the observer login test. The wallet login must be proven for BOTH aliases: a failure on either prints `FAILED`, the backup location and the restore command, and exits 1. Staging uses `create_temp_dir` and aborts before `mkstore` when no private directory can be made. `start`, `stop`, `restart` and `status` pick one reachable broker member per run (`PRIMARY_TNS_ALIAS`, then `STANDBY_TNS_ALIAS`; each attempt bounded by `DG_OBSERVER_CONNECT_TIMEOUT`, default 20 s, with a shell watchdog) and use it for preflight, launch, presence poll and stop, so the observer can be restarted after a failover while the original primary is down.

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
  only when THIS observer is live: listed in `SHOW OBSERVER`, its own ping no older
  than `DG_OBS_MAX_PING_AGE` (default 60 s), and its pidfile process not known dead.
  Another observer's health never stands in for this one's; `FS_FAILOVER_OBSERVER_PRESENT`
  is used only when `SHOW OBSERVER` cannot be parsed, and is reported as weaker evidence.
  `04_verify_observer.sh` applies the same rule.

## Maximum Availability Without FSFO (Optional)

**Step 13: Set Maximum Availability Protection (on PRIMARY)**
```bash
./primary/13_set_max_availability.sh
```
Raises the configuration to zero-data-loss protection without enabling Fast-Start Failover: validates first (broker `SHOW CONFIGURATION` health, `VALIDATE DATABASE` readiness on both members via `sql/dgmgrl/validate_database.dgmgrl`, transport/apply lag, archive destination errors), then sets `LogXptMode=FASTSYNC` on both databases and `EDIT CONFIGURATION SET PROTECTION MODE AS MAXAVAILABILITY`, and finally polls `SHOW CONFIGURATION` until it returns SUCCESS.

- Skip this step if Step 9 (FSFO) was run — FSFO setup already applies both settings; the script detects that and exits as a no-op before any prompt (LogXptMode values are compared quote-stripped and uppercased).
- Broker health is graded with `dgmgrl_status_value`; the final poll mirrors step 6 (12 × 10 s) and only SUCCESS ends it early. Non-interactive aborts exit 1.
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

Service discovery (`sql/queries/get_user_services*.sql`) excludes every default service case-insensitively, with or without the `.<db_domain>` suffix (`DB_NAME`, `DB_UNIQUE_NAME`, instance name, each container name), the exact `<name>XDB` dispatcher services (not `%XDB%`), `SYS$*` and the broker's `_CFG`/`_DGMGRL` services - the same semantics as `dg_handoff.sh`'s DEFAULT classification. Verified on the 19c lab (`db_domain=world`): the old query offered the root default service `cdb1.world` as a user service, which would have made the trigger stop it on the standby at every role change. The packages check `V$ACTIVE_SERVICES` before START/STOP (no alert-log noise), the scripts warn when the SYS and dedicated-user trigger sets coexist, and `-n/--check` stops after discovery and the printed plan, before any user, helper procedure, package, trigger or service change.

**Alternative variant: dedicated user**
```bash
./trigger/create_role_trigger_dedicated_user.sh
```
Same behavior, but creates a dedicated database user (`DG_ADMIN`; non-CDB only - the script refuses a CDB and points to `create_role_trigger_cdb.sh`, and the user gets the database's default temporary tablespace) with only the privileges required (including `SELECT ON V_$ACTIVE_SERVICES`), and places the package and triggers under that user instead of `SYS`. Use this variant when policy disallows adding objects to `SYS`. Since the dedicated user cannot call SYS-only `DBMS_SYSTEM.KSDWRT` for alert-log writes, the script creates a narrow SYS-owned wrapper procedure (`SYS.DG_ALERT_LOG_MSG`) and grants `EXECUTE` on that wrapper only - not on `DBMS_SYSTEM` - to the dedicated user.

**Alternative variant: CDB / PDB-aware**
```bash
./trigger/create_role_trigger_cdb.sh
```
SYS-owned variant for **multitenant (CDB)** databases that manages services living inside PDBs as well as user services at the `CDB$ROOT` level. The base `create_role_trigger.sh` only manages services in the current container, which is insufficient when application services belong to PDBs.

Key differences from the base script:
- Verifies `V$DATABASE.CDB = YES` (errors and points to the base script otherwise).
- Discovers services as `(container, service)` pairs via `sql/queries/get_user_services_cdb.sql` (`V$ACTIVE_SERVICES` joined to `V$CONTAINERS`), excluding `PDB$SEED`, system services, and each container's default service (with or without the `.<db_domain>` suffix, compared case-insensitively). Root-level `V$ACTIVE_SERVICES` checks filter on `CON_ID = SYS_CONTEXT('USERENV','CON_ID')`, so a same-named PDB service cannot mask a root service.
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

`dg_handoff.sh` is the **single implementation** (emitter, HTML twin, JSON sidecar, deliverable pack, visualizer link, verdict). `primary/10_generate_handoff_report.sh` is a thin wrapper that adds only what the setup workflow knows: the setup-step banner/preflight/`select_config_file` chrome, `-n` check mode, the `docs/DG_APPLICATION_IMPACT.html` copy onto the share, the status/summary blocks, and the setup-step exit convention (nonzero only on ERROR, an unexpected `dg_handoff.sh` exit status, or a missing/empty report file). It then calls `dg_handoff.sh -o ${NFS_SHARE}/dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.md --primary-host --standby-host --port --all-flavors [--standby-tns-alias] [--impact-reference] [--env] [--contact]` from the build's `standby_config_*.env`. Consequences: the HTML renderer and the visualizer helper block live **only** in `dg_handoff.sh`; `sql/queries/get_role_trigger_status.sql`, `sql/queries/get_service_ha_attributes.sql` and `sql/dgmgrl/show_fsfo_threshold.dgmgrl` were deleted (only step 10 used them).

The report collects a status snapshot for both DBAs and application teams: roles, open modes, protection mode, standby `LogXptMode`, MRP/apply lag, archive gaps, FSFO state (threshold shown only when FSFO is enabled), broker config, role-trigger deployment status, and server-side `SQLNET.EXPIRE_TIME`. The role trigger counts as ready only when ONE owner (SYS, or the dedicated user) holds a VALID `DG_SERVICE_MGR` package spec and body plus both triggers ENABLED and VALID; an invalid body, a disabled/invalid/missing trigger, objects split across owners, or two complete installations are each reported as a named problem with an action (WARNING). The report states object state ("deployed and valid"), not runtime behaviour. Apply/transport **lag in time** is parsed from the broker's `SHOW DATABASE '<standby>'` ("Apply Lag: N seconds (computed ...)") or from a direct standby connection (`--standby-tns-alias`), and surfaces in At a Glance ("Standby data freshness"), the Status Snapshot, the JSON sidecar and the verdict. The report opens with an **At a Glance** section (verdict + one-line RPO/failover/readability/freshness facts + which connect string to hand out), then **Changes Since Last Report** (diff against the previous JSON sidecar: verdict, DB unique names, hosts, port, protection mode, LogXptMode, standby open mode, FSFO, role trigger, DB version, descriptor timeouts, and services added/removed/changed; a one-liner on the first run or when nothing changed, and a "not comparable" note instead of a diff when the service filter differs), then the application-facing sections (1 Connection Strings, 2 Application Impact, 3 Client and Pool Settings, 4 Verification); all DBA-only material (topology, status snapshot, broker output, datafile/PDB convert-pair note, discovery warnings) lives in a closing **Appendix: DBA Snapshot**, which also carries **Recommended Service Changes (DBA)**: for every USER service missing TAF, `COMMIT_OUTCOME` or `DRAIN_TIMEOUT`, a ready `DBMS_SERVICE.MODIFY_SERVICE` snippet (prefixed with `ALTER SESSION SET CONTAINER` for a PDB service) with suggested starting values and the "restart the service for new sessions" note. The **Verdict** is computed with each reason named *and an action attached* (e.g. which script to run): ERROR on broker-config errors/ORA- diagnostics, failure-state switchover status, or apply lag beyond `DG_SEQ_GAP_CRIT` sequences; WARNING on lesser findings (broker warnings, role trigger not deployed, standby readability unknown, no user-created service, apply lag in time beyond `DG_LAG_WARN_SECONDS` (default 60), a `--service` name that matches nothing); HEALTHY only when nothing fired. `DG_HANDOFF_ENV` / `DG_HANDOFF_CONTACT` (env vars; `--env`/`--contact` flags on `dg_handoff.sh`) add an environment label and DBA-contact chip to the header. Each service's HA attributes are read from the dictionary (an inline `CDB_SERVICES` query, case-insensitive on the name, since the dictionary stores a PDB default service uppercased) and stated per service as facts: TAF type/method/retries/delay, Transaction Guard `COMMIT_OUTCOME` (`TRUE`/`YES` both mean enabled), `DRAIN_TIMEOUT`, `FAILOVER_RESTORE`. The standby's open mode is derived from the broker's `Real Time Query` field (19c DGMGRL prints no "Open Mode" line) plus, when `--standby-tns-alias` is given, a best-effort auto-login-wallet connect to the standby (never prompts). Hostname discovery prefers the broker's `HostName` property; `DGConnectIdentifier` is only trusted when it is a genuine easy-connect string, never a TNS alias. The default `<DB_UNIQUE_NAME>` service is flagged as NOT managed by the role trigger. Role-aware TNS + JDBC + Easy Connect Plus strings are always emitted; `--all-flavors` (which step 10 passes) adds two more per service:

- **Primary-only** TNS + JDBC — writes / admin
- **Standby-only** TNS + JDBC — read-only reporting against an open standby. If the standby is `MOUNTED`, the report marks these strings as not currently usable; if it is `READ ONLY WITH APPLY`, it includes the Active Data Guard licensing note, apply-lag/read-your-writes caveat, and ORA-16000 no-DML warning
- **Role-aware failover** TNS + JDBC + Easy Connect Plus — single descriptor with both hosts in `ADDRESS_LIST`. Recommended for the application tier when `trigger/create_role_trigger.sh` is deployed and enabled: the service is only running on whichever side is primary, so clients automatically follow the active database after a switchover or failover

The report is written for application engineers, technical and fluff-free: precise RPO semantics per protection/transport mode (stated separately for SYNC - ack after the standby redo disk write - and FASTSYNC - ack on receipt into standby memory; the standby-disconnected loss window; ASYNC loss bounds), an outage-budget breakdown (FSFO threshold + failover execution + service startup + reconnect), an "Errors During Role Transitions" ORA- table (12514/12541/01033/03113/25402/16000 with retryability) plus commit-ambiguity guidance (in-doubt COMMIT, idempotency, Transaction Guard prerequisites), a descriptor-parameter reference with worst-case connect math DERIVED from the `TNS_CT`/`TNS_TCT`/`TNS_RC`/`TNS_RD` shell variables (defaults 10/3/3/3, overridable per run with `--connect-timeout`/`--transport-timeout`/`--retry-count`/`--retry-delay` or the matching `DG_HANDOFF_*` env vars) that also render the descriptors, the JDBC/EZ+ strings and the pool checklist - change the knobs and the prose stays true (33 s both-hosts-down, 21 s primary-down at the defaults); the descriptors themselves configure **no** `FAILOVER_MODE` - TAF is reported as a per-service dictionary fact only; the Easy Connect Plus strings carry the same connect/retry values as the TNS descriptor (retry_delay omitted - not every 19c client parses it), ADG read-staleness controls (`STANDBY_MAX_DATA_DELAY`/ORA-03172, `SYNC WITH PRIMARY`), sequence-cache gap and NOLOGGING/ORA-26040 specifics, Easy Connect Plus and driver mapping examples for ODP.NET / python-oracledb / SQLAlchemy (one set of labeled copy-button code blocks for the first role-manageable service, not a clipped table per service), a concrete client/pool settings checklist (checkout timeout derived from the descriptor math, read/call timeouts, `(ENABLE=BROKEN)` keepalive, validate-on-borrow, logon-storm cap), and a verification section: `tnsping`/`nc -z` against both hosts plus an end-to-end `SYS_CONTEXT('USERENV', ...)` role check through the role-aware descriptor that doubles as the switchover-drill pass criterion.

It also copies `docs/DG_APPLICATION_IMPACT.html` to `${NFS_SHARE}/dg_application_impact.html` when available and links it from "Notes for Client Teams". The Markdown remains self-contained: the "Application Impact Summary" bullets cover commit-latency/RPO, outage budget, cold-cache brownout, NOLOGGING/ORA-26040, and the reach-both-hosts prerequisite, so the HTML briefing is supplementary, not required reading.

User-visible services are discovered from `V$ACTIVE_SERVICES` (same logic as the role trigger), with the default `<DB_UNIQUE_NAME>` service always included. **Output files**, all written next to the Markdown (`<out>` = output path without `.md`; step 10 puts them on the NFS share as `dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.*`, and a "Files" chip in the report header lists them):

- `<out>.md` - the report, also printed to stdout
- `<out>.html` - the styled self-contained twin (below)
- `<out>.json` - line-oriented machine-readable sidecar (`schema_version` 1; one scalar per line and one service object per line, so a POSIX-awk reader can parse it back). Keys: generation/env/contact, `verdict` + `verdict_notes[]`, DB unique names/hosts/port, role, open modes, version/CDB/charset/domain, protection mode, LogXptMode, switchover status, force logging, broker state, sequence and time lag, archive gaps, FSFO fields, role-trigger state, `sqlnet_expire_time`, `visualizer_url`, `descriptor{}` (the four timeouts + worst-case seconds), `service_filter[]`/`service_exclude[]`, `services[]` (name, container, class, role_aware, TAF/COMMIT_OUTCOME/DRAIN_TIMEOUT/FAILOVER_RESTORE, TNS alias, easy connect, JDBC), `discovery_warnings[]`. It is also the baseline the next run diffs for "Changes Since Last Report"; `--no-json` skips both
- `<out>_tnsnames.ora` / `<out>_jdbc.properties` - the deliverable pack an application team installs (one `<SERVICE>_HA` alias/URL per service, plus `_PRI`/`_STB` under `--all-flavors`)
- `<out>_verify.sh` - runnable reachability + `SYS_CONTEXT` role check for application hosts (no repo, no Oracle server install needed: every external tool is `command -v`-probed and a missing one SKIPs rather than fails). `-u user/pass` or `APP_USER`/`APP_PASSWORD` enable the end-to-end check; `--expect-db-unique-name X` makes it the switchover-drill pass criterion. Skipped when no standby hostname is known; `--no-pack` skips the whole pack

The Markdown emitter stays the single definition of the report; a built-in POSIX-awk converter (`handoff_md_to_html` + `render_handoff_html`, between `# ---- begin/end handoff html renderer ----` markers in `dg_handoff.sh` - the only copy) renders it into a light/dark-theme page (ČSOB brand palette — Pacific Blue `#0099CC`, Seagull `#80CCE6`, Midnight `#003366` via the same `--br`/`--brs`/`--brf`/`--brn` tokens as the ČSOB variant in the dataguard-doc repo, with the ČSOB logo as an inline `data:` PNG in a mono uppercase eyebrow, sitting on a white chip in dark theme; `prefers-color-scheme`) with the report meta as a chip strip, the verdict as a colored pill, WARNING/blockquote amber callouts, checklist boxes for `- [ ]` items, and terminal-styled descriptor blocks with clipboard copy buttons. It also emits slugified heading anchors and a table of contents (sticky sidebar at >= 1100px, a collapsible `<details>` block below that), a print stylesheet (`@media print`: one h2 per page, no copy buttons or TOC, link URLs printed), and a staleness banner (inline JS compares the "Generated" chip against `DG_HANDOFF_STALE_DAYS`, default 30; no JS, no banner). Branding is overridable by env, defaults reproducing the previous output byte for byte: `DG_HANDOFF_BRAND_NAME` (default `Oracle Data Guard`), `DG_HANDOFF_BRAND_LOGO` (image file to inline as a `data:` URI, or `none`; default the built-in ČSOB PNG), `DG_HANDOFF_BRAND_COLOR` `#0099CC`, `DG_HANDOFF_BRAND_INK` `#003366`, `DG_HANDOFF_BRAND_TINT` `#DCEFF7`, `DG_HANDOFF_BRAND_DARK_ACCENT` `#80CCE6`. Step 12 cleanup's `--all` removes the HTML twin, the JSON sidecar and the pack along with the Markdown. Re-run after listener changes, new services, or topology changes to refresh the report.

Robustness notes:
- A failed HTML render warns and drops the `.html` (and its Files-chip entry) - the JSON, pack, stdout report and verdict exit code still happen; the converter returns non-zero instead of shipping a truncated page.
- Broker output is classified on the `Configuration Status:` value plus `Error:` lines: an ORA- under a member's `Warning:` line is a WARNING, not an ERROR; DISABLED is a WARNING; empty dgmgrl output while the broker is started is a discovery warning.
- `V$ARCHIVE_GAP` is only meaningful on the standby: it is queried through `--standby-tns-alias`; without it the row says "not assessable from the primary" and the JSON `archive_gaps` is `null`.
- The FSFO threshold is a configuration property, read from `SHOW FAST_START FAILOVER` (`Threshold:`) with `SHOW CONFIGURATION FastStartFailoverThreshold` as fallback; the diff compares the same FSFO-gated value the JSON writer stores, so FSFO-disabled reruns show no spurious change.
- The pack's aliases (`<SERVICE>_HA` etc.) are unqualified; a client whose sqlnet.ora sets `NAMES.DEFAULT_DOMAIN` must append that domain to them (the report and `_tnsnames.ora` header say so).
- `json_escape` uses tr/sed, not awk `gsub` (bwk awk mangles backslashes), and strips control bytes by explicit octal range, never `[[:cntrl:]]` (which matches 0x80-0x9F under ISO8859-1).
- `_verify.sh` runs `sqlplus -s -L /nolog` with `SET DEFINE OFF` and `CONNECT` on stdin (no password on argv; the EZ+ string contains `&`), resolves names via `getent`, then `host` (AIX, honours /etc/hosts), then `ping -c1` (no `-W`), and SKIPs rather than FAILs when no resolver is available.
- Flag values: a missing value exits 3; numeric values are normalised with `10#` (no octal surprises from `08`); `--port` must be 1-65535; `--previous` with a missing file exits 3.

The report header also carries an **"Interactive diagram"** link: the discovered topology (DB unique names, hosts, observer host/placement, first service, port, protection mode, LogXptMode, FSFO threshold — never credentials) is encoded as `#cfg=<base64url(JSON)>` for the interactive Data Guard configuration explorer (source repo `davidbudac/dataguard-doc`, published at `https://davidbudac.cz/dataguard/`; base overridable via `DG_DOC_BASE_URL`). Unknown/undiscovered fields are omitted so the page falls back to its defaults; the link is skipped entirely if neither `base64` nor `openssl` exists on the host. The helper block is duplicated **byte-identically** in `dg_handoff.sh` and `get_dg_config_url.sh` between `# ---- begin/end dataguard-doc visualizer helpers ----` markers — `tests/test_visualizer_url.sh` diffs the copy in `get_dg_config_url.sh` against the one in `dg_handoff.sh` (the reference) and fails on drift, so edit that one and re-copy.

**Link only, on demand: `get_dg_config_url.sh`** (root of repo)
```bash
./get_dg_config_url.sh                                   # summary on stderr, URL on stdout
./get_dg_config_url.sh -q                                # URL only (URL=$(./get_dg_config_url.sh -q))
./get_dg_config_url.sh --standby-host stb --port 1521    # fill in what discovery missed
```
Generates the same visualizer link for **any existing** Data Guard configuration without producing a handoff report. Connects with `sqlplus / as sysdba` and discovers the topology from `V$DATABASE`, `V$DATAGUARD_CONFIG`, `V$LISTENER_NETWORK`, `V$ACTIVE_SERVICES` and `DGMGRL SHOW DATABASE`; standalone (no `standby_config_*.env`, no `common/dg_functions.sh`, no NFS share), so it can be copied to a DB host on its own. Runs from either side — on a standby it swaps the roles and reports the local host as the standby. Overrides: `--primary-host`, `--standby-host`, `--observer-host`, `--port`, `--service`, `--base-url`. Undiscovered fields are omitted (page defaults apply) and every query is best-effort; only a failed `sqlplus / as sysdba` connection or a host with neither `base64` nor `openssl` is fatal.

**Standalone use: `dg_handoff.sh`** (root of repo)
```bash
./dg_handoff.sh
./dg_handoff.sh -o /tmp/handoff.md
./dg_handoff.sh --primary-host pri --standby-host stb --port 1521
./dg_handoff.sh --standby-tns-alias STB_ALIAS --all-flavors
./dg_handoff.sh --service APP_SVC --exclude-service 'PDB1:OLD_SVC'
./dg_handoff.sh --connect-timeout 5 --retry-count 2 --previous old.json --no-json --no-pack
```

Flags: `-o/--output`, `--primary-host`/`--standby-host`/`--port`, `--standby-tns-alias A` (env `DG_HANDOFF_STANDBY_TNS_ALIAS`; best-effort auto-login-wallet query of the standby's `OPEN_MODE` and `V$DATAGUARD_STATS` - facts the broker cannot supply), `--all-flavors`, `--impact-reference PATH` (what the "Full application behavior briefing" bullet points at, instead of the auto-detected local `docs/DG_APPLICATION_IMPACT.html`), `--env`/`--contact`, `--service NAME` / `--exclude-service NAME` (both repeatable, case-insensitive, `CONTAINER:NAME` form accepted; an unmatched `--service` escalates the verdict to WARNING, and an active filter is stated as a header chip and suppresses the service diff), `--connect-timeout`/`--transport-timeout`/`--retry-count`/`--retry-delay N` (validated as non-negative integers; exit 3 otherwise), `--previous FILE` (sidecar to diff against instead of the default JSON path), `--no-json`, `--no-pack`.

Runs against any existing Data Guard configuration without depending on `standby_config_*.env`, `common/dg_functions.sh`, or the NFS share. Topology (peer `DB_UNIQUE_NAME`, hostnames, listener port) is discovered from `V$DATABASE`, `V$DATAGUARD_CONFIG`, `V$LISTENER_NETWORK`, and `DGMGRL SHOW DATABASE VERBOSE`, plus version/CDB/charset/`db_domain` for the header and client notes. Use the `--*-host` / `--port` flags when broker is down or discovery returns the wrong value; `--env`/`--contact` fill the header chips. Output defaults to `./dg_handoff_<PRIMARY_DB_UNIQUE_NAME>.md` (plus the HTML/JSON/pack files listed above). Service discovery is **container-aware**: services come from `V$ACTIVE_SERVICES` joined to `V$CONTAINERS` (works on non-CDB - single CON_ID=0 row), each service section names its container (warning for `CDB$ROOT`), every container **default** service (`DB_NAME[.DB_DOMAIN]`, `DB_UNIQUE_NAME`, instance name, PDB name) is flagged NOT role-aware (registered wherever the container is up, incl. the standby - never a failover descriptor), user-created services sort first, and zero user-created services is a WARNING. Without `--all-flavors` it emits role-aware descriptors only (the standby-readability note is stated once). Exit codes: `0` HEALTHY, `1` WARNING, `2` ERROR, `3` usage/connect failure (the step-10 wrapper keeps the setup-step convention: nonzero only on ERROR). A run on a non-primary emits a prominent in-report warning (service discovery is incomplete there). The standalone report references `DG_APPLICATION_IMPACT.html` only when the file is present next to the script or under `docs/`.

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

`primary/01_gather_primary_info.sh` and `primary/09_configure_fsfo.sh` stage `orapw*` password file copies (SYS password hash) on the group-readable NFS share; `primary/02_generate_standby_config.sh` and `standby/05_clone_standby.sh` leave a generated pfile and RMAN duplicate cmdfiles/logs behind. None of this is ever cleaned up automatically.

**Step 12: Clean Up NFS Artifacts (on any host with the share mounted, optional)**
```bash
./common/cleanup_nfs_artifacts.sh                 # default: password files, pfile, RMAN cmdfiles/logs
./common/cleanup_nfs_artifacts.sh -c /path/to/standby_config_<NAME>.env
./common/cleanup_nfs_artifacts.sh --all           # also remove config .env, the whole handoff set (.md/.html/.json/_tnsnames.ora/_jdbc.properties/_verify.sh), app-impact HTML, generated TNS/listener/broker files, dg_service_mgr*_<PRIMARY>.sql, the observer pidfile and logs (skipped while the observer runs), and this build's logs/state files
./common/cleanup_nfs_artifacts.sh -y              # skip the confirmation prompt
```

Run this once Data Guard has been verified (Step 7) and the handoff report has been reviewed. It selects (or accepts via `-c`/`--config`) the build's `standby_config_*.env`, prints exactly what will be removed and what will be kept, and requires confirmation before deleting anything. The `orapw<SID>` copy is named by the primary SID only, so when another build's `standby_config_*.env` on the share references the same primary it is flagged as shared and the script warns and asks before removing it (`-y` skips the question).
