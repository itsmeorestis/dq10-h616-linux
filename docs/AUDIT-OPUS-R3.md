# AUDIT-OPUS-R3: DQ10 Route F (revision 3) and the post-RMR hang

Auditor: Opus, 2026-10-30. I did not touch the stick at all: no adb, no sunxi-fel, no usbipd, no writes to any block device. I did not read the private key. I checked sources read-only in WSL kali: U-Boot v2026.10 at `~/src/u-boot` and TF-A v2.15.0 at `~/src/tf-a`. I rebuilt nothing.

## Verdict

**Write: NO-GO for tonight. The package itself is GO-WITH-FIXES once the Job 2 gate (D2/D3 below) passes.**

Why NO-GO: U-Boot proper started over FEL has produced its payload **once in six runs**: one UMS success yesterday, then four UMS failures and one F3 test boot with no picture tonight. The eMMC boot runs the same TF-A + U-Boot proper code. Until we know which stage fails, a flashed eMMC could land in the one state that has no software way back: SPL accepted, then a hang. Route F also cannot get past F4 right now, and the ADB fallback is gone because Android does not come up.

---

## Job 1: re-check of the revision-3 changes

### Verified OK
* `sha256sum -c SHA256SUMS-ALL.txt` (Git Bash, package root): **69/69 OK**, no failures. The manifest covers docs, scripts, uboot, image, felbundle, overlay, dts, wifi and the downloads. It leaves out `work/`, which is fine.
* `scripts/ums-flash.sh`: there is no rev2 backup of it, so I reviewed the whole file.
  * Guards come before any write, in this order: root; `readlink -f`; whole-disk `sdX` name; sysfs `/usbN/`; exact size 15,634,268,160; exact-match mount/swap check (including partitions); `setro`; input hashes, including the decompressed rootfs; identity hash of sectors 0..73727. The default mode is a dry run.
  * The arithmetic checks out:
    * 14910 MiB = 30,535,680 sectors = the whole device.
    * The rootfs goes at `seek=2048` MiB = sector 4,194,304, and ends at 3328 MiB = `ROOT_END`.
    * The head goes in this order: 17..8191, then 0..15, then 16 last. Zeroing everything first means an interruption leaves no valid eGON image anywhere, so the BROM falls back to FEL.
  * The verify step reads from the media with `iflag=direct`, 1 MiB reads, and the exact zero-check lengths.
  * I found no path that could write the wrong device or leave vendor data in the user area. The hardware boot partitions are out of UMS reach. That is documented, and the first-boot wipe service checks them.
