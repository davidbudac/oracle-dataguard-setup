#!/usr/bin/env bash
# ============================================================
# Tests for common/setup_dg_wallet.sh
# ============================================================
# Usage: bash tests/test_setup_dg_wallet.sh
#
# DB-free: sqlplus, dgmgrl, mkstore and orapki are stubs in a fake
# ORACLE_HOME/bin that record their argv (and mkstore the staging directory's
# `ls -ld` at -create time). The script runs under the same bash as this suite,
# with PATH reduced to a toolbox of symlinks so mktemp can be removed or
# replaced by a failing stub. Covers
#   - finding 4: private staging directory with mktemp missing, failing,
#     printing nothing or returning a symlink; the fallback helper (extracted
#     between its marker lines) refusing every kind of pre-existing candidate;
#     an unwritable / missing / non-directory TMPDIR aborting with ZERO mkstore
#     and orapki invocations
#   - finding 13: a failed wallet login (ORA-01017 with exit 1, an ORA- error
#     with exit 0, empty output) on the peer or the local alias exits 1 with no
#     success wording, names the alias, shows the Oracle error, and prints the
#     restore command for the previous wallet backup
#   - the happy path still exits 0; no password on any stub's argv
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
TARGET="${REPO_ROOT}/common/setup_dg_wallet.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }
check() {   # check "name" expected actual
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
contains() {   # contains "name" file fixed-string
    if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (missing '$3' in $2)"; fi
}
lacks() {      # lacks "name" file fixed-string
    if grep -qF -- "$3" "$2"; then fail "$1 (unexpected '$3' in $2)"; else pass "$1"; fi
}
count_lines() { if [[ -f "$1" ]]; then wc -l < "$1" | tr -d ' '; else printf '0'; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/setup_dg_wallet_test.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

SYS_PW='Sys_s3cret&pw'
WALLET_PW='Wallet_pw_42'

# ------------------------------------------------------------
# Toolbox: every external command the script and the stubs use, except
# mktemp. PATH is set to this directory (plus a mktemp variant per case).
# ------------------------------------------------------------
TOOLS="$WORK/tools"
mkdir -p "$TOOLS"
for t in awk basename cat chmod cp cut date dirname echo env grep head id ln ls \
         mkdir mv od openssl rm rmdir sed sleep sort stty tail touch tr wc xargs; do
    p=$(command -v "$t" 2>/dev/null) || continue
    case "$p" in /*) ln -s "$p" "$TOOLS/$t" ;; esac
done

MKTEMP_REAL="$WORK/mktemp_real"; mkdir -p "$MKTEMP_REAL"
REAL_MKTEMP=$(command -v mktemp 2>/dev/null) && ln -s "$REAL_MKTEMP" "$MKTEMP_REAL/mktemp"

MKTEMP_FAIL="$WORK/mktemp_fail"; mkdir -p "$MKTEMP_FAIL"
printf '#!/bin/bash\nexit 1\n' > "$MKTEMP_FAIL/mktemp"
MKTEMP_EMPTY="$WORK/mktemp_empty"; mkdir -p "$MKTEMP_EMPTY"
printf '#!/bin/bash\nexit 0\n' > "$MKTEMP_EMPTY/mktemp"
# Returns a symlink to a directory (mode 700, ours) - must be refused.
MKTEMP_LINK="$WORK/mktemp_link"; mkdir -p "$MKTEMP_LINK"
cat > "$MKTEMP_LINK/mktemp" <<'STUB'
#!/bin/bash
mkdir -m 700 "$STUB_LINK_TARGET" 2>/dev/null
ln -s "$STUB_LINK_TARGET" "${TMPDIR}/dg_wallet_staging.LINKED"
printf '%s\n' "${TMPDIR}/dg_wallet_staging.LINKED"
STUB
chmod +x "$MKTEMP_FAIL/mktemp" "$MKTEMP_EMPTY/mktemp" "$MKTEMP_LINK/mktemp"

# ------------------------------------------------------------
# Fake ORACLE_HOME
# ------------------------------------------------------------
OH="$WORK/oh"
mkdir -p "$OH/bin"

cat > "$OH/bin/dgmgrl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG/dgmgrl.calls"
case "$*" in
    *"SHOW CONFIGURATION"*)
        printf '\nConfiguration - dg_cfg\n\n  Protection Mode: MaxPerformance\n  Members:\n'
        printf '  prim - Primary database\n    stby - Physical standby database \n\n'
        printf 'Configuration Status:\nSUCCESS   (status updated 5 seconds ago)\n' ;;
    *"'prim'"*) printf "  DGConnectIdentifier = 'prim_tns'\n" ;;
    *"'stby'"*) printf "  DGConnectIdentifier = 'stby_tns'\n" ;;
esac
STUB

cat > "$OH/bin/sqlplus" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG/sqlplus.calls"
input=$(cat)
case "$*" in
    "-s / as sysdba")
        printf 'DBSTATUS|PRIMARY|prim\nBROKER|TRUE\n' ;;
    "-s /nolog")
        # Password login pre-check: CONNECT sys/"<pw>"@<alias> AS SYSDBA
        alias=$(printf '%s\n' "$input" | sed -n 's/^CONNECT sys\/".*"@\([^ ]*\) AS SYSDBA$/\1/p')
        pw=$(printf '%s\n' "$input" | sed -n 's/^CONNECT sys\/"\(.*\)"@.*$/\1/p')
        case " ${STUB_PW_FAIL_ALIASES:-} " in
            *" $alias "*) pw="__forced_failure__" ;;
        esac
        if [[ "$pw" != "$STUB_SYS_PW" ]]; then
            printf 'ERROR:\nORA-01017: invalid username/password; logon denied\n'
            exit 0
        fi
        printf '%s\n' "$input" | grep -q PEER_OK && printf 'PEER_OK\n'
        printf '%s\n' "$input" | grep -q LOC_OK && printf 'LOC_OK\n' ;;
    "-s -L /@"*)
        alias="${3#/@}"
        printf '%s\n' "$alias" >> "$STUB_LOG/wallet_logins"
        mode="ok"
        [[ "$alias" == "stby_tns" ]] && mode="${STUB_WALLET_PEER:-ok}"
        [[ "$alias" == "prim_tns" ]] && mode="${STUB_WALLET_LOC:-ok}"
        case "$mode" in
            ok)       printf '\nWALLET_OK\n\n'; exit 0 ;;
            ora01017) printf 'ERROR:\nORA-01017: invalid username/password; logon denied\n\n\nSP2-0751: Unable to connect to Oracle.  Exiting SQL*Plus\n'; exit 1 ;;
            ora_rc0)  printf '\nWALLET_OK\nORA-28000: The account is locked.\n'; exit 0 ;;
            empty_rc0) exit 0 ;;
        esac ;;
esac
exit 0
STUB

cat > "$OH/bin/mkstore" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG/mkstore.calls"
wrl=""; op=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -wrl) wrl="$2"; shift 2 ;;
        -create|-createSSO|-listCredential|-deleteCredential|-createCredential) op="$1"; shift; break ;;
        *) shift ;;
    esac
done
input=$(cat)
case "$op" in
    -create)
        ls -ld "$wrl" >> "$STUB_LOG/staging.ls"
        printf '%s\n' "$wrl" >> "$STUB_LOG/staging.paths"
        : > "$wrl/ewallet.p12" ;;
    -createSSO)
        : > "$wrl/cwallet.sso" ;;
    -listCredential)
        if [[ "$(printf '%s\n' "$input" | head -1)" == "$STUB_WALLET_PW" ]]; then
            printf 'List credential (index: connect_string username)\n1: stby_tns sys\n'
        else
            printf 'Error: incorrect password\n'
            exit 1
        fi ;;
    -deleteCredential) : ;;
    -createCredential)
        printf '%s %s\n' "$1" "$2" >> "$STUB_LOG/creds" ;;
esac
exit 0
STUB

cat > "$OH/bin/orapki" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG/orapki.calls"
STUB
chmod +x "$OH/bin/"*

# ------------------------------------------------------------
# run_case <case> <mktemp-dir-or-empty> <stdin> [script args...]
#   Fresh case dir with log/, admin/ (TNS_ADMIN) and tmp/ (TMPDIR) unless
#   CASE_TMPDIR is set. Output in $C/out, exit status in RC.
# ------------------------------------------------------------
RC=0
run_case() {
    local name="$1" mkt="$2" input="$3" path
    shift 3
    C="$WORK/case_${name}"
    mkdir -p "$C/log" "$C/admin" "$C/tmp"
    path="$TOOLS"
    [[ -n "$mkt" ]] && path="${mkt}:${TOOLS}"
    printf '%s' "$input" | \
        PATH="$path" ORACLE_HOME="$OH" ORACLE_SID=prim TNS_ADMIN="$C/admin" \
        TMPDIR="${CASE_TMPDIR:-$C/tmp}" STUB_LOG="$C/log" STUB_SYS_PW="$SYS_PW" \
        STUB_WALLET_PW="$WALLET_PW" STUB_LINK_TARGET="$C/link_target" \
        "$BASH" "$TARGET" -w "${CASE_WALLET:-$C/wallet}" "$@" > "$C/out" 2>&1
    RC=$?
}

# A wallet directory as an earlier run leaves it.
make_old_wallet() {
    mkdir -p "$1"
    : > "$1/ewallet.p12"
    : > "$1/cwallet.sso"
}

no_password_on_argv() {
    local f leaked=0
    for f in "$C"/log/*.calls; do
        [[ -f "$f" ]] || continue
        if grep -qF -- "$SYS_PW" "$f" || grep -qF -- "$WALLET_PW" "$f"; then leaked=1; fi
    done
    check "$1: no password on any stub argv" "0" "$leaked"
}

echo "============================================================"
echo "common/setup_dg_wallet.sh (bash ${BASH_VERSION})"
echo "============================================================"

echo ""
echo "Test 1: mktemp missing -> private fallback staging dir, distinct per run, wallet built"
SHARED_TMP="$WORK/shared_tmp"; mkdir -p "$SHARED_TMP"
CASE_TMPDIR="$SHARED_TMP" run_case t1a "" "${SYS_PW}
" -A
check "t1a: exit 0" "0" "$RC"
check "t1a: staging dir mode drwx------" "drwx------" "$(cut -c1-10 "$C/log/staging.ls")"
case "$(cat "$C/log/staging.paths")" in
    "$SHARED_TMP/dg_wallet_staging."*) pass "t1a: staging dir is under TMPDIR" ;;
    *) fail "t1a: staging dir is under TMPDIR (got $(cat "$C/log/staging.paths"))" ;;
esac
T1A_PATH=$(cat "$C/log/staging.paths")
[[ -f "$C/wallet/ewallet.p12" && -f "$C/wallet/cwallet.sso" ]] && pass "t1a: wallet activated" || fail "t1a: wallet activated"
check "t1a: peer and local credentials stored" "stby_tns sys prim_tns sys" "$(tr '\n' ' ' < "$C/log/creds" | sed 's/ $//')"
contains "t1a: sqlnet.ora points at the wallet" "$C/admin/sqlnet.ora" "DIRECTORY = $C/wallet"
contains "t1a: success summary" "$C/out" "Credentials stored and verified for:"
check "t1a: no staging dir left behind" "" "$(ls "$SHARED_TMP")"
check "t1a: zero orapki calls" "0" "$(count_lines "$C/log/orapki.calls")"
no_password_on_argv t1a
CASE_TMPDIR="$SHARED_TMP" run_case t1b "" "${SYS_PW}
" -A
check "t1b: exit 0" "0" "$RC"
T1B_PATH=$(cat "$C/log/staging.paths")
[[ -n "$T1A_PATH" && "$T1A_PATH" != "$T1B_PATH" ]] && pass "t1: two runs use distinct staging dirs" \
    || fail "t1: two runs use distinct staging dirs ('$T1A_PATH' vs '$T1B_PATH')"

if [[ -n "$REAL_MKTEMP" ]]; then
    run_case t1c "$MKTEMP_REAL" "${SYS_PW}
" -A
    check "t1c: real mktemp -> exit 0" "0" "$RC"
    check "t1c: real mktemp staging dir mode drwx------" "drwx------" "$(cut -c1-10 "$C/log/staging.ls")"
    lacks "t1c: no fallback warning with a working mktemp" "$C/out" "exclusive-mkdir fallback"
fi

echo ""
echo "Test 2: mktemp installed but failing / printing nothing / returning a symlink"
for variant in fail empty; do
    if [[ "$variant" == fail ]]; then mkt="$MKTEMP_FAIL"; else mkt="$MKTEMP_EMPTY"; fi
    run_case "t2_$variant" "$mkt" "${SYS_PW}
" -A
    check "t2 $variant: exit 0 via fallback" "0" "$RC"
    contains "t2 $variant: fallback announced" "$C/out" "exclusive-mkdir fallback"
    check "t2 $variant: staging dir mode drwx------" "drwx------" "$(cut -c1-10 "$C/log/staging.ls")"
    case "$(cat "$C/log/staging.paths")" in
        "$C/tmp/dg_wallet_staging."*) pass "t2 $variant: never an empty staging path" ;;
        *) fail "t2 $variant: never an empty staging path (got '$(cat "$C/log/staging.paths")')" ;;
    esac
done
run_case t2_link "$MKTEMP_LINK" "${SYS_PW}
" -A
check "t2 link: precondition - mktemp stub returned a symlink" "1" "$([[ -L "$C/tmp/dg_wallet_staging.LINKED" ]] && echo 1 || echo 0)"
check "t2 link: exit 0 via fallback" "0" "$RC"
case "$(cat "$C/log/staging.paths")" in
    *LINKED*|"$C/link_target"*) fail "t2 link: symlinked mktemp result refused" ;;
    "$C/tmp/dg_wallet_staging."*) pass "t2 link: symlinked mktemp result refused" ;;
    *) fail "t2 link: symlinked mktemp result refused (got '$(cat "$C/log/staging.paths")')" ;;
esac
check "t2 link: symlink target left untouched" "" "$(ls -A "$C/link_target")"

echo ""
echo "Test 3: fallback helper refuses every pre-existing candidate"
HELPER="$WORK/helper.sh"
sed -n '/^# ---- begin staging dir helper ----$/,/^# ---- end staging dir helper ----$/p' "$TARGET" > "$HELPER"
check "helper block extracted" "1" "$(grep -c '^make_private_staging_dir()' "$HELPER")"
H="$WORK/h_tmp"; mkdir -p "$H" "$WORK/h_target"
(
    PATH="$TOOLS"                  # no mktemp: the fallback runs
    TMPDIR="$H"
    error() { printf 'ERROR %s\n' "$1"; }
    warn()  { printf 'WARN %s\n' "$1"; }
    # shellcheck disable=SC1090
    source "$HELPER"

    # The real candidate generator: distinct names, carrying $$.
    _staging_candidate "$H" 1; c1="$STAGING_CANDIDATE"
    _staging_candidate "$H" 1; c2="$STAGING_CANDIDATE"
    [[ "$c1" != "$c2" ]] && echo "distinct_ok" || echo "distinct_bad"
    case "$c1" in "$H/dg_wallet_staging.$$."*) echo "pid_ok" ;; *) echo "pid_bad" ;; esac

    # Deterministic candidates for the occupancy tests.
    _staging_candidate() { STAGING_CANDIDATE="${1}/cand.${2}"; }
    mkdir -m 700 "$H/cand.1"                         # our own private dir - still refused
    printf 'x\n' > "$H/cand.2"                       # regular file
    ln -s "$WORK/h_target" "$H/cand.3"               # symlink to a directory
    ln -s "$WORK/h_nowhere" "$H/cand.4"              # dangling symlink
    mkdir -m 755 "$H/cand.5"                         # someone's open directory
    i=6; while [[ $i -le 10 ]]; do mkdir "$H/cand.$i"; i=$((i+1)); done
    out=$(make_private_staging_dir 2>"$WORK/h_err"); rc=$?
    echo "all_taken_rc=$rc out=[$out]"
    [[ -L "$H/cand.4" && ! -e "$WORK/h_nowhere" ]] && echo "dangling_untouched" || echo "dangling_touched"
    rmdir "$H/cand.7"
    out=$(make_private_staging_dir 2>/dev/null); rc=$?
    echo "free_rc=$rc out=[$out]"
    ls -ld "$out" | cut -c1-10

    # The verification predicate on its own.
    mkdir -m 700 "$WORK/h_priv"; ln -s "$WORK/h_priv" "$WORK/h_privlink"
    _staging_dir_is_private "$WORK/h_priv" && echo "priv_ok" || echo "priv_bad"
    _staging_dir_is_private "$WORK/h_privlink" && echo "link_accepted" || echo "link_refused"
    _staging_dir_is_private "$H/cand.5" && echo "755_accepted" || echo "755_refused"
    _staging_dir_is_private "" && echo "empty_accepted" || echo "empty_refused"
) > "$WORK/h_out" 2>&1
check "real candidates are distinct between attempts" "1" "$(grep -c '^distinct_ok$' "$WORK/h_out")"
check "real candidates carry the PID" "1" "$(grep -c '^pid_ok$' "$WORK/h_out")"
check "all candidates taken -> rc 1, nothing printed" "all_taken_rc=1 out=[]" "$(grep '^all_taken_rc=' "$WORK/h_out")"
contains "all candidates taken -> error names the attempts" "$WORK/h_err" "(10 attempts)"
check "dangling symlink not followed" "1" "$(grep -c '^dangling_untouched$' "$WORK/h_out")"
check "symlink target dir untouched" "" "$(ls -A "$WORK/h_target")"
check "regular file candidate untouched" "x" "$(cat "$H/cand.2")"
check "first free candidate is used" "free_rc=0 out=[$H/cand.7]" "$(grep '^free_rc=' "$WORK/h_out")"
check "fallback dir is drwx------" "1" "$(grep -c '^drwx------$' "$WORK/h_out")"
check "predicate accepts a private dir" "1" "$(grep -c '^priv_ok$' "$WORK/h_out")"
check "predicate refuses a symlink to a private dir" "1" "$(grep -c '^link_refused$' "$WORK/h_out")"
check "predicate refuses a 755 dir" "1" "$(grep -c '^755_refused$' "$WORK/h_out")"
check "predicate refuses an empty path" "1" "$(grep -c '^empty_refused$' "$WORK/h_out")"

echo ""
echo "Test 4: no private dir can be made -> exit 1, zero mkstore/orapki calls"
RO_TMP="$WORK/ro_tmp"; mkdir -p "$RO_TMP"; chmod 555 "$RO_TMP"
if : 2>/dev/null > "$RO_TMP/probe"; then
    rm -f "$RO_TMP/probe"
    echo "  SKIP: running with privileges that ignore directory modes"
else
    for variant in nomktemp realmktemp; do
        mkt=""; [[ "$variant" == realmktemp ]] && mkt="$MKTEMP_REAL"
        [[ "$variant" == realmktemp && -z "$REAL_MKTEMP" ]] && continue
        CASE_TMPDIR="$RO_TMP" run_case "t4_$variant" "$mkt" "${SYS_PW}
" -A
        check "t4 unwritable TMPDIR ($variant): exit 1" "1" "$RC"
        check "t4 unwritable TMPDIR ($variant): zero mkstore calls" "0" "$(count_lines "$C/log/mkstore.calls")"
        check "t4 unwritable TMPDIR ($variant): zero orapki calls" "0" "$(count_lines "$C/log/orapki.calls")"
        contains "t4 unwritable TMPDIR ($variant): refusal explained" "$C/out" "without a private staging directory"
        [[ ! -e "$C/wallet" && ! -e "$C/admin/sqlnet.ora" ]] && pass "t4 unwritable TMPDIR ($variant): nothing changed" \
            || fail "t4 unwritable TMPDIR ($variant): nothing changed"
    done
fi
printf 'not a dir\n' > "$WORK/tmp_is_file"
CASE_TMPDIR="$WORK/tmp_is_file" run_case t4_file "" "${SYS_PW}
" -A
check "t4 TMPDIR is a file: exit 1" "1" "$RC"
check "t4 TMPDIR is a file: zero mkstore calls" "0" "$(count_lines "$C/log/mkstore.calls")"
CASE_TMPDIR="$WORK/no_such_tmp" run_case t4_missing "$MKTEMP_FAIL" "${SYS_PW}
" -A
check "t4 TMPDIR missing + failing mktemp: exit 1" "1" "$RC"
check "t4 TMPDIR missing + failing mktemp: zero mkstore calls" "0" "$(count_lines "$C/log/mkstore.calls")"
check "t4 TMPDIR missing: not created by mkdir -p" "0" "$([[ -e "$WORK/no_such_tmp" ]] && echo 1 || echo 0)"

echo ""
echo "Test 5: failed wallet login -> exit 1, no success wording, restore hint"
# 5a: in-place update of an existing wallet (backup copy), peer ORA-01017.
C="$WORK/case_t5a"; make_old_wallet "$C/wallet"
STUB_WALLET_PEER=ora01017 run_case t5a "" "${SYS_PW}
${WALLET_PW}
"
check "t5a peer ORA-01017: exit 1" "1" "$RC"
contains "t5a: names the failing alias" "$C/out" "Wallet login FAILED for standby alias stby_tns"
contains "t5a: shows the Oracle error" "$C/out" "ORA-01017: invalid username/password; logon denied"
lacks "t5a: no success summary" "$C/out" "Credentials stored and verified"
lacks "t5a: no 'connect without a password'" "$C/out" "You can now connect without a password"
lacks "t5a: no 'successful' for the peer" "$C/out" "Wallet connection to standby (stby_tns) successful"
contains "t5a: wallet left in place" "$C/out" "left in place at: $C/wallet"
BAK=$(ls -d "$C"/wallet.bak.* 2>/dev/null | head -1)
[[ -n "$BAK" && -f "$BAK/ewallet.p12" ]] && pass "t5a: pre-update backup exists" || fail "t5a: pre-update backup exists"
contains "t5a: exact restore command" "$C/out" "Restore it with: rm -rf $C/wallet && mv $BAK $C/wallet"
contains "t5a: sqlnet.ora creation reported" "$C/out" "sqlnet.ora was created by this run"
no_password_on_argv t5a

# 5b: -A recreate of an unopenable wallet (moved aside), peer ORA-01017.
C="$WORK/case_t5b"; make_old_wallet "$C/wallet"
STUB_WALLET_PEER=ora01017 run_case t5b "" "${SYS_PW}
wrong_wallet_pw
RECREATE WALLET
" -A
check "t5b recreate + peer ORA-01017: exit 1" "1" "$RC"
BAK=$(ls -d "$C"/wallet.bak.* 2>/dev/null | head -1)
[[ -n "$BAK" ]] && pass "t5b: previous wallet moved aside" || fail "t5b: previous wallet moved aside"
contains "t5b: restore command names the moved-aside wallet" "$C/out" "Restore it with: rm -rf $C/wallet && mv $BAK $C/wallet"
[[ -f "$C/wallet/cwallet.sso" ]] && pass "t5b: new wallet left in place" || fail "t5b: new wallet left in place"

# 5c: sqlplus exits 0 but prints an ORA- error (and even the marker).
STUB_WALLET_PEER=ora_rc0 run_case t5c "" "${SYS_PW}
" -A
check "t5c ORA- with exit 0: exit 1" "1" "$RC"
contains "t5c: shows the Oracle error" "$C/out" "ORA-28000"
lacks "t5c: no success summary" "$C/out" "Credentials stored and verified"
contains "t5c: no previous wallet -> removal hint" "$C/out" "There was no previous wallet; remove it with: rm -rf $C/wallet"

# 5d: sqlplus exits 0 with no output at all.
STUB_WALLET_PEER=empty_rc0 run_case t5d "" "${SYS_PW}
" -A
check "t5d empty output, exit 0: exit 1" "1" "$RC"
contains "t5d: reports the empty output" "$C/out" "(no output; sqlplus exit status 0)"

# 5e: local alias wallet login fails, peer succeeds.
STUB_WALLET_LOC=ora01017 run_case t5e "" "${SYS_PW}
" -A
check "t5e local fails, peer ok: exit 1" "1" "$RC"
contains "t5e: peer reported successful" "$C/out" "Wallet connection to standby (stby_tns) successful"
contains "t5e: names the local alias" "$C/out" "Wallet login FAILED for local alias prim_tns"
lacks "t5e: no success summary" "$C/out" "Credentials stored and verified"

# 5f: local alias fails the PASSWORD pre-check -> not stored, not required.
STUB_PW_FAIL_ALIASES="prim_tns" run_case t5f "" "${SYS_PW}
" -A
check "t5f local pre-check fails: exit 0" "0" "$RC"
check "t5f: only the peer credential stored" "stby_tns sys" "$(tr '\n' ' ' < "$C/log/creds" | sed 's/ $//')"
check "t5f: only the peer wallet login attempted" "stby_tns" "$(tr '\n' ' ' < "$C/log/wallet_logins" | sed 's/ $//')"
contains "t5f: says the local credential is not stored" "$C/out" "The local credential will NOT be stored"

echo ""
echo "Test 6: happy path with an existing wallet (in-place update) exits 0"
C="$WORK/case_t6"; make_old_wallet "$C/wallet"
printf 'NAMES.DIRECTORY_PATH = (TNSNAMES)\n' > "$WORK/t6_sqlnet"
mkdir -p "$C/admin"; cp "$WORK/t6_sqlnet" "$C/admin/sqlnet.ora"
run_case t6 "" "${SYS_PW}
${WALLET_PW}
"
check "t6: exit 0" "0" "$RC"
contains "t6: success summary" "$C/out" "Credentials stored and verified for:"
check "t6: wallet login tested for both aliases" "stby_tns prim_tns" "$(tr '\n' ' ' < "$C/log/wallet_logins" | sed 's/ $//')"
SQLBAK=$(ls "$C"/admin/sqlnet.ora.bak.* 2>/dev/null | head -1)
[[ -n "$SQLBAK" ]] && check "t6: sqlnet.ora backup holds the original" "NAMES.DIRECTORY_PATH = (TNSNAMES)" "$(cat "$SQLBAK")" \
    || fail "t6: sqlnet.ora backup made"
contains "t6: override line added" "$C/admin/sqlnet.ora" "SQLNET.WALLET_OVERRIDE = TRUE"
no_password_on_argv t6

echo ""
echo "Test 7: help text documents the exit status"
"$BASH" "$TARGET" --help > "$WORK/help.out" 2>&1
check "--help exits 0" "0" "$?"
contains "--help documents exit status" "$WORK/help.out" "Exit status: 0 = wallet works"

echo ""
echo "============================================================"
echo "Test Summary: $PASS passed, $FAIL failed"
echo "============================================================"
[[ $FAIL -eq 0 ]]
