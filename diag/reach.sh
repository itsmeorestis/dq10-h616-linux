#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# usage: reach.sh <uenv>  - run new main U-Boot with a reach uEnv (RAM only)
cd "$(dirname "$0")/.."
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sunxi-fel ver >/dev/null 2>&1 && break; sleep 0.5; done
sunxi-fel writel 0x00100000 0 2>&1 | head -1
sunxi-fel -v -p uboot uboot/u-boot-sunxi-with-spl.bin write 0x43100000 "$1" 2>&1 | tr '\r' '\n' | grep -E "Passing|rror"
echo "started $(date +%T.%N | cut -c1-10)"
