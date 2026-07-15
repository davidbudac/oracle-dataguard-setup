#!/usr/bin/env bash
# Shared local Data Guard status collection and rendering.

if [[ -n "${DG_LOCAL_STATUS_COMMON_SH_LOADED:-}" ]]; then
    return 0
fi
DG_LOCAL_STATUS_COMMON_SH_LOADED=1

DG_LOCAL_STATUS_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DG_LOCAL_STATUS_ROOT="$(dirname "$DG_LOCAL_STATUS_COMMON_DIR")"

# Colors, layout, configurable thresholds, lag parsing, and the generic
# text/box rendering primitives (repeat_char/fit_text/wrap_text/row/header/
# subheader/status_icon/warn_icon/short_hostname/extract_first_status/
# format_services/compute_fra_*) all live in dg_render_common.sh now -
# shared with dg_status.sh (WS4.2/4.3/4.4). NO_COLOR_FLAG below is wired
# through parse_args and re-invokes dg_render_init_colors before any output.
source "${DG_LOCAL_STATUS_COMMON_DIR}/dg_render_common.sh"

NO_COLOR_FLAG=false

# -- Shared state -------------------------------------------------------------
declare -a SUMMARY_ERRORS=()
declare -a SUMMARY_WARNINGS=()
declare -a SUMMARY_INFOS=()

ERRORS=0
WARNINGS=0

PROMPT_PASSWORD=false
LOCAL_ONLY=false
SHOW_HELP=false

DG_STATUS_MODE=""
DG_SCRIPT_NAME=""
REMOTE_DEFAULT_PROMPT=false

REMOTE_SQL=""
REMOTE_CONNECTED=false
REMOTE_CONNECT=""
REMOTE_AUTH_METHOD="none"
REMOTE_CONNECTION_RESULT=""
REMOTE_DATA_SOURCE="broker"
REMOTE_DATA_SOURCE_LABEL=""
REMOTE_TEST_TIMEOUT="${REMOTE_TEST_TIMEOUT:-5}"

LOC_ALERT_MATCHES=""
LOC_DRC_MATCHES=""
LOC_ALERT_MATCH_COUNT=0
LOC_DRC_MATCH_COUNT=0
LOC_ALERT_FILE=""
LOC_DRC_FILE=""

IS_PRIMARY=false
LOC_LABEL=""
PEER_LABEL=""

# -- Generic helpers ----------------------------------------------------------
# repeat_char/strip_ansi/fit_text/wrap_text/row/header/subheader/
# short_hostname/extract_first_status/status_icon/warn_icon/format_services
# now live in dg_render_common.sh (sourced above), shared with dg_status.sh.
# format_event_limit/print_event_block/is_error_event stay here: dg_status.sh
# renders alert/broker log entries differently (no "N matched, newest M
# shown" heading), so these are not genuinely shared - see WS4.4 notes.

format_event_limit() {
    local raw="$1" limit="$2"
    printf '%s\n' "$raw" | sed '/^$/d' | awk -v max="$limit" '
        NF { lines[++n] = $0 }
        END {
            if (n == 0) {
                exit
            }
            start = n
            end = n - max + 1
            if (end < 1) {
                end = 1
            }
            for (i = start; i >= end; i--) {
                print lines[i]
            }
        }
    '
}

print_event_block() {
    local label="$1" raw="$2" count="$3" limit="$4" filepath="$5"
    local heading entries line ts msg
    heading="${label}: ${count} matched"
    if (( count > 0 )); then
        heading="${heading}, newest ${limit} shown"
    fi
    printf "  ${DIM}%s${NC}\n" "$heading"
    if [[ "${DG_DEBUG:-0}" == "1" && -n "$filepath" ]]; then
        printf "    ${DIM}%s${NC}\n" "$filepath"
    fi
    if (( count == 0 )); then
        printf "    ${DIM}(none)${NC}\n"
        return
    fi

    entries=$(format_event_limit "$raw" "$limit")
    while IFS= read -r line || [[ -n "$line" ]]; do
        ts=""
        msg="$line"
        if printf '%s' "$line" | grep -q '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] '; then
            ts="${line:0:19}"
            msg="${line:21}"
        fi
        if is_error_event "$msg"; then
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
}

is_error_event() {
    local msg="$1"
    if printf '%s' "$msg" | grep -qiE 'ORA-(00000|0([^0-9]|$))'; then
        return 1
    fi
    printf '%s' "$msg" | grep -qiE 'ORA-|error|failed|failure'
}

add_summary_error() {
    local message="$1"
    SUMMARY_ERRORS+=("$message")
    ERRORS=$((ERRORS + 1))
}

add_summary_warning() {
    local message="$1"
    SUMMARY_WARNINGS+=("$message")
    WARNINGS=$((WARNINGS + 1))
}

add_summary_info() {
    local message="$1"
    SUMMARY_INFOS+=("$message")
}

show_usage() {
    local script_name="$1"
    printf "Usage: bash %s [-P] [-L] [--no-color]\n" "$script_name"
    printf "  -P, --password   Prompt for SYS password for remote connection\n"
    printf "  -L, --local      Skip remote SQL checks (local + broker only)\n"
    printf "  --no-color       Disable colored output (also honors NO_COLOR)\n"
    printf "  -h, --help       Show this help\n"
}

parse_args() {
    local script_name="$1"
    shift
    PROMPT_PASSWORD=false
    LOCAL_ONLY=false
    SHOW_HELP=false
    NO_COLOR_FLAG=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -P|--password)
                PROMPT_PASSWORD=true
                shift
                ;;
            -L|--local)
                LOCAL_ONLY=true
                shift
                ;;
            --no-color)
                NO_COLOR_FLAG=true
                shift
                ;;
            -h|--help)
                SHOW_HELP=true
                shift
                ;;
            *)
                printf "Unknown option: %s\n" "$1" >&2
                show_usage "$script_name" >&2
                return 64
                ;;
        esac
    done

    # Re-initialize colors now that --no-color has been parsed, and BEFORE
    # any output is produced (show_usage below is the first possible output
    # in this call path) - satisfies WS4.2's "before any output" requirement.
    $NO_COLOR_FLAG && dg_render_init_colors 1

    if $SHOW_HELP; then
        show_usage "$script_name"
    fi
}

verify_oracle_env() {
    if [[ -z "${ORACLE_SID:-}" ]]; then
        printf "ERROR: ORACLE_SID is not set\n" >&2
        return 64
    fi
    if [[ -z "${ORACLE_HOME:-}" ]]; then
        printf "ERROR: ORACLE_HOME is not set\n" >&2
        return 64
    fi
    export PATH="${ORACLE_HOME}/bin:${PATH}"
}

run_local_sql() {
    sqlplus -s / as sysdba <<SQL
SET HEADING OFF FEEDBACK OFF LINESIZE 300 PAGESIZE 0 TRIMSPOOL ON
$1
EXIT;
SQL
}

run_remote_sql() {
    local connect="$1" query="$2"
    # CONNECT is fed via stdin (sqlplus -s /nolog) rather than on the
    # sqlplus command line, so a password-based connect string (sys/pw@tns)
    # never appears in `ps -ef`. Works the same for wallet-based connects
    # (/@tns) - no password involved there either way.
    sqlplus -s /nolog <<SQL
CONNECT ${connect} AS SYSDBA
SET HEADING OFF FEEDBACK OFF LINESIZE 300 PAGESIZE 0 TRIMSPOOL ON
${query}
EXIT;
SQL
}

# Inject CONNECT_TIMEOUT/TRANSPORT_CONNECT_TIMEOUT/RETRY_COUNT into a TNS
# connect identifier (a full DESCRIPTION, or a plain tnsnames.ora alias) so
# the network connect itself is time-bounded at the SQL*Net layer. This is
# the ONLY timeout mechanism on hosts without the GNU `timeout` binary
# (stock AIX has none), which is why it does not simply defer to the
# `timeout`-binary fast path in run_remote_sql_timeout below.
# Usage: identifier=$(build_timeout_connect_string 5 "$PEER_TNS")
build_timeout_connect_string() {
    local timeout_secs="$1" identifier="$2" resolved

    if printf '%s' "$identifier" | grep -qi 'DESCRIPTION[[:space:]]*='; then
        # Already a full descriptor - inject the timeout params right after
        # the opening DESCRIPTION=(
        # Note: real TNS descriptors have exactly one paren pair enclosing
        # "DESCRIPTION=" together with all its children - there is no
        # separate opening paren strictly for "DESCRIPTION" itself, so the
        # match/replace below must only consume "DESCRIPTION[ ]*=" and leave
        # the following "(" (the first child's own opening paren) untouched.
        printf '%s' "$identifier" | sed "s/DESCRIPTION[[:space:]]*=/DESCRIPTION=(CONNECT_TIMEOUT=${timeout_secs})(TRANSPORT_CONNECT_TIMEOUT=3)(RETRY_COUNT=0)/"
        return
    fi

    # Plain TNS alias - resolve it to a descriptor via tnsping so the timeout
    # params can be embedded. If tnsping is unavailable or resolution fails,
    # fall back to the bare alias (no descriptor-level timeout in that case;
    # the `timeout`-binary fast path, when present, is the only guard).
    if command -v tnsping >/dev/null 2>&1; then
        resolved=$(tnsping "$identifier" 2>/dev/null | sed -n 's/^Attempting to contact[[:space:]]*//p' | tail -1)
        if [[ "$resolved" == *DESCRIPTION* ]]; then
            printf '%s' "$resolved" | sed "s/DESCRIPTION[[:space:]]*=/DESCRIPTION=(CONNECT_TIMEOUT=${timeout_secs})(TRANSPORT_CONNECT_TIMEOUT=3)(RETRY_COUNT=0)/"
            return
        fi
    fi

    printf '%s' "$identifier"
}

