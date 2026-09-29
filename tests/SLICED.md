# Checks that still compile a string slice of a production file

A slice is `source[source.index('marker'):source.index('other marker')]` over a file under `LightTouchMac/`,
wrapped in a fixture that stands in for the rest of the file. It breaks whenever the markers move. E4
(docs/sweep/PLAN.md) converted every check whose section could be a file of its own, and E6 (the service layering
and the big-view-controller extractions) converted the checks its extractions cover: they now compile
`Services/InstallationProxy.swift`, `Services/AFC.swift`, `Services/DeviceServices.swift`, `Features/AppInstaller.swift`,
`Features/CaptureController.swift`, `Features/MediaImport.swift`, `UI/DroppedFiles.swift`, `Device/DeviceProcess.swift`,
`Library/StorageLocations.swift` and `Library/IPAMembers.swift` whole, against the shared stand-ins in `tests/fixtures/app-installer*.swift` and
`tests/fixtures/capture-controller.swift`. A few whole-file compiles swap a pause point or an AppKit sheet in by
text (check-install-startup, check-capture-shortcuts); that is not a slice, and each says so in its docstring.

39 checks sliced before E6; 27 still do. What is left slices one of the hubs, for members that are the
controller's or the view's own state, which none of E6's extractions moves:

| Check | Slices | Why it still slices; what retires it |
|---|---|---|
| offline/check-app-events, check-app-launch, check-clean-shutdown, check-device-keyboard, check-device-recovery, check-factory-reset, check-preparation-wake, check-tilt-game-input; sessions/check-activation-gate, check-boot-deadline | `Device/EmulatorController.swift` (notices, the launch wake, the shutdown ladder, the keyboard setting, connection recovery, erase, the readiness watch, tilt, the activation verdict, the boot deadline); check-app-launch also `AppLaunchError` out of `Guest/GuestServices.swift`, check-activation-gate `lockLacksActivation` out of `Library/DeviceInstance.swift` | E6 moved what was a service out of the controller (every forwarder, and the attachment probe, which check-device-health now compiles whole). These are the controller's state machines over its own private state (boot generation, notices, the readiness task, the helper link). Retired by splitting that state into small value types the controller holds (a notice store, a shutdown ladder, a recovery policy, an activation verdict), each compiled whole. |
| offline/check-app-row-layout, check-app-row-refresh, check-apps-menu, check-app-launch (`launch`), check-media-drop (`installStarted`), check-device-health (`readsSuppressed`, one declaration), check-extracted (`freshnessText`); run-catalog-checks `--ui` | `UI/AppsInspectorViewController.swift` (row identity and appearance, cells, the Apps menu, the table's reload) | The inspector's own table, cell and menu code; the install queue it used to hold is `Features/AppInstaller.swift`. Retired by giving the table data and the menu builder types of their own. |
| offline/check-device-menus, check-window-restoration, check-zoom | `UI/MainWindowController.swift` (the Device menu's validation, window restoration, zoom steps) | Capture is `Features/CaptureController.swift` (check-device-menus reads its availability from there). What is left is `validateMenuItem`'s device branches and the window controller's own restoration and zoom. Retired by moving the device branches onto the session. |
| offline/check-chassis-drag, check-keyboard-pointer, check-panel-capture, check-rotation, check-media-drop, check-tilt-game-input, check-zoom | `UI/DisplayView.swift` (gesture math, pointer mapping, panel capture, the drag handling around `DroppedFiles`) | Gesture math inside an NSView; the app.md survey skips extracting it until a second board needs it. The file kinds a drop carries are `UI/DroppedFiles.swift`, compiled whole. |
| offline/check-help, check-settings, check-termination, check-window-restoration | `App/AppDelegate.swift` | 300 lines that reach `MainWindowController`, `DeviceLibrary`, `FirmwareJobs`, `EmulatorController`; a stub for those is the app. Retired with the rows above. |

Not production slices, listed so nobody hunts for them: `offline/check-model-startup` slices its sibling
`check-model.py`'s fixture; `offline/check-reap-reason` cuts `DeviceTermination` out of `Shared/DeviceLink.swift`
(the link itself needs the C channel); `release/check-package-layout` and `release/test-signing` run functions cut
out of `scripts/package.sh` (shell, not Swift); `sessions/matrix.py`, `release/test-dependency-sources.py` use
`index()` on their own data.
