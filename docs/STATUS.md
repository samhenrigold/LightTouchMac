# Project status

The one place that says what is done, what is running and what is left. Updated at every merge into
`multidevice` (this repo) or `ipad1` (qemu-ios). Every "done" line names how it was checked. Answer
status questions from this file, after checking it against the commits it cites.

Build for Sam: `multidevice-20260928c` (rebuilding; 20260928b's directory was deleted by mistake after its verify passed 11/11 on all five entries). 20260928b was (09ad91f + qemu-ios 082b45e77d, notarized adfbf096…, verified in-bundle 11/11 on all five entries; iPads on the real iBoot chain; typing on 4.2.1; package serial 3; no USB alert). Not in it: the DeviceLink.reap fix (a helper killed under load could go unnoticed), the bundled-iPod conversion, runtime GL.

Last update: 2026-09-28, `ipa-library` merged (IPA library; iBoot shipped; Track A), qemu-ios ipad1 `082b45e77d`.

## Done

| Area | State | Checked by |
|---|---|---|
| iPad 1 emulation (A4, real iBoot chain, NAND, GL, touch, USB) | Boots iOS 3.2, 3.2.2, 4.2.1 to the home screen with GPU drawing; 49-app compatibility pass. FirmwareKit's k48 recipe defaults to the `iboot` strategy (SecureROM→LLB→iBoot→kernel), producing `iBoot.bin`, `nor.bin` and `gid-blobs.bin` byte-equal to the Python pipeline; app-prepared iPads boot the real chain from the lock's `boot_strategy`, `boot: kboot` kept for debugging. | `K48IBootTests` (7B500 + 8C148 vs Python); the "real iBoot in the app" line below |
| Real iBoot in the app (09-28, `iboot-ship`) | The app ships its own `iBoot32Patcher` (`Contents/MacOS`, built by both native paths from the pinned LukeZGD fork `1ff9bd1`, GPL-3.0, in `build-support/dependencies.json`; license shipped), and FirmwareKit takes the bundled copy first. The bundled `firmwarekit create` (bundled helper, guest tools, patcher) prepares 7B500 and 8C148; the bundle boots them through the real chain, shuts down cleanly and boots again; the app-prepared 7B500 passes qemu-ios `restore-smoke.py`; a kboot-prepared record (a clone of the Python-made 8C148 one, `qemu-ios-files/ipad1/offline-activation-8C148/device`) still boots through the app's `kboot=` path (lit, lockdown, AFC; its IPA install fails with ApplicationVerificationFailed because that record predates AppSync, not because of the boot). The app's chain starts at the patched iBoot (`iboot=`): the serial log shows the NOR image table, the iBoot-817.29 / iBoot-931.71.16 banner and `Loading kernel cache`, no kboot; the SecureROM→DFU→recovery path is restore-smoke's. | `K48IBootTests.patcherMatchesReference` (bundled build vs the Legacy-iOS-Kit binary, byte-equal on 7B500/8C148/7B367); `swift test` 63/63; `check-sessions.py --single --board ipad` through the bundle: app-prepared 7B500 11/11 twice, app-prepared 8C148 11/11, kboot clone 8/11 (install, see left); `tests/ipad1/restore-smoke.py` on the app-prepared 7B500: PASS; `test-release.py` 21/21, `test-package.py` on the Developer-ID build, `test-signing.py` |
| Reproducible stores (09-28, `iboot-ship`) | The host mount no longer leaves run-to-run noise in the volumes (dates, macOS date-added, volume identifier, journal, B-tree slack: `HFSPlusVolume.normalize`, `VolumeMount.withMounted`). The lock's `outputs.nand.built_listing_sha256` (store as built, before the seal/keybag boots) is the golden-lock oracle; `listing_sha256` of a sealed k48 store still differs by design (the guest's first-boot writes). iPod 7E18: both hashes equal across runs. | `SystemEditsTests.volumesAreReproducible` (7B500, 8C148: volumes and store byte-equal twice); two bundled `create`s of 7B500 with equal `built_listing_sha256`, `iboot`, `nor`, `gid_blobs`; two `create`s of n72ap-7E18 with equal `listing_sha256` |
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
| One gate command per repo | qemu-ios `tests/gate.sh --quick|--full|--fresh`; app `scripts/gate.sh --quick|--full`; known failures listed as XFAIL with reasons | qemu-ios quick 73 PASS/26 SKIP/12 XFAIL, full: iPad 7/7, iPod 8/8 (staged shim); app quick 67 PASS/2 SKIP/5 XFAIL, full: check-sessions two-device 17/17, --guest 27/27, guest-package PASS, swift test 61/61; regress-app's env checks XFAIL (parse moved code) |
| Fidelity ledger | docs/fidelity-ledger.md: K48 24 R / 10 H / 6 P / 20 S; N72 20/6/8/22; 42 guest-side P items; faithful version + cost per row | qemu-ios docs/ipad1/ios5.md: iOS 4.3.5 and 5.1.1 both stop at the IOP HLE (config block v3, EmbeddedIOP-20/33); real iBoot-1219 stops at the security epoch (POWER_ID); SecureROM→LLB-1219 runs to the PMU power-off path |
| GL bridge refusals counted and painted | every reject path in shim and host counts (`gles-rejects`), magenta under `gles-debug`; 4444/1555/ARGB/ABGR/L008 surfaces, REV/float/half/depth texture types, anisotropy/max-level/LOD params, fixed-point + fence slots, CA surfaces to 4096 wide; produced-vs-refused list from the five firmwares' frameworks (docs/sweep/gl-coverage.md) | iPod 7E18 and iPad 7B500/8C148 boot+gles+shadow with zero refusals; app-compat 42/51 on 7B500: two counters (one app bug, one 2240-wide surface, fixed) |
| Storage fixes from the audit | App and device locks, atomic delete/publish, launch sweeps, TM exclusions, disk checks, Settings ▸ Storage | `221ef9a`; check-sessions 17/17, check-helper-boot lease 6/6, offline checks |
| Silent headless boots | `-audio driver=none` everywhere headless | grep of tests and helper modes |
| Track A: app correctness (`app-correctness`, 09-28) | A1 activation verified once per boot (persistent issue, notice with Erase, "Prepared without activation" row note); A2 boot deadline (lockdown within the board's budget) and iBoot recovery-mode detection end the session as a named error, helper halted; A3 per-device install queue (`InstallJob.deviceID`, `discard(for:)`, per-device pause/busy, filtered inspectors); A4 published bases `chflags uchg`, a watch on a running device's files with a persistent notice and Stop without a flush, Show in Finder per device; A5 install checks use the device's iOS version and slice; A6 "Guest tools" status line with concrete states; A7 keyboard input and auto-rotation per device (tiltSnap/modelPresentation were animation keys, not defaults); A8 usbmuxd polls 50 ms once idle for 1 s (fork branch `idle-poll`, 3 idle iPods 6.3% → 0.3% of a core; not pinned yet) | `check-activation-gate` 8/8 (7E18-a), `check-boot-deadline` 3/3 (8C148-b, marker in 1.3 s), `check-install-queue-scope`, `check-device-files`, `check-helper-boot --only meddle` 6/6, `check-sessions --ipad-device` (see the merge note), the offline checks listed in PLAN.md |
| Quit-with-resume snapshots removed (S3) | The unreachable app-side save/restore code is gone; the helper's snapshot ops, the guest-tools restarts and Erase's sweep of stale snapshot files stay | app, helper and firmwarekit build; `check-clean-shutdown`, `check-termination`, `check-preparation-wake`, `tests/device-state-storage.swift`, `check-helper-boot` restore case unchanged |
| C6: the built-in iPod is a prepared device (`bundled-prepared`, 09-28) | The shipped iPod is a `firmwarekit create` of n72ap-7E18 packed as one blob (`Resources/device/n72ap-7E18.itbase`, `scripts/pack-base.py`, made by the release build from the built firmwarekit and guest tools), unpacked into `Preparing/<id>/` at first launch and published as a `.prepared` device like any other; the catalog entry keeps `user_ipsw` (Prepare / Import IPSW after a Delete). Every legacy path is gone: `LegacyAdoption`, `LaunchOptions`, `legacyBundled`/`development` bases, the packed-image pointer and `nandrw-<key>` code, the state/log migrations, the raw-image boots, `session.env`, the legacy pid, the in-place guest component upgrade (`updateComponents`, `updateMediaComponents`). A Mac with the old layout gets one prompt at launch ("Light Touch's built-in iPod has changed format. Erase it and continue (apps you've saved are kept), or quit."): Erase & Continue keeps the IPAs in the library and the pairing (seeded into the new device), Quit changes nothing. `LTM_DEV_BASE=<firmwarekit output>` is the only development boot. | app, helper, firmwarekit build; `tests/check-bundled-prepared.py` (fresh → published `.prepared`, bootable files; old layout → prompt path, dirs gone, IPAs kept, pairing copied); `check-firmware-jobs` (publish; no longer XFAIL), `check-storage-lifecycle` (the unpack), `check-storage-locations`; `check-sessions --single --board ipod` on the unpacked blob; `test-release.py` 22/22, `test-package.py`; `scripts/gate.sh --quick` |
| Track B: IPA library (`ipa-library`, 09-28) | Content-addressed store `State/Library/IPAs/<sha256>.ipa` + `index.json` (bundle id, name, version, min OS, size, md5, catalog copy); `IPALibrary.adopt` hashes once and clones the blob into `Devices/<uuid>/IPAs/<bundle-id>.ipa` (drag-out and `forget` unchanged); uninstall drops the device copy only, and the app-wide icon only when no device keeps the app; Legacy Store downloads reuse the blob whose md5 the catalog copy names (no transfer; a copy the library lacks still downloads and verifies); "Install on ▸ <running device>" in the installed row's menu and `.ipa` drops on running sidebar rows, both through the per-device `AppInstaller.start`; launch sweep stores existing device copies once (and still moves a pre-per-device `State/IPAs` into every device); Settings ▸ Storage "Library" line with Remove Unused | `tests/check-ipa-library.py` (two records → one blob, two clones, one entry; uninstall on A keeps B's copy and icon; Remove Unused spares referenced blobs; Store dedupe against a local fixture with its IPA route disabled; sweep idempotent); `check-uninstall-queue` (icon kept while another device has the app), `check-install-queue-scope`, `check-media-queue`, `check-storage-lifecycle`; app builds; `scripts/gate.sh --quick`; `check-sessions --ipad-device` 16/16 (iPod + iPad, install into each) |

