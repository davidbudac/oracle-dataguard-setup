#!/usr/bin/env bash
# ============================================================
# Oracle Data Guard Setup - Shared Utility Functions
# ============================================================

# Get the directory where this script is located
DG_FUNCTIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes for output. TTY/NO_COLOR-aware color init (dg_render_init_colors)
# lives in dg_render_common.sh, shared with dg_status.sh and
# dg_local_status_common.sh (WS4.2). Sourcing it here means every script
# under primary/, standby/, trigger/, fsfo/, nfs/ that sources dg_functions.sh
# picks up TTY-aware colors and --no-color (via enable_verbose_mode below)
# automatically - no per-script changes needed. dg_render_common.sh already
# calls dg_render_init_colors once, unconditionally, as soon as it is
# sourced, so color vars are sane immediately - before enable_verbose_mode
# (or any --no-color flag) is ever parsed.
source "${DG_FUNCTIONS_DIR}/dg_render_common.sh"

# NFS share path for file exchange (default, can be overridden by confirm_nfs_share)
NFS_SHARE="${NFS_SHARE:-/OINSTALL/_dataguard_setup}"
VERBOSE="${VERBOSE:-0}"
APPROVAL_MODE="${APPROVAL_MODE:-${SUSPICIOUS:-0}}"
CHECK_ONLY="${CHECK_ONLY:-0}"
VERBOSE_TRACE_PAUSED=0
ERROR_TRAP_ACTIVE=0
CURRENT_PROGRESS_TITLE=""
STEP_STATE_FILE=""

# SQL scripts directory (relative to project root)
SQL_DIR="$(dirname "$DG_FUNCTIONS_DIR")/sql"

# ============================================================
# Logging Functions
# ============================================================

enable_verbose_mode() {
    local args=("$@")
    local i=0
    local no_color_flag=false

    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            -v|--verbose)
                VERBOSE=1
                ;;
            -a|--approval-mode|-s|--suspicious)
                APPROVAL_MODE=1
                ;;
            --no-verbose)
                VERBOSE=0
                ;;
            --no-approval-mode|--no-suspicious)
                APPROVAL_MODE=0
                ;;
            -n|--check|--plan)
                CHECK_ONLY=1
                ;;
            --execute)
                CHECK_ONLY=0
                ;;
            --no-color)
                no_color_flag=true
                ;;
        esac
        i=$((i + 1))
    done

    # Re-initialize colors now that --no-color has been parsed (WS4.2). Any
    # script that calls enable_verbose_mode "$@" near its own top gets this
    # for free without adding its own flag handling.
    $no_color_flag && dg_render_init_colors 1

    export VERBOSE
    export APPROVAL_MODE
    export CHECK_ONLY
    export SUSPICIOUS="$APPROVAL_MODE"

    set -E -o pipefail
    trap 'handle_error "$?" "$BASH_COMMAND" "${BASH_LINENO[0]:-$LINENO}"' ERR

    if [[ "$VERBOSE" == "1" ]]; then
        export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
        set -x
        log_info "Verbose mode enabled. Shell command tracing is active."
    fi

    if [[ "$APPROVAL_MODE" == "1" ]]; then
        log_info "Approval mode enabled. Mutating actions require approval."
    fi

    if [[ "$CHECK_ONLY" == "1" ]]; then
        log_info "Check mode enabled. The script will stop before making changes."
    fi

}

pause_verbose_trace() {
    if [[ "$VERBOSE" == "1" && "$-" == *x* ]]; then
        VERBOSE_TRACE_PAUSED=1
        set +x
    else
        VERBOSE_TRACE_PAUSED=0
    fi
}

resume_verbose_trace() {
    if [[ "$VERBOSE_TRACE_PAUSED" == "1" ]]; then
        VERBOSE_TRACE_PAUSED=0
        set -x
    fi
}

log_info() {
    printf "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - %s\n" "$1"
    [ -n "$LOG_FILE" ] && echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" || :
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - %s\n" "$1"
    [ -n "$LOG_FILE" ] && echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" || :
}

log_success() {
    printf "${CYAN}[OK]${NC} $(date '+%Y-%m-%d %H:%M:%S') - %s\n" "$1"
    [ -n "$LOG_FILE" ] && echo "[OK] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" || :
}

log_error() {
    printf "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - %s\n" "$1"
    [ -n "$LOG_FILE" ] && echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" || :
}

log_section() {
    echo ""
    printf "${BLUE}============================================================${NC}\n"
    printf "${BLUE}%s${NC}\n" "$1"
    printf "${BLUE}============================================================${NC}\n"
    echo ""
    if [ -n "$LOG_FILE" ]; then
        echo "" >> "$LOG_FILE"
        echo "============================================================" >> "$LOG_FILE"
        echo "$1" >> "$LOG_FILE"
        echo "============================================================" >> "$LOG_FILE"
    fi
}

# Log a command that is about to be executed
# Usage: log_cmd "sqlplus / as sysdba" "STARTUP NOMOUNT PFILE='...'"
# Or:    log_cmd "COMMAND:" "lsnrctl reload"
log_cmd() {
    local prefix="$1"
    local cmd="$2"
    printf "${YELLOW}>>> %s${NC} %s\n" "$prefix" "$cmd"
    [ -n "$LOG_FILE" ] && echo ">>> $prefix $cmd" >> "$LOG_FILE" || :
}

log_detail() {
    [ -n "$LOG_FILE" ] && printf "%s\n" "$1" >> "$LOG_FILE" || :
}

shell_join() {
    local arg
    local output=""
    local quoted

    for arg in "$@"; do
        printf -v quoted '%q' "$arg"
        output="${output:+${output} }${quoted}"
    done

    printf '%s' "$output"
}

