# Copy reference

How Light Touch talks to the user. Check new strings against this; change this file when a term changes.

## Rules

- Say what happened and what to do next. If the user can't act on a detail (an exit code, a signal, a package serial, a lockdown code, a file inside an IPA), it goes to the log line (`logEvent`) and the text says "Open Device Logs for details." at most.
- Cut copy that answers a question the user wouldn't ask: no reassurance about fixed bugs, no captions that repeat a label, no "use Find to search".
- Calm: no exclamation marks, no "Oops", no blame.
- Sentence case for status lines, badges, labels, alert titles and messages. Title case for menu items, buttons and toolbar labels (macOS convention).
- Typography: ’ for apostrophes, “ ” for quotes, … for ellipses (an action that opens a dialog or is in progress ends in …), — for the break in a status line.
- Contractions: "Couldn’t", "isn’t", "didn’t", not "Could not".

## Glossary

| Use | For | Don't use |
|---|---|---|
| the device's name (`profile.shortName`: "iPod", "iPad", any later model) | the emulated device, when the profile is at hand | hard-coded "iPod", "the emulator", "the guest" |
| device | the emulated device, when no profile is at hand; menu "Device" | emulator, VM, guest, helper |
| [Device] | Help text for a menu item that carries the device name ("Show [Device] Files") | a specific model |
| Light Touch | the app | LightTouchMac, "this build" (say "this copy of Light Touch") |
| prepare, preparing, prepared | turning an IPSW into a device (`firmwarekit create`) | preparer, bake, build, create |
| download | fetching an IPSW | prepare |
| Download & Prepare / Prepare | the row's button: Prepare when the IPSW is already here or built in | |
| Import IPSW… | using an IPSW from disk | |
| IPSW | the firmware file, in user text | firmware image, restore image |
| guest tools | the in-device helpers (agent, loader, packages) | agent, it_agent, package, serial, itpack |
| app services | the USB services that list, install and remove apps | libimobiledevice, lockdown(d), usbmux, installd, instproxy |
| the Home screen | SpringBoard | SpringBoard |
| start, starting | booting; "Starting iOS…" | boot, booting, kboot, iBoot, it_boot |
| stop, stopped, stopped unexpectedly | the device's session ended; unexpectedly = nobody asked | helper exited, killed, signal |
| Power Off / Power On | the guest's own shutdown, Light Touch stays open | |
| Erase All Content and Settings | wiping a device's data | reset, factory reset |
| Delete Device | removing the device from the Mac | |
| a component is missing … Reinstall Light Touch | a bundled binary or library is absent | brew install, tool names |

## State names

The same state has the same words on every surface (sidebar accessory, placeholder, status line, VoiceOver).

### Device (sidebar row: `DeviceRow.stateDescription`; placeholder: `DevicePlaceholderViewController`)

| State | Words | Notes |
|---|---|---|
| notDownloaded | Not downloaded (, 580 MB) | size only in VoiceOver/row |
| downloaded | Downloaded | |
| bundled | Built in | |
| downloading | Downloading, 43% / Downloading… | |
| preparing | Preparing, Step 6 of 7 · 48% / Preparing… | step name below the bar |
| ready | Ready | |
| running | Running | |
| stopping | Stopping / Stopping… | |
| error | Error, with the reason below | reason is the failure or stop text |
| comingSoon | Coming soon | |
| untested | Untested | |
| requiresIPSW | Requires an IPSW | |
| experimental (tag) | Experimental | catalog `status_note` replaces the placeholder note only when it adds something |
| prepared without activation (note) | Prepared without activation | |

### Status line (`EmulatorController.statusLine`, window subtitle and dead overlay)

| State | Words |
|---|---|
| erasing | Erasing iPod… |
| storage write failed | Couldn’t save to disk — iPod stopped; recent changes weren’t saved |
| shutting down | Stopping… |
| powered off | Powered off |
| not started | Starting… |
| booting | Starting iOS… |
| readiness wait | Starting iOS… then Waiting for the Home screen… (`preparationStatus`) |
| running | Running — Guest tools: *state* |
| running, no USB | Running — USB unavailable |
| sleeping | Sleeping |
| restarting SpringBoard | Restarting the Home screen… |
| startup failed | Startup failed — *reason* |
| paused | Paused |
| dead | Stopped (overlay: the stop reason) |
| a persistent connection issue | the issue's summary |

Stop reasons (`DeviceSession`): "The iPod stopped." (asked for), "The iPod stopped unexpectedly. Open Device Logs for details." (not asked for), "The iPod didn’t start. Open Device Logs for details.", "This device is in use by another copy of Light Touch.", "The iPod didn’t start within N seconds. Open Device Logs for details.", "The iPod entered recovery mode instead of starting iOS. Delete it and prepare it again. Open Device Logs for details."

### Guest tools (`GuestPackage.Status.text`, after "Guest tools: ")

| State | Words |
|---|---|
| current | Up to date |
| builtIn | Built in |
| outOfDate | Out of date — restart to update |
| reverted | Using an earlier version — the update didn’t work / kept failing / was refused |
| legacy | Won’t update — erase and prepare again to get updates |
| notResponding | Not responding |
| recovery | Unavailable in recovery mode |
| notBooted | Waiting for iOS |
| unknown | Unknown |

The serial and verdicts are in the log (`guest package: …`).

### Connection issues (`DeviceConnectionIssue.summary`; detail in the banner's tooltip and the log)

| Condition | Words |
|---|---|
| not activated (persistent) | This iPod isn’t activated. Choose Erase All Content and Settings, then prepare it again. |
| install in progress | Updating apps… |
| app services missing | App connection unavailable |
| locked | Unlock the iPod to connect |
| pairing refused | Couldn’t pair with the iPod |
| services starting | Waiting for app services… |
| activation service refused | iPod activation unavailable |
| USB gone | USB connection lost — retrying… |
| USB slow | USB connection delayed — retrying… |
| connection dropped | App connection interrupted — retrying… |
| anything else | Couldn’t update apps — retrying… |

Apps inspector banner: Device powered off, Device powering off…, Reconnecting app services…, USB connection unavailable, Transfers paused.

### Storage and notices

| Condition | Words |
|---|---|
| storage writes failed (notice) | Couldn’t save to disk. The device stopped and recent changes weren’t saved. Free disk space, then reopen Light Touch. Open Device Logs for details. |
| low disk space | Your Mac is almost out of disk space: X is available, and Light Touch needs at least Y to save changes reliably. |
| not enough space to prepare | Not enough disk space: this needs X, and Y is available. |
| files changed under a running device | Files of this iPod were changed while it was running. Stop and start it again; unsaved changes may be lost. |
| older data | This iPod’s data was made with an older system image. |
| Settings ▸ Storage | Devices (Base · Data · Snapshot), IPSWs (Downloaded / Imported IPSW), Caches and logs, Library (N IPAs · size · size on no device) |
