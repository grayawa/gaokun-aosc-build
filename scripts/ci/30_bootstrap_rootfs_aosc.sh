#!/usr/bin/env bash
set -euo pipefail

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${ROOTFS_DIR:?missing ROOTFS_DIR}"
: "${KERN_SRC:?missing KERN_SRC}"
: "${KERN_OUT:?missing KERN_OUT}"

AOSC_SNAPSHOT="${AOSC_SNAPSHOT:-latest}"
DESKTOP_URL="${AOSC_DESKTOP_URL:-https://releases.aosc.io/os-arm64/desktop}"

mkdir -p "$WORKDIR"
# Recover cleanly from a previously interrupted image build.
if [[ -s "$WORKDIR/loop-device.txt" ]]; then
  old_loop="$(cat "$WORKDIR/loop-device.txt")"
  sudo umount -lf "$ROOTFS_DIR" 2>/dev/null || true
  sudo losetup -d "$old_loop" 2>/dev/null || true
  rm -f "$WORKDIR/loop-device.txt"
fi
sudo rm -rf "$ROOTFS_DIR"
sudo mkdir -p "$ROOTFS_DIR"

LOOP=""
cleanup_failed_image() {
  local status=$?
  if (( status != 0 )); then
    set +e
    for target in "$ROOTFS_DIR/boot/efi" "$ROOTFS_DIR/run" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/dev" "$ROOTFS_DIR"; do
      sudo umount -lf "$target" 2>/dev/null || true
    done
    if [[ -n "$LOOP" ]]; then
      sudo losetup -d "$LOOP" 2>/dev/null || true
    fi
  fi
}
trap cleanup_failed_image EXIT

if [[ "$AOSC_SNAPSHOT" == "latest" ]]; then
  index_html="$(curl -fsSL "$DESKTOP_URL/")"
  archive_name="$(
    printf '%s\n' "$index_html" |
      grep -oE 'aosc-os_desktop_[0-9]{8}_arm64\.tar\.xz' |
      sort -V |
      tail -n 1
  )"
  if [[ -z "$archive_name" ]]; then
    echo "Could not discover an ARM64 AOSC Desktop tarball at $DESKTOP_URL" >&2
    exit 1
  fi
else
  [[ "$AOSC_SNAPSHOT" =~ ^[0-9]{8}$ ]] || {
    echo "AOSC_SNAPSHOT must be latest or YYYYMMDD" >&2
    exit 2
  }
  archive_name="aosc-os_desktop_${AOSC_SNAPSHOT}_arm64.tar.xz"
fi

snapshot="${archive_name#aosc-os_desktop_}"
snapshot="${snapshot%_arm64.tar.xz}"
archive_path="$WORKDIR/$archive_name"
checksum_path="$archive_path.sha256sum"

IMAGE_SIZE="${IMAGE_SIZE:?missing IMAGE_SIZE}"
[[ "$IMAGE_SIZE" =~ ^[1-9][0-9]*G$ ]] || {
  echo "IMAGE_SIZE must be an integer number of GiB, for example 24G" >&2
  exit 2
}
IMAGE_FILE="$WORKDIR/aosc-desktop-$snapshot-gaokun3.img"
EFI_END_MIB=1025

# Build directly into the final image's root partition. This avoids holding
# both a full staging rootfs and a second copy inside the raw image.
rm -f "$IMAGE_FILE"
truncate -s "$IMAGE_SIZE" "$IMAGE_FILE"
parted -s "$IMAGE_FILE" mklabel gpt
parted -s "$IMAGE_FILE" mkpart EFI fat32 1MiB "${EFI_END_MIB}MiB"
parted -s "$IMAGE_FILE" set 1 esp on
parted -s "$IMAGE_FILE" mkpart rootfs ext4 "${EFI_END_MIB}MiB" 100%

LOOP="$(sudo losetup --show -fP "$IMAGE_FILE")"
echo "$LOOP" > "$WORKDIR/loop-device.txt"
sudo mkfs.vfat -F32 -n EFI "${LOOP}p1"
sudo mkfs.ext4 -F -L rootfs "${LOOP}p2"
sudo blkid -s UUID -o value "${LOOP}p1" > "$WORKDIR/efi-uuid.txt"
sudo blkid -s UUID -o value "${LOOP}p2" > "$WORKDIR/root-uuid.txt"
sudo mount "${LOOP}p2" "$ROOTFS_DIR"

echo "Using AOSC Desktop snapshot: $snapshot"
curl -fL --retry 3 --retry-delay 2 "$DESKTOP_URL/$archive_name" -o "$archive_path"
curl -fL --retry 3 --retry-delay 2 "$DESKTOP_URL/$archive_name.sha256sum" -o "$checksum_path"
(
  cd "$WORKDIR"
  sha256sum -c "$(basename "$checksum_path")"
)

