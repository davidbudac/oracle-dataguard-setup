# Scenario E2E suite

End-to-end tests of the Data Guard setup scripts against a real two-host
Oracle 19c lab. One runner, one config file, a catalog of primary database
shapes crossed with standby builds, and a prompt driver that answers the
scripts' questions by **what they ask**, not by position.

```bash
cp tests/e2e/config.env.template tests/e2e/config.env   # fill in hosts and paths
bash tests/e2e/e2e.sh doctor                            # what the lab can do; what each scenario needs
bash tests/e2e/e2e.sh run --tier smoke                  # ~40 min: s01 + r03
bash tests/e2e/e2e.sh run --tier core                   # ~3 h
bash tests/e2e/e2e.sh run --scenario s02 --keep         # one scenario, leave the databases up
bash tests/e2e/e2e.sh run --scenario s02 --from-step step5   # resume a build after a fix
bash tests/e2e/e2e.sh clean --scenario s02              # tear it down later
```

Always run with `bash`. Logs land in `tests/e2e/logs/<run>/<scenario>/`.

## 1. What the lab needs

The doctor checks all of it and prints the exact fix for anything missing;
a scenario whose prerequisites are not met is **skipped with the reason**,
never failed, so a bare two-host lab runs the suite on day one.

| Need | Why | Without it |
|---|---|---|
| two hosts with 19c software, ssh as `oracle` (direct or via a jump host) | everything | nothing runs |
| NFS share mounted read/write on both | the scripts exchange files through it | nothing runs |
| `python3` on both DB hosts (OL/RHEL 8+ ship it) | the prompt driver | nothing runs |
| three oracle-writable base directories with distinct first path components (`LAB_FS_SLOTS`, default `/u01/app/oracle /home/oracle /var/tmp/oracle`) | "the filesystem" to the scripts' Q1b is the first path component, so no root and no extra mounts are needed | profiles on `{FS2}`/`{FS3}` (P02, P03, P05) skip |
| a world-writable, disk-backed top-level dir on the standby (`LAB_FS_RENAME_TARGET`, default `/tmp`) | the "filesystem renamed on the standby" scenario maps `/home/oracle/...` to `/tmp/oracle/...` | s02 skips |
| `dirname(ORACLE_BASE)` writable on the standby | a different standby `ORACLE_BASE` | s09 skips (fix: one `chown` as root) |
| a third host with `dgmgrl` (`HOST3`) | observer away from both DB hosts | s06 skips |
| ~1.8 GB / ~2.8 GB `MemAvailable` per host | non-CDB / CDB pairs | the scenario skips |

Nothing needs root. Every scenario except s01 runs in its own scratch
`TNS_ADMIN` (own `listener.ora`, `sqlnet.ora`, `tnsnames.ora`, listener on
`LAB_SCRATCH_PORT`) under `LAB_SCRATCH`, so the shared
`$ORACLE_HOME/network/admin` and any other database on the hosts are never
touched. s01 deliberately uses the shared one, because that is what a user
gets by default.

## 2. How it works

```
tests/e2e/
  e2e.sh                 doctor | list | run | clean
  config.env(.template)  hosts, paths, passwords, the lab's writable slots
  lib/
    answer.py            pty prompt driver (stdlib only), runs ON the DB host
    drive.sh             run_step: ship the rules, run a script under answer.py, keep the logs
    scenario.sh          load profile + scenario, expand {FSn} placeholders, derive S_NEEDS
    doctor.sh            probe the lab -> logs/lab.caps; resolve S_NEEDS; per-scenario table
    provision.sh         profile -> DBCA + reshaping SQL -> shape verification
    build.sh             steps 1-7, 13 / 9+10 / services / 11 / wallet / handoff / 12
    refusal.sh           CASE_n_* runner for the r* scenarios
    checks.sh            run checks/*.sh and proofs/*.sh; shared helpers (mark, scn wait, dgmgrl as SYS)
    teardown.sh          remove what a scenario created, and only that
    ssh.sh assert.sh common.sh report.sh
  answers/*.rules        prompt regex -> answer, per step; @VAR@ tokens filled per scenario
  scenarios/primaries/pNN_*.env     primary shapes (P_*)
  scenarios/sNN_*.scenario.env      builds   (WANT_* / PROVE_* / EXPECT_*)
  scenarios/rNN_*.scenario.env      refusals (CASE_n_*)
  checks/NN_*.sh         one standalone tool or contract each; self-skipping
  proofs/NN_*.sh         the standby is usable: redo, switchover, failover, new files/PDBs
  logs/<run>/<scenario>/ provision/ build/stepN.{out,tty,rules} checks/ proofs/ result.json
```

