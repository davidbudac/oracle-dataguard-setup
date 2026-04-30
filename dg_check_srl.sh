#!/bin/bash
# ============================================================
# Data Guard Standby Redo Log Checker - Standalone
# ============================================================
# On a running Data Guard configuration, verifies that standby
# redo logs (SRLs) are correctly configured on BOTH sides:
#
#   - At least (online_redo_groups + 1) SRL groups per thread
#   - SRL size equal to the largest online redo log
#
# If any side is missing or undersized SRLs, prints the exact
# DDL needed to bring it into compliance. Does NOT execute any
# DDL itself.
#
# Connects locally via 'sqlplus / as sysdba' against $ORACLE_SID.
# Uses the broker-managed peer TNS alias plus Oracle Wallet to
# reach the peer database. Pass -p to prompt for SYS password
# instead, or -L to skip the peer entirely (e.g. when running
# the script separately on each host).
#
# Usage:
#   ./dg_check_srl.sh
#   ./dg_check_srl.sh -p
#   ./dg_check_srl.sh -L
#   ./dg_check_srl.sh -d /u02/oradata/srl
# ============================================================

set -u
set -o pipefail

PEER_MODE="wallet"
SRL_PATH_OVERRIDE=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Checks standby redo logs across the Data Guard configuration that
\$ORACLE_SID belongs to and prints the DDL required to fix any side
that is missing or undersized. Connects locally via
'sqlplus / as sysdba'.

Options:
  -p, --prompt-password   Prompt for SYS password to reach the peer.
                          Default: try Oracle Wallet via TNS alias only.
  -L, --local-only        Skip the peer check entirely.
  -d, --srl-path PATH     Override SRL directory used in generated DDL.
                          Default: re-use the existing SRL or ORL
                          member directory of the side being fixed,
                          or omit the path entirely when OMF is enabled.
  -h, --help              Show this help.

Exit codes:
  0  All checked sides have SRLs at the correct count and size.
  1  At least one side requires DDL.
  2  Argument or pre-flight error.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--prompt-password) PEER_MODE="prompt"; shift ;;
        -L|--local-only)      PEER_MODE="skip";   shift ;;
        -d|--srl-path)        SRL_PATH_OVERRIDE="$2"; shift 2 ;;
        -h|--help)            usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

die()  { echo "ERROR: $*" >&2; exit 2; }
warn() { echo "WARN:  $*" >&2; }
info() { echo "INFO:  $*" >&2; }

[[ -n "${ORACLE_SID:-}" ]]  || die "ORACLE_SID is not set."
[[ -n "${ORACLE_HOME:-}" ]] || die "ORACLE_HOME is not set."
command -v sqlplus >/dev/null || die "sqlplus not on PATH."

# ============================================================
# SQL helper
# ============================================================

run_sql() {
    # $1 = connect string, $2 = SQL text
    local cs="$1" sql="$2"
    sqlplus -s -L "$cs" <<EOF 2>/dev/null
SET HEADING OFF FEEDBACK OFF VERIFY OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
WHENEVER SQLERROR EXIT 1
${sql}
EXIT;
EOF
}

clean() { tr -d ' \r' | sed '/^$/d'; }

# ============================================================
# Local connectivity
# ============================================================

LOCAL_CS="/ as sysdba"
if ! run_sql "$LOCAL_CS" "SELECT 'OK' FROM DUAL;" | clean | grep -q '^OK$'; then
    die "Could not connect via 'sqlplus / as sysdba' (ORACLE_SID=${ORACLE_SID})."
fi

# ============================================================
# gather_side: emit one tab-separated record describing a side.
# Fields:
#   1 DB_UNIQUE_NAME
#   2 DATABASE_ROLE
#   3 MAX_ORL_MB                 (largest online redo log in MB)
#   4 THREAD_DATA                (csv of "tid:orl_cnt:srl_cnt:min_srl_mb")
#   5 MAX_GROUP                  (max(group#) across V$LOG and V$STANDBY_LOG)
#   6 SRL_PATH                   (existing SRL dir, or ORL dir as fallback)
#   7 OMF                        ("YES" if db_create_file_dest is set)
#   8 PEER_DB_UNIQUE_NAME        (from V$DATAGUARD_CONFIG; may be empty)
# ============================================================