* SSH key-only setup:
  * the baked-in key file was byte-identical to the owner's public key file (`cmp` clean; the key is no longer part of this repository).
  * The fingerprint file matches.
  * The drop-in sets `PermitRootLogin prohibit-password`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`.
  * Sonnet's debugfs inspection (modes 0700/0600, `Include` before `PermitRootLogin yes`) is consistent with this. I did not repeat it.
* The H2/H3/MEDIUM fixes are as described in sec. 16. The SD node is in the U-Boot DT. The H3 text, `dq10-prep.sh` and `oom_score_adj` are in the fallback route.
* The wipe service is safe if someone boots the SD image: it refuses unless root is `<disk>p1` on a disk that has `boot0` partitions, i.e. the eMMC.

### Fixes required (exact)
1. **FLASH-PLAN Part 1 is stale after tonight's facts.** The text says the efex flag persists and that a plain power cycle returns to FEL. Neither is true any more: a normal power-on now runs the vendor chain (HDMI signal, black picture).
   * Replace every "power-cycle (-> FEL)" with: "unplug the stick's **power adapter**, hold the button, plug the power back in, release after ~3 s". Replugging the A-A cable does not reset the stick.
   * Places to change: Hardware fact 1 (and its consequence (a)), F1 intro, F3 "When done", F4 "If no 1f3a:1010", fact 5 step (3), the failure table rows F1/F2/F3/F4/F8/F9, and the restore text.
   * Add "remove any microSD card first": the BROM tries SD before eMMC.
2. **Make F3 (or the D2 reach-bootcmd test below) a blocker, not "information".**
   * New rule before F8: U-Boot proper over FEL must reach its bootcmd **3/3**. Proof is FEL coming back on the `reset` signal (D2), or the F3 Linux console on HDMI. The eMMC boot runs the same TF-A + U-Boot proper.
   * Change the F3 "If HDMI stays black..." paragraph and the F3 table row to match.
3. **F8 exit code is masked by `tee`.** `bash scripts/ums-flash.sh $DEV --yes-wipe-everything 2>&1 | tee log` leaves `$?` = tee's code. Append `; echo "ums-flash rc=${PIPESTATUS[0]}"` to the F8 command, and tell the operator to read that line.
4. **`ums-flash.sh` verify phase: a read error exits with a misleading code 1 and no message.**
   * Cause: after `trap - EXIT`, a failing `dd` inside `H=$(dd ...|sha256sum|cut ...)` or `R=$(...)` trips `set -e`/`pipefail`. Exit code 1 is documented as "nothing written".
   * Fix lines 119 and 121:
     ```
     H=$(dd if="$DEV" bs=1M count=4 iflag=direct status=none | sha256sum | cut -c1-64) || H=READ-ERROR
     R=$(dd if="$DEV" bs=1M skip=2048 count=1280 iflag=direct status=none | sha256sum | cut -c1-64) || R=READ-ERROR
     ```
     The `cmp <(...)` checks already fail into `bad=1`. Then re-run the loop test and regenerate `SHA256SUMS-ALL.txt`.
5. **"Nothing was written to the stick" is not proven.**
   * During the 10-29 UMS session Windows mounted a vendor FAT volume read-write as D:. That volume is almost certainly `bootloader_a` (sector 73728), and Windows routinely creates `System Volume Information`.
   * The F6 identity hash covers only sectors 0..73727, so it cannot see such a change.
   * State this in Hardware fact 4 and BUILD-NOTES. At the first working UMS session, run the restore's "verify 2" loop **read-only** against `partition-hashes.txt` and record the result. For Route F this is no brick risk, since everything gets zeroed. It does matter for the "restore = exact original" claim and for the black-screen question.
6. Restore section (minor): before `blockdev --setrw`, add the same USB-transport check the script uses:
   ```
   readlink -f /sys/block/$(basename $DEV)/device | grep -Eq '/usb[0-9]+/' || echo NOT-USB-STOP
   ```
   Size alone is a weak guard for a raw 15 GB write.
7. After any doc or script edit, regenerate `SHA256SUMS-ALL.txt`. My report file is not in it and does not need to be.

---

## Job 2: the post-RMR "nothing happens"

### What the facts and the source establish
* **RVBAR 0x08100040 is correct for this die.** U-Boot `arch/arm/mach-sunxi/Kconfig` defines `SUNXI_RVBAR_ALTERNATIVE` = 0x08100040 for H616: the second die variant, used when `SRAM_VER_REG[7:0] != 0` (H618/H313). Our own SPL's 32-bit RMR stub (`boot0.h`/`rmr_switch.S`) uses the same variant logic. It switches to AArch64 and back (`return_to_fel`) successfully on every `spl` run. sunxi-tools is git 2026-05-30 and chose the same address. **RMR/RVBAR: ruled out.**
* **TF-A v2.15 AXP313 code is harmless.** `sunxi_power.c` only reads PMIC reg 0x03 over R_I2C. For AXP313 it says "no regulators to set up". Without a DTB it skips. Very unlikely to hang.
* **The MUSB gadget does not depend on VBUS or ID.** `musb-new/sunxi.c` in peripheral mode does `ForceIdToHigh` + `ForceVbusValidToHigh`. The PHY driver routes PHY0 to MUSB when `CONFIG_USB_MUSB_SUNXI` is set, and it has the H616 PHY2-SIDDQ quirk. The A-A cable's VBUS does not matter to the gadget logic.
* **The gadget always negotiates high speed.** `musb_core.c` writes `MUSB_POWER_HSENAB` unconditionally, and `CONFIG_USB_GADGET_DUALSPEED=y`. BROM FEL is **full-speed** (fact (d), vhci speed 2). The UMS gadget uses a different, more demanding signalling mode over a non-standard A-A cable.
* **Both configs:**
  * `CONFIG_BOOTDELAY=2`, any key aborts autoboot (`abortboot_single_key`: any `tstc()` byte);
  * `CONFIG_PREBOOT="usb start"`;
  * `CONFIG_ENV_IS_IN_FAT=y`: on FEL boot this means FAT on mmc 0, i.e. the SD slot;
  * `CONFIG_EFI_LOADER` with `EFI_VARIABLE_FILE_STORE`;
  * `CMD_SAVEENV=y`;
  * no serial attached.

  The UART0 RX (PH1) has the SPL's internal pull-up.
* **Neither bootcmd writes anything.**
  * Recovery: `echo; mmc dev 1; ums 0 mmc 1`. No `saveenv`, no `mmc write`. **But `ums` exports the eMMC read-write to the host.** That is the only write path we opened, and Windows used it (D:).
  * Main + felbundle: `fel` target → `boot.scr` → `booti`. No writes. If `booti` returned, distro boot would scan mmc/usb/pxe. U-Boot persists EFI variables only to an ESP it booted from, so a write there is very unlikely.
  * Neither U-Boot (sunxi code) nor TF-A writes RTC GP registers (grep: none).
  * The SPL writes AXP313 DCDC2 = 1.0 V and DCDC3 = 1.2 V. These registers are volatile and reset when the adapter is removed (fact (c): the stick has no other power).
  * **So our RAM-only runs cannot have changed the RTC flag, the PMIC or the eMMC. The one exception is the host writes during UMS.**
* **Fact (b) means the vendor chain now runs past boot0.**
  * HDMI signal + black picture means the vendor boot0 did not "eraly jump fel": the RTC efex flag is gone. Vendor boot0 initialised DRAM, and vendor U-Boot 2018 (or the Android kernel) started the display.
  * The likely reason is ordinary RTC-domain power loss on a longer unplug. Boot0 strings show it reads `rtc[%d]` and also "Use rtc to store dram tuning para". Yesterday's quick replugs probably kept the RTC alive on capacitor charge. That is an inference, not tested.
  * A black picture with a signal points to:
    1. Android booting with a black or absent boot logo, or HDMI handed to the kernel;
    2. vendor U-Boot stuck (e.g. AVB or a partition check);
    3. Allwinner efex/FES mode. Unlikely: that would enumerate `1f3a:efe8`.
  * Check (1) with zero writes: wait 2-3 min, then ping or ARP the stick's address / check the hotspot client list. If Android is up, the ADB fallback is alive again.
  * If Windows changed `bootloader_a` (logo partition), a black logo is plausible but should not stop Android.
* **The button.** The vendor boot0 has "get adc time out!!!" and "key press". The vendor DT has an LRADC keyboard at 0x5070800. So the button may be **either** the BROM FEL pin **or** an LRADC/GPIO key read by vendor boot0/U-Boot. **I cannot call it "almost certainly BROM".**
  * The difference matters only for the hang case "SPL valid but hangs". A wiped or unbootable eMMC always gives FEL from the BROM anyway.
  * Test (D1/D1b) before flashing.
* **The key variable.** Yesterday every FEL entry, including the UMS success, went through the vendor boot0's efex jump: boot0 had already set PMIC, clocks, DRAM and eMMC. Tonight's entries were by button, possibly cold BROM FEL. Tonight both payloads failed: recovery UMS 0/4 and the main U-Boot + Linux test boot 0/1. Two different payloads failing points to a **common stage after RMR and before the payload**.

### Ranked hypotheses
1. **Autoboot never ran (BOOTDELAY=2 + any byte on UART0 RX aborts to an invisible prompt).**
   * For: it explains both payloads failing; it is intermittent by nature; SPL-only runs never read input.
   * Against: PH1 is pulled up internally. It would need noise or something wired to the pads, which is unknown on the DQ10.
   * Cost to exclude: zero. A uEnv override, no rebuild (D2).
2. **State-dependent hang in TF-A/U-Boot proper init or `mmc dev 1` after a cold/button FEL entry, versus the boot0-initialised state of yesterday's success.**
   * Examples: DCDC1/VDD-SYS left at its OTP default (U-Boot cannot set it on AXP313); eMMC never initialised; clocks.
   * This is the dangerous one: the eMMC boot runs exactly this cold path.
   * D1 + D2/D3 separate it from 1.
3. **USB physical layer for the HS gadget (UMS case only).** The full-speed BROM link is fine; HS chirp/signal integrity over the A-A cable or host port is marginal; 1/5 success.
   * Does not explain the F3 failure, but can stack with 1 or 2.
   * Windows would usually show "Unknown USB Device (Device Descriptor Request Failed)" (`usbipd list`: `0000:0002`). Check for that (D4).
4. **Windows-side state after `usbipd bind/unbind 1f3a:1010`** (UMS case only). Check PnP and the event log. Test on a native Linux host or after a Windows reboot.
5. **Linux/HDMI-only failure in F3** (DT or display), separate from the UMS failure. Possible, but it does not explain the UMS failures.
6. RVBAR/RMR, TF-A PMIC, VBUS/ID detection: **ruled out or very unlikely** (see above).

**Could the same hang hit a normal eMMC boot?**
* Hypotheses 1 and 2: **yes.** The eMMC boot also has BOOTDELAY=2 and the same TF-A + U-Boot proper. Under 1 the stick would hang at an invisible prompt; a power cycle probably fixes it. Under 2 it would hang in init: LED on, no FEL, needs SD `fel-sdboot` or a BROM-level button.
* Hypotheses 3 and 4: **no.** UMS only.

### Diagnostics, in order (all zero eMMC writes; RAM, SRAM and SoC registers only)
Before every attempt: remove the microSD; unplug the **adapter** for at least 60 s; hold the button; plug the adapter in. Then `usbipd attach` efe8 as in F1.

**D0 Observations, no tools.**
* Does the blue LED (PH6) come on during `sunxi-fel spl` (F2)? The SPL sets it on. This validates the LED as a signal.
* How exactly was "Windows sees nothing" checked?
* Was yesterday's 11:46 run entered via the efex flag (yes, per the notes)?
* Did any SD card sit in the slot?

**D1 Register probe, read-only, right after a cold button entry:**
```
sunxi-fel ver
sunxi-fel readl 0x03001010        # PLL_DDR0: bit31 set => boot0 ran before FEL (button = boot0 key), clear => pure BROM FEL
sunxi-fel readl 0x03001000        # PLL_CPUX (BROM default vs boot0-raised)
sunxi-fel hexdump 0x00020000 32   # "eGON.BT0" at +4 => the BROM loaded the vendor boot0 before FEL
for r in 0 1 2 3 4 5 6 7; do sunxi-fel readl $((0x07000100 + 4*r)); done   # RTC GP regs (efex flag / DRAM tuning cache)
```
Record the results. They tell which path the button takes and whether the efex flag is gone.

**D1b Decisive button test (writes only a microSD on the laptop).**
* Make a microSD with **only** `u-boot-sunxi-with-spl.bin` at 8 KiB: `dd of=/dev/sdX bs=1k seek=8`, using the SD reader's device. No rootfs on the card.
* Insert it, hold the button, power on.
* `1f3a:efe8` appears: the button is the BROM FEL pin, checked before any media.
* LED on and no FEL: the button is a software key in the vendor chain. Then the only rescue for a hanging SPL is an SD card with `fel-sdboot.sunxi`.
* With no rootfs on the card, U-Boot finds nothing bootable on it. Distro boot does not write.

**D2 Does U-Boot proper reach its bootcmd? (main U-Boot, no rebuild, uEnv override).**
* sunxi-fel passes a file starting with `#=uEnv` through the SPL header. U-Boot imports it in `misc_init_r()`, which runs after the env load and before autoboot.
* Create `dq10-reach.uenv` with LF line endings:
  ```
  #=uEnv
  bootdelay=-2
  preboot=
  blink=gpio clear PH6; sleep 1; gpio set PH6; sleep 1; gpio clear PH6; sleep 1; gpio set PH6
  bootcmd=run blink; mw.l 0x00100000 0xd10c0001; reset
  ```