run_remote_sql_timeout() {
    local timeout_secs="$1" connect="$2" query="$3"
    local auth identifier

    # Embed connect-time timeouts in the connect identifier itself (see
    # build_timeout_connect_string) - this protects the connect regardless
    # of whether the `timeout` binary exists. When `timeout` IS present we
    # additionally wrap the whole sqlplus call with it as a second layer,
    # since it also catches non-network hangs (e.g. sqlplus blocking on an
    # unexpected prompt) that a connect-time parameter cannot cover.
    if [[ "$connect" == *@* ]]; then
        auth="${connect%@*}"
        identifier="${connect##*@}"
        connect="${auth}@$(build_timeout_connect_string "$timeout_secs" "$identifier")"
    fi

    # CONNECT is fed via stdin (sqlplus -s /nolog), not the sqlplus command
    # line, so a password-based connect string never appears in `ps -ef`.
    # identifier may be a full (DESCRIPTION=...) descriptor produced by
    # build_timeout_connect_string above - CONNECT accepts that the same way
    # a command-line logon does.
    if command -v timeout >/dev/null 2>&1; then
        timeout "${timeout_secs}"s sqlplus -s /nolog <<SQL
CONNECT ${connect} AS SYSDBA
SET HEADING OFF FEEDBACK OFF LINESIZE 300 PAGESIZE 0 TRIMSPOOL ON
${query}
EXIT;
SQL
    else
        run_remote_sql "$connect" "$query"
    fi
}

collect_identity() {
    LOCAL_ID_SQL=$(run_local_sql "
SELECT 'DBSTATUS|' || DATABASE_ROLE || '|' || DB_UNIQUE_NAME FROM V\$DATABASE;
")

    LOC_ID_STATUS=$(printf '%s\n' "$LOCAL_ID_SQL" | grep '^DBSTATUS|' | head -1 | sed 's/^DBSTATUS|//')
    LOC_ROLE=$(printf '%s' "$LOC_ID_STATUS" | awk -F'|' '{print $1}' | xargs)
    LOC_DBUNIQ=$(printf '%s' "$LOC_ID_STATUS" | awk -F'|' '{print $2}' | xargs)

    if printf '%s' "$LOC_ROLE" | grep -qi "PRIMARY"; then
        IS_PRIMARY=true
        LOC_LABEL="PRIMARY"
        PEER_LABEL="STANDBY"
    else
        IS_PRIMARY=false
        LOC_LABEL="STANDBY"
        PEER_LABEL="PRIMARY"
    fi
}

collect_broker_data() {
    DGMGRL_CONFIG=$(dgmgrl -silent / 'SHOW CONFIGURATION' 2>&1)
    DGMGRL_FSFO=$(dgmgrl -silent / 'SHOW FAST_START FAILOVER' 2>&1)

    BROKER_CFG_NAME=$(printf '%s\n' "$DGMGRL_CONFIG" | grep 'Configuration -' | sed 's/.*Configuration - //' | xargs)
    BROKER_OVERALL=$(printf '%s\n' "$DGMGRL_CONFIG" | tail -5 | extract_first_status)

    if $IS_PRIMARY; then
        PEER_DBUNIQ=$(printf '%s\n' "$DGMGRL_CONFIG" | grep -i 'Physical standby' | head -1 | awk '{print $1}')
    else
        PEER_DBUNIQ=$(printf '%s\n' "$DGMGRL_CONFIG" | grep -i 'Primary database' | head -1 | awk '{print $1}')
    fi

    PEER_TNS=""
    if [[ -n "${PEER_DBUNIQ:-}" ]]; then
        PEER_TNS_RAW=$(dgmgrl -silent / "SHOW DATABASE '${PEER_DBUNIQ}' 'DGConnectIdentifier'" 2>&1)
        PEER_TNS=$(printf '%s\n' "$PEER_TNS_RAW" | grep 'DGConnectIdentifier' | sed "s/.*= *'//" | sed "s/'.*//")
        DGMGRL_PEER=$(dgmgrl -silent / "SHOW DATABASE '${PEER_DBUNIQ}'" 2>&1)
    else
        DGMGRL_PEER=""
    fi
}

attempt_remote_connection() {
    REMOTE_SQL=""
    REMOTE_CONNECTED=false
    REMOTE_CONNECT=""
    REMOTE_AUTH_METHOD="none"
    REMOTE_CONNECTION_RESULT=""
    REMOTE_DATA_SOURCE="broker"

    if $LOCAL_ONLY; then
        REMOTE_CONNECTION_RESULT="remote SQL skipped by -L"
        REMOTE_DATA_SOURCE="local-only"
        REMOTE_DATA_SOURCE_LABEL="local+broker (-L)"
        return
    fi

    if [[ -z "${PEER_TNS:-}" ]]; then
        REMOTE_CONNECTION_RESULT="peer TNS alias could not be discovered from broker"
        REMOTE_DATA_SOURCE="broker"
        REMOTE_DATA_SOURCE_LABEL="broker-only degraded mode"
        return
    fi

    WALLET_TEST=$(run_remote_sql_timeout "$REMOTE_TEST_TIMEOUT" "/@${PEER_TNS}" "
SELECT 'WALLET_OK' FROM DUAL;
" 2>&1)
    if printf '%s' "$WALLET_TEST" | grep -q 'WALLET_OK'; then
        REMOTE_CONNECT="/@${PEER_TNS}"
        REMOTE_CONNECTED=true
        REMOTE_AUTH_METHOD="wallet"
        REMOTE_CONNECTION_RESULT="wallet authentication succeeded"
        REMOTE_DATA_SOURCE="runtime"
        REMOTE_DATA_SOURCE_LABEL="remote runtime via wallet"
        return
    fi

    if $PROMPT_PASSWORD || $REMOTE_DEFAULT_PROMPT; then
        printf " Enter SYS password for remote connection (or press Enter to skip): "
        stty -echo 2>/dev/null || true
        # WS4.6: on EOF/closed stdin, `read` fails and SYS_PASS is left
        # empty - `|| SYS_PASS=""` makes that explicit rather than relying
        # on read's implicit-empty-on-EOF behavior. An empty SYS_PASS falls
        # straight into the "skipped" branch below (safe default: continue
        # in broker-only degraded mode, never block waiting for input).
        # This deliberately does NOT gate on `[ -t 0 ]`: the E2E suite pipes
        # real answers into these scripts over a non-tty stdin, and that
        # must keep working exactly as before.
        read -r SYS_PASS || SYS_PASS=""
        stty echo 2>/dev/null || true
        printf "\n"

        if [[ -n "$SYS_PASS" ]]; then
            # Quote the password inside the connect string (handles most
            # special characters an operator might type); run_remote_sql
            # and run_remote_sql_timeout feed this whole string to sqlplus
            # via a CONNECT statement on stdin, never on the command line.
            REMOTE_CONNECT="sys/\"${SYS_PASS}\"@${PEER_TNS}"
            PASS_TEST=$(run_remote_sql_timeout "$REMOTE_TEST_TIMEOUT" "$REMOTE_CONNECT" "SELECT 'PASS_OK' FROM DUAL;" 2>&1)
            if printf '%s' "$PASS_TEST" | grep -q 'PASS_OK'; then
                REMOTE_CONNECTED=true
                REMOTE_AUTH_METHOD="password"
                REMOTE_CONNECTION_RESULT="SYS password authentication succeeded"
                REMOTE_DATA_SOURCE="runtime"
                REMOTE_DATA_SOURCE_LABEL="remote runtime via password"
                return
            fi
            REMOTE_CONNECTION_RESULT="password authentication failed; continuing with broker-only view"
        else
            REMOTE_CONNECTION_RESULT="password prompt skipped; continuing with broker-only view"
        fi
    else
        REMOTE_CONNECTION_RESULT="wallet authentication failed or timed out; continuing with broker-only view"
    fi

    REMOTE_DATA_SOURCE="broker"
    REMOTE_DATA_SOURCE_LABEL="broker-only degraded mode"
}

collect_remote_sql() {
    if [[ "$REMOTE_CONNECTED" != true ]]; then
        return
    fi

    REMOTE_SQL=$(run_remote_sql "$REMOTE_CONNECT" "
${DG_SQL_SELECT_DBSTATUS_FULL}
${DG_SQL_SELECT_REDOLOG}
${DG_SQL_SELECT_SRLCOUNT}
${DG_SQL_SELECT_ARCHGAP}
${DG_SQL_SELECT_FRA}
${DG_SQL_SELECT_SERVICE}
${DG_SQL_SELECT_MRP}
${DG_SQL_SELECT_DGSTATS}
${DG_SQL_SELECT_APPLYINFO}
${DG_SQL_SELECT_RECMODE}
" 2>&1)
}

collect_local_sql() {
    LOCAL_SQL=$(run_local_sql "
${DG_SQL_SELECT_DBSTATUS_FULL}
${DG_SQL_SELECT_DGPARAMS}
${DG_SQL_SELECT_REDOLOG}
${DG_SQL_SELECT_SRLCOUNT}
${DG_SQL_SELECT_ARCHGAP}
SELECT 'ARCHDEST|' || DEST_ID || '|' || STATUS || '|' || DB_UNIQUE_NAME || '|' || ERROR FROM V\$ARCHIVE_DEST WHERE DEST_ID IN (1,2);
${DG_SQL_SELECT_FSFODB}
${DG_SQL_SELECT_FRA}
${DG_SQL_SELECT_SERVICE}
${DG_SQL_SELECT_MRP}
${DG_SQL_SELECT_DGSTATS}
${DG_SQL_SELECT_APPLYINFO}
${DG_SQL_SELECT_RECMODE}
")
}

parse_local_sql() {
    LOC_DBSTATUS=$(printf '%s\n' "$LOCAL_SQL" | grep '^DBSTATUS|' | head -1 | sed 's/^DBSTATUS|//')
    LOC_ROLE=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $1}' | xargs)
    LOC_OPEN=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $2}' | xargs)
    LOC_PROTECT=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $3}' | xargs)
    LOC_SWITCH=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $4}' | xargs)
    LOC_FORCE=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $5}' | xargs)
    LOC_FLASH=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $6}' | xargs)
    LOC_DBUNIQ=$(printf '%s' "$LOC_DBSTATUS" | awk -F'|' '{print $7}' | xargs)

    LOC_BROKER=$(printf '%s\n' "$LOCAL_SQL" | grep 'dg_broker_start' | awk -F'|' '{print $3}' | xargs)
    LOC_ARCHGAP=$(printf '%s\n' "$LOCAL_SQL" | grep '^ARCHGAP|' | awk -F'|' '{print $2}' | xargs)
    LOC_REDO=$(printf '%s\n' "$LOCAL_SQL" | grep '^REDOLOG|' | sed 's/^REDOLOG|//')
    LOC_REDO_CNT=$(printf '%s' "$LOC_REDO" | awk -F'|' '{print $1}' | xargs)
    LOC_REDO_MB=$(printf '%s' "$LOC_REDO" | awk -F'|' '{print $2}' | xargs)
    LOC_SRL=$(printf '%s\n' "$LOCAL_SQL" | grep '^SRLCOUNT|' | awk -F'|' '{print $2}' | xargs)

    LOC_DEST2_STATUS=$(printf '%s\n' "$LOCAL_SQL" | grep '^ARCHDEST|2|' | awk -F'|' '{print $3}' | xargs)
    LOC_DEST2_DBUNIQ=$(printf '%s\n' "$LOCAL_SQL" | grep '^ARCHDEST|2|' | awk -F'|' '{print $4}' | xargs)
    LOC_DEST2_ERROR=$(printf '%s\n' "$LOCAL_SQL" | grep '^ARCHDEST|2|' | awk -F'|' '{print $5}' | xargs)

    LOC_FSFODB=$(printf '%s\n' "$LOCAL_SQL" | grep '^FSFODB|' | head -1 | sed 's/^FSFODB|//')
    LOC_FSFO_STATUS=$(printf '%s' "$LOC_FSFODB" | awk -F'|' '{print $1}' | xargs)
    LOC_FSFO_OBSERVER_PRESENT=$(printf '%s' "$LOC_FSFODB" | awk -F'|' '{print $2}' | xargs)
    LOC_FSFO_OBSERVER_HOST=$(printf '%s' "$LOC_FSFODB" | awk -F'|' '{print $3}' | xargs)

    LOC_FRA=$(printf '%s\n' "$LOCAL_SQL" | grep '^FRA|' | head -1 | sed 's/^FRA|//')
    LOC_FRA_PATH=$(printf '%s' "$LOC_FRA" | awk -F'|' '{print $1}' | xargs)
    LOC_FRA_SIZE=$(printf '%s' "$LOC_FRA" | awk -F'|' '{print $2}' | xargs)
    LOC_FRA_USED=$(printf '%s' "$LOC_FRA" | awk -F'|' '{print $3}' | xargs)
    LOC_FRA_RECLAIM=$(printf '%s' "$LOC_FRA" | awk -F'|' '{print $4}' | xargs)
    LOC_FRA_FILES=$(printf '%s' "$LOC_FRA" | awk -F'|' '{print $5}' | xargs)

    LOC_SERVICES=$(format_services "$(printf '%s\n' "$LOCAL_SQL" | grep '^SERVICE|' | sed 's/^SERVICE|//')")

    LOC_MRP=$(printf '%s\n' "$LOCAL_SQL" | grep '^MRP|' | head -1 | sed 's/^MRP|//')
    LOC_MRP_STATUS=$(printf '%s' "$LOC_MRP" | awk -F'|' '{print $2}' | xargs)
    LOC_MRP_SEQ=$(printf '%s' "$LOC_MRP" | awk -F'|' '{print $3}' | xargs)

    LOC_TRANSPORT_LAG=$(printf '%s\n' "$LOCAL_SQL" | grep 'transport lag' | awk -F'|' '{print $3}' | xargs)
    LOC_APPLY_LAG=$(printf '%s\n' "$LOCAL_SQL" | grep 'apply lag' | awk -F'|' '{print $3}' | xargs)
    LOC_APPLY_FINISH=$(printf '%s\n' "$LOCAL_SQL" | grep 'apply finish time' | awk -F'|' '{print $3}' | xargs)

    LOC_APPLYINFO=$(printf '%s\n' "$LOCAL_SQL" | grep '^APPLYINFO|' | sed 's/^APPLYINFO|//')
    LOC_LAST_APPLIED=$(printf '%s' "$LOC_APPLYINFO" | awk -F'|' '{print $1}' | xargs)
    LOC_LAST_RECEIVED=$(printf '%s' "$LOC_APPLYINFO" | awk -F'|' '{print $2}' | xargs)
    LOC_RECOVERY_MODE=$(printf '%s\n' "$LOCAL_SQL" | grep '^RECMODE|' | head -1 | awk -F'|' '{print $2}' | xargs)
}

