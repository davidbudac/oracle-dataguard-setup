#!/usr/bin/env bash
# =============================================================================
# Shared rendering / color / threshold helpers for the Data Guard status
# tooling: dg_status.sh (SSH/jump-host dashboard) and
# common/dg_local_status_common.sh (local dg_triage_sid.sh / dg_diag_sid.sh).
#
# This file holds ONLY pure, side-effect-free (beyond color/layout init)
# shared pieces:
#   - TTY/NO_COLOR-aware color initialization (WS4.2)
#   - configurable thresholds + Data Guard lag parsing (WS4.3)
#   - generic text/box rendering primitives (WS4.4)
#   - the awk log-filter program text shared between local execution and
#     dg_status.sh's SSH-embedded remote commands (WS4.4)
#   - SQL SELECT fragments confirmed byte-identical across call sites (WS4.4)
# =============================================================================

if [[ -n "${DG_RENDER_COMMON_SH_LOADED:-}" ]]; then
    return 0
fi
DG_RENDER_COMMON_SH_LOADED=1

# -----------------------------------------------------------------------
# Colors (WS4.2)
# -----------------------------------------------------------------------
# TTY-aware: colors are enabled only when stdout is a terminal AND NO_COLOR
# is unset/empty (see https://no-color.org). Called once, unconditionally,
# below so color vars are always sane immediately after sourcing - even for
# callers that never parse a --no-color flag of their own. Callers that DO
# expose --no-color should re-invoke `dg_render_init_colors 1` right after
# parsing args and BEFORE producing any output, to force colors off
# regardless of TTY state.
dg_render_init_colors() {
    local force_off="${1:-0}"
    if [[ "$force_off" == "1" ]] || [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
        RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
    else
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        CYAN='\033[0;36m'
        BOLD='\033[1m'
        DIM='\033[2m'
        NC='\033[0m'
    fi
    CHK="${GREEN}OK${NC}"
    WARN="${YELLOW}!!${NC}"
    FAIL="${RED}XX${NC}"
}
dg_render_init_colors

# -----------------------------------------------------------------------
# Layout
# -----------------------------------------------------------------------
if command -v tput >/dev/null 2>&1; then
    TERM_WIDTH=$(tput cols 2>/dev/null || printf '100')
else
    TERM_WIDTH=100
fi
[[ "$TERM_WIDTH" =~ ^[0-9]+$ ]] || TERM_WIDTH=100
(( TERM_WIDTH < 80 )) && TERM_WIDTH=80

LABEL_W=24
STATUS_W=4
ROW_VALUE_W=$((TERM_WIDTH - LABEL_W - STATUS_W - 6))
(( ROW_VALUE_W < 28 )) && ROW_VALUE_W=28

HLINE=$(printf '%*s' $((TERM_WIDTH - 2)) '')
HLINE=${HLINE// /─}

# -----------------------------------------------------------------------
# Configurable thresholds (WS4.3)
# -----------------------------------------------------------------------
# `: "${VAR:=default}"` only assigns when VAR is unset or empty, so an
# operator can override any of these by exporting them before running
# dg_status.sh / dg_triage_sid.sh / dg_diag_sid.sh, e.g.:
#   DG_FRA_WARN_PCT=70 DG_LAG_WARN_SECONDS=30 bash dg_status.sh
: "${DG_FRA_WARN_PCT:=80}"
: "${DG_FRA_CRIT_PCT:=90}"
: "${DG_SEQ_GAP_WARN:=1}"
: "${DG_SEQ_GAP_CRIT:=5}"
: "${DG_LAG_WARN_SECONDS:=60}"

# -----------------------------------------------------------------------
# Data Guard lag parsing (WS4.3)
# -----------------------------------------------------------------------
# V$DATAGUARD_STATS.VALUE for 'transport lag' / 'apply lag' is an
# INTERVAL DAY TO SECOND rendered by Oracle as "+DD HH:MI:SS[.FF]" (e.g.
# "+00 00:01:23" or "+01 03:00:00.500"). A bare "+HH:MI:SS" (no day field)
# is also accepted for robustness in case a caller feeds a differently
# formatted value. Prints the total whole seconds represented; empty/"0"/
# "NONE" values print 0.
dg_parse_lag_seconds() {
    local value="${1:-}" days hms h m s
    if [[ -z "$value" ]]; then
        printf '0'
        return 0
    fi
    case "$value" in
        0|NONE|none)
            printf '0'
            return 0
            ;;
    esac
    # Strip leading sign (+ is normal; - would mean clock skew, treat the
    # same way - magnitude is what matters for a warn/ok decision).
    value="${value#[+-]}"
    if [[ "$value" == *' '* ]]; then
        days="${value%% *}"
        hms="${value#* }"
    else
        days=0
        hms="$value"
    fi
    # Drop fractional seconds, if any.
    hms="${hms%%.*}"
    IFS=':' read -r h m s <<< "$hms"
    # Force base-10 interpretation so a leading zero (e.g. "08") is never
    # mistaken for an invalid octal literal.
    days=$((10#${days:-0}))
    h=$((10#${h:-0}))
    m=$((10#${m:-0}))
    s=$((10#${s:-0}))
    printf '%d' $(( days * 86400 + h * 3600 + m * 60 + s ))
}

# Display helper: collapse a lag value to "none" only when it truly parses
# to zero seconds; otherwise show the raw value as reported by Oracle.
dg_display_lag_value() {
    local value="${1:-}"
    if [[ -z "$value" ]]; then
        printf ''
        return
    fi
    if [[ "$(dg_parse_lag_seconds "$value")" == "0" ]]; then
        printf 'none'
    else
        printf '%s' "$value"
    fi
}

# -----------------------------------------------------------------------
# Threshold-based severity icons (WS4.3)
# -----------------------------------------------------------------------
# These read CHK/WARN/FAIL, which dg_render_init_colors sets.
dg_fra_icon() {
    local pct="${1:-0}"
    if [[ "$pct" -ge "$DG_FRA_CRIT_PCT" ]]; then
        printf '%b' "$FAIL"
    elif [[ "$pct" -ge "$DG_FRA_WARN_PCT" ]]; then
        printf '%b' "$WARN"
    else
        printf '%b' "$CHK"
    fi
}

dg_seq_gap_icon() {
    local gap="${1:-0}"
    if (( gap > DG_SEQ_GAP_CRIT )); then
        printf '%b' "$FAIL"
    elif (( gap > DG_SEQ_GAP_WARN )); then
        printf '%b' "$WARN"
    else
        printf '%b' "$CHK"
    fi
}

dg_lag_icon() {
    local secs
    secs=$(dg_parse_lag_seconds "${1:-}")
    if (( secs > DG_LAG_WARN_SECONDS )); then
        printf '%b' "$WARN"
    else
        printf '%b' "$CHK"
    fi
}

# -----------------------------------------------------------------------
# Generic text / rendering primitives (WS4.4)
# -----------------------------------------------------------------------
repeat_char() {
    local char="$1" count="$2" out=""
    while (( count > 0 )); do
        out="${out}${char}"
        count=$((count - 1))
    done
    printf '%s' "$out"
}

strip_ansi() {
    printf '%b' "$1" | sed $'s/\033\\[[0-9;]*m//g'
}

fit_text() {
    local text="$1" width="$2" plain
    plain=$(strip_ansi "$text")
    if [[ ${#plain} -le $width ]]; then
        printf '%s' "$text"
    elif (( width > 3 )); then
        printf '%s...' "${plain:0:$((width - 3))}"
    else
        printf '%s' "${plain:0:$width}"
    fi
}

wrap_text() {
    local text="$1" width="$2"
    # [[:space:]][[:space:]]* not [[:space:]]\+ : \+ is a GNU BRE extension,
    # AIX 7.2 /usr/bin/sed matches a literal '+' instead (runs of blanks then
    # survive into the rendered table and break the column alignment).
    text=$(printf '%s' "$text" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
    [[ -z "$text" ]] && text="-"
    printf '%s\n' "$text" | fold -s -w "$width"
}

row() {
    local label="$1" value="$2" status="${3:-}"
    local first=true line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if $first; then
            printf "  ${DIM}%-*s${NC} %-*s %b\n" "$LABEL_W" "$label" "$ROW_VALUE_W" "$line" "$status"
            first=false
        else
            printf "  ${DIM}%-*s${NC} %-*s\n" "$LABEL_W" "" "$ROW_VALUE_W" "$line"
        fi
    done < <(wrap_text "$value" "$ROW_VALUE_W")
}

header() {
    printf "\n ${BOLD}${BLUE}%s${NC}\n" "$1"
    printf " ${DIM}%s${NC}\n" "$HLINE"
}

subheader() {
    printf " ${BOLD}${CYAN}%s${NC}\n" "$1"
}

short_hostname() {
    local host
    host=$(hostname 2>/dev/null || uname -n 2>/dev/null || printf 'unknown')
    printf '%s' "${host%%.*}"
}

extract_first_status() {
    awk '
        match($0, /(SUCCESS|WARNING|ERROR)/) {
            print substr($0, RSTART, RLENGTH)
            exit
        }
    '
}

status_icon() {
    local value="$1"
    shift
    local pattern
    for pattern in "$@"; do
        if printf '%s' "$value" | grep -qi "$pattern"; then
            printf '%b' "$CHK"
            return
        fi
    done
    printf '%b' "$FAIL"
}

warn_icon() {
    local value="$1"
    shift
    local pattern
    for pattern in "$@"; do
        if printf '%s' "$value" | grep -qi "$pattern"; then
            printf '%b' "$CHK"
            return
        fi
    done
    printf '%b' "$WARN"
}

# -----------------------------------------------------------------------
# DGMGRL "SHOW CONFIGURATION" line classification (M20)
# -----------------------------------------------------------------------
# 19c does NOT put a member's diagnosis on the member line. It prints:
#
#     cdb1      - Primary database
#       Error: ORA-16810: multiple errors or warnings detected for the member
#
#       cdb1_stby - Physical standby database
#         Error: ORA-12154: TNS:could not resolve the connect identifier
#
# so a grep for Error/Warning *on the member line* can never fire. Callers
# iterate the output, remember the last member line seen, and attribute any
# following Error:/Warning: line to it. These helpers are shared by
# dg_status.sh and dg_local_status_common.sh so both tools agree on what
# counts as a member issue.
dg_is_broker_member_line() {
    # Takes the RAW (untrimmed) line - the leading indent is part of the
    # shape that distinguishes a member line from the "Configuration - x"
    # header.
    printf '%s' "$1" | grep -qE '^[[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+'
}

dg_broker_member_name() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*-[[:space:]].*$//'
}

# Prints "error", "warning", or nothing at all for a diagnosis line.
# "Error: 0" / ORA-00000 is DGMGRL's *healthy* value and is deliberately
# not treated as a finding (same exclusion dgmgrl_output_has_error makes).
dg_broker_diagnosis_severity() {
    local trimmed
    trimmed=$(printf '%s' "$1" | sed 's/^[[:space:]]*//')
    case "$trimmed" in
        Error:*|error:*|ERROR:*)
            if printf '%s' "$trimmed" | grep -qiE '^error:[[:space:]]*(0|ORA-00000)[[:space:]]*$'; then
                return 0
            fi
            printf 'error'
            ;;
        Warning:*|warning:*|WARNING:*)
            printf 'warning'
            ;;
    esac
}

# The diagnosis text with the "Error:"/"Warning:" prefix and indent removed.
dg_broker_diagnosis_text() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/^[Ee][Rr][Rr][Oo][Rr]:[[:space:]]*//; s/^[Ww][Aa][Rr][Nn][Ii][Nn][Gg]:[[:space:]]*//'
}

# Worst severity attached to one member across the whole SHOW CONFIGURATION
# output: "error", "warning", or nothing. Lets a renderer put the right icon
# on the member line itself, instead of a green OK immediately above the
# member's own "Error: ORA-16810" line.
# Usage: dg_broker_member_severity "$DGMGRL_CONFIG" "cdb1"
dg_broker_member_severity() {
    local config="$1" member="$2"
    local line current="" sev result=""
    while IFS= read -r line; do
        if dg_is_broker_member_line "$line"; then
            current=$(dg_broker_member_name "$line")
            continue
        fi
        [[ "$current" != "$member" ]] && continue
        sev=$(dg_broker_diagnosis_severity "$line")
        if [[ "$sev" == "error" ]]; then
            printf 'error'
            return
        elif [[ "$sev" == "warning" ]]; then
            result="warning"
        fi
    done <<< "$config"
    printf '%s' "$result"
}

format_services() {
    local input="$1" formatted
    formatted=$(printf '%s\n' "$input" | sed '/^$/d' | awk 'BEGIN{ORS=""} {if (NR>1) printf ", "; printf "%s", $0}')
    if [[ -n "$formatted" ]]; then
        printf '%s' "$formatted"
    else
        printf 'NONE'
    fi
}

compute_fra_pct() {
    local size="$1" used="$2" reclaim="$3"
    awk "BEGIN {if (${size:-0} > 0) {effective=${used:-0}-${reclaim:-0}; if (effective < 0) effective=0; printf \"%.0f\", (effective/${size})*100} else print 0}"
}

compute_fra_effective() {
    local used="$1" reclaim="$2"
    awk "BEGIN {effective=${used:-0}-${reclaim:-0}; if (effective < 0) effective=0; printf \"%.1f\", effective}"
}

# -----------------------------------------------------------------------
# Shared log-filter awk programs (WS4.4)
# -----------------------------------------------------------------------
# Identical pattern text used both by dg_local_status_common.sh's local
# collect_log_matches (invoked directly as `awk "$DG_ALERT_LOG_AWK_FILTER"`,
# a normal local process argument) and by dg_status.sh's four SSH-embedded
# remote commands, where the constant is interpolated inside a
# single-quoted `awk '...'` segment of a larger double-quoted string built
# locally and sent to the remote host as one ssh command argument.
#
# This is safe because bash parameter expansion is single-pass:
# substituting ${DG_ALERT_LOG_AWK_FILTER} inside a double-quoted string
# inserts its literal text (including literal $0/$1/" characters) without
# re-triggering local expansion or quote processing. The surrounding single
# quotes - written directly in the caller's own source around the
# ${...} reference - protect those characters from the REMOTE shell exactly
# as if the awk program had been typed there directly, so the remote-side
# behavior is byte-for-byte the same as the original inline literal. This
# was verified experimentally (constructed-string diff + a live `awk` run
# through an extra `bash -c` hop) before adopting the pattern; see WS4.4
# notes in the implementation report for details.
DG_ALERT_LOG_AWK_FILTER=$(cat <<'AWKEOF'
/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ { ts = substr($0, 1, 19); gsub(/T/, " ", ts); next }
{ low = tolower($0) }
low ~ /ora-16[0-9][0-9][0-9]|ora-01034|ora-03113|ora-12541|switchover|failover|data guard|mrp0|fal\[|rfs\[|lns[0-9]|broker|dgmgrl|role.change|arch.*gap|apply_lag|transport_lag|unsynchronized|synchronized|maximum availability|maximum performance|maximum protection|redo transport|log shipping|media recovery|recovery stopped|recovery paused|catching up|incomplete/ {
    if (ts != "") printf "%s  %s\n", ts, $0; else print $0
}
AWKEOF
)

DG_BROKER_LOG_AWK_FILTER=$(cat <<'AWKEOF'
/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ { ts = substr($0, 1, 19); gsub(/T/, " ", ts); next }
{ low = tolower($0) }
low ~ /ora-|error|warning|fail|switchover|failover|role change|fsfo|reinstate|disable|enable|nsv|broker/ {
    if (ts != "") printf "%s  %s\n", ts, $0; else print $0
}
AWKEOF
)

# -----------------------------------------------------------------------
# Shared SQL SELECT fragments (WS4.4)
# -----------------------------------------------------------------------
# Only fragments confirmed byte-identical (same columns, same view, same
# filter, same literal text) across ALL of their call sites are centralized
# here. One superficially-similar query was checked line-by-line and found
# to genuinely differ - it is deliberately left duplicated in dg_status.sh /
# dg_local_status_common.sh rather than force-merged:
#
#   - ARCHDEST: dg_status.sh's primary query selects
#     DEST_ID|STATUS|ERROR (3 fields); dg_local_status_common.sh's
#     collect_local_sql also selects DB_UNIQUE_NAME (4 fields) so it can
#     flag a dest pointed at the wrong peer (PRI_DEST2_DBUNIQ check).
#   - The 5-field standby DBSTATUS query in dg_status.sh's STANDBY block
#     (DATABASE_ROLE|OPEN_MODE|PROTECTION_MODE|SWITCHOVER_STATUS|
#     DB_UNIQUE_NAME, no FORCE_LOGGING/FLASHBACK_ON) is a distinct shape
#     from DG_SQL_SELECT_DBSTATUS_FULL below and is left as literal text.
#
# DGSTATS (transport/apply lag + apply finish time) IS byte-identical
# everywhere it's queried (dg_status.sh fetches 'apply finish time' too,
# even though it does not currently display it), so it is centralized below
# as DG_SQL_SELECT_DGSTATS.
DG_SQL_SELECT_DBSTATUS_FULL="SELECT 'DBSTATUS|' || DATABASE_ROLE || '|' || OPEN_MODE || '|' || PROTECTION_MODE || '|' || SWITCHOVER_STATUS || '|' || FORCE_LOGGING || '|' || FLASHBACK_ON || '|' || DB_UNIQUE_NAME FROM V\$DATABASE;"
DG_SQL_SELECT_DGPARAMS="SELECT 'DGPARAMS|' || NAME || '|' || VALUE FROM V\$PARAMETER WHERE NAME IN ('dg_broker_start') ORDER BY NAME;"
DG_SQL_SELECT_REDOLOG="SELECT 'REDOLOG|' || COUNT(*) || '|' || ROUND(SUM(BYTES)/1024/1024) FROM V\$LOG;"
DG_SQL_SELECT_SRLCOUNT="SELECT 'SRLCOUNT|' || COUNT(*) FROM V\$STANDBY_LOG;"
DG_SQL_SELECT_ARCHGAP="SELECT 'ARCHGAP|' || COUNT(*) FROM V\$ARCHIVE_GAP;"
DG_SQL_SELECT_FSFODB="SELECT 'FSFODB|' || FS_FAILOVER_STATUS || '|' || FS_FAILOVER_OBSERVER_PRESENT || '|' || FS_FAILOVER_OBSERVER_HOST FROM V\$DATABASE;"
DG_SQL_SELECT_FRA="SELECT 'FRA|' || NAME || '|' || ROUND(SPACE_LIMIT/1024/1024/1024,1) || '|' || ROUND(SPACE_USED/1024/1024/1024,1) || '|' || ROUND(SPACE_RECLAIMABLE/1024/1024/1024,1) || '|' || NUMBER_OF_FILES FROM V\$RECOVERY_FILE_DEST;"
DG_SQL_SELECT_SERVICE="SELECT 'SERVICE|' || NAME
  FROM (
    SELECT NAME
      FROM V\$ACTIVE_SERVICES
     WHERE NAME NOT LIKE 'SYS\$%'
       AND UPPER(NAME) NOT LIKE '%XDB%'
     ORDER BY NAME
  );"
DG_SQL_SELECT_MRP="SELECT 'MRP|' || PROCESS || '|' || STATUS || '|' || SEQUENCE# FROM V\$MANAGED_STANDBY WHERE PROCESS = 'MRP0';"
DG_SQL_SELECT_DGSTATS="SELECT 'DGSTATS|' || NAME || '|' || VALUE FROM V\$DATAGUARD_STATS WHERE NAME IN ('transport lag','apply lag','apply finish time');"
DG_SQL_SELECT_APPLYINFO="SELECT 'APPLYINFO|' || NVL(MAX(CASE WHEN APPLIED='YES' THEN SEQUENCE# END),0) || '|' || NVL(MAX(SEQUENCE#),0) FROM V\$ARCHIVED_LOG WHERE THREAD#=1;"
DG_SQL_SELECT_RECMODE="SELECT 'RECMODE|' || RECOVERY_MODE FROM V\$ARCHIVE_DEST_STATUS WHERE TYPE = 'LOCAL' AND STATUS = 'VALID' AND ROWNUM = 1;"
