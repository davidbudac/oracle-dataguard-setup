#!/usr/bin/env bash
# ============================================================
# Tests for the shared helpers in common/dg_functions.sh:
#   - enable_verbose_mode: --help, unknown options, declared flags
#     (DG_SCRIPT_FLAGS / DG_SCRIPT_POSITIONAL), value flags
#   - pause_verbose_trace / resume_verbose_trace nesting, prompt_password
#   - dgmgrl_status_value / dgmgrl_has_error_lines (19c SHOW CONFIGURATION)
#   - hostnames_match (IPv4 handling), get_db_parameter, dg_net_admin_dir,
#     dg_sqlplus_bin
#   - create_temp_dir: no-mktemp and failing-mktemp fallback, two live
#     allocations, pre-existing dirs/symlinks skipped, nested use by
#     add_sid_to_listener (finding 7)
#   - compare_db_identity / assert_db_matches_config, dgmgrl_config_members /
#     dgmgrl_foreign_members, and steps 4/6 end to end with stubbed
#     sqlplus/dgmgrl: a mismatched database makes no mutating call (finding 2)
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
for _tool in mkdir ls rmdir; do
    ln -s "$(command -v $_tool)" "$TEST_DIR/nomktemp_bin/$_tool"
done
# The same tools plus an installed-but-broken mktemp that writes junk to
# stdout and exits 1
mkdir -p "$TEST_DIR/badmktemp_bin"
for _tool in mkdir ls rmdir; do
    ln -s "$(command -v $_tool)" "$TEST_DIR/badmktemp_bin/$_tool"
done
printf '#!/bin/sh\necho /junk/from/mktemp\nexit 1\n' > "$TEST_DIR/badmktemp_bin/mktemp"
chmod 755 "$TEST_DIR/badmktemp_bin/mktemp"

mode_is_700() { [[ "$(ls -ld "$1" | cut -c1-10)" == "drwx------" ]]; }

t_fallback_creates_700() {
    local d
    d=$(PATH="$TEST_DIR/nomktemp_bin" TMPDIR="$TEST_DIR/tmpbase" create_temp_dir) || return 1
    [[ -d "$d" && "$d" == "$TEST_DIR/tmpbase/"* ]] && mode_is_700 "$d"
}
check "fallback creates a mode-700 directory" t_fallback_creates_700

t_fallback_two_live() {
    # Finding 7: two allocations alive at once in ONE shell ($$ identical
    # in both command substitutions) must get two distinct directories
    local d1 d2
    d1=$(PATH="$TEST_DIR/nomktemp_bin" TMPDIR="$TEST_DIR/tmpbase" create_temp_dir) || return 1
    d2=$(PATH="$TEST_DIR/nomktemp_bin" TMPDIR="$TEST_DIR/tmpbase" create_temp_dir) || return 1
    [[ -n "$d1" && -n "$d2" && "$d1" != "$d2" && -d "$d1" && -d "$d2" ]] || return 1
    mode_is_700 "$d1" && mode_is_700 "$d2" || return 1
    # cleanup removes both, contents included
    touch "$d1/f" "$d2/f"
    rm -rf "$d1" "$d2"
    [[ ! -e "$d1" && ! -e "$d2" ]]
}
check "fallback (no mktemp): two live allocations are distinct, both 700, cleanable" t_fallback_two_live

t_failing_mktemp_two_live() {
    local d1 d2
    d1=$(PATH="$TEST_DIR/badmktemp_bin" TMPDIR="$TEST_DIR/tmpbase" create_temp_dir) || return 1
    d2=$(PATH="$TEST_DIR/badmktemp_bin" TMPDIR="$TEST_DIR/tmpbase" create_temp_dir) || return 1
    [[ "$d1" != *junk* && "$d2" != *junk* ]] || return 1
    [[ "$d1" == "$TEST_DIR/tmpbase/dg_tmp_"* && "$d2" == "$TEST_DIR/tmpbase/dg_tmp_"* && "$d1" != "$d2" ]] || return 1
    mode_is_700 "$d1" && mode_is_700 "$d2" || return 1
    rm -rf "$d1" "$d2"
}
check "installed-but-failing mktemp falls through to the fallback, no stdout leak" t_failing_mktemp_two_live

