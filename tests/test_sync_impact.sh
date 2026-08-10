#!/bin/bash
# ============================================================
# Unit tests for dg_sync_impact.sh
# ============================================================
# Pure bash, no database: a stub `sqlplus` on PATH dispatches on the
# QTAG markers embedded in every query dg_sync_impact.sh issues and
# returns canned pipe-delimited rows. Stub behavior is steered with
# environment variables:
#   STUB_ROLE       database role in the DBINFO row (default PRIMARY)
#   STUB_NO_SYNC    YES -> the remote destination is ASYNCHRONOUS
#   STUB_FAIL_QTAG  QTAG name whose query exits 1 (simulated ORA- error)
#   STUB_AUTOBASE   AUTOBASE classification scenario: default (NOSYNC run
#                   40-49, MIXED 50, SYNC 51-90), ALLSYNC, or NOSYNCONLY
#
# Usage: bash tests/test_sync_impact.sh
#
# Don't use set -e as we need to test for failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT="$REPO_DIR/dg_sync_impact.sh"

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

# ---- test environment ----

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/dg_sync_impact_test.XXXXXX") || {
    echo "FATAL: cannot create temp dir"; exit 1; }
trap 'rm -rf "$TEST_TMP"' EXIT

STUB_BIN="$TEST_TMP/bin"
EMPTY_BIN="$TEST_TMP/emptybin"
ERR_FILE="$TEST_TMP/stderr.out"
mkdir -p "$STUB_BIN" "$EMPTY_BIN"

cat > "$STUB_BIN/sqlplus" <<'STUB'
#!/bin/bash
# sqlplus stub: reads the SQL from stdin, dispatches on the QTAG marker.
IN=$(cat)
fail_if() { if [[ "${STUB_FAIL_QTAG:-}" == "$1" ]]; then exit 1; fi; }
case "$IN" in
*QTAG:PING*)
    fail_if PING
    echo "OK"
    ;;
*QTAG:DBINFO*)
    fail_if DBINFO
    echo "DBINFO|CDB1|CDB1|${STUB_ROLE:-PRIMARY}|MAXIMUM AVAILABILITY|READ WRITE|testhost|19.0.0.0.0|cdb1|1|2026-08-01 10:00:00|864000|1234567890|FALSE"
    ;;
*QTAG:DESTS*)
    fail_if DESTS
    if [[ "${STUB_NO_SYNC:-}" == "YES" ]]; then
        echo "DEST|2|cdb1_stby|ASYNCHRONOUS|NO|30|VALID"
    else
        echo "DEST|2|cdb1_stby|PARALLELSYNC|NO|30|VALID"
    fi
    ;;
*QTAG:EVENTS*)
    fail_if EVENTS
    echo "EVT|log file sync|3600000|3600.0|1"
    echo "EVT|log file parallel write|3000000|1500.0|.5"
    echo "EVT|SYNC Remote Write|3000000|2100.0|.7"
    echo "STAT|user commits|5400000"
    echo "STAT|redo writes|3000000"
    echo "STAT|redo synch writes|3600000"
    echo "STAT|redo size|123456789"
    echo "STAT|redo synch time (usec)|3600000000"
    echo "STAT|redo synch time overhead (usec)|360000000"
    echo "STAT|DB time (s)|86400"
    ;;
*QTAG:EMAX*)
    fail_if EMAX
    echo "EMAX|.85|.52|.71|3000000|3000000"
    ;;
*QTAG:HISTPCT*)
    fail_if HISTPCT
    echo "PCT|log file sync|1024|2048|4096|3600000"
    echo "PCT|log file parallel write|512|1024|2048|3000000"
    echo "PCT|SYNC Remote Write|512|1024|4096|3000000"
    ;;
*QTAG:RESPHIST*)
    fail_if RESPHIST
    echo "RESP|2|1|2999000"
    echo "RESP|2|2|1000"
    ;;
*QTAG:AWRSNAP*)
    fail_if AWRSNAP
    echo "SNAPWIN|100|268|169"
    ;;
*QTAG:AWRAGG*)
    fail_if AWRAGG
    if [[ "$IN" == *"BETWEEN 50 AND 90"* || "$IN" == *"BETWEEN 40 AND 49"* ]]; then
        echo "XAGG|604800|1800000|.6|.48|0|-|2700000|48000"
    else
        echo "XAGG|604800|2000000|1.05|.5|1900000|.7|3000000|50000"
    fi
    ;;
