#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# /init of the DQ10 FEL flasher (ROUTE L).  Installed into the flasher initramfs by scripts/build-flasher.sh.
#
# What it does (RAM-only system booted over FEL; nothing is read from or written to any disk image of its own):
#   1. mounts proc/sys/devtmpfs/tmpfs, sends all text to the console (tty1 = HDMI) and drives the PH6 LED;
#   2. finds the stick's eMMC by EXACT SIZE (15,634,268,160 bytes = 30,535,680 sectors) among the whole MMC disks, refuses
#      unless exactly one device matches; no other block device is ever opened;
#   3. loads the MUSB (USB0) driver and the gadget modules, creates a configfs composite gadget with
#         mass storage LUN0 = that eMMC (removable=0, nofua=0, cdrom=0, ro=1 or 0) + a CDC-ACM serial function
#      and binds it to the UDC;  /dev/ttyGS0 gets a root shell (diagnostics over the physical USB link only);
#   4. keeps a status screen on the console.
# Mode comes from the kernel command line (the uEnv bootargs):   dq10mode=ro (default, also for anything unknown)
#                                                                 dq10mode=rw  (LUN writable: this is the flash mode)
#                                                  optional:     dq10speed=full (force USB full speed, a diagnostic)
# It never mounts anything from the eMMC, never runs fsck and never writes to the eMMC by itself.
# In ro mode the LUN is read-only AND the block device is set read-only in the kernel (blockdev --setro).
#
# LED (PH6, active low in hardware, the DT knows that): fast blink = starting, VERY fast = error (nothing is exported),
#                                                       slow blink = READ-ONLY export ready, SOLID = WRITABLE export ready.
#
# Test hook (used only by tests/test-flasher-init.sh): the four path variables below are substituted by sed in a throw-away
# copy so that device selection and cmdline parsing can run against a fake sysfs.  Nothing in this file reads an
# environment switch other than DQ10_SOURCE_ONLY (= "define the functions but do not run main").

PATH=/usr/bin:/usr/sbin:/bin:/sbin; export PATH
PROCFS=/proc               #T-PROC
SYSFS=/sys                 #T-SYS
DEVFS=/dev                 #T-DEV
CFGFS=/sys/kernel/config   #T-CFG

EMMC_SECTORS=30535680                              # 15,634,268,160 / 512
EMMC_BYTES=15634268160
GVID=0x1d6b                                        # Linux Foundation, the stock ID of the Linux multifunction composite gadget
GPID=0x0104
GSERIAL=DQ10-FLASHER-0001
GNAME=dq10
# 28-byte SCSI INQUIRY string = 8 vendor + 16 product + 4 revision
INQ="DQ10    eMMC flasher    0001"

MODE=ro
SPEED=""
BADOPT=""
EMMC=""
LED=""
UDC=""
RO=1

say() { echo "$*"; }

# ---- LED ------------------------------------------------------------------------------------------------------------
find_led() {
	LED=""
	for l in "$SYSFS"/class/leds/*; do
		[ -e "$l/brightness" ] || continue
		case "$l" in *power*) LED=$l; break;; esac
	done
}
led_blink() { # $1 = ms on, $2 = ms off
	[ -n "$LED" ] || return 0
	echo timer > "$LED/trigger" 2>/dev/null
	echo "$1" > "$LED/delay_on" 2>/dev/null
	echo "$2" > "$LED/delay_off" 2>/dev/null
}
led_solid() {
	[ -n "$LED" ] || return 0
	echo none > "$LED/trigger" 2>/dev/null
	echo 1 > "$LED/brightness" 2>/dev/null
}

# ---- failure: say why, show the kernel log, signal on the LED, and stop (the stick is then safe to power-cycle) ----------
hold() { while :; do sleep 3600; done; }
fatal() {
	led_blink 40 40
	say ""
	say "!!!!!!!!!!!!!!!!  FLASHER ERROR: $*"
	say "nothing is exported over USB. Kernel log (usb/musb/phy/mmc lines, last 30):"
	dmesg | grep -i -E "musb|usb|phy|udc|gadget|configfs|mmc|sunxi" | tail -n 30
	say "Power-cycle the stick (unplug the adapter), hold the button, plug in again to retry from FEL."
	hold
}

# ---- command line -----------------------------------------------------------------------------------------------------
parse_cmdline() {
	MODE=ro; SPEED=""; BADOPT=""
	for w in $(cat "$PROCFS/cmdline" 2>/dev/null); do
		case "$w" in
			dq10mode=rw) MODE=rw;;
			dq10mode=ro) MODE=ro;;
			dq10mode=*) BADOPT="$w";;
			dq10speed=full) SPEED=full;;
		esac
	done
	if [ "$MODE" = rw ]; then RO=0; else RO=1; fi
}

# ---- eMMC identification: whole MMC disk, exact size, exactly one match --------------------------------------------------
find_emmc() {
	EMMC=""; n=0
	for b in "$SYSFS"/block/mmcblk[0-9]; do
		[ -d "$b" ] || continue
		sz=$(cat "$b/size" 2>/dev/null) || continue
		[ "$sz" = "$EMMC_SECTORS" ] || continue
		[ "$(cat "$b/device/type" 2>/dev/null)" = MMC ] || continue
		n=$((n + 1)); EMMC=${b##*/}
	done
	if [ "$n" != 1 ]; then EMMC=""; return 1; fi
	return 0
}

