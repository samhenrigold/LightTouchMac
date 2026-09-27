# iPad frame (stand-in)

`LightTouchMac/Assets.xcassets/ipad-frame.imageset/ipad-frame.png` is the iPad chrome from the
iPhone Simulator in Xcode 3.2.4 and iOS SDK 4.1 (`iPhoneSimulatorSDKTools.pkg`,
`iPhone Simulator.app/Contents/Resources/Devices/iPad.deviceinfo/portrait.png`, 852x1108). It is
here until the iPad has a 3D model like the iPod's N72. It will replace this.

`iPad.deviceinfo-Info.plist` and `home.png` are that bundle's metadata and pressed-Home overlay,
kept for reference:

- `width`/`height` 768x1024: the screen sits centred in the frame, at (42, 42).
- `homeOriginX`/`homeOriginY` (412, 9, bottom-left origin) and the 29x31 `home.png` give the
  Home circle: diameter 31, bottom inset 9.

These numbers live in `DeviceProfile+Display.swift`. `tests/check-ipad-frame.py [panel.png]` checks
them against the asset and optionally writes `composite-check.png`: the frame with a qemu-ios panel
dump turned upright into the cutout, the way `DisplayView` draws it. `composite-settings.png` and
`composite-landscape.png` are the same with Settings, portrait and after rotating to orientation 3.