*QTAG:BASEHIST*)
    fail_if BASEHIST
    if [[ "$IN" == *"BETWEEN 50 AND 90"* || "$IN" == *"BETWEEN 40 AND 49"* ]]; then
        echo "HPCT|1|1|2|1800000"
    else
        echo "HPCT|1|2|4|2000000"
    fi
    ;;
*QTAG:AUTOBASE*)
    fail_if AUTOBASE
    case "${STUB_AUTOBASE:-}" in
    ALLSYNC)
        i=40
        while [[ $i -le 90 ]]; do
            echo "CLS|$i|2026-05-01 00:00|1000|1000|SYNC"
            i=$((i+1))
        done
        ;;
    NOSYNCONLY)
        i=40
        while [[ $i -le 90 ]]; do
            echo "CLS|$i|2026-05-01 00:00|0|1000|NOSYNC"
            i=$((i+1))
        done
        ;;
    *)
        i=40
        while [[ $i -le 49 ]]; do
            printf 'CLS|%s|2026-05-%02d 00:00|0|1000|NOSYNC\n' "$i" $((i-39))
            i=$((i+1))
        done
        echo "CLS|50|2026-05-11 00:00|300|1000|MIXED"
        echo "CLS|51|2026-05-12 00:00|980|1000|SYNC"
        i=52
        while [[ $i -le 90 ]]; do
            echo "CLS|$i|2026-06-01 00:00|1000|1000|SYNC"
            i=$((i+1))
        done
        ;;
    esac
    ;;
*QTAG:BASEWIN*)
    fail_if BASEWIN
    echo "BASEWIN|50|90|41|2026-06-01 00:00|2026-06-08 00:00"
    ;;
*QTAG:TREND*)
    fail_if TREND
    echo "TREND|101|2026-08-03 11:00|12000|1.05|.5|.7|3.3|300|2.4"
    echo "TREND|102|2026-08-03 12:00|13000|1.1|.52|.72|3.6|310|2.6"
    ;;
*QTAG:ASH*)
    fail_if ASH
    echo "ASHSUM|10000|1500|42|2026-08-09 12:00"
    echo "ASHSQL|abc123def456|800|INSERT INTO orders VALUES (...)"
    echo "ASHSQL|ghi789jkl012|400|UPDATE accounts SET balance=..."
    echo "ASHMOD|JDBC Thin Client|900"
    echo "ASHMOD|-|600"
    echo "ASHSVC|orders_svc|1000"
    echo "ASHSVC|cdb1|500"
    echo "ASHHR|08-09 12|700|4000"
    echo "ASHHR|08-09 13|800|6000"
    ;;
*)
    # Unknown query: make the test fail loudly rather than silently
    echo "STUB-UNKNOWN-QUERY"
    exit 1
    ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/sqlplus"

# run_script [args...] - runs dg_sync_impact.sh with the stub on PATH.
# Sets OUT (stdout), ERR (stderr), RC.
run_script() {
    OUT=$(PATH="$STUB_BIN:$PATH" ORACLE_SID=TESTSID ORACLE_HOME="$TEST_TMP" \
          bash "$SCRIPT" "$@" 2>"$ERR_FILE")
    RC=$?
    ERR=$(cat "$ERR_FILE")
}

# ==== Test 1: --help ====
echo "Test 1: --help prints usage and exits 0"
run_script --help
assert_eq "help exit code" "0" "$RC"
assert_contains "help shows usage" "$OUT$ERR" "Usage:"

# ==== Test 2: argument validation ====
echo "Test 2: argument validation exits 2"
run_script --bogus-flag
assert_eq "unknown flag rc" "2" "$RC"
run_script --ash-hours abc
assert_eq "non-numeric --ash-hours rc" "2" "$RC"
run_script --ash-hours 0
assert_eq "zero --ash-hours rc" "2" "$RC"
run_script --days x
assert_eq "non-numeric --days rc" "2" "$RC"
run_script --baseline-begin 50
assert_eq "baseline begin without end rc" "2" "$RC"
run_script --baseline-begin 50 --baseline-end '2026-06-08 00:00'
assert_eq "mixed baseline formats rc" "2" "$RC"
run_script --baseline-begin 'garbage' --baseline-end 'garbage2'
assert_eq "bad baseline format rc" "2" "$RC"
run_script --no-pack --baseline-begin 50 --baseline-end 90
assert_eq "baseline with --no-pack rc" "2" "$RC"
run_script --baseline-begin 90 --baseline-end 50
assert_eq "reversed baseline snaps rc" "2" "$RC"

