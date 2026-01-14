#!/bin/bash
# ============================================================
# Oracle Data Guard Setup - Step 2: Generate Standby Configuration
# ============================================================
# Run this script after gathering primary info.
# It generates the standby configuration (single source of truth)
# and displays it for user review.
# ============================================================

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "${SCRIPT_DIR}/dg_functions.sh"

# ============================================================
# Main Script
# ============================================================

print_banner "Step 2: Generate Standby Config"

# Initialize logging
init_log "02_generate_standby_config"

# ============================================================
# Pre-flight Checks
# ============================================================

log_section "Pre-flight Checks"

check_nfs_mount || exit 1

# Check primary info file exists
PRIMARY_INFO_FILE="${NFS_SHARE}/primary_info.env"
if [[ ! -f "$PRIMARY_INFO_FILE" ]]; then
    log_error "Primary info file not found: $PRIMARY_INFO_FILE"
    log_error "Please run 01_gather_primary_info.sh on the primary server first"
    exit 1
fi

log_info "Loading primary info from: $PRIMARY_INFO_FILE"

# Source primary info
source "$PRIMARY_INFO_FILE"

log_info "Primary database: $DB_UNIQUE_NAME on $PRIMARY_HOSTNAME"

# ============================================================
# Prompt for Standby Information
# ============================================================

log_section "Standby Server Configuration"

echo ""
echo "Please provide the following information for the standby database:"
echo ""

# Standby hostname
read -p "Standby server hostname: " STANDBY_HOSTNAME
if [[ -z "$STANDBY_HOSTNAME" ]]; then
    log_error "Standby hostname cannot be empty"
    exit 1
fi

# Standby DB_UNIQUE_NAME
echo ""
echo "The standby DB_UNIQUE_NAME must be different from primary ($DB_UNIQUE_NAME)"
read -p "Standby DB_UNIQUE_NAME: " STANDBY_DB_UNIQUE_NAME
if [[ -z "$STANDBY_DB_UNIQUE_NAME" ]]; then
    log_error "Standby DB_UNIQUE_NAME cannot be empty"
    exit 1
fi

if [[ "$STANDBY_DB_UNIQUE_NAME" == "$DB_UNIQUE_NAME" ]]; then
    log_error "Standby DB_UNIQUE_NAME must be different from primary"
    exit 1
fi

# Standby Oracle SID (default same as primary)
echo ""
echo "The standby ORACLE_SID (default: $PRIMARY_ORACLE_SID)"
read -p "Standby ORACLE_SID [$PRIMARY_ORACLE_SID]: " STANDBY_ORACLE_SID
STANDBY_ORACLE_SID=${STANDBY_ORACLE_SID:-$PRIMARY_ORACLE_SID}

# ============================================================
# Generate Path Conversions
# ============================================================

log_section "Generating Path Conversions"

# Replace primary DB_UNIQUE_NAME with standby DB_UNIQUE_NAME in paths
STANDBY_DATA_PATH=$(echo "$PRIMARY_DATA_PATH" | sed "s/${DB_UNIQUE_NAME}/${STANDBY_DB_UNIQUE_NAME}/g")
STANDBY_REDO_PATH=$(echo "$PRIMARY_REDO_PATH" | sed "s/${DB_UNIQUE_NAME}/${STANDBY_DB_UNIQUE_NAME}/g")
STANDBY_ARCHIVE_DEST=$(echo "$PRIMARY_ARCHIVE_DEST" | sed "s/${DB_UNIQUE_NAME}/${STANDBY_DB_UNIQUE_NAME}/g")

# Generate FILE_NAME_CONVERT parameters
DB_FILE_NAME_CONVERT="'${PRIMARY_DATA_PATH}','${STANDBY_DATA_PATH}'"
LOG_FILE_NAME_CONVERT="'${PRIMARY_REDO_PATH}','${STANDBY_REDO_PATH}'"

