# Contributing to Light Touch

Light Touch is a native macOS (AppKit) app that runs a library of emulated legacy iOS devices.
The device catalog covers the iPhone (m68ap), iPhone 3GS (n88ap), iPhone 4 (n90ap), iPod touch 1G to 4G
(n45ap, n72ap, n18ap, n81ap) and iPad (k48ap). Each device is prepared
from a stock Apple IPSW by the bundled Swift preparer, `firmwarekit` (`Packages/FirmwareKit`), using
the keys pinned in `LightTouchMac/Resources/firmware-catalog.json`; there are no hand-prepared images
per firmware. Each running device is its own helper process (`LightTouchDevice`), which is the only
thing that links the emulator.

## Firmwares in the catalog

The shared [firmware catalog](LightTouchMac/Resources/firmware-catalog.json) is the source of truth for
builds, availability, keys and preparation recipes. The CLI reads that same catalog:

```sh
firmwarekit create --catalog LightTouchMac/Resources/firmware-catalog.json \
  --id k48ap-7B500 --ipsw /path/to/stock.ipsw --out /path/to/new-device \
  --helper /path/to/LightTouchDevice --guest-tools /path/to/ipad-guest-tools
```

Catalog availability is distinct from measured acceptance.

## The three repositories

| Repo | What it is | How this app uses it |
|---|---|---|
| [LightTouchMac](https://github.com/samhenrigold/LightTouchMac) | This app, the per-device helper, the Swift preparer, the app tests, the product build | — |
| [qemu-ios](https://github.com/samhenrigold/qemu-ios) (branch `main`) | The emulator (`hw/arm/ipod_touch_*.c`, `hw/arm/ipad1.c`, `hw/arm/s5l8930_*.c`), the guest tools under `contrib/` (agent, GL shims, AppSync, guest packages), Python format inspection tools and frozen bake references, and the emulator gates under `tests/` | Pinned by commit in `build-support/sources.json`. Loaded by the helper as `libqemu-arm.dylib` (`contrib/macos-app/make-dylib-macos.sh`), which it refuses unless `qemu_ios_api_version()`'s major matches `Qemu.apiMajor` (bump both when an entry point is removed or changed); its `contrib/export-guest-artifacts.sh` builds and stages the guest tools, GL tables, entitlements and headers with a manifest, which `scripts/vendor` runs |
| [usbmuxd](https://github.com/samhenrigold/usbmuxd) (fork, branch `idle-poll` on `qemu-zlp`) | The usbmuxd that bridges the emulated USB device to libimobiledevice | Built into the bundle from the commit pinned in `build-support/sources.json`; the emulator and this fork ship together, so bump both pins in one commit |

The emulator side's own entry point is qemu-ios `README.md`.

## First build

On a fresh Apple Silicon Mac, clone this repository and run `scripts/vendor`, the one setup command (run it again
after a pin bump). It checks Xcode, the Homebrew build tools, the qemu-ios and usbmuxd checkouts holding their pinned
commits, the iPhoneOS 3.1.3 and 3.2 SDKs and the SecureROMs, prints each missing piece and where to get it (Apple's
software and firmware are never downloaded or copied for you), and then builds the vendor directory (below; about 15
minutes). After that, build the `LightTouchMac` scheme in Xcode. `scripts/vendor --check` only checks. Either way it
turns on the pre-commit formatter (`git config core.hooksPath scripts/hooks`, and `git config blame.ignoreRevsFile
':(optional).git-blame-ignore-revs'` so blame skips reformat commits).

## Building

Open `LightTouchMac.xcodeproj` in Xcode and build the `LightTouchMac` scheme: the app, the device helper
(`LightTouchDevice`), the services helper (`LightTouchServices`) and the preparer (`firmwarekit`, from
`Packages/FirmwareKit/Sources/FirmwareKitCLI`). The app's one script phase stamps the build number
(`CFBundleVersion`, the commit count).

Every build setting is in `Configuration/`, none in the project file: `Shared.xcconfig` is the project's (every
target's base), and `App`, `Device`, `Services` and `Tool.xcconfig` are the four targets' own, each written once with a
`[config=Debug]` or `[config=Release]` line where the two differ. A Debug helper loads `libqemu-arm.dylib` from a
qemu-ios development build:

```
QEMU_IOS_DIR   = $(HOME)/Developer/qemu-ios
QEMU_BUILD_DIR = $(QEMU_IOS_DIR)/build-w1-native          # libqemu-arm.dylib, on a Debug helper's rpath
```

These repeat **the pin**, `build-support/sources.json`: the qemu-ios commit, its expected checkout path and
development build directory, and the usbmuxd commit; iBoot32Patcher and ANGLE (with its depot_tools) are pinned in
`build-support/dependencies.json`.
`scripts/vendor` reads the pin (`QEMU_IOS_DIR` and `USBMUXD_SOURCE_DIR` move the checkouts) and hands the recipes
(`build-support/recipes`) a tree at each pinned commit.
To produce the dylib, build `qemu-system-arm` in that checkout and run `contrib/macos-app/make-dylib-macos.sh BUILD_DIR`.
The services helper links libimobiledevice and libplist from the vendor directory (below), and OfflineTests compile
against its headers (`build/vendor/include`); nothing in the build reads Homebrew's (BuildToolsTests checks). Put local overrides of any of these in `Configuration/Local.xcconfig` (gitignored).

The device helper runs under the App Sandbox, in Debug and Release (`LTM_HELPER_SANDBOX = YES`, `Shared.xcconfig`):
whoever spawns it (the app, `firmwarekit`, the harness) reads the helper's signature and grants it its device's files
(HostRuntime `HelperSandbox`, `SandboxExtension`; a Debug helper also gets the emulator's folders, read-only). To debug
without it, set `LTM_HELPER_SANDBOX = NO` in `Local.xcconfig`, or pass `LTM_HELPER_SANDBOX=NO` to `xcodebuild`,
`sessions` or `scripts/ship`. The sockets the helper reaches are in its app group's container, which the app is
entitled to; `firmwarekit` or the harness run from a Terminal without Full Disk Access makes macOS ask once to let
the Terminal reach that container.

Debug-only knobs (compiled out of Release, which runs only what its bundle holds; the Release plan's
`noBinaryNamesADebugOverride` fails on any of these names in a shipped binary, `ReleaseApp.debugOverrides`):
`LTM_FIRMWAREKIT=/path/to/firmwarekit` (another preparer), `LTM_QEMU_DYLIB` (another emulator library),
`LTM_USBMUXD` (another usbmuxd), `LTM_HOST_SERVICE_WORKER` (another services worker), `LTM_FILES` (another device
files root), `LTM_GUEST_PACKAGE` (another guest package), `LTM_DEV_BASE` (a `firmwarekit create` output run as a
device), `FIRMWAREKIT_IBOOT_PATCHER`/`IBOOT32PATCHER` (another iBoot32Patcher; Debug also finds one on PATH),
`FIRMWAREKIT_DISK_IMAGE` (hdiutil or diskutil) and `LTM_TEST_MIGRATION_KILL` (the migration kill tests).
`LTM_STATE_DIR=/dir` keeps all writable state and logs inside one directory.

## Releases

A release is an Xcode archive made by `scripts/ship`; nothing edits the bundle after Xcode.

1. **`scripts/vendor`**, once per pin change (`build-support/sources.json`, `dependencies.json`, the patches or the
   recipes in `build-support/recipes`). It builds what Xcode can't, from the pins, into `~/Developer/ltm-vendor.noindex/<pin-hash>/`
   (`.noindex` keeps Spotlight out; `LTM_VENDOR_ROOT` moves it; only `scripts/clean` deletes one): the native dependencies, usbmuxd and QEMU for arm64 and
   x86_64, merged universal with final install names
   (`Frameworks/`, `MacOS/`), the guest tools and the developer SSH payload packed into
   `Resources/Guest/guest.aar`, the SecureROMs (`Resources/Device/`), the licenses and `build-inputs.json`; with
   `--release` (which `scripts/ship` passes) also the built-in iPod (`Resources/Device/n72ap-7E18.itbase`, which only
   an archive copies). A rerun with nothing changed builds nothing; with `--release`, one after a FirmwareKit or
   helper change only prepares the built-in iPod again. Every run writes HostRuntime's `MachineOptions.swift` (each
   board's -machine options, which a boot keeps to) from the vendored QEMU; commit it when it changed. Inputs:
   `ARMV6_SDK` (default `~/Developer/ipod2g-re/OldSDK/iPhoneOS3.1.3.sdk`), `IPAD_SDK`, `LTM_ASSETS` (the SecureROMs,
   default `~/Developer/qemu-ios-files`), with `--release` the n72ap-7E18 IPSW in the app's IPSW cache, and the
   network for the pinned source archives. Firmware and the iPhoneOS SDK are never downloaded or redistributed. Xcode finds the directory
   itself: the services helper's first phase (`scripts/vendor-check`) keys the pins (`scripts/vendor` keys with it too), points
   the gitignored `build/vendor` (the default `VENDOR_DIR`) at that directory, and fails the build with "run
   scripts/vendor" when there is none, rather than build with another pin's, or when the checkout's
   `MachineOptions.swift` isn't the one written there. `LTM_VENDOR_ROOT` counts for Debug builds
   only. A `VENDOR_DIR` in `Configuration/Local.xcconfig` is held to the current pins the same way.
2. **`scripts/ship --notes notes.md [--title T] [--commit REV] [--archive X.xcarchive] [--dry-run]`**, the only way to
   make a release, from a clean checkout at origin/main (or REV). Preflight: Xcode is exactly the build
   `build-support/sources.json` pins (`xcode.build`; `scripts/ship --pin-xcode` records the selected one, then commit
   it), the tree is clean at the commit, the notes are there and hold no template text such as TODO, the notary key,
   the Developer ID identity, `amore whoami`, `gh auth status`, disk, and `scripts/host-ready` (waited on). Then every
   IPSW the vendor step and the Release plan need goes into the app's IPSW cache (a local copy with the catalog's
   SHA-1 found under `LTM_IPSW_DIRS` or `LTM_BUILT_IN_IPSW`, else downloaded and checked), `scripts/vendor --release`,
   and `xcodebuild archive` (scheme `LightTouchMac`, Release, arm64 + x86_64, Developer ID, only the package versions
   `Package.resolved` records; `--archive` restarts with an archive made before). The archive's Copy Files phases
   bring in the vendor directory (Code Sign On Copy signs its binaries with the app's identity and the hardened
   runtime); `LightTouchDevice` carries `Configuration/LightTouchDevice-Sandbox.entitlements` (the App Sandbox,
   allow-jit, network client and server, the app group; library validation on; a Debug build uses
   `LightTouchDevice-Sandbox-Debug.entitlements`, which also disables library validation for a development dylib) and
   the app `LightTouchMac-Sandbox.entitlements` (the app group, location); with `LTM_HELPER_SANDBOX=NO`, the helper's
   are `LightTouchDevice.entitlements` (`-Debug`) and the app's only location. Nothing edits the bundle after Xcode.

   It exports for Developer ID (`Configuration/ExportOptions.plist`), notarizes a zip of the app (`notarytool submit
   --wait`; on Invalid it prints the log), staples and validates the ticket, and writes `LightTouchMac-universal.zip`
   (`ditto -c -k --keepParent` of the stapled app) and `SHA256SUMS` beside the exported app. Then the Release plan
   (`Packages/ReleaseChecks`) on the stapled app as an export: the app is built from the current pins; every Mach-O
   signed, hardened, universal, with the declared entitlements and an in-bundle load closure at the app's minimum
   macOS; the bundled helper, services worker and bridge run from the bundle and the helper loads the bundled
   emulator; bundle hygiene (licenses, sources, Help, no local paths, the built-in iPod's placeholder identity,
   stripped, no duplicates, nothing loose under `Resources`, the guest archive included); the identity scan;
   Gatekeeper and the ticket; and the boots, run once more if they fail: the bundled `firmwarekit` unpacks the
   built-in iPod, which `sessions single` (tests/sessions) boots through the bundled helper, dylib, services worker
   and usbmuxd, and the prepare matrix: the bundled `firmwarekit create`, with its default helper and guest tools,
   prepares one firmware per preparation route (`Packages/ReleaseChecks/boots.json`: n45ap-4A102, n72ap-7E18,
   k48ap-7B500, n90ap-8A293, n88ap-10B500; two at a time) and each is booted the same way.

   Then Amore makes an unsigned DMG of the stapled app (`--skip-notarization`), which is signed with the app's own
   Developer ID identity (or `LTM_SIGN_IDENTITY`), notarized, stapled, checked by Gatekeeper and uploaded as a draft
   with the notes; the CDN's copy must have the DMG's SHA-256 and pass Gatekeeper; the draft is published, and the
   appcast's item for the build must carry the notes as its `<description>` and an `edSignature` of the CDN's DMG
   valid for the app's `SUPublicEDKey` (`scripts/ltm-build release`). Last, `gh release create
   v<version>-<YYYY.MM.DD>[b|c|…]` with the zip and SHA256SUMS, a line in `releases.log`, and only the newest two
   archives and exports kept. Its work and log go in `~/Developer/ltm-int-rel` (`LTM_RELEASE_DIR`); it ends `PASS
   released build N (tag) <log>`. `--dry-run` runs through the release's checks without notarizing, stapling or
   uploading and prints what Amore, GitHub and the record would get; `LTM_RELEASE_SKIP_PREPARE=1` also skips the
   prepare matrix, in a dry run only. The header of `scripts/ship` lists its settings. (`scripts/release ARCHIVE
   --notes notes.md` still runs `scripts/ship --archive` for now; it is deprecated and goes after the next real
   release.)

   The Release plan alone, on a built app: `TEST_RUNNER_LTM_RELEASE_APP="path/to/Light Touch.app" xcodebuild test
   -skipMacroValidation -project LightTouchMac.xcodeproj -scheme LightTouchMac -testPlan Release`
   (`TEST_RUNNER_LTM_RELEASE_ARCHIVE` takes an archive; `TEST_RUNNER_LTM_RELEASE_SKIP_PREPARE=1` skips the matrix, for
   development runs only; a missing IPSW fails the plan).

   Notarization uses an App Store Connect API key, read from the environment or, for any it leaves unset, from
   `~/.config/lighttouch/notary.env` (mode 600; `LTM_NOTARY_CONFIG` moves it), which is never committed:

   ```sh
   LTM_NOTARY_KEY=$HOME/.appstoreconnect/private_keys/AuthKey_<key id>.p8
   LTM_NOTARY_KEY_ID=<key id>
   LTM_NOTARY_ISSUER=<issuer id>
   # optional: the DMG's signing identity, when not the exported app's
   LTM_SIGN_IDENTITY=Developer ID Application: <name> (<team>)
   ```

   The key is an App Store Connect team key with the Developer role (Users and Access ▸ Integrations); `scripts/ship`
   passes its path to `notarytool --key` and never prints it.

## Gates

Three commands, no runner around them:

```sh
# no emulator: every package's Swift Testing suites (the list is Unit.xctestplan); -skipMacroValidation for
# swift-binary-parsing's macro target, which Xcode itself asks once to trust
xcodebuild test -skipMacroValidation -project LightTouchMac.xcodeproj -scheme LightTouchMac -testPlan Unit
# emulator sessions on prepared bases (firmwarekit create output), one boot at a time; `sessions --help` for the rest
swift run --package-path tests/sessions sessions single BASE [--launch] [--reboot]
# a jailbroken base: Cydia refreshes and installs from local repositories the web proxy serves (no internet);
# --network uses the real ones and installs bc (the nightly and pre-release matrix)
# needs idevicesyslog on PATH for its Substrate check (build/vendor/work/native/arm64/prefix/bin)
swift run --package-path tests/sessions sessions single JAILBROKEN_BASE --jailbreak [--network]
# many rows at once: each job a base, or create's flags to prepare one, and a check (default single as prepared);
# up to --lanes jobs share the Mac's emulator slots, so one row prepares while others boot (`sessions matrix --help`)
swift run --package-path tests/sessions sessions matrix JOBS [--lanes 3]
# what a change needs, from the paths it touches (git diff RANGE): the Unit plan, and one boot per board family it can
# reach (all of them for the helper, the emulator, guest code, the drivers or a path no rule names); --run runs it
swift run --package-path tests/sessions sessions affected main [--run] [--bases DIR]
# preparation's gate, booting nothing: each family row's volumes (create --stop-after volumes) against the listings
# in tests/sessions/listings (paths, owners, modes, flags, sizes, content hashes, link targets); --record rewrites them
# and prints every change, and the commit that re-records says why each changed path changed
swift run --package-path tests/sessions sessions listings [ROW …] [--record]
# snapshot resume (an n72ap base): Home saved after a cold boot, booted again from it; not yet a way to skip boots,
# since a resumed guest takes no taps
swift run --package-path tests/sessions sessions resume N72_BASE
# as a device the user already has, through the app's boot admission; an old device must take its admission steps
# (the old devices in ~/Developer/qemu-ios-files/old-devices: tests/sessions/Sources/sessions/Managed.swift)
swift run --package-path tests/sessions sessions single BASE --managed
swift run --package-path tests/sessions sessions single OLD_DEVICE --expect-admission STEP
swift run --package-path tests/sessions sessions phone N90_BASE --only carrier --overlay PAST_SETUP_OVERLAY
swift run --package-path tests/sessions sessions local-network N72_BASE
# a built app (Releases, step 2)
TEST_RUNNER_LTM_RELEASE_APP="path/to/Light Touch.app" xcodebuild test -skipMacroValidation -project LightTouchMac.xcodeproj \
    -scheme LightTouchMac -testPlan Release
```

`sessions` builds the Debug helper, services worker and firmwarekit and boots them in an app's layout beside
scripts/vendor's dylib, usbmuxd, SecureROMs and guest package, or a built app's (`--app`). A build is shared by every
checkout through `~/Developer/ltm-scratch.noindex/.sessions-tools/<key>`, the key the committed trees it is built from
(a checkout with uncommitted changes there builds its own, in the run's directory); `--dylib` takes a
development build for the Debug helper (it is refused with `--app`, whose helper loads the app's own dylib). It prints one ok/FAIL line per check and exits 1 on any FAIL; logs, screenshots and the driver's
events stay in `--work`. It judges the Home screen by the guest agent's frontmost app and screen where the base has an
agent, and by a frame reference in `tests/sessions/matrix-refs` where there is one. No test run writes the real app
state or logs: the Unit plan's packages run in a private home, and `sessions` keeps the drivers' state in its work
directory and fails a run that touched the real `app.log`.

| Directory | What is there |
|---|---|
| `Packages/*/Tests`, `Unit.xctestplan` | Swift Testing: LightTouchCoreTests (the app's logic), HostRuntimeTests, FirmwareKitTests, HostServiceWireTests, ReleaseChecksTests' fixtures, BuildToolsTests (the native merge, the dependency sources, the repository's format and lint). LightTouchCore's tests run one at a time in a private home (Tests/TestIsolation) |
| `tests/offline/` | A Swift package (OfflineTests, in the Unit plan) for what needs the app target's own files: AppKit views rendered offscreen, the display's input and layout, the helper's C API version and LCD color, the services engine against a fake libimobiledevice. The production files are compiled whole through symlinks beside small stand-ins; no window is ordered in |
| `tests/sessions/` | A Swift package: `sessions` (the checks and their verdicts), the drivers that stand in for the app (`session-driver`: the app's session code; `helper-driver`: DeviceLink straight to the helper), and SessionKit (frame references, the Home verdict, the Setup walks), whose tests are in the Unit plan |
| `tests/scripts/` | Shell tests of the scripts (`clean.sh`: scripts/clean's keep and remove decisions; `format-hook.sh`: the pre-commit formatter in a scratch repository; `host-ready.sh`; `scan-release-zip.sh`: the release identity scan; `ship.sh`: scripts/ship's tags, notes, Xcode pin, notary config, IPSW fill, pruning, argument checks and `ltm-build release`), each run by BuildToolsTests in the Unit plan, or alone |
| `tests/activation/`, `tests/fixtures/` | C harnesses run by hand (`tests/activation/run.sh`: the activation finish and the lockdown zone writes); the fake preparer (`fake-firmwarekit`, bash), the store fixtures and `machines.json` the tests share |
| `swift test --package-path Packages/FirmwareKit` | Also runs FirmwareKit's suites alone. Optional corpus tests report real skips unless `FK_TEST_CORPUS=1` or `FK_REQUIRE_FIXTURES=1` selects them; selected missing inputs fail. Format/bake oracle checks compare against qemu-ios's imgtools through `FIRMWAREKIT_QEMU_IOS` |

Every headless boot passes `-audio driver=none`. The checks are headless; none of them launch the app.

## Style

Apple's [API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) first; where they are
silent, [Google's Swift style guide](https://google.github.io/swift/). American spelling, except Apple's cancelled,
cancelling and cancellable.

**Format.** The toolchain's formatters own layout, matching Xcode's editor settings (4 spaces, 120 columns;
`.editorconfig` carries them to other editors): `swift-format` for Swift (`.swift-format`, the one configuration: its
defaults with those widths and no trailing comma in a multi-line collection) and `clang-format` for C, Objective-C
and C++ (`.clang-format`: LLVM with those widths and case labels indented). Always `xcrun swift-format` and `xcrun
clang-format`, never Homebrew's. The pre-commit hook (`scripts/hooks/pre-commit`) runs `scripts/format --staged`: it
formats each staged file and stages it again, and refuses a partly staged file whose staged text isn't formatted,
printing the command to run. `scripts/format <paths>` formats files by hand, `scripts/format --check` lists every
tracked file that isn't formatted and every `swift-format lint --strict` finding (the rules the formatter can't
apply, such as a for-in loop for `forEach`), and `scripts/format --all` reformats the repository (that commit goes in
`.git-blame-ignore-revs`). BuildToolsTests runs `--check` in the Unit plan, so both stay at zero: a finding is fixed in
the code (or in its generator), not by turning the rule off. Code from upstream projects (`build-support/patches`, the
GPL fixture in `tests/offline/fixtures`) is left alone; a generator writes what the formatter would
(`ltm-build machine-options`).

**Warnings.** None. Fix the cause: a `@Sendable` closure or a lock-guarded `@unchecked Sendable` box for state shared
across threads, `MainActor.assumeIsolated` in an AppKit completion that runs on the main thread, `nonisolated` on test
fixtures in the MainActor-by-default packages. A deprecated API we must keep goes in one small C file with a scoped
`#pragma clang diagnostic` and a comment saying why (`LightTouchDevice/GuestTLS.c`).

**Files.** One main type per file, named after it; helpers only it uses can live beside it. No created-by or license
headers. A file whose role isn't obvious from its name opens with a short `//` paragraph saying what it is and why,
then the imports (sorted, one per line). `// MARK: - Topic` separates the sections of a long type; short files have
none.

**Access and types.** `private` by default, `private(set)` for state others read; never spell out `internal`;
`public` only for what another module uses. Access levels go on members, not on `extension`. Classes are `final`
unless designed for subclassing; prefer structs and enums; `actor` or a lock for shared mutable state. A conformance
that is its own topic (a delegate, a data source) goes in its own `extension`; `Sendable`, `Hashable` and the like
stay on the declaration.

**Naming.** Clear at the call site, no `get` prefixes, Booleans read as assertions (`isRunning`), factories start
with `make`. Acronyms keep one case: `deviceID`, `ipaURL`, `urlSession`. Wire and catalog names live in raw values
and `CodingKeys`, not in Swift identifiers, in new code.

**Comments.** `///` for documentation, never `/** */`; the first sentence summarizes; `- Parameter`/`- Returns` only
when they add something. Comments say why, not what. A trailing comment that won't fit in 120 columns goes above the
line.

**Code.** `guard` for early exits; `for`-`in` for a loop body (`.forEach` for one call); no `!`, `try!` or implicitly unwrapped optionals in new
non-test code unless the value can't be absent. `@MainActor` for UI state; `async`/`await` over completion handlers
in new code; `[weak self]` with `guard let self` in escaping closures, on the outermost closure that captures it.

**SwiftUI.** `@Observable` models, not `ObservableObject`; `@State` and `@Environment` are `private`. Properties,
then `init`, then `body`, then private helpers. A piece with its own state, or longer than a screen, becomes a
`private struct`; a small piece stays a `private var something: some View`. Previews use `#Preview`.

**Tests.** Swift Testing (`@Test`, `#expect`); test names are camelCase sentences stating the behavior
(`aBootThatEndsBeforeUSBEndsItsStartup`).

## Boards

A board's facts have two homes. The emulator's: qemu-ios's `qemu_ios_device_info` table
(`contrib/ios-app/qemu-ios-ui.c`): the `-M` machine, the board ID, the screen, the modem, the USB host, the compass,
the USB charger and the `panel=` limits; the helper reports them in its hello and lists them with
`LightTouchDevice '{"mode":{"machines":{}}}'`, and the app reads them as `DeviceInfo` (`Board.hardware`). The app's: one `Board`
case and its `Facts` in `Packages/HostRuntime/Sources/HostRuntime/Board.swift`: the names, the model ID, the SoC
family (which decides how its prepared base boots and its guest architecture) and the art. Adding a board touches
those two places; its firmware is catalog entries, and preparing it is a FirmwareKit recipe if no existing one fits.
`tests/fixtures/machines.json` is the listing the tests use without an emulator; the Release plan
(`ReleaseAppStaticTests`) holds each of its machines to the bundled library's.

`device.lock.json` is `DeviceLock` (HostRuntime): FirmwareKit writes it, everything else reads it through that type.

## Rules

- **No Python bridge.** The app runs one preparer, the Swift `firmwarekit`. qemu-ios's Python `imgtools/` is the test oracle, not a runtime.
- **Activation is maintained separately.** FirmwareKit runs it as a built-in preparation step
  (`Packages/FirmwareKit/Sources/CActivation`, `tools/activation/`). Treat it as a black box.
- **No firmware in any repo.** IPSWs, decrypted components, NAND images, SDKs and prepared devices stay
  outside the three repositories; the app downloads or imports them on the user's Mac.
- **Branches.** Both repositories work on `main`. Make a short branch per change and open a pull request;
  `main` doesn't accept force-pushes. A qemu-ios change the app needs lands there first, then the app's
  pin (`build-support/sources.json`) moves to it in the same pull request as the app change, with the
  `MachineOptions.swift` that `scripts/vendor` writes for the new pin (the build fails until it is there).

## Layout

| Path | What |
|---|---|
| `LightTouchMac/` | The app, one directory per layer (below), plus `Resources/firmware-catalog.json` (its `bundled` names the built-in iPod, `Resources/Device/n72ap-7E18.itbase`, which a fresh install unpacks and selects; `first_run` is what a first launch selects without it: an `available` build Apple still serves), `Assets.xcassets`, `Shim/` |
| `LightTouchMac/Transport/` | The wire to a device and the app's logs: `USBMux` (each device's usbmuxd), `NativeLogging`, `AppEventLog` |
| `LightTouchMac/Services/` | What the app layers on the stock services: `LockdownTools` (the lockdown-tz and lockdown-mcinstall writes run as child processes of the services helper, `LightTouchServices/Lockdown`), `MediaStaging`, `HomeScreenOrdering`, `ClockRegion` |
| `LightTouchMac/Guest/` | The guest agent: `GuestAgent` (the wire and typed ops), `GuestServices` (media commit, trust, proxy route, respring, launch), `GuestPackage` |
| `LightTouchMac/Library/` | What the app keeps: `DeviceInstance`, `DeviceLibrary`, `DeviceStateStorage`, `StorageLocations`, `Bundled`, `LegacyState`, `IPSWStore`, `FirmwareCatalog`, `FirmwareJobs`, `FirmwareDownloads`, `PreparationJob`, `IPALibrary`, `IPAMembers`, `AppMetadataCache` |
| `LightTouchMac/Device/` | One running device: `Board+App` (what the app derives from a board), `DeviceSession`, `DeviceProcess` (its helper), `EmulatorController` (lifecycle and input; vends `services`, `guest`, `installPipeline`), `DeviceRow`, `DeviceConnectionIssue`, `DeviceFileWatch`, `WebProxyConfiguration` |
| `LightTouchMac/Features/` | What the app does with a device: `AppInstaller` (the per-device install and removal queue), `AppInstallPipeline`, `MediaImport` (+ `Media*`, `PreparedMedia`), `WebProxySetup`, `CaptureController` (+ recording, movie writer, canvas capture, capture preferences), `CatalogClient`/`CatalogCopy`, `DiagnosticsExport` |
| `LightTouchMac/UI/` | Windows, views and view controllers: `MainWindowController`, the sidebar, placeholder, device and inspector view controllers, `DisplayView`, `DeviceModelView`, `DroppedFiles`, the Files, log, storage, proxy and capture panels, small controls |
| `LightTouchMac/App/` | `main`, `AppDelegate`, `MainMenu`, `WindowRestorationPolicy`, `NetworkAccessPreference` |
| `LightTouchDevice/` | The per-device helper: one QEMU instance, frames over IOSurface, control over the `DeviceRuntime` link, and the device's web proxy (`WebProxy` on URLSession, `WebProxyAdapters`; `GuestTLS.c`, the TLS 1.0 old guests speak, on SecureTransport) behind the 10.0.2.100:3128 guestfwd |
| `Packages/DeviceRuntime/` | The app–helper link (`DeviceLink`, `DeviceLinkProtocol`, `DeviceRendezvous`, the `CLink` module); `WebProxyCA`, the per-device proxy CA both sides use |
| `Packages/LightTouchCore/` | The app's logic that needs no window, mirroring `LightTouchMac/`'s layers (Library, Device, Session, Features, Guest, Apps, Catalog, Input, Capture, UI models); the app target keeps the AppKit and SwiftUI |
| `Packages/ReleaseChecks/` | The checks of a built app (`Release.xctestplan`): signatures, entitlements, slices and load closure, bundle hygiene, the bundled tools, boots through the bundle |
| `Packages/DeviceServices/` | One device's stock lockdown services: `HostServiceWire` (the request/event protocol, errors, timeouts, device paths, the Home screen layout) and `HostServiceClient` (the app's `DeviceServices` calls, `HostServiceWorkers`, `NotificationProxy`) |
| `Packages/FirmwareKit/` | `FirmwareKit` (IPSW → device), `FirmwareSchema` (the wire types, `StorageCapacity`, `DeveloperTools`, `GuestArchive`: what the app links), the `firmwarekit` CLI (`Sources/FirmwareKitCLI`), `CActivation` |
| `scripts/` | `clean`, `format` (with `hooks/pre-commit`), `host-ready`, `vendor` and `vendor-check`, `ltm-build` (Packages/BuildTools: vendor, machine-options, release, check-macho, merge-native, sources), `ship` (and the deprecated `release`, which runs it) |
| `tests/` | `offline/` and `sessions/` (Swift packages), `activation/` (C harnesses), `fixtures/` |
| `build-support/` | `sources.json` and `dependencies.json` (the pins), `recipes/` (the native builds `scripts/vendor` runs: `build-package-native.sh`, `build-static-deps.sh`, `build-iboot32patcher.sh`, `build-angle.sh`), build patches and checks |
| `Configuration/` | `Shared.xcconfig` (with the gitignored, optional `Local.xcconfig`), the targets' `App`, `Device`, `Services` and `Tool.xcconfig`, the helper's `LightTouchDevice-Sandbox.entitlements` (Release) and `-Sandbox-Debug`, the app's `LightTouchMac-Sandbox.entitlements`, and the unsandboxed `LightTouchDevice.entitlements` and `-Debug` (`LTM_HELPER_SANDBOX = NO`) |
| `Models/` | The 3D device models and their lighting (`Resources/Models/` in the app) |
| `LightTouchServices/` | The services helper: `Engine/` (libimobiledevice: installation_proxy, AFC, springboardservices, notification_proxy and lockdown on one `run` kernel, the serial gate and deadlines), and the lockdown writes (`Lockdown/`) it runs as child processes |
| `tools/activation/` | Sam's activation tool (its `build/` output is ignored) |
