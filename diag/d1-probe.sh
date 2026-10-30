#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sunxi-fel ver 2>/dev/null && break; sleep 0.5; done
echo "PLL_DDR0 0x03001010: $(sunxi-fel readl 0x03001010)"
echo "PLL_CPUX 0x03001000: $(sunxi-fel readl 0x03001000)"
sunxi-fel hexdump 0x00020000 32
for r in 0 1 2 3 4 5 6 7; do a=$((0x07000100 + 4*r)); printf 'RTC GP%d 0x%08x: %s\n' $r $a "$(sunxi-fel readl $a)"; done