# If data and redo are in different paths with DB_UNIQUE_NAME, add both
if [[ "$PRIMARY_DATA_PATH" != "$PRIMARY_REDO_PATH" ]]; then
    DB_FILE_NAME_CONVERT="'${PRIMARY_DATA_PATH}','${STANDBY_DATA_PATH}','${PRIMARY_REDO_PATH}','${STANDBY_REDO_PATH}'"
    LOG_FILE_NAME_CONVERT="'${PRIMARY_DATA_PATH}','${STANDBY_DATA_PATH}','${PRIMARY_REDO_PATH}','${STANDBY_REDO_PATH}'"
fi

log_info "Primary data path: $PRIMARY_DATA_PATH"
log_info "Standby data path: $STANDBY_DATA_PATH"
log_info "Primary redo path: $PRIMARY_REDO_PATH"
log_info "Standby redo path: $STANDBY_REDO_PATH"

# ============================================================
# Generate TNS Aliases
# ============================================================

log_section "Generating TNS Configuration"

PRIMARY_TNS_ALIAS="${DB_UNIQUE_NAME}"
STANDBY_TNS_ALIAS="${STANDBY_DB_UNIQUE_NAME}"

log_info "Primary TNS alias: $PRIMARY_TNS_ALIAS"
log_info "Standby TNS alias: $STANDBY_TNS_ALIAS"

# ============================================================
# Generate Admin Directories
# ============================================================

log_section "Generating Admin Directories"

# Assume same ORACLE_BASE structure on standby
STANDBY_ORACLE_BASE="$PRIMARY_ORACLE_BASE"
STANDBY_ORACLE_HOME="$PRIMARY_ORACLE_HOME"

STANDBY_ADMIN_DIR="${STANDBY_ORACLE_BASE}/admin/${STANDBY_DB_UNIQUE_NAME}"

log_info "Standby admin directory: $STANDBY_ADMIN_DIR"

# ============================================================
# Calculate Standby Redo Log Groups
# ============================================================

RECOMMENDED_STBY_GROUPS=$((ONLINE_REDO_GROUPS + 1))

log_info "Online redo groups: $ONLINE_REDO_GROUPS"
log_info "Recommended standby redo groups: $RECOMMENDED_STBY_GROUPS"

# ============================================================
# Write Standby Configuration File
# ============================================================

log_section "Writing Standby Configuration"

STANDBY_CONFIG_FILE="${NFS_SHARE}/standby_config.env"

cat > "$STANDBY_CONFIG_FILE" <<EOF
# ============================================================
# Oracle Data Guard Standby Configuration
# Generated: $(date)
# Single Source of Truth for Standby Setup
# ============================================================

# --- Primary Database Info ---
PRIMARY_HOSTNAME="$PRIMARY_HOSTNAME"
PRIMARY_DB_NAME="$DB_NAME"
PRIMARY_DB_UNIQUE_NAME="$DB_UNIQUE_NAME"
PRIMARY_ORACLE_SID="$PRIMARY_ORACLE_SID"
PRIMARY_ORACLE_HOME="$PRIMARY_ORACLE_HOME"
PRIMARY_ORACLE_BASE="$PRIMARY_ORACLE_BASE"
PRIMARY_LISTENER_PORT="$LISTENER_PORT"
PRIMARY_TNS_ALIAS="$PRIMARY_TNS_ALIAS"

# --- Standby Database Info ---
STANDBY_HOSTNAME="$STANDBY_HOSTNAME"
STANDBY_DB_NAME="$DB_NAME"
STANDBY_DB_UNIQUE_NAME="$STANDBY_DB_UNIQUE_NAME"
STANDBY_ORACLE_SID="$STANDBY_ORACLE_SID"
STANDBY_ORACLE_HOME="$STANDBY_ORACLE_HOME"
STANDBY_ORACLE_BASE="$STANDBY_ORACLE_BASE"
STANDBY_LISTENER_PORT="$LISTENER_PORT"
STANDBY_TNS_ALIAS="$STANDBY_TNS_ALIAS"

