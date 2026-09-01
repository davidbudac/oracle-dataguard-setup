#!/bin/bash
# ============================================================
# Unit tests for dg_handoff.sh
# ============================================================
# Pure bash, no database. A stub `sqlplus` on PATH dispatches on the
# "-- QTAG:<name>" marker embedded in every query dg_handoff.sh issues and
# returns canned pipe-delimited rows; a stub `$ORACLE_HOME/bin/dgmgrl`
# dispatches on the command piped to it. Everything is created inside one
# mktemp -d scratch directory that is removed on exit.
#
# Stub behavior is steered with environment variables:
#   DGSTUB_ROLE        "standby" -> V$DATABASE reports PHYSICAL STANDBY/MOUNTED
#   DGSTUB_PROT        protection mode (default MAXIMUM AVAILABILITY)
#   DGSTUB_SWITCHOVER  switchover status (default TO STANDBY)
#   DGSTUB_BROKER      dg_broker_start value (default TRUE)
#   DGSTUB_APPLY_INFO  "applied|received" (default 412|412)
#   DGSTUB_GAPS        V$ARCHIVE_GAP count (default 0)
#   DGSTUB_FSFO        "off" -> FSFO disabled
#   DGSTUB_TRIGGER     role-trigger status row (default 1|2|2|SYS)
#   DGSTUB_EXTRA_SVC   name of a second USER service to report
#   DGSTUB_APPLY_LAG   broker Apply Lag text (default "3 seconds")
#   DGSTUB_CFG         "error" -> SHOW CONFIGURATION reports ERROR + ORA-16810
#   DGSTUB_FAIL_TAGS   space-separated QTAGs whose query exits 1 (ORA-00942)
#   DGSTUB_DIRECT      "1" -> the standby_direct query answers (scenario 9)
#
# Usage: bash tests/test_handoff.sh
#
# Don't use set -e as we need to test for failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT="$REPO_DIR/dg_handoff.sh"

PASS=0
FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    missing: $needle"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  FAIL: $name"
        echo "    unexpectedly present: $needle"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    fi
}

assert_file() {
    local name="$1" path="$2"
    if [[ -f "$path" ]]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    missing file: $path"
        FAIL=$((FAIL + 1))
    fi
}

assert_no_file() {
    local name="$1" path="$2"
    if [[ -f "$path" ]]; then
        echo "  FAIL: $name"
        echo "    unexpected file: $path"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    fi
}

note_skip() { echo "  SKIP: $1"; }

# ---- test environment ----

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/dg_handoff_test.XXXXXX") || {
    echo "FATAL: cannot create temp dir"; exit 1; }
trap 'rm -rf "$TEST_TMP"' EXIT

STUB_BIN="$TEST_TMP/bin"
OH="$TEST_TMP/oh"
ERR_FILE="$TEST_TMP/stderr.out"
mkdir -p "$STUB_BIN" "$OH/bin" "$OH/network/admin"

printf 'NAMES.DIRECTORY_PATH = (TNSNAMES, EZCONNECT)\nSQLNET.EXPIRE_TIME = 10\n' \
    > "$OH/network/admin/sqlnet.ora"

# ---- stub sqlplus ------------------------------------------------------
cat > "$STUB_BIN/sqlplus" <<'STUB'
#!/bin/bash
# Reads the SQL from stdin and dispatches on the "-- QTAG:<name>" marker.
IN=$(cat)
TAG=$(printf '%s\n' "$IN" | sed -n 's/^-- QTAG:\([A-Za-z0-9_]*\).*$/\1/p' | head -1)

case " ${DGSTUB_FAIL_TAGS:-} " in
    *" ${TAG} "*)
        echo "ORA-00942: table or view does not exist"
        exit 1
        ;;
esac

case "$TAG" in
connect_check)        echo "OK" ;;
local_db_unique_name) echo "cdb1" ;;
db_status)
    if [ "${DGSTUB_ROLE:-primary}" = "standby" ]; then
        echo "PHYSICAL STANDBY|MOUNTED|${DGSTUB_PROT:-MAXIMUM AVAILABILITY}|NOT ALLOWED"
    else
        echo "PRIMARY|READ WRITE|${DGSTUB_PROT:-MAXIMUM AVAILABILITY}|${DGSTUB_SWITCHOVER:-TO STANDBY}"
    fi
    ;;
