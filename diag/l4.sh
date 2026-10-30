#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
cd "$(dirname "$0")/.."
(cd flasher && sha256sum -c --quiet SHA256SUMS) && echo flasher-sums-ok || exit 1
sha256sum uboot/u-boot-sunxi-with-spl.bin | cut -c1-16
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sunxi-fel ver >/dev/null 2>&1 && break; sleep 0.5; done
echo "start $(date +%T)"
sunxi-fel -v -p uboot uboot/u-boot-sunxi-with-spl.bin write 0x40080000 flasher/Image write 0x4fa00000 flasher/dq10-flasher.dtb write 0x4ff00000 flasher/initramfs.cpio.gz write 0x43100000 flasher/flasher-ro.uenv 2>&1 | tr '\r' '\n' | grep -E "Passing|Starting|rror"
echo "fel-exit=$? $(date +%T)"
