#!/bin/bash
# ============================================================
# Test script for the dataguard-doc visualizer link helpers
# embedded in dg_handoff.sh and get_dg_config_url.sh
# ============================================================
# Usage: bash tests/test_visualizer_url.sh [-b|--base-url <url>]
#
# -b/--base-url overrides the visualizer base URL the helpers build on
# (same effect as exporting DG_DOC_BASE_URL); the generated URLs are then
# asserted against that base instead of the published default.
#
# The helpers build the "#cfg=<base64url(JSON)>" share URL consumed by
# the interactive Data Guard configuration explorer
# (https://github.com/davidbudac/dataguard-doc, published at
# https://davidbudac.cz/dataguard/). The block is duplicated in the
# handoff report generator and the standalone link generator; this test:
#   1. diffs all copies (they must stay byte-identical)
#   2. sources the extracted block and checks the generated URL:
#      base64url alphabet, decodable payload, correct JSON members,
#      omission of unknown fields, protection-mode/transport mapping,
#      observer placement mapping, and JSON escaping of odd values
# ============================================================

# Don't use set -e as we need to test for failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

DEFAULT_BASE_URL="https://davidbudac.cz/dataguard/"
BASE_URL="${DG_DOC_BASE_URL:-$DEFAULT_BASE_URL}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--base-url)
            if [[ -z "$2" ]]; then
                echo "ERROR: $1 requires a URL argument" >&2
                exit 2
            fi
            BASE_URL="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: bash tests/test_visualizer_url.sh [-b|--base-url <url>]"
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# The helper block reads DG_DOC_BASE_URL at eval time
export DG_DOC_BASE_URL="$BASE_URL"

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
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    expected to contain: $needle"
        echo "    actual:              $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name"
        echo "    expected NOT to contain: $needle"
        echo "    actual:                  $haystack"
        FAIL=$((FAIL + 1))
    fi
}

extract_block() {
    sed -n '/^# ---- begin dataguard-doc visualizer helpers ----$/,/^# ---- end dataguard-doc visualizer helpers ----$/p' "$1"
}