force_logging)        echo "YES" ;;
dg_broker_start)      echo "${DGSTUB_BROKER:-TRUE}" ;;
peer_db_unique_name)  echo "cdb1_stby" ;;
apply_info)           echo "${DGSTUB_APPLY_INFO:-412|412}" ;;
archive_gap_count)    echo "${DGSTUB_GAPS:-0}" ;;
fsfo_status)
    if [ "${DGSTUB_FSFO:-on}" = "off" ]; then
        echo "DISABLED||"
    else
        echo "TARGET UNDER LAG LIMIT|YES|obs1.example.com"
    fi
    ;;
role_trigger_status)  echo "${DGSTUB_TRIGGER:-1|2|2|SYS}" ;;
local_listener)       echo "(ADDRESS=(PROTOCOL=TCP)(HOST=pri.example.com)(PORT=1521))" ;;
is_cdb)               echo "YES" ;;
db_version_full)      echo "19.23.0.0.0" ;;
db_version)           echo "19.0.0.0.0" ;;
db_charset)           echo "AL32UTF8" ;;
db_domain)            echo "example.com" ;;
active_services)
    echo "PDB1|app_svc|USER"
    [ -n "${DGSTUB_EXTRA_SVC:-}" ] && echo "PDB1|${DGSTUB_EXTRA_SVC}|USER"
    echo "CDB\$ROOT|cdb1.example.com|DEFAULT"
    echo "PDB1|pdb1|DEFAULT"
    ;;
service_ha_attributes)
    echo "PDB1|app_svc|SELECT|BASIC|30|5|YES|60|NONE"
    [ -n "${DGSTUB_EXTRA_SVC:-}" ] && echo "PDB1|${DGSTUB_EXTRA_SVC}|NONE|-|-|-|NO|-|NONE"
    echo "CDB\$ROOT|cdb1.example.com|NONE|-|-|-|NO|-|NONE"
    echo "PDB1|PDB1|NONE|-|-|-|NO|-|NONE"
    ;;
standby_direct)
    if [ "${DGSTUB_DIRECT:-0}" = "1" ]; then
        echo "OPENMODE=READ ONLY WITH APPLY"
        echo "DGSTAT=apply lag=+00 00:00:07"
        echo "DGSTAT=transport lag=+00 00:00:01"
    fi
    ;;
*)  ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/sqlplus"

# ---- stub dgmgrl -------------------------------------------------------
cat > "$OH/bin/dgmgrl" <<'STUB'
#!/bin/bash
# Reads the command from stdin (first line) and prints canned broker output.
CMD=$(head -1)
case "$CMD" in
"SHOW CONFIGURATION;")
    echo "Configuration - dg_config"
    echo ""
    echo "  Protection Mode: MaxAvailability"
    echo "  Members:"
    echo "  cdb1      - Primary database"
    echo "    cdb1_stby - Physical standby database"
    echo ""
    echo "Fast-Start Failover:  Enabled in Zero Data Loss Mode"
    echo ""
    echo "Configuration Status:"
    if [ "${DGSTUB_CFG:-ok}" = "error" ]; then
        echo "ERROR   (status updated 12 seconds ago)"
        echo "ORA-16810: multiple errors or warnings detected for the member"
    else
        echo "SUCCESS   (status updated 45 seconds ago)"
    fi
    ;;
*"VERBOSE 'cdb1_stby'"*)
    echo "Database - cdb1_stby"
    echo "  HostName                        = 'stb.example.com'"
    echo "  DGConnectIdentifier             = 'cdb1_stby'"
    ;;
*"VERBOSE 'cdb1'"*)
    echo "Database - cdb1"
    echo "  HostName                        = 'pri.example.com'"
    echo "  DGConnectIdentifier             = 'cdb1'"
    ;;
*"'LogXptMode'"*)
    echo "  LogXptMode = 'FASTSYNC'"
    ;;
*"'FastStartFailoverThreshold'"*)
    echo "  FastStartFailoverThreshold = '30'"
    ;;
