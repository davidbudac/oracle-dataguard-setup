# Data Guard Status Dashboard

`dg_status.sh` is a single-command health check for an Oracle 19c Data Guard configuration. It connects to both the primary and standby databases over SSH, queries key V$ views and DGMGRL, and prints a colour-coded dashboard that highlights issues at a glance.

## Quick Start

```bash
# Uses $ORACLE_SID (or auto-detects from running pmon)
bash dg_status.sh

# Explicit SID (primary), and the standby's when several instances run there
bash dg_status.sh -s cdb1
bash dg_status.sh -s cdb1 --standby-sid cdb1_stby

# Custom SSH config
bash dg_status.sh -c /path/to/config.env

# Disable colored output (for logs/pipes; NO_COLOR is also honored,
# and color is off automatically when stdout is not a terminal)
bash dg_status.sh --no-color
```

## What It Checks

### Primary Database

| Check | Source | OK | Warning | Error |
|---|---|---|---|---|
| Role | `V$DATABASE.DATABASE_ROLE` | PRIMARY | - | Anything else |
| Open Mode | `V$DATABASE.OPEN_MODE` | READ WRITE | - | Anything else |
| Protection Mode | `V$DATABASE.PROTECTION_MODE` | _(displayed, not graded)_ | | |
| Switchover Status | `V$DATABASE.SWITCHOVER_STATUS` | TO STANDBY / SESSIONS ACTIVE | Anything else | - |
| Force Logging | `V$DATABASE.FORCE_LOGGING` | YES | - | NO |
| Flashback | `V$DATABASE.FLASHBACK_ON` | YES | NO | - |
| DG Broker | `V$PARAMETER (dg_broker_start)` | TRUE | - | FALSE |
| Running Services | `V$ACTIVE_SERVICES` | _(displayed, not graded)_ | | |
| Online Redo Logs | `V$LOG` | _(displayed, not graded)_ | | |
| Standby Redo Logs | `V$STANDBY_LOG` | Count > 0 | NONE | - |
| Archive Dest 2 | `V$ARCHIVE_DEST` | VALID | - | ERROR (with ORA message) |
| Archive Gaps | `V$ARCHIVE_GAP` | 0 | - | > 0 |
| FRA Usage | `V$RECOVERY_FILE_DEST` | < 80% | 80-89% | >= 90% |

### Standby Database

| Check | Source | OK | Warning | Error |
|---|---|---|---|---|
| Role | `V$DATABASE.DATABASE_ROLE` | PHYSICAL STANDBY | - | Anything else |
| Open Mode | `V$DATABASE.OPEN_MODE` | MOUNTED / READ ONLY | Anything else | - |
| Protection Mode | `V$DATABASE.PROTECTION_MODE` | _(displayed, not graded)_ | | |
| Switchover Status | `V$DATABASE.SWITCHOVER_STATUS` | NOT ALLOWED / SWITCHOVER PENDING | Anything else (`!!` icon only; not counted in the summary or exit code) | - |
| Flashback | `V$DATABASE.FLASHBACK_ON` | YES | NO | - |
| DG Broker | `V$PARAMETER (dg_broker_start)` | TRUE | - | FALSE |
| Running Services | `V$ACTIVE_SERVICES` | _(displayed, not graded)_ | | |
| MRP Status | `V$MANAGED_STANDBY (MRP0)` | APPLYING_LOG / WAIT_FOR_LOG | - | Not running / other |
| Transport Lag | `V$DATAGUARD_STATS` | <= `DG_LAG_WARN_SECONDS` (60 s) | Above that | - |
| Apply Lag | `V$DATAGUARD_STATS` | <= `DG_LAG_WARN_SECONDS` (60 s) | Above that | - |
| Sequences | `V$ARCHIVED_LOG` (applied = `YES`/`IN-MEMORY`, floor MRP0 `SEQUENCE#-1`) | Lag <= 1 | Lag 2-5 | Lag > 5 |
| Replication state (summary row) | derived | IN SYNC | LAGGING / BEHIND / **UNKNOWN** | BEHIND (> `DG_SEQ_GAP_CRIT`) |
| Standby Redo Logs | `V$STANDBY_LOG` | Count > 0 | - | NONE |
| Archive Gaps | `V$ARCHIVE_GAP` | 0 | - | > 0 |
| FRA Usage | `V$RECOVERY_FILE_DEST` | < 80% | 80-89% | >= 90% |

### Data Guard Broker