* Run:
  ```
  sunxi-fel -v -p uboot uboot/u-boot-sunxi-with-spl.bin write 0x43100000 dq10-reach.uenv
  ```
  The `-v` output must contain `Passing boot info via sunxi SPL: script address = 0x43100000, uEnv length = N`.
* **Keep holding the button for about 20 s.** Expect 2 LED blinks, then `reset`, then `1f3a:efe8` back. Re-attach, then `sunxi-fel readl 0x00100000`: 0xd10c0001 means the marker survived, a bonus.
* Repeat 3x. Then run once **without** the `bootdelay=-2` and `preboot=` lines, for contrast.
* Reading the results:
  * 3/3 with the override but failures without it: hypothesis 1 confirmed.
  * 0/3 even with the override: hypothesis 2. Hang before bootcmd. **Flashing stays NO-GO.**
  * Back to FEL but no blinks: PH6 is not the visible LED. Use the FEL-return as the signal.

**D3 eMMC init.** Same file, with:
```
bootcmd=run blink; if mmc dev 1; then mw.l 0x00100000 0xd10c0002; mmc info; reset; else gpio clear PH6; fi
```
FEL comes back only if `mmc dev 1` worked. LED off with no FEL means eMMC init failed.

**D4 Recovery UMS with the override** (recovery binary unchanged):
```
#=uEnv
bootdelay=-2
preboot=
blink=gpio clear PH6; sleep 1; gpio set PH6; sleep 1; gpio clear PH6; sleep 1; gpio set PH6
bootcmd=run blink; if mmc dev 1; then gpio clear PH6; sleep 3; gpio set PH6; ums 0 mmc 1; fi; gpio clear PH6
```
* LED on steady after the 3 s off means `ums` is running. Then check Windows:
  ```
  Get-PnpDevice -PresentOnly | ? InstanceId -match 'VID_1F3A|VID_0000'
  usbipd list
  ```
  Also: Event Viewer > Microsoft-Windows-Kernel-PnP/Configuration.