wait_emmc() {
	i=0
	while [ "$i" -lt 60 ]; do
		find_emmc && [ -b "$DEVFS/$EMMC" ] && return 0
		i=$((i + 1)); sleep 1
	done
	return 1
}

# ---- USB gadget ---------------------------------------------------------------------------------------------------------
gadget_setup() {
	G=$CFGFS/usb_gadget/$GNAME
	mkdir "$G" || return 1
	echo "$GVID" > "$G/idVendor" || return 1
	echo "$GPID" > "$G/idProduct" || return 1
	echo 0x0200 > "$G/bcdUSB"
	echo 0x0100 > "$G/bcdDevice"
	echo 0xEF > "$G/bDeviceClass"; echo 0x02 > "$G/bDeviceSubClass"; echo 0x01 > "$G/bDeviceProtocol"   # composite with IAD
	[ "$SPEED" = full ] && echo full-speed > "$G/max_speed"
	mkdir "$G/strings/0x409" || return 1
	echo "$GSERIAL" > "$G/strings/0x409/serialnumber"
	echo "dq10-linux" > "$G/strings/0x409/manufacturer"
	echo "DQ10 eMMC flasher" > "$G/strings/0x409/product"
	mkdir "$G/configs/c.1" || return 1
	mkdir "$G/configs/c.1/strings/0x409" || return 1
	echo "eMMC mass storage + serial" > "$G/configs/c.1/strings/0x409/configuration"
	echo 0xC0 > "$G/configs/c.1/bmAttributes"     # self powered (the stick has its own adapter)
	echo 2 > "$G/configs/c.1/MaxPower"
	mkdir "$G/functions/mass_storage.0" || return 1
	L=$G/functions/mass_storage.0/lun.0
	[ -d "$L" ] || return 1
	echo 0 > "$L/cdrom" || return 1
	echo 0 > "$L/nofua" || return 1
	echo 0 > "$L/removable" || return 1
	echo "$RO" > "$L/ro" || return 1               # BEFORE the file: ro cannot be changed while the backing file is open
	echo "$INQ" > "$L/inquiry_string" || return 1
	echo "$DEVFS/$EMMC" > "$L/file" || return 1
	# f_mass_storage silently falls back to read-only when it cannot open the device read-write: insist on what was asked for
	[ "$(cat "$L/ro")" = "$RO" ] || return 1
	[ "$(cat "$L/file")" = "$DEVFS/$EMMC" ] || return 1
	mkdir "$G/functions/acm.usb0" || return 1
	ln -s "$G/functions/mass_storage.0" "$G/configs/c.1/mass_storage.0" || return 1
	ln -s "$G/functions/acm.usb0" "$G/configs/c.1/acm.usb0" || return 1
	return 0
}

gadget_bind() {
	i=0
	while [ "$i" -lt 30 ]; do
		for u in "$SYSFS"/class/udc/*; do
			[ -e "$u" ] && { UDC=${u##*/}; break 2; }
		done
		i=$((i + 1)); sleep 1
	done
	[ -n "$UDC" ] || return 1
	echo "$UDC" > "$CFGFS/usb_gadget/$GNAME/UDC" || return 1
	[ "$(cat "$CFGFS/usb_gadget/$GNAME/UDC")" = "$UDC" ]
}

acm_shell() {
	while :; do
		if [ -c "$DEVFS/ttyGS0" ]; then
			setsid sh -c 'PS1="dq10-flasher# "; export PS1; echo; echo "DQ10 flasher root shell (physical USB link only). eMMC export: see /proc/cmdline"; exec sh -i' <"$DEVFS/ttyGS0" >"$DEVFS/ttyGS0" 2>&1
		fi
		sleep 2
	done
}

