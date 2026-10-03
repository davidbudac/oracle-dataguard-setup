#!/usr/bin/env bash
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
#   DGSTUB_TRIGGER     role-trigger status row: ready-count|ready-owners|all-owners|detail
#                      (default 1|SYS|SYS|SYS spec=VALID,body=VALID,chg=OK,startup=OK)
#   DGSTUB_EXTRA_SVC   name of a second USER service to report
#   DGSTUB_APPLY_LAG   broker Apply Lag text (default "3 seconds")
#   DGSTUB_CFG         "error" -> SHOW CONFIGURATION reports ERROR + ORA-16810;
#                      "warn" -> WARNING + a member-level "Warning: ORA-16789";
#                      "disabled" -> DISABLED; "empty" -> no output at all
#   DGSTUB_FSFO_SHOW   "none" -> SHOW FAST_START FAILOVER prints nothing
#                      (forces the SHOW CONFIGURATION FastStartFailoverThreshold fallback);
#                      "all-none" -> neither command prints the threshold
#   DGSTUB_FAIL_TAGS   space-separated QTAGs whose query exits 1 (ORA-00942)
#   DGSTUB_DIRECT      "1" -> the standby_direct query answers (scenario 9)
#   DGSTUB_DIRECT_GAPS V$ARCHIVE_GAP count the standby reports (default 0)
#
# Usage: bash tests/test_handoff.sh
#
# Don't use set -e as we need to test for failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT="$REPO_DIR/dg_handoff.sh"

PASS=0
FAIL=0

# The sqlnet.ora lookup honours TNS_ADMIN; a developer's own value must not
# leak into the fixtures (the tests that need it set it explicitly).
unset TNS_ADMIN

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
role_trigger_status)  echo "${DGSTUB_TRIGGER:-1|SYS|SYS|SYS spec=VALID,body=VALID,chg=OK,startup=OK}" ;;
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
        echo "ARCHGAP=${DGSTUB_DIRECT_GAPS:-0}"
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
    [ "${DGSTUB_CFG:-ok}" = "empty" ] && exit 0
    echo "Configuration - dg_config"
    echo ""
    echo "  Protection Mode: MaxAvailability"
    echo "  Members:"
    echo "  cdb1      - Primary database"
    if [ "${DGSTUB_CFG:-ok}" = "warn" ]; then
        echo "    Warning: ORA-16789: standby redo logs configured incorrectly"
    fi
    echo "    cdb1_stby - Physical standby database"
    echo ""
    echo "Fast-Start Failover:  Enabled in Zero Data Loss Mode"
    echo ""
    echo "Configuration Status:"
    case "${DGSTUB_CFG:-ok}" in
    error)
        echo "ERROR   (status updated 12 seconds ago)"
        echo "ORA-16810: multiple errors or warnings detected for the member"
        ;;
    warn)     echo "WARNING   (status updated 12 seconds ago)" ;;
    disabled) echo "DISABLED" ;;
    *)        echo "SUCCESS   (status updated 45 seconds ago)" ;;
    esac
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
"SHOW CONFIGURATION FastStartFailoverThreshold;")
    [ "${DGSTUB_FSFO_SHOW:-}" = "all-none" ] && exit 0
    echo "Configuration - dg_config"
    echo "  FastStartFailoverThreshold = '30'"
    ;;
"SHOW FAST_START FAILOVER;")
    case "${DGSTUB_FSFO_SHOW:-}" in none|all-none) exit 0 ;; esac
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

DGSTUB_TRIGGER="0|NONE|NONE|NONE" run_handoff v_trg
assert_eq "role trigger rc" "1" "$RC"
assert_contains "role trigger note" "$MDC" "Role-aware service trigger is not deployed and valid: the DG_SERVICE_MGR package and both triggers are not deployed"
assert_contains "role trigger note carries an action" "$MDC" "— run trigger/create_role_trigger.sh"
assert_contains "role trigger status row" "$MDC" "| Role trigger ready | NO (NONE) |"
assert_contains "role trigger problem row" "$MDC" "| Role trigger problem | the DG_SERVICE_MGR package and both triggers are not deployed |"

