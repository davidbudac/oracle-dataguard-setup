#!/bin/bash
# ============================================================
# NFS Server Setup for Oracle Data Guard
# ============================================================
# Run this script on the server that will host the NFS share.
# Requires root/sudo privileges.
# ============================================================

set -e

for arg in "$@"; do
    case "$arg" in
        -v|--verbose)
            export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
            set -x
            break
            ;;
    esac
done

# Configuration
NFS_SHARE_PATH="/OINSTALL/_dataguard_setup"
# no_root_squash intentionally NOT used: everything in this workflow runs
# as the oracle OS user (never root), so root on a client gains nothing
# from squashing being disabled, and leaving it enabled (the default)
# keeps root-owned writes mapped down to the anonymous user.
NFS_EXPORT_OPTIONS="rw,sync,no_subtree_check"

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

# ============================================================
# Platform guard
# ============================================================
# Everything below is Linux-specific: yum/dnf/apt, systemd units, the
# Linux /etc/exports option syntax and `exportfs -ra`. AIX has none of
# them, and NFSv4 on AIX additionally needs an NFS domain (chnfsdom) and
# an nfsroot (chnfs -r) - site decisions a script should not make as root
# on someone's box. Stop with the AIX-native sequence instead of running
# Linux commands that half-fail.
if [ "$(uname -s)" = "AIX" ]; then
    log_error "This NFS *server* script supports Linux only (see docs/DATA_GUARD_WALKTHROUGH.md, Step 0a)."
    log_error ""
    log_error "On AIX 7.2, export ${NFS_SHARE_PATH} manually as root:"
    log_error "  mkdir -p ${NFS_SHARE_PATH} && chown oracle:oinstall ${NFS_SHARE_PATH} && chmod 750 ${NFS_SHARE_PATH}"
    log_error "  mknfs -B                                  # configure + start the NFS daemons"
    log_error "  chnfsdom <your.nfs.domain>                # NFSv4 domain, must match the clients"
    log_error "  chnfs -r / -B                             # NFSv4 pseudo-root"
    log_error "  mknfsexp -d ${NFS_SHARE_PATH} -v 4 -t rw -c <primary>,<standby> -B"
    log_error "  exportfs -v                               # verify"
    log_error ""
    log_error "The rest of the workflow (steps 1-13) is AIX-clean and needs only the"
    log_error "share mounted at ${NFS_SHARE_PATH} on both DB hosts."
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

printf "Primary server hostname/IP: "
read PRIMARY_HOST
printf "Standby server hostname/IP: "
read STANDBY_HOST

if [ -z "$PRIMARY_HOST" ] || [ -z "$STANDBY_HOST" ]; then
    log_error "Both hostnames are required"
    exit 1
fi

echo ""
echo "Enter the OS user:group that should own the NFS share."
echo "This is normally the Oracle software owner (oracle:oinstall). Its"
echo "UID and GID must be identical on this server and on both DB hosts -"
echo "NFS maps ownership by numeric UID/GID, not by name, so a mismatch"
echo "means the oracle user on a DB host will not be able to read/write"
echo "files another host wrote even though the names match."
echo ""

DEFAULT_NFS_OWNER="oracle:oinstall"
printf "Owner user:group for the NFS share [%s]: " "$DEFAULT_NFS_OWNER"
read -r NFS_OWNER
NFS_OWNER="${NFS_OWNER:-$DEFAULT_NFS_OWNER}"

echo ""
log_info "NFS share path: $NFS_SHARE_PATH"
log_info "Allowed hosts: $PRIMARY_HOST, $STANDBY_HOST"
log_info "Share owner: $NFS_OWNER"
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

# Set ownership and permissions. The share carries password file copies
# and other Data Guard setup artifacts: mode 750 keeps it fully closed to
# world, writable only by its owner (normally "oracle"), and readable
# (r-x) by its owning group (normally "oinstall") - the standard Oracle
# software-owner/group split, needed because the primary and standby DB
# hosts may run as different OS users in the same "oinstall" group.
if chown "$NFS_OWNER" "$NFS_SHARE_PATH" "$NFS_SHARE_PATH/logs" 2>/dev/null; then
    log_info "Ownership set to $NFS_OWNER"
else
    log_warn "Could not chown $NFS_SHARE_PATH to $NFS_OWNER"
    log_warn "The '$NFS_OWNER' user/group may not exist on this host - create it (matching the"
    log_warn "UID/GID used on the DB hosts) or chown the share manually before continuing."
fi

chmod 750 "$NFS_SHARE_PATH"
chmod 750 "$NFS_SHARE_PATH/logs"

log_info "Directory created with owner $NFS_OWNER and permissions 750"

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
echo "Owner: $NFS_OWNER (permissions 750)"
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
