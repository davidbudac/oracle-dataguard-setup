# Implementation review: production readiness and IBM AIX 7.2

Date: 2026-10-01

Reviewed commit: `9e2c82ac058a004de2ad93f7438fbcda9e3195d3`

Scope: implementation correctness, logical errors, operational failure handling, and AIX 7.2 compatibility. Architecture redesign was outside scope.

## Verdict

**The reviewed implementation is not ready for production sign-off.** This review identifies 14 actionable issues, including unsafe check-mode behavior, observer recovery failures, and a migration verification query that cannot work on Oracle 19c.

This is a follow-up to [the earlier review](REVIEW_2026-10-01.md). It describes the implementation at the commit above, after the earlier fixes. It does not claim those fixes were never made. No implementation files were changed during this review; this document records findings for a subsequent agent to fix.

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