# Finding 9: readiness needs ONE owner with a VALID package spec AND body and
# both triggers ENABLED and VALID. Each case below is a stub answer in the
# "ready-count|ready-owners|all-owners|detail" layout.
echo "Test: role-trigger readiness predicates"
trigger_case() {
    # $1 label, $2 stub row, $3 expected READY (YES/NO), $4 fragment expected in the problem text ('' = none)
    DGSTUB_TRIGGER="$2" run_handoff "v_trg_$1"
    assert_contains "trigger case $1: status row" "$MDC" "| Role trigger ready | $3 ("
    if [[ "$3" == "YES" ]]; then
        assert_eq "trigger case $1: healthy rc" "0" "$RC"
        assert_not_contains "trigger case $1: no trigger verdict note" "$MDC" "Role-aware service trigger is not deployed and valid"
        assert_not_contains "trigger case $1: no trigger warning" "$MDC" "role-aware service objects are not deployed and valid"
        assert_contains "trigger case $1: deployed-and-valid wording" "$MDC" "deployed and valid under"
    else
        assert_eq "trigger case $1: rc is WARNING" "1" "$RC"
        assert_contains "trigger case $1: verdict note" "$MDC" "Role-aware service trigger is not deployed and valid: "
        assert_contains "trigger case $1: problem text" "$MDC" "$4"
        assert_contains "trigger case $1: action attached" "$MDC" "trigger/create_role_trigger.sh"
    fi
}
trigger_case invalid_body "0|NONE|SYS|SYS spec=VALID,body=INVALID,chg=OK,startup=OK" NO "package body not VALID (INVALID)"
trigger_case invalid_trg  "0|NONE|SYS|SYS spec=VALID,body=VALID,chg=OK,startup=INVALID" NO "trigger TRG_MANAGE_SERVICES_STARTUP invalid"
trigger_case disabled_trg "0|NONE|SYS|SYS spec=VALID,body=VALID,chg=DISABLED,startup=OK" NO "trigger TRG_MANAGE_SERVICES_ROLE_CHG disabled"
trigger_case missing_trg  "0|NONE|SYS|SYS spec=VALID,body=VALID,chg=OK,startup=MISSING" NO "trigger TRG_MANAGE_SERVICES_STARTUP missing"
trigger_case missing_body "0|NONE|SYS|SYS spec=VALID,body=MISSING,chg=OK,startup=OK" NO "package body missing"
trigger_case split_owners "0|NONE|DG_ADMIN,SYS|DG_ADMIN spec=MISSING,body=MISSING,chg=OK,startup=OK;SYS spec=VALID,body=VALID,chg=MISSING,startup=MISSING" NO "objects are split across owners"
assert_contains "trigger split case names each owner" "$MDC" "DG_ADMIN (package spec missing, package body missing)"
trigger_case both_variants "2|DG_ADMIN,SYS|DG_ADMIN,SYS|DG_ADMIN spec=VALID,body=VALID,chg=OK,startup=OK;SYS spec=VALID,body=VALID,chg=OK,startup=OK" NO "more than one owner (DG_ADMIN,SYS)"
trigger_case sys_ok       "1|SYS|SYS|SYS spec=VALID,body=VALID,chg=OK,startup=OK" YES ""
assert_contains "trigger sys case: owner shown" "$MDC" "| Role trigger ready | YES (SYS) |"
trigger_case dedicated_ok "1|DG_ADMIN|DG_ADMIN|DG_ADMIN spec=VALID,body=VALID,chg=OK,startup=OK" YES ""
assert_contains "trigger dedicated case: owner shown" "$MDC" "| Role trigger ready | YES (DG_ADMIN) |"
trigger_case ok_plus_leftover "1|SYS|DG_ADMIN,SYS|DG_ADMIN spec=MISSING,body=MISSING,chg=INVALID,startup=MISSING;SYS spec=VALID,body=VALID,chg=OK,startup=OK" YES ""
assert_contains "trigger leftover case: leftover note" "$MDC" "other owners also hold incomplete role-trigger objects (DG_ADMIN ("