t_fallback_skips_existing() {
    # Predictable candidates: 1 = an existing directory (ours, even mode
    # 700), 2 = a symlink to a directory, 3 = a dangling symlink, 4 = free.
    # None of the existing paths may be reused or written through.
    local base="$TEST_DIR/tmpbase3" d
    mkdir -p "$base/target"
    mkdir -m 700 "$base/cand_1"
    ln -s "$base/target" "$base/cand_2"
    ln -s "$base/nowhere" "$base/cand_3"
    d=$(
        _dg_temp_dir_candidate() { printf '%s/cand_%s\n' "$1" "$2"; }
        PATH="$TEST_DIR/nomktemp_bin" TMPDIR="$base" create_temp_dir
    ) || return 1
    [[ "$d" == "$base/cand_4" && -d "$d" && ! -L "$d" ]] || return 1
    mode_is_700 "$d" || return 1
    # the pre-existing entries are untouched
    [[ -L "$base/cand_2" && -L "$base/cand_3" && ! -e "$base/nowhere" ]] || return 1
    [[ -z "$(ls -A "$base/target")" && -z "$(ls -A "$base/cand_1")" ]]
}
check "fallback skips a pre-existing directory and symlinks, never reuses them" t_fallback_skips_existing

t_fallback_bounded() {
    # every candidate collides: give up (non-zero, nothing on stdout)
    local base="$TEST_DIR/tmpbase4" d rc=0
    mkdir -p "$base/taken"
    d=$(
        _dg_temp_dir_candidate() { printf '%s/taken\n' "$1"; }
        PATH="$TEST_DIR/nomktemp_bin" TMPDIR="$base" create_temp_dir
    ) || rc=$?
    [[ $rc -ne 0 && -z "$d" ]]
}
check "fallback gives up after a bounded number of collisions" t_fallback_bounded

t_fallback_unwritable_base() {
    # a base that cannot be written fails at once rather than retrying
    local d rc=0
    d=$(PATH="$TEST_DIR/nomktemp_bin" TMPDIR="$TEST_DIR/no_such_base" create_temp_dir) || rc=$?
    [[ $rc -ne 0 && -z "$d" ]]
}
check "fallback fails (nothing on stdout) when the base directory is unusable" t_fallback_unwritable_base

t_fallback_listener_nested() {
    # Finding 7 acceptance: the caller (step 4) holds one fallback temp dir
    # while add_sid_to_listener allocates its own; the insert must succeed
    local base="$TEST_DIR/tmpbase5" outer lf sd
    mkdir -p "$base"
    outer=$(PATH="$TEST_DIR/nomktemp_bin" TMPDIR="$base" create_temp_dir) || return 1
    lf="$TEST_DIR/listener_nested.ora"
    sd="$outer/sid_desc"
    cat > "$lf" <<'LEOF'
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = pri)(PORT = 1521))
    )
  )

SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = other)
      (ORACLE_HOME = /u01/oh)
      (SID_NAME = other)
    )
  )
LEOF
    write_sid_desc_entries "$sd" "cdb1" "/u01/oh" "cdb1" "cdb1_DGMGRL"
    (
        # Only the tools add_sid_to_listener needs - no mktemp - and count
        # the fallback candidates so the test proves the fallback ran
        PATH="$TEST_DIR/listener_bin"
        command -v mktemp >/dev/null 2>&1 && exit 99
        _dg_temp_dir_candidate() {
            printf 'x\n' >> "$TEST_DIR/inner_candidates"
            printf '%s/dg_tmp_%s_%s_%s%s\n' "$1" "$$" "$2" "$RANDOM" "$RANDOM"
        }
        TMPDIR="$base" add_sid_to_listener "$lf" "$sd"
    ) || return 1
    [[ -s "$TEST_DIR/inner_candidates" ]] || return 1
    listener_has_global_dbname "$lf" "cdb1" && listener_has_global_dbname "$lf" "cdb1_DGMGRL" \
        && listener_has_global_dbname "$lf" "other" || return 1
    # inserted inside the existing SID_LIST (before its closing paren)
    awk '/GLOBAL_DBNAME = cdb1_DGMGRL/{a=NR} /^  \)$/{c=NR} END{exit !(a && c && a < c)}' "$lf" || return 1
    # the inner allocation was cleaned up; only the caller's dir is left
    [[ -d "$outer" && "$(ls -A "$base")" == "$(basename "$outer")" ]] || return 1
    rm -rf "$outer"
}
mkdir -p "$TEST_DIR/listener_bin"
for _tool in mkdir ls rmdir rm grep awk head tail cat; do
    ln -s "$(command -v $_tool)" "$TEST_DIR/listener_bin/$_tool"
