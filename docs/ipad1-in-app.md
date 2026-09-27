# Running the iPad 1 in Light Touch

Status: 2026-09-27. The iPad boots to SpringBoard in the app's bridge, unlocks,
opens apps, rotates, takes typing from an emulated USB keyboard, persists in a
copy-on-write overlay and answers lockdown over usbmuxd-qemu.

## Pieces

| Where | What |
| --- | --- |
| `qemu-ios` branch `ipad1-app` | `ipad1` machine (merged from `ipad1`), `qemu_ios_device_info()`, bridge buttons, rotate via `accel-orientation` |
| `LightTouchMac` branch `ipad1` | `DeviceProfile` and the iPad start path |
| `~/Developer/qemu-ios-files/ipad1/7B500/k48-kboot-usbhost.bin` | K48KBOOT bundle from `imgtools/ipad1_kboot.py` at `ipad1-app` HEAD; carries the `hsic-enabled` DT property the USB keyboard needs (the older `k48-kboot.bin` does not) |
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

## Stubbed or absent

- No snapshots (every launch cold-boots), no Wi-Fi/proxy, no media
  preparation, no guest agent, no guest-driven orientation watch.
- `qemu_ios_ui_display_sleeping()`, `guest_shutdown_confirmed()` and
  `storage_failed()` read iPod devices: the window never shows the iPad as
  asleep (its backlight does go off after the stock idle time) and a guest
  power-off is not detected.
- Shake, tilt, battery and pasteboard set iPod machine properties; on the
  iPad they log an error and do nothing.
- The two-finger path was not exercised end to end in this pass.
- Menus and alerts still say "iPod"; the shell is a black slab, no art.

## Verifying frames without the app

`qemu_ios_ui_frame()` returns the console's pixels; the kernel draws a small
glyph top-left before userland, so a lit frame means the bridge works:

    cc -o framecheck framecheck.c    # loads the dylib, boots, counts lit pixels
    ./framecheck build/libqemu-arm.dylib framecheck \
        -M ipad1,kboot=.../k48-kboot-usbhost.bin,nand=<golden>,nand-overlay=<dir> -display none -serial null

(`framecheck.c` is a 50-line harness kept out of the repo; write it against
`qemu_ios_main`, `qemu_ios_ui_frame`, `qemu_ios_ui_quit`.)
