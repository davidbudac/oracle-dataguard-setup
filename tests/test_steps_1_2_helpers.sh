#!/usr/bin/env bash
# ============================================================
# Tests for the step 1 / step 2 fixes from the 2026-10-01 review:
#   Step 1 (primary/01_gather_primary_info.sh) helpers, extracted from the
#   script itself (no copies to drift): resolve_fqdn (A5), extract_port /
#   valid_port_or_empty (M2); static checks for the -n/--check guard (C3),
#   the umask copy, the password-file candidates and the SQL files.
#   Step 2 (primary/02_generate_standby_config.sh): the validators,
#   pick_standby_for_primary (M3/M4), and end-to-end runs against a scratch
#   "NFS share" with piped stdin: -n/--check writes nothing (C3), M3/M4 paths,
#   DG_BROKER_CONFIG_NAME survives --regenerate, SHARED password file refused,
#   bad names refused non-interactively.
# Usage: ./tests/test_steps_1_2_helpers.sh
# ============================================================

# Don't use set -e as we need to test for failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
STEP1="${REPO_DIR}/primary/01_gather_primary_info.sh"
STEP2="${REPO_DIR}/primary/02_generate_standby_config.sh"

LOG_FILE=/dev/null
source "${REPO_DIR}/common/dg_functions.sh"

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test_steps_1_2.XXXXXX") || TEST_DIR=""
if [[ -z "$TEST_DIR" || ! -d "$TEST_DIR" ]]; then
    echo "FATAL: could not create a temporary test directory" >&2
    exit 1
fi
trap 'rm -rf "$TEST_DIR"' EXIT

PASS=0
FAIL=0

check() {
    local name="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1))
        echo "PASS: $name"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $name"
    fi
}

check_not() {
    local name="$1"
    shift
    if "$@"; then
        FAIL=$((FAIL + 1))
        echo "FAIL: $name"
    else
        PASS=$((PASS + 1))
        echo "PASS: $name"
    fi
}

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo "PASS: $name"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $name"
        echo "    expected: $expected"
        echo "    actual:   $actual"
    fi
}

# Define the named top-level function from a script (column-0 header through
# the first column-0 closing brace) in the current shell.
load_fn() {
    local file="$1" name="$2" body
    body=$(sed -n "/^${name}()/,/^}/p" "$file")
    if [[ -z "$body" ]]; then
        FAIL=$((FAIL + 1))
        echo "FAIL: could not extract ${name} from ${file}"
        return 1
    fi
    eval "$body"
}

# ------------------------------------------------------------
# Step 1: resolve_fqdn (A5) with stub host / nslookup
# ------------------------------------------------------------
echo "--- resolve_fqdn"
load_fn "$STEP1" resolve_fqdn

STUB="${TEST_DIR}/bin"
mkdir -p "$STUB"
cat > "${STUB}/host" <<'STUBEOF'
#!/bin/bash
case "$HOSTMODE" in
    aix)    echo "db1.corp.example.com is 10.1.2.3" ;;
    linux)  echo "db1.corp.example.com has address 10.1.2.3" ;;
    alias)  echo "db1 is an alias for db1x.corp.example.com."
            echo "db1x.corp.example.com has address 10.1.2.3" ;;
    none)   echo "Host db1 not found: 3(NXDOMAIN)"; exit 1 ;;
esac
STUBEOF
cat > "${STUB}/nslookup" <<'STUBEOF'
#!/bin/bash
printf 'Server:\t1.1.1.1\nAddress:\t1.1.1.1#53\n\nName:\tdb1.ns.example.com\nAddress: 10.1.2.3\n'
STUBEOF
chmod +x "${STUB}/host" "${STUB}/nslookup"

OLD_PATH="$PATH"
PATH="${STUB}:$PATH"
assert_eq "AIX 'name is a.b.c.d' form" "db1.corp.example.com" "$(HOSTMODE=aix resolve_fqdn db1)"
assert_eq "Linux 'name has address' form" "db1.corp.example.com" "$(HOSTMODE=linux resolve_fqdn db1)"
assert_eq "alias line is skipped, canonical name used" "db1x.corp.example.com" "$(HOSTMODE=alias resolve_fqdn db1)"
assert_eq "host fails -> nslookup Name: line" "db1.ns.example.com" "$(HOSTMODE=none resolve_fqdn db1)"
PATH="$OLD_PATH"

# ------------------------------------------------------------
# Step 1: extract_port / valid_port_or_empty (M2)
# ------------------------------------------------------------
echo "--- extract_port"
load_fn "$STEP1" extract_port
load_fn "$STEP1" valid_port_or_empty

