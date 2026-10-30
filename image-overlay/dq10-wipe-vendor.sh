#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# dq10-wipe-vendor.sh - first-boot clean-up of the DQ10 eMMC.
#
# Runs ONCE (service dq10-wipe-vendor.service, before armbian-resize-filesystem)
# from the already-installed Linux.  It zero-fills every sector that is not
# (a) [0, 8192): MBR + SPL + U-Boot (+gap), or (b) the root partition p1,
# so that no Android/vendor data survives, then verifies that everything
# outside those two areas reads back as zero.  Afterwards Armbian's own
# first-boot resize grows p1 to the end of the disk.
#
# It REFUSES to run (and wipes nothing) unless the layout is exactly the
# expected one: a single partition, an eGON SPL at sector 16, the disk is an
# eMMC with boot partitions.
set -u
mkdir -p /var/lib/dq10
LOG=/var/lib/dq10/wipe.log   # on the real disk (not /var/log, which Armbian moves to zram)
exec > >(tee -a "$LOG" /dev/tty1 2>/dev/null) 2>&1
echo "=== dq10-wipe-vendor $(date -u +%FT%TZ) ==="

die() { echo "ABORT: $*"; exit 1; }

rootpart=$(findmnt -no SOURCE /) || die "cannot find root"
pname=$(basename "$rootpart")
disk=/dev/$(lsblk -no PKNAME "$rootpart" | head -1)
dname=$(basename "$disk")
[ -b "$disk" ] || die "no disk for $rootpart"
[ "$pname" = "${dname}p1" ] || die "root is $pname, expected ${dname}p1"
[ -e "/sys/block/${dname}boot0" ] || die "$dname has no eMMC boot partitions - not the expected eMMC"
nparts=$(lsblk -nr -o TYPE "$disk" | grep -c '^part$')
[ "$nparts" = 1 ] || die "disk has $nparts partitions, expected exactly 1"
total=$(blockdev --getsz "$disk")
start=$(cat /sys/class/block/$pname/start)
size=$(cat /sys/class/block/$pname/size)
end=$((start + size))
echo "disk=$disk total=$total p1_start=$start p1_size=$size p1_end=$end"
[ "$start" -ge 8192 ] || die "p1 starts below sector 8192"
[ "$end" -le "$total" ] || die "p1 end beyond disk"
magic=$(dd if="$disk" bs=512 skip=16 count=1 status=none | dd bs=1 skip=4 count=8 status=none)
[ "$magic" = "eGON.BT0" ] || die "no eGON SPL at sector 16 (found '$magic') - refusing to wipe"

zero_range() { # from_sector to_sector(exclusive)
  local a=$1 b=$2
  [ "$b" -gt "$a" ] || return 0
  echo "zeroing sectors $a..$((b-1)) ($(( (b-a)/2048 )) MiB)"
  # 1 MiB blocks; sectors are 2048-aligned for the start; handle tail via sector-sized dd
  local mib_start=$(( (a + 2047) / 2048 )) mib_end=$(( b / 2048 ))
  if [ "$mib_end" -gt "$mib_start" ]; then
    [ $((mib_start*2048)) -gt "$a" ] && dd if=/dev/zero of="$disk" bs=512 seek="$a" count=$((mib_start*2048-a)) conv=notrunc,fsync status=none
    dd if=/dev/zero of="$disk" bs=1M seek="$mib_start" count=$((mib_end-mib_start)) conv=notrunc,fsync status=progress
    [ "$b" -gt $((mib_end*2048)) ] && dd if=/dev/zero of="$disk" bs=512 seek=$((mib_end*2048)) count=$((b-mib_end*2048)) conv=notrunc,fsync status=none
  else
    dd if=/dev/zero of="$disk" bs=512 seek="$a" count=$((b-a)) conv=notrunc,fsync status=none
  fi
}
verify_zero() {
  local a=$1 b=$2
  [ "$b" -gt "$a" ] || return 0
  # cmp against /dev/zero for the exact byte length
  if cmp -s -n $(( (b-a)*512 )) <(dd if="$disk" bs=1M iflag=skip_bytes,count_bytes skip=$((a*512)) count=$(( (b-a)*512 )) status=none) /dev/zero; then
    echo "verified zero: sectors $a..$((b-1))"; return 0
  fi
  echo "NOT ZERO: sectors $a..$((b-1))"; return 1
}

sync; blockdev --flushbufs "$disk"
zero_range 8192 "$start"
zero_range "$end" "$total"
sync; blockdev --flushbufs "$disk"; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
rc=0
verify_zero 8192 "$start" || rc=1
verify_zero "$end" "$total" || rc=1

# eMMC hardware boot partitions: should already be empty (they were on the
# original device); verify, and zero them if not.
for b in ${dname}boot0 ${dname}boot1; do
  if [ -b /dev/$b ]; then
    n=$(blockdev --getsz /dev/$b)
    if cmp -s -n $((n*512)) /dev/$b /dev/zero; then echo "$b: empty"; else
      echo "$b: NOT empty -> zeroing"
      echo 0 > /sys/block/$b/force_ro 2>/dev/null
      dd if=/dev/zero of=/dev/$b bs=1M conv=fsync status=none
      echo 1 > /sys/block/$b/force_ro 2>/dev/null
      cmp -s -n $((n*512)) /dev/$b /dev/zero && echo "$b: now empty" || { echo "$b: STILL NOT EMPTY"; rc=1; }
    fi
  fi
done

if [ $rc -eq 0 ]; then
  echo "WIPE OK - nothing outside [0,8192) and p1 remains."
  mkdir -p /var/lib/dq10 && date -u +%FT%TZ > /var/lib/dq10/wipe-done
else
  echo "WIPE INCOMPLETE - see above; will retry on next boot."
  exit 1
fi
