#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# make-hash-list.sh - write YOUR partition-hashes.txt from YOUR OWN backup of the vendor eMMC.  Read-only; nothing is written
# except the list on stdout.
#
#   usage:  bash scripts/make-hash-list.sh /path/to/dq10-mmcblk0.img  > partition-hashes.txt
#           (IMG = a RAW image of the whole eMMC user area, 15,634,268,160 bytes, or a read-only block device.  A .gz backup must be
#            unpacked first:  gzip -dc dq10-mmcblk0.img.gz > dq10-mmcblk0.img   - about 15 GB of disk space.)
#
# Output format, one line per region, four space-separated fields (the format scripts/ums-flash.sh reads):
#       name start_sector sector_count sha256
# The first line is always  "preboot-area 0 73728 <sha256>"  (sectors 0..73727 = the first 36 MiB: MBR/GPT, both vendor boot0
# copies, the boot package) - ums-flash.sh uses that hash as the IDENTITY check of the stick.  Every following line is one GPT
# partition of the image (name taken from the GPT; spaces become '_'; a duplicate name gets '-<start>' appended).
# Keep the list private: it fingerprints your unit's vendor state.  It is NOT part of this repository.
set -euo pipefail
IMG=${1:?usage: $0 /path/to/raw-image-or-device > partition-hashes.txt}
PRE=73728
[ -r "$IMG" ] || { echo "cannot read $IMG" >&2; exit 1; }
command -v sfdisk >/dev/null || { echo "sfdisk (util-linux) is needed" >&2; exit 1; }
hash_range() { # start count (sectors): largest block size that divides both offset and length, 1 MiB reads are far faster than 512 B
  local s=$1 c=$2 bs=512 t
  for t in 1048576 65536 4096; do
    if [ $(( s * 512 % t )) = 0 ] && [ $(( c * 512 % t )) = 0 ]; then bs=$t; break; fi
  done
  dd if="$IMG" bs=$bs skip=$(( s * 512 / bs )) count=$(( c * 512 / bs )) status=none | sha256sum | cut -c1-64
}
echo "preboot-area 0 $PRE $(hash_range 0 $PRE)"
declare -A seen=()
sfdisk -d "$IMG" 2>/dev/null \
  | sed -n 's/.*start= *\([0-9][0-9]*\), *size= *\([0-9][0-9]*\),.*name="\([^"]*\)".*/\1 \2 \3/p' \
  | sort -n \
  | while read -r start size name; do
      [ "$size" -gt 0 ] || continue
      [ "$start" -ge "$PRE" ] || { echo "skipping '$name' (starts inside the preboot area)" >&2; continue; }
      name=${name// /_}
      echo "$start $size $name"
    done \
  | while read -r start size name; do
      if [ -n "${seen[$name]:-}" ]; then name="$name-$start"; fi
      seen[$name]=1
      echo "$name $start $size $(hash_range "$start" "$size")"
    done