## Catalog (LightTouchMac/Resources/firmware-catalog.json)

| Entry | Status | Note |
|---|---|---|
| iPod 3.1.3 (7E18) | user IPSW, built in | shipped as a packed prepared base (C6) |
| iPod 4.2.1 (8C148) | experimental | added 2026-09-28 |
| iPod 2.1.1 (5F138) | coming soon | emulator done; needs the N72 recipe path, keys, in-app check |
| iPad 3.2.2 (7B500) | available | |
| iPad 3.2 (7B367) | available | |
| iPad 4.2.1 (8C148) | experimental | keyboard fixed 09-28; devices prepared before need re-preparing |

## Running now (2026-09-28)

| Work | Branch | Covers |
|---|---|---|

| GL bridge rejection audit | qemu-ios `gl-coverage` | every reject/unimplemented path counted + logged, magenta fallback under `gles-debug`, produced-vs-rejected list from the firmwares' own frameworks, cheap formats implemented |
| iPod touch 1G, milestone 0 | qemu-ios `ipod-1g` | devos50's S5L8900 machine on our tree with shared models + properties; boot 3A101a from his public images (docs/sweep/ipod-1g.md) |
| Firmware matrix | `matrix` | every iPad 3.x/4.x/5.x and iPod 2.x–4.x build enumerated with keys; tests/matrix.py runner; results in docs/matrix-results.md |
| iOS 5 spike gate | qemu-ios `ios5-spike` | three generic fixes (boot_args version from the kernel, mkpkg no-family, cache-only GLEngine) awaiting fresh-device on 7B500/8C148 |
| Runtime GL dispatch | qemu-ios `gl-runtime` | one shim per arch, dispatch discovered at load, name-keyed wire |
| Consolidation sweep | docs/sweep/PLAN.md | surveys done (docs/sweep/*.md); Tracks A and B merged; C–E sequenced in the plan; S1–S3 decided |

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
- tests/check-helper-boot.py's iPad recipe is the kboot bring-up; it should use the app's BootRecipe like check-sessions does (gate.sh skips its iPad cases on iBoot devices).
- tests/check-app-row-refresh.py and check-media-drop.py: slicer drift from InstallJob.deviceID; being fixed on `ipa-library`.
- 12 qemu-ios unit-test slices and 5 app check slices are behind the tree (listed as XFAIL in tests/gate.sh and scripts/gate.sh); E4 retires slicing.
- The app's QEMU-backed checks look for `$QEMU_IOS_DIR/build-native14/qemu-build/libqemu-arm.dylib` (xcconfig), which no ipad1 worktree provides; E1's pin file fixes the lookup.
- Adding iBoot32Patcher to the native recipes invalidated every earlier native root: `--native-deps` must now point at one built with it (`LightTouchMac-iboot-ship/.build/native-iboot-ship`, one-step `build-package-native.sh` on 09-28), until the next one-step build.
- `test-package.py <app>` needs a Developer-ID-signed build (it checks the helper's `runtime` flags); an ad-hoc package fails that check by design.
- Survey reports live in docs/sweep/.
- `tests/ipod/test_regress.py`: one test's mock lacks `guest_package_status`.
- Two checks flake under heavy load (one iPad boot hang, one audio correlation); pass on retry.
- `tests/check-device-menus.py` fails at baseline on the App menu's Settings… item. (`run-catalog-checks.py` is back: its IPALibrary assertions moved to `check-ipa-library.py`.)
- usbmuxd `idle-poll` (fork branch, off `qemu-zlp`): pin it with the next release build (`build-support`/release pin) so the app ships the backoff.
- Tip fix not yet confirmed on an app-prepared iPad.
- ~45 worktrees under ~/Developer and /tmp from finished agents; prune the merged ones.

### Sam's calls
- Activation UX.
- Merge into `main` and push a scrubbed `ipad1` (the bundled iPod is now built from this tree by every release build; no image swap).
- Post the drafted replies to GitHub #12 and #15.