# A failed status query degrades to a discovery warning and is never "ready".
DGSTUB_FAIL_TAGS="role_trigger_status" run_handoff v_trg_fail
assert_eq "trigger query failure rc" "1" "$RC"
assert_contains "trigger query failure: discovery warning" "$MDC" "role-aware service trigger status"
assert_contains "trigger query failure: not ready" "$MDC" "| Role trigger ready | NO (unknown) |"
assert_contains "trigger query failure: problem" "$MDC" "the object status could not be read"

# The JSON sidecar keeps its key names, and a healthy unchanged installation
# produces no "Role trigger ready" entry in Changes Since Last Report.
run_handoff v_trg_json
run_handoff v_trg_json
assert_contains "trigger json: key kept" "$JSONC" '"role_trigger_ready": true'
assert_contains "trigger json: owners key kept" "$JSONC" '"trigger_owners": "SYS"'
assert_not_contains "trigger json: no spurious diff" "$MDC" "| Role trigger ready | true"
DGSTUB_TRIGGER="0|NONE|SYS|SYS spec=VALID,body=INVALID,chg=OK,startup=OK" run_handoff v_trg_json
assert_contains "trigger json: a real regression is diffed" "$MDC" "| Role trigger ready | true | false |"

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

# ============================================================
# Test 12: the HTML twin is best-effort (H4)
# ============================================================
echo "Test 12: a failing HTML converter costs only the HTML twin"
# A stub awk that dies on the renderer's program (identified by its
# 'function esc' helper) and defers to the real awk for everything else - the
# same shape as AIX awk aborting with 0602-558 on the converter.
REAL_AWK=$(command -v awk)
BADAWK="$TEST_TMP/badawk"
mkdir -p "$BADAWK"
cat > "$BADAWK/awk" <<STUB
#!/bin/bash
case "\$*" in
    *"function esc"*) echo "awk: 0602-558 cannot be used as an array" >&2; exit 2 ;;
esac
exec "$REAL_AWK" "\$@"
STUB
chmod +x "$BADAWK/awk"
H4_DIR="$TEST_TMP/h4"; mkdir -p "$H4_DIR"
H4_OUT=$(PATH="$BADAWK:$STUB_BIN:$PATH" ORACLE_SID=cdb1 ORACLE_HOME="$OH" \
         bash "$SCRIPT" -o "$H4_DIR/dg_handoff_cdb1.md" 2>"$ERR_FILE"); H4_RC=$?
H4_ERR=$(cat "$ERR_FILE")
assert_eq "html failure keeps the verdict exit code" "0" "$H4_RC"
assert_contains "html failure warns" "$H4_ERR" "HTML twin failed"
assert_no_file "no partial html left behind" "$H4_DIR/dg_handoff_cdb1.html"
assert_no_file "no html temp file left behind" "$H4_DIR/dg_handoff_cdb1.html.tmp"
assert_file "json still written"      "$H4_DIR/dg_handoff_cdb1.json"
assert_file "tnsnames still written"  "$H4_DIR/dg_handoff_cdb1_tnsnames.ora"
assert_file "jdbc still written"      "$H4_DIR/dg_handoff_cdb1_jdbc.properties"
assert_file "verify still written"    "$H4_DIR/dg_handoff_cdb1_verify.sh"
assert_contains "report still printed to stdout" "$H4_OUT" "# Data Guard Handoff Report"
H4_MD=$(cat "$H4_DIR/dg_handoff_cdb1.md")
assert_not_contains "Files chip drops the missing html" "$H4_MD" "dg_handoff_cdb1.html"
assert_contains "Files chip keeps the other files" "$H4_MD" "dg_handoff_cdb1.md, dg_handoff_cdb1.json"
# An ERROR verdict must still come through as exit 2 (not masked, not faked)
H4_OUT=$(DGSTUB_GAPS=2 PATH="$BADAWK:$STUB_BIN:$PATH" ORACLE_SID=cdb1 ORACLE_HOME="$OH" \
         bash "$SCRIPT" -o "$H4_DIR/dg_handoff_cdb1.md" 2>/dev/null); H4_RC=$?
