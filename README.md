# LightTouchMac

A native macOS app that boots and manages an emulated iPod touch 2G (iOS 3.1.3),
built on a [fork of qemu-ios](https://github.com/samhenrigold/qemu-ios).

It is one of three repos that version together:

| Repo | What it is |
|------|------------|
| [LightTouchMac](https://github.com/samhenrigold/LightTouchMac) | This app (AppKit). |
| [qemu-ios](https://github.com/samhenrigold/qemu-ios) | The emulator, loaded as `libqemu-arm.dylib`; also the guest-side helpers the app ships. |
| [usbmuxd-qemu](https://github.com/samhenrigold/usbmuxd-qemu) | Forked usbmuxd that carries USB between the guest and libimobiledevice. |

## Kernel diagnostics

Device > Advanced > Kernel Console enables XNU serial logging on the next boot.
Verbose Boot separately controls text on the guest display. Kernel output is
written to the device's `serial.log` and included in Export Diagnostics; it starts
when XNU initializes its serial console, so the earliest kernel banner may not
appear there.

## Building (development)

Checkouts are expected as siblings under `~/Developer`: `qemu-ios`,
`usbmuxd-qemu`, and a `qemu-ios-files` directory holding the device assets
(bootrom, iBoot, NOR, NAND — not distributed here; see below).

1. Build the native emulator and dependencies with
   `scripts/build-package-native.sh "$HOME/Developer/qemu-ios/build-native14"`.
   Debug and Release link `build-native14/qemu-build/libqemu-arm.dylib`.
   After emulator-only changes, run `ninja -C ../qemu-ios/build-native14/qemu-build qemu-system-arm`
   and `bash ../qemu-ios/contrib/macos-app/make-dylib-macos.sh "$HOME/Developer/qemu-ios/build-native14/qemu-build"`
   before rebuilding in Xcode; Xcode does not compile the emulator itself.
2. Build `usbmuxd-qemu/usbmuxd`.
3. Open `LightTouchMac.xcodeproj` and build. A dev build finds everything in
   the checkouts; nothing is embedded.

## Packaging (a self-contained app)

Requires Xcode, Python 3.12 (with QEMU’s `distlib` prerequisite), Meson, Ninja,
pkg-config, autotools, and the existing macOS 12 static client prefix at `~/Developer/qemu-ios-deps12` (its
`build-deps12.sh` records its build). Homebrew tools may run the build; Homebrew
runtime libraries are not bundled.

```sh
scripts/build-package-native.sh "$HOME/Developer/qemu-ios/build-native14"
xcodebuild -scheme LightTouchMac -configuration Release \
  -derivedDataPath build-package \
  OTHER_LDFLAGS="$HOME/Developer/qemu-ios/build-native14/qemu-build/libqemu-arm.dylib"
scripts/package.sh build-package/Build/Products/Release/LightTouchMac.app
python3 scripts/test-package.py
```

The native build downloads pinned sources, checks their SHA-256 hashes, and
builds a macOS 14-compatible emulator and USB dependency closure in the ignored
`qemu-ios/build-native14` directory. It retains CGL rendering, CoreAudio output, and Wi-Fi/slirp.
It refuses to reuse a build directory: for a clean rebuild, choose a new one
and use the `QEMU_BUILD_DIR`, `LTM_DEPS_PREFIX`, and `USBMUXD_BIN` overrides it
prints. The packaging defaults use `build-native14`; they do not silently
fall back to Homebrew.

Packaging rejects missing dependencies, newer macOS deployment targets, and
load paths outside the bundle before signing. It explicitly embeds the two
libraries the app loads with `dlopen`, even when the client tools are static.
The packed NAND includes a `nand.itnand.sha256` content identity so installing
a new app version does not replace an unchanged guest base.

Takes the built app and makes it run on a Mac with no Homebrew and no source
checkouts: embeds `libqemu-arm.dylib` and its dylib closure, the
libimobiledevice tools, usbmuxd, the guest-side helpers, and the device assets
(including a packed NAND), then re-signs. `Bundled.swift` makes the app look inside its own
bundle first, so packaged and dev builds exercise the same code paths.

- Ad-hoc signed by default (runs on your Mac; other Macs need Gatekeeper
  override). Set `SIGN_ID` to a "Developer ID Application: …" identity and
  `NOTARY_PROFILE` to a notarytool keychain profile for a distributable,
  notarized build.
- `LTM_ASSETS=none` skips the device assets; `LTM_NAND=<dir>` picks the NAND
  image (default `nand-ultimate`).

## Device assets

The emulator boots real iPod touch 2G firmware (bootrom, iBoot, NOR) and a
prepared iOS 3.1.3 NAND image. These are Apple-copyrighted and are not in any
of the three repos; a packaged app embeds your local copies from
`~/Developer/qemu-ios-files`. The app never writes to the base image — per-user
state (NAND overlay, snapshots, logs) lives in
`~/Library/Application Support/LightTouchMac`.


### Catalog and installation reliability (2026-09-04)

The Store keeps `/api/emulator/apps` for its compatibility-filtered catalog.
“Versions and Details…” uses the public versions/copy APIs; each selected copy
is revalidated against the emulator endpoint, then checked for size and archive
MD5 before installation. These checks do not establish runtime compatibility.

Downloads run independently; only completed IPAs enter the serial device queue.
A device/transfer failure pauses pending installs while retaining their downloaded
files. Use “Resume Pending Installs” in the app-list context menu after the device
responds, or cancel individual jobs. Open/Uninstall remain available during network
downloads, but wait while a device operation is active. Store rows also expose
Open/Uninstall for installed apps. Selection tracks stable row identities.

Run the isolated checks (no QEMU or existing device state is used):

```sh
python3 tests/run-catalog-checks.py
python3 tests/run-catalog-checks.py --ui  # also briefly presents an AppKit test sheet
```

Tilt counter-rotation now follows only the guest orientation, so a layout during
a gesture cannot leave the screen crooked. Quit no longer attempts a UI power-off
swipe. Native shutdown now follows SpringBoard’s launchd-coordinated `reboot2`
path and passes actual PMU confirmation. Warm-reset storage mapping and watchdog
command handling are corrected in QEMU; the app no longer suppresses resets.
The `boot,restart,persist,fsck` regression passes with byte-identical markers
and a full-volume filesystem check. A helper banner remains insufficient proof
of shutdown.

Outstanding reports: Spore’s black MPEG-4/AAC intro, silent PCM game music, missing
video-player status bar still require further guest/emulator diagnosis. The
status bar appeared in an isolated movie-player run, so that omission is not
universal. Native reboot and post-media warm reset now pass. The current hardware model does not implement the video
decoder or full AMC compressed-audio processing. These are not claimed fixed by
the frontend changes.


Power Off in the Lock toolbar menu shuts down the guest and leaves the window
open. Power On cold-boots the same emulator instance. A dimmed device with a
Sleeping or Powered Off badge distinguishes these states from an unresponsive
frame; Wake Up uses the power button. The window subtitle follows SpringBoard's
localized foreground app name (Home Screen when no app is foreground).

For isolated development runs, `LTM_STATE_DIR=/absolute/test/path` redirects
all writable device state, logs and usbmuxd scratch from Application Support.
The default remains the existing user state directory.

### Web and captures

Device > Proxy offers No Proxy or HTTP Proxy, with an optional archive date.
The proxy is bundled: no separate server or installation is required. Dated
browsing fetches the closest available Internet Archive capture through verified
host HTTPS. Changes apply when the guest is awake and ready; No Proxy restores
its previous proxy keys. Normal CONNECT preserves guest TLS; this does not yet
modernize old TLS. Archive availability and rate limits still apply.

Capture provides Save Screenshot (Shift-Command-S), Live Text
(Shift-Command-L), and Start/Stop Recording (Shift-Command-R). Screenshots use
the native screen pixels, including while paused. Live Text freezes the image inline inside the device screen for selection and
data detectors; Done or Escape returns to the live guest. Show Finger Dots uses
44-point soft gradient indicators with shadows and a 160 ms release fade in the
preview, screenshots and recordings. Touches do nothing while sleeping or off.
The sleeping presentation uses the bundled Sleeping.caar animation.

Recordings use H.264 video on a fixed 480 × 480 canvas, preserving native pixels
through rotation with black margins. The title bar and Dock indicate recording.
Stopping or quitting finishes the movie and asks where to save it. This initial
recording path is video-only; guest audio capture remains follow-up work.