| Check | Source | OK | Warning | Error |
|---|---|---|---|---|
| Configuration | `SHOW CONFIGURATION` | Exists | - | ORA-16532 (not configured) |
| Overall Status | `SHOW CONFIGURATION` | SUCCESS | WARNING | ERROR / anything else |
| Per-member status | `SHOW CONFIGURATION` | No errors | `Warning:` line under the member | `Error:` line under the member |
| ORA errors | `SHOW CONFIGURATION` | _(displayed in red and attributed to the member)_ | | |
| Fast-Start Failover | `SHOW FAST_START FAILOVER` | Enabled (with target/observer) | Disabled | - |
| Observer present | `V$DATABASE.FS_FAILOVER_OBSERVER_PRESENT` | YES (when FSFO enabled) | - | FSFO enabled but no observer connected |

**Broker member diagnosis (19c line layout).** DGMGRL does not put a member's
diagnosis on the member line; it prints it on the line below:

```
  cdb1      - Primary database
    Error: ORA-16810: multiple errors or warnings detected for the member

    cdb1_stby - Physical standby database
      Error: ORA-12154: TNS:could not resolve the connect identifier specified
```

The dashboard tracks the most recent member line and attributes any following
`Error:` / `Warning:` line to it, so both the member line's icon and the final
summary reflect the real state (`Broker member cdb1_stby: ORA-12154: ...`).
`Error: 0` — DGMGRL's healthy value — is deliberately not treated as a finding.

**Observer liveness.** `SHOW FAST_START FAILOVER` only reports the *configured*
observer; `V$DATABASE.FS_FAILOVER_OBSERVER_PRESENT` is what says whether one is
actually connected. FSFO enabled with no observer present means automatic
failover will not happen, and is graded as an **error** — the same grade
`dg_triage_sid.sh` / `dg_diag_sid.sh` give it.

## Prerequisites

- **SSH access** to both primary and standby database hosts, either directly or via a jump host
- **Oracle OS authentication** (`sqlplus / as sysdba`) working on both hosts
- **DG Broker** running (`dg_broker_start = TRUE`)
- A **config file** providing SSH connection details (defaults to `tests/e2e/config.env`)

## Config File

The script uses the same config format as the E2E test suite. Required variables:

```bash
# Jump host. May be left empty to connect to the DB hosts directly; when set
# it is skipped automatically if this machine IS the jump host (compared as a
# whole short or fully-qualified name, so "jump" does not match "jump02").
JUMP_HOST="bastion"
JUMP_USER="db"
JUMP_SSH_PORT="22"

# Primary DB host (reachable from jump host)
PRIMARY_HOST="localhost"
PRIMARY_SSH_PORT="2201"
PRIMARY_ORACLE_HOSTNAME="primary-host"    # Display name

# Standby DB host (reachable from jump host)
STANDBY_HOST="localhost"
STANDBY_SSH_PORT="2202"
STANDBY_ORACLE_HOSTNAME="standby-host"   # Display name

# SSH to DB hosts
SSH_USER="oracle"
SSH_KEY=""       # Empty = default key
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

# Oracle environment (same on both hosts)
ORACLE_HOME="/u01/app/oracle/product/19.0.0/dbhome_1"
ORACLE_BASE="/u01/app/oracle"
```

## SID Resolution

The Oracle SID is resolved in this order:

1. **`-s` / `--sid` flag** -- explicit override
2. **`$ORACLE_SID` environment variable** -- uses whatever is set in your shell
3. **Auto-detect** -- finds the running `ora_pmon_<SID>` process on the primary host

The standby SID is taken from `--standby-sid` when given, otherwise
auto-detected from its own pmon process (it may differ from the primary SID).

**Several instances on one host.** With more than one `ora_pmon_*` process (ASM
excluded) the first one used to be picked silently. Now:

- on the **standby**, each candidate is asked for its `DB_NAME` and the one that
  equals the primary's `DB_NAME` (a physical standby shares it) is used; no
  warning is needed when that decides;
- when it cannot decide, or on the **primary** (nothing to match against), the
  first candidate is used **and a warning is raised** naming all candidates and
  the flag to use (`-s` / `--standby-sid`).

Auto-detection is deliberately paranoid about what it parses. The remote side runs

```
ps -ef | grep '[o]ra_pmon_' | grep -v '+ASM' | sed 's/^/DG_PMON|/'
```

and the local side keeps only `DG_PMON|`-marked lines, with SSH's stderr **not**
merged into that stream. Anything the login shell prints on its own (an
`/etc/motd` banner, a `Last login:` line, a security notice that happens to
mention `ora_pmon_`) is therefore never mistaken for a process line. The SID
itself is extracted with an anchored expression — `ora_pmon_<SID>` must be the
last token on the line and `<SID>` must match `[A-Za-z][A-Za-z0-9_$]*` — so
prose can never be turned into a "SID". See `tests/test_sid_detection.sh`.

