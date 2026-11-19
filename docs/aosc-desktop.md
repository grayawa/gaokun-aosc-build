# AOSC OS Desktop ARM64 image for Gaokun3

This branch adds an experimental GitHub Actions workflow for building an AOSC OS
Desktop ARM64 raw image with the standard Gaokun3 kernel.

## Build

Run the **Build Image - AOSC OS Desktop Gaokun3** workflow from the
aosc-desktop branch.

Inputs:

- AOSC snapshot: an eight-digit snapshot date, or latest (the default).
- Raw image size: an integer number of GiB, default 24G.
- Publish release: disabled by default. Enable only after reviewing the artifact.

The workflow:

1. Builds the standard kernel at the commit pinned in build.env.
2. Creates the GPT image with a 1 GiB FAT32 ESP and an ext4 root partition.
3. Streams the official AOSC ARM64 Desktop rootfs tarball directly into the
   image's ext4 partition while verifying its SHA-256 checksum.
4. Installs dracut-ng, NetworkManager, SDDM and the AOSC graphical OOBE wizard
   through the AOSC ARM64 stable repository.
   Device firmware is merged without overwriting a distribution-provided
   WCN6855/hw2.1 directory with the repository's hw2.1 symlink.
5. Installs the kernel modules, Gaokun3 DTB and repository firmware into the
   rootfs, then creates an initramfs with the device drivers and firmware.
6. Installs systemd-boot and writes a BLS entry with an explicit DTB path.
7. Compresses the image, writes SHA256SUMS and uploads a workflow artifact.

The rootfs is built directly inside the final disk image. The tarball is streamed
through a FIFO and hashed in parallel, so neither a separate tarball copy nor a
second full staging-rootfs copy is needed on the runner.

AOSC's ARM installation notes explain that generic ARM tarballs contain an
unconfigured mainline kernel and require device-specific image preparation:
https://wiki.aosc.io/aosc-os/installation/rawimgs/

The official ARM64 Desktop tarballs are published here:
https://releases.aosc.io/os-arm64/desktop/

The October 2026 AOSC release notes identify KDE Plasma 6.7.5 as the updated
desktop environment:
https://aosc.io/aosc-os/relnote

AOSC's KDE 6 update notes describe the new Plasma Login Manager and document
SDDM as a fallback:
https://aosc.io/news/2026-10-11-kde-6.7-update-notes

The current ARM64 stable package index lists plasma-login-manager under
missing packages while SDDM is available. This workflow therefore installs
and enables SDDM for the ARM64 image:
https://packages.aosc.io/missing/arm64/stable?page=6
https://packages.aosc.io/repo/arm64/stable?page=61

## Boot layout

The ESP contains:

- EFI/BOOT/BOOTAA64.EFI
- loader/loader.conf
- loader/entries/aosc-<kernel-release>.conf
- aosc/<kernel-release>/Image
- aosc/<kernel-release>/initramfs.img
- aosc/<kernel-release>/gaokun3.dtb

The BLS entry explicitly names the DTB. This first version writes the entry
directly so the DTB path and root UUID are explicit and easy to audit.

The root filesystem is ext4. The kernel command line is based on the existing
Gaokun3 Fedora/Ubuntu image configuration and includes root UUID, rootwait,
EFI runtime, framebuffer rotation and the existing USB HID quirk.

## KDE display setup

The GNOME Mutter monitors.xml file is intentionally not installed into this
image. A KDE autostart helper attempts to apply the internal DSI-1 output's
right rotation and 2x scale on the first Plasma login. It records a per-user
marker after success, so later logins do not overwrite the user's settings.

This does not configure the SDDM greeter. If the panel connector is not named
DSI-1 on a particular hardware revision, the helper exits without changing
anything and the display can be configured manually in System Settings.

## Scope and limitations

- EL2 is deliberately disabled. The repository's EL2 migration is not ready.
- The kernel and DTB are the currently pinned Gaokun3 2023 target. The 2022
  3 GHz MateBook E Go variant has not been independently validated by this
  workflow; a successful CI build does not prove that its panel, EC, touch,
  suspend or power-management paths match.
- The workflow does not create a project-specific user/password. Follow the
  account and first-boot behavior supplied by the selected AOSC Desktop
  snapshot.
- The image is a first boot candidate. It must be tested from USB before any
  internal-disk installation is attempted.
- The kernel is installed directly into the image rather than registered as an
  AOSC package. Kernel upgrades and package-manager integration are follow-up
  work.

## Local validation

The repository checks run Bash syntax validation, ShellCheck and the existing
boot-entry unit tests. They do not replace a real boot test on the target
tablet.


## Flash-ready GitHub Actions image

Run [the experimental build workflow](../.github/workflows/aosc-gaokun3-desktop.yml)
on branch `aosc-desktop`. Its downloadable `aosc-gaokun3-desktop` artifact
is a ZIP produced by GitHub Actions, **not the disk image itself**. Open the ZIP
and extract its files; the important one is a **single**
`aosc-desktop-<date>-gaokun3.img.zst`. Do not open that compressed image as an
archive and try to write its embedded EFI/rootfs partitions separately.

On Windows, Rufus 4.7+ supports Zstandard compressed disk images: select the
`.img.zst` in Rufus, choose the **whole removable USB drive**, and start a
raw/DD image write. If the image isn't recognized by your writing utility,
decompress `.img.zst` with 7-Zip or `zstd -d` and write the resulting
`.img` as a raw disk image.

On Linux, decompress then write (replace `/dev/sdX` with the actual USB
**disk**, not its partition; double-check using `lsblk`):

```sh
sha256sum -c SHA256SUMS
zstd -d aosc-desktop-*.img.zst -o gaokun3.img
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS
sudo dd if=gaokun3.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

The image is 24 GiB uncompressed by default, so use a USB stick of at least
32 GB. **All data and the USB's partition table will be overwritten.**
On Android, MT Manager may identify subimages such as `0.EFI.img` and
`1.rootfs.img` inside the raw disk image. These are partition *views* of
the complete GPT disk. They are not separate flash targets.

GitHub Releases restrict each individual asset to less than 2 GiB. The
`publish_release` option therefore still splits large `.img.zst` files into
pieces, with `SHA256SUMS.parts`. GitHub Actions artifacts now keep a
complete, unbroken compressed raw image inside the artifact ZIP.

## Optional EL2 mode

Following [9Bakabaka's 7.2.7 Fedora EL2 release](https://github.com/9Bakabaka/build/releases/tag/fedora45-7.2.7-gaokun3%2B-el2-20261115133603),
this experimental workflow builds both the normal EL1 kernel
`73033564068250603f5b2150c408554faaf22d66` and the pinned EL2
kernel `6122a641adb7b93e2671867540d6f04ef3fe1529`.
The ESP contains two systemd-boot entries, the EL2-specific DTB and
initramfs, `slbounceaa64.efi`, `qebspilaa64.efi`, `tcblaunch.exe`, and the
required Qualcomm DSP firmware. **Normal EL1 remains the default boot**;
choose the experimental EL2 entry manually.

This is adapted from a 2023 Gaokun3-oriented build. Neither EL1 nor EL2
is verified on the MateBook E Go 2022 3 GHz performance variant. EL2 may
lose Venus hardware video decode and may fail before KVM is usable.
Boot from USB first; do not overwrite the internal Windows disk.