assert_eq "port from the whole V\$LISTENER_NETWORK address" "1522" \
    "$(printf '%s\n' '(ADDRESS=(PROTOCOL=TCP)(HOST=db1)(PORT=1522))' | extract_port)"
assert_eq "port with spaces (lsnrctl style)" "1521" \
    "$(printf '%s\n' 'Connecting to (DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=h)(PORT = 1521)))' | extract_port)"
assert_eq "first of several addresses wins" "1521" \
    "$(printf '%s\n' '(ADDRESS_LIST=(ADDRESS=(HOST=a)(PORT=1521))(ADDRESS=(HOST=b)(PORT=1599)))' | extract_port)"
assert_eq "a host name containing 'port' is not a port" "1530" \
    "$(printf '%s\n' '(ADDRESS=(PROTOCOL=TCP)(HOST=transport1)(PORT=1530))' | extract_port)"
assert_eq "no PORT= yields nothing" "" \
    "$(printf '%s\n' '(ADDRESS=(PROTOCOL=IPC)(KEY=EXTPROC1521))' | extract_port)"
assert_eq "valid port passes" "1521" "$(valid_port_or_empty 1521)"
assert_eq "non-numeric rejected" "" "$(valid_port_or_empty '(PORT=1521)')"
assert_eq "zero rejected" "" "$(valid_port_or_empty 0)"
assert_eq "out of range rejected" "" "$(valid_port_or_empty 70000)"

# ------------------------------------------------------------
# Step 1: static checks
# ------------------------------------------------------------
echo "--- step 1 static checks"
_chk_line=$(grep -n 'Check mode: stopping before writing primary info' "$STEP1" | head -1 | cut -d: -f1)
_write_line=$(grep -n '^cat > "\$OUTPUT_FILE"' "$STEP1" | head -1 | cut -d: -f1)
_copy_line=$(grep -n 'umask 077; cp "\$PWD_FILE"' "$STEP1" | head -1 | cut -d: -f1)
check "check-mode stop exists and precedes the .env write" \
    test -n "$_chk_line" -a -n "$_write_line" -a "${_chk_line:-999999}" -lt "${_write_line:-0}"
check "check-mode stop precedes the password file copy" \
    test -n "$_copy_line" -a "${_chk_line:-999999}" -lt "${_copy_line:-0}"
check "password file copy runs under umask 077" test -n "$_copy_line"
check "password file also looked up by DB_NAME and read-only home" \
    grep -q 'orapw\${DB_NAME}' "$STEP1"
check "password file lookup asks the database first" \
    grep -q 'get_password_file_name.sql' "$STEP1"
check "redo path query is online-only and ordered" \
    grep -q "TYPE = 'ONLINE'" "${REPO_DIR}/sql/queries/get_redo_log_paths.sql"
check "redo size counts members and SRLs" \
    grep -q 'V\$STANDBY_LOG' "${REPO_DIR}/sql/queries/get_redolog_total_size.sql"
check "per-day redo average is not extrapolated under a day" \
    grep -q 'GREATEST(s.span_days, 1)' "${REPO_DIR}/sql/queries/get_redo_stats_pipe.sql"

# ------------------------------------------------------------
# Step 2: validators and pick_standby_for_primary
# ------------------------------------------------------------
echo "--- step 2 helpers"
load_fn "$STEP2" is_valid_db_unique_name
load_fn "$STEP2" is_valid_oracle_sid
load_fn "$STEP2" is_valid_hostname
load_fn "$STEP2" pick_standby_for_primary

check "db_unique_name: plain" is_valid_db_unique_name STBY_1
check "db_unique_name: 30 chars ok" is_valid_db_unique_name abcdefghijklmnopqrstuvwxyz0123
check_not "db_unique_name: 31 chars rejected" is_valid_db_unique_name abcdefghijklmnopqrstuvwxyz01234
check_not "db_unique_name: leading digit rejected" is_valid_db_unique_name 1STBY
check_not "db_unique_name: space rejected" is_valid_db_unique_name "ST BY"
check_not "db_unique_name: ; rejected" is_valid_db_unique_name 'a;b'
check_not "db_unique_name: dollar rejected" is_valid_db_unique_name 'a$b'
check_not "db_unique_name: quote rejected" is_valid_db_unique_name "a'b"
check_not "db_unique_name: empty rejected" is_valid_db_unique_name ""
check "sid: plain" is_valid_oracle_sid cdb1_s
check "sid: 12 chars ok" is_valid_oracle_sid abcdefghijkl
check_not "sid: 13 chars rejected" is_valid_oracle_sid abcdefghijklm
check_not "sid: dash rejected" is_valid_oracle_sid a-b
check "hostname: fqdn" is_valid_hostname stby-01.corp.example.com
check "hostname: ipv4" is_valid_hostname 10.1.2.3
check_not "hostname: space rejected" is_valid_hostname "a b"
check_not "hostname: leading dash rejected" is_valid_hostname -bad
check_not "hostname: slash rejected" is_valid_hostname "a/b"
check_not "hostname: backtick rejected" is_valid_hostname 'a`b'