confirm_approval_action() {
    local action_title="$1"
    local action_cmd="$2"
    local response
    local impact_scope

    if [[ "$APPROVAL_MODE" != "1" ]]; then
        return 0
    fi

    case "$action_cmd" in
        *sqlplus* )
            impact_scope="Database change"
            ;;
        *rman* )
            impact_scope="RMAN / database storage change"
            ;;
        *dgmgrl* )
            impact_scope="Data Guard Broker change"
            ;;
        *listener.ora*|*tnsnames.ora*|*/etc/oratab* )
            impact_scope="Oracle host configuration change"
            ;;
        *mkdir*|*cp*|*chmod*|*mv*|*append*|*write* )
            impact_scope="Filesystem change"
            ;;
        * )
            impact_scope="Mutating external action"
            ;;
    esac

    # Send banner and prompt to stderr so they remain visible when a call
    # site captures stdout via command substitution.
    {
        echo ""
        printf "${BLUE}============================================================${NC}\n"
        printf "${YELLOW}Approval Mode Check${NC}\n"
        printf "${BLUE}============================================================${NC}\n"
        print_status_row "Action" "$action_title"
        print_status_row "Impact" "$impact_scope"
        if [[ -n "$LOG_FILE" ]]; then
            print_status_row "Log File" "$LOG_FILE"
        fi
        echo ""
        printf "${BLUE}Command Preview${NC}\n"
        printf "${BLUE}%s${NC}\n" "------------------------------------------------------------"
        printf "  %s\n" "$action_cmd"
        echo ""
        printf "${YELLOW}Approve this action? [y/N]: ${NC}"
    } >&2
    read -r response

    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
    esac

    log_warn "Action cancelled by user: $action_title"
    return 1
}

confirm_suspicious_action() {
    confirm_approval_action "$@"
}

run_mutating_command() {
    local action_title="$1"
    shift
    local action_cmd

    action_cmd=$(shell_join "$@")
    confirm_approval_action "$action_title" "$action_cmd" || return 1
    "$@"
}

handle_error() {
    local exit_code="$1"
    local failing_command="$2"
    local line_no="$3"

    if [[ "$ERROR_TRAP_ACTIVE" == "1" ]]; then
        return "$exit_code"
    fi

    ERROR_TRAP_ACTIVE=1
    log_error "Command failed at line ${line_no}: ${failing_command}"
    if [[ -n "$CURRENT_PROGRESS_TITLE" ]]; then
        log_error "Failure occurred during step: ${CURRENT_PROGRESS_TITLE}"
    fi
    if [[ -n "$LOG_FILE" ]]; then
        log_error "Review log: ${LOG_FILE}"
    fi
    if [[ -n "$STEP_STATE_FILE" ]]; then
        record_state_value "status" "ERROR"
        record_state_value "failed_line" "$line_no"
        record_state_value "failed_command" "$failing_command"
    fi
    ERROR_TRAP_ACTIVE=0
    return "$exit_code"
}

# Initialize log file
init_log() {
    local script_name="$1"
    local log_dir="${NFS_SHARE}/logs"
    local state_dir="${NFS_SHARE}/state"

    # Idempotent: several scripts call init_log twice in one run (a
    # generic name at startup, then a DB_UNIQUE_NAME-qualified name once
    # config is loaded). Without this guard, the second call created a
    # brand-new state file and left the first one behind forever marked
    # status=RUNNING - print_summary only ever updates the *current*
    # STEP_STATE_FILE, so the earlier one never gets finalized. Reuse the
    # existing log/state files and just relabel the run instead.
    if [[ -n "${STEP_STATE_FILE:-}" && -f "$STEP_STATE_FILE" ]]; then
        record_state_value "script_name" "$script_name"
        log_info "Log re-initialized for: $script_name (reusing existing log/state files)"
        return 0
    fi

    mkdir -p "$log_dir" 2>/dev/null
    mkdir -p "$state_dir" 2>/dev/null
    LOG_FILE="${log_dir}/${script_name}_$(date '+%Y%m%d_%H%M%S').log"
    STEP_STATE_FILE="${state_dir}/${script_name}_$(date '+%Y%m%d_%H%M%S').state"

    # If the log location is not writable (e.g. NFS share not mounted yet),
    # degrade gracefully: disable file logging so the script can proceed to
    # the proper check_nfs_mount error instead of dying here under set -e.
    if ! echo "============================================================" > "$LOG_FILE" 2>/dev/null; then
        LOG_FILE="/dev/null"
        STEP_STATE_FILE=""
        log_warn "Log directory not writable: ${log_dir} - file logging disabled for this run"
        return 0
    fi
    echo "Log started: $(date)" >> "$LOG_FILE"
    echo "Script: $script_name" >> "$LOG_FILE"
    echo "Hostname: $(hostname)" >> "$LOG_FILE"
    echo "============================================================" >> "$LOG_FILE"

    if ! cat > "$STEP_STATE_FILE" 2>/dev/null <<EOF
script_name=$(printf '%q' "$script_name")
hostname=$(printf '%q' "$(hostname)")
status=RUNNING
log_file=$(printf '%q' "$LOG_FILE")
check_only=$(printf '%q' "$CHECK_ONLY")
EOF
    then
        log_warn "State directory not writable: ${state_dir} - state tracking disabled for this run"
        STEP_STATE_FILE=""
        return 0
    fi

    log_info "Log file initialized: $LOG_FILE"
    log_info "State file initialized: $STEP_STATE_FILE"
}

record_state_value() {
    local key="$1"
    local value="$2"
    local temp_file

    [[ -z "$STEP_STATE_FILE" ]] && return 0

    temp_file="${STEP_STATE_FILE}.tmp.$$"
    if [[ -f "$STEP_STATE_FILE" ]]; then
        grep -v "^${key}=" "$STEP_STATE_FILE" > "$temp_file" || true
    else
        : > "$temp_file"
    fi
    printf '%s=%q\n' "$key" "$value" >> "$temp_file"
    mv "$temp_file" "$STEP_STATE_FILE"
}

append_state_value() {
    local key="$1"
    local value="$2"

    [[ -z "$STEP_STATE_FILE" ]] && return 0
    printf '%s=%q\n' "$key" "$value" >> "$STEP_STATE_FILE"
}