# --- Database Properties ---
DB_DOMAIN="$DB_DOMAIN"
DBID="$DBID"
NLS_CHARACTERSET="$NLS_CHARACTERSET"
DB_BLOCK_SIZE="$DB_BLOCK_SIZE"
COMPATIBLE="$COMPATIBLE"

# --- Path Conversions ---
PRIMARY_DATA_PATH="$PRIMARY_DATA_PATH"
STANDBY_DATA_PATH="$STANDBY_DATA_PATH"
PRIMARY_REDO_PATH="$PRIMARY_REDO_PATH"
STANDBY_REDO_PATH="$STANDBY_REDO_PATH"
DB_FILE_NAME_CONVERT="${DB_FILE_NAME_CONVERT}"
LOG_FILE_NAME_CONVERT="${LOG_FILE_NAME_CONVERT}"

# --- Archive Log Configuration ---
PRIMARY_ARCHIVE_DEST="$PRIMARY_ARCHIVE_DEST"
STANDBY_ARCHIVE_DEST="$STANDBY_ARCHIVE_DEST"

# --- Recovery Area ---
DB_RECOVERY_FILE_DEST="$DB_RECOVERY_FILE_DEST"
DB_RECOVERY_FILE_DEST_SIZE="$DB_RECOVERY_FILE_DEST_SIZE"

# --- Redo Log Configuration ---
REDO_LOG_SIZE_MB="$REDO_LOG_SIZE_MB"
ONLINE_REDO_GROUPS="$ONLINE_REDO_GROUPS"
STANDBY_REDO_GROUPS="$RECOMMENDED_STBY_GROUPS"
STANDBY_REDO_EXISTS="$STANDBY_REDO_EXISTS"

# --- Admin Directories ---
STANDBY_ADMIN_DIR="$STANDBY_ADMIN_DIR"

# --- Data Guard Broker ---
# Note: Data Guard parameters (LOG_ARCHIVE_DEST_2, FAL_SERVER, etc.)
# are managed by Data Guard Broker (DGMGRL), not set manually
DG_BROKER_CONFIG_NAME="${DB_NAME}_DG"
EOF

log_info "Standby configuration written to: $STANDBY_CONFIG_FILE"

# ============================================================
# Generate Standby Init Parameter File
# ============================================================

log_section "Generating Standby Init Parameter File"

STANDBY_PFILE="${NFS_SHARE}/init${STANDBY_ORACLE_SID}.ora"

cat > "$STANDBY_PFILE" <<EOF
# ============================================================
# Oracle Data Guard Standby Parameter File
# Generated: $(date)
# Database: $STANDBY_DB_UNIQUE_NAME
# ============================================================

# --- Database Identity ---
*.db_name='${DB_NAME}'
*.db_unique_name='${STANDBY_DB_UNIQUE_NAME}'
$(if [[ -n "$DB_DOMAIN" ]]; then echo "*.db_domain='${DB_DOMAIN}'"; fi)

# --- Memory (adjust as needed) ---
*.memory_target=0
*.sga_target=0
*.pga_aggregate_target=0
# Note: Memory parameters will be copied from primary during RMAN duplicate

# --- Processes ---
*.processes=300

# --- Control Files ---
*.control_files='${STANDBY_DATA_PATH}/control01.ctl','${STANDBY_DATA_PATH}/control02.ctl'

# --- Archive Log Destination (local only) ---
*.log_archive_dest_1='LOCATION=${STANDBY_ARCHIVE_DEST} VALID_FOR=(ALL_LOGFILES,ALL_ROLES) DB_UNIQUE_NAME=${STANDBY_DB_UNIQUE_NAME}'
*.log_archive_dest_state_1=ENABLE
*.log_archive_format='%t_%s_%r.arc'

