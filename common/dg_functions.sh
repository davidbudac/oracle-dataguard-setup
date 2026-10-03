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
VERBOSE_TRACE_DEPTH=0
ERROR_TRAP_ACTIVE=0
CURRENT_PROGRESS_TITLE=""
STEP_STATE_FILE=""

# SQL scripts directory (relative to project root)
SQL_DIR="$(dirname "$DG_FUNCTIONS_DIR")/sql"

# ============================================================
# Logging Functions
# ============================================================

# Print the calling script's leading comment header (the '#' lines after the
# shebang, up to the first non-comment line) with the comment marker and the
# pure ==== / ---- separator lines stripped. Used by --help when the script
# defines no usage() function.
_dg_print_script_header() {
    local script_file="$1"
    [[ -r "$script_file" ]] || return 0
    awk '
        NR == 1 && /^#!/ { next }
        /^#/ {
            sub(/^# ?/, "")
            if ($0 ~ /^[=-][=-][=-]*$/) next
            print
            next
        }
        { exit }
    ' "$script_file"
}

# Shared argument parser for every numbered script. Handles the global flags
# (-v, -a/-s, -n, --execute, --no-color, ...), -h/--help, and rejects anything
# else, so a mistyped flag (--chek, --channel) or an unexpected positional
# argument fails with exit 2 instead of silently running the real step.
#
# A script declares its OWN options BEFORE calling enable_verbose_mode:
#   DG_SCRIPT_FLAGS='--regenerate -x --channels= -r='   # space-separated
# A flag with a trailing '=' takes a value (next argument, or --flag=value).
#   DG_SCRIPT_POSITIONAL=1   # script also takes positional (non-dash) args
#   DG_SCRIPT_FLAGS='*'      # script's own parser is complete and rejects
#                            # unknowns itself - skip these checks
# The script still parses its own flags afterwards; this only validates them.
enable_verbose_mode() {
    local args=("$@")
    local i=0
    local no_color_flag=false
    local arg w name matched script_file
    local declared="${DG_SCRIPT_FLAGS:-}"
    local check_unknown=true
    local end_of_opts=false

    [[ "$declared" == "*" ]] && check_unknown=false

    while [[ $i -lt ${#args[@]} ]]; do
        arg="${args[$i]}"
        if $end_of_opts; then
            if [[ "$check_unknown" == "true" && "${DG_SCRIPT_POSITIONAL:-0}" != "1" ]]; then
                log_error "Unexpected argument: ${arg} (see --help)"
                exit 2
            fi
            i=$((i + 1))
            continue
        fi
        case "$arg" in
            -h|--help)
                script_file="${BASH_SOURCE[1]:-$0}"
                if declare -F usage >/dev/null 2>&1; then
                    # usage() conventionally ends in exit 1; --help is success
                    ( usage ) || true
                else
                    _dg_print_script_header "$script_file"
                fi
                exit 0
                ;;
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
            --)
                end_of_opts=true
                ;;
            -?*)
                if [[ "$check_unknown" == "true" ]]; then
                    matched=""
                    for w in $declared; do
                        if [[ "$w" == *= ]]; then
                            name="${w%=}"
                            if [[ "$arg" == "$name" ]]; then
                                if [[ $((i + 1)) -ge ${#args[@]} ]]; then
                                    log_error "Option ${arg} requires a value (see --help)"
                                    exit 2
                                fi
                                i=$((i + 1))
                                matched=1
                                break
                            elif [[ "$arg" == "${name}="* ]]; then
                                matched=1
                                break
                            fi
                        elif [[ "$arg" == "$w" ]]; then
                            matched=1
                            break
                        fi
                    done
                    if [[ -z "$matched" ]]; then
                        log_error "Unknown option: ${arg} (see --help)"
                        exit 2
                    fi
                fi
                ;;
            *)
                if [[ "$check_unknown" == "true" && "${DG_SCRIPT_POSITIONAL:-0}" != "1" ]]; then
                    log_error "Unexpected argument: ${arg} (see --help)"
                    exit 2
                fi
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

# Pause/resume xtrace around password handling. Calls nest (a caller can pause
# around a block that itself calls prompt_password or verify_sys_password,
# which pause too): tracing comes back only when the outermost pause is
# resumed, so a password is never traced in between.
pause_verbose_trace() {
    if [[ "$VERBOSE_TRACE_DEPTH" -eq 0 && "$VERBOSE" == "1" && "$-" == *x* ]]; then
        VERBOSE_TRACE_PAUSED=1
        set +x
    fi
    VERBOSE_TRACE_DEPTH=$((VERBOSE_TRACE_DEPTH + 1))
}

resume_verbose_trace() {
    if [[ "$VERBOSE_TRACE_DEPTH" -gt 0 ]]; then
        VERBOSE_TRACE_DEPTH=$((VERBOSE_TRACE_DEPTH - 1))
    fi
    if [[ "$VERBOSE_TRACE_DEPTH" -eq 0 && "$VERBOSE_TRACE_PAUSED" == "1" ]]; then
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

    # || true: an unwritable share must fall through to the graceful
    # "file logging disabled" path below, not die here under set -e.
    mkdir -p "$log_dir" 2>/dev/null || true
    mkdir -p "$state_dir" 2>/dev/null || true
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
# manually created mode-700 directory when `mktemp` is not on PATH (e.g. a
# minimal AIX image) or is installed but fails - a fixed `/tmp/foo_$$`
# filename is predictable and can be pre-created/symlinked by another user,
# so any fallback still needs its own private, non-world-writable directory
# rather than a bare file directly under /tmp.
# Prints the directory path (and nothing else) to stdout; returns non-zero
# with nothing on stdout when no private directory could be established.
# Callers should immediately register `trap 'rm -rf "$dir"' EXIT` (merging
# with any existing EXIT trap) so the directory and everything placed inside
# it are cleaned up on every exit path, not just the happy path.
# Usage: MY_TMP_DIR=$(create_temp_dir) && trap 'rm -rf "$MY_TMP_DIR"' EXIT
#        MY_TMP_FILE="${MY_TMP_DIR}/dg_sid_desc_primary.$$"
create_temp_dir() {
    local dir
    if command -v mktemp >/dev/null 2>&1; then
        # Captured rather than passed through, so a failing mktemp that
        # still writes to stdout cannot leak text into the caller's path.
        dir=$(mktemp -d 2>/dev/null) && [[ -n "$dir" && -d "$dir" ]] && {
            printf '%s\n' "$dir"
            return 0
        }
    fi
    # Fallback. $$ is the SAME in every command substitution of one script,
    # so a name built from $$ alone collides as soon as two directories are
    # live at once (step 4 holds one while add_sid_to_listener allocates
    # another). Each candidate therefore also carries $RANDOM (bash reseeds
    # it per subshell) and the attempt number, and a candidate that already
    # exists is skipped, a bounded number of times.
    # No -p: an existing path (directory, file or symlink - pre-created by
    # someone else, or by an earlier allocation) must fail rather than be
    # reused, and a new one that is not ours/700 is refused even if mkdir
    # somehow succeeded.
    local base="${TMPDIR:-/tmp}" attempt=0
    base="${base%/}"
    while [[ $attempt -lt 20 ]]; do
        attempt=$((attempt + 1))
        dir=$(_dg_temp_dir_candidate "$base" "$attempt")
        if mkdir -m 700 "$dir" 2>/dev/null; then
            if [[ -O "$dir" && ! -L "$dir" ]]; then
                case "$(ls -ld "$dir" 2>/dev/null)" in
                    drwx------*)
                        printf '%s\n' "$dir"
                        return 0
                        ;;
                esac
            fi
            # Created by us but not private: remove the (empty) directory
            # and give up - retrying would not change the filesystem's
            # ownership or permission semantics.
            rmdir "$dir" 2>/dev/null
            return 1
        fi
        # Only a name collision is worth another candidate; anything else
        # (unwritable or missing base directory) fails the same way again.
        if [[ ! -e "$dir" && ! -L "$dir" ]]; then
            return 1
        fi
    done
    return 1
}

# Candidate path for create_temp_dir's fallback: <base>/dg_tmp_<pid>_<n>_<random>.
# Separate so the unit tests can substitute predictable names.
_dg_temp_dir_candidate() {
    printf '%s/dg_tmp_%s_%s_%s%s\n' "$1" "$$" "$2" "$RANDOM" "$RANDOM"
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

# Path of the sqlplus to run: $ORACLE_HOME/bin/sqlplus when executable (the
# same home rman and dgmgrl are taken from), else whatever is on PATH.
dg_sqlplus_bin() {
    if [[ -n "${ORACLE_HOME:-}" && -x "${ORACLE_HOME}/bin/sqlplus" ]]; then
        printf '%s\n' "${ORACLE_HOME}/bin/sqlplus"
    else
        printf '%s\n' "sqlplus"
    fi
}

check_db_connection() {
    log_info "Checking database connection..."

    local result
    result=$("$(dg_sqlplus_bin)" -s / as sysdba @"${SQL_DIR}/queries/check_connection.sql" </dev/null)

    if echo "$result" | grep -q "CONNECTED"; then
        log_info "Successfully connected to database"
        return 0
    else
        log_error "Failed to connect to database as SYSDBA"
        log_error "Output: $result"
        return 1
    fi
}

# Pure comparison behind assert_db_matches_config (no sqlplus, unit-tested).
# Usage: compare_db_identity <mode> <db_unique_name> <database_role> <dbid> \
#            <expected_primary> <expected_standby> <expected_dbid>
#   mode primary - the connected database must be <expected_primary> and
#                  hold the PRIMARY role (steps 4 and 6: the initial build)
#   mode member  - the connected database must hold the PRIMARY role and be
#                  <expected_primary> or <expected_standby> (steps 9, 10, 13,
#                  which also run after a switchover)
# The DBID must equal <expected_dbid>; an empty <expected_dbid> (a config
# written before step 2 recorded DBID) is a warning, not a failure. Names
# compare case-insensitively. Empty connected values - a failed or empty
# V$DATABASE query - are failures, never a pass.
# Prints one finding per line tagged "FAIL: ", "WARN: " or "NOTE: "; a
# "NOTE: ROLES_SWAPPED" line means the connected database is the config's
# standby (now primary). Returns 0 when no FAIL line was printed, else 1.
compare_db_identity() {
    local mode="$1" name="$2" role="$3" dbid="$4"
    local exp_pri="$5" exp_stb="$6" exp_dbid="$7"
    local lname lpri lstb failed=0

    lname=$(printf '%s' "$name" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    lpri=$(printf '%s' "$exp_pri" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    lstb=$(printf '%s' "$exp_stb" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    role=$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    dbid=$(printf '%s' "$dbid" | tr -d '[:space:]')
    exp_dbid=$(printf '%s' "$exp_dbid" | tr -d '[:space:]')

    case "$mode" in
        primary|member) ;;
        *)
            printf 'FAIL: unknown identity check mode "%s"\n' "$mode"
            return 1
            ;;
    esac
    if [[ -z "$lname" || -z "$role" ]]; then
        printf 'FAIL: could not read the connected database identity from V$DATABASE\n'
        return 1
    fi
    if [[ -z "$lpri" ]]; then
        printf 'FAIL: the configuration has no PRIMARY_DB_UNIQUE_NAME\n'
        return 1
    fi

    if [[ "$role" != "PRIMARY" ]]; then
        printf 'FAIL: the connected database role is %s, not PRIMARY\n' "$role"
        failed=1
    fi

    if [[ "$lname" == "$lpri" ]]; then
        :
    elif [[ "$mode" == "member" && -n "$lstb" && "$lname" == "$lstb" ]]; then
        printf 'NOTE: ROLES_SWAPPED\n'
    elif [[ "$mode" == "member" ]]; then
        printf 'FAIL: DB_UNIQUE_NAME %s is neither the configuration primary (%s) nor its standby (%s)\n' \
            "$name" "$exp_pri" "${exp_stb:-<unset>}"
        failed=1
    else
        printf 'FAIL: DB_UNIQUE_NAME %s is not the configuration primary %s\n' "$name" "$exp_pri"
        failed=1
    fi

    if [[ -z "$exp_dbid" ]]; then
        printf 'WARN: the configuration records no DBID - the database could only be matched by name\n'
    elif [[ "$dbid" != "$exp_dbid" ]]; then
        printf 'FAIL: DBID %s does not match the configuration DBID %s\n' "${dbid:-<empty>}" "$exp_dbid"
        failed=1
    fi

    return $failed
}

# Refuse to continue unless the database this session is connected to (the
# ambient ORACLE_SID, "/ as sysdba") is the one the sourced
# standby_config_*.env describes. Reads PRIMARY_DB_UNIQUE_NAME,
# STANDBY_DB_UNIQUE_NAME, DBID (and STANDBY_CONFIG_FILE for messages) from
# the caller's environment; see compare_db_identity for the two modes.
# Run it right after sourcing the config and before the first mutating SQL,
# broker command or file write (and before the CHECK_ONLY stop).
# Sets DG_CONFIG_ROLES_SWAPPED=1 when (member mode) the connected primary is
# the config's standby - a switchover happened since the build - else 0.
# Returns 0 on a match; logs the mismatch and returns 1 otherwise.
# Usage: assert_db_matches_config primary|member || exit 1
assert_db_matches_config() {
    local mode="$1"
    local out line name="" role="" dbid="" findings rc=0 finding

    DG_CONFIG_ROLES_SWAPPED=0
    log_info "Checking that the connected database matches the selected configuration..."

    out=$(run_sql_query "get_db_identity_pipe.sql") || rc=$?
    line=$(printf '%s\n' "$out" | tr -d '\r' | grep '|' | head -1)
    if [[ $rc -ne 0 || -z "$line" ]]; then
        log_error "Could not read DB_UNIQUE_NAME/DATABASE_ROLE/DBID of the connected database (ORACLE_SID=${ORACLE_SID:-<unset>})"
        log_error "Refusing to continue: the selected configuration cannot be matched to this database"
        return 1
    fi
    IFS='|' read -r name role dbid <<< "$line"
    name=$(printf '%s' "$name" | tr -d '[:space:]')
    dbid=$(printf '%s' "$dbid" | tr -d '[:space:]')
    role=$(printf '%s' "$role" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    rc=0
    findings=$(compare_db_identity "$mode" "$name" "$role" "$dbid" \
        "${PRIMARY_DB_UNIQUE_NAME:-}" "${STANDBY_DB_UNIQUE_NAME:-}" "${DBID:-}") || rc=$?

    if [[ $rc -ne 0 ]]; then
        log_error "The connected database does not match the selected configuration"
        log_error "  Connected : DB_UNIQUE_NAME=${name:-<empty>} ROLE=${role:-<empty>} DBID=${dbid:-<empty>} (ORACLE_SID=${ORACLE_SID:-<unset>})"
        if [[ "$mode" == "member" ]]; then
            log_error "  Expected  : the PRIMARY role on ${PRIMARY_DB_UNIQUE_NAME:-<unset>} or ${STANDBY_DB_UNIQUE_NAME:-<unset>}, DBID=${DBID:-<not recorded>}"
        else
            log_error "  Expected  : ${PRIMARY_DB_UNIQUE_NAME:-<unset>} in the PRIMARY role, DBID=${DBID:-<not recorded>}"
        fi
        log_error "  Config    : ${STANDBY_CONFIG_FILE:-<unknown>}"
    fi
    while IFS= read -r finding; do
        case "$finding" in
            "FAIL: "*) log_error "  ${finding#FAIL: }" ;;
            "WARN: "*) log_warn "${finding#WARN: } (DBID not cross-checked)" ;;
            "NOTE: ROLES_SWAPPED")
                DG_CONFIG_ROLES_SWAPPED=1
                log_info "Connected to ${name}, the configuration's standby, which now holds the PRIMARY role (roles are swapped relative to the configuration - a switchover/failover happened since the build)"
                ;;
        esac
    done <<< "$findings"

    if [[ $rc -ne 0 ]]; then
        log_error "Check that ORACLE_SID (and ORACLE_HOME) point at the database this configuration describes, or select the matching standby_config_*.env"
        return 1
    fi
    log_info "Connected database ${name} (${role}, DBID ${dbid}) matches the selected configuration"
    return 0
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
    "$(dg_sqlplus_bin)" -s / as sysdba @"$script" "$@" </dev/null
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
    output=$("$(dg_sqlplus_bin)" -s / as sysdba @"${SQL_DIR}/queries/${script_name}" "$@" </dev/null) && rc=0 || rc=$?
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
    "$(dg_sqlplus_bin)" -s / as sysdba @"${SQL_DIR}/commands/${script_name}" "$@" </dev/null
}

# Run a SQL query script with headers (for display)
# Usage: run_sql_display <script_name> [arg1] [arg2] ...
run_sql_display() {
    local script_name="$1"
    shift
    "$(dg_sqlplus_bin)" -s / as sysdba @"${SQL_DIR}/queries/${script_name}" "$@" </dev/null
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
    # Trim only leading/trailing whitespace: interior spaces are significant
    # (log_archive_dest_1 = "LOCATION=/arch VALID_FOR=(...)" - stripping them
    # glued the attributes onto the path). Blank lines are dropped and the
    # remaining lines joined, as before.
    printf '%s\n' "$value" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\n'
    printf '\n'
}

# Get a database property value
# Usage: get_db_property <property_name>
get_db_property() {
    local prop_name="$1"
    local value
    value=$(run_sql_query "get_db_property.sql" "$prop_name")
    echo "$value" | tr -d ' \t\n\r'
}

# ============================================================
# OMF File-Placement Helpers (inherited-parameter handling)
# ============================================================
# RMAN DUPLICATE ... SPFILE copies the PRIMARY's spfile to the standby and
# overrides only the parameters named in its SET clauses, so file-placement
# parameters the OMF branch does not SET are inherited silently:
#   - DB_CREATE_ONLINE_LOG_DEST_1..5 outrank DB_CREATE_FILE_DEST for online
#     and standby redo logs and OMF control files -> the standby would
#     re-create them in the PRIMARY's directories (ORA-19504/ORA-27040 when
#     those do not exist on the standby host).
#   - LOG_FILE_NAME_CONVERT / DB_FILE_NAME_CONVERT outrank the OMF
#     parameters in RMAN's file-naming precedence.
# The functions below are pure (no DB access) so steps 1, 2, 3 and 5 share
# one implementation and tests/test_omf_online_log_dest.sh can cover it.

# True when $1 is safe to embed in a sourced .env, a pfile and an RMAN
# SET clause: an absolute path or an ASM disk-group form (+DG, +DG/dir),
# characters limited to letters, digits and _ . / + -
# (the regex lives in variables - the portable bash 3.2 / AIX form)
# Usage: is_safe_omf_dest_path <value>
is_safe_omf_dest_path() {
    local _v="$1"
    local _re_abs='^/[A-Za-z0-9_./+-]*$'
    local _re_asm='^\+[A-Za-z0-9_][A-Za-z0-9_./+-]*$'
    [[ -n "$_v" ]] || return 1
    [[ "$_v" =~ $_re_abs ]] && return 0
    [[ "$_v" =~ $_re_asm ]] && return 0
    return 1
}

# Default standby value for DB_CREATE_ONLINE_LOG_DEST_<n>. Mirrors Oracle's
# own OMF redo multiplexing: member 1 in the file destination, member 2 in
# the recovery destination, any further member back in the file destination.
# An empty recovery destination degrades to the file destination.
# Prints nothing and returns 1 for n outside 1..5.
# Usage: omf_default_online_log_dest <n> <db_create_file_dest> <db_recovery_file_dest>
omf_default_online_log_dest() {
    local _n="$1" _file_dest="$2" _rec_dest="$3"
    case "$_n" in
        1|3|4|5) printf '%s\n' "$_file_dest" ;;
        2)       printf '%s\n' "${_rec_dest:-$_file_dest}" ;;
        *)       return 1 ;;
    esac
}

