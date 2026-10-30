#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# fel-dram-test.sh - OPTIONAL, only if the stick is in FEL mode (USB id 1f3a:efe8) and attached to WSL via usbipd.
# Runs OUR SPL (DRAM init with the decoded vendor parameters) from the BROM over USB and then tests the 2 GiB of DRAM
# with patterns.  Writes NOTHING to the eMMC (only SRAM/DRAM).  NOT EXECUTED by the build agent.
set -u
SPL=${1:-uboot/u-boot-sunxi-with-spl.bin}
command -v sunxi-fel >/dev/null || { echo "sunxi-fel missing (apt install sunxi-tools)"; exit 1; }
sunxi-fel -l || exit 1
sunxi-fel ver || exit 1
echo "== run SPL (DRAM init); the SPL returns to the BROM FEL loop afterwards"
sunxi-fel -v spl "$SPL" || { echo "SPL/DRAM INIT FAILED"; exit 2; }
echo "== DRAM test: 16 MiB pattern blocks at 128 MiB steps over 0x40000000..0xBFFFFFFF"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
head -c 16777216 /dev/urandom > "$T/pat.bin"
bad=0
for i in $(seq 0 15); do
  A=$(printf '0x%08x' $((0x40000000 + i*0x08000000 + 0x00100000)))   # skip the first MiB (BL31/SPL area)
  sunxi-fel write $A "$T/pat.bin" || { echo "write failed @ $A"; bad=1; continue; }
  sunxi-fel read $A 16777216 "$T/rb.bin" || { echo "read failed @ $A"; bad=1; continue; }
  cmp -s "$T/pat.bin" "$T/rb.bin" && echo "ok   $A" || { echo "BAD  $A"; bad=1; }
done
[ $bad = 0 ] && echo "DRAM PATTERN TEST PASSED" || echo "DRAM PATTERN TEST FAILED"
echo "(addresses above 0x80000000 only exist if all 2 GiB were detected; a failure there means the size detection or the training is wrong)"
exit $bad
