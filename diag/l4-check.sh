#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
cd "$(dirname "$0")/.."
L=/root/l4-$(date +%F-%H%M)
echo "size=$(blockdev --getsize64 /dev/sde) ro=$(blockdev --getro /dev/sde)"
bash scripts/ums-flash.sh /dev/sde > "$L-dryrun.log" 2>&1; echo "dryrun rc=$?"
tail -25 "$L-dryrun.log"
bash scripts/ums-flash.sh /dev/sde --compare-hashes > "$L-compare.log" 2>&1; echo "compare rc=$?"
tail -40 "$L-compare.log"
