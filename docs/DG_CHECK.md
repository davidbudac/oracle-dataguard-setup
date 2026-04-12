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
```

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
- `2` error
- `64` usage or preflight failure

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

## What The Scripts Check

Both commands use the same shared collector and grading rules. The difference is presentation depth.

### Primary-side checks

- Database role and open mode
- Protection mode
- Switchover status
- Force logging
- Flashback
- `dg_broker_start`
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
- Recovery mode
- Transport lag
- Apply lag
- Apply finish time
- Sequence lag
- Standby redo count
- Archive gaps
- FRA usage and thresholds
- Flashback state

### Broker / FSFO checks

- Configuration presence
- Overall broker status
- Member warnings / errors
- Fast-Start Failover mode
- FSFO target
- Observer presence / host

## Data Source Modes

The scripts now make the peer data source explicit:

- `remote runtime via wallet`
- `remote runtime via password`
- `broker-only degraded mode`
- `local+broker only (-L)`

When remote runtime SQL is unavailable, peer details fall back to broker data and the command is graded as a warning instead of appearing healthy.

## Recent DG Events

Both commands inspect the local alert log and broker log:

- `dg_triage_sid.sh` shows compressed recent events only
- `dg_diag_sid.sh` shows longer excerpts

Set `DG_DEBUG=1` if you also want file paths printed in triage output.

## Wallet Usage

These commands work best with wallet-based peer authentication configured via [WALLET_SETUP.md](WALLET_SETUP.md). With a wallet in place, peer runtime queries can use:

```bash
sqlplus /@peer_tns_alias as sysdba
```

## Relationship to `dg_status.sh`

[`dg_status.sh`](DG_STATUS.md) remains the SSH-based dashboard run from a jump host or any host that can reach both databases over SSH.

The local commands in this document are for running directly on one DB host without SSH to the peer.
