# Data Guard Setup Script Review Findings

Date: 2026-08-11

Scope: Shell and SQL orchestration scripts in this repository

Review type: Read-only static review plus non-live syntax and test execution

## Executive summary

The review found one critical destructive-cleanup risk, eleven high-priority correctness or safety issues, and four medium-priority portability, validation, and operational-reporting issues.

The most urgent items are:

1. E2E cleanup can delete the whole Oracle wallet directory.
2. The destructive E2E database name is not validated.
3. FASTSYNC is described as providing an unconditional zero-data-loss guarantee.
4. FSFO SQL and broker failures can be hidden by successful-looking output.
5. Migration verification can pass without confirming the standby.

## Findings

### DG-001 — E2E cleanup deletes the entire Oracle wallet directory

**Severity:** Critical

**Evidence**

- `tests/e2e/drop_test_db.sh:269-270`
- `tests/e2e/run_e2e_test.sh:508-509`
- `tests/e2e/run_e2e_test_cdb.sh:454-455`

The cleanup paths execute the equivalent of:

```sh
rm -rf "${ORACLE_HOME}/network/admin/wallet"
```

**Impact**

On a shared test host, this can remove credentials belonging to other databases or applications. If the directory is also used as a TDE keystore, the impact can extend beyond test connectivity and may make encrypted data unavailable.

**Recommended improvement**

- Give each E2E run a dedicated wallet directory.
- Track the exact files or aliases created by the run.
- Remove only those run-owned artifacts during cleanup.
- Before deletion, resolve and validate the target and reject shared/default wallet paths.
- Add a regression test proving cleanup cannot target `${ORACLE_HOME}/network/admin/wallet` itself.

### DG-002 — Destructive E2E database names are not validated

**Severity:** High

**Evidence**

- `tests/e2e/drop_test_db.sh:41`
- `tests/e2e/drop_test_db.sh:58-72`
- `tests/e2e/drop_test_db.sh:93-102`
- `tests/e2e/drop_test_db.sh:141-169`
- `tests/e2e/drop_test_db.sh:248-267`

The `--name` value is checked for presence but is subsequently interpolated into remote shell commands and destructive filesystem paths without a strict allowlist.

**Impact**

A value containing `/`, `..`, quotes, whitespace, or shell metacharacters could escape the intended database directory or alter a remote command. The `--force` option removes the final interactive safeguard.

**Recommended improvement**

- Restrict the value to the project's accepted Oracle identifier format.
- Keep shell arguments out of remotely constructed command strings where possible.
- Canonicalize every deletion path and confirm it remains below an explicitly approved test root.
- Refuse empty, root-like, default, or production-looking identifiers.
- Add negative tests for path traversal and shell metacharacters.

### DG-003 — FASTSYNC is described as an unconditional zero-data-loss mode

**Severity:** High

**Evidence**

- `primary/13_set_max_availability.sh:18`
- `primary/13_set_max_availability.sh:330-332`
- `dg_handoff.sh:556-559`
- `primary/10_generate_handoff_report.sh:468-471`

The handoff output groups `MAXAVAILABILITY|SYNC` and `MAXAVAILABILITY|FASTSYNC` together and states that failover loses no committed transactions. However, FASTSYNC uses `SYNC NOAFFIRM`: the primary waits for receipt in standby memory, not durable standby disk.

