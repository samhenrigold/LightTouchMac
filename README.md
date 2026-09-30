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
| [qemu-ios](https://github.com/samhenrigold/qemu-ios) (fork; branch `ipad1` carries both boards) | The emulator (`hw/arm/ipod_touch_*.c`, `hw/arm/ipad1.c`, `hw/arm/s5l8930_*.c`), the guest tools under `contrib/` (agent, GL shims, AppSync, guest packages), the Python `imgtools/` pipeline that is FirmwareKit's test oracle, and the emulator gates under `tests/` | Pinned by commit in `build-support/sources.json`. Linked by the helper as `libqemu-arm.dylib` (`contrib/macos-app/make-dylib-macos.sh`); its `contrib/export-guest-artifacts.sh` builds and stages the guest tools, GL tables, entitlements and headers with a manifest, and `scripts/build-guest-tools.sh` is a thin caller of it |
| [usbmuxd](https://github.com/samhenrigold/usbmuxd) (fork, branch `idle-poll` on `qemu-zlp`) | The usbmuxd that bridges the emulated USB device to libimobiledevice | Built into the bundle from the commit pinned in `build-support/sources.json`; the emulator and this fork ship together, so bump both pins in one commit |

The emulator side's own entry point is qemu-ios `README.md`; its iPod capabilities doc is
`docs/capabilities.md` and its iPad entry is `docs/ipad1/README.md`.

## Building

Open `LightTouchMac.xcodeproj` in Xcode and build the `LightTouchMac` scheme. The project has no shell
build phases: an Xcode build compiles the app and the helper, nothing else.

Debug and Release share `Configuration/Shared.xcconfig`, which expects a qemu-ios checkout and a build
directory holding `libqemu-arm.dylib`:

```
QEMU_IOS_DIR   = $(HOME)/Developer/qemu-ios-ipad1        # headers: contrib/ios-app, contrib/macos-app; helper entitlements
QEMU_BUILD_DIR = $(QEMU_IOS_DIR)/build-w1-native          # libqemu-arm.dylib the helper links and loads
```

These two lines repeat **the pin**, `build-support/sources.json`: the qemu-ios commit (branch `ipad1`; the
iPod-only branch's dylib lacks the iPad exports the helper links), its expected checkout path and development
build directory, and the usbmuxd commit; iBoot32Patcher is pinned in `build-support/dependencies.json`.
`scripts/sources.py` resolves the pin for every script and check (`sources.py qemu-ios | usbmuxd | qemu-build`,
`sources.py check` for pinned vs actual; `QEMU_IOS_DIR`, `USBMUXD_SOURCE_DIR` and `QEMU_BUILD_DIR` override),
and `tests/release/test-release.py` checks that the xcconfig agrees with it. To produce the dylib, build
`qemu-system-arm` in that checkout and run `contrib/macos-app/make-dylib-macos.sh BUILD_DIR`.

Development knobs: `LTM_FIRMWAREKIT=/path/to/firmwarekit` makes a Debug app run that preparer instead of
the bundled one (for example `swift build` output from `Packages/FirmwareKit`); `LTM_STATE_DIR=/dir`
keeps all writable state and logs inside one directory.

The product build is `scripts/build-release.py` (see its `--help`). Its resumable `--stage` pipeline is
`native, qemu, dylib, guest, app, package, notarize, staple, verify`. Its `--qemu-source` and `--usbmuxd-source`
default to the pin; it records pinned vs actual commits in `build-inputs.json` and refuses a Developer ID build
whose checkout is not at the pinned commit unless `--allow-unpinned` (an ad-hoc build only records it). The
guest stage runs qemu-ios's export and validates the staged tree against its `manifest.json` (every file at its
hash, the names the app and firmwarekit need, the catalog's GL tables, the sources unchanged). Dependency
archives are pinned in `build-support/dependencies.json`. Firmware and the iPhoneOS SDK are external inputs;
nothing downloads or redistributes them.

The pre-multi-device README, with the iPod feature notes (media import, battery, proxy, captures) and
the older build walkthrough, is kept at `docs/archive/README-2026-09-26.md`.

## Gates

One runner, three tiers, and a wrapper that runs the host-only ones:

```sh
tests/run.py offline            # no emulator, about a minute: every tests/offline/check-*.py (swiftc on the app's
                                # sources plus temp fixtures) and the catalog checks, -j 4 through one shared
                                # module cache
tests/run.py release            # packaging and build checks (tests/release/); --network adds the dependency fetch
tests/run.py sessions           # helper + emulator, one boot at a time, -audio driver=none: check-helper-boot,
                                # check-sessions (--ipad-device, then --guest), check-guest-package,
                                # check-activation-gate, check-boot-deadline, check-files-native, check-media-native
scripts/gate.sh --quick         # swift test (Packages/FirmwareKit) + offline + release
scripts/gate.sh --full          # quick + sessions
```

`--only NAME` runs a subset. One line per check (PASS, FAIL, SKIP with the reason, XFAIL for a check
`tests/run.py` lists as known failing on today's code, XPASS once it passes again); non-zero exit only on
FAIL; every log under the printed directory. The sessions tier's inputs (`QEMU_IOS_DIR`, the helper's dylib,
the iPad and iPod device directories, the armv6 package) are documented in `tests/run.py`; a check whose
input is missing is SKIP with the path it wanted. Every script resolves the qemu-ios and usbmuxd checkouts
through `scripts/sources.py` (the pin in `build-support/sources.json`).

| Directory | What is there |
|---|---|
| `tests/offline/` | One check per topic. Each is standalone; its docstring names what it compiles and its flags. Most compile whole production files with a small fixture; the ones that still cut a section out of a hub file by marker are listed with the reason in [tests/SLICED.md](tests/SLICED.md) |
| `tests/sessions/` | `check-sessions.py` boots two devices at once through the app's own session code (`tests/drivers/session-driver`); `--single DIR --board ipod|ipad` boots one prepared base the way the app does and is what the release verify stage runs; `--guest` runs the guest-services scenario. `check-helper-boot.py` drives the helper directly (`tests/drivers/helper-driver`). `matrix.py`, `install-durability.py` and `volume-rebuild-oracle.py` are tools run by hand (`tests/matrix.py` still works) |
| `tests/release/` | Build and packaging checks: dependency sources, guest build, release, package, signing, package layout. `scripts/check-macho.py` and `scripts/test-glib-compat.py` stay in `scripts/` because the native recipe hash includes them |
| `tests/drivers/`, `tests/fixtures/` | The Swift drivers the session checks compile; the fake preparer, the catalog server and the Swift fixtures the checks share |
| `swift test --package-path Packages/FirmwareKit` | FirmwareKit's unit tests; oracle comparisons against the Python pipeline. Fixtures under `~/Developer/qemu-ios-files` and a qemu-ios checkout (`FIRMWAREKIT_QEMU_IOS`; `gate.sh` sets it from the pin); tests skip when they are absent |
| `scripts/build-release.py --stage verify` | The bundled `firmwarekit` prepares each entry in `VERIFY_ENTRIES`, then `tests/sessions/check-sessions.py --single` boots it through the bundle: lit, lockdown, AFC round trips past 16 KiB, an IPA install, a clean shutdown |

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
| `LightTouchMac/` | The app, one directory per layer (below), plus `Resources/firmware-catalog.json` (its `first_run` names the device a first launch selects: an `available` build Apple still serves), `Assets.xcassets`, `Shim/` |
| `LightTouchMac/Transport/` | The wire to a device and the app's logs: `IMobileDevice` (the dlopen'd libimobiledevice), `USBMux` (each device's usbmuxd), `DeviceExecution` (the serial gate, deadlines, late-handle cleanup, errors, timeouts), `NativeLogging`, `AppEventLog` |
| `LightTouchMac/Services/` | Stock lockdown services on one device, all on `DeviceServices`' `run` kernel: `InstallationProxy`, `AFC` (staging and the Files browser), `SpringBoardServices`, `LockdownTools` (ActivationState, the lockdown-tz and lockdown-mcinstall children), `NotificationProxy` |
| `LightTouchMac/Guest/` | The guest agent: `GuestAgent` (the wire and typed ops), `GuestServices` (media commit, trust, proxy route, respring, launch), `GuestPackage` |
| `LightTouchMac/Library/` | What the app keeps: `DeviceInstance`, `DeviceLibrary`, `DeviceStateStorage`, `StorageLocations`, `Bundled`, `LegacyState`, `IPSWStore`, `FirmwareCatalog`, `FirmwareJobs`, `FirmwareDownloads`, `PreparationJob`, `IPALibrary`, `IPAMembers`, `AppMetadataCache` |
| `LightTouchMac/Device/` | One running device: `DeviceProfile`, `DeviceSession`, `DeviceProcess` (its helper), `BootRecipe`, `EmulatorController` (lifecycle and input; vends `services`, `guest`, `installPipeline`), `DeviceRow`, `DeviceConnectionIssue`, `DeviceFileWatch`, `WebProxyConfiguration` |
| `LightTouchMac/Features/` | What the app does with a device: `AppInstaller` (the per-device install and removal queue), `AppInstallPipeline`, `MediaImport` (+ `Media*`, `PreparedMedia`), `WebProxySetup`, `CaptureController` (+ recording, movie writer, canvas capture, capture preferences), `CatalogClient`/`CatalogCopy`, `DiagnosticsExport` |
| `LightTouchMac/UI/` | Windows, views and view controllers: `MainWindowController`, the sidebar, placeholder, device and inspector view controllers, `DisplayView`, `DeviceModelView`, `DroppedFiles`, the Files, log, storage, proxy and capture panels, small controls |
| `LightTouchMac/App/` | `main`, `AppDelegate`, `MainMenu`, `WindowRestorationPolicy`, `NetworkAccessPreference` |
| `LightTouchDevice/` | The per-device helper: one QEMU instance, frames over IOSurface, control over the `Shared/` link, and the device's web proxy (`WebProxy` on URLSession, `WebProxyAdapters`) behind the 10.0.2.100:3128 guestfwd |
| `Shared/` | The app–helper link (`DeviceLink`, `DeviceLinkProtocol`, `DeviceRendezvous`, the `CLink` module); `WebProxyCA`, the per-device proxy CA both sides use |
| `Packages/FirmwareKit/` | `FirmwareKit` (IPSW → device), the `firmwarekit` CLI (`Sources/FirmwareKitCLI`), `CActivation` |
| `scripts/` | `build-release.py` and its stages, `build-guest-tools.sh`, `package.sh`, `gate.sh`, `sources.py`, `check-macho.py`, `test-glib-compat.py`, lockdown C helpers |
| `tests/` | `run.py` and the tiers `offline/`, `sessions/`, `release/`; `drivers/` (helper-driver, session-driver), `fixtures/` (fake-firmwarekit.py, catalog-server.py, the Swift fixtures); `SLICED.md` |
| `build-support/` | `dependencies.json` (pinned archives) and build patches |
| `Configuration/` | `Shared.xcconfig` |
| `docs/` | Documentation; `docs/sweep/` surveys and plan; `docs/archive/` superseded material |
| `spikes/` | Phase-0 spike sources (rendezvous, GL helper, two-at-once); archive material, kept for reference |
| `tools/activation/` | Sam's activation tool (its `build/` output is ignored) |
