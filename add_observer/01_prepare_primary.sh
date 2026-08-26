#!/usr/bin/env bash
# ============================================================
# Add an FSFO observer on a third host - Step 1 (run on PRIMARY)
# ============================================================
# Prepares an ALREADY WORKING Data Guard configuration for an
# observer that will run on a separate, third host, and generates a
# self-contained bundle of files + commands to run over there.
#
# It does, in order:
#   1. Pre-flight: role is PRIMARY, password file, broker started.
#   2. Discovers the topology (both DB_UNIQUE_NAMEs, hostnames,
#      listener ports, services) from V$DATABASE, V$DATAGUARD_CONFIG,
#      V$LISTENER_NETWORK, DGMGRL SHOW DATABASE VERBOSE and tnsping.
#   3. Reports FSFO readiness (broker health, VALIDATE DATABASE,
#      Flashback Database, protection mode, standby redo logs).
#   4. Creates/verifies a dedicated observer user with exactly
#      CREATE SESSION + SYSDG (CDB-aware: C## prefix).
#   5. Enables Fast-Start Failover if it is off (--enable-fsfo), or
#      prints the exact DGMGRL commands to do it later.
#   6. Writes ./observer_bundle_<PRIMARY_DB_UNIQUE_NAME>/ containing
#      the TNS entries, an env file, the observer-host scripts, and
#      RUN_ON_OBSERVER_HOST.md with the copy-paste commands.
#
# What it does NOT do: change the protection mode, change LogXptMode,
# or touch redo transport. A working configuration keeps working.
#
# Usage:
#   ./01_prepare_primary.sh
#   ./01_prepare_primary.sh --observer-host obs1 --enable-fsfo
#   ./01_prepare_primary.sh -u dg_watch --standby-host stb1 --port 1521
#
# Exit codes: 0 success, 1 fatal, 2 bad arguments
# ============================================================

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

OBSERVER_USER=""
CREATE_USER=true
PRIMARY_HOST_OVERRIDE=""
STANDBY_HOST_OVERRIDE=""
PRIMARY_PORT_OVERRIDE=""
STANDBY_PORT_OVERRIDE=""
OBSERVER_HOST=""
OBSERVER_NAME=""
OBSERVER_DIR=""
FSFO_THRESHOLD=30
FSFO_LAG_LIMIT=30
ENABLE_FSFO=false
OUTDIR=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Prepares an existing Data Guard configuration for an observer on a third
host and generates the bundle to copy there. Run on the PRIMARY, with
'sqlplus / as sysdba' and 'dgmgrl /' working.

