#!/bin/bash
# ==============================================================================
# install.sh: Automated installer for arch-freeze on Arch Linux
# Handles Btrfs Incus subvolume isolation, mkinitcpio hooks, UKI generation,
# and CLI utility installation.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="/var/backups/arch-freeze"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

msg() { echo -e "${GREEN}[+]${NC} ${BOLD}$*${NC}"; }
info() { echo -e "${BLUE}[*]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} ${BOLD}$*${NC}"; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# 1. Root Check
if [ "$(id -u)" -ne 0 ]; then
    err "This installation script must be run as root: sudo ./install.sh"
fi

echo -e "${BOLD}======================================================${NC}"
echo -e "${BOLD}         ARCH-FREEZE SYSTEM INSTALLATION              ${NC}"
echo -e "${BOLD}======================================================${NC}"

# 2. Pre-flight Checks
info "Checking system environment..."

# Verify Btrfs root
ROOT_FSTYPE="$(findmnt -no FSTYPE / 2>/dev/null || true)"
if [ "$ROOT_FSTYPE" != "btrfs" ]; then
    err "Root filesystem is '$ROOT_FSTYPE' (expected btrfs). arch-freeze is tailored for Btrfs systems."
fi

ROOT_DEV="$(findmnt -no SOURCE / 2>/dev/null | sed -E 's/\[.*\]//')"
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)"
if [ -z "$ROOT_UUID" ]; then
    err "Could not determine UUID for root device '$ROOT_DEV'"
fi
info "Root device: $ROOT_DEV (UUID: $ROOT_UUID)"

# Verify systemd-boot
if [ ! -d "/boot/EFI/systemd" ] && [ ! -f "/boot/EFI/Linux/arch-linux.efi" ]; then
    warn "Could not locate standard systemd-boot UKI directory in /boot/EFI/Linux."
    read -r -p "Continue anyway? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
fi

# 3. Create Backup Directory
mkdir -p "$BACKUP_DIR"
info "Created backup directory at $BACKUP_DIR"

# 4. Migrate Incus Storage to Dedicated Btrfs Subvolume
msg "Phase 1: Ensuring Incus persistent storage isolation..."

INCUS_MOUNTED="$(findmnt -no TARGET /var/lib/incus 2>/dev/null || true)"
if [ "$INCUS_MOUNTED" = "/var/lib/incus" ]; then
    info "/var/lib/incus is already mounted as a dedicated filesystem/subvolume. Skipping migration."
else
    info "Migrating /var/lib/incus to a dedicated persistent subvolume (/@incus)..."

    # Stop incus services
    systemctl stop incus.service incus.socket 2>/dev/null || true

    STAGING_MNT="/mnt/arch-freeze-btrfs-$TIMESTAMP"
    mkdir -p "$STAGING_MNT"
    mount -t btrfs -o subvolid=5 "$ROOT_DEV" "$STAGING_MNT"

    if [ ! -e "$STAGING_MNT/@incus" ]; then
        info "Creating Btrfs subvolume /@incus on $ROOT_DEV..."
        btrfs subvolume create "$STAGING_MNT/@incus"

        if [ -d "$STAGING_MNT/@/var/lib/incus" ]; then
            # If storage-pools/default is a subvolume, snapshot it
            if [ -e "$STAGING_MNT/@/var/lib/incus/storage-pools/default" ]; then
                mkdir -p "$STAGING_MNT/@incus/storage-pools"
                info "Snapshotting Incus default storage pool subvolume..."
                btrfs subvolume snapshot "$STAGING_MNT/@/var/lib/incus/storage-pools/default" "$STAGING_MNT/@incus/storage-pools/default"
            fi

            # Copy all remaining files (database, certificates, etc.)
            info "Copying Incus configuration and state files..."
            rsync -aHAX --exclude="storage-pools" "$STAGING_MNT/@/var/lib/incus/" "$STAGING_MNT/@incus/"
        fi
        chmod 0711 "$STAGING_MNT/@incus"
    fi

    umount "$STAGING_MNT"
    rmdir "$STAGING_MNT"

    # Backup /etc/fstab
    cp -p /etc/fstab "$BACKUP_DIR/fstab.bak.$TIMESTAMP"
    info "Backed up /etc/fstab -> $BACKUP_DIR/fstab.bak.$TIMESTAMP"

    # Add fstab entry
    if ! grep -q "subvol=/@incus" /etc/fstab; then
        cat <<EOF >> /etc/fstab