parse_remote_sql() {
    REM_ROLE=""
    REM_OPEN=""
    REM_PROTECT=""
    REM_SWITCH=""
    REM_FORCE=""
    REM_FLASH=""
    REM_DBUNIQ=""
    REM_REDO_CNT=""
    REM_REDO_MB=""
    REM_SRL=""
    REM_ARCHGAP=""
    REM_FRA_PATH=""
    REM_FRA_SIZE=""
    REM_FRA_USED=""
    REM_FRA_RECLAIM=""
    REM_FRA_FILES=""
    REM_MRP_STATUS=""
    REM_MRP_SEQ=""
    REM_TRANSPORT_LAG=""
    REM_APPLY_LAG=""
    REM_APPLY_FINISH=""
    REM_LAST_APPLIED=""
    REM_LAST_RECEIVED=""
    REM_RECOVERY_MODE=""
    REM_SERVICES=""

    if [[ -z "$REMOTE_SQL" ]]; then
        return
    fi

    REM_DBSTATUS=$(printf '%s\n' "$REMOTE_SQL" | grep '^DBSTATUS|' | head -1 | sed 's/^DBSTATUS|//')
    REM_ROLE=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $1}' | xargs)
    REM_OPEN=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $2}' | xargs)
    REM_PROTECT=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $3}' | xargs)
    REM_SWITCH=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $4}' | xargs)
    REM_FORCE=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $5}' | xargs)
    REM_FLASH=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $6}' | xargs)
    REM_DBUNIQ=$(printf '%s' "$REM_DBSTATUS" | awk -F'|' '{print $7}' | xargs)

    REM_REDO=$(printf '%s\n' "$REMOTE_SQL" | grep '^REDOLOG|' | sed 's/^REDOLOG|//')
    REM_REDO_CNT=$(printf '%s' "$REM_REDO" | awk -F'|' '{print $1}' | xargs)
    REM_REDO_MB=$(printf '%s' "$REM_REDO" | awk -F'|' '{print $2}' | xargs)
    REM_SRL=$(printf '%s\n' "$REMOTE_SQL" | grep '^SRLCOUNT|' | awk -F'|' '{print $2}' | xargs)
    REM_ARCHGAP=$(printf '%s\n' "$REMOTE_SQL" | grep '^ARCHGAP|' | awk -F'|' '{print $2}' | xargs)

    REM_FRA=$(printf '%s\n' "$REMOTE_SQL" | grep '^FRA|' | head -1 | sed 's/^FRA|//')
    REM_FRA_PATH=$(printf '%s' "$REM_FRA" | awk -F'|' '{print $1}' | xargs)
    REM_FRA_SIZE=$(printf '%s' "$REM_FRA" | awk -F'|' '{print $2}' | xargs)
    REM_FRA_USED=$(printf '%s' "$REM_FRA" | awk -F'|' '{print $3}' | xargs)
    REM_FRA_RECLAIM=$(printf '%s' "$REM_FRA" | awk -F'|' '{print $4}' | xargs)
    REM_FRA_FILES=$(printf '%s' "$REM_FRA" | awk -F'|' '{print $5}' | xargs)

    REM_SERVICES=$(format_services "$(printf '%s\n' "$REMOTE_SQL" | grep '^SERVICE|' | sed 's/^SERVICE|//')")

    REM_MRP=$(printf '%s\n' "$REMOTE_SQL" | grep '^MRP|' | head -1 | sed 's/^MRP|//')
    REM_MRP_STATUS=$(printf '%s' "$REM_MRP" | awk -F'|' '{print $2}' | xargs)
    REM_MRP_SEQ=$(printf '%s' "$REM_MRP" | awk -F'|' '{print $3}' | xargs)

    REM_TRANSPORT_LAG=$(printf '%s\n' "$REMOTE_SQL" | grep 'transport lag' | awk -F'|' '{print $3}' | xargs)
    REM_APPLY_LAG=$(printf '%s\n' "$REMOTE_SQL" | grep 'apply lag' | awk -F'|' '{print $3}' | xargs)
    REM_APPLY_FINISH=$(printf '%s\n' "$REMOTE_SQL" | grep 'apply finish time' | awk -F'|' '{print $3}' | xargs)

    REM_APPLYINFO=$(printf '%s\n' "$REMOTE_SQL" | grep '^APPLYINFO|' | sed 's/^APPLYINFO|//')
    REM_LAST_APPLIED=$(printf '%s' "$REM_APPLYINFO" | awk -F'|' '{print $1}' | xargs)
    REM_LAST_RECEIVED=$(printf '%s' "$REM_APPLYINFO" | awk -F'|' '{print $2}' | xargs)
    REM_RECOVERY_MODE=$(printf '%s\n' "$REMOTE_SQL" | grep '^RECMODE|' | head -1 | awk -F'|' '{print $2}' | xargs)
}

