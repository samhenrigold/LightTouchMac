# Running the iPad 1 in Light Touch

Status: 2026-09-27. The iPad boots to SpringBoard in the app's bridge, unlocks,
opens apps, rotates, takes typing from an emulated USB keyboard, persists in a
copy-on-write overlay and answers lockdown over usbmuxd-qemu.

## Pieces

| Where | What |
| --- | --- |
| `qemu-ios` branch `ipad1-app` | `ipad1` machine (merged from `ipad1`), `qemu_ios_device_info()`, bridge buttons, rotate via `accel-orientation` |
| `LightTouchMac` branch `ipad1` | `DeviceProfile` and the iPad start path |
| `~/Developer/qemu-ios-files/ipad1/7B500/k48-kboot.bin` | K48KBOOT bundle from `imgtools/ipad1_kboot.py` at `ipad1-app` HEAD; must carry the `hsic-enabled` DT property (the builder adds it) or the USB keyboard never enumerates |
| `~/Developer/qemu-ios-files/ipad1/userland/golden-pristine` | read-only NAND page store |

## Build

    # emulator: both machines in one dylib
    cd ~/Developer/qemu-ios-ipad1-app
    bash contrib/macos-app/make-dylib-macos.sh "$PWD/build"
    nm -gU build/libqemu-arm.dylib | grep device_info

    # app: point the project at that checkout/build
    cd ~/Developer/LightTouchMac-ipad1
    xcodebuild -scheme LightTouchMac -configuration Debug \
        QEMU_IOS_DIR=$HOME/Developer/qemu-ios-ipad1-app \
        QEMU_BUILD_DIR=$HOME/Developer/qemu-ios-ipad1-app/build build

`Configuration/Shared.xcconfig` holds the same two settings for Xcode.

## Run

    LIGHTTOUCH_DEVICE=ipad1 open -a <built LightTouchMac.app>
    # or set the variable in the Xcode scheme's environment

Without the variable the app is the iPod, unchanged. `LTM_FILES` moves the files root as before.

## What the app does for the iPad

- `DeviceProfile.current` picks the machine, display name, window size and
  shell art. Panel geometry (1024x768) comes from `qemu_ios_device_info()`.
- Machine: `ipad1,kboot=…,nand=<golden>,nand-overlay=State/nandrw-ipad1-golden-pristine-<hash>,usb-tcp-addr=<bridge>`
  plus `-device usb-kbd,bus=usb-bus.0`. The overlay is keyed like the iPod's,
  so Erase All Content and Settings deletes it and the next boot is factory.
- Display: the panel is landscape-native and portrait SpringBoard arrives with
  its status bar on the panel's right edge, so the content layer is fixed to
  the shell a quarter turn counter-clockwise (`DeviceProfile.panelRotation`).
  The guest turns its own UI inside the panel, so unlike the iPod the content
  is not counter-rotated when the shell turns. Touches convert through the
  layer tree, so they arrive in panel coordinates, which `ipad1_map_touch`
  expects. Screenshots/recordings are turned to match the window.
- Rotate: `qemu_ios_ui_rotate` steps `accel-orientation` on ipad1
  (clockwise 1 → 3 → 2 → 4, found by frame dumps); the app's rotate control
  and `rotationDegrees` are unchanged.
- Touch: one finger on the absolute path, the Option-key second finger on the
  mtt path (slot 1), same as the iPod.
- Keyboard: `qemu_ios_ui_key_mac` → the usb-kbd, which takes over as the
  active keyboard; typing needs no on-screen keyboard. Home/Lock/volume use
  `qemu_ios_ui_button` → GPIO. SpringBoard shows the stock "attached USB
  device is not supported" alert once per boot.
- USB: the same `USBMux` daemon session as the iPod; `ideviceinfo` against it
  reports DeviceClass iPad, 3.2.2 (7B500).

- Buttons: the Device menu's Home (⇧⌘H), Lock (⌘L) and Volume (⌥⌘↑/↓)
  are menu shortcuts that call `qemu_ios_ui_button` → the iPad's GPIO/PMU
  buttons. Command/Control chords never reach the guest keyboard, so the
  usb-kbd holding host keys does not take them.