# rw mode only: keep the eMMC block device cache clean so that a host-side read-back is served from the media, not from
# this system's page cache (the gadget reads the block device through the page cache)
cache_dropper() {
	while :; do
		sleep 2
		sync
		echo 3 > "$PROCFS/sys/vm/drop_caches" 2>/dev/null
	done
}

status_screen() {
	while :; do
		st=$(cat "$SYSFS/class/udc/$UDC/state" 2>/dev/null)
		read -r _a _b rs _c _d _e ws _rest < "$SYSFS/block/$EMMC/stat" 2>/dev/null
		printf '\033[H\033[2J'
		if [ "$MODE" = rw ]; then
			say "=== DQ10 eMMC FLASHER (RAM only)    mode: WRITABLE (dq10mode=rw)   LED solid ==="
		else
			say "=== DQ10 eMMC FLASHER (RAM only)    mode: READ-ONLY (dq10mode=$MODE)   LED slow blink ==="
		fi
		say "eMMC       : $DEVFS/$EMMC  $EMMC_BYTES bytes  name $(cat "$SYSFS/block/$EMMC/device/name" 2>/dev/null)"
		say "USB gadget : $GVID:$GPID \"DQ10 eMMC flasher\" serial $GSERIAL  UDC $UDC  speed limit: ${SPEED:-none}"
		say "LUN0       : file=$(cat "$CFGFS/usb_gadget/$GNAME/functions/mass_storage.0/lun.0/file" 2>/dev/null)  ro=$(cat "$CFGFS/usb_gadget/$GNAME/functions/mass_storage.0/lun.0/ro" 2>/dev/null)  kernel-ro=$(blockdev --getro "$DEVFS/$EMMC" 2>/dev/null)"
		say "UDC state  : $st   (configured = the PC has enumerated it)"
		say "eMMC I/O   : sectors read $rs   written $ws   (uptime $(cut -d' ' -f1 "$PROCFS/uptime" 2>/dev/null) s)"
		say ""
		say "PC side    : usbipd list -> $GVID:$GPID ; attach to WSL ; scripts/ums-flash.sh (docs/FLASH-PLAN.md, Route L)"
		say "Do NOT unplug the stick's power while the PC is writing."
		sleep 5
	done
}

main() {
	mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev; mount -t tmpfs tmp /tmp
	exec </dev/console >/dev/console 2>&1
	dmesg -n 3
	find_led
	led_blink 100 100
	parse_cmdline
	say ""
	say "=========== DQ10 eMMC FLASHER (FEL boot, RAM only) ==========="
	uname -a
	say "mode: $MODE   $( [ -n "$BADOPT" ] && echo "(ignored unknown option $BADOPT -> read-only)" )   cmdline: $(cat "$PROCFS/cmdline")"
	say "LED: ${LED:-NOT FOUND}"

	say "--- looking for the eMMC (whole MMC disk of exactly $EMMC_BYTES bytes)"
	wait_emmc || fatal "no unique MMC disk of exactly $EMMC_SECTORS sectors found (matches: $n). Block devices: $(ls "$SYSFS/block" | tr '\n' ' ')"
	say "eMMC = $DEVFS/$EMMC  name=$(cat "$SYSFS/block/$EMMC/device/name" 2>/dev/null)"
	if [ "$RO" = 1 ]; then
		blockdev --setro "$DEVFS/$EMMC" || fatal "blockdev --setro failed"
	fi
	[ "$(blockdev --getro "$DEVFS/$EMMC")" = "$RO" ] || fatal "kernel read-only flag of $EMMC is not $RO (write-protected media?)"

	say "--- loading USB modules (MUSB sunxi, configfs, libcomposite, mass storage, acm)"
	for m in configfs libcomposite usb_f_mass_storage usb_f_acm sunxi; do
		modprobe "$m" || fatal "modprobe $m failed"
	done
	mount -t configfs none "$CFGFS" || fatal "cannot mount configfs"

	say "--- creating the gadget"
	gadget_setup || fatal "gadget configuration failed"
	gadget_bind || fatal "no UDC (USB device controller) appeared or the bind failed - MUSB/PHY problem, see the log above"
	say "gadget bound to UDC $UDC"

	if [ "$RO" = 1 ]; then
		led_blink 500 500
	else
		led_solid
		cache_dropper &
	fi
	acm_shell &
	status_screen
}

[ -n "$DQ10_SOURCE_ONLY" ] || main
