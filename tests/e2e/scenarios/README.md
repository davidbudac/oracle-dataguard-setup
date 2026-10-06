# Scenario E2E Suite (design draft)

Status: **design, awaiting your input**. Nothing here runs yet. The catalogs in sections 4 and 5 are a
proposal for you to validate; section 10 collects the decisions that shape the runner.

## 1. What this suite is

A fixed catalog of **primary databases** (different configurations) crossed with
**standby builds** (the features you want on the standby). For each scenario an agent
builds the standby with the repo's scripts, working the way a DBA would: in a real
terminal, reading each prompt, answering from a written brief and the walkthrough.
The scenario passes only if the resulting Data Guard configuration matches what the
brief asked for.

It complements `run_e2e_test.sh`, it does not replace it:

| | `run_e2e_test.sh` (existing) | Scenario suite (this) |
|---|---|---|
| Input | fixed piped-stdin sequence | agent answers prompts in a TTY |
| Script path covered | non-interactive defaults | the TTY-gated prompts (Q1b filesystem map, path review table, `ORACLE_BASE` override, online-log-dest override), which piped runs cannot reach |
| Primary | one shape (non-CDB, no OMF, no FRA) + one CDB variant | a catalog of shapes |
| Breaks when | a prompt is added or reordered | a prompt cannot be answered from the docs and the brief |
| Verdict | asserts inside the harness | asserts derived from the brief, independent of the scripts' own `.env` |

## 2. Principle: scripts for everything except the operator

Only the part a human would do is done by the agent. Everything else is deterministic,
so a failed run is a finding about the scripts and not about the test.

| Phase | Done by | What happens |
|---|---|---|
| 1 provision | script | clean up the previous run, build the primary from its profile, **verify the profile took** (a multi-filesystem profile whose files all landed in one directory tests nothing), record a before-state |
| 2 brief | script | render the operator brief from the scenario file |
| 3 operate | **agent** | run the walkthrough steps on the lab hosts in a TTY |
| 4 assert | script | check the outcome against the scenario file |
| 5 report | script | per-scenario result + campaign summary |
| 6 teardown | script | drop both databases, restore listener/tnsnames/sqlnet |

Phases 1, 4 and 6 reuse the ssh helpers, asserts and cleanup of `run_e2e_test.sh`
(to be extracted into `tests/e2e/lib/`).

## 3. One file per scenario, one file per primary

```
tests/e2e/scenarios/
  primaries/pNN_<name>.env      # how to build one primary shape   (keys: P_*)
  sNN_<name>.scenario.env       # one standby build on one primary (keys: S_*, WANT_*, PROVE_*, EXPECT_*)
  rNN_<name>.scenario.env       # a refusal pack: numbered cases, no clone (same keys, plus CASE_n_*)
```

`S_PRIMARY_OVERRIDES` changes profile keys for one scenario only (for example `P_FLASHBACK=yes`).
`INJECT_FAULTS` lists faults the harness introduces while the operator works, and
`EXPECT_FAULT_OUTPUT` holds one ERE per fault. `CASE_n_*` describe one refusal case each: the
step to run, the setup to apply, the expected exit code and an ERE taken from the script's message.

The scenario file is the **single source** for both the operator brief and the
assertions. The brief is rendered from the `WANT_*` keys, and the assertions are
derived from the same keys, so the two cannot drift apart. Free text that fits no key
goes into `OPERATOR_NOTES` and reaches the agent verbatim.

Templates: `primaries/_template.env`, `_template.scenario.env`.
All profiles of section 4 and all scenarios of section 5 exist as files in this directory.

## 4. Primary catalog (proposal v2, awaiting validation)

Each profile exists because it sends the scripts down a different code path.