# --- File Name Conversions ---
*.db_file_name_convert=${DB_FILE_NAME_CONVERT}
*.log_file_name_convert=${LOG_FILE_NAME_CONVERT}
*.standby_file_management=AUTO

# --- Data Guard Broker ---
# DG Broker will manage LOG_ARCHIVE_DEST_2, FAL_SERVER, LOG_ARCHIVE_CONFIG, etc.
*.dg_broker_start=TRUE

# --- Diagnostic Destinations ---
*.audit_file_dest='${STANDBY_ADMIN_DIR}/adump'
*.diagnostic_dest='${STANDBY_ORACLE_BASE}'

# --- Block Size ---
*.db_block_size=${DB_BLOCK_SIZE}

# --- Compatibility ---
*.compatible='${COMPATIBLE}'

# --- Remote Login ---
*.remote_login_passwordfile=EXCLUSIVE

# --- Local Listener ---
*.local_listener='(ADDRESS=(PROTOCOL=TCP)(HOST=${STANDBY_HOSTNAME})(PORT=${LISTENER_PORT}))'
EOF

log_info "Standby pfile written to: $STANDBY_PFILE"

# ============================================================
# Generate TNS Entries
# ============================================================

log_section "Generating TNS Entries"

TNSNAMES_FILE="${NFS_SHARE}/tnsnames_entries.ora"

cat > "$TNSNAMES_FILE" <<EOF
# ============================================================
# Oracle Data Guard TNS Entries
# Generated: $(date)
# Add these entries to tnsnames.ora on BOTH primary and standby
# ============================================================

${PRIMARY_TNS_ALIAS} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${PRIMARY_HOSTNAME})(PORT = ${LISTENER_PORT}))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${DB_UNIQUE_NAME})
    )
  )

${STANDBY_TNS_ALIAS} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${STANDBY_HOSTNAME})(PORT = ${LISTENER_PORT}))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${STANDBY_DB_UNIQUE_NAME})
    )
  )
EOF

log_info "TNS entries written to: $TNSNAMES_FILE"

# ============================================================
# Generate Listener Entry for Standby
# ============================================================

log_section "Generating Listener Configuration for Standby"

LISTENER_FILE="${NFS_SHARE}/listener_standby.ora"

cat > "$LISTENER_FILE" <<EOF
# ============================================================
# Oracle Data Guard Listener Entry for Standby
# Generated: $(date)
# Add this SID_LIST entry to listener.ora on STANDBY server
# Static registration required for RMAN duplicate (DB in NOMOUNT)
# ============================================================

# Add this to your existing SID_LIST_LISTENER or create new:
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = ${STANDBY_DB_UNIQUE_NAME})
      (ORACLE_HOME = ${STANDBY_ORACLE_HOME})
      (SID_NAME = ${STANDBY_ORACLE_SID})
    )
  )

# Ensure LISTENER section exists:
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = TCP)(HOST = ${STANDBY_HOSTNAME})(PORT = ${LISTENER_PORT}))
    )
  )
EOF

log_info "Listener entries written to: $LISTENER_FILE"

# ============================================================
# Generate Data Guard Broker Configuration Script
# ============================================================

log_section "Generating Data Guard Broker Configuration Script"

DG_BROKER_CONFIG_NAME="${DB_NAME}_DG"
DGMGRL_SCRIPT="${NFS_SHARE}/configure_broker.dgmgrl"

cat > "$DGMGRL_SCRIPT" <<EOF
# ============================================================
# Data Guard Broker Configuration Script
# Generated: $(date)
# Run this script using: dgmgrl / @configure_broker.dgmgrl
# ============================================================

# Create the Data Guard Broker configuration
CREATE CONFIGURATION '${DG_BROKER_CONFIG_NAME}' AS PRIMARY DATABASE IS '${DB_UNIQUE_NAME}' CONNECT IDENTIFIER IS '${PRIMARY_TNS_ALIAS}';

