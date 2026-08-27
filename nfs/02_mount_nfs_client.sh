#!/bin/bash
# ============================================================
# NFS Client Mount for Oracle Data Guard
# ============================================================
# Run this script on both PRIMARY and STANDBY servers.
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
NFS_MOUNT_PATH="/OINSTALL/_dataguard_setup"
# nointr is intentionally omitted: it's a no-op on modern Linux kernels
# and AIX (hard mounts have not been interruptible via this option for
# years) and is documented obsolete - keeping it would just be cargo cult.
FSTAB_OPTIONS="rw,bg,hard,tcp,vers=4,timeo=600,rsize=1048576,wsize=1048576"

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
# Write access test helper
# ============================================================
# nfs/01_setup_nfs_server.sh exports with root_squash (deliberately - see
# that script's comment), so a write test run as root is mapped to the
# anonymous user and gets EACCES even on a perfectly writable share. This
# script requires root (checked below), so the meaningful write test is
# "can the oracle OS user write here", not "can root write here". Falls
# back to testing as the invoking user if the oracle account doesn't exist
# locally, or if neither su nor sudo is usable.
test_nfs_write_access() {
    local mount_path="$1"
    local test_file="${mount_path}/.mount_test_$$"

    if [ "$EUID" -ne 0 ]; then
        # Not root (script normally enforces this, but keep the test
        # meaningful if that check is ever relaxed): just test as ourselves.
        touch "$test_file" 2>/dev/null && rm -f "$test_file" 2>/dev/null
        return $?
    fi

    if ! id oracle >/dev/null 2>&1; then
        log_warn "oracle OS user not found on this host - testing write access as root instead"
        log_warn "(meaningful only if root_squash is NOT set on the NFS export)"
        touch "$test_file" 2>/dev/null && rm -f "$test_file" 2>/dev/null
        return $?
    fi

    if su - oracle -c "touch '$test_file' && rm -f '$test_file'" >/dev/null 2>&1; then
        return 0
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -u oracle touch "$test_file" >/dev/null 2>&1; then
        sudo -u oracle rm -f "$test_file" >/dev/null 2>&1 || true
        return 0
    fi

    log_error "Write test as the oracle OS user failed via both 'su - oracle' and 'sudo -u oracle'."
    log_error "The NFS export uses root_squash (nfs/01_setup_nfs_server.sh does not disable it, by"
    log_error "design), so root's own writes here are mapped to the anonymous user and denied even"
    log_error "on a share that oracle can legitimately write to. Verify:"
    log_error "  - the oracle user's UID/GID matches between this host and the NFS server"
    log_error "  - /etc/exports on the NFS server grants rw to this host"
    log_error "  - the share is owned oracle:oinstall with mode 750 (nfs/01_setup_nfs_server.sh)"
    return 1
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
# Below is Linux-specific: yum/dnf/apt, `mount -t nfs4`, /etc/fstab.
# AIX mounts NFS through /etc/filesystems (mknfsmnt), so running the
# Linux path there leaves a mounted-but-not-persistent share at best.
if [ "$(uname -s)" = "AIX" ]; then
    log_error "This NFS *client* script supports Linux only (see docs/DATA_GUARD_WALKTHROUGH.md, Step 0b)."
    log_error ""
    log_error "On AIX 7.2, mount the share manually as root:"
    log_error "  mkdir -p ${NFS_MOUNT_PATH}"
    log_error "  chnfsdom <your.nfs.domain>                # must match the NFS server's domain"
    log_error "  mknfsmnt -f ${NFS_MOUNT_PATH} -d <server-export-path> -h <nfs-server> \\"
    log_error "           -A -t rw -w bg -X -Y -V 4        # -A = mount now + persist in /etc/filesystems"
    log_error "  mount ${NFS_MOUNT_PATH} && df -k ${NFS_MOUNT_PATH}"
    log_error ""
    log_error "Then confirm the oracle user can write to it:"
    log_error "  su - oracle -c 'touch ${NFS_MOUNT_PATH}/.w && rm -f ${NFS_MOUNT_PATH}/.w && echo OK'"
    log_error ""
    log_error "The rest of the workflow (steps 1-13) is AIX-clean once the share is mounted."
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
    if test_nfs_write_access "$NFS_MOUNT_PATH"; then
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

# ============================================================
# Detect running on the NFS server itself
# ============================================================
# The export path and the mount path are deliberately the same directory
# (see 01_setup_nfs_server.sh), so on the server host the share is already
# available locally and must NOT be NFS-mounted on top of itself: a
# loopback NFS mount shadows the exported directory with an NFS
# filesystem, and rpc.mountd then refuses every OTHER client with
# "Cannot export ..., possibly unsupported filesystem or fsid= required"
# (client-side symptom: mount.nfs4 "No such file or directory").
# Found live: the walkthrough runs this script on both DB hosts, and the
# NFS server is usually one of them.

_is_local_nfs_server="no"
if [ "$NFS_SERVER" = "$(hostname 2>/dev/null)" ] || [ "$NFS_SERVER" = "$(hostname -s 2>/dev/null)" ]; then
    _is_local_nfs_server="yes"
elif hostname -I >/dev/null 2>&1; then
    # Linux: match against every local interface address
    for _local_ip in $(hostname -I 2>/dev/null); do
        if [ "$NFS_SERVER" = "$_local_ip" ]; then
            _is_local_nfs_server="yes"
            break
        fi
    done
elif command -v ifconfig >/dev/null 2>&1; then
    # AIX/other: fall back to ifconfig -a output
    if ifconfig -a 2>/dev/null | grep -w "inet" | awk '{print $2}' | grep -qx "$NFS_SERVER"; then
        _is_local_nfs_server="yes"
    fi
fi

if [ "$_is_local_nfs_server" = "yes" ]; then
    echo ""
    log_info "This host IS the NFS server ($NFS_SERVER) - skipping the NFS mount."
    log_info "The share directory $NFS_MOUNT_PATH is already available locally"
    log_info "(the export path and the client mount path are the same directory)."
    if [ ! -d "$NFS_MOUNT_PATH" ]; then
        log_error "Export directory $NFS_MOUNT_PATH does not exist - run 01_setup_nfs_server.sh first"
        exit 1
    fi
    log_info "Testing write access..."
    if test_nfs_write_access "$NFS_MOUNT_PATH"; then
        log_info "Write access confirmed"
        echo ""
        echo "============================================================"
        echo "     NFS share is ready on the server host - no mount needed"
        echo "============================================================"
        exit 0
    else
        log_error "Write access test failed on the local share directory"
        log_error "Check ownership/permissions of $NFS_MOUNT_PATH (expected owner oracle:oinstall, mode 750)"
        exit 1
    fi
fi

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

# ICMP is frequently filtered by firewalls/security groups even when the
# NFS server is perfectly reachable, so a failed ping is not proof of an
# outage - warn and let the actual mount attempt below be the real test.
if ! ping -c 1 -W 5 "$NFS_SERVER" &> /dev/null; then
    log_warn "Could not ping NFS server: $NFS_SERVER (ICMP may be filtered - continuing)"
else
    log_info "NFS server is reachable"
fi

# Check if NFS exports are available. showmount queries rpc.mountd, which
# NFSv4-only servers do not run (there's no separate MOUNT protocol in
# NFSv4 - clients reach exports directly via the pseudo-filesystem), so a
# failed/empty showmount does not necessarily mean the export is missing.
# Warn instead of aborting and let the actual mount attempt be the judge.
log_info "Checking NFS exports from server..."
if command -v showmount &> /dev/null; then
    if ! showmount -e "$NFS_SERVER" 2>/dev/null | grep -q "$NFS_MOUNT_PATH"; then
        log_warn "showmount did not list export $NFS_MOUNT_PATH on $NFS_SERVER"
        log_warn "This is expected on NFSv4-only servers (no rpc.mountd) - continuing to the mount attempt"
        echo ""
        echo "Available exports from $NFS_SERVER (if any):"
        showmount -e "$NFS_SERVER" 2>/dev/null || echo "(unable to list exports - showmount/mountd unavailable)"
    else
        log_info "NFS export is available"
    fi
fi

# ============================================================
# Mount the NFS share
# ============================================================

log_info "Mounting NFS share..."

# Mount with the same options that get written to /etc/fstab below, so the
# interactive mount actually exercises what will be used on every reboot
# instead of the (different) kernel defaults.
if mount -t nfs4 -o "$FSTAB_OPTIONS" "$NFS_SOURCE" "$NFS_MOUNT_PATH"; then
    log_info "NFS share mounted successfully"
else
    log_error "Failed to mount NFS share"
    log_error "Try mounting manually: mount -t nfs4 -o $FSTAB_OPTIONS $NFS_SOURCE $NFS_MOUNT_PATH"
    exit 1
fi

# ============================================================
# Test write access
# ============================================================

log_info "Testing write access..."

if test_nfs_write_access "$NFS_MOUNT_PATH"; then
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
    # Both guarded: this host is root, and the export is root_squashed by
    # design (see nfs/01_setup_nfs_server.sh) - a root-issued chown/chmod
    # against the mounted share is squashed to the anonymous user and can
    # fail with EACCES on a perfectly correctly-permissioned share. That is
    # not fatal here (ownership/mode were already set by 01 on the server
    # side); just warn instead of aborting under set -e.
    if chown oracle:oinstall "$NFS_MOUNT_PATH" 2>/dev/null || chown oracle:dba "$NFS_MOUNT_PATH" 2>/dev/null; then
        :
    else
        log_warn "chown oracle:oinstall $NFS_MOUNT_PATH failed (expected under root_squash - see nfs/01_setup_nfs_server.sh)"
    fi
    # 750 (not 775): the mount point IS the exported share directory, so a
    # wider mode here would silently undo the 750 set by
    # nfs/01_setup_nfs_server.sh for every client that mounts it. The share
    # holds password-file copies and generated configs - keep others out.
    if chmod 750 "$NFS_MOUNT_PATH" 2>/dev/null; then
        log_info "Permissions set for oracle user"
    else
        log_warn "chmod 750 $NFS_MOUNT_PATH failed (expected under root_squash - see nfs/01_setup_nfs_server.sh)"
        log_warn "Permissions were already set to 750 on the NFS server side; this is informational only"
    fi
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