done
check "add_sid_to_listener works while the caller holds a fallback temp dir" t_fallback_listener_nested

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
# compare_db_identity (pure) - finding 2
# ============================================================

# ident <mode> <name> <role> <dbid> <exp_pri> <exp_stb> <exp_dbid>: sets
# IDENT_OUT and IDENT_RC
ident() {
    IDENT_RC=0
    IDENT_OUT=$(compare_db_identity "$@") || IDENT_RC=$?
}

t_id_primary_match() {
    ident primary cdb1 PRIMARY 1234567890 cdb1 cdb1_stby 1234567890
    [[ $IDENT_RC -eq 0 && -z "$IDENT_OUT" ]]
}
check "identity primary: exact match passes silently" t_id_primary_match

t_id_case() {
    ident primary CDB1 primary 1234567890 cdb1 CDB1_STBY 1234567890
    [[ $IDENT_RC -eq 0 && -z "$IDENT_OUT" ]]
}
check "identity: names and role compare case-insensitively" t_id_case

t_id_two_primaries() {
    # two primaries on one host: a role-only check would pass - must not
    ident primary orcl PRIMARY 999 cdb1 cdb1_stby 1234567890
    [[ $IDENT_RC -ne 0 && "$IDENT_OUT" == *"FAIL: DB_UNIQUE_NAME orcl is not the configuration primary cdb1"* \
       && "$IDENT_OUT" == *"FAIL: DBID 999"* ]]
}
check "identity primary: another PRIMARY database on the host is refused" t_id_two_primaries

t_id_two_primaries_member() {
    ident member orcl PRIMARY 1234567890 cdb1 cdb1_stby 1234567890
    [[ $IDENT_RC -ne 0 && "$IDENT_OUT" == *"FAIL: DB_UNIQUE_NAME orcl is neither"* ]]
}
check "identity member: a foreign PRIMARY is refused even with the same DBID" t_id_two_primaries_member

t_id_wrong_dbid() {
    ident primary cdb1 PRIMARY 111 cdb1 cdb1_stby 1234567890
    [[ $IDENT_RC -ne 0 && "$IDENT_OUT" == "FAIL: DBID 111 does not match the configuration DBID 1234567890" ]]
}
check "identity: right name, wrong DBID is refused" t_id_wrong_dbid

t_id_standby_role() {
    ident primary cdb1 "PHYSICAL STANDBY" 1234567890 cdb1 cdb1_stby 1234567890
    [[ $IDENT_RC -ne 0 && "$IDENT_OUT" == *"role is PHYSICAL STANDBY, not PRIMARY"* ]]
}
check "identity primary: the config primary in a standby role is refused" t_id_standby_role

t_id_standby_role_member() {
    ident member cdb1_stby "PHYSICAL STANDBY" 1234567890 cdb1 cdb1_stby 1234567890
    [[ $IDENT_RC -ne 0 && "$IDENT_OUT" == *"not PRIMARY"* ]]
}
check "identity member: the config standby still in the standby role is refused" t_id_standby_role_member

t_id_swapped_primary_mode() {
    ident primary cdb1_stby PRIMARY 1234567890 cdb1 cdb1_stby 1234567890
    [[ $IDENT_RC -ne 0 && "$IDENT_OUT" == *"is not the configuration primary"* ]]
}
check "identity primary: swapped roles are refused (initial-build steps)" t_id_swapped_primary_mode

