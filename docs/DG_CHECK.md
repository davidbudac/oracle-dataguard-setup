# Local Data Guard Status Commands

The local status flow is now split into two commands that run directly on a DB host, using `sqlplus / as sysdba` locally and DGMGRL-based peer discovery:

- `dg_triage_sid.sh` for fast operator triage
- `dg_diag_sid.sh` for deeper diagnostics

`dg_check_sid.sh` is kept as a deprecated compatibility wrapper. It forwards to `dg_triage_sid.sh`, prints a deprecation warning, and still exits with `0`.

## Quick Start

```bash
# Fast triage - wallet only by default, non-blocking when remote runtime is unavailable
export ORACLE_SID=cdb1
bash dg_triage_sid.sh

# Deep diagnostics - prompts for SYS password if wallet auth fails
bash dg_diag_sid.sh

# Skip remote SQL entirely (local + broker view only)
bash dg_triage_sid.sh -L
bash dg_diag_sid.sh -L

# Force password prompt for remote runtime checks
bash dg_triage_sid.sh -P
bash dg_diag_sid.sh -P

# Disable colored output (for logs/pipes; NO_COLOR is also honored,
# and color is off automatically when stdout is not a terminal)
bash dg_triage_sid.sh --no-color
```

Warning/critical thresholds (FRA %, sequence gaps, lag seconds) are
env-overridable via `DG_FRA_WARN_PCT`, `DG_FRA_CRIT_PCT`, `DG_SEQ_GAP_WARN`,
`DG_SEQ_GAP_CRIT`, `DG_LAG_WARN_SECONDS` -- see
[DG_STATUS.md](DG_STATUS.md#thresholds) for defaults and meaning. A value that
is not a non-negative integer (`80%`) is a usage error (exit `64`).

## Command Roles

### `dg_triage_sid.sh`

Optimized for quick health confirmation:

- leads with top findings
- shows concise primary / standby / broker state
- makes degraded peer visibility explicit
- keeps recent DG events compressed to the newest few lines

Default remote behavior:

1. try wallet authentication
2. if wallet fails, do **not** prompt
3. continue in broker-only degraded mode unless `-P` was specified

Exit codes:

- `0` healthy
- `1` warning or degraded data source
- `2` error (including a local instance that is down — see below)
- `64` usage or preflight failure (unknown flag, `ORACLE_SID`/`ORACLE_HOME`
  unset, malformed threshold variable)

### `dg_diag_sid.sh`

Optimized for deeper investigation:

- keeps the same local collection path and broker discovery
- shows richer runtime detail
- includes more verbose log excerpts
- includes connection provenance and peer-data interpretation

Default remote behavior:

1. try wallet authentication
2. if wallet fails, prompt for SYS password unless `-L`

Exit codes are the same as `dg_triage_sid.sh`.

### `dg_check_sid.sh` (deprecated)

Compatibility behavior:

- prints `DEPRECATED: Use dg_triage_sid.sh` to stderr
- forwards flags unchanged
- always exits `0`

## Local Instance Availability

Before anything else, both commands read `V$DATABASE` locally. If that returns
no role at all — `ORA-01034` (instance not started), `ORA-01109` (not open), a
wrong `ORACLE_SID`, a bad `ORACLE_HOME` — the tool says so explicitly:

```
  Error   Local instance cdb1 is DOWN or not open: ORA-01034: ORACLE not available
  Info    Check: ps -ef | grep ora_pmon_cdb1 ; then 'sqlplus / as sysdba' and STARTUP MOUNT
```

and exits `2`, with a `Local Instance ... DOWN` row in AT A GLANCE. Previously
every field parsed empty, every check was skipped because it was gated on a
non-empty role, and the tool most likely to be run *because* the database is
down reported `WARNING` / exit `1` without ever saying "down".

## What The Scripts Check

Both commands use the same shared collector and grading rules. The difference is presentation depth.

### Primary-side checks

- Database role and open mode
- Protection mode
- Switchover status -- anything other than `TO STANDBY` / `SESSIONS ACTIVE` is a
  **warning**, as in `dg_status.sh`
- Force logging
- Flashback
- `dg_broker_start` -- **only when the command is running on the primary.**
  This parameter is read from the local `V$PARAMETER`; the peer connection
  never queries it. When you run the tools on the *standby*, the primary's
  `DG Broker` row reads `unknown (dg_broker_start is only readable on the local
  instance)` and the standby section shows the standby's own value instead.
  (It used to publish the standby's local value as the primary's, producing a
  "dg_broker_start is FALSE" finding pointed at the wrong host.)
- Services
- Online redo and standby redo counts
- Archive destination 2 status and peer target
- Archive gaps
- FRA usage and thresholds

### Standby-side checks

- Database role and open mode
- Protection mode
- Switchover status
- MRP status and sequence
- `dg_broker_start` (only when running on the standby -- see the primary list)
- Recovery mode -- anything other than real-time apply is a **warning** (`!!`),
  matching both the summary grading and `dg_status.sh`
- Transport lag
- Apply lag
- Apply finish time
- Sequence lag
- Replication state (`Redo Apply` row) -- derived by the same function
  `dg_status.sh` uses (`dg_repl_state` in `common/dg_render_common.sh`). When
  the standby returned no transport lag, apply lag *and* no sequence data the
  row reads `UNKNOWN` and a warning is raised; it is never a green `IN SYNC`
  by default
- Standby redo count
- Archive gaps
- FRA usage and thresholds
- Flashback state

### Broker / FSFO checks

- Configuration presence
- Overall broker status (`ERROR` -> error/exit 2, red; `WARNING` -> warning/exit 1,
  amber -- the same colours and icons `dg_status.sh` uses)
- Member warnings / errors. 19c prints a member's diagnosis on the line *after*
  the member line:

  ```
    cdb1      - Primary database
      Error: ORA-16810: multiple errors or warnings detected for the member
  ```

  The tools remember the last member line and attribute the following
  `Error:` / `Warning:` line to it, so the finding reads
  `Broker member cdb1: ORA-16810: ...` and reaches the summary and the exit
  code. The member line itself is graded by its own diagnosis lines, so it can
  never show a green `OK` directly above its own `Error:`. `Error: 0` is
  DGMGRL's healthy value and is not treated as a finding.
- Fast-Start Failover mode
- FSFO target
- Observer presence / host. `V$DATABASE.FS_FAILOVER_OBSERVER_PRESENT` is the
  authority on whether an observer is actually connected. **FSFO enabled with
  no observer present is an error** (automatic failover will not happen) -- the
  same grade `dg_status.sh` gives it. With FSFO disabled, no observer is
  expected and it is not graded as an error.

## Data Source Modes

The scripts now make the peer data source explicit:

- `remote runtime via wallet`
- `remote runtime via password`
- `broker-only degraded mode`
- `local+broker only (-L)`

When remote runtime SQL is unavailable, peer details fall back to broker data and the command is graded as a warning instead of appearing healthy.

Explanatory `Info` lines (for example "Peer runtime skipped by request (-L)")
are rendered under TOP FINDINGS and in the diagnostics FINAL SUMMARY. They
carry no severity and never affect the exit code -- they exist so that a `-L`
run's red `CHECK` state has a visible reason next to it.

## Recent DG Events

Both commands inspect the local alert log and broker log:

- `dg_triage_sid.sh` shows compressed recent events only
- `dg_diag_sid.sh` shows longer excerpts

The **path that was actually read is always printed** (it used to be hidden
behind `DG_DEBUG=1`), and three outcomes are rendered distinctly:

- `(log path unknown: V$DIAG_INFO 'Diag Trace' returned nothing)`
- `(file not found)` -- the usual symptom of a non-default `diagnostic_dest`
  or an `ORACLE_SID` that does not match the log file name
- `(0 matched - file read, no Data Guard entries)` -- a genuinely quiet log

Previously the last two both printed `(none)`, so "I am looking in the wrong
place" and "nothing happened" were indistinguishable.

## Wallet Usage

These commands work best with wallet-based peer authentication configured via [WALLET_SETUP.md](WALLET_SETUP.md). With a wallet in place, peer runtime queries can use:

```bash
sqlplus /@peer_tns_alias as sysdba
```

The wallet probe connects with the alias **exactly as the broker reports it**
(`/@alias`). (Confirmed on a 19c lab: a credential stored under the alias
connects as `/@alias` but fails with ORA-01017 when the same address is given
as an inline `(DESCRIPTION=...)`.) The external password store matches
credentials on the connect string text, and `common/setup_dg_wallet.sh` stores them under the alias, so
the alias is never rewritten into a descriptor for this connect. The probe is
time-bounded from outside instead (`REMOTE_TEST_TIMEOUT`, default 5 s): the
`timeout` binary when present, otherwise a portable background-and-kill
watchdog (AIX has no `timeout`). Descriptor-level connect timeouts are used
only on the SYS-password path, where there is no stored-credential match to
break.

### Password prompt

`dg_diag_sid.sh` (and `-P`) prompt for the peer SYS password with echo off; Ctrl-C
or a termination signal restores the terminal. The password is sent to
`sqlplus` on stdin after `SET DEFINE OFF`, so a `&` in it is not treated as a
substitution variable. A password containing a double quote (`"`) cannot be
passed in a quoted `CONNECT` and is rejected with a message; the tool then
continues in broker-only mode.

## Standby Redo Log Checker: `dg_check_srl.sh`

A separate local tool that verifies standby redo logs on **both** sides and
prints the DDL needed to fix any side that is missing or undersized. It never
executes DDL.

```bash
export ORACLE_SID=cdb1
bash dg_check_srl.sh              # local + peer via wallet
bash dg_check_srl.sh -p           # prompt for the peer SYS password
bash dg_check_srl.sh -L           # local only
bash dg_check_srl.sh -d /u02/oradata/srl   # override the dir used in generated DDL
```

Rules: each thread needs at least `online_redo_groups + 1` SRL groups, all
at least as large as the largest online redo log (larger is fine; only a
smaller SRL is flagged).

Every peer in `V$DATAGUARD_CONFIG` is checked, each reached via its broker
`DGConnectIdentifier`. If an online redo log size cannot be read, the tool
exits `2` and prints no DDL rather than guessing.

### Thread accounting (`THREAD#=0`)

An SRL added **without** a `THREAD` clause reports `THREAD#=0` until Oracle
binds it on first use. This repo's step 4 created its SRLs that way before
2026-08 (it now assigns `THREAD` explicitly, as does
`sql/commands/add_standby_logfile.sql`), and so does any SRL added by hand
without the clause, so builds from before that change still look like this. Counting SRLs strictly per thread therefore
saw zero on a never-switched primary and demanded DDL that would have created
duplicate groups on an already-compliant database.

The checker now reports those groups in their own `Unassign` column and counts
them toward the requirement:

- **Single enabled thread** — the unassigned pool belongs to that thread.
  N+1 unassigned SRLs at the right size are **COMPLIANT** (exit `0`), and no
  DDL is emitted.
- **Multiple threads (RAC)** — the pool is shared. It is counted toward every
  thread's requirement and the output says so explicitly, because Oracle binds
  each group to whichever thread claims it first. Re-check the distribution
  after a role transition, or add per-thread SRLs explicitly.

The minimum-size check uses the smallest of the thread's own SRLs and the
unassigned pool.

### Exit codes

- `0` -- every checked side has SRLs at the correct count and size
- `1` -- at least one side needs DDL, or a peer exists but could not be checked
- `2` -- argument error, pre-flight failure, or a side that could not be
  evaluated at all (for example `V$THREAD` returned no usable rows). An empty
  thread list used to print `Result: OK` and exit `0` — verifying nothing while
  reporting compliance. It now reports `ERROR - not verified`.

Options that take an argument (`-d` / `--srl-path`) are checked for a missing
value and exit `2` with usage text, rather than aborting on `set -u` with the
exit code that means "DDL needed".

## Relationship to `dg_status.sh`

[`dg_status.sh`](DG_STATUS.md) remains the SSH-based dashboard run from a jump host or any host that can reach both databases over SSH.

The local commands in this document are for running directly on one DB host without SSH to the peer.