collect_log_matches() {
    LOC_ALERT_TRACE=$(run_local_sql "SELECT VALUE FROM V\$DIAG_INFO WHERE NAME = 'Diag Trace';" | xargs)
    LOC_ALERT_FILE="${LOC_ALERT_TRACE}/alert_${ORACLE_SID}.log"
    LOC_DRC_FILE="${LOC_ALERT_TRACE}/drc${ORACLE_SID}.log"

    LOC_ALERT_MATCHES=""
    LOC_DRC_MATCHES=""
    LOC_ALERT_MATCH_COUNT=0
    LOC_DRC_MATCH_COUNT=0

    if [[ -f "$LOC_ALERT_FILE" ]]; then
        LOC_ALERT_MATCHES=$(tail -2000 "$LOC_ALERT_FILE" | awk "$DG_ALERT_LOG_AWK_FILTER" 2>/dev/null)
        LOC_ALERT_MATCH_COUNT=$(printf '%s\n' "$LOC_ALERT_MATCHES" | sed '/^$/d' | wc -l | tr -d ' ')
    fi

    if [[ -f "$LOC_DRC_FILE" ]]; then
        LOC_DRC_MATCHES=$(tail -500 "$LOC_DRC_FILE" | awk "$DG_BROKER_LOG_AWK_FILTER" 2>/dev/null)
        LOC_DRC_MATCH_COUNT=$(printf '%s\n' "$LOC_DRC_MATCHES" | sed '/^$/d' | wc -l | tr -d ' ')
    fi
}

assign_role_views() {
    if $IS_PRIMARY; then
        PRI_ROLE="$LOC_ROLE"
        PRI_OPEN="$LOC_OPEN"
        PRI_PROTECT="$LOC_PROTECT"
        PRI_SWITCH="$LOC_SWITCH"
        PRI_FORCE="$LOC_FORCE"
        PRI_FLASH="$LOC_FLASH"
        PRI_DBUNIQ="$LOC_DBUNIQ"
        PRI_BROKER="$LOC_BROKER"
        PRI_REDO_CNT="$LOC_REDO_CNT"
        PRI_REDO_MB="$LOC_REDO_MB"
        PRI_SRL="$LOC_SRL"
        PRI_DEST2_STATUS="$LOC_DEST2_STATUS"
        PRI_DEST2_DBUNIQ="$LOC_DEST2_DBUNIQ"
        PRI_DEST2_ERROR="${LOC_DEST2_ERROR:-}"
        PRI_ARCHGAP="$LOC_ARCHGAP"
        PRI_FRA_PATH="$LOC_FRA_PATH"
        PRI_FRA_SIZE="$LOC_FRA_SIZE"
        PRI_FRA_USED="$LOC_FRA_USED"
        PRI_FRA_RECLAIM="$LOC_FRA_RECLAIM"
        PRI_FRA_FILES="$LOC_FRA_FILES"
        PRI_SERVICES="$LOC_SERVICES"
        PRI_HOST=$(short_hostname)

        STB_ROLE="$REM_ROLE"
        STB_OPEN="$REM_OPEN"
        STB_PROTECT="$REM_PROTECT"
        STB_SWITCH="$REM_SWITCH"
        STB_FORCE="$REM_FORCE"
        STB_FLASH="$REM_FLASH"
        STB_DBUNIQ="${REM_DBUNIQ:-${PEER_DBUNIQ:-?}}"
        STB_REDO_CNT="$REM_REDO_CNT"
        STB_REDO_MB="$REM_REDO_MB"
        STB_SRL="$REM_SRL"
        STB_ARCHGAP="$REM_ARCHGAP"
        STB_MRP_STATUS="$REM_MRP_STATUS"
        STB_MRP_SEQ="$REM_MRP_SEQ"
        STB_TRANSPORT_LAG="$REM_TRANSPORT_LAG"
        STB_APPLY_LAG="$REM_APPLY_LAG"
        STB_APPLY_FINISH="$REM_APPLY_FINISH"
        STB_LAST_APPLIED="$REM_LAST_APPLIED"
        STB_LAST_RECEIVED="$REM_LAST_RECEIVED"
        STB_RECOVERY_MODE="$REM_RECOVERY_MODE"
        STB_FRA_PATH="$REM_FRA_PATH"
        STB_FRA_SIZE="$REM_FRA_SIZE"
        STB_FRA_USED="$REM_FRA_USED"
        STB_FRA_RECLAIM="$REM_FRA_RECLAIM"
        STB_FRA_FILES="$REM_FRA_FILES"
        STB_SERVICES="$REM_SERVICES"
        STB_HOST="${PEER_TNS:-unknown}"
    else
        STB_ROLE="$LOC_ROLE"
        STB_OPEN="$LOC_OPEN"
        STB_PROTECT="$LOC_PROTECT"
        STB_SWITCH="$LOC_SWITCH"
        STB_FORCE="$LOC_FORCE"
        STB_FLASH="$LOC_FLASH"
        STB_DBUNIQ="$LOC_DBUNIQ"
        STB_REDO_CNT="$LOC_REDO_CNT"
        STB_REDO_MB="$LOC_REDO_MB"
        STB_SRL="$LOC_SRL"
        STB_ARCHGAP="$LOC_ARCHGAP"
        STB_MRP_STATUS="$LOC_MRP_STATUS"
        STB_MRP_SEQ="$LOC_MRP_SEQ"
        STB_TRANSPORT_LAG="$LOC_TRANSPORT_LAG"
        STB_APPLY_LAG="$LOC_APPLY_LAG"
        STB_APPLY_FINISH="$LOC_APPLY_FINISH"
        STB_LAST_APPLIED="$LOC_LAST_APPLIED"
        STB_LAST_RECEIVED="$LOC_LAST_RECEIVED"
        STB_RECOVERY_MODE="$LOC_RECOVERY_MODE"
        STB_FRA_PATH="$LOC_FRA_PATH"
        STB_FRA_SIZE="$LOC_FRA_SIZE"
        STB_FRA_USED="$LOC_FRA_USED"
        STB_FRA_RECLAIM="$LOC_FRA_RECLAIM"
        STB_FRA_FILES="$LOC_FRA_FILES"
        STB_SERVICES="$LOC_SERVICES"
        STB_HOST=$(short_hostname)

        PRI_ROLE="$REM_ROLE"
        PRI_OPEN="$REM_OPEN"
        PRI_PROTECT="$REM_PROTECT"
        PRI_SWITCH="$REM_SWITCH"
        PRI_FORCE="$REM_FORCE"
        PRI_FLASH="$REM_FLASH"
        PRI_DBUNIQ="${REM_DBUNIQ:-${PEER_DBUNIQ:-?}}"
        PRI_BROKER="${LOC_BROKER}"
        PRI_REDO_CNT="$REM_REDO_CNT"
        PRI_REDO_MB="$REM_REDO_MB"
        PRI_SRL="$REM_SRL"
        PRI_DEST2_STATUS=""
        PRI_DEST2_DBUNIQ=""
        PRI_DEST2_ERROR=""
        PRI_ARCHGAP="$REM_ARCHGAP"
        PRI_FRA_PATH="$REM_FRA_PATH"
        PRI_FRA_SIZE="$REM_FRA_SIZE"
        PRI_FRA_USED="$REM_FRA_USED"
        PRI_FRA_RECLAIM="$REM_FRA_RECLAIM"
        PRI_FRA_FILES="$REM_FRA_FILES"
        PRI_SERVICES="$REM_SERVICES"
        PRI_HOST="${PEER_TNS:-unknown}"
    fi
}

# compute_fra_pct/compute_fra_effective now live in dg_render_common.sh.
# Lag display text uses the shared dg_display_lag_value ("none" for a
# truly-zero lag, raw value otherwise); the WARN/OK *decision* uses
# dg_parse_lag_seconds against DG_LAG_WARN_SECONDS instead of an
# any-nonzero check (WS4.3). See dg_render_common.sh.