# ==== Test 3: missing sqlplus is fatal ====
echo "Test 3: missing sqlplus exits 1"
OUT=$(PATH="$EMPTY_BIN" ORACLE_SID=TESTSID ORACLE_HOME="$TEST_TMP" \
      /bin/bash "$SCRIPT" 2>"$ERR_FILE")
RC=$?
ERR=$(cat "$ERR_FILE")
assert_eq "missing sqlplus rc" "1" "$RC"
assert_contains "missing sqlplus message" "$ERR" "sqlplus not on PATH"

# ==== Test 4: failed connection is fatal ====
echo "Test 4: failed sqlplus connection exits 1"
STUB_FAIL_QTAG=PING
export STUB_FAIL_QTAG
run_script
unset STUB_FAIL_QTAG
assert_eq "failed connection rc" "1" "$RC"
assert_contains "failed connection message" "$ERR" "Could not connect"

# ==== Test 5: non-primary role is fatal ====
echo "Test 5: non-PRIMARY role exits 1"
STUB_ROLE="PHYSICAL STANDBY"
export STUB_ROLE
run_script
unset STUB_ROLE
assert_eq "standby role rc" "1" "$RC"
assert_contains "standby role message" "$ERR" "run it on the PRIMARY"

# ==== Test 6: full run - report structure and derived numbers ====
echo "Test 6: full run produces the report with correct derived numbers"
run_script
assert_eq "full run rc" "0" "$RC"
assert_contains "report title" "$OUT" "# Synchronous Data Guard Impact Report"
assert_contains "section 1" "$OUT" "## 1. Synchronous transport configuration"
assert_contains "section 2" "$OUT" "## 2. Headline"
assert_contains "section 3" "$OUT" "## 3. LGWR pipeline decomposition"
assert_contains "section 4" "$OUT" "## 4. Latency distributions"
assert_contains "section 5" "$OUT" "## 5. AWR trend"
assert_contains "section 6" "$OUT" "## 6. Baseline comparison"
assert_contains "section 7" "$OUT" "## 7. ASH attribution"
assert_contains "section 8" "$OUT" "## 8. Method notes and caveats"
# Configuration
assert_contains "dest table row" "$OUT" "| 2 | cdb1_stby | PARALLELSYNC | NO | 30 | VALID |"
assert_contains "FASTSYNC classification" "$OUT" "NOAFFIRM (FASTSYNC)"
# Headline: E[max]-E[L] = .85-.52 = 0.330; bounds .7-.5=0.200 .. .7
assert_contains "refined estimate" "$OUT" "| Added latency per commit (refined estimate) | **0.330 ms** |"
assert_contains "bounds" "$OUT" "0.200 .. .7 ms"
# Scaling: 0.330ms x (2000000 lfs / 604800s x 3600) / 1000 = 3.929 s/hr
assert_contains "added s per hour" "$OUT" "3.929 s per hour"
# 0.330 x 2000000 / 1000 / 50000 x 100 = 1.320 % of DB time
assert_contains "pct of DB time" "$OUT" "1.320 %"
# 0.330 / 1.05 x 100 = 31.429 % of lfs
assert_contains "pct of lfs" "$OUT" "31.429 %"
assert_contains "reading line uses AWR window avg" "$OUT" "waits ~1.05 ms"
# Pipeline: group commit 5400000/3000000=1.800; overhead 360000000/3600000/1000=0.100
assert_contains "group-commit ratio" "$OUT" "**1.800**"
assert_contains "redo synch overhead avg" "$OUT" "**0.100 ms**"
assert_contains "event table row" "$OUT" "| SYNC Remote Write | 3000000 | 2100.0 | .7 |"
# Distributions: 1024us -> 1.024ms buckets
assert_contains "lfs percentiles" "$OUT" "| log file sync | <= 1.024 | <= 2.048 | <= 4.096 | 3600000 |"
assert_contains "overlap model result" "$OUT" "E[max(L,R)] - E[L] = **0.330 ms**"
assert_contains "resp histogram row" "$OUT" "| 2 | 1 | 2999000 |"
# AWR trend
assert_contains "trend row" "$OUT" "| 101 | 2026-08-03 11:00 | 12000 | 1.05 | .5 | .7 | 3.3 | 300 | 2.4 |"
# Baseline not requested
assert_contains "baseline hint" "$OUT" "No baseline window supplied"
# ASH: 1500/10000 = 15.000 %
assert_contains "ash pct" "$OUT" "15.000 %"
assert_contains "ash top sql" "$OUT" "abc123def456"
assert_contains "ash top module" "$OUT" "JDBC Thin Client"
assert_contains "ash top service" "$OUT" "orders_svc"
assert_contains "ash hourly row" "$OUT" "| 08-09 12 | 700 | 4000 | 17.500 |"
# License note
assert_contains "license note" "$OUT" "Diagnostics Pack"

