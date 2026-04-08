# Oracle Wallet Setup for Data Guard

An Oracle auto-login wallet lets scripts like `dg_check_sid.sh` connect to the peer database without prompting for a password. This guide covers setting up wallet-based SYS authentication between primary and standby databases.

## Quick Start

```bash
# On primary host - auto-generate wallet password, no prompts except SYS
export ORACLE_SID=cdb1
bash common/setup_dg_wallet.sh -A

# On standby host - same command
export ORACLE_SID=cdb1
bash common/setup_dg_wallet.sh -A

# Verify it works
sqlplus /@standby_tns_alias as sysdba
```

Run the script on **both** hosts for bidirectional wallet auth.

## How It Works

Oracle Wallet stores database credentials in encrypted files on disk. An **auto-login wallet** creates an additional file (`cwallet.sso`) that allows connections without entering the wallet password at runtime.

The setup script:

1. Detects the local database role (primary or standby) from `V$DATABASE`
2. Discovers the peer database and TNS aliases from the DG Broker
3. Prompts for the SYS password and verifies it against the peer
4. Creates an auto-login wallet with `mkstore`
5. Stores SYS credentials for both local and peer TNS aliases
6. Adds `WALLET_LOCATION` and `SQLNET.WALLET_OVERRIDE` to `sqlnet.ora`
7. Tests the wallet connection to the peer

After setup, any tool that connects using `/@<tns_alias> as sysdba` will authenticate via the wallet automatically.

## Command-Line Options

| Flag | Description |
|---|---|
| `-A`, `--auto-password` | Generate wallet password automatically (no prompt) |
| `-w`, `--wallet-dir DIR` | Custom wallet directory (default: `$ORACLE_HOME/network/admin`) |
| `-h`, `--help` | Show usage |

## Wallet Password Modes

### Auto-password (`-A`)

```bash
bash common/setup_dg_wallet.sh -A
```

The wallet password is generated internally and discarded. You never see it, and you don't need it -- the auto-login file handles all connections. To modify the wallet later, just re-run with `-A` (the old wallet is backed up and a new one is created).

This is the simplest option for most setups.

### Manual password

```bash
bash common/setup_dg_wallet.sh
```

You choose the wallet password. This lets you manage the wallet later with `mkstore` commands directly (add credentials, list entries, etc.) without re-running the script. You'll be prompted for this password whenever you re-run the script to update credentials in an existing wallet.

## What Gets Created

| File | Purpose |
|---|---|
| `ewallet.p12` | Encrypted wallet (password-protected) |
| `cwallet.sso` | Auto-login wallet (no password needed at connect time) |

Both are stored in the wallet directory. The `sqlnet.ora` entry tells Oracle where to find them:

```
WALLET_LOCATION = (SOURCE = (METHOD = FILE) (METHOD_DATA = (DIRECTORY = /path/to/wallet)))
SQLNET.WALLET_OVERRIDE = TRUE
```

`SQLNET.WALLET_OVERRIDE = TRUE` means the wallet credentials take precedence over OS authentication when connecting via a TNS alias.

## Credentials Stored

The script stores SYS credentials for two TNS aliases (discovered from the broker):

| TNS Alias | Purpose |
|---|---|
| Peer alias (e.g. `cdb1_stby`) | Connect to the other database |
| Local alias (e.g. `cdb1`) | Connect to self via TNS (used by some tools) |

After running on both hosts, each database can reach the other with:

```bash
sqlplus /@peer_tns_alias as sysdba
```

## Prerequisites

- `ORACLE_HOME` and `ORACLE_SID` set, `sqlplus / as sysdba` working
- DG Broker configured and running (`dg_broker_start = TRUE`)
- TNS entries for both databases in `$ORACLE_HOME/network/admin/tnsnames.ora`
- `mkstore` available in `$ORACLE_HOME/bin`
- SYS password (same on both databases)

## Relationship to Other Wallets

This project uses wallets in two places:

| Wallet | Script | User | Purpose |
|---|---|---|---|
| **DG connectivity** | `common/setup_dg_wallet.sh` | SYS | Primary ↔ standby connections for status checks |
| **FSFO observer** | `fsfo/observer.sh setup` | SYSDG user | Observer → both databases for failover monitoring |

These can coexist in the same wallet directory -- credentials are keyed by TNS alias and username, so they don't conflict. If the observer wallet already exists at the default location, the DG wallet script will add credentials to it (when not using `-A`) or back it up and recreate (when using `-A`).

## Common Tasks

### Check what's in the wallet

```bash
mkstore -wrl $ORACLE_HOME/network/admin -listCredential
```

### Remove a credential

```bash
mkstore -wrl $ORACLE_HOME/network/admin -deleteCredential tns_alias
```

### Update SYS password in wallet (after password change)

```bash
# Easiest: re-run the setup script
bash common/setup_dg_wallet.sh       # prompts for wallet + SYS password
bash common/setup_dg_wallet.sh -A    # or just recreate with auto-password
```

### Test wallet connection manually

```bash
sqlplus /@peer_tns_alias as sysdba
# Should connect without prompting for a password
```

### Wallet not working?

1. **Check sqlnet.ora** -- verify `WALLET_LOCATION` points to the right directory
2. **Check files exist** -- `ls -la $ORACLE_HOME/network/admin/ewallet.p12 cwallet.sso`
3. **Check TNS entry** -- `tnsping peer_tns_alias` should resolve
4. **Check credentials** -- `mkstore -wrl ... -listCredential` should show the alias
5. **Check WALLET_OVERRIDE** -- must be `TRUE` for `/@alias as sysdba` to use wallet credentials
