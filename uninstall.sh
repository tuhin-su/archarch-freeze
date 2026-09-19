#!/bin/bash
# ==============================================================================
# uninstall.sh: Clean rollback uninstaller for arch-freeze
# Restores bootloader, mkinitcpio configurations, UKIs, and removes CLI binaries.
# ==============================================================================

set -euo pipefail

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

if [ "$(id -u)" -ne 0 ]; then
    err "This uninstaller script must be run as root: sudo ./uninstall.sh"
fi

echo -e "${BOLD}======================================================${NC}"
echo -e "${BOLD}         ARCH-FREEZE SYSTEM UNINSTALLATION            ${NC}"
echo -e "${BOLD}======================================================${NC}"

read -r -p "Are you sure you want to completely uninstall arch-freeze? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Uninstallation cancelled."
    exit 0
fi

# 1. Remove Binaries
info "Removing CLI binaries..."
rm -f /usr/local/bin/arch-freeze /usr/local/bin/arch-unfreeze

# 2. Revert Bootloader Default
info "Ensuring systemd-boot default is normal arch-linux.efi..."
bootctl set-default arch-linux.efi 2>/dev/null || true
bootctl set-oneshot "" 2>/dev/null || true

# 3. Remove Frozen UKI and Cmdline
info "Removing frozen UKI and cmdline..."
rm -f /boot/EFI/Linux/arch-linux-frozen.efi
rm -f /etc/kernel/cmdline-frozen

# 4. Clean mkinitcpio Hooks
info "Removing mkinitcpio hooks..."
rm -f /usr/lib/initcpio/hooks/arch-freeze /usr/lib/initcpio/install/arch-freeze

if grep -q "arch-freeze" /etc/mkinitcpio.conf; then
    sed -i -E 's/ *arch-freeze *//' /etc/mkinitcpio.conf
    info "Removed 'arch-freeze' hook from /etc/mkinitcpio.conf."
fi

# 5. Clean linux.preset
PRESET_FILE="/etc/mkinitcpio.d/linux.preset"
if [ -f "$PRESET_FILE" ]; then
    if grep -q "frozen" "$PRESET_FILE"; then
        # Revert PRESETS array
        sed -i -E "s/ 'frozen'//g; s/'frozen' //g" "$PRESET_FILE"
        sed -i '/# Frozen mode UKI configuration/,+2d' "$PRESET_FILE"
        info "Removed 'frozen' preset from $PRESET_FILE."
    fi
fi

# 6. Rebuild Normal UKI
msg "Rebuilding normal UKI with clean configuration..."
mkinitcpio -p linux

# 7. Incus Storage Question
echo ""
info "Note on Incus storage:"
info "Your Incus storage pool is currently safely mounted on persistent subvolume /@incus in /etc/fstab."
warn "Keeping /var/lib/incus mounted as a dedicated subvolume is safe, prevents nested Btrfs issues, and preserves VM/container data."
read -r -p "Keep persistent /@incus subvolume in /etc/fstab? [Y/n]: " keep_incus
if [[ "$keep_incus" =~ ^[Nn]$ ]]; then
    warn "Removing /var/lib/incus entry from /etc/fstab..."
    sed -i '/subvol=\/@incus/d' /etc/fstab
    info "Note: The subvolume /@incus still exists on disk to prevent accidental data loss."
fi

echo ""
msg "Uninstallation complete! The system is restored to its original boot configuration."