| ID | Shape | Code paths it opens | Lab needs |
|---|---|---|---|
| P01 `noncdb_plain` | non-CDB, explicit paths, data and redo in one directory, no FRA, one user service | the default path; cheapest to build, so it also hosts the FSFO, recovery and refusal scenarios | nothing new |
| P02 `noncdb_spread` | non-CDB; datafiles on two filesystems; redo on a third with no DB-name component; multiplexed redo; temp separate; explicit `control_files` in two places; FRA set, archiving into the FRA | convert pairs over several directories, Q1b, the unmapped-path confirmation, inherited FRA and `control_files` in step 5 | extra top-level filesystems (root, once) |
| P03 `noncdb_omf` | non-CDB, OMF: `db_create_file_dest`, `db_create_online_log_dest_1/2`, FRA | inherited placement parameters, `STANDBY_DB_CREATE_ONLINE_LOG_DEST_n` mapping | nothing new |
| P04 `cdb_explicit` | CDB + 2 PDBs, explicit paths (PDB subdirectories), `db_domain` + `NAMES.DEFAULT_DOMAIN`, one user service per PDB | alias domain qualification, `C##` observer user, CDB trigger, PDB services | nothing new |
| P05 `cdb_omf` | CDB + 2 PDBs, OMF (GUID directories), FRA | OMF with PDB GUID paths | nothing new |
| P06 `noncdb_quirks` | SID != DB_NAME != DB_UNIQUE_NAME, listener on a non-default port, undersized SRLs created without `THREAD`, non-default `dg_broker_config_file1/2` | name handling, port detection, SRL size warning, broker-file `SPFILE SET` | a second listener |

There is no separate "not ready" primary: the refusal scenarios toggle P01 and restore it.

## 5. Scenario catalog (proposal v2, awaiting validation)

Tiers: **smoke** = every change, **core** = every version, **full** = before a release.
Every build scenario also runs `dg_status.sh`, `dg_triage_sid.sh`, `dg_check_srl.sh` and
the handoff report as part of the assertions.

### Builds (full workflow, about 30 min each)

| ID | Tier | Primary | Standby the operator is asked to build | After the build | Proof |
|---|---|---|---|---|---|
| S01 baseline | smoke | P01 | Traditional, same layout. Every step is run with `-n` first, then for real | step 13 (max availability), SYS role trigger, handoff, default cleanup | `-n` changed nothing; redo roundtrip; switchover roundtrip; at the end, step 5 re-run and declined leaves the standby untouched |
| S02 renamed filesystems | core | P02 | Traditional; two filesystems renamed through Q1b; separate SRL directory; second control-file directory; `--channels 2`; no FRA on the standby | stays MAXIMUM PERFORMANCE; cleanup `--all` | every file where asked, none under a primary-only path; standby has no FRA; a datafile added on the primary arrives |
| S03 OMF standby, explicit primary | core | P02 | OMF mode with FRA on the standby | step 13 | files under the OMF destinations; explicit `control_files` not inherited (the item CLAUDE.md lists as open); added datafile arrives |
| S04 CDB | core | P04 | Traditional, same layout | step 13, CDB role trigger, `create_pdb_service.sh`, wallet on both hosts, handoff `--all-flavors` | switchover roundtrip with the PDB services following the role; wallet-based triage works; new PDB under a covered directory arrives |
| S05 FSFO, observer on standby host | core | P01 | Traditional, same layout | step 9, `fsfo/observer.sh setup` + `start`, dedicated-user role trigger | `SHUTDOWN ABORT` the primary: observer fails over within the threshold, service moves, old primary reinstated |
| S06 FSFO, third-host observer | full | P04 | Traditional, same layout | step 9 routed to `add_observer/`, bundle installed on dg3, `C##` observer user | failover as S05; observer survives it and is judged live by `03_observer_ctl.sh status` |
| S07 OMF to OMF | full | P03 | OMF mode; online-log destinations mapped to non-default directories | none | redo and control files in the mapped destinations; redo roundtrip |
| S08 CDB with OMF | full | P05 | OMF mode | CDB role trigger | new PDB created after setup arrives with no operator action |
| S09 different base paths | full | P02 | Traditional; filesystem names kept, directories changed in the review table; different standby `ORACLE_BASE`; FRA on the standby; `--rate` limit | none | file placement as overridden; redo roundtrip |
| S10 quirks | full | P06 | Traditional, defaults | step 13 | undersized-SRL warning shown and nothing dropped; port and names correct in TNS, listener and broker; redo roundtrip |
| S11 mistakes and recovery | full | P01 | Traditional. Operator enters a wrong path in step 2, corrects it by editing the `.env` and `--regenerate`; SYS is locked when step 5 first runs; the second step 5 is killed mid-duplicate | re-run step 6 over the existing configuration | each failure is reported with the documented fix; the documented restart procedure leads to a healthy standby |