Options:
  -u, --user USER        Observer database user (default: dg_observer,
                         c##dg_observer on a CDB)
      --no-user          Skip user creation/verification (it already exists)
      --observer-host H  Hostname of the third host (used in the generated
                         guidance and the scp command; prompted if absent)
      --observer-name N  Registered observer name (default: obs_<primary>)
      --observer-dir D   Directory on the third host for the observer's
                         fsfo.dat / log (default: \$HOME/fsfo_observer)
      --primary-host H   Override the discovered primary hostname
      --standby-host H   Override the discovered standby hostname
      --port N           Override the listener port for BOTH sides
      --primary-port N   Override the primary listener port
      --standby-port N   Override the standby listener port
      --threshold SEC    FastStartFailoverThreshold (default: 30)
      --lag-limit SEC    FastStartFailoverLagLimit, used only when the
                         configuration is in MAXIMUM PERFORMANCE mode
                         (default: 30)
      --enable-fsfo      Enable Fast-Start Failover now if it is disabled.
                         Without this flag the commands are only printed.
  -o, --outdir DIR       Bundle output directory
                         (default: ./observer_bundle_<PRIMARY_DB_UNIQUE_NAME>)
  -h, --help             Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)         [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                           OBSERVER_USER="$2"; shift 2 ;;
        --no-user)         CREATE_USER=false; shift ;;
        --observer-host)   [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                           OBSERVER_HOST="$2"; shift 2 ;;
        --observer-name)   [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                           OBSERVER_NAME="$2"; shift 2 ;;
        --observer-dir)    [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                           OBSERVER_DIR="$2"; shift 2 ;;
        --primary-host)    [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                           PRIMARY_HOST_OVERRIDE="$2"; shift 2 ;;
        --standby-host)    [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                           STANDBY_HOST_OVERRIDE="$2"; shift 2 ;;
        --port)            [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                           PRIMARY_PORT_OVERRIDE="$2"; STANDBY_PORT_OVERRIDE="$2"; shift 2 ;;
        --primary-port)    [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                           PRIMARY_PORT_OVERRIDE="$2"; shift 2 ;;
        --standby-port)    [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                           STANDBY_PORT_OVERRIDE="$2"; shift 2 ;;
        --threshold)       [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                           FSFO_THRESHOLD="$2"; shift 2 ;;
        --lag-limit)       [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                           FSFO_LAG_LIMIT="$2"; shift 2 ;;
        --enable-fsfo)     ENABLE_FSFO=true; shift ;;
        -o|--outdir)       [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                           OUTDIR="$2"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
done

for v in FSFO_THRESHOLD FSFO_LAG_LIMIT PRIMARY_PORT_OVERRIDE STANDBY_PORT_OVERRIDE; do
    val="${!v}"
    [[ -z "$val" ]] && continue
    printf '%s' "$val" | grep -q '^[0-9][0-9]*$' || { log_error "$v must be numeric: $val"; exit 2; }
done

# ============================================================
# Pre-flight
# ============================================================

log_section "Pre-flight Checks"

check_oracle_env
[[ -n "${ORACLE_SID:-}" ]] || die "ORACLE_SID is not set."
[[ -x "$ORACLE_HOME/bin/sqlplus" ]] || die "sqlplus not found under $ORACLE_HOME/bin"
[[ -x "$ORACLE_HOME/bin/dgmgrl" ]]  || die "dgmgrl not found under $ORACLE_HOME/bin"

DB_ROLE=$(run_sql "select database_role from v\$database;" | trim | head -1) \
    || die "Cannot connect 'sqlplus / as sysdba' to ${ORACLE_SID}."
[[ "$DB_ROLE" == "PRIMARY" ]] \
    || die "This database is '${DB_ROLE}', not PRIMARY. Run this script on the PRIMARY (roles may be swapped after a switchover)."
log_info "Database role: PRIMARY (${ORACLE_SID})"

PWFILE_MODE=$(run_sql "select upper(nvl(value,'NONE')) from v\$parameter where name = 'remote_login_passwordfile';" | clean | head -1) || PWFILE_MODE="NONE"
if [[ "$PWFILE_MODE" != "EXCLUSIVE" && "$PWFILE_MODE" != "SHARED" ]]; then
    die "remote_login_passwordfile = ${PWFILE_MODE}. The observer authenticates remotely AS SYSDG, which needs a password file."
fi
log_info "Password file authentication: ${PWFILE_MODE}"

BROKER_START=$(run_sql "select upper(value) from v\$parameter where name = 'dg_broker_start';" | clean | head -1) || BROKER_START=""
[[ "$BROKER_START" == "TRUE" ]] \
    || die "dg_broker_start is '${BROKER_START:-unknown}'. Fast-Start Failover requires the Data Guard Broker. Enable it on BOTH databases: ALTER SYSTEM SET dg_broker_start=TRUE SCOPE=BOTH;"
log_info "Data Guard Broker: started"

IS_CDB=$(run_sql "select cdb from v\$database;" | clean | head -1) || IS_CDB="NO"
log_info "Multitenant (CDB): ${IS_CDB}"

# ============================================================
# Discover the topology
# ============================================================

log_section "Discovering Topology"

PRIMARY_DBUN=$(run_sql "select db_unique_name from v\$database;" | clean | head -1) \
    || die "Could not read DB_UNIQUE_NAME."
PROTECTION_MODE=$(run_sql "select protection_mode from v\$database;" | trim | head -1) || PROTECTION_MODE="UNKNOWN"
FLASHBACK_PRIMARY=$(run_sql "select flashback_on from v\$database;" | trim | head -1) || FLASHBACK_PRIMARY="UNKNOWN"

STANDBY_DBUN=$(run_sql "select db_unique_name from v\$dataguard_config where db_unique_name <> '${PRIMARY_DBUN}' and rownum = 1;" | clean | head -1) || STANDBY_DBUN=""
[[ -n "$STANDBY_DBUN" ]] \
    || die "No peer database found in V\$DATAGUARD_CONFIG. This kit adds an observer to an EXISTING configuration - build the standby first."

log_info "Primary : ${PRIMARY_DBUN}"
log_info "Standby : ${STANDBY_DBUN}"
log_info "Protection mode: ${PROTECTION_MODE}"

PEER_COUNT=$(run_sql "select count(*) from v\$dataguard_config where db_unique_name <> '${PRIMARY_DBUN}';" | clean | head -1) || PEER_COUNT="1"
if [[ "$PEER_COUNT" != "1" ]]; then
    log_warn "${PEER_COUNT} peers found in V\$DATAGUARD_CONFIG; this kit configures the observer for '${STANDBY_DBUN}'."
    log_warn "Fast-Start Failover has exactly one target - use --standby-host and check FastStartFailoverTarget if that is the wrong one."
fi

# --- broker properties for both members -------------------------------
SHOW_PRI=$(run_dgmgrl "/" "SHOW DATABASE VERBOSE '${PRIMARY_DBUN}';" || true)
SHOW_STB=$(run_dgmgrl "/" "SHOW DATABASE VERBOSE '${STANDBY_DBUN}';" || true)

PRIMARY_HOST=$(broker_property "$SHOW_PRI" "HostName")
STANDBY_HOST=$(broker_property "$SHOW_STB" "HostName")
PRIMARY_DGCI=$(broker_property "$SHOW_PRI" "DGConnectIdentifier")
STANDBY_DGCI=$(broker_property "$SHOW_STB" "DGConnectIdentifier")
STANDBY_LOGXPT=$(broker_property "$SHOW_STB" "LogXptMode")

# --- resolve what the members actually use to reach each other --------
# tnsping resolves the DGConnectIdentifier through the primary's own
# Oracle Net configuration, which is the authoritative answer for host,
# port and service - far better than guessing any of the three.
PRIMARY_DESC=$(resolve_descriptor "$PRIMARY_DGCI")
STANDBY_DESC=$(resolve_descriptor "$STANDBY_DGCI")

PRIMARY_PORT=$(descriptor_part "$PRIMARY_DESC" PORT)
STANDBY_PORT=$(descriptor_part "$STANDBY_DESC" PORT)
PRIMARY_SERVICE=$(descriptor_part "$PRIMARY_DESC" SERVICE_NAME)
STANDBY_SERVICE=$(descriptor_part "$STANDBY_DESC" SERVICE_NAME)
[[ -n "$PRIMARY_HOST" ]] || PRIMARY_HOST=$(descriptor_part "$PRIMARY_DESC" HOST)
[[ -n "$STANDBY_HOST" ]] || STANDBY_HOST=$(descriptor_part "$STANDBY_DESC" HOST)

# Local listener port as a fallback for the primary side.
LOCAL_LISTENER=$(run_sql "select value from v\$listener_network where type = 'LOCAL LISTENER' and rownum = 1;" | clean | head -1) || LOCAL_LISTENER=""
LOCAL_PORT=$(printf '%s' "$LOCAL_LISTENER" | sed -n 's/.*PORT *= *\([0-9][0-9]*\).*/\1/p' | head -1)

# Overrides and last-resort defaults.
[[ -n "$PRIMARY_HOST_OVERRIDE" ]] && PRIMARY_HOST="$PRIMARY_HOST_OVERRIDE"
[[ -n "$STANDBY_HOST_OVERRIDE" ]] && STANDBY_HOST="$STANDBY_HOST_OVERRIDE"
[[ -n "$PRIMARY_PORT_OVERRIDE" ]] && PRIMARY_PORT="$PRIMARY_PORT_OVERRIDE"
[[ -n "$STANDBY_PORT_OVERRIDE" ]] && STANDBY_PORT="$STANDBY_PORT_OVERRIDE"
[[ -n "$PRIMARY_PORT" ]] || PRIMARY_PORT="${LOCAL_PORT:-1521}"
[[ -n "$STANDBY_PORT" ]] || STANDBY_PORT="${LOCAL_PORT:-1521}"
[[ -n "$PRIMARY_SERVICE" ]] || PRIMARY_SERVICE="$PRIMARY_DBUN"
[[ -n "$STANDBY_SERVICE" ]] || STANDBY_SERVICE="$STANDBY_DBUN"
[[ -n "$PRIMARY_HOST" ]] || PRIMARY_HOST=$(hostname)

if [[ -z "$STANDBY_HOST" ]]; then
    log_error "Could not discover the standby hostname (broker HostName property and tnsping both came up empty)."
    die "Re-run with --standby-host <hostname>."
fi

PRIMARY_TNS_ALIAS=$(printf '%s' "$PRIMARY_DBUN" | tr '[:upper:]' '[:lower:]')
STANDBY_TNS_ALIAS=$(printf '%s' "$STANDBY_DBUN" | tr '[:upper:]' '[:lower:]')

log_info "Primary connect : ${PRIMARY_HOST}:${PRIMARY_PORT}/${PRIMARY_SERVICE}"
log_info "Standby connect : ${STANDBY_HOST}:${STANDBY_PORT}/${STANDBY_SERVICE}"
[[ -n "$STANDBY_LOGXPT" ]] && log_info "Standby LogXptMode: ${STANDBY_LOGXPT}"

if [[ "$PRIMARY_HOST" == "$STANDBY_HOST" ]]; then
    log_warn "Both databases report the same hostname (${PRIMARY_HOST}) - check the discovered values above."
fi

# ============================================================
# FSFO readiness
# ============================================================

log_section "Fast-Start Failover Readiness"

CONFIG_OUT=$(run_dgmgrl "/" "SHOW CONFIGURATION;" || true)
printf '%s\n' "$CONFIG_OUT"

CONFIG_HEALTHY=true
if printf '%s\n' "$CONFIG_OUT" | grep -qi 'SUCCESS'; then
    log_info "Broker configuration status: SUCCESS"
elif printf '%s\n' "$CONFIG_OUT" | grep -qi 'WARNING'; then
    log_warn "Broker configuration status: WARNING - review the output above before enabling FSFO."
    CONFIG_HEALTHY=false
else
    log_error "Broker configuration is not healthy (no SUCCESS status)."
    CONFIG_HEALTHY=false
fi

log_section "VALIDATE DATABASE '${STANDBY_DBUN}'"
VALIDATE_OUT=$(run_dgmgrl "/" "VALIDATE DATABASE '${STANDBY_DBUN}';" || true)
printf '%s\n' "$VALIDATE_OUT"

if printf '%s\n' "$VALIDATE_OUT" | grep -qiE 'Ready for Failover:[[:space:]]*Yes'; then
    log_info "Standby reports 'Ready for Failover: Yes'."
else
    log_warn "Standby does NOT report 'Ready for Failover: Yes' - an observer would have nothing safe to fail over to."
    CONFIG_HEALTHY=false
fi

# Flashback Database: needed so the broker can automatically REINSTATE the
# old primary after a fast-start failover. VALIDATE DATABASE prints it for
# both members; fall back to V$DATABASE for the primary.
log_info "Flashback Database (primary, V\$DATABASE.FLASHBACK_ON): ${FLASHBACK_PRIMARY}"
# VALIDATE DATABASE prints a "Flashback Database Status:" block listing each
# member on its own "<db_unique_name>:  On|Off" line; keep only those lines.
FLASHBACK_BLOCK=$(printf '%s\n' "$VALIDATE_OUT" \
    | sed -n '/[Ff]lashback [Dd]atabase [Ss]tatus/,/^[[:space:]]*$/p' \
    | grep -iE ':[[:space:]]*(On|Off)[[:space:]]*$' | trim)
if [[ -n "$FLASHBACK_BLOCK" ]]; then
    log_info "Flashback Database (both members, VALIDATE DATABASE):"
    printf '%s\n' "$FLASHBACK_BLOCK" | sed 's/^/    /'
fi
# Anchored on the ": Off" value, not a bare 'off' - a DB_UNIQUE_NAME such as
# 'orcl_offsite' would otherwise read as "flashback is off".
if printf '%s\n' "${FLASHBACK_BLOCK}" | grep -qiE ':[[:space:]]*Off[[:space:]]*$' || [[ "$(upper "$FLASHBACK_PRIMARY")" == "NO" ]]; then
    log_warn "Flashback Database is OFF on at least one member."
    log_warn "  - The broker may refuse ENABLE FAST_START FAILOVER (ORA-16693)."
    log_warn "  - Without it, a failed-over primary cannot be reinstated automatically;"
    log_warn "    it has to be rebuilt or restored by hand."
    log_warn "  Enable on BOTH (needs a flash recovery area and a MOUNTED database):"
    log_warn "    ALTER DATABASE FLASHBACK ON;"
fi

# Protection mode decides which FSFO flavour applies.
PROT_NORM=$(upper "$PROTECTION_MODE" | tr -d ' ')
FSFO_FLAVOUR="threshold"
case "$PROT_NORM" in
    MAXIMUMAVAILABILITY|MAXIMUMPROTECTION)
        log_info "Protection mode ${PROTECTION_MODE}: zero-data-loss FSFO, governed by FastStartFailoverThreshold."
        ;;
    MAXIMUMPERFORMANCE)
        FSFO_FLAVOUR="lag"
        log_warn "Protection mode is MAXIMUM PERFORMANCE (asynchronous transport)."
        log_warn "FSFO is still supported here, but it is NOT zero-data-loss: the broker"
        log_warn "only fails over automatically while the standby's apply lag is within"
        log_warn "FastStartFailoverLagLimit (${FSFO_LAG_LIMIT}s), and you can lose up to that much redo."
        log_warn "This script does NOT change your protection mode. For zero data loss,"
        log_warn "raise it separately (LogXptMode=SYNC/FASTSYNC + MAXAVAILABILITY)."
        ;;
    *)
        log_warn "Unrecognised protection mode: ${PROTECTION_MODE}"
        ;;
