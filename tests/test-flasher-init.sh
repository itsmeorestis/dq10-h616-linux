#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Host-side unit test of scripts/flasher-init.sh (RAM/tmp only; no device is touched).
# A throw-away copy has its four path variables pointed at a fake tree; a mini configfs emulator (mkdir creates the attribute
# files the kernel creates, names taken from drivers/usb/gadget/configfs.c + f_mass_storage.c of v6.18.53) lets gadget_setup run.
set -u
PKG=$(cd "$(dirname "$0")/.." && pwd)
SH=${SHELL_UNDER_TEST:-busybox sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed -e "s#^PROCFS=/proc #PROCFS=$T/proc #" -e "s#^SYSFS=/sys #SYSFS=$T/sys #" -e "s#^DEVFS=/dev #DEVFS=$T/dev #" \
    -e "s#^CFGFS=/sys/kernel/config #CFGFS=$T/cfg #" "$PKG/scripts/flasher-init.sh" > "$T/init.test"
grep -q "^PROCFS=$T/proc " "$T/init.test" && grep -q "^SYSFS=$T/sys " "$T/init.test" && grep -q "^DEVFS=$T/dev " "$T/init.test" && grep -q "^CFGFS=$T/cfg " "$T/init.test" || { echo "path substitution failed"; exit 2; }
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1: got '$2' want '$3'"; fi; }

mkblk() { # name sectors type
  mkdir -p "$T/sys/block/$1/device"; echo "$2" > "$T/sys/block/$1/size"; [ -n "$3" ] && echo "$3" > "$T/sys/block/$1/device/type"; echo "0 0 0 0 0 0 0 0 0 0 0" > "$T/sys/block/$1/stat"; :
}
run() { # shell snippet run with the functions defined
  $SH -c "DQ10_SOURCE_ONLY=1; export DQ10_SOURCE_ONLY; . '$T/init.test'; $1"
}
reset() { rm -rf "$T/sys" "$T/proc" "$T/dev" "$T/cfg"; mkdir -p "$T/sys/block" "$T/sys/class/leds" "$T/sys/class/udc" "$T/proc" "$T/dev" "$T/cfg/usb_gadget"; }

# ---- syntax -------------------------------------------------------------------------------------------------------------
$SH -n "$PKG/scripts/flasher-init.sh"; ok "busybox sh -n" "$?" 0
if command -v dash >/dev/null; then dash -n "$PKG/scripts/flasher-init.sh"; ok "dash -n" "$?" 0; fi
if command -v shellcheck >/dev/null; then shellcheck -s dash -S warning "$PKG/scripts/flasher-init.sh" >"$T/sc.txt" 2>&1; ok "shellcheck -s dash" "$?" 0; [ -s "$T/sc.txt" ] && cat "$T/sc.txt"; fi

# ---- find_emmc ----------------------------------------------------------------------------------------------------------
reset; mkblk mmcblk0 30535680 MMC; mkblk mmcblk0boot0 8192 MMC; mkblk loop0 0 ""
ok "find_emmc: exact size + MMC" "$(run 'find_emmc; echo "$? $EMMC"')" "0 mmcblk0"
reset; mkblk mmcblk0 30535681 MMC
ok "find_emmc: size +1 sector refused" "$(run 'find_emmc; echo "$? [$EMMC]"')" "1 []"
reset; mkblk mmcblk0 30535679 MMC
ok "find_emmc: size -1 sector refused" "$(run 'find_emmc; echo "$? [$EMMC]"')" "1 []"
reset; mkblk mmcblk0 30535680 SD
ok "find_emmc: type SD refused" "$(run 'find_emmc; echo "$? [$EMMC]"')" "1 []"
reset; mkblk mmcblk0 30535680 ""
ok "find_emmc: no device/type refused" "$(run 'find_emmc; echo "$? [$EMMC]"')" "1 []"
reset; mkblk mmcblk0 30535680 MMC; mkblk mmcblk1 30535680 MMC
ok "find_emmc: two matches refused" "$(run 'find_emmc; echo "$? [$EMMC]"')" "1 []"
reset; mkblk mmcblk0boot0 30535680 MMC; mkblk mmcblk0rpmb 30535680 MMC
ok "find_emmc: boot/rpmb names never match" "$(run 'find_emmc; echo "$? [$EMMC]"')" "1 []"
reset; mkblk sda 30535680 MMC; mkblk vda 30535680 MMC; mkblk mmcblk1 15000000 MMC
ok "find_emmc: other disks (sda, vda, small mmc) ignored" "$(run 'find_emmc; echo "$? [$EMMC]"')" "1 []"
reset; mkblk mmcblk2 30535680 MMC; mkblk mmcblk0 15000000 SD
ok "find_emmc: matches by size not by name (mmcblk2)" "$(run 'find_emmc; echo "$? $EMMC"')" "0 mmcblk2"

# ---- parse_cmdline ------------------------------------------------------------------------------------------------------
pc() { reset; printf '%s\n' "$1" > "$T/proc/cmdline"; run 'parse_cmdline; echo "$MODE $RO [$BADOPT] [$SPEED]"'; }
ok "cmdline: absent option -> ro" "$(pc 'console=tty1 loglevel=4 rdinit=/init')" "ro 1 [] []"
ok "cmdline: dq10mode=ro" "$(pc 'console=tty1 dq10mode=ro')" "ro 1 [] []"
ok "cmdline: dq10mode=rw" "$(pc 'console=tty1 rdinit=/init dq10mode=rw')" "rw 0 [] []"
ok "cmdline: unknown value -> ro + noted" "$(pc 'dq10mode=RW')" "ro 1 [dq10mode=RW] []"
ok "cmdline: rwx -> ro" "$(pc 'dq10mode=rwx')" "ro 1 [dq10mode=rwx] []"
ok "cmdline: empty value -> ro" "$(pc 'dq10mode=')" "ro 1 [dq10mode=] []"
ok "cmdline: substring in other option not honoured" "$(pc 'foo=dq10mode=rw xdq10mode=rw')" "ro 1 [] []"
ok "cmdline: dq10speed=full" "$(pc 'dq10mode=ro dq10speed=full')" "ro 1 [] [full]"
ok "cmdline: no /proc/cmdline at all -> ro" "$(reset; run 'parse_cmdline; echo "$MODE $RO"')" "ro 1"

# ---- gadget_setup against the configfs emulator -----------------------------------------------------------------------
EMU='mkdir() { command mkdir "$@" || return 1; for d in "$@"; do case "$d" in -p) continue;; esac
  case "$d" in
    */usb_gadget/*/strings/*|*/configs/*/strings/*) :> "$d/serialnumber"; :> "$d/manufacturer"; :> "$d/product"; :> "$d/configuration";;
    */usb_gadget/*/configs/*) :> "$d/MaxPower"; :> "$d/bmAttributes"; command mkdir -p "$d/strings";;
    */usb_gadget/*/functions/mass_storage.*) command mkdir -p "$d/lun.0"; for a in file ro removable cdrom nofua inquiry_string forced_eject; do :> "$d/lun.0/$a"; done;;
    */usb_gadget/*/functions/acm.*) :> "$d/port_num";;
    */usb_gadget/*) command mkdir -p "$d/strings" "$d/configs" "$d/functions"; for a in idVendor idProduct bcdDevice bcdUSB bDeviceClass bDeviceSubClass bDeviceProtocol bMaxPacketSize0 UDC max_speed; do :> "$d/$a"; done;;
  esac; done; }'
gs() { # $1 cmdline, then prints the resulting attribute values
  reset; printf '%s\n' "$1" > "$T/proc/cmdline"; mkdir -p "$T/sys/class/udc/musb-hdrc.1.auto"; mkblk mmcblk0 30535680 MMC; :> "$T/dev/mmcblk0"
  run "$EMU
  parse_cmdline; find_emmc; gadget_setup; echo rc=\$?; gadget_bind; echo bind=\$? udc=\$UDC"
}
G=$T/cfg/usb_gadget/dq10; L=$G/functions/mass_storage.0/lun.0
gcheck() { # $1 label $2 cmdline $3 want_ro
  out=$(gs "$2")
  ok "$1: setup rc=0, bind ok, udc picked" "$(echo "$out" | tr '\n' ' ')" "rc=0 bind=0 udc=musb-hdrc.1.auto "
  ok "$1: LUN ro" "$(cat "$L/ro")" "$3"
  ok "$1: LUN file" "$(cat "$L/file")" "$T/dev/mmcblk0"
  ok "$1: LUN cdrom/nofua/removable = 0" "$(cat "$L/cdrom")$(cat "$L/nofua")$(cat "$L/removable")" "000"
  ok "$1: inquiry string is exactly 28 chars" "$(wc -c < "$L/inquiry_string" | tr -d ' ')" "29"      # 28 + newline
  ok "$1: idVendor/idProduct" "$(cat "$G/idVendor") $(cat "$G/idProduct")" "0x1d6b 0x0104"
  ok "$1: serial" "$(cat "$G/strings/0x409/serialnumber")" "DQ10-FLASHER-0001"
  ok "$1: UDC written" "$(cat "$G/UDC")" "musb-hdrc.1.auto"
  ok "$1: config links (the two functions)" "$(find "$G/configs/c.1" -maxdepth 1 -type l -printf '%f
' | sort | tr '
' ' ')" "acm.usb0 mass_storage.0 "
  ok "$1: self powered / MaxPower" "$(cat "$G/configs/c.1/bmAttributes") $(cat "$G/configs/c.1/MaxPower")" "0xC0 2"
}
gcheck "gadget ro" 'dq10mode=ro' 1
ok "gadget ro: max_speed forced only on request (none here)" "$(cat "$G/max_speed")" ""
gcheck "gadget default (no option)" 'console=tty1' 1
gcheck "gadget rw" 'dq10mode=rw' 0
# the eMMC node is the only device path referenced anywhere in the gadget
ok "gadget: only the selected node is referenced" "$(grep -r "$T/dev" "$G" | wc -l | tr -d ' ')" "1"
out=$(gs 'dq10mode=ro dq10speed=full'); ok "gadget speed=full" "$(cat "$G/max_speed")" "full-speed"
# no UDC -> gadget_bind must fail (shortened wait: the test only checks the return code with an empty udc dir)
reset; mkdir -p "$T/sys/class/udc"
ok "gadget_bind without UDC fails" "$(run 'sleep() { :; }; GNAME=none; gadget_bind; echo $?')" "1"

# ---- LED ----------------------------------------------------------------------------------------------------------------
reset; mkdir -p "$T/sys/class/leds/power" "$T/sys/class/leds/standby"
for f in brightness trigger delay_on delay_off; do :> "$T/sys/class/leds/power/$f"; :> "$T/sys/class/leds/standby/$f"; done
ok "LED: picks the *power* LED only" "$(run 'find_led; echo ${LED##*/}')" "power"
run 'find_led; led_blink 500 500'; ok "LED: blink writes timer/delays" "$(cat $T/sys/class/leds/power/trigger)/$(cat $T/sys/class/leds/power/delay_on)/$(cat $T/sys/class/leds/power/delay_off)" "timer/500/500"
run 'find_led; led_solid';        ok "LED: solid writes none/1" "$(cat $T/sys/class/leds/power/trigger)/$(cat $T/sys/class/leds/power/brightness)" "none/1"
ok "LED: standby LED untouched" "$(cat $T/sys/class/leds/standby/trigger)" ""
reset; ok "LED: absent LED -> no-ops, rc 0" "$(run 'find_led; led_blink 1 1; led_solid; echo "[$LED] $?"')" "[] 0"

echo "---- $pass passed, $fail failed"
[ "$fail" = 0 ]
