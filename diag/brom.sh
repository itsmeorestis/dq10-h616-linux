#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sunxi-fel ver >/dev/null 2>&1 && break; sleep 0.5; done
sunxi-fel ver
cd /root; sunxi-fel read 0x0 0x10000 brom-dq10.bin; ls -l brom-dq10.bin
cd "$(dirname "$0")/.."
B=${BLOBS:-dl-sunxi-blobs-h616-brom}   # published NBROM/SBROM references (docs/BUILD-NOTES.md sec. 1)
sha256sum brom-dq10.bin $B/nbrom-sun50iw9p1.bin $B/sbrom-sun50iw9p1.bin
cmp brom-dq10.bin $B/nbrom-sun50iw9p1.bin && echo "IDENTICAL TO NBROM"
cmp -l brom-dq10.bin $B/nbrom-sun50iw9p1.bin | wc -l
od -A x -t x1z -N 64 brom-dq10.bin | head -4
