# E2E Test Instructions for Claude

## What the user wants

The user wants Claude to **directly execute** the E2E test suite against real Oracle 19c servers.
This is not a "design tests and hand off" task - Claude must SSH to the hosts and run the tests,
diagnose failures, fix scripts, push fixes, and re-run in a loop until all steps pass.

## Architecture

```
Local machine (macOS)
  └─ SSH ─→ Jump host (dbmint, user: db)
               ├─ SSH -p 2201 ─→ Primary DB host (oracle@localhost:2201)
               └─ SSH -p 2202 ─→ Standby DB host (oracle@localhost:2202)
```

- Both DB hosts are reachable from the jump host as `oracle@localhost` on different ports
- SSH uses ProxyJump (-J) for clean double-hop from local machine
- NFS share at `/OINSTALL/_dataguard_setup` is mounted on both DB hosts
- No `sudo` available on DB hosts; no `expect` installed

## How to run

### 1. Check config.env is filled in

Read `tests/e2e/config.env`. Required fields:
- `JUMP_HOST`, `JUMP_USER` - jump/bastion server
- `PRIMARY_HOST`, `PRIMARY_SSH_PORT` - primary DB host (from jump)
- `STANDBY_HOST`, `STANDBY_SSH_PORT` - standby DB host (from jump)
- `ORACLE_HOME`, `ORACLE_BASE` - Oracle paths on both DB hosts
- `REPO_URL` - GitHub repo URL for git clone on DB hosts

### 2. Verify SSH connectivity

```bash
# Jump host
ssh -o StrictHostKeyChecking=no db@dbmint "echo ok"

# Primary (via jump)
ssh -o StrictHostKeyChecking=no -J db@dbmint:22 -p 2201 oracle@localhost "echo ok"

# Standby (via jump)
ssh -o StrictHostKeyChecking=no -J db@dbmint:22 -p 2202 oracle@localhost "echo ok"
```

### 3. Run the test

Always use `bash` explicitly (zsh has different word-splitting for SSH_OPTS):

```bash
cd /Users/davidbudac/claude_projects/dataguard_setup

# Full run
bash ./tests/e2e/run_e2e_test.sh 2>&1

# Individual phases
bash ./tests/e2e/run_e2e_test.sh --only preflight
bash ./tests/e2e/run_e2e_test.sh --only deploy
bash ./tests/e2e/run_e2e_test.sh --only cleanup
bash ./tests/e2e/run_e2e_test.sh --only create_db
bash ./tests/e2e/run_e2e_test.sh --from step1
bash ./tests/e2e/run_e2e_test.sh --from step5
```

**Important:** `create_db` (DBCA) takes 3-8 minutes. Run with a long timeout or in background.

### 4. Handle failures - THE LOOP

When a phase fails:

1. **Read the output** - understand exactly what failed and why
2. **Document the issue** - add to the issues log and this file
3. **Diagnose** - SSH to the failing host:
   ```bash
   # Quick SSH to primary
   ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -J db@dbmint:22 -p 2201 oracle@localhost

   # Check Oracle alert log
   cat $ORACLE_BASE/diag/rdbms/dgtest/dgtest/trace/alert_dgtest.log | tail -50

   # Check script logs on NFS
   ls -lt /OINSTALL/_dataguard_setup/logs/ | head
   ```
4. **Fix the script** - edit the failing script in the local repo
5. **Push the fix** - `git add`, `git commit`, `git push`
6. **Redeploy** - `bash ./run_e2e_test.sh --only deploy`
7. **Re-run from the failing phase** - `bash ./run_e2e_test.sh --from <phase>`
   - If the fix requires a clean state, run cleanup first: `--only cleanup`

Repeat until all phases pass.

### 5. After all tests pass

```bash
bash ./tests/e2e/run_e2e_test.sh --only cleanup
```

## What the test does (phase by phase)

| Phase | Host | What it does |
|-------|------|-------------|
| preflight | both | Validates SSH (via jump), Oracle Home, git, NFS write access |
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

## Interactive input handling

Scripts are interactive (they prompt for config selection, passwords, confirmations).
The test uses `ssh_piped()` which feeds responses via stdin pipe. Each `\n` in the
input string feeds one `read` call in the script. Order matters - responses must
match the exact sequence of prompts.

If a script's prompts change, the piped input sequence in `run_e2e_test.sh` must be
updated. To debug: SSH to the host and run the script manually to see actual prompts.

## Known issues and fixes discovered during testing

### Issue: zsh vs bash word splitting
- `SSH_OPTS` variable is a space-separated string of `-o` flags
- zsh doesn't word-split unquoted variables the same way bash does
- **Fix:** Always run the test script with `bash` explicitly
- The shebang `#!/usr/bin/env bash` handles this when run as `./run_e2e_test.sh`

### Issue: Both DB hosts are localhost (different ports)
- When PRIMARY_HOST == STANDBY_HOST (both "localhost"), port lookup by hostname fails
- **Fix:** All SSH functions use "PRIMARY"/"STANDBY" target tokens, resolved to
  actual host+port only inside the SSH functions. Never compare hostnames.

### Issue: Cleanup failures abort the script
- `set -euo pipefail` causes cleanup to abort if any cleanup command fails
- Cleanup commands WILL fail when there's nothing to clean (expected)
- **Fix:** Cleanup functions use `set +e` in remote commands, `|| true` on calls

### Issue: SSH host key warnings with ProxyJump
- ProxyJump connects from local machine directly to DB host
- Known_hosts entries conflict when multiple containers share localhost
- **Fix:** SSH_OPTS includes `-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR`

### Issue: No expect on DB hosts, no sudo to install it
- Original test design used `expect` for interactive prompt automation
- **Fix:** Replaced with `ssh_piped()` using stdin pipe. Works because scripts'
  `prompt_password()` falls back to reading stdin when no tty is present.

## Key files

- `tests/e2e/config.env` - User's environment config (DO NOT commit - gitignored)
- `tests/e2e/config.env.template` - Template (committed to repo)
- `tests/e2e/run_e2e_test.sh` - Main test orchestrator
- `tests/e2e/TEST_INSTRUCTIONS.md` - This file (update as issues are found)
- `tests/e2e/logs/` - Test run logs (gitignored)
- `docs/DATA_GUARD_WALKTHROUGH.md` - Reference for what each step should do
