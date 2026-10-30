#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# build-fel-bundle.sh - build a ZERO-WRITE "full test boot" bundle for FEL (Linux kernel + our DTB + an initramfs that
# carries the AIC8800 modules/firmware and a few tools), to be loaded into RAM with sunxi-fel.  Run as root in WSL.
# Nothing is written to the stick by building it; running it later (sunxi-fel) writes only RAM.
set -euo pipefail
PKG=$(cd "$(dirname "$0")/.." && pwd)
WORK=${DQ10_WORK:-$HOME/dq10-work}
ROOTFS=${ROOTFS:-$WORK/final/rootfs.ext4}
DTB=${DTB:-$PKG/dts/sun50i-h616-dq10-athena-p1.dtb}
OUT=${OUT:-$WORK/felbundle}
KVER=6.18.53-current-sunxi64
rm -rf "$OUT"; mkdir -p "$OUT/rd" "$OUT/mnt"; cd "$OUT"
mount -o loop,ro "$ROOTFS" mnt; trap 'umount -l "$OUT/mnt" 2>/dev/null || true' EXIT
R=$OUT/rd
mkdir -p $R/{usr/bin,usr/sbin,usr/lib,etc,proc,sys,dev,tmp,run}; ln -sfn usr/lib $R/lib
cp mnt/boot/Image Image 2>/dev/null || cp -L mnt/boot/vmlinuz-$KVER Image
cp "$DTB" dq10.dtb
# --- binaries (+ every shared library they need, resolved with readelf on the target rootfs) ---
copy_bin() { # $1 = path inside rootfs
  local src=mnt$1; [ -e "$src" ] || { echo "missing $1"; return 1; }
  install -D -m755 "$src" "$R$1"
  local interp; interp=$(aarch64-linux-gnu-readelf -l "$src" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
  [ -n "$interp" ] && install -D -m755 "mnt$interp" "$R$interp" 2>/dev/null || true
  for l in $(aarch64-linux-gnu-readelf -d "$src" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
    local f; f=$(find mnt/usr/lib mnt/lib -name "$l" 2>/dev/null | head -1)
    [ -n "$f" ] || { echo "lib $l not found"; continue; }
    local rel=${f#mnt}; [ -e "$R$rel" ] || { install -D -m755 "$f" "$R$rel"; copy_bin "$rel"; }
  done
}
# the rootfs has no busybox: use Debian trixie's busybox-static (arm64, static) fetched and sha256-checked separately
BUSYBOX=${BUSYBOX:-$PKG/dl-busybox-static-arm64/x/usr/bin/busybox}
install -D -m755 "$BUSYBOX" $R/usr/bin/busybox
for b in /usr/sbin/iw /usr/bin/lsusb /usr/bin/mmc; do
  [ -e mnt$b ] && copy_bin $b || true
done
# merged-/usr symlinks so /bin/sh etc. exist
for a in sh ash mount umount mkdir ls cat echo sleep ps dmesg ip ifconfig insmod rmmod lsmod modprobe cp mv rm grep sed awk head tail find dd hexdump xxd cut tr wc date uname free df switch_root poweroff reboot setsid cttyhack mknod ln chmod vi tee test; do
  ln -sf busybox $R/usr/bin/$a 2>/dev/null || true
done
rm -rf $R/bin $R/sbin; ln -sfn usr/bin $R/bin; ln -sfn usr/sbin $R/sbin
# --- kernel modules needed for Wi-Fi (with dependencies) + our AIC modules ---
MODS=$(modprobe -d "$OUT/mnt" -S $KVER --show-depends aic8800_fdrv | awk '/^insmod/{print $2}')
[ -n "$MODS" ] || { echo "no modules resolved"; exit 1; }
for m in $MODS; do install -D -m644 "$m" "$R${m#$OUT/mnt}"; done
depmod -b $R $KVER
echo "modules in initramfs:"; (cd $R && find lib/modules -name '*.ko' -printf '  %P\n')
# --- firmware ---
mkdir -p $R/lib/firmware; cp -a mnt/usr/lib/firmware/aic8800_fw $R/lib/firmware/; cp -a mnt/usr/lib/firmware/regulatory.db* $R/lib/firmware/ 2>/dev/null || true
# --- init ---
cat > $R/init <<'EOT'
#!/bin/sh
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev; mount -t tmpfs tmp /tmp
exec </dev/console >/dev/console 2>&1
echo; echo "=========== DQ10 FEL TEST BOOT (RAM only, eMMC untouched) ==========="
uname -a; free -m | head -2
echo "--- cmdline:"; cat /proc/cmdline
echo "--- DRM / HDMI:"; dmesg | grep -i -E "drm|hdmi|sun4i|fb0|framebuffer" | tail -12; ls /dev/dri /dev/fb0 2>&1
echo "--- regulators:"; for r in /sys/class/regulator/regulator.*; do echo "  $(cat $r/name) $(cat $r/microvolts 2>/dev/null)"; done
echo "--- mmc / sdio devices:"; ls /sys/bus/sdio/devices 2>&1; for d in /sys/bus/sdio/devices/*; do [ -e $d/vendor ] && echo "  $(basename $d) $(cat $d/vendor) $(cat $d/device)"; done
echo "--- eMMC visible (READ ONLY test):"; ls -l /dev/mmcblk* 2>&1 | head
echo "--- loading Wi-Fi modules"
modprobe aic8800_fdrv 2>&1; sleep 6
dmesg | grep -i -E "aicbsp|aicwf|rwnx|aic8800|firmware|mmc1" | tail -25
echo "--- network interfaces:"; ip link 2>&1
ip link set wlan0 up 2>&1; sleep 2
echo "--- scan (iw dev wlan0 scan):"; iw dev wlan0 scan 2>&1 | grep -E "^BSS|SSID:|signal:|freq:" | head -60
echo; echo "=========== done. Shell on the console (type 'dmesg | tail' etc.). ==========="
exec setsid cttyhack /bin/sh
EOT
chmod +x $R/init
( cd $R && find . | cpio -o -H newc --quiet | gzip -9 ) > initramfs.cpio.gz
ISZ=$(stat -c %s initramfs.cpio.gz)
# --- U-Boot boot script (loaded to the FEL script address 0x4fc00000 and auto-run by "bootcmd_fel") ---
cat > boot.cmd <<EOT
echo ==== DQ10 FEL test boot: kernel + dtb + initramfs from RAM ====
setenv bootargs "console=tty1 console=ttyS0,115200 loglevel=7 rdinit=/init keep_bootcon"
fdt addr \${fdt_addr_r}
fdt resize 65536
booti \${kernel_addr_r} \${ramdisk_addr_r}:$(printf '0x%x' $ISZ) \${fdt_addr_r}
EOT
mkimage -A arm64 -O linux -T script -C none -n dq10-fel-boot -d boot.cmd boot.scr >/dev/null
ls -l Image dq10.dtb initramfs.cpio.gz boot.scr; sha256sum Image dq10.dtb initramfs.cpio.gz boot.scr > SHA256SUMS
cat > RUN-ME.txt <<EOT
# From WSL (stick in FEL mode, attached with usbipd). Addresses are U-Boot's sunxi arm64 defaults (include/configs/sunxi-common.h):
#   kernel_addr_r=0x40080000  fdt_addr_r=0x4fa00000  scriptaddr/fel script=0x4fc00000  ramdisk_addr_r=0x4ff00000
sunxi-fel -v -p uboot uboot/u-boot-sunxi-with-spl.bin \
  write 0x40080000 felbundle/Image \
  write 0x4fa00000 felbundle/dq10.dtb \
  write 0x4ff00000 felbundle/initramfs.cpio.gz \
  write 0x4fc00000 felbundle/boot.scr
# initramfs size: $ISZ bytes ($(printf '0x%x' $ISZ)) is baked into boot.scr
# SUPERSEDED (revision 4): this boot.scr route failed on 2026-10-30 (autoboot with BOOTDELAY=2/preboot); the working pattern is a uEnv with
# bootdelay=-2 (diag/d5-linux.uenv). Its dq10.dtb is the revision-3 DTB (PH6 LED active-high; the LED is active-low).
# After the test boot: unplug the stick's power adapter. A plain power-up no longer returns to FEL (the vendor efex flag is gone); to re-enter FEL hold the button while plugging in the power. Nothing was written to the eMMC.
# The flash route is Route L (docs/FLASH-PLAN.md Part 1, flasher/, scripts/ums-flash.sh).
EOT
cat RUN-ME.txt
