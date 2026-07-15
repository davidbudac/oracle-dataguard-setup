# Handover: Repo Review & Asymmetric-Layout Hardening

**Branch:** `claude/project-review-plan-l5ihf4` (pushed; branched from `main` @ `04012ad`)
**Commits:** `ef4190b` (review fixes), `02f85f4` (asymmetric filesystem support)
**Status:** All work committed and pushed. `bash -n` clean on every touched script; all 7 unit tests pass (`for t in tests/test_*.sh; do bash "$t"; done`). No PR opened (user has not asked for one).

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
- **Tests:** `tests/test_file_name_convert.sh` rewritten to copy `build_convert_pairs` verbatim (byte-identity checked via diff in the test); covers prefix overlap, SRL contradiction, length warning. 10/10 pass.

## Interface contracts introduced (do not rename)

- `PRIMARY_DATA_PATH_SIZES_MB` — bash array in `primary_info_<NAME>.env`, index-parallel to `PRIMARY_DATA_PATHS`, integer MB per dir.
- `STANDBY_DATA_PATH_SIZES_MB` — same, in `standby_config_<NAME>.env`, parallel to `STANDBY_DATA_PATHS`; step 2 writes it only when parallelism holds (omitted in OMF mode); step 3 falls back to the aggregate check when absent/mismatched.
- Convert-pair format changed: elements now carry a **trailing slash** (`'/u01/oradata2/','/stby/data2/'`) and are sorted longest-primary-first. `add_convert_standby_dirs` in step 3 tolerates this (dedup strips trailing-slash variants).

## Repo ground rules (from CLAUDE.md — verified real, enforced by tests)

- AIX 7.2 / bash 3.2 portable: no `mapfile`, `declare -A`, `${var,,}`/`${var^^}`, `grep -P`, `\s` in ERE, BRE `\|`, `sed -i`, `echo -e`, `date -d`. Use `printf`, `df -Pk`, `x=$((x+1))` (never `((x++))` — banned under `set -e`, swept by `test_counter_increment.sh`).
- The E2E suite drives interactive scripts via **piped stdin with a fixed line sequence** — any NEW prompt must be gated on `[[ -t 0 ]]` or it breaks E2E. All prompts added in this branch follow that rule.
- DGMGRL-first for all Data Guard configuration; passwords prompted, never stored; step 5 (RMAN duplicate) is NOT restartable.

## Known remaining issues (found, deliberately NOT fixed — good next tasks)

1. **DGMGRL exit codes are meaningless** (`common/dg_functions.sh` `run_dgmgrl*`): scripts end in `EXIT;` so dgmgrl returns 0 even when CREATE CONFIGURATION / `StaticConnectIdentifier` edits failed; every `if ! run_dgmgrl` is a no-op. Fix = output-grepping wrappers (`ORA-|Error|Failed` → nonzero), but that changes behavior for ALL callers (some grep output themselves, e.g. `06:288`) — needs a deliberate pass, possibly a `run_dgmgrl_checked` used only by mutating calls.
2. **`sql/queries/*.sql` lack `WHENEVER SQLERROR EXIT`** — error text can flow into env files/arithmetic as data. A sweep changes exit-code semantics under `set -e` repo-wide; pair with an `is_numeric` guard helper.
3. E2E gaps: CDB E2E (`tests/e2e/run_e2e_test_cdb.sh`) builds a **zero-PDB, symmetric, token-in-path** CDB only. Untested: real PDBs/GUID dirs, asymmetric mounts, the new `_review_path_mappings` interactive path, OMF-primary→Traditional-standby, post-setup PDB creation with apply verification. IMPROVEMENT_PLAN.md items 6.2–6.4 (switchover/observer/CDB E2E) also still open.
4. Low-severity leftovers: `select_config_file` breaks on paths with spaces (parses `ls`); `substitute_dgmgrl_args` sed-replacement unescaped for `|&\`; progress totals off-by-one in most scripts (`[12/11]`); double `init_log` calls orphan `RUNNING` state files; NFS preflight uses ping/showmount (fails on ICMPI-filtered/NFSv4-only servers) + no-op `nointr`; step-number terminology still differs between WALKTHROUGH.md and CLAUDE.md; standby control files both land on one filesystem (no multiplexing prompt); `tr -d ' '` in step 1 mangles paths containing spaces.

## Verification commands

```bash
for f in $(git diff main --name-only | grep '\.sh$'); do bash -n "$f"; done
for t in tests/test_*.sh; do bash "$t"; done          # all 7 must pass
bash ./tests/e2e/run_e2e_test.sh                       # ~20 min, needs the lab env (tests/e2e/config.env)
```

The single most valuable validation still outstanding: **one live E2E run with an intentionally asymmetric standby layout** (different base mount, temp on its own mount, ideally a 1-PDB CDB) — the asymmetric fixes are verified by code trace and unit tests, not by a real RMAN duplicate.
