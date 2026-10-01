# Converting an FSFO Observer from SYS to a Dedicated SYSDG User

A standalone side toolkit — **not part of this repo's numbered setup workflow**.
Use it on existing Data Guard configurations (built by hand or by other tooling)
where the Fast-Start Failover observer still authenticates as **SYS**, to move it
to a dedicated user holding only **SYSDG + CREATE SESSION**.

The scripts have no dependency on the rest of this repository (no
`common/dg_functions.sh`, no NFS share, no `standby_config_*.env`) — copy this
one directory to the hosts involved and run.

## Why bother

| Running the observer as SYS | Dedicated SYSDG user |
|---|---|
| Observer breaks every time the SYS password rotates | SYS password can rotate (or the account be locked for remote use) freely |
| SYS = full SYSDBA power on both databases, held by a long-lived unattended process | SYSDG is the administrative privilege *designed* for Data Guard operations — it can manage the broker, switchover and failover, and little else |
| SYS credentials sit in a wallet (or worse, in a start script) on the observer host | Compromise of the observer host yields a DG-scoped account, not SYS |
| Audit trail shows "SYS did a failover" | Audit trail shows the observer account did it |

Oracle's own recommendation since 12c is to run the observer with SYSDG.
(This repo's normal workflow — step 9 + `fsfo/observer.sh` — already does this
for new builds; this kit retrofits the same shape onto existing ones.)

## What's in the kit

| Script | Runs on | Does |
|---|---|---|
| `01_create_sysdg_user.sh` | **PRIMARY** | Creates/verifies the dedicated user with exactly `CREATE SESSION` + `SYSDG` (CDB-aware: auto-prefixes `C##`). Idempotent. Checks the user's `PASSWORD_LIFE_TIME` (see below). |
| `02_switch_observer_credentials.sh` | **OBSERVER host** | Replaces SYS credentials in the existing wallet — or creates a wallet if the observer used `sys/password@alias` directly — tests both databases with the new user, then (optionally) restarts the observer under the new identity. |
| `03_verify_conversion.sh` | anywhere | `SHOW CONFIGURATION` / `SHOW FAST_START FAILOVER` / `SHOW OBSERVER` + `V$DATABASE` observer columns + `V$PWFILE_USERS`. Exit 0 = observer present. |
| `_lib.sh` | — | Shared helpers sourced by the three scripts. |

All passwords are prompted at runtime — never accepted via argv, env, or files,
and never placed on a process argv either (`mkstore -createCredential` is fed the
credential password and the wallet password over stdin).
A password may contain `&` (SQL*Plus substitution is switched off); a double
quote is rejected, because the password is embedded as `IDENTIFIED BY "..."`.

## Before you start: know how your observer authenticates today

On the observer host:

```bash
ps -eo args | grep -i dgmgrl | grep -iv grep
```

- `dgmgrl /@some_alias START OBSERVER` → **Case A: wallet.** The wallet most
  likely holds SYS credentials; find it via `WALLET_LOCATION` in
  `$TNS_ADMIN/sqlnet.ora` and inspect with
  `mkstore -wrl <dir> -listCredential`.
- `dgmgrl sys/•••@some_alias ...`, or a nohup/cron/systemd wrapper containing
  the SYS password → **Case B: no wallet.** Script 02 creates one.

Script 02 handles both cases automatically. Also note which host the broker
believes runs the observer:

```bash
dgmgrl / "show observer"
```

## Conversion procedure

### 1. On the PRIMARY — create the SYSDG user

```bash
./01_create_sysdg_user.sh                  # prompts; default dg_observer / c##dg_observer
./01_create_sysdg_user.sh -u dg_observer   # explicit name
```

Safe to run at any time: it touches no observer, no broker property, no
transport. It verifies the grant landed via `V$PWFILE_USERS` (administrative
privileges appear there, never in `DBA_ROLE_PRIVS`).

