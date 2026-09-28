# September 19 UX corrections

- Captures default directly to Desktop. An explicitly selected destination remains respected.
- The gradient and device scene extend continuously to the canvas edges. The later September 20 toolbar-only layout removes the floating controls and gives Fit the full canvas height.
- The compact native glass controls sit 12 points above the bottom edge. Recording uses one elapsed-time label and red Stop control. Status feedback appears above the controls, with readable text and a spinner when busy.
- Capture controls and feedback occupy a nonactivating child panel, so own-window ScreenCaptureKit captures exclude them while retaining the whole canvas. Screenshots and recordings still support Screen Only.
- Store rows have aligned title/subtitle columns and fixed-width actions. The native install-progress indicator remains visible beside Cancel.
- The inspector uses its own 34-point Installed footer; Store has no empty footer or bottom accessory gap.
- Files has an independent retained window, an action row, untitled native browser columns, and a separate path/status footer. Closing and reopening preserves navigation; the window remains in the Window menu.
- The Settings window is removed. Automatic rotation and Internet access are in Device; capture destination and capture mode remain in Capture.
- The guest launch-animation regression is fixed in the sibling emulator checkout; see [the emulator write-up](UX-emulator-followups.md).

## Verification

The normal Debug Xcode build succeeds. Targeted checks cover control/status geometry at 360/500/720-point widths, Files navigation and geometry at 360/660/900 points, app-row layout and progress, menus/preferences, Desktop capture destinations, physical display measurements, recording/export lifecycle, own-process capture crops and child-window exclusion, Help, and shutdown handling.

The initial September 19 visual review was blocked by a locked desktop. On September 20 the native controls and live canvas were inspected on the unlocked desktop; see [the Device Hub implementation notes](DeviceHub-capture-interface.md) for the current scope and evidence. The earlier RealityKit first-frame check could not obtain a drawable, although its controlled startup/lifetime checks passed. The Bluetooth/animation checks used the emulator’s native framebuffer.

## Follow-up: menus, capture controls, recovery, and erase

- Device groups orientation, volume, and networking into shallow submenus. Diagnostics and boot switches are under Help → Device Tools. The automatic rotation command is **Rotate Automatically**.
- Capture keeps the common screenshot and recording commands together. Less frequent file export/recovery actions are in File; Live Text is in Edit. Discard Recording appears only during a recording. Menu grouping follows the supplied 2014 OS X HIG (menu organization and hierarchical menus, printed pages 77–78 and 105).
- **Superseded on September 20:** capture actions now live in the toolbar, with no Show/Hide Capture Controls command or canvas inset. Only transient feedback uses the child panel, which detaches/reattaches on activation and window changes.
- Device Hub’s `DeviceKit.framework` Swift metadata identifies separate capsule/circle action groups, safe-area padding, Home, Screenshot, Recording, and Rotate controls. The revised bar follows that structure: a compact Home/camera/record capsule and separate rotation circle; recording adds black elapsed time and a red Stop button. It now uses the same regular, non-interactive SwiftUI glass recovered from DeviceKit, with a material fallback. The September 20 pass replaces the original AppKit approximation; measurements and visual verification are recorded in the Device Hub notes.
- Repeated management failures trigger a bounded, rate-limited restart of the guest’s lockdownd service over the independent guest channel. Recovery skips app installs and file transfers. The iPod is not rebooted and its app data is not modified by recovery.
- Shutdown now submits a kernel halt through that independent channel before resolving any USB tools. A missing USB session cannot block that route. The shell still requires the emulator’s final PMU power-off confirmation to call the shutdown clean.
- Erase now stops the native VM, removes its writable NAND/NOR and saved states, and then closes the app. A failed stop leaves storage untouched. A failed erase remains visible and retryable. No erase is deferred to a future launch; legacy pending markers are cleared with an explanation.

The updated Debug build succeeds without Swift compiler warnings. Native regression checks pass for menus, preferences, animated panel lifecycle, rapid hide/show, simulated application activation, file/inspector layout, recovery cooldown and transfer guards, independent shutdown without USB, and erase ordering/failure handling. Storage checks also cover adoption of the bundled base after explicit erase.

The SpringBoard-deletion issue was tested with a cloned copy of the affected writable storage. In the full production shell, Mactracker was installed, deleted through SpringBoard’s Delete and No Thanks dialogs, removed from three subsequent app queries, and followed by a confirmed clean shutdown. That run **did not reproduce the original intermittent failure**, so it does not establish its root cause. The connection-recovery and shutdown fixes protect the failure paths independently; see the emulator follow-up for the remaining diagnostic scope.

## Xcode debugger signal handling

During live verification, Xcode had paused the emulator on SIGUSR2 inside `__sigsuspend`. QEMU deliberately uses that signal to create coroutine stacks (`util/coroutine-sigaltstack.c`); treating it as a debugger stop can leave the guest and shutdown stalled. The shared launch scheme now loads `Configuration/Debug.lldbinit`, which passes SIGUSR2 to QEMU without stopping or notifying. Xcode MCP confirmed PASS=true, STOP=false, NOTIFY=false after a fresh debug launch. The app subsequently quit through its normal shutdown path and relaunched successfully. This fixes that concrete debugger interruption; it does not establish the cause of every earlier device-management failure.