# Dedicated persistent storage for Incus (managed by arch-freeze)
UUID=${ROOT_UUID}	/var/lib/incus	btrfs	rw,relatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/@incus	0 0
EOF
        info "Added /var/lib/incus entry to /etc/fstab."
    fi

    # Mount /var/lib/incus
    mkdir -p /var/lib/incus
    mount /var/lib/incus
    info "Mounted /var/lib/incus successfully."

    # Enable and start Incus
    systemctl enable --now incus.socket
    info "Enabled and started incus.socket."
fi

# 5. Install mkinitcpio Hooks
msg "Phase 2: Installing mkinitcpio early userspace hook..."

cp -p "$SCRIPT_DIR/hooks/arch-freeze.install" /usr/lib/initcpio/install/arch-freeze
cp -p "$SCRIPT_DIR/hooks/arch-freeze.hook" /usr/lib/initcpio/hooks/arch-freeze
chmod 644 /usr/lib/initcpio/install/arch-freeze /usr/lib/initcpio/hooks/arch-freeze

# Backup mkinitcpio.conf
cp -p /etc/mkinitcpio.conf "$BACKUP_DIR/mkinitcpio.conf.bak.$TIMESTAMP"
info "Backed up /etc/mkinitcpio.conf -> $BACKUP_DIR/mkinitcpio.conf.bak.$TIMESTAMP"

# Add hook to mkinitcpio.conf if not present
if ! grep -q "arch-freeze" /etc/mkinitcpio.conf; then
    sed -i -E 's/\bfilesystems\b/filesystems arch-freeze/' /etc/mkinitcpio.conf
    info "Added 'arch-freeze' hook after 'filesystems' in /etc/mkinitcpio.conf."
fi

# 6. Configure UKI Presets
msg "Phase 3: Configuring Unified Kernel Image (UKI) presets..."

# Generate /etc/kernel/cmdline-frozen
if [ -f "/etc/kernel/cmdline" ]; then
    BASE_CMDLINE="$(cat /etc/kernel/cmdline | tr -d '\n' | sed 's/ *$//')"
    echo "$BASE_CMDLINE arch.frozen systemd.volatile=overlay" > /etc/kernel/cmdline-frozen
    info "Generated /etc/kernel/cmdline-frozen with volatile overlay flags."
else
    err "Could not find /etc/kernel/cmdline to generate frozen cmdline."
fi

# Backup preset file
PRESET_FILE="/etc/mkinitcpio.d/linux.preset"
if [ -f "$PRESET_FILE" ]; then
    cp -p "$PRESET_FILE" "$BACKUP_DIR/linux.preset.bak.$TIMESTAMP"
    info "Backed up $PRESET_FILE -> $BACKUP_DIR/linux.preset.bak.$TIMESTAMP"

    if ! grep -q "frozen" "$PRESET_FILE"; then
        # Update PRESETS array
        sed -i -E "s/PRESETS=\(([^)]*)\)/PRESETS=(\1 'frozen')/" "$PRESET_FILE"
        sed -i -E "s/PRESETS=\('default' 'frozen'\)/PRESETS=('default' 'frozen')/" "$PRESET_FILE"

        cat <<'EOF' >> "$PRESET_FILE"

# Frozen mode UKI configuration (managed by arch-freeze)
frozen_uki="/boot/EFI/Linux/arch-linux-frozen.efi"
frozen_options="--cmdline /etc/kernel/cmdline-frozen"
EOF
        info "Configured 'frozen' preset in $PRESET_FILE."
    fi
else
    err "Preset file $PRESET_FILE not found."
fi

# Build UKIs
msg "Building Unified Kernel Images (arch-linux.efi and arch-linux-frozen.efi)..."
mkinitcpio -p linux

# 7. Install CLI Binaries
msg "Phase 4: Installing arch-freeze CLI utilities..."

cp -p "$SCRIPT_DIR/bin/arch-freeze" /usr/local/bin/arch-freeze
chmod 755 /usr/local/bin/arch-freeze
ln -sf arch-freeze /usr/local/bin/arch-unfreeze
info "Installed /usr/local/bin/arch-freeze and /usr/local/bin/arch-unfreeze."

# 8. Set Bootloader Default to Normal
bootctl set-default arch-linux.efi 2>/dev/null || true
bootctl set-oneshot "" 2>/dev/null || true

echo ""
msg "Installation complete! Verifying system status..."
echo ""
/usr/local/bin/arch-freeze status
echo ""
info "To enter Frozen mode on next boot, run: arch-freeze"
info "To return to Normal mode, run:             arch-unfreeze"
info "To inspect system status anytime, run:     arch-freeze status"