## Exit Codes

Monitoring-friendly, matching `dg_triage_sid.sh` / `dg_diag_sid.sh`:

- `0` -- healthy (no errors, no warnings)
- `1` -- warnings only
- `2` -- one or more errors (including an unreachable host, a primary with no running instance, or a remote collection or discovery call that timed out)
- `3` -- **usage / pre-flight error**: unknown flag, an option missing its
  argument, config file not found, config file missing a required setting, a
  SID that fails validation, a malformed threshold or `DG_REMOTE_TIMEOUT`
  value, or no usable temporary directory. Nothing was checked.

This lets cron/monitoring wrappers alert on the exit status instead of scraping
the text output. `3` is separate from `1`/`2` on purpose: a typo in the command
line must not be reported as a Data Guard finding.

## Reporting Rules Worth Knowing

- **Replication state is never guessed.** With the standby unreachable, or when
  it returns no transport lag, apply lag *and* no sequence data, the `Redo Apply`
  summary row reads `UNKNOWN` (amber) rather than falling through to a green
  `IN SYNC`. When there is genuinely no data and the host *is* reachable, a
  warning is recorded too.
- **Broker `WARNING` is a warning**, not an error — exit `1`, amber in the final
  summary. `ERROR` (or any other non-`SUCCESS` value) is exit `2`. This matches
  how `dg_triage_sid.sh` / `dg_diag_sid.sh` grade the same broker state.
- **Log sections always name the file they read.** Each alert/broker log block
  prints the full path it inspected, and distinguishes three outcomes:
  the path could not be determined (`V$DIAG_INFO` returned nothing),
  `(file not found: <path>)`, and `(0 matched - file read, no Data Guard
  entries)`. A missing **alert** log raises a warning (a running instance must
  have one); a missing **broker** log does not, since it legitimately does not
  exist until the broker has started.
- **SSH noise is not a finding.** DGMGRL output is read without ssh's stderr
  (`Warning: Permanently added ...`, login banners) and only from the
  `Configuration -` line on, so it can no longer count as a broker warning.
- **Remote execution is time-bounded, discovery included.** All collection
  jobs run in parallel under a watchdog: after `DG_REMOTE_TIMEOUT` seconds
  (default `120`) whatever is still running is killed (including the ssh
  child), its partial output is discarded, and an **error** naming the host and
  the cut-off jobs is recorded - the run ends with exit `2`, never a silent
  pass. The calls that run *before* the collection - the ssh reachability probe
  on each host, the `ora_pmon_` scan, and (with several instances on the
  standby) the remote `sqlplus` `DB_NAME` query per candidate SID - run under
  the same kind of tree-killing watchdog, each bounded by `DG_REMOTE_TIMEOUT`
  (a hung `sqlplus` on a healthy ssh connection is not caught by ssh
  keepalives). Discovery as a whole has an overall budget of
  `2 x DG_REMOTE_TIMEOUT`, and no further call is sent to a host after its
  first timeout, so a typical hang costs one bound per host. Worst case for a
  whole run: about `3 x DG_REMOTE_TIMEOUT` (discovery budget plus collection).
  A discovery timeout is an **error** (exit `2`, message `Discovery on <side>
  <host> timed out after Ns (<what>)`): a timed-out probe or standby pmon scan
  leaves that side uncollected (`UNREACHABLE (SSH probe timed out)` /
  `UNREACHABLE (discovery timed out)`), a timed-out primary pmon scan stops the
  run with exit `2`, and a timed-out `DB_NAME` query falls back to the first
  standby SID with the usual "pass `--standby-sid`" warning. ssh itself also
  gets `ServerAliveInterval=15` / `ServerAliveCountMax=3` /
  `ConnectTimeout=15` as defaults (appended after `SSH_OPTS`, so values set
  there win). Killing the local ssh does not guarantee the remote `sqlplus`
  dies at once: with no tty it ends when it next writes or when the session is
  reaped on the host.
- **Same grading as the local tools.** The `Redo Apply` state, broker colours
  and the primary/standby switchover, flashback and `dg_broker_start` checks
  are shared with / matched to `dg_triage_sid.sh` and `dg_diag_sid.sh`.

## Thresholds

The warning/critical cutoffs are env-overridable (defaults shown):

| Variable | Default | Meaning |
|---|---|---|
| `DG_FRA_WARN_PCT` | `80` | FRA usage % that triggers a warning |
| `DG_FRA_CRIT_PCT` | `90` | FRA usage % that triggers an error |
| `DG_SEQ_GAP_WARN` | `1` | Archived-sequence lag (sequences) above which to warn |
| `DG_SEQ_GAP_CRIT` | `5` | Archived-sequence lag above which to flag an error |
| `DG_LAG_WARN_SECONDS` | `60` | Transport/apply lag (seconds, parsed from `+DD HH:MM:SS`) above which to warn |

