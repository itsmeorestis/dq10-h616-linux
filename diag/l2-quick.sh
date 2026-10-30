#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
cd "$(dirname "$0")/.."
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sunxi-fel ver >/dev/null 2>&1 && break; sleep 0.5; done
sha256sum uboot/u-boot-sunxi-with-spl.bin
sunxi-fel spl uboot/u-boot-sunxi-with-spl.bin; echo "spl-exit=$?"
sleep 1; sunxi-fel ver || exit 1
head -c 2097152 /dev/urandom > /tmp/p.bin; bad=0
for A in 0x42000000 0x5fe00000 0x7fe00000 0x9fe00000 0xbfe00000; do
  sunxi-fel write $A /tmp/p.bin && sunxi-fel read $A 2097152 /tmp/r.bin && cmp -s /tmp/p.bin /tmp/r.bin && echo "ok $A" || { echo "BAD $A"; bad=1; }
done
[ $bad = 0 ] && echo "DRAM QUICK TEST PASSED" || echo "DRAM QUICK TEST FAILED"