* An "Unknown USB Device / Descriptor Request Failed" entry means the physical layer: try a short, good A-A cable, a USB 2.0 port without a dock/hub, or a native Linux laptop boot (live USB, no usbipd).
* LED off at the end means mmc or ums failed.

**D5 F3 retry with autoboot protection** (no boot.scr; the commands go straight into the uEnv; same writes of Image/dtb/initramfs as F3; drop the `write 0x4fc00000 felbundle/boot.scr`):
```
#=uEnv
bootdelay=-2
preboot=
bootcmd=gpio clear PH6; sleep 1; gpio set PH6; setenv bootargs "console=tty1 console=ttyS0,115200 loglevel=7 rdinit=/init keep_bootcon"; fdt addr 0x4fa00000; fdt resize 65536; booti 0x40080000 0x4ff00000:0x482d19 0x4fa00000
```
A blink with no HDMI afterwards means the problem is the kernel/DT/HDMI, not U-Boot.

**D6 (only if D4 shows `ums` running but nothing enumerates): force full-speed** with a diagnostic build. See builder item R5.

### Binary changes for the Sonnet builder
Recovery (`dq10_athena_p1_recovery_defconfig`). Builds only after D2; D2-D5 need none.
* R1 `CONFIG_BOOTDELAY=-2`
* R2 `# CONFIG_USE_PREBOOT is not set`
* R3 `CONFIG_ENV_IS_NOWHERE=y` and `# CONFIG_ENV_IS_IN_FAT is not set`: a deterministic env that never reads the SD or eMMC FAT. Also `# CONFIG_EFI_LOADER is not set`.
* R4 `CONFIG_BOOTCOMMAND="gpio clear PH6; sleep 1; gpio set PH6; if mmc dev 1; then gpio clear PH6; sleep 3; gpio set PH6; ums 0 mmc 1; fi; gpio clear PH6"`
* R4b Recovery DT `sun50i-h313-dq10-recovery.dts`: add `&ehci0 { status = "disabled"; }; &ohci0 { status = "disabled"; };` so PHY0 belongs to MUSB only.
* R5 (diagnostic variant `-fs`, only for D6): `# CONFIG_USB_GADGET_DUALSPEED is not set`, plus a local patch in `drivers/usb/musb-new/musb_core.c` `musb_start()` that drops `| MUSB_POWER_HSENAB`. Label it clearly as a diagnostic build.

Main (`dq10_athena_p1_defconfig`):
* M1 **Mandatory if D2 confirms hypothesis 1, recommended anyway:** `CONFIG_AUTOBOOT_KEYED=y` and `CONFIG_AUTOBOOT_STOP_STR="dq10stop"`. This keeps BOOTDELAY but noise can no longer abort, and someone with a future UART can still stop it. Then regenerate the head image, the SD image and all hashes, and re-run F2 + D2 with the new binary before F8.
* Do not change anything else in the main build until D1-D3 are done.

### Should flashing wait?
**Yes.** Flash only after all three:
1. D2 passes 3/3 on the binary that will be flashed (with M1 if needed), or D5 shows Linux on HDMI;
2. D3 passes;
3. D4 gives a working UMS disk.

D1b should also be done first, so the operator knows whether the button can rescue a hanging SPL. If it cannot, prepare a `fel-sdboot` microSD before F8.
