#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# usage: run.sh <uboot.bin> <uenv>   (RAM only)
cd "$(dirname "$0")/.."
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sunxi-fel ver >/dev/null 2>&1 && break; sleep 0.5; done
sunxi-fel -v -p uboot "$1" write 0x43100000 "$2" 2>&1 | tr '\r' '\n' | grep -E "uEnv|Passing|Starting|RVBAR|ERROR|rror"
echo "fel-exit=$? $(date +%T)"
