#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
cd "$(dirname "$0")/.."
for i in 1 2 3 4 5 6 7 8 9 10; do sunxi-fel ver >/dev/null 2>&1 && break; sleep 0.5; done
sunxi-fel spl uboot/u-boot-sunxi-with-spl.bin; echo "spl-exit=$? $(date +%T)"; sunxi-fel ver
