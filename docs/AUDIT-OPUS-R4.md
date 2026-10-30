# AUDIT-OPUS-R4 - Route L (revision 4), 2026-10-30

Auditor: Opus. Scope: `flasher/`, `scripts/flasher-init.sh`, `scripts/ums-flash.sh`, the rev-4 U-Boot, the rev-4 image, FLASH-PLAN Part 1 (L0-L8), BUILD-NOTES sec. 19. Compared against the revision-3 backups of those files (not published).
Method: everything was read-only. I used no adb, sunxi-fel or usbipd commands, wrote no block device, did not read the private key and did not call a global `sync`. WSL was used only to decompile DTBs, list the initramfs and inspect `$DQ10_WORK/final-r4/rootfs.ext4` with debugfs/dumpe2fs/`e2fsck -fn`. The usbipd-win version was read from the file properties of `usbipd.exe` (5.3.0), not by running it.

## Verdicts

| session | verdict |
|---|---|
| **Read-only session** (L0-L4, including the RAM-only L2/L3 tests) | **GO.** Nothing in this chain can write the eMMC. Apply F1 in L4, where the bind happens, and F2 to L3. |
| **Write** (L5-L7) | **GO-WITH-FIXES.** F1 and F2 are mandatory, and every gate below must pass first. |

Gates for the write: L3 (a) 3/3 and (b) at least 1/1, judged by the F2 criteria. In L4 the gadget must enumerate, the identity must be OK and the compare result must be recorded. In L5 the HDMI screen must show WRITABLE with the LED solid, `usbipd list` must show `Shared (forced)` and no drive letter may appear.

## Mandatory fixes

**F1 - `usbipd bind` must be `--force` (FLASH-PLAN fact 8, L4, L5, Restore).** The installed usbipd-win is 5.3.0. A plain `bind` makes the device "Shared", but Windows' own drivers keep using it until a client attaches; only `bind --force` stops the host from using it. Fact 9 ("Device in error state" because Windows' storage driver still held the disk) fits this. So the plan's statements are wrong: "the drive letter should vanish" after the bind, and the bind "makes usbipd's stub driver take the device at enumeration" for the writable session.
- Consequence as written: in L5 the writable disk is visible to Windows until the attach, so the L5 stop rule fires every time. If the operator ignores the rule, Windows has a writable vendor GPT/FAT disk again, the same thing that happened to `bootloader_a` on 2026-10-29. The flash itself survives this (the whole disk is zeroed, and the identity area 0..73727 is not a FAT volume), but it makes the plan's safety claim false and puts the restore and compare at risk.
- Fix: `usbipd bind --force --hardware-id 1d6b:0104` in L4. Then unplug and replug the A-A cable (the flasher keeps running) and check that `usbipd list` shows `Shared (forced)` and that no drive letter is present.
- Use the same USB port for every session.
- After the project, run `usbipd unbind --hardware-id 1d6b:0104`: 1d6b:0104 is the generic ID of every Linux composite gadget.
- With F1 in place, the `usbipd detach` before unplugging in L7 and in the script's final message is harmless. Without F1, unplug the stick first and detach afterwards.

**F2 - L3 pass criterion can give a false pass.** "FEL comes back within ~25 s" is also what a crash or panic before bootcmd produces, because U-Boot resets on panic and the held button re-enters FEL. That includes a crash in `preboot=usb start`, which is exactly what (b) is meant to test. The marker can also be stale from an earlier run.
- Before each run: `sunxi-fel writel 0x00100000 0` in the same FEL session.
- PASS requires all of:
  - the blink pattern was seen (on/off/on/off at 1 s);
  - FEL came back **no sooner than about 16 s** for (a), or about 18 s for (b) (2 s bootdelay + 4 s blink + 12 s sleep);
  - when the marker is readable, it reads `0xd10c0001` for (a) or `0xd10c0002` for (b).
- An early return is a FAIL.

## Recommended (not blocking)