**Phases of a build scenario:** `provision -> build -> checks -> proofs -> cleanup (step 12) -> teardown`.
A refusal scenario: `provision -> cases -> teardown`. `--from PHASE`, `--only PHASE`,
`--from-step stepN` resume after a fix; `--keep` leaves the pair up.

### The prompt driver

`lib/answer.py` runs a script in a real pseudo-terminal, so the TTY-gated
prompts (Q1b filesystem map, the path review table, `ORACLE_BASE` override,
`db_create_online_log_dest_n`, the second control-file directory) appear
exactly as they do for a DBA. Rules are `regex<TAB>answer[<TAB>flags]`,
matched against the ANSI-stripped output since the previous answer, anchored
at the end, so a rule can carry context lines (`Continue anyway\?\nDo you
want to proceed\? \[y/N\]:` -> `n`) or read a menu number off the screen
(`^ *([0-9]+)\) \[data\] /u02/... ->` -> `\1`). Flags: `secret` (never
logged), `once` (consumed after one match), `fail` (a prompt that must not
appear: answered, then exit 96).

A prompt no rule matches ends the step with exit 97 and `UNANSWERED PROMPT:
<text>` - the scenario fails, and the finding is "the script asked something
the scenario did not foresee". Every answered prompt is recorded in
`build/stepN.tty` as `[prompt] <text> => <answer>`, so the log doubles as the
prompt sequence of that run.

### Provisioning

`lib/provision.sh` builds the primary from a profile with DBCA, then reshapes
it with SQL (datafile moves, redo rebuilt per directory, control files,
tempfiles, archiving, FRA, password-file mode, flashback, PDBs, services,
pre-existing SRLs, broker files, preset convert parameters, a marker schema)
and **verifies the shape against the live database** before the scenario
starts - a multi-filesystem profile whose files all landed in one directory
tests nothing.

### Few builds, many checks

A build costs ~25 min; a check costs seconds and runs after every build.
Coverage grows by adding a `checks/NN_name.sh` that defines `check_name()`
(return 0 pass, 1 fail, 2 not applicable), not by adding builds.

## 3. Catalog

Primaries (`scenarios/primaries/`):

| ID | Shape | Opens |
|---|---|---|
| P01 | non-CDB, explicit paths, data+redo in one dir, no FRA | the default path |
| P02 | non-CDB on {FS1}+{FS2}+{FS3}: data on two, multiplexed redo with no DB-name component, explicit control files in two places, FRA, archiving into it, DML load during the clone | convert pairs over several dirs, Q1b, unmapped-path confirmation, inherited FRA/control_files |
| P03 | non-CDB, OMF + `db_create_online_log_dest_1/2` + FRA | inherited placement parameters |
| P04 | CDB + 2 PDBs, explicit, `db_domain`/`NAMES.DEFAULT_DOMAIN`, a service per PDB | alias domain qualification, `C##` observer user, CDB trigger |
| P05 | CDB + 2 PDBs, OMF, FRA | OMF with PDB GUID paths |
| P06 | SID != DB_NAME != DB_UNIQUE_NAME, port 1541, undersized THREAD#=0 SRLs, non-default broker files | names, port detection, SRL warning, broker-file SPFILE SET |

Builds and refusals (tiers: **smoke** every change, **core** every version, **full** before a release):

