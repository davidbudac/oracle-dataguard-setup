# Handover: Repo Review & Asymmetric-Layout Hardening

**Branch:** `claude/project-review-plan-l5ihf4` (branched from `main` @ `04012ad`), then `handover-followups`
**Commits:** `ef4190b` (review fixes), `02f85f4` (asymmetric filesystem support), plus the `handover-followups` series
**Status:** **Merged to `main` @ `706c1a5` (2026-07-17)** — this document is now a historical record of the work, not an open handover. `bash -n` clean on every touched script; all unit tests pass (`for t in tests/test_*.sh; do bash "$t"; done` — 8 suites as of 2026-08-05). Known issues 1, 2, and 4 below are fixed; see the update block under "Known remaining issues" for what is still open.

## What this branch contains

### Commit 1 — `ef4190b`: fixes from a full repo review

A prior review round already existed and was implemented (see `docs/IMPROVEMENT_PLAN.md`, all workstreams ✅ 2026-07-07, merged via PR #2). This commit fixes *new* issues found on top of that:

- **Credential exposure:** step 8 changed the SYS password via sqlplus argv (visible in `ps`) — now a stdin heredoc with `pause_verbose_trace`. FSFO/dedicated-user scripts redact passwords from error output. orapw copies to NFS now created under `umask 077`.
- **Wallet safety:** `common/setup_dg_wallet.sh` default `WALLET_DIR` moved from `$ORACLE_HOME/network/admin` (whole dir was swapped away on first run — destructive!) to `network/admin/dg_wallet`; activation refuses to displace a dir containing non-wallet files. Auto password now openssl/urandom, not cksum.
- **Observer pidfile** (`fsfo/observer.sh`): stores `host:pid`; start/stop/status refuse cross-host actions instead of deleting the live observer's pidfile or killing an unrelated PID. Legacy bare-PID files treated as local.
- **Monitoring correctness:** handoff verdicts only escalate (gap ERROR no longer downgraded by broker WARNING); unparseable DGMGRL output counts as warning instead of rendering healthy/exit 0; `-s` SID overrides validated; `dg_check_srl.sh` exits ≥1 on unchecked peer.
- **Setup pipeline:** Traditional+FRA used the *primary's* `db_recovery_file_dest_size` (fixed to standby value w/ fallback); RMAN CONNECT password now double-quoted to match verification; RMAN failure block was dead under `set -e` (fixed with `set +e` around the pipeline); tnsnames idempotency check anchored on `^alias\s*=`; step 6 aborts on unexpected SHOW CONFIGURATION output; approval prompts go to stderr (survive `$(...)`); `init_log` degrades gracefully when NFS unmounted.
- **Docs:** `dg_check_srl.sh`, `migrate_noncdb_to_pdb/`, `trigger/create_cdb_service.sh`, `dg_local_status_common.sh`, and all 7 unit tests documented in CLAUDE.md/README; README quick-start renumbered 1–12; `${var^^}` bash-4-ism removed from migrate preflight.

### Commit 2 — `02f85f4`: asymmetric primary/standby filesystem layouts (user's explicit focus, incl. CDB)

The user asked to verify usability when primary and standby have **different filesystem structures**, for **both CDB and non-CDB**. Two deep code traces confirmed the interactive first-run path mostly worked but had holes; all fixed:

- **Step 1:** tempfile dirs gathered from `V$TEMPFILE` and merged into `PRIMARY_DATA_PATHS` (temp-only mounts previously got no convert pair → clone failure). New parallel array `PRIMARY_DATA_PATH_SIZES_MB` (per-directory MB, datafiles+tempfiles). `PRIMARY_DATA_PATH` now = SYSTEM datafile's dir (`FILE#=1`), not an unordered first row (on CDBs that could be a seed/GUID dir). New SQL: `get_tempfile_dirs.sql`, `get_datafile_dir_sizes.sql`, `get_system_datafile_dir.sql`.
- **Step 2:** pair-building refactored into `build_convert_pairs()` (~line 54 of `primary/02_generate_standby_config.sh`) — called by BOTH normal and `--regenerate` modes (regenerate previously shipped stale convert strings verbatim from the .env). Pairs sorted longest-primary-path-first and emitted with trailing slashes (Oracle first-prefix-match; prevents `/u01/oradata` shadowing `/u01/oradata2` and parent dirs shadowing nested CDB GUID dirs). New `_review_path_mappings()`: interactive numbered table of every primary→standby dir mapping with per-entry override — **TTY-gated** (`[[ -t 0 ]]`). Standby ORACLE_BASE/HOME prompted (TTY-gated) instead of assumed equal. SRL-contradiction warning; >20 pairs/2000 chars warning recommending OMF; archive-dest default uses component-bounded remap. Passes `STANDBY_DATA_PATH_SIZES_MB` through to the standby .env when parallel.
- **Step 3:** per-filesystem disk check (group standby dirs by mount via `df -Pk`, +20% headroom per mount) when `STANDBY_DATA_PATH_SIZES_MB` is present/parallel; otherwise falls back to the exact old aggregate check with a note. FRA fallback sed made component-bounded.
- **Step 5:** prefers locally-set `ORACLE_HOME` (with `bin/sqlplus` present) over the config value, warning on mismatch.
- **Post-setup trap (biggest CDB operational risk):** new PDB/datafile created after setup in a dir no convert pair covers → `UNNAMED` file + ORA-01274, apply halts despite `standby_file_management=AUTO`. Now: "Life After Setup: Adding Datafiles and PDBs" section in `docs/DATA_GUARD_WALKTHROUGH.md` (incl. repair sequence), DBA note in both handoff reports, and UNNAMED-datafile detection (new `get_unnamed_datafiles.sql`) wired into `dg_status.sh` and `common/dg_local_status_common.sh` as errors.
- **Tests:** `tests/test_file_name_convert.sh` rewritten to copy `build_convert_pairs` verbatim; covers prefix overlap, SRL contradiction, length warning. (Correction 2026-07-17: this claimed "byte-identity checked via diff in the test", but no such check existed — it was a comment-only convention, so the copies could rot apart with every test still green. A real diff-based drift guard is now Test 11.) 15/15 pass.

## Interface contracts introduced (do not rename)

- `PRIMARY_DATA_PATH_SIZES_MB` — bash array in `primary_info_<NAME>.env`, index-parallel to `PRIMARY_DATA_PATHS`, integer MB per dir.
- `STANDBY_DATA_PATH_SIZES_MB` — same, in `standby_config_<NAME>.env`, parallel to `STANDBY_DATA_PATHS`; step 2 writes it only when parallelism holds (omitted in OMF mode); step 3 falls back to the aggregate check when absent/mismatched.
- Convert-pair format changed: elements now carry a **trailing slash** (`'/u01/oradata2/','/stby/data2/'`) and are sorted longest-primary-first. `add_convert_standby_dirs` in step 3 tolerates this (dedup strips trailing-slash variants).

## Repo ground rules (from CLAUDE.md — verified real, enforced by tests)

- AIX 7.2 / bash 3.2 portable: no `mapfile`, `declare -A`, `${var,,}`/`${var^^}`, `grep -P`, `\s` in ERE, BRE `\|`, `sed -i`, `echo -e`, `date -d`. Use `printf`, `df -Pk`, `x=$((x+1))` (never `((x++))` — banned under `set -e`, swept by `test_counter_increment.sh`).
- The E2E suite drives interactive scripts via **piped stdin with a fixed line sequence** — any NEW prompt must be gated on `[[ -t 0 ]]` or it breaks E2E. All prompts added in this branch follow that rule.
- DGMGRL-first for all Data Guard configuration; passwords prompted, never stored; step 5 (RMAN duplicate) is NOT restartable.

## Known remaining issues (found, deliberately NOT fixed — good next tasks)

> **Update 2026-07-17:** items 1, 2, and 4 below are FIXED on branch `handover-followups`.
> Item 1 → new `run_dgmgrl_checked` (output-grepping, `Error: 0` benign line excluded) used by all mutating broker calls in steps 6/9; read-only and custom-grepping call sites left on `run_dgmgrl`.
> Item 2 → `WHENEVER SQLERROR EXIT SQL.SQLCODE` added to all 54 `sql/queries/*.sql`; `run_sql_query` now surfaces failures on stderr (set -e safe); `is_numeric()` guards added at arithmetic/env consumption sites in steps 1/2/3.
> Item 4 → all eight sub-items fixed (glob-based `select_config_file`, escaped `substitute_dgmgrl_args`, progress totals, idempotent `init_log`, NFS ping/showmount downgraded to warnings + `nointr` dropped, CLAUDE.md renumbered to walkthrough steps, optional TTY-gated control-file-2 dir prompt in step 2 + dir creation in step 3, `tr -d ' '` replaced with edge-trimming sed on paths).
> Item 3 (E2E gaps) — **partially closed 2026-07-17 by live lab runs** (poug-dg1/poug-dg2 via dbmint):
> - Full standard non-CDB E2E passes end to end on this branch (steps 1–7, role trigger, cleanup).
> - **Live asymmetric-layout validation done**: primary with 3 datafile dirs (incl. mixed-case DB-name tokens and a temp-only dir), standby remapped to a completely different base (`/u01/stby/{data,data2,temp,redo,arch}`) via edit-env + `--regenerate`; RMAN duplicate placed every file correctly, broker SUCCESS, MRP healthy, and a post-setup `CREATE TABLESPACE` on the primary auto-replicated into the remapped standby dir.
> - Live-run fixes made along the way: FSFO disable before REMOVE CONFIGURATION (ORA-16654); ORA-16596 treated as no-usable-config; tab-stripping before is_numeric (sqlplus pads scalars with tabs); TTY-gate on the unmapped-path prompt; **`--regenerate` now persists rebuilt convert strings into the .env** (step 5 feeds RMAN from the .env — stale strings silently overrode the regenerated pfile); step 5 instance-status probes tolerate WHENEVER SQLERROR; E2E harness fixes (DBCA exit 6, honest deploy reporting, ERE `|` in asserts, broker-SUCCESS retry loop).
> - Known limitation found: when the primary keeps data+redo in ONE directory but the standby splits them, first-prefix-match means ORLs/SRLs land in the standby DATA dir, not the split redo dir (both convert strings share one pair list). Functional, but a split needs a distinct primary redo dir too. **Addressed 2026-07-17:** not fixable by ordering (a pair remaps a primary filename; nothing tells an ORL from a datafile in a shared dir), so `build_convert_pairs()` now detects and warns instead of shipping the split silently — tests 9/10 in `tests/test_file_name_convert.sh`.
> - Still untested live: CDB E2E with real PDBs/GUID dirs, OMF-primary→Traditional-standby, switchover (IMPROVEMENT_PLAN 6.2, 6.4).
>
> **Correction 2026-08-05:** the line above originally also listed **observer** as untested. That was true of *this* branch's runs, but a separate lab session on **2026-07-07** (merged after this document, see `docs/IMPROVEMENT_PLAN.md` → "E2E run 2026-07-07") had already exercised the full observer lifecycle plus optional steps 8 and 9 — and found three product bugs there: the 32-char SYS password (`ORA-00972`), the missing password-file format-12.2 pre-check (`ORA-40365` leaving SYS changed-but-unlocked), and `observer.sh start` misreading healthy FSFO output as a connection failure. IMPROVEMENT_PLAN 6.3 is therefore ✅, not ⏭️. Steps 8–10 were *not* re-run on 2026-07-17, so that session remains their only live coverage.

1. **DGMGRL exit codes are meaningless** (`common/dg_functions.sh` `run_dgmgrl*`): scripts end in `EXIT;` so dgmgrl returns 0 even when CREATE CONFIGURATION / `StaticConnectIdentifier` edits failed; every `if ! run_dgmgrl` is a no-op. Fix = output-grepping wrappers (`ORA-|Error|Failed` → nonzero), but that changes behavior for ALL callers (some grep output themselves, e.g. `06:288`) — needs a deliberate pass, possibly a `run_dgmgrl_checked` used only by mutating calls.
2. **`sql/queries/*.sql` lack `WHENEVER SQLERROR EXIT`** — error text can flow into env files/arithmetic as data. A sweep changes exit-code semantics under `set -e` repo-wide; pair with an `is_numeric` guard helper.
3. E2E gaps: CDB E2E (`tests/e2e/run_e2e_test_cdb.sh`) builds a **zero-PDB, symmetric, token-in-path** CDB only. Untested: real PDBs/GUID dirs, asymmetric mounts, the new `_review_path_mappings` interactive path, OMF-primary→Traditional-standby, post-setup PDB creation with apply verification. IMPROVEMENT_PLAN.md items 6.2–6.4 (switchover/observer/CDB E2E) also still open.
4. Low-severity leftovers: `select_config_file` breaks on paths with spaces (parses `ls`); `substitute_dgmgrl_args` sed-replacement unescaped for `|&\`; progress totals off-by-one in most scripts (`[12/11]`); double `init_log` calls orphan `RUNNING` state files; NFS preflight uses ping/showmount (fails on ICMPI-filtered/NFSv4-only servers) + no-op `nointr`; step-number terminology still differs between WALKTHROUGH.md and CLAUDE.md; standby control files both land on one filesystem (no multiplexing prompt); `tr -d ' '` in step 1 mangles paths containing spaces.

## Verification commands

```bash
for f in $(git diff main --name-only | grep '\.sh$'); do bash -n "$f"; done
for t in tests/test_*.sh; do bash "$t"; done          # all must pass (8 suites as of 2026-08-05)
bash ./tests/e2e/run_e2e_test.sh                       # ~20 min, needs the lab env (tests/e2e/config.env)
```

~~The single most valuable validation still outstanding: **one live E2E run with an intentionally asymmetric standby layout**~~ — **done 2026-07-17** against the poug-dg1/poug-dg2 lab (non-CDB); see the update block above for the results and the eight fixes it produced. The asymmetric fixes are now backed by a real RMAN duplicate, not only code trace and unit tests.

The most valuable validation now outstanding: **the same asymmetric run against a CDB with real PDBs** (GUID dirs), plus OMF-primary→Traditional-standby and the switchover assertion (IMPROVEMENT_PLAN 6.2, 6.4). Observer lifecycle is covered — see the 2026-08-05 correction above.
