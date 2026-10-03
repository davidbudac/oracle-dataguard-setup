# Implementation review: production readiness and IBM AIX 7.2

Date: 2026-10-01

Reviewed commit: `9e2c82ac058a004de2ad93f7438fbcda9e3195d3`

Scope: implementation correctness, logical errors, operational failure handling, and AIX 7.2 compatibility. Architecture redesign was outside scope.

## Verdict

**The reviewed implementation is not ready for production sign-off.** This review identifies 14 actionable issues, including unsafe check-mode behavior, observer recovery failures, and a migration verification query that cannot work on Oracle 19c.

This is a follow-up to [the earlier review](REVIEW_2026-10-01.md). It describes the implementation at the commit above, after the earlier fixes. It does not claim those fixes were never made. No implementation files were changed during this review; this document records findings for a subsequent agent to fix.

## Fix status (added 2026-10-03, after the fix pass)

All 14 findings are fixed in code and covered by DB-free tests. The three release gates are
answered below: one is fixed, two stay open because they need systems this pass did not run
on. Nothing here has been through a real clone, switchover, failover or migration yet, so the
verdict above stands until [TEST_PLAN_2026-10-01.md](TEST_PLAN_2026-10-01.md) Phase 12 has
been run. The plan, the design decisions and the batch split are in
[FIX_PLAN_2026-10-01_FOLLOWUP.md](FIX_PLAN_2026-10-01_FOLLOWUP.md).

### Lab run 2026-10-03 (added the same evening)

The E2E run and the first Phase 12 rows were run on `23d6ec8`. Steps 1-9 and 13, the ten
Phase 1 spot checks and rows 12.1, 12.2, 12.4, 12.5 and 12.7 passed, which covers findings 1,
2, 4 (Linux), 7 and 13 on a real system. Step 10 failed, on a defect this review did not
contain:

**Finding 15 (High, found in the lab).** On 19.27 with a MOUNTED physical standby,
`CREATE USER` + `GRANT SYSDG` on the primary does not reach the standby's password file; a
following `ALTER USER … IDENTIFIED BY` carries the entry over within a second. The observer
user created by step 9 (and by `add_observer/01` and `observer_sys_to_sysdg/01`) therefore
had no login on the standby. Finding 13's both-aliases check is what exposed it. It is fixed
in code and unit-tested (fix plan, finding 15); the lab verification is test plan row 12.12,
together with the clean end-to-end E2E run that is still owed. The verdict above stands until
then. Current lab state and next steps: [HANDOFF_2026-10-03.md](HANDOFF_2026-10-03.md).

### How the fixes were verified

- **Unit suites:** 25 pass under Bash 5.3 and under Bash 3.2.57 (driver and every inner
  `bash`), with `ps` available so no check is skipped. Five suites are new:
  `test_fsfo_observer`, `test_setup_dg_wallet`, `test_migrate_lib`, `test_step5_fra_reset`
  and `test_step4_srl_size`.
- **Read-only on the 19c lab** (`cdb1` / `cdb1_stby`, 2026-10-03), no file written there:
  - `V$ARCHIVE_DEST_STATUS` has no `APPLIED_SCN`; `V$ARCHIVE_DEST` has one, but it trailed
    the standby's own `V$DATABASE.CURRENT_SCN`.
  - The new standby gate query returns `PHYSICAL STANDBY|cdb1_stby|<scn>` on the MOUNTED
    standby.
  - `rman checksyntax` accepts `RESET DB_RECOVERY_FILE_DEST` /
    `RESET DB_RECOVERY_FILE_DEST_SIZE` inside `DUPLICATE … SPFILE`.
  - Step 5's live-primary FRA query, the identity query (`cdb1|PRIMARY|<dbid>`) and the new
    role-trigger query all parse and return rows. The role-trigger query answered
    `0|NONE|NONE|NONE`, because `cdb1` has no trigger deployed, so the "healthy
    installation" answer is still unseen.
  - `dg_check_srl.sh -L` with the byte-exact queries: OK on both sides. Step 4's query
    returns `52428800|52428800` (smallest SRL, largest ORL).
  - The `SHOW OBSERVER` parser, fed the lab's real output, finds the observer by name and by
    short host name and reads both ping ages, including the singular `1 second ago`.