Example: `DG_FRA_WARN_PCT=70 DG_LAG_WARN_SECONDS=30 bash dg_status.sh`

Each value must be a non-negative integer. `80%` or `abc` is rejected up front
(exit `3` for `dg_status.sh`, `64` for the local tools) instead of making the
checks silently always or never fire.

Other environment variable: `DG_REMOTE_TIMEOUT` (default `120`) -- seconds
before a hung remote job or discovery call is killed and reported (see above).

FRA sizes are produced with an explicit `NLS_NUMERIC_CHARACTERS` in the SQL, so
a comma-decimal session `NLS_LANG` cannot turn `0.4` into `0,4`; the values are
also validated as numeric before the percentage is computed.

These same variables are honored by `dg_triage_sid.sh` and `dg_diag_sid.sh` (shared via `common/dg_render_common.sh`).

## How It Works

The script runs all SSH connections in parallel (up to 8 concurrent sessions: 3 on the primary for SQL/DGMGRL, 1 on the standby for SQL, and the alert-log and broker-log reads on each side) to minimise wall-clock time. The remote shell gets `ORACLE_HOME`, `ORACLE_BASE`, `ORACLE_SID`, `PATH` and `LIBPATH` (AIX) exported explicitly, since a non-login ssh skips `.profile`:

1. **Primary SQL** -- single `sqlplus` session querying `V$DATABASE`, `V$PARAMETER`, `V$LOG`, `V$STANDBY_LOG`, `V$ARCHIVE_GAP`, `V$ARCHIVE_DEST`, `V$RECOVERY_FILE_DEST`, `V$ACTIVE_SERVICES`
2. **Primary DGMGRL** -- `SHOW CONFIGURATION` and `SHOW FAST_START FAILOVER`
3. **Standby SQL** -- single `sqlplus` session querying `V$DATABASE`, `V$PARAMETER`, `V$MANAGED_STANDBY`, `V$DATAGUARD_STATS`, `V$ARCHIVE_GAP`, `V$ARCHIVED_LOG`, `V$STANDBY_LOG`, `V$RECOVERY_FILE_DEST`, `V$ACTIVE_SERVICES`

Results are parsed and displayed with colour-coded status indicators:
- **OK** (green) -- check passed
- **!!** (yellow) -- warning, review recommended
- **XX** (red) -- error, action needed

## Example Output

```
 Data Guard Status Dashboard  2026-04-02 12:53:09
 Primary: poug-dg1 (SID: cdb1)  |  Standby: poug-dg2 (SID: cdb1)

 PRIMARY DATABASE  (poug-dg1 / cdb1)
 ────────────────────────────────────────────────────────────
  Role                     PRIMARY                              OK
  Open Mode                READ WRITE                           OK
  Protection Mode          MAXIMUM AVAILABILITY
  Switchover Status        TO STANDBY                           OK
  Force Logging            YES                                  OK
  Flashback                YES                                  OK
  DG Broker                TRUE                                 OK
  Running Services         CDB1, MY_APP_SERVICE
  Online Redo Logs         3 groups (150 MB total)
  Standby Redo Logs        4 groups                             OK
  Archive Dest 2 (Standby) VALID                                OK
  FRA Usage                0.4/20 GB effective (2%), reclaimable 13.7 GB OK
  FRA Location             /u01/app/oracle/fast_recovery_area (316 files)

 STANDBY DATABASE  (poug-dg2 / cdb1_stby)
 ────────────────────────────────────────────────────────────
  Role                     PHYSICAL STANDBY                     OK
  Open Mode                MOUNTED                              OK
  Protection Mode          MAXIMUM AVAILABILITY
  Switchover Status        NOT ALLOWED                          OK
  Flashback                YES                                  OK
  DG Broker                TRUE                                 OK
  Running Services         CDB1_STBY
  MRP Status               APPLYING_LOG (seq# 1295)             OK
  Transport Lag            none                                 OK
  Apply Lag                none                                 OK
  Sequences                applied=1294  received=1294          OK
  Standby Redo Logs        4 groups                             OK
  FRA Usage                0.0/20 GB effective (0%), reclaimable .5 GB OK
  FRA Location             /u01/app/oracle/fast_recovery_area (12 files)

 DATA GUARD BROKER
 ────────────────────────────────────────────────────────────
  Configuration            my_dg_config
  Overall Status           SUCCESS                              OK
  Fast-Start Failover      Disabled                             disabled

 ────────────────────────────────────────────────────────────
  HEALTHY  No issues detected
```