PRI_D=("/u/PRIM/pdb" "/u/PRIM/sys")
STB_D=("/s/STBY/pdb" "/s/STBY/sys")
r=$(pick_standby_for_primary "/u/PRIM/sys" PRI_D STB_D); rc=$?
assert_eq "pick: matching primary entry" "/s/STBY/sys" "$r"
assert_eq "pick: match returns 0" "0" "$rc"
r=$(pick_standby_for_primary "/u/PRIM/sys/" PRI_D STB_D)
assert_eq "pick: trailing slash on the primary path ignored" "/s/STBY/sys" "$r"
r=$(pick_standby_for_primary "/nowhere" PRI_D STB_D); rc=$?
assert_eq "pick: no match falls back to first entry" "/s/STBY/pdb" "$r"
assert_eq "pick: no match returns 1" "1" "$rc"

# ------------------------------------------------------------
# Step 2: end to end against a scratch share, piped stdin
# ------------------------------------------------------------
echo "--- step 2 end to end"
NFS="${TEST_DIR}/nfs"
mkdir -p "$NFS"
write_primary_info() {
    # $1 = REMOTE_LOGIN_PASSWORDFILE value
    cat > "${NFS}/primary_info_PRIM.env" <<ENVEOF
DB_NAME="PRIM"
DB_UNIQUE_NAME="PRIM"
DB_DOMAIN=""
INSTANCE_NAME="PRIM"
DBID="123"
PRIMARY_HOSTNAME="pri.example.com"
PRIMARY_ORACLE_HOME="/u01/app/oracle/product/19c"
PRIMARY_ORACLE_BASE="/u01/app/oracle"
PRIMARY_ORACLE_SID="PRIM"
NLS_CHARACTERSET="AL32UTF8"
DB_BLOCK_SIZE="8192"
COMPATIBLE="19.0.0"
PRIMARY_DATA_PATH="/u01/oradata/PRIM/sys"
PRIMARY_DATA_PATHS=(
    "/u01/oradata/PRIM/pdb"
    "/u01/oradata/PRIM/sys"
)
PRIMARY_DATA_PATH_SIZES_MB=(
    "10"
    "20"
)
PRIMARY_REDO_PATH="/u02/redo/PRIM"
PRIMARY_REDO_PATHS=(
    "/u02/redo/PRIM"
)
PRIMARY_ARCHIVE_DEST="/u03/arch/PRIM"
CONTROL_FILES="x"
DB_RECOVERY_FILE_DEST=""
DB_RECOVERY_FILE_DEST_SIZE=""
USE_FRA_FOR_ARCHIVE="NO"
REDO_LOG_SIZE_MB="200"
ONLINE_REDO_GROUPS="3"
STANDBY_REDO_EXISTS="NO"
STANDBY_REDO_COUNT="0"
LISTENER_PORT="1521"
SERVICE_NAMES="PRIM"
LOG_MODE="ARCHIVELOG"
FORCE_LOGGING="YES"
REMOTE_LOGIN_PASSWORDFILE="$1"
DG_BROKER_START="TRUE"
ENVEOF
}
# Same sequence the E2E suite pipes: host, name, SID, storage, Q2, archive
# dir, separate SRL?, confirm.
INPUT='stby.example.com\nSTBY\n\n\n\n\n\ny\n'
run_step2() {
    # run_step2 <stdin-printf-format> [args...]
    local input="$1"
    shift
    printf "$input" | NFS_SHARE="$NFS" bash "$STEP2" "$@" 2>&1
}
list_share() { ls "$NFS" | grep -v '^logs$' | grep -v '^state$' | sort | tr '\n' ' '; }

