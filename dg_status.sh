#!/usr/bin/env bash
# =============================================================================
# Oracle Data Guard - Quick Status Dashboard
# =============================================================================
#
# Single-command health check for an Oracle 19c Data Guard configuration.
# Connects to primary and standby over SSH, queries V$ views and DGMGRL,
# and prints a colour-coded dashboard with OK / !! / XX indicators.
#
# Prerequisites:
#   - SSH access to both primary and standby DB hosts (directly or via jump)
#   - Oracle OS authentication (sqlplus / as sysdba) on both hosts
#   - DG Broker running (dg_broker_start = TRUE)
#   - A config file providing SSH connection details (see tests/e2e/config.env)
#
# SID resolution order:
#   1. -s / --sid flag
#   2. $ORACLE_SID environment variable
#   3. Auto-detect from running ora_pmon_ process on primary host
#   The standby SID is always auto-detected from its pmon process.
#
# Usage:
#   bash dg_status.sh                           # Use $ORACLE_SID or auto-detect
#   bash dg_status.sh -s cdb1                   # Specify Oracle SID explicitly
#   bash dg_status.sh -c /path/to/config.env    # Use custom SSH config file
#
#
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors, layout, configurable thresholds, lag parsing, generic text/box
# rendering primitives (repeat_char/fit_text/wrap_text/row/header/subheader/
# status_icon/warn_icon/short_hostname/extract_first_status/format_services/
# compute_fra_*), and the shared awk log-filter constants all live in
# common/dg_render_common.sh now - shared with common/dg_local_status_common.sh
# (WS4.2/4.3/4.4). dg_status.sh only ever sources files under common/, so it
# stays runnable from a bare jump-host checkout.
source "${SCRIPT_DIR}/common/dg_render_common.sh"

# -- Exit codes (WS4.1 + L1) ---------------------------------------------------
# 0 healthy, 1 warnings only, 2 errors present, 3 usage/pre-flight error.
# The distinct usage code keeps a mistyped flag or a missing config file from
# being reported to a monitoring wrapper as "1 warning" / "2 errors".
EXIT_USAGE=3

usage() {
    printf "Usage: bash dg_status.sh [-c config.env] [-s SID] [--no-color]\n"
    printf "  -c, --config FILE   SSH connection config (default: tests/e2e/config.env)\n"
    printf "  -s, --sid SID       Oracle SID (default: \$ORACLE_SID, then auto-detect)\n"
    printf "  --no-color          Disable colored output (also honors NO_COLOR)\n"
    printf "\n"
    printf "Exit codes: 0 healthy, 1 warnings, 2 errors, %s usage/pre-flight error\n" "$EXIT_USAGE"
}

# -- Parse args ---------------------------------------------------------------
CONFIG_FILE="${SCRIPT_DIR}/tests/e2e/config.env"
ORACLE_SID_OVERRIDE=""
NO_COLOR_FLAG=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            if [[ $# -lt 2 ]]; then
                printf "ERROR: %s requires a file argument\n" "$1" >&2
                usage >&2
                exit $EXIT_USAGE
            fi
            CONFIG_FILE="$2"; shift 2 ;;
        -s|--sid)
            if [[ $# -lt 2 ]]; then
                printf "ERROR: %s requires a SID argument\n" "$1" >&2
                usage >&2
                exit $EXIT_USAGE
            fi
            ORACLE_SID_OVERRIDE="$2"; shift 2 ;;
        --no-color)  NO_COLOR_FLAG=true; shift ;;
        -h|--help)
            usage
            exit 0 ;;
        *)
            printf "Unknown option: %s\n" "$1" >&2
            usage >&2
            exit $EXIT_USAGE ;;
    esac
done

# Re-initialize colors now that --no-color has been parsed, and BEFORE any
# output is produced below (the missing-config-file error is the first
# possible output in this script) - satisfies WS4.2's "before any output"
# requirement, and confirmed by inspection: `bash dg_status.sh | cat` emits
# no escape codes since stdout is not a tty in that pipeline either way.
$NO_COLOR_FLAG && dg_render_init_colors 1

if [[ ! -f "$CONFIG_FILE" ]]; then
    printf "ERROR: Config file not found: %s\n" "$CONFIG_FILE" >&2
    exit $EXIT_USAGE
fi
source "$CONFIG_FILE"

# -- Config pre-flight ---------------------------------------------------------
# Verify the settings the rest of the script relies on are actually present.
# Without this, a missing key surfaces later as a cryptic `set -u: unbound
# variable` abort deep inside SSH setup or SQL generation.
_REQUIRED_CONFIG_KEYS=(PRIMARY_HOST STANDBY_HOST
    PRIMARY_ORACLE_HOSTNAME STANDBY_ORACLE_HOSTNAME SSH_USER SSH_OPTS
    ORACLE_HOME ORACLE_BASE)
# JUMP_HOST is deliberately NOT required: an empty JUMP_HOST means "connect
# to the DB hosts directly" (same convention as the E2E harness), and the
# jump-skip test below already degrades to no -J in that case. JUMP_USER is
# only needed when a jump host is actually in play.
if [[ -n "${JUMP_HOST:-}" && -z "${JUMP_USER:-}" ]]; then
    printf "ERROR: Config file %s sets JUMP_HOST but not JUMP_USER\n" "$CONFIG_FILE" >&2
    exit $EXIT_USAGE
fi
_MISSING_CONFIG_KEYS=()
for _key in "${_REQUIRED_CONFIG_KEYS[@]}"; do
    [[ -z "${!_key:-}" ]] && _MISSING_CONFIG_KEYS+=("$_key")