"SHOW FAST_START FAILOVER;")
    echo "Fast-Start Failover:  Enabled in Zero Data Loss Mode"
    echo "  Threshold:          30 seconds"
    ;;
"SHOW DATABASE "*)
    echo "Database - cdb1_stby"
    echo ""
    echo "  Role:               PHYSICAL STANDBY"
    echo "  Intended State:     APPLY-ON"
    echo "  Transport Lag:      0 seconds (computed 1 second ago)"
    echo "  Apply Lag:          ${DGSTUB_APPLY_LAG:-3 seconds} (computed 1 second ago)"
    echo "  Average Apply Rate: 12.00 KByte/s"
    echo "  Real Time Query:    ON"
    echo "  Instance(s):"
    echo "    cdb1"
    echo ""
    echo "Database Status:"
    echo "SUCCESS"
    ;;
*)  ;;
esac
exit 0
STUB
chmod +x "$OH/bin/dgmgrl"

# run_handoff <dirname> [args...] - runs dg_handoff.sh with -o <dir>/dg_handoff_cdb1.md
# Sets MD (report path), MDC (report content), OUT, ERR, RC.
run_handoff() {
    local dir="$1"; shift
    RUN_DIR="$TEST_TMP/$dir"
    mkdir -p "$RUN_DIR"
    MD="$RUN_DIR/dg_handoff_cdb1.md"
    OUT=$(PATH="$STUB_BIN:$PATH" ORACLE_SID=cdb1 ORACLE_HOME="$OH" \
          bash "$SCRIPT" -o "$MD" "$@" 2>"$ERR_FILE")
    RC=$?
    ERR=$(cat "$ERR_FILE")
    MDC=$(cat "$MD" 2>/dev/null)
    JSON="$RUN_DIR/dg_handoff_cdb1.json"
    JSONC=$(cat "$JSON" 2>/dev/null)
}

# ============================================================
# Test 1: happy path
# ============================================================
echo "Test 1: happy path - HEALTHY report plus the full deliverable pack"
run_handoff run1
assert_eq "happy path rc" "0" "$RC"
assert_contains "verdict healthy" "$MDC" "**Verdict:** HEALTHY"
assert_contains "report title" "$MDC" "# Data Guard Handoff Report"
assert_file "markdown written"  "$RUN_DIR/dg_handoff_cdb1.md"
assert_file "html written"      "$RUN_DIR/dg_handoff_cdb1.html"
assert_file "json written"      "$RUN_DIR/dg_handoff_cdb1.json"
assert_file "tnsnames written"  "$RUN_DIR/dg_handoff_cdb1_tnsnames.ora"
assert_file "jdbc written"      "$RUN_DIR/dg_handoff_cdb1_jdbc.properties"
assert_file "verify written"    "$RUN_DIR/dg_handoff_cdb1_verify.sh"
VERIFY_SH="$RUN_DIR/dg_handoff_cdb1_verify.sh"
if [[ -x "$VERIFY_SH" ]]; then
    echo "  PASS: verify script is executable"; PASS=$((PASS + 1))
else
    echo "  FAIL: verify script is executable"; FAIL=$((FAIL + 1))
fi
if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$JSON" 2>"$TEST_TMP/json.err"; then
        echo "  PASS: JSON sidecar parses"; PASS=$((PASS + 1))
    else
        echo "  FAIL: JSON sidecar parses"; sed 's/^/    /' "$TEST_TMP/json.err"
        FAIL=$((FAIL + 1))
    fi
else
    note_skip "JSON sidecar parses (no python3 on this host)"