# Decode the payload of a generated URL back to JSON (test-side inverse
# of b64url_encode; re-adds the stripped padding)
decode_cfg() {
    local payload="${1#*#cfg=}" b
    b=$(printf '%s' "$payload" | tr -- '-_' '+/')
    while [[ $(( ${#b} % 4 )) -ne 0 ]]; do b="${b}="; done
    printf '%s' "$b" | base64 -d 2>/dev/null || printf '%s' "$b" | openssl enc -base64 -d -A
}

# ============================================================
# Test 1: every embedded copy is byte-identical
# ============================================================
# dg_handoff.sh is the reference copy; each other script carrying the
# block is diffed against it.
echo "Test 1: helper block identical in every script that embeds it"
BLOCK_A=$(extract_block "${REPO_DIR}/dg_handoff.sh")
TMP_A="${TMPDIR:-/tmp}/viz_block_a.$$"
printf '%s\n' "$BLOCK_A" > "$TMP_A"

if [[ -z "$BLOCK_A" ]]; then
    echo "  FAIL: helper block markers not found in dg_handoff.sh"
    FAIL=$((FAIL + 1))
fi

for OTHER in "get_dg_config_url.sh"; do
    BLOCK_B=$(extract_block "${REPO_DIR}/${OTHER}")
    TMP_B="${TMPDIR:-/tmp}/viz_block_b.$$"
    printf '%s\n' "$BLOCK_B" > "$TMP_B"
    if [[ -z "$BLOCK_A" || -z "$BLOCK_B" ]]; then
        echo "  FAIL: helper block markers not found in ${OTHER}"
        FAIL=$((FAIL + 1))
    elif diff "$TMP_A" "$TMP_B" >/dev/null; then
        echo "  PASS: ${OTHER} matches dg_handoff.sh"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: block differs between dg_handoff.sh and ${OTHER}"
        diff "$TMP_A" "$TMP_B" | head -20
        FAIL=$((FAIL + 1))
    fi
    rm -f "$TMP_B"
done
rm -f "$TMP_A"

# Everything below exercises the real code from dg_handoff.sh
eval "$BLOCK_A"

# ============================================================
# Test 2: full discovery -> full URL
# ============================================================
echo "Test 2: fully discovered topology"
PRIMARY_DB_UNIQUE_NAME="CDB1PRI"
STANDBY_DB_UNIQUE_NAME="CDB1STB"
PRIMARY_HOSTNAME="pri-host.example.com"
STANDBY_HOSTNAME="stb-host.example.com"
FSFO_OBSERVER_HOST="obs-host.example.com"
SERVICE_LIST=("app_svc" "other_svc")
PORT="1521"
PROTECTION_MODE="MAXIMUM AVAILABILITY"
STANDBY_LOGXPTMODE="FASTSYNC"
FSFO_STATUS="SYNCHRONIZED"
FSFO_THRESHOLD="45"

URL=$(build_visualizer_url)
assert_contains "URL uses the configured base"     "$URL" "${BASE_URL}#cfg="
PAYLOAD="${URL#*#cfg=}"
if printf '%s' "$PAYLOAD" | LC_ALL=C grep -q '[^A-Za-z0-9_-]'; then
    echo "  FAIL: payload contains characters outside the base64url alphabet"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: payload is base64url (no +, /, =, or other characters)"
    PASS=$((PASS + 1))
fi

JSON=$(decode_cfg "$URL")
assert_contains "version marker"        "$JSON" '{"v":1'
assert_contains "dbPrimary"             "$JSON" '"dbPrimary":"CDB1PRI"'
assert_contains "dbStandby"             "$JSON" '"dbStandby":"CDB1STB"'
assert_contains "hostPrimary"           "$JSON" '"hostPrimary":"pri-host.example.com"'
assert_contains "hostStandby"           "$JSON" '"hostStandby":"stb-host.example.com"'
assert_contains "hostObserver"          "$JSON" '"hostObserver":"obs-host.example.com"'
assert_contains "first service only"    "$JSON" '"service":"app_svc"'
assert_not_contains "second service excluded" "$JSON" "other_svc"
assert_contains "port as number"        "$JSON" '"port":1521'
assert_contains "mode maxavail"         "$JSON" '"mode":"maxavail"'
assert_contains "logXptMode fastsync"   "$JSON" '"logXptMode":"fastsync"'
assert_contains "threshold as number"   "$JSON" '"threshold":45'
assert_contains "observer on 3rd site"  "$JSON" '"observerLoc":"dc3"'

# ============================================================
# Test 3: unknown/missing fields are omitted, not emitted empty
# ============================================================
echo "Test 3: partial discovery omits unknown keys"
STANDBY_DB_UNIQUE_NAME=""
STANDBY_HOSTNAME=""
FSFO_OBSERVER_HOST=""
SERVICE_LIST=()
PROTECTION_MODE="MAXIMUM PROTECTION"
STANDBY_LOGXPTMODE="unknown"
FSFO_STATUS="DISABLED"
FSFO_THRESHOLD="unknown"

URL=$(build_visualizer_url)
JSON=$(decode_cfg "$URL")
assert_contains "primary still present"     "$JSON" '"dbPrimary":"CDB1PRI"'
assert_not_contains "no empty dbStandby"    "$JSON" '"dbStandby"'
assert_not_contains "no empty hostStandby"  "$JSON" '"hostStandby"'
assert_not_contains "no empty service"      "$JSON" '"service"'
assert_not_contains "MaxProtection not mapped" "$JSON" '"mode"'
assert_not_contains "unknown transport omitted" "$JSON" '"logXptMode"'
assert_not_contains "unknown threshold omitted" "$JSON" '"threshold"'
assert_contains "FSFO disabled -> no observer"  "$JSON" '"observerLoc":"none"'

# ============================================================
# Test 4: observer placement mapping (dc1/dc2, FQDN vs short)
# ============================================================
echo "Test 4: observer placement"
STANDBY_DB_UNIQUE_NAME="CDB1STB"
STANDBY_HOSTNAME="stb-host.example.com"
FSFO_STATUS="SYNCHRONIZED"

FSFO_OBSERVER_HOST="STB-HOST"   # short + different case -> still the standby
URL=$(build_visualizer_url)
JSON=$(decode_cfg "$URL")
assert_contains "observer on standby -> dc2" "$JSON" '"observerLoc":"dc2"'

FSFO_OBSERVER_HOST="pri-host.example.com"
URL=$(build_visualizer_url)
JSON=$(decode_cfg "$URL")
assert_contains "observer on primary -> dc1" "$JSON" '"observerLoc":"dc1"'

FSFO_OBSERVER_HOST=""           # FSFO on but observer host undiscovered
URL=$(build_visualizer_url)
JSON=$(decode_cfg "$URL")
assert_not_contains "unknown placement omitted" "$JSON" '"observerLoc"'

# ============================================================
# Test 5: JSON escaping and non-numeric guards
# ============================================================
echo "Test 5: escaping and numeric guards"
FSFO_OBSERVER_HOST=""
FSFO_STATUS="DISABLED"
PRIMARY_HOSTNAME='host"with\quirks'
PORT="15x1"
FSFO_THRESHOLD="30 seconds"

URL=$(build_visualizer_url)
JSON=$(decode_cfg "$URL")
assert_contains "quotes and backslashes escaped" "$JSON" '"hostPrimary":"host\"with\\quirks"'
assert_not_contains "non-numeric port dropped"      "$JSON" '"port"'
assert_not_contains "non-numeric threshold dropped" "$JSON" '"threshold"'

# ============================================================
echo ""
echo "Test Summary: $PASS passed, $FAIL failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