record_artifact() {
    append_state_value "artifact" "$1"
}

record_next_step() {
    record_state_value "next_step" "$1"
}

finish_check_mode() {
    local message="$1"
    record_state_value "status" "CHECK_ONLY"
    print_summary "SUCCESS" "$message"
    exit 0
}

# ============================================================
# String Utility Functions
# ============================================================

# Strip all whitespace (spaces, tabs, newlines) from a string
# AIX compatible - uses POSIX character class [:space:]
# Usage: VALUE=$(strip_whitespace "$VALUE")
strip_whitespace() {
    echo "$1" | tr -d '[:space:]'
}

# ============================================================
# Temp File Helpers
# ============================================================

# Create a private temp directory for scratch files, preferring `mktemp -d`
# (unpredictable name, created atomically, mode 700). Falls back to a
# manually created mode-700 directory named with $$ when `mktemp` is not on
# PATH (e.g. a minimal AIX image) - a fixed `/tmp/foo_$$` filename is
# predictable and can be pre-created/symlinked by another user, so any
# fallback still needs its own private, non-world-writable directory rather
# than a bare file directly under /tmp.
# Prints the directory path to stdout. Callers should immediately register
# `trap 'rm -rf "$dir"' EXIT` (merging with any existing EXIT trap) so the
# directory and everything placed inside it are cleaned up on every exit
# path, not just the happy path.
# Usage: MY_TMP_DIR=$(create_temp_dir) && trap 'rm -rf "$MY_TMP_DIR"' EXIT
#        MY_TMP_FILE="${MY_TMP_DIR}/dg_sid_desc_primary.$$"
create_temp_dir() {
    if command -v mktemp >/dev/null 2>&1; then
        mktemp -d 2>/dev/null && return
    fi
    local dir="${TMPDIR:-/tmp}/dg_tmp_$$"
    mkdir -m 700 -p "$dir" 2>/dev/null && printf '%s\n' "$dir"
}

# ============================================================
# Validation Functions
# ============================================================

check_oracle_env() {
    log_info "Checking Oracle environment variables..."

    if [[ -z "$ORACLE_HOME" ]]; then
        log_error "ORACLE_HOME is not set"
        return 1
    fi

    if [[ -z "$ORACLE_SID" ]]; then
        log_error "ORACLE_SID is not set"
        return 1
    fi

    if [[ ! -d "$ORACLE_HOME" ]]; then
        log_error "ORACLE_HOME directory does not exist: $ORACLE_HOME"
        return 1
    fi

    if [[ ! -x "$ORACLE_HOME/bin/sqlplus" ]]; then
        log_error "sqlplus not found or not executable: $ORACLE_HOME/bin/sqlplus"
        return 1
    fi

    log_info "ORACLE_HOME: $ORACLE_HOME"
    log_info "ORACLE_SID: $ORACLE_SID"
    log_info "ORACLE_BASE: ${ORACLE_BASE:-not set}"

    return 0
}

check_oracle_client_env() {
    log_info "Checking Oracle client environment..."

    if [[ -z "$ORACLE_HOME" ]]; then
        log_error "ORACLE_HOME is not set"
        return 1
    fi

    if [[ ! -d "$ORACLE_HOME" ]]; then
        log_error "ORACLE_HOME directory does not exist: $ORACLE_HOME"
        return 1
    fi

    if [[ ! -x "$ORACLE_HOME/bin/dgmgrl" ]]; then
        log_error "dgmgrl not found or not executable: $ORACLE_HOME/bin/dgmgrl"
        return 1
    fi

    log_info "ORACLE_HOME: $ORACLE_HOME"
    return 0
}

check_nfs_mount() {
    log_info "Checking NFS mount at $NFS_SHARE..."

    if [[ ! -d "$NFS_SHARE" ]]; then
        log_error "NFS share directory does not exist: $NFS_SHARE"
        log_error "Please ensure the NFS mount is available"
        return 1
    fi

    # Test write access
    local test_file="${NFS_SHARE}/.write_test_$$"
    if ! touch "$test_file" 2>/dev/null; then
        log_error "Cannot write to NFS share: $NFS_SHARE"
        return 1
    fi
    rm -f "$test_file"

    log_info "NFS share is accessible and writable"
    return 0
}

# Parse the available-KB column from POSIX `df -Pk` output, reading the
# report from stdin. Kept as a separate pure function (no `df` call of its
# own) so a unit test can pipe captured df output through it directly.
# Usage: df -Pk "$path" | parse_df_available_kb
parse_df_available_kb() {
    tail -1 | awk '{print $4}'
}

# Get available space in KB for the filesystem containing $path.
# Uses `df -Pk` (POSIX output format) so the column layout is identical on
# Linux and AIX. Plain `df -k` on AIX places %Used in field 4 (not free KB
# as on Linux), which silently breaks downstream arithmetic.
# Usage: AVAILABLE_KB=$(get_available_space_kb "$path")
get_available_space_kb() {
    local path="$1"
    df -Pk "$path" 2>/dev/null | parse_df_available_kb
}

# Prompt user to confirm or provide NFS share location
# Usage: confirm_nfs_share
# Sets: NFS_SHARE global variable
confirm_nfs_share() {
    local default_path="$NFS_SHARE"
    local user_input

    echo ""
    printf "${BLUE}============================================================${NC}\n"
    printf "${BLUE}NFS Share Location Configuration${NC}\n"
    printf "${BLUE}============================================================${NC}\n"
    echo ""
    printf "The NFS share is used to exchange files between primary and standby servers.\n"
    echo ""
    printf "Current NFS share path: ${GREEN}%s${NC}\n" "$default_path"
    echo ""
    printf "Press Enter to use this path, or type a different path: "
    read -r user_input

    if [[ -n "$user_input" ]]; then
        # User provided a different path - strip trailing slash
        NFS_SHARE="${user_input%/}"
        log_info "NFS share path set to: $NFS_SHARE"
    else
        log_info "Using default NFS share path: $NFS_SHARE"
    fi

    # Export so child processes can access it
    export NFS_SHARE
}