- Sleep: `qemu_ios_ui_display_sleeping()` reports the panel's DSI power state
  on ipad1 (ApplePinotLCD's display-off), so the window shows sleep and Space
  wakes it as for the iPod.
- Tilt, shake, battery and cable use the iPod's machine property names on
  ipad1, so the existing bridge calls work.
- Device ▸ Battery (both devices): level presets and Charge Automatically /
  Charging / Not Charging, via `qemu_ios_ui_battery`. On the iPad configd's
  gas-gauge plugin reads the level at runtime; the status bar follows within
  ~30 s. Whether it *charges* is the power source's call from the USB current
  the host grants: the usbmuxd bridge sends Apple's vendor power request
  (0x40/0x40, 500 + 1600 mA) as a Mac does, so with app management on the iPad
  shows Charging. Device ▸ Battery ▸ High-Power USB Port (iPad only) sets the
  machine's `usb-charger` and replugs USB; it only matters for the built-in
  host, i.e. with app management off (`--no-appsync`), and is disabled
  otherwise. Charging/Not Charging set the gauge and charger bits but do not
  override the power source.
- Device ▸ Orientation ▸ Compass Heading (iPad only): North/East/South/West,
  via `qemu_ios_ui_compass` (machine `compass-heading`).
- Location: not yet. It will come from a4-iboot's location responder and sit
  beside the compass (`EmulatorController`, "Location comes later").
- Quit / Power Off: the iPad has no guest tools, so the clean shutdown sends
  `qemu_ios_ui_powerdown()`; the machine turns system_powerdown into the
  power-off gesture and the D1815 power-off write sets
  `qemu_ios_ui_guest_shutdown_confirmed()` (about 15 s when driven through the
  dylib). If it isn't confirmed within `haltShutdownBudget` (30 s) the quit
  continues as a failed clean shutdown and the existing hard stop applies.

- Network: Wi-Fi, as on the iPod. The ipad1 machine brings it up by itself
  (`wifi` defaults on); `--no-network` passes `wifi=off`. With networking the
  launch replaces the machine's netdev with `user,id=wifi0` plus the
  itwebproxy guestfwd (10.0.2.100:3128), the iPod's web proxy. Stock 3.2.2
  joins the BCM4329 model's open "qemu-ios" network by itself: Settings shows
  Wi-Fi "qemu-ios", the guest takes 10.0.2.15 by DHCP, the host is 10.0.2.2.
  Works with the stock usbmuxd, no `LTM_USBMUXD`; usbmux is unaffected.
- Web proxy (Device > Proxy): routing is the golden image's Wi-Fi PAC
  (`ipad1_rootfs.py --web-proxy`: the proxy, falling back to DIRECT), so on,
  off and archive are host-side itwebproxy modes and the guest is never
  reconfigured. Turning it on offers the device's own CA as a configuration
  profile over lockdown's stock MCInstall (`scripts/lockdown-mcinstall.c`, a
  child process like lockdown-tz, bundled by package.sh; dev builds need it
  on the PATH): Settings shows Install Profile, one tap on Install trusts it,
  and HTTPS sites then open through the proxy's TLS bridge. Turning it off
  leaves the profile (remove it in Settings > General > Profiles). Needs a
  golden built with `--web-proxy` and the keychain ownership fix (qemu-ios
  ipad1 912b8cac49): before that fix the certificate could not be installed.
- USB Ethernet (opt-in, not needed for networking): golden-pristine carries
  `it_ethlink`; run with `LTM_USBMUXD=~/Developer/usbmuxd-qemu-ipad1-net/src/usbmuxd`
  (usbmuxd `ipad1` branch, 23c3afd), which selects USB configuration 4 when
  the device offers Ethernet and is unchanged for the iPod. **Release
  packaging** would need that branch merged into `qemu-backend` (Sam's call).

## Snapshots

The iPad uses the iPod's snapshot path unchanged:

- Save State Now and save-on-quit go through `qemu_ios_snapshot_save2`/`_status` (a migration stream of
  RAM and devices, taken with the vCPU stopped). The NAND overlay beside it is the flash half.
- `startIPad1` adds `restoreArgs`, which is `-incoming` when a trusted snapshot exists. It runs after the
  overlay pin check, so a snapshot only ever resumes over the overlay it was saved with.
- `verifyRestoreIfNeeded` quarantines a restore that never comes alive.
- `snapshotIdentity` keys the iPad on its golden store (`options.ipad1NAND`).
- The overlay-newer rule works for the iPad's page-store overlay because the IOP model stamps the
  overlay file's mtime on every program/erase (qemu-ios `hw/arm/s5l8930_iop.c`, `nand_touch`).
- Automatic resume follows `resumeOnLaunch`, which is currently off for both devices.
- Saving is refused while the guest holds live host GL contexts (`qemu_ios_gles_contexts`), as on the iPod.

Proven without the app (qemu-ios `ipad1-guest`):

- `tests/ipad1/snapshot-check.py` saves a live machine and restores it three ways:
  - With Safari showing a page, a USB keyboard and Wi-Fi: the page survives, touch, typing and a
    Wi-Fi-only fetch work after resume, and a new usbmuxd reattaches.
  - Mid-sound: audio continues after resume.
  - Pairing: the overlay is not newer than the state after save + quit, and is newer once the resumed
    guest writes.
- The same round trip through the app's dylib ABI (`qemu_ios_snapshot_save2`, then a relaunch with
  `-incoming` and autostart): the page is still on screen (0.00% frame difference), Safari fetches a new
  page, `ideviceinfo` answers through the new bridge, and there's no panic.

## Stubbed or absent

- **With the USB keyboard attached, Lock does not stick**: the panel goes off
  and straight back on (`_lcdEnable: 0` then `1`). Without `usb-kbd` it stays
  asleep and the sleep indicator holds. Idle sleep with the keyboard attached
  was not observed either. Emulator-side (usb-kbd/EHCI wake), not app code.
- No web proxy, no media preparation, no guest agent, no guest-driven
  orientation watch.
- `storage_failed()` reads iPod devices: an iPad NAND write failure is not
  reported to the app.
- Paste is left to the guest pasteboard work.
- The two-finger path was not exercised end to end.
- The shell is a black slab, no art.

## Verifying frames without the app

`qemu_ios_ui_frame()` returns the console's pixels; the kernel draws a small
glyph top-left before userland, so a lit frame means the bridge works:

    cc -o framecheck framecheck.c    # loads the dylib, boots, counts lit pixels
    ./framecheck build/libqemu-arm.dylib framecheck \
        -M ipad1,kboot=.../k48-kboot.bin,nand=<golden>,nand-overlay=<dir> -display none -serial null

(`framecheck.c` is a 50-line harness kept out of the repo; write it against
`qemu_ios_main`, `qemu_ios_ui_frame`, `qemu_ios_ui_quit`.)