Step 9 does not enable Flashback Database. S05 and S06 therefore build the primary with flashback
on (`S_PRIMARY_OVERRIDES="P_FLASHBACK=yes"`), and the operator enables it on the standby after step 7.

### Refusals (no clone, minutes each)

| ID | Tier | Primary | What is attempted | Must happen |
|---|---|---|---|---|
| R01 not ready | core | P01, toggled | step 1 against NOARCHIVELOG, then no FORCE LOGGING, then `REMOTE_LOGIN_PASSWORDFILE=SHARED` | NOARCHIVELOG and SHARED: exit 1, the failed prerequisite named. No FORCE LOGGING: a warning and exit 0 (step 1 does not treat it as fatal) |
| R02 OMF blocked | core | P01 with `LOG_FILE_NAME_CONVERT` set | step 2, operator chooses OMF mode | exit 1 as soon as OMF is chosen, before the OMF directory prompts and before any file is written |
| R03 wrong target | smoke | P01, after steps 1-2 | steps 4, 6, 9 and 13 with a config whose DBID does not match; step 5 started on the primary host | steps 4, 6, 9, 13: the identity guard exits 1. Step 5: a hostname warning and "Continue anyway?", the operator declines, exit 1. Database and share (apart from `logs/` and `state/`) unchanged |

Out of scope: `migrate_noncdb_to_pdb/`, `observer_sys_to_sysdg/` and the `nfs/` scripts
(side toolkits or root-only), AIX, RAC, ASM.

## 6. The operator agent

One fresh agent per scenario. It receives the rendered brief,
`docs/DATA_GUARD_WALKTHROUGH.md`, the test passwords, and a small driver that opens a
tmux session on each lab host (`open`, `send`, `read`, `wait-for`). tmux gives the
scripts a real TTY and its `pipe-pane` log is the transcript.

Rules of engagement:

1. Sources of truth are the brief, the walkthrough, and what the scripts print. The
   agent does not read script source to work out an answer.
2. It does not edit scripts, and does not repair a failed step with manual SQL, DGMGRL
   or file edits unless the walkthrough or the script's own output tells the operator to.
3. Read-only inspection a DBA would do (`ls`, `df`, `lsnrctl status`, a `SELECT`) is
   allowed and logged.
4. Every prompt goes into a decision log: prompt text, answer, the brief key or
   walkthrough section that justified it. A prompt with no justification is recorded
   as an **ambiguous prompt** finding, answered with the default, and the run continues.
5. If it cannot proceed within the rules it stops with `BLOCKED` and the transcript.
   It never works around the problem.

The agent never decides pass or fail. Phase 4 does.

## 7. Assertions

Derived from the scenario file and checked against the live databases. They are not
read back from the `standby_config_*.env` the scripts generated, which would only prove
the scripts agree with themselves.

Standard set, every `build` scenario:

- standby: `DATABASE_ROLE`, `DB_UNIQUE_NAME`, open mode, MRP applying, no `UNNAMED` datafiles, datafile count equals the primary's
- broker: `SHOW CONFIGURATION` is `SUCCESS`, `VALIDATE DATABASE` ready for switchover on both members
- SRLs: count and size per `dg_check_srl.sh` (exit 0)
- every script the agent ran exited with the code the walkthrough promises
- `dg_status.sh` exits 0 (or 1 where the scenario lists an expected warning)

Derived from `WANT_*`:

- file placement: every standby datafile, ORL, SRL, tempfile and control file is under the directory the brief asked for, and none is under a primary-only path
- parameters: `db_create_file_dest`, `db_recovery_file_dest`, `db_create_online_log_dest_n`, `control_files`, convert parameters
- protection mode, `LogXptMode`, FSFO state, observer present and where it runs
- role trigger objects valid under the right owner; services running on the primary only
- handoff files exist, verdict as expected, `_verify.sh` passes