**Password expiry.** A new user lands in the `DEFAULT` profile, whose
`PASSWORD_LIFE_TIME` is 180 days on a stock database. When the observer's
password expires its logins fail with `ORA-28001` and Fast-Start Failover stops
working without an obvious alarm. Script 01 reports the user's effective
`PASSWORD_LIFE_TIME` and, if it is not `UNLIMITED`, prints the fix and (on a
terminal, default **No**) offers to create `DG_OBSERVER_PROFILE`
(`C##DG_OBSERVER_PROFILE` on a CDB, `CONTAINER = ALL`) with an unlimited life
time and assign it to the user. It never changes a profile without asking; if you
keep the stock profile, schedule a password rotation *and* a wallet update.

**Standby password file.** The observer must also log into the *standby* (that
is how it completes a failover), and `AS SYSDG` logins on a mounted standby are
authenticated purely against its password file. On 12.2+ a physical standby
that is receiving redo picks up primary password-file changes automatically.
Script 02's standby connection test proves whether it worked; if it didn't
(long-disconnected standby, older version):

```bash
# names use each side's ORACLE_SID, which may differ
primary$ scp $ORACLE_HOME/dbs/orapw<PRIMARY_SID>  standby:$ORACLE_HOME/dbs/orapw<STANDBY_SID>
```

### 2. On the OBSERVER host — switch credentials and restart

```bash
./02_switch_observer_credentials.sh -u C##DG_OBSERVER \
      --primary-tns prim --standby-tns stby
```

What it does, in order:

