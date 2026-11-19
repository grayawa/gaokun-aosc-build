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

1. Downloads the official AOSC ARM64 Desktop rootfs tarball and verifies its
   SHA-256 sidecar.
2. Installs dracut-ng, NetworkManager and SDDM through the AOSC ARM64 stable repository.
3. Builds the standard kernel at the commit pinned in build.env.
4. Installs the kernel modules, Gaokun3 DTB and repository firmware into the
   rootfs.
5. Creates an initramfs with the device storage, Wi-Fi, input and audio drivers.
6. Creates a GPT image with a 1 GiB FAT32 ESP and an ext4 root partition.
7. Installs systemd-boot and writes a BLS entry with an explicit DTB path.
8. Compresses the image, writes SHA256SUMS and uploads a workflow artifact.

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