done
if [[ ${#_MISSING_CONFIG_KEYS[@]} -gt 0 ]]; then
    printf "ERROR: Config file %s is missing required setting(s):\n" "$CONFIG_FILE" >&2
    for _key in "${_MISSING_CONFIG_KEYS[@]}"; do
        printf "  - %s\n" "$_key" >&2
    done
    exit $EXIT_USAGE
fi
unset _key _REQUIRED_CONFIG_KEYS _MISSING_CONFIG_KEYS

# -- SSH setup ----------------------------------------------------------------
JUMP_SSH_PORT="${JUMP_SSH_PORT:-22}"
PRIMARY_SSH_PORT="${PRIMARY_SSH_PORT:-22}"
STANDBY_SSH_PORT="${STANDBY_SSH_PORT:-22}"
DB_SSH_KEY_OPT=""
[[ -n "${SSH_KEY:-}" ]] && DB_SSH_KEY_OPT="-i ${SSH_KEY}"

# Skip ProxyJump if we're already on the jump host
_CURRENT_HOST=$(hostname 2>/dev/null || uname -n 2>/dev/null || printf 'unknown')
_CURRENT_HOST=${_CURRENT_HOST%%.*}
if [[ -z "${JUMP_HOST:-}" || "$_CURRENT_HOST" == "${JUMP_HOST}"* ]]; then
    _JUMP_OPT=""
else
    _JUMP_OPT="-J ${JUMP_USER}@${JUMP_HOST}:${JUMP_SSH_PORT}"
fi

_ssh_raw() {
    local host="$1" port="$2" cmd="$3"
    ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} ${_JUMP_OPT} \
        -p "${port}" "${SSH_USER}@${host}" "${cmd}" 2>&1
}

# Same as _ssh_raw but WITHOUT merging the remote/ssh stderr into stdout.
# Used for streams that get parsed (M23): an SSH login banner, an MOTD or a
# "Warning: Permanently added ..." line printed on stderr must never end up
# in data we run sed over.
_ssh_raw_stdout() {
    local host="$1" port="$2" cmd="$3"
    ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} ${_JUMP_OPT} \
        -p "${port}" "${SSH_USER}@${host}" "${cmd}" 2>/dev/null
}

_ssh_ora() {
    local host="$1" port="$2" sid="$3" cmd="$4"
    ssh ${SSH_OPTS} ${DB_SSH_KEY_OPT} ${_JUMP_OPT} \
        -p "${port}" "${SSH_USER}@${host}" \
        "export ORACLE_HOME='${ORACLE_HOME}'; \
         export ORACLE_BASE='${ORACLE_BASE}'; \
         export ORACLE_SID='${sid}'; \
         export PATH=\"\${ORACLE_HOME}/bin:\${PATH}\"; \
         ${cmd}" 2>&1
}

# -- Helpers ------------------------------------------------------------------
# repeat_char/short_hostname/extract_first_status/fit_text/wrap_text/
# format_services/row/header/subheader/status_icon/warn_icon now live in
# common/dg_render_common.sh (sourced above), shared with
# common/dg_local_status_common.sh (WS4.4).

make_temp_dir() {
    if command -v mktemp >/dev/null 2>&1; then
        mktemp -d 2>/dev/null && return
    fi
    local dir="${TMPDIR:-/tmp}/dg_status.$$"
    mkdir -m 700 -p "$dir" && printf '%s\n' "$dir"
}

ERRORS=0; WARNINGS=0

err()  { ERRORS=$((ERRORS+1)); }
warn() { WARNINGS=$((WARNINGS+1)); }

declare -a SUMMARY_ERRORS=()
declare -a SUMMARY_WARNINGS=()

add_summary_error() {
    local message="$1"
    SUMMARY_ERRORS+=("$message")
    err
}

add_summary_warning() {
    local message="$1"
    SUMMARY_WARNINGS+=("$message")
    warn
}

# -- Connectivity pre-check ----------------------------------------------------
# A dead host must never render as blank fields with an overall HEALTHY
# status. Check both sides can be reached before we try to use them for
# anything (SID auto-detection included).
PRIMARY_REACHABLE=true
STANDBY_REACHABLE=true

_check_ssh_host() {
    local host="$1" port="$2"
    local out
    out=$(_ssh_raw "${host}" "${port}" "echo DG_SSH_OK")
    printf '%s\n' "$out" | grep -q '^DG_SSH_OK$'
}

if ! _check_ssh_host "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}"; then
    PRIMARY_REACHABLE=false
    printf "ERROR: cannot SSH to primary (%s:%s)\n" "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}"
    add_summary_error "Cannot SSH to primary host ${PRIMARY_HOST}:${PRIMARY_SSH_PORT}"
fi

if ! _check_ssh_host "${STANDBY_HOST}" "${STANDBY_SSH_PORT}"; then
    STANDBY_REACHABLE=false
    printf "ERROR: cannot SSH to standby (%s:%s)\n" "${STANDBY_HOST}" "${STANDBY_SSH_PORT}"
    add_summary_error "Cannot SSH to standby host ${STANDBY_HOST}:${STANDBY_SSH_PORT}"
fi

# -- Resolve SID --------------------------------------------------------------
# Priority: -s flag > $ORACLE_SID > auto-detect from pmon
_detect_pmon_sid() {
    local host="$1" port="$2"
    local raw pmon_line sid
    # `[o]ra_pmon_` keeps the grep's own process line from matching; the
    # explicit `+ASM` exclusion prevents an ASM instance pmon from being
    # picked up ahead of (or instead of) the real database instance.
    #
    # M23: the remote side tags every candidate line with a `DG_PMON|`
    # marker and we filter on that marker LOCALLY before running sed.
    # Without it, anything the login shell prints (a /etc/motd banner, a
    # "Last login:" line, an sshd warning) lands in the same stream and the
    # unanchored `sed 's/.*ora_pmon_//'` happily turns it into a "SID".
    # _ssh_raw_stdout additionally keeps stderr out of the parsed stream.
    raw=$(_ssh_raw_stdout "${host}" "${port}" \
        "ps -ef 2>/dev/null | grep '[o]ra_pmon_' | grep -v '+ASM' | sed 's/^/DG_PMON|/'")
    pmon_line=$(printf '%s\n' "$raw" | grep '^DG_PMON|' | grep 'ora_pmon_' | head -1)
    [[ -z "$pmon_line" ]] && return 0
    # Anchored extraction: in real `ps -ef` output `ora_pmon_<SID>` is the
    # LAST token on the line, and a SID is [A-Za-z][A-Za-z0-9_$]*. Requiring
    # both means a prose line that merely mentions ora_pmon_ yields nothing
    # at all, instead of the old unanchored `s/.*ora_pmon_//` turning the
    # rest of the sentence into a "SID".
    sid=$(printf '%s' "$pmon_line" \
        | sed 's/[[:space:]]*$//' \
        | sed -n 's/.*ora_pmon_\([A-Za-z][A-Za-z0-9_$]*\)$/\1/p')
    printf '%s' "$sid"
}

_validate_sid() {
    [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_$]*$ ]]
}

if [[ -n "$ORACLE_SID_OVERRIDE" ]]; then
    DETECTED_SID="$ORACLE_SID_OVERRIDE"
    if ! _validate_sid "$DETECTED_SID"; then
        printf "ERROR: SID '%s' from -s/--sid looks invalid\n" "$DETECTED_SID" >&2
        exit $EXIT_USAGE
    fi
elif [[ -n "${ORACLE_SID:-}" ]]; then
    DETECTED_SID="$ORACLE_SID"
    if ! _validate_sid "$DETECTED_SID"; then
        printf "ERROR: SID '%s' from \$ORACLE_SID looks invalid; use -s/--sid to specify explicitly\n" "$DETECTED_SID" >&2
        exit $EXIT_USAGE
    fi
elif $PRIMARY_REACHABLE; then
    DETECTED_SID=$(_detect_pmon_sid "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}")
    if [[ -z "$DETECTED_SID" ]]; then
        # Reachable host, no pmon: the instance is down. That is a genuine
        # finding, not an operator mistake - report it with the "errors
        # present" code rather than the usage code.
        printf "ERROR: No Oracle instance detected on primary (%s:%s) - no ora_pmon_ process is running\n" \
            "$PRIMARY_HOST" "$PRIMARY_SSH_PORT" >&2
        exit 2
    fi
    if ! _validate_sid "$DETECTED_SID"; then
        printf "ERROR: Auto-detected primary SID '%s' looks invalid; use -s/--sid to specify explicitly\n" "$DETECTED_SID" >&2
        exit $EXIT_USAGE
    fi
else
    # Primary unreachable: also a genuine finding (already counted as a
    # summary error above), so exit 2 rather than the usage code.
    printf "ERROR: cannot SSH to primary (%s:%s) to auto-detect the Oracle SID; use -s/--sid or set \$ORACLE_SID\n" \
        "$PRIMARY_HOST" "$PRIMARY_SSH_PORT" >&2
    exit 2
fi

# Detect standby SID (may differ)
if $STANDBY_REACHABLE; then
    DETECTED_SID_STB=$(_detect_pmon_sid "${STANDBY_HOST}" "${STANDBY_SSH_PORT}")
    if [[ -z "$DETECTED_SID_STB" ]]; then
        DETECTED_SID_STB="$DETECTED_SID"
        add_summary_error "No Oracle instance detected on standby ${STANDBY_HOST}:${STANDBY_SSH_PORT} (no ora_pmon_ process)"
    elif ! _validate_sid "$DETECTED_SID_STB"; then
        printf "ERROR: Auto-detected standby SID '%s' looks invalid; use -s/--sid to specify explicitly\n" "$DETECTED_SID_STB" >&2
        exit $EXIT_USAGE
    fi
else
    DETECTED_SID_STB="$DETECTED_SID"
fi

# -- Title --------------------------------------------------------------------
printf "\n ${BOLD}${CYAN}Data Guard Status Dashboard${NC}  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')${NC}\n"
printf " ${DIM}Primary: ${PRIMARY_ORACLE_HOSTNAME} (SID: ${DETECTED_SID})  |  Standby: ${STANDBY_ORACLE_HOSTNAME} (SID: ${DETECTED_SID_STB})${NC}\n"

# -- Collect data in parallel -------------------------------------------------
TMP=$(make_temp_dir)
trap 'rm -rf "$TMP"' EXIT