# Add the standby database to the configuration
ADD DATABASE '${STANDBY_DB_UNIQUE_NAME}' AS CONNECT IDENTIFIER IS '${STANDBY_TNS_ALIAS}' MAINTAINED AS PHYSICAL;

# Enable the configuration
ENABLE CONFIGURATION;

# Show the configuration status
SHOW CONFIGURATION;

# Show database details
SHOW DATABASE '${DB_UNIQUE_NAME}';
SHOW DATABASE '${STANDBY_DB_UNIQUE_NAME}';
EOF

log_info "DGMGRL script written to: $DGMGRL_SCRIPT"

# ============================================================
# Display Configuration for Review
# ============================================================

log_section "Configuration Review"

echo ""
echo "================================================================"
echo "                 STANDBY CONFIGURATION SUMMARY"
echo "================================================================"
echo ""
echo "PRIMARY DATABASE:"
echo "  Hostname:        $PRIMARY_HOSTNAME"
echo "  DB_UNIQUE_NAME:  $DB_UNIQUE_NAME"
echo "  ORACLE_SID:      $PRIMARY_ORACLE_SID"
echo "  TNS Alias:       $PRIMARY_TNS_ALIAS"
echo "  Data Path:       $PRIMARY_DATA_PATH"
echo ""
echo "STANDBY DATABASE:"
echo "  Hostname:        $STANDBY_HOSTNAME"
echo "  DB_UNIQUE_NAME:  $STANDBY_DB_UNIQUE_NAME"
echo "  ORACLE_SID:      $STANDBY_ORACLE_SID"
echo "  TNS Alias:       $STANDBY_TNS_ALIAS"
echo "  Data Path:       $STANDBY_DATA_PATH"
echo ""
echo "PATH CONVERSIONS:"
echo "  DB_FILE_NAME_CONVERT:  $DB_FILE_NAME_CONVERT"
echo "  LOG_FILE_NAME_CONVERT: $LOG_FILE_NAME_CONVERT"
echo ""
echo "REDO LOG CONFIGURATION:"
echo "  Online Redo Groups:  $ONLINE_REDO_GROUPS"
echo "  Standby Redo Groups: $RECOMMENDED_STBY_GROUPS"
echo "  Redo Log Size:       ${REDO_LOG_SIZE_MB}MB"
echo ""
echo "DATA GUARD BROKER:"
echo "  Configuration Name:  $DG_BROKER_CONFIG_NAME"
echo "  (Parameters will be managed automatically by DGMGRL)"
echo ""
echo "================================================================"
echo ""
echo "Generated Files:"
echo "  - Standby config:    $STANDBY_CONFIG_FILE"
echo "  - Standby pfile:     $STANDBY_PFILE"
echo "  - TNS entries:       $TNSNAMES_FILE"
echo "  - Listener config:   $LISTENER_FILE"
echo "  - DGMGRL script:     $DGMGRL_SCRIPT"
echo ""
echo "================================================================"

# ============================================================
# User Confirmation
# ============================================================

echo ""
if ! confirm_proceed "Please review the configuration above."; then
    log_warn "User cancelled. Configuration files have been saved for review."
    echo ""
    echo "You can edit the configuration files manually and re-run, or"
    echo "run this script again with different parameters."
    exit 0
fi

print_summary "SUCCESS" "Standby configuration generated successfully"

echo ""
echo "NEXT STEPS:"
echo "==========="
echo ""
echo "1. On STANDBY server:"
echo "   Run: ./standby/03_setup_standby_env.sh"
echo ""
echo "2. On PRIMARY server:"
echo "   Run: ./primary/04_prepare_primary_dg.sh"
echo ""
echo "3. On STANDBY server:"
echo "   Run: ./standby/05_clone_standby.sh"
echo ""
echo "4. On PRIMARY server:"
echo "   Run: ./primary/06_configure_broker.sh"
echo ""
echo "5. On either server:"
echo "   Run: ./standby/07_verify_dataguard.sh"
echo ""