assert_eq "html failure still reports the ERROR verdict" "2" "$H4_RC"

# ============================================================
# Test 13: JSON escaping (A2/A8)
# ============================================================
echo "Test 13: quotes, backslashes, tabs and UTF-8 survive in the JSON sidecar"
TAB=$(printf '\t')
run_handoff json_esc --env 'PR"OD\x' --contact "dba${TAB}team é—ü"
assert_eq "special-character run rc" "0" "$RC"
assert_contains "quote escaped"     "$JSONC" '"environment": "PR\"OD\\x"'
assert_contains "tab escaped"       "$JSONC" 'dba\tteam'
assert_contains "utf-8 kept intact" "$JSONC" 'é—ü'
if command -v python3 >/dev/null 2>&1; then
    JV=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["environment"] + "|" + d["contact"])' "$JSON" 2>"$TEST_TMP/json.err")
    assert_eq "JSON round-trips the special characters" "PR\"OD\\x|dba${TAB}team é—ü" "$JV"
else
    note_skip "JSON special-character round trip (no python3 on this host)"
fi

# ============================================================
# Test 14: option parsing (C5) and TNS_ADMIN (C6)
# ============================================================
echo "Test 14: missing option values, numeric normalisation, --port, --previous"
for opt in -o --primary-host --standby-host --port --standby-tns-alias --env --contact \
           --service --exclude-service --connect-timeout --transport-timeout \
           --retry-count --retry-delay --previous --impact-reference; do
    run_handoff opt_missing "$opt"
    assert_eq "$opt without a value exits 3" "3" "$RC"
    assert_contains "$opt without a value says so" "$ERR" "$opt requires a value"
done
run_handoff port_bad --port abc
assert_eq "--port abc rc" "3" "$RC"
run_handoff port_big --port 70000
assert_eq "--port 70000 rc" "3" "$RC"
run_handoff port_zero --port 0
assert_eq "--port 0 rc" "3" "$RC"
run_handoff port_lead --port 01522
assert_eq "--port 01522 rc" "0" "$RC"
assert_contains "--port 01522 normalised" "$MDC" "(PORT = 1522)"
run_handoff lead_zero --connect-timeout 08 --retry-delay 09
assert_eq "leading-zero knobs rc" "0" "$RC"
assert_contains "08 read as decimal" "$MDC" "| CONNECT_TIMEOUT | 8 s |"
DG_SEQ_GAP_WARN=08 DG_SEQ_GAP_CRIT=09 DG_LAG_WARN_SECONDS=010 run_handoff lead_zero_env
assert_eq "leading-zero thresholds rc" "0" "$RC"
run_handoff prev_missing --previous "$TEST_TMP/no_such_baseline.json"
assert_eq "--previous with a missing file rc" "3" "$RC"
assert_contains "--previous names the file" "$ERR" "no_such_baseline.json"

mkdir -p "$TEST_TMP/tnsadmin"
printf 'SQLNET.EXPIRE_TIME = 25\n' > "$TEST_TMP/tnsadmin/sqlnet.ora"
TNS_ADMIN="$TEST_TMP/tnsadmin" run_handoff tns_admin
assert_contains "TNS_ADMIN sqlnet.ora is read" "$MDC" "| SQLNET.EXPIRE_TIME | 25 minutes |"
TNS_ADMIN="$TEST_TMP/empty_tns_admin" run_handoff tns_admin_missing
assert_contains "TNS_ADMIN without sqlnet.ora is reported, not ORACLE_HOME's" "$MDC" "not set (sqlnet.ora not found)"