# Primary: SQL data + DGMGRL
if $PRIMARY_REACHABLE; then
_ssh_ora "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}" "${DETECTED_SID}" "sqlplus -s / as sysdba <<'SQL'
SET HEADING OFF FEEDBACK OFF LINESIZE 300 PAGESIZE 0 TRIMSPOOL ON
${DG_SQL_SELECT_DBSTATUS_FULL}
${DG_SQL_SELECT_DGPARAMS}
${DG_SQL_SELECT_REDOLOG}
${DG_SQL_SELECT_SRLCOUNT}
${DG_SQL_SELECT_ARCHGAP}
SELECT 'UNNAMEDDF|' || COUNT(*) FROM V\$DATAFILE WHERE NAME LIKE '%UNNAMED%';
SELECT 'ARCHDEST|' || DEST_ID || '|' || STATUS || '|' || ERROR FROM V\$ARCHIVE_DEST WHERE DEST_ID IN (1,2);
${DG_SQL_SELECT_FSFODB}
${DG_SQL_SELECT_FRA}
${DG_SQL_SELECT_SERVICE}
EXIT;
SQL" > "$TMP/primary_sql" &

_ssh_ora "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}" "${DETECTED_SID}" \
    "dgmgrl -silent / 'SHOW CONFIGURATION'" > "$TMP/dgmgrl_config" &

_ssh_ora "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}" "${DETECTED_SID}" \
    "dgmgrl -silent / 'SHOW FAST_START FAILOVER'" > "$TMP/dgmgrl_fsfo" 2>/dev/null &
fi

# Standby: SQL data
if $STANDBY_REACHABLE; then
_ssh_ora "${STANDBY_HOST}" "${STANDBY_SSH_PORT}" "${DETECTED_SID_STB}" "sqlplus -s / as sysdba <<'SQL'
SET HEADING OFF FEEDBACK OFF LINESIZE 300 PAGESIZE 0 TRIMSPOOL ON
SELECT 'DBSTATUS|' || DATABASE_ROLE || '|' || OPEN_MODE || '|' || PROTECTION_MODE || '|' || SWITCHOVER_STATUS || '|' || DB_UNIQUE_NAME FROM V\$DATABASE;
${DG_SQL_SELECT_MRP}
${DG_SQL_SELECT_DGSTATS}
${DG_SQL_SELECT_ARCHGAP}
SELECT 'UNNAMEDDF|' || COUNT(*) FROM V\$DATAFILE WHERE NAME LIKE '%UNNAMED%';
${DG_SQL_SELECT_APPLYINFO}
${DG_SQL_SELECT_SRLCOUNT}
${DG_SQL_SELECT_RECMODE}
${DG_SQL_SELECT_FRA}
${DG_SQL_SELECT_SERVICE}
EXIT;
SQL" > "$TMP/standby_sql" &
fi

