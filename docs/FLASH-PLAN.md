# FLASH-PLAN - DQ10 (athena_p1): mainline U-Boot + Armbian to the internal eMMC

**Revision 4 (2026-10-30).** Main route = **Route L: FEL (button) -> Linux flasher in RAM -> USB gadget exports the eMMC -> `scripts/ums-flash.sh` from WSL.** Route F (recovery U-Boot UMS) is **not usable** from a cold button entry (hardware test 2026-10-30) and is kept only as history. The ADB-staging route is kept as a **FALLBACK** in Part 2 (sections 5-7).
**Status note added when this repository was published:** this runbook is kept as written before the first flash, so passages that say "not executed" or "never run on the stick" describe the state at the time of writing. Route L was then executed once, on one unit, on 2026-10-30 (see `../README.md` for the result). Every command is for a supervised run by the person who owns the stick. Paths: `$PKG` = the root of this repository, `$BACKUP` = the directory with YOUR OWN backup of YOUR vendor eMMC (see "Your own backup and hash list" below); the host paths of the original session were replaced by these placeholders. Companion: `BUILD-NOTES.md` (sources, decoded tables, risks, changelog sec. 19), `AUDIT-OPUS-R3.md` (the audit whose fixes 1-6 this revision applies).

## Hardware facts (2026-10-29 and 2026-10-30; read these first)

