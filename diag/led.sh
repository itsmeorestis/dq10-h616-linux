#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Toggle PH6/PH7 via the PIO registers (RAM-mapped I/O only). H616 PIO: port H cfg0 0x0300B0FC, data 0x0300B10C
CFG=0x0300B0FC; DAT=0x0300B10C
c=$(sunxi-fel readl $CFG); d=$(sunxi-fel readl $DAT)
echo "before: cfg0=$c data=$d"
mode=$1   # e.g. "6 1" = PH6 high
pin=$2; val=$3
c=$(( c & ~(0xF << (pin*4)) | (1 << (pin*4)) ))
if [ "$val" = 1 ]; then d=$(( d | (1<<pin) )); else d=$(( d & ~(1<<pin) )); fi
sunxi-fel writel $DAT $d
sunxi-fel writel $CFG $c
echo "after:  cfg0=$(sunxi-fel readl $CFG) data=$(sunxi-fel readl $DAT)"