- **F3 (L4 wording):** "23 OK = the eMMC is exactly the backed-up vendor state" overclaims. The 23 ranges cover sectors 0..7095296 except two gaps (6890496..6923264 and 6956032..6988800). userdata and the rest of the disk are not covered. If Android has booted since fact 2, those regions differ without showing up.
- **F4 (Restore):** the L5 dry run will REFUSE identity once Armbian is on the eMMC. That is expected in the restore and the step is skipped there; say so. The `--compare-hashes` check does not cover userdata, so make the full `cmp` (verify 3) mandatory before claiming "exact original".
- **F5:** `dq10speed=full` is documented only for ro. A full-speed write is about 1 MB/s, which means about 4-5 h for the 14.9 GB zero pass. Say whether that is acceptable.
- **F6:** the R4-3e harness check was corrected but not re-run. Re-run it, or keep the note in sec. 19.5 as it is.
- Note: the installed Armbian DT has USB0 `dr_mode host` with PH8 VBUS, so it drives VBUS on the A-A cable. L7 already says to unplug the cable; never reconnect it to the laptop while Armbian runs.

## Findings by item

### 1. flasher/ - OK
- **Checksums:** `sha256sum -c flasher/SHA256SUMS` passes 7/7. `sha256sum -c SHA256SUMS-ALL.txt` passes all 82 lines (rc 0).
- **Init:** the init inside the initramfs is byte-identical to `scripts/flasher-init.sh` (`87ca7570...`). Busybox is static, `lib`/`sbin` are symlinks into `usr`, and the 8 modules are present with a consistent `modules.dep`. HDMI/DRM, LED triggers and MMC are built into the kernel, so the status screen does not depend on modules. The initramfs has no `/dev/console`; that is harmless because the init redirects after mounting devtmpfs.
- **Device selection:** only whole `mmcblk[0-9]` disks with `size`=30535680 and `device/type`=`MMC` qualify, and exactly one match is required. mmc0 is disabled and mmc1 is SDIO, so only the eMMC can match. Unknown `dq10mode` falls back to ro.
- **ro enforcement:** `ro` is written before `file` (`_fsg_store_ro` returns -EBUSY once the file is open). `ro` and `file` are read back, which catches the silent `O_RDONLY` fallback in `fsg_lun_open`. `blockdev --setro` + `--getro` are checked. In ro mode two independent layers refuse writes.
- **configfs gadget:** attribute names, order and values are correct. The INQUIRY string is 28 chars; with the trailing newline `snprintf("%-28s")` truncates cleanly. `bmAttributes`/`MaxPower` and the IAD class are fine.
- **Page-cache drop loop in rw:** `f_mass_storage` opens the backing device buffered (`O_RDWR|O_LARGEFILE`, no `O_DIRECT`), so the loop is needed. It works: drop_caches iterates the bdev superblock. MODE SENSE reports WCE, so the host's fsync sends SYNCHRONIZE CACHE, which leads to `vfs_fsync` on the stick and then an eMMC cache flush. The 6 s pause covers the 2 s loop.
- **Load addresses:**
  - The Image header gives text_offset 0, image_size 36,372,480 and flags 0xa (bit 3). `booti` therefore moves the kernel to 0x40200000..0x424b0000.
  - BL31 is 36,964 B at 0x40000000; TF-A sets BL31_LIMIT to +0x40000, which is below 0x40080000.
  - The uEnv at 0x43100000, the fdt at 0x4fa00000+0x18d22 and the initramfs at 0x4ff00000..0x5010936b do not overlap. 0x20936b equals the file size.
  - This is the same layout as D5.
- **uEnv files:** they are LF-only and use the D5 pattern. `bootdelay=-2` bypasses `abortboot` entirely, also with keyed autoboot. RUN-ME matches L3-L5.
- **Flasher DT diff:** compared after decompiling, ignoring phandle renumbering. The only changes are: model, `mmc@4020000` disabled, usbotg `dr_mode` host -> peripheral, ehci0/ohci0 disabled, and `usb0_vbus-supply` removed (1 -> 0 occurrences). Nothing else changed.

