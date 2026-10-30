#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
T=/root/l4diff; mkdir -p $T
dd if=/dev/sde of=$T/now.bin bs=1M count=36 iflag=direct status=none
gzip -dc "${1:?usage: l4-diff.sh /path/to/your-backup.img.gz}" | head -c 37748736 > $T/bak.bin
sha256sum $T/now.bin $T/bak.bin
cmp -l $T/bak.bin $T/now.bin > $T/diff.txt; echo "differing bytes: $(wc -l < $T/diff.txt)"
awk '{s=int(($1-1)/512); c[s]++} END {for (k in c) print k, c[k]}' $T/diff.txt | sort -n > $T/sectors.txt
echo "differing sectors (sector count_of_bytes):"; head -40 $T/sectors.txt; echo "total sectors: $(wc -l < $T/sectors.txt)"
echo "--- first 40 differing bytes (offset(1-based) old(octal) new(octal)):"; head -40 $T/diff.txt
