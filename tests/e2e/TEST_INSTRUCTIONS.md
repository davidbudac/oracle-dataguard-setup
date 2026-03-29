# E2E Test Instructions for Claude

## What the user wants

The user wants Claude to **directly execute** the E2E test suite against real Oracle 19c servers.
This is not a "design tests and hand off" task - Claude must SSH to the hosts and run the tests,
diagnose failures, fix scripts, push fixes, and re-run in a loop until all steps pass.

## How to run

### 1. Check config.env is filled in

Read `tests/e2e/config.env`. If `PRIMARY_HOST`, `STANDBY_HOST`, `ORACLE_HOME`, `ORACLE_BASE`,
or `REPO_URL` are empty, ask the user to fill them in first.

### 2. Verify SSH connectivity

```bash
ssh -p <port> -o StrictHostKeyChecking=no oracle@<PRIMARY_HOST> "echo ok"
ssh -p <port> -o StrictHostKeyChecking=no oracle@<STANDBY_HOST> "echo ok"
```

If SSH fails, tell the user and stop. Don't guess at credentials.

### 3. Run the test

```bash
cd /Users/davidbudac/claude_projects/dataguard_setup
./tests/e2e/run_e2e_test.sh 2>&1 | tee /tmp/claude/e2e_run_$(date +%s).log
```

Or run individual phases:
```bash
./tests/e2e/run_e2e_test.sh --only preflight
./tests/e2e/run_e2e_test.sh --only create_db
./tests/e2e/run_e2e_test.sh --from step1
```

### 4. Handle failures - THE LOOP

When a phase fails:

1. **Read the output** - understand exactly what failed and why
2. **Document the issue** - note what went wrong in the test log
3. **Diagnose** - SSH to the failing host if needed, check Oracle logs:
   - Alert log: `$ORACLE_BASE/diag/rdbms/<db>/<sid>/trace/alert_<sid>.log`
   - Listener log: `$ORACLE_BASE/diag/tnslsnr/<host>/listener/trace/listener.log`
   - Script logs: `$NFS_SHARE/logs/`
4. **Fix the script** - edit the failing script in the local repo
5. **Push the fix** - `git add`, `git commit`, `git push`
6. **Redeploy** - `./run_e2e_test.sh --only deploy`
7. **Re-run from the failing phase** - `./run_e2e_test.sh --from <phase>`
   - If the fix requires a clean state, run cleanup first: `--only cleanup`

Repeat until all phases pass.

### 5. Cleanup

After all tests pass (or if you need to start fresh):
```bash
./tests/e2e/run_e2e_test.sh --only cleanup
```

## What the test does (phase by phase)

| Phase | Host | What it does |
|-------|------|-------------|
| preflight | both | Validates SSH, Oracle Home, expect, NFS write access |
| deploy | both | git clone/pull the repo to REPO_DIR on each host |
| cleanup_previous | both | Drops any existing test DB, removes files from prior run |
| create_db | primary | DBCA creates test DB, disables OMF/FRA, enables ARCHIVELOG |
| step1 | primary | Runs 01_gather_primary_info.sh, validates primary_info.env |
| step2 | primary | Runs 02_generate_standby_config.sh, validates standby_config.env |
| step3 | standby | Runs 03_setup_standby_env.sh, validates dirs/listener/tns |
| step4 | primary | Runs 04_prepare_primary_dg.sh, validates DG params/standby redo |
| step5 | standby | Runs 05_clone_standby.sh (RMAN duplicate), validates MRP |
| step6 | primary | Runs 06_configure_broker.sh, validates DGMGRL config |
| step7 | standby | Runs 07_verify_dataguard.sh, checks health report |
| step8 | primary | Runs 08_security_hardening.sh, validates SYS locked (optional) |
| step9 | primary | Runs 09_configure_fsfo.sh, validates FSFO enabled (optional) |
| step10 | standby | Runs observer.sh setup+start, validates observer running (optional) |
| step11 | primary | Runs create_role_trigger.sh, validates PL/SQL objects (optional) |
| cleanup_final | both | Drops DBs, removes all test files, restores configs |

## Common issues and fixes

- **expect not found**: Install with `yum install expect` or `apt install expect`
- **DBCA fails**: Check ORACLE_HOME/ORACLE_BASE are correct, listener is running
- **RMAN duplicate hangs**: Check TNS connectivity both ways, listener static registration
- **Broker won't enable**: Wait 30+ seconds, check DMON process, tnsping both ways
- **expect patterns don't match**: The prompt text in scripts may differ from what the
  test expects. SSH to the host, run the script manually to see actual prompts, then
  update the expect patterns in run_e2e_test.sh

## Key files

- `tests/e2e/config.env` - User's environment config (DO NOT commit secrets)
- `tests/e2e/config.env.template` - Template (committed to repo)
- `tests/e2e/run_e2e_test.sh` - Main test orchestrator
- `tests/e2e/logs/` - Test run logs (gitignored)
- `docs/DATA_GUARD_WALKTHROUGH.md` - Reference for what each step should do
