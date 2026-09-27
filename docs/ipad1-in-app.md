# Running the iPad 1 in Light Touch

Status: bring-up, 2026-09-26. The kernel mounts root and stops in CDMA, so the
app shows the kernel's early framebuffer, not SpringBoard.

## Pieces

| Where | What |
| --- | --- |
| `qemu-ios` branch `ipad1-app` | `ipad1` machine, `qemu_ios_device_info()`, buttons routed to the iPad GPIO |
| `LightTouchMac` branch `ipad1` | `DeviceProfile` (this doc's subject) |
| `~/Developer/qemu-ios-files/ipad1/7B500/k48-kboot.bin` | K48KBOOT bundle from `imgtools/ipad1_kboot.py` |
| `~/Developer/qemu-ios-files/ipad1/userland/nand-pristine` | NAND page store from `imgtools/ipad1_fw.py` |

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

Without the variable the app is the iPod, unchanged. `LTM_FILES` moves the
files root as before; the iPad paths are `ipad1/7B500/k48-kboot.bin` and
`ipad1/userland/nand-pristine` under it.

## What the app does for the iPad

- `DeviceProfile.current` picks the machine name, display name, window size
  and shell art. Screen geometry (1024x768, landscape) comes from
  `qemu_ios_device_info("ipad1")` in the dylib, not from the app.
- `EmulatorController.startIPad1()` runs
  `-M ipad1,kboot=...,nand=... -display none -no-shutdown -serial <log>`.
  The IOP mmaps the page store writable (`MAP_SHARED`), so the pristine image
  is cloned once into `State/ipad1/nand-pristine` (APFS clone; instant) and the
  guest runs on the clone. Delete that directory to start over.
- Frames, single-finger touches and Home/Lock/volume go through the same
  `qemu_ios_ui_*` bridge as the iPod. Touches land on the Zephyr2 multitouch
  model; buttons on GPIO port 0 pins 0-3.
- The shell is a flat black slab with a 96 px bezel; no photo or 3D model.

## Stubbed or absent

- No USB (`usbmuxd`, app install, Files, agent), no Wi-Fi, no proxy, no media
  preparation, no orientation/time-zone sync: none of these are started.
- No snapshots: nothing is saved on quit, every launch cold-boots.
- No writable overlay: the guest writes straight into the cloned page store.
  There is no Erase All Content and Settings path yet; delete the clone.
- `qemu_ios_ui_display_sleeping()`, `guest_shutdown_confirmed()` and
  `storage_failed()` read iPod devices and are always false on the iPad, so
  Lock never dims the window and a guest power-off is not detected.
- Shake, tilt, battery, pasteboard and rotation chords set iPod machine
  properties; on the iPad they log an error and do nothing.
- Second-finger gestures use the multi-touch path and are untested on the
  Zephyr2 model as wired for the iPad.
- User-facing copy still says "iPod" in menus and alerts.

## Verifying frames without the app

`qemu_ios_ui_frame()` returns the console's pixels; the kernel draws a small
glyph top-left before userland, so a lit frame means the bridge works:

    cc -o framecheck framecheck.c    # loads the dylib, boots, counts lit pixels
    ./framecheck build/libqemu-arm.dylib framecheck \
        -M ipad1,kboot=.../k48-kboot.bin,nand=<clone> -display none -serial null

(`framecheck.c` is a 50-line harness kept out of the repo; write it against
`qemu_ios_main`, `qemu_ios_ui_frame`, `qemu_ios_ui_quit`.)
