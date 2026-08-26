# Adding an FSFO Observer on a Third Host

A standalone side toolkit — **not part of this repo's numbered setup workflow**.
Use it to add a Fast-Start Failover observer, running on a **separate third
host**, to a Data Guard configuration that already exists and already works —
whether it was built by this repo, by hand, or by other tooling.

The scripts have no dependency on the rest of this repository (no
`common/dg_functions.sh`, no NFS share, no `standby_config_*.env`). Script 01
runs on the primary and **generates a self-contained bundle** you copy to the
third host; everything the third host needs is in that bundle.

> Building a *new* Data Guard configuration with this repo? Use the numbered
> workflow instead — step 9 (`primary/09_configure_fsfo.sh`) plus
> `fsfo/observer.sh`, which share the build's `standby_config_*.env`.
> Already have an observer that logs in as **SYS**? That is a different
> problem: see [`../observer_sys_to_sysdg/`](../observer_sys_to_sysdg/).

## Why a third host

The observer's job is to be the tie-breaker. When it sits on one of the two
database hosts it cannot do that job:

| Observer on… | What happens when that host dies |
|---|---|
| the **primary** host | The observer dies with the primary. Nothing is left to initiate the failover it existed for. |
| the **standby** host | It works — until the standby host is the one that fails, and until a network partition between the sites makes "primary unreachable" indistinguishable from "I am the isolated one". |
| a **third** host | Two independent witnesses agree the primary is gone before anything fails over. This is Oracle's recommended placement. |

The third host needs no database and almost no resources — it runs one
`dgmgrl` process. It should sit in a **different failure domain** from both
databases (different rack/AZ/site, ideally on the network path clients use), and
it must reach **both** listeners.

## What's in the kit

| Script | Runs on | Does |
|---|---|---|
| `01_prepare_primary.sh` | **PRIMARY** | Discovers the topology, reports FSFO readiness, creates the dedicated `SYSDG` observer user, optionally enables FSFO, and writes the bundle for the third host. |
| `02_setup_observer_host.sh` | **THIRD host** | Installs the TNS entries, builds the auto-login wallet, configures `sqlnet.ora`, and proves connectivity to **both** databases. |
| `03_observer_ctl.sh` | **THIRD host** | `start` / `stop` / `restart` / `status` / `log` / `boot` (prints a systemd unit, a cron `@reboot` line, and a watchdog). |
| `04_verify_observer.sh` | anywhere | End-state verification, including a check that the observer is *not* on a database host. Exit 0 = verified. |
| `_lib.sh` | — | Shared helpers sourced by the numbered scripts. |

All passwords are prompted at runtime — never accepted via argv, env, or files.
Nothing here changes your protection mode, `LogXptMode`, or redo transport.

## Prerequisites

**On the primary:** `ORACLE_SID`/`ORACLE_HOME` set, `sqlplus / as sysdba` and
`dgmgrl /` working, `dg_broker_start=TRUE`, and a real Data Guard configuration
the broker knows about.

**On the third host:**

* An Oracle **client installation of the Administrator type**, or a full
  database home, at the **same release as the databases**. The Instant Client is
  not enough — it ships neither `dgmgrl` nor `mkstore`.
* TCP reachability to both database listeners.
* An OS user to own the observer (conventionally `oracle`). No `ORACLE_SID`, no
  database, no listener.

**Everywhere:** Flashback Database should be on for both members, or a
fast-start failover leaves you with an old primary that must be rebuilt rather
than reinstated automatically — and the broker may refuse to enable FSFO at all
(`ORA-16693`).

## Procedure

### 1. On the PRIMARY — prepare and generate the bundle

```bash
cd add_observer
./01_prepare_primary.sh --observer-host obs1
```

It walks through, in order:

1. **Pre-flight** — role is `PRIMARY`, `remote_login_passwordfile` is set, the
   broker is started.
2. **Discovery** — both `DB_UNIQUE_NAME`s from `V$DATAGUARD_CONFIG`, hostnames
   from the broker's `HostName` property, and host/port/service by running
   `tnsping` on each member's `DGConnectIdentifier`. That last step matters:
   it reports what the members *actually* use to reach each other, instead of
   guessing a port or assuming the service equals the `DB_UNIQUE_NAME`. Override
   anything it gets wrong with `--primary-host` / `--standby-host` /
   `--port` / `--primary-port` / `--standby-port`.
3. **Readiness** — `SHOW CONFIGURATION`, `VALIDATE DATABASE` on the standby,
   Flashback Database status for both, protection mode, standby redo logs.
   Findings are reported, not silently swallowed.
4. **Observer user** — creates (or verifies) a user with exactly
   `CREATE SESSION` + `SYSDG`, never SYS. CDB-aware: it insists on the `C##`
   prefix, because `dgmgrl` connects at the root. The grant is verified through
   `V$PWFILE_USERS` — administrative privileges never appear in
   `DBA_ROLE_PRIVS`. Idempotent; `--no-user` skips it.
