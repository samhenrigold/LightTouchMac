# Fidelity ledger + iOS 5 spike report (2026-09-28)

## Deliverables

- **Ledger**: `/Users/shg/Developer/LightTouchMac-fidelity-ledger/docs/fidelity-ledger.md`, branch `fidelity-ledger` off `multidevice`, commit `d69033c`.
- **Spike**: `/Users/shg/Developer/qemu-ios-ios5-spike`, branch `ios5-spike` off `ipad1` (082b45e77d), commit `45f9c77d1b`: `docs/ipad1/ios5.md` (+ README index row), `manifests/ipad1-9B206.json`, and three generic fixes (below). Not merged anywhere.
- Scratch kept (2.1 GB, outside repos): `~/Developer/qemu-ios-files/ios5-spike/` — the 9B206/9A405/8L1 IPSWs (sha1-verified), rendered key files, decrypted components (rootfs dmgs deleted), DT diffs, `gli-dispatch-9B206.tsv`, extracted IOP firmware images, and the small drivers (`boot9.py` headless boot + QMP dumps, `kcdis.py`/`ibdis.py` capstone disassembly, `dtdiff.py`, `kcinfo.py`, `iopfw.py`). Boot clones, mounts and the 9B206 device build were deleted; 421 GB free.

## Part 1: ledger summary (per class)

| Board | R | H | P | S | rows |
|---|---|---|---|---|---|
| K48 iPad 1 | 24 | 10 | 6 | 20 | 60 |
| N72 iPod touch 2G | 20 | 6 | 8 | 22 | 56 |
| Guest side (boot-args 8, injected components/image edits 29, synthesised state 5) | 0 | 0 | 42 | 0 | 42 |

Every row has file:line, a one-line justification and the faithful version's cost. The GPU is stated plainly: no SGX535 (K48) or MBX (N72) model; GL exists only via the guest GLEngine/MBXGLEngine shim + host bridge, which is also what keeps `amfi_allow_any_signature`/`cs_enforcement_disable` in every boot. Each boot-arg is listed with what it bypasses. Per-build assumptions from `docs/sweep/emulator.md (b)` are carried with the spike's verdict on each.

Two discrepancies the guest-side inventory turned up (not fixed): the 4.2.1 iPad AppSync option is `false` in `manifests/ipad1-8C148.json` but `true` in the app catalog; and only the kboot path sets `arm-io/sgx compatible=none` — the default `iboot=` path leaves the stock SGX node (IMGSGX535 lands in the unimplemented window).

## Part 2: iOS 5 (and 4.3.5) — predicted vs actual, how far it got

Static first (all in `ios5.md`): 8L1 = xnu-1735/iBoot-1072, 9B206 = xnu-1878/iBoot-1219. Key deltas: **security epoch SEPO 1→2 at 4.3.5**; **boot_args.Version 2→3 at 4.3**; **IOP framework EmbeddedIOP-20.4 (4.3) / 33.x (5.x) with a new config-block layout**; `enable-hsic`/`hsic-enabled` gone from 4.3 (`publish-criteria`); 5.x adds `wdt` node, `use-lwvm` + LightweightVolumeManager (MBR still present; fstab unchanged), `AppleBCMWLANCore` with firmware from `/usr/share/firmware/wifi/4329b1/duo.bin`, `*-1,samsung` compatibles, 905 GLI slots (first 772 identical to 8C148; derivable). iBoot32Patcher handles 1072 and 1219. The keybag one-shot recipe still applies (rc.boot execs the same names; restored still does format_effaceable + MKBKeyBagCreateSystem).