check_db_connection() {
    log_info "Checking database connection..."

    local result
    result=$(sqlplus -s / as sysdba @"${SQL_DIR}/queries/check_connection.sql" </dev/null)

    if echo "$result" | grep -q "CONNECTED"; then
        log_info "Successfully connected to database"
        return 0
    else
        log_error "Failed to connect to database as SYSDBA"
        log_error "Output: $result"
        return 1
    fi
}

# ============================================================
# SQL Execution Functions
# ============================================================

# Run a SQL script file
# Usage: run_sql_script <script_path> [arg1] [arg2] ...
run_sql_script() {
    local script="$1"
    shift
    confirm_approval_action "Run SQL script" "sqlplus -s / as sysdba @$script $(shell_join "$@")" || return 1
    sqlplus -s / as sysdba @"$script" "$@" </dev/null
}

# Run a SQL query script and return clean output
# Usage: run_sql_query <script_name> [arg1] [arg2] ...
# Note: script_name is relative to $SQL_DIR/queries/
run_sql_query() {
    local script_name="$1"
    shift
    # Redirect stdin from /dev/null: these query scripts are non-interactive,
    # so if sqlplus ever falls through to its SQL> prompt (e.g. SP2-0310 when
    # the script file is missing, or a statement that errors before EXIT) it
    # gets EOF and exits instead of blocking forever reading the terminal.
    #
    # The query scripts carry WHENEVER SQLERROR EXIT SQL.SQLCODE, so a
    # failed query returns nonzero. Callers almost always capture stdout
    # via $(...) - under set -e that would abort the script with the ORA-
    # text trapped inside the never-used substitution. Surface the failure
    # on stderr before propagating the exit code.
    # The && rc=0 || rc=$? form keeps set -e from exiting on the failing
    # assignment before we get a chance to print the error to stderr.
    local output rc
    output=$(sqlplus -s / as sysdba @"${SQL_DIR}/queries/${script_name}" "$@" </dev/null) && rc=0 || rc=$?
    printf '%s\n' "$output"
    if [[ $rc -ne 0 ]]; then
        printf 'ERROR: SQL query %s failed (exit %s). Output:\n%s\n' "$script_name" "$rc" "$output" >&2
    fi
    return $rc
}

# Run a SQL command script
# Usage: run_sql_command <script_name> [arg1] [arg2] ...
# Note: script_name is relative to $SQL_DIR/commands/
run_sql_command() {
    local script_name="$1"
    shift
    confirm_approval_action "Run SQL command script" "sqlplus -s / as sysdba @${SQL_DIR}/commands/${script_name} $(shell_join "$@")" || return 1
    sqlplus -s / as sysdba @"${SQL_DIR}/commands/${script_name}" "$@" </dev/null
}

# Run a SQL query script with headers (for display)
# Usage: run_sql_display <script_name> [arg1] [arg2] ...
run_sql_display() {
    local script_name="$1"
    shift
    sqlplus -s / as sysdba @"${SQL_DIR}/queries/${script_name}" "$@" </dev/null
}

# Check whether a value is a plain non-negative integer (no sign, no
# decimal point, no thousands separators). Use this to guard SQL*Plus
# query output before it flows into shell arithmetic ($(( )) ) or gets
# written into a generated env file - a query that errors out (or
# returns NULL/empty because of an unexpected server state) must not
# silently poison a downstream calculation.
# bash 3.2 / AIX safe: plain ERE via [[ =~ ]], no grep -P, no \s.
# Usage: is_numeric <value>
is_numeric() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]]
}

# Get a database parameter value
# Usage: get_db_parameter <param_name>
get_db_parameter() {
    local param_name="$1"
    local value
    value=$(run_sql_query "get_db_parameter.sql" "$param_name")
    echo "$value" | tr -d ' \n\r'
}

# Get a database property value
# Usage: get_db_property <property_name>
get_db_property() {
    local prop_name="$1"
    local value
    value=$(run_sql_query "get_db_property.sql" "$prop_name")
    echo "$value" | tr -d ' \n\r'
}

# ============================================================
# RMAN Execution Functions
# ============================================================

# Run an RMAN script file
# Usage: run_rman_script <script_path>
run_rman_script() {
    local script="$1"
    confirm_approval_action "Run RMAN script" "\"$ORACLE_HOME/bin/rman\" target / @$script" || return 1
    "$ORACLE_HOME/bin/rman" target / @"$script"
}

# Run an RMAN script from the sql/rman directory
# Usage: run_rman <script_name>
run_rman() {
    local script_name="$1"
    confirm_approval_action "Run RMAN command script" "\"$ORACLE_HOME/bin/rman\" target / @${SQL_DIR}/rman/${script_name}" || return 1
    "$ORACLE_HOME/bin/rman" target / @"${SQL_DIR}/rman/${script_name}"
}

