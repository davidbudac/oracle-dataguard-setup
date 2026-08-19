# Implementation plan: `--auto-baseline` for dg_sync_impact.sh

> **Status: implemented and merged** (commit `d3915a7`, 2026-08). This document is a
> historical record of the plan, not open work. The shipped behavior is documented in
> [docs/DG_SYNC_IMPACT.md](docs/DG_SYNC_IMPACT.md) and covered by
> `tests/test_sync_impact.sh`.

Self-contained handoff plan. No conversation context needed; everything an
implementing agent must know is in here plus the referenced files.

## Context

`dg_sync_impact.sh` (repo root, ~1300 lines, standalone bash + inline SQL)
reports what synchronous Data Guard transport (SYNC/FASTSYNC) costs commits
on a PRIMARY. It already supports a **manual** baseline comparison: the user
passes `--baseline-begin/--baseline-end` (dates `'YYYY-MM-DD[ HH24:MI]'` or
AWR snap IDs) marking a period *before* synchronous transport was enabled,
and section 6 of the report compares avg `log file sync`, commit rates and
latency percentiles between that window and the current one.

Goal: add `--auto-baseline`, which **detects** the pre-SYNC period from AWR
history instead of requiring the user to know it. Oracle does not historize
transport configuration (no `DBA_HIST_` view holds `TRANSMIT_MODE` /
protection mode), but there is a reliable fingerprint: while transport is
synchronous, LGWR records a `SYNC Remote Write` wait for essentially every
redo write, so the per-snapshot ratio

    SYNC Remote Write waits (delta) / redo writes (delta)

is ~1 while sync transport is active and ~0 while it is not (ASYNC, deferred
destination, or standby unreachable). Classify each retained AWR snapshot by
that ratio, take the most recent contiguous "not-sync" run as the baseline,
and feed it into the existing baseline machinery unchanged.

Known, accepted caveat (must be disclosed in report + docs): a period where
SYNC was *configured* but the standby was *down* classifies as "not sync".
For the question the baseline answers - "what do commits cost without the
remote ack" - that period genuinely behaves like no-sync, so it is a valid
baseline, but the report must say the window is behavior-derived, not
config-derived.

## Read these before coding

- `dg_sync_impact.sh` - especially: flag defaults + `usage()` + arg parser
  (top ~150 lines), the AWR collection branch (search `QTAG:AWRSNAP`,
  `QTAG:TREND`, `BASELINE_MODE`), `collect_awr_agg()` / `collect_hist_pct()`,
  and the section-6 emission in `emit_report()` (search `## 6. Baseline`).
- `tests/test_sync_impact.sh` - the stubbed-`sqlplus` pattern: the stub
  dispatches on `-- QTAG:<name>` comment markers embedded in every query and
  is steered by `STUB_*` env vars. 97 assertions currently, all must stay
  green.
- `CLAUDE.md` sections "Synchronous Transport Impact Report" and "Testing";
  `docs/DG_SYNC_IMPACT.md`; the tool line in README.md "Operational Tools".

## Hard conventions (enforced by repo sweep tests)

- AIX/portability: `printf` not `echo -e`; no `grep -P`, no `\s`/`\S` in
  grep, no BRE `\|` alternation (use `[|]` or `grep -E`); no `((VAR++))`
  (use `x=$((x+1))`); bash 3.2-safe; POSIX awk only (no gensub).
- Every new SQL query carries a unique `-- QTAG:<NAME>` comment (the test
  stub dispatches on it).
- Collectors are best-effort: `_out=$(run_sql "...") || { _out="";
  degraded "<label>"; }` then filter tagged rows; a failed query degrades
  one report section, never the run.
- Report text goes to stdout via `emit_report()` (Markdown; the `--html`
  mode converts that same emitter, so **only** touch `emit_report()` -
  HTML follows automatically).
- Exit codes: 0 report produced, 1 fatal, 2 bad arguments.

## Design

### CLI

- New flag `--auto-baseline` (no argument). Sets `AUTO_BASELINE="YES"`
  (default `"NO"`, defined next to the other defaults at the top).
- Validation (in the existing arg-validation block, `exit 2` via
  `arg_error`):
  - mutually exclusive with `--baseline-begin`/`--baseline-end`;
  - incompatible with `--no-pack` (it needs AWR), same as manual baseline.
- `usage()` gets one line:
  `--auto-baseline   Detect the pre-SYNC baseline window from AWR history`.

### Classification query (new collector, `-- QTAG:AUTOBASE`)

