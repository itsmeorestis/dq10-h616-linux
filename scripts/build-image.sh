#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# build-image.sh - reproducible assembly of the DQ10 Armbian image (run as root inside WSL kali-linux or any Debian-like Linux).
#
# SSH: NO key is baked into the image unless you pass one:  AUTHORIZED_KEY=/path/to/your_key.pub  sudo -E scripts/build-image.sh
#      (a public key file, one or more lines; it is installed as /root/.ssh/authorized_keys, root:root 0600).  Without it the image
#      has no SSH login at all (sshd is key-only, see image-overlay/10-dq10-sshd.conf): use the HDMI console + USB keyboard, or add a key
#      afterwards (docs/FLASH-PLAN.md section 8.1).
# Inputs (all pinned in BUILD-NOTES.md):
#   $ORIG   Armbian_26.8.7_Tanix-tx6s-axp313_trixie_current_6.18.53_minimal.img (decompressed, sha256 checked)
#   $UBOOT  u-boot-sunxi-with-spl.bin  (U-Boot v2026.10 + TF-A v2.15.0, dq10_athena_p1_defconfig)
#   $DTB    sun50i-h616-dq10-athena-p1.dtb
# Outputs in $OUT:
#   rootfs.ext4              1.25 GiB ext4, pruned firmware, our dtb, wipe service
#   head-emmc-4MiB.bin       sectors 0..8191 for the eMMC layout (MBR p1@4194304, U-Boot @ 8 KiB)
#   dq10-armbian.img         conventional layout (p1@8192) - SD/USB/other uses, NOT what we flash
set -euo pipefail
PKG=$(cd "$(dirname "$0")/.." && pwd)
WORK=${DQ10_WORK:-$HOME/dq10-work}
ORIG=${ORIG:-$WORK/armbian/orig.img}
UBOOT=${UBOOT:-$PKG/uboot/u-boot-sunxi-with-spl.bin}      # build it first (docs/BUILD-NOTES.md sec. 13)
DTB=${DTB:-$PKG/dts/sun50i-h616-dq10-athena-p1.dtb}      # build it first (docs/BUILD-NOTES.md sec. 13)
OVL=${OVL:-$PKG/image-overlay}
OUT=${OUT:-$WORK/final}
AUTHORIZED_KEY=${AUTHORIZED_KEY:-}
[ -z "$AUTHORIZED_KEY" ] || [ -r "$AUTHORIZED_KEY" ] || { echo "AUTHORIZED_KEY=$AUTHORIZED_KEY is not a readable file"; exit 1; }
DTSNAME=sun50i-h616-dq10-athena-p1
TOTAL=30535680             # eMMC sectors (15,634,268,160 / 512)
P1_START_EMMC=4194304      # 2 GiB: inside the free tail of the Android 'super' partition
P1_SECT=2621440            # 1.25 GiB
# sha256 of the reference build of uboot/dq10_athena_p1_defconfig (docs/BUILD-NOTES.md sec. 14). A U-Boot you build yourself may differ
# byte-wise (toolchain): then pass UBOOT_SHA=$(sha256sum "$UBOOT" | cut -d" " -f1) after checking it with scripts/fel-dram-test.sh.
UBOOT_SHA=${UBOOT_SHA:-48691413166cb499c2f2328290e7ff5fd700064e980b57871a934ce693e1ea72}
[ "$(sha256sum "$UBOOT" | cut -d" " -f1)" = "$UBOOT_SHA" ] || { echo "UBOOT is not the pinned main build (set UBOOT_SHA to accept your own build)"; exit 1; }
[ "$(sha256sum "$ORIG" | cut -d' ' -f1)" = f9f73601234c29b29f8c58813923a76243ad8c1a234fbbcf287be0d099f1916a ] || { echo "orig.img sha mismatch"; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT/mnt"; cd "$OUT"

echo "== extract partition 1 of the Armbian image"
dd if="$ORIG" of=part1.ext4 bs=512 skip=8192 count=3014656 status=none
mount -o loop part1.ext4 mnt
trap 'umount -l "$OUT/mnt" 2>/dev/null || true' EXIT
KVER=6.18.53-current-sunxi64

echo "== our DTB: /boot/dq10-dtb + into the kernel dtb dir"
install -d mnt/boot/dq10-dtb
install -m644 "$DTB" mnt/boot/dq10-dtb/$DTSNAME.dtb
install -m644 "$DTB" mnt/boot/dtb-$KVER/allwinner/$DTSNAME.dtb
# armbianEnv.txt is read by boot.scr: select our DTB, from a dir that survives kernel/dtb package upgrades
cat >> mnt/boot/armbianEnv.txt <<EOT
fdtdir=/boot/dq10-dtb
fdtfile=$DTSNAME.dtb
EOT
sed -i 's/^console=.*/console=both/' mnt/boot/armbianEnv.txt

echo "== prune /lib/firmware (keep only regulatory db; AIC8800 fw is re-installed from the Radxa package below)"
FW=mnt/usr/lib/firmware; [ -d $FW ] || FW=mnt/lib/firmware
du -sh $FW | tee "$OUT/firmware-before.txt"
ls $FW > "$OUT/firmware-removed-list.txt"
find $FW -mindepth 1 -maxdepth 1 ! -name 'regulatory.db*' -exec rm -rf {} +
du -sh $FW | tee "$OUT/firmware-after.txt"
ls -R $FW | head -50 > "$OUT/firmware-kept-list.txt"
# dpkg would complain about missing files only on verify; hold the package so apt does not re-add 440 MB
python3 "$OVL/hold-firmware.py" mnt/var/lib/dpkg/status


echo "== AIC8800D80 Wi-Fi: prebuilt out-of-tree modules + firmware from radxa-pkg/aic8800"
AICSRC=${AICSRC:-$WORK/aic}
AICDRV=$AICSRC/src/SDIO/driver_fw/driver/aic8800
KMOD=mnt/lib/modules/$KVER/extra/aic8800
install -d $KMOD
for m in aic8800_bsp aic8800_fdrv aic8800_btlpm; do
  aarch64-linux-gnu-strip --strip-debug -o $KMOD/$m.ko $AICDRV/$m/$m.ko
  modinfo -F vermagic $KMOD/$m.ko
done
depmod -b mnt $KVER
printf 'aic8800_bsp
aic8800_fdrv
' > mnt/etc/modules-load.d/aic8800.conf
FWD=mnt/usr/lib/firmware/aic8800_fw/SDIO/aic8800D80
install -d $FWD
cp $AICSRC/src/SDIO/driver_fw/fw/aic8800D80/*.bin $AICSRC/src/SDIO/driver_fw/fw/aic8800D80/*.txt $FWD/
( cd $FWD && sha256sum * ) > "$OUT/aic8800-firmware-installed.sha256"
( cd $KMOD && sha256sum *.ko ) > "$OUT/aic8800-modules.sha256"
cp $AICSRC/RADXA_COMMIT "$OUT/" 2>/dev/null || true
install -d mnt/usr/share/doc/dq10
cat > mnt/usr/share/doc/dq10/WIFI.txt <<'EOT'
DQ10 Wi-Fi: AIC8800D80 (SDIO c8a1:0082 / c8a1:0182), driver = radxa-pkg/aic8800 (see BUILD-NOTES.md),
modules in /lib/modules/$(uname -r)/extra/aic8800/ (built for exactly this kernel; they must be rebuilt
after a kernel upgrade), firmware in /lib/firmware/aic8800_fw/SDIO/aic8800D80/.
Debug: dmesg | grep -i -E 'aic|mmc1|sdio' ; ls /sys/bus/sdio/devices ; ip link ; iw dev ; rfkill list
EOT

echo "== first-boot wipe service + ordering before Armbian's resize"
install -m755 "$OVL/dq10-wipe-vendor.sh" mnt/usr/local/sbin/dq10-wipe-vendor.sh
install -m644 "$OVL/dq10-wipe-vendor.service" mnt/etc/systemd/system/dq10-wipe-vendor.service
install -d mnt/etc/systemd/system/basic.target.wants mnt/etc/systemd/system/armbian-resize-filesystem.service.d
ln -sf /etc/systemd/system/dq10-wipe-vendor.service mnt/etc/systemd/system/basic.target.wants/dq10-wipe-vendor.service
install -m644 "$OVL/dq10-resize-after-wipe.conf" mnt/etc/systemd/system/armbian-resize-filesystem.service.d/dq10.conf
echo dq10 > mnt/etc/hostname
sed -i 's/\btanix-tx6s-axp313\b/dq10/g' mnt/etc/hosts 2>/dev/null || true
grep -q '127.0.1.1' mnt/etc/hosts && sed -i 's/^127.0.1.1.*/127.0.1.1\tdq10/' mnt/etc/hosts || echo -e '127.0.1.1\tdq10' >> mnt/etc/hosts


echo "== SSH: key-only root + sshd drop-in"
install -d mnt/etc/ssh/sshd_config.d
install -m 644 "$OVL/10-dq10-sshd.conf" mnt/etc/ssh/sshd_config.d/00-dq10.conf
if [ -n "$AUTHORIZED_KEY" ]; then
  echo "   baking the PUBLIC key(s) from $AUTHORIZED_KEY into /root/.ssh/authorized_keys"
  install -d -m 700 -o root -g root mnt/root/.ssh
  install -m 600 -o root -g root "$AUTHORIZED_KEY" mnt/root/.ssh/authorized_keys
  ls -la mnt/root/.ssh
  ssh-keygen -lf mnt/root/.ssh/authorized_keys | tee "$OUT/authorized_key.fingerprint"
else
  echo "   AUTHORIZED_KEY not set: NO ssh key is baked in (console login only; add a key later, docs/FLASH-PLAN.md 8.1)"
fi

echo "== bookkeeping"
( cd mnt && find boot/dq10-dtb usr/local/sbin etc/systemd/system -newer "$ORIG" -type f 2>/dev/null | sort ) > "$OUT/files-added.txt" || true
df -h mnt | tail -1
umount mnt; trap - EXIT

echo "== shrink to minimum, then grow to exactly $P1_SECT sectors"
e2fsck -fy part1.ext4 >/dev/null || true
resize2fs -M part1.ext4 2>&1 | tail -1
BLOCKS=$(( P1_SECT * 512 / 4096 ))
truncate -s $(( P1_SECT * 512 )) part1.ext4
resize2fs part1.ext4 $BLOCKS 2>&1 | tail -1
e2fsck -fn part1.ext4 | tail -2
tune2fs -l part1.ext4 | grep -E 'UUID|Block count|Filesystem volume name|Free blocks'
mv part1.ext4 rootfs.ext4

echo "== MBR for the eMMC layout (p1 @ $P1_START_EMMC) and conventional layout (p1 @ 8192)"
mk_mbr() { # $1=outfile $2=start $3=disksize_sectors
  truncate -s $(( $3 * 512 )) "$1"
  sfdisk -q "$1" <<EOT
label: dos
label-id: 0x85d82b93
unit: sectors
start=$2, size=$P1_SECT, type=83
EOT
}
mk_mbr mbr-emmc.img $P1_START_EMMC $TOTAL
dd if=mbr-emmc.img of=head-emmc-4MiB.bin bs=512 count=8192 status=none
rm mbr-emmc.img
# U-Boot (SPL at 8 KiB = sector 16). Sectors 1..15 are zero => no GPT header.
dd if="$UBOOT" of=head-emmc-4MiB.bin bs=1k seek=8 conv=notrunc status=none
# conventional image
mk_mbr dq10-armbian.img 8192 $(( 8192 + P1_SECT ))
dd if="$UBOOT" of=dq10-armbian.img bs=1k seek=8 conv=notrunc status=none
dd if=rootfs.ext4 of=dq10-armbian.img bs=512 seek=8192 conv=notrunc status=none

echo "== SD image gets its own filesystem UUID (avoids root=UUID ambiguity when SD + eMMC are both present)"
SDUUID=5d1e0c10-d9a0-4a58-8c3b-d09d10a7c0de
LOOP=$(losetup -f --show -o $((8192*512)) --sizelimit $((P1_SECT*512)) dq10-armbian.img)
e2fsck -fy $LOOP >/dev/null || true
tune2fs -U $SDUUID $LOOP >/dev/null
mkdir -p sdm && mount $LOOP sdm
sed -i "s/^rootdev=.*/rootdev=UUID=$SDUUID/" sdm/boot/armbianEnv.txt
sed -i "s/e70cdb2c-6e3a-442f-9d56-99fd4c5ecae5/$SDUUID/g" sdm/etc/fstab
grep -n "UUID" sdm/boot/armbianEnv.txt sdm/etc/fstab
umount sdm; rmdir sdm; e2fsck -fn $LOOP | tail -1; losetup -d $LOOP

sfdisk -d dq10-armbian.img
rmdir mnt
sha256sum rootfs.ext4 head-emmc-4MiB.bin dq10-armbian.img | tee SHA256SUMS
gzip -9 -k -n rootfs.ext4
sha256sum rootfs.ext4.gz >> SHA256SUMS      # scripts/ums-flash.sh reads image/SHA256SUMS (copy this file next to the images)
ls -la