esac

SRL_COUNT=$(run_sql "select count(*) from v\$standby_log;" | clean | head -1) || SRL_COUNT="0"
log_info "Standby redo logs on the primary: ${SRL_COUNT} (needed for it to receive redo after a role change)"
[[ "$SRL_COUNT" == "0" ]] && log_warn "The primary has no standby redo logs - it cannot accept redo after a failover/switchover."

$CONFIG_HEALTHY || log_warn "Findings above are not fatal to this script, but fix them before relying on automatic failover."

# ============================================================
# Observer database user
# ============================================================

log_section "Observer Database User"

DEFAULT_OBSERVER_USER="dg_observer"
[[ "$IS_CDB" == "YES" ]] && DEFAULT_OBSERVER_USER="c##dg_observer"

if [[ -z "$OBSERVER_USER" ]]; then
    prompt_with_default OBSERVER_USER "Observer database username" "$DEFAULT_OBSERVER_USER"
fi
OBSERVER_USER=$(upper "$OBSERVER_USER")

[[ "$OBSERVER_USER" != "SYS" ]] \
    || die "Refusing to configure the observer as SYS. Use a dedicated user with SYSDG (that is what this kit is for)."

# On a CDB the observer user must be a COMMON user: dgmgrl connects at the
# root, and a local user there fails with ORA-65096.
if [[ "$IS_CDB" == "YES" && "$OBSERVER_USER" != C##* ]]; then
    log_warn "This is a CDB: the observer user must be a COMMON user (C## prefix)."
    if [[ -t 0 ]]; then
        confirm_proceed "Use C##${OBSERVER_USER} instead?" \
            || die "Cannot create a non-common observer user on a CDB."
    else
        log_warn "Non-interactive stdin: auto-prefixing as C##${OBSERVER_USER}"
    fi
    OBSERVER_USER="C##${OBSERVER_USER}"
fi

valid_db_username "$OBSERVER_USER" || die "Invalid observer username: ${OBSERVER_USER}"
log_info "Observer username: ${OBSERVER_USER}"

run_sql_or_die() {
    local __sql="$1" __msg="$2" __out=""
    if ! __out=$(run_sql "$__sql"); then
        printf '%s\n' "$__out" >&2
        die "$__msg"
    fi
}

if ! $CREATE_USER; then
    log_info "--no-user given: skipping user creation/verification."
else
    USER_EXISTS=$(run_sql "select count(*) from dba_users where username = '${OBSERVER_USER}';" | clean | head -1) || USER_EXISTS="0"

    set_observer_password() {
        local pw pw2
        prompt_password pw  "Enter password for ${OBSERVER_USER}"
        prompt_password pw2 "Confirm password"
        [[ "$pw" == "$pw2" ]] || die "Passwords do not match."
        [[ -n "$pw" ]] || die "Password cannot be empty."
        case "$pw" in
            *\"*) die 'Password must not contain a double quote (").' ;;
        esac
        OBSERVER_PASSWORD="$pw"
    }

    if [[ "$USER_EXISTS" == "0" ]]; then
        log_info "Creating ${OBSERVER_USER} with CREATE SESSION + SYSDG..."
        set_observer_password
        run_sql_or_die "create user ${OBSERVER_USER} identified by \"${OBSERVER_PASSWORD}\";
grant create session to ${OBSERVER_USER};
grant sysdg to ${OBSERVER_USER};" "Failed to create ${OBSERVER_USER}."
        unset OBSERVER_PASSWORD
        log_info "User created."
    else
        log_info "User ${OBSERVER_USER} already exists."
        # SYSDG is an administrative (password-file) privilege: it appears in
        # V$PWFILE_USERS, never in DBA_ROLE_PRIVS / DBA_SYS_PRIVS.
        HAS_SYSDG=$(run_sql "select count(*) from v\$pwfile_users where username = '${OBSERVER_USER}' and sysdg = 'TRUE';" | clean | head -1) || HAS_SYSDG="0"
        if [[ "$HAS_SYSDG" == "1" ]]; then
            log_info "It already holds SYSDG."
        else
            log_info "Granting CREATE SESSION + SYSDG..."
            run_sql_or_die "grant create session to ${OBSERVER_USER};
grant sysdg to ${OBSERVER_USER};" "Failed to grant SYSDG to ${OBSERVER_USER}."
            log_info "Granted."
        fi
        if confirm_proceed "Reset the password for ${OBSERVER_USER} now?"; then
            set_observer_password
            run_sql_or_die "alter user ${OBSERVER_USER} identified by \"${OBSERVER_PASSWORD}\";" \
                "Failed to reset the password for ${OBSERVER_USER}."
            unset OBSERVER_PASSWORD
            log_info "Password updated."
        else
            log_info "Keeping the existing password - you will need it on the observer host in step 02."
        fi
    fi

    VERIFIED=$(run_sql "select count(*) from v\$pwfile_users where username = '${OBSERVER_USER}' and sysdg = 'TRUE';" | clean | head -1) || VERIFIED="0"
    [[ "$VERIFIED" == "1" ]] \
        || die "${OBSERVER_USER} does not show SYSDG='TRUE' in V\$PWFILE_USERS - the grant did not land."
    log_info "Verified: ${OBSERVER_USER} holds SYSDG in the primary's password file."

    # The observer must log in to the STANDBY too (that is how it completes a
    # failover), and on a mounted standby AS SYSDG is authenticated purely
    # against the password file.
    log_info "Standby password file: on 12.2+ a standby that is receiving redo picks up"
    log_info "this change automatically. Step 02's standby connection test proves it."
fi

# ============================================================
# Fast-Start Failover
# ============================================================

log_section "Fast-Start Failover State"

FSFO_OUT=$(run_dgmgrl "/" "SHOW FAST_START FAILOVER;" || true)
printf '%s\n' "$FSFO_OUT"

FSFO_ENABLED=false
printf '%s\n' "$FSFO_OUT" | grep -qiE 'Fast-Start Failover:[[:space:]]*(Enabled|ENABLED)' && FSFO_ENABLED=true

if [[ "$FSFO_FLAVOUR" == "lag" ]]; then
    FSFO_CMDS="EDIT CONFIGURATION SET PROPERTY FastStartFailoverThreshold=${FSFO_THRESHOLD};
EDIT CONFIGURATION SET PROPERTY FastStartFailoverTarget='${STANDBY_DBUN}';
EDIT CONFIGURATION SET PROPERTY FastStartFailoverLagLimit=${FSFO_LAG_LIMIT};
ENABLE FAST_START FAILOVER;"
else
    FSFO_CMDS="EDIT CONFIGURATION SET PROPERTY FastStartFailoverThreshold=${FSFO_THRESHOLD};
EDIT CONFIGURATION SET PROPERTY FastStartFailoverTarget='${STANDBY_DBUN}';
ENABLE FAST_START FAILOVER;"
fi

if $FSFO_ENABLED; then
    CURRENT_TARGET=$(run_sql "select nvl(fs_failover_current_target,'(none)') from v\$database;" | trim | head -1) || CURRENT_TARGET=""
    log_info "Fast-Start Failover is already ENABLED (current target: ${CURRENT_TARGET:-unknown})."
    if [[ -n "$CURRENT_TARGET" && "$(upper "$CURRENT_TARGET")" != "$(upper "$STANDBY_DBUN")" && "$CURRENT_TARGET" != "(none)" ]]; then
        log_warn "The FSFO target is '${CURRENT_TARGET}', not '${STANDBY_DBUN}'."
        log_warn "The observer will follow the broker's target - adjust the discovered standby if that is wrong."
    fi
    log_info "Nothing to change here: adding a third-host observer does not require re-enabling FSFO."
else
    log_warn "Fast-Start Failover is DISABLED. The observer will refuse to do anything useful until it is on."
    if $ENABLE_FSFO; then
        if ! $CONFIG_HEALTHY; then
            log_warn "Readiness findings were reported above."
            confirm_proceed "Enable Fast-Start Failover anyway?" || die "Aborted before enabling FSFO."
        fi
        log_info "Enabling Fast-Start Failover..."
        printf '%s\n' "$FSFO_CMDS" | sed 's/^/    /'
        ENABLE_OUT=$(run_dgmgrl "/" "$FSFO_CMDS" || true)
        printf '%s\n' "$ENABLE_OUT"
        if dgmgrl_failed "$ENABLE_OUT"; then
            log_error "Enabling Fast-Start Failover failed. Common causes:"
            log_error "  ORA-16693 - Flashback Database is off on one/both members (see above)."
            log_error "  ORA-16627 - the standby is not synchronized / not a valid target."
            log_error "  ORA-16651 - broker configuration warnings must be cleared first."
            die "FSFO not enabled."
        fi
        log_info "Fast-Start Failover enabled (target: ${STANDBY_DBUN})."
        FSFO_ENABLED=true
    else
        log_info "Not enabling it (no --enable-fsfo). Run this on the primary when ready:"
        printf '\n    dgmgrl /\n'
        printf '%s\n' "$FSFO_CMDS" | sed 's/^/    /'
        printf '\n'
        log_info "Or re-run this script with --enable-fsfo."
    fi
fi

# ============================================================
# Generate the observer-host bundle
# ============================================================

log_section "Generating the Observer Host Bundle"

[[ -n "$OBSERVER_NAME" ]] || OBSERVER_NAME="obs_$(printf '%s' "$PRIMARY_DBUN" | tr '[:upper:]' '[:lower:]')"
if [[ -z "$OBSERVER_HOST" ]]; then
    prompt_with_default OBSERVER_HOST "Hostname of the third host that will run the observer" "observer-host"
fi
[[ -n "$OUTDIR" ]] || OUTDIR="./observer_bundle_${PRIMARY_DBUN}"

mkdir -p "$OUTDIR"
OUTDIR=$(cd "$OUTDIR" && pwd)
log_info "Bundle directory: ${OUTDIR}"

# --- TNS entries ------------------------------------------------------
{
    cat <<EOF
# ============================================================
# TNS entries for the Data Guard FSFO observer
# Generated on $(hostname) at $(date '+%Y-%m-%d %H:%M:%S')
# from the broker configuration of ${PRIMARY_DBUN}.
#
# Install on the OBSERVER host as \$TNS_ADMIN/tnsnames.ora
# (02_setup_observer_host.sh does it for you).
#
# The observer connects to BOTH databases - to the primary to watch
# it, to the standby to complete a failover - so both entries are
# required, and both hosts must be reachable from the observer host
# on the ports below.
# ============================================================

${PRIMARY_TNS_ALIAS} =
$(tns_descriptor "$PRIMARY_HOST" "$PRIMARY_PORT" "$PRIMARY_SERVICE")
${STANDBY_TNS_ALIAS} =
$(tns_descriptor "$STANDBY_HOST" "$STANDBY_PORT" "$STANDBY_SERVICE")
EOF
} > "${OUTDIR}/tnsnames_observer.ora"
log_info "Wrote tnsnames_observer.ora"

# --- environment file -------------------------------------------------
{
    cat <<EOF
# ============================================================
# Observer settings discovered from ${PRIMARY_DBUN} on $(hostname)
# at $(date '+%Y-%m-%d %H:%M:%S'). Sourced by the scripts in this
# bundle - no passwords are stored here.
# ============================================================
PRIMARY_DB_UNIQUE_NAME="${PRIMARY_DBUN}"
STANDBY_DB_UNIQUE_NAME="${STANDBY_DBUN}"
PRIMARY_TNS_ALIAS="${PRIMARY_TNS_ALIAS}"
STANDBY_TNS_ALIAS="${STANDBY_TNS_ALIAS}"
PRIMARY_HOST="${PRIMARY_HOST}"
STANDBY_HOST="${STANDBY_HOST}"
PRIMARY_PORT="${PRIMARY_PORT}"
STANDBY_PORT="${STANDBY_PORT}"
OBSERVER_USER="${OBSERVER_USER}"
OBSERVER_NAME="${OBSERVER_NAME}"
OBSERVER_HOST="${OBSERVER_HOST}"
PROTECTION_MODE="${PROTECTION_MODE}"
EOF
    [[ -n "$OBSERVER_DIR" ]] && printf 'OBSERVER_DIR="%s"\n' "$OBSERVER_DIR"
} > "${OUTDIR}/observer_env.sh"
log_info "Wrote observer_env.sh"

# --- the observer-host scripts ---------------------------------------
for f in _lib.sh 02_setup_observer_host.sh 03_observer_ctl.sh 04_verify_observer.sh; do
    if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
        cp "${SCRIPT_DIR}/${f}" "${OUTDIR}/${f}"
        [[ "$f" == _lib.sh ]] || chmod +x "${OUTDIR}/${f}"
    else
        log_warn "Missing from this kit, not copied into the bundle: ${f}"
    fi
done
log_info "Copied the observer-host scripts into the bundle"

# --- the runbook ------------------------------------------------------
OBS_DIR_TEXT="${OBSERVER_DIR:-\$HOME/fsfo_observer}"

cat > "${OUTDIR}/RUN_ON_OBSERVER_HOST.md" <<EOF
# Add an FSFO observer for \`${PRIMARY_DBUN}\` on \`${OBSERVER_HOST}\`

Generated on \`$(hostname)\` at $(date '+%Y-%m-%d %H:%M:%S') from the live broker
configuration. Everything below runs **on the third host** (\`${OBSERVER_HOST}\`)
as the Oracle software owner.

| | |
|---|---|
| Primary | \`${PRIMARY_DBUN}\` — ${PRIMARY_HOST}:${PRIMARY_PORT}/${PRIMARY_SERVICE} |
| Standby | \`${STANDBY_DBUN}\` — ${STANDBY_HOST}:${STANDBY_PORT}/${STANDBY_SERVICE} |
| Protection mode | ${PROTECTION_MODE} |
| Observer user | \`${OBSERVER_USER}\` (SYSDG) |
| Observer name | \`${OBSERVER_NAME}\` |
| Observer files | \`${OBS_DIR_TEXT}\` |

## 0. Prerequisites on ${OBSERVER_HOST}

* An Oracle **client** installation of the *Administrator* type, or a full
  database home, at the **same release as the databases** (19c here). The
  Instant Client is **not** enough — it ships neither \`dgmgrl\` nor \`mkstore\`.
* TCP reachability to **both** database hosts:

  \`\`\`bash
  nc -z ${PRIMARY_HOST} ${PRIMARY_PORT} && echo primary reachable
  nc -z ${STANDBY_HOST} ${STANDBY_PORT} && echo standby reachable
  \`\`\`

* \`ORACLE_HOME\` exported and on \`PATH\`. No \`ORACLE_SID\` is needed — the
  observer host runs no database.

## 1. Copy the bundle over

Run this **on the primary** (\`$(hostname)\`):

\`\`\`bash
scp -r ${OUTDIR} ${OBSERVER_HOST}:~/
\`\`\`

## 2. Set up TNS, the wallet and test connectivity

\`\`\`bash
cd ~/$(basename "$OUTDIR")
export ORACLE_HOME=/path/to/your/oracle/home
export PATH=\$ORACLE_HOME/bin:\$PATH

./02_setup_observer_host.sh
\`\`\`

It installs the two TNS entries, builds an **auto-login wallet** holding
\`${OBSERVER_USER}\`'s credentials for both aliases (it prompts for the wallet
password and for that user's database password), points \`sqlnet.ora\` at the
wallet, and then proves the whole chain:

\`\`\`
sqlplus /@${PRIMARY_TNS_ALIAS} as sysdg    -> must reach ${PRIMARY_DBUN}
sqlplus /@${STANDBY_TNS_ALIAS} as sysdg    -> must reach ${STANDBY_DBUN}
dgmgrl  /@${PRIMARY_TNS_ALIAS} "show configuration"
\`\`\`

If the **standby** connection fails with \`ORA-01017\` while the primary works,
the primary's password file has not reached the standby. Copy it (mind that the
filename carries each side's own \`ORACLE_SID\`):

\`\`\`bash
primary\$ scp \$ORACLE_HOME/dbs/orapw${ORACLE_SID} ${STANDBY_HOST}:\$ORACLE_HOME/dbs/orapw<STANDBY_SID>
\`\`\`

Do not skip past this: an observer whose credentials the standby rejects cannot
complete a failover, which is the one job it exists for.

## 3. Start the observer

\`\`\`bash
./03_observer_ctl.sh start
./03_observer_ctl.sh status
\`\`\`

\`start\` runs, via \`dgmgrl /@${PRIMARY_TNS_ALIAS}\`:

\`\`\`
START OBSERVER ${OBSERVER_NAME} IN BACKGROUND
      FILE IS '${OBS_DIR_TEXT}/fsfo_${PRIMARY_DBUN}.dat'
      LOGFILE IS '${OBS_DIR_TEXT}/fsfo_${PRIMARY_DBUN}.log'
      CONNECT IDENTIFIER IS ${PRIMARY_TNS_ALIAS}
\`\`\`

\`CONNECT IDENTIFIER IS\` is mandatory with \`IN BACKGROUND\`: the detached
observer opens its own connection instead of inheriting the dgmgrl session's.

## 4. Verify

\`\`\`bash
./04_verify_observer.sh
\`\`\`

Expect \`FS_FAILOVER_OBSERVER_PRESENT = YES\`, \`FS_FAILOVER_STATUS = SYNCHRONIZED\`
(or \`TARGET UNDER LAG LIMIT\` in MAXIMUM PERFORMANCE mode), and \`${OBSERVER_HOST}\`
listed in \`SHOW OBSERVER\`.

## 5. Survive a reboot

The observer is a plain background \`dgmgrl\` process — nothing restarts it for
you. Install one of the two starters:

\`\`\`bash
./03_observer_ctl.sh boot          # prints a systemd unit and a cron @reboot line
\`\`\`

## Day-to-day

\`\`\`bash
./03_observer_ctl.sh status        # broker's view + local process
./03_observer_ctl.sh log           # tail the observer log
./03_observer_ctl.sh restart
./03_observer_ctl.sh stop
\`\`\`

## What changes for the databases

Nothing about redo transport, protection mode or apply. Adding an observer only
registers a watcher. The one behavioural change is that with FSFO enabled the
primary will stall if it loses **both** the observer and the standby at the same
time — which is precisely why the observer belongs on a third host, in a
different failure domain from either database.
EOF
log_info "Wrote RUN_ON_OBSERVER_HOST.md"

# ============================================================
# Summary
# ============================================================

log_section "Next Steps"

cat <<EOF

Bundle ready: ${OUTDIR}

  tnsnames_observer.ora     TNS entries for ${PRIMARY_TNS_ALIAS} and ${STANDBY_TNS_ALIAS}
  observer_env.sh           discovered settings (no passwords)
  02_setup_observer_host.sh TNS + wallet + connectivity tests
  03_observer_ctl.sh        start | stop | status | restart | log | boot
  04_verify_observer.sh     end-state verification
  RUN_ON_OBSERVER_HOST.md   the runbook, with these commands and the caveats

RUN THESE COMMANDS
==================

  # 1. from HERE (${PRIMARY_DBUN}'s host), copy the bundle over:
  scp -r ${OUTDIR} ${OBSERVER_HOST}:~/

  # 2. on ${OBSERVER_HOST}, as the Oracle software owner:
  ssh ${OBSERVER_HOST}
  export ORACLE_HOME=/path/to/oracle/home        # 19c client (Administrator) or DB home
  export PATH=\$ORACLE_HOME/bin:\$PATH
  cd ~/$(basename "$OUTDIR")

  ./02_setup_observer_host.sh                    # prompts: wallet password, ${OBSERVER_USER} password
  ./03_observer_ctl.sh start
  ./04_verify_observer.sh
  ./03_observer_ctl.sh boot                      # optional: restart-on-reboot

EOF

if ! $FSFO_ENABLED; then
    cat <<EOF
STILL TO DO ON THIS HOST
========================
Fast-Start Failover is disabled, so the observer will start but never act.
Enable it here when the readiness findings above are cleared:

  dgmgrl /
$(printf '%s\n' "$FSFO_CMDS" | sed 's/^/    /')

EOF
fi

log_info "Step 1 complete."
