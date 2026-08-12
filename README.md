# LightTouchMac

A native macOS app that boots and manages an emulated iPod touch 2G (iOS 3.1.3),
built on a [fork of qemu-ios](https://github.com/samhenrigold/qemu-ios).

It is one of three repos that version together:

| Repo | What it is |
|------|------------|
| [LightTouchMac](https://github.com/samhenrigold/LightTouchMac) | This app (AppKit). |
| [qemu-ios](https://github.com/samhenrigold/qemu-ios) | The emulator, loaded as `libqemu-arm.dylib`; also the guest-side helpers the app ships. |
| [usbmuxd-qemu](https://github.com/samhenrigold/usbmuxd-qemu) | Forked usbmuxd that carries USB between the guest and libimobiledevice. |

## Building (development)

Checkouts are expected as siblings under `~/Developer`: `qemu-ios`,
`usbmuxd-qemu`, and a `qemu-ios-files` directory holding the device assets
(bootrom, iBoot, NOR, NAND — not distributed here; see below).

1. Build the emulator dylib: `qemu-ios/contrib/macos-app/make-dylib-macos.sh`
   (produces `build-min12b/libqemu-arm.dylib`).
2. Build `usbmuxd-qemu/usbmuxd`.
3. Open `LightTouchMac.xcodeproj` and build. A dev build finds everything in
   the checkouts; nothing is embedded.

## Packaging (a self-contained app)

```sh
scripts/package.sh [path/to/LightTouchMac.app]
```

Takes the built app and makes it run on a Mac with no Homebrew and no source
checkouts: embeds `libqemu-arm.dylib` and its dylib closure, the
libimobiledevice tools, usbmuxd, the guest-side helpers, and the device assets
(≈1.2 GB), then re-signs. `Bundled.swift` makes the app look inside its own
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
