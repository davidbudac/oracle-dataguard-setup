# Review plan — 2026-10-01 follow-up review

Companion to [REVIEW_2026-10-01_FOLLOWUP.md](REVIEW_2026-10-01_FOLLOWUP.md). Finding numbers
1-14 and the three "remaining release gates" refer to that document. Each row below says what
is done about the finding (fix or comment), in which batch, and where it is tested. The
real-system tests live in [TEST_PLAN_2026-10-01.md](TEST_PLAN_2026-10-01.md), Phase 12.

Status values: `PLANNED` → `FIXED` (code + DB-free test in the repo) → `LAB-VERIFIED` (the
test-plan row passed on a real system). `OPEN` means it needs a system we have not run on yet.

**State on 2026-10-03:** all 14 findings are `FIXED`, none is `LAB-VERIFIED` yet. The changes
are in the working tree on top of `0afa3ac`, not committed. One release gate is fixed, two are
open. The per-finding detail is in the review's "Fix status" section.

## Decisions taken before fixing

Checked read-only on the 19c lab (`cdb1` / `cdb1_stby`, 2026-10-03):

| Question | Result | Used by |
|---|---|---|
| Does `V$ARCHIVE_DEST_STATUS` have `APPLIED_SCN`? | No (`APPLIED_THREAD#`, `APPLIED_SEQ#` only). `V$ARCHIVE_DEST` has `APPLIED_SCN`, but it trails the standby's own `V$DATABASE.CURRENT_SCN` (20030439 vs 20030716 at the same moment) | Finding 5 |
| What does `SHOW OBSERVER` print per observer? | `Observer "<name>" - Master`, `Host Name:`, `Last Ping to Primary: N second(s) ago`, `Last Ping to Target: N second(s) ago` | Finding 3 |
| Does RMAN accept `RESET <param>` inside `DUPLICATE … SPFILE`? | Yes, `rman checksyntax` reports no syntax errors for `RESET DB_RECOVERY_FILE_DEST` / `RESET DB_RECOVERY_FILE_DEST_SIZE` between `SET` lines | Finding 6 |

Design choices:

- **Check mode (1):** `fsfo/observer.sh -n` keeps the meaning the numbered steps give it:
  discovery and read-only broker queries run, the plan is printed, nothing is written, started,
  stopped, signalled or deleted (stale-pidfile cleanup included). `status` is read-only and runs
  normally. Approval mode asks before every mutating action; a declined action does not run.
- **Identity guard (2):** one shared helper compares the connected database's `DB_UNIQUE_NAME`,
  `DATABASE_ROLE` and `DBID` with the selected `standby_config_*.env`. Steps 4 and 6 must be
  connected to the config's primary. Steps 9, 10 and 13 accept either member of the config as
  long as it currently holds the PRIMARY role (so they still work after a switchover). Step 6
  also names any broker member that is not in the selected config before it removes a
  configuration, and refuses non-interactively.
- **Observer liveness (3):** registration is no longer proof. This observer is "up" only when
  the broker lists it *and* its last ping is recent (`DG_OBS_MAX_PING_AGE`, default 60 s) *and*
  its local process is alive. A registered-but-dead observer is restarted with its existing
  `.dat` file, after deregistering the stale entry if the broker refuses the start.
- **Applied-SCN gate (5):** the gate reads the CDB standby's own `V$DATABASE.CURRENT_SCN`
  through the direct standby connection step 05 already requires. It is an SCN comparison, so
  it is independent of thread and sequence numbering. A query error is reported as a query
  error, not as lag.
- **No-FRA clone (6):** `RESET` lines are emitted only when the live primary has
  `db_recovery_file_dest` set, and the standby's effective value is read back after the
  duplicate.
- **Wallet verification (13):** a failed login test is a failed setup (exit 1, no SUCCESS
  summary). The previous wallet stays available as the timestamped backup and the restore
  command is printed.