`PROVE_*` (functional proof that the standby is usable):

- `PROVE_REDO_ROUNDTRIP`: a marker row written on the primary after the build is covered by the standby's applied SCN
- `PROVE_SWITCHOVER=roundtrip`: switch over, read the marker on the new primary, write a second one, switch back, read both
- `PROVE_FAILOVER`: `SHUTDOWN ABORT` the primary, FSFO completes within threshold + margin, reinstate the old primary
- `PROVE_ADD_DATAFILE` / `PROVE_NEW_PDB`: create it on the primary, check that it arrives and apply keeps running

`refusal` scenarios assert `EXPECT_STEP`, `EXPECT_EXIT`, `EXPECT_OUTPUT_MATCH`, and that
the before-state from phase 1 is unchanged.

## 8. Running it and reading the result

```bash
bash tests/e2e/scenarios/run.sh --tier core        # phases 1-2, then waits for the operator
bash tests/e2e/scenarios/run.sh --scenario s02 --phase assert
```

Phase 3 is started from Claude Code ("run the core tier"), one scenario after another:
the lab has a single host pair, so scenarios are serial. Estimate 25-35 min per build
scenario (DBCA ~10, clone and broker ~5, proofs ~5, the rest prompts and teardown),
which puts the core tier (four builds plus two refusal packs) near two and a half hours.

Per scenario: `logs/<run>/<scenario>/{brief.md, transcript.log, decisions.md, assert.log, result.json}`.
Campaign summary, one row per scenario: verdict (`PASS` / `FAIL` / `BLOCKED`), failed
assertions, ambiguous prompts, duration. Ambiguous prompts are reported separately from
failures: they are documentation and usability findings, and the build may still pass.

## 9. Lab preparation

These must exist before the suite can run. The suite does not create them.

1. Directories `/u02`, `/u03`, `/u04`, `/u05`, `/u06` and `/u07`, owned by `oracle:oinstall`, on both database hosts. Needs root, once. Used by P02, S02, S03 and S09.
2. `/u01/app/oracle_stby`, creatable by `oracle` on the standby host (S09).
3. A second listener on port 1531 for P06, defined in the Oracle home's `network/admin` that the lab's `cdb1` databases share.
4. `NAMES.DEFAULT_DOMAIN=world` in that shared `sqlnet.ora` for P04 (`cdb1` already uses `db_domain` world).
5. `dg3` reachable, with an Oracle client home installed, for S06.

## 10. Decisions I need from you

1. **Primary catalog** (section 4): validate; add shapes from your real estate that are missing.
2. **Scenario catalog** (section 5): validate the standby features per scenario, and the tiers.
3. **Lab filesystems.** P02 (S02, S03, S09) needs distinct first path components (`/u02`,
   `/u03`, `/u04`, ...) owned by `oracle` on both VMs. That takes root once; the
   runbook says there is no sudo on the DB hosts. Can you create them, or should the
   profiles stay under `/u01` (which leaves Q1b untested)?
4. **`cdb1` during a campaign.** The scenario databases share the 4 GB VMs with the
   `cdb1`/`cdb1_stby` FSFO pair. Leave it running, or stop it for the campaign? A
   failover proof (S05/S06) puts the most load on the hosts.
5. **Primary provisioning.** Fresh DBCA per scenario (simple, ~10 min each), or build
   each profile once and keep a DBCA clone template (faster, but the template can go stale)?
   My recommendation is fresh DBCA first, templates when the runtime starts to hurt.
6. **Proof level.** Switchover roundtrip in every build scenario, or only in the ones
   marked above? Is the destructive failover proof acceptable in the core tier?
7. **Primary under load.** Should the primary carry data and a small DML load while
   step 5 clones (closer to production), or is an empty database enough?
8. **Expected outcomes still open:** new PDB after setup in Traditional mode (S04),
   and which `dg_status.sh` warnings are acceptable per scenario.
9. **Operator strictness.** Is "ambiguous prompt, take the default, continue" right, or
   should an unanswerable prompt fail the scenario?
10. **Not covered:** AIX (the lab is OL9 only), RAC, ASM. Say so if any of these needs a
    stand-in.
