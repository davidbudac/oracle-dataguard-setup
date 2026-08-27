#!/bin/bash
# ============================================================
# Test script for AIX 7.2 portability of the shipped scripts
# ============================================================
# Usage: bash tests/test_aix_portability.sh
#
# Repo-wide sweep that fails on constructs which work on Linux but not on
# a stock AIX 7.2 host: GNU-only sed/coreutils flags, GNU BRE extensions,
# bash 4+ syntax, and Linux-only binaries used without a `command -v`
# guard. Complements tests/test_grep_portability.sh (grep patterns) and
# tests/test_df_parsing.sh (the `df -Pk` column layout).
#
# Scope - deliberately NOT swept:
#   * tests/**            - test drivers run on the operator's Linux/macOS
#                           workstation, never on the AIX DB host.
#   * nfs/01_setup_nfs_server.sh, nfs/02_mount_nfs_client.sh
#                         - Linux-only by design (yum/systemd/exportfs,
#                           mount -t nfs4, /etc/fstab). Both refuse to run
#                           on AIX with the AIX-native command sequence
#                           printed instead; that guard is asserted below.
# ============================================================

# Don't use set -e as we need to test for failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

cd "$REPO_ROOT" || exit 1

echo "============================================================"
echo "AIX 7.2 portability sweep"
echo "============================================================"
echo ""

# ------------------------------------------------------------
# Files in scope
# ------------------------------------------------------------
SH_FILES=$(find . \( -path ./.git -o -path ./.claude \) -prune -o -type f -name '*.sh' -print \
    | sed 's#^\./##' \
    | grep -v '^tests/' \
    | grep -v '/tests/' \
    | grep -v '^nfs/0[12]_' \
    | sort)

# ------------------------------------------------------------
# Rule table: "<id>~~<ERE matched against non-comment lines>~~<why>"
# The separator is ~~ and not | : every pattern is a full ERE that
# contains | itself.
# ------------------------------------------------------------
RULES='sed-i~~(^|[^A-Za-z0-9_])sed[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*i([[:space:]]|$)~~sed -i is GNU-only (AIX sed cannot edit in place)
sed-Er~~(^|[^A-Za-z0-9_])sed[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*[Er]([[:space:]]|$)~~sed -E/-r is GNU-only (AIX sed has BRE only)
sed-bre~~sed[^~]*\\[+?]~~GNU BRE extension in a sed expression (AIX sed matches it literally)
echo-flag~~(^|[^A-Za-z0-9_])echo[[:space:]]+-[en]([[:space:]]|$)~~echo -e/-n is not portable - use printf
case-mod~~\$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,)~~bash 4 case modification of a variable
mapfile~~(^|[^A-Za-z0-9_])(mapfile|readarray)([[:space:]]|$)~~mapfile/readarray is bash 4+
assoc-array~~(declare|typeset|local)[[:space:]]+-[A-Za-z]*A([[:space:]]|$)~~associative arrays are bash 4+
nameref~~(declare|typeset|local)[[:space:]]+-[A-Za-z]*n([[:space:]]|$)~~namerefs (declare -n) are bash 4.3+
du-b~~(^|[^A-Za-z0-9_])du[[:space:]]+-[A-Za-z]*b~~du -b is GNU-only (use -k and multiply)
date-epoch~~(^|[^A-Za-z0-9_])date[[:space:]]+[^;)]*\+%s~~date +%s is not in the AIX date format set
date-d~~(^|[^A-Za-z0-9_])date[[:space:]]+(-d|--date)([[:space:]]|=)~~date -d/--date is GNU-only
ping-W~~(^|[^A-Za-z0-9_])ping[[:space:]]+[^;)]*-W([[:space:]]|$)~~ping -W is GNU-only
df-h~~(^|[^A-Za-z0-9_])df[[:space:]]+-[A-Za-z]*h([[:space:]]|$)~~df -h is not on AIX - use df -Pk (see tests/test_df_parsing.sh)
hostname-I~~(^|[^A-Za-z0-9_])hostname[[:space:]]+-[IiF]~~hostname -I/-i/-F is Linux-only
stat-c~~(^|[^A-Za-z0-9_])stat[[:space:]]+(-c|--format)~~stat -c is GNU-only (AIX has no stat(1))
readlink-f~~(^|[^A-Za-z0-9_])(readlink[[:space:]]+-[A-Za-z]*f|realpath)([[:space:]]|$)~~readlink -f / realpath are GNU-only
xargs-flag~~(^|[^A-Za-z0-9_])xargs[[:space:]]+-[0rd]~~xargs -0/-r/-d are GNU-only
gnu-bin~~(^|[^A-Za-z0-9_./])(seq|tac|nproc|md5sum|sha1sum|sha256sum|lscpu)([[:space:]]|$)~~not present on a stock AIX 7.2
sort-Vh~~(^|[^A-Za-z0-9_])sort[[:space:]]+[^;)]*-[Vh]([[:space:]]|$)~~sort -V/-h are GNU-only
long-opt~~(^|[^A-Za-z0-9_])(cp|mv|rm|ls|head|tail|wc|cut|tr|mkdir|chmod|chown|ln|du|find)[[:space:]]+--[a-z]~~GNU long options are not accepted by AIX utilities
proc-fs~~/proc/(meminfo|cpuinfo|net/)~~/proc/meminfo etc. do not exist on AIX'

