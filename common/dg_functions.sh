#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Shared Utility Functions
# ============================================================

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# NFS share path for file exchange
NFS_SHARE="/OINSTALL/_dataguard_setup"

# Get the directory where this script is located
DG_FUNCTIONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# SQL scripts directory (relative to project root)
SQL_DIR="$(dirname "$DG_FUNCTIONS_DIR")/sql"

# ============================================================
# Logging Functions
# ============================================================

log_info() {
    printf "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - %s\n" "$1"
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - %s\n" "$1"
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null
}

log_error() {
    printf "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - %s\n" "$1"
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE" 2>/dev/null
}

log_section() {
    echo ""
    printf "${BLUE}============================================================${NC}\n"
    printf "${BLUE}%s${NC}\n" "$1"
    printf "${BLUE}============================================================${NC}\n"
    echo ""
    echo "" >> "$LOG_FILE" 2>/dev/null
    echo "============================================================" >> "$LOG_FILE" 2>/dev/null
    echo "$1" >> "$LOG_FILE" 2>/dev/null
    echo "============================================================" >> "$LOG_FILE" 2>/dev/null
}

# Log a command that is about to be executed
# Usage: log_cmd "sqlplus / as sysdba" "STARTUP NOMOUNT PFILE='...'"
# Or:    log_cmd "COMMAND:" "lsnrctl reload"
log_cmd() {
    local prefix="$1"
    local cmd="$2"
    printf "${YELLOW}>>> %s${NC} %s\n" "$prefix" "$cmd"
    echo ">>> $prefix $cmd" >> "$LOG_FILE" 2>/dev/null
}

# Initialize log file
init_log() {
    local script_name="$1"
    local log_dir="${NFS_SHARE}/logs"

    mkdir -p "$log_dir" 2>/dev/null
    LOG_FILE="${log_dir}/${script_name}_$(date '+%Y%m%d_%H%M%S').log"

    echo "============================================================" > "$LOG_FILE"
    echo "Log started: $(date)" >> "$LOG_FILE"
    echo "Script: $script_name" >> "$LOG_FILE"
    echo "Hostname: $(hostname)" >> "$LOG_FILE"
    echo "============================================================" >> "$LOG_FILE"

    log_info "Log file initialized: $LOG_FILE"
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

check_db_connection() {
    log_info "Checking database connection..."

    local result
    result=$(sqlplus -s / as sysdba @"${SQL_DIR}/queries/check_connection.sql")

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
    sqlplus -s / as sysdba @"$script" "$@"
}

# Run a SQL query script and return clean output
# Usage: run_sql_query <script_name> [arg1] [arg2] ...
# Note: script_name is relative to $SQL_DIR/queries/
run_sql_query() {
    local script_name="$1"
    shift
    sqlplus -s / as sysdba @"${SQL_DIR}/queries/${script_name}" "$@"
}

# Run a SQL command script
# Usage: run_sql_command <script_name> [arg1] [arg2] ...
# Note: script_name is relative to $SQL_DIR/commands/
run_sql_command() {
    local script_name="$1"
    shift
    sqlplus -s / as sysdba @"${SQL_DIR}/commands/${script_name}" "$@"
}

# Run a SQL query script with headers (for display)
# Usage: run_sql_display <script_name> [arg1] [arg2] ...
run_sql_display() {
    local script_name="$1"
    shift
    sqlplus -s / as sysdba @"${SQL_DIR}/queries/${script_name}" "$@"
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
    "$ORACLE_HOME/bin/rman" target / @"$script"
}

# Run an RMAN script from the sql/rman directory
# Usage: run_rman <script_name>
run_rman() {
    local script_name="$1"
    "$ORACLE_HOME/bin/rman" target / @"${SQL_DIR}/rman/${script_name}"
}

# ============================================================
# DGMGRL Execution Functions
# ============================================================

# Run a DGMGRL script file with OS authentication
# Usage: run_dgmgrl_script <script_path> [arg1] [arg2] ...
run_dgmgrl_script() {
    local script="$1"
    shift
    "$ORACLE_HOME/bin/dgmgrl" -silent / @"$script" "$@"
}

# Run a DGMGRL script from the sql/dgmgrl directory
# Usage: run_dgmgrl <script_name> [arg1] [arg2] ...
run_dgmgrl() {
    local script_name="$1"
    shift
    "$ORACLE_HOME/bin/dgmgrl" -silent / @"${SQL_DIR}/dgmgrl/${script_name}" "$@"
}

# Run a DGMGRL script with password authentication
# Usage: run_dgmgrl_with_password <password> <tns_alias> <script_name> [arg1] [arg2] ...
run_dgmgrl_with_password() {
    local password="$1"
    local tns_alias="$2"
    local script_name="$3"
    shift 3
    "$ORACLE_HOME/bin/dgmgrl" -silent "sys/${password}@${tns_alias}" @"${SQL_DIR}/dgmgrl/${script_name}" "$@"
}

# ============================================================
# Password Handling Functions
# ============================================================

prompt_password() {
    local prompt_text="$1"
    local password

    # Output prompt to stderr so it doesn't get captured by $()
    printf "${YELLOW}%s${NC}: " "$prompt_text" >&2
    read -s password
    echo "" >&2

    # Only the password goes to stdout (gets captured)
    echo "$password"
}

verify_sys_password() {
    local password="$1"
    local tns_alias="$2"

    local result
    result=$(sqlplus -s "sys/${password}@${tns_alias} as sysdba" @"${SQL_DIR}/queries/check_connection.sql" 2>&1)

    if echo "$result" | grep -q "CONNECTED"; then
        return 0
    else
        return 1
    fi
}

# ============================================================
# File Operations
# ============================================================

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.bak.$(date '+%Y%m%d_%H%M%S')"
        cp "$file" "$backup"
        log_info "Backed up $file to $backup"
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

    # Create the new file by inserting sid_desc before the insert_line
    # AIX compatible: use $$ (PID) instead of mktemp
    local temp_file
    temp_file="/tmp/dg_listener_edit_$$.tmp"

    head -n $((insert_line - 1)) "$listener_file" > "$temp_file"
    cat "$sid_desc_file" >> "$temp_file"
    tail -n "+${insert_line}" "$listener_file" >> "$temp_file"

    # Replace original
    mv "$temp_file" "$listener_file"

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
    read response

    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================
# Display Functions
# ============================================================

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
    echo ""
    printf "${BLUE}============================================================${NC}\n"
    printf "${BLUE}     Oracle Data Guard Setup - %s${NC}\n" "$title"
    printf "${BLUE}============================================================${NC}\n"
    echo ""
}

print_summary() {
    local status="$1"
    local message="$2"

    echo ""
    printf "${BLUE}============================================================${NC}\n"
    if [[ "$status" == "SUCCESS" ]]; then
        printf "${GREEN}     %s: %s${NC}\n" "$status" "$message"
    else
        printf "${RED}     %s: %s${NC}\n" "$status" "$message"
    fi
    printf "${BLUE}============================================================${NC}\n"
    echo ""
}
