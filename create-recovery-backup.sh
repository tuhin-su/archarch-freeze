#!/bin/bash
# ==============================================================================
# create-recovery-backup.sh
# Creates a complete bare-metal restore image of this laptop onto a USB pendrive.
# Uses atomic Btrfs snapshots, saves partition tables & UUIDs, and generates
# an automated 1-command restore.sh script on the pendrive.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

msg()  { echo -e "${GREEN}[+]${NC} ${BOLD}$*${NC}"; }
info() { echo -e "${BLUE}[*]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} ${BOLD}$*${NC}"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# 1. Require Root
if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root: sudo ./create-recovery-backup.sh"
fi

echo -e "${BOLD}======================================================${NC}"
echo -e "${BOLD}       ARCH LINUX BARE-METAL RECOVERY BUILDER         ${NC}"
echo -e "${BOLD}======================================================${NC}"

# Source device definitions
SRC_DISK="/dev/nvme0n1"
SRC_BOOT_PART="/dev/nvme0n1p1"
SRC_BTRFS_PART="/dev/nvme0n1p2"

if [ ! -b "$SRC_DISK" ]; then
    err "Source disk $SRC_DISK not found!"
fi

BOOT_UUID="$(blkid -s UUID -o value "$SRC_BOOT_PART" 2>/dev/null || true)"
BTRFS_UUID="$(blkid -s UUID -o value "$SRC_BTRFS_PART" 2>/dev/null || true)"
BOOT_PARTUUID="$(blkid -s PARTUUID -o value "$SRC_BOOT_PART" 2>/dev/null || true)"
BTRFS_PARTUUID="$(blkid -s PARTUUID -o value "$SRC_BTRFS_PART" 2>/dev/null || true)"

info "Source Disk:           $SRC_DISK (Samsung 512GB NVMe)"
info "EFI Partition:         $SRC_BOOT_PART (UUID: $BOOT_UUID, PARTUUID: $BOOT_PARTUUID)"
info "Btrfs Root Partition:  $SRC_BTRFS_PART (UUID: $BTRFS_UUID, PARTUUID: $BTRFS_PARTUUID)"
echo ""

# 2. Select Target Backup Location
msg "Step 1: Select Target USB Drive / Partition"
echo -e "Available removable / USB storage devices:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT | grep -v "nvme0n1\|zram0" || true
echo ""

read -r -p "Enter the mount directory of your USB drive (e.g. /run/media/tuhin/USB or /mnt/usb): " TARGET_DIR

if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then
    err "Target directory '$TARGET_DIR' does not exist or is not mounted. Please mount your USB drive first."
fi

# Check free space on target
AVAIL_SPACE_KB=$(df -k "$TARGET_DIR" | awk 'NR==2{print $4}')
if [ "$AVAIL_SPACE_KB" -lt 10485760 ]; then # Less than 10 GB
    warn "Target has less than 10 GB free space ($(( AVAIL_SPACE_KB / 1024 / 1024 )) GB available). The backup might need ~6-10 GB."
    read -r -p "Continue anyway? [y/N]: " confirm_space
    [[ "$confirm_space" =~ ^[Yy]$ ]] || exit 0
fi

BACKUP_PATH="$TARGET_DIR/arch-recovery"
mkdir -p "$BACKUP_PATH"
info "Backup directory: $BACKUP_PATH"

# 3. Save Disk Partition Table
msg "Step 2: Exporting exact GPT Partition Table..."
sfdisk -d "$SRC_DISK" > "$BACKUP_PATH/partition_layout.sfdisk"
info "Saved partition table to $BACKUP_PATH/partition_layout.sfdisk"

# 4. Save /boot (EFI, UKIs, systemd-boot)
msg "Step 3: Backing up EFI & Boot partition (/boot)..."
tar -C /boot -czf "$BACKUP_PATH/boot_partition.tar.gz" .
info "Saved compressed /boot archive ($BACKUP_PATH/boot_partition.tar.gz)"

# 5. Take Atomic Read-Only Btrfs Snapshots and Stream
msg "Step 4: Creating atomic Btrfs subvolume snapshots..."
TMP_BTRFS_MNT="/mnt/btrfs-snap-$$"
mkdir -p "$TMP_BTRFS_MNT"
mount -t btrfs -o subvolid=5 "$SRC_BTRFS_PART" "$TMP_BTRFS_MNT"

cleanup() {
    info "Cleaning up temporary snapshots..."
    for s in @ @_backup_snap @home @_backup_home @incus @_backup_incus @log @_backup_log @pkg @_backup_pkg; do
        if [ -e "$TMP_BTRFS_MNT/${s}_backup_snap" ]; then
            btrfs subvolume delete "$TMP_BTRFS_MNT/${s}_backup_snap" 2>/dev/null || true
        fi
    done
    umount "$TMP_BTRFS_MNT" 2>/dev/null || true
    rmdir "$TMP_BTRFS_MNT" 2>/dev/null || true
}
trap cleanup EXIT

# List of subvolumes to backup
SUBVOLS=("@" "@home" "@incus" "@log" "@pkg")

for subvol in "${SUBVOLS[@]}"; do
    if [ -d "$TMP_BTRFS_MNT/$subvol" ]; then
        SNAP_NAME="${subvol}_backup_snap"
        
        if [ "$subvol" = "@" ]; then
            info "Creating clean snapshot for root (@) excluding /tmp and /var/tmp..."
            btrfs subvolume snapshot "$TMP_BTRFS_MNT/$subvol" "$TMP_BTRFS_MNT/$SNAP_NAME"
            # Ensure /tmp and /var/tmp are completely emptied inside the snapshot
            rm -rf "${TMP_BTRFS_MNT}/${SNAP_NAME}/tmp"/* 2>/dev/null || true
            rm -rf "${TMP_BTRFS_MNT}/${SNAP_NAME}/var/tmp"/* 2>/dev/null || true
            chmod 1777 "${TMP_BTRFS_MNT}/${SNAP_NAME}/tmp" "${TMP_BTRFS_MNT}/${SNAP_NAME}/var/tmp" 2>/dev/null || true
            # Set read-only property for btrfs send
            btrfs property set "$TMP_BTRFS_MNT/$SNAP_NAME" ro true
        else
            info "Creating read-only snapshot for $subvol -> $SNAP_NAME..."
            btrfs subvolume snapshot -r "$TMP_BTRFS_MNT/$subvol" "$TMP_BTRFS_MNT/$SNAP_NAME"
        fi

        OUT_FILE="$BACKUP_PATH/subvol_${subvol#@}.btrfs.zst"
        info "Streaming $subvol compressed with zstd to $OUT_FILE..."
        btrfs send "$TMP_BTRFS_MNT/$SNAP_NAME" | zstd -T0 -1 -o "$OUT_FILE"
    else
        warn "Subvolume $subvol does not exist in top-level Btrfs. Skipping."
    fi
done

# 6. Generate Automated restore.sh on the Pendrive
msg "Step 5: Generating 1-Click restore.sh script on the USB drive..."

cat <<EOF > "$BACKUP_PATH/restore.sh"
#!/bin/bash
# ==============================================================================
# Automated Bare-Metal Restore Script for Arch Linux
# Restores GPT layout, exact UUIDs, Btrfs subvolumes, and UEFI bootloader.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"

if [ "\$(id -u)" -ne 0 ]; then
    echo -e "\${RED}[ERROR]\${NC} Must be run as root: sudo ./restore.sh" >&2
    exit 1
fi

TARGET_DISK="/dev/nvme0n1"
TARGET_BOOT="\${TARGET_DISK}p1"
TARGET_BTRFS="\${TARGET_DISK}p2"

echo -e "\${RED}\${BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\${NC}"
echo -e "\${RED}\${BOLD}                          WARNING                             \${NC}"
echo -e "\${RED}\${BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\${NC}"
echo -e "This will \${BOLD}COMPLETELY WIPE AND RE-IMAGE\${NC}: \${BOLD}\$TARGET_DISK\${NC}"
echo -e "Target NVMe Drive: \$TARGET_DISK"
echo ""
read -r -p "Are you ABSOLUTELY sure you want to restore the backup to \$TARGET_DISK? [type 'RESTORE']: " confirm
if [ "\$confirm" != "RESTORE" ]; then
    echo "Restore aborted by user."
    exit 0
fi

echo ""
echo -e "\${GREEN}[+] 1. Restoring GPT Partition Table...\${NC}"
sfdisk "\$TARGET_DISK" < "\$SCRIPT_DIR/partition_layout.sfdisk"
partprobe "\$TARGET_DISK"
sleep 2

echo -e "\${GREEN}[+] 2. Formatting EFI Partition (\${TARGET_BOOT}) with exact UUID ($BOOT_UUID)...\${NC}"
mkfs.vfat -F 32 -i "$(echo "$BOOT_UUID" | tr -d '-')" "\$TARGET_BOOT"

echo -e "\${GREEN}[+] 3. Formatting Btrfs Partition (\${TARGET_BTRFS}) with exact UUID ($BTRFS_UUID)...\${NC}"
mkfs.btrfs -f -U "$BTRFS_UUID" "\$TARGET_BTRFS"

echo -e "\${GREEN}[+] 4. Restoring Btrfs Subvolumes...\${NC}"
RESTORE_MNT="/mnt/restore-\$\$"
mkdir -p "\$RESTORE_MNT"
mount -t btrfs -o subvolid=5 "\$TARGET_BTRFS" "\$RESTORE_MNT"

# Restore each subvolume
for subvol_file in "\$SCRIPT_DIR"/subvol_*.btrfs.zst; do
    [ -f "\$subvol_file" ] || continue
    name=\$(basename "\$subvol_file" .btrfs.zst | sed 's/subvol_//')
    target_subvol="@\$name"
    snap_name="\${target_subvol}_backup_snap"

    echo -e "    -> Receiving \$target_subvol..."
    zstd -dc "\$subvol_file" | btrfs receive "\$RESTORE_MNT/"

    # Make writable subvolume from snapshot
    btrfs subvolume snapshot "\$RESTORE_MNT/\$snap_name" "\$RESTORE_MNT/\$target_subvol"
    btrfs subvolume delete "\$RESTORE_MNT/\$snap_name"
done

echo -e "\${GREEN}[+] 5. Restoring /boot (EFI & UKIs)...\${NC}"
mkdir -p "\$RESTORE_MNT/@/boot"
mount "\$TARGET_BOOT" "\$RESTORE_MNT/@/boot"
tar -xzf "\$SCRIPT_DIR/boot_partition.tar.gz" -C "\$RESTORE_MNT/@/boot"

echo -e "\${GREEN}[+] 6. Ensuring /tmp and /var/tmp are empty with standard permissions (1777)...\${NC}"
mkdir -p "\$RESTORE_MNT/@/tmp" "\$RESTORE_MNT/@/var/tmp"
rm -rf "\$RESTORE_MNT/@/tmp"/* 2>/dev/null || true
rm -rf "\$RESTORE_MNT/@/var/tmp"/* 2>/dev/null || true
chmod 1777 "\$RESTORE_MNT/@/tmp" "\$RESTORE_MNT/@/var/tmp"

echo -e "\${GREEN}[+] 7. Registering UEFI Boot Entry...\${NC}"
if [ -d "/sys/firmware/efi/efivars" ]; then
    efibootmgr -c -d "\$TARGET_DISK" -p 1 -L "Linux Boot Manager" -l '\EFI\systemd\systemd-bootx64.efi' 2>/dev/null || true
fi

umount -R "\$RESTORE_MNT"
rmdir "\$RESTORE_MNT"

echo ""
echo -e "\${GREEN}\${BOLD}==============================================================\${NC}"
echo -e "\${GREEN}\${BOLD}       RESTORE COMPLETED SUCCESSFULLY!                        \${NC}"
echo -e "\${GREEN}\${BOLD}==============================================================\${NC}"
echo -e "You can now safely remove the USB drive and reboot your laptop:"
echo -e "    sudo reboot"
EOF

chmod +x "$BACKUP_PATH/restore.sh"

echo ""
echo -e "${GREEN}${BOLD}======================================================${NC}"
echo -e "${GREEN}${BOLD}       RECOVERY IMAGE CREATED SUCCESSFULLY!           ${NC}"
echo -e "${GREEN}${BOLD}======================================================${NC}"
info "All files written to: $BACKUP_PATH"
ls -lh "$BACKUP_PATH"
echo ""
msg "Summary of what was saved:"
echo "  1. Partition layout:     $BACKUP_PATH/partition_layout.sfdisk"
echo "  2. Boot partition:       $BACKUP_PATH/boot_partition.tar.gz"
echo "  3. Root subvolume:       $BACKUP_PATH/subvol_.btrfs.zst"
echo "  4. Home subvolume:       $BACKUP_PATH/subvol_home.btrfs.zst"
echo "  5. Incus subvolume:      $BACKUP_PATH/subvol_incus.btrfs.zst"
echo "  6. Log & Pkg subvolumes: $BACKUP_PATH/subvol_log.btrfs.zst & subvol_pkg.btrfs.zst"
echo "  7. 1-Click Restore tool: $BACKUP_PATH/restore.sh"