# AOSC rootfs tarballs are unpacked directly at the target root. Preserve
# numeric ownership, ACLs and extended attributes; do not strip path components.
sudo tar -xJpf "$archive_path" \
  -C "$ROOTFS_DIR" \
  --numeric-owner \
  --xattrs \
  --acls
# Free the compressed source before package installation and image finalization.
rm -f "$archive_path" "$checksum_path"

if ! grep -Eq '^ID="?aosc"?
  echo "The downloaded archive does not look like an AOSC OS rootfs." >&2
  exit 1
fi

KREL="$(cat "$WORKDIR/kernel-release.txt")"
DTB_NAME="sc8280xp-huawei-gaokun3.dtb"
DTB_SOURCE="$KERN_OUT/arch/arm64/boot/dts/qcom/$DTB_NAME"
IMAGE_SOURCE="$KERN_OUT/arch/arm64/boot/Image"
test -s "$IMAGE_SOURCE"
test -s "$DTB_SOURCE"

RESOLV_SAVED="$WORKDIR/rootfs-resolv.conf.saved"
POLICY_SAVED="$WORKDIR/rootfs-policy-rc.d.saved"
RESOLV_PRESENT=false
POLICY_PRESENT=false

cleanup_chroot() {
  set +e
  if [[ "$RESOLV_PRESENT" == "true" ]]; then
    sudo rm -f "$ROOTFS_DIR/etc/resolv.conf"
    sudo cp -a "$RESOLV_SAVED" "$ROOTFS_DIR/etc/resolv.conf"
  else
    sudo rm -f "$ROOTFS_DIR/etc/resolv.conf"
  fi
  if [[ "$POLICY_PRESENT" == "true" ]]; then
    sudo rm -f "$ROOTFS_DIR/usr/sbin/policy-rc.d"
    sudo cp -a "$POLICY_SAVED" "$ROOTFS_DIR/usr/sbin/policy-rc.d"
  else
    sudo rm -f "$ROOTFS_DIR/usr/sbin/policy-rc.d"
  fi
  for target in "$ROOTFS_DIR/run" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/dev"; do
    sudo umount -lf "$target" 2>/dev/null || true
  done
}

if [[ -e "$ROOTFS_DIR/etc/resolv.conf" || -L "$ROOTFS_DIR/etc/resolv.conf" ]]; then
  sudo cp -a "$ROOTFS_DIR/etc/resolv.conf" "$RESOLV_SAVED"
  RESOLV_PRESENT=true
fi
if [[ -e "$ROOTFS_DIR/usr/sbin/policy-rc.d" || -L "$ROOTFS_DIR/usr/sbin/policy-rc.d" ]]; then
  sudo cp -a "$ROOTFS_DIR/usr/sbin/policy-rc.d" "$POLICY_SAVED"
  POLICY_PRESENT=true
fi

sudo mkdir -p "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/run" "$ROOTFS_DIR/usr/sbin"
sudo rm -f "$ROOTFS_DIR/etc/resolv.conf"
sudo cp -L /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

# Prevent package maintainer scripts from trying to start services in the
# temporary chroot. The normal systemd presets remain available on the device.
printf '#!/bin/sh\nexit 101\n' | sudo tee "$ROOTFS_DIR/usr/sbin/policy-rc.d" >/dev/null
sudo chmod 0755 "$ROOTFS_DIR/usr/sbin/policy-rc.d"

sudo mount --bind /dev "$ROOTFS_DIR/dev"
sudo mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
sudo mount -t proc proc "$ROOTFS_DIR/proc"
sudo mount -t sysfs sysfs "$ROOTFS_DIR/sys"
sudo mount --bind /run "$ROOTFS_DIR/run"

sudo chroot "$ROOTFS_DIR" /usr/bin/env DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get update
sudo chroot "$ROOTFS_DIR" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
  /usr/bin/apt-get install -y --no-install-recommends dracut-ng networkmanager sddm aosc-os-oobe-gui
sudo chroot "$ROOTFS_DIR" /usr/bin/env sh -c \
  'command -v dracut >/dev/null && command -v bootctl >/dev/null'
# The Desktop OOBE unit is gated by ConditionFirstBoot and kde-base.list. It
# runs before SDDM, creates the first user, then removes itself and reboots.
test -f "$ROOTFS_DIR/var/lib/dpkg/info/kde-base.list"
test -s "$ROOTFS_DIR/usr/lib/systemd/system/aosc-os-oobe-gui.service"
test -e "$ROOTFS_DIR/usr/lib/systemd/system/first-boot-complete.target.wants/aosc-os-oobe-gui.service"

