# DG_SYNC_IMPACT - Synchronous Data Guard Impact Report

`dg_sync_impact.sh` quantifies what synchronous redo transport (SYNC /
FASTSYNC) is costing the primary database: how much commit latency
(`log file sync`) the remote acknowledgment adds, and what that adds up
to across the workload. It is standalone (no `common/`, no `sql/`, no
NFS share) - copy the one file to the primary host and run it.

## Running it

1. **Copy the single file to the PRIMARY database host** (nothing else is
   needed - it has no dependency on the rest of this repo):

   ```bash
   scp dg_sync_impact.sh oracle@primary-host:~/
   ```

2. **Log in as the Oracle software owner and set the environment** so that
   `sqlplus / as sysdba` connects to the primary instance (e.g. via
   `. oraenv` with the primary `ORACLE_SID`). In a CDB, stay in `CDB$ROOT`.

3. **Run it** - no arguments needed for the default report:

   ```bash
   ./dg_sync_impact.sh                          # defaults: ASH last 24h, AWR last 7 days
   ./dg_sync_impact.sh --ash-hours 6 --days 14
   ./dg_sync_impact.sh --baseline-begin '2026-07-01 00:00' --baseline-end '2026-07-08 00:00'
   ./dg_sync_impact.sh --baseline-begin 12000 --baseline-end 12168     # snap-ID form
   ./dg_sync_impact.sh --no-pack                # no Diagnostics Pack license
   ./dg_sync_impact.sh -o /tmp/sync_impact.md
   ./dg_sync_impact.sh --html -o /tmp/sync_impact.html   # self-contained HTML page
   ```

The **report** is written to stdout (and to the `-o` file when given);
**progress and warnings go to stderr**, so `./dg_sync_impact.sh > report.md`
captures a clean report while still showing you what is happening. A run
takes a few seconds; it is read-only against the database (SELECTs,
`dgmgrl SHOW`, and one session-local NLS setting - no DDL, no DML, no
configuration changes), so it is safe on production. Exit codes: `0`
report produced (read the report - warnings live there), `1` fatal
(environment/connection problem, or not a PRIMARY), `2` bad arguments.

`--html` renders the same report as a standalone HTML page (inline CSS,
light/dark aware, no external assets) - the Markdown emitter remains the
single definition of the report and is converted with a built-in
POSIX-awk filter, so both formats always carry identical content.

## Why "log file sync minus the remote wait" is wrong

Since 12c, LGWR does not serialize the local write and the network send.
When a commit is issued:

1. LGWR issues the **local** redo write (`log file parallel write`, call it **L**), and
2. **in parallel**, hands the redo to the NSS process which ships it to the
   SYNC standby and waits for the acknowledgment (`SYNC Remote Write`, call it **R**).

The commit is acknowledged when **both** finish, so the redo-write phase of
a commit lasts `max(L, R)` - not `L + R`. The true cost of synchronous
transport per redo write is therefore

```
overhead = E[max(L, R)] - E[L]
```

and because the *average of a max* is not the *max of the averages*, plain
`V$SYSTEM_EVENT` averages cannot produce this number - only bound it.

With **AFFIRM** (plain SYNC), R additionally includes the standby's SRL disk
write; with **NOAFFIRM** (FASTSYNC, what steps 9/13 of this repo configure),
R is in-memory receipt on the standby. The report's section 1 shows which
applies (`V$ARCHIVE_DEST.TRANSMIT_MODE` + `AFFIRM`).

## The three layers of evidence

**Layer 1 - hard bounds from averages** (`V$SYSTEM_EVENT`, `V$SYSSTAT`,
and their AWR deltas). Regardless of any modeling assumption:

```
max(0, avg R - avg L)  <=  overhead per redo write  <=  avg R
```