# ==== Test 7: baseline comparison ====
echo "Test 7: baseline window comparison (snap-ID form)"
run_script --baseline-begin 50 --baseline-end 90
assert_eq "baseline run rc" "0" "$RC"
assert_contains "baseline window line" "$OUT" "Baseline: snapshots 50-90 (41), 2026-06-01 00:00 .. 2026-06-08 00:00"
assert_contains "baseline lfs row" "$OUT" "| log file sync avg (ms) | .6 | 1.05 |"
# Empirical delta 1.05 - .6 = 0.450
assert_contains "empirical delta" "$OUT" "Empirical added latency per commit: 0.450 ms"
assert_contains "baseline percentiles" "$OUT" "| lfs p50 / p90 / p99 (<= ms buckets) | 1 / 1 / 2 | 1 / 2 / 4 |"
assert_contains "model cross-check" "$OUT" "Model estimate for comparison: 0.330 ms"
# Workloads are comparable in the canned data - no warnings expected
assert_not_contains "no commit-rate warning" "$OUT" "commit rate differs by more than 2x"
assert_not_contains "no local-write warning" "$OUT" "LOCAL redo write latency also shifted"

# ==== Test 7b: --auto-baseline ====
echo "Test 7b: --auto-baseline detects the pre-SYNC window"
run_script --auto-baseline
assert_eq "auto-baseline rc" "0" "$RC"
assert_contains "auto-detected provenance" "$OUT" "auto-detected"
assert_contains "auto-detected window" "$OUT" "snapshots 40-49"
assert_contains "transition snap line" "$OUT" "Synchronous transport first observed at snap 51 (2026-05-12 00:00)"
assert_contains "classification counts" "$OUT" "40 SYNC, 10 NOSYNC, 1 IDLE/MIXED"
assert_contains "behavioral disclosure" "$OUT" "behavioral, not configurational"
assert_contains "auto baseline window line" "$OUT" "Baseline: snapshots 40-49 (10), 2026-05-01 00:00 .. 2026-05-10 00:00"
# Empirical delta from the canned 40-49 aggregates: 1.05 - .6 = 0.450
assert_contains "auto empirical delta" "$OUT" "Empirical added latency per commit: 0.450 ms"
assert_contains "auto baseline percentiles" "$OUT" "| lfs p50 / p90 / p99 (<= ms buckets) | 1 / 1 / 2 | 1 / 2 / 4 |"

echo "Test 7b: --auto-baseline flag conflicts exit 2"
run_script --auto-baseline --baseline-begin 50 --baseline-end 90
assert_eq "auto + manual baseline rc" "2" "$RC"
run_script --auto-baseline --no-pack
assert_eq "auto-baseline with --no-pack rc" "2" "$RC"

echo "Test 7b: --auto-baseline detection-failure scenarios"
STUB_AUTOBASE=ALLSYNC
export STUB_AUTOBASE
run_script --auto-baseline
unset STUB_AUTOBASE
assert_eq "all-sync rc" "0" "$RC"
assert_contains "all-sync note" "$OUT" "predates AWR retention"
assert_contains "all-sync skips comparison" "$OUT" "comparison skipped"

STUB_AUTOBASE=NOSYNCONLY
export STUB_AUTOBASE
run_script --auto-baseline
unset STUB_AUTOBASE
assert_eq "no-sync-snaps rc" "0" "$RC"
assert_contains "no-sync-snaps note" "$OUT" "no synchronous-transport snapshots in AWR retention"

echo "Test 7b: --auto-baseline classification query degradation"
STUB_FAIL_QTAG=AUTOBASE
export STUB_FAIL_QTAG
run_script --auto-baseline
unset STUB_FAIL_QTAG
assert_eq "degraded autobase rc" "0" "$RC"
assert_contains "autobase degraded note" "$OUT" "snapshot classification unavailable"
assert_contains "autobase collection warning" "$OUT" "auto-baseline classification"
assert_contains "autobase other sections intact" "$OUT" "**0.330 ms**"