5. **FSFO** — reports the current state. If FSFO is off it prints the exact
   `dgmgrl` commands; `--enable-fsfo` runs them.
6. **Bundle** — writes `./observer_bundle_<PRIMARY_DB_UNIQUE_NAME>/`.

Remember the observer user's password: you type it again on the third host.

#### The FSFO flavour follows your protection mode

The script does **not** change your protection mode — an existing configuration
keeps the transport behaviour it has. It does adapt what it configures:

| Protection mode | What FSFO does | Property set |
|---|---|---|
| `MAXIMUM AVAILABILITY` / `MAXIMUM PROTECTION` | Zero-data-loss automatic failover once the primary has been unreachable for the threshold. | `FastStartFailoverThreshold` (`--threshold`, default 30s) |
| `MAXIMUM PERFORMANCE` | Automatic failover **with possible data loss**, allowed only while the standby's apply lag is inside the limit. | `FastStartFailoverLagLimit` (`--lag-limit`, default 30s) |

If you are in `MAXIMUM PERFORMANCE` and want zero data loss, that is a separate
decision with a real commit-latency cost — raise the mode yourself
(`primary/13_set_max_availability.sh` in this repo does it with validation), then
come back here.

### 2. Copy the bundle to the third host

Script 01 prints the exact command; it looks like:

```bash
scp -r ./observer_bundle_ORCL_PRI obs1:~/
```

The bundle contains `tnsnames_observer.ora`, `observer_env.sh` (discovered
settings, **no passwords**), the three observer-host scripts, and
`RUN_ON_OBSERVER_HOST.md` — a runbook written for whoever operates that host,
with the values already filled in.

### 3. On the THIRD host — TNS, wallet, connectivity

```bash
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/client_1
export PATH=$ORACLE_HOME/bin:$PATH
cd ~/observer_bundle_ORCL_PRI

./02_setup_observer_host.sh
```

It installs the two TNS entries (backing up any existing `tnsnames.ora`), checks
raw TCP reachability of both listeners, `tnsping`s both aliases, builds an
**auto-login wallet** holding the observer user's credentials for both aliases,
points `sqlnet.ora` at it, and then proves the chain end to end:

```
sqlplus /@<primary> as sysdg    ->  must connect and report PRIMARY
sqlplus /@<standby> as sysdg    ->  must connect and report PHYSICAL STANDBY
dgmgrl  /@<primary> "show configuration"
```

Auto-login is what lets the unattended observer run as `/@alias` with **no
password on disk and none in any start script**.

**The standby test is not optional.** The observer connects to the standby to
*complete* a failover; if the standby rejects it, the observer is decorative.
A standby-only `ORA-01017` means the primary's password file has not reached the
standby (12.2+ propagates it automatically only while the standby is receiving
redo). Copy it — the filename carries each side's own `ORACLE_SID`:

```bash
primary$ scp $ORACLE_HOME/dbs/orapw<PRIMARY_SID> standby:$ORACLE_HOME/dbs/orapw<STANDBY_SID>
```

then re-run script 02; it is idempotent.

### 4. Start and verify

```bash
./03_observer_ctl.sh start
./04_verify_observer.sh
```

`start` issues, through the wallet:

```
START OBSERVER <name> IN BACKGROUND
      FILE IS '<dir>/fsfo_<PRIMARY>.dat'
      LOGFILE IS '<dir>/fsfo_<PRIMARY>.log'
      CONNECT IDENTIFIER IS <primary alias>
```

`CONNECT IDENTIFIER IS` is mandatory with `IN BACKGROUND`: the detached observer
opens its own connection instead of inheriting the `dgmgrl` session's. Named
observers need a 12.2+ broker configuration; on an older one the script retries
without the name rather than leaving you with nothing.

Then it polls `V$DATABASE.FS_FAILOVER_OBSERVER_PRESENT` until the *primary*
confirms the observer — a local process is not evidence.

Verification passes when `FS_FAILOVER_OBSERVER_PRESENT = YES` **and**
`FS_FAILOVER_STATUS` is `SYNCHRONIZED` (or `TARGET UNDER LAG LIMIT` in
`MAXIMUM PERFORMANCE` mode). Anything else — `UNSYNCHRONIZED`,
`TARGET OVER LAG LIMIT`, `STALLED` — means no automatic failover would happen
right now, and `04_verify_observer.sh` exits 1.

### 5. Make it survive a reboot

```bash
./03_observer_ctl.sh boot
```

This is the step people skip. A background observer is an ordinary detached
`dgmgrl` process; **nothing in Oracle restarts it**. After a reboot of the third
host the configuration runs on with no observer and no automatic failover, and
usually nobody notices until the day it was needed. `boot` prints a ready-made
systemd unit, a cron `@reboot` line, and a five-minute watchdog that restarts a
dead observer (`03_observer_ctl.sh status` exits 0 only when the primary reports
the observer present, so it is safe to drive a restart from).

Alert on it as well:

```sql
select fs_failover_observer_present from v$database;   -- expect YES
```

## Day-to-day