t_id_swapped_member_mode() {
    ident member cdb1_stby PRIMARY 1234567890 cdb1 cdb1_stby 1234567890
    [[ $IDENT_RC -eq 0 && "$IDENT_OUT" == "NOTE: ROLES_SWAPPED" ]]
}
check "identity member: swapped roles are accepted with a note" t_id_swapped_member_mode

t_id_no_config_dbid() {
    ident primary cdb1 PRIMARY 1234567890 cdb1 cdb1_stby ""
    [[ $IDENT_RC -eq 0 && "$IDENT_OUT" == "WARN: "* && "$IDENT_OUT" != *FAIL* ]]
}
check "identity: config without DBID passes on the name, with a warning" t_id_no_config_dbid

t_id_no_config_dbid_wrong_name() {
    ident primary orcl PRIMARY 1 cdb1 cdb1_stby ""
    [[ $IDENT_RC -ne 0 && "$IDENT_OUT" == *"FAIL: DB_UNIQUE_NAME orcl"* ]]
}
check "identity: config without DBID still refuses the wrong name" t_id_no_config_dbid_wrong_name

t_id_empty_query() {
    ident primary "" "" "" cdb1 cdb1_stby 1234567890
    [[ $IDENT_RC -ne 0 && "$IDENT_OUT" == "FAIL: could not read"* ]]
}
check "identity: empty query result is a refusal" t_id_empty_query

t_id_empty_dbid() {
    ident primary cdb1 PRIMARY "" cdb1 cdb1_stby 1234567890
    [[ $IDENT_RC -ne 0 && "$IDENT_OUT" == *"FAIL: DBID <empty>"* ]]
}
check "identity: an empty connected DBID against a recorded one is refused" t_id_empty_dbid

t_id_no_expected_primary() {
    ident member cdb1 PRIMARY 1 "" "" ""
    [[ $IDENT_RC -ne 0 && "$IDENT_OUT" == *"no PRIMARY_DB_UNIQUE_NAME"* ]]
}
check "identity: a config without PRIMARY_DB_UNIQUE_NAME is refused" t_id_no_expected_primary

t_id_bad_mode() {
    ident whatever cdb1 PRIMARY 1 cdb1 cdb1_stby 1
    [[ $IDENT_RC -ne 0 && "$IDENT_OUT" == *"unknown identity check mode"* ]]
}
check "identity: unknown mode is refused" t_id_bad_mode

# ============================================================
# assert_db_matches_config (run_sql_query stubbed above)
# ============================================================

# assert_cfg <mode> : runs the wrapper in a subshell with the config values
# below; sets AC_RC and AC_OUT (stdout+stderr), AC_SWAPPED
assert_cfg() {
    AC_RC=0
    AC_OUT=$( (
        PRIMARY_DB_UNIQUE_NAME=cdb1 STANDBY_DB_UNIQUE_NAME=cdb1_stby DBID="$CFG_DBID"
        STANDBY_CONFIG_FILE=/nfs/standby_config_cdb1_stby.env ORACLE_SID=orcl
        assert_db_matches_config "$1"
        rc=$?
        echo "SWAPPED=${DG_CONFIG_ROLES_SWAPPED}"
        exit $rc
    ) 2>&1 ) || AC_RC=$?
}
CFG_DBID=1234567890

t_ac_match() {
    STUB_SQL_OUTPUT="cdb1|PRIMARY|1234567890"
    assert_cfg primary
    [[ $AC_RC -eq 0 && "$AC_OUT" == *"SWAPPED=0"* ]]
}
check "assert_db_matches_config: matching database passes" t_ac_match

t_ac_mismatch() {
    STUB_SQL_OUTPUT="orcl|PRIMARY|42"
    assert_cfg primary
    [[ $AC_RC -ne 0 && "$AC_OUT" == *"DB_UNIQUE_NAME=orcl ROLE=PRIMARY DBID=42 (ORACLE_SID=orcl)"* \
       && "$AC_OUT" == *"cdb1 in the PRIMARY role, DBID=1234567890"* && "$AC_OUT" == *"ORACLE_SID"* \
       && "$AC_OUT" == *"standby_config_cdb1_stby.env"* ]]
}
check "assert_db_matches_config: mismatch names both sides and the ORACLE_SID hint" t_ac_mismatch