fi
assert_contains "json verdict"     "$JSONC" '"verdict": "HEALTHY"'
assert_contains "json apply lag s" "$JSONC" '"apply_lag_seconds": "3"'
assert_contains "json services"    "$JSONC" '{"name": "app_svc"'
# At a Glance facts
assert_contains "glance freshness" "$MDC" "**Standby data freshness:** apply lag 3 seconds (computed 1 second ago)"
assert_contains "glance readable"  "$MDC" "readable (READ ONLY WITH APPLY"
assert_contains "glance rpo"       "$MDC" "RPO = 0 while synchronized (MAXIMUM AVAILABILITY, transport FASTSYNC)"
# Role-aware descriptor for the user service
assert_contains "role-aware alias"   "$MDC" "APP_SVC_HA ="
assert_contains "descriptor primary" "$MDC" "(ADDRESS = (PROTOCOL = TCP)(HOST = pri.example.com)(PORT = 1521))"
assert_contains "descriptor standby" "$MDC" "(ADDRESS = (PROTOCOL = TCP)(HOST = stb.example.com)(PORT = 1521))"
assert_contains "service section"    "$MDC" '### Service: `app_svc`'
# Default services are flagged
assert_contains "default flagged"    "$MDC" "**Default service — NOT role-aware.**"
assert_contains "default pdb1"       "$MDC" '### Service: `pdb1`'
# Change tracking baseline
assert_contains "first report" "$MDC" "First report for this configuration"
# Nothing to recommend: app_svc already has TAF + TG + drain
assert_contains "no dba recommendations" "$MDC" "All user services already carry TAF, Transaction Guard and a drain timeout"
assert_not_contains "no dbms_service block" "$MDC" "dbms_service.modify_service(service_name => 'app_svc'"
# Impact reference auto-detected from docs/
assert_contains "sqlnet expire time" "$MDC" "| SQLNET.EXPIRE_TIME | 10 minutes |"
assert_not_contains "no discovery warnings" "$MDC" "### Discovery Warnings"

cp "$JSON" "$TEST_TMP/baseline1.json"

# ============================================================
# Test 2: second run in the same directory
# ============================================================
echo "Test 2: re-run against its own sidecar reports no changes"
run_handoff run1
assert_eq "second run rc" "0" "$RC"
assert_contains "no changes" "$MDC" "No changes since the previous report"

# ============================================================
# Test 3: third run with a changed topology and descriptor knobs
# ============================================================
echo "Test 3: changed protection mode, new service and --connect-timeout"
DGSTUB_EXTRA_SVC=rpt_svc DGSTUB_PROT="MAXIMUM PERFORMANCE" \
    run_handoff run1 --connect-timeout 20
assert_eq "third run rc" "0" "$RC"
assert_contains "changes header" "$MDC" "Compared against the previous JSON sidecar"
assert_contains "protection mode row" "$MDC" "| Protection mode | MAXIMUM AVAILABILITY | MAXIMUM PERFORMANCE |"
assert_contains "connect timeout row" "$MDC" "| CONNECT_TIMEOUT | 10 | 20 |"
assert_contains "service added" "$MDC" "**Services added:**"
assert_contains "rpt_svc added" "$MDC" '- `rpt_svc`'
# DBA recommendations for the bare new service, inside its PDB
assert_contains "rec heading"    "$MDC" '#### `rpt_svc`'
assert_contains "rec missing"    "$MDC" "Missing: TAF, Transaction Guard, drain timeout."
assert_contains "rec container"  "$MDC" "ALTER SESSION SET CONTAINER = PDB1;"
assert_contains "rec modify"     "$MDC" "dbms_service.modify_service(service_name => 'rpt_svc'"
# Descriptor math derived from the overridden knob
assert_contains "descriptor ct row" "$MDC" "| CONNECT_TIMEOUT | 20 s |"
assert_contains "ez connect ct"     "$MDC" "connect_timeout=20&transport_connect_timeout=3&retry_count=3"
# WORST_PRI_S = 3*(3+1) + 3*3 = 21 -> pool timeout 26; ONE_PASS_MAX_S = 2*20 = 40
assert_contains "pool timeout"      "$MDC" "Pool connection-wait/checkout timeout of at least 26 s"
assert_contains "one pass bound"    "$MDC" "one pass over the ADDRESS_LIST can take up to 40 s"
assert_contains "worst both"        "$MDC" "about 33 s"

# ============================================================
# Test 4: --previous against an explicit baseline
# ============================================================
echo "Test 4: --previous diffs against the named sidecar"
DGSTUB_PROT="MAXIMUM PERFORMANCE" \
    run_handoff run4 --previous "$TEST_TMP/baseline1.json"
assert_eq "previous run rc" "0" "$RC"
assert_not_contains "not a first report" "$MDC" "First report for this configuration"
assert_contains "previous baseline diff" "$MDC" "| Protection mode | MAXIMUM AVAILABILITY | MAXIMUM PERFORMANCE |"

