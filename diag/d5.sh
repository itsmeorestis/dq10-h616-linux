#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
cd "$(dirname "$0")/.."
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sunxi-fel ver >/dev/null 2>&1 && break; sleep 0.5; done
(cd felbundle && sha256sum -c --quiet SHA256SUMS) && echo bundle-ok
date +%T
sunxi-fel -v -p uboot uboot/u-boot-sunxi-with-spl.bin write 0x40080000 felbundle/Image write 0x4fa00000 felbundle/dq10.dtb write 0x4ff00000 felbundle/initramfs.cpio.gz write 0x43100000 diag/d5-linux.uenv 2>&1 | tr '\r' '\n' | grep -E "uEnv|Starting|ERROR"
echo "fel-exit=$? $(date +%T)"
