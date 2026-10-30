#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# ums-flash.sh - ROUTE L (main) / ROUTE F (historic): write the whole DQ10 eMMC from the PC over USB mass storage.
# Route L: the stick runs the FEL-booted Linux flasher (flasher/, gadget 1d6b:0104 "DQ10 eMMC flasher", SCSI vendor 'DQ10', model
# 'eMMC flasher'); Route F: recovery U-Boot UMS (1f3a:1010, vendor 'Linux', model 'UMS disk 0'; not working from a cold button entry).
# Run in WSL kali as root, with the disk attached to WSL by usbipd (FLASH-PLAN Part 1).
#   usage: bash scripts/ums-flash.sh /dev/sdX                          # DRY RUN (default): checks only, nothing is written
#          bash scripts/ums-flash.sh /dev/sdX --compare-hashes [FILE]  # READ-ONLY: every partition vs YOUR partition-hashes.txt (FILE or
#                                                                      # $DQ10_PARTITION_HASHES; works on a read-only export; never writes)
#          bash scripts/ums-flash.sh /dev/sdX --yes-wipe-everything    # the real thing (5 s countdown first)
#          bash scripts/ums-flash.sh /dev/sdX --yes-wipe-everything --skip-identity   # ONLY to repeat after an interrupted run
#
# Exit codes:  0 = dry run OK / compare all equal, or write + full verification OK
#              1 = usage error or a guard REFUSED (nothing was written)
#              2 = everything was written but the read-back verification FAILED (re-run, do not power-cycle yet)
#              3 = a write/zero/decompress step failed half way (re-run from the FEL step if the disk vanished)
#              4 = --compare-hashes finished and at least one partition differs / could not be read (nothing was written)
#
# Identity: this script never ships a fingerprint of anybody's stick.  YOU take a backup of YOUR vendor eMMC first and derive the
# identity hash from it (docs/FLASH-PLAN.md, 'Your own backup and hash list'):
#   export DQ10_PARTITION_HASHES=/path/to/partition-hashes.txt     # lines: name start_sector sector_count sha256 (needs a 'preboot-area 0 73728 <sha256>' line)
#   or  export DQ10_IDENTITY_SHA256=<sha256 of the first 36 MiB (sectors 0..73727) of your backup>
# Without one of them the script refuses, unless --skip-identity is given.
# Expected hashes of the image files come from image/SHA256SUMS (written by scripts/build-image.sh).
#
# Safety (reviewed against docs/AUDIT-OPUS.md and Route F, revision 3):
#  * refuses unless the device is (a) named /dev/sdX, (b) a USB device according to sysfs (so never WSL's own virtual system
#    disks), (c) EXACTLY 15,634,268,160 bytes, (d) not mounted / not swap / no partition mounted (this also covers WSL's root),
#    (e) its first 36 MiB (sectors 0..73727) hash to the pre-boot area of YOUR backup (partition-hashes.txt line
#    'preboot-area', or $DQ10_IDENTITY_SHA256), i.e. it really is your stick's unmodified vendor eMMC. (e) is skipped only with --skip-identity, which is
#    needed solely when repeating after a partial/previous write (the first 36 MiB are no longer the vendor ones then);
#  * input files are hash-checked before anything is written, including the DECOMPRESSED rootfs;
#  * order = zero everything (this also kills the vendor GPT, both boot0 copies, boot_package and the BACKUP GPT at the disk
#    end), then the rootfs at sector 4194304, then the head image: sectors 17..8191, 0..15, and sector 16 (the SPL header =
#    commit point) LAST. An interrupted run leaves no valid SPL -> the BROM goes back to FEL -> run it again from the FEL step;
#  * all large writes use O_DIRECT (oflag=direct), 1 MiB blocks + conv=fsync; read-back uses iflag=direct after
#    blockdev --flushbufs, so the hashes come from the media, not from the page cache;
#  * only the user area is visible over UMS. The eMMC hardware boot partitions (mmcblk0boot0/1) are NOT reachable here; they
#    were read as all-zero (4 MiB each, sha256 bb9f8df6...3af8) from Android and the first-boot wipe service re-checks them.
# Test hooks: the two guard lines tagged "#G-NAME" and "#G-USB" are deleted ONLY in the throw-away test copy that
# tests/test-ums-flash.sh builds to exercise this script on a loop file (a loop device is neither sdX nor USB).
# The environment variables above only SUPPLY the expected identity hash / hash list; no variable or option weakens a guard in this shipped file.
set -euo pipefail

