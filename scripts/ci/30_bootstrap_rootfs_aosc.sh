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
sudo rm -rf "$ROOTFS_DIR"
sudo mkdir -p "$ROOTFS_DIR"

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

echo "Using AOSC Desktop snapshot: $snapshot"
curl -fL --retry 3 --retry-delay 2 "$DESKTOP_URL/$archive_name" -o "$archive_path"
curl -fL --retry 3 --retry-delay 2 "$DESKTOP_URL/$archive_name.sha256sum" -o "$checksum_path"
(
  cd "$WORKDIR"
  sha256sum -c "$(basename "$checksum_path")"
)

# AOSC's ARM image recipes unpack rootfs tarballs with one leading directory
# component removed. Keep numeric ownership, ACLs and extended attributes.
sudo tar -xJpf "$archive_path" \
  -C "$ROOTFS_DIR" \
  --strip-components=1 \
  --numeric-owner \
  --xattrs \
  --acls

if ! grep -Eq '^ID="?aosc"?$' "$ROOTFS_DIR/etc/os-release"; then
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
trap cleanup_chroot EXIT

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
  /usr/bin/apt-get install -y --no-install-recommends dracut-ng networkmanager sddm
sudo chroot "$ROOTFS_DIR" /usr/bin/env sh -c \
  'command -v dracut >/dev/null && command -v bootctl >/dev/null'

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
  echo "AOSC_SNAPSHOT_RESOLVED=$snapshot" >> "$GITHUB_ENV"
fi
trap - EXIT
cleanup_chroot
