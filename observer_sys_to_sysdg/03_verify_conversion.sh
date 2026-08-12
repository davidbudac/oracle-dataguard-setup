#!/usr/bin/env bash
# ============================================================
# Observer SYS -> SYSDG conversion - Step 3 (verify, run anywhere)
# ============================================================
# Confirms the end state after the conversion:
#   - broker configuration health (SHOW CONFIGURATION)
#   - FSFO state and observer registration (SHOW FAST_START FAILOVER,
#     SHOW OBSERVER)
#   - V$DATABASE observer columns (FS_FAILOVER_OBSERVER_PRESENT etc.)
#   - which users hold SYSDG in the password file (V$PWFILE_USERS)
#
# Where to run / how it connects:
#   --tns ALIAS   -> wallet auth 'dgmgrl /@ALIAS' (observer host, or any
#                    host with the wallet + TNS entries)
#   no --tns      -> local OS auth 'dgmgrl /' (primary or standby host
#                    with ORACLE_SID set)
#
# Exit codes: 0 observer present, 1 observer missing / cannot verify,
#             2 bad arguments
# ============================================================

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

TNS_ALIAS=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [--tns ALIAS]

  --tns ALIAS   Connect via wallet as 'dgmgrl /@ALIAS' (use on the
                observer host). Without it, connects locally as
                'dgmgrl /' (use on a DB host with ORACLE_SID set).
  -h, --help    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tns)     [[ -n "${2:-}" ]] || { log_error "Missing argument for $1"; exit 2; }
                   TNS_ALIAS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
done

check_oracle_env
DGMGRL="$ORACLE_HOME/bin/dgmgrl"
SQLPLUS="$ORACLE_HOME/bin/sqlplus"
[[ -x "$DGMGRL" ]] || die "dgmgrl not found: $DGMGRL"

if [[ -n "$TNS_ALIAS" ]]; then
    DG_CONN="/@${TNS_ALIAS}"
else
    [[ -n "${ORACLE_SID:-}" ]] || die "No --tns given and ORACLE_SID is not set - nothing to connect to."
    DG_CONN="/"
fi
log_info "Connecting as: dgmgrl ${DG_CONN}"

# ============================================================
# Broker view
# ============================================================

log_section "Broker: SHOW CONFIGURATION"
"$DGMGRL" -silent "$DG_CONN" "show configuration" 2>&1 || true

log_section "Broker: SHOW FAST_START FAILOVER"
FSFO_OUT=$("$DGMGRL" -silent "$DG_CONN" "show fast_start failover" 2>&1 || true)
printf '%s\n' "$FSFO_OUT"

log_section "Broker: SHOW OBSERVER"
"$DGMGRL" -silent "$DG_CONN" "show observer" 2>&1 || true

# ============================================================
# V$DATABASE view (queried on the primary via the same connection)
# ============================================================

log_section "V\$DATABASE Observer Columns"

if [[ -n "$TNS_ALIAS" ]]; then
    SQL_CONN=("/@${TNS_ALIAS}" "as" "sysdg")
else
    SQL_CONN=("/" "as" "sysdba")
fi

VDB_OUT=$("$SQLPLUS" -s -L "${SQL_CONN[@]}" <<EOF 2>&1 || true
set pagesize 0 heading off feedback off linesize 200
select 'FS_FAILOVER_STATUS='           || fs_failover_status           from v\$database;
select 'FS_FAILOVER_OBSERVER_PRESENT=' || fs_failover_observer_present from v\$database;
select 'FS_FAILOVER_OBSERVER_HOST='    || fs_failover_observer_host    from v\$database;
select 'FS_FAILOVER_CURRENT_TARGET='   || fs_failover_current_target   from v\$database;
exit
EOF
)
printf '%s\n' "$VDB_OUT" | grep -E '^FS_FAILOVER' || log_warn "Could not query V\$DATABASE via this connection."

log_section "Password File: SYSDG Holders (V\$PWFILE_USERS)"
"$SQLPLUS" -s -L "${SQL_CONN[@]}" <<EOF 2>&1 | grep -Ev '^ *$' || log_warn "Could not query V\$PWFILE_USERS."
set pagesize 100 feedback off linesize 200
col username format a30
select username, sysdba, sysdg from v\$pwfile_users;
exit
EOF

# ============================================================
# Verdict
# ============================================================

log_section "Verdict"

PRESENT=$(printf '%s\n' "$VDB_OUT" | sed -n 's/^FS_FAILOVER_OBSERVER_PRESENT=//p' | tr -d ' \r' | head -1)

if [[ "$PRESENT" == "YES" ]]; then
    log_info "Observer is PRESENT. If SHOW OBSERVER above lists the expected host,"
    log_info "the conversion is complete."
    log_info "Final check on the OBSERVER host: the observer's dgmgrl process must"
    log_info "have been started via wallet ('dgmgrl /@...'), not 'sys/...@...':"
    log_info "  ps -eo args | grep -i 'dgmgrl' | grep -iv grep"
    exit 0
elif [[ "$PRESENT" == "NO" ]]; then
    log_error "FS_FAILOVER_OBSERVER_PRESENT=NO - the observer is not connected."
    log_error "Check the observer log (fsfo_observer.log) on the observer host."
    exit 1
else
    log_warn "Could not determine observer presence from V\$DATABASE."
    if printf '%s\n' "$FSFO_OUT" | grep -qi 'disabled'; then
        log_warn "Fast-Start Failover appears to be DISABLED on this configuration."
    fi
    exit 1
fi
