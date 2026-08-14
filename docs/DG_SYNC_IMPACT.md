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
   ./dg_sync_impact.sh --auto-baseline          # detect the pre-SYNC baseline from AWR
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
POSIX-awk filter, so both formats always carry identical content. The
HTML adds two purely presentational upgrades on top: the headline
`| Measure | Value |` table renders as a row of KPI cards, and numeric
table columns get proportional inline bars scaled to the column maximum
(so latency spikes and skewed histograms are visible at a glance). A
column only qualifies for bars when every populated cell is a plain
number, at least two are, and its header is not ordinal (`Snap`, `Hour`,
`bucket`, `Dest`, `SQL_ID`, `NET_TIMEOUT`); everything else keeps plain
table cells.

The converter sticks to what AIX 7.2's `/usr/bin/awk` accepts - it seeds
every array in `BEGIN` and keys table cells with a `"row|col"` string
rather than a multi-subscript `arr[i,j]` reference, both of which that
awk otherwise rejects outright with `0602-558 cannot be used as an
array`. Should the conversion still fail on some other vendor awk, the
page is written with the Markdown report embedded verbatim (and a
warning on stderr) instead of ending mid-report.

## Why "log file sync minus the remote wait" is wrong

Since 11g Release 2, LGWR does not serialize the local write and the
network send. Per Oracle's 19c HA guide commit sequence, when a commit is
issued:

1. LGWR **starts the remote write** to the SYNC standby (shipped by the
   NSSn network server; LGWR's wait is `SYNC Remote Write`, call it **R**), then
2. issues the **local** redo write (`log file parallel write`, call it **L**),
3. and waits for **both** to finish.

So the redo-write phase of a commit lasts about `max(L, R)` - not `L + R`
(a small serial remainder - redo preprocessing, I/O status checks, the
foreground post - exists on top and is not attributed to transport). The
same guide explicitly warns that for measuring SYNC impact "the averages
can be very deceiving", which is exactly why this script models the
distributions. The true cost of synchronous transport per redo write is
therefore

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
(`bucket_upper / sqrt(2)`, since a bucket covers `[upper/2, upper)` -
`WAIT_TIME_MICRO` is a documented exclusive upper bound), and
computes `E[max(L,R)]` by cross-joining the two distributions **under an
independence assumption**. This is the headline number. The
`V$REDO_DEST_RESP_HISTOGRAM` per-destination response histogram is printed
alongside (it also separates multiple SYNC standbys, which the event
histogram cannot) - but note its durations are rounded **up** to whole
seconds, so on a fast network every response lands in bucket 1 and the
view can only surface outliers, never corroborate a sub-second estimate.

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
- *Top latency spikes*: the top 10 slowest SYNC transport responses ever
  recorded (`V$REDO_DEST_RESP_HISTOGRAM` non-empty buckets, worst first,
  each with the timestamp of its most recent occurrence - a free V\$ view,
  so this survives `--no-pack`) plus the top 10 AWR snapshots of the
  `--days` window ranked by the lower-bound added-latency-per-commit
  estimate. The micro-histogram percentile table also carries a `max`
  column: the highest non-empty bucket, i.e. the slowest single wait since
  instance startup.
- *Baseline comparison*: with `--baseline-begin/--baseline-end` covering a
  pre-SYNC window, the report compares avg latencies, commit rates, and
  `log file sync` percentile shift (`DBA_HIST_EVENT_HISTOGRAM`), and puts
  the **empirical** per-commit delta next to the **model** estimate. Guards
  warn when the two windows are not comparable (commit rate differs >2x,
  or the *local* write latency also shifted - i.e. storage changed too).
- *ASH attribution* (`V$ACTIVE_SESSION_HISTORY`): who pays - top SQL,
  modules, services, and the hourly profile of `log file sync` weight.

## Auto-detected baseline (`--auto-baseline`)

If you don't know when synchronous transport was enabled, `--auto-baseline`
detects the pre-SYNC window from AWR history instead. Oracle does not
historize the transport configuration (no `DBA_HIST_` view holds
`TRANSMIT_MODE` or the protection mode), but synchronous transport leaves a
reliable behavioral fingerprint: while it is active, LGWR records a
`SYNC Remote Write` wait for essentially every redo write, so the
per-snapshot ratio

```
SYNC Remote Write waits (delta) / redo writes (delta)
```

is ~1 under sync transport and ~0 without it. The script classifies **every
retained snapshot** (not just the `--days` window - the transition usually
predates it): `SYNC` at ratio >= 0.5, `NOSYNC` at ratio <= 0.05, `IDLE` for
near-idle snapshots (fewer than 50 redo writes) or restart artifacts
(negative deltas), `MIXED` in between. The thresholds are env-overridable:
`DG_SI_SYNC_RATIO` (0.5), `DG_SI_NOSYNC_RATIO` (0.05), `DG_SI_MIN_WRITES`
(50). It then takes the **most recent run of at least 2 consecutive
`NOSYNC` snapshots** before the last `SYNC` snapshot as the baseline
(`IDLE`/`MIXED` snapshots break a run - gaps are never silently bridged)
and feeds it into the same comparison machinery as the manual flags. The
report's section 7 states the detected window, the apparent transition
snapshot, and the classification counts.

If every classified snapshot is `SYNC` (the transition predates AWR
retention) or none is (sync transport never observed), the report says so
and the comparison is skipped - the rest of the report is unaffected.

**Caveat - detection is behavioral, not configurational**: a period where a
SYNC destination was *configured* but the standby was *down* classifies as
no-sync, because commits genuinely paid no remote ack then. That makes it a
valid latency baseline, but sanity-check that the detected window makes
sense for your history. `--auto-baseline` is mutually exclusive with
`--baseline-begin`/`--baseline-end` and, like them, requires AWR (it cannot
be combined with `--no-pack`).

## Reading the report

| Section | What to look at |
|---------|-----------------|
| 1 Configuration | Which destinations are synchronous; AFFIRM vs NOAFFIRM decides what R contains |
| 2 Headline | The refined per-commit estimate with its bounds; s/hour; % of DB time |
| 3 LGWR pipeline | `redo synch time overhead` - the part of log file sync that is scheduling/CPU, **not** transport. If this dominates, fix CPU starvation, not Data Guard |
| 4 Distributions | p50/p90/p99 **and max** for lfs, L and R; the E[max] model inputs; per-destination SYNC response histogram (with each bucket's last-occurrence time) |
| 5 AWR trend | Per-snapshot averages; spot the hours where the overhead column spikes |
| 6 Top latency spikes | Top 10 slowest SYNC responses ever recorded (`V$REDO_DEST_RESP_HISTOGRAM`, worst bucket first, with when each last happened) and the top 10 AWR snapshots by estimated added ms/commit |
| 7 Baseline | Empirical before/after delta vs the model estimate - they should roughly agree |
| 8 ASH | Which SQL/services/modules actually sit in `log file sync`, and when |
| 9 Method notes | The assumptions, restated; any collection warnings |

Section 6's two rankings answer "how bad does it get?" from opposite ends:
the response histogram catches **individual** slow acks (a standby restart, a
network stall - real seconds-long spikes, cumulative since the destination
came up), while the AWR ranking catches **sustained** bad intervals inside
the `--days` window (snapshot averages, so a single slow commit is diluted -
see the spike-dilution method note).

## Caveats

- **Independence assumption**: the E[max] convolution assumes L and R are
  independent. A shared burst (storage and network loaded together) makes
  the estimate optimistic; the Layer-1 bounds do not depend on it.
- **Window mismatch**: micro-histograms are cumulative since instance
  startup; AWR/ASH sections cover their stated windows. Every number is
  labeled with its source.
- **ASH sampling**: 1-second samples estimate total wait *time* fairly (when
  counting samples - never sum `TIME_WAITED`, it is biased high) but
  under-count short waits - never read sample counts as wait counts.
- **`redo synch time overhead (usec)`** is not documented by Oracle; its
  interpretation as post/scheduling overhead is community-established and
  consistent with the documented commit sequence, but not an Oracle statement.
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
degradation, `--no-pack`, the no-SYNC-destination mode, and the
`--auto-baseline` scenarios (happy-path window pick, all-SYNC and
no-SYNC-snapshots retention edge cases, flag conflicts, degradation).