usage() { echo "usage: $0 /dev/sdX [--yes-wipe-everything] [--skip-identity] | [--compare-hashes [hashfile]]"; exit 1; }
[ $# -ge 1 ] || usage
DEVARG=$1; shift
GO=0; SKIPID=0; COMPARE=0
HASHES=${DQ10_PARTITION_HASHES:-}     # your own list, columns: name start_sector sector_count sha256
while [ $# -gt 0 ]; do
  case "$1" in
    --yes-wipe-everything) GO=1;;
    --skip-identity) SKIPID=1;;
    --compare-hashes) COMPARE=1; case "${2:-}" in ""|--*) ;; *) HASHES=$2; shift;; esac;;
    *) echo "unknown option $1"; usage;;
  esac
  shift
done
[ -z "$HASHES" ] || case "$HASHES" in /*) ;; *) HASHES=$PWD/$HASHES;; esac      # the script cd's to the package root below: make a relative path absolute first
[ "$COMPARE" = 0 ] || { [ "$GO" = 0 ] && [ "$SKIPID" = 0 ]; } || { echo "--compare-hashes is read-only and cannot be combined with --yes-wipe-everything / --skip-identity"; exit 1; }
cd "$(dirname "$0")/.."

SZ=15634268160
ID_SHA=${DQ10_IDENTITY_SHA256:-}      # sha256 of sectors 0..73727 of YOUR vendor eMMC (from your backup); see the header
SUMS=image/SHA256SUMS                  # written by scripts/build-image.sh (sha256sum format)
want() { awk -v f="$1" '{ n=$2; sub(/^[*]/, "", n) } n==f { print $1; exit }' "$SUMS" 2>/dev/null || true; }
ROOTGZ_SHA=$(want rootfs.ext4.gz)     # optional (gzip output is not guaranteed to be identical across gzip builds)
ROOT_SHA=$(want rootfs.ext4)          # decompressed, 1280 MiB
HEAD_SHA=$(want head-emmc-4MiB.bin)   # sectors 0..8191
ROOT_SECTOR=4194304
ROOT_END=6815744                                                               # ROOT_SECTOR + 2621440
TOTAL_SECTORS=30535680

fail() { echo "REFUSE: $*"; exit 1; }
[ "$(id -u)" = 0 ] || fail "run as root"
DEV=$(readlink -f "$DEVARG")
[ -b "$DEV" ] || fail "$DEVARG is not a block device"
BN=$(basename "$DEV")
case "$BN" in sd[a-z]|sd[a-z][a-z]) ;; *) fail "unexpected device name $BN (expected a whole disk /dev/sdX)";; esac   #G-NAME
SYSDEV=$(readlink -f "/sys/block/$BN/device" 2>/dev/null || true)
echo "$SYSDEV" | grep -Eq '/usb[0-9]+/' || fail "$DEV is not a USB device (sysfs path: ${SYSDEV:-none}); WSL's own disks are never USB"   #G-USB
[ "$(blockdev --getsize64 "$DEV")" = "$SZ" ] || fail "$DEV size $(blockdev --getsize64 "$DEV") != $SZ (the DQ10 eMMC)"
# mounted (whole disk or any partition: /dev/sdX, /dev/sdX1, /dev/sdXp1) or swap -> refuse
if awk -v d="$DEV" '{ if ($1==d || (index($1,d)==1 && substr($1,length(d)+1) ~ /^p?[0-9]+$/)) f=1 } END { exit !f }' /proc/mounts /proc/swaps; then
  fail "$DEV (or a partition of it) is mounted or used as swap"
fi
VENDOR=$(cat "/sys/block/$BN/device/vendor" 2>/dev/null || true)
MODEL=$(cat "/sys/block/$BN/device/model" 2>/dev/null || true)
echo "device : $DEV  vendor='${VENDOR% }' model='${MODEL% }'  size=$SZ"
echo "         (expected: Route L gadget vendor 'DQ10' model 'eMMC flasher'; Route F U-Boot UMS vendor 'Linux' model 'UMS disk 0')"
case "${VENDOR% }/${MODEL% }" in
  DQ10*/eMMC\ flasher*|Linux*/UMS\ disk\ 0*) ;;
  *) echo "WARNING: vendor/model are neither the Route L gadget nor the U-Boot UMS disk (the hard guards - USB, exact size, identity hash - still apply)";;
