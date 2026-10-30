#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# test-ums-flash.sh - exercises scripts/ums-flash.sh on LOOP DEVICES backed by sparse files (never a real device).
# Run as root (WSL or any Linux with loop devices):  bash tests/test-ums-flash.sh
# Needs ~16 GiB free in /tmp (the two full-write tests really write 14910 MiB of zeros to the backing file).
# No real vendor data and no built image are needed: the "vendor pre-boot area" and the image files (rootfs.ext4.gz,
# head-emmc-4MiB.bin, SHA256SUMS) are generated synthetically.  To test against your own built image instead:
#   IMAGE_DIR=/path/to/image bash tests/test-ums-flash.sh      (a directory with rootfs.ext4.gz, head-emmc-4MiB.bin, SHA256SUMS)
# The shipped script refuses loop devices (not sdX, not USB). For the positive tests a throw-away COPY is made in which
# ONLY the two lines tagged #G-NAME and #G-USB are deleted; every other guard (size, mounted, identity hash, input hashes)
# and the write/verify logic run unchanged.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=/tmp/dq10ums
SZ=15634268160
rm -rf $T; mkdir -p $T/tree/scripts; cd $T || exit 1
for i in 0 1 2 3 4 5 6 7 8 9 10 11; do [ -b /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
# a previous --setro on a loop device survives detach/re-attach of the same /dev/loopN: reset it for every new loop device
nl() { local d; d=$(losetup -f --show "$@") || return 1; blockdev --setrw "$d"; echo "$d"; }
# --- synthetic "vendor pre-boot area" (36 MiB) and synthetic image files with their SHA256SUMS ---
PRE=$T/preboot.bin
yes DQ10-TEST-PREBOOT-AREA | head -c 37748736 > $PRE
export DQ10_IDENTITY_SHA256=$(sha256sum $PRE | cut -c1-64)
if [ -n "${IMAGE_DIR:-}" ]; then
  ln -s "$(readlink -f "$IMAGE_DIR")" $T/tree/image
else
  mkdir -p $T/tree/image
  truncate -s 1342177280 $T/rootfs.raw
  for o in 0 1 700 1279; do head -c 1048576 /dev/urandom | dd of=$T/rootfs.raw bs=1M seek=$o conv=notrunc status=none; done
  head -c 4194304 /dev/zero > $T/tree/image/head-emmc-4MiB.bin
  head -c 600000 /dev/urandom | dd of=$T/tree/image/head-emmc-4MiB.bin bs=1 seek=0 conv=notrunc status=none
  gzip -1 -n -c $T/rootfs.raw > $T/tree/image/rootfs.ext4.gz
  ( cd $T && sha256sum rootfs.raw | sed 's/rootfs.raw/rootfs.ext4/' ; cd tree/image && sha256sum head-emmc-4MiB.bin rootfs.ext4.gz ) > $T/tree/image/SHA256SUMS
  rm -f $T/rootfs.raw
fi
EXPECT_ROOT=$(awk '$2=="rootfs.ext4"{print $1}' $T/tree/image/SHA256SUMS)
EXPECT_HEAD=$(awk '$2=="head-emmc-4MiB.bin"{print $1}' $T/tree/image/SHA256SUMS)
cp $REPO/scripts/ums-flash.sh $T/tree/scripts/real.sh
sed -e '/#G-NAME$/d' -e '/#G-USB$/d' $REPO/scripts/ums-flash.sh > $T/tree/scripts/testcopy.sh
echo "guard lines removed in the test copy: $(diff $REPO/scripts/ums-flash.sh $T/tree/scripts/testcopy.sh | grep -c '^<')"
pass=0; failn=0
chk() { # name expected_rc got_rc [pattern file]
  if [ "$2" = "$3" ] && { [ -z "${4:-}" ] || grep -q -- "$4" "$5"; }; then
    echo "PASS $1 (rc=$3)"; pass=$((pass+1))
  else
    echo "FAIL $1 (expected rc=$2 got $3 pattern='${4:-}')"; cat "${5:-/dev/null}"; failn=$((failn+1))
  fi
}
mkimg() { truncate -s "$2" "$1"; dd if=$PRE of="$1" bs=1M conv=notrunc status=none; sync; }   # sync: after a 15 GB write the buffered 36 MiB could still be dirty when the script reads the loop with O_DIRECT
mkimg good.img $SZ
L=$(nl good.img); echo "loop good: $L"

# T1 shipped script on the loop device: refused by the name/USB guard
bash $T/tree/scripts/real.sh "$L" > o1 2>&1; chk "T1 shipped script refuses a loop device" 1 $? "REFUSE: unexpected device name" o1
# T2 non-block path
bash $T/tree/scripts/real.sh /tmp/nothing > o2 2>&1; chk "T2 non-block-device refused" 1 $? "REFUSE" o2
# T3 WSL's own system disk (an sdX name that is not USB) must be refused before anything is touched
RS=$(findmnt -no SOURCE /); PK=$(lsblk -no PKNAME "$RS" 2>/dev/null | head -1); ROOTDISK=/dev/${PK:-$(basename "$RS")}; echo "WSL root source: $RS -> disk $ROOTDISK"
bash $T/tree/scripts/real.sh "$ROOTDISK" > o3 2>&1; chk "T3 WSL system disk $ROOTDISK refused by the USB guard" 1 $? "not a USB device" o3
for d in /dev/sda /dev/sdb /dev/sdc; do
  [ -b $d ] || continue
  bash $T/tree/scripts/real.sh $d > o3b 2>&1; chk "T3b $d refused" 1 $? "REFUSE" o3b
done
# T4 usage
bash $T/tree/scripts/real.sh > o4 2>&1; chk "T4 no argument -> usage" 1 $? "usage" o4
bash $T/tree/scripts/testcopy.sh "$L" --bogus > o4b 2>&1; chk "T4b unknown option" 1 $? "unknown option" o4b

# T5 dry run on the good loop (test copy)
bash $T/tree/scripts/testcopy.sh "$L" > o5 2>&1; chk "T5 dry run on exact-size loop with the vendor pre-boot area" 0 $? "DRY RUN OK" o5
sed 's/^/   | /' o5
SUM0=$(sha256sum good.img | cut -c1-64)
bash $T/tree/scripts/testcopy.sh "$L" > /dev/null 2>&1
[ "$(sha256sum good.img | cut -c1-64)" = "$SUM0" ] && echo "PASS T5b two dry runs left the backing file bit-identical" || echo "FAIL T5b backing file changed"

# T6 wrong size
truncate -s 1073741824 small.img; LS=$(nl small.img)
bash $T/tree/scripts/testcopy.sh "$LS" > o6 2>&1; chk "T6 wrong size refused" 1 $? "size 1073741824" o6; losetup -d "$LS"

# T7 identity mismatch (one flipped byte inside the first 36 MiB)
mkimg bad.img $SZ; printf 'X' | dd of=bad.img bs=1 seek=1000000 conv=notrunc status=none
BADSUM=$(dd if=bad.img bs=1M count=40 status=none | sha256sum | cut -c1-64)
LB=$(nl bad.img)
bash $T/tree/scripts/testcopy.sh "$LB" > o7 2>&1; chk "T7 identity hash mismatch refused" 1 $? "identity hash differs" o7
bash $T/tree/scripts/testcopy.sh "$LB" --yes-wipe-everything > o7b 2>&1; chk "T7b identity mismatch refused also with --yes-wipe-everything" 1 $? "identity hash differs" o7b
[ "$(dd if=bad.img bs=1M count=40 status=none | sha256sum | cut -c1-64)" = "$BADSUM" ] && echo "PASS T7c refused runs wrote nothing" || echo "FAIL T7c bad.img changed"
losetup -d "$LB"

# T8 mounted device refused (filesystem directly on the exact-size loop)
truncate -s $SZ mnt.img; LM=$(nl mnt.img); mkfs.ext4 -q -F "$LM" || echo "SETUP PROBLEM mkfs"; mkdir -p mp; mount "$LM" mp || echo "SETUP PROBLEM mount"; grep -q "^$LM " /proc/mounts || echo "SETUP PROBLEM: $LM not mounted"
bash $T/tree/scripts/testcopy.sh "$LM" > o8 2>&1; chk "T8 mounted device refused" 1 $? "mounted or used as swap" o8
umount mp; losetup -d "$LM"; rm -f mnt.img
# T8b a mounted PARTITION refuses the whole device
mkimg part.img $SZ; printf 'label: dos\nstart=4194304, size=2621440, type=83\n' | sfdisk -q part.img
LP=$(nl -P part.img); sleep 1; mkfs.ext4 -q -F "${LP}p1" && mount "${LP}p1" mp || echo "SETUP PROBLEM part mount"; grep -q "^${LP}p1 " /proc/mounts || echo "SETUP PROBLEM: ${LP}p1 not mounted"
bash $T/tree/scripts/testcopy.sh "$LP" > o8b 2>&1; chk "T8b device with a mounted partition refused" 1 $? "mounted or used as swap" o8b
umount mp; losetup -d "$LP"; rm -f part.img

# T9 full write on the good loop
echo "== T9 full write (15 GB, takes a while)"
START=$(date +%s)
bash $T/tree/scripts/testcopy.sh "$L" --yes-wipe-everything > o9 2>&1; rc=$?
echo "   write+verify took $(( $(date +%s) - START )) s"
chk "T9 full write + verify" 0 $rc "ALL VERIFIED" o9
tr '\r' '\n' < o9 | grep -v -E '^[0-9]+ bytes|copied' | tail -14 | sed 's/^/   | /'
# independent verification (plain reads of the backing file, not the script's own checks)
H=$(dd if=good.img bs=1M count=4 status=none | sha256sum | cut -c1-64)
R=$(dd if=good.img bs=1M skip=2048 count=1280 status=none | sha256sum | cut -c1-64)
[ "$H" = "$EXPECT_HEAD" ] && echo "PASS T9b independent head hash" || echo "FAIL T9b head $H"
[ "$R" = "$EXPECT_ROOT" ] && echo "PASS T9c independent rootfs hash" || echo "FAIL T9c rootfs $R"
Z1=$(cmp -n $(( (4194304-8192)*512 )) <(dd if=good.img bs=1M skip=4 count=2044 status=none) /dev/zero && echo ok)
Z2=$(cmp -n $(( (30535680-6815744)*512 )) <(dd if=good.img bs=1M skip=3328 status=none) /dev/zero && echo ok)
if [ "$Z1" = ok ] && [ "$Z2" = ok ]; then echo "PASS T9d independent zero ranges (front gap + tail)"; else echo "FAIL T9d zero ranges"; fi
echo "   MBR sig: $(dd if=good.img bs=1 skip=510 count=2 status=none | od -An -tx1)  eGON at 8196: $(dd if=good.img bs=1 skip=8196 count=8 status=none)  FIT magic at 49152: $(dd if=good.img bs=1 skip=49152 count=4 status=none | od -An -tx1)"

# T10 a second run is now refused without --skip-identity, accepted with it (dry run)
bash $T/tree/scripts/testcopy.sh "$L" > o10 2>&1; chk "T10 dry run after a write is refused (identity)" 1 $? "identity hash differs" o10
bash $T/tree/scripts/testcopy.sh "$L" --skip-identity > o10b 2>&1; chk "T10b dry run with --skip-identity" 0 $? "DRY RUN OK" o10b
losetup -d "$L"; rm -f good.img

# T11 write-phase failure: dm device = loop (linear) for all but the last MiB, error target for the last MiB
if command -v dmsetup >/dev/null; then
  mkimg ef.img $SZ; LE=$(nl ef.img)
  S=$((SZ/512)); GOOD=$((S-2048))
  printf '0 %d linear %s 0\n%d 2048 error\n' $GOOD "$LE" $GOOD | dmsetup create dq10err 2>/dev/null
  if [ -b /dev/mapper/dq10err ]; then
    bash $T/tree/scripts/testcopy.sh /dev/mapper/dq10err --yes-wipe-everything > o11 2>&1; rc=$?
    chk "T11 write error in the zero phase -> exit 3 with message" 3 $rc "WRITE PHASE FAILED" o11
    tr '\r' '\n' < o11 | tail -3 | sed 's/^/   | /'
    dmsetup remove dq10err
  else echo "SKIP T11 (dmsetup create failed)"; fi
  losetup -d "$LE"; rm -f ef.img
else echo "SKIP T11 (no dmsetup)"; fi
rm -f bad.img small.img

# ================= revision 4 additions =================
echo "== R4: --compare-hashes, READ-ERROR handling, write-protect refusal"
mkimg c.img $SZ; LC=$(nl c.img); BNC=$(basename "$LC")
eh() { dd if=c.img bs=512 skip=$1 count=$2 status=none | sha256sum | cut -c1-64; }
{ echo "preboot-area 0 73728 $(eh 0 73728)"; echo "aligned1m 2048 4096 $(eh 2048 4096)"; echo "aligned64k 128 128 $(eh 128 128)";
  echo "aligned4k 8 8 $(eh 8 8)"; echo "odd512 101 7 $(eh 101 7)"; echo "tailzero 6815744 2048 $(eh 6815744 2048)"; } > h.good
CSUM0=$(dd if=c.img bs=1M count=40 status=none | sha256sum | cut -c1-64); CDU0=$(du -k c.img | cut -f1)
bash $T/tree/scripts/testcopy.sh "$LC" --compare-hashes h.good > o12 2>&1; chk "R4-1 compare: all six equal -> rc 0" 0 $? "COMPARE: 6 equal, 0 different" o12
grep -q "OK   aligned64k" o12 && grep -q "OK   odd512" o12 && grep -q "OK   aligned4k" o12 && echo "PASS R4-1b every block-size path (1M/64K/4K/512) was exercised" || { echo "FAIL R4-1b"; cat o12; failn=$((failn+1)); }
[ "$(blockdev --getro "$LC")" = 1 ] && echo "PASS R4-1c compare left the device read-only (no setrw)" || { echo "FAIL R4-1c device not ro"; failn=$((failn+1)); }
[ "$(dd if=c.img bs=1M count=40 status=none | sha256sum | cut -c1-64)" = "$CSUM0" ] && [ "$(du -k c.img | cut -f1)" = "$CDU0" ] && echo "PASS R4-1d compare wrote nothing (content + allocated size unchanged)" || { echo "FAIL R4-1d"; failn=$((failn+1)); }
awk '$1=="aligned64k" { c=substr($4,1,1); $4=(c=="0" ? "1" : "0") substr($4,2) } { print }' h.good > h.bad   # flip the first hex digit (never a no-op)
bash $T/tree/scripts/testcopy.sh "$LC" --compare-hashes h.bad > o13 2>&1; chk "R4-2 compare: one wrong hash -> rc 4 + BAD line" 4 $? "BAD  aligned64k" o13
grep -q "COMPARE: 5 equal, 1 different" o13 && echo "PASS R4-2b summary counts" || { echo "FAIL R4-2b"; cat o13; failn=$((failn+1)); }
echo "x 1 2 abc" > h.mal; bash $T/tree/scripts/testcopy.sh "$LC" --compare-hashes h.mal > o14 2>&1; chk "R4-3 compare: malformed hash line refused" 1 $? "malformed hash" o14
bash $T/tree/scripts/testcopy.sh "$LC" --compare-hashes /nonexistent > o14b 2>&1; chk "R4-3b compare: missing list refused" 1 $? "not readable" o14b
bash $T/tree/scripts/testcopy.sh "$LC" --compare-hashes h.good --yes-wipe-everything > o14c 2>&1; chk "R4-3c compare + wipe flag refused" 1 $? "cannot be combined" o14c
bash $T/tree/scripts/real.sh "$LC" --compare-hashes h.good > o14d 2>&1; chk "R4-3d shipped script: compare mode still passes the device guards (loop refused)" 1 $? "REFUSE" o14d
# a list written on Windows (CRLF) is accepted
sed 's/$/'"$(printf '\r')"'/' h.good > h.crlf
bash $T/tree/scripts/testcopy.sh "$LC" --compare-hashes h.crlf > o14e 2>&1; chk "R4-3e CRLF hash list is accepted" 0 $? "COMPARE: 6 equal, 0 different" o14e

# ---- identity / hash-list sources (path-independence): nothing is baked into the script ----
echo "== ID: identity hash comes from the environment or from the user's hash list"
( unset DQ10_IDENTITY_SHA256 DQ10_PARTITION_HASHES; bash $T/tree/scripts/testcopy.sh "$LC" > oi1 2>&1 ); chk "ID-1 dry run with no identity source -> refused" 1 $? "no identity hash" oi1
( unset DQ10_IDENTITY_SHA256 DQ10_PARTITION_HASHES; bash $T/tree/scripts/testcopy.sh "$LC" --yes-wipe-everything > oi1b 2>&1 ); chk "ID-1b write mode with no identity source -> refused" 1 $? "no identity hash" oi1b
( unset DQ10_IDENTITY_SHA256; DQ10_PARTITION_HASHES=$PWD/h.good bash $T/tree/scripts/testcopy.sh "$LC" > oi2 2>&1 ); chk "ID-2 identity derived from the preboot-area line of DQ10_PARTITION_HASHES" 0 $? "DRY RUN OK" oi2
( unset DQ10_IDENTITY_SHA256 DQ10_PARTITION_HASHES; bash $T/tree/scripts/testcopy.sh "$LC" --skip-identity > oi3 2>&1 ); chk "ID-3 --skip-identity needs no identity source" 0 $? "identity check SKIPPED" oi3
( unset DQ10_IDENTITY_SHA256; DQ10_PARTITION_HASHES=h.bad bash $T/tree/scripts/testcopy.sh "$LC" --compare-hashes > oi4 2>&1 ); chk "ID-4 --compare-hashes without FILE uses DQ10_PARTITION_HASHES (relative path ok)" 4 $? "BAD  aligned64k" oi4
( unset DQ10_PARTITION_HASHES; bash $T/tree/scripts/testcopy.sh "$LC" --compare-hashes > oi5 2>&1 ); chk "ID-5 --compare-hashes with no list at all -> refused" 1 $? "no hash list" oi5
( DQ10_IDENTITY_SHA256=$(printf x | sha256sum | cut -c1-64) bash $T/tree/scripts/testcopy.sh "$LC" > oi6 2>&1 ); chk "ID-6 wrong identity hash from the environment -> refused" 1 $? "identity hash differs" oi6
mv $T/tree/image/SHA256SUMS $T/SUMS.keep
bash $T/tree/scripts/testcopy.sh "$LC" > oi7 2>&1; chk "ID-7 missing image/SHA256SUMS -> refused before anything is read from the device" 1 $? "SHA256SUMS missing or incomplete" oi7
mv $T/SUMS.keep $T/tree/image/SHA256SUMS

# write protect seen by the sd driver -> write mode refuses before touching anything
mkdir -p fakebin; printf '#!/bin/sh\necho "[%s] Write Protect is on"\n' "$BNC" > fakebin/dmesg; chmod +x fakebin/dmesg
PATH=$T/fakebin:$PATH bash $T/tree/scripts/testcopy.sh "$LC" > o15 2>&1; chk "R4-4 dry run shows the kernel's write-protect line" 0 $? "Write Protect is on" o15
PATH=$T/fakebin:$PATH bash $T/tree/scripts/testcopy.sh "$LC" --yes-wipe-everything > o15b 2>&1; chk "R4-4b write mode refused while write-protected" 1 $? "WRITE PROTECT" o15b
[ "$(dd if=c.img bs=1M count=40 status=none | sha256sum | cut -c1-64)" = "$CSUM0" ] && [ "$(du -k c.img | cut -f1)" = "$CDU0" ] && echo "PASS R4-4c refused write left the image untouched" || { echo "FAIL R4-4c"; failn=$((failn+1)); }

# READ-ERROR handling through dm-flakey (reads fail, writes succeed)
S=$((SZ/512))
modprobe dm-flakey 2>/dev/null
printf '0 %d flakey %s 0 0 3600 1 error_reads\n' $S "$LC" | dmsetup create dq10fl 2>/dev/null
if [ -b /dev/mapper/dq10fl ]; then
  blockdev --setrw /dev/mapper/dq10fl
  bash $T/tree/scripts/testcopy.sh /dev/mapper/dq10fl > o16 2>&1; chk "R4-5 dry run, unreadable media: identity READ-ERROR -> rc 1 (nothing written)" 1 $? "identity hash differs" o16
  grep -q "got READ-ERROR" o16 && echo "PASS R4-5b identity line says READ-ERROR" || { echo "FAIL R4-5b"; cat o16; failn=$((failn+1)); }
  bash $T/tree/scripts/testcopy.sh /dev/mapper/dq10fl --compare-hashes h.good > o16b 2>&1; chk "R4-6 compare on unreadable media -> rc 4, READ-ERROR" 4 $? "got READ-ERROR" o16b
  echo "== R4-7 full write whose read-back fails (15 GB, takes a while)"
  bash $T/tree/scripts/testcopy.sh /dev/mapper/dq10fl --yes-wipe-everything --skip-identity > o17 2>&1; rc=$?
  chk "R4-7 verify read errors -> rc 2 (not the misleading rc 1)" 2 $rc "HEAD MISMATCH READ-ERROR" o17
  grep -q "ROOTFS MISMATCH READ-ERROR" o17 && grep -q "VERIFICATION FAILED" o17 && echo "PASS R4-7b ROOTFS READ-ERROR + final message" || { echo "FAIL R4-7b"; tail -8 o17; failn=$((failn+1)); }
  dmsetup remove dq10fl
else echo "SKIP R4-5..7 (dm-flakey not available)"; fi
losetup -d "$LC"; rm -f c.img
echo "RESULT: $pass passed, $failn failed"
