#!/bin/bash
# ============================================================
# Create a Test Database for Data Guard Testing
# ============================================================
# Run this script directly on the database server.
# Creates a new Oracle 19c database using DBCA (silent mode)
# configured for Data Guard: ARCHIVELOG, no OMF, no FRA.
#
# Usage:
#   bash tests/create_test_db.sh                       # Interactive prompts
#   bash tests/create_test_db.sh -n mydb               # Custom DB name
#   bash tests/create_test_db.sh -n mydb -p secret     # Name + password
#   bash tests/create_test_db.sh -n mydb -m 800        # Name + memory (MB)
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$(dirname "$SCRIPT_DIR")/common"

# Source common functions
source "${COMMON_DIR}/dg_functions.sh"

# ============================================================
# Defaults
# ============================================================

DB_NAME=""
SYS_PASSWORD=""
MEMORY_MB="1024"
REDO_SIZE_MB="200"
CHARSET="AL32UTF8"
DATA_DIR="/u01/app/oracle/oradata"
ARCH_DIR="/u01/app/oracle/arch"

# ============================================================
# Parse Arguments
# ============================================================

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -n, --name NAME        Database name / SID (prompted if omitted)"
    echo "  -p, --password PASS    SYS/SYSTEM password (prompted if omitted)"
    echo "  -m, --memory MB        Total memory in MB (default: $MEMORY_MB)"
    echo "  -r, --redo-size MB     Redo log size in MB (default: $REDO_SIZE_MB)"
    echo "  -c, --charset CHARSET  Character set (default: $CHARSET)"
    echo "  -d, --data-dir DIR     Datafile directory (default: $DATA_DIR)"
    echo "  -a, --arch-dir DIR     Archive log directory (default: $ARCH_DIR)"
    echo "  -h, --help             Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)     DB_NAME="$2"; shift 2 ;;
        -p|--password) SYS_PASSWORD="$2"; shift 2 ;;
        -m|--memory)   MEMORY_MB="$2"; shift 2 ;;
        -r|--redo-size) REDO_SIZE_MB="$2"; shift 2 ;;
        -c|--charset)  CHARSET="$2"; shift 2 ;;
        -d|--data-dir) DATA_DIR="$2"; shift 2 ;;
        -a|--arch-dir) ARCH_DIR="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# ============================================================
# Pre-flight Checks
# ============================================================

print_banner "Create Test Database"

# Check ORACLE_HOME
if [[ -z "${ORACLE_HOME:-}" ]]; then
    log_error "ORACLE_HOME is not set"
    exit 1
fi

if [[ ! -x "${ORACLE_HOME}/bin/dbca" ]]; then
    log_error "dbca not found at ${ORACLE_HOME}/bin/dbca"
    exit 1
fi

ORACLE_BASE="${ORACLE_BASE:-$(dirname "$(dirname "$ORACLE_HOME")")}"

# Prompt for DB name if not provided
if [[ -z "$DB_NAME" ]]; then
    printf "Database name (SID): "
    read DB_NAME
    if [[ -z "$DB_NAME" ]]; then
        log_error "Database name cannot be empty"
        exit 1
    fi
fi

# Prompt for password if not provided
if [[ -z "$SYS_PASSWORD" ]]; then
    SYS_PASSWORD=$(prompt_password "Enter SYS/SYSTEM password for new database")
    if [[ -z "$SYS_PASSWORD" ]]; then
        log_error "Password cannot be empty"
        exit 1
    fi
fi

export ORACLE_SID="$DB_NAME"

# Build the archive path with DB name
ARCH_DEST="${ARCH_DIR}/${DB_NAME}"

# Check database doesn't already exist
PMON_CHECK=$(ps -ef 2>/dev/null | grep -w "ora_pmon_${DB_NAME}" | grep -v grep || true)
if [[ -n "$PMON_CHECK" ]]; then
    log_error "Database '${DB_NAME}' is already running"
    exit 1
fi
log_info "No existing database with SID '${DB_NAME}'"

# ============================================================
# Display Configuration
# ============================================================

echo ""
print_status_block "Test Database Configuration" \
    "DB Name / SID" "$DB_NAME" \
    "Character Set" "$CHARSET" \
    "Memory" "${MEMORY_MB} MB" \
    "Redo Log Size" "${REDO_SIZE_MB} MB" \
    "Datafiles" "${DATA_DIR}" \
    "Archive Logs" "${ARCH_DEST}" \
    "OMF" "Disabled" \
    "FRA" "Disabled"

if ! confirm_proceed "Create this database?"; then
    log_info "Cancelled."
    exit 0
fi

# ============================================================
# Create Archive Directory
# ============================================================

log_info "Creating archive log directory: ${ARCH_DEST}"
mkdir -p "${ARCH_DEST}"

# ============================================================
# Run DBCA
# ============================================================

log_info "Running DBCA (this takes several minutes)..."
echo ""