1. Finds the wallet (from `sqlnet.ora`'s `WALLET_LOCATION`, or `-w DIR`). A
   `-w DIR` that differs from `sqlnet.ora`'s `WALLET_LOCATION` is **refused**:
   sqlplus/dgmgrl read the `sqlnet.ora` wallet, so editing another one would
   change nothing the observer uses (and the connection test could still pass on
   the old SYS entry, since SYS can log in `AS SYSDG`).
2. **Wallet exists** → lists its credentials (you'll see the SYS entries), copies
   the wallet to `<wallet-dir>.bak.<YYYYmmddHHMMSS>` **before the first change**,
   and replaces the entries with the new user for both TNS aliases. Any failure
   from then on prints the backup path and the exact restore command. A wallet
   that has `ewallet.p12` but no `cwallet.sso` also gets auto-login enabled
   (`mkstore -createSSO`), otherwise the unattended observer could not open it.
   Afterwards the wallet is re-listed: both aliases must map to the new user, and
   any credential for **SYS** still present under another key (an FQDN-qualified
   alias, the broker's `DGConnectIdentifier`) is reported loudly — the script
   only converts the two aliases you typed, and finishes with
   "CREDENTIAL SWITCH FINISHED - WITH WARNINGS" instead of "COMPLETE".
   **Wallet password lost?** It offers to move the old wallet to a timestamped
   `.bak` and build a fresh one (`--rebuild-wallet` forces this path).
   **Auto-login-only wallet** (`cwallet.sso` without `ewallet.p12`)? Rebuild is
   automatic: mkstore cannot verify a password against such a wallet, so its
   edits exit 0 yet produce credentials sqlplus rejects with ORA-01017.
   **No wallet** → creates an auto-login wallet and adds
   `WALLET_LOCATION` + `SQLNET.WALLET_OVERRIDE = TRUE` to `sqlnet.ora`
   (backing it up first; it matches `WALLET_LOCATION` anchored, so a TDE
   `ENCRYPTION_WALLET_LOCATION` entry is never mistaken for it).
3. Tests `sqlplus /@alias as sysdg` against **both** databases. A standby
   failure (ORA-01017) aborts with the password-file fix above — an observer
   whose credentials the standby rejects cannot complete a failover, so
   restarting it in that state would be strictly worse than doing nothing.
   The test also requires `SYS_CONTEXT('USERENV','AUTHENTICATED_IDENTITY')` to
   equal the new user (an `AS SYSDG` session reports `USER` = `SYSDG` whichever
   user logged in, so only this value proves the new credential was used); SYS or
   any other value fails it.
4. Tests `dgmgrl /@primary "show configuration"`, then reads each member's broker
   `DGConnectIdentifier` — the string the observer actually resolves and looks up
   in the wallet — and checks that the wallet maps it to the new user and that a
   connection through it works. A mismatch (typically an FQDN or easy-connect
   identifier different from the typed alias) is warned about, and the restart
   needs an explicit confirmation; re-run with that identifier as
   `--standby-tns` to fix it.
5. Offers to `STOP OBSERVER` + `START OBSERVER IN BACKGROUND FILE IS ...
   LOGFILE IS ...` (files under `--observer-dir`, default `~/fsfo_observer`).
   Decline (or pass `--no-restart`) to get the exact commands printed instead.
   `dgmgrl` exits 0 even when `START OBSERVER` fails, so the output is parsed
   (`ORA-`/`DGM-` codes outside `Warning:` lines, `Error: N`, `Failed.`) and
   `FS_FAILOVER_OBSERVER_PRESENT` is polled for up to 60 seconds. If no observer
   is present at the end the script says so plainly — the old one is already
   stopped — prints the manual start command and **exits 1**.

**The restart gap.** Between STOP and START (seconds) there is no observer: no
automatic failover can trigger, and the primary keeps running normally. The
only theoretical exposure is a primary failure inside that window, which would
then need a manual failover — exactly as it would with no FSFO. If even that
gap is unacceptable, see "Zero-gap variant" below.

**Clean up the old starter.** If the observer used to be resurrected by a cron
entry, rc script, or systemd unit containing `sys/<password>@...`, update it to
the wallet form (`dgmgrl /@alias "START OBSERVER ..."`), or the SYS observer
comes back on the next reboot.

### 3. Verify

```bash
# on the observer host (wallet auth):
./03_verify_conversion.sh --tns prim
# or on a DB host (OS auth):
./03_verify_conversion.sh
```

Expect: healthy `SHOW CONFIGURATION`, `FS_FAILOVER_OBSERVER_PRESENT=YES`, the
expected host in `SHOW OBSERVER`, and the new user with `SYSDG=TRUE` in
`V$PWFILE_USERS`. Finally, confirm the *process* identity on the observer host:

```bash
ps -eo args | grep -i dgmgrl | grep -iv grep     # must show /@alias, not sys/
```

### 4. Afterwards (optional, recommended)

With no observer depending on SYS anymore, you can rotate the SYS password
without coordination — the observer no longer cares. If you also want to lock
SYS against remote logins entirely, the pattern is: rotate the password,
`ALTER USER SYS ACCOUNT LOCK`, and propagate the refreshed password file to the
standby (transport fails with ORA-16191 until the copies match).

## Zero-gap variant (no observer downtime)

12.2+ broker supports multiple registered observers (one master). Instead of
stop-then-start:

1. Run script 02 with `--no-restart` (wallet gets the new credentials).
2. `dgmgrl /@prim "START OBSERVER obs_sysdg IN BACKGROUND FILE IS ... LOGFILE IS ... CONNECT IDENTIFIER IS prim"`
   — a *second* observer, now authenticated as the SYSDG user
   (`CONNECT IDENTIFIER IS` is mandatory with `IN BACKGROUND`).
3. Wait for it to appear in `SHOW OBSERVER`, then stop the old SYS one:
   `dgmgrl /@prim "STOP OBSERVER <old_observer_name>"` (names are listed by
   `SHOW OBSERVER`); make it master first with
   `SET MASTEROBSERVER TO obs_sysdg` if needed.

## Rollback

Everything the kit changes is reversible and backed up:

- **Wallet**: before an in-place edit the wallet is copied to
  `<wallet-dir>.bak.<YYYYmmddHHMMSS>`; a rebuild moves the old wallet there
  instead. The script prints the exact restore command on any failure
  (`rm -rf <wallet-dir> && cp -p -R <backup> <wallet-dir>`, or `mv` after a
  rebuild). Restore it and restart the observer.
- **sqlnet.ora**: timestamped `.bak` copy next to the original.
- **The SYSDG user**: harmless to leave; `DROP USER <user>;` on the primary to
  remove (the drop replicates to the standby, and the password-file entry
  disappears with the grant).
- The observer itself can always be restarted the old way as long as you still
  know the SYS password.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `ORA-01017` connecting to the **standby** only | Primary password-file change hasn't reached the standby. Copy `orapw<SID>` manually (see step 1) — mind the differing `ORACLE_SID`s in the filename. |
| `ORA-01017` on **both** | Wrong password in the wallet, or the grant didn't land — re-run 01 and check `V$PWFILE_USERS`. |
| `ORA-65096` creating the user | CDB needs a common user; accept the `C##` prefix that script 01 offers. |
| `mkstore` rejects the wallet password | The old wallet's password is lost (common for wallets built by someone long gone). Script 02 offers a backup-and-rebuild. |
| `mkstore` edits "succeed" but connects still fail ORA-01017 | The wallet is auto-login-only (`cwallet.sso` without `ewallet.p12`) — mkstore has no password to verify, so edits exit 0 without producing usable credentials. Script 02 detects this and rebuilds automatically; use `--rebuild-wallet` on older copies of the kit. |
| Script 02 ends "WITH WARNINGS" listing SYS keys | The wallet held SYS credentials under keys other than the two aliases you typed (FQDN-qualified alias, broker `DGConnectIdentifier`). Re-run with that key as `--primary-tns`/`--standby-tns`, or `mkstore -wrl <dir> -deleteCredential <key>` once nothing uses it. |
| Script 02 refuses with "Wallet directory mismatch" | `-w` names a different directory than `sqlnet.ora`'s `WALLET_LOCATION`. Omit `-w`, or change `WALLET_LOCATION` first. |
| Observer logins start failing with `ORA-28001` months later | The observer user's password expired (`DEFAULT` profile `PASSWORD_LIFE_TIME` 180). Give the user a profile with an unlimited life time (script 01 offers it) and reset the password + wallet entry. |
| `STOP OBSERVER` errors | The old observer process is dead or unreachable — kill its `dgmgrl` process on its host, then start the new one. With multiple observers registered, name it: `STOP OBSERVER <name>` (see `SHOW OBSERVER`). |
| Observer present but `SHOW OBSERVER` shows the wrong host | Something (cron/systemd) restarted the old SYS observer elsewhere. Find and fix the starter, `STOP OBSERVER`, start yours. |
| Host uses TDE | Unrelated: TDE's keystore is `ENCRYPTION_WALLET_LOCATION`; the observer credential wallet is `WALLET_LOCATION` + `SQLNET.WALLET_OVERRIDE`. The scripts only ever match the latter (anchored), and `WALLET_OVERRIDE` does not affect TDE. |

## FAQ

**Is SYSDG really enough — including for the actual failover?**
Yes. SYSDG exists precisely for this: broker administration, switchover,
failover (including FSFO-initiated), startup/shutdown during role changes.
This repo's E2E-tested workflow runs its observers exactly this way.

**Does the primary stall while the observer is down?**
No. A missing observer alone never stalls the primary. (With FSFO enabled, a
primary stalls only if it loses *both* the observer and the standby
simultaneously.)

**Can I keep the observer on the standby host / a third host?**
Unchanged by this conversion — the kit works wherever the observer runs; run
script 02 there.

**Multiple databases to convert?**
Repeat per configuration. Wallets keyed by TNS alias mean one observer host
serving several configurations keeps all credentials in one wallet — script 02
only touches the two aliases you give it.
