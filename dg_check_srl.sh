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
# Thread accounting: an SRL added without a THREAD clause (which is what
# this repo's step 4 / sql/commands/add_standby_logfile.sql did before
# 2026-08; both now assign THREAD explicitly) sits at THREAD#=0 until
# Oracle assigns it on first use. Those unassigned groups
# are counted here as a pool that satisfies the per-thread requirement -
# on a single-thread database N+1 unassigned SRLs of the right size are
# COMPLIANT. On a multi-thread (RAC) database the pool is shared and is
# counted toward every thread's requirement, which is flagged in the output
# because Oracle will hand each group to whichever thread claims it first.
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
  1  At least one side requires DDL, or a peer exists but was not checked.
  2  Argument, pre-flight, or data error (nothing was verified).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--prompt-password) PEER_MODE="prompt"; shift ;;
        -L|--local-only)      PEER_MODE="skip";   shift ;;
        -d|--srl-path)
            # L1/L2: without this guard, `set -u` turns a missing argument
            # into a bare "$2: unbound variable" abort with exit 1 - the
            # code that means "DDL needed" to a monitoring wrapper.
            if [[ $# -lt 2 ]]; then
                echo "ERROR: $1 requires a directory argument" >&2
                usage >&2
                exit 2
            fi
            SRL_PATH_OVERRIDE="$2"; shift 2 ;;
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
    # CONNECT on stdin (sqlplus -s /nolog) instead of on the sqlplus command
    # line, so a password-bearing connect string ("sys/pw@alias as sysdba")
    # never appears in `ps -ef` output. -L avoids reconnect prompts.
    # Do not discard stderr: WHENEVER SQLERROR EXIT 1 keeps it silent when
    # healthy, so any connection/ORA- error is surfaced rather than swallowed.
    sqlplus -s -L /nolog <<EOF
SET HEADING OFF FEEDBACK OFF VERIFY OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
WHENEVER SQLERROR EXIT 1
CONNECT ${cs}
${sql}
EXIT;
EOF
}

# Numeric / token fields. NOTE the \t: with a large LINESIZE, sqlplus pads
# NUMBER output with TAB characters ("\t\t\t 50"), not just spaces. The old
# `tr -d ' \r'` left those in, so every numeric field failed its
# `*[!0-9]*` guard and silently became 0 - which is how "SIZE 0M" DDL and
# "at least one existing SRL group is not 0 MB" got printed against a
# perfectly healthy database (verified live on cdb1).
clean() { tr -d ' \t\r' | sed '/^$/d'; }

# Text fields (identifiers, roles, paths): trim the ends only, so
# "PHYSICAL STANDBY" keeps its space and a path is not corrupted.
trim() { sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d'; }

# ============================================================
# Local connectivity
# ============================================================

LOCAL_CS="/ as sysdba"
if ! run_sql "$LOCAL_CS" "SELECT 'OK' FROM DUAL;" | clean | grep -q '^OK$'; then
    die "Could not connect via 'sqlplus / as sysdba' (ORACLE_SID=${ORACLE_SID})."
fi

# ============================================================
# gather_side: emit one '|'-separated record describing a side.
#
# M21: the separator used to be a TAB and the reader used
# `IFS=$'\t' read`. TAB is IFS *whitespace*, so bash collapses runs of it -
# one empty field (a failed thread query, a database with no SRL directory)
# shifted every later field left, silently skipping the peer check and
# producing DDL like ('NOstandby_redo8.log') SIZE 0M. '|' is not IFS
# whitespace, so adjacent delimiters keep producing empty fields.
# Oracle identifiers, roles and file paths cannot contain '|'.
#
# Fields:
#   1  DB_UNIQUE_NAME
#   2  DATABASE_ROLE
#   3  MAX_ORL_MB                (largest online redo log in MB)
#   4  THREAD_DATA               (csv of "tid:orl_cnt:srl_cnt:min_srl_mb",
#                                 counting only SRLs already bound to that
#                                 thread)
#   5  MAX_GROUP                 (max(group#) across V$LOG and V$STANDBY_LOG)
#   6  SRL_PATH                  (existing SRL dir, or ORL dir as fallback)
#   7  OMF                       ("YES" if db_create_file_dest is set)
#   8  PEER_DB_UNIQUE_NAME       (from V$DATAGUARD_CONFIG; may be empty)
#   9  UNASSIGNED_SRL_CNT        (H11: SRL groups still at THREAD#=0)
#  10  UNASSIGNED_SRL_MIN_MB     (smallest of those, 0 when none)
# ============================================================

gather_side() {
    local cs="$1"
    local du role max_orl threads max_grp omf path peer dbinfo unassigned

    # '~' as the intra-query separator so the record separator ('|') stays
    # unambiguous even if this string is ever logged or re-parsed.
    dbinfo=$(run_sql "$cs" "SELECT DB_UNIQUE_NAME||'~'||DATABASE_ROLE FROM V\$DATABASE;" | trim | head -1)
    du="${dbinfo%%~*}"
    role="${dbinfo#*~}"
    [[ "$role" == "$du" ]] && role=""

    max_orl=$(run_sql "$cs" "SELECT NVL(MAX(BYTES)/1024/1024,0) FROM V\$LOG;" | clean | head -1)
    max_grp=$(run_sql "$cs" "SELECT NVL(MAX(GROUP#),0) FROM (SELECT GROUP# FROM V\$LOG UNION ALL SELECT GROUP# FROM V\$STANDBY_LOG);" | clean | head -1)

    # Per-thread counts deliberately match only SRLs already bound to the
    # thread; the THREAD#=0 pool is gathered separately below (H11) so the
    # caller can decide how to attribute it.
    threads=$(run_sql "$cs" "
SELECT t.thread#||':'||
       (SELECT COUNT(DISTINCT GROUP#) FROM V\$LOG WHERE THREAD#=t.thread#)||':'||
       NVL((SELECT COUNT(DISTINCT GROUP#) FROM V\$STANDBY_LOG WHERE THREAD#=t.thread#),0)||':'||
       NVL((SELECT MIN(BYTES)/1024/1024 FROM V\$STANDBY_LOG WHERE THREAD#=t.thread#),0)
FROM V\$THREAD t
WHERE t.ENABLED IN ('PUBLIC','PRIVATE')
ORDER BY t.thread#;
" | clean | tr '\n' ',' | sed 's/,$//')

    # H11: SRLs created without a THREAD clause report THREAD#=0 until
    # Oracle assigns them on first use. Counting them per-thread returned 0
    # and produced "ACTION REQUIRED" plus duplicate-SRL DDL on a database
    # that was in fact compliant.
    unassigned=$(run_sql "$cs" "
SELECT COUNT(DISTINCT GROUP#)||':'||NVL(MIN(BYTES)/1024/1024,0)
FROM V\$STANDBY_LOG
WHERE NVL(THREAD#,0)=0;
" | clean | head -1)
    case "$unassigned" in ''|*[!0-9:.]*) unassigned="0:0" ;; esac

    omf=$(run_sql "$cs" "SELECT CASE WHEN VALUE IS NULL OR VALUE='' THEN 'NO' ELSE 'YES' END FROM V\$PARAMETER WHERE NAME='db_create_file_dest';" | clean | head -1)
    omf="${omf:-NO}"

    path=$(run_sql "$cs" "
SELECT SUBSTR(MEMBER,1,INSTR(MEMBER,'/',-1))
FROM V\$LOGFILE
WHERE TYPE='STANDBY' AND ROWNUM=1;
" | trim | head -1)
    if [[ -z "$path" ]]; then
        path=$(run_sql "$cs" "
SELECT SUBSTR(MEMBER,1,INSTR(MEMBER,'/',-1))
FROM V\$LOGFILE
WHERE TYPE='ONLINE' AND ROWNUM=1;
" | trim | head -1)
    fi

    peer=$(run_sql "$cs" "SELECT DB_UNIQUE_NAME FROM V\$DATAGUARD_CONFIG WHERE DB_UNIQUE_NAME <> '${du}' AND ROWNUM=1;" | trim | head -1)

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$du" "$role" "${max_orl:-0}" "$threads" "${max_grp:-0}" "$path" "$omf" "$peer" \
        "${unassigned%%:*}" "${unassigned#*:}"
}

# ============================================================
# emit_side: print summary + DDL for one side.
# Returns 0 = compliant, 1 = DDL emitted (missing or wrong size),
#         2 = the side could not be evaluated at all (M22).
#
# Args: du role max_orl threads max_grp path omf unassigned_cnt unassigned_min_mb
# ============================================================

emit_side() {
    local du="$1" role="$2" max_orl="$3" threads="$4" max_grp="$5" path="$6" omf="$7"
    local unassigned_cnt="${8:-0}" unassigned_min="${9:-0}"
    local needs_fix="no" any_size_mismatch="no"
    local ddl_lines=""
    case "$max_grp" in ''|*[!0-9]*) max_grp=0 ;; esac
    local next_grp=$((max_grp + 1))

    unassigned_cnt="${unassigned_cnt%.*}"
    case "$unassigned_cnt" in ''|*[!0-9]*) unassigned_cnt=0 ;; esac
    local unassigned_min_int="${unassigned_min%.*}"
    case "$unassigned_min_int" in ''|*[!0-9]*) unassigned_min_int=0 ;; esac

    local target_path="$path"
    [[ -n "$SRL_PATH_OVERRIDE" ]] && target_path="$SRL_PATH_OVERRIDE"
    [[ -n "$target_path" && "$target_path" != */ ]] && target_path="${target_path}/"

    echo ""
    echo "============================================================"
    echo " ${du} (${role:-unknown role})"
    echo "============================================================"
    echo "  Max online redo log size : ${max_orl} MB"
    echo "  OMF (db_create_file_dest): ${omf}"
    echo "  SRL/ORL member directory : ${path:-<none>}"
    if [[ -n "$SRL_PATH_OVERRIDE" ]]; then
        echo "  Target dir for new SRLs  : ${target_path} (overridden)"
    fi

    local max_orl_int="${max_orl%.*}"
    case "$max_orl_int" in ''|*[!0-9]*) max_orl_int=0 ;; esac

    # -- Pass 1: validate the thread list (M22) ---------------------------
    # An empty or unparsable V$THREAD result used to produce a table with
    # zero rows, "Result: OK" and exit 0 - i.e. "verified nothing, reported
    # compliant". Count the usable records before deciding anything.
    local thread_count=0 rec
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        case "${rec%%:*}" in ''|*[!0-9]*) continue ;; esac
        thread_count=$((thread_count + 1))
    done < <(printf '%s\n' "$threads" | tr ',' '\n')

    if [[ "$thread_count" -eq 0 ]]; then
        echo ""
        echo "  Result: ERROR - could not read the thread/SRL layout."
        echo "  V\$THREAD returned no usable rows for ${du}, so nothing was verified."
        echo "  Check that the connection has SYSDBA and that the instance is at"
        echo "  least MOUNTED, then re-run. Raw value: '${threads}'"
        return 2
    fi

    echo ""
    printf "  %-8s %-11s %-11s %-11s %-13s %-11s\n" \
        "Thread" "ORL_grps" "SRL_grps" "Unassign" "Required_SRL" "Min_SRL_MB"
    printf "  %-8s %-11s %-11s %-11s %-13s %-11s\n" \
        "------" "--------" "--------" "--------" "------------" "----------"

    # -- Pass 2: grade each thread ----------------------------------------
    while IFS=':' read -r tid orl_cnt srl_cnt min_mb; do
        [[ -z "$tid" ]] && continue
        case "$tid" in ''|*[!0-9]*) continue ;; esac
        case "$orl_cnt" in ''|*[!0-9]*) orl_cnt=0 ;; esac
        case "$srl_cnt" in ''|*[!0-9]*) srl_cnt=0 ;; esac
        local min_mb_int="${min_mb%.*}"
        case "$min_mb_int" in ''|*[!0-9]*) min_mb_int=0 ;; esac

        # H11: the unassigned (THREAD#=0) pool counts toward this thread.
        # With one thread that is exact; with several it is a shared pool
        # and the note printed below says so.
        local effective_srl=$((srl_cnt + unassigned_cnt))

        # Effective minimum size across whatever actually exists for this
        # thread. A thread with no SRLs at all reports 0 and is graded by
        # the deficit rule, not the size rule.
        local effective_min=0
        if [[ "$srl_cnt" -gt 0 && "$unassigned_cnt" -gt 0 ]]; then
            if [[ "$min_mb_int" -le "$unassigned_min_int" ]]; then
                effective_min="$min_mb_int"
            else
                effective_min="$unassigned_min_int"
            fi
        elif [[ "$srl_cnt" -gt 0 ]]; then
            effective_min="$min_mb_int"
        elif [[ "$unassigned_cnt" -gt 0 ]]; then
            effective_min="$unassigned_min_int"
        fi

        local required=$((orl_cnt + 1))
        local deficit=$((required - effective_srl))
        printf "  %-8s %-11s %-11s %-11s %-13s %-11s\n" \
            "$tid" "$orl_cnt" "$srl_cnt" "$unassigned_cnt" "$required" "$effective_min"

        if [[ "$effective_srl" -gt 0 ]] && [[ "$effective_min" -ne "$max_orl_int" ]]; then
            any_size_mismatch="yes"
            needs_fix="yes"
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
    done < <(printf '%s\n' "$threads" | tr ',' '\n')

    if [[ "$unassigned_cnt" -gt 0 ]]; then
        echo ""
        if [[ "$thread_count" -eq 1 ]]; then
            echo "  Note: ${unassigned_cnt} SRL group(s) report THREAD#=0 - they were added"
            echo "        without a THREAD clause and Oracle binds them on first use."
            echo "        With a single enabled thread they are counted toward it."
        else
            echo "  Note: ${unassigned_cnt} SRL group(s) report THREAD#=0 (added without a"
            echo "        THREAD clause). They form a SHARED pool and are counted toward"
            echo "        EVERY thread's requirement above; Oracle binds each group to"
            echo "        whichever thread claims it first, so with ${thread_count} threads verify"
            echo "        the distribution again after the next role transition, or add"
            echo "        per-thread SRLs explicitly (ADD STANDBY LOGFILE THREAD n ...)."
        fi
    fi

    echo ""
    if [[ "$needs_fix" == "no" ]]; then
        echo "  Result: OK - all ${thread_count} thread(s) have at least N+1 SRLs at ${max_orl_int} MB."
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

# M21: every field is defaulted before use, and the '|' delimiter keeps an
# empty field from shifting all the later ones.
LOCAL_DU=""; LOCAL_ROLE=""; LOCAL_MAX_ORL=0; LOCAL_THREADS=""; LOCAL_MAX_GRP=0
LOCAL_PATH=""; LOCAL_OMF="NO"; LOCAL_PEER=""; LOCAL_UNASSIGNED=0; LOCAL_UNASSIGNED_MB=0

LOCAL_REC=$(gather_side "$LOCAL_CS")
IFS='|' read -r LOCAL_DU LOCAL_ROLE LOCAL_MAX_ORL LOCAL_THREADS LOCAL_MAX_GRP \
    LOCAL_PATH LOCAL_OMF LOCAL_PEER LOCAL_UNASSIGNED LOCAL_UNASSIGNED_MB <<<"$LOCAL_REC"

LOCAL_MAX_ORL="${LOCAL_MAX_ORL:-0}"
LOCAL_MAX_GRP="${LOCAL_MAX_GRP:-0}"
LOCAL_OMF="${LOCAL_OMF:-NO}"
LOCAL_UNASSIGNED="${LOCAL_UNASSIGNED:-0}"
LOCAL_UNASSIGNED_MB="${LOCAL_UNASSIGNED_MB:-0}"

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
            read -r PEER_PWD
            stty echo 2>/dev/null || true
            printf "\n" >&2
            # Double-quoted password: this string is fed to an in-script
            # CONNECT (never sqlplus argv), and the quotes keep special
            # characters in an operator-typed password intact.
            PEER_CS="sys/\"${PEER_PWD}\"@${peer_alias} as sysdba"
            ;;
    esac

    if run_sql "$PEER_CS" "SELECT 'OK' FROM DUAL;" | clean | grep -q '^OK$'; then
        PEER_REACHED="yes"
        info "Connected to peer ${peer_alias}."
        PEER_DU=""; PEER_ROLE=""; PEER_MAX_ORL=0; PEER_THREADS=""; PEER_MAX_GRP=0
        PEER_PATH=""; PEER_OMF="NO"; PEER_PEER=""; PEER_UNASSIGNED=0; PEER_UNASSIGNED_MB=0
        PEER_REC=$(gather_side "$PEER_CS")
        IFS='|' read -r PEER_DU PEER_ROLE PEER_MAX_ORL PEER_THREADS PEER_MAX_GRP \
            PEER_PATH PEER_OMF PEER_PEER PEER_UNASSIGNED PEER_UNASSIGNED_MB <<<"$PEER_REC"
        PEER_MAX_ORL="${PEER_MAX_ORL:-0}"
        PEER_MAX_GRP="${PEER_MAX_GRP:-0}"
        PEER_OMF="${PEER_OMF:-NO}"
        PEER_UNASSIGNED="${PEER_UNASSIGNED:-0}"
        PEER_UNASSIGNED_MB="${PEER_UNASSIGNED_MB:-0}"
        if [[ -z "$PEER_DU" ]]; then
            warn "Connected to peer '${peer_alias}' but could not read its DB_UNIQUE_NAME; treating the peer as unchecked."
            PEER_REACHED="no"
        fi
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
emit_side "$LOCAL_DU" "$LOCAL_ROLE" "$LOCAL_MAX_ORL" "$LOCAL_THREADS" "$LOCAL_MAX_GRP" \
    "$LOCAL_PATH" "$LOCAL_OMF" "$LOCAL_UNASSIGNED" "$LOCAL_UNASSIGNED_MB" || LOCAL_FIX_RC=$?

if [[ "$PEER_REACHED" == "yes" ]]; then
    PEER_FIX_RC=0
    emit_side "$PEER_DU" "$PEER_ROLE" "$PEER_MAX_ORL" "$PEER_THREADS" "$PEER_MAX_GRP" \
        "$PEER_PATH" "$PEER_OMF" "$PEER_UNASSIGNED" "$PEER_UNASSIGNED_MB" || PEER_FIX_RC=$?
fi

# rc 2 from emit_side means the side could not be evaluated (M22) - report
# that as its own state, never as OK and never as "ACTION REQUIRED".
_side_verdict() {
    case "$1" in
        0) printf 'OK' ;;
        1) printf 'ACTION REQUIRED' ;;
        *) printf 'ERROR - not verified' ;;
    esac
}

echo ""
echo "============================================================"
echo " Summary"
echo "============================================================"
printf "  %-30s %s\n" "${LOCAL_DU} (${LOCAL_ROLE:-unknown role})" "$(_side_verdict "$LOCAL_FIX_RC")"

PEER_UNCHECKED="no"
if [[ "$PEER_REACHED" == "yes" ]]; then
    printf "  %-30s %s\n" "${PEER_DU} (${PEER_ROLE:-unknown role})" "$(_side_verdict "$PEER_FIX_RC")"
elif [[ "$PEER_MODE" != "skip" && -n "$LOCAL_PEER" ]]; then
    PEER_UNCHECKED="yes"
    printf "  %-30s %s\n" "${LOCAL_PEER} (peer)" "UNCHECKED - peer exists but was not verified (exit code 1)"
fi

EXIT_CODE=0
[[ $LOCAL_FIX_RC -eq 1 ]] && EXIT_CODE=1
[[ $PEER_FIX_RC  -eq 1 ]] && EXIT_CODE=1
[[ "$PEER_UNCHECKED" == "yes" && $EXIT_CODE -eq 0 ]] && EXIT_CODE=1
# A side that could not be evaluated outranks "DDL needed": nothing was
# verified there, so the run is an error, not a finding.
[[ $LOCAL_FIX_RC -gt 1 ]] && EXIT_CODE=2
[[ $PEER_FIX_RC  -gt 1 ]] && EXIT_CODE=2
exit $EXIT_CODE