# RMAN "SET DB_CREATE_ONLINE_LOG_DEST_<n>='<value>'" lines (4-space indent,
# matching the DUPLICATE ... SPFILE body). Arguments are the values for
# n = 1..5 in order; an empty or missing argument is skipped, so nothing is
# printed when none is set. A value that fails is_safe_omf_dest_path prints
# nothing at all and returns 1 (never emit it into an RMAN script).
# Usage: build_rman_online_log_dest_set_lines <d1> <d2> <d3> <d4> <d5>
build_rman_online_log_dest_set_lines() {
    local _n=1 _v _out=""
    while [[ $_n -le 5 ]]; do
        _v="${1:-}"
        [[ $# -gt 0 ]] && shift
        if [[ -n "$_v" ]]; then
            is_safe_omf_dest_path "$_v" || return 1
            _out="${_out}    SET DB_CREATE_ONLINE_LOG_DEST_${_n}='${_v}'
"
        fi
        _n=$((_n + 1))
    done
    printf '%s' "$_out"
}

# Same values as pfile lines: *.db_create_online_log_dest_<n>='<value>'
# Usage: build_pfile_online_log_dest_lines <d1> <d2> <d3> <d4> <d5>
build_pfile_online_log_dest_lines() {
    local _n=1 _v _out=""
    while [[ $_n -le 5 ]]; do
        _v="${1:-}"
        [[ $# -gt 0 ]] && shift
        if [[ -n "$_v" ]]; then
            is_safe_omf_dest_path "$_v" || return 1
            _out="${_out}*.db_create_online_log_dest_${_n}='${_v}'
"
        fi
        _n=$((_n + 1))
    done
    printf '%s' "$_out"
}

# Parse the output of sql/queries/get_omf_placement_params.sql
# ("name|value" rows) into globals (the whole bash 3.2 / AIX toolbox has no
# namerefs, so results are fixed names):
#   OMF_PARAM_ONLINE_LOG_DEST_1..5     raw trimmed value, empty when unset
#   OMF_PARAM_LOG_FILE_NAME_CONVERT_SET  YES|NO
#   OMF_PARAM_DB_FILE_NAME_CONVERT_SET   YES|NO
#   OMF_PARAM_UNSAFE                   YES when any online log dest value
#                                      fails is_safe_omf_dest_path
# Values are kept raw (only surrounding whitespace is trimmed) so a value
# with an embedded space or quote is detected rather than silently mangled;
# callers must not store an unsafe value anywhere that gets sourced.
# Usage: parse_omf_placement_params "<raw query output>"
parse_omf_placement_params() {
    local _raw="$1" _pname _pval _n
    OMF_PARAM_ONLINE_LOG_DEST_1=""
    OMF_PARAM_ONLINE_LOG_DEST_2=""
    OMF_PARAM_ONLINE_LOG_DEST_3=""
    OMF_PARAM_ONLINE_LOG_DEST_4=""
    OMF_PARAM_ONLINE_LOG_DEST_5=""
    OMF_PARAM_LOG_FILE_NAME_CONVERT_SET="NO"
    OMF_PARAM_DB_FILE_NAME_CONVERT_SET="NO"
    OMF_PARAM_UNSAFE="NO"

    while IFS='|' read -r _pname _pval; do
        _pname=$(printf '%s' "$_pname" | tr -d '[:space:]')
        _pval=$(printf '%s' "$_pval" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$_pname" || -z "$_pval" ]] && continue
        case "$_pname" in
            db_create_online_log_dest_[1-5])
                _n="${_pname#db_create_online_log_dest_}"
                eval "OMF_PARAM_ONLINE_LOG_DEST_${_n}=\$_pval"
                is_safe_omf_dest_path "$_pval" || OMF_PARAM_UNSAFE="YES"
                ;;
            log_file_name_convert) OMF_PARAM_LOG_FILE_NAME_CONVERT_SET="YES" ;;
            db_file_name_convert)  OMF_PARAM_DB_FILE_NAME_CONVERT_SET="YES" ;;
        esac
    done <<EOF
$_raw
EOF
    return 0
}

# Operator-facing explanation shared by step 2 (OMF refused at generation
# time) and step 5 (refused before anything destructive happens).
# Usage: log_omf_inherited_convert_error <log_file_name_convert_set> <db_file_name_convert_set>
log_omf_inherited_convert_error() {
    local _lfnc="${1:-NO}" _dfnc="${2:-NO}"
    local _set=""
    [[ "$_lfnc" == "YES" ]] && _set="log_file_name_convert"
    if [[ "$_dfnc" == "YES" ]]; then
        _set="${_set}${_set:+ and }db_file_name_convert"
    fi
    log_error "The primary has ${_set} set. RMAN DUPLICATE copies the primary's spfile to the standby,"
    log_error "so the standby would inherit it - and these parameters take precedence over the OMF"
    log_error "parameters (db_create_file_dest / db_create_online_log_dest_n) when RMAN names files,"
    log_error "placing them in paths derived from the stale convert pairs."
    log_error "Ways forward:"
    log_error "  1) Use Traditional storage mode (step 2, Q1) - it manages the convert pairs itself."
    log_error "  2) If they are leftovers (e.g. the primary used to be a standby), reset them on the primary:"
    log_error "       ALTER SYSTEM RESET log_file_name_convert SCOPE=SPFILE;"
    log_error "       ALTER SYSTEM RESET db_file_name_convert SCOPE=SPFILE;"
    log_error "     They are static parameters: the reset only shows up in V\$PARAMETER (what the"
    log_error "     checks read) after the next primary restart. Then re-run step 1 and this step."
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

# Value of the broker's status field in captured SHOW CONFIGURATION /
# SHOW DATABASE output: the "Configuration Status:" value, or failing that
# the "Database Status:" value, uppercased - SUCCESS, WARNING, ERROR or
# DISABLED. 19c DGMGRL normally puts it on the NEXT line
#     Configuration Status:
#     SUCCESS   (status updated 42 seconds ago)
# older/other output keeps it on the same line; both are handled.
# Prints nothing and returns 1 when no such field is found (empty output,
# dgmgrl failure, unrecognized value) - callers must treat that as failure,
# and under set -e use: v=$(dgmgrl_status_value "$out") || v=""
# Usage: dgmgrl_status_value <output>
dgmgrl_status_value() {
    local output="$1"
    local value
    value=$(printf '%s\n' "$output" | tr -d '\r' | awk '
    {
        line = $0
        if (want_kind != "") {
            if (line ~ /^[ \t]*$/) next
            kind = want_kind
            want_kind = ""
            rest = line
        } else if (tolower(line) ~ /^[ \t]*(configuration|database)[ \t]+status:/) {
            kind = (tolower(line) ~ /^[ \t]*configuration/) ? "c" : "d"
            rest = line
            sub(/^[^:]*:/, "", rest)
            if (rest ~ /^[ \t]*$/) {
                want_kind = kind
                next
            }
        } else {
            next
        }
        sub(/^[ \t]+/, "", rest)
        n = split(rest, tok, /[ \t]+/)
        v = toupper(tok[1])
        if (v == "SUCCESS" || v == "WARNING" || v == "ERROR" || v == "DISABLED") {
            if (kind == "c" && cval == "") cval = v
            if (kind == "d" && dval == "") dval = v
        }
    }
    END {
        if (cval != "") print cval
        else if (dval != "") print dval
    }
    ')
    if [[ -z "$value" ]]; then
        return 1
    fi
    printf '%s\n' "$value"
}

# True when captured broker output carries a real error: an "Error: <n>"
# line with a nonzero code, or an ORA-/DGM- code that is NOT preceded on the
# same line by "Warning:". Member-level warnings such as
#     Warning: ORA-16789: standby redo logs configured incorrectly
# are therefore not errors here (unlike dgmgrl_output_has_error, which
# counts every ORA-/DGM- code and stays as is for its current callers).
# Usage: dgmgrl_has_error_lines <output>
dgmgrl_has_error_lines() {
    local output="$1"
    printf '%s\n' "$output" | awk '
    tolower($0) ~ /^[ \t]*error:[ \t]*[1-9]/ { found = 1 }
    {
        if (match($0, /(ORA|DGM)-[0-9]/)) {
            w = index(tolower($0), "warning:")
            if (!(w > 0 && w < RSTART)) found = 1
        }
    }
    END { exit(found ? 0 : 1) }
    '
}

# Member names, one per line as the broker prints them, from captured 19c
# SHOW CONFIGURATION output: the "<name> - <description>" lines after a
# "Members:" (or "Members Not Receiving Redo:") header, up to
# "Fast-Start Failover:" / "Configuration Status:".
#     Members:
#     cdb1      - Primary database
#       cdb1_stby - (*) Physical standby database
#         Warning: ORA-16809: multiple warnings detected for the member
# Indented Warning:/Error:/ORA- lines under a member are not members.
# Prints nothing when no member line is found.
# Usage: dgmgrl_config_members <output>
dgmgrl_config_members() {
    printf '%s\n' "$1" | tr -d '\r' | awk '
    tolower($0) ~ /^[ \t]*members[^:]*:[ \t]*$/ { inm = 1; next }
    tolower($0) ~ /^[ \t]*(fast-start failover|configuration status)/ { inm = 0; next }
    inm && NF >= 3 && $2 == "-" { print $1 }
    '
}

# Members of captured SHOW CONFIGURATION output that are none of the given
# DB_UNIQUE_NAMEs (case-insensitive), one per line; nothing when all belong.
# Usage: dgmgrl_foreign_members <output> <db_unique_name>...
dgmgrl_foreign_members() {
    local output="$1"
    shift
    local known
    # Space-joined (DB_UNIQUE_NAMEs contain no blanks): a newline inside an
    # awk -v value is rejected by some awks ("newline in string").
    known=$(printf '%s ' "$@" | tr '[:upper:]' '[:lower:]')
    dgmgrl_config_members "$output" | awk -v known="$known" '
    BEGIN { n = split(known, k, " "); for (i = 1; i <= n; i++) if (k[i] != "") ok[k[i]] = 1 }
    !(tolower($0) in ok) { print }
    '
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
    local old_traps

    # Output prompt to stderr so it doesn't get captured by $()
    printf "${YELLOW}%s${NC}: " "$prompt_text" >&2
    # Tracing stays paused until the password has been printed: xtrace would
    # otherwise show the read value and the printf below (-v / C2).
    pause_verbose_trace
    # Ctrl-C between stty -echo and stty echo would leave the terminal with
    # echo off. Restore it on interrupt, then put any previous traps back.
    old_traps=$(trap -p INT TERM HUP 2>/dev/null) || old_traps=""
    trap 'stty echo 2>/dev/null || true; printf "\n" >&2; exit 130' INT TERM HUP
    # AIX compatible: use stty instead of read -s
    stty -echo 2>/dev/null || true
    read -r password
    stty echo 2>/dev/null || true
    trap - INT TERM HUP
    if [[ -n "$old_traps" ]]; then
        eval "$old_traps"
    fi
    echo "" >&2

    # Only the password goes to stdout (gets captured). printf, not echo:
    # a password such as -n or -e would be eaten as an echo option.
    printf '%s\n' "$password"
    resume_verbose_trace
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
    # SET DEFINE OFF comes first: as *script* input (unlike the old
    # command-line logon) the CONNECT line is scanned for substitution
    # variables, so an "&" anywhere in the password would be silently
    # replaced and a correct password rejected with ORA-01017.
    # 2>&1 is kept deliberately: the connection test inspects the error text
    # in $result, and callers read it back from VERIFY_SYS_ERROR_TEXT (which
    # holds sqlplus output only - never the password).
    result=$("$(dg_sqlplus_bin)" -s /nolog <<SQL 2>&1
SET DEFINE OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE
CONNECT sys/"${password}"@${tns_alias} AS SYSDBA
@${SQL_DIR}/queries/check_connection.sql
SQL
)
    local rc=$?
    resume_verbose_trace

    VERIFY_SYS_ERROR_TEXT="$result"

    if [[ $rc -ne 0 ]]; then
        return 1
    fi

    if echo "$result" | grep -q "CONNECTED"; then
        return 0
    else
        return 1
    fi
}

# ------------------------------------------------------------
# Endpoints the local listener actually listens on, one
# "HOST PORT" line per TCP endpoint in lsnrctl order.
#
# The listener binds exactly the address listener.ora names, so
# on the usual (HOST=<server>) configuration nothing answers on
# 127.0.0.1 - "localhost" is not a valid stand-in for "local".
# ------------------------------------------------------------
_discover_listener_tcp_endpoints() {
    [[ -x "${ORACLE_HOME}/bin/lsnrctl" ]] || return 0
    # (protocol=tcp) with the closing paren so TCPS endpoints (which would
    # need a wallet) are not offered as probe candidates.
    "${ORACLE_HOME}/bin/lsnrctl" status 2>/dev/null \
        | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz' \
        | sed -n 's/.*(protocol=tcp)(host=\([^)]*\))(port=\([0-9][0-9]*\)).*/\1 \2/p'
}

# True when the sqlplus output is a transport/listener failure - the
# database never saw the credentials, so it says nothing about the
# password and the next candidate endpoint should be tried.
_sys_probe_transport_error() {
    printf '%s\n' "$1" | grep -E 'TNS-|ORA-12154|ORA-12162|ORA-12170|ORA-12224|ORA-12500|ORA-12505|ORA-12514|ORA-12518|ORA-12520|ORA-12521|ORA-12528|ORA-12537|ORA-12541|ORA-12545|ORA-12547|ORA-12560|ORA-12564|ORA-12570|ORA-03113|ORA-03135' >/dev/null 2>&1
}

# First diagnostic line of a sqlplus run, for operator-facing messages.
_first_ora_line() {
    local line
    line=$(printf '%s\n' "$1" | grep -E 'ORA-|TNS-|SP2-' | head -1 | sed 's/^[[:space:]]*//')
    printf '%s\n' "${line:-no diagnostic returned by sqlplus}"
}

# ============================================================
# Prompt for a SYS password and verify it against the LOCAL
# database via the listener (TCP). This exercises the password
# file the same way RMAN duplicate will later, so a bad password
# fails fast at step 1 rather than deep into step 5.
#
# On success: sets SYS_PASSWORD (a plain shell variable, deliberately not
# exported - children would see it in their environment) to the verified
# password.
# On failure (after _max_attempts attempts): exits non-zero.
# ============================================================
prompt_and_verify_local_sys_password() {
    local prompt_text="${1:-Enter SYS password for the local primary database}"
    local max_attempts="${2:-3}"

    # Probe candidates, best first: the addresses the listener reports for
    # itself, then this host's own name, then localhost as a last resort.
    # Hardcoding localhost (as this did before) rejects every password on
    # the standard listener.ora that binds the host address only.
    # DG_SYS_PROBE_HOST / DG_SYS_PROBE_PORT override discovery entirely.
    local endpoints first_port candidates this_host
    endpoints=$(_discover_listener_tcp_endpoints)
    first_port=$(printf '%s\n' "$endpoints" | sed -n '1s/.*[[:space:]]//p')
    first_port="${first_port:-1521}"

    if [[ -n "${DG_SYS_PROBE_HOST:-}" ]]; then
        candidates="${DG_SYS_PROBE_HOST} ${DG_SYS_PROBE_PORT:-$first_port}"
    else
        candidates="$endpoints"
        this_host=$(hostname 2>/dev/null)
        [[ -n "$this_host" ]] && candidates="${candidates}
${this_host} ${first_port}"
        candidates="${candidates}
localhost ${first_port}"
    fi
    # Drop blank lines (no endpoints discovered) and duplicates, keeping order.
    candidates=$(printf '%s\n' "$candidates" | sed '/^[[:space:]]*$/d' | awk '!seen[$0]++')

    log_info "Verifying SYS password against the local instance (SID ${ORACLE_SID}) via:"
    log_info "  $(printf '%s\n' "$candidates" | sed 's/ /:/' | tr '\n' ',' | sed 's/,$//; s/,/, /g')"

    # The live endpoint is settled on the first attempt: whichever candidate
    # returns an *authentication* verdict (right or wrong password) is the
    # one the instance answers on. Candidates that fail in transport are
    # skipped, and if every one of them does we report that rather than
    # blaming the password.
    local pinned=""
    local attempt=1
    local pw="" cand_host cand_port target answered transport_error

    while [[ $attempt -le $max_attempts ]]; do
        # Tracing stays paused while the password is held in $pw (read,
        # tests, verify call, assignment) so -v never prints it (C2).
        pause_verbose_trace
        pw=$(prompt_password "$prompt_text")
        if [[ -z "$pw" ]]; then
            resume_verbose_trace
            log_warn "SYS password cannot be empty (attempt ${attempt}/${max_attempts})"
            attempt=$((attempt + 1))
            continue
        fi
        if [[ "$pw" == *'"'* ]]; then
            resume_verbose_trace
            # verify_sys_password() (and RMAN's CONNECT string) embed the
            # password inside double quotes (sys/"<pw>"@...) - an embedded
            # quote breaks that syntax and would otherwise be misreported as
            # a plain "Invalid SYS password" a few lines below (L16).
            log_warn "SYS password must not contain a double-quote (\") character - it breaks the sys/\"<pw>\"@ connect syntax (attempt ${attempt}/${max_attempts})"
            attempt=$((attempt + 1))
            continue
        fi

        answered=0
        transport_error=""
        while IFS=' ' read -r cand_host cand_port; do
            [[ -z "$cand_host" ]] && continue
            target="(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${cand_host})(PORT=${cand_port}))(CONNECT_DATA=(SID=${ORACLE_SID})))"

            if verify_sys_password "$pw" "$target"; then
                log_success "SYS password verified against the local primary database (${cand_host}:${cand_port}, SID ${ORACLE_SID})"
                SYS_PASSWORD="$pw"
                resume_verbose_trace
                return 0
            fi

            if _sys_probe_transport_error "$VERIFY_SYS_ERROR_TEXT"; then
                transport_error="$VERIFY_SYS_ERROR_TEXT"
                log_info "  ${cand_host}:${cand_port} unreachable - $(_first_ora_line "$VERIFY_SYS_ERROR_TEXT")"
                continue
            fi

            # The instance answered: a real authentication verdict, so stop
            # walking candidates and keep using this one from now on.
            answered=1
            pinned="${cand_host} ${cand_port}"
            log_error "SYS logon rejected by ${cand_host}:${cand_port} (attempt ${attempt}/${max_attempts})"
            log_error "  $(_first_ora_line "$VERIFY_SYS_ERROR_TEXT")"
            break
        done <<CANDIDATES
${pinned:-$candidates}
CANDIDATES
        resume_verbose_trace

        if [[ $answered -eq 0 ]]; then
            # Not a password problem - no candidate endpoint even reached the
            # instance. Re-prompting would just misattribute this to the user.
            log_error "Could not reach the local instance on any listener endpoint - the password was never tested"
            log_error "  Last error: $(_first_ora_line "$transport_error")"
            log_error "  Tried: $(printf '%s\n' "$candidates" | sed 's/ /:/' | tr '\n' ',' | sed 's/,$//; s/,/, /g') (SID ${ORACLE_SID})"
            log_error "  Check 'lsnrctl status' (endpoints and a registered instance for SID ${ORACLE_SID}),"
            log_error "  or set DG_SYS_PROBE_HOST/DG_SYS_PROBE_PORT to the address the listener answers on."
            return 1
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

# Directory Oracle Net reads sqlnet.ora / tnsnames.ora / listener.ora from:
# $TNS_ADMIN when set, else $ORACLE_HOME/network/admin. Shared or relocated
# TNS_ADMIN directories are common (especially on AIX); editing the
# ORACLE_HOME copy then changes files Oracle never reads.
dg_net_admin_dir() {
    printf '%s\n' "${TNS_ADMIN:-$ORACLE_HOME/network/admin}"
}

# True when listener.ora has an uncommented (GLOBAL_DBNAME = <name>) whose
# value equals <name> exactly (case-insensitive, whitespace-insensitive).
# Whole-value match: cdb1_stby must not be satisfied by cdb1_stby_DGMGRL.
listener_has_global_dbname() {
    local listener_file="$1"
    local global_dbname="$2"

    awk -v target="$global_dbname" '
    BEGIN {
        t = tolower(target)
        gsub(/[[:space:]]+/, "", t)
    }
    {
        line = $0
        sub(/#.*/, "", line)
        gsub(/[[:space:]]+/, "", line)
        line = tolower(line)
        while ((p = index(line, "global_dbname=")) > 0) {
            rest = substr(line, p + 14)
            q = index(rest, ")")
            val = (q > 0) ? substr(rest, 1, q - 1) : rest
            gsub(/["\047]/, "", val)
            if (val == t) {
                found = 1
            }
            line = rest
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
# Returns: 0 on success, 1 on failure (including a one-line
#          SID_LIST_LISTENER=(...) definition, which is refused rather than
#          spliced into the wrong place - add the entry by hand)
# Output: Modified listener.ora, rewritten in place (mode, owner and a
#         symlink target are kept). This function takes NO backup: callers
#         run backup_file "$listener_file" first (steps 3 and 4 do).
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

    # Anchored on the definition itself (SID_LIST_LISTENER = ...), so a
    # comment or another key that merely mentions the name does not count.
    if ! grep -iq '^[[:space:]]*SID_LIST_LISTENER[[:space:]]*=' "$listener_file"; then
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
        start_line = 0
    }
    !in_sid_list_listener && toupper($0) ~ /^[ \t]*SID_LIST_LISTENER[ \t]*=/ {
        in_sid_list_listener = 1
        start_line = NR
    }
    in_sid_list_listener && !found_line {
        # Count parens on this line (ignoring comments)
        line = $0
        sub(/#.*/, "", line)
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (c == "(") {
                paren_count++
            }
            if (c == ")") {
                paren_count--
                # When paren_count drops to 0, this line closes SID_LIST
                # We want to insert BEFORE this line
                if (paren_count == 0 && !found_line) {
                    found_line = NR
                }
            }
        }
    }
    END {
        # Whole definition on the starting line: nothing to insert before
        if (found_line && found_line == start_line) {
            print -1
        } else {
            print found_line
        }
    }
    ' "$listener_file")

    if [[ "$insert_line" == "-1" ]]; then
        echo "ERROR: SID_LIST_LISTENER is defined on a single line in $listener_file - cannot insert automatically" >&2
        return 1
    fi

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

    # Replace original. Copy the content over the existing file instead of
    # mv-ing the temp file onto it: mv would replace a symlink with a plain
    # file and drop the original's mode and owner.
    if ! confirm_approval_action "Update listener file" "cat $temp_file > $listener_file"; then
        rm -rf "$temp_dir"
        return 1
    fi
    if ! cat "$temp_file" > "$listener_file"; then
        echo "ERROR: Could not write $listener_file" >&2
        rm -rf "$temp_dir"
        return 1
    fi
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

# Guard a confirm_proceed()-style validation gate so it never blocks a
# --check/-n run before it reaches the preflight summary, and never blocks
# silently on a non-interactive stdin (M8).
#
#   - CHECK_ONLY=1: the finding is logged and this returns 0 ("continue") -
#     safe because CHECK_ONLY callers only run read-only work between here
#     and their own finish_check_mode exit; no mutation happens either way.
#   - CHECK_ONLY=0 and stdin is not a TTY: default to "no" (abort) with an
#     explicit message rather than silently consuming/misreading whatever
#     is next on stdin. Points the operator at -n/--check.
#   - CHECK_ONLY=0 and stdin is a TTY: behaves exactly like confirm_proceed
#     (interactive prompt).
#
# Usage: confirm_proceed_or_check "<message>" && ... (same calling
# convention as confirm_proceed - non-zero return means "do not proceed").
# True when $1 is a dotted-quad IPv4 address
_is_ipv4_addr() {
    local re='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
    [[ "$1" =~ $re ]]
}

# This host's IPv4 addresses, one per line. DG_LOCAL_IPV4_ADDRS (space
# separated) overrides discovery, mainly for tests. Otherwise `ifconfig -a`
# (present on AIX, Linux net-tools and the BSDs; "inet 10.0.0.1 netmask ..."
# or the older "inet addr:10.0.0.1"), then `ip -4 addr` where available.
# `hostname -I` / `ip` are Linux-only and never required.
_local_ipv4_addrs() {
    if [[ -n "${DG_LOCAL_IPV4_ADDRS+x}" ]]; then
        printf '%s\n' $DG_LOCAL_IPV4_ADDRS
        return 0
    fi
    local out=""
    if command -v ifconfig >/dev/null 2>&1; then
        out=$(ifconfig -a 2>/dev/null | sed -n 's/^[[:space:]]*inet addr:\([0-9.]*\).*/\1/p;s/^[[:space:]]*inet \([0-9][0-9.]*\).*/\1/p') || out=""
    fi
    if [[ -z "$out" ]] && command -v ip >/dev/null 2>&1; then
        out=$(ip -4 addr 2>/dev/null | sed -n 's/^[[:space:]]*inet \([0-9.]*\).*/\1/p') || out=""
    fi
    [[ -n "$out" ]] && printf '%s\n' "$out"
    return 0
}

# Compare two hostnames tolerantly: case-insensitive, and a short name
# matches its own FQDN (config files usually carry the short name while
# `hostname` returns the FQDN, or vice versa). Only the first label is
# compared when either side is unqualified; two different domains with the
# same short name still match - acceptable for a "am I on the right host?"
# sanity check, not for security decisions.
# Dotted-quad IPv4 input is never truncated to its first octet: two IPs match
# only when identical; an IP against a name matches only when the IP is one of
# this host's own addresses (callers pass `hostname` as $1, so the question
# is always "is this config entry me?").
hostnames_match() {
    local a b
    a=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    b=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
    [[ -n "$a" && -n "$b" ]] || return 1

    if _is_ipv4_addr "$a" && _is_ipv4_addr "$b"; then
        [[ "$a" == "$b" ]]
        return
    fi
    if _is_ipv4_addr "$a" || _is_ipv4_addr "$b"; then
        local ip="$a" addrs addr
        _is_ipv4_addr "$ip" || ip="$b"
        addrs=$(_local_ipv4_addrs)
        for addr in $addrs; do
            [[ "$addr" == "$ip" ]] && return 0
        done
        return 1
    fi
    [[ "${a%%.*}" == "${b%%.*}" ]]
}

confirm_proceed_or_check() {
    local message="$1"

    if [[ "$CHECK_ONLY" == "1" ]]; then
        log_warn "$message (check mode - continuing to the preflight summary without prompting)"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        log_warn "$message"
        log_warn "Non-interactive stdin: aborting (re-run with -n/--check to preview without prompting, or attach a TTY to confirm interactively)."
        return 1
    fi

    confirm_proceed "$message"
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