t_ac_swapped() {
    STUB_SQL_OUTPUT="  cdb1_stby|PRIMARY|1234567890  "
    assert_cfg member
    [[ $AC_RC -eq 0 && "$AC_OUT" == *"SWAPPED=1"* && "$AC_OUT" == *"roles are swapped"* ]]
}
check "assert_db_matches_config member: swapped roles pass and set DG_CONFIG_ROLES_SWAPPED" t_ac_swapped

t_ac_empty() {
    STUB_SQL_OUTPUT=""
    assert_cfg member
    [[ $AC_RC -ne 0 && "$AC_OUT" == *"Could not read"* ]]
}
check "assert_db_matches_config: empty query output refuses" t_ac_empty

t_ac_query_fails() {
    AC_RC=0
    AC_OUT=$( (
        run_sql_query() { echo "ORA-01034: ORACLE not available"; return 1; }
        PRIMARY_DB_UNIQUE_NAME=cdb1 STANDBY_DB_UNIQUE_NAME=cdb1_stby DBID=1
        assert_db_matches_config primary
    ) 2>&1 ) || AC_RC=$?
    [[ $AC_RC -ne 0 && "$AC_OUT" == *"Could not read"* ]]
}
check "assert_db_matches_config: a failed query refuses" t_ac_query_fails

t_ac_no_dbid() {
    STUB_SQL_OUTPUT="cdb1|PRIMARY|1234567890"
    CFG_DBID="" assert_cfg primary
    local rc=$AC_RC
    [[ $rc -eq 0 && "$AC_OUT" == *"DBID not cross-checked"* ]]
}
check "assert_db_matches_config: config without DBID passes with a warning" t_ac_no_dbid

t_query_file() {
    local f="${SQL_DIR}/queries/get_db_identity_pipe.sql"
    [[ -f "$f" ]] && grep -qi '^SET DEFINE OFF' "$f" && grep -q 'WHENEVER SQLERROR EXIT' "$f" \
        && grep -q 'DB_UNIQUE_NAME' "$f" && grep -q 'DATABASE_ROLE' "$f" && grep -q 'DBID' "$f"
}
check "get_db_identity_pipe.sql exists with SET DEFINE OFF and WHENEVER SQLERROR" t_query_file

# ============================================================
# dgmgrl_config_members / dgmgrl_foreign_members - finding 2
# ============================================================

SHOW_CFG_FOREIGN='
Configuration - dg_cdb1

  Protection Mode: MaxAvailability
  Members:
  cdb1      - Primary database
    Error: ORA-16810: multiple errors or warnings detected for the member

    cdb1_stby - (*) Physical standby database
      Warning: ORA-16809: multiple warnings detected for the member

    orcl_far  - Far sync instance

  Members Not Receiving Redo:
  orcl_stby - Physical standby database (disabled)
    ORA-16795: the standby database needs to be re-created

Fast-Start Failover: Enabled in Zero Data Loss Mode
  Target:          cdb1_stby
  Observer:        dg3 - (*) Master

Configuration Status:
ERROR   (status updated 3 seconds ago)
'

members_are() { [[ "$(dgmgrl_config_members "$1" | tr '\n' ' ')" == "$2" ]]; }

check "members: 19c SUCCESS sample" members_are "$SHOW_CFG_SUCCESS" "cdb1 cdb1_stby "
check "members: real lab output with the FSFO (*) marker" members_are "$SHOW_CFG_LAB" "cdb1 cdb1_stby "
check "members: Warning: lines under members are not members" members_are "$SHOW_CFG_WARNING" "cdb1 cdb1_stby "
check "members: Error:/ORA- lines under members are not members" members_are "$SHOW_CFG_ERROR" "cdb1 cdb1_stby "
check "members: far sync and Members Not Receiving Redo; observer line excluded" \
    members_are "$SHOW_CFG_FOREIGN" "cdb1 cdb1_stby orcl_far orcl_stby "
check "members: CRLF output" members_are "$(printf 'Configuration - x\r\n  Members:\r\n  cdb1 - Primary database\r\n\r\nConfiguration Status:\r\nSUCCESS\r\n')" "cdb1 "
check "members: no configuration -> nothing" members_are "$ERR_NO_CONFIG" ""

