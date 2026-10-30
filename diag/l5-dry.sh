#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
cd "$(dirname "$0")/.."
lsblk -o NAME,SIZE,VENDOR,MODEL,TRAN,RO
DEV=$(lsblk -dno NAME,TRAN,MODEL | awk '$2=="usb" && /eMMC flasher/ {print "/dev/"$1}')
echo "DEV=$DEV size=$(blockdev --getsize64 $DEV) ro=$(blockdev --getro $DEV)"
dmesg | grep -i "write protect" | tail -2
bash scripts/ums-flash.sh $DEV --skip-identity 2>&1 | tail -20; echo "dry rc=${PIPESTATUS[0]}"
