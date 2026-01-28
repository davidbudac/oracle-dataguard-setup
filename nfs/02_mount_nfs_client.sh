#!/bin/bash
# ============================================================
# NFS Client Mount for Oracle Data Guard
# ============================================================
# Run this script on both PRIMARY and STANDBY servers.
# Requires root/sudo privileges.
# ============================================================

set -e

# Configuration
NFS_MOUNT_PATH="/OINSTALL/_dataguard_setup"
FSTAB_OPTIONS="rw,bg,hard,nointr,tcp,vers=4,timeo=600,rsize=1048576,wsize=1048576"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

# ============================================================
# Check root privileges
# ============================================================

if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

echo "============================================================"
echo "     NFS Client Mount for Oracle Data Guard"
echo "============================================================"
echo ""

# ============================================================
# Check if already mounted
# ============================================================

if mountpoint -q "$NFS_MOUNT_PATH" 2>/dev/null; then
    log_info "NFS share is already mounted at $NFS_MOUNT_PATH"
    echo ""
    df -h "$NFS_MOUNT_PATH"
    echo ""
    log_info "Testing write access..."
    TEST_FILE="$NFS_MOUNT_PATH/.mount_test_$$"
    if touch "$TEST_FILE" 2>/dev/null && rm -f "$TEST_FILE"; then
        log_info "Write access confirmed"
        echo ""
        echo "============================================================"
        echo "     NFS mount is ready - no action needed"
        echo "============================================================"
        exit 0
    else
        log_error "Mount exists but write access failed"
        exit 1
    fi
fi

# ============================================================
# Prompt for NFS server
# ============================================================

echo "Enter the hostname or IP address of the NFS server."
echo "(This is the server where you ran 01_setup_nfs_server.sh)"
echo ""

printf "NFS server hostname/IP: "
read NFS_SERVER

if [ -z "$NFS_SERVER" ]; then
    log_error "NFS server hostname is required"
    exit 1
fi

NFS_SOURCE="$NFS_SERVER:$NFS_MOUNT_PATH"

echo ""
log_info "NFS source: $NFS_SOURCE"
log_info "Mount point: $NFS_MOUNT_PATH"
echo ""

# ============================================================
# Install NFS client packages
# ============================================================

log_info "Installing NFS client packages..."

if command -v yum &> /dev/null; then
    # RHEL/CentOS/Oracle Linux
    yum install -y nfs-utils
elif command -v dnf &> /dev/null; then
    # Fedora/RHEL 8+
    dnf install -y nfs-utils
elif command -v apt-get &> /dev/null; then
    # Debian/Ubuntu
    apt-get update
    apt-get install -y nfs-common
else
    log_warn "Could not detect package manager. Please install NFS client manually."
fi

# ============================================================
# Create mount point
# ============================================================

log_info "Creating mount point: $NFS_MOUNT_PATH"
mkdir -p "$NFS_MOUNT_PATH"

# ============================================================
# Test NFS server connectivity
# ============================================================

log_info "Testing connectivity to NFS server..."

if ! ping -c 1 -W 5 "$NFS_SERVER" &> /dev/null; then
    log_error "Cannot reach NFS server: $NFS_SERVER"
    log_error "Please check network connectivity and hostname resolution"
    exit 1
fi

log_info "NFS server is reachable"

# Check if NFS exports are available
log_info "Checking NFS exports from server..."
if command -v showmount &> /dev/null; then
    if ! showmount -e "$NFS_SERVER" 2>/dev/null | grep -q "$NFS_MOUNT_PATH"; then
        log_error "NFS export not found on server"
        log_error "Please verify NFS server setup and that this host is allowed"
        echo ""
        echo "Available exports from $NFS_SERVER:"
        showmount -e "$NFS_SERVER" 2>/dev/null || echo "(unable to list exports)"
        exit 1
    fi
    log_info "NFS export is available"
fi

# ============================================================
# Mount the NFS share
# ============================================================

log_info "Mounting NFS share..."

if mount -t nfs4 "$NFS_SOURCE" "$NFS_MOUNT_PATH"; then
    log_info "NFS share mounted successfully"
else
    log_error "Failed to mount NFS share"
    log_error "Try mounting manually: mount -t nfs4 $NFS_SOURCE $NFS_MOUNT_PATH"
    exit 1
fi

# ============================================================
# Test write access
# ============================================================

log_info "Testing write access..."

TEST_FILE="$NFS_MOUNT_PATH/.mount_test_$$"
if touch "$TEST_FILE" 2>/dev/null && rm -f "$TEST_FILE"; then
    log_info "Write access confirmed"
else
    log_error "Write access test failed"
    log_error "Check NFS export options and permissions"
    exit 1
fi

# ============================================================
# Add to /etc/fstab for persistence
# ============================================================

log_info "Configuring persistent mount in /etc/fstab..."

FSTAB_FILE="/etc/fstab"
FSTAB_ENTRY="$NFS_SOURCE    $NFS_MOUNT_PATH    nfs4    $FSTAB_OPTIONS    0 0"

if grep -q "$NFS_MOUNT_PATH" "$FSTAB_FILE" 2>/dev/null; then
    log_warn "Entry for $NFS_MOUNT_PATH already exists in /etc/fstab"
    log_warn "Please verify it manually"
else
    # Backup fstab
    cp "$FSTAB_FILE" "$FSTAB_FILE.backup.$(date +%Y%m%d_%H%M%S)"

    # Add entry
    echo "" >> "$FSTAB_FILE"
    echo "# Oracle Data Guard NFS share - added $(date)" >> "$FSTAB_FILE"
    echo "$FSTAB_ENTRY" >> "$FSTAB_FILE"
    log_info "Added entry to /etc/fstab for persistent mount"
fi

# ============================================================
# Verify setup
# ============================================================

echo ""
echo "============================================================"
echo "     Verification"
echo "============================================================"

log_info "Mount details:"
df -h "$NFS_MOUNT_PATH"

echo ""
log_info "Mount options:"
mount | grep "$NFS_MOUNT_PATH"

# ============================================================
# Set permissions for oracle user
# ============================================================

echo ""
log_info "Setting permissions for oracle user..."

# Try to find oracle user UID
ORACLE_UID=$(id -u oracle 2>/dev/null || echo "")

if [ -n "$ORACLE_UID" ]; then
    chown oracle:oinstall "$NFS_MOUNT_PATH" 2>/dev/null || chown oracle:dba "$NFS_MOUNT_PATH" 2>/dev/null || true
    chmod 775 "$NFS_MOUNT_PATH"
    log_info "Permissions set for oracle user"
else
    log_warn "Oracle user not found on this system"
    log_warn "Please set appropriate ownership manually:"
    log_warn "   chown oracle:oinstall $NFS_MOUNT_PATH"
fi

# ============================================================
# Summary
# ============================================================

echo ""
echo "============================================================"
echo "     SUCCESS: NFS Client Mount Complete"
echo "============================================================"
echo ""
echo "NFS Share: $NFS_SOURCE"
echo "Mount Point: $NFS_MOUNT_PATH"
echo ""
echo "The mount is configured to persist across reboots."
echo ""
echo "NEXT STEPS:"
echo "==========="
echo ""
echo "If this is the PRIMARY server:"
echo "   ./primary/01_gather_primary_info.sh"
echo ""
echo "If this is the STANDBY server:"
echo "   Wait for PRIMARY to complete steps 1-2, then:"
echo "   ./standby/03_setup_standby_env.sh"
echo ""
