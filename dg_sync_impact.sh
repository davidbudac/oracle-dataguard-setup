#!/usr/bin/env bash
# ============================================================
# Synchronous Data Guard Impact Report - Standalone
# ============================================================
# Quantifies what synchronous redo transport (SYNC / FASTSYNC)
# is costing the local PRIMARY database: how much commit latency
# ('log file sync') the remote acknowledgment adds, and what that
# adds up to across the workload.
#
# The naive "subtract the remote wait" is wrong: since 11g R2 the
# local redo write and the network send to the standby run IN
# PARALLEL (LGWR starts the remote write before issuing the local
# one), so the redo-write phase of a commit lasts about
# max(local write, remote ack) - not their sum. This script
# therefore estimates
#
#     overhead per redo write = E[max(L,R)] - E[L]
#
# from the wait-event histograms (L = 'log file parallel write',
# R = 'SYNC Remote Write'), brackets it with hard bounds from the
# event averages, scales it to the workload (per commit, per hour,
# % of DB time), and cross-checks it against AWR history -
# including an optional empirical before/after comparison with a
# pre-SYNC baseline window.
#
# Run on the PRIMARY host with:
#   - ORACLE_SID and ORACLE_HOME set
#   - sqlplus '/ as sysdba' working
#
# LICENSING: the AWR trend, baseline and ASH sections query
# DBA_HIST_* / V$ACTIVE_SESSION_HISTORY, which require the Oracle
# Diagnostics Pack license. Use --no-pack to restrict the report
# to freely usable V$ views.
#
# Usage:
#   ./dg_sync_impact.sh
#   ./dg_sync_impact.sh --ash-hours 6 --days 14
#   ./dg_sync_impact.sh --baseline-begin '2026-07-01 00:00' \
#                       --baseline-end   '2026-07-08 00:00'
#   ./dg_sync_impact.sh --baseline-begin 12000 --baseline-end 12168
#   ./dg_sync_impact.sh --auto-baseline
#   ./dg_sync_impact.sh --no-pack
#   ./dg_sync_impact.sh -o /tmp/sync_impact.md
# ============================================================

set -e
set -o pipefail

ASH_HOURS=24
AWR_DAYS=7
BASELINE_BEGIN=""
BASELINE_END=""
AUTO_BASELINE="NO"
NO_PACK="NO"
OUTPUT_FILE=""
OUTPUT_FORMAT="md"

# --auto-baseline classification thresholds (env-overridable). A snapshot
# is SYNC when 'SYNC Remote Write' waits / redo writes >= DG_SI_SYNC_RATIO,
# NOSYNC when <= DG_SI_NOSYNC_RATIO, IDLE below DG_SI_MIN_WRITES redo
# writes (or on a restart's negative delta), MIXED otherwise.
DG_SI_SYNC_RATIO="${DG_SI_SYNC_RATIO:-0.5}"
DG_SI_NOSYNC_RATIO="${DG_SI_NOSYNC_RATIO:-0.05}"
DG_SI_MIN_WRITES="${DG_SI_MIN_WRITES:-50}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Reports the commit-latency impact of synchronous Data Guard redo transport
on the local PRIMARY database, connecting via 'sqlplus / as sysdba'.

Options:
      --ash-hours N         ASH attribution window in hours (default: 24)
      --days N              AWR trend window in days (default: 7)
      --baseline-begin V    Baseline window start: 'YYYY-MM-DD HH24:MI' or a
                            pure-digit AWR snapshot ID. Enables the empirical
                            before/after comparison against a pre-SYNC period.
      --baseline-end V      Baseline window end (same formats; both or neither)
      --auto-baseline       Detect the pre-SYNC baseline window from AWR history
      --no-pack             Skip AWR/ASH sections (no Diagnostics Pack license);
                            only freely usable V\$ views are queried
      --html                Emit a self-contained HTML page instead of Markdown
  -o, --output FILE         Also write the report to FILE
  -h, --help                Show this help

Exit codes:
  0  report produced (warnings possible - read the report)
  1  fatal: sqlplus/environment/connection problem, or not a PRIMARY
  2  invalid arguments
EOF
}

# is_uint VALUE -> 0 when VALUE is a non-empty string of digits
is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# baseline_kind VALUE -> prints "snap", "date" or "bad"
baseline_kind() {
    if is_uint "$1"; then
        echo "snap"
        return 0
    fi
    case "$1" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' '[0-9][0-9]:[0-9][0-9])
            echo "date" ;;
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
            echo "date" ;;
        *)  echo "bad" ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ash-hours)        ASH_HOURS="$2"; shift 2 ;;
        --days)             AWR_DAYS="$2"; shift 2 ;;
        --baseline-begin)   BASELINE_BEGIN="$2"; shift 2 ;;
        --baseline-end)     BASELINE_END="$2"; shift 2 ;;
        --auto-baseline)    AUTO_BASELINE="YES"; shift ;;
        --no-pack)          NO_PACK="YES"; shift ;;
        --html)             OUTPUT_FORMAT="html"; shift ;;
        -o|--output)        OUTPUT_FILE="$2"; shift 2 ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

arg_error() { echo "ERROR: $*" >&2; usage >&2; exit 2; }

is_uint "$ASH_HOURS" || arg_error "--ash-hours must be a positive integer (got '${ASH_HOURS}')."
is_uint "$AWR_DAYS"  || arg_error "--days must be a positive integer (got '${AWR_DAYS}')."
[[ "$ASH_HOURS" -gt 0 ]] || arg_error "--ash-hours must be greater than zero."
[[ "$AWR_DAYS"  -gt 0 ]] || arg_error "--days must be greater than zero."

BASELINE_MODE=""
if [[ -n "$BASELINE_BEGIN" || -n "$BASELINE_END" ]]; then
    [[ -n "$BASELINE_BEGIN" && -n "$BASELINE_END" ]] \
        || arg_error "--baseline-begin and --baseline-end must be given together."
    [[ "$NO_PACK" == "NO" ]] \
        || arg_error "--baseline-* requires AWR and cannot be combined with --no-pack."
    BK1=$(baseline_kind "$BASELINE_BEGIN")
    BK2=$(baseline_kind "$BASELINE_END")
    [[ "$BK1" != "bad" && "$BK2" != "bad" ]] \
        || arg_error "Baseline values must be 'YYYY-MM-DD[ HH24:MI]' or a snapshot ID."
    [[ "$BK1" == "$BK2" ]] \
        || arg_error "Baseline begin/end must use the same format (both dates or both snap IDs)."
    BASELINE_MODE="$BK1"
    if [[ "$BASELINE_MODE" == "snap" && "$BASELINE_BEGIN" -ge "$BASELINE_END" ]]; then
        arg_error "--baseline-begin snapshot must be lower than --baseline-end."
    fi
fi

if [[ "$AUTO_BASELINE" == "YES" ]]; then
    [[ -z "$BASELINE_BEGIN" && -z "$BASELINE_END" ]] \
        || arg_error "--auto-baseline cannot be combined with --baseline-begin/--baseline-end."
    [[ "$NO_PACK" == "NO" ]] \
        || arg_error "--auto-baseline requires AWR and cannot be combined with --no-pack."
fi

# ============================================================
# Pre-flight
# ============================================================

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }
info() { echo "INFO:  $*" >&2; }

info "Starting: ORACLE_SID=${ORACLE_SID:-unset}, ORACLE_HOME=${ORACLE_HOME:-unset}"

[[ -n "$ORACLE_SID" ]]  || die "ORACLE_SID is not set."
[[ -n "$ORACLE_HOME" ]] || die "ORACLE_HOME is not set."
command -v sqlplus >/dev/null || die "sqlplus not on PATH ($ORACLE_HOME/bin/sqlplus expected)."
info "Pre-flight checks passed."

# ============================================================
# SQL helpers (inlined - no external SQL files)
# ============================================================
# Standalone by design (no common/dg_functions.sh dependency) so the
# script can be copied to a DB host on its own.
# NLS_NUMERIC_CHARACTERS is forced so every number arrives with a '.'
# decimal separator regardless of the server locale - the report math
# below (awk) depends on it.

# Every query is kept verbatim so the report can show exactly what it ran.
# A directory, not shell variables: collectors run inside $(...) subshells,
# so a variable set in run_sql would never reach the emitter. Best-effort -
# without a writable temp dir the report simply omits the query blocks.
QDIR=""
if QDIR=$(mktemp -d "${TMPDIR:-/tmp}/dg_sync_impact.XXXXXX" 2>/dev/null); then
    trap 'rm -rf "$QDIR"' EXIT INT TERM
else
    QDIR=""
fi

# recorded_sql TAG -> the exact text of the TAG query, empty if unrecorded
recorded_sql() {
    [[ -n "$QDIR" && -f "$QDIR/$1.sql" ]] || return 0
    cat "$QDIR/$1.sql"
}

run_sql() {
    local sql="$1"
    local tag
    if [[ -n "$QDIR" ]]; then
        tag=$(printf '%s\n' "$sql" | sed -n 's/^-- QTAG:\([A-Za-z0-9_]*\).*/\1/p' | head -1)
        [[ -n "$tag" ]] && printf '%s\n' "$sql" > "$QDIR/$tag.sql"
    fi
    sqlplus -s -L / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF VERIFY OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
WHENEVER SQLERROR EXIT 1
ALTER SESSION SET NLS_NUMERIC_CHARACTERS='.,';
${sql}
EXIT;
EOF
}

clean() { tr -d ' \r' | sed '/^$/d'; }
# Like clean(), but keeps embedded spaces - event names, ISO timestamps
# and SQL text fragments contain meaningful spaces.
trim()  { tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d'; }
field() { awk -F'|' -v i="$2" '{print $i}' <<< "$1"; }

# rows TAG <<< "$RAW": print the rows of one tag family, prefix stripped
rows() { sed -n "s/^$1|//p"; }

# Floating-point helper for the bash-side derivations. All inputs come
# from Oracle with '.' decimals (forced above), so awk parses them as-is.
calc() { awk "BEGIN{printf \"%.3f\", $1}"; }

# is_num VALUE -> 0 when VALUE is a plain non-negative decimal number
is_num() {
    case "$1" in
        ''|*[!0-9.]*|*.*.*) return 1 ;;
        .) return 1 ;;
    esac
    return 0
}

# fmt_or_na VALUE [SUFFIX] - prints "n/a" for missing values
fmt_or_na() {
    if is_num "$1"; then
        printf '%s%s' "$1" "${2:-}"
    else
        printf 'n/a'
    fi
}

# qblock TAG... - fenced SQL block(s) carrying the exact text of the query
# that produced the table above. A fenced block in the Markdown; the HTML
# renderer turns it into a collapsed <details>.
qblock() {
    local _t _sql
    for _t in "$@"; do
        _sql=$(recorded_sql "$_t")
        [[ -n "$_sql" ]] || continue
        printf '```sql\n%s\n```\n\n' "$_sql"
    done
}

run_dgmgrl_cmd() {
    local cmd="$1"
    "$ORACLE_HOME/bin/dgmgrl" -silent / <<EOF 2>&1
${cmd}
EXIT;
EOF
}

# First value after '=' in broker "Property = 'value'" output
parse_broker_property() {
    awk -F= '
        /[A-Za-z0-9_]+[[:space:]]*=/ {
            value=$2
            gsub(/^[[:space:]]*'\''?/, "", value)
            gsub(/'\''?[[:space:]]*$/, "", value)
            if (value != "") {
                print value
                exit
            }
        }
    '
}

# ============================================================
# Section degradation tracking
# ============================================================
# The connectivity/role check below is the only thing allowed to kill
# this script. Every collector afterwards is best-effort: a failed query
# empties its variable (required under `set -e` - an unwrapped failing
# command substitution aborts the script), the affected report section
# says so, and the run continues.

DEGRADED_NOTES=()
degraded() {
    warn "Collection failed: $* (section degraded in report)"
    DEGRADED_NOTES+=("$1")
}

# ============================================================
# Connectivity + role check
# ============================================================

info "Checking connectivity via 'sqlplus / as sysdba'..."
if ! run_sql "-- QTAG:PING
SELECT 'OK' FROM DUAL;" | clean | grep -q '^OK$'; then
    die "Could not connect via 'sqlplus / as sysdba' (ORACLE_SID=${ORACLE_SID})."
fi
info "Connected."

DBINFO_RAW=$(run_sql "-- QTAG:DBINFO
SELECT 'DBINFO|'||d.DB_UNIQUE_NAME
  ||'|'||d.NAME
  ||'|'||d.DATABASE_ROLE
  ||'|'||d.PROTECTION_MODE
  ||'|'||d.OPEN_MODE
  ||'|'||i.HOST_NAME
  ||'|'||i.VERSION
  ||'|'||i.INSTANCE_NAME
  ||'|'||i.INSTANCE_NUMBER
  ||'|'||TO_CHAR(i.STARTUP_TIME,'YYYY-MM-DD HH24:MI:SS')
  ||'|'||ROUND((SYSDATE - CAST(i.STARTUP_TIME AS DATE))*86400)
  ||'|'||d.DBID
  ||'|'||(SELECT VALUE FROM V\$PARAMETER WHERE NAME='dg_broker_start')
FROM V\$DATABASE d, V\$INSTANCE i;" | trim | grep '^DBINFO|' | head -1) \
    || die "Could not read V\$DATABASE / V\$INSTANCE."

DB_UNIQUE_NAME=$(field  "$DBINFO_RAW" 2)
DB_NAME=$(field         "$DBINFO_RAW" 3)
DB_ROLE=$(field         "$DBINFO_RAW" 4)
PROTECTION_MODE=$(field "$DBINFO_RAW" 5)
OPEN_MODE=$(field       "$DBINFO_RAW" 6)
HOST_NAME=$(field       "$DBINFO_RAW" 7)
DB_VERSION=$(field      "$DBINFO_RAW" 8)
INSTANCE_NAME=$(field   "$DBINFO_RAW" 9)
INSTANCE_NUMBER=$(field "$DBINFO_RAW" 10)
STARTUP_TIME=$(field    "$DBINFO_RAW" 11)
UPTIME_SECONDS=$(field  "$DBINFO_RAW" 12)
DBID=$(field            "$DBINFO_RAW" 13)
DG_BROKER_START=$(field "$DBINFO_RAW" 14)

[[ "$DB_ROLE" == "PRIMARY" ]] \
    || die "Database role is '${DB_ROLE}' - this analysis measures the redo-shipping side; run it on the PRIMARY."
case "$OPEN_MODE" in
    "READ WRITE"*) : ;;
    *) warn "Open mode is '${OPEN_MODE}' (expected READ WRITE); some statistics may be incomplete." ;;
