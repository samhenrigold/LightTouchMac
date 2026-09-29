# Fidelity ledger

What in the two emulated boards is a real hardware model, what is a high-level stand-in, what only
works because the guest is patched, and what is a stub. Kept honest so a new iOS build's failures can
be named by component and class, and so the fix that raises the class (H→R, P→R) is preferred over
another special case.

> **Audit caveat (2026-09-29, docs/test-audit-2026-09-29.md).** Five class claims made in today's
> smoke.md "Closed" list assert R without citing a hardware contract; the honest class is:
> - **I2S "stopped" bit (smoke #4)** — H, not R: the bit's meaning is inferred from the driver's spin loop; STATUS says "no datasheet".
> - **CDMA inline AES (smoke #3)** — H: the fix removed AES on writes to match ledger #34's mmap store; the device-FIFO inline-AES path is now dead code, not a modelled block.
> - **H2FMI transfer rule (FPart stall)** — fitted to two drivers' write sequences, not a datasheet contract; R-by-fit.
> - **RGBOUT swap (smoke #27)** — the swap-complete path is modelled, but ledger row 27 (RGBOUT) stays S: nothing is scanned out.
> - **ADC mux 6 cable read (smoke #35)** — the read path is disassembly-backed R, but the 0 V value and `usb_host`-follows-`usb_cable` are inferred, narrower than "the charger contract".
> Raising any of these to true R needs a datasheet or a silicon trace; until then they are declared here, not hidden.


Sam, 2026-09-28: "iOS 4.3 and iOS 5 will give us a good idea of what parts are brittle, what parts
mean that we should make a more faithful emulator because we were just getting along by happenstance
rather than by making a good emulator. A major version update forces us to have all of these
confrontations. If we had a perfect emulator, then it would be able to just boot up any version of iOS
that we want."

Sources: qemu-ios `ipad1` @ `082b45e77d` (paths below are relative to that tree), LightTouchMac
`multidevice` @ `0a5a0cf`. Written 2026-09-28 from a read of every model file; the iOS 5 spike that
tested it is qemu-ios `docs/ipad1/ios5.md` (branch `ios5-spike`). Activation is Sam's and is not
described here.

## Classes

| Class | Meaning |
|---|---|
| **R** | Register-level model. The guest's own firmware or driver runs unmodified against it (the DWC OTG core, SPI/NOR, PL192 VICs, the PMGR event timers). |
| **H** | High-level emulation. Replaces a firmware or protocol the real hardware would run: the IOP's ARM7 firmware is answered in C, the Wi-Fi dongle firmware is never executed, the touch controller's downloaded firmware is dropped and the protocol answered from tables. Works for the driver versions it was written against. |
| **P** | Needs a guest patch, shim, injected component, boot-arg or pipeline edit of the firmware. No real device has it. |
| **S** | Stub. Fixed values, writes ignored, or a RAM window where a device should be. |

A row with two classes (R/S) is a register-level model whose data is synthetic; it is counted under
the lower class in the summary.

## Summary

| Board | R | H | P | S | rows |
|---|---|---|---|---|---|
| K48 iPad 1 | 26 | 8 | 6 | 20 | 60 |
| N72 iPod touch 2G | 20 | 6 | 8 | 22 | 56 |
| Guest side (both boards: boot-args, injected components, image edits, synthesised state) | 0 | 0 | 42 | 0 | 42 |

The distance to "boots any iOS unchanged" is the H and P rows. The two that decided it were the IOP
(every NAND and SDIO byte went through a C reimplementation of one specific firmware's mailbox ABI;
since 2026-09-29 Apple's firmware runs on a modelled second core, the default) and the GPU (there is
none; GL exists only because the guest's GLEngine is replaced by a shim), which is now the first stop
of iOS 5 (5.1.1 reaches SpringBoard on the IOP core and never draws). The
iOS 5 spike hit exactly those, in that order (`docs/ipad1/ios5.md`).

## K48 (iPad 1, S5L8930 "A4")

Machine: `hw/arm/ipad1.c`. Boot paths: `bootrom=` (real SecureROM → LLB → iBoot; R with
`gid-blobs=` and `development-fuses` for unpersonalised images), `iboot=` (a pattern-patched iBoot,
P), `kboot=` (direct kernel with a synthesised boot_args/DeviceTree, P). The default prepared device
uses `iboot=`.

| # | Component | Model, key lines | Class | Why | Faithful version, cost |
|---|---|---|---|---|---|
| 1 | Cortex-A8 | `ipad1.c:595-602` (stock QEMU TCG) | R | Guest code runs unmodified. | – |
| 2 | DRAM 256 MiB @0x40000000, SRAM 256 KiB @0x84000000 | `ipad1.c:604-618` | R | Plain RAM. | – |
| 3 | DRAM mirror @0x50000000 | `ipad1.c:607-615` | R (unverified) | The alias iBoot links against (0x5ff00000). "Not yet confirmed on hardware"; the 0xC0000000 alias is not mapped. | Probe on the unit, 0.5 d |
| 4 | SecureROM @0 + alias @0xbf000000 | `ipad1.c:626-646` | R | The real 64 KiB ROM dump executes (`docs/ipad1/iboot.md`). | – |
| 5 | ChipID / fuses @0xbf500000 | `ipad1.c:648-674` | S | Fixed words {0x31800387, 0x80758000, die-id}; `development-fuses` clears bits 0 and 7. | Fuse block from a dump, 0.5 d |
| 6 | CPU debug @0xbf701000 | `ipad1.c:676-679` | S | A RAM page. | 1-2 d, little value |
| 7 | VIC ×4 (PL192, daisy-chained) | `ipad1.c:681-697`, `hw/intc/pl192.c` | R | Register-level. | – |
| 8 | DMC @0xbf800000 | `hw/arm/s5l8930_dmc.c:30-41` | S | "Immediate DLL calibration": writes set lock plus a fixed delay; everything else reads back. | Training state machine, 1-2 d |
| 9 | PMGR PLLs, clock config, gates, POWER_ID | `hw/arm/s5l8930_pmgr.c:84-146, 258-267, 316-351` | S | "Nothing here decodes clock frequencies." Reconstructed values, lock/busy bits faked, gates settle instantly and gate nothing. Only the I2S NCO (+0x104) feeds anything. | A clock tree that derives timer/UART/I2S rates and gates peripherals, 5-8 d |
| 10 | PMGR 24 MHz timebase + 2 event timers | `s5l8930_pmgr.c:158-211, 239-253, 290-304` | R | Counts down in virtual time with the kernel's FIQ ack protocol. | – |
| 11 | Watchdog (PMGR +0x2020) | `s5l8930_pmgr.c:213-226` | S | Never counts; only the "reset now" pattern fires. iOS 5 adds a `wdt` node (`wdt-version 1`) at this address. | Ticking timer with expiry, 0.5 d |
| 12 | GPIO + interrupt controller @0xbfa00000 | `hw/arm/s5l8930_gpio.c:1-16` | R | 176 pin configs, group mask/status, IRQ 0x74. | – |
| 13 | Buttons | `ipad1.c:381-389, 509-577, 1517-1546` | R | Host keys drive GPIO port 0 levels and PMU wake events. | – |
| 14 | I2C0 / I2C2 | `hw/arm/s5l8930_i2c.c:26-160` | R | FIFO block driven by the stock kext; a transfer completes inside the command write. I2C1 absent. | – |
| 15 | D1815 PMU (i2c0 0x74) | `s5l8930_i2c.c:224-480` | H | Register file with events and IRQ, but hibernate keeps the AP running, ADC mux 4 (battery) and mux 6 (brick ID: the dock's selected USB data line, 0 V with the cable in as a host's pull-downs hold it; AppleD1815PMUPowerSource's cable classifier on 4.2.1, 4.3.x and 5.x, smoke #35) are real, the others 0x800, RTC is host time, an OOC write shuts QEMU down, the restart command (0x7b = 0x0b, AppleD1815PMU vtable +0x358 on 4.2.1 and 4.3.5) resets the machine; the rest of 0x7b (0x0f/0x0e from +0x354) is stored. | Power-down/resume through the ROM, all ADC channels, regulator effects, 5-10 d |
| 16 | TCA6408 GPIO expander (i2c0 0x20) | `s5l8930_i2c.c:529-690` | R | Datasheet registers and INT; no input pins wired. | – |
| 17 | LTC4099 charger (i2c0 0x09) | `hw/arm/s5l8930_ltc4099.c:41-80` | S | STAT synthesised from `usb-cable`; writes stored, never acted on. | Charge state machine, 0.5-1 d |
| 18 | CS42L61 codec (i2c0 0x4a) | `ipad1.c:732-739`, `hw/arm/ipod_touch_cs42l58.c` | S | The iPod's CS42L58 register file stands in; the kext never checks the chip ID; MCLK (PWM block) unmodelled. | CS42L61 map, 1-2 d |
| 19 | AK8973 magnetometer (i2c0 0x1e) | `s5l8930_i2c.c:798-990` | R | Register-level; field from the host heading and pose. | – |
| 20 | CD3282 Mikey (i2c0 0x39) | `hw/arm/ipod_touch_cd3272_mikey.c:16-38` | S | Every register reads 0 ("nothing plugged in"). | Headset detection, 1-2 d |
| 21 | LIS331DLH accelerometer (i2c2 0x19) | `hw/arm/ipod_touch_lis302dl.c:30-40, 243, 382` | R | LIS302DL model with `whoami=0x32`; 4.x's BOOT-bit poll fixed 2026-09-28. INT pins not driven. | – |
| 22 | TSL2581 light sensor (i2c2 0x39) | `s5l8930_i2c.c:693-763` | S | One fixed indoor reading; no interrupts. | Host lux + IRQ, 0.5 d |
| 23 | bq27545 gas gauge over HDQ (UART5) | `hw/arm/s5l8930_hdq.c:136-196` | R/S | The bit-banged HDQ protocol runs unmodified; the data is synthetic (linear voltage, ±300 mA). | Discharge model, 1-2 d |
| 24 | DisplayPipe0 @0x89000000 | `hw/arm/s5l8930_display.c:395-523, 602-650` | H | Parameter-FIFO register file; only UI0/UI1 scanned out, source-over only, nearest scaling, ARGB8888/4444/RGB565, layer rectangles honoured; no video layers, blend modes, gamma, dither; VBL is a fixed 60 Hz timer. | All layers and modes, timing-driven VBL/underrun, 5-10 d |
| 25 | CLCD timing generator @0x89200000 | `s5l8930_display.c:217-238, 618-635` | S | Register file whose reset seeds iBoot's "k48" timing (needed by 4.x's `start_hardware`); IRQ 0x29 never raised. | Derive refresh from timing, 1-2 d |
| 26 | DART1 @0x88d00000 (ISP/JPEG/VENC), DART2 @0x89d00000 (display) | `s5l8930_dart.c` (one register block, dart2 embedded in the display) | S | STE read/write only; never busy; no fault IRQ. dart1 has no modelled client (smoke #29). | Full DART, 1-2 d |
| 27 | RGBOUT, RGBOUT2, TV-out | `s5l8930_display.c` (`pipe_frame_end`, `ram_ops`) | S | Second pipe: register file plus swap completion and its own VBL/swap-done interrupt (0x2b) on the shared 60 Hz tick (smoke #27: 4.3's power-off waits on it), never scanned out; RGBOUT2/TV-out RAM blocks with a "clock-down ready" bit. | Second scanout + SDO, 3-5 d |
| 28 | MIPI-DSIM + Pinot panel @0x89500000 | `hw/arm/ipod_touch_mipi_dsi.c:27-155` | H | DSIM registers with direct-boot handshake shortcuts; the panel answers only DCS B1 with a constant; DSI IRQ unwired. | Panel state machine, 1-2 d |
| 29 | M2 scaler/CSC @0x89300000 | `hw/arm/ipod_touch_scaler.c:63-210` | H | RGB32 nearest-neighbour only; its NV12 path rejects iPad DRAM addresses (`:130-134`). | Polyphase, all formats, through DART, 4-7 d |
| 30 | SWI (backlight, core voltage) @0xbf600000 | `hw/arm/ipod_touch_swi.c` | S | RAM; busy bit self-clears; backlight level ignored. | Dimming on the console, 0.5-1 d |
| 31 | SDHC @0x80000000 | `hw/arm/s5l8930_sdio.c` | R | SDHCI 2.0 host under the IOP firmware's sdiodrv: self-clearing software reset, internal-clock-stable, block size/count, argument, transfer mode, command (issued by its index byte), responses, present state, normal/error status with status and signal enables, caps/version; CMD53 data through the buffer data port the firmware's CDMA channel streams (read: in the FIFO when the command completes; write: collected, then to the card). No SDMA/ADMA (the firmware uses neither), no command/data timeouts. With `iop-core=off` ring-3 commands are still run in C (H). | Timeouts/error bits, 0.5 d |
| 32 | BCM4329 Wi-Fi card | `ipad1.c:829-876`, `hw/arm/ipod_touch_sdio.c:128-178, 228-244, 501-679` | H | The firmware the driver downloads is stored and never executed; DEVREADY/FWREADY announced on a CORECTL write; CDC/BDC ioctls answered in C (BSS_INFO, RSSI −45, `ver` = "4.218.175.43"); a fake open BSS "qemu-ios" auto-joined; only the 802.3 frames are real. | Dongle SoC (Cortex-M3, backplane, D11 MAC/PHY) running the downloaded firmware, 60-120 d; practically infeasible |
| 33 | IOP (the A4's ARM7 coprocessor) | `hw/arm/s5l8930_iop_core.c`, `s5l8930_iop.c` (control block) | R | The firmware the kernel uploads (iBoot-817, iBoot-931, EmbeddedIOP-20.4, -33.4 seen) runs unmodified on an arm946 second core (default `iop-core=on`): address 0 = the image, DRAM at 0xc0000000, the AP's peripherals at their addresses, its own four PL192s with every board interrupt split to them, PMGR event timer 1 as its tick; system reset and snapshots cover it. Eight cp15 overrides stand in for what QEMU's arm946 lacks (ID/thread regs, a ninth MPU region, CPACR, v6 WFI). `iop-core=off` keeps the v1/v2 HLE (iOS 3.2-4.2 firmware only; the v3 instrument is deleted). | cp15 by the ARM7TDMI-S/946 TRM rather than overrides, 1 d |
| 34 | NAND page store | `s5l8930_iop.c` (store), `s5l8930_h2fmi.c` (chips) | H | mmap'd sparse store + dirty-bitmap overlay, programmed and erased through the H2FMI; pages are plaintext: the CDMA's inline AES and per-page IVs on the NAND FIFO channels are skipped both ways (a real device holds ciphertext). | Keep the store, apply the NAND AES both ways (key + IV descriptors) with an encrypted store format, 1-2 d + pipeline |
| 35 | H2FMI0/1 @0x81200000 | `hw/arm/s5l8930_h2fmi.c` | R | Register-level read, program (0x80/0x10, cache 0x81/0x11) and erase (0x60/0xd0) for iBoot and the IOP firmware: per-CE page latches, a transfer starts on entering read mode or raising bit 7, FIFOs paced for the CDMA (O(1) pops), a page write waits for its data and meta, each write FIFO completes its own chain on drain, ECC results per sector (clean or blank; no bit errors), migrated. A full stock restore (`restore-smoke --erase`) passes through it. | ECC error injection for FTL error paths, 1 d |
| 36 | CDMA @0x87000000 | `hw/arm/s5l8930_cdma.c` | R | Descriptor engine driven by the stock AppleCDMA, iBoot and the IOP firmware; +0x10/+0x14 read back the enabled channels (the three drivers' enable helpers and AppleCDMA-300.8's CSR check); device-FIFO channels paced by the H2FMI and completed when it drains them; AES on memory-to-memory pairs, skipped on device FIFOs (row 34); I2S paced; UART RX channels park. | Timing + UART RX hook, 2-3 d |
| 37 | AES filter (custom keys) | `s5l8930_cdma.c:273-279` | R | Real AES-CBC with the guest's key. | – |
| 38 | AES UID key | `s5l8930_cdma.c:171-176, 294-298` | S | "A fixed made-up value". | Impossible (fused) |
| 39 | AES GID key | `s5l8930_cdma.c:178-193`, `ipad1.c:916-918` | S/P | Pre-decrypted KBAGs from `gid-blobs=` (from the public key page); a miss falls back to the UID stand-in. | Impossible (fused); the table is the honest substitute |
| 40 | SHA-1 @0x80100000 | `hw/arm/s5l8930_sha1.c` | R | Compression engine, CDMA FIFO and PIO. | – |
| 41 | PKE (RSA) @0x83100000 | `hw/arm/ipod_touch_pke.c:8-28, 109, 230` | R | Genuine Montgomery math; `forge-sigcheck` never set on ipad1. | – |
| 42 | I2S0-2 @0x84500400 | `hw/arm/s5l8930_i2s.c`, `ipad1.c:1056-1068` | R | i2s0 TX/RX to host audio at the NCO rate; i2s1/i2s2 drop data (S). | – |
| 43 | AMC @0x84100000 | `hw/arm/ipod_touch_amc.c:29-35, 1335` | S | Register file whose interrupts report pending as soon as enabled; no decode; aux window unimplemented. | AMC DSP programs (undocumented) 30+ d; porting the iPod's decode HLE 5 d |
| 44 | USB PHY @0x86000000 | `hw/arm/ipod_touch_usb_phys.c:11-60` | S | Register file. | Charger detect, 0.5-1 d |
| 45 | DWC OTG device @0x86100000 | `ipad1.c:941-976`, `hw/arm/ipod_touch_usb_otg.c` | R | Synopsys core driven by the stock AppleSynopsysOTGDevice; 4.x's NAK-clear and ZLP behaviour added 2026-09-28. | – |
| 46 | OTG "wire" (TCP to usbmuxd-qemu) | `hw/arm/ipod_touch_tcp_usb.c`, `ipod_touch_usb_otg.c:143-180, 1143-1190` | H | The USB bus is a TCP packet protocol; without a bridge a scripted host enumerates and sends the 500/1600 mA charge request. | usbredir/usbip export, 3-5 d |
| 47 | EHCI + OHCI0 host @0x86400000 | `ipad1.c:977-997`, stock `exynos4210-ehci`, `sysbus-ohci` | R (+P gate) | Stock QEMU controllers, but published only because the pipeline adds `hsic-enabled` to the DT and `enable-hsic=1` to boot-args; USB_CTL 0xbf108000 unimplemented. | Model USB_CTL and cable-type mode switching, 2-4 d (4.3+ changed the gate to `publish-criteria`) |
| 48 | USB keyboard (`usb-kbd,max-power=20`) | `hw/usb/dev-hid.c:46-49, 725-733` | R | Stock HID with a lower bMaxPower so 4.x's 50 mA CCK budget accepts it. | – |
| 49 | SPI0 + NOR (1 MiB, `nor=`/`nor-rw=`) | `ipad1.c:999-1018`, `hw/arm/ipod_touch_nor_spi.c` | R | Controller + JEDEC flash; program/erase instant; peripheral chosen through the `set_spi_base()` global (`ipod_touch_spi.c:302-354`). | Busy latency, 0.5 d |
| 50 | SPI1 + Zephyr2 multitouch | `ipad1.c:1020-1030`, `hw/arm/ipod_touch_multitouch.c:109-215, 288-310, 453-509, 601-815` | H | The ~48 KB firmware download is checksummed and discarded; report-info and controls come from `mt_profile_k48`; touch frames are built in C; register writes not processed; reset/download GPIOs ignored. | Touch MCU running the downloaded firmware + a capacitive front-end, 30-60 d (undocumented) |
| 51 | SPI2 baseband controller | `ipad1.c:1032-1040` | R | Empty bus, as on the Wi-Fi unit. | – |
| 52 | UART0/1/2/4 | `ipad1.c:1085-1096`, `hw/char/exynos4210_uart.c` | R | Exynos UART patched for the S5L interrupt scheme. | – |
| 53 | UART3 Bluetooth | `ipad1.c:1107-1109`, `imgtools/ipad1_rootfs.py:238-242, 771` | S + P | NULL chardev; BTServer is set `Disabled` at bake (Settings shows Bluetooth "Unavailable"). | HCI port of `ipod_touch_bt.c` (H) 3-5 d; running BCM patchram (R) infeasible |
| 54 | SGX535 GPU @0x85100000 | nothing in `ipad1.c`; `imgtools/ipad1_kboot.py:304-307` sets `sgx` compatible=none (kboot only) | P (absent) | **There is no GPU model.** On the kboot path the driver is unmatched; on the iBoot path the stock node stays and IMGSGX535 hits the unimplemented window. | PowerVR SGX535 (USSE cores, TA/ISP/TSP, microcode) running the guest's kext: 120+ d, undocumented; the one row that would delete rows 55, 59-61 and most boot-args. **First milestone, separable: the SGX MMU** (page-directory base register + the kext's page tables, walked by the host). The kext already builds those tables for every surface; walking them could give the GL bridge each CA surface's physical pages with no CPU mapping (surfaces measured 09-29 as scattered 4 KiB pages, no DART, no carveout). Caveat (docs/research/sgx535-feasibility.md): the kext maps into the GPU tables from its GL-context paths, which our shim bypasses, so the walk may find no CA surfaces while the shim is in place; phase 1 must check whether IOSurface creation alone maps them |
| 55 | GLES host bridge | `hw/arm/gles-host.c`, `hw/arm/guest-gles.c`, `ipad1.c:140-214` (cp15 hypercall) | P | The guest's GLEngine is replaced by a shim that traps `QC_GLES` to a host CGL/EAGL context; ES 2.0 partial; plus the `GLRendererFloatQEMU` gld plugin on 4.x. | Replaced by row 54 |
| 56 | cp15 hypercall register | `ipad1.c:140-214`, `include/hw/arm/guest-services/general.h` | P | A made-up coprocessor register (op1=3, c15,c15,0) only guest shims use. | None (not hardware) |
| 57 | TCG `it-hle` hooks | `target/arm/tcg/it-hle.c`, `target/arm/tcg/translate.c:7828-7834` | P (inert) | memcpy/memset replacement at fixed iPod 3.1.3 addresses; off unless `IT_HLE`. | Delete, 0 d |
| 58 | Guest pasteboard, packages, agent | `hw/arm/guest-pasteboard.c`, `hw/arm/guest-package.c`, `ipad1.c:175-203` | P | Reachable only through guest-installed daemons over the hypercall. | Stock USB services (lockdown/AFC) for what they cover; the pasteboard has no R form |
| 59 | Rootfs bake shims | `imgtools/ipad1_rootfs.py` (see the guest-side table) | P | Guest edits the pipeline makes. | See guest-side table |
| 60 | Unimplemented window | `ipad1.c:620-624` | S | One `create_unimplemented_device` over 0x80000000-0xBFFFFFFF: SGX, PWM 0x83500000 (codec MCLK), AMC aux, USB_CTL 0xbf108000, CE-ATA, I2C1, SPI3/4, UART6 all read 0. | Per block, above |

## N72 (iPod touch 2G, S5L8720)

Machine: `hw/arm/ipod_touch_2g.c`. Boot paths: SecureROM (default; the boot ROM runs LLB from NOR
and iBoot, and FMSS NAND reads patch iBoot in RAM, P), `direct-iboot=`/`direct-llb=` (decrypted
images staged in RAM, P). 35 `getenv()` calls (32 `IT_*` names) in the machine file alone.

| # | Component | Model, key lines | Class | Why | Faithful version, cost |
|---|---|---|---|---|---|
| 1 | ARM1176 | `ipod_touch_2g.c:883-904` | R | Stock QEMU core. | – |
| 2 | cp15 REG0/REG1 overrides | `ipod_touch_2g.c:33-41, 872-875` | S | Cache ops store and do nothing. | 0.5 d |
| 3 | cp15 hypercall | `ipod_touch_2g.c:43-60, 876`, `hw/arm/guest-services.c:54-192` | P | Used only by injected guest binaries. | None |
| 4 | cp15 HOST_GMT_SECONDS | `ipod_touch_2g.c:860-880` | P | Host `time()` for old research kernels; stock builds use the PMU RTC. | Delete, 0 d |
| 5 | RAM windows (vrom, insecure 48 M, secure, fb, iboot, llb, sram1) | `ipod_touch_2g.c:1366-1392` | R | Plain RAM; llb/sram1 overlap at equal priority. | MIU model, 2-3 d |
| 6 | EdgeIC @0x38E02000 | `ipod_touch_2g.c:1381` | S | 4 KB of RAM. | 1-2 d |
| 7 | VIC0/1 (PL192) | `ipod_touch_2g.c:2934-2952` | R | Register-level. | – |
| 8 | Timer | `hw/arm/ipod_touch_timer.c:4-25, 125-150` | R/S | Timer 4 + 64-bit tick counter real; timers A-D write-only; 6 vs 10 MHz mismatch kept; time-dilation knob. | All timers at rate, 2-3 d |
| 9 | Clock0/1 | `hw/arm/ipod_touch_clock.c` | S | Register file, PLLs always locked, no frequency derivation. | 2-4 d |
| 10 | SYSIC (power + GPIO IC) | `hw/arm/ipod_touch_sysic.c:52-70, 110-200` | R/S/P | GPIO IC real; ONCTRL drops some bits; epoch 4 synthesised for direct boot. | Power-domain machine, 2-3 d |
| 11 | GPIO | `hw/arm/ipod_touch_gpio.c:20-60, 97-130` | R/S | Only FSEL out-lo/hi modelled. | 2 d |
| 12 | WDT | `hw/arm/ipod_touch_wdt.c:17-64` | S | One exact command resets; no timed expiry. | 1 d |
| 13 | UART0-3 | `ipod_touch_2g.c:3017-3042` | R | Exynos UART; UART4 never created. | 0.5 d |
| 14 | Bluetooth HCI (BCM4325 BT on UART1) | `hw/arm/ipod_touch_bt.c:93-170, 242-287` | H | Command Complete from tables; no ACL/SCO; fake 0xfc2e banner for BlueTool. | BT core running patchram, 30-60 d |
| 15 | PL080 DMAC0/1 | `ipod_touch_2g.c:3151-3238` | R | Stock PL080 with paced request lines. | – |
| 16 | SPI0-4 | `hw/arm/ipod_touch_spi.c:124-260` | R | FIFO/IRQ model. | – |
| 17 | NOR (SPI0) | `hw/arm/ipod_touch_nor_spi.c:236-349` | R | JEDEC flash, program/erase, `nor-rw` overlay. | – |
| 18 | NOR NVRAM boot-args rewrite | `ipod_touch_nor_spi.c:27-72, 108-110` | P | The host rewrites the "common" CHRP partition when `boot-args=` is set. | None |
| 19 | Zephyr2 multitouch (SPI4) | `hw/arm/ipod_touch_multitouch.c:109-215, 288-310, 480-545, 638-800` | H | Firmware download discarded; tables answer the protocol; frames from the host pointer. | Touch MCU + front-end, 40-80 d |
| 20 | ChipID | `hw/arm/ipod_touch_chipid.c:9-54` | S | 0x8720 + security bits; `IT_DEV_MODE` changes them. | 0.5 d |
| 21 | TV-out | `hw/arm/ipod_touch_tvout.c:14-51, 61-220` | S | Handshake registers + paced vblank; no output. | 5-10 d |
| 22 | unknown1 @0x3D700000 | `hw/arm/ipod_touch_unknown1.c:20-28` | S | Two fixed words. | Identify it, 1-3 d |
| 23 | MPVD (MPEG-4 decoder) | `hw/arm/ipod_touch_mpvd.c:19-32, 190-325` | S (default) / H (`mpvd-decode`) | Register file; opt-in rebuilds the stream and decodes with VideoToolbox. | Job model + in-tree decoder, 15-30 d |
| 24 | H.264 (M2H264) | `hw/arm/ipod_touch_h264.c:248-760` | S (default) / H (`h264-decode`) | RAM window; opt-in synthesises SPS/PPS/slices for VideoToolbox/libavcodec. | Macroblock pipeline, 30-60 d |
| 25 | DWC OTG | `hw/arm/ipod_touch_usb_otg.c` | R | Register-level, S5L8720 HWCFG. | – |
| 26 | USB-over-TCP transport | `hw/arm/ipod_touch_tcp_usb.c` | R (transport) | Host side only. | – |
| 27 | USB PHY | `hw/arm/ipod_touch_usb_phys.c:24-60` | S | Register file. | 1 d |
| 28 | I2C0/1 | `hw/i2c/ipod_touch_i2c.c:35-64, 185-330` | R | Samsung IIC; NAKs absent addresses. | – |
| 29 | PMU (D1759, "pcf50633") | `hw/arm/ipod_touch_pcf50633_pmu.c:54-175, 218-300, 353-404` | R/S | Register file; RTC = host time; synthetic battery ADC; shutdown stops the host. | Full map with charger, 5-10 d |
| 30 | LIS302DL | `hw/arm/ipod_touch_lis302dl.c:153-246` | R | Register-level; host attitude; no INT/click. | 2 d |
| 31 | Tethered demo card (`IT_TETHERED`) | `hw/arm/ipod_touch_tethered.c` | S | Returns 0x82. | None (not retail) |
| 32 | CS42L58 codec | `hw/arm/ipod_touch_cs42l58.c:5-43, 61-111` | R/S | MAP register file; LRCLK from reg 05; no ADC/mic. | Capture path, 3-5 d |
| 33 | LM48821 amp | `hw/arm/ipod_touch_lm48821.c` | R | Datasheet control word. | – |
| 34 | I2S0 | `hw/arm/ipod_touch_i2s.c`, `ipod_touch_2g.c:3285-3322` | R | DMA-paced FIFO to host audio at the codec's LRCLK. | – |
| 35 | ISL29003 ALS | `hw/arm/ipod_touch_isl29003dl.c:25-82` | S | Fixed value. | 1 d |
| 36 | CD3272 Mikey | `hw/arm/ipod_touch_cd3272_mikey.c:14-41` | S | Reads 0. | 2-3 d |
| 37 | AMC | `hw/arm/ipod_touch_amc.c:1-119, 361-525` | S (registers) / H (`decode`) | Default reports enabled IRQs pending; decode mode is AAC/MP3/ALAC HLE via libavcodec. | AMC DSP running the guest's DE programs, 60-120 d |
| 38 | FMSS sequencer | `hw/arm/ipod_touch_fmss.c:96-223` | R (partial) | Executes the guest's sequencer programs, but only the opcodes READ ID and reset need; others stop the run. | With row 39 |
| 39 | FMSS page I/O | `ipod_touch_fmss.c:1058-1288, 1340-1418` | H | 0xD38 + csgenrc 0xa01/0xa02 decoded in C from descriptors; erase inferred from writes; no ECC. | Execute read/write/erase programs against an FMC + NAND model, 10-15 d |
| 40 | FMSS store / overlay | `ipod_touch_fmss.c:360-909` | R (backend) | ITNAND01 mmap or directory; copy-on-write overlay. | – |
| 41 | FMSS generated-image FTL compatibility | `ipod_touch_fmss.c:687-824, 1244-1276` | P | Moves writes to their logical home and rewrites the FTL free pool when cs3 page 255 is read (`FMSS_PHYSICAL` off). | Image builder emitting real VFL/FTL metadata, 5-10 d |
| 42 | FMSS iBoot RAM patches | `ipod_touch_fmss.c` (NAND-read hook), `hw/arm/it_iboot.c` (pattern-found boot-args literal) | P | On NAND reads the Bluetooth DT node is renamed uart3→uart1 and a hard-coded boot-args string is written into `gBootArgs.commandLine`. | Root-cause the DT difference, 1-2 d |
| 43 | MIPI-DSI + panel | `hw/arm/ipod_touch_mipi_dsi.c:27-40, 50-100` | H | Canned panel-ID reply; handshake bits only in direct boot. | DSIM + panel, 3-5 d |
| 44 | LCD/CLCD | `hw/arm/ipod_touch_lcd.c:136-258, 377-540` | R (partial) | Window-1 registers kept but scanout fixed 320×480 x8r8g8b8; `lcd-planes` adds BGRA + NV12 planes. | Depth/stride/formats/blending, 5-10 d |
| 45 | Scaler/CSC | `ipod_touch_2g.c:3398-3406`, `hw/arm/ipod_touch_scaler.c` | S (default) | `create_unimplemented_device`; opt-in NV12→RGB only. | 5-8 d |
| 46 | SHA-1 | `hw/arm/ipod_touch_sha1.c` | R | DMA hash engine. | – |
| 47 | AES | `hw/arm/ipod_touch_aes.c:52-383, 385-431, 593-709` | R (custom) / S (GID, UID) / P (preserve) | GID = a built-in KBAG→key table for 5F138/7E18 plus `gid-blobs`; UID constant; an address-specific "preserve" hack for three in-place ops. | Fused keys impossible; the table is the substitute |
| 48 | PKE | `hw/arm/ipod_touch_pke.c` | R | Real RSA; `forge-sigcheck` off by default. | – |
| 49 | MBX register block (PowerVR MBX Lite) | `hw/arm/ipod_touch_mbx.c` | S | **The GPU is absent.** Fixed ID words, idle status; the interrupt block (mask read-back, status set by the driver's software interrupt, write-1-to-clear, the line) is register-level since `gles-1x`; `IT_MBX_COMPLETE` fakes completions. The 1G uses the same model (it was an id stub). | MBX TA/ISP/TSP with an undocumented command format, 120-250 d |
| 50 | OpenGL ES path | `contrib/it-gles/mbxshim.c`, `gles2x.c`, `hw/arm/gles-host.c` | P | 3.x/4.x: MBXGLEngine.bundle replaced by a shim forwarding every dispatch slot to host GL (3.0, no shared cache and 2.x's dyld: the same source legacy-linked, `MBXGLEngine-30`, guest package `n72-ios30`; qemu-ios `gles-30`). 1.x/2.x: `OpenGLES.framework/OpenGLES` (the IMG MBX driver itself) replaced by `gles2x.c`, the same core under the firmware's 218 export names (guest package `n72-ios2`); SpringBoard composites through it with CA_ENABLE_OGL=1 (2.1.1: software-CA frame rates, about a quarter less host CPU on the launch zoom). 1.x (the 1G, 3A101a): the same file built without EAGL under 1.x's 186 names (`OpenGLES-1x`, guest package `n45-ios1`), LayerKit with LK_ENABLE_OGL=1 (software frame rates, a quarter less host CPU on the launch zoom). | Row 49 |
| 51 | SWI | `hw/arm/ipod_touch_swi.c` | S | RAM; busy bit self-clears. | 1 d |
| 52 | SDIO host controller | `hw/arm/ipod_touch_sdio.c:45-121, 983-1080` | R | CMD5/52/53, CCCR/FBR/CIS. | – |
| 53 | BCM4325 Wi-Fi dongle | `ipod_touch_sdio.c:127-178, 296-440, 540-680` | H | Firmware stored, never run; CDC/BDC in C; fake BSS; off by default. | 60-120 d, infeasible |
| 54 | Host input automation (keys→buttons, on-screen keyboard taps, power-off slide) | `ipod_touch_2g.c:2020-2145, 2435-2650` | H | Host synthesises GPIO/touch events. | None |
| 55 | Guest services (agent, keyboard, pasteboard, package) | `hw/arm/guest-services.c:98-183`, `hw/arm/ipod-agent.c` | P | Injected daemons/dylibs over the hypercall. | USB lockdown/AFC tooling for what it covers, 10-20 d |
| 56 | TCG `it-hle` | `target/arm/tcg/it-hle.c` | P (inert) | Opt-in memcpy hoist at fixed 7E18 addresses. | Delete, 0 d |

## Guest side: patches, shims, boot-args, synthesised state (both boards)

Everything here is class P. "Replaces" says what a real device has instead.

### Boot-args

| Arg | Where | Replaces / bypasses | Faithful alternative, cost |
|---|---|---|---|
| `amfi_allow_any_signature=1` | K48: `imgtools/ipad1_kboot.py:63` (kboot) and `ipad1_iboot.py:77` (iBoot32Patcher `-b`); N72: `tests/ipod/regress.py:292,355`, `hw/arm/ipod_touch_2g.c:1051-1226` (late DRAM write), `ipod_touch_fmss.c:968` (SecureROM boot string) | AMFI's rejection of ad-hoc (ldid) signatures: every injected helper, shim and dylib is ad-hoc signed. | Nothing injected (needs the GPU model and stock services); otherwise permanent |
| `cs_enforcement_disable=1` | same places | Kernel code-signing enforcement, for the same binaries and for `DYLD_INSERT` hooks. | Same |
| `debug=0x8`, `serial=3` | same | Diagnostic: kprintf on UART0. A production iBoot boots with neither. | Drop once serial is not needed; 0 d |
| `enable-hsic=1` + DT `arm-io/usb-complex/hsic-enabled` | `ipad1_kboot.py:350-351`, `imgtools/ipad1_gid.py:53-88` (NOR DT) | 4.2.1's `AppleS5L8930XUSBArbitrator` publishes the host nubs (USB keyboard) only with both. Apple's own knob, but not a shipping configuration. 4.3+ removed both (`publish-criteria` in the DT instead). | USB_CTL + cable-type model, 2-4 d (K48 row 47) |
| `rd=md0` | `ipad1_kboot.py` ramdisk mode, `imgtools/ipod2g_keybag.py:34` | Restore boot for the keybag one-shot: the IPSW's own restore ramdisk as SecureRoot. Faithful restore-boot state, used once. | Stock USB restore instead (exists: `tests/ipad1/restore-smoke.py`), 1-2 d to make it the pipeline |
| `-v`, `rd=disk0s1`, `kextlog`, `io=`, `pmu-debug`, `debug-usb` | `ipod_touch_fmss.c:968-969` | Hard-coded verbose boot string the FMSS writes into iBoot for the SecureROM path. | Boot-args as a machine property only; 0.5 d |
| iBoot32Patcher `--rsa --debug -b` | `ipad1_iboot.py:70-91` | `--rsa`: image signature / personalisation check (unpersonalised stock images boot); `--debug`: `debug-enabled` so boot-args are honoured; `-b`: the boot-args above. | Unpatched iBoot needs Apple-personalised images (SHSH/APTicket); impossible offline. The bootrom path with `development-fuses` and the IPSW's development certificates is the honest R-adjacent form |
| `nand-enable-reformat=1`, `amfi_get_out_of_my_way=1` | not used any more | Historical (kernel self-format; DYLD-insert into installd). | – |

### Guest components and image edits

| Item | Board | Applied where | Replaces / bypasses | Faithful alternative, cost |
|---|---|---|---|---|
| `GLEngine-<BUILD>` (glishim) | K48 | `contrib/ipad1-gles/build.sh`, `imgtools/ipad1_rootfs.py:106-119, 630-638`; per-build `docs/ipad1/gli-dispatch-<BUILD>.tsv` from `glitsv.py` | Apple's GLEngine (the SGX driver's GL front end); the slot table is derived per build from the shared cache's `__GLIFunctionDispatchRec` @encode. | GPU model (K48 row 54). Runtime @encode parse in the shim removes the per-build table, 2-3 d |
| `GLRendererFloatQEMU.bundle` (gldshim) | K48 4.x | `contrib/ipad1-gles/gldshim.c`, `ipad1_rootfs.py:633-638` | The `IMGSGX535GLDriver` gld plugin libGFXShared needs for EAGL sharegroups. | GPU model |
| dyld `enable-dylibs-to-override-cache` | K48 4.x/5.x | `ipad1_rootfs.py:117, 157-165` | Lets a file on disk override the cached GLEngine (Apple's own switch). | GPU model |
| `MBXGLEngine-<BUILD>` (mbxshim) | N72 | `contrib/it-gles/build.sh`, `contrib/guest-package/mkpkg.py:52-66` | Apple's MBXGLEngine. | N72 row 49 |
| SpringBoard env `CA_ENABLE_OGL=0`/`GLI_ACCELERATED=1`, `MBX2D_PAGE_FLIP=0`, stdio to `/dev/console` | K48 | `ipad1_rootfs.py:610, 694` | CoreAnimation's compositor choice; SpringBoard stderr on serial. | GPU model; console line is diagnostic |
| AppSync (shared-cache patch of `MISValidateSignature` + installd `DYLD_INSERT` dylib) | both | `imgtools/appsync_cachepatch.py`, `contrib/appsync`, `ipad1_rootfs.py:211-215, 675` | App Store signature checks in amfid/installd/SpringBoard, so decrypted IPAs install and launch. | None that keeps unsigned IPAs; a signing identity would be Apple's |
| Guest-package loader `it_boot` + seed package | both | `contrib/guest-package/mkpkg.py`, `ipad1_rootfs.py` bake, `imgtools/bake-guest-tools.sh` | Delivers the helpers below at boot (versioned, rollback) instead of baking each. `FAMILIES` keyed on exact build strings (`mkpkg.py:52-66`). | Key on (board, major); 0.5 d |
| `it_agent` (+ `it_typein` on N72) | both | `contrib/it-agent` | Foreground app, lock state, launch/sync, typing: services the stock device offers only through Apple tooling. | usbmux/lockdown/DDI for what they cover, 10-20 d |
| `it_pbd` / pasteboard | both | `contrib/it-agent`, `hw/arm/guest-pasteboard.c` | Host↔guest clipboard (no real analogue). | None |
| `it_ethlink` | K48 | `contrib/it-ethlink` | Sets USB Ethernet `LinkStatus=1` through IOKit (replaced the deleted `--usb-eth-link` kernel patch). | Model the link in the OTG/Ethernet function, 1 d |
| `it_prefs` (one-shot CFPreferences) | K48 | `contrib/it-prefs` | Web-proxy PAC, location defaults. | Stock DHCP/WPAD, 1 d |
| `it_msmquiet.dylib` (mounter hook) | K48 | `mkpkg.py IPAD_HOOKS`, `ipad1_rootfs.py:230-231, 769` | Hides the "USB device not supported" alert (Apple bug that blocks screen lock; Sam approved). | None wanted |
| `it_seal` | both | `ipad1_rootfs.py:243-244` | One-shot clean `reboot(RB_HALT)` at prepare so the FTL context is flushed. | Stock restore, or a guest power-off gesture, 0.5 d |
| `it_keybag` as `restored_external` on the IPSW's restore ramdisk | K48 4.x/5.x | `imgtools/ipad1_keybag.py`, `contrib/it-keybag` | The data-protection steps `restored` does (format effaceable, `MKBKeyBagCreateSystem`), using the stock symbols. | Stock USB restore, 1-2 d |
| BTServer `Disabled` | K48 | `ipad1_rootfs.py:238-242, 771` | Bluetooth (no controller model; BTServer's retries stalled SpringBoard). | HCI model, K48 row 53 |
| fstab rw root, `/dev/disk0s2` data | K48 | `ipad1_rootfs.py:24-26` | Insurance for a failed data mount (stock is `ro`). | `--ro-root` exists; 0 d |
| USB Ethernet DHCP service, AirPort service + PAC | K48 | `ipad1_rootfs.py:37-41, 320-351` | Network preferences a first boot would create itself. | Let the guest configure, 0.5 d |
| `/var` owners patched offline, data volume seeded | K48 | `ipad1_rootfs.py:42-45, 499, 732` | What `mobile_obliterator` / restore does on-device. | Stock restore |
| Kernelcache img3 installed on the system volume | K48 | `ipad1_rootfs.py build --kernelcache` | What restore writes. | Stock restore |
| iPod image edits (`ipod2g_device.py`, `nand-current`) | N72 | `imgtools/ipod2g_device.py` | Guest tools baked; major≥3 derivations from Restore.plist. | Stock restore (no USB restore path exists for N72 yet) |
| App catalog per-build fields | both | `LightTouchMac/Resources/firmware-catalog.json` (`recipe.options`, `gli_dispatch`) | – | `gli_dispatch` goes with the runtime @encode parse |

### Synthesised device state

| Item | Where | What it stands in for | Faithful alternative, cost |
|---|---|---|---|
| NOR: NVRAM banks, SysCfg, all_flash images, patched iBoot | `imgtools/ipad1_iboot.py`, `imgtools/build_nor.py` | What a factory/restore writes. | Stock restore writes NOR (`restore-smoke.py --erase` did on 7B500), 1-2 d |
| NAND: offline FTL/VFL writer ("restore + power cut before the CXT flush", first boot does a R/O restore) | `imgtools/ipad1_nand.py`, `imgtools/ipod2g_nand.py` | The on-flash state `restored`/asr leave. Bets on the FTL format (YaFTL 3.x/4.x; iOS 5 adds LwVM). | Stock restore, 1-2 d; then no format knowledge in the pipeline |
| `gid-blobs.bin` (KBAG→key from the public key page) | `imgtools/ipad1_gid.py` | The fused GID key. | Impossible; this is the honest substitute |
| Synthetic identity (serial, ECID, die-id, MACs) | `imgtools/ipad1_kboot.py synth_identity` | SysCfg of a real unit. | – (must stay synthetic) |
| kboot DeviceTree fill (`chosen/*`, clocks, NAND geometry on `disk` and, for iBoot-1219's 5.x layout, on flash-controller0 with `ce-bitmap`, `display-rotation 270`, `lcd-panel-id`, baseband unmatched, `sgx` off) | `ipad1_kboot.py:284-331` | What iBoot writes into the DT before handoff. | The iBoot path already does most of it (default); kboot stays a debug path |

### Per-build assumptions still in the emulator and pipeline

From the consolidation survey (`docs/sweep/emulator.md` (b)), with the iOS 5 spike's verdict:

1. GLI dispatch layout per build (`gli-dispatch-<BUILD>.tsv`, `GLEngine-<BUILD>`, `mkpkg.py` FAMILIES). Confirmed by 9B206: 905 slots vs 841, derivable by `glitsv.py`, but a new shim build per release.
2. `mkpkg.py` FAMILIES keyed on exact build strings. 9B206 matches no family.
3. iOS-4 gld plugin: discovered by symbol; unchanged.
4. ~~IOP HLE v1/v2 by firmware string + `cnfg` scan.~~ The IOP core runs whatever firmware the kernel uploads (2026-09-29, default); the v1/v2 HLE is left behind `iop-core=off` for iOS 3.2-4.2 only.
5. Kernel banner table `ipod_touch_firmware.c`: deleted (D6, 2026-09-29).
6. GID KBAG hex in C (`ipod_touch_aes.c:52-383`): delete after the nand-current swap.
7. iPod boot-args delivery (DRAM scan, literal redirect, `IT_BOOT_ARGS*`).
8. Power-off knob coordinates per orientation (`ipad1.c:376-383`, iPod `PWROFF_KNOB_Y`).
9. Test/tool defaults keyed to 7B500 (`boot-smoke.py` markers name `iBoot-817.29`, `AppleS5L8920XARM7M`, `AppleS5L8920XIOPFMI`; 4.3+ renamed the kexts to `AppleARM7M`/`AppleIOPFMI`).
10. `fb-base 0x4f700000` (iBoot's logo framebuffer).
11. `ipod2g_device.py` major≥3 derivations (manifest logic, acceptable).
12. 115 `IT_*` env names in hw/ (one on the iPad).

## Ranked: what to make faithful, and what it buys

| # | Item | Class today | Cost | What it removes |
|---|---|---|---|---|
| 1 | ~~Run the IOP firmware (second ARM7 core, real mailbox/VIC/timer, H2FMI program/erase/ECC, SDHCI under it)~~ done 2026-09-29 (qemu-ios `iop-core`, `iop-core-2`; default on) | R | – | The v1/v2/vN ABI bets on every NAND and SDIO byte; 4.3.5 and 5.1.1 need no IOP table |
| 2 | NAND and NOR from a stock USB restore instead of the offline writers | P (pipeline) | 1-2 d (path exists; `restore-smoke --erase` passes on the IOP core too) | All FTL/VFL/LwVM format knowledge; the keybag one-shot; the img3 kernelcache install; the `it_seal` boot |
| 3 | GLI shim reads the dispatch @encode at load | P | 2-3 d | Per-build TSVs, `GLEngine-<BUILD>`, `gli_dispatch` in the catalog, FAMILIES by build |
| 4 | USB_CTL + cable-type host/device switching | R+P | 2-4 d | `enable-hsic`, the DT edit; matches 4.3+'s `publish-criteria` gate |
| 5 | PMGR clock tree | S | 5-8 d | The reconstructed table; 4.3+ reads new pmgr props (`voltage-states0`, performance domains) |
| 6 | Display pipe: all layers/modes, CLCD-derived VBL | H/S | 5-10 d + 1-2 d | The UI0/UI1-only assumption (4.x already needed the rectangle fix) |
| 7 | D1815 PMU | H | 5-10 d | Sleep/resume shortcuts |
| 8 | Delete inert code (`it-hle`, `HOST_GMT_SECONDS`, banner table, `IT_*` env) | P/S | 0-1 d | Confusion |
| 9 | BCM4329/4325 protocol coverage per driver generation (still H) | H | 2-5 d per driver | AppleBCMWLAN 2.60 vs AppleBCMWLANCore (5.x: firmware from `/usr/share/firmware/wifi/4329b1/duo.bin`, new iovars) |
| 10 | Multitouch: answer from the downloaded firmware's own tables rather than `mt_profile_k48` | H | 3-5 d | Per-board profile tables; still not R |
| 11 | SGX535 GPU (phased plan 150-330 d, low confidence: docs/research/sgx535-feasibility.md; first phase the MMU walk, K48 #54) | absent | 120+ d, undocumented | The GL shim, gld plugin, dyld override, SpringBoard env, `amfi_allow_any_signature`/`cs_enforcement_disable` (once no other injected code remains) |
| 12 | MBX Lite GPU (N72) | S | 120-250 d | Same for the iPod |

Rows 11-12 are the honest answer to "boots any iOS unchanged": without a GPU model every iOS build
needs an injected GL shim and the two AMFI boot-args, so the guest is never unmodified. Everything
above them is bounded work.

## What the iOS 5 spike said (2026-09-28)

Full evidence: qemu-ios `docs/ipad1/ios5.md` (branch `ios5-spike`). iOS 5.1.1 (9B206) and 4.3.5
(8L1) were booted on the three paths; each stop named a ledger row.

| Order met | Blocker | Row | Class | Verdict |
|---|---|---|---|---|
| 1 | kboot's boot_args.Version (4.3+ kernels demand 3) | synthesised state, kboot | P | fixed generically on the branch (read off the kernel); the R path (real iBoot) never had it |
| 2 | IOP mailbox config block v3 (EmbeddedIOP-20 in 4.3, -33 in 5.x): "IOP: startup ping failed" | K48 #33 | H | the first hard stop on **both** 4.3.5 and 5.1.1; raise to R (run the ARM7 firmware, 20-30 d) or add a third HLE table (0.5-1 d, stays H) |
| 3 | iBoot-1219/1072 security epoch 2 vs the fixed `POWER_ID` (epoch 1): "miu_init: Epoch Mismatch" reset loop | K48 #9 (PMGR/POWER_ID), boot path `iboot=` | S + P | the `iboot=` path skips LLB, which writes the epoch on hardware; the ROM path accepts LLB-1219 under development fuses and is the R answer |
| 4 | D1815 power-off/reset registers ignored (LLB-1219 and iBoot-1219 both end there) | K48 #15 | H | PMU sequencing, 5-10 d |
| 5 | I2C controller +0x14, blocks 0xbfc00000/0xbfe00000, 0x89e0/0x89f0xxxx | K48 #14, #60 | R gap / S | small, 0.5-3 d each |
| 6 | Guest package family by build; bake's on-disk GLEngine assumption; GLI table per build (905 slots) | guest side | P | the first two fixed generically; the third confirmed as per-build debt |
| – | PMGR performance-domain props, `wdt` node, CLCD/Pinot/DisplayPipe, USB PHY/EHCI (`enable-hsic` now a no-op) | K48 #9, #11, #24-28, #44-47 | S/H/R | passed at driver start on 5.1.1 |
| – | Wi-Fi driver split (AppleBCMWLANCore, firmware from a file), LwVM, data protection, GL on 5.x | K48 #32, #34, guest side | H/P | not reached; behind #33 |

So the ranking above holds: the IOP (H) is the single component that gates every 4.3+ build, and the
boot chain's own state (epoch) is the second; both are exactly "getting along by happenstance" with
the iBoot-817/931 generation.

> 2026-09-28 `iop-v3` (qemu-ios): the HLE now also speaks the EmbeddedIOP-20/33 layout (ring table at +0x10, IOP DRAM window 0xc0000000, 64-byte ring entries, FMI args +0x18): an H-class instrument to be deleted when the IOP core lands. 4.3.5 reaches VFL init (then waits on a NAND epoch notification the blank effaceable NOR never gives); 5.1.1 needs the IOP→AP message ring (endpoint activation events), which only the real firmware defines.

> 2026-09-29 `iop-core-2` (qemu-ios): with the IOP core the default, 4.3.5 boots, powers off through launchd and
> reboots; 5.1.1 (kboot) gets through the IOP ping, FTL_Open, the keybag one-shot, the seal, root mount and
> launchd to SpringBoard, which never draws (no GPU, 9B206 has no GL shim). What the spike read as "the IOP->AP
> message ring's endpoint activation" was AppleIOPFMI-49 spinning in `_fmiInitVirtToPhysMap` on an empty
> `ce-bitmap`: iBoot-1219 writes the NAND geometry to flash-controller0 itself, the kboot fill only wrote the 4.x
> `disk` node (guest side, P; fixed generically). Before that, 5.1.1 panicked 1 s in on the CDMA's +0x10 (K48 #36,
> R now). Ring 1 carries only the firmware's console ('tty ') messages. Remaining 5.x stops: GPU (absent), the
> `iboot=` path's epoch (smoke #7), halt-as-restart with USB power (smoke #28).

> 2026-09-29 `ios5-gl` (qemu-ios, not merged): 5.1.1 is created, sealed and booted on the `iboot=` chain and
> SpringBoard composites through the GL bridge (Setup Assistant, home, Spotlight, Safari; `gles-rejects` empty).
> Row 3 above: the epoch is what LLB would write, read off the staged iBoot's miu_init check for the model's fuse
> field (P path, the value as LLB computes it; smoke #7 closed). Row 4 was not the PMU at all: iBoot-1219's
> `dialog_read_adc` polls the ADC start bit, which never cleared (K48 #15, R now), and ten timeouts mean power-off.
> Also met: the Pinot panel answered the iPod's ID (K48 #28: now the K48 panel's measured bytes, R), a CDMA
> drain-during-push race behind the IOP's "dma timeout" on seal (K48 #36, R), and D1815 ADC mux 6 (the dock's
> D+/D- brick ID) read mid-scale, so 4.3.x/5.x called the cable "Detached" (R now: a host's pull-downs; smoke #35's
> cause). Per-build item 1 below is retired for GL: one GLEngine and one gld plugin serve 3.2, 4.2.1 and 5.1.1,
> libGFXShared's generation and the dispatch read at load, the 64 new fields rows 848-911 (guest side, H: the
> engine and plugin stay stand-ins, smoke #41 for what they take on trust). 5.x activation (smoke #37) and the 5.x
> guest-package family (#39) remain P.