# Alert log: primary (get diag trace path, then extract DG-related entries with timestamps)
# Oracle 19c alert log has ISO timestamps on their own line (e.g. 2024-01-15T10:30:45.123+00:00)
# awk tracks the last timestamp and prepends it to matching DG lines
if $PRIMARY_REACHABLE; then
_ssh_ora "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}" "${DETECTED_SID}" "
TRACE_DIR=\$(sqlplus -s / as sysdba <<'SQLT'
SET HEADING OFF FEEDBACK OFF LINESIZE 500 PAGESIZE 0 TRIMSPOOL ON
SELECT VALUE FROM V\$DIAG_INFO WHERE NAME = 'Diag Trace';
EXIT;
SQLT
)
TRACE_DIR=\$(printf '%s' \"\$TRACE_DIR\" | xargs)
ALERT_FILE=\"\${TRACE_DIR}/alert_${DETECTED_SID}.log\"
if [ -f \"\$ALERT_FILE\" ]; then
    printf 'FILE|%s\n' \"\$ALERT_FILE\"
    tail -2000 \"\$ALERT_FILE\" | awk '${DG_ALERT_LOG_AWK_FILTER}' | tail -15 | sed 's/^/ENTRY|/'
else
    printf 'MISSING|%s\n' \"\$ALERT_FILE\"
fi
" > "$TMP/primary_alert" 2>/dev/null &
fi

# Alert log: standby
if $STANDBY_REACHABLE; then
_ssh_ora "${STANDBY_HOST}" "${STANDBY_SSH_PORT}" "${DETECTED_SID_STB}" "
TRACE_DIR=\$(sqlplus -s / as sysdba <<'SQLT'
SET HEADING OFF FEEDBACK OFF LINESIZE 500 PAGESIZE 0 TRIMSPOOL ON
SELECT VALUE FROM V\$DIAG_INFO WHERE NAME = 'Diag Trace';
EXIT;
SQLT
)
TRACE_DIR=\$(printf '%s' \"\$TRACE_DIR\" | xargs)
ALERT_FILE=\"\${TRACE_DIR}/alert_${DETECTED_SID_STB}.log\"
if [ -f \"\$ALERT_FILE\" ]; then
    printf 'FILE|%s\n' \"\$ALERT_FILE\"
    tail -2000 \"\$ALERT_FILE\" | awk '${DG_ALERT_LOG_AWK_FILTER}' | tail -15 | sed 's/^/ENTRY|/'
else
    printf 'MISSING|%s\n' \"\$ALERT_FILE\"
fi
" > "$TMP/standby_alert" 2>/dev/null &
fi

# Broker log (drc<SID>.log): primary
if $PRIMARY_REACHABLE; then
_ssh_ora "${PRIMARY_HOST}" "${PRIMARY_SSH_PORT}" "${DETECTED_SID}" "
TRACE_DIR=\$(sqlplus -s / as sysdba <<'SQLT'
SET HEADING OFF FEEDBACK OFF LINESIZE 500 PAGESIZE 0 TRIMSPOOL ON
SELECT VALUE FROM V\$DIAG_INFO WHERE NAME = 'Diag Trace';
EXIT;
SQLT
)
TRACE_DIR=\$(printf '%s' \"\$TRACE_DIR\" | xargs)
DRC_FILE=\"\${TRACE_DIR}/drc${DETECTED_SID}.log\"
if [ -f \"\$DRC_FILE\" ]; then
    printf 'FILE|%s\n' \"\$DRC_FILE\"
    tail -500 \"\$DRC_FILE\" | awk '${DG_BROKER_LOG_AWK_FILTER}' | tail -10 | sed 's/^/ENTRY|/'
else
    printf 'MISSING|%s\n' \"\$DRC_FILE\"
fi
" > "$TMP/primary_drc" 2>/dev/null &
fi

# Broker log (drc<SID>.log): standby
if $STANDBY_REACHABLE; then
_ssh_ora "${STANDBY_HOST}" "${STANDBY_SSH_PORT}" "${DETECTED_SID_STB}" "
TRACE_DIR=\$(sqlplus -s / as sysdba <<'SQLT'
SET HEADING OFF FEEDBACK OFF LINESIZE 500 PAGESIZE 0 TRIMSPOOL ON
SELECT VALUE FROM V\$DIAG_INFO WHERE NAME = 'Diag Trace';
EXIT;
SQLT
)
TRACE_DIR=\$(printf '%s' \"\$TRACE_DIR\" | xargs)
DRC_FILE=\"\${TRACE_DIR}/drc${DETECTED_SID_STB}.log\"
if [ -f \"\$DRC_FILE\" ]; then
    printf 'FILE|%s\n' \"\$DRC_FILE\"
    tail -500 \"\$DRC_FILE\" | awk '${DG_BROKER_LOG_AWK_FILTER}' | tail -10 | sed 's/^/ENTRY|/'
else
    printf 'MISSING|%s\n' \"\$DRC_FILE\"
fi
" > "$TMP/standby_drc" 2>/dev/null &
fi

wait

# -- Parse primary SQL --------------------------------------------------------
PRI_SQL=$(cat "$TMP/primary_sql" 2>/dev/null)

PRI_DBSTATUS=$(printf '%s\n' "$PRI_SQL" | grep '^DBSTATUS|' | head -1 | sed 's/^DBSTATUS|//')
PRI_ROLE=$(printf '%s' "$PRI_DBSTATUS" | awk -F'|' '{print $1}' | xargs)
PRI_OPEN=$(printf '%s' "$PRI_DBSTATUS" | awk -F'|' '{print $2}' | xargs)
PRI_PROTECT=$(printf '%s' "$PRI_DBSTATUS" | awk -F'|' '{print $3}' | xargs)
PRI_SWITCH=$(printf '%s' "$PRI_DBSTATUS" | awk -F'|' '{print $4}' | xargs)
PRI_FORCE=$(printf '%s' "$PRI_DBSTATUS" | awk -F'|' '{print $5}' | xargs)
PRI_FLASH=$(printf '%s' "$PRI_DBSTATUS" | awk -F'|' '{print $6}' | xargs)
PRI_DBUNIQ=$(printf '%s' "$PRI_DBSTATUS" | awk -F'|' '{print $7}' | xargs)

PRI_BROKER=$(printf '%s\n' "$PRI_SQL" | grep 'dg_broker_start' | awk -F'|' '{print $3}' | xargs)
PRI_ARCHGAP=$(printf '%s\n' "$PRI_SQL" | grep '^ARCHGAP|' | awk -F'|' '{print $2}' | xargs)
PRI_UNNAMED=$(printf '%s\n' "$PRI_SQL" | grep '^UNNAMEDDF|' | awk -F'|' '{print $2}' | xargs)
case "$PRI_UNNAMED" in ''|*[!0-9]*) PRI_UNNAMED="" ;; esac
PRI_REDO=$(printf '%s\n' "$PRI_SQL" | grep '^REDOLOG|' | sed 's/^REDOLOG|//')
PRI_REDO_CNT=$(printf '%s' "$PRI_REDO" | awk -F'|' '{print $1}' | xargs)
PRI_REDO_MB=$(printf '%s' "$PRI_REDO" | awk -F'|' '{print $2}' | xargs)
PRI_SRL=$(printf '%s\n' "$PRI_SQL" | grep '^SRLCOUNT|' | awk -F'|' '{print $2}' | xargs)
PRI_DEST2_STATUS=$(printf '%s\n' "$PRI_SQL" | grep '^ARCHDEST|2|' | awk -F'|' '{print $3}' | xargs)
PRI_DEST2_ERROR=$(printf '%s\n' "$PRI_SQL" | grep '^ARCHDEST|2|' | awk -F'|' '{print $4}' | xargs)

# FRA
PRI_FRA=$(printf '%s\n' "$PRI_SQL" | grep '^FRA|' | head -1 | sed 's/^FRA|//')
PRI_FRA_PATH=$(printf '%s' "$PRI_FRA" | awk -F'|' '{print $1}' | xargs)
PRI_FRA_SIZE=$(printf '%s' "$PRI_FRA" | awk -F'|' '{print $2}' | xargs)
PRI_FRA_USED=$(printf '%s' "$PRI_FRA" | awk -F'|' '{print $3}' | xargs)
PRI_FRA_RECLAIM=$(printf '%s' "$PRI_FRA" | awk -F'|' '{print $4}' | xargs)
PRI_FRA_FILES=$(printf '%s' "$PRI_FRA" | awk -F'|' '{print $5}' | xargs)
PRI_SERVICES=$(format_services "$(printf '%s\n' "$PRI_SQL" | grep '^SERVICE|' | sed 's/^SERVICE|//')")

# FSFO runtime state from V$DATABASE (M17). The FSFODB row was collected all
# along but never parsed, so an FSFO configuration whose observer had died
# still rendered a green "Enabled" and exited 0.
PRI_FSFODB=$(printf '%s\n' "$PRI_SQL" | grep '^FSFODB|' | head -1 | sed 's/^FSFODB|//')
PRI_FSFO_STATUS=$(printf '%s' "$PRI_FSFODB" | awk -F'|' '{print $1}' | xargs)
PRI_FSFO_OBSERVER_PRESENT=$(printf '%s' "$PRI_FSFODB" | awk -F'|' '{print $2}' | xargs)
PRI_FSFO_OBSERVER_HOST=$(printf '%s' "$PRI_FSFODB" | awk -F'|' '{print $3}' | xargs)

# -- Parse standby SQL --------------------------------------------------------
STB_SQL=$(cat "$TMP/standby_sql" 2>/dev/null)

STB_DBSTATUS=$(printf '%s\n' "$STB_SQL" | grep '^DBSTATUS|' | head -1 | sed 's/^DBSTATUS|//')
STB_ROLE=$(printf '%s' "$STB_DBSTATUS" | awk -F'|' '{print $1}' | xargs)
STB_OPEN=$(printf '%s' "$STB_DBSTATUS" | awk -F'|' '{print $2}' | xargs)
STB_PROTECT=$(printf '%s' "$STB_DBSTATUS" | awk -F'|' '{print $3}' | xargs)
STB_SWITCH=$(printf '%s' "$STB_DBSTATUS" | awk -F'|' '{print $4}' | xargs)
STB_DBUNIQ=$(printf '%s' "$STB_DBSTATUS" | awk -F'|' '{print $5}' | xargs)

STB_MRP=$(printf '%s\n' "$STB_SQL" | grep '^MRP|' | head -1 | sed 's/^MRP|//')
STB_MRP_STATUS=$(printf '%s' "$STB_MRP" | awk -F'|' '{print $2}' | xargs)
STB_MRP_SEQ=$(printf '%s' "$STB_MRP" | awk -F'|' '{print $3}' | xargs)
STB_RECOVERY_MODE=$(printf '%s\n' "$STB_SQL" | grep '^RECMODE|' | head -1 | awk -F'|' '{print $2}' | xargs)

STB_TRANSPORT_LAG=$(printf '%s\n' "$STB_SQL" | grep 'transport lag' | awk -F'|' '{print $3}' | xargs)
STB_APPLY_LAG=$(printf '%s\n' "$STB_SQL" | grep 'apply lag' | awk -F'|' '{print $3}' | xargs)

STB_ARCHGAP=$(printf '%s\n' "$STB_SQL" | grep '^ARCHGAP|' | awk -F'|' '{print $2}' | xargs)
STB_UNNAMED=$(printf '%s\n' "$STB_SQL" | grep '^UNNAMEDDF|' | awk -F'|' '{print $2}' | xargs)
case "$STB_UNNAMED" in ''|*[!0-9]*) STB_UNNAMED="" ;; esac
STB_APPLYINFO=$(printf '%s\n' "$STB_SQL" | grep '^APPLYINFO|' | sed 's/^APPLYINFO|//')
STB_LAST_APPLIED=$(printf '%s' "$STB_APPLYINFO" | awk -F'|' '{print $1}' | xargs)
STB_LAST_RECEIVED=$(printf '%s' "$STB_APPLYINFO" | awk -F'|' '{print $2}' | xargs)
STB_SRL=$(printf '%s\n' "$STB_SQL" | grep '^SRLCOUNT|' | awk -F'|' '{print $2}' | xargs)

# FRA
STB_FRA=$(printf '%s\n' "$STB_SQL" | grep '^FRA|' | head -1 | sed 's/^FRA|//')
STB_FRA_PATH=$(printf '%s' "$STB_FRA" | awk -F'|' '{print $1}' | xargs)
STB_FRA_SIZE=$(printf '%s' "$STB_FRA" | awk -F'|' '{print $2}' | xargs)
STB_FRA_USED=$(printf '%s' "$STB_FRA" | awk -F'|' '{print $3}' | xargs)
STB_FRA_RECLAIM=$(printf '%s' "$STB_FRA" | awk -F'|' '{print $4}' | xargs)
STB_FRA_FILES=$(printf '%s' "$STB_FRA" | awk -F'|' '{print $5}' | xargs)
STB_SERVICES=$(format_services "$(printf '%s\n' "$STB_SQL" | grep '^SERVICE|' | sed 's/^SERVICE|//')")

# -- Parse DGMGRL output -----------------------------------------------------
DGMGRL_CONFIG=$(cat "$TMP/dgmgrl_config" 2>/dev/null)
DGMGRL_FSFO=$(cat "$TMP/dgmgrl_fsfo" 2>/dev/null)

BROKER_CFG_NAME=$(printf '%s\n' "$DGMGRL_CONFIG" | grep 'Configuration -' | sed 's/.*Configuration - //' | xargs)
BROKER_OVERALL=$(printf '%s\n' "$DGMGRL_CONFIG" | tail -5 | extract_first_status)

# =============================================================================
# Display
# =============================================================================

# -- Summary box --------------------------------------------------------------
_W=29
_BAR=$(repeat_char '─' "$_W")

box_row() {
    local left="$1" right="$2"
    local lp rp
    left=$(fit_text "$left" "$_W")
    right=$(fit_text "$right" "$_W")
    lp=$(strip_ansi "$left")
    rp=$(strip_ansi "$right")
    local lpad=$((_W - ${#lp})); [[ $lpad -lt 0 ]] && lpad=0
    local rpad=$((_W - ${#rp})); [[ $rpad -lt 0 ]] && rpad=0
    printf ' │ %b%*s│ %b%*s│\n' "$left" "$lpad" "" "$right" "$rpad" ""
}

# Quick health check for summary dots (computed early, displayed later)
PRI_OK=true; STB_OK=true
printf '%s' "${PRI_ROLE:-}" | grep -qi "PRIMARY" || PRI_OK=false
printf '%s' "${PRI_OPEN:-}" | grep -qi "READ WRITE" || PRI_OK=false
printf '%s' "${STB_ROLE:-}" | grep -qi "PHYSICAL STANDBY" || STB_OK=false
if [[ -z "${STB_MRP_STATUS:-}" ]]; then
    STB_OK=false
else
    printf '%s' "$STB_MRP_STATUS" | grep -qiE "APPLYING_LOG|WAIT_FOR_LOG" || STB_OK=false
fi
$PRIMARY_REACHABLE || PRI_OK=false
$STANDBY_REACHABLE || STB_OK=false
if $PRI_OK; then PRI_DOT="${GREEN}●${NC}"; else PRI_DOT="${RED}●${NC}"; fi
if $STB_OK; then STB_DOT="${GREEN}●${NC}"; else STB_DOT="${RED}●${NC}"; fi

# -- Recent Alert Log (DG-related) --------------------------------------------
# Shown first (least urgent — historical context scrolls off the top)
header "RECENT ALERT LOG (Data Guard)"

# L20: the path that was checked is ALWAYS printed, and "the file is not
# there" (wrong SID, non-default diagnostic_dest, log never created) is
# rendered differently from "the file was read and nothing matched".
# Previously both showed a bare "(none)".
# $3 = "warn" to raise a summary warning when the file is missing (used for
# the alert log, which must exist on a running instance; the broker log is
# legitimately absent before the broker has ever started).
_show_alert_entries() {
    local label="$1" file="$2" missing_severity="${3:-info}"
    local raw filepath missingpath entries
    raw=$(cat "$file" 2>/dev/null | sed '/^$/d')
    filepath=$(printf '%s\n' "$raw" | grep '^FILE|' | head -1 | sed 's/^FILE|//')
    missingpath=$(printf '%s\n' "$raw" | grep '^MISSING|' | head -1 | sed 's/^MISSING|//')
    # Only marker-tagged lines are real log content; anything else in the
    # stream is SSH/login noise.
    entries=$(printf '%s\n' "$raw" | grep '^ENTRY|' | sed 's/^ENTRY|//')

    if [[ -n "$missingpath" ]]; then
        printf "  ${DIM}%s${NC}\n" "$label"
        printf "    ${YELLOW}(file not found: %s)${NC}\n" "$missingpath"
        if [[ "$missing_severity" == "warn" ]]; then
            add_summary_warning "${label} not found at ${missingpath}"
        fi
        return
    fi
    if [[ -n "$filepath" ]]; then
        printf "  ${DIM}%s (%s)${NC}\n" "$label" "$filepath"
    else
        printf "  ${DIM}%s${NC}\n" "$label"
        printf "    ${YELLOW}(path could not be determined; V\$DIAG_INFO query failed)${NC}\n"
        if [[ "$missing_severity" == "warn" ]]; then
            add_summary_warning "${label} path could not be determined (V\$DIAG_INFO 'Diag Trace' query returned nothing)"
        fi
        return
    fi
    if [[ -z "$entries" ]]; then
        printf "    ${DIM}(0 matched - file read, no Data Guard entries)${NC}\n"
    else
        while IFS= read -r line; do
            local ts="" msg="$line"
            if printf '%s' "$line" | grep -q '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] '; then
                ts="${line:0:19}"
                msg="${line:21}"
            fi
            if printf '%s' "$msg" | grep -qiE 'ORA-|error|fail'; then
                if [[ -n "$ts" ]]; then
                    printf "    ${DIM}%s${NC}  ${RED}%s${NC}\n" "$ts" "$msg"
                else
                    printf "    ${RED}%s${NC}\n" "$msg"
                fi
            else
                if [[ -n "$ts" ]]; then
                    printf "    ${DIM}%s${NC}  %s\n" "$ts" "$msg"
                else
                    printf "    %s\n" "$msg"
                fi
            fi
        done <<< "$entries"
    fi
}

subheader "Primary (${PRIMARY_ORACLE_HOSTNAME})"
if $PRIMARY_REACHABLE; then
    _show_alert_entries "Primary alert log" "$TMP/primary_alert" warn
    printf "\n"
    _show_alert_entries "Primary broker log" "$TMP/primary_drc"
else
    printf "  ${RED}UNREACHABLE${NC} ${DIM}(SSH to primary failed; logs not collected)${NC}\n"
fi

subheader "Standby (${STANDBY_ORACLE_HOSTNAME})"
if $STANDBY_REACHABLE; then
    _show_alert_entries "Standby alert log" "$TMP/standby_alert" warn
    printf "\n"
    _show_alert_entries "Standby broker log" "$TMP/standby_drc"
else
    printf "  ${RED}UNREACHABLE${NC} ${DIM}(SSH to standby failed; logs not collected)${NC}\n"
fi

# -- Primary Database ---------------------------------------------------------
header "PRIMARY DATABASE  (${PRIMARY_ORACLE_HOSTNAME} / ${PRI_DBUNIQ:-?})"

if ! $PRIMARY_REACHABLE; then
    row "Status" "UNREACHABLE (SSH failed)" "$FAIL"
else
subheader "Identity"

icon=$(status_icon "$PRI_ROLE" "PRIMARY")
[[ "$icon" == *"XX"* ]] && add_summary_error "Primary role is '$PRI_ROLE' (expected PRIMARY)"
row "Role" "$PRI_ROLE" "$icon"

icon=$(status_icon "$PRI_OPEN" "READ WRITE")
[[ "$icon" == *"XX"* ]] && add_summary_error "Primary open mode is '$PRI_OPEN' (expected READ WRITE)"
row "Open Mode" "$PRI_OPEN" "$icon"

row "Protection Mode" "$PRI_PROTECT"

icon=$(warn_icon "$PRI_SWITCH" "TO STANDBY" "SESSIONS ACTIVE")
[[ "$icon" == *"!!"* ]] && add_summary_warning "Primary switchover status is '$PRI_SWITCH'"
row "Switchover Status" "$PRI_SWITCH" "$icon"

icon=$(status_icon "$PRI_FORCE" "YES")
[[ "$icon" == *"XX"* ]] && add_summary_error "Force logging is '$PRI_FORCE' on primary"
row "Force Logging" "$PRI_FORCE" "$icon"

icon=$(warn_icon "$PRI_FLASH" "YES")
[[ "$icon" == *"!!"* ]] && add_summary_warning "Flashback is '$PRI_FLASH' on primary"
row "Flashback" "$PRI_FLASH" "$icon"

subheader "Services"

icon=$(status_icon "${PRI_BROKER:-FALSE}" "TRUE")
[[ "$icon" == *"XX"* ]] && add_summary_error "DG Broker is '${PRI_BROKER:-FALSE}' on primary"
row "DG Broker" "${PRI_BROKER:-FALSE}" "$icon"
row "Running Services" "${PRI_SERVICES:-NONE}"

subheader "Redo / Archive"

row "Online Redo Logs" "${PRI_REDO_CNT:-?} groups (${PRI_REDO_MB:-?} MB total)"
if [[ -n "${PRI_SRL:-}" ]] && [[ "${PRI_SRL:-0}" -gt 0 ]]; then
    row "Standby Redo Logs" "${PRI_SRL} groups" "$CHK"
else
    row "Standby Redo Logs" "NONE" "$WARN"; add_summary_warning "Primary has no standby redo logs configured"
fi

if [[ "${PRI_DEST2_STATUS:-}" == "VALID" ]]; then
    row "Archive Dest 2 (Standby)" "$PRI_DEST2_STATUS" "$CHK"
elif [[ -n "${PRI_DEST2_STATUS:-}" ]]; then
    row "Archive Dest 2 (Standby)" "${PRI_DEST2_STATUS} ${PRI_DEST2_ERROR:-}" "$FAIL"; add_summary_error "Archive destination 2 is '${PRI_DEST2_STATUS}' ${PRI_DEST2_ERROR:-}"
fi

if [[ -n "${PRI_ARCHGAP:-}" ]] && [[ "${PRI_ARCHGAP:-0}" -gt 0 ]]; then
    row "Archive Gaps" "${PRI_ARCHGAP} gap(s)!" "$FAIL"; add_summary_error "Primary reports ${PRI_ARCHGAP} archive gap(s)"
fi

if [[ -n "${PRI_UNNAMED:-}" ]] && [[ "${PRI_UNNAMED:-0}" -gt 0 ]]; then
    row "UNNAMED Datafiles" "${PRI_UNNAMED} UNNAMED datafile(s)!" "$FAIL"; add_summary_error "Primary has ${PRI_UNNAMED} UNNAMED datafile(s) (ORA-01274: datafile path not covered by DB_FILE_NAME_CONVERT pairs; repair with ALTER DATABASE CREATE DATAFILE)"
fi

subheader "Recovery Area"

if [[ -n "${PRI_FRA_PATH:-}" ]]; then
    PRI_FRA_EFFECTIVE_USED=$(compute_fra_effective "$PRI_FRA_USED" "$PRI_FRA_RECLAIM")
    PRI_FRA_PCT=$(compute_fra_pct "$PRI_FRA_SIZE" "$PRI_FRA_USED" "$PRI_FRA_RECLAIM")
    icon=$(dg_fra_icon "$PRI_FRA_PCT")
    if [[ "$PRI_FRA_PCT" -ge "$DG_FRA_CRIT_PCT" ]]; then
        add_summary_error "Primary FRA usage is ${PRI_FRA_PCT}%"
    elif [[ "$PRI_FRA_PCT" -ge "$DG_FRA_WARN_PCT" ]]; then
        add_summary_warning "Primary FRA usage is ${PRI_FRA_PCT}%"
    fi
    row "FRA Usage" "${PRI_FRA_EFFECTIVE_USED}/${PRI_FRA_SIZE} GB effective (${PRI_FRA_PCT}%), reclaimable ${PRI_FRA_RECLAIM} GB" "$icon"
    row "FRA Location" "${PRI_FRA_PATH} (${PRI_FRA_FILES:-0} files)"
fi
fi

# -- Standby Database ---------------------------------------------------------
header "STANDBY DATABASE  (${STANDBY_ORACLE_HOSTNAME} / ${STB_DBUNIQ:-?})"

if ! $STANDBY_REACHABLE; then
    row "Status" "UNREACHABLE (SSH failed)" "$FAIL"
else
subheader "Identity"

icon=$(status_icon "$STB_ROLE" "PHYSICAL STANDBY")
[[ "$icon" == *"XX"* ]] && add_summary_error "Standby role is '$STB_ROLE' (expected PHYSICAL STANDBY)"
row "Role" "$STB_ROLE" "$icon"

icon=$(warn_icon "$STB_OPEN" "MOUNTED" "READ ONLY")
[[ "$icon" == *"!!"* ]] && add_summary_warning "Standby open mode is '$STB_OPEN'"
row "Open Mode" "$STB_OPEN" "$icon"

row "Protection Mode" "$STB_PROTECT"

icon=$(warn_icon "$STB_SWITCH" "NOT ALLOWED" "SWITCHOVER PENDING")
row "Switchover Status" "$STB_SWITCH" "$icon"

subheader "Services"

row "Running Services" "${STB_SERVICES:-NONE}"

subheader "Recovery / Apply"

# MRP (Managed Recovery Process)
if [[ -n "${STB_MRP_STATUS:-}" ]]; then
    icon=$(status_icon "$STB_MRP_STATUS" "APPLYING_LOG" "WAIT_FOR_LOG")
    [[ "$icon" == *"XX"* ]] && add_summary_error "MRP status is '$STB_MRP_STATUS'"
    row "MRP Status" "${STB_MRP_STATUS} (seq# ${STB_MRP_SEQ:-?})" "$icon"
else
    row "MRP Status" "NOT RUNNING" "$FAIL"; add_summary_error "MRP is not running on standby"
fi

if [[ -n "${STB_RECOVERY_MODE:-}" ]]; then
    icon=$(warn_icon "$STB_RECOVERY_MODE" "REAL TIME")
    [[ "$icon" == *"!!"* ]] && add_summary_warning "Recovery mode is '${STB_RECOVERY_MODE}' (not real-time apply)"
    row "Recovery Mode" "$STB_RECOVERY_MODE" "$icon"
fi

# Lag (WS4.3: warn only when lag exceeds DG_LAG_WARN_SECONDS, not on any
# nonzero lag; the raw "+DD HH:MI:SS[.FF]" value is parsed to seconds by
# dg_parse_lag_seconds/dg_lag_icon in common/dg_render_common.sh)
if [[ -n "${STB_TRANSPORT_LAG:-}" ]]; then
    icon=$(dg_lag_icon "$STB_TRANSPORT_LAG")
    row "Transport Lag" "$(dg_display_lag_value "$STB_TRANSPORT_LAG")" "$icon"
    [[ "$icon" == *"!!"* ]] && add_summary_warning "Transport lag is $STB_TRANSPORT_LAG"
else
    row "Transport Lag" "N/A (standby mounted)"
fi

if [[ -n "${STB_APPLY_LAG:-}" ]]; then
    icon=$(dg_lag_icon "$STB_APPLY_LAG")
    row "Apply Lag" "$(dg_display_lag_value "$STB_APPLY_LAG")" "$icon"
    [[ "$icon" == *"!!"* ]] && add_summary_warning "Apply lag is $STB_APPLY_LAG"
else
    row "Apply Lag" "N/A (standby mounted)"
fi

# Sequence gap
if [[ -n "${STB_LAST_APPLIED:-}" ]] && [[ -n "${STB_LAST_RECEIVED:-}" ]] && [[ "${STB_LAST_RECEIVED:-0}" -gt 0 ]]; then
    SEQ_LAG=$((STB_LAST_RECEIVED - STB_LAST_APPLIED))
    if [[ "$SEQ_LAG" -le "$DG_SEQ_GAP_WARN" ]]; then
        row "Sequences" "applied=${STB_LAST_APPLIED}  received=${STB_LAST_RECEIVED}" "$CHK"
    elif [[ "$SEQ_LAG" -le "$DG_SEQ_GAP_CRIT" ]]; then
        row "Sequences" "applied=${STB_LAST_APPLIED}  received=${STB_LAST_RECEIVED}  (lag: ${SEQ_LAG})" "$WARN"; add_summary_warning "Standby sequence lag is ${SEQ_LAG}"
    else
        row "Sequences" "applied=${STB_LAST_APPLIED}  received=${STB_LAST_RECEIVED}  (lag: ${SEQ_LAG})" "$FAIL"; add_summary_error "Standby sequence lag is ${SEQ_LAG}"
    fi
fi

subheader "Redo / Archive"

if [[ -n "${STB_SRL:-}" ]] && [[ "${STB_SRL:-0}" -gt 0 ]]; then
    row "Standby Redo Logs" "${STB_SRL} groups" "$CHK"
else
    row "Standby Redo Logs" "NONE" "$FAIL"; add_summary_error "Standby has no standby redo logs configured"
fi

if [[ -n "${STB_ARCHGAP:-}" ]] && [[ "${STB_ARCHGAP:-0}" -gt 0 ]]; then
    row "Archive Gaps" "${STB_ARCHGAP} gap(s)!" "$FAIL"; add_summary_error "Standby reports ${STB_ARCHGAP} archive gap(s)"
fi

if [[ -n "${STB_UNNAMED:-}" ]] && [[ "${STB_UNNAMED:-0}" -gt 0 ]]; then
    row "UNNAMED Datafiles" "${STB_UNNAMED} UNNAMED datafile(s)!" "$FAIL"; add_summary_error "Standby has ${STB_UNNAMED} UNNAMED datafile(s) (ORA-01274: datafile path not covered by DB_FILE_NAME_CONVERT pairs; repair with ALTER DATABASE CREATE DATAFILE)"
fi

subheader "Recovery Area"

if [[ -n "${STB_FRA_PATH:-}" ]]; then
    STB_FRA_EFFECTIVE_USED=$(compute_fra_effective "$STB_FRA_USED" "$STB_FRA_RECLAIM")
    STB_FRA_PCT=$(compute_fra_pct "$STB_FRA_SIZE" "$STB_FRA_USED" "$STB_FRA_RECLAIM")
    icon=$(dg_fra_icon "$STB_FRA_PCT")
    if [[ "$STB_FRA_PCT" -ge "$DG_FRA_CRIT_PCT" ]]; then
        add_summary_error "Standby FRA usage is ${STB_FRA_PCT}%"
    elif [[ "$STB_FRA_PCT" -ge "$DG_FRA_WARN_PCT" ]]; then
        add_summary_warning "Standby FRA usage is ${STB_FRA_PCT}%"
    fi
    row "FRA Usage" "${STB_FRA_EFFECTIVE_USED}/${STB_FRA_SIZE} GB effective (${STB_FRA_PCT}%), reclaimable ${STB_FRA_RECLAIM} GB" "$icon"
    row "FRA Location" "${STB_FRA_PATH} (${STB_FRA_FILES:-0} files)"
fi
fi

# -- Broker Configuration ----------------------------------------------------
header "DATA GUARD BROKER"

if ! $PRIMARY_REACHABLE; then
    row "Configuration" "UNREACHABLE (SSH to primary failed; DGMGRL not queried)" "$FAIL"
elif printf '%s' "$DGMGRL_CONFIG" | grep -qE "ORA-16532|not yet available|not exist"; then
    row "Configuration" "NOT CONFIGURED" "$FAIL"; add_summary_error "Data Guard Broker configuration is not configured or not available"
else
    row "Configuration" "${BROKER_CFG_NAME:-unknown}"

    # M19: WARNING is a warning (exit 1) and ERROR is an error (exit 2) -
    # the local triage/diag tools already grade it that way, and the two
    # tools must not disagree about the same broker state.
    if [[ -n "${BROKER_OVERALL:-}" ]]; then
        case "$BROKER_OVERALL" in
            SUCCESS)
                row "Overall Status" "$BROKER_OVERALL" "$CHK"
                ;;
            WARNING)
                add_summary_warning "Broker overall status is WARNING"
                row "Overall Status" "$BROKER_OVERALL" "$WARN"
                ;;
            *)
                add_summary_error "Broker overall status is '$BROKER_OVERALL'"
                row "Overall Status" "$BROKER_OVERALL" "$FAIL"
                ;;
        esac
    else
        row "Overall Status" "UNKNOWN (DGMGRL output could not be parsed)" "$WARN"
        add_summary_warning "Broker status could not be determined"
    fi

    # Show members and their ORA errors/warnings from SHOW CONFIGURATION.
    # M20: 19c prints the diagnosis on the line AFTER the member line, so we
    # carry the last member name forward and attribute the Error:/Warning:
    # line to it. Without this the member line always looked clean and the
    # ORA- detail never reached the summary or the exit code.
    BROKER_LAST_MEMBER=""
    while IFS= read -r line; do
        line_trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
        if dg_is_broker_member_line "$line"; then
            # Member line (e.g. "cdb1 - Primary database"). Its icon is
            # decided by the diagnosis lines that follow it, so it can't
            # render a green OK directly above its own "Error: ORA-…" line.
            BROKER_LAST_MEMBER=$(dg_broker_member_name "$line")
            _member_sev=$(dg_broker_member_severity "$DGMGRL_CONFIG" "$BROKER_LAST_MEMBER")
            if printf '%s' "$line_trimmed" | grep -qi "Error"; then
                add_summary_error "Broker member issue: $line_trimmed"
                row "" "$line_trimmed" "$FAIL"
            elif printf '%s' "$line_trimmed" | grep -qi "Warning"; then
                add_summary_warning "Broker member warning: $line_trimmed"
                row "" "$line_trimmed" "$WARN"
            elif [[ "$_member_sev" == "error" ]]; then
                row "" "$line_trimmed" "$FAIL"
            elif [[ "$_member_sev" == "warning" ]]; then
                row "" "$line_trimmed" "$WARN"
            else
                row "" "$line_trimmed" "$CHK"
            fi
            continue
        fi

        _diag_sev=$(dg_broker_diagnosis_severity "$line_trimmed")
        _diag_text=$(dg_broker_diagnosis_text "$line_trimmed")
        if [[ "$_diag_sev" == "error" ]]; then
            add_summary_error "Broker member ${BROKER_LAST_MEMBER:-configuration}: ${_diag_text}"
            printf "  ${DIM}%-24s${NC} ${RED}%s${NC}\n" "" "$line_trimmed"
        elif [[ "$_diag_sev" == "warning" ]]; then
            add_summary_warning "Broker member ${BROKER_LAST_MEMBER:-configuration}: ${_diag_text}"
            printf "  ${DIM}%-24s${NC} ${YELLOW}%s${NC}\n" "" "$line_trimmed"
        elif printf '%s' "$line" | grep -qi 'ORA-'; then
            # ORA detail line without an Error:/Warning: prefix
            printf "  ${DIM}%-24s${NC} ${RED}%s${NC}\n" "" "$line_trimmed"
        fi
    done <<< "$DGMGRL_CONFIG"

    # FSFO status
    FSFO_MODE=$(printf '%s\n' "$DGMGRL_FSFO" | grep -i 'Fast-Start Failover:' | head -1 | sed 's/.*: *//' | xargs)
    if [[ -n "${FSFO_MODE:-}" ]]; then
        if printf '%s' "$FSFO_MODE" | grep -qi "Enabled"; then
            row "Fast-Start Failover" "$FSFO_MODE" "$CHK"
            FSFO_TARGET=$(printf '%s\n' "$DGMGRL_FSFO" | grep -i 'Target:' | sed 's/.*: *//' | xargs)
            FSFO_OBS=$(printf '%s\n' "$DGMGRL_FSFO" | grep -i 'Observer:' | sed 's/.*: *//' | xargs)
            FSFO_THRESHOLD=$(printf '%s\n' "$DGMGRL_FSFO" | grep -i 'Threshold:' | sed 's/.*: *//' | xargs)
            [[ -n "${FSFO_TARGET:-}" ]] && row "  Target" "$FSFO_TARGET"
            [[ -n "${FSFO_OBS:-}" ]] && row "  Observer" "$FSFO_OBS"
            [[ -n "${FSFO_THRESHOLD:-}" ]] && row "  Threshold" "$FSFO_THRESHOLD"
        else
            row "Fast-Start Failover" "${FSFO_MODE}" "${DIM}disabled${NC}"
            add_summary_warning "Fast-Start Failover is ${FSFO_MODE}"
        fi
    fi

    # M17: FS_FAILOVER_OBSERVER_PRESENT from V$DATABASE is the authoritative
    # "is an observer actually connected right now" answer - SHOW
    # FAST_START FAILOVER's "Observer:" line only reports the configured
    # observer name. FSFO enabled with no observer connected means no
    # automatic failover will happen, so it is graded as an error here and
    # in the local triage/diag tools alike.
    if [[ -n "${PRI_FSFO_STATUS:-}" ]]; then
        row "  FSFO Status (V\$DATABASE)" "$PRI_FSFO_STATUS"
    fi
    _fsfo_enabled=false
    if printf '%s' "${FSFO_MODE:-}" | grep -qi "Enabled"; then
        _fsfo_enabled=true
    elif [[ -n "${PRI_FSFO_STATUS:-}" ]] && ! printf '%s' "$PRI_FSFO_STATUS" | grep -qi "DISABLED"; then
        _fsfo_enabled=true
    fi
    if $_fsfo_enabled && [[ -n "${PRI_FSFO_OBSERVER_PRESENT:-}" ]]; then
        if [[ "$PRI_FSFO_OBSERVER_PRESENT" == "YES" ]]; then
            row "  Observer Present" "YES${PRI_FSFO_OBSERVER_HOST:+ (${PRI_FSFO_OBSERVER_HOST})}" "$CHK"
        else
            row "  Observer Present" "$PRI_FSFO_OBSERVER_PRESENT" "$FAIL"
            add_summary_error "FSFO is enabled but no observer is present (automatic failover will not happen)"
        fi
    fi
fi

# -- Summary box (right before final summary) ---------------------------------
printf '\n ┌%s┬%s┐\n' "$_BAR" "$_BAR"
box_row "${PRI_DOT} ${BOLD}PRIMARY${NC}" "${STB_DOT} ${BOLD}PHYSICAL STANDBY${NC}"
box_row "${PRI_DBUNIQ:-?} @ ${PRIMARY_ORACLE_HOSTNAME}" "${STB_DBUNIQ:-?} @ ${STANDBY_ORACLE_HOSTNAME}"
box_row "${PRI_OPEN:-?}" "${STB_OPEN:-?} / MRP: ${STB_MRP_STATUS:-NOT RUNNING}"
printf ' └%s┴%s┘\n' "$_BAR" "$_BAR"

# =============================================================================
# Summary
# =============================================================================
# The state labels are computed BEFORE the headline banner: REPL_STATE's
# "no data" branch (M18) raises a warning, and the banner, the
# "errors=/warnings=" row and the exit code all have to agree with it.

if $PRI_OK; then
    PRIMARY_STATE="${GREEN}OK${NC}"
else
    PRIMARY_STATE="${RED}CHECK${NC}"
fi

if $STB_OK; then
    STANDBY_STATE="${GREEN}OK${NC}"
else
    STANDBY_STATE="${RED}CHECK${NC}"
fi

# M19: WARNING is amber here too, so the final-summary colour agrees with
# the severity the check assigned above.
if [[ "${BROKER_OVERALL:-}" == "SUCCESS" ]]; then
    BROKER_STATE="${GREEN}${BROKER_OVERALL}${NC}"
elif [[ "${BROKER_OVERALL:-}" == "WARNING" ]]; then
    BROKER_STATE="${YELLOW}${BROKER_OVERALL}${NC}"
elif [[ -n "${BROKER_OVERALL:-}" ]]; then
    BROKER_STATE="${RED}${BROKER_OVERALL}${NC}"
else
    BROKER_STATE="${YELLOW}UNKNOWN${NC}"
fi

# M18: "IN SYNC" must be a conclusion, not a fall-through. With an
# unreachable or down standby every lag/sequence field is empty, and the old
# final `else` rendered that as a green IN SYNC.
if ! $STANDBY_REACHABLE; then
    # The unreachable host is already a summary error; don't double-count.
    REPL_STATE="${YELLOW}UNKNOWN${NC}"
elif [[ -z "${STB_TRANSPORT_LAG:-}" && -z "${STB_APPLY_LAG:-}" && -z "${SEQ_LAG:-}" ]]; then
    REPL_STATE="${YELLOW}UNKNOWN${NC}"
    add_summary_warning "Replication state unknown: no transport lag, apply lag or sequence data returned by the standby"
elif [[ -n "${STB_TRANSPORT_LAG:-}" ]] && (( $(dg_parse_lag_seconds "$STB_TRANSPORT_LAG") > DG_LAG_WARN_SECONDS )); then
    REPL_STATE="${YELLOW}LAGGING${NC}"
elif [[ -n "${STB_APPLY_LAG:-}" ]] && (( $(dg_parse_lag_seconds "$STB_APPLY_LAG") > DG_LAG_WARN_SECONDS )); then
    REPL_STATE="${YELLOW}LAGGING${NC}"
elif [[ -n "${SEQ_LAG:-}" && "$SEQ_LAG" -gt "$DG_SEQ_GAP_CRIT" ]]; then
    REPL_STATE="${RED}BEHIND${NC}"
elif [[ -n "${SEQ_LAG:-}" && "$SEQ_LAG" -gt "$DG_SEQ_GAP_WARN" ]]; then
    REPL_STATE="${YELLOW}BEHIND${NC}"
else
    REPL_STATE="${GREEN}IN SYNC${NC}"
fi

printf "\n ${DIM}────────────────────────────────────────────────────────────${NC}\n"

if [[ $ERRORS -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
    printf " ${BOLD}${GREEN} HEALTHY${NC}  ${DIM}No issues detected${NC}\n"
elif [[ $ERRORS -eq 0 ]]; then
    printf " ${BOLD}${YELLOW} WARNING${NC}  ${DIM}${WARNINGS} warning(s)${NC}\n"
else
    printf " ${BOLD}${RED} ISSUES ${NC}  ${RED}${ERRORS} error(s)${NC}"
    [[ $WARNINGS -gt 0 ]] && printf "  ${YELLOW}${WARNINGS} warning(s)${NC}"
    printf "\n"
fi

if [[ $ERRORS -gt 0 ]]; then
    OVERALL_STATE="${RED}CRITICAL${NC}"
elif [[ $WARNINGS -gt 0 ]]; then
    OVERALL_STATE="${YELLOW}ATTENTION${NC}"
else
    OVERALL_STATE="${GREEN}HEALTHY${NC}"
fi

header "FINAL SUMMARY"
row "Overall" "errors=${ERRORS} warnings=${WARNINGS}" "$OVERALL_STATE"
row "Primary" "${PRI_DBUNIQ:-?} / ${PRI_OPEN:-unknown}" "$PRIMARY_STATE"
row "Standby" "${STB_DBUNIQ:-?} / MRP ${STB_MRP_STATUS:-NOT RUNNING}" "$STANDBY_STATE"
row "Broker" "${BROKER_CFG_NAME:-not configured}" "$BROKER_STATE"
row "Redo Apply" "transport=${STB_TRANSPORT_LAG:-n/a}, apply=${STB_APPLY_LAG:-n/a}" "$REPL_STATE"

if [[ $ERRORS -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
    row "Status" "No problems detected" "$CHK"
else
    if [[ ${#SUMMARY_ERRORS[@]} -gt 0 ]]; then
        for item in "${SUMMARY_ERRORS[@]}"; do
            row "Error" "$item" "$FAIL"
        done
    fi
    if [[ ${#SUMMARY_WARNINGS[@]} -gt 0 ]]; then
        for item in "${SUMMARY_WARNINGS[@]}"; do
            row "Warning" "$item" "$WARN"
        done
    fi
fi

printf "\n"

# -- Exit code (WS4.1 + L1) ---------------------------------------------------
# Monitoring-friendly convention, mirroring dg_local_status_exit_code() in
# common/dg_local_status_common.sh: 0 healthy, 1 warnings-only, 2 errors.
# Usage / pre-flight failures exit 3 (EXIT_USAGE) further up so a mistyped
# flag or a missing config file is never reported as a health finding.
# This lets cron/monitoring wrappers alert on `dg_status.sh`'s own exit
# status instead of having to scrape the colour-coded text output.
if [[ $ERRORS -gt 0 ]]; then
    exit 2
elif [[ $WARNINGS -gt 0 ]]; then
    exit 1
fi
exit 0