1. **FEL entry = the button at power-up.** Remove any microSD first (the BROM tries SD before eMMC), **unplug the stick's power adapter**, hold the stick's button, plug the adapter in, release after ~3 s. The data link is the **USB A-A cable** to the laptop; the stick is powered by its **own adapter**. Replugging only the A-A cable does not reset the stick. Evidence (D1, read-only register probe after such an entry): PLL_DDR0 `0x03001010` = `0x08002301` (off), no eGON header at `0x20000`, RTC GP registers `0x07000100..11c` all 0 => the button enters the **BROM FEL directly**, nothing from the vendor boot chain ran.
2. **The vendor efex flag is gone.** A normal power-up now runs the vendor chain (HDMI signal, black picture on the test unit); a plain power-cycle no longer returns to FEL. **Android may boot again** (not checked; ping <stick-ip> / hotspot client list would tell). Every "power-cycle (-> FEL)" of the old plan became "button + power".
3. **LED PH6 is ACTIVE-LOW** (pin low = blue LED on). The old SPL turned it off; this revision's SPL (`CONFIG_SPL_SUNXI_LED_STATUS_ACTIVE_HIGH` off) lights it, and the Linux DT declares it `GPIO_ACTIVE_LOW` (PH7 assumed alike, unverified).
4. **uEnv override works:** `sunxi-fel -v -p uboot <u-boot> write 0x43100000 <file starting '#=uEnv'>` prints "Passing boot info via sunxi SPL: script address = 0x43100000". With `bootdelay=-2` + `preboot=` the main U-Boot reached its bootcmd 3/3 (FEL back after `reset`); with the default BOOTDELAY=2 + preboot it passed once. `mmc dev 1` (eMMC) works in U-Boot.
5. **U-Boot UMS does not start from a cold button entry:** the recovery U-Boot's `ums 0 mmc 1` returned failure (4 variants, with and without `usb start`, `stdin=nulldev`); root cause unknown. It worked once on 2026-10-29 when FEL had been entered through the vendor boot0 jump. **Route F is therefore not usable.**
6. **Linux in RAM works (D5):** main U-Boot + Image/DTB/initramfs loaded by `sunxi-fel` and started by a uEnv (bootdelay=-2, `booti`) gave a console on HDMI, a busybox shell, the heartbeat LED, and the AIC8800 Wi-Fi scan found networks. Route L builds on exactly this.
7. **"Nothing was written to the stick" on 2026-10-29 is not proven.** During the UMS session Windows mounted a vendor FAT volume read-write as D: (almost certainly `bootloader_a`, sector 73728; Windows routinely adds `System Volume Information`). The identity hash covers only sectors 0..73727 and cannot see that. The first read-only Route L session therefore runs `--compare-hashes` against `partition-hashes.txt` and the result is recorded (BUILD-NOTES 19.7). For the flash itself this is irrelevant (everything is zeroed); it matters for the "restore = exact original" claim and for the black-screen question.
8. **WINDOWS DRIVE-LETTER WARNING.** Windows may assign a drive letter to the exported disk (the flasher's read-only session: harmless but do not touch it; the writable session: **it must never be mounted by Windows**). Never open, format, initialise, repair or "scan and fix" it (a "You need to format the disk" dialog: Cancel; never Initialize Disk). **Use `usbipd bind --force --hardware-id 1d6b:0104`** (audit R4 F1: with usbipd-win 5.3.0 a plain `bind` leaves Windows' storage driver in charge until an attach; only `--force` makes the stub driver take the device at enumeration). Do it during the read-only session, then replug the A-A cable and confirm `usbipd list` shows **`Shared (forced)`** and no drive letter. Use the same laptop USB port for every session. Unbind only after the whole job (after L7, or after a restore): `usbipd unbind --hardware-id 1d6b:0104`: 1d6b:0104 is the generic Linux gadget ID.
9. **`usbipd attach` can fail with "Device in error state"** (Windows' storage driver still held the disk). Remedy: retry; `usbipd detach --hardware-id 1d6b:0104` and retry; unplug the A-A cable, plug it in again (the stick keeps running the flasher, no power cycle needed).

Conventions
* Three shells, each block labelled: **[PS-ADMIN]** = Windows PowerShell "as Administrator"; **[PS]** = normal Windows PowerShell; **[WSL]** = root shell in Kali: `wsl -d kali-linux -u root`, then `cd $PKG`. The ADB fallback (Part 2, sections 5-7) uses **Git Bash** (`ADB="adb -s <stick-ip>:5555"`).
* Step ids: Route L steps are **L0..L9**; fallback sections: 4.x preflight, 5.x staging, 6.x commit.
* Working directory: the repository root, `$PKG` (in WSL: its `/mnt/c/...` view). Tools: `usbipd` (Windows), `sunxi-fel` 1.4.2 (WSL, apt `sunxi-tools`).
* **"FEL" in every step means: the full button + power sequence of fact 1.** Hold the button until `usbipd list` shows `1f3a:efe8`.

## Your own backup and hash list (do this first; the repository cannot supply it)

The flasher refuses to write unless it recognises the stick as an unmodified vendor unit, and the "restore" path needs the original data. Both come from a backup of **your own** stick, which only you can make. The repository publishes no hash of any vendor eMMC on purpose (such a hash fingerprints one unit).

1. **Back up the whole eMMC user area (15,634,268,160 bytes) before you change anything.** The least intrusive way is the read-only session of Route L (step L4): the vendor Android never runs, the disk is exported read-only. With `$DEV` verified as in L4:
   ```
   set -o pipefail            # without it a dd read error inside "dd | gzip" is hidden and gzip -t still passes on a short stream
   export BACKUP=$HOME/dq10-vendor-backup; mkdir -p $BACKUP
   blockdev --getsize64 $DEV                                   # MUST be 15634268160
   dd if=$DEV bs=1M iflag=direct status=progress | gzip -1 > $BACKUP/dq10-mmcblk0.img.gz
   gzip -t $BACKUP/dq10-mmcblk0.img.gz && echo BACKUP-GZ-OK
   ls -l $BACKUP/dq10-mmcblk0.img.gz; gzip -dc $BACKUP/dq10-mmcblk0.img.gz | wc -c    # MUST print 15634268160 (do not rely on gzip -l: it wraps at 4 GiB)
   ```
   This is exactly the order of step L4 below (the commands are repeated there in place). On L4's first dry run use `--skip-identity`, because you have no identity hash yet; the dry run writes nothing. **What proves the backup is `COMPARE OK` in step 3** (every partition of the stick equals the hash of your backup); `gzip -t` alone does not. Keep the backup somewhere safe and **private**: it contains the unit's unique IDs, the vendor firmware and its malware (`MALWARE-IOCS.md`). The eMMC hardware boot partitions and RPMB are not reachable this way (the test unit's boot partitions read all-zero).
2. **Generate your hash list** from the backup:
   ```
   gzip -dc $BACKUP/dq10-mmcblk0.img.gz > $BACKUP/dq10-mmcblk0.img          # ~15 GB of disk space
   bash scripts/make-hash-list.sh $BACKUP/dq10-mmcblk0.img > $BACKUP/partition-hashes.txt
   export DQ10_PARTITION_HASHES=$BACKUP/partition-hashes.txt
   ```
   Format of `partition-hashes.txt`, one region per line, four space-separated fields: `name start_sector sector_count sha256` (512-byte sectors; the hash covers exactly those sectors). The first line must be `preboot-area 0 73728 <sha256>` (sectors 0..73727 = the first 36 MiB: MBR/GPT, the vendor boot0 copies, the boot package); `scripts/ums-flash.sh` uses it as the identity check of the stick (alternatively `export DQ10_IDENTITY_SHA256=<that hash>`). The following lines are the GPT partitions of the image (names from the GPT). CRLF line endings are tolerated.
3. **Check the list against the stick** (read-only): `bash scripts/ums-flash.sh $DEV --compare-hashes` must report `COMPARE OK`. From now on the dry run of step L4 also checks the identity.
4. Never publish `partition-hashes.txt`, the backup, or anything derived from it (SoC ID words 1-3, eMMC CID/serial, MAC address, Android serial).

# PART 1 - ROUTE L (main runbook): FEL -> Linux flasher in RAM -> ums-flash.sh

What it does to the stick: first RAM only (U-Boot and a small Linux are loaded over FEL; the eMMC is only read), then, in the writable session, the eMMC user area is **zeroed completely** (vendor Android, the root agents, both vendor boot0 copies, the backup GPT), the Armbian rootfs is written at sector 4194304 and the 4 MiB head (MBR + our SPL + U-Boot) last, **sector 16 (SPL header) as the very last write**. The eMMC hardware boot partitions are not reachable (they read all-zero on the original; the first-boot wipe service re-checks them).

What the flasher is (`flasher/`, built by `scripts/build-flasher.sh`, init = `scripts/flasher-init.sh`): the shipped Armbian 6.18.53 `Image`; `dq10-flasher.dtb` (= the board DT with `&usbotg dr_mode = "peripheral"`, ehci0/ohci0/microSD disabled, **no PH8 VBUS regulator**); an initramfs (static busybox + 8 kernel modules: MUSB `sunxi`, `musb_hdrc`, `phy-generic`, `configfs`, `libcomposite`, `usb_f_mass_storage`, `usb_f_acm`, `u_serial`). Its init finds the eMMC **by exact size 15,634,268,160 bytes** among the whole MMC disks (exactly one match or it stops), mounts nothing from it, runs no fsck, and exports it as LUN 0 of a USB gadget **1d6b:0104 "DQ10 eMMC flasher"**, serial `DQ10-FLASHER-0001`, SCSI vendor `DQ10` model `eMMC flasher`, plus a CDC-ACM serial port with a root shell (diagnostics, physical link only). Two modes from the kernel command line (the uEnv): **ro** (default; LUN `ro=1` and the block device set read-only in the kernel) and **rw** (`dq10mode=rw`, LUN writable; the kernel then also drops its page cache every 2 s so host read-backs come from the media).
Status: HDMI text screen; **LED PH6: fast blink = starting, very fast = error (nothing exported), slow blink = READ-ONLY export ready, SOLID = WRITABLE export ready.**

## L0. Preconditions (laptop only, nothing touches the stick)

[WSL]
```
cd $PKG
# The next two lines apply FROM THE SECOND SESSION ON only. On your very first run there is no backup and no hash list yet:
# skip them; both are created in step L4 (backup first, then the hash list). Do not write anything to the stick before L4 is complete.
gzip -t $BACKUP/dq10-mmcblk0.img.gz && echo BACKUP-GZ-OK     # YOUR only copy of the vendor data (15,634,268,160 B uncompressed)
export DQ10_PARTITION_HASHES=$BACKUP/partition-hashes.txt     # YOUR hash list (format below); ums-flash.sh needs it (or DQ10_IDENTITY_SHA256)
(cd image && sha256sum -c --ignore-missing SHA256SUMS)       # written by scripts/build-image.sh; ums-flash.sh also checks it
(cd flasher && sha256sum -c SHA256SUMS)
sha256sum image/rootfs.ext4.gz image/head-emmc-4MiB.bin uboot/u-boot-sunxi-with-spl.bin
#   the values of the maintainer's reference build (it had an SSH key baked in; YOUR OWN build has other image hashes - use the values from
#   your image/SHA256SUMS, which scripts/build-image.sh wrote, wherever this runbook quotes them; no prebuilt image is published):
#   ff72f2cc2b25292793208c91c9c27237c54f3059a0d8b684af326d6602f8f1ab  rootfs.ext4.gz
#   81566c4080f1703974b42e9ddf2ec2e20de3a4e835792fb90fb817e0d2b0dc95  head-emmc-4MiB.bin
#   48691413166cb499c2f2328290e7ff5fd700064e980b57871a934ce693e1ea72  u-boot-sunxi-with-spl.bin
command -v sunxi-fel && sunxi-fel --help 2>&1 | head -2      # sunxi-tools 1.4.2
```
* Laptop on mains, **sleep/hibernate disabled** for ~1.5 hours; use a good USB 2.0 port (no dock/hub) and a short A-A cable. The stick on its own adapter. **Remove the microSD.**
* HDMI display attached to the stick (the status screen and the LED are the only signals; the stick has no serial console). Optional: a USB hub + keyboard is useless in Route L (the only USB-A port is the gadget port).
* One-time Windows: `usbipd bind --hardware-id 1f3a:efe8` (FEL device, [PS-ADMIN]; already done on 2026-10-29). The flasher gadget is bound later (step L4).

## L1. Stick into FEL and hand it to WSL

Unplug the **power adapter** (and the A-A cable end at the stick if you like), hold the button, plug the adapter in, keep holding ~3 s; the A-A cable goes to the laptop.
[PS]
```
usbipd list                                         # expect 1f3a:efe8 (Shared)
usbipd attach --wsl --hardware-id 1f3a:efe8         # add --distribution kali-linux if several distros exist
```
[WSL]
```
sunxi-fel -l; sunxi-fel ver                         # an H616-family line, soc 0x1823
sh diag/d1-probe.sh                            # optional, read-only: expect PLL_DDR0 0x08002301, no eGON, RTC GP regs 0
```
*If no `1f3a:efe8`:* the sequence was wrong (adapter must be unplugged, then button, then power); other cable/port; check Device Manager. Nothing has been written. Safe to repeat.

## L2. RAM-only DRAM test of the shipped SPL (zero writes)

[WSL] `bash scripts/fel-dram-test.sh`  (ends with `DRAM PATTERN TEST PASSED`). The SPL returns to the BROM, the stick stays in FEL.
*If it fails:* **stop**, do not flash; report the output.

## L3. BLOCKER: U-Boot proper must reach its bootcmd on the NEW main binary (audit fix 2; zero writes)

The eMMC boot runs the same TF-A + U-Boot proper as FEL. Each run starts from a fresh button entry (L1). Each uEnv blinks PH6, writes a marker to RAM and `reset`s; **keep holding the button** (the BROM then re-enters FEL on the reset) - FEL coming back ALONE is NOT proof (audit R4 F2): a U-Boot crash/panic before bootcmd (e.g. in `preboot=usb start`) also resets into FEL while the button is held. **A run counts as a pass only if ALL hold:** (1) the on/off/on/off blink pattern was seen; (2) FEL came back **no sooner than ~16 s** after `Starting U-Boot` for (a), **~18 s** for (b) (blink 3 s + `sleep 12` [+ 2 s BOOTDELAY]); (3) the marker, if readable, is 0xd10c0001 for (a) / 0xd10c0002 for (b). Clear the marker before each run: `sunxi-fel writel 0x00100000 0` (on 2026-10-30 `readl 0x00100000` returned nothing; if it is unreadable, criteria 1+2 decide).

[WSL] (after `usbipd attach` of the fresh FEL device)
```
# (a) with the override that worked 3/3 on the old binary: bootdelay=-2, preboot empty.  Repeat 3x (each from a fresh button entry).
sunxi-fel -v -p uboot uboot/u-boot-sunxi-with-spl.bin write 0x43100000 flasher/reach-override.uenv 2>&1 | tr '\r' '\n' | grep -E "uEnv|Passing|rror"
# -> LED on at start (SPL), blinks, then FEL comes back.  [PS] usbipd attach again, then [WSL]:  sunxi-fel readl 0x00100000   # 0xd10c0001 (bonus: the marker survived)
# (b) with the COMPILED-IN config (BOOTDELAY=2, keyed autoboot "dq10stop", preboot "usb start", no override of any of them):
sunxi-fel -v -p uboot uboot/u-boot-sunxi-with-spl.bin write 0x43100000 flasher/reach-flashed.uenv 2>&1 | tr '\r' '\n' | grep -E "uEnv|Passing|rror"
#    -> FEL must come back too; marker 0xd10c0002.  Run it at least once, preferably 3x.
```
**Pass:** (a) 3/3 **and** (b) at least 1/1 (keyed autoboot proven without help). **If (a) fails** (hang before bootcmd): flashing stays NO-GO (the eMMC boot would hang in the one state without a software way back). **If (a) passes but (b) fails:** autoboot is being aborted or preboot hangs: do not flash this U-Boot; report. The LED is a bonus signal (SPL: lit at power-up).

## L4. Flasher, READ-ONLY session: identity + partition-hash compare

FEL (L1), then:
[WSL]
```
sunxi-fel -v -p uboot uboot/u-boot-sunxi-with-spl.bin \
  write 0x40080000 flasher/Image write 0x4fa00000 flasher/dq10-flasher.dtb \
  write 0x4ff00000 flasher/initramfs.cpio.gz write 0x43100000 flasher/flasher-ro.uenv
```
(`-v` must print `Passing boot info via sunxi SPL: script address = 0x43100000`.) Wait ~30 s. Expected: HDMI shows `DQ10 eMMC FLASHER ... mode: READ-ONLY`; **LED slow blink**; `UDC state` changes to `configured` once the laptop enumerates it. Windows enumerates **1d6b:0104 "DQ10 eMMC flasher"** (a read-only drive letter may appear: ignore it, do not open it).
[PS-ADMIN]
```
usbipd list                                          # expect 1d6b:0104  DQ10 eMMC flasher
usbipd bind --force --hardware-id 1d6b:0104          # audit R4 F1: --force is mandatory. Then REPLUG the A-A cable (same port)
usbipd list                                          # must show 1d6b:0104 ... Shared (forced); no drive letter may exist for it
usbipd attach --wsl --hardware-id 1d6b:0104
```
[WSL]
```
lsblk -o NAME,SIZE,VENDOR,MODEL,TRAN,RO,MOUNTPOINT   # the new disk: TRAN usb, VENDOR DQ10, MODEL "eMMC flasher", RO 1, 14.6G
DEV=/dev/sdX                                         # <- the REAL name; WSL's own virtual disks are also sdX but are not USB
blockdev --getsize64 $DEV                            # MUST be 15634268160

# --- ORDER MATTERS. On first contact you have no backup and no hash list, so the identity of the stick is unknown. ---
# (1) dry run with --skip-identity: guards only, READ-ONLY session, nothing is written (the only legitimate use of --skip-identity here)
bash scripts/ums-flash.sh $DEV --skip-identity

# (2) full backup of YOUR stick (see "Your own backup and hash list"). pipefail so that a dd read error is not hidden by gzip
set -o pipefail
export BACKUP=$HOME/dq10-vendor-backup; mkdir -p $BACKUP
dd if=$DEV bs=1M iflag=direct status=progress | gzip -1 > $BACKUP/dq10-mmcblk0.img.gz
gzip -t $BACKUP/dq10-mmcblk0.img.gz && echo BACKUP-GZ-OK                       # must print BACKUP-GZ-OK
ls -l $BACKUP/dq10-mmcblk0.img.gz; gzip -dc $BACKUP/dq10-mmcblk0.img.gz | wc -c   # must print 15634268160

# (3) your hash list from the backup (~15 GB of disk space), then export it
gzip -dc $BACKUP/dq10-mmcblk0.img.gz > $BACKUP/dq10-mmcblk0.img
bash scripts/make-hash-list.sh $BACKUP/dq10-mmcblk0.img > $BACKUP/partition-hashes.txt
export DQ10_PARTITION_HASHES=$BACKUP/partition-hashes.txt

# (4) the stick must equal the backup: READ-ONLY, every partition vs partition-hashes.txt. It MUST end with COMPARE OK
bash scripts/ums-flash.sh $DEV --compare-hashes 2>&1 | tee ~/compare-before-$(date +%F-%H%M).log

# (5) dry run WITHOUT --skip-identity (sectors 0..73727 must hash to the 'preboot-area' line of YOUR list). It MUST end with DRY RUN OK
bash scripts/ums-flash.sh $DEV
```
**On a repeat session** (backup and list already exist, L0 done in full) steps (1)-(3) are skipped: export `DQ10_PARTITION_HASHES`, then run (4) and (5).
* **Compare result:** one `OK` line per line of your hash list and `COMPARE OK` = the eMMC is exactly the backed-up vendor state. Any `BAD` is **information, not a blocker for the flash** (everything is zeroed anyway): `bootloader_a` BAD = Windows wrote to the FAT volume on 2026-10-29 (fact 7). **Record the result.** (The test unit's result is in BUILD-NOTES 19.7 / 21.) `preboot-area` BAD means sectors 0..73727 changed: the dry run's identity check will refuse. Stop and find out why (a known cause is BUILD-NOTES 21); do not reach for `--skip-identity` on a first write.
* Size differs: wrong device, **STOP**. Dry run `REFUSE:` names the failed guard; never edit a guard.
* If the dry run says **no `1d6b:0104`** or the HDMI screen shows an error / the LED is very fast: nothing is exported. Read the HDMI screen (kernel usb/musb/phy lines are printed), power-cycle into FEL (L1) and retry. If a second try fails, repeat with `dq10speed=full` (forces USB full speed: `sed 's/dq10mode=ro/dq10mode=ro dq10speed=full/' flasher/flasher-ro.uenv > /tmp/ro-fs.uenv` and load that file instead). If it still fails the Linux MUSB gadget shares the unknown cold-entry USB problem of fact 5: Route L is unavailable (see the table); do not improvise.
* Optional: `ls /dev/ttyACM*` in WSL (needs the `cdc_acm` module in the WSL kernel) gives the diagnostic root shell of the flasher.

## L5. Flasher, WRITABLE session

> **HARD STOP before L5 and L6: no wipe without `BACKUP-GZ-OK` AND `COMPARE OK` (both from L4, for THIS stick).** If either is missing, go back to L4. **`--skip-identity` is never used on a first write.** It exists only to repeat the write after an interrupted run of `ums-flash.sh` itself (the pre-boot area then no longer matches your list). Do not use it to get past a missing identity hash: that means you have no backup.

Detach in [PS]: `usbipd detach --hardware-id 1d6b:0104`. Unplug the adapter, FEL again (L1; re-attach `1f3a:efe8`), then:
[WSL]
```
sunxi-fel -v -p uboot uboot/u-boot-sunxi-with-spl.bin \
  write 0x40080000 flasher/Image write 0x4fa00000 flasher/dq10-flasher.dtb \
  write 0x4ff00000 flasher/initramfs.cpio.gz write 0x43100000 flasher/flasher-rw.uenv
```
HDMI must say **`mode: WRITABLE (dq10mode=rw)`** and the **LED must be SOLID** (not blinking). Windows must **not** show a new drive letter (the bind of L4 applies; if one appears, unplug the A-A cable at once, do not open it, and report). [PS] `usbipd attach --wsl --hardware-id 1d6b:0104`, then [WSL]: `lsblk -o NAME,SIZE,VENDOR,MODEL,TRAN,RO` (find `DEV` again; it may have a different letter) and `bash scripts/ums-flash.sh $DEV` (dry run again: it also checks that the sd driver did not report write protect).

## L6. The real write (point of no return for the vendor Android - the backup is the way back)

Hard stop (see L5): `BACKUP-GZ-OK` and `COMPARE OK` must both have been printed for this stick, and the L5 dry run (without `--skip-identity`) must have said `DRY RUN OK`.

[WSL]
```
bash scripts/ums-flash.sh $DEV --yes-wipe-everything 2>&1 | tee ~/ums-flash-$(date +%F-%H%M).log; echo "ums-flash rc=${PIPESTATUS[0]}"
```
**Read the `ums-flash rc=` line** (the pipe to `tee` would otherwise hide the exit code; audit fix 3): **0** = `ALL VERIFIED`; **1** a guard refused (nothing written); **2** written but read-back disagrees (`READ-ERROR` or a hash named in the line); **3** a write step failed half way. 5 s countdown (Ctrl-C aborts), then 1/5 zero all 14910 MiB, 2/5 rootfs 1280 MiB at sector 4194304, 3/5 head (sectors 17..8191, 0..15, **16 last**), 4/5 read-back verify head + rootfs from the media (`iflag=direct`, after a 6 s pause so the flasher's cache is dropped), 5/5 zero-check of the front gap and the tail to the last sector. Duration is dominated by USB 2.0 speed (roughly 30-60 minutes; an estimate: Route L has not been timed on the stick). Keep the laptop awake; do not unplug anything.

## L7. Leave the flasher and boot the new system

[WSL] `sync $DEV` (only that device; a bare `sync` can hang on an unrelated filesystem; the script already flushed). [PS] `usbipd detach --hardware-id 1d6b:0104`. Then unplug the **adapter and the A-A cable**, wait 10 s, plug the **adapter in WITHOUT the button** (HDMI attached). The BROM finds our SPL at sector 16: **LED lit within ~1 s (SPL; active-low fixed)**, U-Boot -> keyed autoboot (2 s) -> distro boot -> Armbian, **heartbeat after ~15-25 s**, HDMI console. **The first boot is slow:** `dq10-wipe-vendor.service` always runs once and zero-fills the free ranges again (10-20 min), blocking the login prompt; then Armbian's resize may reboot once. Normal, not a hang (Part 2, section 8).

## L8. Verify

SSH (key only, section 8.1) or console: run the checklist of section 10 (10.1 software identity, 10.2 wipe verification, 10.4 Wi-Fi, 10.5 eMMC health). `1f3a:efe8` appearing on the laptop after L7 means the BROM did not accept the SPL (table).

## Failures at each step, and the way back

| step | symptom | meaning | action |
|---|---|---|---|
| L1 | no `1f3a:efe8` | wrong power-up order, cable/port, microSD inserted | adapter out, **button held**, adapter in; other cable/port; remove the card; nothing written |
| L1/L4/L5 | `usbipd attach`: "Device in error state" | Windows' driver held the device (fact 9) | retry; detach+retry; replug the A-A cable |
| L2 | DRAM test fails | DRAM params wrong for this SPL build | **do not flash**; investigate |
| L3 (a) | FEL does not come back | U-Boot proper hangs before bootcmd after a cold entry | **NO-GO**: the eMMC boot would do the same |
| L3 (b) only | FEL comes back with the override, not with the flashed config | autoboot aborted or preboot hangs | **do not flash this U-Boot**; report |
| L4/L5 | HDMI black after loading | Linux did not start (DT/kernel) - but D5 worked with the same kernel | power-cycle, retry once; compare with `diag/d5-linux.uenv` |
| L4/L5 | HDMI shows `FLASHER ERROR` / LED very fast | no unique 15,634,268,160 B MMC disk, a module failed, or no UDC appeared | nothing is exported; read the screen; retry once, then `dq10speed=full`; else Route L unavailable (below) |
| L4/L5 | status screen fine, `UDC state` never `configured`, no `1d6b:0104` | USB enumeration fails (cable/port/HS signalling, or the unknown cold-entry USB problem of fact 5) | other cable/port (USB 2.0, no hub), `dq10speed=full`, Windows Event Viewer; else unavailable |
| L4 | dry run `REFUSE` | a guard failed (not USB, wrong size, mounted, identity) | the message names it; fix the cause |
| L4 | compare shows `BAD` | the vendor eMMC differs from the backup | record; irrelevant for the flash (all zeroed) |
| L5 | drive letter appears for the writable session | Windows' storage driver got the device before usbipd | unplug the A-A cable immediately, report; do not write |
| L6 | rc 1 with "WRITE PROTECT" | flasher is in the read-only mode | repeat L5 with `flasher-rw.uenv` |
| L6 | rc 3 / disk vanished mid-write | USB reset, laptop sleep, power glitch | the SPL header is zeroed first, so the BROM returns to FEL on button + power: repeat L1, L5, dry run (identity now fails: `--skip-identity` **only** here), L6 |
| L6 | rc 2 (`MISMATCH` / `READ-ERROR`) | data written, read-back disagrees | do not power-cycle; re-run L6 with `--skip-identity`; if it keeps failing, the eMMC or USB link is faulty: restore the backup (below) |
| L7 | LED never lights, HDMI black, `1f3a:efe8` visible | BROM rejected the image (SPL header not committed) | repeat L1, L5, L6 |
| L7 | LED solid forever / no `1f3a:efe8` | SPL accepted but hangs - **the one state without a software way back** | button + power FEL entry: D1 showed the BROM honours the button before it loads any media (a valid vendor boot0 was on the eMMC and no eGON had been loaded), so the same entry should work with our SPL - **inferred, D1b not run**; fallback microSD `fel-sdboot` (section 9). L3 passing makes this unlikely |
| L7/L8 | boots, but no HDMI / no Wi-Fi | kernel/DT/driver | SSH or USB Ethernet; section 10.4 |

**Route L unavailable** (the gadget never enumerates): the other ways are the ADB fallback if Android runs again (fact 2), or a microSD image (section 9: `dq10-armbian.img` boots a full Linux with the eMMC as `/dev/mmcblk0`; write the eMMC from there, e.g. by `dd` over the network). Do not improvise a write path without the same guards (exact size, identity, read-back).

**FEL is reachable while the eMMC holds no valid SPL** (BROM mask ROM), and by the button even with a valid boot0 on the eMMC (fact 1; with OUR SPL on the eMMC this is inferred, not tested).

### Restore the original vendor image (undo everything) through the same path

Repeat L1, L5 (writable flasher attached to WSL as `$DEV`), then:
[WSL]
```
DEV=/dev/sdX                                          # the exported disk, verified as in L4 (VENDOR DQ10, size 15634268160, TRAN usb)
blockdev --getsize64 $DEV                             # MUST be 15634268160
readlink -f /sys/block/$(basename $DEV)/device | grep -Eq '/usb[0-9]+/' || echo NOT-USB-STOP     # MUST print nothing (audit fix 6); a raw 15 GB write needs more than the size
awk -v d="$DEV" '$1 ~ d' /proc/mounts /proc/swaps     # MUST print nothing
blockdev --setrw $DEV
gzip -dc $BACKUP/dq10-mmcblk0.img.gz | dd of=$DEV bs=1M iflag=fullblock oflag=direct conv=fsync status=progress
sync $DEV; blockdev --flushbufs $DEV; sleep 6
# verify 1+2 (read-only; same code path as before the flash): boot area + every partition against YOUR partition-hashes.txt
bash scripts/ums-flash.sh $DEV --compare-hashes            # all OK + COMPARE OK
# verify 3 (optional, slow, complete): byte-for-byte comparison of the whole disk; silence + exit 0 = identical
cmp <(gzip -dc $BACKUP/dq10-mmcblk0.img.gz) <(dd if=$DEV bs=1M iflag=direct status=none) && echo FULL-IMAGE-IDENTICAL
blockdev --setro $DEV
```
Then [PS] `usbipd detach --hardware-id 1d6b:0104` and power-cycle (adapter out/in, no button). This puts back **exactly what was received - malware included** (root agent `polkitu_android`, JM remote command system; see `MALWARE-IOCS.md`): keep the stick on the isolated network and apply the egress block (`scripts/device/dq10-prep.sh`) as soon as Android runs. Whether the restored vendor boot0 returns to FEL once more is unknown (the efex flag is gone, so probably not). The eMMC hardware boot partitions were never touched by this plan.

### Route F (recovery U-Boot UMS) - historic, NOT usable from a cold button entry
`uboot/recovery/u-boot-recovery-with-spl.bin` (sha256 `1d33b20ecfc915412269d03c15c2a1be0a768c6f2b0886a5d32d49d406188033`, unchanged) exported the eMMC once, on 2026-10-29, after a vendor-efex-jump FEL entry (USB `1f3a:1010` "Linux UMS disk 0"). From a button entry `ums 0 mmc 1` fails (fact 5). `scripts/ums-flash.sh` still accepts that UMS disk (vendor `Linux`, model `UMS disk 0`) should it ever work again.

---

# PART 2 - Reference and fallback

## 0. What gets written, and the hashes to check (both routes)

| File | Size | SHA-256 |
|---|---|---|
| `image/rootfs.ext4.gz` (gz of the 1.25 GiB root filesystem, eMMC variant) | 400,131,296 B | `ff72f2cc2b25292793208c91c9c27237c54f3059a0d8b684af326d6602f8f1ab` |
| rootfs after `zcat` (must be on the eMMC at sector 4194304) | 1,342,177,280 B | `3ce4160814fb2885eb50a5df54fd35670a99cd8c42a5dd8ee7c1603e835b770b` |
| `image/head-emmc-4MiB.bin` = eMMC sectors 0..8191 (new MBR + SPL at 8 KiB + U-Boot FIT at sector 96) | 4,194,304 B | `81566c4080f1703974b42e9ddf2ec2e20de3a4e835792fb90fb817e0d2b0dc95` |
| `uboot/u-boot-sunxi-with-spl.bin` (inside the head file at byte 8192) | 790,505 B | `48691413166cb499c2f2328290e7ff5fd700064e980b57871a934ce693e1ea72` |
| `uboot/recovery/u-boot-recovery-with-spl.bin` (FEL only, never written) | 863,377 B | `1d33b20ecfc915412269d03c15c2a1be0a768c6f2b0886a5d32d49d406188033` |
| `image/dq10-armbian.img` (conventional layout, **for a microSD card**; own filesystem UUID `5d1e0c10-...`) | 1,346,371,584 B | `54e69e44fd231b2773d54a0532951e170ab21901e2eeda6a11abdf2bef6246ad` |
| `dts/sun50i-h616-dq10-athena-p1.dtb` (PH6/PH7 LEDs active-low) | 36,135 B | `6287d02a7bfb8a923714b1daf443a5f4313777a867f6b8bc3929d1e43932f286` |
| `flasher/Image` (= shipped Armbian kernel) | 35,437,056 B | `e5bc78d4e3a6776f70cb5efe8be0f6e989095ead8498100ce70920018bc9cfce` |
| `flasher/dq10-flasher.dtb` | 36,130 B | `31dfce302c20d17bf85fdbf4eeb32f787702602fa5d15b612a644f96bb1de1bc` |
| `flasher/initramfs.cpio.gz` | 2,134,891 B | `5fc33775ba8a8948d4fff83388ebb1149e1ae274d730c0e7532851f860e97801` |
| `flasher/flasher-ro.uenv` / `flasher-rw.uenv` | 460 B each | `13b9279a...588d` / `4651c3be...bc68` (full list: `flasher/SHA256SUMS`) |

Final eMMC layout (30,535,680 sectors):

```
sector 0        MBR (one partition: p1 start 4194304, size 2621440, type 83, disk-id 0x85d82b93)
sectors 1-15    zero (no GPT header)
sector 16       SPL (eGON.BT0)  --- BROM loads it from 8 KiB
sector 96       U-Boot FIT (U-Boot + TF-A BL31 + DTB)   (ends ~sector 1559)
sectors ..8191  zero
sectors 8192 .. 4194303      old vendor data until the first-boot wipe zeroes it
sectors 4194304 .. 6815743   p1 = Armbian root ext4 (UUID e70cdb2c-...)
after first boot: Armbian's resize grows p1 to sector 30212095 (1% spare, 16 MiB aligned);
sectors 30212096 .. 30535679 (323,584 sectors = 158 MiB) stay unpartitioned and are zero (wiped).
```

Why p1 sits at 2 GiB: sectors 4,021,560 .. 6,890,495 are the **unused tail of the vendor `super` partition** (`lpdump`: last used extent ends at super-sector 3,422,520; `dmctl table` shows only `system_a/vendor_a/product_a/vendor_dlkm_a` as linear maps on `179:9`, all mounted `ro`, no dm-verity target). Staging there leaves everything Android needs untouched until the final sub-second commit (BUILD-NOTES sec. 10). The auditor re-verified this on the stick.

## 1. Preconditions (general; items 5-6 apply mainly to the ADB fallback, Route L never runs the vendor Android)

1. **Backup verified**: `gzip -t "$BACKUP/dq10-mmcblk0.img.gz" && echo BACKUP-GZ-OK` (15,634,268,160 B uncompressed, `partition-hashes.txt`). It is the **only** copy of the vendor data and contains the malware described in `MALWARE-IOCS.md` (observed 2026-10).
2. **A microSD card (any 4-32 GB, ~EUR 5) is recommended, not required for Route L** (less critical now that FEL and the DRAM init are proven). With the fixed U-Boot (SD controller enabled in its DT - audit H2) the BROM/U-Boot try the card **before** the eMMC. You get (a) a zero-risk test boot of this exact software (Phase A) and (b) a rescue medium afterwards: a card with the `dq10-armbian.img` boots a full Linux with the eMMC visible as `/dev/mmcblk0`; a card with sunxi-tools `fel-sdboot.sunxi` forces FEL. **Caveats (audit H1): if the SPL hangs in DRAM init the same code runs from the card, so the card only helps for non-DRAM failures** (bad rootfs, bad DT, wrong MBR, a later software mistake).
3. Stable power for the stick during steps 5-6 (never unplug). Laptop on mains. Hotspot stable (~400 MB transfer).
4. A **USB hub + USB keyboard** and an HDMI display for the first login (the stick has a single USB-A port) - or use an SSH key baked into the image with `AUTHORIZED_KEY=` (see 8.1) plus Wi-Fi credentials (section 3) / USB Ethernet.
5. Keep the stick on the isolated hotspot only. The egress block (iptables chain `DQ10BLOCK`) is **runtime-only: it is lost on every reboot**. `scripts/device/dq10-prep.sh` re-applies it idempotently - run it at the start of every session on the stick (4.0), after any reboot of Android (including the Phase 0 FEL probe), and again before staging and commit.
6. Threat model: the vendor Android is compromised (a root remote-access agent was found running, observed 2026-10; see `MALWARE-IOCS.md`). Never execute anything pulled from the stick on the laptop. Treat on-device hash output as advisory; the real proof is the post-boot checks (section 8) from software we built.

## 2. Phase 0: the FEL probe - DONE on 2026-10-29 (result: FEL works), and the zero-write test boot

*(Route L, Part 1 above, reuses these commands as steps L1-L2. Historic: on 2026-10-29 FEL was entered with `reboot efex` from Android; that flag is gone now, FEL is entered with the button - see "Hardware facts" at the top.)*

**Result (main session, zero eMMC writes):** `$ADB shell reboot efex` put the stick into FEL; the laptop saw **USB 1f3a:efe8**; the device was passed to WSL kali with usbipd-win (`usbipd attach --wsl --hardware-id 1f3a:efe8`; needs only the owner's one-time `usbipd bind`, no admin afterwards). Then:
* `sunxi-fel ver` -> H616 family, soc 0x1823; `sunxi-fel sid` -> SID word 0 = `33802100` (words 1-3 are the unique chip ID; they are deliberately not published).
* `sunxi-fel -v spl uboot/u-boot-sunxi-with-spl.bin` (the **pre-fix build, sha256 2c792ef3...0909**) executed our SPL: **DRAM init succeeded and returned to FEL**; sunxi-fel then loaded TF-A to 0x40000000 and U-Boot to 0x4a000000.
* RAM test: 2 MiB random patterns written and read back OK at 0x42000000, 0x50000000 ... 0xB0000000 and 0xBFE00000 (9/9); an alias test (0x40001000 / 0x60001000 / 0x80001000 / 0xA0001000 holding distinct values) stayed intact -> **the full 2 GiB is present and unaliased**.

Conclusions: (1) the decoded vendor DRAM parameters work on the hardware with the mainline LPDDR3 code (audit H1's biggest risk is largely retired); (2) **FEL works**, i.e. a proven recovery path as long as the BROM can be made to enter it (see 9). What is still not covered by this test: the BROM loading the SPL from the eMMC (the vendor boot0 proves that works) and U-Boot reading `boot.scr` from eMMC/SD.

**The U-Boot rebuild of this revision (SD node enabled) keeps the identical DRAM/PMIC configuration** (BUILD-NOTES 16: `.config` diff old vs new = only `DEFAULT_DEVICE_TREE` and `OF_LIST`). The SPL binary is not byte-identical (its embedded DT is larger), so run the new one once before flashing: `bash scripts/fel-dram-test.sh` (runs `sunxi-fel spl uboot/u-boot-sunxi-with-spl.bin` = the new build, then a pattern test over 0x40000000..0xBFFFFFFF; no eMMC access).

Commands (stick in FEL; Windows side then WSL kali, repo at `$PKG`):
```
usbipd list                                  # Windows: shows 1f3a:efe8
usbipd attach --wsl --hardware-id 1f3a:efe8  # Windows (no admin after the one-time bind)
sunxi-fel -l; sunxi-fel ver                  # WSL
bash scripts/fel-dram-test.sh                # new SPL + pattern test
```
Tools: `sunxi-fel` 1.4.2 from the kali `sunxi-tools` apt package. No Windows-native binary was built or downloaded (building third-party tools was blocked by policy and I did not circumvent it); if you prefer one, take it from the sunxi-tools project and install the WinUSB driver for `1f3a:efe8` with Zadig.
If Android is re-entered after a probe (fallback route only; the efex flag is gone, so Android is what normally boots): power-cycle (unplug 10 s) and **re-apply the egress block at once** (`sh /dev/dq10-prep.sh`, 5/4.0) - it is lost with every reboot - then check `$ADB shell id`.

### 2.1 Zero-write FEL "full test boot": kernel + our DTB + Wi-Fi initramfs in RAM (HDMI and Wi-Fi scan before touching the eMMC)
Bundle `felbundle/` (built by `scripts/build-fel-bundle.sh` from the final image; hashes in its `SHA256SUMS`): `Image` (Armbian 6.18.53, 35.4 MB), `dq10.dtb` (= `dts/*.dtb`), `initramfs.cpio.gz` (4.7 MB: static busybox from Debian trixie `busybox-static 1:1.37.0-6+b9` [downloaded, sha256-checked, never executed here], `iw` + libs, the AIC8800 modules + `cfg80211`/`rfkill`, the Radxa AIC8800D80 firmware), `boot.scr` (U-Boot script; initramfs size baked in).
Load addresses are U-Boot's sunxi arm64 defaults (`include/configs/sunxi-common.h`): kernel `0x40080000`, FDT `0x4fa00000`, **script `0x4fc00000`** (sunxi-fel passes the script address to U-Boot through the SPL header - the binary contains "Passing boot info via sunxi SPL: script address = ..." and U-Boot's `bootcmd_fel` sources `fel_scriptaddr`), ramdisk `0x4ff00000`. BL31 sits at 0x40000000 and U-Boot at 0x4a000000: no overlap with the ~35 MB kernel.
```
cd $PKG
sunxi-fel -v -p uboot uboot/u-boot-sunxi-with-spl.bin \
  write 0x40080000 felbundle/Image \
  write 0x4fa00000 felbundle/dq10.dtb \
  write 0x4ff00000 felbundle/initramfs.cpio.gz \
  write 0x4fc00000 felbundle/boot.scr
```
Only RAM is written (about 40 MB over USB). Then watch **HDMI**: kernel log; the banner "DQ10 FEL TEST BOOT"; DRM/HDMI lines; regulators (expect vdd-dram 1200000); the SDIO devices (`0xc8a1`, `0x0082`/`0x0182`); the AIC8800 module/firmware log; `ip link`; an `iw dev wlan0 scan` list; then a shell (USB keyboard via a hub). LED PH6 heartbeat = Linux alive. The eMMC is visible but not mounted. To leave: power-cycle -> Android returns (eMMC untouched). Unknown until run: whether HDMI lights up with this DT, whether the SDIO chip enumerates (power sequence), whether the scan returns networks - exactly what this bundle is for.

## 3. Optional: bake Wi-Fi credentials into a copy of the rootfs

In WSL as root (a line starting with a space, or `unset HISTFILE`, keeps the passphrase out of history; `sudo -E` if not root):
```
 SSID='your-hotspot' PSK='your-passphrase' REGDOM=GR \
  bash scripts/set-wifi.sh <(zcat image/rootfs.ext4.gz) image/rootfs-wifi.ext4   # or gunzip first
gzip -9 -n -k image/rootfs-wifi.ext4
```
Use the resulting file in 5.1 instead (and its own sha256; the "after zcat" hash in 5.3 changes accordingly). Quotes and backslashes in SSID/PSK are handled (YAML single-quoting). Do **not** reuse any Wi-Fi password that was ever configured on the vendor firmware: treat it as exposed.

## 4. Phase A (recommended): test-boot from a microSD, eMMC untouched

1. Write `image/dq10-armbian.img` to the card (balenaEtcher or Raspberry Pi Imager "Use custom"; or `dd` from Linux with the card's real device node). It has its **own filesystem UUID** (`5d1e0c10-...`) so `root=UUID=` cannot pick the eMMC rootfs later (audit L4).
2. Power off the stick, insert the card, power on. Expected (unverified): LED PH6 solid within ~1 s (SPL), U-Boot finds `boot.scr` on the card (SD = U-Boot `mmc 0`, tried before the eMMC), LED heartbeat after ~15-25 s, HDMI console. With Android still on the eMMC, U-Boot would otherwise fall back to the eMMC and fail - that false negative (audit H2) is why the U-Boot DT now enables SMHC0.
3. `dq10-wipe-vendor.service` **refuses to run** on the card (no eMMC boot partitions on it) so the eMMC cannot be wiped by this test; Armbian's resize then grows the card's rootfs.
4. On the running system do section 8 (except the wipe checks) - RAM size, `dmesg`, regulators, HDMI, Wi-Fi, SSH, BROM hash. Remove the card before Phase B unless you want it to keep boot priority.
5. If it does not boot, the eMMC/Android is untouched; fix first. Remember audit H1: a DRAM-init failure looks the same from the card as from the eMMC.

## 5. FALLBACK (ADB route), Phase B: preflight (read-only on the stick)

> **FALLBACK - NOT the main route since revision 3.** Sections 5, 6, 7 (and the old Phase B text in 9.1) describe the Android-staged flash through `adb` exactly as audited in revision 2 (H3 text and the MEDIUM mitigations M1/M2 are kept intact). It needs the vendor Android to be **running** and reachable by adb. The efex flag is gone (fact 2), so a normal power-up runs the vendor chain again and **Android may boot** (not checked: ping <stick-ip> / hotspot client list / `adb connect`); only then is this route possible, with all the caveats below unchanged. It also has a ~1 s commit window (section 7) that Route L does not have. Use Route L (Part 1) unless Route L is unavailable and Android runs.

```
# 4.0 (once per session and after ANY reboot of Android): push + run the prep script (runtime-only, idempotent)
$ADB exec-in 'cat > /dev/dq10-prep.sh' < scripts/device/dq10-prep.sh
$ADB shell 'sh /dev/dq10-prep.sh'
#   expect: DQ10BLOCK chain with lo RETURN / <lan-subnet> RETURN / REJECT; update_engine/ttyunos/qw/rootaccess "stopped";
#   "no agent processes left"; free RAM printed.  ip6tables chain DQ10BLOCK6 likewise.
# 4.1 identity: root, serial prefix, eMMC CID, exact size (compare with the values you recorded from YOUR stick before)
$ADB shell 'id -u; getprop ro.boot.serialno | cut -c1-6; cat /sys/class/mmc_host/mmc0/mmc0:0001/cid; blockdev --getsize64 /dev/block/mmcblk0'
#   expect: 0 / <your serial prefix> / <your eMMC CID> / 15634268160
# 4.2 boot area unchanged since the backup (36 MiB read)
$ADB exec-out 'dd if=/dev/block/mmcblk0 bs=1048576 count=36 2>/dev/null | sha256sum'
#   expect the 'preboot-area' hash of YOUR hash list (sha256 of the first 36 MiB of your backup)
# 4.3 the free tail of super: layout unchanged, no OTA/snapshot state
$ADB exec-out 'lpdump | grep -E "linear super|super: |Size:"'
#   expect the four extents ending at 3399680+22840 = 3422520 and "Size: 3221225472" (super starts at disk sector 599040)
$ADB exec-out 'dmctl list devices; mount | grep -E "dm-|mmcblk0p9"; getprop init.svc.update_engine'
#   only system_a/vendor_a/product_a/vendor_dlkm_a; all ro; update_engine "stopped"
```
Abort and investigate if anything differs. (The audit found the state clean: `snapshotctl` "Update state: none", `/metadata/ota/snapshots` empty, no `scratch` partition. A running OTA (Virtual A/B) would allocate `_b` partitions inside exactly this free tail - that is why `update_engine` is stopped.)

## 6. FALLBACK (ADB route), Phase B: stage the root filesystem (Android keeps running)

Writes only disk sectors 4,194,304 .. 6,815,743, inside the unused part of `super`. Re-run `sh /dev/dq10-prep.sh` first (it is idempotent).

```
# 5.1 stream: the stick's own zcat decompresses, dd writes at 2 GiB (seek in 1 MiB blocks: 2048 * 1 MiB = sector 4194304)
$ADB exec-in 'zcat | dd of=/dev/block/mmcblk0 bs=1048576 seek=2048 conv=notrunc,fsync' < image/rootfs.ext4.gz
# (exec-in forwards stdin only and prints nothing. Do NOT use "adb shell -T" for binary input: in the build agent's test it
#  silently altered a 3 MB stream.)
# 5.2 wait until the remote dd has ended, flush
$ADB shell 'while pidof dd >/dev/null; do sleep 2; done; sync; blockdev --flushbufs /dev/block/mmcblk0; echo 3 > /proc/sys/vm/drop_caches'
# 5.3 read back exactly 1,342,177,280 bytes from the media and hash
$ADB exec-out 'dd if=/dev/block/mmcblk0 bs=1048576 skip=2048 count=1280 2>/dev/null | sha256sum'
#   MUST equal 3ce4160814fb2885eb50a5df54fd35670a99cd8c42a5dd8ee7c1603e835b770b  (the maintainer's reference build; for YOUR OWN build use
#   the rootfs.ext4 line of your image/SHA256SUMS: grep ' rootfs.ext4$' image/SHA256SUMS)
```
If the hash differs: repeat 5.1-5.3 (junk space; nothing important is lost). If it keeps failing, stop; the stick still boots Android.

## 7. FALLBACK (ADB route), Phase B: commit (the point of no return; ~1 second)

```
# 6.1 put the 4 MiB head image and the commit script into the stick's RAM disk (/dev is tmpfs)
$ADB exec-in 'cat > /dev/dq10-head.bin' < image/head-emmc-4MiB.bin
$ADB exec-in 'cat > /dev/dq10-commit.sh' < scripts/device/dq10-commit.sh
$ADB shell 'sha256sum /dev/dq10-head.bin | cut -c1-64; ls -l /dev/dq10-head.bin'
#   MUST be 81566c4080f1703974b42e9ddf2ec2e20de3a4e835792fb90fb817e0d2b0dc95 (maintainer's reference build; for YOUR OWN build use the
#   head-emmc-4MiB.bin line of your image/SHA256SUMS, AND set HEADSHA in scripts/device/dq10-commit.sh to the same value before pushing it) and 4194304 bytes
# 6.2 final go/no-go: re-run prep (4.0), 4.2/4.3 checks, and the 5.3 hash.  Then run the commit detached (survives an adb drop;
#     the script sets oom_score_adj -1000 for itself because the stick has only tens of MB free):
$ADB shell 'nohup sh /dev/dq10-commit.sh >/dev/null 2>&1 &'
# 6.3 wait a few seconds (an immediate read can show an incomplete log), then read the result
sleep 10; $ADB shell 'tail -5 /dev/dq10-commit.log'
#   MUST end with COMMIT-VERIFIED-OK
```
What the script does (`scripts/device/dq10-commit.sh`): refuse unless the head hash and eMMC size match; write sectors 17..8191 (our U-Boot FIT + zeros; after this both vendor boot0 copies are invalid); write sectors 0..15 (new MBR, kills the vendor GPT header); write sector 16 (the SPL header = commit point); sync, flush, read 4 MiB back, compare.

**RULE (audit H3): never power-cycle, unplug or reboot the stick until `/dev/dq10-commit.log` shows `COMMIT-VERIFIED-OK`.**
Between steps 1 and 3 of the script the BROM would find no valid image, and FEL is proven but cannot be entered by itself while the first image bytes are half replaced, so a power loss there is still to be avoided. The script needs about one second and runs detached, so a lost adb session does not stop it. If adb is lost:
1. **wait** (minutes if needed); do not touch the power;
2. reconnect (`adb connect <stick-ip>:5555`, `adb root`), re-run `sh /dev/dq10-prep.sh` only if you must (not required for reading);
3. read `$ADB shell 'tail -20 /dev/dq10-commit.log'`. `COMMIT-VERIFIED-OK` -> done. `COMMIT-VERIFY-FAILED`, `FAIL stepN`, or no log/`ABORT` -> re-run the commit (`nohup sh /dev/dq10-commit.sh ...`); `/dev` survives as long as Android is up. If `/dev/dq10-commit.sh` or the head file vanished (Android rebooted by itself), the vendor boot chain may be in the half-written state: re-run from 6.1 as soon as adb is back; if adb never returns, use section 9 (microSD / FEL).
4. only after `COMMIT-VERIFIED-OK`: power-cycle (unplug 10 s) or `$ADB shell reboot`.

## 8. First boot - what to expect

| time | expected | notes |
|---|---|---|
| 0-1 s | LED PH6 solid on | SPL's status LED (GPIO 230 = PH6, vendor "normal_led"); if it stays off nothing is proven either way |
| 1-5 s | DRAM init, BL31, U-Boot, `boot.scr` (blind) | the only U-Boot-stage signal is the LED staying solid (nothing in U-Boot turns it off) |
| ~15-25 s | LED PH6 **heartbeat** (Linux alive); HDMI console | HDMI is the least certain part |
| first 10-20 min | `dq10-wipe-vendor.service` zero-fills ~13 GB and verifies; progress on tty1 | blocks `basic.target`: the login prompt appears only after it ends. Log: `/var/lib/dq10/wipe.log` (on the real disk; `/var/log` is zram under Armbian). If it ever fails it re-runs on **every** boot and blocks Armbian's resize - safe, but the stick then looks "stuck"; `/var/lib/dq10/wipe-done` exists only after success |
| then | Armbian grows p1 (to sector 30212095), may reboot once | |

Failure diagnosis (no serial console):

| symptom | likely cause | action |
|---|---|---|
| LED never lights, no HDMI | SPL not run (BROM found no valid image -> FEL?), or SPL died before the LED | `lsusb`/Device Manager for `1f3a:efe8`; re-commit |
| LED solid forever | DRAM init hang, or U-Boot FIT / `boot.scr` not found | DRAM parameters are the prime suspect (BUILD-NOTES 3.3); a microSD does not help for DRAM (same SPL) |
| LED solid, nothing else | U-Boot ran, no bootable partition found | insert the Phase-A card (boots first), repair from there |
| heartbeat but black HDMI | kernel OK, display pipeline/DT problem | use SSH (below) and read `dmesg` |

### 8.1 First login and SSH (audit M4)
* **No SSH key is baked into the image unless you ask for it.** Build with `AUTHORIZED_KEY=/path/to/your_key.pub sudo -E scripts/build-image.sh` and the **public** key is installed as `/root/.ssh/authorized_keys` (dir 0700, file 0600, root-owned); never put a private key anywhere. Without it there is no SSH login (console only); you can add a key later from the console (`install -d -m700 /root/.ssh; cat your_key.pub >> /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys`) or, before flashing, into a loop-mounted copy of the rootfs. In both cases the image has `/etc/ssh/sshd_config.d/00-dq10.conf` with `PermitRootLogin prohibit-password`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no` (sshd keeps the first value it reads and the Include is at the top of `sshd_config`, so the file's own `PermitRootLogin yes` is overridden). Armbian's first-run only regenerates host keys and edits `AcceptEnv`; first-login does not touch `authorized_keys` unless `PRESET_ROOT_KEY` is set (it is not). The private key was never read or copied by this package.
* From the laptop: `ssh -i ~/.ssh/<your-key> root@<ip>` (find the ip with `arp -a` / the hotspot's client list).
* **What the HDMI console asks (nothing blocks the boot):** a `dq10 login:` prompt; Armbian's default root password is `1234` and works **only on the local console** (SSH password auth is off). On the console `Press Enter to start the first login setup on this console` appears; the wizard then asks to **set a new root password**, choose the shell, create a regular user (name + password), and locale/timezone questions. Over SSH (key) the wizard starts automatically in the session with the same questions. A regular user created by the wizard has no SSH key - log in as root with the key (or copy `authorized_keys` to the user) because password logins are disabled.

## 9. Recovery options, ranked (FEL by button is PROVEN; Route L is built but not yet run against the PC)
1. **FEL via the BROM**, available whenever the BROM finds no valid boot image (blank/invalid eMMC *and* no SD card with a valid image): the stick then waits as `1f3a:efe8`; attach with usbipd and use `sunxi-fel` (section 2). Entered with the **button held while plugging in the power adapter** (proven 2026-10-30; the old `reboot efex` flag is gone). **After our SPL is committed** `reboot efex` no longer exists and the BROM does not return to FEL when the SPL is valid but hangs; to force FEL again you need one of: an SD card carrying `fel-sdboot.sunxi` (sunxi-tools, written at 8 KiB; the BROM tries the card first), a deliberately invalid eMMC boot area (from a rescue Linux on SD: zero sector 16), or the hardware trick (short the eMMC clock/CMD pad to ground at power-on; case open).
2. **Route L - flash/rescue the eMMC from the PC through FEL + the Linux flasher (USB gadget): this is Part 1 of this file.** The eMMC appears as USB disk `1d6b:0104` "DQ10 eMMC flasher", attached to WSL with usbipd, then `scripts/ums-flash.sh`. The write path was tested only on loop files (BUILD-NOTES 18, 19); the gadget itself has never run on the stick. No Android takes part; an interrupted write leaves an invalid SPL, i.e. the BROM returns to FEL and you retry. (Route F, the recovery U-Boot UMS, does not start from a button entry: not usable.)
3. **microSD** (U-Boot tries it first): `dq10-armbian.img` boots a full Linux with the eMMC as `/dev/mmcblk0` for repair/restore.
4. **Restore Android from the backup** through the Route L path with the exact commands (write + verifications) in Part 1, "Restore the original vendor image" - exactly as received, malware included.

### 9.1 Which flash route to use now
Order: (1) FEL DRAM test, **U-Boot reach test** and the flasher's read-only session (L2-L4: nothing written) -> (2) microSD test boot (Phase A, optional) -> (3) **Route L (Part 1)** -> (4) only if Route L cannot work (no gadget enumeration) *and* Android is running: the ADB-staged fallback (sections 5-7, audited). Route L is the main route because the compromised vendor Android never participates, every interruption leaves the stick in FEL, and there is no ~1 s commit window.

## 10. Post-flash verification checklist (on the running Linux, as root)

### 10.1 Is it our software, on the intended hardware
```
cat /proc/device-tree/model; uname -r                       # "DQ10 TV stick (athena_p1)", 6.18.53-current-sunxi64
cat /proc/cmdline; free -m | head -2                         # MemTotal about 1.9-2.0 GB (if ~1 GB: DRAM size detection problem)
dmesg | grep -i -E "axp|regulator|mmc2|mmcblk0|sunxi-mmc|panfrost|hdmi|drm|aic|sdio|thermal" | head -80
for r in /sys/class/regulator/regulator.*; do echo "$(cat $r/name) $(cat $r/microvolts 2>/dev/null)"; done
#   expect vdd-dram = 1200000, vcc3v3 = 3300000, vcc1v8 = 1800000, vdd-cpu 0.9-1.1 V
cat /sys/class/thermal/thermal_zone*/temp
```
RAM stress (no network needed): `python3 -c "b=bytearray(1400*2**20); [b.__setitem__(slice(i,i+4096),b'\xa5'*4096) for i in range(0,len(b),4096)]; print(all(x==0xa5 for x in b))"` a few times, or `memtester` once Wi-Fi works; watch `dmesg`.

### 10.2 Wipe verification (the "nothing vendor survives" requirement)
```
cat /var/lib/dq10/wipe-done; tail -20 /var/lib/dq10/wipe.log        # "WIPE OK" (log may be truncated on the console; wipe-done is the real proof)
lsblk -o NAME,SIZE,TYPE,START /dev/mmcblk0
sfdisk -d /dev/mmcblk0          # sector 0 CHANGES after Armbian's resize (fdisk rewrites the partition entry): check this, do not hash sector 0.
#   expect one partition, start=4194304, size about 26,017,792 sectors (end = sector 30212095)
P=$(cat /sys/class/block/mmcblk0p1/start); E=$(( P + $(cat /sys/class/block/mmcblk0p1/size) )); T=$(blockdev --getsz /dev/mmcblk0)
echo "p1 start=$P end(excl)=$E disk=$T"            # expect E = 30212096, T = 30535680 -> tail = 323,584 sectors (158 MiB)
cmp -n $(( (P-8192)*512 )) <(dd if=/dev/mmcblk0 bs=512 skip=8192 count=$((P-8192)) status=none) /dev/zero && echo FRONT-OK
cmp -n $(( (T-E)*512 )) <(dd if=/dev/mmcblk0 bs=512 skip=$E status=none) /dev/zero && echo TAIL-OK     # meaningful: the 158 MiB tail was zeroed by the wipe
for b in mmcblk0boot0 mmcblk0boot1; do cmp -n 4194304 /dev/$b /dev/zero && echo "$b EMPTY"; done
# SPL + U-Boot untouched: compare sectors 1..8191 with the head image (sector 0 differs after the resize)
dd if=/dev/mmcblk0 bs=512 skip=1 count=8191 status=none | sha256sum     # compare with: tail -c +513 head-emmc-4MiB.bin | sha256sum on the laptop -> 91055ca672bc9020291bbf8abf5b56bbe910421f4d3475691765d22ec885e462
```
Not reachable by software, by design: eMMC **RPMB** (4 MiB, keyed), controller spare/wear-levelled blocks, eFuses, BROM. `blkdiscard`/secure erase were not used (semantics vary); explicit zero-write + read-back is verifiable.

### 10.3 SoC / eFuse / secure-boot state (record, do not publish the unique ID)
```
xxd -l 4 -e /sys/bus/nvmem/devices/sunxi-sid0/nvmem      # word 0; was 33802100 under Android. Words 1-3 are the unique chip ID: do NOT note them.
sha256sum /sys/bus/nvmem/devices/sunxi-sid0/nvmem
```
Secure boot: the vendor read `sunxi_secure normal`. Mainline has no simple flag; the BROM dump (10.6) tells: only one of NBROM/SBROM is mapped depending on the secure-boot eFuse (smaeul/sunxi-blobs README).

### 10.4 Wi-Fi bring-up and debug checklist (AIC8800D80, SDIO C8A1:0082 / C8A1:0182)
Software: modules `aic8800_bsp`, `aic8800_fdrv`, `aic8800_btlpm` in `/lib/modules/6.18.53-current-sunxi64/extra/aic8800/` (radxa-pkg/aic8800 @ fce88024 built for exactly this kernel), firmware in `/lib/firmware/aic8800_fw/SDIO/aic8800D80/`; autoload by SDIO alias + `/etc/modules-load.d/aic8800.conf`. DT: SMHC1 (`mmc1`), WL_REG_ON PG18 via `mmc-pwrseq-simple` (+200 ms), 32 kHz from PG10, 1.8 V I/O, 50 MHz.
1. Enumeration: `for d in /sys/bus/sdio/devices/*; do cat $d/vendor $d/device; done` -> `0xc8a1` with `0x0082` and `0x0182`. None -> power/reset/clock: `mount -t debugfs none /sys/kernel/debug; grep -E "PG18|PG10" /sys/kernel/debug/gpio /sys/kernel/debug/pinctrl/*/pinmux-pins; grep -i 32k /sys/kernel/debug/clk/clk_summary`; `dmesg | grep -i -E "mmc1|pwrseq|sdio|timeout|-110"`. Try in the DTS: `post-power-on-delay-ms = <500>`, `max-frequency = <25000000>`, remove `cap-sdio-irq`.
2. Modules: `lsmod | grep aic`; "Invalid module format"/"disagrees about version": `modinfo -F vermagic .../aic8800_fdrv.ko` must equal `uname -r` + `SMP preempt mod_unload aarch64`; a kernel upgrade needs a rebuild (not DKMS). An oops at load = struct-layout mismatch with the Armbian-patched kernel (audit M3: `struct module` layout verified identical; other structs unproven) -> rebuild with the installed kernel's real headers. A crash affects Wi-Fi only; boot is unaffected.
3. Firmware: `dmesg | grep -i -E "aicbsp|firmware|8800d80|rwnx"` - expect `matched chip: aic8800d80`, `rev id: 0x7`, files `.../aic8800D80/{fw_patch_table,fw_adid,fw_patch,fmacfw}_8800d80_u02.bin`. Missing file -> `ls -l /lib/firmware/aic8800_fw/SDIO/aic8800D80/`.
4. Interface: `ip -br link` (`wlan0`), `rfkill list`, `iw dev`, `iw reg get` (set your country), `iw dev wlan0 scan | grep -E "SSID|signal" | head`.
5. Connect: `/etc/netplan/20-wifi.yaml` (schema in `scripts/set-wifi.sh`, mode 600) then `netplan apply`; `networkctl status wlan0`; `journalctl -u wpa_supplicant@wlan0 -u systemd-networkd -b`.
6. Stability: ping for minutes; `dmesg` for SDIO timeouts; 2.4 GHz first; `iw dev wlan0 set power_save off`.
7. Failure ladder: (i) nothing enumerates -> hardware/DT; (ii) enumerates, firmware load fails -> path/files; (iii) firmware runs, no `wlan0` -> driver/kernel mismatch; (iv) `wlan0`, no scan -> regdomain/firmware variant; (v) drops -> power-save, SDIO clock. Fallback: a USB Ethernet adapter via a hub (Ethernet adapters work without firmware; **USB Wi-Fi adapters mostly do not - the image's `/lib/firmware` was pruned to the AIC set (audit L2)**). Bluetooth is not configured.

### 10.5 eMMC health / identity
```
cat /sys/class/mmc_host/mmc0/mmc0:0001/{name,manfid,life_time,pre_eol_info}        # "R821MB", 0x15, 0x01 0x01, 0x01 as under Android
mmc extcsd read /dev/mmcblk0 | grep -i -E "BOOT|PARTITION_CONFIG|EXT_CSD_REV"      # mmc-utils is in the image: record BOOT_PARTITION_ENABLE etc.
```

### 10.6 BROM dump and hash (only now; **never from the current Android**)
The H616-family BROM is mask ROM at physical **0x00000000, 64 KiB (0x10000)** (TF-A `plat/allwinner/sun50i_h616/include/sunxi_mmap.h`: `SUNXI_ROM_BASE 0`, `SUNXI_ROM_SIZE 0x10000`; U-Boot Kconfig: "some newer SoCs map the boot ROM at address 0"; SRAM A1 is at 0x20000).
```
dd if=/dev/mem of=/root/brom-dq10.bin bs=4096 count=16 skip=0 status=none     # CONFIG_DEVMEM=y in the image's kernel config
ls -l /root/brom-dq10.bin; sha256sum /root/brom-dq10.bin                       # exactly 65536 bytes
```
If the read faults or returns zeros: that path is blocked (secure-world only?), not a chip fault - use FEL later (`sunxi-fel read 0x0 0x10000 brom.bin`) if it ever works; do not retry blindly.
Published reference: **`smaeul/sunxi-blobs` commit `7cda4903df7b46eba9514094904e57cbe0272520`, `sun50iw9p1/nbrom/blob.hex`** ("dumped from running devices using md in U-Boot"), converted to binary by me: 65536 B, **sha256 `da649502bc3fc09fcbde1d50beaaddbf0e9390e0c7fcaacb86fac399a9188a1a`** (normal BROM); secure BROM `sbrom`: `4239e5e03ce3cd252c74d542a126391e5bd5cd97ff88093be207a47532130035`. Local copies: `dl-sunxi-blobs-h616-brom\{nbrom,sbrom}-sun50iw9p1.bin`.
Interpretation: equal to NBROM -> normal boot ROM, secure-boot eFuse off, consistent with `sunxi_secure normal`. Equal to SBROM -> secure boot on (unexpected). Different from both -> not proof of anything: the reference is for "sun50iw9p1" from unnamed device(s), H313/H618 steppings may differ; no H313/H618-specific dump was found; the linux-sunxi wiki (which might list more) was unreachable (Cloudflare 403). A mask ROM cannot be reprogrammed by the stick vendor; the check mainly detects an unexpected secure-boot state or memory map. Keep the dump file local (do not publish it); record only size, hash, verdict.

## 11. Things deliberately not done / left to the audit
* No `blkdiscard`/secure erase; the eMMC boot partitions are already all-zero (wipe script re-checks and zeroes if not). No EXT_CSD change (BROM uses the user area).
* Assumed toybox behaviour was verified read-only by the auditor and me: `dd` (`seek/skip/count`, `conv=notrunc,fsync`), `blockdev --flushbufs/--getsize64`, `zcat`, `pidof`, `sha256sum`, `nohup`, `lpdump`, `dmctl`; `exec-in` forwards stdin only (prints nothing) - hence the read-back hash after every write.
* `/etc/boot.cmd` probes `*0x10028` (H3-era boot-source byte); on H616 it only prints a (possibly wrong) "loaded from" message (audit L8).