# ============================================================
# Test 15: broker classification (C9)
# ============================================================
echo "Test 15: Warning: ORA- lines are warnings; empty or DISABLED broker output is not healthy"
DGSTUB_CFG=warn run_handoff c9_warn
assert_eq "WARNING config with a member Warning: ORA-16789 rc" "1" "$RC"
assert_contains "verdict is WARNING" "$MDC" "**Verdict:** WARNING"
assert_contains "WARNING status note" "$MDC" "Broker Configuration Status is WARNING"
assert_not_contains "member warning is not an ORA- error" "$MDC" "Broker reported ORA-/DGM- errors"
assert_not_contains "verdict is not ERROR" "$MDC" "**Verdict:** ERROR"

DGSTUB_CFG=disabled run_handoff c9_disabled
assert_eq "DISABLED config rc" "1" "$RC"
assert_contains "DISABLED note" "$MDC" "Broker configuration is DISABLED"

DGSTUB_CFG=empty run_handoff c9_empty
assert_eq "empty broker output rc" "1" "$RC"
assert_contains "empty broker output note" "$MDC" "DGMGRL returned no configuration output"
assert_contains "empty broker output is a discovery warning" "$MDC" "broker configuration (DGMGRL SHOW CONFIGURATION returned no output)"

DGSTUB_CFG=error run_handoff c9_error
assert_eq "ERROR config still rc 2" "2" "$RC"
assert_contains "ERROR config still names the ORA- text" "$MDC" "Broker reported ORA-/DGM- errors"

# ============================================================
# Test 16: change diff with FSFO disabled (M18) and FSFO threshold discovery
# ============================================================
echo "Test 16: FSFO disabled reruns show no threshold change"
DGSTUB_FSFO=off run_handoff fsfo_off
assert_eq "FSFO off first run rc" "0" "$RC"
DGSTUB_FSFO=off run_handoff fsfo_off
assert_eq "FSFO off second run rc" "0" "$RC"
assert_contains "no changes with FSFO off" "$MDC" "No changes since the previous report"
assert_not_contains "no FSFO threshold change row" "$MDC" "FSFO threshold"
assert_contains "json threshold is null with FSFO off" "$JSONC" '"fsfo_threshold": null'

run_handoff fsfo_on
assert_contains "FSFO threshold from SHOW FAST_START FAILOVER" "$JSONC" '"fsfo_threshold": "30"'
DGSTUB_FSFO_SHOW=none run_handoff fsfo_fallback
assert_contains "FSFO threshold falls back to SHOW CONFIGURATION property" "$JSONC" '"fsfo_threshold": "30"'
assert_not_contains "fallback is not a discovery failure" "$MDC" "fast-start failover threshold (broker)"
DGSTUB_FSFO_SHOW=all-none run_handoff fsfo_unknown
assert_contains "FSFO threshold unknown when both commands fail" "$MDC" "fast-start failover threshold (broker)"

# ============================================================
# Test 17: archive gaps are only claimed when assessed (M19)
# ============================================================
echo "Test 17: V\$ARCHIVE_GAP is not claimed as 0 from the primary"
run_handoff gap_primary
assert_contains "gap row says not assessable" "$MDC" "| Archive gaps | not assessable from the primary"
assert_contains "json gap is null" "$JSONC" '"archive_gaps": null'
assert_eq "unassessed gaps do not change the verdict" "0" "$RC"
DGSTUB_DIRECT=1 run_handoff gap_direct --standby-tns-alias stby_alias
assert_contains "standby view reports 0 gaps" "$MDC" "| Archive gaps | 0 |"
assert_contains "json gap from the standby" "$JSONC" '"archive_gaps": "0"'
DGSTUB_DIRECT=1 DGSTUB_DIRECT_GAPS=3 run_handoff gap_direct_bad --standby-tns-alias stby_alias
assert_eq "gaps on the standby raise ERROR" "2" "$RC"
assert_contains "gap note" "$MDC" "3 archive gap(s) detected"
DGSTUB_ROLE=standby run_handoff gap_standby_role
assert_contains "standby-side run assesses its own gaps" "$MDC" "| Archive gaps | 0 |"