# ==== Test 8: --no-pack skips AWR and ASH ====
echo "Test 8: --no-pack restricts to free V\$ views"
run_script --no-pack
assert_eq "no-pack rc" "0" "$RC"
assert_contains "no-pack scope note" "$OUT" "free V\$ views only"
assert_contains "no-pack awr note" "$OUT" "--no-pack: Diagnostics Pack views not queried"
assert_contains "no-pack ash note" "$OUT" "Skipped ("
assert_not_contains "no ASH content" "$OUT" "orders_svc"
assert_not_contains "no trend content" "$OUT" "| 101 | 2026-08-03 11:00"
# The free-view sections still work
assert_contains "no-pack still has headline" "$OUT" "**0.330 ms**"

# ==== Test 9: no synchronous destination ====
echo "Test 9: no SYNC destination - report degrades to observation mode"
STUB_NO_SYNC=YES
export STUB_NO_SYNC
run_script
unset STUB_NO_SYNC
assert_eq "no-sync rc" "0" "$RC"
assert_contains "no-sync note" "$OUT" "No synchronous destination is active"
assert_contains "no-sync headline" "$OUT" "Not applicable - no synchronous destination"
assert_contains "still shows lfs stats" "$OUT" "| log file sync | 3600000 |"

# ==== Test 10: per-section degradation ====
echo "Test 10: a failing query degrades its section, not the run"
STUB_FAIL_QTAG=TREND
export STUB_FAIL_QTAG
run_script
unset STUB_FAIL_QTAG
assert_eq "degraded trend rc" "0" "$RC"
assert_contains "trend degraded note" "$OUT" "AWR trend unavailable"
assert_contains "collection warning listed" "$OUT" "AWR per-snapshot trend"
assert_contains "other sections intact" "$OUT" "**0.330 ms**"

STUB_FAIL_QTAG=EVENTS
export STUB_FAIL_QTAG
run_script
unset STUB_FAIL_QTAG
assert_eq "degraded events rc" "0" "$RC"
assert_contains "events degraded note" "$OUT" "Wait event data unavailable"
assert_contains "events collection warning" "$OUT" "wait events / sysstats"

# ==== Test 11: -o writes the report file ====
echo "Test 11: -o writes the report to a file and stdout"
run_script -o "$TEST_TMP/report.md"
assert_eq "-o rc" "0" "$RC"
if [[ -f "$TEST_TMP/report.md" ]]; then
    echo "  PASS: report file created"
    PASS=$((PASS + 1))
else
    echo "  FAIL: report file created"
    FAIL=$((FAIL + 1))
fi
FILE_CONTENT=$(cat "$TEST_TMP/report.md" 2>/dev/null)
assert_contains "report file has title" "$FILE_CONTENT" "# Synchronous Data Guard Impact Report"
assert_contains "stdout still has report" "$OUT" "# Synchronous Data Guard Impact Report"

# ==== Test 12: --html output mode ====
echo "Test 12: --html emits a self-contained HTML page"
run_script --html
assert_eq "html rc" "0" "$RC"
assert_contains "doctype" "$OUT" "<!DOCTYPE html>"
assert_contains "title carries DB name" "$OUT" "<title>Sync Data Guard Impact - CDB1</title>"
assert_contains "h2 section" "$OUT" "<h2>2. Headline: estimated cost of synchronous transport</h2>"
assert_contains "table header cell" "$OUT" "<th>Transmit mode</th>"
assert_contains "table data cell" "$OUT" "<td>cdb1_stby</td>"
assert_contains "bold converted" "$OUT" "<strong>0.330 ms</strong>"
assert_contains "code span converted" "$OUT" "<code>log file sync</code>"
assert_contains "escaped comparison" "$OUT" "&lt;= 1.024"
assert_not_contains "no raw markdown bold" "$OUT" "**0.330 ms**"
assert_not_contains "no raw table pipes" "$OUT" "| Measure |"
assert_contains "closing tag" "$OUT" "</html>"
# Multi-line italic note renders as <em> without literal underscores
assert_contains "italic note" "$OUT" "<p><em>No baseline window supplied."
assert_not_contains "no leftover underscores" "$OUT" "_No baseline window supplied"

STUB_NO_SYNC=YES
export STUB_NO_SYNC
run_script --html
unset STUB_NO_SYNC
assert_eq "html no-sync rc" "0" "$RC"
assert_contains "blockquote rendered" "$OUT" "<blockquote><p><strong>No synchronous destination is active.</strong>"

run_script --html -o "$TEST_TMP/report.html"
assert_eq "html -o rc" "0" "$RC"
HTML_FILE_CONTENT=$(cat "$TEST_TMP/report.html" 2>/dev/null)
assert_contains "html file written" "$HTML_FILE_CONTENT" "<!DOCTYPE html>"

# ==== Summary ====
echo ""
echo "Test Summary: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