Oracle documents the potential exposure in the special case where the primary and standby fail in close succession: [Oracle Data Guard protection modes](https://docs.oracle.com/en/database/oracle/oracle-database/21/sbydb/oracle-data-guard-protection-modes.html).

**Impact**

Operators and business owners may rely on a stronger recovery-point guarantee than the configured transport mode actually provides.

**Recommended improvement**

- Report `SYNC AFFIRM` and `SYNC NOAFFIRM` separately.
- Describe FASTSYNC as reducing latency while accepting a narrow multiple-failure data-loss exposure.
- Derive the handoff wording from the actual protection mode and transport attributes instead of a combined case branch.

### DG-004 — FSFO observer-user SQL failures can be reported as success

**Severity:** High

**Evidence**

- `primary/09_configure_fsfo.sh:283-318`
- `primary/09_configure_fsfo.sh:339-354`
- `primary/09_configure_fsfo.sh:381-398`

Several direct SQL*Plus blocks omit `WHENEVER SQLERROR EXIT` and `WHENEVER OSERROR EXIT`. Some branches run a trailing `SELECT 'SUCCESS'`, so the expected success marker can appear after a failed `CREATE USER`, `ALTER USER`, or `GRANT`. Another grant branch does not inspect SQL output before logging success.

**Impact**

The script can claim that observer credentials and privileges are ready while the user is missing, locked, has the wrong password, or lacks required grants.

**Recommended improvement**

- Use the repository's checked SQL execution pattern consistently.
- Exit SQL*Plus on SQL and operating-system errors.
- Validate the target user state and required grants with independent queries.
- Add stubbed failure-path tests for every create, alter, and grant branch.

### DG-005 — FSFO enablement swallows broker failure and rejected approval

**Severity:** High

**Evidence**

- `primary/09_configure_fsfo.sh:507-516`

The `ENABLE FAST_START FAILOVER` call is followed by `|| true`. This suppresses both DGMGRL failures and a rejected confirmation from the shared execution wrapper. The subsequent output matching is incomplete, and the script logs success without querying the resulting FSFO state.

**Impact**

The run can finish with a success message even though FSFO remains disabled.

**Recommended improvement**

- Use checked DGMGRL execution without unconditional error suppression.
- Treat rejected approval as a deliberate non-success outcome.
- Query `SHOW FAST_START FAILOVER` afterward and require an enabled state.
- Recognize bare `ORA-`, `DGM-`, and broker error status output.

### DG-006 — Password-file staging can falsely finish successfully

**Severity:** High

**Evidence**

- `primary/08_security_hardening.sh:143-160`
- `primary/08_security_hardening.sh:313-348`
- `primary/08_security_hardening.sh:401-424`
- `primary/08_security_hardening.sh:447-452`

If the local `orapw${ORACLE_SID}` file is absent, the script logs errors but does not set a fatal failure state. Its final summary can still claim the password file was staged successfully.

**Impact**

SYS can be rotated or locked without a valid password file ready for the standby, potentially breaking redo transport or later administrative connections.

**Recommended improvement**

- Require the source password file before making any account changes.
- Stage and validate the replacement first.
- Make absence, copy failure, permission failure, or checksum mismatch fatal.
- Build the final summary from verified state rather than intended actions.

### DG-007 — The advertised `--check` safety contract is not consistently enforced

**Severity:** High

**Evidence**

- `common/dg_functions.sh:56-92`
- `README.md:98`
- `trigger/create_cdb_service.sh:84`
- `trigger/create_cdb_service.sh:279`
- `primary/02_generate_standby_config.sh:22`
- `primary/02_generate_standby_config.sh:975`

The shared argument parser advertises that `--check` stops before changes. Several scripts accept the flag but do not gate their mutating operations; examples include database DDL and generated-file replacement.

**Impact**

An operator can reasonably believe a command is read-only while it changes database or filesystem state.

**Recommended improvement**

- Enforce check-only behavior in one shared execution boundary.
- For scripts that cannot support it, reject `--check` explicitly.
- Test each mutating wrapper and at least one complete script path with check-only enabled.

### DG-008 — Migration verification can pass without connecting to the standby

**Severity:** High

**Evidence**

- `migrate_noncdb_to_pdb/05_verify_pdb_dataguard.sh:89-120`
- `migrate_noncdb_to_pdb/05_verify_pdb_dataguard.sh:168-175`

Failure to connect directly to the standby is treated as a warning. The script falls back to a primary-side query and can still record `verify_done=true` and print that verification passed.

**Impact**

The destructive decommission stage can be unlocked without confirming that the PDB and its datafiles are usable on the standby.

**Recommended improvement**

- Make direct standby verification mandatory for a passing result.
- Verify PDB presence, open state where appropriate, datafile visibility, and recovery/apply state on the standby.
- Store separate states for `verified`, `inconclusive`, and `failed`.
- Allow decommissioning only from a fully verified state.

### DG-009 — Existing wallet credentials are updated in place and non-atomically

**Severity:** High

**Evidence**

- `common/setup_dg_wallet.sh:393-440`
- `fsfo/observer.sh:335-367`

For an existing wallet, the scripts delete the live credential alias before creating its replacement. New wallets use staging, but existing-wallet updates mutate the live wallet directly.

**Impact**

If credential creation or validation fails after deletion, the previously working alias is lost and the wallet is left partially updated.

**Recommended improvement**

- Copy the live wallet to a private staging directory.
- Apply the update and test the staged wallet.
- Preserve a recoverable backup.
- Atomically swap the validated wallet into place.

### DG-010 — The AIX temporary-directory fallback is predictable

**Severity:** High

**Evidence**

- `common/dg_functions.sh:387-405`
- `standby/05_clone_standby.sh:319-328`
- `standby/05_clone_standby.sh:425-432`

When `mktemp` is unavailable, the helper uses a predictable `/tmp/dg_tmp_$$` path with `mkdir -p`. A pre-existing directory is accepted, and `mkdir -m` does not repair the permissions or ownership of an existing object. The standby clone stores a command file containing SYS credentials in this directory.

**Impact**

Another local user could pre-create the directory, observe sensitive contents, redirect writes, or interfere with cleanup.

**Recommended improvement**

- Set `umask 077` before creation.
- Generate randomized candidate names and use atomic non-`-p` creation.
- Reject any pre-existing candidate.
- Verify owner, type, and permissions before use.

### DG-011 — Oracle versions are compared lexicographically

**Severity:** High

**Evidence**

- `migrate_noncdb_to_pdb/01_preflight.sh:123-137`

The preflight assumes version fields are zero-padded and uses shell string ordering. Oracle versions such as `19.10` and `19.9` are not ordered correctly as strings.

**Impact**

A supported upgrade can be rejected, while an invalid source/target ordering can be accepted.

**Recommended improvement**

- Parse numeric version components.
- Compare each component as an integer.
- Add tests covering `19.3`, `19.9`, `19.10`, and differing major versions.

### DG-012 — `run_minimal.sh` bypasses the maintained migration safeguards

**Severity:** High

**Evidence**

- `migrate_noncdb_to_pdb/run_minimal.sh:14-33`
- `migrate_noncdb_to_pdb/_lib.sh:168`

The shortcut script hard-codes an environment, takes the source offline, and disables apply without the normal preflight, confirmation, persisted state, or checked DGMGRL output handling.

**Impact**

It provides a second implementation of a destructive migration with fewer safeguards and can drift independently from the maintained staged workflow.

**Recommended improvement**

- Remove the shortcut, or make it a thin orchestrator over the maintained `01` through `05` scripts.
- Do not duplicate destructive SQL or DGMGRL commands.
- Require the same confirmation and state gates as the primary workflow.

### DG-013 — Plug compatibility errors do not stop migration

**Severity:** Medium

**Evidence**

- `migrate_noncdb_to_pdb/04_plug_into_cdb.sh:62-96`

The compatibility check treats `COMPATIBLE = NO` as a warning and continues toward PDB creation, including cases where unresolved violations are classified as errors.

**Impact**

The migration can proceed with a PDB that cannot be plugged in cleanly or that requires unsupported corrective action.

**Recommended improvement**

- Fail closed on `COMPATIBLE = NO` or unresolved `ERROR` violations.
- If exceptions are required, classify narrowly and require an explicit override naming the accepted violation.
- Persist the accepted exception in migration state and the handoff report.

### DG-014 — Standby clone reports success when managed recovery is absent

**Severity:** Medium

**Evidence**

- `standby/05_clone_standby.sh:584-597`
- `standby/05_clone_standby.sh:642-654`

After attempting to start managed recovery, the script only warns if MRP is missing and then prints a successful completion summary stating that recovery was started.

**Impact**

The standby can be handed over while redo is not being applied.

**Recommended improvement**

- Poll for MRP with a bounded timeout.
- Make persistent absence fatal.
- Include the observed process and apply state in the final summary.

### DG-015 — AIX-targeted migration scripts use GNU-only `du -sb`

**Severity:** Medium

**Evidence**

- `migrate_noncdb_to_pdb/03_describe_and_stage.sh:150-151`
- `migrate_noncdb_to_pdb/06_decommission_noncdb.sh:95`

The scripts run `du -sb` under `set -e` and `pipefail`. On AIX, unsupported `-b` can terminate the script before the apparent fallback executes.

**Impact**

Migration staging or decommissioning can fail on one of the repository's stated target platforms.

**Recommended improvement**

- Detect supported `du` syntax before use.
- Put platform-specific commands inside a guarded conditional.
- Prefer a portable helper shared by both scripts.
- Include AIX-compatible command stubs in the test suite.

### DG-016 — NFS server setup can print success after required failures

**Severity:** Medium

**Evidence**

- `nfs/01_setup_nfs_server.sh:134-145`
- `nfs/01_setup_nfs_server.sh:162-174`
- `nfs/01_setup_nfs_server.sh:184-192`
- `nfs/01_setup_nfs_server.sh:252`

Ownership and service start failures are reduced to warnings, followed by unconditional statements that permissions are correct and setup completed. The export-existence check is also substring-based and can mistake an unrelated or stale entry for the desired configuration.

**Impact**

The script can report a usable NFS server when the export has the wrong ownership, the service is inactive, or the allowed-client configuration is stale.

**Recommended improvement**

- Treat required ownership and service activation failures as fatal.
- Parse exports structurally rather than with substring matching.
- Verify the effective export and active service state before reporting success.
- Make the final summary reflect verified facts only.

## Suggested remediation order

1. DG-001 and DG-002: constrain destructive E2E cleanup.
2. DG-003 through DG-006: correct protection claims and fail closed in FSFO/security setup.
3. DG-008, DG-011, DG-012, and DG-013: strengthen migration gates before any production use.
4. DG-007, DG-009, and DG-010: repair shared safety and credential-handling primitives.
5. DG-014 through DG-016: improve operational verification and platform portability.

## Validation performed during review

- No Oracle database, listener, broker, NFS, migration, or E2E lifecycle operation was run.
- All shell scripts passed `bash -n` syntax validation.
- Nine non-live `tests/test_*.sh` scripts passed, totalling 230 assertions.
- ShellCheck findings were inspected, but the repository was not claimed to be ShellCheck-clean.
- The worktree was clean before this report branch was created.

## Recommended test additions

- E2E cleanup target allowlist and path-containment tests.
- Missing-argument and hostile-identifier parser tests.
- SQL*Plus failure injection for FSFO user creation and security hardening.
- DGMGRL failure, rejected-confirmation, and postcondition tests.
- `--check` contract tests covering every mutating wrapper.
- Wallet update rollback and atomic replacement tests.
- Standby-unreachable migration verification tests.
- Numeric Oracle version comparison tests.
- AIX command-compatibility stubs.
- Final-summary tests that compare claimed actions with observed state.