# ============================================================
# Test 5: verdicts
# ============================================================
echo "Test 5: verdict escalation"
DGSTUB_GAPS=2 run_handoff v_gap
assert_eq "archive gaps rc" "2" "$RC"
assert_contains "archive gaps verdict" "$MDC" "**Verdict:** ERROR"
assert_contains "archive gaps note" "$MDC" "2 archive gap(s) detected"

DGSTUB_APPLY_LAG="5 minutes" run_handoff v_lag
assert_eq "apply lag rc" "1" "$RC"
assert_contains "apply lag verdict" "$MDC" "**Verdict:** WARNING"
assert_contains "apply lag note" "$MDC" "Apply lag is 5 minutes (computed 1 second ago) (threshold 60s)"

DGSTUB_CFG=error run_handoff v_cfg
assert_eq "broker config error rc" "2" "$RC"
assert_contains "broker config verdict" "$MDC" "**Verdict:** ERROR"
assert_contains "broker config note" "$MDC" "Broker Configuration Status is ERROR"

DGSTUB_TRIGGER="0|0|0|NONE" run_handoff v_trg
assert_eq "role trigger rc" "1" "$RC"
assert_contains "role trigger note" "$MDC" "Role-aware service trigger is not deployed/enabled"
assert_contains "role trigger status row" "$MDC" "| Role trigger ready | NO (NONE) |"

DGSTUB_ROLE=standby run_handoff v_stb
assert_eq "standby role rc" "1" "$RC"
assert_contains "standby role note" "$MDC" "Local role is PHYSICAL STANDBY, expected PRIMARY"
assert_contains "standby in-report warning" "$MDC" "**WARNING:** This report was generated on the PHYSICAL STANDBY side."

DGSTUB_BROKER=FALSE run_handoff v_brk --standby-host stb.example.com
assert_eq "broker down rc" "1" "$RC"
assert_contains "broker down note" "$MDC" "Data Guard Broker is not started"
assert_contains "broker down standby host" "$MDC" "(HOST = stb.example.com)"
assert_not_contains "broker down has no broker appendix" "$MDC" "### Broker Configuration"

# ============================================================
# Test 6: service filters
# ============================================================
echo "Test 6: --service / --exclude-service"
run_handoff f_only --service PDB1:APP_SVC
assert_eq "service filter rc" "0" "$RC"
assert_contains "filter keeps app_svc" "$MDC" '### Service: `app_svc`'
assert_not_contains "filter drops pdb1"   "$MDC" '### Service: `pdb1`'
assert_not_contains "filter drops root"   "$MDC" '### Service: `cdb1.example.com`'
assert_contains "filter chip" "$MDC" "**Service filter:** only PDB1:APP_SVC"
assert_contains "json records filter" "$JSONC" '"PDB1:APP_SVC"'

run_handoff f_excl --exclude-service pdb1
assert_eq "exclude rc" "0" "$RC"
assert_not_contains "excluded pdb1" "$MDC" '### Service: `pdb1`'
assert_contains "exclude keeps app_svc" "$MDC" '### Service: `app_svc`'
assert_contains "exclude chip" "$MDC" "excluding pdb1"

run_handoff f_miss --service nosuch
assert_eq "missing service rc" "1" "$RC"
assert_contains "missing service note" "$MDC" "Requested service nosuch not found among active services"

# ============================================================
# Test 7: flags
# ============================================================
echo "Test 7: flag handling"
run_handoff fl_nojson --no-json
assert_eq "--no-json rc" "0" "$RC"
assert_no_file "--no-json writes no sidecar" "$RUN_DIR/dg_handoff_cdb1.json"
assert_not_contains "--no-json drops changes section" "$MDC" "## Changes Since Last Report"

run_handoff fl_nopack --no-pack
assert_eq "--no-pack rc" "0" "$RC"
assert_no_file "--no-pack writes no tnsnames" "$RUN_DIR/dg_handoff_cdb1_tnsnames.ora"
assert_no_file "--no-pack writes no jdbc"     "$RUN_DIR/dg_handoff_cdb1_jdbc.properties"
assert_no_file "--no-pack writes no verify"   "$RUN_DIR/dg_handoff_cdb1_verify.sh"