| ID | Tier | Primary | Build | Proofs |
|---|---|---|---|---|
| s01 | smoke | P01 | shared net; every step `-n` first; max availability (13); SYS trigger; handoff | redo, switchover roundtrip with services following, declined step 5, uncovered dir -> UNNAMED -> fix |
| s02 | core | P02 | Q1b map {FS2},{FS3} -> {RENAME}; separate SRL dir; 2nd control-file dir; `--channels 2`; no standby FRA; cleanup `--all` | redo, add datafile |
| s03 | core | P02 | OMF standby with FRA; max availability | redo, add datafile; control files not inherited |
| s04 | core | P04 | CDB trigger, `create_pdb_service.sh`, wallets, handoff | redo, switchover roundtrip, new PDB |
| s05 | core | P01+flashback | FSFO, observer on the standby host, dedicated-user trigger | redo, **failover** + reinstate |
| s06 | full | P04+flashback | FSFO, observer on HOST3 via `add_observer`, CDB trigger | redo, failover + reinstate |
| s07 | full | P03 | OMF -> OMF, online-log dests remapped | redo |
| s08 | full | P05 | CDB OMF, CDB trigger | redo, new PDB |
| s09 | full | P02 | review-table overrides on every dir, other `ORACLE_BASE`, standby FRA, `--rate` | redo, add datafile |
| s10 | full | P06 | defaults on the quirks primary; max availability | redo (+ `dg_check_srl` exit 1 with DDL) |
| s11 | full | P01 | wrong dir in step 2 fixed by `--regenerate`; SYS locked at step 5; RMAN killed mid-duplicate; step 6 re-run | redo |
| r01 | core | P01 | step 1 vs NOARCHIVELOG (refuse), no FORCE LOGGING (warn), SHARED pwfile (refuse) | primary unchanged |
| r02 | core | P01+convert | OMF chosen with `log_file_name_convert` set -> step 2 exits 1 before writing | share unchanged |
| r03 | smoke | P01 | wrong DBID on steps 4/6/9/13 (identity guard); step 5 on the primary host, declined | share + primary unchanged |

Checks run after every build (each skips itself when not applicable):
`dg_status.sh` (exit code, IN SYNC; and exit 2 + UNREACHABLE with a dead
standby address), `dg_triage_sid.sh`/`dg_diag_sid.sh` (wallet when built),
`dg_check_srl.sh` local and peer, the handoff pack's `_verify.sh` run from an
application host, `get_dg_config_url.sh` from both sides, `dg_sync_impact.sh`
(free views, HTML, fatal on a standby), `-v` never printing the SYS password,
the `-h`/unknown-flag exit-code contract of every script, a declined step 5
re-run, the observer stop/start/restart/status/-n lifecycle, and the file
placement on the standby against what the brief asked for.

Out of scope: `migrate_noncdb_to_pdb/`, `observer_sys_to_sysdg/`, `nfs/`,
AIX (unit tests cover portability), RAC, ASM.

## 4. Writing a scenario

1. Pick or add a primary profile (`primaries/_template.env`).
2. Copy `_template.scenario.env`; fill the `WANT_*` keys - every key is a
   prompt answer and an assertion at once. Use `{FS1}`..`{FS3}`, `{FSn:fs}`,
   `{RENAME}`, `{SCRATCH}`, `${ORACLE_BASE}` for paths.
3. `bash tests/e2e/e2e.sh doctor` shows whether the lab can run it and why not.
4. `bash tests/test_e2e_harness.sh` (no lab needed) checks that it loads,
   expands and derives its answers.

If a script gains a prompt, the step fails with `UNANSWERED PROMPT: <text>`;
add a rule to the step's `answers/*.rules` (and a `WANT_*` key if the answer
is scenario-specific).

## 5. Reading a result

`logs/<run>/summary.md` has one row per scenario. Per scenario:
`result.json` (verdict, failed assertions, prompt count), `results.log`
(every PASS/FAIL/SKIP line), `run.log`, `provision/shape.txt` (what the
primary really looked like), `build/stepN.out` (what the script printed),
`build/stepN.tty` (prompt records), `build/stepN.rules` (the answers used,
secrets masked), `checks/*.out`, `proofs/*.out`, `scenario.resolved`.

A failed build leaves the databases in place (`CLEANUP_ON_FAILURE=false`);
`e2e.sh clean --scenario ID` removes them.