esac

info "Primary confirmed: ${DB_UNIQUE_NAME} (${INSTANCE_NAME}@${HOST_NAME}, ${DB_VERSION}, ${PROTECTION_MODE})."

# ============================================================
# Collect: synchronous transport configuration
# ============================================================

info "Collecting remote archive destination configuration..."
_out=$(run_sql "-- QTAG:DESTS
SELECT 'DEST|'||DEST_ID
  ||'|'||NVL(DB_UNIQUE_NAME,'-')
  ||'|'||TRANSMIT_MODE
  ||'|'||NVL(AFFIRM,'-')
  ||'|'||NVL(TO_CHAR(NET_TIMEOUT),'-')
  ||'|'||STATUS
FROM V\$ARCHIVE_DEST
WHERE STATUS <> 'INACTIVE'
  AND TARGET IN ('STANDBY','REMOTE')
ORDER BY DEST_ID;") \
    || { _out=""; degraded "remote destinations (V\$ARCHIVE_DEST)"; }
DESTS_RAW=$(printf '%s\n' "$_out" | trim | grep '^DEST[|]' || true)

# Classify destinations. TRANSMIT_MODE reflects only the SYNC/ASYNC
# attribute: SYNCHRONOUS and PARALLELSYNC are both synchronous
# transport, ASYNCHRONOUS is not. AFFIRM vs NOAFFIRM (FASTSYNC) is NOT
# encoded in TRANSMIT_MODE - only the separate AFFIRM column carries it.
SYNC_DEST_COUNT=0
SYNC_TARGETS=""
SYNC_AFFIRM_ANY="NO"
if [[ -n "$DESTS_RAW" ]]; then
    while IFS='|' read -r _tag _id _dbun _tmode _affirm _nt _status; do
        case "$_tmode" in
            SYNCHRONOUS|PARALLELSYNC)
                SYNC_DEST_COUNT=$((SYNC_DEST_COUNT + 1))
                SYNC_TARGETS="${SYNC_TARGETS:+${SYNC_TARGETS}, }${_dbun}"
                [[ "$_affirm" == "YES" ]] && SYNC_AFFIRM_ANY="YES"
                ;;
        esac
    done <<< "$DESTS_RAW"
fi

if [[ "$SYNC_DEST_COUNT" -eq 0 ]]; then
    warn "No synchronous (SYNC/FASTSYNC) destination is active - the report will show current commit latency without a transport overhead estimate."
else
    info "Synchronous destination(s): ${SYNC_TARGETS} (AFFIRM used: ${SYNC_AFFIRM_ANY})."
fi

# Broker LogXptMode per synchronous target (best-effort corroboration)
BROKER_XPT=""
if [[ "$DG_BROKER_START" == "TRUE" && -n "$DESTS_RAW" ]]; then
    info "Broker is running; reading LogXptMode per destination..."
    while IFS='|' read -r _tag _id _dbun _tmode _affirm _nt _status; do
        [[ "$_dbun" != "-" ]] || continue
        _xpt=$(run_dgmgrl_cmd "SHOW DATABASE '${_dbun}' 'LogXptMode';" | parse_broker_property || true)
        [[ -n "$_xpt" ]] && BROKER_XPT="${BROKER_XPT}${_dbun}=${_xpt}; "
    done <<< "$DESTS_RAW"
fi

# ============================================================
# Collect: since-startup wait events and statistics (Layer 1)
# ============================================================