# Replace any generic image kernel with the pinned device kernel. The kernel
# release itself is pinned by build.env and the checked-out kernel commit.
sudo mkdir -p "$ROOTFS_DIR/boot"
sudo find "$ROOTFS_DIR/boot" -maxdepth 1 -type f \
  \( -name 'vmlinuz*' -o -name 'initramfs*' -o -name 'initrd*' \) -delete
sudo make -C "$KERN_SRC" O="$KERN_OUT" ARCH=arm64 INSTALL_MOD_PATH="$ROOTFS_DIR" modules_install
sudo rm -f "$ROOTFS_DIR/lib/modules/$KREL/build" "$ROOTFS_DIR/lib/modules/$KREL/source"
sudo depmod -b "$ROOTFS_DIR" -a "$KREL"

sudo install -Dm644 "$IMAGE_SOURCE" "$ROOTFS_DIR/boot/vmlinuz-$KREL"
sudo install -Dm644 "$DTB_SOURCE" "$ROOTFS_DIR/boot/dtb-$KREL/qcom/$DTB_NAME"

# Merge the device firmware with the distribution firmware.
sudo mkdir -p "$ROOTFS_DIR/lib/firmware"
sudo rsync -a "$GAOKUN_DIR/firmware/" "$ROOTFS_DIR/lib/firmware/"

sudo install -d "$ROOTFS_DIR/etc/dracut.conf.d"
sudo tee "$ROOTFS_DIR/etc/dracut.conf.d/90-gaokun3.conf" >/dev/null <<'EOF'
hostonly="no"
add_drivers+=" ext4 nvme phy-qcom-qmp-pcie phy-qcom-qmp-combo phy-qcom-qmp-usb phy-qcom-snps-femto-v2 usb-storage uas typec pci-pwrctrl-pwrseq ath11k ath11k_pci i2c-hid-of lpasscc_sc8280xp snd-soc-sc8280xp pinctrl_sc8280xp_lpass_lpi "
install_items+=" /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn /lib/firmware/qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin "
EOF

echo "$snapshot" > "$WORKDIR/aosc-snapshot.txt"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "AOSC_SNAPSHOT=$snapshot" >> "$GITHUB_ENV"
  echo "IMAGE_FILE=$IMAGE_FILE" >> "$GITHUB_ENV"
fi
# Leave the root partition mounted and the loop device attached for the next
# step, which mounts the ESP and installs the bootloader in-place.
trap - EXIT
cleanup_chroot
 "$ROOTFS_DIR/etc/os-release"; then
  echo "The downloaded archive does not look like an AOSC OS rootfs." >&2
  exit 1
fi

KREL="$(cat "$WORKDIR/kernel-release.txt")"
DTB_NAME="sc8280xp-huawei-gaokun3.dtb"
DTB_SOURCE="$KERN_OUT/arch/arm64/boot/dts/qcom/$DTB_NAME"
IMAGE_SOURCE="$KERN_OUT/arch/arm64/boot/Image"
test -s "$IMAGE_SOURCE"
test -s "$DTB_SOURCE"

RESOLV_SAVED="$WORKDIR/rootfs-resolv.conf.saved"
POLICY_SAVED="$WORKDIR/rootfs-policy-rc.d.saved"
RESOLV_PRESENT=false
POLICY_PRESENT=false

cleanup_chroot() {
  set +e
  if [[ "$RESOLV_PRESENT" == "true" ]]; then
    sudo rm -f "$ROOTFS_DIR/etc/resolv.conf"
    sudo cp -a "$RESOLV_SAVED" "$ROOTFS_DIR/etc/resolv.conf"
  else
    sudo rm -f "$ROOTFS_DIR/etc/resolv.conf"
  fi
  if [[ "$POLICY_PRESENT" == "true" ]]; then
    sudo rm -f "$ROOTFS_DIR/usr/sbin/policy-rc.d"
    sudo cp -a "$POLICY_SAVED" "$ROOTFS_DIR/usr/sbin/policy-rc.d"
  else
    sudo rm -f "$ROOTFS_DIR/usr/sbin/policy-rc.d"
  fi
  for target in "$ROOTFS_DIR/run" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/dev"; do
    sudo umount -lf "$target" 2>/dev/null || true
  done
}

if [[ -e "$ROOTFS_DIR/etc/resolv.conf" || -L "$ROOTFS_DIR/etc/resolv.conf" ]]; then
  sudo cp -a "$ROOTFS_DIR/etc/resolv.conf" "$RESOLV_SAVED"
  RESOLV_PRESENT=true