foreign_are() { local o="$1" want="$2"; shift 2; [[ "$(dgmgrl_foreign_members "$o" "$@" | tr '\n' ' ')" == "$want" ]]; }

check "foreign: none when every member belongs to the config" foreign_are "$SHOW_CFG_LAB" "" cdb1 cdb1_stby
check "foreign: config names compare case-insensitively" foreign_are "$SHOW_CFG_LAB" "" CDB1 CDB1_STBY
check "foreign: other members are named" foreign_are "$SHOW_CFG_FOREIGN" "orcl_far orcl_stby " cdb1 cdb1_stby
check "foreign: a config for different databases names every member" foreign_are "$SHOW_CFG_SUCCESS" "cdb1 cdb1_stby " orcl orcl_stby

# ============================================================
# Steps 4 and 6 end to end with stubbed Oracle binaries - finding 2
# ============================================================
# A mismatched database must stop the step with ZERO mutating invocations:
# the only sqlplus calls allowed are check_connection.sql and the identity
# query, no dgmgrl/lsnrctl call at all, and no file under TNS_ADMIN.

REPO_DIR="$(dirname "$SCRIPT_DIR")"
E2E="$TEST_DIR/e2e"
mkdir -p "$E2E/oh/bin" "$E2E/nfs" "$E2E/tns"
cat > "$E2E/oh/bin/sqlplus" <<'SQLEOF'
#!/bin/bash
script=""
for a in "$@"; do case "$a" in @*) script="${a#@}" ;; esac; done
printf 'sqlplus %s\n' "$(basename "$script")" >> "$STUB_LOG"
case "$(basename "$script")" in
    check_connection.sql) echo CONNECTED ;;
    get_db_identity_pipe.sql) printf '%s\n' "$STUB_IDENTITY" ;;
    get_db_parameter.sql) echo TRUE ;;
    get_dmon_count.sql) echo 1 ;;
    *) echo "" ;;
esac
exit 0
SQLEOF
cat > "$E2E/oh/bin/dgmgrl" <<'DGEOF'
#!/bin/bash
cmd=$(cat)
printf 'dgmgrl %s\n' "$(printf '%s' "$cmd" | tr '\n' ' ')" >> "$STUB_LOG"
case "$cmd" in
    *"SHOW CONFIGURATION"*) printf '%s\n' "$STUB_SHOW_CONFIG" ;;
    *) echo "Succeeded." ;;
esac
DGEOF
for _b in lsnrctl tnsping; do
    printf '#!/bin/bash\necho "%s $*" >> "$STUB_LOG"\nexit 0\n' "$_b" > "$E2E/oh/bin/$_b"
done
chmod 755 "$E2E/oh/bin/"*
cat > "$E2E/nfs/standby_config_cdb1_stby.env" <<'ENVEOF'
PRIMARY_DB_NAME="cdb1"
PRIMARY_DB_UNIQUE_NAME="cdb1"
PRIMARY_ORACLE_SID="cdb1"
PRIMARY_HOSTNAME="pri.example.com"
PRIMARY_TNS_ALIAS="cdb1"
STANDBY_DB_UNIQUE_NAME="cdb1_stby"
STANDBY_HOSTNAME="stb.example.com"
STANDBY_TNS_ALIAS="cdb1_stby"
DBID="1234567890"
STANDBY_REDO_GROUPS="4"
ENVEOF

# run_step <script> <identity> <stdin> [args...] : sets STEP_RC, STEP_OUT;
# the invocation log is $E2E/calls.log
run_step() {
    local script="$1" identity="$2" input="$3"
    shift 3
    : > "$E2E/calls.log"
    STEP_RC=0
    STEP_OUT=$(printf "$input" | env ORACLE_HOME="$E2E/oh" ORACLE_SID=orcl NFS_SHARE="$E2E/nfs" \
        TNS_ADMIN="$E2E/tns" STUB_LOG="$E2E/calls.log" STUB_IDENTITY="$identity" \
        STUB_SHOW_CONFIG="${STUB_SHOW_CONFIG:-}" PATH="$E2E/oh/bin:$PATH" \
        bash "$REPO_DIR/primary/$script" "$@" 2>&1) || STEP_RC=$?
}
# only the two read-only identity calls were made
only_identity_calls() {
    [[ "$(grep -v -e '^sqlplus check_connection.sql' -e '^sqlplus get_db_identity_pipe.sql' "$E2E/calls.log")" == "" ]] \
        && grep -q '^sqlplus get_db_identity_pipe.sql' "$E2E/calls.log" \
        && [[ -z "$(ls -A "$E2E/tns")" ]]
}

