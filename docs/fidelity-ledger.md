# Fidelity ledger

What in the emulated boards is a real hardware model, what is a high-level stand-in, what only
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

## September 30 candidate findings

The unmerged `codex/reuse-implementation` candidates add explicit physical
`nand-xor-ff-v2` erase/program semantics and upstream QEMU BlockBackend ownership,
with stock blank erase restore and prepared-device persistence gates. This does
not upgrade generated FTL mappings or missing NAND crypto to register fidelity.
FMSS physical-page and erase maps now serialize through QEMU VMState trees; native 7E18 file/USB/clock/live graphics/audio/new HTTP resume passes. Identity, file, clock and USB snapshot gates also pass 2.1.1, 3.0 and 4.2.1. Already-open host sockets remain unqualified. N45 touch interrupt
requests obey the measured SYSIC pending/enable contract; touch firmware remains
high-level emulation, and the historical early-touch panic was not reproduced.

Read-only stock K48 sampling maps the SGX polled word to DRAM (`0x4112e018`), not
an MMIO register. The firmware producer remains undecoded and the stock cold-boot
identity gate fails; no invented completion is claimed. Current status and
acceptance boundaries are in [remaining work](remaining-work-2026-09-30.md).

## October 1 candidate findings

QEMU candidate `7eadb42b54` removes the direct-iBoot empty-root literal redirect.
It skipped stock iBoot's factory root properties and produced a different UDID.
Stock 7E18 now publishes its generated serial; identity, full music tags and
stock-decoded artwork pass import and cold reopen. Early kernel UART also passes
with bounded fast handoff discovery followed by the normal refresh cadence.
A fresh 8C148 prepared device completes its host-owned keybag one-shot, then
passes factory USB identity and early BSD mount logging with the current emulator.
The BCM HCI stand-in now stores BlueTool’s provisioned address and returns it
through ReadBDADDR, including across HCI reset and actual VMState restoration.
Three UART1 production-board qtests and a native 7E18 stack probe pass; the
observed programmed address matches the fixture’s generated MAC. The controller
is still H, with no radio/link transport or patchram execution.
The earlier ReadBDADDR-only change did not retire the UART-path rewrite.
Candidate `cbf1000344` completes combo-chip OTP identity and physical presence
independent of host networking, removing that rewrite. All four native
firmware lifecycle gates pass without modifying iBoot bytes or literals.

QEMU `69db528b32` also provisions the BCM4325 CIS Wi-Fi address and Apple's
combo-card Bluetooth OTP record from the generated unit. The 2.x driver otherwise
overwrites Bluetooth with a fallback derived from Wi-Fi. Stock 5F138 now matches
serial, UDID and both MACs with Wi-Fi enabled, reaches agent-confirmed Home and
powers off through its stock gesture. Three production SDIO qtests and all eight
native 7E18 default regressions pass. This improves factory identity; the radio
and downloaded firmware remain H. See QEMU `docs/research/n72-radio-identity.md`.

The N72 root clock now derives a peripheral output and PLL lock status from
registers, with production board snapshot restoration tests. Peripheral consumers
are not connected to it yet, clock gates are partial, and timed watchdog expiry
still lacks the S5L8720 counter/divider contract. These do not become R by passing
boot tests. See QEMU `docs/ipod/clock-n72.md` and
`docs/research/ipod-identity-handoff.md` for the precise evidence.

## Classes

| Class | Meaning |
|---|---|
| **R** | Register-level model. The guest's own firmware or driver runs unmodified against it (the DWC OTG core, SPI/NOR, PL192 VICs, the PMGR event timers). |
| **H** | High-level emulation. Replaces a firmware or protocol the real hardware would run: the IOP's ARM7 firmware is answered in C, the Wi-Fi dongle firmware is never executed, the touch controller's downloaded firmware is dropped and the protocol answered from tables. Works for the driver versions it was written against. |
| **P** | Needs a guest patch, shim, injected component, boot-arg or pipeline edit of the firmware. No real device has it. |
| **S** | Stub. Fixed values, writes ignored, or a RAM window where a device should be. |

A row with more than one class (R/S, R (+P gate), S + P, R (SDIO) / H (firmware)) is counted under its lowest class
in the summary, in the order R > H > P > S; qualifiers such as "(unverified)", "(partial)", "(inert)" or
"(absent)" do not change the class.

## Summary

| Board | R | H | P | S | rows |
|---|---|---|---|---|---|
| K48 iPad 1 | 26 | 8 | 6 | 19 | 59 |
| N72 iPod touch 2G (and the N45 1G parts it shares or adds) | 20 | 7 | 7 | 24 | 58 |
| Guest side (both boards: boot-args, injected components, image edits, synthesised state) | 0 | 0 | 43 | 0 | 43 |

Counts exclude the retired fixed-address TCG libc substitution on October 1; K48 watchdog updated after the overnight audit confirmed the already-landed timed reset model. The two board lines were one off before: K48 #47 (`R (+P gate)`) and N72 #47
(`R (custom) / S (GID, UID) / P (preserve)`) had been counted as R. Guest side: the 34 rows of its three tables (the
historical `nand-enable-reformat` row not counted) plus the 9 per-build assumptions still live (items 1, 4 and 5
retired).

