#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common_image.sh
. "$(dirname "$0")/lib/common_image.sh"

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${ROOTFS_DIR:?missing ROOTFS_DIR}"
: "${ARTIFACT_DIR:?missing ARTIFACT_DIR}"
: "${IMAGE_FILE:?missing IMAGE_FILE}"

KREL="$(cat "$WORKDIR/kernel-release.txt")"
BUILD_EL2="${BUILD_EL2:-false}"
KREL_EL2=""
if [[ "$BUILD_EL2" == "true" ]]; then
  KREL_EL2="$(cat "$WORKDIR/kernel-release-el2.txt")"
fi
DTB_NAME="sc8280xp-huawei-gaokun3.dtb"

[[ "$IMAGE_SIZE" =~ ^[1-9][0-9]*G$ ]] || {
  echo "IMAGE_SIZE must be an integer number of GiB, for example 24G" >&2
  exit 2
}
mkdir -p "$ARTIFACT_DIR"
LOOP="$(cat "$WORKDIR/loop-device.txt")"
if ! sudo losetup "$LOOP" >/dev/null 2>&1; then
  LOOP="$(sudo losetup --show -fP "$IMAGE_FILE")"
  echo "$LOOP" > "$WORKDIR/loop-device.txt"
fi

MNT="$ROOTFS_DIR"
if ! mountpoint -q "$MNT"; then
  sudo mount "${LOOP}p2" "$MNT"
fi
ROOT_UUID="$(cat "$WORKDIR/root-uuid.txt")"
EFI_UUID="$(cat "$WORKDIR/efi-uuid.txt")"

test -s "$ROOTFS_DIR/boot/vmlinuz-$KREL"
test -s "$ROOTFS_DIR/boot/dtb-$KREL/qcom/$DTB_NAME"
if [[ "$BUILD_EL2" == "true" ]]; then
  test -s "$ROOTFS_DIR/boot/vmlinuz-$KREL_EL2"
  test -s "$ROOTFS_DIR/boot/dtb-$KREL_EL2/qcom/sc8280xp-huawei-gaokun3-el2.dtb"
fi

cleanup() {
  set +e
  for target in "$MNT/dev/pts" "$MNT/boot/efi" "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/run" "$MNT"; do
    sudo umount -lf "$target" 2>/dev/null || true
  done
  sudo losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

sudo mkdir -p "$MNT/boot/efi" "$MNT/dev/pts" "$MNT/proc" "$MNT/sys" "$MNT/run"
sudo mount "${LOOP}p1" "$MNT/boot/efi"

# The root filesystem was extracted directly into this partition by the
# previous step; no second staging-tree copy is needed.
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

sudo chroot "$MNT" /usr/bin/env KREL="$KREL" KREL_EL2="$KREL_EL2" BUILD_EL2="$BUILD_EL2" ROOT_UUID="$ROOT_UUID" DTB_NAME="$DTB_NAME" \
  /bin/bash -euxo pipefail <<'CHROOT_EOF'
echo "aosc-gaokun3" > /etc/hostname

mkdir -p /etc/kernel
printf 'layout=bls\n' > /etc/kernel/install.conf
printf '%s\n' 'aosc' > /etc/kernel/entry-token
cat > /etc/kernel/cmdline <<EOF
root=UUID=$ROOT_UUID rw rootwait clk_ignore_unused pd_ignore_unused arm64.nopauth pcie_aspm.policy=powersupersave efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 plymouth.enable=0 lsm=landlock,lockdown,yama,loadpin,safesetid,selinux,integrity,bpf
EOF
printf 'qcom/%s\n' "$DTB_NAME" > /etc/kernel/devicetree

test -s "/boot/vmlinuz-$KREL"
test -s "/boot/dtb-$KREL/qcom/$DTB_NAME"
command -v dracut
command -v bootctl
dracut --force --no-hostonly "/boot/initramfs-$KREL.img" "$KREL"
test -s "/boot/initramfs-$KREL.img"
if [[ "$BUILD_EL2" == "true" ]]; then
  dracut --force --no-hostonly "/boot/initramfs-$KREL_EL2.img" "$KREL_EL2"
  test -s "/boot/initramfs-$KREL_EL2.img"
fi

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

if [[ "$BUILD_EL2" == "true" ]]; then
  install -d "/boot/efi/aosc/$KREL_EL2"
  install -m0644 "/boot/vmlinuz-$KREL_EL2" "/boot/efi/aosc/$KREL_EL2/Image"
  install -m0644 "/boot/initramfs-$KREL_EL2.img" "/boot/efi/aosc/$KREL_EL2/initramfs.img"
  install -m0644 "/boot/dtb-$KREL_EL2/qcom/sc8280xp-huawei-gaokun3-el2.dtb" \
    "/boot/efi/aosc/$KREL_EL2/gaokun3-el2.dtb"
  cat > "/boot/efi/loader/entries/aosc-$KREL_EL2.conf" <<EOF
title AOSC OS Desktop (Gaokun3 EL2 / KVM - experimental)
version $KREL_EL2
linux /aosc/$KREL_EL2/Image
initrd /aosc/$KREL_EL2/initramfs.img
devicetree /aosc/$KREL_EL2/gaokun3-el2.dtb
options $(cat /etc/kernel/cmdline) modprobe.blacklist=simpledrm
EOF
fi

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
systemctl disable plasmalogin.service 2>/dev/null || true
systemctl enable --force sddm.service
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
if [[ "$BUILD_EL2" == "true" ]]; then
  test -s "/boot/efi/loader/entries/aosc-$KREL_EL2.conf"
  grep -Fq "devicetree /aosc/$KREL_EL2/gaokun3-el2.dtb" \
    "/boot/efi/loader/entries/aosc-$KREL_EL2.conf"
fi
CHROOT_EOF

if [[ "$BUILD_EL2" == "true" ]]; then
  install_el2_efi_payloads "$MNT" "$GAOKUN_DIR"
fi

sync
trap - EXIT
cleanup