### 2. U-Boot rev 4 - OK (not yet hardware-tested; L3 is the gate)
- **.config diff vs rev3:** exactly `SPL_SUNXI_LED_STATUS_ACTIVE_HIGH` y -> unset, `AUTOBOOT_KEYED`=y with `STOP_STR="dq10stop"`, plus the Kconfig-derived keyed symbols and the removal of `USE_MENUKEY`. The DRAM/PMIC/DT lines are identical.
- **SPL:** it differs from 0b1285d8 in exactly 2 places: the eGON checksum at 0xc and `mov w1,#1` -> `#0` at 0x2f64. The eGON checksum recomputes to `8a1381dd`, which is valid.
- **FIT:** BL31 and `u-boot.dtb` are at the same offsets as in the old binary. `head-emmc-4MiB.bin` equals the rev-3 head for bytes 0..8191 (MBR unchanged), contains the new binary at 8192, and is zero after it.
- **Keyed autoboot:** an empty DELAY_STR is skipped (`len > 0`), CTRLC is off, and only the exact string "dq10stop" aborts, so noise cannot stop the boot. It still waits the full 2 s and then runs `distro_bootcmd`.
- **Preboot:** `usb start` finds no enabled USB node in the U-Boot DT, so it cannot drive VBUS.
- **Environment:** `ENV_IS_IN_FAT` ":auto" on the eMMC boot hits the ext4 p1, so U-Boot uses the default environment and nothing writes.

### 3. ums-flash.sh - OK
- **READ-ERROR handling:** works for identity, compare and verify. Under `pipefail`, `x=$(dd|sha256sum|cut) || x=READ-ERROR` is correct.
- **Compare mode:** it is read-only. It refuses the write flags, keeps `--setro` and contains no `setrw`. It strips CR (the hash list has 22 CRs and an LF-only last line) and makes a relative path absolute.
- **Write-protect refusal:** it is a second layer; a ro LUN fails the write anyway.
- **`sync "$DEV"`:** this is an fsync of that device only, which sends SYNCHRONIZE CACHE to the gadget. That is correct.
- **`PIPESTATUS`:** correct for root's `/bin/bash`.
- **Guards:** the USB sysfs check, the exact size (the gadget reports size>>9 = 30,535,680) and the identity hash of the owner's backup all apply to the gadget unchanged. The zero pass of 14910 MiB is exactly 15,634,268,160 B.

### 4. Image rev 4 - OK
- The rootfs in final-r4 equals `ROOT_SHA` `3ce41608`, and the `.gz` is byte-identical to the one in the package.
- `/boot/Image` is a symlink to `vmlinuz-6.18.53`, and that file has hash `e5bc78d4` = `flasher/Image`.
- The DTB in `/boot/dq10-dtb` = `6287d02a` = `dts/*.dtb`, with LED flags 0x01 (`GPIO_ACTIVE_LOW`).
- The UUID is still `e70cdb2c-...`. Filesystem state clean, max mount count -1, `e2fsck -fn` clean. `authorized_keys` is identical to the overlay. `armbianEnv` has `fdtdir`/`fdtfile`.

### 5. FLASH-PLAN Part 1 - order correct, apart from F1/F2
- The order is right: backup check, FEL, DRAM test, reach blocker on the NEW binary, ro identity + compare + bind, rw session, write with an `rc` line, power-cycle without the button.
- In the failure table, the analysis of an interrupted write is right: the zero pass kills the vendor boot0 at sectors 16 and 256 first, and sector 16 is written last.
- The restore via Route L has the USB, size and mount checks and the post-write compare (see F1 and F4).
- Remaining unproven items, already listed in sec. 19.7: the Linux MUSB gadget has never run, D1b was not run, and throughput is unmeasured. An unreliable eMMC timing in Linux would show up as BAD lines in the L4 compare, so L4 also works as a link test.