is_mutating_dgmgrl_script() {
    case "$(basename "$1")" in
        show_*|validate_*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# ============================================================
# DGMGRL Execution Functions
# ============================================================

# Substitute &1, &2, etc. in dgmgrl script content with provided arguments
# Unlike SQLPlus, dgmgrl does not support passing positional arguments after @script
# Usage: substitute_dgmgrl_args <script_content> [arg1] [arg2] ...
substitute_dgmgrl_args() {
    local content="$1"
    shift
    local i=1
    local arg esc_arg
    for arg in "$@"; do
        # Escape the replacement side for sed: backslash first (so we
        # don't double-escape the backslashes just inserted), then the
        # '|' delimiter, then '&' (sed's "whole match" backreference).
        # Without this, an arg containing any of those characters (e.g.
        # a password or path with '&') could corrupt the substitution
        # or inject a bogus backreference into the generated DGMGRL
        # script. (Bash's own ${content//pat/repl} was tried instead of
        # sed here, but bash 5.2+ gives '&' in the replacement the same
        # "whole match" meaning sed does, so it needs identical escaping
        # - sed is kept since callers already expect sed semantics.)
        esc_arg=$(printf '%s' "$arg" | sed 's/\\/\\\\/g; s/|/\\|/g; s/&/\\\&/g')
        content=$(printf '%s' "$content" | sed "s|&${i}|${esc_arg}|g")
        i=$((i + 1))
    done
    printf '%s' "$content"
}

# Run a DGMGRL script file with OS authentication
# Usage: run_dgmgrl_script <script_path> [arg1] [arg2] ...
run_dgmgrl_script() {
    local script="$1"
    shift
    local content
    content=$(cat "$script")
    content=$(substitute_dgmgrl_args "$content" "$@")
    if is_mutating_dgmgrl_script "$script"; then
        confirm_approval_action "Run DGMGRL script" "printf '<script>' | \"$ORACLE_HOME/bin/dgmgrl\" -silent /  # $(basename "$script") $(shell_join "$@")" || return 1
    fi
    printf '%s\n' "$content" | "$ORACLE_HOME/bin/dgmgrl" -silent /
}

# Run a DGMGRL script from the sql/dgmgrl directory
# Usage: run_dgmgrl <script_name> [arg1] [arg2] ...
run_dgmgrl() {
    local script_name="$1"
    shift
    local script_path="${SQL_DIR}/dgmgrl/${script_name}"
    local content
    content=$(cat "$script_path")
    content=$(substitute_dgmgrl_args "$content" "$@")
    if is_mutating_dgmgrl_script "$script_name"; then
        confirm_approval_action "Run DGMGRL script" "printf '<script>' | \"$ORACLE_HOME/bin/dgmgrl\" -silent /  # ${script_name} $(shell_join "$@")" || return 1
    fi
    printf '%s\n' "$content" | "$ORACLE_HOME/bin/dgmgrl" -silent /
}

# Inspect captured DGMGRL output for failure patterns.
# dgmgrl scripts always end in EXIT; so the process exit code is 0 even
# when a command inside the script failed - the only reliable signal is
# the text DGMGRL printed. Matches real ORA-/DGM- error codes and
# "Error:"/"Failed." lines, while deliberately NOT matching benign broker
# report lines such as "Error: 0" (no error) that appear in SHOW
# CONFIGURATION / SHOW DATABASE output, or property names/values that
# merely contain the word "error".
# Usage: dgmgrl_output_has_error <output>
dgmgrl_output_has_error() {
    local output="$1"
    # Real Oracle/broker error codes anywhere in the output.
    if printf '%s\n' "$output" | grep -Eq 'ORA-[0-9]|DGM-[0-9]'; then
        return 0
    fi
    # A standalone "Error:" line with a nonzero code. "Error: 0" is the
    # benign per-member status line in SHOW CONFIGURATION/SHOW DATABASE.
    if printf '%s\n' "$output" | grep -Eiq '^[[:space:]]*Error:[[:space:]]*[1-9]'; then
        return 0
    fi
    # DGMGRL prints a standalone "Failed." line for some failed operations.
    if printf '%s\n' "$output" | grep -Eiq '^[[:space:]]*Failed\.[[:space:]]*$'; then
        return 0
    fi
    return 1
}

# Run a DGMGRL script from the sql/dgmgrl directory and check its output
# for failure patterns, since the script's own exit code is always 0
# (every sql/dgmgrl/*.dgmgrl script ends in EXIT;). Use this instead of
# run_dgmgrl for MUTATING broker commands (CREATE/ADD/EDIT/ENABLE/REMOVE,
# protection mode changes, FSFO enable) where the caller relies on the
# return code to detect failure. Prints the output exactly like
# run_dgmgrl so existing `echo "$output"` / log capture patterns keep
# working; only the return code differs.
# Usage: run_dgmgrl_checked <script_name> [arg1] [arg2] ...
run_dgmgrl_checked() {
    local script_name="$1"
    shift
    local script_path="${SQL_DIR}/dgmgrl/${script_name}"
    local content
    content=$(cat "$script_path")
    content=$(substitute_dgmgrl_args "$content" "$@")
    if is_mutating_dgmgrl_script "$script_name"; then
        confirm_approval_action "Run DGMGRL script" "printf '<script>' | \"$ORACLE_HOME/bin/dgmgrl\" -silent /  # ${script_name} $(shell_join "$@")" || return 1
    fi
    local output
    output=$(printf '%s\n' "$content" | "$ORACLE_HOME/bin/dgmgrl" -silent /)
    local rc=$?
    printf '%s\n' "$output"
    if [[ $rc -ne 0 ]]; then
        return $rc
    fi
    if dgmgrl_output_has_error "$output"; then
        return 1
    fi
    return 0
}

# Run a DGMGRL script with password authentication
# Usage: run_dgmgrl_with_password <password> <tns_alias> <script_name> [arg1] [arg2] ...
run_dgmgrl_with_password() {
    local password="$1"
    local tns_alias="$2"
    local script_name="$3"
    shift 3
    local script_path="${SQL_DIR}/dgmgrl/${script_name}"
    local content
    content=$(cat "$script_path")
    content=$(substitute_dgmgrl_args "$content" "$@")
    pause_verbose_trace
    # CONNECT is fed as the first line of stdin (dgmgrl -silent /nolog)
    # instead of on the command line, so the SYS password never appears in
    # `ps -ef` output for the life of the call.
    { printf 'CONNECT sys/"%s"@%s\n' "${password}" "${tns_alias}"; printf '%s\n' "$content"; } \
        | "$ORACLE_HOME/bin/dgmgrl" -silent /nolog
    local rc=$?
    resume_verbose_trace
    return $rc
}

# ============================================================
# Password Handling Functions
# ============================================================

prompt_password() {
    local prompt_text="$1"
    local password

    # Output prompt to stderr so it doesn't get captured by $()
    printf "${YELLOW}%s${NC}: " "$prompt_text" >&2
    # AIX compatible: use stty instead of read -s
    pause_verbose_trace
    stty -echo 2>/dev/null || true
    read -r password
    stty echo 2>/dev/null || true
    resume_verbose_trace
    echo "" >&2

    # Only the password goes to stdout (gets captured)
    echo "$password"
}

prompt_with_default() {
    local prompt_text="$1"
    local default_value="$2"
    local result_var="$3"
    local user_input

    if [[ -n "$default_value" ]]; then
        printf "%s [%s]: " "$prompt_text" "$default_value"
    else
        printf "%s: " "$prompt_text"
    fi

    read -r user_input

    if [[ -z "$user_input" ]]; then
        user_input="$default_value"
    fi

    printf -v "$result_var" '%s' "$user_input"
}

verify_sys_password() {
    local password="$1"
    local tns_alias="$2"

    local result
    pause_verbose_trace
    # CONNECT is fed on stdin (sqlplus -s /nolog) instead of on the sqlplus
    # command line, so the SYS password never appears in `ps -ef` output.
    # WHENEVER SQLERROR EXIT SQL.SQLCODE makes a failed CONNECT itself end
    # the session with a non-zero exit code before check_connection.sql ever
    # runs - this replaces the old "</dev/null so a bad password hits EOF at
    # the re-prompt" trick, which only applied to a bad *command-line* logon
    # and is unreachable now that the logon happens as an in-script CONNECT.
    # 2>&1 is kept deliberately: the connection test inspects the error text
    # in $result.
    result=$(sqlplus -s /nolog <<SQL 2>&1
WHENEVER SQLERROR EXIT SQL.SQLCODE
CONNECT sys/"${password}"@${tns_alias} AS SYSDBA
@${SQL_DIR}/queries/check_connection.sql
SQL
)
    local rc=$?
    resume_verbose_trace

    if [[ $rc -ne 0 ]]; then
        return 1
    fi

    if echo "$result" | grep -q "CONNECTED"; then
        return 0
    else
        return 1
    fi
}

# ============================================================
# Prompt for a SYS password and verify it against the LOCAL
# database via the listener (TCP). This exercises the password
# file the same way RMAN duplicate will later, so a bad password
# fails fast at step 1 rather than deep into step 5.
#
# On success: exports SYS_PASSWORD with the verified password.
# On failure (after _max_attempts attempts): exits non-zero.
# ============================================================
prompt_and_verify_local_sys_password() {
    local prompt_text="${1:-Enter SYS password for the local primary database}"
    local max_attempts="${2:-3}"

    # Discover the running listener port. Auto-derived from lsnrctl,
    # falling back to 1521 if that fails. This is local only.
    local probe_port=""
    if [[ -x "${ORACLE_HOME}/bin/lsnrctl" ]]; then
        probe_port=$("${ORACLE_HOME}/bin/lsnrctl" status 2>/dev/null \
            | sed -n 's/.*PORT[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
            | head -1)
    fi
    probe_port="${probe_port:-1521}"

    # Build a SID-based descriptor so we don't depend on knowing the
    # registered service name (PMON registers <SID> via the static
    # entry on most setups).
    local probe_target
    probe_target="(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=localhost)(PORT=${probe_port}))(CONNECT_DATA=(SID=${ORACLE_SID})))"

    log_info "Verifying SYS password against local instance (port ${probe_port}, SID ${ORACLE_SID})..."

    local attempt=1
    local pw=""
    while [[ $attempt -le $max_attempts ]]; do
        pw=$(prompt_password "$prompt_text")
        if [[ -z "$pw" ]]; then
            log_warn "SYS password cannot be empty (attempt ${attempt}/${max_attempts})"
        elif verify_sys_password "$pw" "$probe_target"; then
            log_success "SYS password verified against the local primary database"
            export SYS_PASSWORD="$pw"
            return 0
        else
            log_error "SYS password verification failed (attempt ${attempt}/${max_attempts})"
        fi
        attempt=$((attempt + 1))
    done

    log_error "Could not verify SYS password after ${max_attempts} attempts"
    log_error "Confirm REMOTE_LOGIN_PASSWORDFILE=EXCLUSIVE and that orapw${ORACLE_SID} contains a valid SYS entry"
    return 1
}

# ============================================================
# File Operations
# ============================================================

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.bak.$(date '+%Y%m%d_%H%M%S')"
        run_mutating_command "Create backup file" cp "$file" "$backup" || return 1
        log_info "Backed up $file to $backup"
        record_artifact "backup:${backup}"
    fi
}