assess_primary() {
    PRI_OK=unknown

    if [[ -n "${PRI_ROLE:-}" ]]; then
        PRI_OK=true
        printf '%s' "$PRI_ROLE" | grep -qi "PRIMARY" || {
            PRI_OK=false
            add_summary_error "Primary role is ${PRI_ROLE:-unknown}"
        }
    fi

    if [[ -n "${PRI_OPEN:-}" ]]; then
        printf '%s' "$PRI_OPEN" | grep -qi "READ WRITE" || {
            PRI_OK=false
            add_summary_error "Primary open mode is ${PRI_OPEN}"
        }
    fi

    if [[ -n "${PRI_FORCE:-}" ]] && ! printf '%s' "$PRI_FORCE" | grep -qi "YES"; then
        PRI_OK=false
        add_summary_error "Primary force logging is ${PRI_FORCE}"
    fi

    if [[ -n "${PRI_FLASH:-}" ]] && ! printf '%s' "$PRI_FLASH" | grep -qi "YES"; then
        add_summary_warning "Primary flashback is ${PRI_FLASH}"
    fi

    if [[ -n "${PRI_BROKER:-}" ]] && ! printf '%s' "$PRI_BROKER" | grep -qi "TRUE"; then
        PRI_OK=false
        add_summary_error "dg_broker_start is ${PRI_BROKER}"
    fi

    if [[ -n "${PRI_DEST2_STATUS:-}" ]] && [[ "${PRI_DEST2_STATUS}" != "VALID" ]]; then
        PRI_OK=false
        add_summary_error "Archive Dest 2 is ${PRI_DEST2_STATUS} ${PRI_DEST2_ERROR:-}"
    fi

    if [[ -n "${PRI_DEST2_DBUNIQ:-}" ]] && [[ -n "${PEER_DBUNIQ:-}" ]] && [[ "${PRI_DEST2_DBUNIQ}" != "${PEER_DBUNIQ}" ]]; then
        add_summary_warning "Archive Dest 2 targets ${PRI_DEST2_DBUNIQ}, expected ${PEER_DBUNIQ}"
    fi

    if [[ -n "${PRI_ARCHGAP:-}" ]] && [[ "${PRI_ARCHGAP:-0}" -gt 0 ]]; then
        PRI_OK=false
        add_summary_error "Primary reports ${PRI_ARCHGAP} archive gap(s)"
    fi

    if [[ -n "${PRI_SRL:-}" ]] && [[ "${PRI_SRL:-0}" -le 0 ]]; then
        add_summary_warning "Primary standby redo log count is ${PRI_SRL:-0}"
    fi

    if [[ -n "${PRI_FRA_SIZE:-}" ]]; then
        PRI_FRA_PCT=$(compute_fra_pct "$PRI_FRA_SIZE" "$PRI_FRA_USED" "$PRI_FRA_RECLAIM")
        PRI_FRA_EFFECTIVE_USED=$(compute_fra_effective "$PRI_FRA_USED" "$PRI_FRA_RECLAIM")
        if [[ "$PRI_FRA_PCT" -ge "$DG_FRA_CRIT_PCT" ]]; then
            PRI_OK=false
            add_summary_error "Primary FRA usage is ${PRI_FRA_PCT}%"
        elif [[ "$PRI_FRA_PCT" -ge "$DG_FRA_WARN_PCT" ]]; then
            add_summary_warning "Primary FRA usage is ${PRI_FRA_PCT}%"
        fi
    else
        PRI_FRA_PCT=0
        PRI_FRA_EFFECTIVE_USED=0.0
    fi
}

assess_standby() {
    STB_OK=unknown
    SEQ_LAG=""

    if [[ -n "${STB_ROLE:-}" ]]; then
        STB_OK=true
        printf '%s' "$STB_ROLE" | grep -qi "PHYSICAL STANDBY" || {
            STB_OK=false
            add_summary_error "Standby role is ${STB_ROLE:-unknown}"
        }
    elif [[ "$REMOTE_DATA_SOURCE" == "runtime" ]]; then
        STB_OK=false
        add_summary_error "Standby runtime data is missing"
    fi

    if [[ -n "${STB_OPEN:-}" ]] && ! printf '%s' "$STB_OPEN" | grep -qiE "MOUNTED|READ ONLY"; then
        add_summary_warning "Standby open mode is ${STB_OPEN}"
    fi

    if [[ -n "${STB_MRP_STATUS:-}" ]]; then
        printf '%s' "$STB_MRP_STATUS" | grep -qiE "APPLYING_LOG|WAIT_FOR_LOG" || {
            STB_OK=false
            add_summary_error "Standby MRP status is ${STB_MRP_STATUS}"
        }
    elif [[ -n "${STB_ROLE:-}" ]]; then
        STB_OK=false
        add_summary_error "Standby MRP is not running"
    fi

    if [[ -n "${STB_RECOVERY_MODE:-}" ]] && ! printf '%s' "$STB_RECOVERY_MODE" | grep -qi "REAL TIME"; then
        add_summary_warning "Standby recovery mode is ${STB_RECOVERY_MODE}"
    fi

    if [[ -n "${STB_TRANSPORT_LAG:-}" ]] && (( $(dg_parse_lag_seconds "$STB_TRANSPORT_LAG") > DG_LAG_WARN_SECONDS )); then
        add_summary_warning "Standby transport lag is ${STB_TRANSPORT_LAG}"
    fi

    if [[ -n "${STB_APPLY_LAG:-}" ]] && (( $(dg_parse_lag_seconds "$STB_APPLY_LAG") > DG_LAG_WARN_SECONDS )); then
        add_summary_warning "Standby apply lag is ${STB_APPLY_LAG}"
    fi

    if [[ -n "${STB_LAST_APPLIED:-}" ]] && [[ -n "${STB_LAST_RECEIVED:-}" ]] && [[ "${STB_LAST_RECEIVED:-0}" -gt 0 ]]; then
        SEQ_LAG=$((STB_LAST_RECEIVED - STB_LAST_APPLIED))
        if (( SEQ_LAG > DG_SEQ_GAP_CRIT )); then
            STB_OK=false
            add_summary_error "Standby sequence lag is ${SEQ_LAG}"
        elif (( SEQ_LAG > DG_SEQ_GAP_WARN )); then
            add_summary_warning "Standby sequence lag is ${SEQ_LAG}"
        fi
    fi

    if [[ -n "${STB_SRL:-}" ]] && [[ "${STB_SRL:-0}" -le 0 ]]; then
        STB_OK=false
        add_summary_error "Standby redo log count is ${STB_SRL:-0}"
    fi

    if [[ -n "${STB_ARCHGAP:-}" ]] && [[ "${STB_ARCHGAP:-0}" -gt 0 ]]; then
        STB_OK=false
        add_summary_error "Standby reports ${STB_ARCHGAP} archive gap(s)"
    fi

    if [[ -n "${STB_FLASH:-}" ]] && ! printf '%s' "$STB_FLASH" | grep -qi "YES"; then
        add_summary_warning "Standby flashback is ${STB_FLASH}"
    fi

    if [[ -n "${STB_FRA_SIZE:-}" ]]; then
        STB_FRA_PCT=$(compute_fra_pct "$STB_FRA_SIZE" "$STB_FRA_USED" "$STB_FRA_RECLAIM")
        STB_FRA_EFFECTIVE_USED=$(compute_fra_effective "$STB_FRA_USED" "$STB_FRA_RECLAIM")
        if [[ "$STB_FRA_PCT" -ge "$DG_FRA_CRIT_PCT" ]]; then
            STB_OK=false
            add_summary_error "Standby FRA usage is ${STB_FRA_PCT}%"
        elif [[ "$STB_FRA_PCT" -ge "$DG_FRA_WARN_PCT" ]]; then
            add_summary_warning "Standby FRA usage is ${STB_FRA_PCT}%"
        fi
    else
        STB_FRA_PCT=0
        STB_FRA_EFFECTIVE_USED=0.0
    fi
}

assess_broker() {
    BROKER_CONFIGURED=true
    if printf '%s' "$DGMGRL_CONFIG" | grep -qE "ORA-16532|not yet available|not exist"; then
        BROKER_CONFIGURED=false
        add_summary_error "Broker configuration is not configured"
        return
    fi

    if [[ -n "${BROKER_OVERALL:-}" ]]; then
        if [[ "$BROKER_OVERALL" == "ERROR" ]]; then
            add_summary_error "Broker overall status is ERROR"
        elif [[ "$BROKER_OVERALL" == "WARNING" ]]; then
            add_summary_warning "Broker overall status is WARNING"
        fi
    else
        add_summary_warning "Broker status could not be determined"
    fi

    while IFS= read -r line; do
        line_trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
        if printf '%s' "$line" | grep -qE '^[[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+'; then
            if printf '%s' "$line_trimmed" | grep -qi "Error"; then
                add_summary_error "Broker member issue: $line_trimmed"
            elif printf '%s' "$line_trimmed" | grep -qi "Warning"; then
                add_summary_warning "Broker member warning: $line_trimmed"
            fi
        fi
    done <<< "$DGMGRL_CONFIG"

    FSFO_MODE=$(printf '%s\n' "$DGMGRL_FSFO" | grep -i 'Fast-Start Failover:' | head -1 | sed 's/.*: *//' | xargs)
    FSFO_TARGET=$(printf '%s\n' "$DGMGRL_FSFO" | grep -i 'Target:' | sed 's/.*: *//' | xargs)
    FSFO_OBS=$(printf '%s\n' "$DGMGRL_FSFO" | grep -i 'Observer:' | sed 's/.*: *//' | xargs)
    FSFO_THRESHOLD=$(printf '%s\n' "$DGMGRL_FSFO" | grep -i 'Threshold:' | sed 's/.*: *//' | xargs)

    if [[ -n "${FSFO_MODE:-}" ]]; then
        if printf '%s' "$FSFO_MODE" | grep -qi "Enabled"; then
            if [[ "${LOC_FSFO_OBSERVER_PRESENT:-}" != "YES" ]]; then
                add_summary_warning "FSFO is enabled but observer is not present"
            fi
        else
            add_summary_warning "Fast-Start Failover disabled"
        fi
    fi
}

assess_data_source() {
    if [[ "$REMOTE_DATA_SOURCE" == "broker" ]]; then
        add_summary_warning "Peer runtime unavailable; broker view only"
    elif [[ "$REMOTE_DATA_SOURCE" == "local-only" ]]; then
        add_summary_info "Peer runtime skipped by request (-L)"
    fi
}

