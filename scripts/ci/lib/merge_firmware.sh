#!/usr/bin/env bash
# Merge Gaokun3's device firmware with a distribution firmware tree.
# The downstream repo uses WCN6855/hw2.1 -> hw2.0, whereas distributions
# may already ship a populated hw2.1 directory. Preserve the latter.
merge_gaokun_firmware() {
  local src="$1" dst="$2"
  local relative_alias="ath11k/WCN6855/hw2.1"
  local src_alias="$src/$relative_alias"
  local dst_alias="$dst/$relative_alias"
  local alias_target=""

  [[ -d "$src" && -d "$dst" ]] || {
    echo "Firmware merge directories not found: $src or $dst" >&2
    return 1
  }

  # The repository's hw2.1 alias conflicts with some full firmware packages.
  # Keep every other override and supplementary device firmware file.
  rsync -a --exclude="/$relative_alias" "$src/" "$dst/"

  # Restore the repository symlink only when the distro provides nothing at
  # the alias path. Never replace an existing directory, file or symlink.
  if [[ ! -e "$dst_alias" && ! -L "$dst_alias" && -L "$src_alias" ]]; then
    alias_target="$(readlink "$src_alias")"
    [[ "$alias_target" == "hw2.0" ]] || {
      echo "Unexpected WCN6855/hw2.1 alias target: $alias_target" >&2
      return 1
    }
    ln -s "$alias_target" "$dst_alias"
  fi
}