fi
if [[ -e "$ROOTFS_DIR/usr/sbin/policy-rc.d" || -L "$ROOTFS_DIR/usr/sbin/policy-rc.d" ]]; then
  sudo cp -a "$ROOTFS_DIR/usr/sbin/policy-rc.d" "$POLICY_SAVED"
  POLICY_PRESENT=true
fi

sudo mkdir -p "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/run" "$ROOTFS_DIR/usr/sbin"
sudo rm -f "$ROOTFS_DIR/etc/resolv.conf"
sudo cp -L /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

# Prevent package maintainer scripts from trying to start services in the
# temporary chroot. The normal systemd presets remain available on the device.
printf '#!/bin/sh\nexit 101\n' | sudo tee "$ROOTFS_DIR/usr/sbin/policy-rc.d" >/dev/null
sudo chmod 0755 "$ROOTFS_DIR/usr/sbin/policy-rc.d"

sudo mount --bind /dev "$ROOTFS_DIR/dev"
sudo mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
sudo mount -t proc proc "$ROOTFS_DIR/proc"
sudo mount -t sysfs sysfs "$ROOTFS_DIR/sys"
sudo mount --bind /run "$ROOTFS_DIR/run"

sudo chroot "$ROOTFS_DIR" /usr/bin/env DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get update
sudo chroot "$ROOTFS_DIR" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
  /usr/bin/apt-get install -y --no-install-recommends dracut-ng networkmanager sddm aosc-os-oobe-gui
sudo chroot "$ROOTFS_DIR" /usr/bin/env sh -c \
  'command -v dracut >/dev/null && command -v bootctl >/dev/null'
# The Desktop OOBE unit is gated by ConditionFirstBoot and kde-base.list. It
# runs before SDDM, creates the first user, then removes itself and reboots.
test -f "$ROOTFS_DIR/var/lib/dpkg/info/kde-base.list"
test -s "$ROOTFS_DIR/usr/lib/systemd/system/aosc-os-oobe-gui.service"
test -e "$ROOTFS_DIR/usr/lib/systemd/system/first-boot-complete.target.wants/aosc-os-oobe-gui.service"

# Replace any generic image kernel with the pinned device kernel. The kernel
# release itself is pinned by build.env and the checked-out kernel commit.
sudo mkdir -p "$ROOTFS_DIR/boot"
sudo find "$ROOTFS_DIR/boot" -maxdepth 1 -type f \
  \( -name 'vmlinuz*' -o -name 'initramfs*' -o -name 'initrd*' \) -delete
sudo make -C "$KERN_SRC" O="$KERN_OUT" ARCH=arm64 INSTALL_MOD_PATH="$ROOTFS_DIR" modules_install
sudo rm -f "$ROOTFS_DIR/lib/modules/$KREL/build" "$ROOTFS_DIR/lib/modules/$KREL/source"
sudo depmod -b "$ROOTFS_DIR" -a "$KREL"

sudo install -Dm644 "$IMAGE_SOURCE" "$ROOTFS_DIR/boot/vmlinuz-$KREL"
sudo install -Dm644 "$DTB_SOURCE" "$ROOTFS_DIR/boot/dtb-$KREL/qcom/$DTB_NAME"

# Merge the device firmware with the distribution firmware.
sudo mkdir -p "$ROOTFS_DIR/lib/firmware"
sudo rsync -a "$GAOKUN_DIR/firmware/" "$ROOTFS_DIR/lib/firmware/"

sudo install -d "$ROOTFS_DIR/etc/dracut.conf.d"
sudo tee "$ROOTFS_DIR/etc/dracut.conf.d/90-gaokun3.conf" >/dev/null <<'EOF'
hostonly="no"
add_drivers+=" ext4 nvme phy-qcom-qmp-pcie phy-qcom-qmp-combo phy-qcom-qmp-usb phy-qcom-snps-femto-v2 usb-storage uas typec pci-pwrctrl-pwrseq ath11k ath11k_pci i2c-hid-of lpasscc_sc8280xp snd-soc-sc8280xp pinctrl_sc8280xp_lpass_lpi "
install_items+=" /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn /lib/firmware/qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin "
EOF

echo "$snapshot" > "$WORKDIR/aosc-snapshot.txt"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "AOSC_SNAPSHOT=$snapshot" >> "$GITHUB_ENV"
  echo "IMAGE_FILE=$WORKDIR/aosc-desktop-$snapshot-gaokun3.img" >> "$GITHUB_ENV"
fi
trap - EXIT
cleanup_chroot
