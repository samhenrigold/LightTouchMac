# LightTouchMac

Built with use from agentic coding products.

Light Touch is a native macOS (AppKit) app that runs a library of emulated legacy iOS devices.
Today that library is the **iPod touch 2G** (n72ap) and the **iPad 1** (k48ap). Each device is prepared
from a stock Apple IPSW by the bundled Swift preparer, `firmwarekit` (`Packages/FirmwareKit`), using
the keys pinned in `LightTouchMac/Resources/firmware-catalog.json`; there are no hand-prepared images
per firmware. Each running device is its own helper process (`LightTouchDevice`), which is the only
thing that links the emulator.

Project status (what is done, running and left) lives in **[docs/STATUS.md](docs/STATUS.md)**. Read it
first.

## Firmwares in the catalog

| Board | Build | iOS | Catalog status |
|---|---|---|---|
| iPod touch 2G (n72ap) | 7E18 | 3.1.3 | `user_ipsw` (no public URL; also the bundled image) |
| iPod touch 2G (n72ap) | 8C148 | 4.2.1 | `experimental` |
| iPod touch 2G (n72ap) | 5F138 | 2.1.1 | `coming_soon` |
| iPad 1 (k48ap) | 7B500 | 3.2.2 | `available` |
| iPad 1 (k48ap) | 7B367 | 3.2 | `available` |
| iPad 1 (k48ap) | 8C148 | 4.2.1 | `experimental` |

Source: `LightTouchMac/Resources/firmware-catalog.json`; the per-entry notes are in STATUS.md.

## The three repositories