**Layer 2 - the refined estimate** (`V$EVENT_HISTOGRAM_MICRO`). The full
distributions of L and R are available in microsecond power-of-2 buckets.
The script normalizes both histograms, takes geometric bucket midpoints
(`bucket_upper / sqrt(2)`, since a bucket covers `(upper/2, upper]`), and
computes `E[max(L,R)]` by cross-joining the two distributions **under an
independence assumption**. This is the headline number. The
`V$REDO_DEST_RESP_HISTOGRAM` per-destination response histogram is printed
alongside as corroboration (it also separates multiple SYNC standbys,
which the event histogram cannot).

**Layer 3 - workload scaling and validation** (Diagnostics Pack):

- *Per commit added latency ~ overhead per write.* Every committer waits on
  one write completion; piggybacked group commits all wait on the same
  write, so the per-commit added latency is the per-write overhead - no
  division by the group-commit ratio.
- *Total added foreground wait* = overhead x `log file sync` wait count,
  expressed per hour, as % of DB time, and as % of log file sync time.
- *AWR trend* (`DBA_HIST_SYSTEM_EVENT` / `DBA_HIST_SYSSTAT` /
  `DBA_HIST_SYS_TIME_MODEL` deltas per snapshot) shows when the tax bites.
  The per-snapshot overhead column uses the **lower bound** estimator -
  AWR's millisecond-resolution histograms are too coarse for the E[max]
  model on a sub-millisecond LAN.
- *Baseline comparison*: with `--baseline-begin/--baseline-end` covering a
  pre-SYNC window, the report compares avg latencies, commit rates, and
  `log file sync` percentile shift (`DBA_HIST_EVENT_HISTOGRAM`), and puts
  the **empirical** per-commit delta next to the **model** estimate. Guards
  warn when the two windows are not comparable (commit rate differs >2x,
  or the *local* write latency also shifted - i.e. storage changed too).
- *ASH attribution* (`V$ACTIVE_SESSION_HISTORY`): who pays - top SQL,
  modules, services, and the hourly profile of `log file sync` weight.

## Reading the report

| Section | What to look at |
|---------|-----------------|
| 1 Configuration | Which destinations are synchronous; AFFIRM vs NOAFFIRM decides what R contains |
| 2 Headline | The refined per-commit estimate with its bounds; s/hour; % of DB time |
| 3 LGWR pipeline | `redo synch time overhead` - the part of log file sync that is scheduling/CPU, **not** transport. If this dominates, fix CPU starvation, not Data Guard |
| 4 Distributions | p50/p90/p99 for lfs, L and R; the E[max] model inputs; per-destination SYNC response histogram |
| 5 AWR trend | Per-snapshot averages; spot the hours where the overhead column spikes |
| 6 Baseline | Empirical before/after delta vs the model estimate - they should roughly agree |
| 7 ASH | Which SQL/services/modules actually sit in `log file sync`, and when |
| 8 Method notes | The assumptions, restated; any collection warnings |

## Caveats

- **Independence assumption**: the E[max] convolution assumes L and R are
  independent. A shared burst (storage and network loaded together) makes
  the estimate optimistic; the Layer-1 bounds do not depend on it.
- **Window mismatch**: micro-histograms are cumulative since instance
  startup; AWR/ASH sections cover their stated windows. Every number is
  labeled with its source.
- **ASH sampling**: 1-second samples estimate total wait *time* fairly but
  under-count short waits - never read sample counts as wait counts.
- **`SYNC Remote Write` missing**: if a SYNC destination is active but the
  event has no waits (version quirk), the refined estimate is skipped and
  the raw `V$REDO_DEST_RESP_HISTOGRAM` is all you get - the bounds still hold.
- **Licensing**: AWR trend, baseline and ASH sections query Diagnostics
  Pack views. `--no-pack` restricts the report to free `V$` views
  (bounds + E[max] model still work - they need no pack).
- **Scope**: single-instance primary. In a CDB, run from the root; AWR
  data is CDB-level.

## Testing

`tests/test_sync_impact.sh` covers the script with a stubbed `sqlplus`
(dispatching on the `-- QTAG:` markers embedded in every query): argument
validation, fatal paths, derived-number correctness, per-section
degradation, `--no-pack`, and the no-SYNC-destination mode.