gather_side() {
    local cs="$1"
    local du role max_orl threads max_grp omf path peer dbinfo

    dbinfo=$(run_sql "$cs" "SELECT DB_UNIQUE_NAME||'|'||DATABASE_ROLE FROM V\$DATABASE;" | clean | head -1)
    du="${dbinfo%%|*}"
    role="${dbinfo#*|}"

    max_orl=$(run_sql "$cs" "SELECT NVL(MAX(BYTES)/1024/1024,0) FROM V\$LOG;" | clean | head -1)
    max_grp=$(run_sql "$cs" "SELECT NVL(MAX(GROUP#),0) FROM (SELECT GROUP# FROM V\$LOG UNION ALL SELECT GROUP# FROM V\$STANDBY_LOG);" | clean | head -1)

    threads=$(run_sql "$cs" "
SELECT t.thread#||':'||
       (SELECT COUNT(DISTINCT GROUP#) FROM V\$LOG WHERE THREAD#=t.thread#)||':'||
       NVL((SELECT COUNT(DISTINCT GROUP#) FROM V\$STANDBY_LOG WHERE THREAD#=t.thread#),0)||':'||
       NVL((SELECT MIN(BYTES)/1024/1024 FROM V\$STANDBY_LOG WHERE THREAD#=t.thread#),0)
FROM V\$THREAD t
WHERE t.ENABLED IN ('PUBLIC','PRIVATE')
ORDER BY t.thread#;
" | clean | tr '\n' ',' | sed 's/,$//')

    omf=$(run_sql "$cs" "SELECT CASE WHEN VALUE IS NULL OR VALUE='' THEN 'NO' ELSE 'YES' END FROM V\$PARAMETER WHERE NAME='db_create_file_dest';" | clean | head -1)
    omf="${omf:-NO}"

    path=$(run_sql "$cs" "
SELECT SUBSTR(MEMBER,1,INSTR(MEMBER,'/',-1))
FROM V\$LOGFILE
WHERE TYPE='STANDBY' AND ROWNUM=1;
" | clean | head -1)
    if [[ -z "$path" ]]; then
        path=$(run_sql "$cs" "
SELECT SUBSTR(MEMBER,1,INSTR(MEMBER,'/',-1))
FROM V\$LOGFILE
WHERE TYPE='ONLINE' AND ROWNUM=1;
" | clean | head -1)
    fi

    peer=$(run_sql "$cs" "SELECT DB_UNIQUE_NAME FROM V\$DATAGUARD_CONFIG WHERE DB_UNIQUE_NAME <> '${du}' AND ROWNUM=1;" | clean | head -1)

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$du" "$role" "${max_orl:-0}" "$threads" "${max_grp:-0}" "$path" "$omf" "$peer"
}

# ============================================================
# emit_side: print summary + DDL for one side. Returns 0 if no
# fix needed, 1 if DDL was emitted (missing or size mismatch).
#
# Args: du role max_orl threads max_grp path omf
# ============================================================

emit_side() {
    local du="$1" role="$2" max_orl="$3" threads="$4" max_grp="$5" path="$6" omf="$7"
    local needs_fix="no" any_size_mismatch="no"
    local ddl_lines=""
    local next_grp=$((max_grp + 1))

    local target_path="$path"
    [[ -n "$SRL_PATH_OVERRIDE" ]] && target_path="$SRL_PATH_OVERRIDE"
    [[ -n "$target_path" && "$target_path" != */ ]] && target_path="${target_path}/"

    echo ""
    echo "============================================================"
    echo " ${du} (${role})"
    echo "============================================================"
    echo "  Max online redo log size : ${max_orl} MB"
    echo "  OMF (db_create_file_dest): ${omf}"
    echo "  SRL/ORL member directory : ${path:-<none>}"
    if [[ -n "$SRL_PATH_OVERRIDE" ]]; then
        echo "  Target dir for new SRLs  : ${target_path} (overridden)"
    fi
    echo ""
    printf "  %-8s %-12s %-12s %-15s %-12s\n" "Thread" "ORL_groups" "SRL_groups" "Required_SRL" "Min_SRL_MB"
    printf "  %-8s %-12s %-12s %-15s %-12s\n" "------" "----------" "----------" "------------" "----------"

    local max_orl_int="${max_orl%.*}"

    while IFS=':' read -r tid orl_cnt srl_cnt min_mb; do
        [[ -z "$tid" ]] && continue
        local required=$((orl_cnt + 1))
        local deficit=$((required - srl_cnt))
        printf "  %-8s %-12s %-12s %-15s %-12s\n" \
            "$tid" "$orl_cnt" "$srl_cnt" "$required" "${min_mb%.*}"

        if [[ "$srl_cnt" -gt 0 ]]; then
            local min_mb_int="${min_mb%.*}"
            if [[ "${min_mb_int:-0}" -ne "${max_orl_int:-0}" ]]; then
                any_size_mismatch="yes"
                needs_fix="yes"
            fi
        fi

        if [[ "$deficit" -gt 0 ]]; then
            needs_fix="yes"
            local i=0
            while [[ $i -lt $deficit ]]; do
                if [[ "$omf" == "YES" ]]; then
                    ddl_lines+=$'\n'"ALTER DATABASE ADD STANDBY LOGFILE THREAD ${tid} GROUP ${next_grp} SIZE ${max_orl_int}M;"
                else
                    ddl_lines+=$'\n'"ALTER DATABASE ADD STANDBY LOGFILE THREAD ${tid} GROUP ${next_grp} ('${target_path}standby_redo${next_grp}.log') SIZE ${max_orl_int}M;"
                fi
                next_grp=$((next_grp + 1))
                i=$((i + 1))
            done
        fi
    done < <(echo "$threads" | tr ',' '\n')

    echo ""
    if [[ "$needs_fix" == "no" ]]; then
        echo "  Result: OK - all threads have at least N+1 SRLs at ${max_orl_int} MB."
        return 0
    fi

    echo "  Result: ACTION REQUIRED"

    if [[ "$any_size_mismatch" == "yes" ]]; then
        echo ""
        echo "  WARNING: At least one existing SRL group is not ${max_orl_int} MB."
        echo "  Undersized SRLs are skipped by transport. List them with:"
        echo ""
        echo "    SELECT GROUP#, THREAD#, BYTES/1024/1024 MB, STATUS"
        echo "      FROM V\$STANDBY_LOG WHERE BYTES/1024/1024 <> ${max_orl_int};"
        echo ""
        echo "  Then drop and recreate each at the correct size (the group must"
        echo "  not be CURRENT or ACTIVE; on a standby, stop apply first):"
        echo ""
        echo "    ALTER DATABASE DROP STANDBY LOGFILE GROUP <n>;"
        if [[ "$omf" == "YES" ]]; then
            echo "    ALTER DATABASE ADD STANDBY LOGFILE THREAD <t> GROUP <n> SIZE ${max_orl_int}M;"
        else
            echo "    ALTER DATABASE ADD STANDBY LOGFILE THREAD <t> GROUP <n> ('${target_path}standby_redo<n>.log') SIZE ${max_orl_int}M;"
        fi
    fi

    if [[ -n "$ddl_lines" ]]; then
        echo ""
        echo "  DDL to add the missing SRLs (run as SYSDBA on ${du}):"
        echo ""
        echo "    -- e.g. sqlplus / as sysdba   (on the host where ORACLE_SID=${du})"
        echo "    -- or   sqlplus /@${du} as sysdba"
        echo ""
        local line
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            echo "    $line"
        done <<<"$ddl_lines"
    fi
    return 1
}

# ============================================================
# Run for local
# ============================================================

info "Checking local side (ORACLE_SID=${ORACLE_SID})..."

LOCAL_REC=$(gather_side "$LOCAL_CS")
IFS=$'\t' read -r LOCAL_DU LOCAL_ROLE LOCAL_MAX_ORL LOCAL_THREADS LOCAL_MAX_GRP LOCAL_PATH LOCAL_OMF LOCAL_PEER <<<"$LOCAL_REC"

[[ -n "$LOCAL_DU" ]] || die "Could not read local DB_UNIQUE_NAME."

# ============================================================
# Try peer
# ============================================================

PEER_REACHED="no"
PEER_DU=""
PEER_ROLE=""
PEER_FIX_RC=0

if [[ "$PEER_MODE" != "skip" && -n "$LOCAL_PEER" ]]; then
    peer_alias="$LOCAL_PEER"
    case "$PEER_MODE" in
        wallet)
            PEER_CS="/@${peer_alias} as sysdba"
            ;;
        prompt)
            stty -echo 2>/dev/null || true
            printf "Enter SYS password for %s: " "$peer_alias" >&2
            read PEER_PWD
            stty echo 2>/dev/null || true
            printf "\n" >&2
            PEER_CS="sys/${PEER_PWD}@${peer_alias} as sysdba"
            ;;
    esac

    if run_sql "$PEER_CS" "SELECT 'OK' FROM DUAL;" | clean | grep -q '^OK$'; then
        PEER_REACHED="yes"
        info "Connected to peer ${peer_alias}."
        PEER_REC=$(gather_side "$PEER_CS")
        IFS=$'\t' read -r PEER_DU PEER_ROLE PEER_MAX_ORL PEER_THREADS PEER_MAX_GRP PEER_PATH PEER_OMF PEER_PEER <<<"$PEER_REC"
    else
        case "$PEER_MODE" in
            wallet) warn "Could not reach peer '${peer_alias}' via wallet. Use -p for password prompt or -L to skip; or run this script on the peer host." ;;
            prompt) warn "Could not reach peer '${peer_alias}' with the provided password." ;;
        esac
    fi
elif [[ -z "$LOCAL_PEER" ]]; then
    warn "No peer found in V\$DATAGUARD_CONFIG. Reporting on local only."
fi

# ============================================================
# Output
# ============================================================

LOCAL_FIX_RC=0
emit_side "$LOCAL_DU" "$LOCAL_ROLE" "$LOCAL_MAX_ORL" "$LOCAL_THREADS" "$LOCAL_MAX_GRP" "$LOCAL_PATH" "$LOCAL_OMF" || LOCAL_FIX_RC=$?

if [[ "$PEER_REACHED" == "yes" ]]; then
    PEER_FIX_RC=0
    emit_side "$PEER_DU" "$PEER_ROLE" "$PEER_MAX_ORL" "$PEER_THREADS" "$PEER_MAX_GRP" "$PEER_PATH" "$PEER_OMF" || PEER_FIX_RC=$?
fi

echo ""
echo "============================================================"
echo " Summary"
echo "============================================================"
printf "  %-30s %s\n" "${LOCAL_DU} (${LOCAL_ROLE})" \
    "$([[ $LOCAL_FIX_RC -eq 0 ]] && echo OK || echo 'ACTION REQUIRED')"

if [[ "$PEER_REACHED" == "yes" ]]; then
    printf "  %-30s %s\n" "${PEER_DU} (${PEER_ROLE})" \
        "$([[ $PEER_FIX_RC -eq 0 ]] && echo OK || echo 'ACTION REQUIRED')"
elif [[ "$PEER_MODE" != "skip" && -n "$LOCAL_PEER" ]]; then
    printf "  %-30s %s\n" "${LOCAL_PEER} (peer)" "UNCHECKED"
fi

EXIT_CODE=0
[[ $LOCAL_FIX_RC -ne 0 ]] && EXIT_CODE=1
[[ $PEER_FIX_RC  -ne 0 ]] && EXIT_CODE=1
exit $EXIT_CODE