compute_state_labels() {
    if [[ $ERRORS -gt 0 ]]; then
        OVERALL_STATE="${RED}CRITICAL${NC}"
    elif [[ $WARNINGS -gt 0 ]]; then
        OVERALL_STATE="${YELLOW}ATTENTION${NC}"
    else
        OVERALL_STATE="${GREEN}HEALTHY${NC}"
    fi

    if [[ "$PRI_OK" == true ]]; then
        PRIMARY_STATE="${GREEN}OK${NC}"
    elif [[ -n "${PRI_ROLE:-}" ]]; then
        PRIMARY_STATE="${RED}CHECK${NC}"
    else
        PRIMARY_STATE="${YELLOW}UNKNOWN${NC}"
    fi

    if [[ "$STB_OK" == true ]]; then
        STANDBY_STATE="${GREEN}OK${NC}"
    elif [[ -n "${STB_ROLE:-}" ]] || [[ "$REMOTE_DATA_SOURCE" != "runtime" ]]; then
        STANDBY_STATE="${RED}CHECK${NC}"
    else
        STANDBY_STATE="${YELLOW}UNKNOWN${NC}"
    fi

    if [[ "$BROKER_CONFIGURED" != true ]]; then
        BROKER_STATE="${RED}NOT CONFIGURED${NC}"
    elif [[ "${BROKER_OVERALL:-}" == "SUCCESS" ]]; then
        BROKER_STATE="${GREEN}SUCCESS${NC}"
    elif [[ -n "${BROKER_OVERALL:-}" ]]; then
        BROKER_STATE="${YELLOW}${BROKER_OVERALL}${NC}"
    else
        BROKER_STATE="${YELLOW}UNKNOWN${NC}"
    fi

    if [[ "$REMOTE_DATA_SOURCE" == "broker" ]]; then
        PEER_SOURCE_STATE="${YELLOW}BROKER ONLY${NC}"
    elif [[ "$REMOTE_DATA_SOURCE" == "local-only" ]]; then
        PEER_SOURCE_STATE="${CYAN}LOCAL ONLY${NC}"
    else
        PEER_SOURCE_STATE="${GREEN}RUNTIME SQL${NC}"
    fi

    if $IS_PRIMARY && [[ "$REMOTE_DATA_SOURCE" != "runtime" ]]; then
        REPL_STATE="$PEER_SOURCE_STATE"
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
}

assess_all() {
    SUMMARY_ERRORS=()
    SUMMARY_WARNINGS=()
    SUMMARY_INFOS=()
    ERRORS=0
    WARNINGS=0

    assess_primary
    assess_standby
    assess_broker
    assess_data_source
    compute_state_labels
}

print_title() {
    local title="$1"
    printf "\n ${BOLD}${CYAN}%s${NC}  ${DIM}%s${NC}\n" "$title" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf " ${DIM}Local: %s (SID: %s, role: %s)  |  Peer: %s  |  Source: %s${NC}\n" \
        "$(short_hostname)" "${ORACLE_SID}" "${LOC_LABEL}" "${PEER_DBUNIQ:-unknown}" "${REMOTE_DATA_SOURCE_LABEL}"
}

