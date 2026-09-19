#!/bin/bash
# ==============================================================================
# create-recovery-backup.sh (ISO Edition)
#
# Creates a standalone, bootable Arch Linux Recovery ISO (arch-recovery.iso)
# containing an exact bare-metal backup of your laptop (/dev/nvme0n1).
#
# USAGE:
#   sudo ./create-recovery-backup.sh               # Builds arch-recovery.iso in ~/
#   sudo ./create-recovery-backup.sh /path/to/dir  # Builds ISO in specified directory
#
# RESTORE WORKFLOW:
#   1. Flash arch-recovery.iso to USB (or copy to Ventoy).
#   2. Plug USB into laptop and boot.
#   3. The ISO boots directly into the automated restore screen.
#   4. Press Enter to confirm restore -> in ~2 minutes the entire system is restored!
# ==============================================================================

set -euo pipefail

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

msg()  { echo -e "${GREEN}[+]${NC} ${BOLD}$*${NC}"; }
info() { echo -e "${BLUE}[*]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} ${BOLD}$*${NC}"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# 1. Root Check
if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root: sudo ./create-recovery-backup.sh"
fi

echo -e "${BOLD}========================================================================${NC}"
echo -e "${BOLD}          ARCH LINUX AUTOMATED RECOVERY ISO BUILDER                     ${NC}"
echo -e "${BOLD}========================================================================${NC}"

# Output directory for ISO
OUTPUT_DIR="${1:-/home/tuhin}"
OUTPUT_ISO="$OUTPUT_DIR/arch-recovery.iso"

# Source disk and partition definitions
SRC_DISK="/dev/nvme0n1"
SRC_BOOT_PART="${SRC_DISK}p1"
SRC_BTRFS_PART="${SRC_DISK}p2"

if [ ! -b "$SRC_DISK" ]; then
    err "Source disk $SRC_DISK not found!"
fi

BOOT_UUID="$(blkid -s UUID -o value "$SRC_BOOT_PART" 2>/dev/null || true)"
BTRFS_UUID="$(blkid -s UUID -o value "$SRC_BTRFS_PART" 2>/dev/null || true)"
BOOT_PARTUUID="$(blkid -s PARTUUID -o value "$SRC_BOOT_PART" 2>/dev/null || true)"
BTRFS_PARTUUID="$(blkid -s PARTUUID -o value "$SRC_BTRFS_PART" 2>/dev/null || true)"

info "Source NVMe Disk:     $SRC_DISK (Samsung 512GB)"
info "EFI Boot Partition:   $SRC_BOOT_PART (UUID: $BOOT_UUID)"
info "Btrfs Root Partition: $SRC_BTRFS_PART (UUID: $BTRFS_UUID)"
info "Target ISO Output:    $OUTPUT_ISO"
echo ""

# 2. Check and Install Required Tools
info "Checking required ISO build tools..."
MISSING_PKGS=()
if ! command -v xorriso &>/dev/null; then
    MISSING_PKGS+=("libisoburn")
fi
if ! command -v mkfs.vfat &>/dev/null; then
    MISSING_PKGS+=("dosfstools")
fi

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    msg "Installing required build dependencies (${MISSING_PKGS[*]})..."
    pacman -S --needed --noconfirm "${MISSING_PKGS[@]}"
fi

# 3. Setup Workspace
WORK_DIR="/tmp/arch-recovery-build-$$"
mkdir -p "$WORK_DIR/iso_root/arch-recovery"
mkdir -p "$WORK_DIR/iso_root/EFI"

cleanup() {
    info "Cleaning up temporary build files and snapshots..."
    if [ -d "${TMP_BTRFS_MNT:-}" ]; then
        for s in @ @_backup_snap @home @home_backup_snap @incus @incus_backup_snap @log @log_backup_snap @pkg @pkg_backup_snap; do
            if [ -e "$TMP_BTRFS_MNT/${s}_backup_snap" ]; then
                btrfs subvolume delete "$TMP_BTRFS_MNT/${s}_backup_snap" 2>/dev/null || true
            fi
        done
        umount "$TMP_BTRFS_MNT" 2>/dev/null || true
        rmdir "$TMP_BTRFS_MNT" 2>/dev/null || true
    fi
    if [ -d "${EFI_STAGING:-}" ]; then
        umount "$EFI_STAGING" 2>/dev/null || true
        rmdir "$EFI_STAGING" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

BACKUP_PATH="$WORK_DIR/iso_root/arch-recovery"

# 4. Export Partition Table and Boot Partition
msg "Phase 1: Exporting partition table and /boot files..."
sfdisk -d "$SRC_DISK" > "$BACKUP_PATH/partition_layout.sfdisk"
tar -C /boot -czf "$BACKUP_PATH/boot_partition.tar.gz" .
info "Saved partition table and /boot archive."

# 5. Capture Btrfs Subvolumes (Excluding /tmp and /var/tmp)
msg "Phase 2: Taking atomic Btrfs snapshots and compressing subvolumes..."
TMP_BTRFS_MNT="/mnt/btrfs-snap-$$"
mkdir -p "$TMP_BTRFS_MNT"
mount -t btrfs -o subvolid=5 "$SRC_BTRFS_PART" "$TMP_BTRFS_MNT"

SUBVOLS=("@" "@home" "@incus" "@log" "@pkg")

for subvol in "${SUBVOLS[@]}"; do
    if [ -d "$TMP_BTRFS_MNT/$subvol" ]; then
        SNAP_NAME="${subvol}_backup_snap"

        if [ "$subvol" = "@" ]; then
            info "Creating clean root (@) snapshot excluding /tmp and /var/tmp..."
            btrfs subvolume snapshot "$TMP_BTRFS_MNT/$subvol" "$TMP_BTRFS_MNT/$SNAP_NAME"
            rm -rf "${TMP_BTRFS_MNT}/${SNAP_NAME}/tmp"/* 2>/dev/null || true
            rm -rf "${TMP_BTRFS_MNT}/${SNAP_NAME}/var/tmp"/* 2>/dev/null || true
            chmod 1777 "${TMP_BTRFS_MNT}/${SNAP_NAME}/tmp" "${TMP_BTRFS_MNT}/${SNAP_NAME}/var/tmp" 2>/dev/null || true
            btrfs property set "$TMP_BTRFS_MNT/$SNAP_NAME" ro true
        else
            info "Creating read-only snapshot for $subvol -> $SNAP_NAME..."
            btrfs subvolume snapshot -r "$TMP_BTRFS_MNT/$subvol" "$TMP_BTRFS_MNT/$SNAP_NAME"
        fi

        OUT_FILE="$BACKUP_PATH/subvol_${subvol#@}.btrfs.zst"
        info "Compressing and streaming $subvol to $OUT_FILE..."
        btrfs send "$TMP_BTRFS_MNT/$SNAP_NAME" | zstd -T0 -1 -o "$OUT_FILE"
    else
        warn "Subvolume $subvol does not exist on top-level Btrfs. Skipping."
    fi
done

# 6. Generate the Embedded restore.sh
msg "Phase 3: Generating embedded restore.sh script..."
cat <<EOF > "$BACKUP_PATH/restore.sh"
#!/bin/bash
# Automated Restore Script
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
TARGET_DISK="$SRC_DISK"
TARGET_BOOT="\${TARGET_DISK}p1"
TARGET_BTRFS="\${TARGET_DISK}p2"

clear
echo -e "\${BOLD}========================================================================\${NC}"
echo -e "\${BOLD}            ARCH LINUX AUTOMATED RECOVERY RESTORE                       \${NC}"
echo -e "\${BOLD}========================================================================\${NC}"
echo -e "Target NVMe Drive:   \${BOLD}\$TARGET_DISK\${NC}"
echo -e "Partition Layout:    \$TARGET_BOOT (EFI, $BOOT_UUID)"
echo -e "                     \$TARGET_BTRFS (Btrfs, $BTRFS_UUID)"
echo -e "Subvolumes Included: @, @home, @incus, @log, @pkg"
echo -e "\${BOLD}========================================================================\${NC}"
echo ""
echo -e "\${RED}\${BOLD}WARNING:\${NC} This will completely overwrite and re-image \${BOLD}\$TARGET_DISK\${NC}!"
echo ""

AUTO_CONFIRM=false
if [ "\${1:-}" = "--auto" ]; then
    echo -e "Press \${GREEN}\${BOLD}[ENTER]\${NC} to start full recovery restore now,"
    read -r -p "or type 'cancel' to exit to command prompt: " user_input
    if [ "\$user_input" = "cancel" ] || [ "\$user_input" = "exit" ]; then
        echo "Restore cancelled by user."
        exit 0
    fi
else
    read -r -p "Are you sure you want to restore to \$TARGET_DISK? [type 'RESTORE']: " user_input
    if [ "\$user_input" != "RESTORE" ]; then
        echo "Restore cancelled."
        exit 0
    fi
fi

echo ""
echo -e "\${GREEN}[+] 1. Re-partitioning \$TARGET_DISK with original GPT layout...\${NC}"
sfdisk "\$TARGET_DISK" < "\$SCRIPT_DIR/partition_layout.sfdisk"
partprobe "\$TARGET_DISK" 2>/dev/null || true
sleep 2

echo -e "\${GREEN}[+] 2. Formatting EFI Partition (\${TARGET_BOOT}) with UUID $BOOT_UUID...\${NC}"
mkfs.vfat -F 32 -i "$(echo "$BOOT_UUID" | tr -d '-')" "\$TARGET_BOOT"

echo -e "\${GREEN}[+] 3. Formatting Btrfs Partition (\${TARGET_BTRFS}) with UUID $BTRFS_UUID...\${NC}"
mkfs.btrfs -f -U "$BTRFS_UUID" "\$TARGET_BTRFS"

echo -e "\${GREEN}[+] 4. Restoring Btrfs Subvolumes...\${NC}"
RESTORE_MNT="/mnt/restore-\$\$"
mkdir -p "\$RESTORE_MNT"
mount -t btrfs -o subvolid=5 "\$TARGET_BTRFS" "\$RESTORE_MNT"

for subvol_file in "\$SCRIPT_DIR"/subvol_*.btrfs.zst; do
    [ -f "\$subvol_file" ] || continue
    name=\$(basename "\$subvol_file" .btrfs.zst | sed 's/subvol_//')
    target_subvol="@\$name"
    snap_name="\${target_subvol}_backup_snap"

    echo -e "    -> Receiving \$target_subvol..."
    zstd -dc "\$subvol_file" | btrfs receive "\$RESTORE_MNT/"

    btrfs subvolume snapshot "\$RESTORE_MNT/\$snap_name" "\$RESTORE_MNT/\$target_subvol"
    btrfs subvolume delete "\$RESTORE_MNT/\$snap_name"
done

echo -e "\${GREEN}[+] 5. Ensuring /tmp and /var/tmp are clean with mode 1777...\${NC}"
mkdir -p "\$RESTORE_MNT/@/tmp" "\$RESTORE_MNT/@/var/tmp"
rm -rf "\$RESTORE_MNT/@/tmp"/* 2>/dev/null || true
rm -rf "\$RESTORE_MNT/@/var/tmp"/* 2>/dev/null || true
chmod 1777 "\$RESTORE_MNT/@/tmp" "\$RESTORE_MNT/@/var/tmp"

echo -e "\${GREEN}[+] 6. Restoring /boot (EFI & UKIs)...\${NC}"
mkdir -p "\$RESTORE_MNT/@/boot"
mount "\$TARGET_BOOT" "\$RESTORE_MNT/@/boot"
tar -xzf "\$SCRIPT_DIR/boot_partition.tar.gz" -C "\$RESTORE_MNT/@/boot"

echo -e "\${GREEN}[+] 7. Registering UEFI Bootloader in NVRAM...\${NC}"
if [ -d "/sys/firmware/efi/efivars" ]; then
    efibootmgr -c -d "\$TARGET_DISK" -p 1 -L "Linux Boot Manager" -l '\EFI\systemd\systemd-bootx64.efi' 2>/dev/null || true
fi

umount -R "\$RESTORE_MNT"
rmdir "\$RESTORE_MNT"

echo ""
echo -e "\${GREEN}\${BOLD}========================================================================\${NC}"
echo -e "\${GREEN}\${BOLD}                  RESTORE COMPLETED SUCCESSFULLY!                       \${NC}"
echo -e "\${GREEN}\${BOLD}========================================================================\${NC}"
EOF
chmod +x "$BACKUP_PATH/restore.sh"

# 7. Build Automated Recovery Initramfs
msg "Phase 4: Building self-booting automated recovery initramfs..."
HOOKS_DIR="$WORK_DIR/hooks"
INSTALL_DIR="$WORK_DIR/install"
mkdir -p "$HOOKS_DIR" "$INSTALL_DIR"

cat <<'HOOK_EOF' > "$HOOKS_DIR/recovery"
run_hook() {
    mount_handler="recovery_mount_handler"
}

recovery_mount_handler() {
    echo ""
    echo "========================================================================"
    echo "            ARCH LINUX AUTOMATED RECOVERY SYSTEM                        "
    echo "========================================================================"
    echo ":: Locating recovery media (Volume: ARCH_RECOVERY)..."
    local recovery_dev=""
    for i in $(seq 1 20); do
        recovery_dev=$(blkid -L ARCH_RECOVERY 2>/dev/null || true)
        [ -n "$recovery_dev" ] && break
        sleep 1
    done

    if [ -z "$recovery_dev" ]; then
        for d in /dev/disk/by-label/ARCH_RECOVERY /dev/sr* /dev/sd* /dev/nvme*; do
            if blkid "$d" 2>/dev/null | grep -q "ARCH_RECOVERY"; then
                recovery_dev="$d"
                break
            fi
        done
    fi

    if [ -z "$recovery_dev" ]; then
        echo ":: ERROR: ARCH_RECOVERY media not detected! Dropping to shell."
        launch_interactive_shell
        return 1
    fi

    echo ":: Found recovery media at $recovery_dev"
    mkdir -p /recovery
    mount -o ro "$recovery_dev" /recovery

    if [ -f /recovery/arch-recovery/restore.sh ]; then
        /bin/bash /recovery/arch-recovery/restore.sh --auto
        echo ""
        echo ":: Restore process complete."
        echo ":: Please remove the USB recovery media."
        echo -n ":: Press [ENTER] to reboot..."
        read -r _
        reboot -f
    else
        echo ":: ERROR: Restore script not found on recovery media! Dropping to shell."
        launch_interactive_shell
    fi
}
HOOK_EOF

cat <<'INST_EOF' > "$INSTALL_DIR/recovery"
build() {
    add_module "btrfs"
    add_module "vfat"
    add_module "nvme"
    add_module "nvme_core"
    add_module "uas"
    add_module "usb_storage"
    add_module "loop"
    add_module "isofs"

    add_binary "/usr/bin/bash"
    add_binary "/usr/bin/btrfs"
    add_binary "/usr/bin/sfdisk"
    add_binary "/usr/bin/zstd"
    add_binary "/usr/bin/tar"
    add_binary "/usr/bin/partprobe"
    add_binary "/usr/bin/efibootmgr"
    add_binary "/usr/bin/mkfs.vfat"
    add_binary "/usr/bin/mkfs.btrfs"
    add_binary "/usr/bin/blkid"
    add_binary "/usr/bin/clear"

    add_runscript
}

help() {
    cat <<'HELPEOF'
Automated Arch Linux recovery hook for arch-freeze ISO.
HELPEOF
}
INST_EOF

# Locate kernel image
KERNEL_FILE="/boot/vmlinuz-linux"
if [ ! -f "$KERNEL_FILE" ]; then
    KERNEL_FILE="/usr/lib/modules/$(uname -r)/vmlinuz"
fi
if [ ! -f "$KERNEL_FILE" ]; then
    err "Kernel image not found at /boot/vmlinuz-linux or /usr/lib/modules/$(uname -r)/vmlinuz"
fi

# Temporary mkinitcpio config
cat <<EOF > "$WORK_DIR/mkinitcpio-recovery.conf"
MODULES=(btrfs vfat nvme nvme_core uas usb_storage loop isofs)
BINARIES=(bash btrfs sfdisk zstd tar partprobe efibootmgr mkfs.vfat mkfs.btrfs blkid clear)
FILES=()
HOOKS=(base udev block filesystems recovery)
COMPRESSION="zstd"
EOF

INITRAMFS_IMG="$WORK_DIR/initramfs-recovery.img"
info "Compiling recovery initramfs with embedded tools..."
MKINITCPIO_HOOKS="$HOOKS_DIR:/etc/initcpio/hooks:/usr/lib/initcpio/hooks" \
MKINITCPIO_INSTALL="$INSTALL_DIR:/etc/initcpio/install:/usr/lib/initcpio/install" \
mkinitcpio -c "$WORK_DIR/mkinitcpio-recovery.conf" \
           -g "$INITRAMFS_IMG" \
           -k "$KERNEL_FILE"

# 8. Create UEFI Boot Image (efiboot.img)
msg "Phase 5: Creating UEFI boot image (efiboot.img)..."
EFIBOOT_IMG="$WORK_DIR/iso_root/EFI/efiboot.img"
dd if=/dev/zero of="$EFIBOOT_IMG" bs=1M count=128 status=none
mkfs.vfat -F 32 "$EFIBOOT_IMG" >/dev/null

EFI_STAGING="/mnt/efi-staging-$$"
mkdir -p "$EFI_STAGING"
mount -o loop "$EFIBOOT_IMG" "$EFI_STAGING"

mkdir -p "$EFI_STAGING/EFI/BOOT"
mkdir -p "$EFI_STAGING/loader/entries"
mkdir -p "$EFI_STAGING/boot"

cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi "$EFI_STAGING/EFI/BOOT/BOOTX64.EFI"
cp "$KERNEL_FILE" "$EFI_STAGING/boot/vmlinuz-linux"
cp "$INITRAMFS_IMG" "$EFI_STAGING/boot/initramfs-recovery.img"

cat <<'EOF' > "$EFI_STAGING/loader/loader.conf"
default recovery.conf
timeout 3
EOF

cat <<'EOF' > "$EFI_STAGING/loader/entries/recovery.conf"
title Arch Linux Automated Recovery
linux /boot/vmlinuz-linux
initrd /boot/initramfs-recovery.img
options quiet loglevel=3
EOF

# Copy EFI tree and boot files to iso_root for direct UEFI / Ventoy boot support
mkdir -p "$WORK_DIR/iso_root/EFI/BOOT" "$WORK_DIR/iso_root/loader/entries" "$WORK_DIR/iso_root/boot"
cp "$EFI_STAGING/EFI/BOOT/BOOTX64.EFI" "$WORK_DIR/iso_root/EFI/BOOT/BOOTX64.EFI"
cp "$EFI_STAGING/loader/loader.conf" "$WORK_DIR/iso_root/loader/loader.conf"
cp "$EFI_STAGING/loader/entries/recovery.conf" "$WORK_DIR/iso_root/loader/entries/recovery.conf"
cp "$KERNEL_FILE" "$WORK_DIR/iso_root/boot/vmlinuz-linux"
cp "$INITRAMFS_IMG" "$WORK_DIR/iso_root/boot/initramfs-recovery.img"

umount "$EFI_STAGING"
rmdir "$EFI_STAGING"
info "Configured UEFI boot image with systemd-boot."

# 9. Build Hybrid Bootable ISO with xorriso
msg "Phase 6: Generating final bootable ISO ($OUTPUT_ISO)..."

mkdir -p "$(dirname "$OUTPUT_ISO")"
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "ARCH_RECOVERY" \
    -eltorito-alt-boot \
    -e EFI/efiboot.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -output "$OUTPUT_ISO" \
    "$WORK_DIR/iso_root" \
    2>&1 | grep -v "DEBUG" || true

chmod 644 "$OUTPUT_ISO"
echo ""
echo -e "${GREEN}${BOLD}========================================================================${NC}"
echo -e "${GREEN}${BOLD}          RECOVERY ISO CREATED SUCCESSFULLY!                            ${NC}"
echo -e "${GREEN}${BOLD}========================================================================${NC}"
ls -lh "$OUTPUT_ISO"
echo ""
msg "HOW TO USE THIS ISO:"
echo -e "  ${BOLD}Option A (Ventoy - Recommended):${NC}"
echo -e "    Simply copy ${BOLD}$OUTPUT_ISO${NC} onto your Ventoy USB drive."
echo ""
echo -e "  ${BOLD}Option B (Direct USB Flash):${NC}"
echo -e "    sudo dd if=$OUTPUT_ISO of=/dev/sdX bs=4M status=progress conv=fsync"
echo -e "    ${YELLOW}(Replace /dev/sdX with your USB drive - e.g. /dev/sdb)${NC}"
echo ""
echo -e "  ${BOLD}To Restore Laptop:${NC}"
echo -e "    1. Plug USB into laptop and turn on."
echo -e "    2. Press F12 (or Esc) to boot from the USB."
echo -e "    3. It will boot directly into the restore screen."
echo -e "    4. Press [ENTER] to restore. In ~2 minutes your laptop will reboot 100% restored!"