backup_directory() {
    local dir="$1"
    local backup

    if [[ -d "$dir" ]]; then
        backup="${dir}.bak.$(date '+%Y%m%d_%H%M%S')"
        run_mutating_command "Create backup directory" mv "$dir" "$backup" || return 1
        log_info "Backed up $dir to $backup"
        record_artifact "backup:${backup}"
        printf '%s\n' "$backup"
    fi
}

append_to_file() {
    local file="$1"
    local content="$2"
    local marker="$3"

    # Check if content already exists (using marker)
    if [[ -n "$marker" ]] && grep -q "$marker" "$file" 2>/dev/null; then
        log_warn "Content with marker '$marker' already exists in $file"
        return 1
    fi

    confirm_approval_action "Append content to file" "append content to $file" || return 1
    echo "" >> "$file"
    echo "$content" >> "$file"
    log_info "Appended content to $file"
    return 0
}

# ============================================================
# TNS Functions
# ============================================================

tnsping_test() {
    local tns_alias="$1"

    if "$ORACLE_HOME/bin/tnsping" "$tns_alias" > /dev/null 2>&1; then
        log_info "tnsping $tns_alias successful"
        return 0
    else
        log_error "tnsping $tns_alias failed"
        return 1
    fi
}

listener_has_global_dbname() {
    local listener_file="$1"
    local global_dbname="$2"

    awk -v target="$global_dbname" '
    {
        line = $0
        gsub(/[[:space:]]+/, "", line)
        if (index(line, "GLOBAL_DBNAME=" target) > 0) {
            found = 1
        }
    }
    END {
        exit(found ? 0 : 1)
    }
    ' "$listener_file"
}

