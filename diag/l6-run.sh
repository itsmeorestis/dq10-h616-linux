#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# L6 runner: detached write; log + rc file (the operator started it after the explicit go-ahead).
cd "$(dirname "$0")/.."
DEV=$(lsblk -dno NAME,TRAN,MODEL | awk '$2=="usb" && /eMMC flasher/ {print "/dev/"$1}')
echo "L6 start $(date '+%F %T') DEV=$DEV" > /root/ums-flash.log
rm -f /root/ums-flash.rc
bash scripts/ums-flash.sh "$DEV" --skip-identity --yes-wipe-everything >> /root/ums-flash.log 2>&1
rc=$?
echo "L6 end $(date '+%F %T') rc=$rc" >> /root/ums-flash.log
echo $rc > /root/ums-flash.rc