| Repo | What it is | How this app uses it |
|---|---|---|
| [LightTouchMac](https://github.com/samhenrigold/LightTouchMac) | This app, the per-device helper, the Swift preparer, the app tests, the product build | — |
| [qemu-ios](https://github.com/samhenrigold/qemu-ios) (fork; branch `ipad1` carries both boards) | The emulator (`hw/arm/ipod_touch_*.c`, `hw/arm/ipad1.c`, `hw/arm/s5l8930_*.c`), the guest tools under `contrib/` (agent, GL shims, AppSync, guest packages), the Python `imgtools/` pipeline that is FirmwareKit's test oracle, and the emulator gates under `tests/` | Linked by the helper as `libqemu-arm.dylib` (`contrib/macos-app/make-dylib-macos.sh`); `scripts/build-guest-tools.sh` compiles the guest tools from its `contrib/*` sources |
| [usbmuxd](https://github.com/samhenrigold/usbmuxd) (fork, branch `qemu-zlp`) | The usbmuxd that bridges the emulated USB device to libimobiledevice | Built into the bundle from the commit pinned as `USBMUXD_COMMIT` in `scripts/build-release.py`; the emulator and this fork ship together |

The emulator side's own entry point is qemu-ios `README.md`; its iPod capabilities doc is
`docs/capabilities.md` and its iPad entry is `docs/ipad1/README.md`.

## Building

Open `LightTouchMac.xcodeproj` in Xcode and build the `LightTouchMac` scheme. The project has no shell
build phases: an Xcode build compiles the app and the helper, nothing else.

Debug and Release share `Configuration/Shared.xcconfig`, which expects a qemu-ios checkout and a build
directory holding `libqemu-arm.dylib`:

```
QEMU_IOS_DIR   = $(SRCROOT)/../qemu-ios                     # headers: contrib/ios-app, contrib/macos-app; helper entitlements
QEMU_BUILD_DIR = $(QEMU_IOS_DIR)/build-native14/qemu-build  # libqemu-arm.dylib the helper links and loads
```

Override both (in Xcode or on the `xcodebuild` command line) to point at a checkout of the `ipad1`
line and a build made from it: the multi-device helper links iPad exports that the iPod-only branch's
dylib does not have (see "Corrections from implementation", W1, in `docs/multi-device-plan.md`). To
produce the dylib, build `qemu-system-arm` in that checkout and run
`contrib/macos-app/make-dylib-macos.sh BUILD_DIR`. A pin file for the qemu-ios and usbmuxd revisions
(`build-support/sources.json`) is planned (`docs/sweep/PLAN.md`, E1); until it lands, the xcconfig
defaults, `scripts/build-release.py --qemu-source` and the tests' own defaults are the pins.

Development knobs: `LTM_FIRMWAREKIT=/path/to/firmwarekit` makes a Debug app run that preparer instead of
the bundled one (for example `swift build` output from `Packages/FirmwareKit`); `LTM_STATE_DIR=/dir`
keeps all writable state and logs inside one directory.

The product build is `scripts/build-release.py` (see its `--help`). Its resumable `--stage` pipeline is
`native, qemu, dylib, guest, app, package, notarize, staple, verify`. Dependency archives are pinned in
`build-support/dependencies.json`. Firmware and the iPhoneOS SDK are external inputs; nothing downloads
or redistributes them.

The pre-multi-device README, with the iPod feature notes (media import, battery, proxy, captures) and
the older build walkthrough, is kept at `docs/archive/README-2026-09-26.md`.

## Gates

One command, two tiers:

```sh
scripts/gate.sh --quick    # host only, a few minutes: swift test, the catalog checks, every offline
                           # check-*.py and scripts/test-*.py (except the network one), in parallel
scripts/gate.sh --full     # quick + the emulator-backed checks one after the other: check-helper-boot,
                           # check-sessions (--ipad-device, then --guest), check-guest-package, regress-app.sh
```

One line per check (PASS, FAIL, SKIP with the reason, XFAIL for a check the script lists as known failing
on today's code, XPASS once it passes again); non-zero exit only on FAIL; every log under the printed
directory. The script's header names its inputs (`QEMU_IOS_DIR`, the helper's dylib, the iPad and iPod
device directories, the armv6 package) and their defaults; a check whose input is missing is SKIP with the
path it wanted. The table below is what the tiers are made of:

| Gate | Runs | Needs |
|---|---|---|
| `swift test --package-path Packages/FirmwareKit` | FirmwareKit's unit tests; oracle comparisons against the Python pipeline | Fixtures under `~/Developer/qemu-ios-files` and a qemu-ios checkout (`~/Developer/qemu-ios-ipad1`, or `FIRMWAREKIT_QEMU_IOS`); tests skip when they are absent |
| `python3 tests/run-catalog-checks.py [--ui]` | Catalog, ready-queue and boundary checks, optionally a brief AppKit test sheet | No QEMU, no device state |
| `python3 tests/check-<topic>.py` | One check per topic (69 today). Each is standalone; its docstring names what it compiles, what it needs and its flags. Most are offline; `check-helper-boot.py`, `check-sessions.py` and `check-media-native.py` boot the emulator headless, and some flags do real work (`check-firmware-jobs.py --download` fetches an IPSW from Apple) | Read the docstring; QEMU-backed checks default to `~/Developer/qemu-ios-ipad1` and `~/Developer/qemu-ios-files` |
| `python3 tests/check-sessions.py …` | Two devices at once through the app's own session code (`tests/session-driver`); `--single DIR --board ipod|ipad` boots one prepared base the way the app does and is what the release verify stage runs; `--guest` runs the guest-services scenario | A prepared device directory, a built helper, the usbmuxd fork |
| `python3 scripts/test-<topic>.py` | Build and packaging checks: dependency sources, guest build, release, package, signing, GLib compatibility, zoom | Per script |
| `scripts/regress-app.sh` | App-level regression reusing the qemu-ios harness (`scripts/regress_app.py`) | The qemu-ios checkout at `~/Developer/qemu-ios` and its images |
| `scripts/build-release.py --stage verify` | The bundled `firmwarekit` prepares each entry in `VERIFY_ENTRIES`, then `check-sessions.py --single` boots it through the bundle: lit, lockdown, AFC round trips past 16 KiB, an IPA install, a clean shutdown | A finished `--stage package` and the entries' IPSWs |

Every headless boot passes `-audio driver=none`. Nobody but Sam launches the app itself; verification is
headless.

## Documentation

Reading order for a new contributor:

1. [docs/STATUS.md](docs/STATUS.md): what is done, running and left, with how each line was checked.
2. This README.
3. [docs/multi-device-plan.md](docs/multi-device-plan.md), sections "Preparer contract" and "Corrections
   from implementation". The rest of that file is the plan as written; the corrections say what was built.
4. [docs/storage-layout.md](docs/storage-layout.md): where device state, logs and caches live and who may
   delete what.
5. [docs/filesystem-f0-findings.md](docs/filesystem-f0-findings.md): the offline root-filesystem work
   (`firmwarekit mount/export`).
6. [docs/guest-package-bootstrap.md](docs/guest-package-bootstrap.md): versioned guest tools delivered at
   boot, with rollback; section "P5, the app" is the app side as built.

Also live: [docs/Command-organization.md](docs/Command-organization.md) (menus, toolbar, shortcuts),
[docs/accelerometer-controls.md](docs/accelerometer-controls.md) (Motion menu and the accelerometer
model), [docs/ipad-frame/README.md](docs/ipad-frame/README.md) (the stand-in iPad chrome),
[docs/sweep/](docs/sweep/) (the 2026-09-28 consolidation surveys and plan). `docs/activation-211.md` and
`tools/activation/` are Sam's.

`docs/archive/` holds dated correction logs and superseded plans (the pre-multi-device README, the
`ipad1` branch's app notes, the phase-0 spikes, the September 2026 UX logs). Nothing there describes the
current tree.

## Rules

- **No Python bridge.** The app runs one preparer, the Swift `firmwarekit`, through the contract in
  `docs/multi-device-plan.md`. qemu-ios's Python `imgtools/` is the test oracle, not a runtime.
- **Activation is Sam's.** FirmwareKit runs it as a built-in preparation step
  (`Packages/FirmwareKit/Sources/CActivation`, `tools/activation/`). Treat it as a black box: no
  activation settings, no rewriting or describing its internals, no bundling of anything else.
- **No firmware in any repo.** IPSWs, decrypted components, NAND images, SDKs and prepared devices stay
  outside the three repositories; the app downloads or imports them on the user's Mac.
- **Never merge into `main`** (here) or `ipod_touch_2g` (qemu-ios) without Sam's explicit go-ahead.
  Work lives on `multidevice`, `ipad1` and per-task branches.

## Layout

| Path | What |
|---|---|
| `LightTouchMac/` | The app: sidebar, device windows, install queue, IPSW store, `Resources/firmware-catalog.json` (the built-in iPod is its `bundled` entry, shipped as `Resources/device/n72ap-7E18.itbase`) |
| `LightTouchDevice/` | The per-device helper: one QEMU instance, frames over IOSurface, control over the `Shared/` link |
| `Shared/` | The app–helper link (`DeviceLink`, `DeviceLinkProtocol`, `DeviceRendezvous`, the `CLink` module) |
| `Packages/FirmwareKit/` | `FirmwareKit` (IPSW → device), the `firmwarekit` CLI (`Sources/FirmwareKitCLI`), `CActivation` |
| `scripts/` | `build-release.py` and its stages, `build-guest-tools.sh`, `pack-base.py` (the built-in iPod's blob), `package.sh`, `regress-app.sh`, `test-*.py`, lockdown C helpers |
| `tests/` | `check-*.py`, `run-catalog-checks.py`, the Swift drivers (`helper-driver`, `session-driver`), `fake-firmwarekit.py`, the volume-rebuild oracle |
| `build-support/` | `dependencies.json` (pinned archives) and build patches |
| `Configuration/` | `Shared.xcconfig` |
| `docs/` | Documentation; `docs/sweep/` surveys and plan; `docs/archive/` superseded material |
| `spikes/` | Phase-0 spike sources (rendezvous, GL helper, two-at-once); archive material, kept for reference |
| `tools/activation/` | Sam's activation tool (its `build/` output is ignored) |
