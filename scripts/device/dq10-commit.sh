#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# dq10-commit.sh - runs ON THE STICK (Android root shell). NOT EXECUTED by the build agent.
# Pre-condition: /dev/dq10-head.bin (4 MiB = sectors 0..8191 of the new disk) is on the tmpfs /dev
# and the root filesystem has already been staged + verified at sector 4194304.
# Order matters: everything except sector 16 first, sector 16 (eGON header of OUR SPL) LAST.
# Protect this shell from the OOM killer (the stick has only tens of MB free): the commit must not die half way.
echo -1000 > /proc/self/oom_score_adj 2>/dev/null
H=/dev/dq10-head.bin
D=/dev/block/mmcblk0
# HEADSHA pins the maintainer's REFERENCE build of head-emmc-4MiB.bin. A head image you built yourself has a different hash: replace this
# value with the head-emmc-4MiB.bin line of YOUR image/SHA256SUMS (build-image.sh writes it) before pushing the script to the stick,
# otherwise the script aborts at the hash check below (safe, but useless).
HEADSHA=81566c4080f1703974b42e9ddf2ec2e20de3a4e835792fb90fb817e0d2b0dc95
LOG=/dev/dq10-commit.log
exec > $LOG 2>&1
set -x
[ "$(sha256sum $H | cut -c1-64)" = "$HEADSHA" ] || { echo "ABORT: head file hash mismatch"; exit 1; }
[ "$(blockdev --getsize64 $D)" = 15634268160 ] || { echo "ABORT: not the expected eMMC size"; exit 1; }
# (1) sectors 17..8191: our U-Boot FIT + zeros. This invalidates BOTH vendor boot0 copies (BROM -> FEL if power fails now)
dd if=$H of=$D bs=512 skip=17 seek=17 count=8175 conv=notrunc,fsync || { echo "FAIL step1"; exit 2; }
# (2) sectors 0..15: new MBR (p1 @ 4194304) + zeros (destroys the vendor GPT header at LBA1)
dd if=$H of=$D bs=512 skip=0 seek=0 count=16 conv=notrunc,fsync || { echo "FAIL step2"; exit 3; }
# (3) sector 16: the SPL's eGON header = the commit point
dd if=$H of=$D bs=512 skip=16 seek=16 count=1 conv=notrunc,fsync || { echo "FAIL step3"; exit 4; }
sync
blockdev --flushbufs $D
echo 3 > /proc/sys/vm/drop_caches
GOT=$(dd if=$D bs=512 count=8192 2>/dev/null | sha256sum | cut -c1-64)
echo "readback=$GOT expected=$HEADSHA"
[ "$GOT" = "$HEADSHA" ] && echo COMMIT-VERIFIED-OK || echo COMMIT-VERIFY-FAILED
