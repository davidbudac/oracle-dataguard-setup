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

### Issue: SSH target differs from Oracle network hostname
- SSH access uses `localhost` with port forwarding, but DB hosts know themselves
  as `poug-dg1` / `poug-dg2` on the 192.168.56.x network
- TNS entries must use real hostnames, not "localhost"
- **Fix:** Added `PRIMARY_ORACLE_HOSTNAME` and `STANDBY_ORACLE_HOSTNAME` in config.env
  Step 2 uses these for the standby hostname prompt instead of SSH target hostname

### Issue: Config auto-selection skips menu prompt
- When exactly one config file exists, `select_config_file()` auto-selects
  without reading stdin. Piped "1" selection was consumed by the next prompt.
- **Fix:** Removed "1" from all piped inputs. Scripts auto-select single files.

### Issue: Sessions accumulate and create unexpected menus
- `select_or_restore_config()` checks for sessions before file selection
- Sessions from prior steps show a menu that consumes piped input lines
- **Fix:** `clear_sessions` is called before every step phase in `run_phase()`

### Issue: host command fails with non-zero exit when hostname not in DNS
- `01_gather_primary_info.sh` runs `host "$PRIMARY_HOSTNAME"` which fails
  if the hostname isn't in DNS, triggering the ERR trap under `set -e`
- **Fix:** Added `|| true` to the `host` command in the FQDN lookup

### Issue: NFS has stale files from previous manual tests
- Old `.env` and `.ora` files cause wrong config selection in step 2
- **Fix:** `cleanup_nfs` now removes ALL `.env`/`.ora`/`.dgmgrl` files, not just
  those matching the test DB name

### Issue: prompt_password stty fails under piped stdin
- `common/dg_functions.sh` `prompt_password()` calls `stty -echo` / `stty echo`
- When stdin is a pipe (not a tty), `stty` exits non-zero, triggering ERR trap
- **Fix:** Added `2>/dev/null || true` to both stty calls in `prompt_password()`

### Issue: RMAN heredoc consumed piped stdin
- `standby/05_clone_standby.sh` used `<<EOF` heredoc to pass `@script_file` to RMAN
- The heredoc reads from stdin, consuming bytes meant for interactive prompts
- **Fix:** Changed to RMAN `cmdfile` parameter: `rman ... cmdfile "${RMAN_SCRIPT}"`

### Issue: NAMES.DEFAULT_DOMAIN in sqlnet.ora breaks TNS resolution
- Standby had `NAMES.DEFAULT_DOMAIN=world` in sqlnet.ora
- This causes tnsping to append `.world` to TNS aliases, breaking resolution
- **Fix:** Cleanup phase comments out `NAMES.DEFAULT_DOMAIN` in standby sqlnet.ora

### Issue: Stale tnsnames entries from previous runs
- Scripts append DG entries to tnsnames.ora; cleanup restored from stale backups
- **Fix:** Cleanup uses `sed` to remove DG-added sections instead of restoring backups

### Issue: assert_sql strips whitespace, breaking multi-word matches
- `assert_sql` uses `tr -d '[:space:]'` so "PHYSICAL STANDBY" becomes "PHYSICALSTANDBY"
- **Fix:** Match the stripped form in assertions

### Issue: Step 11 prompt count varies between first run and re-run
- First run: accept services (Enter), deploy (y) = 2 prompts
- Re-run: accept services (Enter), replace existing (y), deploy (y) = 3 prompts
- **Fix:** Provide `\ny\ny\ny` (Enter + 3 y's); extra y's are consumed by EOF

## Last successful full run

**Date:** 2026-03-29, **Duration:** ~20 minutes, **Result:** 62 PASS, 0 FAIL, 3 SKIP

Phases tested: preflight, deploy, cleanup, create_db, steps 1-7, step 11
Phases skipped: step 8 (security), step 9 (FSFO), step 10 (observer)

## Key files

- `tests/e2e/config.env` - User's environment config (DO NOT commit - gitignored)
- `tests/e2e/config.env.template` - Template (committed to repo)
- `tests/e2e/run_e2e_test.sh` - Main test orchestrator
- `tests/e2e/TEST_INSTRUCTIONS.md` - This file (update as issues are found)
- `tests/e2e/logs/` - Test run logs (gitignored)
- `docs/DATA_GUARD_WALKTHROUGH.md` - Reference for what each step should do