esac
# did the host's sd driver see the write-protect bit (flasher booted with dq10mode=ro / LUN ro=1)?  Only visible in the kernel log.
WPLINE=$(dmesg 2>/dev/null | grep -F "[$BN] Write Protect is" | tail -n 1 || true)
echo "         kernel log: ${WPLINE:-no 'Write Protect' line for $BN found}"
blockdev --setro "$DEV"          # read-only until we really write
if [ "$COMPARE" = 1 ]; then
  [ -n "$HASHES" ] || fail "no hash list: give --compare-hashes FILE or set DQ10_PARTITION_HASHES (your own partition-hashes.txt: 'name start_sector sector_count sha256' per line)"
  [ -r "$HASHES" ] || fail "hash list $HASHES is not readable"
  echo "== READ-ONLY partition-hash compare against $HASHES (blockdev --setro stays; this mode never calls setrw and has no write path)"
  nok=0; nbad=0
  while read -r pn ps pc ph; do
    ph=${ph%$'\r'}                                  # the list may have been written on Windows: tolerate CRLF
    [ -n "$pn" ] || continue
    case "$ps$pc" in *[!0-9]*) fail "malformed line in $HASHES: $pn $ps $pc";; esac
    [ ${#ph} = 64 ] || fail "malformed hash in $HASHES for $pn"
    # largest block size that divides both the byte offset and the byte length (1 MiB direct reads are far faster than 512 B ones)
    bs=512
    for t in 1048576 65536 4096; do
      if [ $(( ps * 512 % t )) = 0 ] && [ $(( pc * 512 % t )) = 0 ]; then bs=$t; break; fi
    done
    g=$(dd if="$DEV" bs=$bs skip=$(( ps * 512 / bs )) count=$(( pc * 512 / bs )) iflag=direct status=none | sha256sum | cut -c1-64) || g=READ-ERROR
    if [ "$g" = "$ph" ]; then printf 'OK   %-18s start %-8s count %s\n' "$pn" "$ps" "$pc"; nok=$((nok+1))
    else printf 'BAD  %-18s start %-8s count %s  got %s\n' "$pn" "$ps" "$pc" "$g"; nbad=$((nbad+1)); fi
  done < "$HASHES"
  echo "COMPARE: $nok equal, $nbad different/unreadable (list: $HASHES)"
  if [ "$nbad" = 0 ]; then echo "COMPARE OK - the eMMC is byte-for-byte the backed-up partitions listed. Nothing was written."; exit 0; fi
  echo "COMPARE FOUND DIFFERENCES. Nothing was written. (If a vendor FAT partition such as bootloader_a differs, something - e.g. Windows - wrote to it.)"
  exit 4
fi
echo "== input files"
[ ${#ROOT_SHA} = 64 ] && [ ${#HEAD_SHA} = 64 ] || fail "$SUMS missing or incomplete (need rootfs.ext4 and head-emmc-4MiB.bin lines; scripts/build-image.sh writes it)"
[ -z "$ROOTGZ_SHA" ] || [ "$(sha256sum image/rootfs.ext4.gz | cut -c1-64)" = "$ROOTGZ_SHA" ] || fail "rootfs.ext4.gz hash mismatch"
[ "$(sha256sum image/head-emmc-4MiB.bin | cut -c1-64)" = "$HEAD_SHA" ] || fail "head-emmc-4MiB.bin hash mismatch"
[ "$(zcat image/rootfs.ext4.gz | sha256sum | cut -c1-64)" = "$ROOT_SHA" ] || fail "decompressed rootfs hash mismatch"
echo "   rootfs.ext4.gz, its decompressed content and head-emmc-4MiB.bin match $SUMS"
if [ "$SKIPID" = 0 ]; then
  if [ -z "$ID_SHA" ] && [ -n "$HASHES" ] && [ -r "$HASHES" ]; then       # derive it from the 'preboot-area' line of your own hash list
    ID_SHA=$(awk '$1=="preboot-area" && $2==0 && $3==73728 { sub(/\r$/, "", $4); print $4; exit }' "$HASHES")
  fi
  [ ${#ID_SHA} = 64 ] || fail "no identity hash: set DQ10_IDENTITY_SHA256 or DQ10_PARTITION_HASHES (from YOUR backup, see docs/FLASH-PLAN.md), or pass --skip-identity if you understand why"
  echo "== identity: first 36 MiB (sectors 0..73727) must equal the pre-boot area of your backup"
  ID=$(dd if="$DEV" bs=1M count=36 iflag=direct status=none | sha256sum | cut -c1-64) || ID=READ-ERROR
  echo "   got $ID"
  [ "$ID" = "$ID_SHA" ] || fail "identity hash differs from your backup (not the original vendor eMMC state). If an earlier run of THIS script was interrupted, repeat with --skip-identity; otherwise STOP and investigate"
else
  echo "== identity check SKIPPED (--skip-identity): only valid when repeating after an interrupted write of this script"
fi
if [ "$GO" = 1 ]; then
  case "$WPLINE" in *"is on"*) fail "the sd driver reported WRITE PROTECT for $BN: the stick exports the eMMC read-only (flasher booted with flasher-ro.uenv / dq10mode=ro). Power-cycle into FEL and load flasher-rw.uenv.";; esac
fi
if [ "$GO" = 0 ]; then
  echo "DRY RUN OK - nothing was written. It would: zero all $TOTAL_SECTORS sectors, write the rootfs at sector $ROOT_SECTOR,"
  echo "write the head (sectors 17..8191, 0..15, then 16 last) and verify. Re-run with --yes-wipe-everything to WIPE $DEV completely."
  exit 0
fi

echo "!! writing to $DEV in 5 s - Ctrl-C now to abort. This destroys the vendor Android (you must have your own backup of the eMMC)."
sleep 5
WRITING=1
# shellcheck disable=SC2329  # invoked via trap
on_exit() {
  local rc=$?
  if [ "${WRITING:-0}" = 1 ] && [ "$rc" -ne 0 ]; then
    echo "WRITE PHASE FAILED (rc=$rc). Do NOT power-cycle blindly: if the UMS disk is still attached re-run with --skip-identity;"
    echo "otherwise power-cycle the stick (it returns to FEL: the SPL is either intact or invalid) and repeat from the FEL step."
    exit 3
  fi
}
trap on_exit EXIT
blockdev --setrw "$DEV"
echo "== 1/5 zero the whole eMMC user area (14910 MiB)"
dd if=/dev/zero of="$DEV" bs=1M count=14910 oflag=direct conv=fsync status=progress
echo "== 2/5 root filesystem -> sector $ROOT_SECTOR (1280 MiB)"
zcat image/rootfs.ext4.gz | dd of="$DEV" bs=1M seek=2048 iflag=fullblock oflag=direct conv=fsync status=progress
echo "== 3/5 head: sectors 17..8191, then 0..15, then sector 16 (SPL header) LAST"
dd if=image/head-emmc-4MiB.bin of="$DEV" bs=512 skip=17 seek=17 count=8175 oflag=direct conv=fsync status=none
dd if=image/head-emmc-4MiB.bin of="$DEV" bs=512 skip=0  seek=0  count=16   oflag=direct conv=fsync status=none
dd if=image/head-emmc-4MiB.bin of="$DEV" bs=512 skip=16 seek=16 count=1    oflag=direct conv=fsync status=none
sync "$DEV"; blockdev --flushbufs "$DEV"
WRITING=0
trap - EXIT

echo "== 4/5 verify from the media (iflag=direct); 6 s pause first: the Route L flasher drops its own page cache every 2 s, so the read-back is served by the eMMC"
sleep 6
bad=0
H=$(dd if="$DEV" bs=1M count=4 iflag=direct status=none | sha256sum | cut -c1-64) || H=READ-ERROR       # sectors 0..8191 = 4 MiB
if [ "$H" = "$HEAD_SHA" ]; then echo "head   OK"; else echo "HEAD MISMATCH $H"; bad=1; fi
R=$(dd if="$DEV" bs=1M skip=2048 count=1280 iflag=direct status=none | sha256sum | cut -c1-64) || R=READ-ERROR
if [ "$R" = "$ROOT_SHA" ]; then echo "rootfs OK"; else echo "ROOTFS MISMATCH $R"; bad=1; fi
echo "== 5/5 zero check of everything else (front gap, and the tail incl. where the vendor backup GPT was)"
# both ranges are MiB-aligned (sector 8192 = 4 MiB, ROOT_END = 3328 MiB): 1 MiB direct reads, 512-byte reads would take hours over USB
if cmp -n $(( (ROOT_SECTOR-8192)*512 )) <(dd if="$DEV" bs=1M skip=4 count=$(( (ROOT_SECTOR-8192)/2048 )) iflag=direct status=none) /dev/zero; then
  echo "front zero OK"; else echo "FRONT NOT ZERO"; bad=1; fi
if cmp -n $(( (TOTAL_SECTORS-ROOT_END)*512 )) <(dd if="$DEV" bs=1M skip=$(( ROOT_END/2048 )) iflag=direct status=none) /dev/zero; then
  echo "tail zero OK (to the last sector)"; else echo "TAIL NOT ZERO"; bad=1; fi
blockdev --setro "$DEV"
if [ $bad = 0 ]; then
  echo "ALL VERIFIED. Now (Windows) 'usbipd detach --hardware-id <the id you attached>', unplug the stick's power for 10 s, plug it in again WITHOUT the button."
  echo "Do NOT keep it in FEL/the flasher unless you want to re-flash."
  exit 0
fi
echo "VERIFICATION FAILED - re-run with --yes-wipe-everything --skip-identity BEFORE power-cycling (the data is on the stick, the media disagrees)"
exit 2
