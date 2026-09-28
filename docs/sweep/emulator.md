# Sweep survey: emulator (2026-09-28, read-only)

# qemu-ios consolidation survey (ipad1 @ 821f1b5428, read-only)

Memory dirs read (both). Activation not examined.

## (a) Ranked consolidation proposals

**1. One GL shim per board, no per-build binaries: parse `__GLIFunctionDispatchRec` at guest load time.**
- What: both shims are already generated from one pair of generators (`contrib/ipad1-gles/glitsv.py` derives a build's slot table from its shared cache; `gligen.py --tsv` emits `gli_fwd.h` for glishim *and* mbxshim: `contrib/it-gles/build.sh:27-38`). What remains per build is a compiled `GLEngine-<BUILD>`/`MBXGLEngine-<BUILD>` per layout (`contrib/ipad1-gles/{GLEngine-7B500,GLEngine-8C148}`, `contrib/it-gles/MBXGLEngine-{7E18,8C148}`) and `mkpkg.py:52-66` FAMILIES hard-wiring builds to hooks. The slot list is the ObjC @encode string inside OpenGLES in the same process (`glitsv.py:29-31`), so the shim can read it with `dlsym`/objc metadata at load and build `gli_slot313[]` itself (`mbxshim.c:1551-1563` already remaps per layout from a static table).
- Evidence of duplication: `docs/ipod/gli-dispatch-8C148.tsv` and `docs/ipad1/gli-dispatch-8C148.tsv` are identical in slot/field columns (diff = 0 lines, 845 each).
- Benefit: a new point release (7B405, 8C148-era iPod, iOS 5) needs no shim rebuild, no TSV, no FAMILIES edit; `gli_abi_problem` (`imgtools/ipad1_rootfs.py:199`) becomes a sanity check, not a selector.
- Risk: medium (guest-side ObjC metadata parsing on 3.x dyld). Effort 2-3 days. Test: `tests/ipod/regress.py --checks gles`, `tests/ipad1/gltest.py`, `contrib/ipad1-gles/test_glishim.c`.

**2. One hypercall dispatcher.** `hw/arm/guest-services.c:54-192` (iPod, switch with `IPOD_TOUCH_MACHINE` casts) and `hw/arm/ipad1.c:144-178` (iPad: gles/ping, then `guest_pb_call`/`guest_pkg_call` fall-through) do the same job; the cp15 register is declared twice (`ipad1.c:172-178`, `ipod_touch_2g.c:871`). Handlers are already shared (`guest-gles.c`, `guest-pasteboard.c`, `guest-package.c`). Make `guest_services_call(cs, &q, hooks)` with optional `agent` and `kbd` hooks; the iPad passes NULL. Saves ~120 LOC, low risk, 0.5 day. Test: iPod `regress --checks agent,gles`, iPad `boot-smoke --guest-package`.

**3. Shared "app-facing machine" helper for the duplicated glue.** Identical by design ("same property names as the iPod machine", `ipad1.c:102,1538`):
- battery/accel/pose property getters+validation: `ipad1.c:1234-1402` vs `ipod_touch_2g.c:1580-1820` (~170 lines each);
- power-off gesture state machine (home, hold, settle, drag knob, watch): `ipad1.c:354-470` vs `ipod_touch_2g.c:2435-2600` (~150 lines each; differs only by knob table `ipad1.c:376-383` vs `PWROFF_KNOB_Y`);
- host Cmd-chords: `ipad1.c:472-540` vs `ipod_touch_2g.c:2283-2430`;
- QMP multitouch two-phase handler: `ipad1.c:294-342` vs `ipod_touch_lcd_mtt_event` (comment at `ipad1.c:295-297` admits the copy);
- string-property boilerplate: `ipad1.c:1080-1208` (10 identical get/set pairs).
One `hw/arm/it_board.c` taking `{touch(px,py,down), button(pin,down), panel w/h, knob table}` callbacks. Saves ~450 LOC across the two files; risk medium (persist check needs the clean power-off). 2 days. Test: both `persist` checks + `tests/ipod/test_ui_buttons.py`, `test_attitude_qmp.py`.

**4. Split the A4 I2C slaves out of `s5l8930_i2c.c` (1001 lines).** It holds the controller plus D1815 PMU, TCA6408, TSL2581, AK8973 (`s5l8930_i2c.c:28,226,541-544,704,816`). The iPod keeps each slave in its own file (`ipod_touch_lis302dl.c`, `_cs42l58.c`, `_cd3272_mikey.c`) which is exactly why the iPad could reuse them (`ipad1.c:702,724,741`). D1815/TCA6408/AK8973 recur on iPhone 4 / iPod 4G. Zero LOC saved, pure mobility; 0.5 day; risk nil (mechanical). Test: `tests/ipad1/regress.py --checks boot`.

**5. I2S: one model with a data-source hook.** `s5l8930_i2s.c:5-8` states it is the same register block as `ipod_touch_i2s.c`; offsets agree (ENABLE 0x00, TXCON 0x04, TXCOM 0x08, TXFIFO 0x10, RXCOM 0x34, RXFIFO 0x38: `ipod_touch_i2s.h:37-45` vs `s5l8930_i2s.c:40-45`). Difference is who feeds the FIFO: PL080 MMIO pushes (iPod) vs CDMA paced pull via `s5l8930_cdma_set_source` (`s5l8930.h`). Merge as `apple.i2s` with a `paced` property. Saves ~250 of 348 LOC; risk medium (audio pacing, see emulator-change-traps). 1.5 days. Test: iPod `audio`, `tests/ipad1/audio-check.py`, `snapshot-check.py` audio leg.

**6. Delete the built-in GID KBAG table.** `ipod_touch_aes.c:52-383` is ~330 lines of per-build hex (5F138/7E18); `gid-blobs=` (`ipod_touch_aes.c:385-420`) already supplies the same from the manifest and `ipod2g_device.py` writes `gid-blobs.bin`. The A4 has only the property (`ipad1.c:880`). Delete after the nand-current swap (old images rely on the table). 0.5 day; test: `tests/ipod/test_aes.py`, `fresh-device.sh` both boards.

**7. Keybag one-shot: one module, two boot strategies.** `ipod2g_keybag.py:28-29` imports `DONE, ramdisk_with_helper` from `ipad1_keybag.py`; the 297-line residual diff is the iPod's gdbstub ramdisk injection (iBoot only loads signed img3). Move the shared part to `imgtools/keybag.py`, put `keybag_boot()` in each board module, call it from `device.py create` (ipad1_device.py docstring still says the 4.x keybag "uses an explicit direct-ramdisk boot"). 1 day. Test: `tests/ipad1/test_gid.py`, an 8C148 `fresh-device.sh` per board.

**8. SHA-1 and ChipID: small merges.** SHA-1 engines share CONFIG/RESET 0x0/0x4, HASH 0x20, block buffer 0x40 (`ipod_touch_sha1.h:15-25` vs `s5l8930_sha1.c:32-37`); A4 adds a CDMA FIFO at 0xA0 and drops the IRQ, S5L8720 adds memory mode 0x80-0x8c. One model with `fifo`/`memory-mode` flags saves ~150 LOC. ChipID is a 100-line device on the iPod (`ipod_touch_chipid.c`, env-gated `IT_DEV_MODE`) and an inline ROM in `ipad1.c:617-637` with `die-id`/`development-fuses` properties: one `apple.chipid` with `words` + `development-fuses` saves ~80 LOC and gives the iPod the property. Low risk, 1 day total.

**9. Kill the `set_spi_base()` global.** `ipad1.c:964-1003`: the shared SPI controller picks NOR vs multitouch from a process global index. Make it a qdev property (`peripheral=nor|multitouch|none`). 0.5 day, low risk.

**10. Move the iBoot-literal tricks into a board-agnostic `it_iboot.c`.** `ipod_touch_2g.c:1228-1299` (find the restore string, redirect the empty-boot-args literal, Thumb `ldr` check) and `ipod_touch_firmware.c:90-128` (`gBootArgs.commandLine` printf literal) are pure pattern matches over any iBoot image; the iPad's real-iBoot path (`ipad1.c:204-214`) has nothing equivalent. Also share `ipod_touch_stage_boot_image` (`ipod_touch_2g.c:926`). 1 day.

Already shared, no work needed (keep as the pattern): MIPI-DSI, PKE, USB PHY+OTG with hwcfg table, SPI/NOR/`nor-rw`, multitouch with `mt_profile_k48`, scaler with IOMMU hook, SWI, AMC with `buf-base`, CS42L58/CD3272/LIS302DL with `whoami`/`mount-flipped`, SDIO card as `BCMSDIOChip` profile, guest-package/pasteboard, `gles-host.c`. Truly different IP, keep separate: GPIO+SYSIC vs GPIOIC, Samsung shift-register I2C vs FIFO I2C, timer/wdt/clock vs PMGR, PL080 vs CDMA, PCF50633 vs D1815, CLCD/MBX vs DisplayPipe/DART, FMSS vs IOP/H2FMI. The two NAND stores are two formats with two overlay implementations (`ipod_touch_fmss.c:239-340` per-page files; `s5l8930_iop.c:174-283` mmap + dirty bitmap): not worth unifying now.

## (b) Per-build / per-address items, with a runtime-discovery proposal

Ranked by how much each blocks a new firmware:
1. **GLI dispatch layout per build** (TSVs, `GLEngine-<BUILD>`, `mkpkg.py:52-66`) → runtime @encode parse in the shim (proposal 1). Blocks every point release today.
2. **`mkpkg.py` FAMILIES keyed on exact build strings** → key on (board, iOS major) and let hooks be chosen by what the image actually contains (the way `gli_engine` already matches the cache). 0.5 day.
3. **iOS-4 gld plugin** (`contrib/ipad1-gles/gldshim.c`, 79 names read from the firmware at build time, "fails closed") — already discovered by symbol; nothing to change.
4. **IOP HLE v1/v2** — runtime-detected by a firmware string (`s5l8930_iop.c:140,831-838`) and `FW_CONFIG_MAGIC` scan (`:846-851`). Good; nothing to change.
5. **Kernel banner table** `ipod_touch_firmware.c:7-15` — `it_firmware_loaded/by_build/detect_kernel` have no callers outside `tests/ipod/test_firmware_profiles.py`; only `find_iboot_command_line` is live (`ipod_touch_fmss.c:982`). Delete the table and `IT_KERNEL_SCAN_*`.
6. **GID KBAG hex in C** (`ipod_touch_aes.c:52-383`) → manifest via `gid-blobs` (proposal 6).
7. **Boot-args delivery on the iPod**: DRAM signature scan + timer knobs (`ipod_touch_2g.c:1081-1226`, driven by `IT_BOOT_ARGS*` env, `tests/ipod/regress.py:290-295`) and the iBoot literal redirect. Both are runtime discovery already; the residual per-build item is the comment's offsets. Move to `it_iboot.c` and make the machine property the only input (drop env).
8. **Power-off knob coordinates** per orientation (`ipad1.c:376-383`, iPod `PWROFF_KNOB_Y`/`IT_PWROFF_KNOB_Y`): UI geometry that a new iOS may move. Runtime option: locate the slider track in the framebuffer (bright horizontal/vertical band) before dragging. Until then keep, but put the table in the board helper (proposal 3).
9. **Test/tool defaults keyed to 7B500**: `tests/ipad1/boot-smoke.py:45-50` MARKERS (`iBoot-817.29`), `FILES`/`GOLDEN` paths; `tests/ipad1/regress.py:60-61` `USB_ALERT_DISMISS` vs `_4`; `imgtools/ipad1_rootfs.py:88,100` BASES/GLI_TSV. Read build from `device.lock.json` (both fresh-device scripts already do) and derive markers from the IPSW's iBoot version.
10. **`fb-base 0x4f700000`** (`ipad1.c:772`): iBoot's logo framebuffer for pre-kernel scanout. Readable from the boot-args `video` struct the kboot bundle writes (`ipad1_kboot.py`) or from the DT; low priority (only affects logo before the kernel programs the pipe).
11. **`ipod2g_device.py:148-201` `major >= 3` derivations** are from Restore.plist at build time: acceptable manifest logic, not addresses.
12. **115 distinct `IT_*` env names in hw/** (35 `getenv` in `ipod_touch_2g.c` alone, `:224-860` are env-alias pairs); the iPad machine has one (`IT_USB_TCP`). Remove once `tests/ipod/regress.py:270-300` and LightTouchMac pass properties.

## (c) Target layout

```
hw/arm/
  apple/          soc-neutral shared: it_board.c (props, pwroff, chords, mtt), it_iboot.c,
                  guest-services.c, guest-gles.c, guest-package.c, guest-pasteboard.c,
                  gles-host*.c, ipod-agent.c -> it-agent.c
  s5l8720/        clock, timer, wdt, sysic, gpio, fmss, lcd, mbx, tvout, aes, pl080 glue, pcf50633
  s5l8930/        pmgr, gpio, cdma, iop, h2fmi, display, hdq, i2c + one file per slave (d1815, tca6408, tsl2581, ak8973), ltc4099, dmc
  shared/         ipod_touch_* models both boards instantiate, renamed apple_*: mipi_dsi, pke, usb_otg, usb_phys,
                  spi, nor_spi, multitouch, scaler, swi, amc, i2s (merged), sha1 (merged), chipid (merged),
                  sdio (card), cs42l58, cd3272_mikey, lis302dl, bt
  board/          ipod_touch_2g.c, ipad1.c (instantiation + DT-specific wiring only)
contrib/
  guest/          one build.sh with GUEST_ARCH=armv6|armv7: it_prefs, it_pbd, it_ethlink, it_seal, it_keybag,
                  it_boot, it_agent, it_typein, it_msmquiet, it_gltest, it_cctest, it_heading
  gles/           mbxshim.c (core), glishim.c, gldshim.c, gligen.py, glitsv.py, tests; output GLEngine/MBXGLEngine per board
  guest-package/, appsync/, armv6-toolchain/, it-harness/, it-webproxy/, macos-app/ (dylib only)
docs/
  gli/            gli-dispatch-<BUILD>.tsv once per build (the two 8C148 copies are identical), until proposal 1 removes them
  ipod/, ipad1/   board notes
imgtools/
  device.py, fw.py (from ipad1_fw), kboot.py/identity.py (from ipad1_kboot: synth_identity, udid, DeviceTree),
  rootfs.py (from ipad1_rootfs: extract_rootfs, gli_*, PAC, activation_hook), keybag.py, boards/{k48ap,n72ap}.py
  (evidence the "ipad1_" modules are already shared: ipod2g_device.py:47,104,116,189,224,268,295,316; ipod2g_keybag.py:28-29)
tests/
  lib/            itqmp (panel W/H from a board table instead of tests/ipad1/regress.py:56 monkeypatching 320x480 to 1024x768),
                  Procs, Result, free_port, sha256, png
  boards/         n72.py, k48.py: boot flags, markers, unlock gesture, alert coords
  checks/         boot, afc, usbmux, persist, wifi, net, audio, gles, fsck, agent (each parameterised by board; today duplicated
                  ipod:585/1461/711/1261 vs ipad1:270/282/376/399)
  regress.py --board n72|k48 ; fresh-device.sh --board (the two scripts share ~50 lines of lock/offer logic)
  unit/           the 100+ host-side test_*.py (C-snippet tests of models)
  drivers/        iPad capture tools (tearcheck, respcheck, animfps, gl-drive, snapshot-check, boot-smoke) as opt-in checks
```

## (d) Dead or superseded

- `contrib/ipad1-hidbridge/` — one commit (6195ffab76); only an opt-in `--hidbridge` in `imgtools/ipad1_rootfs.py:33,210,657-673` and "fallback" in `docs/ipad1/usb-keyboard.md:160`. USB keyboard over CCK is merged. Delete dir and flag.
- `contrib/it-ssh-terminal.sh` — needs sshd; the iPod image ships "no shell, sshd or third-party binary" (`imgtools/ipod2g_device.py` docstring). Only referenced by `contrib/macos-app/build-app.sh:313`, last touched 2026-08-05 ("TCG experiments, dead end"); the live piece of that dir is `make-dylib-macos.sh` (2026-09-28). Delete the script and `build-app.sh`/`stage-and-run.sh`.
- `contrib/it-kbd-agent/` — superseded by `contrib/it-agent/it_typein.c`; `imgtools/bake-guest-tools.sh:101-102` strips its dylib from `DYLD_INSERT_LIBRARIES`. Delete the dir. Note: `QC_POLL/PEEK_INPUT` (0x130/0x131) are still used by `it_typein.c:175,181,241`, so the opcodes stay.
- `hw/arm/ipod_touch_firmware.c:7-75` banner table and `IT_KERNEL_SCAN_*`: no callers except its unit test (see (b)5).
- `imgtools/patch_springboard.py`, `patch_codesign_gate.py`, `patch_libmis.py`: obsolete byte patches per `docs/ipod/backport-from-ipad1.md:63`; only `README-appsync.md:57` mentions the last two. `patch_gpt.py` imports `ftlmap` from a hard-coded worktree path (same doc, line 62).
- `contrib/ipad1-gles/GLEngine` — untracked stale binary (`git status`: `?? contrib/ipad1-gles/GLEngine`); the build now emits `GLEngine-<BUILD>`.
- `contrib/ipad1-hw/` — HW-1 iBEC probe kit, referenced only from `docs/ipad1/PLAN.md:45-47`; move under `docs/ipad1/research/` or delete.
- `docs/ipod/gli-dispatch-8C148.tsv` duplicates `docs/ipad1/gli-dispatch-8C148.tsv` byte-for-byte in slot/field columns.
- Not dead, contrary to the brief: `hw/arm/ipod_touch_tethered.c` is instantiated behind `IT_TETHERED` (`ipod_touch_2g.c:3271-3277`) for the AppleTetheredDevice demo card; make it a property, keep it.

## Notes on the two questions asked directly

- GL host is one renderer, one wire protocol (3.1.3 slot numbers as wire ids, `glishim.c:15-18`; engine ops `GLES_OP_*` in `gles.h:303-351`; batching `GLES_OP_BATCH` iPad-only in practice, declined for the iPod at 48→49 fps). Board-keyed spots in `gles-host.c`: `#include "hw/arm/ipod_touch_2g.h"` (:34), `GLES_FB_WIDTH/HEIGHT 320x480` default drawable (:159-160, :920-922), and two `IPodTouchMachineState` casts reading `lcd_state->w1_framebuffer_base` for direct-panel present and the frame-compare debug path (:2822, :2940). Replace with a `gles_host_set_panel()` registration from each machine; ~40 lines.
- The iPad's no-agent policy (`docs/ipad1/guest-services.md`) still holds: guest-package reports go over `QC_PKG_REPORT`, already dispatched on ipad1 (`ipad1.c:164`); `it_prefs` is a one-shot launchd job through CFPreferences (`it_prefs.c:1-28`); the proxy and location are network paths through slirp `10.0.2.100:3128` (`it_prefs.c:14-15`). Nothing on the iPad needs `QC_AG_*`; proposal 2 keeps the agent an optional hook so a 4.x/5.x need (app launch without DDI) can attach it without an ABI change.

### Critical Files for Implementation
- /Users/shg/Developer/qemu-ios-ipad1/hw/arm/ipad1.c
- /Users/shg/Developer/qemu-ios-ipad1/hw/arm/ipod_touch_2g.c
- /Users/shg/Developer/qemu-ios-ipad1/hw/arm/guest-services.c
- /Users/shg/Developer/qemu-ios-ipad1/contrib/it-gles/mbxshim.c
- /Users/shg/Developer/qemu-ios-ipad1/contrib/guest-package/mkpkg.py