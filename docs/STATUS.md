# Project status

The one place that says what is done, what is running and what is left. Updated at every merge into
`multidevice` (this repo) or `ipad1` (qemu-ios). Every "done" line names how it was checked. Answer
status questions from this file, after checking it against the commits it cites.

Last update: 2026-09-28, multidevice storage-fixes merge, qemu-ios ipad1 `821f1b5428`.

## Done

| Area | State | Checked by |
|---|---|---|
| iPad 1 emulation (A4, real iBoot chain, NAND, GL, touch, USB) | Boots iOS 3.2, 3.2.2, 4.2.1 to the home screen with GPU drawing; 49-app compatibility pass. **Gap closed 09-28 (`fk-k48-iboot`):** FirmwareKit's k48 recipe now defaults to the `iboot` strategy (SecureROM→LLB→iBoot→kernel), producing `iBoot.bin`, `nor.bin` and `gid-blobs.bin` byte-equal to the Python pipeline (`K48IBootTests`, 7B500 + 8C148); app-prepared iPads boot the real chain from the lock's `boot_strategy`, with `boot: kboot` kept for debugging and the two existing kboot records still booting. | `Packages/FirmwareKit swift test` (61/61 incl. `K48IBootTests`); iboot boot to userland verified (serial: iBoot banner + fsboot kernelcache load); kboot boot still reaches userland |
| iPad Wi-Fi | Works, on by default, stock driver (BCM4329 model); location answered by the proxy | qemu-ios `docs/ipad1/wifi.md`, `location.md`; soak on 2026-09-27 |
| iPad hardware keyboard | USB keyboard through the CCK path; Bluetooth dropped 2026-09-26 | `docs/ipad1/usb-keyboard.md` |
| iPad restore over emulated USB | Stock idevicerestore: SecureROM → DFU → recovery → restore | `tests/ipad1/restore-smoke.py` (2026-09-28) |
| iPod touch 2G emulation | iOS 3.1.3 and 4.2.1 to the home screen with GPU; 2.1.1 to the home screen once the host sets the clock | `tests/ipod/regress.py` 8/8 (3.1.3 with `--stage-gles-shim`, 4.2.1 boot+gles) |
| Reproducible from a stock IPSW | Both boards, every listed build, from the IPSW plus a manifest; no hand-prepared NANDs | Python `imgtools/device.py`; Swift `firmwarekit` byte-matched against it |
| Swift pipeline (FirmwareKit) | Full port; the app runs only `firmwarekit`, no Python | `swift test` 60/60; `check-firmware-jobs.py` |
| Activation | Built-in preparation step calling Sam's tool; 2.1.1 included | multidevice `a47d719`, `56598a3` (activation UX is Sam's) |
| Multi-device app | Sidebar, one helper process per device, IPSW download/import, catalog with keys, legacy adoption | notarized build `ipod4-20260928`, in-app prepare+boot+install on all four firmwares |
| Guest-package bootstrap | Loader + versioned packages + rollback, in the emulator, preparer and app | `tests/check-sessions.py --guest` (iPod, headless) |
| Guest tools without SSH | Typed agent v2 ops replace SSH, OpenSSH, OpenSSL, freeze | `tests/ipod/regress.py` (no `guest_ssh`) |
| USB zero-length packets | Sent by usbmuxd (`qemu-zlp`, pinned `41631a7`), not faked by the emulator | AFC 16384/16385/65536 round trips in the release verify |
| Offline root-FS read (F1) | `firmwarekit mount/export` for both boards, oracle-checked | `docs/filesystem-f0-findings.md` U1 table |
| iPad app bugs (09-28) | 4.x keyboard (`enable-hsic`, usb-kbd max-power), guest-package report read on every boot, iPad readiness pipeline (boot progress, ready notice, proxy apply), it_agent on k48 via package serial 2 (foreground app in the title bar), A008 alpha surfaces for CA shadows, Stop = flush + hard halt (helper exits in ~0.04 s) | check-sessions 18/18 on 7B500 and 8C148 with `--ipad-itpack`; check-helper-boot 22/22; KBootTests byte-equal to Python; regress `shadow` check |
| USB "not supported" alert gone on both iPad versions (Sam's call: an Apple bug that also blocked manual lock) | `it_msmquiet.dylib` in the mounter's own job interposes the notice, matched on the mounter's localized strings at runtime; one armv7 binary for 3.2.x (DisplayNotice) and 4.2.1 (Create + Cancel); guest package serial 3 | qemu-ios regress boot on 7B500, 8C148 (upgrade path), 7E18: no alert; Hold locks the panel in 5 s (was: stayed lit) |
| Storage fixes from the audit | App and device locks, atomic delete/publish, launch sweeps, TM exclusions, disk checks, Settings ▸ Storage | `221ef9a`; check-sessions 17/17, check-helper-boot lease 6/6, offline checks |
| Silent headless boots | `-audio driver=none` everywhere headless | grep of tests and helper modes |

## Catalog (LightTouchMac/Resources/firmware-catalog.json)

| Entry | Status | Note |
|---|---|---|
| iPod 3.1.3 (7E18) | user IPSW | also the bundled image |
| iPod 4.2.1 (8C148) | experimental | added 2026-09-28 |
| iPod 2.1.1 (5F138) | coming soon | emulator done; needs the N72 recipe path, keys, in-app check |
| iPad 3.2.2 (7B500) | available | |
| iPad 3.2 (7B367) | available | |
| iPad 4.2.1 (8C148) | experimental | keyboard fixed 09-28; devices prepared before need re-preparing |

## Running now (2026-09-28)

| Work | Branch | Covers |
|---|---|---|

| GL bridge rejection audit | qemu-ios `gl-coverage` | every reject/unimplemented path counted + logged, magenta fallback under `gles-debug`, produced-vs-rejected list from the firmwares' own frameworks, cheap formats implemented |
| Real-iBoot boot chain in FirmwareKit | `fk-k48-iboot` | app-prepared iPads boot SecureROM→LLB→iBoot→kernel like the Python-built ones |
| Consolidation sweep | docs/sweep/PLAN.md | surveys done (docs/sweep/*.md); Track A (app correctness: activation check, boot deadline, per-device install queue, device-file protection, guest-tools status line) on `app-correctness`; B–E sequenced in the plan; decisions S1–S6 with Sam |

Then: a notarized build, verified in-app on every firmware, for Sam to test. That build is the first
in-app run of the 2.1.1 clock fix (`c2832d5`) and the first-run tip fix (`1e71588`).

## Left

### Firmware coverage
- iPod 2.1.1 in the app: N72 recipe for 2.x (legacy-linked loader), catalog keys, in-app check.
- More point releases (2.2.1, 3.0, 3.1.x, 4.0–4.1): each needs a manifest, catalog keys and a check. Designed to be routine; none tried.
- iPad iOS 5: not started ("later").
- Two per-build kernel banners remain in `hw/arm/ipod_touch_firmware.c` (5F138, 7E18).

### Features
- Root-FS edit from the Mac: Mount/Export UI with lease and guards (~2 d), then write-back (F2, ~7–10 d). Live Finder volume deferred (guest daemon, 3+ weeks).
- Live storage snapshot of a running device (F4, ~2 d).
- Guest-package updates: test against the new fixes; decide how iPads prepared before the loader get updated (today: frozen tools, said in the UI).
- Finder native device recognition: deferred, needs Apple's USB host-controller entitlement (don't raise unless Sam does).

### Debts
- Real iBoot chain for app-prepared iPads: **done** on `fk-k48-iboot` (see Done table). Remaining: the iboot strategy's NAND store isn't yet byte-equal to Python's end-to-end (HFS timestamps/volume UUID, the pre-existing store non-determinism), so the NAND comparison is by structure/boot, not by hash; the full in-bundle `firmwarekit create` (needs a signed k48 guest-tools dir) was not run this session — the byte-equal artifacts + a real iBoot boot were verified instead.
- Survey reports live in docs/sweep/.
- `tests/ipod/test_regress.py`: one test's mock lacks `guest_package_status`.
- Bundled iPod image carries the old GL shim; regenerate at the main merge.
- Two checks flake under heavy load (one iPad boot hang, one audio correlation); pass on retry.
- Tip fix not yet confirmed on an app-prepared iPad.
- ~45 worktrees under ~/Developer and /tmp from finished agents; prune the merged ones.

### Sam's calls
- Activation UX.
- Merge into `main`; at that moment swap the bundled iPod image and push a scrubbed `ipad1`.
- Post the drafted replies to GitHub #12 and #15.