# ============================================================
# Test 18: wording and driver examples (M20, SQLAlchemy)
# ============================================================
echo "Test 18: aliases are described as unqualified; SQLAlchemy uses connect_args"
run_handoff wording
TNSC=$(cat "$RUN_DIR/dg_handoff_cdb1_tnsnames.ora")
assert_not_contains "no 'fully qualified' claim in the report" "$MDC" "fully qualified"
assert_not_contains "no 'fully qualified' claim in the pack" "$TNSC" "fully qualified"
assert_contains "pack says the aliases are unqualified" "$TNSC" "The aliases below are unqualified"
assert_contains "report tells domain clients what to do" "$MDC" "the aliases printed here (for example \`APP_SVC_HA\`) are unqualified"
assert_contains "SQLAlchemy via connect_args" "$MDC" 'create_engine("oracle+oracledb://@", connect_args={"user": "app_user", "password": "<pwd>", "dsn": "pri.example.com:1521,stb.example.com:1521/app_svc?'
assert_not_contains "no multi-host URL in the SQLAlchemy example" "$MDC" "oracle+oracledb://app_user:<pwd>@"

# The service query hides only the exact <name>XDB dispatcher services, so a
# user service that merely contains XDB (APPXDBSYNC) is still reported.
assert_not_contains "service query has no %XDB% wildcard" "$(cat "$SCRIPT")" "NOT LIKE '%XDB%'"

# ============================================================
# Test 19: the generated _verify.sh (A4, C5, C7)
# ============================================================
echo "Test 19: _verify.sh resolver fallbacks, -u parsing, no password on argv"
run_handoff vf
VF="$RUN_DIR/dg_handoff_cdb1_verify.sh"
BASH_BIN=$(command -v bash)

# A PATH holding only the tools the script itself needs, so a host getent /
# host / nslookup cannot leak into the scenario.
mk_safe_bin() {
    local d="$1" t p
    mkdir -p "$d"
    for t in cat grep sed awk tr head basename dirname; do
        p=$(command -v "$t") && ln -sf "$p" "$d/$t"
    done
}
stub_cmd() { # stub_cmd <dir> <name> <exit-code> [stdout-text]
    { printf '#!/bin/bash\n'; [ -n "$4" ] && printf 'echo "%s"\n' "$4"; printf 'exit %s\n' "$3"; } > "$1/$2"
    chmod +x "$1/$2"
}

# (a) AIX: uname says AIX, no getent; `host` reads /etc/hosts
AIXB="$TEST_TMP/vf_aix"; mk_safe_bin "$AIXB"
stub_cmd "$AIXB" uname 0 AIX
stub_cmd "$AIXB" nc 0
printf '#!/bin/bash\n[ "$1" = "stb.example.com" ] && exit 1\nexit 0\n' > "$AIXB/host"; chmod +x "$AIXB/host"
VOUT=$(PATH="$AIXB" "$BASH_BIN" "$VF" 2>&1); VRC=$?
assert_contains "AIX resolves via host" "$VOUT" "PASS  resolve pri.example.com (host)"
assert_contains "AIX host failure is a FAIL" "$VOUT" "FAIL  resolve stb.example.com (host found no address)"
assert_eq "AIX unresolvable name fails the run" "1" "$VRC"