The distance to "boots any iOS unchanged" is the H and P rows. The two that decided it were the IOP
(every NAND and SDIO byte went through a C reimplementation of one specific firmware's mailbox ABI;
since 2026-09-29 Apple's firmware runs on a modelled second core, the default) and the GPU (there is
none; GL exists only because the guest's GLEngine is replaced by a shim), which was the next stop
of iOS 5 (5.1.1 reached SpringBoard on the IOP core and never drew until `ios5-gl` taught the shim 5.x's GL
stack; GL is still a guest shim, P). The
iOS 5 spike hit exactly those, in that order (`docs/ipad1/ios5.md`).

## K48 (iPad 1, S5L8930 "A4")

Machine: `hw/arm/ipad1.c`. Boot paths: `bootrom=` (real SecureROM → LLB → iBoot; R with
`gid-blobs=` and `development-fuses` for unpersonalised images), `iboot=` (a pattern-patched iBoot,
P), `kboot=` (direct kernel with a synthesised boot_args/DeviceTree, P). The default prepared device
uses `iboot=`.

| # | Component | Model, key lines | Class | Why | Faithful version, scope |
|---|---|---|---|---|---|
| 1 | Cortex-A8 | `ipad1.c:595-602` (stock QEMU TCG) | R | Guest code runs unmodified. | – |
| 2 | DRAM 256 MiB @0x40000000, SRAM 256 KiB @0x84000000 | `ipad1.c:604-618` | R | Plain RAM. | – |
| 3 | DRAM mirror @0x50000000 | `ipad1.c:607-615` | R (unverified) | The alias iBoot links against (0x5ff00000). "Not yet confirmed on hardware"; the 0xC0000000 alias is not mapped. | Probe on the unit |
| 4 | SecureROM @0 + alias @0xbf000000 | `ipad1.c:626-646` | R | The real 64 KiB ROM dump executes (`docs/ipad1/iboot.md`). | – |
| 5 | ChipID / fuses @0xbf500000 | `ipad1.c:648-674` | S | Fixed words {0x31800387, 0x80758000, die-id}; `development-fuses` clears bits 0 and 7. | Fuse block from a dump of the real unit |
| 6 | CPU debug @0xbf701000 | `ipad1.c:676-679` | S | A RAM page. | Register-level debug block; little value |
| 7 | VIC ×4 (PL192, daisy-chained) | `ipad1.c:681-697`, `hw/intc/pl192.c` | R | Register-level. | – |
| 8 | DMC @0xbf800000 | `hw/arm/s5l8930_dmc.c:30-41` | S | "Immediate DLL calibration": writes set lock plus a fixed delay; everything else reads back. | Training state machine |
| 9 | PMGR PLLs, clock config, gates, POWER_ID | `hw/arm/s5l8930_pmgr.c:84-146, 258-267, 316-351` | S | "Nothing here decodes clock frequencies." Reconstructed values, lock/busy bits faked, gates settle instantly and gate nothing. Only the I2S NCO (+0x104) feeds anything. | A clock tree that derives timer/UART/I2S rates and gates peripherals; unknown: the PLL/divider encoding, and 4.3+'s new pmgr properties (`voltage-states0`, performance domains) |
| 10 | PMGR 24 MHz timebase + 2 event timers | `s5l8930_pmgr.c:158-211, 239-253, 290-304` | R | Counts down in virtual time with the kernel's FIQ ack protocol. | – |
| 11 | Watchdog (PMGR +0x2020) | `hw/arm/s5l8930_pmgr.c` | R (driver-backed reset/count contract) | Since `4ecef106c1`, the counter advances on the 24 MHz virtual timebase and schedules reset at the compare, including without further MMIO. Feed, disable/resume, compare changes and immediate reset pass production board qtests. This does not establish watchdog interrupt-mode behavior. | Interrupt threshold/IRQ contract remains unverified |
| 12 | GPIO + interrupt controller @0xbfa00000 | `hw/arm/s5l8930_gpio.c:1-16` | R | 176 pin configs, group mask/status, IRQ 0x74. | – |
| 13 | Buttons | `ipad1.c:381-389, 509-577, 1517-1546` | R | Host keys drive GPIO port 0 levels and PMU wake events. | – |
| 14 | I2C0 / I2C2 | `hw/arm/s5l8930_i2c.c:26-160` | R | FIFO block driven by the stock kext; a transfer completes inside the command write. I2C1 absent. | – |
| 15 | D1815 PMU (i2c0 0x74) | `s5l8930_i2c.c:224-480` | H | Register file with events and IRQ, but hibernate keeps the AP running, ADC mux 4 (battery) and mux 6 (brick ID: the dock's selected USB data line, 0 V with the cable in as a host's pull-downs hold it; AppleD1815PMUPowerSource's cable classifier on 4.2.1, 4.3.x and 5.x, smoke #35) are real, the others 0x800, RTC is host time, an OOC write shuts QEMU down, the restart command (0x7b = 0x0b, AppleD1815PMU vtable +0x358 on 4.2.1 and 4.3.5) resets the machine and keeps the scratch bank 0x80-0x9F (0x8F: the OS's boot reason iBoot reads) and the RTC, as the PMU's always-on domain does (a halt with the cable restarts into iBoot's power-off simulation, confirmed as the power-off, smoke #28); STATUS A bit 3 is VBUS while a host's cable is in (4.x's halt reads it to restart into iBoot's power-off wait rather than stand by, smoke #55a); the rest of 0x7b (0x0f/0x0e from +0x354) is stored. | Power-down/resume through the ROM, all ADC channels, regulator effects, 5-10 d |
| 16 | TCA6408 GPIO expander (i2c0 0x20) | `s5l8930_i2c.c:529-690` | R | Datasheet registers and INT; no input pins wired. | – |
| 17 | LTC4099 charger (i2c0 0x09) | `hw/arm/s5l8930_ltc4099.c:41-80` | S | STAT synthesised from `usb-cable`; writes stored, never acted on. | Charge state machine |
| 18 | CS42L61 codec (i2c0 0x4a) | `ipad1.c:732-739`, `hw/arm/ipod_touch_cs42l58.c` | S | The iPod's CS42L58 register file stands in; the kext never checks the chip ID; MCLK (PWM block) unmodelled. | CS42L61 map |
| 19 | AK8973 magnetometer (i2c0 0x1e) | `s5l8930_i2c.c:798-990` | R | Register-level; field from the host heading and pose. | – |
| 20 | CD3282 Mikey (i2c0 0x39) | `hw/arm/ipod_touch_cd3272_mikey.c:16-38` | S | Every register reads 0 ("nothing plugged in"). | Headset detection |
| 21 | LIS331DLH accelerometer (i2c2 0x19) | `hw/arm/ipod_touch_lis302dl.c:30-40, 243, 382` | R | LIS302DL model with `whoami=0x32`; 4.x's BOOT-bit poll fixed 2026-09-28. INT pins not driven. | – |
| 22 | TSL2581 light sensor (i2c2 0x39) | `s5l8930_i2c.c:693-763` | S | One fixed indoor reading; no interrupts. | Host lux + IRQ |
| 23 | bq27545 gas gauge over HDQ (UART5) | `hw/arm/s5l8930_hdq.c:136-196` | R/S | The bit-banged HDQ protocol runs unmodified; the data is synthetic (linear voltage, ±300 mA). | Discharge model |
| 24 | DisplayPipe0 @0x89000000 | `hw/arm/s5l8930_display.c:395-523, 602-650` | H | Parameter-FIFO register file; only UI0/UI1 scanned out, source-over only, nearest scaling, ARGB8888/4444/RGB565, layer rectangles honoured; no video layers, blend modes, gamma, dither; VBL is a fixed 60 Hz timer. | All layers and modes, timing-driven VBL/underrun; unknown: which layer/mode combinations 4.3+ and 5.x program |
| 25 | CLCD timing generator @0x89200000 | `s5l8930_display.c:217-238, 618-635` | S | Register file whose reset seeds iBoot's "k48" timing (needed by 4.x's `start_hardware`); IRQ 0x29 never raised. | Derive refresh from timing |
| 26 | DART1 @0x88d00000 (ISP/JPEG/VENC), DART2 @0x89d00000 (display) | `s5l8930_dart.c` (one register block, dart2 embedded in the display) | S | STE read/write only; never busy; no fault IRQ. dart1 has no modelled client (smoke #29). | Full DART (translation and faults) |
| 27 | RGBOUT, RGBOUT2, TV-out | `s5l8930_display.c` (`pipe_frame_end`, `ram_ops`) | S | Second pipe: register file plus swap completion and its own VBL/swap-done interrupt (0x2b) on the shared 60 Hz tick (smoke #27: 4.3's power-off waits on it), never scanned out; RGBOUT2/TV-out RAM blocks with a "clock-down ready" bit. | Second scanout + SDO |
| 28 | MIPI-DSIM + Pinot panel @0x89500000 | `hw/arm/ipod_touch_mipi_dsi.c:27-155` | H | DSIM registers with direct-boot handshake shortcuts; the panel answers only DCS B1 with a constant; DSI IRQ unwired. | Panel state machine |
| 29 | M2 scaler/CSC @0x89300000 | `hw/arm/ipod_touch_scaler.c:63-210` | H | RGB32 nearest-neighbour only; its NV12 path rejects iPad DRAM addresses (`:130-134`). | Polyphase, all formats, through DART; unknown: which formats the guest's drivers request |
| 30 | SWI (backlight, core voltage) @0xbf600000 | `hw/arm/ipod_touch_swi.c` | S | RAM; busy bit self-clears; backlight level ignored. | Dimming on the console |
| 31 | SDHC @0x80000000 | `hw/arm/s5l8930_sdio.c` | R | SDHCI 2.0 host under the IOP firmware's sdiodrv: self-clearing software reset, internal-clock-stable, block size/count, argument, transfer mode, command (issued by its index byte), responses, present state, normal/error status with status and signal enables, caps/version; CMD53 data through the buffer data port the firmware's CDMA channel streams (read: in the FIFO when the command completes; write: collected, then to the card). No SDMA/ADMA (the firmware uses neither), no command/data timeouts. With `iop-core=off` ring-3 commands are still run in C (H). | Timeouts/error bits |
| 32 | BCM4329 Wi-Fi card | `ipad1.c:829-876`, `hw/arm/ipod_touch_sdio.c:128-178, 228-244, 501-679` | H | The firmware the driver downloads is stored and never executed; DEVREADY/FWREADY announced on a CORECTL write; CDC/BDC ioctls answered in C (BSS_INFO, RSSI −45, `ver` = "4.218.175.43"); a fake open BSS "qemu-ios" auto-joined; only the 802.3 frames are real. | Dongle SoC (Cortex-M3, backplane, D11 MAC/PHY) running the downloaded firmware; unknowns: the undocumented backplane and D11 MAC/PHY, plus a radio model; practically infeasible |
| 33 | IOP (the A4's ARM7 coprocessor) | `hw/arm/s5l8930_iop_core.c`, `s5l8930_iop.c` (control block) | R | The firmware the kernel uploads (iBoot-817, iBoot-931, EmbeddedIOP-20.4, -33.4 seen) runs unmodified on an arm946 second core (default `iop-core=on`): address 0 = the image, DRAM at 0xc0000000, the AP's peripherals at their addresses, its own four PL192s with every board interrupt split to them, PMGR event timer 1 as its tick; system reset and snapshots cover it. Eight cp15 overrides stand in for what QEMU's arm946 lacks (ID/thread regs, a ninth MPU region, CPACR, v6 WFI). `iop-core=off` keeps the v1/v2 HLE (iOS 3.2-4.2 firmware only; the v3 instrument is deleted). | cp15 by the ARM7TDMI-S/946 TRM rather than overrides |
| 34 | NAND page store | `s5l8930_iop.c` (store), `s5l8930_h2fmi.c` (chips) | H | mmap'd sparse store + dirty-bitmap overlay, programmed and erased through the H2FMI; pages are plaintext: the CDMA's inline AES and per-page IVs on the NAND FIFO channels are skipped both ways (a real device holds ciphertext). | Keep the store, apply the NAND AES both ways (key + IV descriptors) with an encrypted store format, and the pipeline writing it |
| 35 | H2FMI0/1 @0x81200000 | `hw/arm/s5l8930_h2fmi.c` | R | Register-level read, program (0x80/0x10, cache 0x81/0x11) and erase (0x60/0xd0) for iBoot and the IOP firmware: per-CE page latches, a transfer starts on entering read mode or raising bit 7, FIFOs paced for the CDMA (O(1) pops), a page write waits for its data and meta, each write FIFO completes its own chain on drain, ECC results per sector (clean or blank; no bit errors), migrated. A full stock restore (`restore-smoke --erase`) passes through it. | ECC error injection for FTL error paths |
| 36 | CDMA @0x87000000 | `hw/arm/s5l8930_cdma.c` | R | Descriptor engine driven by the stock AppleCDMA, iBoot and the IOP firmware; +0x10/+0x14 read back the enabled channels (the three drivers' enable helpers and AppleCDMA-300.8's CSR check); device-FIFO channels paced by the H2FMI and completed when it drains them; AES on memory-to-memory pairs, skipped on device FIFOs (row 34); I2S paced; UART RX channels park. | Timing + UART RX hook |
| 37 | AES filter (custom keys) | `s5l8930_cdma.c:273-279` | R | Real AES-CBC with the guest's key. | – |
| 38 | AES UID key | `s5l8930_cdma.c:171-176, 294-298` | S | "A fixed made-up value". | Impossible (fused) |
| 39 | AES GID key | `s5l8930_cdma.c:178-193`, `ipad1.c:916-918` | S/P | Pre-decrypted KBAGs from `gid-blobs=` (from the public key page); a miss falls back to the UID stand-in. | Impossible (fused); the table is the honest substitute |
| 40 | SHA-1 @0x80100000 | `hw/arm/s5l8930_sha1.c` | R | Compression engine, CDMA FIFO and PIO. | – |
| 41 | PKE (RSA) @0x83100000 | `hw/arm/ipod_touch_pke.c:8-28, 109, 230` | R | Genuine Montgomery math; `forge-sigcheck` never set on ipad1. | – |
| 42 | I2S0-2 @0x84500400 | `hw/arm/s5l8930_i2s.c`, `ipad1.c:1056-1068` | R | i2s0 TX/RX to host audio at the NCO rate; i2s1/i2s2 drop data (S). | – |
| 43 | AMC @0x84100000 | `hw/arm/ipod_touch_amc.c:29-35, 1335` | S | Register file whose interrupts report pending as soon as enabled; no decode; aux window unimplemented. | AMC DSP running its programs (go/no-go: the DSP's undocumented instruction set); or port the iPod's decode HLE (H, known pieces) |
| 44 | USB PHY @0x86000000 | `hw/arm/ipod_touch_usb_phys.c:11-60` | S | Register file. | Charger detect |
| 45 | DWC OTG device @0x86100000 | `ipad1.c:941-976`, `hw/arm/ipod_touch_usb_otg.c` | R | Synopsys core driven by the stock AppleSynopsysOTGDevice; 4.x's NAK-clear and ZLP behaviour added 2026-09-28. | – |
| 46 | OTG "wire" (TCP to usbmuxd-qemu) | `hw/arm/ipod_touch_tcp_usb.c`, `ipod_touch_usb_otg.c:143-180, 1143-1190` | H | The USB bus is a TCP packet protocol; without a bridge a scripted host enumerates and sends the 500/1600 mA charge request. | usbredir/usbip export |
| 47 | EHCI + OHCI0 host @0x86400000 | `ipad1.c:977-997`, stock `exynos4210-ehci`, `sysbus-ohci` | R (+P gate) | Stock QEMU controllers, but published only because the pipeline adds `hsic-enabled` to the DT and `enable-hsic=1` to boot-args; USB_CTL 0xbf108000 unimplemented. | Model USB_CTL and cable-type mode switching (4.3+ changed the gate to `publish-criteria`) |
| 48 | USB keyboard (`usb-kbd,max-power=20`) | `hw/usb/dev-hid.c:46-49, 725-733` | R | Stock HID with a lower bMaxPower so 4.x's 50 mA CCK budget accepts it. | – |
| 49 | SPI0 + NOR (1 MiB, `nor=`/`nor-rw=`) | `ipad1.c:999-1018`, `hw/arm/ipod_touch_nor_spi.c` | R | Controller + JEDEC flash; program/erase instant; peripheral chosen through the `set_spi_base()` global (`ipod_touch_spi.c:302-354`). | Busy latency |
| 50 | SPI1 + Zephyr2 multitouch | `ipad1.c:1020-1030`, `hw/arm/ipod_touch_multitouch.c:109-215, 288-310, 453-509, 601-815` | H | The ~48 KB firmware download is checksummed and discarded; report-info and controls come from `mt_profile_k48`; touch frames are built in C; register writes not processed; reset/download GPIOs ignored. | Touch MCU running the downloaded firmware + a capacitive front-end; unknowns: the MCU's core and peripherals and the front-end (undocumented) |
| 51 | SPI2 baseband controller | `ipad1.c:1032-1040` | R | Empty bus, as on the Wi-Fi unit. | – |
| 52 | UART0/1/2/4 | `ipad1.c:1085-1096`, `hw/char/exynos4210_uart.c` | R | Exynos UART patched for the S5L interrupt scheme. | – |
| 53 | UART3 Bluetooth | `ipad1.c:1107-1109`, `imgtools/ipad1_rootfs.py:238-242, 771` | S + P | NULL chardev; BTServer is set `Disabled` at bake (Settings shows Bluetooth "Unavailable"). | HCI port of `ipod_touch_bt.c` (H); running BCM patchram (R) infeasible |
| 54 | SGX535 GPU @0x85100000 | nothing in `ipad1.c`; `imgtools/ipad1_kboot.py:304-307` sets `sgx` compatible=none (kboot only) | P (absent) | **There is no GPU model.** On the kboot path the driver is unmatched; on the iBoot path the stock node stays and IMGSGX535 hits the unimplemented window. | PowerVR SGX535 (USSE cores, TA/ISP/TSP, microcode) running the guest's kext: six phases (registers + MMU, driver init, USSE1 interpreter, TA/ISP, fragment/texture, host shader translation; docs/research/sgx535-feasibility.md §3), go/no-go on decoding the undocumented USSE1 encoding; the one row that would delete rows 55, 59-61 and most boot-args. **First milestone, separable: the SGX MMU** (page-directory base register + the kext's page tables, walked by the host). The kext already builds those tables for every surface; walking them could give the GL bridge each CA surface's physical pages with no CPU mapping (surfaces measured 09-29 as scattered 4 KiB pages, no DART, no carveout). Caveat (docs/research/sgx535-feasibility.md): the kext maps into the GPU tables from its GL-context paths, which our shim bypasses, so the walk may find no CA surfaces while the shim is in place; phase 1 must check whether IOSurface creation alone maps them |
| 55 | GLES host bridge | `hw/arm/gles-host.c`, `hw/arm/guest-gles.c`, `ipad1.c:140-214` (cp15 hypercall) | P | The guest's OpenGLES.framework is replaced whole by one front end (qemu-ios `contrib/gles-public`, the same binary on every 3.2-5.1.1 build) that traps `QC_GLES` to a host GL context; nothing under OpenGLES (GLEngine, libGFXShared, a gld plugin) loads. ES 2.0 partial. The seam is the public API, which 4.2.1→4.3.5 did not change at all (qemu-ios `docs/ipad1/gles-public-seam.md`). | Replaced by row 54 |
| 56 | cp15 hypercall register | `ipad1.c:140-214`, `include/hw/arm/guest-services/general.h` | P | A made-up coprocessor register (op1=3, c15,c15,0) only guest shims use. | None (not hardware) |
| 57 | TCG `it-hle` hooks | Retired from the candidate translator | — | The fixed-address memcpy/memset/bzero substitutions and their environment controls are deleted. Guest instructions execute normally. | Removed; excluded from active counts |
| 58 | Guest pasteboard, packages, agent | `hw/arm/guest-pasteboard.c`, `hw/arm/guest-package.c`, `ipad1.c:175-203` | P | Reachable only through guest-installed daemons over the hypercall. | Stock USB services (lockdown/AFC) for what they cover; the pasteboard has no R form |
| 59 | Rootfs bake shims | `imgtools/ipad1_rootfs.py` (see the guest-side table) | P | Guest edits the pipeline makes. | See guest-side table |
| 60 | Unimplemented window | `ipad1.c:620-624` | S | One `create_unimplemented_device` over 0x80000000-0xBFFFFFFF: SGX, PWM 0x83500000 (codec MCLK), AMC aux, USB_CTL 0xbf108000, CE-ATA, I2C1, SPI3/4, UART6 all read 0. | Per block, above |

## N72 (iPod touch 2G, S5L8720)

Machine: `hw/arm/ipod_touch_2g.c`. Boot paths: SecureROM (default; the boot ROM runs LLB from NOR
and iBoot; a board compatibility observer still supplies command-line data, P), `direct-iboot=`/`direct-llb=` (decrypted
images staged in RAM, P). 35 `getenv()` calls (32 `IT_*` names) in the machine file alone.

| # | Component | Model, key lines | Class | Why | Faithful version, scope |
|---|---|---|---|---|---|
| 1 | ARM1176 | `ipod_touch_2g.c:883-904` | R | Stock QEMU core. | – |
| 2 | cp15 REG0/REG1 overrides | `ipod_touch_2g.c:33-41, 872-875` | S | Cache ops store and do nothing. | Real REG0/REG1 values and cache-op effects per the ARM1176 TRM |
| 3 | cp15 hypercall | `ipod_touch_2g.c:43-60, 876`, `hw/arm/guest-services.c:54-192` | P | Used only by injected guest binaries. | None |
| 4 | cp15 HOST_GMT_SECONDS | `ipod_touch_2g.c:860-880` | P | Host `time()` for old research kernels; stock builds use the PMU RTC. | Delete |
| 5 | RAM windows (vrom, insecure 48 M, secure, fb, iboot, llb, sram1) | `ipod_touch_2g.c:1366-1392` | R | Plain RAM; llb/sram1 overlap at equal priority. | MIU model |
| 6 | EdgeIC @0x38E02000 | `ipod_touch_2g.c:1381` | S | 4 KB of RAM. | Register-level EdgeIC (edge latching in front of the VICs) |
| 7 | VIC0/1 (PL192) | `ipod_touch_2g.c:2934-2952` | R | Register-level. | – |
| 8 | Timer | `hw/arm/ipod_touch_timer.c` | R/S | Timer 4 + 64-bit tick counter real; timers 0-3 hold their registers, latch on STATE bit 1, run, one-shot and report the output pin's waveform at `input-hz` (N45: 24 MHz; the N45 buzzer's PWM, row 58), no 0-3 interrupts (none enabled by any kernel seen); 6 vs 10 MHz mismatch kept; time-dilation knob. | 0-3 interrupts when a consumer appears; timer 4 at its configured rate |
| 9 | Clock0/1 | `hw/arm/ipod_touch_clock.c`; `docs/ipod/clock-n72.md` | R for N72 root PLL/PCLK; S for consumers/secondary block | Root PLL locks follow valid enabled PLLs; PCLK derives from reference, MDIV/PDIV and peripheral divider. Reset and actual VMState round trip pass production board qtests. Native SecureROM/LLB programs these registers; direct-iBoot leaves them zero. Analog settling, gates and peripheral timing remain incomplete. | Restore the earlier clock handoff for the direct-iBoot shortcut; prove each consumer's clock/divider/gate contract before connecting it. S5L8900/secondary block retain their existing stubs |
| 10 | SYSIC (power + GPIO IC) | `hw/arm/ipod_touch_sysic.c:52-70, 110-200` | R/S/P | GPIO IC real; ONCTRL drops some bits; epoch 4 synthesised for direct boot. | Power-domain machine |
| 11 | GPIO | `hw/arm/ipod_touch_gpio.c:20-60, 97-130` | R/S | Only FSEL out-lo/hi modelled. | All FSEL modes, inputs and interrupts |
| 12 | WDT | `hw/arm/ipod_touch_wdt.c`; `docs/ipod/clock-n72.md` | S | One exact command resets; no timed expiry. Native timed write trace establishes the regular feed value and cadence. OpeniBoot's disabled enable function and older-chip counter widths are leads, not N72 timing proof. | Establish N72 counter width, selectors and overflow timing; resolve missing direct-iBoot clock setup before enabling a timed reset |
| 13 | UART0-3 | `ipod_touch_2g.c:3017-3042` | R | Exynos UART; UART4 never created. | UART4 |
| 14 | Bluetooth HCI (BCM4325 BT on UART1) | `hw/arm/ipod_touch_bt.c`; `docs/research/ipod-bluetooth-address.md` | H | Command Complete from tables, provisioned Write/ReadBDADDR state with reset and VMState coverage; no ACL/SCO; fake 0xfc2e banner for BlueTool. | BT core running patchram; unknown: the BCM4325's BT core (undocumented) |
| 15 | PL080 DMAC0/1 | `ipod_touch_2g.c:3151-3238` | R | Stock PL080 with paced request lines. | – |
| 16 | SPI0-4 | `hw/arm/ipod_touch_spi.c:124-260` | R | FIFO/IRQ model. | – |
| 17 | NOR (SPI0) | `hw/arm/ipod_touch_nor_spi.c:236-349` | R | JEDEC flash, program/erase, `nor-rw` overlay. | – |
| 18 | NOR NVRAM boot-args rewrite | `ipod_touch_nor_spi.c:27-72, 108-110` | P | The host rewrites the "common" CHRP partition when `boot-args=` is set. | None |
| 19 | Zephyr2 multitouch (SPI4) | `hw/arm/ipod_touch_multitouch.c:109-215, 288-310, 480-545, 638-800` | H | Firmware download discarded; tables answer the protocol; frames from the host pointer. | Touch MCU + front-end; unknowns as K48 #50 (undocumented MCU and front-end) |
| 20 | ChipID | `hw/arm/ipod_touch_chipid.c:9-54` | S | 0x8720 + security bits; `IT_DEV_MODE` changes them. | Fuse words from a real unit |
| 21 | TV-out | `hw/arm/ipod_touch_tvout.c:14-51, 61-220` | S | Handshake registers + paced vblank; no output. | TV encoder + second scanout; unknown: the TV-out register contract |
| 22 | unknown1 @0x3D700000 | `hw/arm/ipod_touch_unknown1.c:20-28` | S | Two fixed words. | Identify it (S5L8720 memory map), then model what LLB's write configures (smoke #18) |
| 23 | MPVD (MPEG-4 decoder) | `hw/arm/ipod_touch_mpvd.c:19-32, 190-325` | S (default) / H (`mpvd-decode`) | Register file; opt-in rebuilds the stream and decodes with VideoToolbox. | Job model + in-tree decoder; unknown: the MPVD job/descriptor format |
| 24 | H.264 (M2H264) | `hw/arm/ipod_touch_h264.c:248-760` | S (default) / H (`h264-decode`) | RAM window; opt-in synthesises SPS/PPS/slices for VideoToolbox/libavcodec. | Macroblock pipeline; unknown: the block's job interface below slice level (undocumented) |
| 25 | DWC OTG | `hw/arm/ipod_touch_usb_otg.c` | R | Register-level, S5L8720 HWCFG. | – |
| 26 | USB-over-TCP transport | `hw/arm/ipod_touch_tcp_usb.c` | R (transport) | Host side only. | – |
| 27 | USB PHY | `hw/arm/ipod_touch_usb_phys.c`; `hw/arm/ipod_touch_usb_otg.c` | S/R (partial) | N45/N72 ORSTCON reset gates physical traffic before DMA/IRQ; core pending IRQs preserved; snapshot replay tested. Other power/clock registers remain limited. | Charger/cable detect, power/clock behavior; K48 wiring remains separate |
| 28 | I2C0/1 | `hw/i2c/ipod_touch_i2c.c:35-64, 185-330` | R | Samsung IIC; NAKs absent addresses. | – |
| 29 | PMU (D1759, "pcf50633") | `hw/arm/ipod_touch_pcf50633_pmu.c:54-175, 218-300, 353-404` | R/S | Register file; RTC = host time (the D1759's LE seconds counter at 0x5c; on the N45 `rtc-bcd`: the PCF50633's own BCD calendar at 0x59-0x5f, host UTC, what 1.x's ApplePCF50635PMURTC reads); synthetic battery ADC; shutdown stops the host; backlight enable/level by register property (N45: LEDENA 0x29 bit 0, on/off only, LEDOUT not rendered). The N45 PCF50635 now has five status/mask banks (0x02-0x06 / 0x07-0x0b), USB edge events and EXTON1 Hold/Power edges. Production-board I2C/GPIO/VIC qtest verifies masked latching, parent level ACK, both edges and read-to-clear. Native hibernate still ends in a terminal branch with IRQ/FIQ masked; delivering an interrupt does not implement retained-RAM resume. | Full map with charger; unknown: the registers only some driver versions touch |
| 30 | LIS302DL | `hw/arm/ipod_touch_lis302dl.c:153-246` | R | Register-level; host attitude; no INT/click. | INT/click interrupts |
| 31 | Tethered demo card (`IT_TETHERED`) | `hw/arm/ipod_touch_tethered.c` | S | Returns 0x82. | None (not retail) |
| 32 | CS42L58 codec | `hw/arm/ipod_touch_cs42l58.c:5-43, 61-111` | R/S | MAP register file; LRCLK from reg 05; no ADC/mic. | Capture path |
| 33 | LM48821 amp | `hw/arm/ipod_touch_lm48821.c` | R | Datasheet control word. | – |
| 34 | I2S0 | `hw/arm/ipod_touch_i2s.c`, `ipod_touch_2g.c:3285-3322` | R | DMA-paced FIFO to host audio at the codec's LRCLK. The same model is N45's I2S1 (dmac1 request 2, ready interrupt GPIO 5/10) with `host-output=off` (smoke #56). | – |
| 35 | ISL29003 ALS | `hw/arm/ipod_touch_isl29003dl.c:25-82` | S | Fixed value. | Host lux |
| 36 | CD3272 Mikey | `hw/arm/ipod_touch_cd3272_mikey.c:14-41` | S | Reads 0. | Headset detection and button reads |
| 37 | AMC | `hw/arm/ipod_touch_amc.c:1-119, 361-525` | S (registers) / H (`decode`) | Default reports enabled IRQs pending; decode mode is AAC/MP3/ALAC HLE via libavcodec. | AMC DSP running the guest's DE programs; go/no-go: the DSP's undocumented instruction set |
| 38 | FMSS sequencer | `hw/arm/ipod_touch_fmss.c:96-223` | R (partial) | Executes the guest's sequencer programs, but only the opcodes READ ID and reset need; others stop the run. | With row 39 |
| 39 | FMSS page I/O | `ipod_touch_fmss.c:1058-1288, 1340-1418` | H | 0xD38 + csgenrc 0xa01/0xa02 decoded in C from descriptors; erase inferred from writes; no ECC. | Execute read/write/erase programs against an FMC + NAND model |
| 40 | FMSS store / overlay | `ipod_touch_fmss.c:360-909` | R (backend) | ITNAND01 mmap or directory; copy-on-write overlay. | – |
| 41 | FMSS generated-image FTL compatibility | `ipod_touch_fmss.c:687-824, 1244-1276` | P | Moves writes to their logical home and rewrites the FTL free pool when cs3 page 255 is read (`FMSS_PHYSICAL` off). | Image builder emitting real VFL/FTL metadata |
| 42 | Legacy normal-boot command-line data | `ipod_touch_2g.c` (board observer of the FMSS pre-read notification), `hw/arm/it_iboot.c` (pattern-found legacy command-line buffer) | P | The Bluetooth literal rewrite is removed: real stock drivers read the modeled combo-chip identity. A hard-coded boot-args string is still written into `gBootArgs.commandLine`. | Define the guest provisioning handoff without normal-boot RAM argument injection |
| 43 | MIPI-DSI + panel | `hw/arm/ipod_touch_mipi_dsi.c:27-40, 50-100` | H | Canned panel-ID reply; handshake bits only in direct boot. | DSIM + panel |
| 44 | LCD/CLCD | `hw/arm/ipod_touch_lcd.c:136-258, 377-540` | R (partial) | Window-1 registers kept but scanout fixed 320×480 x8r8g8b8; `lcd-planes` adds BGRA + NV12 planes. | Depth/stride/formats/blending; unknown: which modes the guests program |
| 45 | Scaler/CSC | `ipod_touch_2g.c:3398-3406`, `hw/arm/ipod_touch_scaler.c` | S (default) | `create_unimplemented_device`; opt-in NV12→RGB only. | Scaler/CSC with every format (today NV12→RGB only) |
| 46 | SHA-1 | `hw/arm/ipod_touch_sha1.c` | R | DMA hash engine. | – |
| 47 | AES | `hw/arm/ipod_touch_aes.c:52-383, 385-431, 593-709` | R (custom) / S (GID, UID) / P (preserve) | GID = a built-in KBAG→key table for 5F138/7E18 plus `gid-blobs`; UID constant; an address-specific "preserve" hack for three in-place ops. | Fused keys impossible; the table is the substitute |
| 48 | PKE | `hw/arm/ipod_touch_pke.c` | R | Real RSA; `forge-sigcheck` off by default. | – |
| 49 | MBX register block (PowerVR MBX Lite) | `hw/arm/ipod_touch_mbx.c` | S | **The GPU is absent.** Fixed ID words, idle status; the interrupt block (mask read-back, status set by the driver's software interrupt, write-1-to-clear, the line) is register-level since `gles-1x`; `IT_MBX_COMPLETE` fakes completions. The 1G uses the same model (it was an id stub). | MBX TA/ISP/TSP with an undocumented command format; go/no-go: decoding the TA/3D state MBXGLEngine writes to the slave ports |
| 50 | OpenGL ES path | `contrib/gles-public/opengles.c` over `contrib/it-gles/mbxshim.c`, `hw/arm/gles-host.c` | P | 2.x-4.x: `OpenGLES.framework/OpenGLES` replaced whole by the one front end the iPad uses (qemu-ios `gles-public`; fat armv6+armv7, legacy-linked for 2.x/3.0's dyld), MBXGLEngine left stock and never loaded. Before gles-public: 3.x/4.x replaced MBXGLEngine.bundle with a dispatch shim and 1.x/2.x used `gles2x.c` under the firmware's own export names; SpringBoard composites through it with CA_ENABLE_OGL=1 (2.1.1: software-CA frame rates, about a quarter less host CPU on the launch zoom). 1.x (the 1G, 3A101a): the same file built without EAGL under 1.x's 186 names (`OpenGLES-1x`, guest package `n45-ios1`), LayerKit with LK_ENABLE_OGL=1 (software frame rates, a quarter less host CPU on the launch zoom). | Row 49 |
| 51 | SWI | `hw/arm/ipod_touch_swi.c` | S | RAM; busy bit self-clears. | SWI register semantics |
| 52 | SDIO host controller | `hw/arm/ipod_touch_sdio.c:45-121, 983-1080` | R | CMD5/52/53, CCCR/FBR/CIS. N45: the same controller at IRQ 0x2A with the 88W8686 as its card (row 59): function 1's CMD52/CMD53 and the card's DAT1 interrupt are the card's; the FBR interface code (7, WLAN) and one function come from its identity. | – |
| 53 | BCM4325 Wi-Fi dongle | `ipod_touch_sdio.c:127-178, 296-440, 540-680` | H | Firmware stored, never run; CDC/BDC in C; fake BSS; off by default. | Dongle SoC running its firmware (as K48 #32), infeasible |
| 54 | Host input automation (keys→buttons, on-screen keyboard taps, power-off slide) | `hw/arm/ipod_touch_2g.c` | H | Board still plans OS gestures/layout and virtual-time input sequences. | Host automation owner with virtual-time/display-state observation and explicit legacy raw-client transition |
| 55 | Guest services (agent, keyboard, pasteboard, package) | `hw/arm/guest-services.c:98-183`, `hw/arm/ipod-agent.c` | P | Injected daemons/dylibs over the hypercall. | USB lockdown/AFC tooling for what it covers; unknown: which agent services have a stock USB equivalent on each iOS |
| 56 | TCG `it-hle` | Retired from the candidate translator | — | Shared ARM translator no longer substitutes libc functions at firmware addresses. | Removed; excluded from active counts |
| 57 | WM8758 codec (N45, i2c1 0x1a) | `hw/arm/ipod_touch_wm8758.c` | R/S | The write-only 2-wire control port (7-bit register, 9-bit value, register 0 resets): what AppleWM8758Audio's start needs. No analogue path (headphone jack, hp_detect), so no Beep reaches the host. | Output path + jack detect after smoke #56 |
| 58 | Piezo buzzer (N45, timer 1) | `hw/arm/ipod_touch_piezo.c` | R | The stock chain drives it unmodified: mediaserverd (Celestial's Buzz, SystemSoundBuzzToneSequences.plist) → AppleS5L8900XTimerDevice → timer 1 registers (row 8). The pin's square wave is rendered into a 44.1 kHz host voice 40 ms behind the guest clock. The transducer is ideal (no resonance or filtering); `amplitude` is a loudness knob. | A piezo response curve, if anyone can measure one |
| 59 | Marvell 88W8686 Wi-Fi card (N45, SDIO) | `hw/arm/mrvl8686.c`, `ipod_touch_1g.c` (the `wifi` property) | R (SDIO) / H (firmware) | AppleMRVL868x-69 runs unmodified. Register level: function 1's registers and I/O port, the helper download, the helper's EEPROM read (Wi-Fi MAC, TX calibration), the main program's block-by-block download with the image's CRC-32 per header and block (a bad one sets the error bit), FIRMWARE_OK, the host interrupt status (write 0 to clear) under its mask, deep sleep and its wake event. The helper and the 120 KiB firmware the kext carries are accepted and never run: the running firmware's host commands, events and TxPD/RxPD data path are answered in C, with one open access point ("qemu-ios", channel 6) behind slirp. The EEPROM's MAC is the unit identity's (machine `wifi-mac`, from FirmwareKit's device.lock.json; iBoot copies the same MAC from nvram `wifiaddr` into the DT, so lockdownd's UDID is the identity's); invented: the calibration bytes, the firmware version (9.70.3.p24), and 00:1b:63:45:1e:01 when no `wifi-mac` is given. The card ignores the slot's `function-power_enable` (GPIO 0x1701, which the S5L8900's FSEL at +0x320 drives on, off, on during boot: smoke #61). `tests/ipod/test_mrvl8686.py`. | Run the Marvell firmware (its ARM core, MAC and a radio model), infeasible |

## Guest side: patches, shims, boot-args, synthesised state (both boards)

Everything here is class P. "Replaces" says what a real device has instead.

### Boot-args

| Arg | Where | Replaces / bypasses | Faithful alternative, cost |
|---|---|---|---|
| `amfi_allow_any_signature=1` | K48: `imgtools/ipad1_kboot.py:63` (kboot) and `ipad1_iboot.py:77` (iBoot32Patcher `-b`); N72: `tests/ipod/regress.py:292,355`, `hw/arm/ipod_touch_2g.c:1051-1226` (late DRAM write), `ipod_touch_2g.c:ipod_touch_compat_command_line` (SecureROM compatibility string) | AMFI's rejection of ad-hoc (ldid) signatures: every injected helper, shim and dylib is ad-hoc signed. | Nothing injected (needs the GPU model and stock services); otherwise permanent |
| `cs_enforcement_disable=1` | same places | Kernel code-signing enforcement, for the same binaries and for `DYLD_INSERT` hooks. | Same |
| `debug=0x8`, `serial=3` | same | Diagnostic: kprintf on UART0. A production iBoot boots with neither. | Drop once serial is not needed |
| `enable-hsic=1` + DT `arm-io/usb-complex/hsic-enabled` | `ipad1_kboot.py:350-351`, `imgtools/ipad1_gid.py:53-88` (NOR DT) | 4.2.1's `AppleS5L8930XUSBArbitrator` publishes the host nubs (USB keyboard) only with both. Apple's own knob, but not a shipping configuration. 4.3+ removed both (`publish-criteria` in the DT instead). | USB_CTL + cable-type model (K48 row 47) |
| `rd=md0` | `ipad1_kboot.py` ramdisk mode, `imgtools/ipod2g_keybag.py:34` | Restore boot for the keybag one-shot: the IPSW's own restore ramdisk as SecureRoot. Faithful restore-boot state, used once. | Stock USB restore instead (exists: `tests/ipad1/restore-smoke.py`); what is left is making it the pipeline's step (ranked #2) |
| `-v`, `rd=disk0s1`, `kextlog`, `io=`, `pmu-debug`, `debug-usb` | `ipod_touch_2g.c:ipod_touch_compat_command_line` | Board compatibility observer writes the verbose string before NAND reads on the SecureROM path; FMSS itself no longer edits firmware. | Stock iBoot NVRAM delivery. A 2026-09-30 no-injection 5F138 probe ignored the generated variable; not yet removable |
| iBoot32Patcher `--rsa --debug -b` | `ipad1_iboot.py:70-91` | `--rsa`: image signature / personalisation check (unpersonalised stock images boot); `--debug`: `debug-enabled` so boot-args are honoured; `-b`: the boot-args above. | Unpatched iBoot needs Apple-personalised images (SHSH/APTicket); impossible offline. The bootrom path with `development-fuses` and the IPSW's development certificates is the honest R-adjacent form |
| `nand-enable-reformat=1`, `amfi_get_out_of_my_way=1` | not used any more | Historical (kernel self-format; DYLD-insert into installd). | – |

### Guest components and image edits

| Item | Board | Applied where | Replaces / bypasses | Faithful alternative, cost |
|---|---|---|---|---|
| `OpenGLES` (the GL front end, qemu-ios `contrib/gles-public`) | K48, N72 2.x-4.x | FirmwareKit `SystemEdits.installCAOGL` (required `FitCheck.glesFrontEnd`), guest package hooks `k48-*`, `n72-ios2/30/3` | Apple's OpenGLES.framework and everything under it (GLEngine/MBXGLEngine, libGFXShared, the gld plugin). One binary; the private present path (native window version, IOSurface/CoreSurface, IOMFB swap, 5.x's macro-context dispatch layout read from the shared cache's stock OpenGLES) found at run time and proven present at prepare. Replaces glishim, gldshim and `GLEngine-<BUILD>` (deleted) and, on the iPod, MBXGLEngine and gles2x. | GPU model (K48 row 54) |
| dyld `enable-dylibs-to-override-cache` | K48, N72 3.1+ | `SystemEdits.setOverrideSwitch` | Lets the front end on disk override the cached OpenGLES (Apple's own switch; dyld rebinds the cached consumers). | GPU model |
| SpringBoard env `CA_ENABLE_OGL=0` (software) / none (GL), `MBX2D_PAGE_FLIP=0`, stdio to `/dev/console` | K48 | `ipad1_rootfs.py:610, 694` | CoreAnimation's compositor choice; SpringBoard stderr on serial. | GPU model; console line is diagnostic |
| AppSync (shared-cache patch of `MISValidateSignature` + installd `DYLD_INSERT` dylib) | both | `imgtools/appsync_cachepatch.py`, `contrib/appsync`, `ipad1_rootfs.py:211-215, 675` | App Store signature checks in amfid/installd/SpringBoard, so decrypted IPAs install and launch. | None that keeps unsigned IPAs; a signing identity would be Apple's |
| Guest-package loader `it_boot` + seed package | both | `contrib/guest-package/mkpkg.py`, `ipad1_rootfs.py` bake, `imgtools/bake-guest-tools.sh` | Delivers the helpers below at boot (versioned, rollback) instead of baking each. `FAMILIES` keyed on exact build strings (`mkpkg.py:52-66`). | Key on (board, major) |
| `it_agent` (+ `it_typein` on N72) | both | `contrib/it-agent` | Foreground app, lock state, launch/sync, typing: services the stock device offers only through Apple tooling. | usbmux/lockdown/DDI for what they cover; unknown: which services have a DDI equivalent on each iOS |
| `it_pbd` / pasteboard | both | `contrib/it-agent`, `hw/arm/guest-pasteboard.c` | Host↔guest clipboard (no real analogue). | None |
| `it_ethlink` | K48 | `contrib/it-ethlink` | Sets USB Ethernet `LinkStatus=1` through IOKit (replaced the deleted `--usb-eth-link` kernel patch). | Model the link in the OTG/Ethernet function |
| `it_prefs` (one-shot CFPreferences) | K48 | `contrib/it-prefs` | Web-proxy PAC, location defaults. | Stock DHCP/WPAD |
| `it_msmquiet.dylib` (mounter hook) | K48 | `mkpkg.py IPAD_HOOKS`, `ipad1_rootfs.py:230-231, 769` | Hides the "USB device not supported" alert (Apple bug that blocks screen lock; Sam approved). | None wanted |
| `it_seal` | both | `ipad1_rootfs.py:243-244` | One-shot clean `reboot(RB_HALT)` at prepare so the FTL context is flushed. | Stock restore, or a guest power-off gesture |
| `it_keybag` as `restored_external` on the IPSW's restore ramdisk | K48 4.x/5.x | `imgtools/ipad1_keybag.py`, `contrib/it-keybag` | The data-protection steps `restored` does (format effaceable, `MKBKeyBagCreateSystem`), using the stock symbols. | Stock USB restore (ranked #2) |
| BTServer `Disabled` | K48 | `ipad1_rootfs.py:238-242, 771` | Bluetooth (no controller model; BTServer's retries stalled SpringBoard). | HCI model, K48 row 53 |
| fstab rw root, `/dev/disk0s2` data | K48 | `ipad1_rootfs.py:24-26` | Insurance for a failed data mount (stock is `ro`). | `--ro-root` exists; no new work |
| USB Ethernet DHCP service, AirPort service + PAC | K48 | `ipad1_rootfs.py:37-41, 320-351` | Network preferences a first boot would create itself. | Let the guest configure |
| `/var` owners patched offline, data volume seeded | K48 | `ipad1_rootfs.py:42-45, 499, 732` | What `mobile_obliterator` / restore does on-device. | Stock restore |
| Kernelcache img3 installed on the system volume | K48 | `ipad1_rootfs.py build --kernelcache` | What restore writes. | Stock restore |
| iPod image edits (`ipod2g_device.py`, `nand-current`) | N72 | `imgtools/ipod2g_device.py` | Guest tools baked; major≥3 derivations from Restore.plist. | Stock restore (no USB restore path exists for N72 yet) |
| App catalog per-build fields | both | `LightTouchMac/Resources/firmware-catalog.json` (`recipe.options`, `gli_dispatch`) | – | `gli_dispatch` goes with the runtime @encode parse |

### Synthesised device state

| Item | Where | What it stands in for | Faithful alternative, cost |
|---|---|---|---|
| NOR: NVRAM banks, SysCfg, all_flash images, patched iBoot | `imgtools/ipad1_iboot.py`, `imgtools/build_nor.py` | What a factory/restore writes. | Stock restore writes NOR (`restore-smoke.py --erase` did on 7B500) |
| NAND: offline FTL/VFL writer ("restore + power cut before the CXT flush", first boot does a R/O restore) | `imgtools/ipad1_nand.py`, `imgtools/ipod2g_nand.py` | The on-flash state `restored`/asr leave. Bets on the FTL format (YaFTL 3.x/4.x; iOS 5 adds LwVM). | Stock restore (ranked #2); then no format knowledge in the pipeline |
| `gid-blobs.bin` (KBAG→key from the public key page) | `imgtools/ipad1_gid.py` | The fused GID key. | Impossible; this is the honest substitute |
| Synthetic identity (serial, ECID, die-id, MACs) | `imgtools/ipad1_kboot.py synth_identity` | SysCfg of a real unit. | – (must stay synthetic) |
| 1.x Wi-Fi preferences (N45): the en0 AirPort service in `preferences.plist` (carrying the web proxy's PAC, as on the 2G) and `com.apple.wifi.plist` with `AllowEnable` and "qemu-ios" in "List of known networks" | FirmwareKit `N45Recipe.wifiKnownNetwork` | A device that has joined the emulator's access point before, in configd's own format. 1.1.5 (4B1) auto-joins from it at boot; 1.1 (3A101a) shows Wi-Fi on and the network but needs one tap (smoke #61). | Let the user join once; nothing faithful to gain |
| kboot DeviceTree fill (`chosen/*`, clocks, NAND geometry on `disk` and, for iBoot-1219's 5.x layout, on flash-controller0 with `ce-bitmap`, `display-rotation 270`, `lcd-panel-id`, baseband unmatched, `sgx` off) | `ipad1_kboot.py:284-331` | What iBoot writes into the DT before handoff. | The iBoot path already does most of it (default); kboot stays a debug path |

### Per-build assumptions still in the emulator and pipeline

From the consolidation survey (`docs/sweep/emulator.md` (b)), with the iOS 5 spike's verdict:

1. GLI dispatch layout per build (`gli-dispatch-<BUILD>.tsv`, `GLEngine-<BUILD>`, `mkpkg.py` FAMILIES). Confirmed by 9B206: 905 slots vs 841, derivable by `glitsv.py`, but a new shim build per release. Retired (qemu-ios `gles-public`, 09-29): the one OpenGLES front end reads the layout (5.x only) from the shared cache at run time; the per-build engines are deleted.
2. `mkpkg.py` FAMILIES keyed on exact build strings. 9B206 matches no family.
3. iOS-4 gld plugin: retired with the GLI shim (qemu-ios `gles-public`): nothing under OpenGLES loads.
4. ~~IOP HLE v1/v2 by firmware string + `cnfg` scan.~~ The IOP core runs whatever firmware the kernel uploads (2026-09-29, default); the v1/v2 HLE is left behind `iop-core=off` for iOS 3.2-4.2 only.
5. Kernel banner table `ipod_touch_firmware.c`: deleted (D6, 2026-09-29).
6. GID KBAG hex in C (`ipod_touch_aes.c:52-383`): delete after the nand-current swap.
7. iPod boot-args delivery (bounded DRAM scan and compatibility writes). The direct-iBoot literal redirect and `IT_BOOT_ARGS*` environment input are removed; early console/identity pass on 7E18 and 8C148. The ramdisk one-shot owns its arguments in the existing host debugger handoff.
8. Power-off knob coordinates per orientation (`ipad1.c:376-383`, iPod `PWROFF_KNOB_Y`).
9. Test/tool defaults keyed to 7B500 (`boot-smoke.py` markers name `iBoot-817.29`, `AppleS5L8920XARM7M`, `AppleS5L8920XIOPFMI`; 4.3+ renamed the kexts to `AppleARM7M`/`AppleIOPFMI`).
10. `fb-base 0x4f700000` (iBoot's logo framebuffer).
11. `ipod2g_device.py` major≥3 derivations (manifest logic, acceptable).
12. 115 `IT_*` env names in hw/ (one on the iPad).

## Fit checks

Every guest-side piece the pipeline injects or edits has to prove it fits the firmware it goes into, read off that
firmware at prepare time (symbols, strings, structure; no per-build tables), or, where only a boot can tell, through the
matrix at boot. "Could not tell" never counts as fits. FirmwareKit `FitCheck` (`Packages/FirmwareKit/Sources/FirmwareKit/
FitCheck/`) does it; every verdict goes into the lock's `fit` list; a required piece that does not fit fails the prepare,
an optional one is a warning event and is left out where it can be. `firmwarekit create --stop-after volumes` runs the
real prepare to the end of the bake and writes `fit.json` (the offline survey of a build, no device);
`firmwarekit fit --root MOUNTED_VOLUME MACHO...` checks one binary. Before = the class the detection had before
2026-09-29: A affirmative proof, B absence treated as fine, C assumed by build number or family. The tests are
FirmwareKit's `FitCheckTests` unless named; each fails with its check removed (the commits record the runs).

| Piece | Before | How fit is proven | Prepare or boot | Misfit | Test that fails when the check is removed |
|---|---|---|---|---|---|
| `it_boot` loader (every board) | C | `FitCheck.loads`: a slice the board's CPU runs; every dyld-required load command one of the firmware's own executables (launchd, SpringBoard, lockdownd) carries, so its dyld takes it (3.0 and 2.x ship none with LC_DYLD_INFO_ONLY); every non-weak linked image on disk or in the shared cache; every non-weak import exported by its image | prepare (seed) + boot: matrix `package` (the loader's report; a seed with jobs or hooks that is never offered anything fails, a stub seed is a skip) | fails | `seedChecksTheLoader`; `test-matrix-judge.py` "package: a baked package never offered fails" |
| Seed family payloads (`mkpkg.py` FAMILIES; the family is still chosen by build glob) | C | `loads` for every package binary and hook, a hook in the program whose job inserts it | prepare | fails | `seedChecksTheLoader`, `importsAndHosts` |
| Seeded hooks whose target is missing | B | dropped only as a recorded misfit, unless the bake left the target out on purpose (AppSync off, `it_msmquiet` not fitting) | prepare | warning | `seedRecordsDroppedHooks`, `k48BakeLeavesOutWhatDoesNotFit` |
| `it_agent` (iPad: seed package; iPod: bake) | C | `loads` | prepare + boot: matrix `helpers.agent` (some home event names the frontmost app through it) | iPad fails; iPod see next row | `importsAndHosts`, `iPodToolsOnlyWhereTheyLoad`; judge "a silent agent fails" |
| iPod baked tools (`it_agent`, `it_typein` in SpringBoard, `sblaunch`, `sbdlicon`, `it_prefs`) | C (installed wherever the shared cache was) | `loads`, all or none (`N72Board.guestToolsFit`) | prepare | left out, warning | `iPodToolsOnlyWhereTheyLoad` |
| iPad baked helpers (`it_pbd`, `it_ethlink`, `it_prefs`, `it_seal`) | C | `loads` | prepare (`it_seal` also: the seal boot's halting line) | fails | `k48BakeChecksItsHelpers` |
| `it_msmquiet` | B | the stock storage_mounter job's program names `UNSUPPORTED_FAILURE` or `UNSUPPORTED_FAILURE_BODY` and imports `CFUserNotificationDisplayNotice` or `CFUserNotificationCreate`; the dylib loads in it | prepare | left out (dylib, job edit, hook), warning | `msmQuietFitsWhereTheMounterRaisesTheNotice`, `k48BakeLeavesOutWhatDoesNotFit` |
| `it_ethlink` and the en1 IOPathMatch pin (`usb_net`) | C | the decrypted kernelcache has every class of the pinned path (AppleUSBEthernetDevice among them) and names LinkStatus | prepare + boot: `helpers.ethlink` ("watching AppleUSBEthernetDevice" on the iPad console) | warning | `usbEthernetNeedsThePinnedClasses`, `k48BakeLeavesOutWhatDoesNotFit`; judge "it_ethlink never watching fails" |
| `it_prefs` keys | B (skipped silently on the guest) | each key's reader names it, by it_prefs' own rule | prepare + boot: `helpers.prefs` (iPad console) | warning | `prefsKeysNamedByTheirReaders`, `k48BakeLeavesOutWhatDoesNotFit`, `iPodToolsOnlyWhereTheyLoad` |
| `SBDidShowReorderText` bake (2.x/3.0) | B ("left alone") | SpringBoard names the key | prepare | warning, not baked | `prefsKeysNamedByTheirReaders`, `iPodToolsOnlyWhereTheyLoad` |
| SpringBoard environment switches (iPad `CA_ENABLE_OGL`/`MBX2D_PAGE_FLIP`/`GLI_ACCELERATED`; iPod `CA_`/`LK_` pairs; 1.x `LK_`) | C | each switch, or its CoreAnimation/LayerKit pair, named by the shared cache, a framework binary, SpringBoard, or the binary injected with it (only the GL shim reads `GLI_ACCELERATED`) | prepare | warning | `springBoardSwitchesHaveReaders`, the 9B206 / 7E18 bake tests, `N45Tests.frontEndAndBakeMatchPython` |
| Web proxy PAC (Wi-Fi Proxies keys) | C | `ProxyAutoConfigEnable`, `ProxyAutoConfigURLString`, `ExceptionsList`, `FTPPassive` named by the firmware | prepare | warning | `springBoardSwitchesHaveReaders`, the 9B206 / 7E18 bake tests |
| AMFI boot-args | C | the kernel names `amfi_allow_any_signature` (required) and `cs_enforcement_disable` | prepare (boot-file step) | fails / warning | `bootArgsReadByTheKernel`, `bootFilesRecordTheBootArgs` |
| Other iPad boot-args (`serial`, `debug`, `enable-hsic`) and DeviceTree `hsic-enabled` | C | read or inert per the kernel, recorded | prepare | recorded | `bootArgsReadByTheKernel`, `bootFilesRecordTheBootArgs` |
| iPad kernelcache for fsboot | C (constant path) | the one kernelcache path the decrypted iBoot names is the one installed | prepare | fails | `iPadKernelcacheWhereIBootLoadsIt` |
| 1.x LaunchDaemons keep-list | C | each kept job is among the firmware's | prepare | warning | `n45SurveyRecordsTheKeptJobs` |
| iPod kernelcache path | A | read out of the decrypted iBoot (exactly one) | prepare | fails | (unchanged) |
| dyld `enable-dylibs-to-override-cache` | A | dyld names the switch; fails closed | prepare | fails | (GL work, unchanged) |
| AppSync `libappsync.dylib` and `appsync-launch` (where `options.appsync` is on) | B (only the helper's own shape: slices, a signature, no modern load commands without a shared cache; nothing checked against the service it goes into) | `FitCheck.appSync`, in the program installAppSync inserts it into (installd's job; 2.x: Lockbot's `mobile_installation_proxy` service): that process (the program and every image it links, prebound 2.x/3.0 imports counted) imports what the dylib hooks: `MISValidateSignatureAndCopyInfo` or `MISValidateSignature`, `SecCertificateCreateWithData`, `SecCertificateCopySubjectSummary`, `kMISValidationInfoSignerCertificate`, `kMISValidationInfoValidatedByProfile`; the dylib's getprogname gate names the program; `loads` in it. `appSyncLauncher`: loads, inserts `/usr/lib/libappsync.dylib`, execs a Mach-O the CPU runs. Where appsync is off: recorded `not installed (appsync off)`, nothing checked | prepare | fails | `appSyncFitsEveryAppSyncFamily`, `appSyncDoesNotFitWhereItCannotWork`, `k48BakeChecksAppSync`, `k48BakeLeavesOutWhatDoesNotFit`, `iPodToolsOnlyWhereTheyLoad` |
| `MISValidateSignature` cache patch | A | located by symbol, Thumb prologue byte-checked before any write | prepare | fails | `SharedCacheTests` (unchanged) |
| Stock job edits (SpringBoard, storage_mounter, installd, BTServer) | A | the job exists under its label | prepare | fails | (unchanged) |
| `it_seal`, `it_keybag` | A | the prepare's own boots require their lines (`it_seal: halting`, the keybag done line) | boot inside the prepare | fails | (unchanged) |

Survey of the catalog (2026-09-29, `create --stop-after volumes` on every cached IPSW, against the same run of the
pre-fit-check pipeline): no build that got through the volumes step before fails now. What the checks found:
5.x (9A334, 9A405, 9A5288d, 9B176, 9B206): MobileStorageMounter names neither notice key, so `it_msmquiet` had nothing
to hide and is now left out; 2.x and 3.0 iPod kernels (5F138, 5G77a, 5H11a, 7A341) have no `cs_enforcement_disable`
boot-arg (only the `_cs_enforcement_disable` global), so the arg is inert there (their guest code runs on
`amfi_allow_any_signature` alone); the iPod helpers do not load on 2.x/3.0 (as before, now proven). AppSync
(2026-09-30, the 40 appsync-on entries, against the same run without the check): the 37 that got through the volumes
step still do, every one with libappsync fitting (installd on 3.0 to 4.3.5; on 2.x `mobile_installation_proxy`, whose
MobileInstallation framework makes the libmis and Security calls, with `appsync-launch` fitting too); the three 4.3
betas (8F5148b, 8F5153d, 8F5166b) stop before it as before (no k48dev iBSS in those IPSWs). 5.1.1's installd passes the
same check (FitCheck, 9B206), so AppSync being off on 5.x is not something installd's shape shows. Not covered yet:
the GL engines
and gld plugin (the GL work), activation (Sam's), the iPod's Sounds defaults (keys not proven), and the Python imgtools
mirror (unchanged).

## Ranked: what to make faithful, and what it buys

| # | Item | Class today | Scope and gate | What it removes |
|---|---|---|---|---|
| 1 | ~~Run the IOP firmware (second ARM7 core, real mailbox/VIC/timer, H2FMI program/erase/ECC, SDHCI under it)~~ done 2026-09-29 (qemu-ios `iop-core`, `iop-core-2`; default on) | R | – | The v1/v2/vN ABI bets on every NAND and SDIO byte; 4.3.5 and 5.1.1 need no IOP table |
| 2 | NAND and NOR from a stock USB restore instead of the offline writers | P (pipeline) | Make the existing restore path the pipeline's (`restore-smoke --erase` passes on the IOP core too); gate: fresh-device on every entry from a restore | All FTL/VFL/LwVM format knowledge; the keybag one-shot; the img3 kernelcache install; the `it_seal` boot |
| 3 | GLI shim reads the dispatch @encode at load | P | done 2026-09-28 (C1, qemu-ios `gl-runtime`) | Per-build TSVs, `GLEngine-<BUILD>`, `gli_dispatch` in the catalog, FAMILIES by build; superseded by the public-API front end (`gles-public`), no GLI shim left |
| 4 | USB_CTL + cable-type host/device switching | R+P | USB_CTL registers + the cable-type host/device switch; gate: 4.2.1's USB keyboard without `enable-hsic` or the DT edit | `enable-hsic`, the DT edit; matches 4.3+'s `publish-criteria` gate |
| 5 | PMGR clock tree | S | K48 #9; unknown: the PLL/divider encoding | The reconstructed table; 4.3+ reads new pmgr props (`voltage-states0`, performance domains) |
| 6 | Display pipe: all layers/modes, CLCD-derived VBL | H/S | K48 #24 (all layers and modes) + #25 (refresh from timing); unknown: which modes 4.3+/5.x program | The UI0/UI1-only assumption (4.x already needed the rectangle fix) |
| 7 | D1815 PMU | H | K48 #15 (power-down/resume through the ROM, all ADC channels, regulators); gate: 4.x and 5.x halts and sleep without shortcuts | Sleep/resume shortcuts |
| 8 | Delete inert code (`it-hle`, `HOST_GMT_SECONDS`, banner table, `IT_*` env) | P/S | Fixed-address TCG libc substitutions retired and default regression passes; audit the remaining items separately | Confusion and guest-address interception |
| 9 | BCM4329/4325 protocol coverage per driver generation (still H) | H | One protocol pass per driver generation; unknown: the iovars each generation adds | AppleBCMWLAN 2.60 vs AppleBCMWLANCore (5.x: firmware from `/usr/share/firmware/wifi/4329b1/duo.bin`, new iovars) |
| 10 | Multitouch: answer from the downloaded firmware's own tables rather than `mt_profile_k48` | H | Answer from the downloaded firmware's own tables | Per-board profile tables; still not R |
| 11 | SGX535 GPU (docs/research/sgx535-feasibility.md §3; first milestone the MMU walk, K48 #54) | absent | Six phases: registers + MMU, driver init, USSE1 interpreter, TA/ISP, fragment/texture, host shader translation; go/no-go: decoding the undocumented USSE1 encoding | The GL shim, gld plugin, dyld override, SpringBoard env, `amfi_allow_any_signature`/`cs_enforcement_disable` (once no other injected code remains) |
| 12 | MBX Lite GPU (N72) | S | TA/ISP/TSP and the 2D engine (N72 #49); go/no-go: decoding the undocumented TA/3D command format | Same for the iPod |

Rows 11-12 are the honest answer to "boots any iOS unchanged": without a GPU model every iOS build
needs an injected GL shim and the two AMFI boot-args, so the guest is never unmodified. Everything
above them is bounded work.

## What the iOS 5 spike said (2026-09-28)

Full evidence: qemu-ios `docs/ipad1/ios5.md` (branch `ios5-spike`). iOS 5.1.1 (9B206) and 4.3.5
(8L1) were booted on the three paths; each stop named a ledger row.

| Order met | Blocker | Row | Class | Verdict |
|---|---|---|---|---|
| 1 | kboot's boot_args.Version (4.3+ kernels demand 3) | synthesised state, kboot | P | fixed generically on the branch (read off the kernel); the R path (real iBoot) never had it |
| 2 | IOP mailbox config block v3 (EmbeddedIOP-20 in 4.3, -33 in 5.x): "IOP: startup ping failed" | K48 #33 | H | the first hard stop on **both** 4.3.5 and 5.1.1; raise to R (run the ARM7 firmware on a second core) or add a third HLE table (stays H); raised to R since (ranked #1) |
| 3 | iBoot-1219/1072 security epoch 2 vs the fixed `POWER_ID` (epoch 1): "miu_init: Epoch Mismatch" reset loop | K48 #9 (PMGR/POWER_ID), boot path `iboot=` | S + P | the `iboot=` path skips LLB, which writes the epoch on hardware; the ROM path accepts LLB-1219 under development fuses and is the R answer |
| 4 | D1815 power-off/reset registers ignored (LLB-1219 and iBoot-1219 both end there) | K48 #15 | H | PMU sequencing |
| 5 | I2C controller +0x14, blocks 0xbfc00000/0xbfe00000, 0x89e0/0x89f0xxxx | K48 #14, #60 | R gap / S | small: one register contract each |
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

### Legacy helper qualification (2026-10-01)

Guest package serial 13 / 1.1.11 now uses the existing legacy linker for one
armv6 helper set across 2.x–4.x. Stock 2.x's older SpringBoard launch API is
selected by export presence; injected it_typein is signed by its recipe and
unsigned package hooks are refused. Fresh 2.1.1, 3.0, 3.1.3 and 4.2.1 native
tests pass **18/18 each**, including actual installed-app foreground identity,
file/app persistence across cold reboot, generated serial/UDID/radio addresses,
automatic activation, Home and guest-confirmed power-off on both boots.
The test runner exposes `--single ... --launch --reboot` and judges those gates.
Evidence: `/private/tmp/ltm-n72-{211,30,421}-legacy13-signed-session` and
`/private/tmp/ltm-n72-313-legacy13-session`. The iPad's armv7 helpers are unchanged.
This closes the absent 2.x/3.0 core-helper seam; typing, clipboard, download
placeholders and media still require older-firmware API proofs. Developer SSH/SFTP
is now qualified on all four iPod builds through a shared legacy Bash payload.

### Radio identity and network presence (2026-10-01)

The candidate removes the iBoot Bluetooth UART-path rewrite. With the modeled
BCM4325 vendor CIS/OTP and HCI identity, native 2.1.1, 3.0, 3.1.3 and 4.2.1
lifecycle gates pass 18/18 each on two cold boots without changing iBoot bytes.
The follow-up network-disabled run exposed that `wifi=off` removed the soldered
combo chip. Chip enumeration and OTP identity now remain present independently
of the optional host data bridge. This does not turn the dongle firmware HLE
into a real microcontroller or remove the command-line provisioning boundary.

The network-disabled identity/snapshot controls now pass 2.1.1, 3.0, 3.1.3 and
4.2.1 before and after resume. The default eight-check 7E18 tier also passes.
QEMU candidate: `cbf1000344`; evidence and residual contracts are recorded in
[remaining work](remaining-work-2026-09-30.md).

### Real-ROM N72 DFU identity

Stock SecureROM enumerates DFU through the existing emulator-only USB bridge;
unaltered 5F138 iBSS uploads and re-enumerates in recovery. QEMU `ae75469472`
adds read-only chip-ID fuse inputs so ROM/iBSS ECID is a hardware read instead
of hard-coded zero. Stock idevicerestore selects the configured identity; its
next stop on 2.1.1 is host firmware suitability validation. Eleven model suites
and the default eight-check iPod tier pass. Automatic N72 ECID provisioning,
iBEC/ramdisk/physical restore and cold stock GPU remain unqualified.

### N72 unit ECID provisioning, 2026-10-01

New N72 identities now include the existing seed-derived ECID; their machine
lock passes it to immutable CHIPID fuses. Legacy bases recover that same value
from their stored seed at the boot-recipe boundary without modifying the base,
serial/MAC/UDID, or N45 identity. Explicit machine ECID overrides win. QEMU pin
53e722ae63 carries the model and reusable stock SecureROM/iBSS identity test.
Swift identity tests (11) and the compiled production BootRecipe check pass;
CHIPID qtests pass 3/3 and default native 7E18 regression passes 8/8.

Stock 5F138 SecureROM and unmodified iBSS report the same unit ECID
`0x98e452f953`. This test uses a private all-FF NOR and NAND overlay and allows
USB reinitialization to settle. Tight descriptor polling reproduces a return
to DFU; its cause remains a transport/controller research lead. A private
host-only legacy Restore.plist compatibility experiment reached iBSS and
uploaded the ramdisk, then failed before DeviceTree upload. Full stock restore
and removal of generated FTL relocation remain open. Existing restored K48
cold-boot and graphics limitations are unchanged. A private universal bundle from app bb5e6e2 / QEMU 53e722ae63 passed
18/18 on a native 2.1.1 session, including foreground launch, persistence and
cold reboot. These results do not qualify later source changes.

The traced restore-ramdisk failure was an explicit fatal unknown GID KBAG
(`d39f8a35...1ea87bd`), not simply an unexplained USB loss. N72 key export
omitted restore components. Adding the catalog Update/Restore ramdisk keys on
a disposable clone lets the existing idevicerestore upload ramdisk, DeviceTree,
and kernel without that fatal error. Final boot still returns to DFU; no stock
restore completion or physical NAND replacement is claimed. N72 preparation
now exports available keys for all resolved normal/restore components, with a
production archive/component test covering both ramdisks. No firmware patch
or permissive unknown-key fallback was added.

### Complete restore crypto transfers (2026-10-01)

QEMU `d2fb06759a` removes the 16 MiB AES register clamp while bounding host
scratch storage to 64 KiB. Stock 5F138 iBSS decrypts its complete 25,313,280-byte
update ramdisk byte-for-byte against the catalog-key reference. The old
`Process 1 exec of /sbin/launchd failed, errno 8` panic was encrypted data left
in the ramdisk tail, not a missing RAM region or a guest executable patch.
Sanitized production-handler tests and the default native 7E18 8/8 regression
pass independently for this correction.

QEMU `31036cf8e9` fixes the same transfer-length issue in SHA DMA with bounded
buffers, raw block chaining, and unchanged guest-owned padding. A new test
reproduced the old register clamp and then compared the complete digest with
hashlib; interrupt and snapshot-state tests pass. Its separate default native
7E18 regression also passes 8/8. The app pins that verified QEMU revision.

An unmodified stock 5F138 restore ramdisk now runs `launchd` and two
`restored_update` processes after 60 seconds, without watchdog suppression.
Process presence alone was not a restore protocol success. The initial kernel USB trace waited
with RESET/ENUMDONE interrupts enabled while the retained recovery connection
receives descriptor NAKs. Actual host bus reset/re-enumeration was subsequently verified (below);
no fabricated descriptor, forced guest completion, or production delay was
added. Rapid post-DFU polling separately reproduces a SecureROM abort/reset.
Physical N72 formatting, full restore, encrypted restored cold boot and removal
of generated-store FTL relocation remain open.

Before these crypto changes, the clean universal app ec3cdeb / QEMU 53e722
candidate also passed native 3.1.3 lifecycle gates 18/18. Its complete Mach-O
closure and ad hoc signature checks pass for the declared macOS 14.4 minimum.
Those packaging results do not qualify the subsequent crypto revision.
Evidence: `/private/tmp/ltm-aes-restore-default`,
`/private/tmp/ltm-sha1-restore-default`,
`/private/tmp/ltm-n72-ramdisk-aes-fixed/ramdisk-comparison.json`, and
`/private/tmp/ltm-n72-kernel-processes/processes.json`.

### Stock N72 restore transport and legacy client reuse (2026-10-01)

QEMU `5d1e9dfd9c` re-enumerates the actual guest USB address reset and separates
descriptor discovery from configuration selection. Kernel USB is handed to
usbmuxd under the request lock before selecting a recovery configuration;
five registered unit tests pass. A native stock erase ramdisk then reaches
com.apple.mobile.restored protocol 11 and starts the erase protocol. It
repeatedly reports "Waiting for NAND (28)" on disposable empty page directories
with FMSS_PHYSICAL and FMSS_ERASE enabled. The session was stopped and is
recorded as a failure, not a full restore or physical NAND qualification.

Reuse LukeZGD's idevicerestore compatibility behavior rather than fabricating
an ECID response in old restored. Its upstream `9e6eacc788d532b887b9b0883477d6b89c5a2841`
already handles the real pre-iOS 3 HardwareInfo response without UniqueChipID.
The private client branch adds `26314aa`, an actual legacy ProductType lifetime
fix reproduced with ASan and verified with ASan/UBSan. With original stock
firmware metadata, the boot-only probe exits successfully in restore mode;
the earlier SupportedProductTypes metadata copy is unnecessary. The client
has not been installed or incorporated into a release dependency receipt.

A diagnostic-only DFU manifest settling interval remains in these probes.
A subsequent trace still reproduced the reconnect race; unattended DFU,
physical erased bytes/erase commands, flash formatting, restored cold boot and
durable subsequent writes remain open. Preserve the generated-store path
until those deletion gates pass. No new production delay or guest patch.

Durable evidence: `/Users/shg/Developer/ltm-evidence/restore-usb-2026-10-01`.
The clean universal app cc67737 / QEMU 31036cf8e9 / USB e19fac2 candidate also
passes actual native 2.1.1 session 18/18, both Mach-O architecture closures at
minimum macOS 14.4, and ad hoc signature verification. Those are packaging
and native arm64 results, not Intel-runtime or notarization qualification.
Its evidence: `/Users/shg/Developer/ltm-evidence/restore-crypto-2026-10-01`.

### FMSS D4C and actual restore arguments (2026-10-01)

QEMU ace95b664b latches the real CPU-supplied D4C sequencer parameter, including
MMIO readback, reset and FMSS VMState6/older-stream initialization. Real FMSS
qtests 4/4, sanitized handler/script tests, and a separate default native
7E18 two-boot 8/8 pass. No restore completion is implied. The subsequent
native stock trace advances from D4C to the unsupported D18 read at +0x68.

Actual kernel PE_boot_args readout is
`rd=md0 nand-enable-reformat=1 -progress `. The stock formatting option is
already present in this probe; the legacy client's build-major argument
policy is not the measured blocker and was not changed. D18/D28 register and
descriptor-load execution, actual erase and honest sequencer failure remain.
Durable D4C evidence: `/Users/shg/Developer/ltm-evidence/fmss-d4c-2026-10-01`.
BootArgs/next divergence: `/private/tmp/ltm-n72-d4c-stock-bootargs-trace`.

Host b5e9af2 independently extracts package qualification into a boot owner;
actual app build and owner cancellation/verdict/oracle tests pass. Further
GUI/CLI runtime module separation remains open. See
architecture-followup-2026-10-01.md for MBX source/capture/replay scope.

### Verified USB PHY reset boundary (2026-10-01)

QEMU a2cc232364 gates physical traffic on ORSTCON bit 0 for N45/N72. The
stock ROM had asserted reset and freed its USB queue while the model still
injected SETUP DMA/interrupts, causing a data abort. Core registers and
latched IRQs remain intact, and migration redrives the PHY signal. No guest
patch or firmware-specific delay is used. Model qtests pass 3/3, rapid stock
5F138 handoffs 3/3, native 5F138 boot/USB 2/2, and the separate default 7E18
two-boot regression 8/8. The baseline binary fails the new reset gate.

Stock SecureROM through the restore ramdisk now passes with the production
bridge and no diagnostic settling wrapper. Descriptor polling keeps its
one-second deadline (f4226be0ff); the preceding timeout failure is retained.
This supersedes the earlier rapid-DFU research blocker for these measured
trials, not the unresolved physical flash restore. N45 native boot passes,
but native host USB is unsupported by that harness. N45 whole-board
migration exposes a separate inactive I2S host voice-rate validation bug;
K48 is not wired to this PHY signal.

Evidence: `/Users/shg/Developer/ltm-evidence/usb-phy-2026-10-01`. The app's
source pin now includes this verified QEMU correction; no new universal
package qualification, target merge or installation is claimed.

### Verified FMSS request parameters (2026-10-01)

QEMU 333bc8023c adds sequencer access to the existing D18 request-count latch
and models D28 as the guest-supplied count of 2048-byte page chunks. No fixed
count, descriptor-load or erase behavior is invented. Reset and VMState7
preserve D28; older supported streams initialize it to zero. Sanitized actual
handler/script tests, real FMSS qtests 4/4 and the separate default native
7E18 two-boot regression 8/8 pass, including filesystem health and persistence.
Evidence: `/Users/shg/Developer/ltm-evidence/fmss-parameters-2026-10-01`.

Stock bulk scripts still encounter opcode06 before descriptor opcode03;
read/status scripts encounter opcode03. These and real physical erase are
unqualified. The source pin advances to the verified parameter correction;
the earlier universal package does not include it.

The subsequent actual stock erase trace uses the production USB bridge with
no diagnostic settling wrapper. It connects to restored version11 and is
stopped after repeated Waiting for NAND. The bulk script's next measured
divergence is opcode06 `06040003 00000000` at +0x78; its semantics remain
unimplemented. Owned subprocesses are reaped. Text/trace evidence is retained
in the fmss-parameters-2026-10-01 directory above; this is not restore success.

### Silent I2S migration correction (2026-10-01)

QEMU 0ceac9c55e corrects the N45 silent-sink rate initialization and accepts
legacy zero host voice rate only without a realized/active host voice, after
all stream/ring/queued PCM/rate/pacing/FIFO validations pass. Guest TX/DMA
activity is valid in silent streams; it does not justify rejecting them.
The permanent whole-board PHY model suite passes 4/4 including N45 migration,
whose baseline failed in I2S. Actual audio sanitizer/alignment tests and the
separate default 7E18 native two-boot regression 8/8 pass.

Evidence: `/Users/shg/Developer/ltm-evidence/i2s-silent-2026-10-01`. This is
silent-stream migration bookkeeping, not N45 native guest suspend/wake,
in-flight USB snapshot qualification or a new packaged candidate. The app
source pin includes the verified fix; targets remain unmerged.

### Observed FMSS register copy (2026-10-01)

QEMU c49f3cdae4 implements the stock immediate-zero opcode06 register-copy
form; unknown forms remain unsupported. The actual-handler baseline fails
the copy assertion; sanitizer fixtures, real FMSS qtests 5/5 and the separate
default 7E18 native two-boot regression 8/8 pass. Actual target8720 dataflow
corroborates [related hardware-tested8702 research](https://github.com/lemonjesus/S5L8702-FMISS-Tools/blob/70b45859af8807a7f841cf649564ce6638e1c112/Documentation.md);
no reference implementation or documentation text was copied into production.

The subsequent actual stock erase trace reaches opcode03
`03010000 00000000` at +0x88, still waits for NAND and is intentionally stopped.
No descriptor DMA, arithmetic, physical erase or completion qualification
follows from the register-copy correction. Durable evidence:
`/Users/shg/Developer/ltm-evidence/fmss-opcode06-2026-10-01`. Source pin advances
to this verified correction; no new packaged candidate or target merge.

### Stock FMSS descriptor DMA (2026-10-01)

QEMU 089b055d73 supports observed opcode03 immediate-zero little-endian32
descriptor loads using QEMU guest memory transactions. Unsupported forms and
failed transactions stop before fabricated data or later stores. Actual-handler
sanitizer tests, real FMSS qtests6/6 and the separate default native7E18
two-boot regression8/8 pass. Full stock erase trace now reaches opcode0A
`0a000004 00000000` at +0xa8, still waits for NAND and is intentionally stopped.
No arithmetic, completion or physical erase qualification follows. Evidence:
`/Users/shg/Developer/ltm-evidence/fmss-opcode03-2026-10-01`. Source pin advances
to verified descriptor support; targets remain unmerged and package unchanged.

Shared prepared boot assembly now lives in Packages/HostRuntime and is imported
by GUI and session driver. Ten package tests, actual app/helper/services builds,
real helper preparation-failure cleanup and native prepared N72 startup/AFC
checks pass. Broader service/process reuse, managed boot-path authority and
malformed lock typing remain. Details and evidence: architecture-followup-2026-10-01.md
and `/Users/shg/Developer/ltm-evidence/host-runtime-2026-10-01`.

### October 1: stock sequencer mask intersection

QEMU 0fb13887b1 adds the observed opcode0A register/immediate AND forms,
corroborated by actual stock5F138 script dataflow. The preceding model fails
the sanitizer overlap test; actual-handler sanitizers, real FMSS qtests7/7
and independent default7E18 native two-boot8/8 pass. Evidence:
`/Users/shg/Developer/ltm-evidence/fmss-opcode0a-2026-10-01`.
Other arithmetic, physical storage, erase and aborted-script completion remain
separate contracts. The production-bridge stock5F138 erase trace now stops at opcode14
`14000001 00000010` at +0x128, after eight Waiting for NAND responses.
The research harness stops/reaps its own children; no full physical
restore/coldboot qualification follows from this correction.

### October 1: physical erased reads and maintained persistence gates

QEMU 8b3856af65 gives confirmed physical holes and erased markers exact FF
bytes, preserving generated storage and invalid/truncated/I/O-error fallbacks.
The packed parser distinguishes holes from invalid records. Stored spare
remains a 64-byte projection with 12 guest-visible bytes; raw OOB/ECC is
not qualified. Actual-source sanitizer behavioral baseline fails, fixed gates
pass, real FMSS qtests12/12 and independent default native8/8 pass. Persistence
fixture declarations now match the existing GTree caches: all 18 fault cases
and the 1,024-page bulk write pass.

Stock physical erase remains at opcode14/imm16+0x128 with eight Waiting for
NAND responses. The research harness stops/reaps its own children. Experimental
MMIO capture cannot expose unimplemented pointer-register readbacks; those
zeros are not parameter-state evidence. No stock restore/coldboot pass follows.
Evidence: `/Users/shg/Developer/ltm-evidence/fmss-physical-blank-2026-10-01`.

Further storage gaps: payloads are controller DMA bytes, not proven raw flash;
bitwise programming cannot be added blindly. First/repeated writes still infer
block erases, stock FMC erase commands do not execute against the backend, and
aborted sequencer runs still receive deferred completion. Directory fsync and
full command/error/timing contracts remain distinct from erased-read fidelity.