write_primary_info EXCLUSIVE
before=$(list_share)
out=$(run_step2 "$INPUT" -n); rc=$?
assert_eq "check mode (normal): exit 0" "0" "$rc"
assert_eq "check mode (normal): nothing written to the share" "$before" "$(list_share)"
check "check mode (normal): says what it would write" \
    bash -c 'printf "%s" "$1" | grep -q "Check mode: stopping before writing the standby files"' _ "$out"

out=$(run_step2 "$INPUT"); rc=$?
assert_eq "normal run: exit 0" "0" "$rc"
check "normal run: .env written" test -f "${NFS}/standby_config_STBY.env"
check "normal run: pfile written" test -f "${NFS}/initPRIM_STBY.ora"
# M3: STANDBY_DATA_PATH is the SYSTEM datafile directory's counterpart, not
# the first (sorted) array entry (.../pdb).
check "M3: STANDBY_DATA_PATH follows PRIMARY_DATA_PATH" \
    grep -q '^STANDBY_DATA_PATH="/u01/oradata/STBY/sys"$' "${NFS}/standby_config_STBY.env"
check "M3: control files use that directory" \
    grep -q "control_files='/u01/oradata/STBY/sys/control01.ctl'" "${NFS}/initPRIM_STBY.ora"

# M4 + C3 (regenerate): edit only the array entry, keep a custom broker name
ENVF="${NFS}/standby_config_STBY.env"
sed 's|^    "/u01/oradata/STBY/sys"$|    "/mnt/new/STBY/sys"|; s|^DG_BROKER_CONFIG_NAME=.*|DG_BROKER_CONFIG_NAME="MY_CUSTOM"|' "$ENVF" > "${ENVF}.edit" && mv "${ENVF}.edit" "$ENVF"
cp "$ENVF" "${TEST_DIR}/edited.env"
out=$(run_step2 "" --regenerate -n); rc=$?
assert_eq "check mode (regenerate): exit 0" "0" "$rc"
check "check mode (regenerate): .env untouched" cmp -s "$ENVF" "${TEST_DIR}/edited.env"
out=$(run_step2 "" --regenerate); rc=$?
assert_eq "regenerate: exit 0" "0" "$rc"
check "M4: STANDBY_DATA_PATH re-derived from the edited array and persisted" \
    grep -q '^STANDBY_DATA_PATH="/mnt/new/STBY/sys"$' "$ENVF"
check "M4: convert strings follow the edited array" \
    grep -q "'/u01/oradata/PRIM/sys/','/mnt/new/STBY/sys/'" "$ENVF"
check "M4: control files in the pfile follow the edited array" \
    grep -q "control_files='/mnt/new/STBY/sys/control01.ctl'" "${NFS}/initPRIM_STBY.ora"
check "regenerate keeps a hand-edited DG_BROKER_CONFIG_NAME in the DGMGRL script" \
    grep -q "CREATE CONFIGURATION 'MY_CUSTOM'" "${NFS}/configure_broker_STBY.dgmgrl"
check "regenerate keeps the DG_BROKER_CONFIG_NAME line in the .env" \
    grep -q '^DG_BROKER_CONFIG_NAME="MY_CUSTOM"$' "$ENVF"

# SHARED password file is refused (step 1 refuses it too)
write_primary_info SHARED
rm -f "${NFS}"/standby_config_*.env
out=$(run_step2 "$INPUT" -n); rc=$?
assert_eq "REMOTE_LOGIN_PASSWORDFILE=SHARED: exit 1" "1" "$rc"
check "REMOTE_LOGIN_PASSWORDFILE=SHARED: names the problem" \
    bash -c 'printf "%s" "$1" | grep -q "REMOTE_LOGIN_PASSWORDFILE is not EXCLUSIVE"' _ "$out"
write_primary_info EXCLUSIVE

# Invalid typed values fail non-interactively without reading further
for bad in 'st by' 'a;b' '1abc'; do
    out=$(run_step2 "stby.example.com\n${bad}\n\n\n\n\n\ny\n" -n); rc=$?
    assert_eq "invalid DB_UNIQUE_NAME '${bad}': exit 1" "1" "$rc"
done
out=$(run_step2 'bad host\nSTBY\n' -n); rc=$?
assert_eq "invalid hostname: exit 1" "1" "$rc"
out=$(run_step2 'h.example.com\nSTBY\nbad sid!\n' -n); rc=$?
assert_eq "invalid ORACLE_SID: exit 1" "1" "$rc"

echo ""
echo "============================================================"
echo "Test Summary: ${PASS} passed, ${FAIL} failed"
echo "============================================================"
[[ $FAIL -eq 0 ]]
