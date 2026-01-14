#!/bin/bash
# ============================================================
# NFS Server Setup for Oracle Data Guard
# ============================================================
# Run this script on the server that will host the NFS share.
# Requires root/sudo privileges.
# ============================================================

set -e

# Configuration
NFS_SHARE_PATH="/OINSTALL/_dataguard_setup"
NFS_EXPORT_OPTIONS="rw,sync,no_subtree_check,no_root_squash"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================================
# Check root privileges
# ============================================================

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

echo "============================================================"
echo "     NFS Server Setup for Oracle Data Guard"
echo "============================================================"
echo ""

# ============================================================
# Prompt for client hosts
# ============================================================

echo "Enter the hostnames or IP addresses that need access to this NFS share."
echo "These are typically your primary and standby database servers."
echo ""

read -p "Primary server hostname/IP: " PRIMARY_HOST
read -p "Standby server hostname/IP: " STANDBY_HOST

if [[ -z "$PRIMARY_HOST" || -z "$STANDBY_HOST" ]]; then
    log_error "Both hostnames are required"
    exit 1
fi

echo ""
log_info "NFS share path: $NFS_SHARE_PATH"
log_info "Allowed hosts: $PRIMARY_HOST, $STANDBY_HOST"
echo ""

# ============================================================
# Install NFS server packages
# ============================================================

log_info "Installing NFS server packages..."

if command -v yum &> /dev/null; then
    # RHEL/CentOS/Oracle Linux
    yum install -y nfs-utils
elif command -v dnf &> /dev/null; then
    # Fedora/RHEL 8+
    dnf install -y nfs-utils
elif command -v apt-get &> /dev/null; then
    # Debian/Ubuntu
    apt-get update
    apt-get install -y nfs-kernel-server
else
    log_warn "Could not detect package manager. Please install NFS server manually."
fi

# ============================================================
# Create share directory
# ============================================================

log_info "Creating NFS share directory: $NFS_SHARE_PATH"

mkdir -p "$NFS_SHARE_PATH"
mkdir -p "$NFS_SHARE_PATH/logs"

# Set permissions (oracle user typically has UID 54321)
# Adjust ownership as needed for your environment
chmod 775 "$NFS_SHARE_PATH"
chmod 775 "$NFS_SHARE_PATH/logs"

log_info "Directory created with permissions 775"

# ============================================================
# Configure /etc/exports
# ============================================================

log_info "Configuring /etc/exports..."

EXPORTS_FILE="/etc/exports"
BACKUP_FILE="/etc/exports.backup.$(date +%Y%m%d_%H%M%S)"

# Backup existing exports file
if [[ -f "$EXPORTS_FILE" ]]; then
    cp "$EXPORTS_FILE" "$BACKUP_FILE"
    log_info "Backed up existing exports to: $BACKUP_FILE"
fi

# Check if entry already exists
if grep -q "$NFS_SHARE_PATH" "$EXPORTS_FILE" 2>/dev/null; then
    log_warn "Entry for $NFS_SHARE_PATH already exists in /etc/exports"
    log_warn "Please verify it manually:"
    grep "$NFS_SHARE_PATH" "$EXPORTS_FILE"
else
    # Add new export entries
    echo "" >> "$EXPORTS_FILE"
    echo "# Oracle Data Guard setup share - added $(date)" >> "$EXPORTS_FILE"
    echo "$NFS_SHARE_PATH $PRIMARY_HOST($NFS_EXPORT_OPTIONS)" >> "$EXPORTS_FILE"
    echo "$NFS_SHARE_PATH $STANDBY_HOST($NFS_EXPORT_OPTIONS)" >> "$EXPORTS_FILE"
    log_info "Added export entries to /etc/exports"
fi

# ============================================================
# Start and enable NFS services
# ============================================================

log_info "Starting NFS services..."

if command -v systemctl &> /dev/null; then
    # Systemd-based systems
    systemctl enable nfs-server 2>/dev/null || systemctl enable nfs-kernel-server 2>/dev/null || true
    systemctl start nfs-server 2>/dev/null || systemctl start nfs-kernel-server 2>/dev/null || true
    systemctl enable rpcbind 2>/dev/null || true
    systemctl start rpcbind 2>/dev/null || true
else
    # SysVinit
    service nfs start 2>/dev/null || service nfs-kernel-server start 2>/dev/null || true
    chkconfig nfs on 2>/dev/null || true
fi

# ============================================================
# Export the filesystem
# ============================================================

log_info "Exporting filesystem..."
exportfs -ra

# ============================================================
# Configure firewall (if active)
# ============================================================

log_info "Checking firewall..."

if command -v firewall-cmd &> /dev/null; then
    if systemctl is-active --quiet firewalld; then
        log_info "Configuring firewalld for NFS..."
        firewall-cmd --permanent --add-service=nfs
        firewall-cmd --permanent --add-service=rpc-bind
        firewall-cmd --permanent --add-service=mountd
        firewall-cmd --reload
        log_info "Firewall configured for NFS"
    fi
elif command -v ufw &> /dev/null; then
    if ufw status | grep -q "active"; then
        log_info "Configuring ufw for NFS..."
        ufw allow from "$PRIMARY_HOST" to any port nfs
        ufw allow from "$STANDBY_HOST" to any port nfs
        log_info "Firewall configured for NFS"
    fi
else
    log_warn "No firewall detected or firewall is inactive"
    log_warn "If you have a firewall, ensure ports 111, 2049 are open"
fi

# ============================================================
# Verify setup
# ============================================================

echo ""
echo "============================================================"
echo "     Verification"
echo "============================================================"

log_info "Exported filesystems:"
exportfs -v

echo ""
log_info "NFS server status:"
if command -v systemctl &> /dev/null; then
    systemctl status nfs-server --no-pager 2>/dev/null || systemctl status nfs-kernel-server --no-pager 2>/dev/null || true
fi

# ============================================================
# Summary
# ============================================================

echo ""
echo "============================================================"
echo "     SUCCESS: NFS Server Setup Complete"
echo "============================================================"
echo ""
echo "NFS Share: $NFS_SHARE_PATH"
echo "Allowed hosts: $PRIMARY_HOST, $STANDBY_HOST"
echo ""
echo "NEXT STEPS:"
echo "==========="
echo ""
echo "On PRIMARY server ($PRIMARY_HOST), run:"
echo "   sudo ./nfs/02_mount_nfs_client.sh"
echo ""
echo "On STANDBY server ($STANDBY_HOST), run:"
echo "   sudo ./nfs/02_mount_nfs_client.sh"
echo ""
