#!/usr/bin/env bash
# ============================================================
# Tests for the shared helpers in common/dg_functions.sh:
#   - enable_verbose_mode: --help, unknown options, declared flags
#     (DG_SCRIPT_FLAGS / DG_SCRIPT_POSITIONAL), value flags
#   - pause_verbose_trace / resume_verbose_trace nesting, prompt_password
#   - dgmgrl_status_value / dgmgrl_has_error_lines (19c SHOW CONFIGURATION)
#   - hostnames_match (IPv4 handling), create_temp_dir, get_db_parameter,
#     dg_net_admin_dir, dg_sqlplus_bin
# Usage: ./tests/test_shared_helpers.sh
# ============================================================

# Don't use set -e as we need to test for failures

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

LOG_FILE=/dev/null
source "${COMMON_DIR}/dg_functions.sh"

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test_shared_helpers.XXXXXX") || TEST_DIR=""
if [[ -z "$TEST_DIR" || ! -d "$TEST_DIR" ]]; then
    echo "FATAL: could not create a temporary test directory under ${TMPDIR:-/tmp}" >&2
    exit 1
fi
trap 'rm -rf "$TEST_DIR"' EXIT

PASS=0
FAIL=0

check() {
    # check "name" <command...> : passes when the command succeeds
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

# ============================================================
# enable_verbose_mode parser
# ============================================================

# mkscript <file> <pre-call lines...>: a tiny script that sources
# dg_functions.sh, runs the given lines, calls enable_verbose_mode "$@"
mkscript() {
    local file="$1"
    shift
    {
        printf '#!/bin/bash\n'
        printf '# Header line one\n'
        printf '# ====\n'
        printf '# Header line two\n'
        printf '\n'
        printf 'set -e\n'
        printf 'source "%s/dg_functions.sh"\n' "$COMMON_DIR"
        local l
        for l in "$@"; do
            printf '%s\n' "$l"
        done
        printf 'enable_verbose_mode "$@"\n'
        printf 'echo "RAN check=$CHECK_ONLY"\n'
    } > "$file"
}

# run_script <file> args... : sets OUT and RC
run_script() {
    local file="$1"
    shift
    OUT=$(bash "$file" "$@" 2>&1 </dev/null)
    RC=$?
}

mkscript "$TEST_DIR/plain.sh"
mkscript "$TEST_DIR/flags.sh" "DG_SCRIPT_FLAGS='--regenerate -x --channels= -r='"
mkscript "$TEST_DIR/pos.sh" "DG_SCRIPT_POSITIONAL=1"
mkscript "$TEST_DIR/star.sh" "DG_SCRIPT_FLAGS='*'"
mkscript "$TEST_DIR/usage.sh" 'usage() { echo "CUSTOM USAGE TEXT"; exit 1; }'

t_plain_ok() { run_script "$TEST_DIR/plain.sh"; [[ $RC -eq 0 && "$OUT" == *"RAN check=0"* ]]; }
check "no arguments runs the script" t_plain_ok

t_global_flags() { run_script "$TEST_DIR/plain.sh" -v -a -n --no-color; [[ $RC -eq 0 && "$OUT" == *"RAN check=1"* ]]; }
check "global flags (-v -a -n --no-color) are accepted" t_global_flags

t_long_global() { run_script "$TEST_DIR/plain.sh" --check --approval-mode --plan --execute --no-verbose --suspicious; [[ $RC -eq 0 ]]; }
check "long global flags are accepted" t_long_global

t_help_header() {
    run_script "$TEST_DIR/plain.sh" --help
    [[ $RC -eq 0 && "$OUT" == *"Header line one"* && "$OUT" == *"Header line two"* \
       && "$OUT" != *"RAN"* && "$OUT" != *"===="* && "$OUT" != *"source"* ]]
}
check "--help prints the leading comment header and exits 0 without running" t_help_header

t_help_short() { run_script "$TEST_DIR/plain.sh" -h; [[ $RC -eq 0 && "$OUT" == *"Header line one"* && "$OUT" != *"RAN"* ]]; }
check "-h behaves like --help" t_help_short

t_help_usage() {
    run_script "$TEST_DIR/usage.sh" --help
    # usage() ends in exit 1 by convention - --help must still exit 0
    [[ $RC -eq 0 && "$OUT" == *"CUSTOM USAGE TEXT"* && "$OUT" != *"Header line one"* ]]
}
check "--help calls a defined usage() and exits 0 even if usage exits 1" t_help_usage

t_unknown() { run_script "$TEST_DIR/plain.sh" --chek; [[ $RC -eq 2 && "$OUT" == *"Unknown option: --chek"* && "$OUT" != *"RAN"* ]]; }
check "unknown option exits 2 with a message and does not run" t_unknown

t_unknown_short() { run_script "$TEST_DIR/plain.sh" -z; [[ $RC -eq 2 ]]; }
check "unknown short option exits 2" t_unknown_short

t_positional_rejected() { run_script "$TEST_DIR/plain.sh" foo; [[ $RC -eq 2 && "$OUT" == *"Unexpected argument: foo"* ]]; }
check "positional argument is rejected by default" t_positional_rejected

t_positional_allowed() { run_script "$TEST_DIR/pos.sh" setup -v; [[ $RC -eq 0 && "$OUT" == *"RAN"* ]]; }
check "DG_SCRIPT_POSITIONAL=1 allows positional arguments" t_positional_allowed

t_pos_unknown_flag() { run_script "$TEST_DIR/pos.sh" setup --nope; [[ $RC -eq 2 ]]; }
check "DG_SCRIPT_POSITIONAL=1 still rejects unknown options" t_pos_unknown_flag

t_declared_bool() { run_script "$TEST_DIR/flags.sh" --regenerate -x; [[ $RC -eq 0 && "$OUT" == *"RAN"* ]]; }
check "declared boolean flags are accepted" t_declared_bool

t_declared_value_space() { run_script "$TEST_DIR/flags.sh" --channels 4 -r 200M; [[ $RC -eq 0 && "$OUT" == *"RAN"* ]]; }
check "declared value flags consume the next argument" t_declared_value_space

t_declared_value_eq() { run_script "$TEST_DIR/flags.sh" --channels=4; [[ $RC -eq 0 && "$OUT" == *"RAN"* ]]; }
check "--flag=value is accepted for a declared value flag" t_declared_value_eq

t_value_not_checked() { run_script "$TEST_DIR/flags.sh" -r -weird; [[ $RC -eq 0 ]]; }
check "the value of a value flag is not parsed as an option" t_value_not_checked

t_value_missing() { run_script "$TEST_DIR/flags.sh" --channels; [[ $RC -eq 2 && "$OUT" == *"requires a value"* ]]; }
check "declared value flag without a value exits 2" t_value_missing

t_typo_still_rejected() { run_script "$TEST_DIR/flags.sh" --channel 4; [[ $RC -eq 2 ]]; }
check "--channel (typo of --channels) is rejected" t_typo_still_rejected

t_star() { run_script "$TEST_DIR/star.sh" --anything foo; [[ $RC -eq 0 && "$OUT" == *"RAN"* ]]; }
check "DG_SCRIPT_FLAGS='*' disables the unknown/positional checks" t_star

t_star_help() { run_script "$TEST_DIR/star.sh" --help; [[ $RC -eq 0 && "$OUT" == *"Header line one"* ]]; }
check "--help still works with DG_SCRIPT_FLAGS='*'" t_star_help

t_dashdash() { run_script "$TEST_DIR/pos.sh" -- -notaflag; [[ $RC -eq 0 ]]; }
check "-- ends option parsing (positional allowed)" t_dashdash

t_dashdash_rejected() { run_script "$TEST_DIR/plain.sh" -- extra; [[ $RC -eq 2 ]]; }
check "-- followed by a positional is still rejected without DG_SCRIPT_POSITIONAL" t_dashdash_rejected

# ============================================================
# Trace pause/resume nesting and prompt_password
# ============================================================

t_pause_nesting() {
    local out
    out=$( (
        VERBOSE=1
        set -x
        pause_verbose_trace
        pause_verbose_trace
        resume_verbose_trace
        if [[ "$-" == *x* ]]; then echo NESTED_RESUME_TURNED_TRACE_ON; fi
        resume_verbose_trace
        if [[ "$-" == *x* ]]; then echo TRACE_BACK; fi
    ) 2>/dev/null )
    [[ "$out" == *"TRACE_BACK"* && "$out" != *"NESTED_RESUME"* ]]
}
check "nested pause/resume only resumes tracing at the outermost level" t_pause_nesting

t_prompt_dash_n() {
    local out
    out=$(printf -- '-n\n' | prompt_password "pw" 2>/dev/null)
    [[ "$out" == "-n" ]]
}
check "prompt_password returns a password such as -n verbatim" t_prompt_dash_n

t_prompt_backslash() {
    local out
    out=$(printf -- 'a\\b c\n' | prompt_password "pw" 2>/dev/null)
    [[ "$out" == 'a\b c' ]]
}
check "prompt_password keeps backslashes and spaces" t_prompt_backslash

t_prompt_no_trace_leak() {
    # Caller pauses (as the real callers do); prompt_password itself must not
    # let xtrace print the password once the pause is in force.
    local err
    err=$( { VERBOSE=1; set -x; pause_verbose_trace; pw=$(printf 'SeCrEt-Pw\n' | prompt_password "pw"); resume_verbose_trace; set +x; } 2>&1 >/dev/null )
    [[ "$err" != *"SeCrEt-Pw"* ]]
}
check "prompt_password does not leak the password into xtrace when the caller pauses" t_prompt_no_trace_leak

t_prompt_trace_control() {
    # positive control: without the caller's pause the assignment IS traced,
    # proving the test above would notice a leak
    local err
    err=$( { VERBOSE=1; set -x; pw=$(printf 'SeCrEt-Pw\n' | prompt_password "pw"); set +x; } 2>&1 >/dev/null )
    [[ "$err" == *"SeCrEt-Pw"* ]]
}
check "control: an unpaused caller assignment is visible in xtrace" t_prompt_trace_control

t_no_export_sys_password() { ! grep -n 'export SYS_PASSWORD' "${COMMON_DIR}/dg_functions.sh" >/dev/null; }
check "SYS_PASSWORD is not exported by dg_functions.sh" t_no_export_sys_password

# ============================================================
# dgmgrl_status_value / dgmgrl_has_error_lines
# ============================================================

SHOW_CFG_SUCCESS='
Configuration - dg_cdb1

  Protection Mode: MaxPerformance
  Members:
  cdb1      - Primary database
    cdb1_stby - Physical standby database

Fast-Start Failover:  Disabled

Configuration Status:
SUCCESS   (status updated 42 seconds ago)
'

SHOW_CFG_WARNING='
Configuration - dg_cdb1

  Protection Mode: MaxAvailability
  Members:
  cdb1      - Primary database
    Warning: ORA-16789: standby redo logs configured incorrectly

    cdb1_stby - Physical standby database
      Warning: ORA-16789: standby redo logs configured incorrectly

Fast-Start Failover:  Disabled

Configuration Status:
WARNING   (status updated 12 seconds ago)
'

SHOW_CFG_ERROR='
Configuration - dg_cdb1

  Protection Mode: MaxAvailability
  Members:
  cdb1      - Primary database
    Error: ORA-16810: multiple errors or warnings detected for the member

    cdb1_stby - Physical standby database (disabled)
      ORA-16795: the standby database needs to be re-created

Fast-Start Failover:  Disabled

Configuration Status:
ERROR   (status updated 5 seconds ago)
'

SHOW_CFG_DISABLED='
Configuration - dg_cdb1

  Protection Mode: MaxPerformance
  Members:
  cdb1      - Primary database
    cdb1_stby - Physical standby database

Fast-Start Failover:  Disabled

Configuration Status:
DISABLED
'

SHOW_CFG_SAME_LINE='
Configuration - dg_cdb1
Configuration Status: SUCCESS
'

SHOW_DB_WARNING='
Database - cdb1_stby

  Role:               PHYSICAL STANDBY
  Intended State:     APPLY-ON
  Transport Lag:      0 seconds (computed 0 seconds ago)
  Apply Lag:          0 seconds (computed 0 seconds ago)
  Instance(s):
    cdb1

  Database Warning(s):
    ORA-16789: standby redo logs configured incorrectly

Database Status:
WARNING
'

ERR_NO_CONFIG='
ORA-16532: Oracle Data Guard broker configuration does not exist
Configuration details cannot be determined by DGMGRL
'

SHOW_CFG_LAB='
Configuration - my_dg_config

  Protection Mode: MaxAvailability
  Members:
  cdb1      - Primary database
    cdb1_stby - (*) Physical standby database 

Fast-Start Failover: Enabled in Zero Data Loss Mode

Configuration Status:
SUCCESS   (status updated 34 seconds ago)
'

status_is() { [[ "$(dgmgrl_status_value "$1")" == "$2" ]]; }

check "status: SUCCESS on the next line" status_is "$SHOW_CFG_SUCCESS" SUCCESS
check "status: real 19c lab output (FSFO enabled)" status_is "$SHOW_CFG_LAB" SUCCESS
check "status: WARNING with member Warning: ORA-16789" status_is "$SHOW_CFG_WARNING" WARNING
check "status: ERROR with member Error: ORA-16810" status_is "$SHOW_CFG_ERROR" ERROR
check "status: DISABLED without an age suffix" status_is "$SHOW_CFG_DISABLED" DISABLED
check "status: value on the same line as the label" status_is "$SHOW_CFG_SAME_LINE" SUCCESS
check "status: falls back to Database Status:" status_is "$SHOW_DB_WARNING" WARNING
check "status: CRLF line endings" status_is "$(printf 'Configuration Status:\r\nSUCCESS   (status updated 1 seconds ago)\r\n')" SUCCESS
check "status: lowercase value is uppercased" status_is "$(printf 'Configuration Status:\nsuccess\n')" SUCCESS

t_status_empty() { local v; v=$(dgmgrl_status_value ""); local rc=$?; [[ $rc -ne 0 && -z "$v" ]]; }
check "status: empty output prints nothing and returns 1" t_status_empty
t_status_noconfig() { local v; v=$(dgmgrl_status_value "$ERR_NO_CONFIG"); local rc=$?; [[ $rc -ne 0 && -z "$v" ]]; }
check "status: dgmgrl error output (no status field) returns 1" t_status_noconfig
t_status_garbage() { local v; v=$(dgmgrl_status_value $'Configuration Status:\nTIMEOUT\n'); local rc=$?; [[ $rc -ne 0 && -z "$v" ]]; }
check "status: unrecognized value returns 1" t_status_garbage
t_status_prefers_config() {
    [[ "$(dgmgrl_status_value "$(printf 'Database Status:\nERROR\n\nConfiguration Status:\nSUCCESS\n')")" == "SUCCESS" ]]
}
check "status: Configuration Status wins over Database Status" t_status_prefers_config

check_not "errors: SUCCESS sample has none" dgmgrl_has_error_lines "$SHOW_CFG_SUCCESS"
check_not "errors: real 19c lab output has none" dgmgrl_has_error_lines "$SHOW_CFG_LAB"
check_not "errors: member 'Warning: ORA-16789' is not an error" dgmgrl_has_error_lines "$SHOW_CFG_WARNING"
check "errors: 'Error: ORA-16810' is an error" dgmgrl_has_error_lines "$SHOW_CFG_ERROR"
check_not "errors: DISABLED sample has none" dgmgrl_has_error_lines "$SHOW_CFG_DISABLED"
check_not "errors: empty output has none" dgmgrl_has_error_lines ""
check "errors: bare ORA- line (no Warning:) is an error" dgmgrl_has_error_lines "$ERR_NO_CONFIG"
check "errors: 'Error: 5' with a nonzero code is an error" dgmgrl_has_error_lines "  Error: 5"
check_not "errors: 'Error: 0' is benign" dgmgrl_has_error_lines "  Error: 0"
check "errors: DGM- code is an error" dgmgrl_has_error_lines "DGM-17016: failed to retrieve status for database"
check_not "errors: 'Warning: DGM-' is not an error" dgmgrl_has_error_lines "    Warning: DGM-16999: something advisory"

# dgmgrl_output_has_error keeps its existing (stricter) behaviour
check "legacy dgmgrl_output_has_error still counts Warning: ORA- as an error" dgmgrl_output_has_error "$SHOW_CFG_WARNING"
check_not "legacy dgmgrl_output_has_error ignores 'Error: 0'" dgmgrl_output_has_error "  Error: 0"

# ============================================================
# hostnames_match
# ============================================================

export DG_LOCAL_IPV4_ADDRS="127.0.0.1 10.1.1.1"

check "hostnames: short name matches FQDN" hostnames_match "stby1" "stby1.example.com"
check "hostnames: case-insensitive" hostnames_match "STBY1.Example.Com" "stby1"
check_not "hostnames: different short names" hostnames_match "stby1" "pri1"
check_not "hostnames: empty side" hostnames_match "" "stby1"
check "hostnames: identical IPs match" hostnames_match "10.1.1.1" "10.1.1.1"
check_not "hostnames: 10.1.1.1 does not equal 10.9.9.9" hostnames_match "10.1.1.1" "10.9.9.9"
check_not "hostnames: IPs are not truncated at the first dot" hostnames_match "10.1.1.1" "10.1.1.2"
check "hostnames: name vs IP matches when the IP is a local address" hostnames_match "stby1" "10.1.1.1"
check "hostnames: IP vs name, either order" hostnames_match "10.1.1.1" "stby1"
check_not "hostnames: name vs a non-local IP does not match" hostnames_match "stby1" "10.9.9.9"
check "hostnames: a numeric-looking FQDN label is still a name" hostnames_match "123.example.com" "123"
DG_LOCAL_IPV4_ADDRS="" check_not "hostnames: no local addresses known, IP vs name" hostnames_match "stby1" "10.1.1.1"
unset DG_LOCAL_IPV4_ADDRS

# ============================================================
# create_temp_dir (including the no-mktemp fallback)
# ============================================================

t_temp_dir_basic() {
    local d
    d=$(create_temp_dir) || return 1
    [[ -d "$d" ]] && rm -rf "$d"
}
check "create_temp_dir returns a directory" t_temp_dir_basic

# A PATH without mktemp but with the few tools the fallback needs
mkdir -p "$TEST_DIR/nomktemp_bin" "$TEST_DIR/tmpbase"
for _tool in mkdir ls; do
    ln -s "$(command -v $_tool)" "$TEST_DIR/nomktemp_bin/$_tool"
done

t_fallback_creates_700() {
    local d
    d=$(PATH="$TEST_DIR/nomktemp_bin" TMPDIR="$TEST_DIR/tmpbase" create_temp_dir) || return 1
    [[ -d "$d" ]] && [[ "$(ls -ld "$d" | cut -c1-10)" == "drwx------" ]]
}
check "fallback creates a mode-700 directory" t_fallback_creates_700

t_fallback_refuses_existing() {
    # the fallback name is dg_tmp_<pid of this shell>; pre-create it (wrong mode)
    mkdir -p "$TEST_DIR/tmpbase2/dg_tmp_$$"
    chmod 755 "$TEST_DIR/tmpbase2/dg_tmp_$$"
    local d
    if d=$(PATH="$TEST_DIR/nomktemp_bin" TMPDIR="$TEST_DIR/tmpbase2" create_temp_dir); then
        return 1
    fi
    [[ -z "$d" ]]
}
check "fallback refuses a pre-existing directory" t_fallback_refuses_existing

# ============================================================
# get_db_parameter, dg_net_admin_dir, dg_sqlplus_bin
# ============================================================

run_sql_query() {
    # test stub shadowing the real helper (declared after sourcing)
    printf '%s\n' "$STUB_SQL_OUTPUT"
}

t_param_interior_spaces() {
    STUB_SQL_OUTPUT="   LOCATION=/u01/arch VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=cdb1   "
    [[ "$(get_db_parameter log_archive_dest_1)" == "LOCATION=/u01/arch VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=cdb1" ]]
}
check "get_db_parameter keeps interior whitespace, trims the ends" t_param_interior_spaces

t_param_location_parse() {
    # the step 1 LOCATION= extraction that stripping whitespace used to break
    STUB_SQL_OUTPUT="LOCATION=/u01/arch VALID_FOR=(ALL_LOGFILES,ALL_ROLES)"
    local v path
    v=$(get_db_parameter log_archive_dest_1)
    path=$(echo "$v" | sed 's/.*LOCATION=\([^ ]*\).*/\1/')
    [[ "$path" == "/u01/arch" ]]
}
check "step 1 LOCATION= parse yields just the path" t_param_location_parse

t_param_blank_lines() {
    STUB_SQL_OUTPUT=$'\n  cdb1  \n\n'
    [[ "$(get_db_parameter db_name)" == "cdb1" ]]
}
check "get_db_parameter drops blank lines" t_param_blank_lines

t_param_control_files() {
    STUB_SQL_OUTPUT="/u01/oradata/c1.ctl, /u02/oradata/c2.ctl"
    [[ "$(get_db_parameter control_files)" == "/u01/oradata/c1.ctl, /u02/oradata/c2.ctl" ]]
}
check "get_db_parameter keeps the space after commas" t_param_control_files

t_net_admin_default() {
    [[ "$(unset TNS_ADMIN; ORACLE_HOME=/u01/oh dg_net_admin_dir)" == "/u01/oh/network/admin" ]]
}
check "dg_net_admin_dir defaults to \$ORACLE_HOME/network/admin" t_net_admin_default

t_net_admin_tns() {
    [[ "$(TNS_ADMIN=/shared/tns ORACLE_HOME=/u01/oh dg_net_admin_dir)" == "/shared/tns" ]]
}
check "dg_net_admin_dir honours TNS_ADMIN" t_net_admin_tns

t_sqlplus_oh() {
    mkdir -p "$TEST_DIR/oh/bin"
    printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/oh/bin/sqlplus"
    chmod 755 "$TEST_DIR/oh/bin/sqlplus"
    [[ "$(ORACLE_HOME="$TEST_DIR/oh" dg_sqlplus_bin)" == "$TEST_DIR/oh/bin/sqlplus" ]]
}
check "dg_sqlplus_bin prefers \$ORACLE_HOME/bin/sqlplus" t_sqlplus_oh

t_sqlplus_path() {
    [[ "$(ORACLE_HOME="$TEST_DIR/nonexistent" dg_sqlplus_bin)" == "sqlplus" ]] \
        && [[ "$(unset ORACLE_HOME; dg_sqlplus_bin)" == "sqlplus" ]]
}
check "dg_sqlplus_bin falls back to PATH sqlplus" t_sqlplus_path

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
