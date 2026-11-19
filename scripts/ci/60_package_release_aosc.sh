#!/usr/bin/env bash
set -euo pipefail

: "${WORKDIR:?missing WORKDIR}"
: "${ARTIFACT_DIR:?missing ARTIFACT_DIR}"
: "${IMAGE_FILE:?missing IMAGE_FILE}"
: "${IMAGE_CHUNK_SIZE:?missing IMAGE_CHUNK_SIZE}"
: "${KERNEL_TAG:?missing KERNEL_TAG}"

KREL="$(cat "$WORKDIR/kernel-release.txt")"
AOSC_SNAPSHOT="$(cat "$WORKDIR/aosc-snapshot.txt")"
IMAGE_BASENAME="$(basename "$IMAGE_FILE")"
ZST_FILE="$ARTIFACT_DIR/${IMAGE_BASENAME}.zst"
RELEASE_BODY_FILE="$ARTIFACT_DIR/release-body.md"
SPLIT_THRESHOLD_BYTES=$((2 * 1024 * 1024 * 1024))

mkdir -p "$ARTIFACT_DIR"
zstd -T0 -19 "$IMAGE_FILE" -o "$ZST_FILE"

if [[ "$(stat -c '%s' "$ZST_FILE")" -lt "$SPLIT_THRESHOLD_BYTES" ]]; then
  PACKAGE_GLOB="${IMAGE_BASENAME}.zst"
  cat > "$RELEASE_BODY_FILE" <<EOF
## Build Information

- Distribution: AOSC OS Desktop
- AOSC ARM64 snapshot: ${AOSC_SNAPSHOT}
- Kernel tag: ${KERNEL_TAG}
- Kernel release: ${KREL}
- Architecture: arm64
- Root filesystem: ext4
- EFI system partition: FAT32, 1 GiB
- Bootloader: systemd-boot with a device-tree-aware BLS entry
- Image: ${IMAGE_BASENAME}
- Compressed image: ${IMAGE_BASENAME}.zst
- Build time (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Notes

- The image uses the standard Gaokun3 kernel; EL2 is not included.
- The official AOSC Desktop userland is retained. This build does not inject a project-specific user name or password.
- The KDE first-login helper attempts to rotate DSI-1 right and set 2x scaling. The Plasma Login Manager greeter is not configured by that helper.
- This is a build artifact, not proof of successful boot on every MateBook E Go hardware revision.
EOF
else
  split -b "$IMAGE_CHUNK_SIZE" -d -a 3 "$ZST_FILE" "$ZST_FILE.part-"
  PACKAGE_GLOB="${IMAGE_BASENAME}.zst.part-*"
  cat > "$RELEASE_BODY_FILE" <<EOF
## Build Information

- Distribution: AOSC OS Desktop
- AOSC ARM64 snapshot: ${AOSC_SNAPSHOT}
- Kernel tag: ${KERNEL_TAG}
- Kernel release: ${KREL}
- Architecture: arm64
- Root filesystem: ext4
- EFI system partition: FAT32, 1 GiB
- Bootloader: systemd-boot with a device-tree-aware BLS entry
- Image: ${IMAGE_BASENAME}
- Compressed image: ${IMAGE_BASENAME}.zst
- Build time (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Notes

- The image uses the standard Gaokun3 kernel; EL2 is not included.
- The official AOSC Desktop userland is retained. This build does not inject a project-specific user name or password.
- The KDE first-login helper attempts to rotate DSI-1 right and set 2x scaling. The Plasma Login Manager greeter is not configured by that helper.
- This is a build artifact, not proof of successful boot on every MateBook E Go hardware revision.

## Reassemble and decompress

    cat ${IMAGE_BASENAME}.zst.part-* > ${IMAGE_BASENAME}.zst
    zstd -d ${IMAGE_BASENAME}.zst -o ${IMAGE_BASENAME}
EOF
fi

TAG_NAME="aosc-desktop-${AOSC_SNAPSHOT}-${KREL}-$(date -u +%Y%m%d%H%M%S)"
echo "$TAG_NAME" > "$WORKDIR/tag-name.txt"
echo "$PACKAGE_GLOB" > "$WORKDIR/package-glob.txt"
basename "$RELEASE_BODY_FILE" > "$WORKDIR/release-body-file.txt"

(
  cd "$ARTIFACT_DIR"
  if ! find . -maxdepth 1 -type f -name "$PACKAGE_GLOB" -print -quit | grep -q .; then
    echo "No compressed image files found for package pattern: $PACKAGE_GLOB" >&2
    exit 1
  fi
  find . -maxdepth 1 -type f -name "$PACKAGE_GLOB" -print0 |
    sort -z |
    xargs -0 sha256sum > SHA256SUMS
)