Scan **all retained snapshots** for this `DBID`/`INSTANCE_NUMBER` (not just
the `--days` window - the transition usually predates it). One row per
snapshot, tag `CLS`:

```sql
-- QTAG:AUTOBASE
WITH sn AS (
  SELECT SNAP_ID, CAST(END_INTERVAL_TIME AS DATE) ET
  FROM DBA_HIST_SNAPSHOT
  WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
),
srw AS (
  SELECT SNAP_ID,
         TOTAL_WAITS - LAG(TOTAL_WAITS) OVER (ORDER BY SNAP_ID) DW
  FROM DBA_HIST_SYSTEM_EVENT
  WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
    AND EVENT_NAME='SYNC Remote Write'
),
rw AS (
  SELECT SNAP_ID,
         VALUE - LAG(VALUE) OVER (ORDER BY SNAP_ID) DV
  FROM DBA_HIST_SYSSTAT
  WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
    AND STAT_NAME='redo writes'
)
SELECT 'CLS|'||sn.SNAP_ID
  ||'|'||TO_CHAR(sn.ET,'YYYY-MM-DD HH24:MI')
  ||'|'||NVL(srw.DW,0)
  ||'|'||NVL(rw.DV,0)
  ||'|'||CASE
       WHEN rw.DV IS NULL OR rw.DV < 50 OR NVL(srw.DW,0) < 0 THEN 'IDLE'
       WHEN NVL(srw.DW,0)/rw.DV >= 0.5  THEN 'SYNC'
       WHEN NVL(srw.DW,0)/rw.DV <= 0.05 THEN 'NOSYNC'
       ELSE 'MIXED'
     END
FROM sn
LEFT JOIN srw ON srw.SNAP_ID = sn.SNAP_ID
LEFT JOIN rw  ON rw.SNAP_ID  = sn.SNAP_ID
ORDER BY sn.SNAP_ID;
```

Notes the implementer must preserve:

- `DBA_HIST_SYSTEM_EVENT` has **no row at all** for snapshots taken before
  the event first occurred on the instance - hence `LEFT JOIN` + `NVL(,0)`.
- Negative deltas (instance restart) and near-idle snapshots (`DV < 50`
  redo writes) are `IDLE` and excluded from both regimes.
- Thresholds 0.5 / 0.05 / 50: define them as script constants near the
  other thresholds so they are override-able via env if desired
  (`DG_SI_SYNC_RATIO`, `DG_SI_NOSYNC_RATIO`, `DG_SI_MIN_WRITES` - optional,
  nice-to-have).

### Window selection (bash/awk on the CLS rows - keep it out of SQL so the
stub can exercise it)

Walk the CLS rows in snap order:

1. Find the **last** snapshot classified `SYNC` (the current regime's end).
   If none exists → warn "no synchronous-transport snapshots in AWR
   retention"; skip baseline (section 6 renders an explanatory note);
   exit 0 overall.
2. Before that regime, find the **most recent maximal run of consecutive
   `NOSYNC` snapshots** (consecutive in snap order; `IDLE`/`MIXED` snaps
   *break* the run - simplest correct rule; do not silently bridge gaps).
   Require run length >= 2. If none → warn "SYNC transport predates AWR
   retention; no baseline found"; skip baseline with note; exit 0.
3. Baseline window = first..last snap of that run. Also capture the first
   `SYNC` snapshot *after* the run (the apparent transition point) for the
   report.

Then reuse the existing machinery exactly as the manual path does: call
`collect_awr_agg BASE_MIN BASE_MAX` and `collect_hist_pct BASE_MIN
BASE_MAX`, and populate the same variables the manual path sets
(`BASEWIN_RAW` with min|max|count|from-time|to-time, `BASEAGG_RAW`,
`BASEHPCT_RAW`). Refactor the small block under `if [[ -n "$BASELINE_MODE"
]]` so manual resolution and auto detection converge on one shared
"collect baseline aggregates" path - do not duplicate it.

### Report changes (section 6 of `emit_report()` only)

When `AUTO_BASELINE=YES` and a window was found, prepend provenance lines:

- "Baseline window auto-detected from AWR: snapshots A-B (N snaps,
  \<from\> .. \<to\>), classified by the per-snapshot ratio of `SYNC Remote
  Write` waits to redo writes."
- "Synchronous transport first observed at snap X (\<time\>)."
- Counts: n SYNC / n NOSYNC / n IDLE-or-MIXED snapshots scanned.
- The disclosure: "Detection is behavioral, not configurational: periods
  where a SYNC destination existed but the standby was unreachable count as
  no-sync - valid for latency comparison, but check the window makes sense."