| # | Component (ledger class) | Predicted | Actual |
|---|---|---|---|
| 1 | kboot boot_args (P) | version per iBoot generation | Hit first on 8L1 and 9B206: `pe_identify_machine: Epoch Mismatch` (wants 3). **Fixed generically** (`boot_args_version()` reads the demanded value off the kernel). |
| 2 | IOP HLE `s5l8930_iop.c` (H) | new mailbox ABI | **Hit on both 4.3.5 and 5.1.1**: `IOP: startup ping failed` (EmbeddedIOP-20.4:221 / 33.4:210). Live dump shows the config block gained a version word at +0x4; ring table moved +0x0c→+0x10, so the HLE reads addresses as counts. Not fixed (a v3 table stays H). |
| 3 | real iBoot (`iboot=`, P) + PMGR POWER_ID (S) | NOR/PMGR issues | Hit: iBoot-1219 `miu_init: Epoch Mismatch` reset loop (POWER_ID epoch byte fixed at 1; LLB writes 2 on hardware, the `iboot=` path skips LLB). With a temporary epoch 2 (reverted) it reaches platform_init, writes unmodelled I2C +0x14, then the D1815 power-off sequence (0xe9/0xe0) and spins. |
| 4 | SecureROM path (`bootrom=`, development fuses) | signature rejection | Better than predicted: the ROM accepts and runs LLB-1219; LLB touches unmodelled 0xbfc00000/0xbfe00000, then the same PMU power-off path. |
| 5 | mkpkg FAMILIES by build (P) | no family | Hit; **fixed generically** (no family → stock volume, lock records null). |
| 6 | bake's on-disk GLEngine assumption (P) | – | Hit (unpredicted); **fixed** (cache-only GLEngine with no shim). |
| 7-11 | PMGR perf-domain props (S), `wdt` (S), CLCD/Pinot/DisplayPipe (H/S), USB PHY/EHCI (R) | various | All started fine on 5.1.1 (kboot path); `enable-hsic` confirmed a no-op on 4.3+. |
| 12-13 | Wi-Fi driver split (H), LwVM/NAND/data protection (H/P) | – | Not reached; behind #2. |

How far: kboot 5.1.1 and 4.3.5 both reach ~2400 serial lines — AMFI args, platform/PMGR, SDIO family, watchdog, PMU, SPI/UART, USB arbitrator, ARM7M firmware upload, CLCD/Pinot/DisplayPipe, "Waiting for root device", EHCI HSIC ports — then the IOP ping panic (~25 s). `iboot=`: iBoot-1219 panics in `miu_init` before the console reaches the UART. `bootrom=`: ROM→LLB-1219 runs, ends in the PMU power-off path. SpringBoard not reached on any path.

## Ranked "make it faithful" (from the ledger, confirmed by the spike)

1. Run the IOP ARM7 firmware on a second core (H→R), 20-30 d (+3-5 d H2FMI program/erase/ECC): the one component that gates every 4.3+ build (HLE v3 table would be 0.5-1 d but stays H).
2. NAND/NOR from a stock USB restore instead of the offline FTL/NOR writers (P→R), 1-2 d (path exists): removes FTL/LwVM/keybag knowledge.
3. GLI shim parses the dispatch @encode at load (P, per-build → generic), 2-3 d.
4. Security epoch: boot from the ROM so LLB sets POWER_ID (R), or a `security-epoch` property from the image's SEPO (generic, 0.5 d, stays P).
5. USB_CTL + cable-type host/device switching, 2-4 d.
6. PMGR clock tree (S→R), 5-8 d; D1815 PMU sequencing incl. power-off/reset (H→R), 5-10 d; I2C +0x14 and blocks 0xbfc00000/0xbfe00000, 0.5-3 d each.
7. Display pipe all layers/modes, 5-10 d. 8. Delete inert code (it-hle, HOST_GMT, banner table), 0-1 d.
9. SGX535 / MBX GPU models: 120+ d, undocumented — the only route to "unmodified guest".

## What 4.3.x already needs (for the matrix agent)

boot_args Version 3 on kboot (done); the IOP config-block v3 / EmbeddedIOP-20 ping (blocks the keybag one-shot and every boot); security epoch 2 for iBoot-1072 on the `iboot=` path; `enable-hsic`/`hsic-enabled` are dead (USB keyboard via `publish-criteria`/`hsic-ports`, re-verify `usb-kbd,max-power`); PMGR's new props are fine. Unknown behind the IOP: 4.3 NAND (`ppn-*` props), Wi-Fi deltas, GLI layout for 8L1 (rootfs not decrypted; ramdisk keys unpublished on ipsw.me).

## Gates run

`ipad1_kboot.py` and `ipad1_rootfs.py --selfcheck`, `mkpkg.py selfcheck`, `tests/guest-package/test_it_boot.py`: all pass; `boot_args_version` returns 2 for 7B500/8C148 kernels, 3 for 8L1/9A405/9B206. No prepared 3.x/4.2.1 device was rebuilt or booted under the change (a fresh-device run for 7B500/8C148 is the remaining gate before merging). Every boot used `-audio driver=none`, one emulator at a time; the temporary POWER_ID diagnostic edit was reverted (`git checkout`), not committed. Activation untouched.