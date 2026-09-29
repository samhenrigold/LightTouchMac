# Checks that still compile a string slice of a production file

A slice is `source[source.index('marker'):source.index('other marker')]` over a file under `LightTouchMac/`,
wrapped in a fixture that stands in for the rest of the file. It breaks whenever the markers move. E4
(docs/sweep/PLAN.md) converted every check whose sliced section could be a file of its own — `DeviceExecution.swift`
(deadline race, serial gate, errors, timeouts), `BootRecipe.swift`, `DeviceRow.swift`, `DiagnosticsExport.swift`,
`DeviceProfile+Display.swift` — and those checks now compile the whole file. What is left slices one of the five
hub types, whose members need the rest of the app; the fix is the extraction each row names, not a stub.

| Check | Slices | Why it still slices; what retires it |
|---|---|---|
| offline/check-app-events, check-app-launch, check-clean-shutdown, check-device-keyboard, check-factory-reset, check-preparation-wake, check-tilt-game-input, check-device-health, check-device-recovery; sessions/check-activation-gate, check-boot-deadline | `EmulatorController.swift` (boot deadline, activation, health probes, shutdown ladder, keyboard, wake) | A 1.7k-line controller whose every method touches the session, the helper link and the views; the checks drive one method against a fake link. Retired by proposal 2's service layering (E6): the methods move onto `Services/` types that compile without the controller. |
| offline/check-app-row-layout, check-app-row-refresh, check-apps-menu, check-extracted, check-install-queue-scope, check-ipa-library, check-media-queue, check-uninstall-queue, check-app-launch, check-media-drop, check-device-health; run-catalog-checks `--ui` | `AppsInspectorViewController.swift` (`InstallJob`/`AppInstaller` queue state machine, row identity, drop classification) | The install state machine lives inside the NSViewController. Retired by proposal 5 (`AppInstaller.swift`, `DroppedFiles`), after which these compile the new files whole. |
| offline/check-capture-destination, check-capture-shortcuts, check-device-menus, check-window-restoration, check-zoom | `MainWindowController.swift` (menu validation, capture availability, zoom steps, window restoration) | Same: the logic is methods of the window controller. Retired by proposal 5's `CaptureController` extraction and moving `validateMenuItem`'s device branches onto the session. |
| offline/check-chassis-drag, check-keyboard-pointer, check-panel-capture, check-rotation, check-media-drop, check-tilt-game-input, check-zoom | `DisplayView.swift` (gesture math, pointer mapping, panel capture, drop classification) | Gesture math inside an NSView; the app.md survey skips extracting it until a second board needs it. |
| offline/check-install-startup (the `Install (instproxy_install` section), check-upload (`validateFilePath`, `stage`), check-staging-ownership, check-extracted | `DeviceServices.swift` (the transport struct) | The checks fake the dlsym'd libimobiledevice calls the struct makes; a whole-file compile would make the real ones. Retired by proposal 2's `Transport/` seam (an injectable `IMobileDevice`). The support half of these checks (deadlines, gate, errors) is already `DeviceExecution.swift` whole. |
| offline/check-help, check-settings, check-termination, check-window-restoration | `AppDelegate.swift` | 300 lines that reach `MainWindowController`, `DeviceLibrary`, `FirmwareJobs`, `EmulatorController`; a stub for those is the app. Retired with the two rows above. |
| offline/check-reap-reason; sessions/check-sessions | `DeviceSession.swift` (`DeviceProcess`, the helper section) | `DeviceProcess` is Foundation-only but sits next to `DeviceSessionHost`, which owns the view controllers. One more split (`DeviceProcess.swift`) retires both; not done here because check-sessions' driver and the reap check pin its private members by marker. |
| offline/check-storage-lifecycle | `AppMetadataCache.swift` (`prepareDirectory`, `save`) | The cache reads `.ipa`s with `NSImage`; the check wants only its directory policy. Retired when the directory policy moves to `StorageLocations`. |

Not production slices, listed so nobody hunts for them: `offline/check-model-startup` slices its sibling
`check-model.py`'s fixture; `release/check-package-layout` and `release/test-signing` run functions cut out of
`scripts/package.sh` (shell, not Swift); `sessions/matrix.py`, `release/test-dependency-sources.py` use `index()`
on their own data.
