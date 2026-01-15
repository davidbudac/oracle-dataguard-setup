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
    result=$(sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF VERIFY OFF
SELECT 'CONNECTED' FROM DUAL;
EXIT;
EOF
)

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

run_sql() {
    local sql="$1"
    sqlplus -s / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF VERIFY OFF LINESIZE 1000 PAGESIZE 0 TRIMSPOOL ON
$sql
EXIT;
EOF
}

run_sql_with_header() {
    local sql="$1"
    sqlplus -s / as sysdba <<EOF
SET LINESIZE 200 PAGESIZE 100
$sql
EXIT;
EOF
}

get_db_parameter() {
    local param_name="$1"
    local value
    value=$(run_sql "SELECT VALUE FROM V\$PARAMETER WHERE NAME='${param_name}';")
    echo "$value" | tr -d ' \n\r'
}

get_db_property() {
    local prop_name="$1"
    local value
    value=$(run_sql "SELECT PROPERTY_VALUE FROM DATABASE_PROPERTIES WHERE PROPERTY_NAME='${prop_name}';")
    echo "$value" | tr -d ' \n\r'
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
    result=$(sqlplus -s "sys/${password}@${tns_alias} as sysdba" <<EOF 2>&1
SET HEADING OFF FEEDBACK OFF
SELECT 'CONNECTED' FROM DUAL;
EXIT;
EOF
)

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
