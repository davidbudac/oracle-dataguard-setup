#!/bin/bash
# ============================================================
# Test script for add_sid_to_listener function
# ============================================================
# Usage: ./tests/test_add_sid_to_listener.sh
# ============================================================

# Don't use set -e as we need to test for failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source the functions (without logging setup)
LOG_FILE=/dev/null
source "${COMMON_DIR}/dg_functions.sh"

# Test directory
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

PASS=0
FAIL=0

run_test() {
    local test_name="$1"
    local expected_result="$2"  # 0 for success, 1 for failure
    shift 2

    echo "----------------------------------------"
    echo "TEST: $test_name"

    if "$@"; then
        actual_result=0
    else
        actual_result=1
    fi

    if [[ "$actual_result" -eq "$expected_result" ]]; then
        echo "PASS"
        ((PASS++))
    else
        echo "FAIL (expected $expected_result, got $actual_result)"
        ((FAIL++))
    fi
}

# ============================================================
# Test 1: Basic insertion into existing SID_LIST_LISTENER
# ============================================================

test_basic_insertion() {
    local listener_file="$TEST_DIR/listener1.ora"
    local sid_desc_file="$TEST_DIR/sid_desc1.txt"

    # Create a basic listener.ora with one existing SID_DESC
    cat > "$listener_file" <<'EOF'
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = myhost)(PORT = 1521))
    )
  )

SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = EXISTING_DB)
      (ORACLE_HOME = /u01/app/oracle)
      (SID_NAME = EXISTING)
    )
  )
EOF

    # Create the new SID_DESC to add
    cat > "$sid_desc_file" <<'EOF'
    (SID_DESC =
      (GLOBAL_DBNAME = NEW_DB)
      (ORACLE_HOME = /u01/app/oracle)
      (SID_NAME = NEWDB)
    )
EOF

    # Run the function
    if ! add_sid_to_listener "$listener_file" "$sid_desc_file"; then
        echo "Function failed"
        return 1
    fi

    # Verify the new SID_DESC was added
    if ! grep -q "SID_NAME = NEWDB" "$listener_file"; then
        echo "New SID_DESC not found in file"
        return 1
    fi

    # Verify the structure is correct (new entry is inside SID_LIST)
    # Count parens - should be balanced
    local open_parens close_parens
    open_parens=$(grep -o '(' "$listener_file" | wc -l)
    close_parens=$(grep -o ')' "$listener_file" | wc -l)

    if [[ "$open_parens" -ne "$close_parens" ]]; then
        echo "Unbalanced parentheses: $open_parens open, $close_parens close"
        cat "$listener_file"
        return 1
    fi

    # Verify EXISTING_DB still exists
    if ! grep -q "GLOBAL_DBNAME = EXISTING_DB" "$listener_file"; then
        echo "Original SID_DESC was removed"
        return 1
    fi

    echo "Result file:"
    cat "$listener_file"
    return 0
}

run_test "Basic insertion" 0 test_basic_insertion

# ============================================================
# Test 2: Missing SID_LIST_LISTENER
# ============================================================

test_missing_sid_list() {
    local listener_file="$TEST_DIR/listener2.ora"
    local sid_desc_file="$TEST_DIR/sid_desc2.txt"

    # Create a listener.ora without SID_LIST_LISTENER
    cat > "$listener_file" <<'EOF'
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = myhost)(PORT = 1521))
    )
  )
EOF

    cat > "$sid_desc_file" <<'EOF'
    (SID_DESC =
      (GLOBAL_DBNAME = NEW_DB)
      (ORACLE_HOME = /u01/app/oracle)
      (SID_NAME = NEWDB)
    )
EOF

    # This should fail
    add_sid_to_listener "$listener_file" "$sid_desc_file" 2>/dev/null
}

run_test "Missing SID_LIST_LISTENER should fail" 1 test_missing_sid_list

# ============================================================
# Test 3: Multiple existing SID_DESC entries
# ============================================================

test_multiple_existing() {
    local listener_file="$TEST_DIR/listener3.ora"
    local sid_desc_file="$TEST_DIR/sid_desc3.txt"

    cat > "$listener_file" <<'EOF'
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = DB1)
      (ORACLE_HOME = /u01/app/oracle)
      (SID_NAME = DB1)
    )
    (SID_DESC =
      (GLOBAL_DBNAME = DB2)
      (ORACLE_HOME = /u01/app/oracle)
      (SID_NAME = DB2)
    )
  )
EOF

    cat > "$sid_desc_file" <<'EOF'
    (SID_DESC =
      (GLOBAL_DBNAME = DB3)
      (ORACLE_HOME = /u01/app/oracle)
      (SID_NAME = DB3)
    )
EOF

    if ! add_sid_to_listener "$listener_file" "$sid_desc_file"; then
        echo "Function failed"
        return 1
    fi

    # Verify all three SID_DESC entries exist
    if ! grep -q "SID_NAME = DB1" "$listener_file"; then
        echo "DB1 missing"
        return 1
    fi
    if ! grep -q "SID_NAME = DB2" "$listener_file"; then
        echo "DB2 missing"
        return 1
    fi
    if ! grep -q "SID_NAME = DB3" "$listener_file"; then
        echo "DB3 missing"
        return 1
    fi

    # Count SID_DESC entries
    local sid_count
    sid_count=$(grep -c "SID_DESC" "$listener_file")
    if [[ "$sid_count" -ne 3 ]]; then
        echo "Expected 3 SID_DESC entries, found $sid_count"
        cat "$listener_file"
        return 1
    fi

    echo "Result file:"
    cat "$listener_file"
    return 0
}

run_test "Multiple existing SID_DESC" 0 test_multiple_existing

# ============================================================
# Summary
# ============================================================

echo ""
echo "========================================"
echo "Test Summary: $PASS passed, $FAIL failed"
echo "========================================"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