dbca -silent -createDatabase \
    -gdbName "$DB_NAME" \
    -sid "$DB_NAME" \
    -templateName General_Purpose.dbc \
    -sysPassword "$SYS_PASSWORD" \
    -systemPassword "$SYS_PASSWORD" \
    -characterSet "$CHARSET" \
    -totalMemory "$MEMORY_MB" \
    -emConfiguration NONE \
    -storageType FS \
    -datafileDestination "$DATA_DIR" \
    -redoLogFileSize "$REDO_SIZE_MB" \
    -databaseType MULTIPURPOSE

DBCA_EXIT=$?
echo ""

if [[ $DBCA_EXIT -ne 0 ]]; then
    log_error "DBCA failed with exit code $DBCA_EXIT"
    exit 1
fi

log_success "DBCA database created"

# ============================================================
# Post-creation: Disable OMF/FRA, Enable ARCHIVELOG
# ============================================================

log_info "Disabling OMF and FRA, enabling ARCHIVELOG..."

sqlplus -s / as sysdba <<'SQLEOF'
SET HEADING OFF FEEDBACK OFF

-- Disable OMF (DBCA sets db_create_file_dest by default)
ALTER SYSTEM RESET db_create_file_dest SCOPE=SPFILE;
ALTER SYSTEM RESET db_create_online_log_dest_1 SCOPE=SPFILE;
ALTER SYSTEM RESET db_create_online_log_dest_2 SCOPE=SPFILE;

-- Disable FRA
ALTER SYSTEM RESET db_recovery_file_dest SCOPE=SPFILE;
ALTER SYSTEM RESET db_recovery_file_dest_size SCOPE=SPFILE;

-- Bounce to apply SPFILE changes and enable ARCHIVELOG
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;

EXIT;
SQLEOF

if [[ $? -ne 0 ]]; then
    log_error "Post-creation SQL failed"
    exit 1
fi

# Set archive destination (must be done after OPEN, uses SCOPE=BOTH)
sqlplus -s / as sysdba <<SQLEOF
SET HEADING OFF FEEDBACK OFF
ALTER SYSTEM SET log_archive_dest_1='LOCATION=${ARCH_DEST} VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${DB_NAME}' SCOPE=BOTH;
EXIT;
SQLEOF

# ============================================================
# Verify
# ============================================================

log_info "Verifying configuration..."

VERIFY_RESULT=$(sqlplus -s / as sysdba <<'SQLEOF'
SET HEADING OFF FEEDBACK OFF LINESIZE 200 PAGESIZE 0 TRIMSPOOL ON
SELECT 'LOGMODE=' || log_mode FROM v$database;
SELECT 'OMF=' || NVL(value, 'UNSET') FROM v$parameter WHERE name = 'db_create_file_dest';
SELECT 'FRA=' || NVL(value, 'UNSET') FROM v$parameter WHERE name = 'db_recovery_file_dest';
SELECT 'ARCH_DEST=' || value FROM v$parameter WHERE name = 'log_archive_dest_1';
EXIT;
SQLEOF
)

if echo "$VERIFY_RESULT" | grep -q 'LOGMODE=ARCHIVELOG'; then
    log_success "ARCHIVELOG mode enabled"
else
    log_error "ARCHIVELOG mode not enabled"
    echo "$VERIFY_RESULT"
    exit 1
fi

if echo "$VERIFY_RESULT" | grep -qE 'OMF=$|OMF=UNSET'; then
    log_success "OMF disabled (db_create_file_dest cleared)"
else
    log_warn "OMF may still have a residual value from DBCA"
fi

if echo "$VERIFY_RESULT" | grep -qE 'FRA=$|FRA=UNSET'; then
    log_success "FRA disabled (db_recovery_file_dest cleared)"
else
    log_warn "FRA may still have a residual value"
fi

echo "$VERIFY_RESULT" | grep 'ARCH_DEST=' | while IFS= read -r line; do
    log_info "Archive dest: ${line#ARCH_DEST=}"
done

# Force a few log switches to populate the archive directory
sqlplus -s / as sysdba <<'SQLEOF' > /dev/null
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
ALTER SYSTEM SWITCH LOGFILE;
EXIT;
SQLEOF

# Brief pause for archiver to write
sleep 2

if find "${ARCH_DEST}" -type f 2>/dev/null | head -1 | grep -q .; then
    log_success "Archive logs written to ${ARCH_DEST}"
else
    log_warn "No archive logs found yet in ${ARCH_DEST} (archiver may still be writing)"
fi

# ============================================================
# Summary
# ============================================================

print_summary "SUCCESS" "Test database '${DB_NAME}' created"
print_status_block "Database Details" \
    "SID" "$DB_NAME" \
    "Datafiles" "${DATA_DIR}/${DB_NAME}" \
    "Archive Logs" "${ARCH_DEST}" \
    "Mode" "ARCHIVELOG, no OMF, no FRA"

print_list_block "Next Steps" \
    "Run ./primary/01_gather_primary_info.sh to start Data Guard setup." \
    "To drop: bash tests/create_test_db.sh is paired with tests/e2e/drop_test_db.sh"