When detection failed, section 6 renders the specific warning from step 1/2
instead of the generic "No baseline window supplied" text. Existing
comparability warnings (commit-rate >2x, local-write shift) stay untouched.

## Tests (`tests/test_sync_impact.sh`)

Extend the stub `sqlplus` with a `*QTAG:AUTOBASE*` case steered by
`STUB_AUTOBASE`:

- default: emit e.g. snaps 40-49 `NOSYNC`, 50 `MIXED`, 51-90 `SYNC`
  (plausible DW/DV numbers). Expected pick: 40-49.
- `STUB_AUTOBASE=ALLSYNC`: every snap `SYNC` → expect the "predates AWR
  retention" note, exit 0.
- `STUB_AUTOBASE=NOSYNCONLY`: no `SYNC` snaps → expect the "no
  synchronous-transport snapshots" note, exit 0.

The stub's existing `*QTAG:AWRAGG*` case dispatches on the literal
`BETWEEN <min> AND <max>` text in the SQL - add a canned `XAGG` row for
`BETWEEN 40 AND 49` (and `HPCT` for `QTAG:BASEHIST` likewise) so the
auto-detected window produces a deterministic empirical delta to assert.

New test group (follow existing conventions: `PASS=$((PASS + 1))` counters,
`assert_eq`/`assert_contains`, no `set -e`):

1. `--auto-baseline` happy path: exit 0; report contains "auto-detected",
   "snapshots 40-49", the transition snap line, and a computed empirical
   delta value.
2. `--auto-baseline --baseline-begin 50 --baseline-end 90` → exit 2.
3. `--auto-baseline --no-pack` → exit 2.
4. ALLSYNC and NOSYNCONLY scenarios → exit 0 + their notes.
5. Degradation: `STUB_FAIL_QTAG=AUTOBASE` → exit 0, section 6 degraded note,
   "Collection warnings" lists it.

## Docs / registration (all four, repo convention)

- `docs/DG_SYNC_IMPACT.md`: add `--auto-baseline` to the flag examples and a
  short subsection explaining the fingerprint, the thresholds, and the
  standby-down caveat.
- `README.md`: add one example line under "What is synchronous transport
  costing commits?".
- `CLAUDE.md`: add the flag to the tool's flag list (Project Structure line
  and the "Synchronous Transport Impact Report" section) and extend the
  `tests/test_sync_impact.sh` description with the auto-baseline scenarios.

## Verification

1. `bash tests/test_sync_impact.sh` - all assertions green (currently 97;
   will grow).
2. `bash tests/test_grep_portability.sh` and
   `bash tests/test_counter_increment.sh` - repo sweeps must stay green.
3. `/bin/bash -n dg_sync_impact.sh` on macOS (bash 3.2 parse check).
4. Live check (optional but available): the user's lab has a 19c pair whose
   AWR genuinely contains both regimes (standby unreachable until
   2026-08-10, then reinstated + a 20k-commit sync load). Current PRIMARY is
   `cdb1_stby`, SID `cdb1`, on `ol9-19-dg2` = 192.168.56.112, reachable ONLY
   via two-stage SSH through the jump host:

   ```bash
   scp dg_sync_impact.sh db@dbmint:/tmp/ && \
   ssh db@dbmint 'scp -o BatchMode=yes /tmp/dg_sync_impact.sh oracle@192.168.56.112:~/ && \
     ssh -o BatchMode=yes oracle@192.168.56.112 \
     "export ORACLE_SID=cdb1; export ORAENV_ASK=NO; . oraenv >/dev/null 2>&1; \
      bash ~/dg_sync_impact.sh --auto-baseline"'
   ```

   Expect it to auto-pick a pre-2026-08-10 baseline. Strictly read-only on
   that host: the script itself must stay SELECT/`dgmgrl SHOW`-only, and do
   not touch the `dgnonc` database on the same VM. If `dbmint` doesn't
   resolve, the network path is unavailable - skip live validation rather
   than mocking it. (Claude Code note: run these SSH commands with the
   sandbox disabled; the sandbox blocks non-whitelisted hosts with what
   looks like a DNS failure.)

## Definition of done

- All of Verification 1-3 green; script remains a single self-contained
  file; report identical to today when neither baseline flag is used;
  `--html` output correct for the new section text (comes free via the
  shared emitter - just eyeball it once).
- One commit, message style like `f1cc344` ("Add dg_sync_impact.sh: ..."),
  subject e.g. `dg_sync_impact.sh: auto-detect the pre-SYNC baseline
  (--auto-baseline)`, body explaining the fingerprint + caveat.