print_top_findings() {
    local limit=5 count=0 item
    header "TOP FINDINGS"
    if [[ ${#SUMMARY_ERRORS[@]} -eq 0 && ${#SUMMARY_WARNINGS[@]} -eq 0 ]]; then
        row "Status" "No findings" "$CHK"
        return
    fi

    if [[ ${#SUMMARY_ERRORS[@]} -gt 0 ]]; then
        for item in "${SUMMARY_ERRORS[@]}"; do
            row "Error" "$item" "$FAIL"
            count=$((count + 1))
            (( count >= limit )) && return
        done
    fi
    if [[ ${#SUMMARY_WARNINGS[@]} -gt 0 ]]; then
        for item in "${SUMMARY_WARNINGS[@]}"; do
            row "Warning" "$item" "$WARN"
            count=$((count + 1))
            (( count >= limit )) && return
        done
    fi
}

render_primary_triage() {
    header "PRIMARY"
    if [[ -n "${PRI_ROLE:-}" ]]; then
        row "Role" "${PRI_ROLE:-?}" "$(status_icon "${PRI_ROLE:-}" "PRIMARY")"
        row "Open Mode" "${PRI_OPEN:-?}" "$(status_icon "${PRI_OPEN:-}" "READ WRITE")"
        row "Switchover" "${PRI_SWITCH:-?}" "$(warn_icon "${PRI_SWITCH:-}" "TO STANDBY" "SESSIONS ACTIVE")"
        row "Force Logging" "${PRI_FORCE:-?}" "$(status_icon "${PRI_FORCE:-}" "YES")"
        row "Flashback" "${PRI_FLASH:-?}" "$(warn_icon "${PRI_FLASH:-}" "YES")"
        row "DG Broker" "${PRI_BROKER:-FALSE}" "$(status_icon "${PRI_BROKER:-FALSE}" "TRUE")"
        if [[ -n "${PRI_DEST2_STATUS:-}" ]]; then
            if [[ "${PRI_DEST2_STATUS}" == "VALID" ]]; then
                row "Archive Dest 2" "${PRI_DEST2_STATUS}" "$CHK"
            else
                row "Archive Dest 2" "${PRI_DEST2_STATUS} ${PRI_DEST2_ERROR:-}" "$FAIL"
            fi
        fi
        if [[ -n "${PRI_DEST2_DBUNIQ:-}" ]]; then
            if [[ -n "${PEER_DBUNIQ:-}" && "${PRI_DEST2_DBUNIQ}" != "${PEER_DBUNIQ}" ]]; then
                row "Dest 2 Target" "${PRI_DEST2_DBUNIQ} (expected ${PEER_DBUNIQ})" "$WARN"
            else
                row "Dest 2 Target" "${PRI_DEST2_DBUNIQ}" "$CHK"
            fi
        fi
        row "Redo Logs" "${PRI_REDO_CNT:-?} groups (${PRI_REDO_MB:-?} MB total)"
        if [[ -n "${PRI_SRL:-}" ]] && [[ "${PRI_SRL:-0}" -gt 0 ]]; then
            row "Standby Redo" "${PRI_SRL} groups" "$CHK"
        else
            row "Standby Redo" "${PRI_SRL:-0} groups" "$WARN"
        fi
        if [[ -n "${PRI_FRA_PATH:-}" ]]; then
            row "FRA Usage" "${PRI_FRA_EFFECTIVE_USED}/${PRI_FRA_SIZE} GB effective (${PRI_FRA_PCT}%)" "$(dg_fra_icon "${PRI_FRA_PCT:-0}")"
        fi
    else
        row "Peer View" "Broker view only; runtime SQL unavailable"
        render_peer_broker_view "PRIMARY"
    fi
}

render_standby_triage() {
    header "STANDBY"
    if [[ -n "${STB_ROLE:-}" ]]; then
        row "Role" "${STB_ROLE:-?}" "$(status_icon "${STB_ROLE:-}" "PHYSICAL STANDBY")"
        row "Open Mode" "${STB_OPEN:-?}" "$(warn_icon "${STB_OPEN:-}" "MOUNTED" "READ ONLY")"
        row "Switchover" "${STB_SWITCH:-?}" "$(warn_icon "${STB_SWITCH:-}" "NOT ALLOWED" "SWITCHOVER PENDING")"
        if [[ -n "${STB_MRP_STATUS:-}" ]]; then
            row "MRP Status" "${STB_MRP_STATUS} (seq# ${STB_MRP_SEQ:-?})" "$(status_icon "${STB_MRP_STATUS:-}" "APPLYING_LOG" "WAIT_FOR_LOG")"
        else
            row "MRP Status" "NOT RUNNING" "$FAIL"
        fi
        if [[ -n "${STB_RECOVERY_MODE:-}" ]]; then
            row "Recovery Mode" "${STB_RECOVERY_MODE}" "$(status_icon "${STB_RECOVERY_MODE:-}" "REAL TIME")"
        fi

        if [[ -n "${STB_TRANSPORT_LAG:-}" ]]; then
            row "Transport Lag" "$(dg_display_lag_value "$STB_TRANSPORT_LAG")" "$(dg_lag_icon "$STB_TRANSPORT_LAG")"
        fi
        if [[ -n "${STB_APPLY_LAG:-}" ]]; then
            row "Apply Lag" "$(dg_display_lag_value "$STB_APPLY_LAG")" "$(dg_lag_icon "$STB_APPLY_LAG")"
            if [[ -n "${STB_APPLY_FINISH:-}" ]] && (( $(dg_parse_lag_seconds "$STB_APPLY_LAG") > DG_LAG_WARN_SECONDS )); then
                row "Apply Finish ETA" "${STB_APPLY_FINISH}"
            fi
        fi
        if [[ -n "${STB_LAST_APPLIED:-}" ]] && [[ -n "${STB_LAST_RECEIVED:-}" ]] && [[ "${STB_LAST_RECEIVED:-0}" -gt 0 ]]; then
            if [[ -n "${SEQ_LAG:-}" ]] && (( SEQ_LAG > DG_SEQ_GAP_WARN )); then
                row "Sequences" "applied=${STB_LAST_APPLIED} received=${STB_LAST_RECEIVED} (lag ${SEQ_LAG})" "$(dg_seq_gap_icon "${SEQ_LAG:-0}")"
            else
                row "Sequences" "applied=${STB_LAST_APPLIED} received=${STB_LAST_RECEIVED}" "$(dg_seq_gap_icon "${SEQ_LAG:-0}")"
            fi
        fi
        if [[ -n "${STB_SRL:-}" ]] && [[ "${STB_SRL:-0}" -gt 0 ]]; then
            row "Standby Redo" "${STB_SRL} groups" "$CHK"
        else
            row "Standby Redo" "${STB_SRL:-0} groups" "$FAIL"
        fi
        if [[ -n "${STB_ARCHGAP:-}" ]] && [[ "${STB_ARCHGAP:-0}" -gt 0 ]]; then
            row "Archive Gaps" "${STB_ARCHGAP} gap(s)" "$FAIL"
        fi
        if [[ -n "${STB_FRA_PATH:-}" ]]; then
            row "FRA Usage" "${STB_FRA_EFFECTIVE_USED}/${STB_FRA_SIZE} GB effective (${STB_FRA_PCT}%)" "$(dg_fra_icon "${STB_FRA_PCT:-0}")"
        fi
    else
        row "Peer View" "Broker view only; runtime SQL unavailable"
        render_peer_broker_view "STANDBY"
    fi
}

render_peer_broker_view() {
    local expected="$1"
    local peer_role peer_state peer_tlag peer_alag peer_db_status
    peer_role=$(printf '%s\n' "$DGMGRL_PEER" | grep 'Role:' | sed 's/.*Role: *//' | xargs)
    peer_state=$(printf '%s\n' "$DGMGRL_PEER" | grep 'Intended State:' | sed 's/.*Intended State: *//' | xargs)
    peer_tlag=$(printf '%s\n' "$DGMGRL_PEER" | grep 'Transport Lag:' | sed 's/.*Transport Lag: *//' | xargs)
    peer_alag=$(printf '%s\n' "$DGMGRL_PEER" | grep 'Apply Lag:' | sed 's/.*Apply Lag: *//' | xargs)
    peer_db_status=$(printf '%s\n' "$DGMGRL_PEER" | tail -3 | extract_first_status)

    if [[ -n "$peer_role" ]]; then
        if [[ "$expected" == "PRIMARY" ]]; then
            row "Role" "$peer_role" "$(status_icon "$peer_role" "PRIMARY")"
        else
            row "Role" "$peer_role" "$(status_icon "$peer_role" "PHYSICAL STANDBY" "PRIMARY")"
        fi
    fi
    [[ -n "$peer_state" ]] && row "Intended State" "$peer_state"
    [[ -n "$peer_tlag" ]] && row "Transport Lag" "$peer_tlag"
    [[ -n "$peer_alag" ]] && row "Apply Lag" "$peer_alag"
    [[ -n "$peer_db_status" ]] && row "Broker Status" "$peer_db_status" "$(status_icon "$peer_db_status" "SUCCESS")"
}

render_broker_triage() {
    header "BROKER / FSFO"
    if [[ "$BROKER_CONFIGURED" != true ]]; then
        row "Configuration" "NOT CONFIGURED" "$FAIL"
        return
    fi

    row "Configuration" "${BROKER_CFG_NAME:-unknown}"
    [[ -n "${BROKER_OVERALL:-}" ]] && row "Overall Status" "${BROKER_OVERALL}" "$(status_icon "${BROKER_OVERALL:-}" "SUCCESS")"

    if [[ -n "${FSFO_MODE:-}" ]]; then
        if printf '%s' "$FSFO_MODE" | grep -qi "Enabled"; then
            row "Fast-Start Failover" "$FSFO_MODE" "$CHK"
        else
            row "Fast-Start Failover" "$FSFO_MODE" "$WARN"
        fi
    fi
    [[ -n "${FSFO_TARGET:-}" && "${FSFO_TARGET}" != "(none)" ]] && row "Target" "${FSFO_TARGET}"
    if [[ -n "${LOC_FSFO_OBSERVER_PRESENT:-}" ]]; then
        if [[ "${LOC_FSFO_OBSERVER_PRESENT}" == "YES" ]]; then
            row "Observer Present" "YES" "$CHK"
        else
            row "Observer Present" "${LOC_FSFO_OBSERVER_PRESENT}" "$WARN"
        fi
    fi
    [[ -n "${LOC_FSFO_OBSERVER_HOST:-}" ]] && row "Observer Host" "${LOC_FSFO_OBSERVER_HOST}"
}

render_recent_events_triage() {
    header "RECENT DG EVENTS"
    print_event_block "Recent Alert Events" "$LOC_ALERT_MATCHES" "${LOC_ALERT_MATCH_COUNT:-0}" 3 "${LOC_ALERT_FILE}"
    printf "\n"
    print_event_block "Recent Broker Events" "$LOC_DRC_MATCHES" "${LOC_DRC_MATCH_COUNT:-0}" 3 "${LOC_DRC_FILE}"
}

render_triage_output() {
    local pri_summary_mode stb_summary_mode
    if [[ -n "${PRI_OPEN:-}" ]]; then
        pri_summary_mode="$PRI_OPEN"
    else
        pri_summary_mode="broker view"
    fi
    if [[ -n "${STB_MRP_STATUS:-}" ]]; then
        stb_summary_mode="MRP ${STB_MRP_STATUS}"
    else
        stb_summary_mode="broker view"
    fi

    print_title "Data Guard Triage"
    print_top_findings

    header "AT A GLANCE"
    row "Overall" "errors=${ERRORS} warnings=${WARNINGS}" "$OVERALL_STATE"
    row "Primary" "${PRI_DBUNIQ:-?} / ${pri_summary_mode}" "$PRIMARY_STATE"
    row "Standby" "${STB_DBUNIQ:-?} / ${stb_summary_mode}" "$STANDBY_STATE"
    row "Broker" "${BROKER_CFG_NAME:-not configured}" "$BROKER_STATE"
    row "Redo Apply" "transport=${STB_TRANSPORT_LAG:-n/a}, apply=${STB_APPLY_LAG:-n/a}" "$REPL_STATE"
    row "Peer Data" "${REMOTE_DATA_SOURCE_LABEL}" "$PEER_SOURCE_STATE"

    render_primary_triage
    render_standby_triage
    render_broker_triage
    render_recent_events_triage

    printf "\n ${DIM}%s${NC}\n" "$HLINE"
    if [[ $ERRORS -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
        printf " ${BOLD}${GREEN} HEALTHY${NC}  ${DIM}No issues detected${NC}\n\n"
    elif [[ $ERRORS -eq 0 ]]; then
        printf " ${BOLD}${YELLOW} WARNING${NC}  ${DIM}${WARNINGS} warning(s)${NC}\n\n"
    else
        printf " ${BOLD}${RED} ISSUES ${NC}  ${RED}${ERRORS} error(s)${NC}"
        [[ $WARNINGS -gt 0 ]] && printf "  ${YELLOW}${WARNINGS} warning(s)${NC}"
        printf "\n\n"
    fi
}

render_primary_diag() {
    header "PRIMARY DATABASE  (${PRI_DBUNIQ:-?})"
    if [[ -n "${PRI_ROLE:-}" ]]; then
        subheader "Identity"
        row "Role" "$PRI_ROLE" "$(status_icon "$PRI_ROLE" "PRIMARY")"
        row "Open Mode" "$PRI_OPEN" "$(status_icon "$PRI_OPEN" "READ WRITE")"
        row "Protection Mode" "$PRI_PROTECT"
        row "Switchover Status" "$PRI_SWITCH" "$(warn_icon "$PRI_SWITCH" "TO STANDBY" "SESSIONS ACTIVE")"
        row "Force Logging" "$PRI_FORCE" "$(status_icon "$PRI_FORCE" "YES")"
        row "Flashback" "$PRI_FLASH" "$(warn_icon "$PRI_FLASH" "YES")"

        subheader "Services"
        row "DG Broker" "${PRI_BROKER:-FALSE}" "$(status_icon "${PRI_BROKER:-FALSE}" "TRUE")"
        row "Running Services" "${PRI_SERVICES:-NONE}"

        subheader "Redo / Archive"
        row "Online Redo Logs" "${PRI_REDO_CNT:-?} groups (${PRI_REDO_MB:-?} MB total)"
        if [[ -n "${PRI_SRL:-}" ]] && [[ "${PRI_SRL:-0}" -gt 0 ]]; then
            row "Standby Redo Logs" "${PRI_SRL} groups" "$CHK"
        else
            row "Standby Redo Logs" "${PRI_SRL:-NONE}" "$WARN"
        fi
        if [[ -n "${PRI_DEST2_STATUS:-}" ]]; then
            if [[ "${PRI_DEST2_STATUS}" == "VALID" ]]; then
                row "Archive Dest 2" "${PRI_DEST2_STATUS}" "$CHK"
            else
                row "Archive Dest 2" "${PRI_DEST2_STATUS} ${PRI_DEST2_ERROR:-}" "$FAIL"
            fi
        fi
        [[ -n "${PRI_DEST2_DBUNIQ:-}" ]] && row "Dest 2 Target" "${PRI_DEST2_DBUNIQ}"
        if [[ -n "${PRI_ARCHGAP:-}" ]] && [[ "${PRI_ARCHGAP:-0}" -gt 0 ]]; then
            row "Archive Gaps" "${PRI_ARCHGAP} gap(s)" "$FAIL"
        fi

        subheader "Recovery Area"
        if [[ -n "${PRI_FRA_PATH:-}" ]]; then
            row "FRA Usage" "${PRI_FRA_EFFECTIVE_USED}/${PRI_FRA_SIZE} GB effective (${PRI_FRA_PCT}%), reclaimable ${PRI_FRA_RECLAIM} GB" "$(dg_fra_icon "${PRI_FRA_PCT:-0}")"
            row "FRA Location" "${PRI_FRA_PATH} (${PRI_FRA_FILES:-0} files)"
        fi
    else
        subheader "Broker View"
        render_peer_broker_view "PRIMARY"
        printf "  ${DIM}%-24s${NC} %s\n" "" "(runtime SQL unavailable)"
    fi
}

render_standby_diag() {
    header "STANDBY DATABASE  (${STB_DBUNIQ:-?})"
    if [[ -n "${STB_ROLE:-}" ]]; then
        subheader "Identity"
        row "Role" "$STB_ROLE" "$(status_icon "$STB_ROLE" "PHYSICAL STANDBY")"
        row "Open Mode" "$STB_OPEN" "$(warn_icon "$STB_OPEN" "MOUNTED" "READ ONLY")"
        row "Protection Mode" "${STB_PROTECT:-$LOC_PROTECT}"
        row "Switchover Status" "$STB_SWITCH" "$(warn_icon "$STB_SWITCH" "NOT ALLOWED" "SWITCHOVER PENDING")"
        row "Flashback" "${STB_FLASH:-unknown}" "$(warn_icon "${STB_FLASH:-unknown}" "YES")"

        subheader "Services"
        row "Running Services" "${STB_SERVICES:-NONE}"

        subheader "Recovery / Apply"
        if [[ -n "${STB_MRP_STATUS:-}" ]]; then
            row "MRP Status" "${STB_MRP_STATUS} (seq# ${STB_MRP_SEQ:-?})" "$(status_icon "$STB_MRP_STATUS" "APPLYING_LOG" "WAIT_FOR_LOG")"
        else
            row "MRP Status" "NOT RUNNING" "$FAIL"
        fi
        if [[ -n "${STB_RECOVERY_MODE:-}" ]]; then
            row "Recovery Mode" "$STB_RECOVERY_MODE" "$(status_icon "$STB_RECOVERY_MODE" "REAL TIME")"
        fi

        if [[ -n "${STB_TRANSPORT_LAG:-}" ]]; then
            row "Transport Lag" "$(dg_display_lag_value "$STB_TRANSPORT_LAG")" "$(dg_lag_icon "$STB_TRANSPORT_LAG")"
        fi
        if [[ -n "${STB_APPLY_LAG:-}" ]]; then
            row "Apply Lag" "$(dg_display_lag_value "$STB_APPLY_LAG")" "$(dg_lag_icon "$STB_APPLY_LAG")"
        fi
        if [[ -n "${STB_APPLY_FINISH:-}" ]] && (( $(dg_parse_lag_seconds "$STB_APPLY_LAG") > DG_LAG_WARN_SECONDS )); then
            row "Apply Finish Time" "${STB_APPLY_FINISH}"
        fi

        if [[ -n "${STB_LAST_APPLIED:-}" ]] && [[ -n "${STB_LAST_RECEIVED:-}" ]] && [[ "${STB_LAST_RECEIVED:-0}" -gt 0 ]]; then
            if [[ -n "${SEQ_LAG:-}" ]] && (( SEQ_LAG > DG_SEQ_GAP_WARN )); then
                row "Sequences" "applied=${STB_LAST_APPLIED}  received=${STB_LAST_RECEIVED}  (lag: ${SEQ_LAG})" "$(dg_seq_gap_icon "${SEQ_LAG:-0}")"
            else
                row "Sequences" "applied=${STB_LAST_APPLIED}  received=${STB_LAST_RECEIVED}" "$(dg_seq_gap_icon "${SEQ_LAG:-0}")"
            fi
        fi

        subheader "Redo / Archive"
        if [[ -n "${STB_SRL:-}" ]] && [[ "${STB_SRL:-0}" -gt 0 ]]; then
            row "Standby Redo Logs" "${STB_SRL} groups" "$CHK"
        else
            row "Standby Redo Logs" "${STB_SRL:-NONE}" "$FAIL"
        fi
        if [[ -n "${STB_ARCHGAP:-}" ]] && [[ "${STB_ARCHGAP:-0}" -gt 0 ]]; then
            row "Archive Gaps" "${STB_ARCHGAP} gap(s)" "$FAIL"
        fi

        subheader "Recovery Area"
        if [[ -n "${STB_FRA_PATH:-}" ]]; then
            row "FRA Usage" "${STB_FRA_EFFECTIVE_USED}/${STB_FRA_SIZE} GB effective (${STB_FRA_PCT}%), reclaimable ${STB_FRA_RECLAIM} GB" "$(dg_fra_icon "${STB_FRA_PCT:-0}")"
            row "FRA Location" "${STB_FRA_PATH} (${STB_FRA_FILES:-0} files)"
        fi
    else
        subheader "Broker View"
        render_peer_broker_view "STANDBY"
        printf "  ${DIM}%-24s${NC} %s\n" "" "(runtime SQL unavailable)"
    fi
}

render_broker_diag() {
    header "DATA GUARD BROKER"
    if [[ "$BROKER_CONFIGURED" != true ]]; then
        row "Configuration" "NOT CONFIGURED" "$FAIL"
        return
    fi

    row "Configuration" "${BROKER_CFG_NAME:-unknown}"
    [[ -n "${BROKER_OVERALL:-}" ]] && row "Overall Status" "${BROKER_OVERALL}" "$(status_icon "${BROKER_OVERALL:-}" "SUCCESS")"

    while IFS= read -r line; do
        line_trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
        if printf '%s' "$line" | grep -qE '^[[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+'; then
            if printf '%s' "$line_trimmed" | grep -qi "Error"; then
                row "" "$line_trimmed" "$FAIL"
            elif printf '%s' "$line_trimmed" | grep -qi "Warning"; then
                row "" "$line_trimmed" "$WARN"
            else
                row "" "$line_trimmed" "$CHK"
            fi
        elif is_error_event "$line_trimmed"; then
            printf "  ${DIM}%-24s${NC} ${RED}%s${NC}\n" "" "$line_trimmed"
        fi
    done <<< "$DGMGRL_CONFIG"

    if [[ -n "${FSFO_MODE:-}" ]]; then
        if printf '%s' "$FSFO_MODE" | grep -qi "Enabled"; then
            row "Fast-Start Failover" "$FSFO_MODE" "$CHK"
        else
            row "Fast-Start Failover" "$FSFO_MODE" "$WARN"
        fi
    fi
    [[ -n "${FSFO_TARGET:-}" && "${FSFO_TARGET}" != "(none)" ]] && row "Target" "$FSFO_TARGET"
    [[ -n "${FSFO_OBS:-}" && "${FSFO_OBS}" != "(none)" ]] && row "Observer" "$FSFO_OBS"
    [[ -n "${FSFO_THRESHOLD:-}" ]] && row "Threshold" "$FSFO_THRESHOLD"
    if [[ -n "${LOC_FSFO_STATUS:-}" ]]; then
        row "Local FSFO Status" "$LOC_FSFO_STATUS"
    fi
    if [[ -n "${LOC_FSFO_OBSERVER_PRESENT:-}" ]]; then
        if [[ "${LOC_FSFO_OBSERVER_PRESENT}" == "YES" ]]; then
            row "Observer Present" "$LOC_FSFO_OBSERVER_PRESENT" "$CHK"
        else
            row "Observer Present" "$LOC_FSFO_OBSERVER_PRESENT" "$WARN"
        fi
    fi
    [[ -n "${LOC_FSFO_OBSERVER_HOST:-}" ]] && row "Observer Host" "$LOC_FSFO_OBSERVER_HOST"
}

render_events_diag() {
    header "RECENT ALERT LOG (DATA GUARD)"
    print_event_block "Alert Log" "$LOC_ALERT_MATCHES" "${LOC_ALERT_MATCH_COUNT:-0}" 15 "${LOC_ALERT_FILE}"
    printf "\n"
    print_event_block "Broker Log" "$LOC_DRC_MATCHES" "${LOC_DRC_MATCH_COUNT:-0}" 10 "${LOC_DRC_FILE}"
}

render_interpretation_diag() {
    header "INTERPRETATION"
    row "Peer Data Source" "${REMOTE_DATA_SOURCE_LABEL}" "$PEER_SOURCE_STATE"
    row "Remote Auth" "${REMOTE_AUTH_METHOD}"
    row "Remote Result" "${REMOTE_CONNECTION_RESULT}"
    row "Remote Timeout" "${REMOTE_TEST_TIMEOUT}s"
}

render_diag_output() {
    local pri_summary_mode stb_summary_mode
    if [[ -n "${PRI_OPEN:-}" ]]; then
        pri_summary_mode="$PRI_OPEN"
    else
        pri_summary_mode="broker view"
    fi
    if [[ -n "${STB_MRP_STATUS:-}" ]]; then
        stb_summary_mode="MRP ${STB_MRP_STATUS}"
    else
        stb_summary_mode="broker view"
    fi

    print_title "Data Guard Diagnostics"

    header "AT A GLANCE"
    row "Overall" "errors=${ERRORS} warnings=${WARNINGS}" "$OVERALL_STATE"
    row "Primary" "${PRI_DBUNIQ:-?} / ${pri_summary_mode}" "$PRIMARY_STATE"
    row "Standby" "${STB_DBUNIQ:-?} / ${stb_summary_mode}" "$STANDBY_STATE"
    row "Broker" "${BROKER_CFG_NAME:-not configured}" "$BROKER_STATE"
    row "Redo Apply" "transport=${STB_TRANSPORT_LAG:-n/a}, apply=${STB_APPLY_LAG:-n/a}" "$REPL_STATE"
    row "Peer Data" "${REMOTE_DATA_SOURCE_LABEL}" "$PEER_SOURCE_STATE"

    render_interpretation_diag
    render_primary_diag
    render_standby_diag
    render_broker_diag
    render_events_diag

    header "FINAL SUMMARY"
    if [[ $ERRORS -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
        row "Status" "No problems detected" "$CHK"
    else
        local item
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
}

collect_all_status_data() {
    collect_identity
    collect_broker_data
    attempt_remote_connection
    collect_remote_sql
    collect_local_sql
    parse_local_sql
    parse_remote_sql
    collect_log_matches
    assign_role_views
    assess_all
}

dg_local_status_exit_code() {
    if [[ $ERRORS -gt 0 ]]; then
        return 2
    fi
    if [[ $WARNINGS -gt 0 ]]; then
        return 1
    fi
    return 0
}

dg_local_status_main() {
    local mode="$1"
    shift

    DG_STATUS_MODE="$mode"
    DG_SCRIPT_NAME="$(basename "${BASH_SOURCE[1]}")"

    case "$mode" in
        triage)
            REMOTE_DEFAULT_PROMPT=false
            ;;
        diag)
            REMOTE_DEFAULT_PROMPT=true
            ;;
        *)
            printf "Unknown local status mode: %s\n" "$mode" >&2
            return 64
            ;;
    esac

    parse_args "$DG_SCRIPT_NAME" "$@" || return $?
    $SHOW_HELP && return 0

    verify_oracle_env || return $?
    collect_all_status_data

    case "$mode" in
        triage) render_triage_output ;;
        diag) render_diag_output ;;
    esac

    dg_local_status_exit_code
}