# (b) no getent, not AIX: the resolver behind ping decides
LNXB="$TEST_TMP/vf_lnx"; mk_safe_bin "$LNXB"
stub_cmd "$LNXB" uname 0 Linux
stub_cmd "$LNXB" nc 0
stub_cmd "$LNXB" nslookup 1          # DNS-only: must never be consulted
stub_cmd "$LNXB" ping 0
VOUT=$(PATH="$LNXB" "$BASH_BIN" "$VF" 2>&1); VRC=$?
assert_contains "ping resolves a name" "$VOUT" "PASS  resolve pri.example.com (ping)"
assert_not_contains "nslookup is never used" "$VOUT" "nslookup"
assert_eq "ping-resolved run passes" "0" "$VRC"
stub_cmd "$LNXB" ping 68 "ping: unknown host pri.example.com"
VOUT=$(PATH="$LNXB" "$BASH_BIN" "$VF" 2>&1); VRC=$?
assert_contains "unresolvable name via ping FAILs" "$VOUT" "FAIL  resolve pri.example.com (ping could not resolve the name)"
stub_cmd "$LNXB" ping 1
VOUT=$(PATH="$LNXB" "$BASH_BIN" "$VF" 2>&1); VRC=$?
assert_contains "silent ping SKIPs, not FAILs" "$VOUT" "SKIP  resolve pri.example.com (resolved, but no ICMP reply"
assert_eq "silent ping does not fail the run" "0" "$VRC"

# (c) no resolver that reads /etc/hosts at all: SKIP
NONEB="$TEST_TMP/vf_none"; mk_safe_bin "$NONEB"
stub_cmd "$NONEB" uname 0 Linux
stub_cmd "$NONEB" nc 0
stub_cmd "$NONEB" nslookup 1
VOUT=$(PATH="$NONEB" "$BASH_BIN" "$VF" 2>&1); VRC=$?
assert_contains "no usable resolver SKIPs" "$VOUT" "SKIP  resolve pri.example.com (no getent, AIX host or ping on this host)"
assert_eq "no usable resolver does not fail the run" "0" "$VRC"

# (d) -u / --expect-db-unique-name as the LAST argument must not loop forever
guarded() { # guarded <seconds> <cmd...> -> sets GOUT, GRC (GRC=137 when killed)
    local secs="$1"; shift
    local out="$TEST_TMP/guarded.out" pid i=0
    "$@" > "$out" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$secs" ]; do sleep 1; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; GRC=137
    else
        wait "$pid"; GRC=$?
    fi
    GOUT=$(cat "$out")
}
guarded 5 env PATH="$VBIN:$PATH" "$BASH_BIN" "$VF" -u
assert_eq "-u without a value exits 2 (no endless loop)" "2" "$GRC"
assert_contains "-u without a value says so" "$GOUT" "-u requires a value"
guarded 5 env PATH="$VBIN:$PATH" "$BASH_BIN" "$VF" --expect-db-unique-name
assert_eq "--expect-db-unique-name without a value exits 2" "2" "$GRC"

# (e) the password goes to sqlplus on stdin, never on argv
SPY="$TEST_TMP/vf_spy"; mkdir -p "$SPY"
cat > "$SPY/sqlplus" <<'SPYSTUB'
#!/bin/bash
printf '%s\n' "$@" > "$SPY_DIR/argv"
cat > "$SPY_DIR/stdin"
echo "DGCHK=cdb1|PRIMARY|pri.example.com"
exit 0
SPYSTUB
chmod +x "$SPY/sqlplus"
VOUT=$(SPY_DIR="$SPY" PATH="$SPY:$VBIN:$PATH" "$BASH_BIN" "$VF" -u 'app/p&w$d' 2>&1); VRC=$?
assert_eq "credentialed run rc" "0" "$VRC"
assert_not_contains "password not on the sqlplus command line" "$(cat "$SPY/argv")" "p&w"
assert_contains "sqlplus started with /nolog" "$(cat "$SPY/argv")" "/nolog"
assert_contains "define off before CONNECT" "$(cat "$SPY/stdin")" "SET DEFINE OFF"
assert_contains "CONNECT carries the quoted password and EZ+ string" "$(cat "$SPY/stdin")" 'CONNECT app/"p&w$d"@"pri.example.com:1521,stb.example.com:1521/app_svc?'

# ==== Summary ====
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