t_e2e_step4_mismatch() {
    run_step 04_prepare_primary_dg.sh "orcl|PRIMARY|42" ""
    [[ $STEP_RC -eq 1 && "$STEP_OUT" == *"does not match the selected configuration"* ]] && only_identity_calls
}
check "step 4: another PRIMARY on the host exits 1 with zero mutating calls" t_e2e_step4_mismatch

t_e2e_step4_mismatch_check() {
    run_step 04_prepare_primary_dg.sh "orcl|PRIMARY|42" "" -n
    [[ $STEP_RC -eq 1 && "$STEP_OUT" == *"does not match"* && "$STEP_OUT" != *"preflight complete"* ]] && only_identity_calls
}
check "step 4 -n: the mismatch is reported and exits 1" t_e2e_step4_mismatch_check

t_e2e_step4_match_check() {
    # positive control: the matching database gets past the guard to the -n stop
    run_step 04_prepare_primary_dg.sh "cdb1|PRIMARY|1234567890" "" -n
    [[ $STEP_RC -eq 0 && "$STEP_OUT" == *"matches the selected configuration"* ]] && only_identity_calls
}
check "step 4 -n: the matching database passes the guard (control)" t_e2e_step4_match_check

t_e2e_step6_mismatch() {
    run_step 06_configure_broker.sh "cdb1|PRIMARY|42" "y\n"
    [[ $STEP_RC -eq 1 && "$STEP_OUT" == *"DBID 42 does not match"* ]] && only_identity_calls
}
check "step 6: wrong DBID exits 1 before any dgmgrl call" t_e2e_step6_mismatch

t_e2e_step6_standby() {
    run_step 06_configure_broker.sh "cdb1_stby|PHYSICAL STANDBY|1234567890" "y\n"
    [[ $STEP_RC -eq 1 ]] && only_identity_calls
}
check "step 6: connected to the standby exits 1 before any dgmgrl call" t_e2e_step6_standby

t_e2e_step6_foreign_member() {
    # right database, but the existing broker configuration also manages
    # orcl_far/orcl_stby: piped stdin -> refuse, no DISABLE/REMOVE issued
    STUB_SHOW_CONFIG="$SHOW_CFG_FOREIGN" run_step 06_configure_broker.sh "cdb1|PRIMARY|1234567890" "y\n"
    [[ $STEP_RC -eq 1 && "$STEP_OUT" == *"orcl_far"* && "$STEP_OUT" == *"orcl_stby"* \
       && "$STEP_OUT" == *"Refusing to remove"* ]] || return 1
    ! grep -qi -e 'REMOVE CONFIGURATION' -e 'DISABLE FAST_START' "$E2E/calls.log"
}
check "step 6: foreign broker members refuse non-interactively, nothing removed" t_e2e_step6_foreign_member

t_e2e_step6_own_members() {
    # control: own members only -> the existing prompt is reached and the
    # piped 'n' keeps the configuration (exit 0), no second prompt consumed
    STUB_SHOW_CONFIG="$SHOW_CFG_SUCCESS" run_step 06_configure_broker.sh "cdb1|PRIMARY|1234567890" "n\n"
    [[ $STEP_RC -eq 0 && "$STEP_OUT" == *"Keeping existing configuration"* && "$STEP_OUT" != *"Refusing"* \
       && "$STEP_OUT" != *"NOT part of the selected"* ]] || return 1
    ! grep -qi 'REMOVE CONFIGURATION' "$E2E/calls.log"
}
check "step 6: own members only keep today's single prompt (control)" t_e2e_step6_own_members

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