### Status by finding

| # | Status | What was done | Still needs a real system |
|---|---|---|---|
| 1 | FIXED | `fsfo/observer.sh -n` on setup/start/stop/restart runs read-only queries, prints the plan and changes nothing (stale pidfiles included). `-a` asks before every mutating action; a decline exits 1 | Test plan 12.1 |
| 2 | FIXED | `assert_db_matches_config` compares `DB_UNIQUE_NAME`, role and DBID with the selected config in steps 4 and 6 (must be the config's primary) and 9, 10, 13 (either member holding the PRIMARY role), before the `-n` stop. Step 6 names foreign broker members before `REMOVE CONFIGURATION`, refuses non-interactively and asks for a typed confirmation on a TTY | 12.2 (the lab has two primaries on one host) |
| 3 | FIXED | `add_observer/03` and `04`: up = listed by the broker and this observer's own ping within `DG_OBS_MAX_PING_AGE` (60 s) and the pidfile process not known dead. A registered-but-dead observer is restarted with its existing `.dat` file; the stale entry is deregistered by name only if the broker refuses the start | 12.3. What the broker answers to a `START OBSERVER <name>` over its own stale registration is an assumption |
| 4 | FIXED | `setup_dg_wallet.sh` stages in `mktemp -d` or an exclusive, verified private `mkdir`, else exits 1 before any `mkstore` call. `fsfo/observer.sh` uses the shared `create_temp_dir` with the same abort | 12.4, 11.10 |
| 5 | FIXED | Step 05 gates on the CDB standby's own `V$DATABASE.CURRENT_SCN` (direct connection, role and unique name checked in the same query). Reached, apply lag and query error are three separate outcomes; a query error is no longer waited out as lag | 9.2, 9.8 |
| 6 | FIXED | Step 5 asks the live primary; when it has an FRA and the standby is configured without one, the SPFILE clause carries the two `RESET` lines. The standby's effective values are read back; a contradiction fails the step at the end, after the remaining post-clone actions | 12.8. RESET semantics inside DUPLICATE are confirmed for syntax only |
| 7 | FIXED | `create_temp_dir` fallback uses a distinct `dg_tmp_<pid>_<n>_<random>` candidate per allocation, with bounded retries; an existing path is never reused. Step 4 now ends in ERROR when the static listener entries could not be inserted, instead of warning | 12.5 |
| 8 | FIXED | `fsfo/observer.sh` picks one reachable member per run (primary alias, then standby alias; each attempt bounded by `DG_OBSERVER_CONNECT_TIMEOUT`, 20 s, by a shell watchdog) and uses it for preflight, launch, presence poll and stop | 12.6 |
| 9 | FIXED | Ready only when one owner holds a VALID package spec and body and both triggers ENABLED and VALID. Each other state is named with an action. JSON keys unchanged | 12.9 |
| 10 | FIXED | Steps 02, 03 and 04 clear state only when a new attempt begins; a refused re-run leaves `state.env` byte-identical | 9.6 |
| 11 | FIXED | `SET DEFINE OFF` and error handling before `CONNECT` in both standby branches; a password containing `"` is refused at the prompt; xtrace paused around the password | 9.9 |
| 12 | FIXED | Reachability probes, pmon detection and the standby `DB_NAME` queries run under the collection watchdog: `DG_REMOTE_TIMEOUT` per call, twice that for all of discovery, exit 2 on a timeout | 12.10 |
| 13 | FIXED | Both wallet scripts exit 1 on a failed login, print no success summary, and name the backup with the restore command. `fsfo/observer.sh` proves both aliases | 12.4, 12.7 |
| 14 | FIXED | Sizes compared in exact bytes; DDL sizes rounded up to whole MiB. Step 4's own check of pre-existing SRLs had the same gap in another form (two rounded-up MiB figures) and now compares bytes too | 12.11 |

### Fixed along the way, not in the review

- **Migration, large SCNs:** `SELECT current_scn` without `TO_CHAR` prints in scientific
  notation once the SCN is wider than 10 digits, which no gate comparison would match.
  All SCN reads use `TO_CHAR` now.
- **Migration, exit codes:** `WHENEVER SQLERROR EXIT SQL.SQLCODE` wraps modulo 256, so some
  errors exited 0. The toolkit uses `EXIT FAILURE`.
- **Migration, standby identity:** step 05 and the step 01/04 prerequisite check now refuse
  an alias that answers as the primary or as another database.
- **`04_verify_observer.sh`:** another observer's `FS_FAILOVER_OBSERVER_PRESENT=YES` used to
  pass verification for this one.
- **`tests/test_grep_portability.sh`:** same `mapfile` bug as the counter test, with the same
  false PASS under Bash 3.2.
- **Step 10 after a switchover:** the wrapper passes the current primary and standby hosts
  to `dg_handoff.sh`.

### Remaining release gates

| Gate | Status | Comment |
|---|---|---|
| OMF control-file placement | OPEN | Not changed. Whether the standby inherits the primary's explicit `control_files` in OMF mode is still unobserved, and a guessed fix in a non-restartable step is worse than none. Test plan Phase 10 decides: files under `db_create_file_dest` closes it, anything else means an explicit `CONTROL_FILES` handling in step 5's OMF branch |
| Test-runtime compatibility | FIXED | Supported shell declared as Bash 3.2 or later. `test_counter_increment.sh` runs its demonstrations with the shell under test, asserts what that version really does, and fails when its sweep cannot run. All 25 suites pass with Bash 3.2 as both driver and inner shell, and with `ps` available |
| AIX 7.2 lifecycle validation | OPEN | Cannot be closed from this repository. Test plan Phase 11 now carries the lifecycle items the review lists (rows 11.10-11.16) |

### Known and left as is

- After a switchover, step 9 still names the staged password-file copy
  `orapw<PRIMARY_ORACLE_SID>` from the config, which may not be the SID of the host it now
  runs on.
- A complete trigger installation plus leftovers under a second owner stays "ready"; the
  report adds a note to drop the leftovers. Two complete installations are not ready.
- Killing the local ssh in `dg_status.sh` does not necessarily end the remote `sqlplus`; it
  ends when it next writes or when sshd reaps the session. The collection watchdog has always
  had this property.
- The wallet scripts do not roll back automatically after a failed login. The cause may be a
  database that is down, so the operator gets the backup and the restore command.

## Evidence and limits

- All 48 shipped shell scripts passed Bash 3.2 syntax checks.
- The AIX portability scan passed.
- 19 of 20 regression suites passed under Bash 3.2 on macOS. The remaining suite has Bash-version assumptions described below.
- Findings explicitly marked **Reproduced** were exercised with isolated functions and mocked commands. These were not live database or observer tests.
- Other findings were established by source inspection and, where cited, Oracle documentation. Suggested integration tests remain outstanding.
- Some process-cleanup assertions were skipped because process inspection was unavailable in the sandbox. Alternative-awk coverage was also skipped where the required interpreter was unavailable.
- No live database operations or AIX execution were performed. These checks do not constitute AIX certification.
- The project's documented scope is filesystem storage and single-instance databases; ASM and RAC were not treated as supported deployment targets.

**Priority:** High means production use of the affected workflow should be blocked pending resolution. Medium means a concrete failure under the described conditions. Fix findings 1–6 first, then complete the remaining regression cases before the AIX lifecycle test.

## Findings

### 1. High — Observer check mode can actually stop the observer

**Evidence:** Reproduced with mocked commands.

**Locations:** [fsfo/observer.sh:37](../fsfo/observer.sh#L37), [stop implementation:879](../fsfo/observer.sh#L879).

The shared argument parser accepts `--check`, `--plan`, and `--approval-mode`, but the observer command implementations do not enforce them. With `CHECK_ONLY=1`, the extracted stop function still invoked `STOP OBSERVER` and removed its PID file in a mocked test. Setup and start also contain unguarded mutations.

**Impact:** An operator requesting a preview can change wallet/process state or stop the production observer. Approval mode also does not provide its expected protection.

**Fix:** Enforce these modes before any mutating operation, or explicitly reject unsupported flags before dispatching the command.

**Acceptance test:** Run setup/start/stop/restart with `--check` and assert that no wallet writes, database commands, process launches, signals, or PID-file deletions occur. Exercise approval mode separately and verify that rejected actions do not execute.

### 2. High — Selected configuration is not checked against the database receiving destructive commands

**Evidence:** Source inspection.

**Locations:** [primary/06_configure_broker.sh:36](../primary/06_configure_broker.sh#L36), [configuration removal:165](../primary/06_configure_broker.sh#L165), [primary preparation](../primary/04_prepare_primary_dg.sh).

The script checks the ambient Oracle connection, then loads the selected configuration. It does not establish that the locally connected database is the primary named in that configuration. On a host with multiple databases, a stale `ORACLE_SID` can direct broker operations at a different database. After the existing confirmation, that includes disabling FSFO and removing its broker configuration. Primary preparation has the same missing identity check.

**Impact:** The configuration the operator selects and the database actually modified can differ.

**Fix:** Before mutations, compare the connected database's `DB_UNIQUE_NAME`, role, and recorded DBID where available against the selected configuration. Validate existing broker membership before removal. Apply the identity guard consistently to other mutating primary steps.

**Acceptance test:** Select configuration B while connected to database A; execution must refuse before issuing any mutating SQL or broker command. Include two primary databases on the same host, so a role-only check cannot pass incorrectly.

### 3. High — A dead observer's registration prevents automatic restart

**Evidence:** Reproduced with a stale broker listing.

**Locations:** [add_observer/03_observer_ctl.sh:183](../add_observer/03_observer_ctl.sh#L183), [watchdog command:500](../add_observer/03_observer_ctl.sh#L500).

`observer_up_here` treats a matching name or host in `SHOW OBSERVER` as proof of liveness. A mocked listing with stale heartbeats and `observer_present=NO` still returned success. Consequently, both startup and the generated `status || start` watchdog can leave a crashed observer stopped.

Oracle explicitly distinguishes registered observers from observers that are still running. See the [Oracle broker command reference](https://docs.oracle.com/en/database/oracle/oracle-database/19/dgbkr/oracle-data-guard-broker-commands.html).

**Impact:** The generated reboot/watchdog integration can report success while leaving FSFO without this observer.

**Fix:** Separate registration from liveness. Use observer-specific heartbeat/process evidence and support restarting with the existing observer state file. Another observer's presence must not substitute for this observer's health.

**Acceptance test:** Kill the observer without deregistering it, then test watchdog recovery and host reboot. Repeat with a second observer running elsewhere.

### 4. High — Wallet staging is unsafe when mktemp is unavailable

**Evidence:** Source inspection; no exploit was executed.

**Location:** [common/setup_dg_wallet.sh:361](../common/setup_dg_wallet.sh#L361).

The fallback uses predictable `/tmp/dg_wallet_staging.$$` with `mkdir -p`, accepting a pre-existing path. Neither directory creation nor `chmod` failure is checked, and this script does not enable `set -e`. Wallet creation can therefore proceed in a location that was not securely created by this invocation. This matters particularly for the portability fallback intended for systems without `mktemp`.

**Impact:** Credential-bearing wallet staging can occur in an unsafe pre-existing location, exposing the operation to local interference or symlink attacks.

**Fix:** Use atomic, exclusive directory creation with unique candidates and retries. Reject existing paths and symlinks; abort on permission or ownership failures. Review the similar fallback in `fsfo/observer.sh` as part of the same change. If sharing `create_temp_dir`, first resolve finding 7.

**Acceptance test:** Simulate missing `mktemp`, pre-existing directories/symlinks, and permission failures. No `mkstore` invocation may occur unless a private directory was successfully established. Also cover an installed but failing `mktemp`.

### 5. High — Migration verification queries a nonexistent Oracle 19c column

**Evidence:** Source inspection and the Oracle 19c view definition.

**Location:** [migrate_noncdb_to_pdb/05_verify_pdb_dataguard.sh:169](../migrate_noncdb_to_pdb/05_verify_pdb_dataguard.sh#L169).

The script selects `APPLIED_SCN` from `V$ARCHIVE_DEST_STATUS`. That view has `APPLIED_THREAD#` and `APPLIED_SEQ#`, but no `APPLIED_SCN`. The error is converted into an empty result, retried for two minutes, and ultimately fails verification even when replication is healthy. See the [Oracle 19c view definition](https://docs.oracle.com/en/database/oracle/oracle-database/19/refrn/V-ARCHIVE_DEST_STATUS.html).

**Impact:** Healthy migrations cannot complete this verification successfully, and the downstream decommission gate remains closed.

**Fix:** Implement a documented applied-redo boundary check that proves the standby applied the smoke-test transaction. Preserve thread/incarnation correctness; do not replace it with an unrelated primary SCN or weaken the verification gate.

**Acceptance test:** On Oracle 19c, a caught-up standby passes; stopped or lagging apply fails. SQL errors must be reported directly rather than disguised as replication lag. Include a schema-validity check for the actual query.

### 6. High — Selecting “no FRA” does not clear the primary's inherited FRA configuration

**Evidence:** Source inspection and documented RMAN SPFILE inheritance; the resulting startup failure still needs an integration reproduction.

**Location:** [standby/05_clone_standby.sh:664](../standby/05_clone_standby.sh#L664).

In traditional mode, `USE_FRA_FOR_STANDBY=NO` produces no FRA overrides. However, `DUPLICATE ... SPFILE` copies the source SPFILE. A primary's `DB_RECOVERY_FILE_DEST` can therefore remain configured on the standby despite the selected option, potentially referring to an unavailable primary-only directory. See the [RMAN DUPLICATE reference](https://docs.oracle.com/en/database/oracle/oracle-database/19/rcmrf/DUPLICATE.html).

**Impact:** The effective standby configuration can contradict the selected storage configuration and can fail during auxiliary restart if the inherited destination is unusable.

**Fix:** Explicitly reset inherited FRA settings when disabled, using supported RMAN/Oracle syntax, and verify the effective auxiliary configuration.

**Acceptance test:** Duplicate a primary with FRA enabled into a standby configured without FRA, with the primary FRA path absent. Verify successful startup and the resulting parameter values.

### 7. Medium — Temporary-directory fallback collides within one script invocation

**Evidence:** Reproduced by forcing `mktemp` to fail; the first allocation succeeded and the second failed.

**Locations:** [common/dg_functions.sh:503](../common/dg_functions.sh#L503), [nested allocation:1642](../common/dg_functions.sh#L1642), [primary caller:169](../primary/04_prepare_primary_dg.sh#L169).

The fallback always chooses `dg_tmp_$$`. Bash retains the same `$$` in command substitutions, so two overlapping allocations collide. Primary preparation allocates a temporary directory and then calls `add_sid_to_listener`, which allocates another. With `mktemp` unavailable or failing, the second allocation fails and static listener insertion is skipped.

**Impact:** The portability fallback can leave required static listener registration incomplete and cause later clone or role-transition operations to fail.

**Fix:** Generate distinct candidates for every allocation while retaining exclusive creation and ownership checks.

**Acceptance test:** Force the fallback, allocate two simultaneously live directories, and exercise listener insertion into an existing multiline `SID_LIST`. Verify unique paths and cleanup.

### 8. Medium — The main observer controller cannot restart when the original primary is unavailable

**Evidence:** Source inspection.

**Locations:** [fsfo/observer.sh:782](../fsfo/observer.sh#L782), [observer launch:827](../fsfo/observer.sh#L827).

Both the FSFO preflight query and observer launch hard-code `PRIMARY_TNS_ALIAS`. After a successful failover, restarting this observer fails if the original primary is down, even when the new primary is reachable through the standby alias.

**Impact:** Observer recovery depends on the availability of the original primary during the very failure scenario it needs to tolerate.

**Fix:** Select a reachable broker member and consistently use that connection for preflight and launch. Bound connection attempts and review the corresponding stop path.

**Acceptance test:** Make the original primary unreachable, promote the standby, and verify that the observer starts and registers successfully.

### 9. Medium — Handoff readiness can pass with broken service-management objects

**Evidence:** Source inspection of the SQL predicates and readiness condition.

**Location:** [dg_handoff.sh:586](../dg_handoff.sh#L586).

The package query accepts either a valid specification or a valid body. A valid specification with an invalid body therefore qualifies. Trigger checks count `ENABLED` entries without checking compilation validity, and aggregate across owners. These conditions can produce `ROLE_TRIGGER_READY=YES` despite unusable service-management code.

**Impact:** The handoff report can claim application-service readiness when the objects needed to manage those services cannot execute correctly.

**Fix:** Require a valid specification and body, plus both required triggers enabled and valid, under the same intended owner. Do not infer runtime service behavior solely from object existence.

**Acceptance test:** Reject an invalid package body, enabled-but-invalid trigger, missing trigger, and objects split across owners. Accept a complete valid installation.

### 10. Medium — Rerunning migration step 04 destroys state needed by step 05

**Evidence:** Source inspection.

**Locations:** [migrate_noncdb_to_pdb/04_plug_into_cdb.sh:55](../migrate_noncdb_to_pdb/04_plug_into_cdb.sh#L55), [step 05 prerequisite:41](../migrate_noncdb_to_pdb/05_verify_pdb_dataguard.sh#L41).

The script clears `plug_done` and related state before checking whether the PDB already exists. After a successful migration, accidentally rerunning step 04 clears those flags and exits, advising the operator to run step 05. Step 05 then refuses because `plug_done` is missing.

**Impact:** A refused rerun damages the workflow's successful state and prevents the documented recovery path.

**Fix:** Perform refusal checks before invalidating successful state. Only clear it when a new, permitted attempt is actually beginning.

**Acceptance test:** Complete step 04, rerun it, and verify that the refusal preserves state and step 05 remains usable. Do not require manual state edits or PDB recreation.

### 11. Medium — Migration password fallback does not disable SQL*Plus substitution

**Evidence:** Source inspection and SQL*Plus substitution behavior; not exercised against live SQL*Plus in this review.

**Location:** [migrate_noncdb_to_pdb/_lib.sh:445](../migrate_noncdb_to_pdb/_lib.sh#L445).

The password-bearing `CONNECT` command executes without `SET DEFINE OFF`. A password containing `&` can trigger SQL*Plus substitution and consume subsequent input instead of authenticating with the literal password. Error handling is also installed after `CONNECT`. See [SQL*Plus substitution settings](https://docs.oracle.com/en/database/oracle/oracle-database/19/sqpug/SET-system-variable-summary.html).

**Impact:** Otherwise valid credentials can fail in the migration's password fallback, and login failure handling is less reliable than the wallet path.

**Fix:** Disable substitution and establish error handling before connecting. Make login failures terminate predictably without exposing the password.

**Acceptance test:** Verify literal handling of passwords containing `&`, and bounded nonzero failure for invalid credentials.

### 12. Medium — Status collection's timeout does not cover database discovery

**Evidence:** Source inspection; the discovery queries precede the collection watchdog.

**Locations:** [dg_status.sh:347](../dg_status.sh#L347), [synchronous discovery calls:418](../dg_status.sh#L418).

When several standby instances exist, SID selection runs remote SQL*Plus queries synchronously before the collection watchdog starts. A hung query can block indefinitely despite `DG_REMOTE_TIMEOUT`. SSH keepalives do not bound a remote command while the SSH connection remains healthy.

**Impact:** An operational status command can hang during an incident despite its configured timeout.

**Fix:** Apply bounded execution to discovery as well as collection, including cleanup of child processes.

**Acceptance test:** Mock a working SSH connection whose discovery query never completes; the tool must terminate within its documented bound and clean up its children.

### 13. Medium — Failed wallet authentication still produces successful completion

**Evidence:** Source inspection.

**Locations:** [fsfo/observer.sh:650](../fsfo/observer.sh#L650), [common/setup_dg_wallet.sh:621](../common/setup_dg_wallet.sh#L621).

Both implementations warn when authentication fails and continue to successful completion. The observer setup explicitly prints `SUCCESS`. Operators or automation can therefore accept an unusable replacement wallet as correctly configured.

**Impact:** A failed credential update can be mistaken for a completed setup and leave downstream operations or the observer unable to connect.

**Fix:** Validate the required aliases and identities, return nonzero on failure, and preserve a recoverable previous wallet when replacement validation fails.

**Acceptance test:** Wrong credentials on either required database must prevent success. Include Oracle-tool failures that return exit status zero but print an error.

### 14. Medium — SRL size validation rounds down and can certify undersized logs

**Evidence:** Reproduced using the extracted `emit_side` function.

**Locations:** [dg_check_srl.sh:268](../dg_check_srl.sh#L268), [SRL size conversion:314](../dg_check_srl.sh#L314).

Both online and standby redo sizes are truncated to integer MiB before comparison. With 100.5 MiB online logs and 100 MiB standby logs, the checker returned `OK` and exit zero. Generated corrective DDL also uses the truncated size.

Reproduction input to `emit_side`, with `SRL_PATH_OVERRIDE` empty:

```bash
emit_side DB PRIMARY 100.5 '1:3:4:100' 10 /redo NO 0 0
```

The observed result was `OK`, reporting the requirement as 100 MB.

**Impact:** Undersized standby redo logs can be certified as adequate, and the suggested repair can reproduce the same sizing error.

**Fix:** Compare exact byte counts. When emitting whole-MiB DDL, round the required size upward.

**Acceptance test:** The fractional-size case above must fail validation, and suggested replacement logs must be at least as large as the online logs.

## Remaining release gates

### OMF control-file placement

The [OMF duplicate branch](../standby/05_clone_standby.sh#L648) leaves inherited `CONTROL_FILES` unresolved. The earlier review also records this as open. This is a source-supported risk requiring integration validation, not a live failure reproduced in this review.

Run a duplicate with primary-only control-file paths and verify the actual standby locations. Ensure the implementation either supplies valid mapped control-file paths or establishes the intended OMF behavior using supported Oracle syntax. See [Oracle's advanced duplication guidance](https://docs.oracle.com/en/database/oracle/oracle-database/19/bradv/rman-duplicating-databases-advanced.html).

### Test-runtime compatibility

[test_counter_increment.sh:98](../tests/test_counter_increment.sh#L98) uses `mapfile`, unavailable in Bash 3.2. Its arithmetic assertions also assume different `set -e` behavior. In this review, the suite failed those assertions, and its file sweep misleadingly reported no violations after `mapfile` failed.

Declare the supported Bash version and make the suite validate that version reliably. A failed scan must not print a passing result. Rerun process-cleanup assertions in an environment where process inspection is available, and run alternative-awk coverage on the intended platform.

### Actual AIX 7.2 lifecycle validation

The passing portability scan does not exercise AIX utilities, process handling, Oracle binaries, startup integration, or filesystem behavior. Before sign-off, exercise clone, broker configuration, switchover, failover, observer crash/reboot recovery, and wallet authentication on the intended AIX/Oracle patch levels.

Include missing/failing `mktemp`, the installed Bash version, native `awk`/`sed`/`ps`, and the generated AIX startup/watchdog commands. The NFS setup scripts are explicitly Linux-only, so AIX NFS provisioning remains a manual prerequisite.

These integration tests are future work. They can change database roles, processes, credentials, and files, and must be run only in an appropriately authorized test environment.