write_sid_desc_entries() {
    local output_file="$1"
    shift
    local sid_name="$1"
    shift
    local oracle_home="$1"
    shift
    local global_name

    : > "$output_file"
    for global_name in "$@"; do
        cat >> "$output_file" <<EOF
    (SID_DESC =
      (GLOBAL_DBNAME = ${global_name})
      (ORACLE_HOME = ${oracle_home})
      (SID_NAME = ${sid_name})
    )
EOF
    done
}

# ============================================================
# Listener Configuration Functions
# ============================================================

# Add a SID_DESC entry to an existing SID_LIST_LISTENER block
# Usage: add_sid_to_listener <listener.ora> <sid_desc_file>
# Returns: 0 on success, 1 on failure
# Output: Modified listener.ora (original backed up)
#
# Example sid_desc_file contents:
#     (SID_DESC =
#       (GLOBAL_DBNAME = MYDB)
#       (ORACLE_HOME = /u01/app/oracle/product/19.0.0/dbhome_1)
#       (SID_NAME = MYDB)
#     )
#
add_sid_to_listener() {
    local listener_file="$1"
    local sid_desc_file="$2"

    if [[ ! -f "$listener_file" ]]; then
        echo "ERROR: Listener file not found: $listener_file" >&2
        return 1
    fi

    if [[ ! -f "$sid_desc_file" ]]; then
        echo "ERROR: SID_DESC file not found: $sid_desc_file" >&2
        return 1
    fi

    if ! grep -q "SID_LIST_LISTENER" "$listener_file"; then
        echo "ERROR: SID_LIST_LISTENER not found in $listener_file" >&2
        return 1
    fi

    # Find the insertion point: the line where SID_LIST closes
    # Structure (typical):
    #   SID_LIST_LISTENER =
    #     (SID_LIST =           <- paren_count becomes 1 after (
    #       (SID_DESC = ...)    <- paren_count goes to 2, back to 1
    #     )                     <- INSERT BEFORE THIS (paren_count goes from 1 to 0)
    #
    # We want to insert BEFORE the line where paren_count drops to 0

    local insert_line
    insert_line=$(awk '
    BEGIN {
        in_sid_list_listener = 0
        paren_count = 0
        found_line = 0
    }
    /SID_LIST_LISTENER/ {
        in_sid_list_listener = 1
    }
    in_sid_list_listener && !found_line {
        # Count parens on this line
        line = $0
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (c == "(") {
                paren_count++
            }
            if (c == ")") {
                paren_count--
                # When paren_count drops to 0, this line closes SID_LIST
                # We want to insert BEFORE this line
                if (paren_count == 0) {
                    found_line = NR
                }
            }
        }
    }
    END {
        print found_line
    }
    ' "$listener_file")

    if [[ -z "$insert_line" || "$insert_line" -eq 0 ]]; then
        echo "ERROR: Could not find SID_LIST closing bracket" >&2
        return 1
    fi

    # Create the new file by inserting sid_desc before the insert_line.
    # Use a private temp directory (create_temp_dir: mktemp -d, or a mode-700
    # fallback dir on AIX images without mktemp) instead of a predictable
    # /tmp/..._$$ filename, and clean it up explicitly on every path out of
    # this function - including a declined approval - rather than a
    # script-wide EXIT trap, since this function is sourced into several
    # top-level scripts that may install their own traps.
    local temp_dir temp_file
    temp_dir=$(create_temp_dir) || { echo "ERROR: Could not create temp directory" >&2; return 1; }
    temp_file="${temp_dir}/dg_listener_edit.$$"

    head -n $((insert_line - 1)) "$listener_file" > "$temp_file"
    cat "$sid_desc_file" >> "$temp_file"
    tail -n "+${insert_line}" "$listener_file" >> "$temp_file"

    # Replace original
    if ! confirm_approval_action "Update listener file" "mv $temp_file $listener_file"; then
        rm -rf "$temp_dir"
        return 1
    fi
    mv "$temp_file" "$listener_file"
    rm -rf "$temp_dir"

    return 0
}

# ============================================================
# File Selection Functions
# ============================================================