run_handoff fl_bad --retry-count abc
assert_eq "bad --retry-count rc" "3" "$RC"
assert_contains "bad --retry-count message" "$ERR" "RETRY_COUNT must be a non-negative integer"

run_handoff fl_unknown --bogus
assert_eq "unknown flag rc" "3" "$RC"

OUT=$(PATH="$STUB_BIN:$PATH" ORACLE_SID="" ORACLE_HOME="$OH" \
      bash "$SCRIPT" 2>"$ERR_FILE"); RC=$?
ERR=$(cat "$ERR_FILE")
assert_eq "missing ORACLE_SID rc" "3" "$RC"
assert_contains "missing ORACLE_SID message" "$ERR" "ORACLE_SID is not set"

run_handoff fl_flavors --all-flavors
assert_eq "--all-flavors rc" "0" "$RC"
assert_contains "primary-only alias" "$MDC" "APP_SVC_PRI ="
assert_contains "standby-only alias" "$MDC" "APP_SVC_STB ="
assert_not_contains "no PRI alias by default" "$(cat "$TEST_TMP/run4/dg_handoff_cdb1.md")" "APP_SVC_PRI ="

run_handoff fl_impact --impact-reference /x/y.html
assert_eq "--impact-reference rc" "0" "$RC"
assert_contains "impact reference line" "$MDC" 'Full application behavior briefing: `/x/y.html`'

run_handoff fl_chips --env PROD --contact "dba@x"
assert_eq "--env/--contact rc" "0" "$RC"
assert_contains "env chip"     "$MDC" "- **Environment:** PROD"
assert_contains "contact chip" "$MDC" "- **Contact:** dba@x"

# ============================================================
# Test 8: per-query degradation
# ============================================================
echo "Test 8: a failing discovery query degrades its section, not the run"
DGSTUB_FAIL_TAGS="service_ha_attributes db_charset" run_handoff degr
assert_eq "degraded rc" "0" "$RC"
assert_contains "discovery warnings section" "$MDC" "### Discovery Warnings"
assert_contains "warns about HA attributes" "$MDC" "service HA attributes (CDB_SERVICES"
assert_contains "warns about charset"       "$MDC" "database character set (NLS_DATABASE_PARAMETERS)"
assert_contains "HA lines degrade"          "$MDC" "HA attributes could not be discovered for this service"

# ============================================================
# Test 9: direct standby query
# ============================================================
echo "Test 9: --standby-tns-alias overrides the broker's lag and open mode"
DGSTUB_DIRECT=1 run_handoff direct --standby-tns-alias stby_alias
assert_eq "direct standby rc" "0" "$RC"
assert_contains "direct open mode" "$MDC" "| Standby open mode | READ ONLY WITH APPLY |"
assert_contains "direct apply lag" "$MDC" "| Apply lag (time) | 7 seconds |"
assert_contains "direct transport lag" "$MDC" "| Transport lag (time) | 1 seconds |"
assert_contains "glance uses direct lag" "$MDC" "**Standby data freshness:** apply lag 7 seconds, transport lag 1 seconds."
assert_not_contains "broker lag not used" "$MDC" "| Apply lag (time) | 3 seconds (computed 1 second ago) |"

# ============================================================
# Test 10: the generated verification script
# ============================================================
echo "Test 10: generated _verify.sh is syntactically valid and runnable"
if bash -n "$VERIFY_SH" 2>"$TEST_TMP/vn.err"; then
    echo "  PASS: verify script parses (bash -n)"; PASS=$((PASS + 1))
else
    echo "  FAIL: verify script parses (bash -n)"; sed 's/^/    /' "$TEST_TMP/vn.err"
    FAIL=$((FAIL + 1))
fi

VBIN="$TEST_TMP/verifybin"
mkdir -p "$VBIN"
printf '#!/bin/bash\nexit 0\n' > "$VBIN/getent"
printf '#!/bin/bash\nexit 0\n' > "$VBIN/nc"
cat > "$VBIN/sqlplus" <<'VSTUB'
#!/bin/bash
cat >/dev/null
echo "DGCHK=cdb1|PRIMARY|pri.example.com"
exit 0
VSTUB
chmod +x "$VBIN/getent" "$VBIN/nc" "$VBIN/sqlplus"