- **Supported Bash (gate):** Bash 3.2 or later. The unit suites must pass when `bash` on the
  `PATH` is 3.2.

## Batches

No two batches touch the same file. Rules for every batch: AIX 7.2 portability (see
`tests/test_aix_portability.sh`), new prompts TTY-gated, `x=$((x+1))` not `((x++))`, DB-free
tests with stubbed Oracle binaries, both `bash` and `/bin/bash` (3.2) must pass.

| Batch | Files | Findings |
|---|---|---|
| A | `fsfo/observer.sh`, new `tests/test_fsfo_observer.sh` | 1, 8, 13 (observer), 4 (observer fallback) |
| B | `common/dg_functions.sh`, `primary/04`, `06`, `09`, `10`, `13`, `tests/test_shared_helpers.sh`, `tests/test_add_sid_to_listener.sh` | 2, 7 |
| C | `common/setup_dg_wallet.sh`, new `tests/test_setup_dg_wallet.sh`, `docs/WALLET_SETUP.md` | 4, 13 (wallet) |
| D | `add_observer/*`, `tests/test_add_observer_lib.sh` | 3 |
| E | `migrate_noncdb_to_pdb/*`, new `tests/test_migrate_lib.sh` | 5, 10, 11 |
| F | `standby/05_clone_standby.sh`, new `tests/test_step5_fra_reset.sh` | 6 |
| G | `dg_handoff.sh`, `tests/test_handoff.sh`, `dg_check_srl.sh`, `tests/test_check_srl.sh`, `tests/test_counter_increment.sh`, `tests/test_grep_portability.sh` | 9, 14, test-runtime gate |
| H | `dg_status.sh`, `tests/test_status_tools.sh`, `docs/DG_STATUS.md` | 12 |
| I (follow-up) | `primary/04_prepare_primary_dg.sh`, `sql/queries/get_standby_redo_min_size.sql`, new `tests/test_step4_srl_size.sh` | 14 (the same rounding gap in step 4's own check, found while fixing G) |

## Findings

| # | Sev | Finding | Action | Batch | Status |
|---|---|---|---|---|---|
| 1 | High | Observer check mode can stop the observer | Fix: enforce `-n` and `-a` in setup/start/stop/restart | A | FIXED |
| 2 | High | Selected config not checked against the connected database | Fix: shared identity guard in steps 4, 6, 9, 10, 13; broker-membership check before `REMOVE CONFIGURATION` | B | FIXED |
| 3 | High | Dead observer's registration blocks restart | Fix: liveness = registration + recent ping + local process; restart with the existing state file | D | FIXED |
| 4 | High | Wallet staging unsafe without `mktemp` | Fix: exclusive, verified private directory or abort; same in `fsfo/observer.sh` | C, A | FIXED |
| 5 | High | Migration step 05 queries a nonexistent column | Fix: gate on the standby's `V$DATABASE.CURRENT_SCN`; surface SQL errors | E | FIXED |
| 6 | High | "No FRA" keeps the primary's FRA parameters | Fix: `RESET` both FRA parameters in the DUPLICATE; read back afterwards | F | FIXED |
| 7 | Medium | `create_temp_dir` fallback collides within one run | Fix: unique candidate per allocation, retries | B | FIXED |
| 8 | Medium | `fsfo/observer.sh` cannot restart when the original primary is down | Fix: pick a reachable member, bounded, for preflight, launch and stop | A | FIXED |
| 9 | Medium | Handoff readiness passes with broken service-management objects | Fix: valid spec + valid body + both triggers enabled and valid, one owner | G | FIXED |
| 10 | Medium | Rerunning migration step 04 clears state step 05 needs | Fix: refusal checks before `clear_state` | E | FIXED |
| 11 | Medium | Migration password fallback lacks `SET DEFINE OFF` | Fix: `SET DEFINE OFF` and error handling before `CONNECT` | E | FIXED |
| 12 | Medium | `dg_status.sh` timeout does not cover SID discovery | Fix: discovery runs under the same watchdog | H | FIXED |
| 13 | Medium | Failed wallet authentication still ends in success | Fix: exit 1, no SUCCESS summary, restore hint | A, C | FIXED |
| 14 | Medium | SRL size check rounds down | Fix: compare bytes; round DDL sizes up | G | FIXED |

## Remaining release gates

| Gate | Action | Status |
|---|---|---|
| OMF control-file placement | Comment: not fixable responsibly without evidence. It stays the open question it was in the first review; test plan Phase 10 decides between "no fix needed" and an explicit `CONTROL_FILES` handling in step 5's OMF branch | OPEN (needs lab run) |
| Test-runtime compatibility | Fix: `tests/test_counter_increment.sh` and `tests/test_grep_portability.sh` run on Bash 3.2 (no `mapfile`, version-aware `set -e` assertions, a failed scan fails the suite); supported Bash version declared; 25/25 suites pass with Bash 3.2 as driver and inner shell | FIXED |
| AIX 7.2 lifecycle validation | Comment: cannot be closed from this repository. Test plan Phase 11 is extended with the lifecycle items the review lists | OPEN (needs AIX host) |

## After the batches (done 2026-10-03)

1. Every diff was read. One batch went back for rework: step 5's FRA read-back exited in the
   middle of the post-clone sequence, which would have left a completed, non-restartable clone
   with the broker off and MRP not started. It now records the contradiction, finishes the
   remaining actions and exits 1 at the end.
2. All 25 suites pass under Bash 5.3 and under Bash 3.2.57 (driver and inner shell), with `ps`
   available so nothing is skipped.
3. The new SQL was run read-only on the lab: identity query, role-trigger query, step 5's FRA
   query, the standby SCN gate query, both SRL size queries, and the `SHOW OBSERVER` parser
   against real output. No file was written on the lab hosts.
4. `CLAUDE.md`, `docs/DATA_GUARD_WALKTHROUGH.md`, `docs/DG_CHECK.md`, `docs/DG_STATUS.md`,
   `docs/WALLET_SETUP.md` and the two toolkit READMEs describe the changed behaviour.
5. The follow-up review has a "Fix status" section.
6. `TEST_PLAN_2026-10-01.md` has Phase 12, rows 9.8-9.9 and 11.10-11.16, and the changed pass
   criteria of rows 0.2, 4.1, 6.1, 7.1, 9.2 and 9.6.

## Deviations from the design choices above

- **Observer liveness through the standby alias (3):** judged on the fresher of this
  observer's two pings, not on the target ping alone. After a completed failover the standby
  alias is the new primary and the target ping points at the dead old primary; target-only
  would mark a healthy observer stale and have the watchdog restart it every cycle.
- **Wallet setup, local alias (13):** `setup_dg_wallet.sh` stores the local alias credential
  only when its SYS password check passes. Storing one that cannot log in would fail the final
  login test after the wallet had already been rewritten.
- **Step 4 (7):** a failed static listener insert now ends the step in ERROR (exit 1) after
  the rest of the step has run. It used to warn and report SUCCESS.
- **Step 5 read-back (6):** also applied when an FRA *was* chosen (Traditional or OMF), where
  the standby's value must equal the configured path.

## What is left

Nothing in this pass ran a clone, a role change, an observer or a migration. In order of
value:

1. Commit and push, then test plan Phases 0-1 (unit suites + the E2E run that drives every
   changed numbered step with its fixed stdin sequence).
2. Phase 12 rows 12.2 (identity guard; the lab has the two-primaries-on-one-host case), 12.3
   (dead-observer restart; it settles the one assumption about the broker's answer) and 12.6
   (observer restart with the original primary down).
3. Row 12.8 together with Phase 10: both need a rebuild, and Phase 10 decides the open OMF
   control-file gate.
4. Phase 9 for the migration fixes (rows 9.2, 9.6, 9.8, 9.9).
5. Phase 11 when an AIX 7.2 host exists.
