#!/usr/bin/env bash
set -euo pipefail

: "${WORKDIR:?missing WORKDIR}"
: "${ARTIFACT_DIR:?missing ARTIFACT_DIR}"
: "${IMAGE_FILE:?missing IMAGE_FILE}"
: "${IMAGE_CHUNK_SIZE:?missing IMAGE_CHUNK_SIZE}"
: "${KERNEL_TAG:?missing KERNEL_TAG}"

KREL="$(cat "$WORKDIR/kernel-release.txt")"
SNAPSHOT="$(cat "$WORKDIR/aosc-snapshot.txt")"
BASE="$(basename "$IMAGE_FILE")"
ZST_NAME="${BASE}.zst"
ZST_FILE="$ARTIFACT_DIR/$ZST_NAME"
RELEASE_BODY="$ARTIFACT_DIR/release-body.md"
SPLIT_LIMIT=$((2 * 1024 * 1024 * 1024))
EL2_KREL=""
EL2_NOTE="EL2: disabled"
if [[ "${BUILD_EL2:-false}" == "true" ]]; then
  EL2_KREL="$(cat "$WORKDIR/kernel-release-el2.txt")"
  EL2_NOTE="EL2 kernel: $EL2_KREL (experimental)"
fi
mkdir -p "$ARTIFACT_DIR"
zstd -T0 -19 "$IMAGE_FILE" -o "$ZST_FILE"
(cd "$ARTIFACT_DIR" && sha256sum "$ZST_NAME" > SHA256SUMS)

# Actions artifact ZIP carries the COMPLETE compressed image as one file.
# GitHub Releases still require smaller individual assets (strictly < 2 GiB).
if [[ "$(stat -c '%s' "$ZST_FILE")" -lt "$SPLIT_LIMIT" ]]; then
  PACKAGE_GLOB="$ZST_NAME"
  cp "$ARTIFACT_DIR/SHA256SUMS" "$ARTIFACT_DIR/SHA256SUMS.parts"
else
  split -b "$IMAGE_CHUNK_SIZE" -d -a 3 "$ZST_FILE" "$ZST_FILE.part-"
  PACKAGE_GLOB="$ZST_NAME.part-*"
  (
    cd "$ARTIFACT_DIR"
    find . -maxdepth 1 -type f -name "$PACKAGE_GLOB" -print0 |
      sort -z |
      xargs -0 sha256sum > SHA256SUMS.parts
  )
fi
cat > "$RELEASE_BODY" <<EOF
## AOSC OS Desktop ARM64 / Gaokun3

- Snapshot: $SNAPSHOT
- Standard EL1 kernel: $KREL
- $EL2_NOTE
- Disk: GPT, FAT32 ESP (1 GiB), ext4 rootfs
- Bootloader: systemd-boot; default EL1
- Full raw disk image: $BASE
- Compressed raw disk image: $ZST_NAME
- Build UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Write to USB

The Actions artifact ZIP contains ONE complete $ZST_NAME and SHA256SUMS.
Extract ZIP and then decompress .zst to obtain the complete .img. Write the
whole .img to a USB drive in raw/DD mode. Do not extract individual partitions.

On a GitHub Release with split assets, reconstruct the compressed image:
    cat $ZST_NAME.part-* > $ZST_NAME
    zstd -d $ZST_NAME -o $BASE

This is experimental on the 2022 MateBook E Go performance edition.
EL2 can have Qualcomm Venus decode limitations. Flashing overwrites the entire
target USB, and neither EL1 nor EL2 has been verified on this hardware revision.
EOF
TAG="aosc-desktop-$SNAPSHOT-$KREL$(if [[ -n "$EL2_KREL" ]]; then printf -- '-el2'; fi)-$(date -u +%Y%m%d%H%M%S)"
echo "$TAG" > "$WORKDIR/tag-name.txt"
echo "$PACKAGE_GLOB" > "$WORKDIR/package-glob.txt"
echo "$ZST_NAME" > "$WORKDIR/direct-image-name.txt"
basename "$RELEASE_BODY" > "$WORKDIR/release-body-file.txt"