info "Collecting since-startup wait events and redo statistics..."
_out=$(run_sql "-- QTAG:EVENTS
SELECT 'EVT|'||EVENT
  ||'|'||TOTAL_WAITS
  ||'|'||ROUND(TIME_WAITED_MICRO/1000,1)
  ||'|'||NVL(TO_CHAR(ROUND(TIME_WAITED_MICRO/NULLIF(TOTAL_WAITS,0)/1000,3)),'-')
FROM V\$SYSTEM_EVENT
WHERE EVENT IN ('log file sync','log file parallel write','SYNC Remote Write',
                'Redo Transport MISC','LNS wait on SENDREQ',
                'Redo Write Broadcast Ack','LGWR-LNS wait on channel');
SELECT 'STAT|'||NAME||'|'||VALUE
FROM V\$SYSSTAT
WHERE NAME IN ('user commits','redo writes','redo synch writes','redo size',
               'redo synch time (usec)','redo synch time overhead (usec)');
SELECT 'STAT|DB time (ms)|'||ROUND(VALUE/1000)
FROM V\$SYS_TIME_MODEL WHERE STAT_NAME='DB time';") \
    || { _out=""; degraded "wait events / sysstats (V\$SYSTEM_EVENT, V\$SYSSTAT)"; }
EVENTS_RAW=$(printf '%s\n' "$_out" | trim | grep -E '^(EVT|STAT)[|]' || true)

# evt_val EVENT FIELD  (FIELD: 2=waits, 3=total ms, 4=avg ms)
# Both helpers must succeed even when the row is absent (empty output),
# or the `set -e` + pipefail combination would abort the script on a
# degraded EVENTS collection.
evt_val() {
    printf '%s\n' "$EVENTS_RAW" | grep "^EVT|$1|" | head -1 | awk -F'|' -v i="$2" '{print $(i+1)}' || true
}
stat_val() {
    printf '%s\n' "$EVENTS_RAW" | grep "^STAT|$1|" | head -1 | awk -F'|' '{print $3}' || true
}

LFS_CNT=$(evt_val  'log file sync' 2)
LFS_TOT_MS=$(evt_val  'log file sync' 3)
LFS_AVG=$(evt_val  'log file sync' 4)
LFPW_CNT=$(evt_val 'log file parallel write' 2)
LFPW_AVG=$(evt_val 'log file parallel write' 4)
SRW_CNT=$(evt_val  'SYNC Remote Write' 2)
SRW_AVG=$(evt_val  'SYNC Remote Write' 4)

USER_COMMITS=$(stat_val 'user commits')
REDO_WRITES=$(stat_val  'redo writes')
REDO_SYNCH_WRITES=$(stat_val 'redo synch writes')
REDO_SIZE=$(stat_val    'redo size')
REDO_SYNCH_US=$(stat_val 'redo synch time (usec)')
REDO_OVERHEAD_US=$(stat_val 'redo synch time overhead (usec)')
DBTIME_STARTUP_MS=$(stat_val 'DB time (ms)')

# ============================================================
# Collect: histogram convolution E[max(L,R)] (Layer 2)
# ============================================================
# V$EVENT_HISTOGRAM_MICRO buckets are [upper/2, upper) - WAIT_TIME_MICRO
# is a documented EXCLUSIVE upper bound ("waits of duration < num"); the
# geometric midpoint of such a bucket is upper/sqrt(2), which is what
# both the means and the E[max] cross-join below use. Independence of L
# and R is assumed (stated in the report).

EMAX_RAW=""
if [[ "$SYNC_DEST_COUNT" -gt 0 ]]; then
    info "Computing E[max(local write, remote ack)] from V\$EVENT_HISTOGRAM_MICRO..."
    EMAX_RAW=$(run_sql "-- QTAG:EMAX
WITH l AS (
  SELECT WAIT_TIME_MICRO/SQRT(2) MID, WAIT_COUNT CNT
  FROM V\$EVENT_HISTOGRAM_MICRO
  WHERE EVENT='log file parallel write' AND WAIT_COUNT > 0
),
r AS (
  SELECT WAIT_TIME_MICRO/SQRT(2) MID, WAIT_COUNT CNT
  FROM V\$EVENT_HISTOGRAM_MICRO
  WHERE EVENT='SYNC Remote Write' AND WAIT_COUNT > 0
),
la AS (SELECT SUM(CNT) N, SUM(CNT*MID)/NULLIF(SUM(CNT),0) MEAN FROM l),
ra AS (SELECT SUM(CNT) N, SUM(CNT*MID)/NULLIF(SUM(CNT),0) MEAN FROM r),
mx AS (
  SELECT SUM(l.CNT*r.CNT*GREATEST(l.MID,r.MID)) S, SUM(l.CNT*r.CNT) W
  FROM l, r
)
SELECT 'EMAX|'||NVL(TO_CHAR(ROUND(mx.S/NULLIF(mx.W,0)/1000,4)),'-')
  ||'|'||NVL(TO_CHAR(ROUND(la.MEAN/1000,4)),'-')
  ||'|'||NVL(TO_CHAR(ROUND(ra.MEAN/1000,4)),'-')
  ||'|'||NVL(la.N,0)
  ||'|'||NVL(ra.N,0)
FROM la, ra, mx;" | trim | grep '^EMAX|' | head -1) \
        || { EMAX_RAW=""; degraded "E[max] histogram model (V\$EVENT_HISTOGRAM_MICRO)"; }
fi

EMAX_MS=$(field "$EMAX_RAW" 2)
EL_MS=$(field   "$EMAX_RAW" 3)
ER_MS=$(field   "$EMAX_RAW" 4)
HIST_L_N=$(field "$EMAX_RAW" 5)
HIST_R_N=$(field "$EMAX_RAW" 6)

info "Collecting latency percentiles from V\$EVENT_HISTOGRAM_MICRO..."
_out=$(run_sql "-- QTAG:HISTPCT
WITH h AS (
  SELECT EVENT, WAIT_TIME_MICRO UB, WAIT_COUNT CNT,
         SUM(WAIT_COUNT) OVER (PARTITION BY EVENT ORDER BY WAIT_TIME_MICRO) CUM,
         SUM(WAIT_COUNT) OVER (PARTITION BY EVENT) TOT
  FROM V\$EVENT_HISTOGRAM_MICRO
  WHERE EVENT IN ('log file sync','log file parallel write','SYNC Remote Write')
)
SELECT 'PCT|'||EVENT
  ||'|'||NVL(TO_CHAR(MIN(CASE WHEN CUM >= 0.50*TOT THEN UB END)),'-')
  ||'|'||NVL(TO_CHAR(MIN(CASE WHEN CUM >= 0.90*TOT THEN UB END)),'-')
  ||'|'||NVL(TO_CHAR(MIN(CASE WHEN CUM >= 0.99*TOT THEN UB END)),'-')
  ||'|'||NVL(TO_CHAR(MAX(CASE WHEN CNT > 0 THEN UB END)),'-')
  ||'|'||NVL(MAX(TOT),0)
FROM h
WHERE TOT > 0
GROUP BY EVENT;") \
    || { _out=""; degraded "latency percentiles (V\$EVENT_HISTOGRAM_MICRO)"; }
PCT_RAW=$(printf '%s\n' "$_out" | trim | grep '^PCT[|]' || true)

info "Collecting per-destination SYNC response histogram..."
_out=$(run_sql "-- QTAG:RESPHIST
SELECT 'RESP|'||DEST_ID||'|'||DURATION*1000||'|'||FREQUENCY||'|'||NVL(TIME,'-')
FROM V\$REDO_DEST_RESP_HISTOGRAM
WHERE FREQUENCY > 0
ORDER BY DEST_ID, DURATION;") \
    || { _out=""; degraded "SYNC response histogram (V\$REDO_DEST_RESP_HISTOGRAM)"; }
RESP_RAW=$(printf '%s\n' "$_out" | trim | grep '^RESP[|]' || true)

# ============================================================
# Collect: AWR window aggregates + trend (Layer 3, Diagnostics Pack)
# ============================================================

AWR_NOTE=""
SNAPWIN_RAW=""
TREND_RAW=""
AWRAGG_RAW=""
CURHPCT_RAW=""
BASEWIN_RAW=""
BASEAGG_RAW=""
BASEHPCT_RAW=""
AUTOBASE_NOTE=""
AB_TRANS_SNAP=""
AB_TRANS_TIME=""
AB_N_SYNC=""
AB_N_NOSYNC=""
AB_N_OTHER=""

# collect_awr_agg MIN_SNAP MAX_SNAP -> XAGG row on stdout
collect_awr_agg() {
    local mins="$1" maxs="$2"
    run_sql "-- QTAG:AWRAGG
WITH ev AS (
  SELECT EVENT_NAME,
         TOTAL_WAITS - LAG(TOTAL_WAITS)
             OVER (PARTITION BY EVENT_NAME ORDER BY SNAP_ID) DW,
         TIME_WAITED_MICRO - LAG(TIME_WAITED_MICRO)
             OVER (PARTITION BY EVENT_NAME ORDER BY SNAP_ID) DT
  FROM DBA_HIST_SYSTEM_EVENT
  WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
    AND SNAP_ID BETWEEN ${mins} AND ${maxs}
    AND EVENT_NAME IN ('log file sync','log file parallel write','SYNC Remote Write')
),
ea AS (
  SELECT
    SUM(CASE WHEN EVENT_NAME='log file sync'           AND DW>=0 THEN DW END) LFS_CNT,
    SUM(CASE WHEN EVENT_NAME='log file sync'           AND DW>=0 AND DT>=0 THEN DT END) LFS_US,
    SUM(CASE WHEN EVENT_NAME='log file parallel write' AND DW>=0 THEN DW END) LFPW_CNT,
    SUM(CASE WHEN EVENT_NAME='log file parallel write' AND DW>=0 AND DT>=0 THEN DT END) LFPW_US,
    SUM(CASE WHEN EVENT_NAME='SYNC Remote Write'       AND DW>=0 THEN DW END) SRW_CNT,
    SUM(CASE WHEN EVENT_NAME='SYNC Remote Write'       AND DW>=0 AND DT>=0 THEN DT END) SRW_US
  FROM ev
),
cm AS (
  SELECT SUM(CASE WHEN DC>=0 THEN DC END) COMMITS FROM (
    SELECT VALUE - LAG(VALUE) OVER (ORDER BY SNAP_ID) DC
    FROM DBA_HIST_SYSSTAT
    WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
      AND STAT_NAME='user commits'
      AND SNAP_ID BETWEEN ${mins} AND ${maxs})
),
tm AS (
  SELECT SUM(CASE WHEN DV>=0 THEN DV END)/1000 DBTIME_MS FROM (
    SELECT VALUE - LAG(VALUE) OVER (ORDER BY SNAP_ID) DV
    FROM DBA_HIST_SYS_TIME_MODEL
    WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
      AND STAT_NAME='DB time'
      AND SNAP_ID BETWEEN ${mins} AND ${maxs})
),
w AS (
  SELECT (MAX(CAST(END_INTERVAL_TIME AS DATE))
         -MIN(CAST(END_INTERVAL_TIME AS DATE)))*86400 SECS
  FROM DBA_HIST_SNAPSHOT
  WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
    AND SNAP_ID BETWEEN ${mins} AND ${maxs}
)
SELECT 'XAGG|'||NVL(TO_CHAR(ROUND(w.SECS)),'-')
  ||'|'||NVL(TO_CHAR(ea.LFS_CNT),'-')
  ||'|'||NVL(TO_CHAR(ROUND(ea.LFS_US/NULLIF(ea.LFS_CNT,0)/1000,3)),'-')
  ||'|'||NVL(TO_CHAR(ROUND(ea.LFPW_US/NULLIF(ea.LFPW_CNT,0)/1000,3)),'-')
  ||'|'||NVL(TO_CHAR(ea.SRW_CNT),'-')
  ||'|'||NVL(TO_CHAR(ROUND(ea.SRW_US/NULLIF(ea.SRW_CNT,0)/1000,3)),'-')
  ||'|'||NVL(TO_CHAR(cm.COMMITS),'-')
  ||'|'||NVL(TO_CHAR(ROUND(tm.DBTIME_MS)),'-')
FROM ea, cm, tm, w;" | trim | grep '^XAGG|' | head -1
}

# collect_hist_pct MIN_SNAP MAX_SNAP -> HPCT row (log file sync ms-bucket
# percentiles across the window) on stdout
collect_hist_pct() {
    local mins="$1" maxs="$2"
    run_sql "-- QTAG:BASEHIST
WITH d AS (
  SELECT WAIT_TIME_MILLI UB,
         WAIT_COUNT - LAG(WAIT_COUNT)
             OVER (PARTITION BY WAIT_TIME_MILLI ORDER BY SNAP_ID) DC
  FROM DBA_HIST_EVENT_HISTOGRAM
  WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
    AND EVENT_NAME='log file sync'
    AND SNAP_ID BETWEEN ${mins} AND ${maxs}
),
h AS (
  SELECT UB, SUM(CASE WHEN DC>0 THEN DC END) CNT
  FROM d GROUP BY UB
),
c AS (
  SELECT UB, CNT,
         SUM(CNT) OVER (ORDER BY UB) CUM,
         SUM(CNT) OVER () TOT
  FROM h WHERE CNT > 0
)
SELECT 'HPCT|'||NVL(TO_CHAR(MIN(CASE WHEN CUM >= 0.50*TOT THEN UB END)),'-')
  ||'|'||NVL(TO_CHAR(MIN(CASE WHEN CUM >= 0.90*TOT THEN UB END)),'-')
  ||'|'||NVL(TO_CHAR(MIN(CASE WHEN CUM >= 0.99*TOT THEN UB END)),'-')
  ||'|'||NVL(MAX(TOT),0)
FROM c;" | trim | grep '^HPCT|' | head -1
}

if [[ "$NO_PACK" == "YES" ]]; then
    AWR_NOTE="skipped (--no-pack: Diagnostics Pack views not queried)"
    info "Skipping AWR and ASH sections (--no-pack)."
else
    info "Resolving AWR snapshot window (last ${AWR_DAYS} days)..."
    SNAPWIN_RAW=$(run_sql "-- QTAG:AWRSNAP
SELECT 'SNAPWIN|'||NVL(TO_CHAR(MIN(SNAP_ID)),'-')
  ||'|'||NVL(TO_CHAR(MAX(SNAP_ID)),'-')
  ||'|'||COUNT(*)
FROM DBA_HIST_SNAPSHOT
WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
  AND END_INTERVAL_TIME >= SYSDATE - ${AWR_DAYS};" | trim | grep '^SNAPWIN|' | head -1) \
        || { SNAPWIN_RAW=""; degraded "AWR snapshot window (DBA_HIST_SNAPSHOT)"; }

    SNAP_MIN=$(field "$SNAPWIN_RAW" 2)
    SNAP_MAX=$(field "$SNAPWIN_RAW" 3)
    SNAP_CNT=$(field "$SNAPWIN_RAW" 4)

    if ! is_uint "$SNAP_CNT" || [[ "${SNAP_CNT:-0}" -lt 2 ]]; then
        AWR_NOTE="skipped (fewer than 2 AWR snapshots in the last ${AWR_DAYS} days)"
        warn "Not enough AWR snapshots in the window; skipping AWR trend/aggregates."
    else
        info "AWR window: snapshots ${SNAP_MIN}-${SNAP_MAX} (${SNAP_CNT} snaps)."
        AWRAGG_RAW=$(collect_awr_agg "$SNAP_MIN" "$SNAP_MAX") \
            || { AWRAGG_RAW=""; degraded "AWR window aggregates (DBA_HIST_SYSTEM_EVENT)"; }
        CURHPCT_RAW=$(collect_hist_pct "$SNAP_MIN" "$SNAP_MAX") \
            || { CURHPCT_RAW=""; degraded "AWR log file sync histogram (DBA_HIST_EVENT_HISTOGRAM)"; }

        info "Collecting AWR per-snapshot trend..."
        _out=$(run_sql "-- QTAG:TREND
WITH sn AS (
  SELECT SNAP_ID, CAST(END_INTERVAL_TIME AS DATE) ET
  FROM DBA_HIST_SNAPSHOT
  WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
    AND END_INTERVAL_TIME >= SYSDATE - (${AWR_DAYS} + 1)
),
ev AS (
  SELECT SNAP_ID, EVENT_NAME,
         TOTAL_WAITS - LAG(TOTAL_WAITS)
             OVER (PARTITION BY EVENT_NAME ORDER BY SNAP_ID) DW,
         TIME_WAITED_MICRO - LAG(TIME_WAITED_MICRO)
             OVER (PARTITION BY EVENT_NAME ORDER BY SNAP_ID) DT
  FROM DBA_HIST_SYSTEM_EVENT
  WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
    AND EVENT_NAME IN ('log file sync','log file parallel write','SYNC Remote Write')
    AND SNAP_ID IN (SELECT SNAP_ID FROM sn)
),
cm AS (
  SELECT SNAP_ID, VALUE - LAG(VALUE) OVER (ORDER BY SNAP_ID) DC
  FROM DBA_HIST_SYSSTAT
  WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
    AND STAT_NAME='user commits'
    AND SNAP_ID IN (SELECT SNAP_ID FROM sn)
),
tm AS (
  SELECT SNAP_ID, VALUE - LAG(VALUE) OVER (ORDER BY SNAP_ID) DV
  FROM DBA_HIST_SYS_TIME_MODEL
  WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
    AND STAT_NAME='DB time'
    AND SNAP_ID IN (SELECT SNAP_ID FROM sn)
),
el AS (
  SELECT SNAP_ID, ET, (ET - LAG(ET) OVER (ORDER BY SNAP_ID))*86400 SECS
  FROM sn
),
p AS (
  SELECT el.SNAP_ID, el.ET, el.SECS,
    MAX(CASE WHEN ev.EVENT_NAME='log file sync'           AND ev.DW>=0 THEN ev.DW END) LFS_CNT,
    MAX(CASE WHEN ev.EVENT_NAME='log file sync'           AND ev.DW>0  THEN ev.DT/ev.DW/1000 END) LFS_MS,
    MAX(CASE WHEN ev.EVENT_NAME='log file parallel write' AND ev.DW>0  THEN ev.DT/ev.DW/1000 END) LFPW_MS,
    MAX(CASE WHEN ev.EVENT_NAME='SYNC Remote Write'       AND ev.DW>0  THEN ev.DT/ev.DW/1000 END) SRW_MS,
    MAX(cm.DC) COMMITS,
    MAX(tm.DV)/1000 DBTIME_MS
  FROM el
  LEFT JOIN ev ON ev.SNAP_ID = el.SNAP_ID
  LEFT JOIN cm ON cm.SNAP_ID = el.SNAP_ID
  LEFT JOIN tm ON tm.SNAP_ID = el.SNAP_ID
  GROUP BY el.SNAP_ID, el.ET, el.SECS
)
SELECT 'TREND|'||SNAP_ID
  ||'|'||TO_CHAR(ET,'YYYY-MM-DD HH24:MI')
  ||'|'||NVL(TO_CHAR(LFS_CNT),'-')
  ||'|'||NVL(TO_CHAR(ROUND(LFS_MS,3)),'-')
  ||'|'||NVL(TO_CHAR(ROUND(LFPW_MS,3)),'-')
  ||'|'||NVL(TO_CHAR(ROUND(SRW_MS,3)),'-')
  ||'|'||CASE WHEN COMMITS >= 0 AND SECS > 0
              THEN TO_CHAR(ROUND(COMMITS/SECS,1)) ELSE '-' END
  ||'|'||CASE WHEN DBTIME_MS >= 0
              THEN TO_CHAR(ROUND(DBTIME_MS)) ELSE '-' END
  ||'|'||CASE WHEN SRW_MS IS NOT NULL AND LFPW_MS IS NOT NULL AND LFS_CNT > 0
              THEN TO_CHAR(ROUND(GREATEST(0,SRW_MS-LFPW_MS)*LFS_CNT,1)) ELSE '-' END
FROM p
WHERE ET >= SYSDATE - ${AWR_DAYS}
ORDER BY SNAP_ID;") \
            || { _out=""; degraded "AWR per-snapshot trend (DBA_HIST_SYSTEM_EVENT)"; }
        TREND_RAW=$(printf '%s\n' "$_out" | trim | grep '^TREND[|]' || true)
    fi

    # ---- baseline window ----
    if [[ -n "$BASELINE_MODE" ]]; then
        info "Resolving baseline window (${BASELINE_BEGIN} .. ${BASELINE_END})..."
        if [[ "$BASELINE_MODE" == "snap" ]]; then
            BASEWIN_RAW=$(run_sql "-- QTAG:BASEWIN
SELECT 'BASEWIN|'||NVL(TO_CHAR(MIN(SNAP_ID)),'-')
  ||'|'||NVL(TO_CHAR(MAX(SNAP_ID)),'-')
  ||'|'||COUNT(*)
  ||'|'||NVL(TO_CHAR(MIN(END_INTERVAL_TIME),'YYYY-MM-DD HH24:MI'),'-')
  ||'|'||NVL(TO_CHAR(MAX(END_INTERVAL_TIME),'YYYY-MM-DD HH24:MI'),'-')
FROM DBA_HIST_SNAPSHOT
WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
  AND SNAP_ID BETWEEN ${BASELINE_BEGIN} AND ${BASELINE_END};" | trim | grep '^BASEWIN|' | head -1) \
                || { BASEWIN_RAW=""; degraded "baseline snapshot window (DBA_HIST_SNAPSHOT)"; }
        else
            BASEWIN_RAW=$(run_sql "-- QTAG:BASEWIN
SELECT 'BASEWIN|'||NVL(TO_CHAR(MIN(SNAP_ID)),'-')
  ||'|'||NVL(TO_CHAR(MAX(SNAP_ID)),'-')
  ||'|'||COUNT(*)
  ||'|'||NVL(TO_CHAR(MIN(END_INTERVAL_TIME),'YYYY-MM-DD HH24:MI'),'-')
  ||'|'||NVL(TO_CHAR(MAX(END_INTERVAL_TIME),'YYYY-MM-DD HH24:MI'),'-')
FROM DBA_HIST_SNAPSHOT
WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
  AND END_INTERVAL_TIME >= TO_DATE('${BASELINE_BEGIN}','YYYY-MM-DD HH24:MI')
  AND END_INTERVAL_TIME <= TO_DATE('${BASELINE_END}','YYYY-MM-DD HH24:MI') + CASE WHEN LENGTH('${BASELINE_END}') = 10 THEN 1 ELSE 0 END;" | trim | grep '^BASEWIN|' | head -1) \
                || { BASEWIN_RAW=""; degraded "baseline snapshot window (DBA_HIST_SNAPSHOT)"; }
        fi
    elif [[ "$AUTO_BASELINE" == "YES" ]]; then
        # ---- auto-detected baseline window ----
        # Oracle does not historize the transport mode, but synchronous
        # transport leaves a behavioral fingerprint: while it is active,
        # LGWR records a 'SYNC Remote Write' wait for essentially every
        # redo write, so the per-snapshot ratio of those waits to redo
        # writes is ~1 under sync transport and ~0 without it. Classify
        # every retained snapshot (not just the --days window - the
        # transition usually predates it) and take the most recent run
        # of consecutive no-sync snapshots as the baseline.
        info "Scanning AWR history for the pre-SYNC baseline window (--auto-baseline)..."
        _out=$(run_sql "-- QTAG:AUTOBASE
WITH sn AS (
  SELECT SNAP_ID, CAST(END_INTERVAL_TIME AS DATE) ET
  FROM DBA_HIST_SNAPSHOT
  WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
),
srw AS (
  SELECT SNAP_ID,
         TOTAL_WAITS - LAG(TOTAL_WAITS) OVER (ORDER BY SNAP_ID) DW
  FROM DBA_HIST_SYSTEM_EVENT
  WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
    AND EVENT_NAME='SYNC Remote Write'
),
rw AS (
  SELECT SNAP_ID,
         VALUE - LAG(VALUE) OVER (ORDER BY SNAP_ID) DV
  FROM DBA_HIST_SYSSTAT
  WHERE DBID=${DBID} AND INSTANCE_NUMBER=${INSTANCE_NUMBER}
    AND STAT_NAME='redo writes'
)
SELECT 'CLS|'||sn.SNAP_ID
  ||'|'||TO_CHAR(sn.ET,'YYYY-MM-DD HH24:MI')
  ||'|'||NVL(srw.DW,0)
  ||'|'||NVL(rw.DV,0)
  ||'|'||CASE
       WHEN rw.DV IS NULL OR rw.DV < ${DG_SI_MIN_WRITES} OR NVL(srw.DW,0) < 0 THEN 'IDLE'
       WHEN NVL(srw.DW,0)/rw.DV >= ${DG_SI_SYNC_RATIO}  THEN 'SYNC'
       WHEN NVL(srw.DW,0)/rw.DV <= ${DG_SI_NOSYNC_RATIO} THEN 'NOSYNC'
       ELSE 'MIXED'
     END
FROM sn
LEFT JOIN srw ON srw.SNAP_ID = sn.SNAP_ID
LEFT JOIN rw  ON rw.SNAP_ID  = sn.SNAP_ID
ORDER BY sn.SNAP_ID;") \
            || { _out=""; degraded "auto-baseline classification (DBA_HIST_SYSTEM_EVENT)"; }
        AUTOBASE_RAW=$(printf '%s\n' "$_out" | trim | grep '^CLS[|]' || true)

        if [[ -z "$AUTOBASE_RAW" ]]; then
            AUTOBASE_NOTE="snapshot classification unavailable (query failed or no AWR history)"
            warn "Auto-baseline: classification query returned no data; skipping the comparison."
        else
            # Walk the classified snapshots in snap order: locate the last
            # SYNC snapshot (end of the current regime), then the most
            # recent run of >= 2 consecutive NOSYNC snapshots before it
            # (IDLE/MIXED snaps break a run - gaps are never bridged), and
            # the first SYNC snapshot after that run (the transition).
            AB_LINE=$(printf '%s\n' "$AUTOBASE_RAW" | rows CLS | awk -F'|' '
                { n = n + 1; snap[n] = $1; tm[n] = $2; cls[n] = $5
                  if ($5 == "SYNC") ns = ns + 1
                  else if ($5 == "NOSYNC") nn = nn + 1
                  else no = no + 1 }
                END {
                  lastsync = 0
                  for (i = 1; i <= n; i++) if (cls[i] == "SYNC") lastsync = i
                  if (lastsync == 0) {
                    printf "NOSYNC||||||||%d|%d|%d\n", ns, nn, no; exit
                  }
                  runlen = 0; runstart = 0; bs = 0; be = 0
                  for (i = 1; i < lastsync; i++) {
                    if (cls[i] == "NOSYNC") {
                      if (runlen == 0) runstart = i
                      runlen = runlen + 1
                    } else {
                      if (runlen >= 2) { bs = runstart; be = i - 1 }
                      runlen = 0
                    }
                  }
                  if (runlen >= 2) { bs = runstart; be = lastsync - 1 }
                  if (bs == 0) {
                    printf "NOBASE||||||||%d|%d|%d\n", ns, nn, no; exit
                  }
                  ti = 0
                  for (j = be + 1; j <= n; j++) if (cls[j] == "SYNC") { ti = j; break }
                  printf "OK|%s|%s|%d|%s|%s|%s|%s|%d|%d|%d\n",
                    snap[bs], snap[be], be - bs + 1, tm[bs], tm[be],
                    snap[ti], tm[ti], ns, nn, no
                }')
            AB_STATUS=$(field   "$AB_LINE" 1)
            AB_N_SYNC=$(field   "$AB_LINE" 9)
            AB_N_NOSYNC=$(field "$AB_LINE" 10)
            AB_N_OTHER=$(field  "$AB_LINE" 11)
            case "$AB_STATUS" in
                OK)
                    AB_TRANS_SNAP=$(field "$AB_LINE" 7)
                    AB_TRANS_TIME=$(field "$AB_LINE" 8)
                    BASEWIN_RAW="BASEWIN|$(field "$AB_LINE" 2)|$(field "$AB_LINE" 3)|$(field "$AB_LINE" 4)|$(field "$AB_LINE" 5)|$(field "$AB_LINE" 6)"
                    ;;
                NOSYNC)
                    AUTOBASE_NOTE="no synchronous-transport snapshots in AWR retention - there is no SYNC period to compare against"
                    warn "Auto-baseline: no synchronous-transport snapshots in AWR retention; skipping the comparison."
                    ;;
                *)
                    AUTOBASE_NOTE="SYNC transport predates AWR retention (no run of 2+ consecutive no-sync snapshots before the SYNC period); no baseline found"
                    warn "Auto-baseline: SYNC transport predates AWR retention; no baseline found."
                    ;;
            esac
        fi
    fi

    # ---- shared baseline collection (manual and auto converge here) ----
    if [[ -n "$BASELINE_MODE" || ( "$AUTO_BASELINE" == "YES" && -n "$BASEWIN_RAW" ) ]]; then
        BASE_MIN=$(field "$BASEWIN_RAW" 2)
        BASE_MAX=$(field "$BASEWIN_RAW" 3)
        BASE_CNT=$(field "$BASEWIN_RAW" 4)
        if ! is_uint "$BASE_CNT" || [[ "${BASE_CNT:-0}" -lt 2 ]]; then
            warn "Baseline window contains fewer than 2 AWR snapshots; skipping the before/after comparison."
        else
            info "Baseline window: snapshots ${BASE_MIN}-${BASE_MAX} (${BASE_CNT} snaps)."
            BASEAGG_RAW=$(collect_awr_agg "$BASE_MIN" "$BASE_MAX") \
                || { BASEAGG_RAW=""; degraded "baseline aggregates (DBA_HIST_SYSTEM_EVENT)"; }
            BASEHPCT_RAW=$(collect_hist_pct "$BASE_MIN" "$BASE_MAX") \
                || { BASEHPCT_RAW=""; degraded "baseline log file sync histogram (DBA_HIST_EVENT_HISTOGRAM)"; }
        fi
    fi
fi

# ============================================================
# Collect: ASH attribution (Diagnostics Pack)
# ============================================================

ASH_RAW=""
if [[ "$NO_PACK" == "NO" ]]; then
    info "Collecting ASH attribution (last ${ASH_HOURS}h)..."
    _out=$(run_sql "-- QTAG:ASH
SELECT 'ASHSUM|'||COUNT(*)
  ||'|'||NVL(SUM(CASE WHEN EVENT='log file sync' THEN 1 ELSE 0 END),0)
  ||'|'||COUNT(DISTINCT CASE WHEN EVENT='log file sync' THEN SESSION_ID END)
  ||'|'||NVL(TO_CHAR(MIN(SAMPLE_TIME),'YYYY-MM-DD HH24:MI'),'-')
FROM V\$ACTIVE_SESSION_HISTORY
WHERE SESSION_TYPE='FOREGROUND'
  AND SAMPLE_TIME > SYSDATE - ${ASH_HOURS}/24;
SELECT 'ASHSQL|'||SQL_ID||'|'||CNT||'|'||TXT FROM (
  SELECT a.SQL_ID, COUNT(*) CNT,
         NVL((SELECT REPLACE(REPLACE(REPLACE(SUBSTR(s.SQL_TEXT,1,60),'|',' '),CHR(10),' '),CHR(13),' ')
              FROM V\$SQLAREA s WHERE s.SQL_ID = a.SQL_ID),'-') TXT
  FROM V\$ACTIVE_SESSION_HISTORY a
  WHERE a.SESSION_TYPE='FOREGROUND'
    AND a.EVENT='log file sync'
    AND a.SQL_ID IS NOT NULL
    AND a.SAMPLE_TIME > SYSDATE - ${ASH_HOURS}/24
  GROUP BY a.SQL_ID
  ORDER BY COUNT(*) DESC
) WHERE ROWNUM <= 10;
SELECT 'ASHMOD|'||MODULE||'|'||CNT FROM (
  SELECT NVL(REPLACE(a.MODULE,'|',' '),'-') MODULE, COUNT(*) CNT
  FROM V\$ACTIVE_SESSION_HISTORY a
  WHERE a.SESSION_TYPE='FOREGROUND'
    AND a.EVENT='log file sync'
    AND a.SAMPLE_TIME > SYSDATE - ${ASH_HOURS}/24
  GROUP BY NVL(REPLACE(a.MODULE,'|',' '),'-')
  ORDER BY COUNT(*) DESC
) WHERE ROWNUM <= 10;
SELECT 'ASHSVC|'||SVC||'|'||CNT FROM (
  SELECT NVL((SELECT s.NAME FROM V\$SERVICES s
              WHERE s.NAME_HASH = a.SERVICE_HASH AND ROWNUM = 1),'-') SVC,
         COUNT(*) CNT
  FROM V\$ACTIVE_SESSION_HISTORY a
  WHERE a.SESSION_TYPE='FOREGROUND'
    AND a.EVENT='log file sync'
    AND a.SAMPLE_TIME > SYSDATE - ${ASH_HOURS}/24
  GROUP BY a.SERVICE_HASH
  ORDER BY COUNT(*) DESC
) WHERE ROWNUM <= 10;
SELECT 'ASHHR|'||TO_CHAR(SAMPLE_TIME,'MM-DD HH24')
  ||'|'||SUM(CASE WHEN EVENT='log file sync' THEN 1 ELSE 0 END)
  ||'|'||COUNT(*)
FROM V\$ACTIVE_SESSION_HISTORY
WHERE SESSION_TYPE='FOREGROUND'
  AND SAMPLE_TIME > SYSDATE - ${ASH_HOURS}/24
GROUP BY TO_CHAR(SAMPLE_TIME,'MM-DD HH24')
ORDER BY 1;") \
        || { _out=""; degraded "ASH attribution (V\$ACTIVE_SESSION_HISTORY)"; }
    ASH_RAW=$(printf '%s\n' "$_out" | trim | grep -E '^ASH(SUM|SQL|MOD|SVC|HR)[|]' || true)
fi

# ============================================================
# Derive: headline numbers
# ============================================================
# Preference order for workload scaling: the AWR window (representative
# recent history) over since-startup cumulative counters.

info "Deriving headline numbers..."

# Refined estimate: E[max(L,R)] - E[L] from the micro histograms
OVERHEAD_EST=""
if is_num "$EMAX_MS" && is_num "$EL_MS" && is_uint "$HIST_R_N" && [[ "$HIST_R_N" -gt 0 ]]; then
    OVERHEAD_EST=$(calc "$EMAX_MS - $EL_MS")
    # Guard against a tiny negative from bucket-midpoint rounding
    case "$OVERHEAD_EST" in
        -*) OVERHEAD_EST="0.000" ;;
    esac
fi

# Bounds from the plain event averages (window-preferred, else startup)
AGG_ELAPSED=$(field "$AWRAGG_RAW" 2)
AGG_LFS_CNT=$(field "$AWRAGG_RAW" 3)
AGG_LFS_AVG=$(field "$AWRAGG_RAW" 4)
AGG_LFPW_AVG=$(field "$AWRAGG_RAW" 5)
AGG_SRW_CNT=$(field "$AWRAGG_RAW" 6)
AGG_SRW_AVG=$(field "$AWRAGG_RAW" 7)
AGG_COMMITS=$(field "$AWRAGG_RAW" 8)
AGG_DBTIME_MS=$(field "$AWRAGG_RAW" 9)

W_LFS_AVG="$LFS_AVG";   is_num "$AGG_LFS_AVG"  && W_LFS_AVG="$AGG_LFS_AVG"
W_LFPW_AVG="$LFPW_AVG"; is_num "$AGG_LFPW_AVG" && W_LFPW_AVG="$AGG_LFPW_AVG"
W_SRW_AVG="$SRW_AVG";   is_num "$AGG_SRW_AVG"  && W_SRW_AVG="$AGG_SRW_AVG"
W_SOURCE="since instance startup"
is_num "$AGG_LFS_AVG" && W_SOURCE="AWR window (last ${AWR_DAYS} days)"

BOUND_LOW=""
BOUND_HIGH=""
if is_num "$W_SRW_AVG" && is_num "$W_LFPW_AVG"; then
    BOUND_LOW=$(calc "($W_SRW_AVG > $W_LFPW_AVG) ? $W_SRW_AVG - $W_LFPW_AVG : 0")
    BOUND_HIGH="$W_SRW_AVG"
fi

# Workload rates for scaling: lfs waits/hour and totals
RATE_LFS_HR=""
TOTAL_DBTIME_MS=""
TOTAL_LFS_CNT=""
if is_num "$AGG_LFS_CNT" && is_num "$AGG_ELAPSED" && [[ "${AGG_ELAPSED%.*}" -gt 0 ]] 2>/dev/null; then
    RATE_LFS_HR=$(calc "$AGG_LFS_CNT / $AGG_ELAPSED * 3600")
    TOTAL_LFS_CNT="$AGG_LFS_CNT"
    TOTAL_DBTIME_MS="$AGG_DBTIME_MS"
elif is_num "$LFS_CNT" && is_num "$UPTIME_SECONDS" && [[ "${UPTIME_SECONDS%.*}" -gt 0 ]] 2>/dev/null; then
    RATE_LFS_HR=$(calc "$LFS_CNT / $UPTIME_SECONDS * 3600")
    TOTAL_LFS_CNT="$LFS_CNT"
    TOTAL_DBTIME_MS="$DBTIME_STARTUP_MS"
fi

# Scaled impact: prefer the refined estimate, fall back to the lower bound
SCALE_BASIS=""
SCALE_MS=""
if is_num "$OVERHEAD_EST"; then
    SCALE_MS="$OVERHEAD_EST"
    SCALE_BASIS="refined estimate E[max(L,R)] - E[L]"
elif is_num "$BOUND_LOW"; then
    SCALE_MS="$BOUND_LOW"
    SCALE_BASIS="lower bound max(0, avg R - avg L)"
fi

ADDED_MS_PER_HR=""
PCT_DBTIME=""
PCT_LFS=""
if is_num "$SCALE_MS"; then
    if is_num "$RATE_LFS_HR"; then
        ADDED_MS_PER_HR=$(calc "$SCALE_MS * $RATE_LFS_HR")
    fi
    if is_num "$TOTAL_LFS_CNT" && is_num "$TOTAL_DBTIME_MS" && [[ "${TOTAL_DBTIME_MS%.*}" -gt 0 ]] 2>/dev/null; then
        PCT_DBTIME=$(calc "$SCALE_MS * $TOTAL_LFS_CNT / $TOTAL_DBTIME_MS * 100")
    fi
    if is_num "$W_LFS_AVG" && awk "BEGIN{exit !($W_LFS_AVG > 0)}"; then
        PCT_LFS=$(calc "$SCALE_MS / $W_LFS_AVG * 100")
    fi
fi

# Group-commit ratio and redo-synch overhead (context numbers)
GROUP_COMMIT_RATIO=""
if is_num "$USER_COMMITS" && is_num "$REDO_WRITES" && [[ "$REDO_WRITES" -gt 0 ]] 2>/dev/null; then
    GROUP_COMMIT_RATIO=$(calc "$USER_COMMITS / $REDO_WRITES")
fi
SYNCH_OVERHEAD_AVG_MS=""
if is_num "$REDO_OVERHEAD_US" && is_num "$REDO_SYNCH_WRITES" && [[ "$REDO_SYNCH_WRITES" -gt 0 ]] 2>/dev/null; then
    SYNCH_OVERHEAD_AVG_MS=$(calc "$REDO_OVERHEAD_US / $REDO_SYNCH_WRITES / 1000")
fi

# SYNC Remote Write present at all? (sanity for the model)
SRW_MISSING="NO"
if [[ "$SYNC_DEST_COUNT" -gt 0 ]]; then
    if ! is_num "$SRW_CNT" || [[ "${SRW_CNT:-0}" -eq 0 ]] 2>/dev/null; then
        SRW_MISSING="YES"
        warn "A synchronous destination is active but no 'SYNC Remote Write' waits were recorded - the refined estimate is unavailable; showing V\$REDO_DEST_RESP_HISTOGRAM raw data instead."
    fi
fi

# ============================================================
# Report emission
# ============================================================

# us_to_ms VALUE - microsecond bucket bound -> ms string
us_to_ms() {
    if is_num "$1"; then
        calc "$1 / 1000"
    else
        printf 'n/a'
    fi
}

emit_report() {
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    printf '# Synchronous Data Guard Impact Report\n\n'
    printf -- '- **Database:** %s (DB_UNIQUE_NAME `%s`, %s, %s)\n' "$DB_NAME" "$DB_UNIQUE_NAME" "$DB_ROLE" "$PROTECTION_MODE"
    printf -- '- **Instance:** `%s` on %s, Oracle %s, started %s\n' "$INSTANCE_NAME" "$HOST_NAME" "$DB_VERSION" "$STARTUP_TIME"
    printf -- '- **Generated:** %s\n' "$now"
    printf -- '- **Windows:** V$ views since instance startup; AWR last %s day(s); ASH last %s hour(s)\n' "$AWR_DAYS" "$ASH_HOURS"
    if [[ "$NO_PACK" == "YES" ]]; then
        printf -- '- **Scope:** free V$ views only (`--no-pack`); AWR/ASH sections skipped\n'
    else
        printf -- '- **License note:** the AWR and ASH sections query Diagnostics Pack views (license required)\n'
    fi
    printf '\n'

    # ---- 1. configuration ----
    printf '## 1. Synchronous transport configuration\n\n'
    printf '_Source: `V$ARCHIVE_DEST`; LogXptMode from the broker._\n\n'
    if [[ -z "$DESTS_RAW" ]]; then
        printf '_Remote destination data unavailable (V$ARCHIVE_DEST query failed)._\n\n'
    else
        printf '| Dest | Target DB_UNIQUE_NAME | Transmit mode | AFFIRM | NET_TIMEOUT | Status |\n'
        printf '|------|----------------------|---------------|--------|-------------|--------|\n'
        while IFS='|' read -r _tag _id _dbun _tmode _affirm _nt _status; do
            printf '| %s | %s | %s | %s | %s | %s |\n' "$_id" "$_dbun" "$_tmode" "$_affirm" "$_nt" "$_status"
        done <<< "$DESTS_RAW"
        printf '\n'
        if [[ "$SYNC_DEST_COUNT" -eq 0 ]]; then
            printf '> **No synchronous destination is active.** Commit latency currently carries no\n'
            printf '> remote-ack component; the sections below describe local commit behavior only\n'
            printf '> (useful as an ASYNC-side baseline for a later comparison).\n\n'
        else
            printf 'Synchronous transport to: **%s**. ' "$SYNC_TARGETS"
            if [[ "$SYNC_AFFIRM_ANY" == "YES" ]]; then
                printf 'AFFIRM is used: the remote ack (R) includes the standby SRL disk write.\n\n'
            else
                printf 'NOAFFIRM (FASTSYNC): the remote ack (R) is standby in-memory receipt only.\n\n'
            fi
        fi
        if [[ -n "$BROKER_XPT" ]]; then
            printf 'Broker LogXptMode: %s\n\n' "$BROKER_XPT"
        fi
        qblock DESTS
    fi

    # ---- 2. headline ----
    printf '## 2. Headline: estimated cost of synchronous transport\n\n'
    printf '_Source: derived from sections 3 and 4 - no view of its own._\n\n'
    if [[ "$SYNC_DEST_COUNT" -eq 0 ]]; then
        printf '_Not applicable - no synchronous destination is active._\n\n'
    elif [[ "$SRW_MISSING" == "YES" ]]; then
        printf '_Unavailable - no `SYNC Remote Write` waits recorded since startup (see section 4\n'
        printf 'for the raw per-destination response histogram)._\n\n'
    else
        printf '| Measure | Value |\n'
        printf '|---------|-------|\n'
        printf '| Added latency per commit (refined estimate) | **%s** |\n' "$(fmt_or_na "$OVERHEAD_EST" " ms")"
        if is_num "$BOUND_LOW"; then
            printf '| Hard bounds from event averages (%s) | %s .. %s ms |\n' "$W_SOURCE" "$BOUND_LOW" "$BOUND_HIGH"
        fi
        printf '| Estimated added foreground wait | %s |\n' "$(fmt_or_na "$ADDED_MS_PER_HR" " ms per hour")"
        printf '| Share of total DB time | %s |\n' "$(fmt_or_na "$PCT_DBTIME" " %")"
        printf '| Share of log file sync time | %s |\n' "$(fmt_or_na "$PCT_LFS" " %")"
        printf '\n'
        printf 'Reading: an average commit currently waits ~%s on `log file sync` (%s);\n' "$(fmt_or_na "$W_LFS_AVG" " ms")" "$W_SOURCE"
        printf 'without synchronous transport the model puts it at ~%s ms less. The estimate is\n' "$(fmt_or_na "${SCALE_MS:-}")"
        printf 'based on the %s; see section 9 for assumptions.\n\n' "${SCALE_BASIS:-event averages}"
    fi

    # ---- 3. LGWR pipeline ----
    printf '## 3. LGWR pipeline decomposition (since instance startup)\n\n'
    printf '_Source: `V$SYSTEM_EVENT`, `V$SYSSTAT`, `V$SYS_TIME_MODEL`._\n\n'
    if [[ -z "$EVENTS_RAW" ]]; then
        printf '_Wait event data unavailable._\n\n'
    else
        printf '| Wait event | Waits | Total (ms) | Avg (ms) |\n'
        printf '|------------|-------|-----------|----------|\n'
        printf '%s\n' "$EVENTS_RAW" | rows EVT | while IFS='|' read -r _ev _w _t _a; do
            printf '| %s | %s | %s | %s |\n' "$_ev" "$_w" "$_t" "$_a"
        done
        printf '\n'
        printf '| Statistic | Value |\n'
        printf '|-----------|-------|\n'
        printf '%s\n' "$EVENTS_RAW" | rows STAT | while IFS='|' read -r _n _v; do
            printf '| %s | %s |\n' "$_n" "$_v"
        done
        printf '\n'
        printf 'Derived context:\n\n'
        printf -- '- Group-commit ratio (user commits / redo writes): **%s**\n' "$(fmt_or_na "$GROUP_COMMIT_RATIO")"
        printf -- '- Avg `redo synch time overhead` per synch write: **%s** - the scheduling/post\n' "$(fmt_or_na "$SYNCH_OVERHEAD_AVG_MS" " ms")"
        printf '  portion of log file sync that is NOT transport (undocumented statistic,\n'
        printf '  community-established meaning; high values point at CPU starvation, not\n'
        printf '  at Data Guard)\n'
        printf -- '- Uptime: %s s; log file sync waits since startup: %s (avg %s)\n' "$(fmt_or_na "$UPTIME_SECONDS")" "$(fmt_or_na "$LFS_CNT")" "$(fmt_or_na "$LFS_AVG" " ms")"
        printf '\n'
        qblock EVENTS
    fi

    # ---- 4. distributions ----
    printf '## 4. Latency distributions (since instance startup)\n\n'
    printf '_Source: `V$EVENT_HISTOGRAM_MICRO`, `V$REDO_DEST_RESP_HISTOGRAM`._\n\n'
    if [[ -z "$PCT_RAW" ]]; then
        printf '_Histogram data unavailable._\n\n'
    else
        printf 'Percentiles are bucket upper bounds from `V$EVENT_HISTOGRAM_MICRO` ("<= value");\n'
        printf '`max` is the highest non-empty bucket - the slowest wait since startup fell in it.\n\n'
        printf '| Event | p50 (ms) | p90 (ms) | p99 (ms) | max (ms) | Samples |\n'
        printf '|-------|----------|----------|----------|----------|---------|\n'
        printf '%s\n' "$PCT_RAW" | rows PCT | while IFS='|' read -r _ev _p50 _p90 _p99 _max _n; do
            printf '| %s | <= %s | <= %s | <= %s | <= %s | %s |\n' \
                "$_ev" "$(us_to_ms "$_p50")" "$(us_to_ms "$_p90")" "$(us_to_ms "$_p99")" "$(us_to_ms "$_max")" "$_n"
        done
        printf '\n'
        qblock HISTPCT
    fi
    if [[ "$SYNC_DEST_COUNT" -gt 0 && -n "$EMAX_RAW" ]]; then
        printf 'Overlap model (independence assumed, geometric bucket midpoints):\n\n'
        printf -- '- E[local write L] = **%s** (n=%s)\n' "$(fmt_or_na "$EL_MS" " ms")" "$(fmt_or_na "$HIST_L_N")"
        printf -- '- E[remote ack R] = **%s** (n=%s)\n' "$(fmt_or_na "$ER_MS" " ms")" "$(fmt_or_na "$HIST_R_N")"
        printf -- '- E[max(L,R)] = **%s**\n' "$(fmt_or_na "$EMAX_MS" " ms")"
        printf -- '- => estimated overhead per redo write = E[max(L,R)] - E[L] = **%s**\n' "$(fmt_or_na "$OVERHEAD_EST" " ms")"
        printf '\n'
        qblock EMAX
    fi
    if [[ -n "$RESP_RAW" ]]; then
        printf 'Per-destination SYNC response histogram (`V$REDO_DEST_RESP_HISTOGRAM`).\n'
        printf 'The view buckets by whole seconds (shown here in ms, so the finest\n'
        printf 'bucket is 1000 ms and every sub-second response lands in it) - on a fast\n'
        printf 'network this view only surfaces outliers and cannot corroborate a\n'
        printf 'sub-second estimate. `Last at` is the most recent response that landed\n'
        printf 'in the bucket:\n\n'
        printf '| Dest | Duration bucket (ms) | Responses | Last at |\n'
        printf '|------|---------------------|-----------|---------|\n'
        printf '%s\n' "$RESP_RAW" | rows RESP | while IFS='|' read -r _d _dur _f _tm; do
            printf '| %s | %s | %s | %s |\n' "$_d" "$_dur" "$_f" "${_tm:-n/a}"
        done
        printf '\n'
        qblock RESPHIST
    fi

    # ---- 5. AWR trend ----
    printf '## 5. AWR trend (last %s day(s))\n\n' "$AWR_DAYS"
    printf '_Source: `DBA_HIST_SNAPSHOT`, `DBA_HIST_SYSTEM_EVENT`, `DBA_HIST_SYSSTAT`,\n'
    printf '`DBA_HIST_SYS_TIME_MODEL` (Diagnostics Pack)._\n\n'
    if [[ -n "$AWR_NOTE" ]]; then
        printf '_%s_\n\n' "$AWR_NOTE"
    elif [[ -z "$TREND_RAW" ]]; then
        printf '_AWR trend unavailable (query failed or no data)._\n\n'
    else
        printf 'Per-snapshot averages; `est ovh (ms)` = max(0, avg R - avg L) x lfs waits, in\n'
        printf 'milliseconds - a lower-bound estimate (AWR carries no histograms fine enough\n'
        printf 'for the E[max] model, but the microsecond event totals keep the averages exact).\n\n'
        printf '| Snap | End time | lfs waits | lfs avg ms | local wr ms | remote ack ms | commits/s | DB time ms | est ovh (ms) |\n'
        printf '|------|----------|-----------|------------|-------------|---------------|-----------|-----------|-------------|\n'
        printf '%s\n' "$TREND_RAW" | rows TREND | while IFS='|' read -r _s _t _c _l _pw _rw _cs _dbt _ovh; do
            printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
                "$_s" "$_t" "$_c" "$_l" "$_pw" "$_rw" "$_cs" "$_dbt" "$_ovh"
        done
        printf '\n'
        qblock TREND
    fi

    # ---- 6. top latency spikes ----
    printf '## 6. Top latency spikes\n\n'
    printf '_Source: the section 4 and section 5 queries, re-ranked worst-first._\n\n'
    if [[ "$SYNC_DEST_COUNT" -eq 0 ]]; then
        printf '_Not applicable - no synchronous destination is active._\n\n'
    else
        if [[ -z "$RESP_RAW" ]]; then
            printf '_Slowest-response ranking unavailable (V$REDO_DEST_RESP_HISTOGRAM query\n'
            printf 'failed or empty)._\n\n'
        else
            printf '**Slowest SYNC transport responses** (top 10 non-empty buckets of\n'
            printf '`V$REDO_DEST_RESP_HISTOGRAM`, worst first; the view buckets by whole\n'
            printf 'seconds, so the 1000 ms bucket holds everything sub-second - these are\n'
            printf 'the actual worst remote acks, including e.g. standby restarts and\n'
            printf 'network stalls, capped at NET_TIMEOUT):\n\n'
            printf '| Dest | Response time bucket (ms) | Responses | Last at |\n'
            printf '|------|--------------------------|-----------|---------|\n'
            printf '%s\n' "$RESP_RAW" | rows RESP | sort -t'|' -k2,2nr | head -10 \
                | while IFS='|' read -r _d _dur _f _tm; do
                printf '| %s | %s | %s | %s |\n' "$_d" "$_dur" "$_f" "${_tm:-n/a}"
            done
            printf '\n'
        fi
        if [[ "$NO_PACK" == "YES" ]]; then
            printf '_AWR snapshot spike ranking skipped (`--no-pack`)._\n\n'
        elif [[ -z "$TREND_RAW" ]]; then
            printf '_AWR snapshot spike ranking unavailable (no AWR trend data - see section 5)._\n\n'
        else
            local spikes
            spikes=$(printf '%s\n' "$TREND_RAW" | rows TREND | awk -F'|' '
                $5 != "-" && $6 != "-" {
                    ovh = $6 - $5; if (ovh < 0) ovh = 0
                    printf "%.3f|%s\n", ovh, $0
                }' | sort -t'|' -k1,1nr | head -10)
            if [[ -z "$spikes" ]]; then
                printf '_AWR snapshot spike ranking unavailable (no snapshot has both local\n'
                printf 'write and remote ack averages)._\n\n'
            else
                printf '**Worst AWR snapshots by estimated added latency per commit** (last %s\n' "$AWR_DAYS"
                printf 'day(s); lower-bound estimator max(0, avg remote ack - avg local write),\n'
                printf 'worst first - these are snapshot-interval averages, so a sustained bad\n'
                printf 'period, not a single slow commit):\n\n'
                printf '| Snap | End time | Added ms/commit (est) | lfs avg ms | local wr ms | remote ack ms | lfs waits | est added ms |\n'
                printf '|------|----------|-----------------------|------------|-------------|---------------|-----------|-------------|\n'
                printf '%s\n' "$spikes" | while IFS='|' read -r _ovh _s _t _c _l _pw _rw _cs _dbt _est; do
                    printf '| %s | %s | %s | %s | %s | %s | %s | %s |\n' \
                        "$_s" "$_t" "$_ovh" "$_l" "$_pw" "$_rw" "$_c" "$_est"
                done
                printf '\n'
            fi
        fi
    fi

    # ---- 7. baseline ----
    printf '## 7. Baseline comparison (before vs after synchronous transport)\n\n'
    printf '_Source: `DBA_HIST_SYSTEM_EVENT`, `DBA_HIST_SYSSTAT`, `DBA_HIST_SNAPSHOT`\n'
    printf 'over two windows (Diagnostics Pack)._\n\n'
    if [[ -z "$BASELINE_MODE" && "$AUTO_BASELINE" != "YES" ]]; then
        printf '_No baseline window supplied. Re-run with `--baseline-begin`/`--baseline-end`\n'
        printf 'covering a pre-SYNC period (or with `--auto-baseline` to detect one from AWR\n'
        printf 'history) to add the empirical before/after comparison._\n\n'
    elif [[ "$AUTO_BASELINE" == "YES" && -n "$AUTOBASE_NOTE" ]]; then
        printf '_Auto-baseline detection: %s - comparison skipped._\n\n' "$AUTOBASE_NOTE"
    elif [[ -z "$BASEAGG_RAW" ]]; then
        printf '_Baseline window has no usable AWR data (fewer than 2 snapshots, or the query\n'
        printf 'failed) - comparison skipped._\n\n'
    else
        local b_elapsed b_lfs_cnt b_lfs_avg b_lfpw_avg b_srw_cnt b_srw_avg b_commits b_dbtime
        b_elapsed=$(field  "$BASEAGG_RAW" 2)
        b_lfs_cnt=$(field  "$BASEAGG_RAW" 3)
        b_lfs_avg=$(field  "$BASEAGG_RAW" 4)
        b_lfpw_avg=$(field "$BASEAGG_RAW" 5)
        b_srw_cnt=$(field  "$BASEAGG_RAW" 6)
        b_srw_avg=$(field  "$BASEAGG_RAW" 7)
        b_commits=$(field  "$BASEAGG_RAW" 8)
        b_dbtime=$(field   "$BASEAGG_RAW" 9)

        if [[ "$AUTO_BASELINE" == "YES" ]]; then
            printf -- '- Baseline window **auto-detected** from AWR: snapshots %s-%s (%s snaps,\n' \
                "$(field "$BASEWIN_RAW" 2)" "$(field "$BASEWIN_RAW" 3)" "$(field "$BASEWIN_RAW" 4)"
            printf '  %s .. %s), classified by the per-snapshot ratio of `SYNC Remote Write`\n' \
                "$(field "$BASEWIN_RAW" 5)" "$(field "$BASEWIN_RAW" 6)"
            printf '  waits to redo writes.\n'
            printf -- '- Synchronous transport first observed at snap %s (%s).\n' \
                "$(fmt_or_na "$AB_TRANS_SNAP")" "${AB_TRANS_TIME:-n/a}"
            printf -- '- Snapshots scanned: %s SYNC, %s NOSYNC, %s IDLE/MIXED.\n' \
                "$(fmt_or_na "$AB_N_SYNC")" "$(fmt_or_na "$AB_N_NOSYNC")" "$(fmt_or_na "$AB_N_OTHER")"
            printf -- '- **Detection is behavioral, not configurational:** periods where a SYNC\n'
            printf '  destination existed but the standby was unreachable count as no-sync -\n'
            printf '  valid for latency comparison, but check the window makes sense.\n'
            printf '\n'
        fi

        printf 'Baseline: snapshots %s-%s (%s), %s .. %s\n\n' \
            "$(field "$BASEWIN_RAW" 2)" "$(field "$BASEWIN_RAW" 3)" "$(field "$BASEWIN_RAW" 4)" \
            "$(field "$BASEWIN_RAW" 5)" "$(field "$BASEWIN_RAW" 6)"

        local b_rate c_rate
        b_rate=""; c_rate=""
        if is_num "$b_commits" && is_num "$b_elapsed" && [[ "${b_elapsed%.*}" -gt 0 ]] 2>/dev/null; then
            b_rate=$(calc "$b_commits / $b_elapsed")
        fi
        if is_num "$AGG_COMMITS" && is_num "$AGG_ELAPSED" && [[ "${AGG_ELAPSED%.*}" -gt 0 ]] 2>/dev/null; then
            c_rate=$(calc "$AGG_COMMITS / $AGG_ELAPSED")
        fi

        printf '| Measure | Baseline | Current window |\n'
        printf '|---------|----------|----------------|\n'
        printf '| log file sync avg (ms) | %s | %s |\n' "$(fmt_or_na "$b_lfs_avg")" "$(fmt_or_na "$AGG_LFS_AVG")"
        printf '| log file parallel write avg (ms) | %s | %s |\n' "$(fmt_or_na "$b_lfpw_avg")" "$(fmt_or_na "$AGG_LFPW_AVG")"
        printf '| SYNC Remote Write avg (ms) | %s | %s |\n' "$(fmt_or_na "$b_srw_avg")" "$(fmt_or_na "$AGG_SRW_AVG")"
        printf '| commits/s | %s | %s |\n' "$(fmt_or_na "$b_rate")" "$(fmt_or_na "$c_rate")"

        local b_p50 b_p90 b_p99 c_p50 c_p90 c_p99
        b_p50=$(field "$BASEHPCT_RAW" 2); b_p90=$(field "$BASEHPCT_RAW" 3); b_p99=$(field "$BASEHPCT_RAW" 4)
        c_p50=$(field "$CURHPCT_RAW" 2);  c_p90=$(field "$CURHPCT_RAW" 3);  c_p99=$(field "$CURHPCT_RAW" 4)
        if [[ -n "$BASEHPCT_RAW" || -n "$CURHPCT_RAW" ]]; then
            printf '| lfs p50 / p90 / p99 (<= ms buckets) | %s / %s / %s | %s / %s / %s |\n' \
                "$(fmt_or_na "$b_p50")" "$(fmt_or_na "$b_p90")" "$(fmt_or_na "$b_p99")" \
                "$(fmt_or_na "$c_p50")" "$(fmt_or_na "$c_p90")" "$(fmt_or_na "$c_p99")"
        fi
        printf '\n'

        # emp_delta may legitimately be negative (baseline slower), so it is
        # printed directly rather than through the non-negative fmt_or_na.
        local emp_delta
        emp_delta=""
        if is_num "$b_lfs_avg" && is_num "$AGG_LFS_AVG"; then
            emp_delta=$(calc "$AGG_LFS_AVG - $b_lfs_avg")
        fi
        if [[ -n "$emp_delta" ]]; then
            printf -- '- **Empirical added latency per commit: %s ms** (current avg lfs - baseline avg lfs)\n' "$emp_delta"
        else
            printf -- '- **Empirical added latency per commit: n/a** (current avg lfs - baseline avg lfs)\n'
        fi
        printf -- '- Model estimate for comparison: %s\n' "$(fmt_or_na "$OVERHEAD_EST" " ms")"

        # Comparability guards
        if is_num "$b_rate" && is_num "$c_rate" \
           && awk "BEGIN{exit !($b_rate > 0 && ($c_rate > 2*$b_rate || $b_rate > 2*$c_rate))}"; then
            printf -- '- **Warning:** commit rate differs by more than 2x between the windows - the\n'
            printf '  workloads are not directly comparable; treat the empirical delta with care.\n'
        fi
        if is_num "$b_lfpw_avg" && is_num "$AGG_LFPW_AVG" \
           && awk "BEGIN{exit !($b_lfpw_avg > 0 && ($AGG_LFPW_AVG > 1.5*$b_lfpw_avg || $b_lfpw_avg > 1.5*$AGG_LFPW_AVG))}"; then
            printf -- '- **Warning:** the LOCAL redo write latency also shifted between the windows\n'
            printf '  (storage change?) - part of the empirical delta is not transport-related.\n'
        fi
        printf '\n'
        qblock AWRAGG BASEHIST AUTOBASE
    fi

    # ---- 8. ASH ----
    printf '## 8. ASH attribution: who pays (last %s hour(s))\n\n' "$ASH_HOURS"
    printf '_Source: `V$ACTIVE_SESSION_HISTORY`, foreground samples only (Diagnostics Pack)._\n\n'
    if [[ "$NO_PACK" == "YES" ]]; then
        printf '_Skipped (`--no-pack`)._\n\n'
    elif [[ -z "$ASH_RAW" ]]; then
        printf '_ASH data unavailable._\n\n'
    else
        local a_total a_lfs a_sess a_oldest
        a_total=""; a_lfs=""; a_sess=""; a_oldest=""
        local ashsum
        ashsum=$(printf '%s\n' "$ASH_RAW" | grep '^ASHSUM|' | head -1 || true)
        if [[ -n "$ashsum" ]]; then
            a_total=$(field "$ashsum" 2)
            a_lfs=$(field   "$ashsum" 3)
            a_sess=$(field  "$ashsum" 4)
            a_oldest=$(field "$ashsum" 5)
        fi
        local a_pct
        a_pct=""
        if is_num "$a_total" && is_num "$a_lfs" && [[ "$a_total" -gt 0 ]] 2>/dev/null; then
            a_pct=$(calc "$a_lfs / $a_total * 100")
        fi
        printf -- '- Foreground samples: %s (oldest in buffer: %s - shorter than requested means\n' "$(fmt_or_na "$a_total")" "${a_oldest:-n/a}"
        printf '  the in-memory ASH buffer wrapped)\n'
        printf -- '- Samples in `log file sync`: %s (**%s of foreground activity**), across %s distinct sessions\n' \
            "$(fmt_or_na "$a_lfs")" "$(fmt_or_na "$a_pct" " %")" "$(fmt_or_na "$a_sess")"
        printf -- '- Time estimate: each V$ASH sample represents ~1 s of wall-clock wait\n'
        printf '\n'

        if printf '%s\n' "$ASH_RAW" | grep -q '^ASHSQL|'; then
            printf '**Top SQL waiting on log file sync:**\n\n'
            printf '| SQL_ID | Samples | Text (first 60 chars) |\n'
            printf '|--------|---------|------------------------|\n'
            printf '%s\n' "$ASH_RAW" | rows ASHSQL | while IFS='|' read -r _id _cnt _txt; do
                printf '| %s | %s | %s |\n' "$_id" "$_cnt" "$_txt"
            done
            printf '\n'
        fi
        if printf '%s\n' "$ASH_RAW" | grep -q '^ASHMOD|'; then
            printf '**Top modules:**\n\n'
            printf '| Module | Samples |\n'
            printf '|--------|---------|\n'
            printf '%s\n' "$ASH_RAW" | rows ASHMOD | while IFS='|' read -r _m _cnt; do
                printf '| %s | %s |\n' "$_m" "$_cnt"
            done
            printf '\n'
        fi
        if printf '%s\n' "$ASH_RAW" | grep -q '^ASHSVC|'; then
            printf '**Top services:**\n\n'
            printf '| Service | Samples |\n'
            printf '|---------|---------|\n'
            printf '%s\n' "$ASH_RAW" | rows ASHSVC | while IFS='|' read -r _s _cnt; do
                printf '| %s | %s |\n' "$_s" "$_cnt"
            done
            printf '\n'
        fi
        if printf '%s\n' "$ASH_RAW" | grep -q '^ASHHR|'; then
            printf '**Hourly profile (lfs samples / all foreground samples):**\n\n'
            printf '| Hour | lfs | total | lfs %% |\n'
            printf '|------|-----|-------|-------|\n'
            printf '%s\n' "$ASH_RAW" | rows ASHHR | while IFS='|' read -r _h _l _t; do
                _p="-"
                if is_num "$_l" && is_num "$_t" && [[ "$_t" -gt 0 ]] 2>/dev/null; then
                    _p=$(calc "$_l / $_t * 100")
                fi
                printf '| %s | %s | %s | %s |\n' "$_h" "$_l" "$_t" "$_p"
            done
            printf '\n'
        fi
        qblock ASH
    fi

    # ---- 9. method notes ----
    printf '## 9. Method notes and caveats\n\n'
    printf '_Source: no data - assumptions behind the numbers above._\n\n'
    printf -- '- **Overlap model:** since 11g R2 the local redo write (L) and the network send to a\n'
    printf '  SYNC standby run in parallel - LGWR starts the remote write, then issues the\n'
    printf '  local one, then waits for both - so a commit'"'"'s redo-write phase lasts about\n'
    printf '  max(L,R) (plus small serial pre/post costs not attributed to transport here).\n'
    printf '  The refined estimate is E[max(L,R)] - E[L], computed by cross-joining the\n'
    printf '  `V$EVENT_HISTOGRAM_MICRO` distributions of `log file parallel write` (L) and\n'
    printf '  `SYNC Remote Write` (R) with geometric bucket midpoints.\n'
    printf -- '- **Why not plain averages:** Oracle'"'"'s own HA tuning guide warns that for SYNC\n'
    printf '  impact "the averages can be very deceiving" - E[max] of the distributions is\n'
    printf '  not derivable from the two averages, hence the histogram model.\n'
    printf -- '- **Independence assumption:** the convolution assumes L and R are independent.\n'
    printf '  Shared load (a storage/network burst hitting both) makes the estimate optimistic.\n'
    printf -- '- **AFFIRM vs NOAFFIRM:** with AFFIRM, R includes the standby SRL disk write; with\n'
    printf '  NOAFFIRM (FASTSYNC) it is in-memory receipt only. Section 1 shows which applies.\n'
    printf -- '- **Bounds:** avg-based bounds hold regardless of the independence assumption:\n'
    printf '  max(0, avg R - avg L) <= per-write overhead <= avg R.\n'
    printf -- '- **Not everything in log file sync is transport:** the `redo synch time overhead`\n'
    printf '  statistic (section 3) is scheduling/post latency; if it dominates, fix CPU, not DG.\n'
    printf -- '- **Window mismatch:** micro-histograms are cumulative since instance startup, while\n'
    printf '  AWR sections cover their stated windows. Numbers are labeled with their source.\n'
    printf -- '- **ASH sampling:** 1-second samples estimate total wait time fairly, but under-count\n'
    printf '  short waits; do not read the sample counts as wait counts.\n'
    printf -- '- **Spike dilution:** the AWR spike ranking (section 6) works on snapshot-interval\n'
    printf '  averages - a single multi-second stall inside an otherwise quiet interval barely\n'
    printf '  moves that snapshot. Individual slow acks show up in the response histogram\n'
    printf '  buckets and the `max` column of section 4 instead.\n'
    printf -- '- **Scope:** single-instance primary; AWR data is CDB-level when run in a CDB root.\n'
    if [[ "${#DEGRADED_NOTES[@]}" -gt 0 ]]; then
        printf '\n**Collection warnings:** the following data could not be collected -\n'
        local n
        for n in "${DEGRADED_NOTES[@]}"; do
            printf -- '- %s\n' "$n"
        done
    fi
    printf '\n'
}

# ============================================================
# HTML rendering (--html)
# ============================================================
# The Markdown emitter above stays the single definition of the report;
# md_to_html converts exactly the Markdown subset it produces (h1/h2,
# pipe tables, bullets with two-space continuations, blockquotes,
# whole-line _italics_, **bold**, `code`) into HTML. POSIX awk only -
# no gensub, AIX-safe.
#
# Two graphical upgrades happen here (the Markdown itself is unchanged):
# - the headline "| Measure | Value |" table renders as a row of KPI cards;
# - every other table keeps plain cells and gets a strip of charts below it,
#   one per plottable column, each on its own scale (columns rarely share
#   units). A column is plottable when every populated cell is a number
#   ("<= 1.024" bucket bounds count), at least two are, the max is > 0 and
#   the header is not an ordinal/identifier (Snap, Hour, bucket, Dest,
#   SQL_ID, NET_TIMEOUT); Measure|Value and Statistic|Value tables mix units
#   down the column and are never charted. Categories come from the first
#   non-plotted column that varies. A snapshot/hour axis with >= 6 points is
#   drawn as a time series (one column per row, oldest to newest); anything
#   else as a horizontal ranking capped at 15 rows.
# Numeric cells get class="n" (right-aligned tabular mono) - alignment only,
# no marks in the cell. Every table is wrapped in <div class="tw"> so wide
# tables scroll inside their own frame instead of widening the page.
#
# AIX 7.2 /usr/bin/awk aborts the whole run with "0602-558 cannot be used
# as an array" where other awks cope, so the converter stays inside its
# rules:
# - no function-local array (an unsupplied extra parameter is a scalar
#   there): varies() replaces a seen[] membership count;
# - every global array is seeded in BEGIN, so no name is first subscripted
#   inside a function body or first touched by a read;
# - cells are keyed with an explicit "row|col" string instead of a
#   multi-subscript (SUBSEP) reference;
# - array elements are compared (== 1), never used as a bare boolean.

md_to_html() {
    awk '
    function esc(s) {
        gsub(/&/, "\\&amp;", s)
        gsub(/</, "\\&lt;", s)
        gsub(/>/, "\\&gt;", s)
        return s
    }
    function inline_fmt(s,   out) {
        out = ""
        while (match(s, /\*\*[^*]+\*\*/)) {
            out = out substr(s, 1, RSTART-1) "<strong>" substr(s, RSTART+2, RLENGTH-4) "</strong>"
            s = substr(s, RSTART+RLENGTH)
        }
        s = out s
        out = ""
        while (match(s, /`[^`]+`/)) {
            out = out substr(s, 1, RSTART-1) "<code>" substr(s, RSTART+1, RLENGTH-2) "</code>"
            s = substr(s, RSTART+RLENGTH)
        }
        return out s
    }
    function trimcell(s) {
        sub(/^[ \t]+/, "", s)
        sub(/[ \t]+$/, "", s)
        return s
    }
    function flush_li() {
        if (li != "") { print "<li>" inline_fmt(li) "</li>"; li = "" }
    }
    function flush_p() {
        if (pbuf != "") {
            # a paragraph fully wrapped in _.._ is an italic note
            # (may have been emitted across several source lines)
            if (pbuf ~ /^_.*_$/)
                print "<p><em>" inline_fmt(substr(pbuf, 2, length(pbuf)-2)) "</em></p>"
            else
                print "<p>" inline_fmt(pbuf) "</p>"
            pbuf = ""
        }
    }
    function flush_bq() {
        if (bqbuf != "") { print "<blockquote><p>" inline_fmt(bqbuf) "</p></blockquote>"; bqbuf = "" }
    }
    # ---- numeric cell helpers ----
    # Oracle prints sub-1 values with a bare leading dot (.5), and the
    # percentile table prints bucket upper bounds as "<= 1.024" (already
    # escaped to "&lt;= 1.024" by esc()); both are chartable numbers.
    function nclean(v) {
        sub(/^&lt;=[ ]*/, "", v)
        return v
    }
    function isnum(v) {
        return (nclean(v) ~ /^-?(\.[0-9]+|[0-9]+(\.[0-9]+)?)$/)
    }
    function nval(v) {
        return nclean(v) + 0
    }
    function attresc(s) {
        gsub(/"/, "\\&quot;", s)
        return s
    }
    # 1234567.8 -> 1 234 567.8, so chart captions stay readable
    function group(x,   s, ip, fp, o, n) {
        s = sprintf("%.10g", x)
        ip = s; fp = ""
        if (index(s, ".") > 0) { ip = substr(s, 1, index(s, ".")-1); fp = substr(s, index(s, ".")) }
        o = ""
        while (length(ip) > 3) {
            o = " " substr(ip, length(ip)-2) o
            ip = substr(ip, 1, length(ip)-3)
        }
        return ip o fp
    }
    # True when column j holds more than one distinct value. Deliberately
    # written without a local array: AIX awk creates a function extra
    # parameter as a scalar and kills the run with "0602-558 cannot be
    # used as an array" the moment one is subscripted.
    function varies(j,   r, first) {
        first = tcell["2|" j]
        for (r = 3; r <= tnr; r++)
            if (tcell[r "|" j] != first) return 1
        return 0
    }
    # Emit the buffered table. Buffering (rather than streaming rows out)
    # is what allows per-column maxima for the charts underneath it.
    function emit_table(   r, j, tag, row, hdr1, h, v, ok, numc, maxc) {
        if (tnr == 0) return
        if (tsep && tnr >= 2 && tnc[1] == 2 && tcell["1|1"] == "Measure" && tcell["1|2"] == "Value") {
            print "<div class=\"kpis\">"
            for (r = 2; r <= tnr; r++)
                print "<div class=\"kpi\"><span class=\"kpi-l\">" inline_fmt(tcell[r "|1"]) "</span><span class=\"kpi-v\">" inline_fmt(tcell[r "|2"]) "</span></div>"
            print "</div>"
            tnr = 0; tsep = 0
            return
        }
        maxc = 0
        for (r = 1; r <= tnr; r++) if (tnc[r] > maxc) maxc = tnc[r]
        for (j = 1; j <= maxc; j++) { numcol[j] = 0; chartcol[j] = 0; cmax[j] = 0 }
        hdr1 = tolower(tcell["1|1"])
        if (tsep) {
            # numcol: every populated cell is a number and at least two are.
            # Drives right-aligned tabular cells - alignment only, no marks.
            for (j = 1; j <= maxc; j++) {
                ok = 1; numc = 0
                for (r = 2; r <= tnr; r++) {
                    v = tcell[r "|" j]
                    if (v == "" || v == "-" || v == "n/a") continue
                    if (!isnum(v)) { ok = 0; break }
                    numc = numc + 1
                    if (nval(v) > cmax[j]) cmax[j] = nval(v)
                }
                if (ok && numc >= 2) numcol[j] = 1
            }
            # chartcol: a numeric column worth plotting - needs a real scale
            # and a header that is a measure, not an ordinal/identifier.
            if (tnr >= 3 && hdr1 !~ /measure|statistic/) {
                for (j = 1; j <= maxc; j++) {
                    h = tolower(tcell["1|" j])
                    if (h ~ /snap|hour|bucket|dest|sql_id|net_timeout/) continue
                    if (numcol[j] == 1 && cmax[j] > 0) chartcol[j] = 1
                }
            }
        }
        print "<div class=\"tw\"><table>"
        for (r = 1; r <= tnr; r++) {
            tag = (tsep && r == 1) ? "th" : "td"
            row = "<tr>"
            for (j = 1; j <= tnc[r]; j++) {
                v = tcell[r "|" j]
                if (numcol[j] == 1)
                    row = row "<" tag " class=\"n\">" inline_fmt(v) "</" tag ">"
                else
                    row = row "<" tag ">" inline_fmt(v) "</" tag ">"
            }
            print row "</tr>"
        }
        print "</table></div>"
        emit_charts(maxc)
        tnr = 0; tsep = 0
    }
    # One small chart per plottable column, below the table it reads from.
    # Each chart carries its own scale (columns rarely share units), so the
    # cells above stay plain and the shape of the data lives here.
    function emit_charts(maxc,   j, lab, any, series) {
        any = 0
        for (j = 1; j <= maxc; j++) if (chartcol[j] == 1) any = 1
        if (!any) return
        # label axis: the first non-plotted column that actually varies
        lab = 0
        for (j = 1; j <= maxc; j++) {
            if (chartcol[j] == 1) continue
            if (varies(j)) { lab = j; break }
        }
        if (lab == 0) lab = 1
        # a snapshot/hour axis with enough points is a trend, not a ranking
        series = (tolower(tcell["1|" lab]) ~ /snap|hour/ && (tnr - 1) >= 6)
        # on a trend the x axis is time: label its ends with a clock column
        # when the table has one ("Snap" alone reads like a category)
        tlab = lab
        for (j = 1; j <= maxc; j++) {
            if (chartcol[j] == 1) continue
            if (tolower(tcell["1|" j]) ~ /time|date/ && varies(j)) { tlab = j; break }
        }
        print "<div class=\"charts\">"
        for (j = 1; j <= maxc; j++) {
            if (chartcol[j] != 1) continue
            if (series) emit_series(j, lab, tlab); else emit_bars(j, lab)
        }
        print "</div>"
    }
    function chart_open(j) {
        print "<figure class=\"chart\">"
        print "<figcaption>" inline_fmt(tcell["1|" j]) "<span class=\"cmax\">max " group(cmax[j]) "</span></figcaption>"
    }
    function emit_bars(j, lab,   r, v, pct, shown) {
        chart_open(j)
        print "<div class=\"bars\">"
        shown = 0
        for (r = 2; r <= tnr; r++) {
            if (shown >= 15) break
            v = tcell[r "|" j]
            pct = 0
            if (isnum(v)) pct = nval(v) / cmax[j] * 100
            if (pct < 0) pct = 0
            print "<div class=\"brow\"><span class=\"bl\" title=\"" attresc(tcell[r "|" lab]) "\">" inline_fmt(tcell[r "|" lab]) "</span><span class=\"bt\"><span class=\"bf\" style=\"width:" sprintf("%.1f", pct) "%\"></span></span><span class=\"bv\">" inline_fmt(v) "</span></div>"
            shown = shown + 1
        }
        print "</div>"
        if (tnr - 1 > shown)
            print "<p class=\"cnote\">first " shown " of " (tnr - 1) " rows</p>"
        print "</figure>"
    }
    # A trend, not a distribution: x is time (one bar per row, oldest left),
    # y is the value with the column max at the top and zero at the baseline.
    # The caption spells out what a single bar is, so it cannot be mistaken
    # for a frequency histogram.
    function emit_series(j, lab, tlab,   r, v, pct) {
        print "<figure class=\"chart\">"
        print "<figcaption>" inline_fmt(tcell["1|" j]) "<span class=\"cmax\">1 bar = 1 " tolower(tcell["1|" lab]) " (" (tnr - 1) ")</span></figcaption>"
        print "<div class=\"plot\">"
        print "<div class=\"yax\"><span>" group(cmax[j]) "</span><span>0</span></div>"
        print "<div class=\"cols\">"
        for (r = 2; r <= tnr; r++) {
            v = tcell[r "|" j]
            pct = 0
            if (isnum(v)) pct = nval(v) / cmax[j] * 100
            if (pct < 0) pct = 0
            print "<span class=\"col\" style=\"height:" sprintf("%.1f", pct) "%\" title=\"" attresc(tcell[r "|" tlab]) ": " attresc(v) "\"></span>"
        }
        print "</div>"
        print "</div>"
        print "<div class=\"axis\"><span>" inline_fmt(tcell["2|" tlab]) "</span><span>" inline_fmt(tcell[tnr "|" tlab]) "</span></div>"
        print "</figure>"
    }
    function close_blocks() {
        flush_li(); flush_p(); flush_bq()
        if (inul)   { print "</ul>"; inul = 0 }
        if (tnr > 0) emit_table()
    }
    # Seed every array and counter up front: AIX awk refuses a name it
    # has not already seen subscripted ("cannot be used as an array"),
    # and index 0 is outside every 1..n loop below, so this is inert.
    BEGIN {
        tnr = 0; tsep = 0; inul = 0; infence = 0
        li = ""; pbuf = ""; bqbuf = ""; fbuf = ""
        cells[0] = ""; tnc[0] = 0; tcell["0|0"] = ""
        numcol[0] = 0; chartcol[0] = 0; cmax[0] = 0
    }
    {
        line = esc($0)

        # fenced block: the exact query behind the table above, folded away
        # in a <details> so it never interrupts the reading flow. Checked
        # first - SQL lines are indented and would otherwise be swallowed by
        # the bullet-continuation rule below.
        # Buffered and printed without the surrounding newlines: a <pre> keeps
        # them, so streaming the lines out would frame the SQL in blank lines.
        if (infence) {
            if (line ~ /^```/) {
                printf "%s", fbuf
                print "</code></pre></details>"
                fbuf = ""; infence = 0
            } else {
                fbuf = fbuf (fbuf == "" ? "" : "\n") line
            }
            next
        }
        if (line ~ /^```/) {
            close_blocks()
            printf "%s", "<details class=\"q\"><summary>Query</summary><pre><code>"
            infence = 1
            next
        }

        # bullet continuation (two-space indent while a bullet is open)
        if (li != "" && line ~ /^  [^ ]/) {
            sub(/^[ \t]+/, "", line)
            li = li " " line
            next
        }
        if (line ~ /^# /)  { close_blocks(); print "<h1>" inline_fmt(substr(line,3)) "</h1>"; next }
        if (line ~ /^## /) { close_blocks(); print "<h2>" inline_fmt(substr(line,4)) "</h2>"; next }
        if (line ~ /^\|/) {
            flush_li(); flush_p(); flush_bq()
            if (inul) { print "</ul>"; inul = 0 }
            if (line ~ /^\|[-| :]+\|$/) { if (tnr > 0) tsep = 1; next }
            n = split(line, cells, /\|/)
            tnr = tnr + 1; tnc[tnr] = 0
            for (i = 2; i < n; i++) {
                tnc[tnr] = tnc[tnr] + 1
                tcell[tnr "|" tnc[tnr]] = trimcell(cells[i])
            }
            next
        }
        if (tnr > 0) emit_table()
        if (line ~ /^- /) {
            flush_p(); flush_bq(); flush_li()
            if (!inul) { print "<ul>"; inul = 1 }
            li = substr(line, 3)
            next
        }
        if (inul) { flush_li(); print "</ul>"; inul = 0 }
        if (line ~ /^&gt; ?/) {
            flush_p()
            sub(/^&gt; ?/, "", line)
            bqbuf = (bqbuf == "") ? line : bqbuf " " line
            next
        }
        flush_bq()
        if (line ~ /^[ \t]*$/) { flush_p(); next }
        pbuf = (pbuf == "") ? line : pbuf " " line
    }
    END { close_blocks() }
    '
}

emit_html() {
    cat <<HTMLHEAD
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sync Data Guard Impact - ${DB_UNIQUE_NAME}</title>
<style>
:root{
  color-scheme:light;
  --ground:#f4f6f5;--surface:#ffffff;--ink:#141a1b;--muted:#5d6b6c;
  --rule:#dae1df;--rule-strong:#b3c0be;
  --accent:#0b6a73;--accent-soft:rgba(11,106,115,.11);--accent-line:rgba(11,106,115,.42);
  --warn:#6d4a08;--warn-bg:#fbf3df;--warn-rule:#d9a441;
  --code-bg:#e9edec;--track:#e7ebe9;
  --f-text:"IBM Plex Sans",-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
  --f-mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,"DejaVu Sans Mono",monospace;
}
@media (prefers-color-scheme: dark){
:root{
  color-scheme:dark;
  --ground:#0e1315;--surface:#151c1e;--ink:#dbe4e3;--muted:#8fa0a0;
  --rule:#26312f;--rule-strong:#3b4846;
  --accent:#5cb8c0;--accent-soft:rgba(92,184,192,.15);--accent-line:rgba(92,184,192,.5);
  --warn:#e2bb6b;--warn-bg:#221c0f;--warn-rule:#8a6a1c;
  --code-bg:#1c2426;--track:#1d2628;
}
}
:root[data-theme="light"]{
  color-scheme:light;
  --ground:#f4f6f5;--surface:#ffffff;--ink:#141a1b;--muted:#5d6b6c;
  --rule:#dae1df;--rule-strong:#b3c0be;
  --accent:#0b6a73;--accent-soft:rgba(11,106,115,.11);--accent-line:rgba(11,106,115,.42);
  --warn:#6d4a08;--warn-bg:#fbf3df;--warn-rule:#d9a441;
  --code-bg:#e9edec;--track:#e7ebe9;
}
:root[data-theme="dark"]{
  color-scheme:dark;
  --ground:#0e1315;--surface:#151c1e;--ink:#dbe4e3;--muted:#8fa0a0;
  --rule:#26312f;--rule-strong:#3b4846;
  --accent:#5cb8c0;--accent-soft:rgba(92,184,192,.15);--accent-line:rgba(92,184,192,.5);
  --warn:#e2bb6b;--warn-bg:#221c0f;--warn-rule:#8a6a1c;
  --code-bg:#1c2426;--track:#1d2628;
}
*{box-sizing:border-box}
body{margin:0;background:var(--ground);color:var(--ink);
  font-family:var(--f-text);font-size:15.5px;line-height:1.65;
  -webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale;
  -webkit-text-size-adjust:100%}
main{max-width:64rem;margin:0 auto;padding:3.5rem 1.5rem 5rem}
p,ul{max-width:68ch}
p{margin:1.05rem 0;text-wrap:pretty}
h1{font-weight:600;font-size:clamp(1.7rem,3.6vw,2.15rem);
  line-height:1.14;letter-spacing:-.022em;margin:0 0 1.5rem;text-wrap:balance}
h2{font-weight:600;font-size:1.2rem;line-height:1.3;
  letter-spacing:-.014em;margin:3.4rem 0 1.15rem;padding-top:1.45rem;
  border-top:1px solid var(--rule);text-wrap:balance}
/* the masthead metadata list (database, instance, generated, windows) */
h1+ul{max-width:none;list-style:none;margin:0;padding:1.05rem 1.25rem;
  display:flex;flex-direction:column;gap:.45rem;
  background:var(--surface);border:1px solid var(--rule);border-radius:3px;font-size:.92rem}
h1+ul li{margin:0}
h1+ul strong{font-family:var(--f-mono);font-size:.72rem;font-weight:600;
  text-transform:uppercase;letter-spacing:.055em;color:var(--muted)}
ul{padding-left:1.15rem;margin:1rem 0}
li{margin:.35rem 0}
li::marker{color:var(--accent-line)}
strong{font-weight:600}
em{color:var(--muted);font-style:italic}
code{font-family:var(--f-mono);font-size:.86em;background:var(--code-bg);
  padding:.08em .34em;border-radius:2px}
.tw{overflow-x:auto;margin:1.3rem 0;background:var(--surface);
  border:1px solid var(--rule);border-radius:3px;width:fit-content;max-width:100%}
table{border-collapse:collapse;width:100%;font-size:.86rem}
th{font-family:var(--f-mono);font-size:.7rem;font-weight:600;text-transform:uppercase;
  letter-spacing:.055em;color:var(--muted);text-align:left;
  padding:.65rem .9rem;border-bottom:1px solid var(--rule-strong);white-space:nowrap}
td{padding:.55rem .9rem;border-bottom:1px solid var(--rule);white-space:nowrap;
  vertical-align:baseline}
tr:last-child td{border-bottom:0}
tr:hover td{background:var(--accent-soft)}
td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}
td.n{font-family:var(--f-mono)}
/* charts: one per plottable column, each on its own scale, below the table */
.charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(17rem,1fr));
  gap:1.4rem 1.6rem;margin:1.4rem 0 1.8rem}
.chart{margin:0}
figcaption{display:flex;justify-content:space-between;align-items:baseline;gap:.75rem;
  font-family:var(--f-mono);font-size:.68rem;font-weight:600;text-transform:uppercase;
  letter-spacing:.055em;color:var(--muted);
  padding-bottom:.5rem;margin-bottom:.6rem;border-bottom:1px solid var(--rule)}
.cmax{font-weight:400;text-transform:none;letter-spacing:.02em;white-space:nowrap;opacity:.85}
.cnote{margin:.5rem 0 0;font-family:var(--f-mono);font-size:.66rem;color:var(--muted)}
/* ranking: horizontal bars, category label at the left */
.bars{display:flex;flex-direction:column;gap:.3rem}
.brow{display:grid;grid-template-columns:minmax(0,11em) 1fr auto;gap:.55rem;
  align-items:center;font-size:.78rem}
.bl{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--muted)}
.bt{position:relative;height:.65rem;background:var(--track);
  background-image:repeating-linear-gradient(to right,var(--rule) 0 1px,transparent 1px 25%)}
.bf{position:absolute;left:0;top:0;bottom:0;background:var(--accent);opacity:.85}
.bv{font-family:var(--f-mono);font-size:.74rem;font-variant-numeric:tabular-nums}
/* trend: one column per snapshot, oldest to newest, on a 0..max y axis */
.plot{display:grid;grid-template-columns:auto 1fr;gap:.45rem}
.yax{display:flex;flex-direction:column;justify-content:space-between;text-align:right;
  font-family:var(--f-mono);font-size:.62rem;line-height:1;color:var(--muted)}
.cols{display:flex;align-items:flex-end;gap:1px;height:5rem;overflow-x:auto;
  background:var(--track);
  background-image:repeating-linear-gradient(to top,var(--rule) 0 1px,transparent 1px 25%);
  border-left:1px solid var(--rule-strong);border-bottom:1px solid var(--rule-strong)}
.col{flex:1 1 auto;min-width:2px;min-height:1px;background:var(--accent);opacity:.8}
.col:hover{opacity:1}
.axis{display:flex;justify-content:space-between;gap:.75rem;margin-top:.35rem;
  margin-left:calc(2.5em + .45rem);
  font-family:var(--f-mono);font-size:.66rem;color:var(--muted)}
/* headline readouts: hairline-divided panel, gaps show the rule beneath */
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(15rem,1fr));
  gap:1px;margin:1.5rem 0;background:var(--surface);
  border:1px solid var(--rule);border-radius:3px;overflow:hidden}
/* the ring is a shadow, not a border, so it lands in the 1px gap and an
   incomplete last row leaves plain surface rather than a stray block */
.kpi{background:var(--surface);box-shadow:0 0 0 1px var(--rule);
  padding:1.05rem 1.2rem;display:flex;flex-direction:column;gap:.45rem}
.kpi-l{font-family:var(--f-mono);font-size:.7rem;font-weight:600;
  text-transform:uppercase;letter-spacing:.055em;color:var(--muted);line-height:1.4}
.kpi-v{font-family:var(--f-mono);font-size:1.4rem;font-weight:500;line-height:1.15;
  letter-spacing:-.01em;font-variant-numeric:tabular-nums;margin-top:auto}
.kpi-v strong{color:var(--accent);font-weight:600}
/* the first readout is the headline estimate the whole report is about */
.kpi:first-child .kpi-v{font-size:1.72rem}
/* the exact query behind the table above - folded away by default */
details.q{margin:1.1rem 0 1.7rem;background:var(--surface);
  border:1px solid var(--rule);border-radius:3px}
details.q summary{display:flex;align-items:center;gap:.5rem;cursor:pointer;list-style:none;
  padding:.55rem .9rem;font-family:var(--f-mono);font-size:.68rem;font-weight:600;
  text-transform:uppercase;letter-spacing:.055em;color:var(--muted)}
details.q summary::-webkit-details-marker{display:none}
details.q summary::before{content:"+";color:var(--accent);font-size:.95rem;line-height:1}
details.q[open] summary::before{content:"\2212"}
details.q summary:hover{color:var(--ink)}
details.q summary:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}
details.q pre{margin:0;padding:.9rem;border-top:1px solid var(--rule);
  overflow-x:auto;font-size:.78rem;line-height:1.55}
details.q code{background:none;padding:0;font-size:1em;white-space:pre}
pre.fallback{white-space:pre-wrap;font-size:.9em}
blockquote{max-width:70ch;margin:1.4rem 0;padding:.85rem 1.15rem;color:var(--warn);
  background:var(--warn-bg);border-left:3px solid var(--warn-rule);border-radius:0 3px 3px 0}
blockquote p{margin:.25rem 0;max-width:none}
blockquote strong{color:var(--warn)}
@media (max-width:34rem){
  main{padding:2.25rem 1rem 3rem}
  .kpis{grid-template-columns:1fr}
  .brow{grid-template-columns:minmax(0,7em) 1fr auto}
}
@media print{
  :root{--ground:#fff;--surface:#fff;--ink:#000;--muted:#444;--rule:#bbb;--rule-strong:#666;
    --accent:#0b6a73;--accent-soft:#eef2f2;--code-bg:#f0f0f0;--warn-bg:#fbf6e8;--warn:#5a3d05;
    --track:#eef0ef}
  main{max-width:none;padding:0}
  h2{page-break-after:avoid}
  .tw,.kpis,.chart,blockquote{page-break-inside:avoid}
  .bf,.col,.bt,.cols{-webkit-print-color-adjust:exact;print-color-adjust:exact}
  tr:hover td{background:transparent}
}
</style>
</head>
<body>
<main>
HTMLHEAD
    # Same contract as the collectors: degrade, never fail. An awk that
    # cannot run the converter (old vendor awks abort on constructs POSIX
    # allows) would otherwise leave a truncated page behind, so fall back
    # to the Markdown verbatim - the report still carries every number.
    local _md _html
    _md=$(emit_report)
    if _html=$(printf '%s\n' "$_md" | md_to_html 2>/dev/null) && [[ -n "$_html" ]]; then
        printf '%s\n' "$_html"
    else
        warn "HTML conversion failed (awk) - embedding the Markdown report verbatim"
        printf '<pre class="fallback">\n'
        printf '%s\n' "$_md" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
        printf '</pre>\n'
    fi
    cat <<HTMLFOOT
</main>
</body>
</html>
HTMLFOOT
}

emit_output() {
    if [[ "$OUTPUT_FORMAT" == "html" ]]; then
        emit_html
    else
        emit_report
    fi
}

info "Generating report (${OUTPUT_FORMAT})..."
if [[ -n "$OUTPUT_FILE" ]]; then
    emit_output > "$OUTPUT_FILE"
    info "Report written: $OUTPUT_FILE"
    cat "$OUTPUT_FILE"
else
    emit_output
fi