```bash
./03_observer_ctl.sh status     # broker's view + this host's process
./03_observer_ctl.sh log -f     # follow the observer's own log
./03_observer_ctl.sh restart
./03_observer_ctl.sh stop
```

`dg_status.sh` in this repo also reports observer presence as part of the wider
health dashboard, and treats a missing observer with FSFO enabled as an error.

## What changes for the databases

Nothing about redo transport, protection mode, apply, or your applications.
Adding an observer registers a watcher. Two behavioural consequences are worth
stating plainly:

* **Automatic failover becomes possible.** After the primary has been
  unreachable from *both* the observer and the standby for
  `FastStartFailoverThreshold` seconds, the broker fails over on its own. Budget
  for it: threshold + failover execution + service startup + client reconnect.
* **Losing the observer *and* the standby together stalls the primary.** With
  FSFO enabled, a primary that can reach neither its target standby nor the
  observer stops committing, because it can no longer guarantee the failover
  contract. This is exactly why the observer belongs in a third failure domain —
  and why a dead observer is an alertable condition, not a cosmetic one.

## Rollback

Everything is reversible:

* **Stop the observer**: `./03_observer_ctl.sh stop` (plus removing the systemd
  unit / cron entry). The databases are untouched.
* **Disable FSFO**: `dgmgrl /` → `DISABLE FAST_START FAILOVER;` on the primary.
  Protection mode and transport are unaffected.
* **The observer user**: harmless to leave; `DROP USER <user>;` on the primary
  removes it (the drop replicates, and the password-file entry goes with the
  grant).
* **The third host**: `sqlnet.ora` and `tnsnames.ora` are backed up with
  timestamps before every edit; a replaced wallet is kept as
  `<wallet-dir>.bak.<timestamp>`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `01` dies with "This database is 'PHYSICAL STANDBY', not PRIMARY" | You are on the standby (or the roles were swapped by a switchover). Run it on the current primary. |
| `01` cannot discover the standby hostname | The broker's `HostName` property is empty and `tnsping` could not resolve the `DGConnectIdentifier`. Pass `--standby-host` (and `--standby-port` if non-default). |
| `ENABLE FAST_START FAILOVER` → `ORA-16693` | Flashback Database is off on one or both members. Enable it on both, or accept that a failed-over primary must be rebuilt by hand. |
| `ENABLE FAST_START FAILOVER` → `ORA-16627` | The standby is not synchronized / not a valid target. Fix transport and apply first (`VALIDATE DATABASE`). |
| `02` reports missing `dgmgrl` / `mkstore` | Instant Client on the third host. Install an Administrator-type client (or a database home) at the databases' release. |
| `tnsping` fails on the third host | Wrong `TNS_ADMIN`, or `sqlnet.ora` sets `NAMES.DEFAULT_DOMAIN` — which silently appends a domain to every unqualified alias. Script 02 warns about this; qualify the aliases or drop the setting. |
| `ORA-01017` on the **standby** only | The primary's password file has not reached the standby. Copy `orapw<SID>` manually (see step 3) — the filename uses each side's own `ORACLE_SID`. |
| `ORA-01017` on **both** | Wrong password typed, or the user/grant never landed. Re-run `01_prepare_primary.sh` and check `V$PWFILE_USERS`. |
| `ORA-65096` creating the user | A CDB needs a common user — accept the `C##` prefix script 01 offers. |
| `START OBSERVER` fails on the name | Named observers need a 12.2+ broker configuration; the script already retries unnamed. |
| Observer starts, then `04` says `FS_FAILOVER_STATUS = UNSYNCHRONIZED` | The observer is fine; the *configuration* is not ready to fail over. Fix the redo gap / apply lag. |
| `SHOW OBSERVER` names a host you did not expect | Another observer is registered (an old one on the standby host, or something in cron). Stop it there, then start yours. |
| Observer vanished after a reboot | Nothing restarts it by default. Run `./03_observer_ctl.sh boot`. |

## FAQ

**Is `SYSDG` really enough, including for the failover itself?**
Yes. `SYSDG` exists for exactly this: broker administration, switchover,
failover (including FSFO-initiated), and the startup/shutdown that goes with a
role change. It is not `SYSDBA`, and that is the point.

**Does the primary stall while the observer is down?**
Not on its own. A primary stalls only if it loses the observer **and** the
target standby at the same time.

**Can I run more than one observer?**
Yes, on 12.2+: up to three can be registered per configuration, one of them the
master (`SET MASTEROBSERVER TO <name>`). Run script 02 on each additional host
and give each a distinct `--observer-name`. The observer *user* and wallet
approach are identical.

**Can one host observe several configurations?**
Yes. Wallet credentials are keyed by TNS alias, so one wallet serves many
configurations. Keep one bundle directory per configuration — the observer name,
`.dat` and `.log` files are already namespaced by `DB_UNIQUE_NAME`.

**Do I need to re-run anything after a switchover?**
No. The observer follows the role change; the wallet already holds credentials
for both aliases. That is also why script 02 insists both connections work
before you start anything.
