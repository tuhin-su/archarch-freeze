# arch-freeze: Ephemeral Immutable Root System for Arch Linux

`arch-freeze` is a fast, safe, native terminal-based utility that adds an on-demand **Frozen (Immutable / Ephemeral)** boot mode to Arch Linux while keeping personal data, system logs, and Incus VMs/containers fully persistent and operational.

---

## Table of Contents
- [How It Works](#how-it-works)
- [What is Persistent vs Temporary](#what-is-persistent-vs-temporary)
- [How Incus is Affected](#how-incus-is-affected)
- [Installation](#installation)
- [Usage & Commands](#usage--commands)
- [How to Enter Normal/Admin Mode](#how-to-enter-normaladmin-mode)
- [Emergency Recovery (If Boot Fails)](#emergency-recovery-if-boot-fails)
- [Uninstallation](#uninstallation)

---

## How It Works

`arch-freeze` uses Linux **OverlayFS** in early userspace (`mkinitcpio`) alongside **systemd-boot Unified Kernel Images (UKIs)**:

1. **Dual Boot Entries:**
   * **`Arch Linux` (Normal Mode):** Boots directly into the real root Btrfs subvolume (`/@`) in read-write mode. This is the administration mode where package updates (`pacman -Syu`) and system configurations persist.
   * **`Arch Linux (Frozen)` (Frozen Mode):** Passes `arch.frozen` and `systemd.volatile=overlay` on the kernel command line. In early userspace, the real root subvolume is remounted **read-only**, and an **OverlayFS** backed by an in-memory `tmpfs` (RAM) is mounted over `/`.
2. **Zero Disk Modification in Frozen Mode:**
   * Any file written to `/` (such as installing packages with `pacman`, editing files in `/etc`, modifying `/usr`, or temporary OS files) is written only to RAM.
   * Upon reboot, the RAM is cleared, returning the OS immediately to its clean state.
3. **No Heavyweight Daemons:**
   * Uses native Linux kernel OverlayFS and early initramfs hooks. No background daemons, no virtualization overhead, and 100% native CPU/GPU performance.

---

## What is Persistent vs Temporary

| Directory / Target | Filesystem Type | Storage Mode in Frozen Mode | Notes |
| :--- | :--- | :--- | :--- |
| **`/` (Root OS, `/etc`, `/usr`, etc.)** | OverlayFS (`tmpfs` upper) | **TEMPORARY (RAM)** | Disappears completely upon reboot |
| **`/home`** | Btrfs (`/@home`) | **PERSISTENT** | All personal files, dotfiles, browser data persist |
| **`/var/log`** | Btrfs (`/@log`) | **PERSISTENT** | Systemd journal and service logs persist |
| **`/var/cache/pacman/pkg`** | Btrfs (`/@pkg`) | **PERSISTENT** | Pacman package cache persists |
| **`/var/lib/incus`** | Btrfs (`/@incus`) | **PERSISTENT** | All Incus VMs, containers, and disks persist |
| **`/boot`** | vfat (FAT32) | **PERSISTENT** | Bootloader configuration and UKIs persist |

---

## How Incus is Affected

This machine is an **Incus VM server**. OverlayFS does not support Btrfs subvolume/snapshot ioctls, and any files written into a volatile overlay would be destroyed upon reboot.

To guarantee zero downtime and 100% data preservation:
1. `install.sh` safely isolates `/var/lib/incus` into its own dedicated Btrfs subvolume (`/@incus`).
2. An entry is added to `/etc/fstab` mounting `subvol=/@incus` to `/var/lib/incus`.
3. Because systemd mounts `/etc/fstab` entries on top of the root overlay:
   * `/var/lib/incus` is mounted directly from Btrfs, completely bypassing the OverlayFS.
   * Native Btrfs snapshotting, subvolume creation, and block device operations remain 100% functional.
   * All Incus containers, VMs, and storage pools survive reboots in both Normal and Frozen modes.
   * Existing instances and storage pools are preserved with zero data loss.

---

## Installation

Run the automated installer script with `sudo`:

```bash
cd ~/arch-freeze
sudo ./install.sh
```

### What the installer does:
1. Performs non-destructive pre-flight checks (verifies Btrfs root and systemd-boot).
2. Creates backups of `/etc/fstab`, `/etc/mkinitcpio.conf`, and `/etc/mkinitcpio.d/linux.preset` in `/var/backups/arch-freeze/`.
3. Migrates `/var/lib/incus` to a dedicated Btrfs subvolume (`/@incus`) and registers it in `/etc/fstab`.
4. Installs the `arch-freeze` hook into `/usr/lib/initcpio/`.
5. Configures the `frozen` preset in `/etc/mkinitcpio.d/linux.preset` and builds `arch-linux-frozen.efi`.
6. Installs `/usr/local/bin/arch-freeze` and creates the `/usr/local/bin/arch-unfreeze` symlink.

---

## Usage & Commands

### 1. Check System Status
Can be run by any regular user or root:
```bash
arch-freeze status
```
Displays:
* Current running mode (`NORMAL` or `FROZEN`)
* Next boot mode (`NORMAL` or `FROZEN`)
* Root filesystem mount and subvolume
* Overlay status (shows RAM tmpfs usage if active)
* `/home` persistence status
* Incus storage location and persistence status

### 2. Enter Frozen Mode (Immutable OS)
To set the next boot into Frozen mode:
```bash
arch-freeze
```
* Sets a one-shot boot entry for `arch-linux-frozen.efi` using `bootctl`.
* Prompts for confirmation before setting.
* Optionally offers to reboot immediately.
* *To make Frozen mode default permanently:* `arch-freeze --permanent`

### 3. Enter Normal / Admin Mode (Writable OS)
To set the next boot into Normal mode for administrative tasks:
```bash
arch-unfreeze
```
* Clears the one-shot entry and ensures the default is `arch-linux.efi`.
* Prompts for confirmation and offers immediate reboot.

### 4. Dry Run Mode
To test what actions would be executed without touching EFI variables or bootloader settings:
```bash
arch-freeze --dry-run
arch-unfreeze --dry-run
```

---

## How to Enter Normal/Admin Mode

When your system is in **Frozen mode** and you need to install software or apply updates:
1. Open a terminal and run:
   ```bash
   arch-unfreeze
   ```
2. Confirm the prompt and reboot.
3. You will boot into **Normal mode** (writable root).
4. Run your system updates or package installations:
   ```bash
   sudo pacman -Syu
   ```
5. When finished, re-enter Frozen mode:
   ```bash
   arch-freeze
   ```
6. Reboot to return to your protected, immutable session.

---

## Emergency Recovery (If Boot Fails)

Because `arch-freeze` uses systemd-boot with separate UKIs, recovering is simple and requires no rescue USB:

1. **Via the Boot Menu:**
   * Reboot your computer and press or hold <kbd>Space</kbd>, <kbd>Esc</kbd>, or <kbd>F12</kbd> at the BIOS splash screen to view the `systemd-boot` menu.
   * Select **`Arch Linux`** (which boots the untouched, original `arch-linux.efi`).
2. **Clear One-Shot Boot from Live Terminal:**
   ```bash
   sudo bootctl set-default arch-linux.efi
   sudo bootctl set-oneshot ""
   ```
3. **If the Frozen UKI fails to mount overlay:**
   * The initramfs hook contains an automatic fallback mechanism: if OverlayFS fails to initialize, it immediately unmounts the tmpfs, restores `/sysroot`, and falls back to booting the normal writable system.

---

## Uninstallation

To completely remove `arch-freeze` and restore your system to its exact original state:

```bash
cd ~/arch-freeze
sudo ./uninstall.sh
```

### What the uninstaller does:
1. Removes `/usr/local/bin/arch-freeze` and `/usr/local/bin/arch-unfreeze`.
2. Sets default bootloader entry back to `arch-linux.efi`.
3. Removes `/boot/EFI/Linux/arch-linux-frozen.efi` and `/etc/kernel/cmdline-frozen`.
4. Removes the `arch-freeze` hook from `/etc/mkinitcpio.conf`.
5. Removes the `frozen` preset from `/etc/mkinitcpio.d/linux.preset`.
6. Rebuilds `arch-linux.efi` so no unused hooks remain in the initramfs.
7. Prompts whether to keep the persistent `/@incus` subvolume in `/etc/fstab` (recommended to preserve your VMs/containers).