# ------------------------------------------------------------
# Part 1: rule sweep
# ------------------------------------------------------------
echo "Part 1: GNU-only construct sweep ($(printf '%s\n' "$SH_FILES" | wc -l | tr -d ' ') files)"

VIOLATIONS=""
COUNT=0

for f in $SH_FILES; do
    while IFS= read -r rule; do
        [ -z "$rule" ] && continue
        rid=${rule%%~~*}
        rest=${rule#*~~}
        pat=${rest%%~~*}
        why=${rest##*~~}

        # Skip comment-only lines: narrative text about a construct is not
        # a use of it (this repo documents its own AIX workarounds inline).
        hits=$(grep -n -E "$pat" "$f" 2>/dev/null | grep -v -E '^[0-9]+:[[:space:]]*#')
        [ -z "$hits" ] && continue

        while IFS= read -r hit; do
            [ -z "$hit" ] && continue
            VIOLATIONS="${VIOLATIONS}  ${f}:${hit%%:*}: [${rid}] ${why}
      ${hit#*:}
"
            COUNT=$((COUNT + 1))
        done <<HITS
$hits
HITS
    done <<RULES_IN
$RULES
RULES_IN
done

if [ -n "$VIOLATIONS" ]; then
    echo "  FAIL: ${COUNT} non-portable construct(s) found:"
    printf '%s' "$VIOLATIONS"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: no GNU-only constructs in the AIX-facing scripts"
    PASS=$((PASS + 1))
fi

# ------------------------------------------------------------
# Part 2: Linux-only binaries must be guarded before use
# ------------------------------------------------------------
# These exist on Linux but not on a stock AIX 7.2 host. Using them is
# fine as an opportunistic fast path; using them unguarded is not.
echo ""
echo "Part 2: Linux-only binaries are guarded before use"

UNGUARDED=""

# Real invocations only. A tool name is a use when it stands in command
# position on a line that is not a comment, not inside a heredoc (both
# handoff scripts and add_observer/ print command *examples* to the
# operator that way), and not an argument to echo/printf/log_*.
_real_uses() {
    awk -v tool="$1" '
        BEGIN { hd = 0 }
        {
            line = $0
            if (hd) { s = line; sub(/^[ \t]+/, "", s); if (s == delim) hd = 0; next }
            if (match(line, /<<-?[ ]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*['"'"'"]?/)) {
                d = substr(line, RSTART, RLENGTH)
                sub(/^<<-?[ ]*/, "", d); gsub(/['"'"'"]/, "", d)
                delim = d; hd = 1
            }
            s = line; sub(/^[ \t]+/, "", s)
            if (s ~ /^#/) next
            if (s ~ /^(echo|printf|log_[a-z]+|die|warn|info)[ \t]/) next
            pat = "(^|[;&|(]|\\$\\()[ \t]*(sudo[ \t]+)?" tool "[ \t]"
            if (s ~ pat || line ~ pat) printf "%d:%s\n", NR, line
        }
    ' "$2"
}

for tool in timeout nc showmount systemctl base64 mktemp tput; do
    for f in $SH_FILES; do
        uses=$(_real_uses "$tool" "$f" | grep -v -E "command[[:space:]]+-v[[:space:]]+${tool}")
        [ -z "$uses" ] && continue
        # Accepted guard shapes: an explicit command -v / [ -x ] probe, or
        # capturing the tool's output in an if-condition with a fallback
        # branch (VAR=$(tool ... 2>/dev/null)).
        if grep -q -E "command[[:space:]]+-v[[:space:]]+${tool}|\[[[:space:]]+-x[[:space:]]+[^]]*${tool}" "$f" \
           || grep -qF "=\$(${tool}" "$f"; then
            continue
        fi
        UNGUARDED="${UNGUARDED}  ${f}: uses '${tool}' with no 'command -v ${tool}' guard
$(printf '%s\n' "$uses" | sed 's/^/      /')
"
    done
done

if [ -n "$UNGUARDED" ]; then
    echo "  FAIL: unguarded Linux-only binaries:"
    printf '%s' "$UNGUARDED"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: every Linux-only binary is behind a command -v guard"
    PASS=$((PASS + 1))
fi

# ------------------------------------------------------------
# Part 3: the Linux-only NFS scripts refuse to run on AIX
# ------------------------------------------------------------
echo ""
echo "Part 3: nfs/ scripts stop on AIX instead of running Linux commands"

for f in nfs/01_setup_nfs_server.sh nfs/02_mount_nfs_client.sh; do
    if grep -q 'uname -s.*=.*"AIX"' "$f" && grep -q 'mknfs' "$f"; then
        echo "  PASS: ${f} has an AIX guard with the AIX-native sequence"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${f} is missing the AIX platform guard"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "============================================================"
echo "Test Summary: $PASS passed, $FAIL failed"
echo "============================================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
