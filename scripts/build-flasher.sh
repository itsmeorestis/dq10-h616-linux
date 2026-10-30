#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# build-flasher.sh - build the ROUTE L flasher bundle (flasher/): the shipped kernel + a "peripheral" DTB + an initramfs whose
# /init exports the stick's eMMC over USB (configfs gadget: mass storage + ACM serial).  Run as root in WSL kali-linux (or any Debian-like Linux with the tools below).
# Nothing is written to the stick by building it; the bundle is loaded into RAM later with sunxi-fel (flasher/RUN-ME.txt).
#
# Inputs (all checked against pinned hashes; override with env):
#   ROOTFS   the shipped eMMC rootfs.ext4 (kernel Image + modules come from it)  default $DQ10_WORK/final/rootfs.ext4
#   BUSYBOX  Debian trixie busybox-static (arm64) binary                          default <repo>/dl-busybox-static-arm64/x/usr/bin/busybox
#   DTSTREE  kernel v6.18.53 dts tree + Armbian patches 0041/0042 (docs/BUILD-NOTES.md sec. 13) default $DQ10_WORK/dtstree
#   OUT      scratch/output dir                                                   default $DQ10_WORK/flasher
# Output: <pkg>/flasher/{Image,dq10-flasher.dtb,initramfs.cpio.gz,flasher-ro.uenv,flasher-rw.uenv,RUN-ME.txt,SHA256SUMS}
set -euo pipefail
PKG=$(cd "$(dirname "$0")/.." && pwd)
WORK=${DQ10_WORK:-$HOME/dq10-work}
ROOTFS=${ROOTFS:-$WORK/final/rootfs.ext4}
BUSYBOX=${BUSYBOX:-$PKG/dl-busybox-static-arm64/x/usr/bin/busybox}
DTSTREE=${DTSTREE:-$WORK/dtstree}
OUT=${OUT:-$WORK/flasher}
KVER=6.18.53-current-sunxi64
IMAGE_SHA=e5bc78d4e3a6776f70cb5efe8be0f6e989095ead8498100ce70920018bc9cfce       # the kernel Image of the shipped Armbian (= felbundle/Image)
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
for t in cpp dtc cpio gzip modprobe depmod aarch64-linux-gnu-readelf busybox; do command -v $t >/dev/null || { echo "missing tool $t"; exit 1; }; done
[ -f "$ROOTFS" ] && [ -f "$BUSYBOX" ] && [ -d "$DTSTREE" ] || { echo "missing input (ROOTFS/BUSYBOX/DTSTREE)"; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT/rd" "$OUT/mnt"; cd "$OUT"
mount -o loop,ro "$ROOTFS" mnt; trap 'umount -l "$OUT/mnt" 2>/dev/null || true' EXIT
R=$OUT/rd

echo "== kernel Image"
cp mnt/boot/Image Image
[ "$(sha256sum Image | cut -c1-64)" = "$IMAGE_SHA" ] || { echo "Image hash differs from the pinned shipped kernel"; exit 1; }
# header: text_offset, image_size, flags (U-Boot's booti relocates a bit-3 image to ALIGN(base,2M)+text_offset)
TEXT_OFF=$(od -An -t u8 -j8  -N8 Image | tr -d ' ')
IMG_SIZE=$(od -An -t u8 -j16 -N8 Image | tr -d ' ')
FLAGS=$(od -An -t u8 -j24 -N8 Image | tr -d ' ')
[ "$(( FLAGS & 8 ))" = 8 ] || { echo "kernel flags bit 3 not set: booti would relocate to a different address, re-do the overlap check"; exit 1; }

echo "== DTBs (cpp | dtc -@ against $DTSTREE; the base DTB must reproduce dts/*.dtb byte for byte)"
D=$DTSTREE/arch/arm64/boot/dts/allwinner
bld() { cpp -nostdinc -I "$D" -I "$DTSTREE/include" -I "$PKG/dts" -undef -D__DTS__ -x assembler-with-cpp "$PKG/dts/$1" > "$2.tmp"
        dtc -@ -I dts -O dtb -o "$2" "$2.tmp" 2>&1 | grep -v -e unit_address -e '^$' || true; }
bld sun50i-h616-dq10-athena-p1.dts main.dtb
if [ -f "$PKG/dts/sun50i-h616-dq10-athena-p1.dtb" ]; then
  cmp main.dtb "$PKG/dts/sun50i-h616-dq10-athena-p1.dtb" || { echo "base DTB does not reproduce dts/*.dtb"; exit 1; }
else   # binaries are not kept in git: the first build creates the (git-ignored) reference DTB that build-image.sh also uses
  echo "   no dts/sun50i-h616-dq10-athena-p1.dtb yet: byte-for-byte check skipped, writing it from this build"
  cp main.dtb "$PKG/dts/sun50i-h616-dq10-athena-p1.dtb"
fi
bld sun50i-h616-dq10-athena-p1-flasher.dts dq10-flasher.dtb
# the flasher DTB must really be a gadget DTB without VBUS drive
dtc -I dtb -O dts dq10-flasher.dtb 2>/dev/null > flasher.dts.txt
grep -q 'dr_mode = "peripheral"' flasher.dts.txt || { echo "dr_mode peripheral missing"; exit 1; }
grep -q 'usb0_vbus-supply' flasher.dts.txt && { echo "usb0_vbus-supply still present"; exit 1; }
cp "$PKG/dts/sun50i-h616-dq10-athena-p1-flasher.dts" .

echo "== initramfs"
mkdir -p $R/usr/bin $R/etc $R/proc $R/sys $R/dev $R/tmp $R/run
ln -sfn usr/lib $R/lib; ln -sfn bin $R/usr/sbin; ln -sfn usr/bin $R/bin; ln -sfn usr/bin $R/sbin
copy_bin() { # $1 = path inside rootfs; copies the binary and the shared libraries it needs
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
install -D -m755 "$BUSYBOX" $R/usr/bin/busybox
# every applet the init and the shell help text rely on must exist in this busybox build
APPLETS="sh ash mount umount mkdir ls cat echo sleep ln dd sha256sum hexdump blockdev lsmod insmod modprobe rmmod setsid dmesg printf tr seq readlink basename awk sed grep cut head tail sync reboot poweroff od test expr chmod rm cp mv date uname free df ps kill find tee wc sort stat cmp fdisk id clear mknod xargs uniq"
tr '\0' '\n' < "$BUSYBOX" | grep -a -x -E '[a-z0-9\[]{1,16}' | sort -u > applets.txt
for a in $APPLETS; do grep -qx "$a" applets.txt || { echo "busybox lacks applet $a"; exit 1; }; ln -sf busybox $R/usr/bin/$a; done
[ -e mnt/usr/bin/mmc ] && copy_bin /usr/bin/mmc || true       # mmc-utils (extcsd reads for diagnostics)
# --- modules: MUSB (sunxi glue), configfs, libcomposite, mass storage, ACM, each with its dependency chain, in load order
: > modlist.txt
for m in sunxi configfs libcomposite usb_f_mass_storage usb_f_acm; do
  modprobe -d "$OUT/mnt" -S $KVER --show-depends $m | awk '/^insmod/{print $2}' >> modlist.txt
done
awk '!s[$0]++' modlist.txt > modlist.u
[ -s modlist.u ] || { echo "no modules resolved"; exit 1; }
for m in $(cat modlist.u); do
  vm=$(modinfo -F vermagic "$m" | cut -d' ' -f1); [ "$vm" = "$KVER" ] || { echo "vermagic mismatch $m"; exit 1; }
  install -D -m644 "$m" "$R${m#$OUT/mnt}"
done
depmod -b $R $KVER
echo "modules in the initramfs:"; (cd $R && find lib/modules -name '*.ko' -printf '  %P\n' | sort)
# the kernel config must offer everything the init relies on (built-in or module)
CFG=mnt/boot/config-$KVER
for c in CONFIG_USB_MUSB_SUNXI=m CONFIG_USB_MUSB_DUAL_ROLE=y CONFIG_USB_CONFIGFS=m CONFIG_USB_CONFIGFS_MASS_STORAGE=y CONFIG_USB_CONFIGFS_ACM=y CONFIG_USB_GADGET=y CONFIG_PHY_SUN4I_USB=y CONFIG_LEDS_TRIGGER_TIMER=y CONFIG_LEDS_GPIO=y CONFIG_DEVTMPFS=y CONFIG_MMC_SUNXI=y; do
  grep -qx "$c" $CFG || { echo "kernel config lacks $c"; exit 1; }
done
# --- init
install -m755 "$PKG/scripts/flasher-init.sh" $R/init
$(command -v busybox) sh -n $R/init
# --- cpio, deterministic: fixed mtimes, sorted names, no inode numbers, gzip -n
find $R -exec touch -h -d @0 {} +
( cd $R && find . | LC_ALL=C sort | cpio -o -H newc --quiet --reproducible --owner 0:0 ) | gzip -9 -n > initramfs.cpio.gz
ISZ=$(stat -c %s initramfs.cpio.gz); IHEX=$(printf '0x%x' "$ISZ")
echo "initramfs.cpio.gz: $ISZ bytes ($IHEX)"

echo "== load-address / overlap check"
KADDR=0x40080000; FDTADDR=0x4fa00000; RDADDR=0x4ff00000; UADDR=0x43100000; UBOOT_LOAD=0x4a000000
DTB_SZ=$(stat -c %s dq10-flasher.dtb)
RELOC=$(( ( (KADDR - TEXT_OFF + 0x1fffff) & ~0x1fffff ) + TEXT_OFF ))   # booti: ALIGN(image - text_offset, 2M) + text_offset
python3 -I - "$KADDR" "$(stat -c %s Image)" "$RELOC" "$IMG_SIZE" "$FDTADDR" "$((DTB_SZ + 65536))" "$RDADDR" "$ISZ" "$UADDR" "$UBOOT_LOAD" <<'PY'
import sys
k,ksz,rel,isz,f,fsz,r,rsz,u,ub=[int(x,0) for x in sys.argv[1:]]
reg=[("Image as written by sunxi-fel",k,ksz),("Image after booti relocation",rel,isz),("FDT (+64 KiB fdt resize)",f,fsz),
     ("initramfs",r,rsz),("uEnv (0x10000 reserved)",u,0x10000)]
for n,a,s in reg: print("  %-32s 0x%08x .. 0x%08x" % (n,a,a+s))
def ov(a,b): return a[1]<b[1]+b[2] and b[1]<a[1]+a[2]
bad=0
# staged-in-RAM regions must not overlap each other; the relocated kernel must not hit FDT / initramfs / uEnv
for i in (0,2,3,4):
    for j in (0,2,3,4):
        if i<j and ov(reg[i],reg[j]): print("OVERLAP:",reg[i][0],"/",reg[j][0]); bad=1
for j in (2,3):
    if ov(reg[1],reg[j]): print("OVERLAP:",reg[1][0],"/",reg[j][0]); bad=1
# U-Boot proper is loaded by sunxi-fel at ub (0x4a000000, ~0.9 MB) and relocates itself to the top of DRAM; BL31 sits at 0x40000000..0x4001xxxx
if ov(reg[0],("u",ub,0x100000)) : print("OVERLAP: Image staging / U-Boot load area"); bad=1
if ov(reg[4],("u",ub,0x100000)) : print("OVERLAP: uEnv / U-Boot load area"); bad=1
if rel < 0x40100000: print("relocated kernel inside BL31 area"); bad=1
sys.exit(bad)
PY
echo "  (the uEnv is read by U-Boot's misc_init_r before booti moves the kernel, so even a relocated kernel end beyond 0x43100000 would be harmless; here it is not)"

echo "== uEnv files"
mkuenv() { # $1 = ro|rw  $2 = out
  cat > "$2" <<EOT
#=uEnv
bootdelay=-2
preboot=
bootcmd=setenv stdin nulldev; gpio clear PH6; sleep 1; gpio set PH6; sleep 1; gpio clear PH6; setenv bootargs "console=tty1 loglevel=4 rdinit=/init dq10mode=$1"; fdt addr $FDTADDR; fdt resize 65536; booti $KADDR $RDADDR:$IHEX $FDTADDR; while true; do gpio clear PH6; sleep 0.15; gpio set PH6; sleep 0.15; gpio clear PH6; sleep 0.15; gpio set PH6; sleep 0.15; gpio clear PH6; sleep 0.15; gpio set PH6; sleep 1.5; done
EOT
}
mkuenv ro flasher-ro.uenv; mkuenv rw flasher-rw.uenv
# U-Boot "reach bootcmd" tests (D2 pattern): blink PH6, leave a marker in RAM, `reset` -> FEL must come back.
#   reach-override.uenv : bootdelay=-2 + empty preboot (the override that worked 3/3 on 2026-10-30)
#   reach-flashed.uenv  : ONLY bootcmd - the compiled-in BOOTDELAY=2, keyed autoboot (STOP_STR dq10stop) and preboot="usb start"
#                         stay in force = what the eMMC boot will run; proves that keyed autoboot reaches bootcmd without help.
cat > reach-override.uenv <<'EOT'
#=uEnv
bootdelay=-2
preboot=
blink=gpio clear PH6; sleep 1; gpio set PH6; sleep 1; gpio clear PH6; sleep 1; gpio set PH6
bootcmd=run blink; mw.l 0x00100000 0xd10c0001; sleep 12; reset
EOT
cat > reach-flashed.uenv <<'EOT'
#=uEnv
blink=gpio clear PH6; sleep 1; gpio set PH6; sleep 1; gpio clear PH6; sleep 1; gpio set PH6
bootcmd=run blink; mw.l 0x00100000 0xd10c0002; sleep 12; reset
EOT
grep -c $'\r' flasher-ro.uenv flasher-rw.uenv | grep -v ':0' && { echo "CR in uenv"; exit 1; } || true
cat > RUN-ME.txt <<EOT
# ROUTE L - load the flasher into RAM (nothing is written to the stick).  From WSL, stick in FEL (button held while plugging in the
# power adapter, USB A-A cable to the PC, usbipd-attached 1f3a:efe8), working dir = the package root.
# Addresses (U-Boot sunxi defaults): kernel 0x40080000 (booti moves it to $(printf '0x%x' $RELOC), image_size $IMG_SIZE), fdt $FDTADDR,
# ramdisk $RDADDR, uEnv $UADDR.  initramfs size $ISZ bytes ($IHEX) is baked into the uEnv.
# READ-ONLY session first (identity + partition-hash compare):
sunxi-fel -v -p uboot uboot/u-boot-sunxi-with-spl.bin write 0x40080000 flasher/Image write $FDTADDR flasher/dq10-flasher.dtb write $RDADDR flasher/initramfs.cpio.gz write $UADDR flasher/flasher-ro.uenv
# WRITE session (after the read-only checks passed; power-cycle into FEL again first):
sunxi-fel -v -p uboot uboot/u-boot-sunxi-with-spl.bin write 0x40080000 flasher/Image write $FDTADDR flasher/dq10-flasher.dtb write $RDADDR flasher/initramfs.cpio.gz write $UADDR flasher/flasher-rw.uenv
# The -v output must contain "Passing boot info via sunxi SPL: script address = $UADDR".
# U-Boot reach test (run each 3x, hold the button as in the plan; FEL must come back after ~15 s = bootcmd was reached):
sunxi-fel -v -p uboot uboot/u-boot-sunxi-with-spl.bin write $UADDR flasher/reach-override.uenv
sunxi-fel -v -p uboot uboot/u-boot-sunxi-with-spl.bin write $UADDR flasher/reach-flashed.uenv      # compiled-in config, keyed autoboot
EOT
sha256sum Image dq10-flasher.dtb initramfs.cpio.gz flasher-ro.uenv flasher-rw.uenv reach-override.uenv reach-flashed.uenv > SHA256SUMS
mkdir -p "$PKG/flasher"
cp Image dq10-flasher.dtb initramfs.cpio.gz flasher-ro.uenv flasher-rw.uenv reach-override.uenv reach-flashed.uenv RUN-ME.txt SHA256SUMS "$PKG/flasher/"
ls -l "$PKG/flasher"; cat SHA256SUMS