VOUT=$(PATH="$VBIN:$PATH" bash "$VERIFY_SH" --help 2>&1); VRC=$?
assert_eq "verify --help rc" "0" "$VRC"
assert_contains "verify --help usage" "$VOUT" "Usage:"

VOUT=$(PATH="$VBIN:$PATH" APP_USER=app APP_PASSWORD=pw bash "$VERIFY_SH" 2>&1); VRC=$?
assert_eq "verify run rc" "0" "$VRC"
assert_contains "verify resolves primary" "$VOUT" "PASS  resolve pri.example.com"
assert_contains "verify tcp standby"      "$VOUT" "PASS  tcp stb.example.com:1521"
assert_contains "verify role check"       "$VOUT" "PASS  DATABASE_ROLE is PRIMARY"
assert_contains "verify db unique name"   "$VOUT" "PASS  DB_UNIQUE_NAME is cdb1"

VOUT=$(PATH="$VBIN:$PATH" APP_USER=app APP_PASSWORD=pw \
       bash "$VERIFY_SH" --expect-db-unique-name cdb1_stby 2>&1); VRC=$?
if [[ "$VRC" -ne 0 ]]; then
    echo "  PASS: verify fails on the wrong DB_UNIQUE_NAME"; PASS=$((PASS + 1))
else
    echo "  FAIL: verify fails on the wrong DB_UNIQUE_NAME (rc=$VRC)"; FAIL=$((FAIL + 1))
fi
assert_contains "verify names the mismatch" "$VOUT" "expected cdb1_stby"

# ============================================================
# Test 11: the HTML renderer under a non-GNU awk (AIX proxy)
# ============================================================
echo "Test 11: HTML output is identical under a POSIX awk"
ALT_AWK=""
for c in mawk busybox; do
    command -v "$c" >/dev/null 2>&1 && { ALT_AWK="$c"; break; }
done
if [[ -z "$ALT_AWK" ]]; then
    note_skip "HTML renderer under an alternative awk (no mawk/busybox installed)"
else
    AWKBIN="$TEST_TMP/awkbin"
    mkdir -p "$AWKBIN"
    if [[ "$ALT_AWK" == "busybox" ]]; then
        printf '#!/bin/bash\nexec busybox awk "$@"\n' > "$AWKBIN/awk"
    else
        printf '#!/bin/bash\nexec mawk "$@"\n' > "$AWKBIN/awk"
    fi
    chmod +x "$AWKBIN/awk"
    mkdir -p "$TEST_TMP/awkrun"
    PATH="$AWKBIN:$STUB_BIN:$PATH" ORACLE_SID=cdb1 ORACLE_HOME="$OH" \
        bash "$SCRIPT" -o "$TEST_TMP/awkrun/dg_handoff_cdb1.md" >/dev/null 2>&1
    ARC=$?
    assert_eq "alternative-awk run rc" "0" "$ARC"
    # Same input rendered with the default awk, for comparison.
    mkdir -p "$TEST_TMP/gnurun"
    PATH="$STUB_BIN:$PATH" ORACLE_SID=cdb1 ORACLE_HOME="$OH" \
        bash "$SCRIPT" -o "$TEST_TMP/gnurun/dg_handoff_cdb1.md" >/dev/null 2>&1
    # The generation timestamp/host chips are the only intentional difference
    # between two runs, so they are filtered out of the comparison.
    grep -v 'Generated' "$TEST_TMP/gnurun/dg_handoff_cdb1.html" > "$TEST_TMP/html.gnu"
    grep -v 'Generated' "$TEST_TMP/awkrun/dg_handoff_cdb1.html" > "$TEST_TMP/html.alt"
    if diff -u "$TEST_TMP/html.gnu" "$TEST_TMP/html.alt" > "$TEST_TMP/html.diff" 2>&1; then
        echo "  PASS: HTML identical under $ALT_AWK"; PASS=$((PASS + 1))
    else
        echo "  FAIL: HTML identical under $ALT_AWK"
        head -40 "$TEST_TMP/html.diff" | sed 's/^/    /'
        FAIL=$((FAIL + 1))
    fi
fi

# ==== Summary ====
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