# Select a config file from a list, sorted by modification time
# Usage: select_config_file <result_var> <file_type> <glob_pattern>
# Example: select_config_file STANDBY_CONFIG_FILE "standby configuration" "${NFS_SHARE}/standby_config_*.env"
# Returns: Sets the result variable to the selected file path
#          Returns 0 on success, 1 if no files found or user cancelled
select_config_file() {
    local result_var="$1"
    local file_type="$2"
    local glob_pattern="$3"

    # Build the candidate list via a glob loop rather than parsing `ls`
    # output (the old approach broke on filenames containing spaces).
    # The pattern is intentionally left unquoted so the shell performs
    # pathname expansion; each match becomes exactly one array element
    # here regardless of embedded spaces. Bash 3.2/AIX safe: no mapfile.
    local files_array=()
    local file
    for file in $glob_pattern; do
        [[ -e "$file" ]] || continue
        files_array+=("$file")
    done

    if [[ ${#files_array[@]} -eq 0 ]]; then
        log_error "No ${file_type} files found matching: $glob_pattern"
        return 1
    fi

    # Sort oldest-first using bash's built-in -ot ("older than") file
    # test instead of parsing `ls -t` output. Simple insertion sort -
    # fine for the small number of candidate files expected here.
    local sorted_files=()
    for file in "${files_array[@]}"; do
        local inserted=0
        local new_sorted=()
        local existing
        for existing in "${sorted_files[@]}"; do
            if [[ $inserted -eq 0 && "$file" -ot "$existing" ]]; then
                new_sorted+=("$file")
                inserted=1
            fi
            new_sorted+=("$existing")
        done
        if [[ $inserted -eq 0 ]]; then
            new_sorted+=("$file")
        fi
        sorted_files=("${new_sorted[@]}")
    done
    files_array=("${sorted_files[@]}")

    local file_count=${#files_array[@]}

    if [[ $file_count -eq 1 ]]; then
        printf -v "$result_var" '%s' "${files_array[0]}"
        log_info "Found ${file_type} file: ${files_array[0]}"
        return 0
    fi

    # Multiple files - show selection menu
    echo ""
    echo "Multiple ${file_type} files found (sorted by date, newest last):"
    echo ""

    local i=1
    for file in "${files_array[@]}"; do
        local basename_file=$(basename "$file")
        local mtime=$(ls -l "$file" 2>/dev/null | awk '{print $6, $7, $8}')
        if [[ $i -eq $file_count ]]; then
            printf "  ${GREEN}%d) %s  [%s] (newest - default)${NC}\n" "$i" "$basename_file" "$mtime"
        else
            printf "  %d) %s  [%s]\n" "$i" "$basename_file" "$mtime"
        fi
        i=$((i + 1))
    done

    echo ""
    printf "Select ${file_type} [1-%d, default=%d]: " "$file_count" "$file_count"
    read -r selection

    # Default to newest (last in list) if empty
    if [[ -z "$selection" ]]; then
        selection=$file_count
    fi

    # Validate selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt $file_count ]]; then
        log_error "Invalid selection: $selection"
        return 1
    fi

    local selected_file="${files_array[$((selection - 1))]}"
    printf -v "$result_var" '%s' "$selected_file"
    log_info "Selected: $selected_file"
    return 0
}


# ============================================================
# User Confirmation
# ============================================================

confirm_proceed() {
    local message="$1"
    local response

    echo ""
    printf "${YELLOW}%s${NC}\n" "$message"
    printf "Do you want to proceed? [y/N]: "
    read -r response

    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

confirm_typed_value() {
    local message="$1"
    local expected_value="$2"
    local response

    echo ""
    printf "${YELLOW}%s${NC}\n" "$message"
    printf "Type '%s' to continue: " "$expected_value"
    read -r response

    if [[ "$response" == "$expected_value" ]]; then
        return 0
    fi

    log_warn "Confirmation text did not match. Expected '${expected_value}'."
    return 1
}

# ============================================================
# Display Functions
# ============================================================

TOTAL_PROGRESS_STEPS=0
CURRENT_PROGRESS_STEP=0

init_progress() {
    TOTAL_PROGRESS_STEPS="${1:-0}"
    CURRENT_PROGRESS_STEP=0
}

progress_step() {
    local title="$1"
    CURRENT_PROGRESS_TITLE="$title"
    record_state_value "current_step" "$title"

    if [[ "$TOTAL_PROGRESS_STEPS" -gt 0 ]]; then
        CURRENT_PROGRESS_STEP=$((CURRENT_PROGRESS_STEP + 1))
        record_state_value "progress" "${CURRENT_PROGRESS_STEP}/${TOTAL_PROGRESS_STEPS}"
        log_section "[$CURRENT_PROGRESS_STEP/$TOTAL_PROGRESS_STEPS] $title"
    else
        log_section "$title"
    fi
}

print_status_row() {
    local label="$1"
    local value="$2"
    printf "  %-24s %s\n" "${label}:" "${value}"
}

print_status_block() {
    local title="$1"
    shift

    echo ""
    printf "${BLUE}%s${NC}\n" "$title"
    printf "${BLUE}%s${NC}\n" "------------------------------------------------------------"

    while [[ $# -gt 1 ]]; do
        print_status_row "$1" "$2"
        shift 2
    done
}

print_list_block() {
    local title="$1"
    shift
    local i=1

    echo ""
    printf "${BLUE}%s${NC}\n" "$title"
    printf "${BLUE}%s${NC}\n" "------------------------------------------------------------"

    for item in "$@"; do
        printf "  %d. %s\n" "$i" "$item"
        i=$((i + 1))
    done
}

display_config() {
    local config_file="$1"

    echo ""
    printf "${BLUE}============================================================${NC}\n"
    printf "${BLUE}Configuration Review${NC}\n"
    printf "${BLUE}============================================================${NC}\n"
    echo ""

    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue

        # Clean up key and value
        key=$(echo "$key" | tr -d ' ')
        value=$(echo "$value" | tr -d '"')

        if [[ -n "$key" && -n "$value" ]]; then
            printf "%-35s = %s\n" "$key" "$value"
        fi
    done < "$config_file"

    echo ""
    printf "${BLUE}============================================================${NC}\n"
}

print_banner() {
    local title="$1"
    local approval_line
    # WS4.6: reflect the actual approval-mode state (set via -a/--approval-mode,
    # or the legacy -s/--suspicious/$SUSPICIOUS) on every banner, so an
    # operator can tell at a glance whether mutating actions will prompt for
    # approval without having to check invocation flags.
    if [[ "${APPROVAL_MODE:-0}" == "1" ]]; then
        approval_line="Approval prompts: ON"
    else
        approval_line="Approval prompts: OFF (use -a to enable)"
    fi
    echo ""
    printf "${BLUE}============================================================${NC}\n"
    printf "${BLUE}     Oracle Data Guard Setup - %s${NC}\n" "$title"
    printf "${BLUE}     %s${NC}\n" "$approval_line"
    printf "${BLUE}============================================================${NC}\n"
    echo ""
}

print_summary() {
    local status="$1"
    local message="$2"

    record_state_value "status" "$status"
    record_state_value "summary" "$message"

    echo ""
    printf "${BLUE}============================================================${NC}\n"
    if [[ "$status" == "SUCCESS" ]]; then
        printf "${GREEN}     %s: %s${NC}\n" "$status" "$message"
    elif [[ "$status" == "WARNING" ]]; then
        printf "${YELLOW}     %s: %s${NC}\n" "$status" "$message"
    else
        printf "${RED}     %s: %s${NC}\n" "$status" "$message"
    fi
    printf "${BLUE}============================================================${NC}\n"
    echo ""
}
