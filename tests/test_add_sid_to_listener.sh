#!/usr/bin/env bash
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
# Created under ${TMPDIR:-/tmp} and checked: a failed mktemp must never leave
# fixtures to be written to / or the current directory.
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test_add_sid.XXXXXX") || TEST_DIR=""
if [[ -z "$TEST_DIR" || ! -d "$TEST_DIR" ]]; then
    echo "FATAL: could not create a temporary test directory under ${TMPDIR:-/tmp}" >&2
    exit 1
fi
trap 'rm -rf "$TEST_DIR"' EXIT

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
        PASS=$((PASS + 1))
    else
        echo "FAIL (expected $expected_result, got $actual_result)"
        FAIL=$((FAIL + 1))
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
# listener_has_global_dbname: whole value, comments, case
# ============================================================

cat > "$TEST_DIR/gdb.ora" <<'EOF'
# (GLOBAL_DBNAME = commented_db)
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = cdb1_stby_DGMGRL.example.com)
      (ORACLE_HOME = /u01/app/oracle)
      (SID_NAME = cdb1)
    )
    (SID_DESC =
      (GLOBAL_DBNAME=CDB1_Other) # trailing comment (GLOBAL_DBNAME = cdb1_stby)
      (SID_NAME = cdb1)
    )
  )
EOF

test_gdb_prefix_not_matched() {
    # cdb1_stby is only a PREFIX of cdb1_stby_DGMGRL.example.com
    ! listener_has_global_dbname "$TEST_DIR/gdb.ora" "cdb1_stby"
}
test_gdb_exact_matched() {
    listener_has_global_dbname "$TEST_DIR/gdb.ora" "cdb1_stby_DGMGRL.example.com"
}
test_gdb_case_insensitive() {
    listener_has_global_dbname "$TEST_DIR/gdb.ora" "cdb1_other" \
        && listener_has_global_dbname "$TEST_DIR/gdb.ora" "CDB1_STBY_dgmgrl.EXAMPLE.com"
}
test_gdb_commented_ignored() {
    ! listener_has_global_dbname "$TEST_DIR/gdb.ora" "commented_db"
}
test_gdb_suffix_not_matched() {
    ! listener_has_global_dbname "$TEST_DIR/gdb.ora" "DGMGRL.example.com"
}

run_test "GLOBAL_DBNAME prefix is not a match" 0 test_gdb_prefix_not_matched
run_test "GLOBAL_DBNAME exact value matches" 0 test_gdb_exact_matched
run_test "GLOBAL_DBNAME compare is case-insensitive" 0 test_gdb_case_insensitive
run_test "GLOBAL_DBNAME in a comment is ignored" 0 test_gdb_commented_ignored
run_test "GLOBAL_DBNAME suffix is not a match" 0 test_gdb_suffix_not_matched

# ============================================================
# add_sid_to_listener: anchoring, one-liners, mode and symlinks
# ============================================================

write_new_desc() {
    cat > "$1" <<'EOF'
    (SID_DESC =
      (GLOBAL_DBNAME = NEW_DB)
      (ORACLE_HOME = /u01/app/oracle)
      (SID_NAME = NEWDB)
    )
EOF
}

test_comment_mentions_sid_list() {
    local f="$TEST_DIR/comment.ora" d="$TEST_DIR/comment_desc.txt"
    cat > "$f" <<'EOF'
# The SID_LIST_LISTENER block below registers the static services (see note)
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
      (SID_NAME = EXISTING)
    )
  )
EOF
    write_new_desc "$d"
    add_sid_to_listener "$f" "$d" || return 1
    # NEW_DB must land inside SID_LIST (after the SID_LIST_LISTENER line and
    # before the last line), not inside the LISTENER block
    local new_line total sid_list_line open close
    new_line=$(grep -n 'NEW_DB' "$f" | head -1 | cut -d: -f1)
    total=$(wc -l < "$f" | tr -d ' ')
    sid_list_line=$(grep -n '^SID_LIST_LISTENER' "$f" | cut -d: -f1)
    [[ "$new_line" -gt "$sid_list_line" && "$new_line" -lt "$total" ]] || { cat "$f"; return 1; }
    open=$(tr -cd '(' < "$f" | wc -c | tr -d ' ')
    close=$(tr -cd ')' < "$f" | wc -c | tr -d ' ')
    [[ "$open" -eq "$close" ]]
}
run_test "Comment mentioning SID_LIST_LISTENER does not start the paren count" 0 test_comment_mentions_sid_list

test_one_line_refused() {
    local f="$TEST_DIR/oneline.ora" d="$TEST_DIR/oneline_desc.txt"
    cat > "$f" <<'EOF'
LISTENER = (DESCRIPTION_LIST = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = h)(PORT = 1521))))
SID_LIST_LISTENER=(SID_LIST=(SID_DESC=(GLOBAL_DBNAME=X)(SID_NAME=x)))
EOF
    cp "$f" "$f.orig"
    write_new_desc "$d"
    if add_sid_to_listener "$f" "$d" 2>/dev/null; then
        echo "Expected refusal for one-line SID_LIST_LISTENER"
        return 1
    fi
    # untouched
    cmp -s "$f" "$f.orig"
}
run_test "One-line SID_LIST_LISTENER definition is refused, file untouched" 0 test_one_line_refused

test_mode_preserved() {
    local f="$TEST_DIR/mode.ora" d="$TEST_DIR/mode_desc.txt" mode
    cat > "$f" <<'EOF'
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC = (GLOBAL_DBNAME = A)(SID_NAME = a))
  )
EOF
    chmod 640 "$f"
    write_new_desc "$d"
    add_sid_to_listener "$f" "$d" || return 1
    mode=$(ls -l "$f" | cut -c1-10)
    [[ "$mode" == "-rw-r-----" ]] || { echo "mode became $mode"; return 1; }
    grep -q NEW_DB "$f"
}
run_test "File mode is preserved" 0 test_mode_preserved

test_symlink_preserved() {
    local real="$TEST_DIR/real_listener.ora" link="$TEST_DIR/link_listener.ora" d="$TEST_DIR/link_desc.txt"
    cat > "$real" <<'EOF'
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC = (GLOBAL_DBNAME = A)(SID_NAME = a))
  )
EOF
    ln -s "$real" "$link"
    write_new_desc "$d"
    add_sid_to_listener "$link" "$d" || return 1
    [[ -L "$link" ]] || { echo "symlink was replaced by a regular file"; return 1; }
    grep -q NEW_DB "$real"
}
run_test "Symlinked listener.ora keeps its link and edits the target" 0 test_symlink_preserved

test_no_definition_fails() {
    local f="$TEST_DIR/nodef.ora" d="$TEST_DIR/nodef_desc.txt"
    printf '# SID_LIST_LISTENER lives elsewhere\nLISTENER = (DESCRIPTION_LIST = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = h)(PORT = 1521))))\n' > "$f"
    write_new_desc "$d"
    ! add_sid_to_listener "$f" "$d" 2>/dev/null
}
run_test "A comment-only mention of SID_LIST_LISTENER is not a definition" 0 test_no_definition_fails

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
