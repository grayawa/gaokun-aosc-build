#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common_image.sh
. "$(dirname "$0")/lib/common_image.sh"

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${ROOTFS_DIR:?missing ROOTFS_DIR}"
: "${ARTIFACT_DIR:?missing ARTIFACT_DIR}"
: "${IMAGE_FILE:?missing IMAGE_FILE}"
: "${IMAGE_SIZE:?missing IMAGE_SIZE}"

KREL="$(cat "$WORKDIR/kernel-release.txt")"
DTB_NAME="sc8280xp-huawei-gaokun3.dtb"
EFI_END_MIB=1025

[[ "$IMAGE_SIZE" =~ ^[1-9][0-9]*G$ ]] || {
  echo "IMAGE_SIZE must be an integer number of GiB, for example 24G" >&2
  exit 2
}
test -s "$ROOTFS_DIR/boot/vmlinuz-$KREL"
test -s "$ROOTFS_DIR/boot/dtb-$KREL/qcom/$DTB_NAME"

mkdir -p "$ARTIFACT_DIR"
rm -f "$IMAGE_FILE"
truncate -s "$IMAGE_SIZE" "$IMAGE_FILE"
parted -s "$IMAGE_FILE" mklabel gpt
parted -s "$IMAGE_FILE" mkpart EFI fat32 1MiB "${EFI_END_MIB}MiB"
parted -s "$IMAGE_FILE" set 1 esp on
parted -s "$IMAGE_FILE" mkpart rootfs ext4 "${EFI_END_MIB}MiB" 100%

LOOP="$(sudo losetup --show -fP "$IMAGE_FILE")"
MNT=/mnt/ego-aosc
cleanup() {
  set +e
  for target in "$MNT/dev/pts" "$MNT/boot/efi" "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/run" "$MNT"; do
    sudo umount -lf "$target" 2>/dev/null || true
  done
  sudo losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

sudo mkfs.vfat -F32 -n EFI "${LOOP}p1"
sudo mkfs.ext4 -F -L rootfs "${LOOP}p2"
EFI_UUID="$(sudo blkid -s UUID -o value "${LOOP}p1")"
ROOT_UUID="$(sudo blkid -s UUID -o value "${LOOP}p2")"

sudo mkdir -p "$MNT"
sudo mount "${LOOP}p2" "$MNT"
sudo mkdir -p "$MNT/boot/efi" "$MNT/dev/pts" "$MNT/proc" "$MNT/sys" "$MNT/run"
sudo mount "${LOOP}p1" "$MNT/boot/efi"
sudo rsync -aHAX --numeric-ids \
  --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' \
  "$ROOTFS_DIR/" "$MNT/"
sudo chown root:root "$MNT"
sudo chmod 0755 "$MNT"

# Keep device assets, but do not install Mutter's monitors.xml into KDE.
install_common_image_assets "$MNT" "$GAOKUN_DIR" kde

sudo tee "$MNT/etc/fstab" >/dev/null <<EOF
UUID=${ROOT_UUID}  /         ext4   errors=remount-ro,noatime  0  1
UUID=${EFI_UUID}   /boot/efi vfat   umask=0077,shortname=winnt,nofail,x-systemd.device-timeout=10s  0  2
EOF

sudo mount --bind /dev "$MNT/dev"
sudo mount --bind /dev/pts "$MNT/dev/pts"
sudo mount -t proc proc "$MNT/proc"
sudo mount -t sysfs sysfs "$MNT/sys"
sudo mount -t tmpfs tmpfs "$MNT/run"

sudo chroot "$MNT" /usr/bin/env KREL="$KREL" ROOT_UUID="$ROOT_UUID" DTB_NAME="$DTB_NAME" \
  /bin/bash -euxo pipefail <<'CHROOT_EOF'
echo "aosc-gaokun3" > /etc/hostname

mkdir -p /etc/kernel
printf 'layout=bls\n' > /etc/kernel/install.conf
printf '%s\n' 'aosc' > /etc/kernel/entry-token
cat > /etc/kernel/cmdline <<EOF
root=UUID=$ROOT_UUID rw rootwait clk_ignore_unused pd_ignore_unused arm64.nopauth pcie_aspm.policy=powersupersave efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000
EOF
printf 'qcom/%s\n' "$DTB_NAME" > /etc/kernel/devicetree

test -s "/boot/vmlinuz-$KREL"
test -s "/boot/dtb-$KREL/qcom/$DTB_NAME"
command -v dracut
command -v bootctl
dracut --force --no-hostonly "/boot/initramfs-$KREL.img" "$KREL"
test -s "/boot/initramfs-$KREL.img"

# Install the ARM64 systemd-boot loader without modifying the build host's NVRAM.
bootctl --no-variables --esp-path=/boot/efi install
test -s /boot/efi/EFI/BOOT/BOOTAA64.EFI

install -d "/boot/efi/aosc/$KREL" /boot/efi/loader/entries
install -m0644 "/boot/vmlinuz-$KREL" "/boot/efi/aosc/$KREL/Image"
install -m0644 "/boot/initramfs-$KREL.img" "/boot/efi/aosc/$KREL/initramfs.img"
install -m0644 "/boot/dtb-$KREL/qcom/$DTB_NAME" "/boot/efi/aosc/$KREL/gaokun3.dtb"

entry="/boot/efi/loader/entries/aosc-$KREL.conf"
cat > "$entry" <<EOF
title AOSC OS Desktop (Gaokun3)
version $KREL
linux /aosc/$KREL/Image
initrd /aosc/$KREL/initramfs.img
devicetree /aosc/$KREL/gaokun3.dtb
options $(cat /etc/kernel/cmdline)
EOF

cat > /boot/efi/loader/loader.conf <<EOF
default aosc-$KREL.conf
timeout 5
console-mode keep
editor yes
EOF

enable_unit_if_present() {
  local unit="$1"
  if [[ -e "/usr/lib/systemd/system/$unit" ||
        -e "/lib/systemd/system/$unit" ||
        -e "/etc/systemd/system/$unit" ]]; then
    systemctl enable "$unit"
  else
    echo "Skipping absent systemd unit: $unit"
  fi
}
enable_unit_if_present NetworkManager.service
enable_unit_if_present plasmalogin.service
enable_unit_if_present bluetooth.service
enable_unit_if_present patch-nvm-bdaddr.service
systemctl set-default graphical.target

rm -f /etc/machine-id
systemd-machine-id-setup
rm -f /boot/efi/loader/random-seed /var/lib/systemd/random-seed /var/lib/systemd/credential.secret
printf 'uninitialized\n' > /etc/machine-id

test -s /boot/efi/loader/entries/aosc-$KREL.conf
grep -Fq "root=UUID=$ROOT_UUID" /boot/efi/loader/entries/aosc-$KREL.conf
grep -Fq "devicetree /aosc/$KREL/gaokun3.dtb" /boot/efi/loader/entries/aosc-$KREL.conf
CHROOT_EOF

sync
trap - EXIT
cleanup
