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
| Download & Prepare / Prepare | the row's button: Prepare when the IPSW is already here | |
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
| Licenses | Help's last section: each shipped component and its license; the texts and SOURCE.txt files in Contents/Resources/licenses | Acknowledgements, third-party notices |

## State names

The same state has the same words on every surface (sidebar accessory, placeholder, status line, VoiceOver).

### Device (sidebar row: `DeviceRow.stateDescription`; placeholder: `DevicePlaceholderViewController`)

| State | Words | Notes |
|---|---|---|
| notDownloaded | Not downloaded (, 580 MB) | row: a tertiary download glyph (`arrow.down.circle`), the words and size in its tooltip and VoiceOver |
| downloaded | Downloaded | VoiceOver only; the row shows nothing (the usual state) |
| downloading | Downloading, 43% / Downloading… (row: ring and “43%”) | placeholder: one line under the bar, “43% · About 1 min remaining”; a build that also fetches its keybag sibling says “2 IPSWs” in the bar’s tooltip |
| preparing | Preparing, 48% / Preparing… (row: ring and “48%”) | placeholder: the same one line; the step and the preparer’s words are the bar’s tooltip |
| ready | Ready | |
| running | Running | |
| stopping | Stopping / Stopping… | |
| error | Error, with the reason below | reason is the failure or stop text |
| comingSoon | Coming soon | |
| untested (note) | Untested (row tooltip and VoiceOver, never drawn in the row) / “Untested.” before the catalog note in the placeholder’s info popover (ⓘ beside the version) | not a state: an untested build downloads and prepares like any other |
| requiresIPSW | Requires an IPSW | |
| experimental (tag) | Experimental | row tooltip and VoiceOver, no capsule; placeholder: “Experimental.” and the catalog `status_note` in the info popover |
| prepared without activation (note) | Prepared without activation | |
| beta / GM (tag) | Beta 1, Beta 3, GM 1, GM 2 | always numbered; secondary text after the version, no capsule |

### Status line (`EmulatorController.statusLine`, window subtitle and dead overlay)

| State | Words |
|---|---|
| erasing | Erasing iPod… |
| storage write failed | Couldn’t save to disk — iPod stopped; recent changes weren’t saved |
| shutting down | Stopping… |
| powered off | Powered off |
| not started | Starting… |
| booting | Starting iOS… |
| boot toast | Starting iOS… over the stage and the session’s counter, “Loading iOS · 42 s”, with a Device Logs button throughout. Stages (`BootStage`, from serial lines, the guest tools and USB, never a timer): Powering on, Loading iOS, Starting the system, Connecting over USB, Waiting for the Home screen |
| readiness wait | Starting iOS… then Waiting for the Home screen… (`preparationStatus`) |
| running | Running (the window subtitle shows the foreground app instead when there is one) |
| running, guest tools need attention (out of date, reverted, not responding) | Running — Guest tools: *state* |
| running, no USB | Running — USB unavailable |
| sleeping | Sleeping |
| restarting SpringBoard | Restarting the Home screen… |
| startup failed | Startup failed — *reason* |
| paused | Paused |
| dead | Stopped (overlay: the stop reason) |
| a persistent connection issue | the issue's summary |

Stop reasons (`DeviceSession`): "The iPod stopped." (asked for), "The iPod stopped unexpectedly. Open Device Logs for details." (not asked for), "The iPod didn’t start. Open Device Logs for details.", "This device is in use by another copy of Light Touch.", "The iPod didn’t start within N seconds. Open Device Logs for details." (only when iOS never showed a picture: `ReadinessDeadline`), "The iPod entered recovery mode instead of starting iOS. Delete it and prepare it again. Open Device Logs for details."

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
| not enough space to prepare | Not enough disk space: this needs X, and Y is available. (placeholder: only when the volume is short; no sizes otherwise) |
| iOS on screen, USB not answering by the boot budget (the device keeps running) | The iPod is running, but it isn’t connected over USB yet. Installing apps and transferring files aren’t available until it connects. |
| files changed under a running device | Files of this iPod were changed while it was running. Stop and start it again; unsaved changes may be lost. |
| older data | This iPod’s data was made with an older system image. |
| legacy erase (a window while it runs) | Erasing the earlier iPod… (alert before it: “The iPod from an earlier version of Light Touch can’t be used.” / “Erase it and continue (apps you’ve saved are kept), or quit.”) |

### Web proxy (`WebProxyStatus.message`)

| State | Words |
|---|---|
| waiting | Waiting for iPod… |
| applying | Updating proxy… |
| ready | (nothing) |
| failed | Couldn’t update the proxy. Try again. |
| needsTap (no guest agent: the profile was offered) | Tap Install on the iPod to trust the proxy certificate. |
| Settings ▸ Storage | Devices (Base · Data · Snapshot), IPSWs (Downloaded / Imported IPSW), Caches and logs, Library (N IPAs · size · size on no device) |

### Install failures

Every failed install, download or removal writes its whole error to app.log (`install: <name> failed: …`, with a DecodingError's coding path; `Legacy Store: HTTP <code> for <path>`). A Legacy Store response that doesn’t decode reads “Legacy Store sent a response Light Touch couldn’t read.”, never Foundation’s “isn’t in the correct format”.

### Store on iPhone OS 1.x

The suggested list isn’t asked for: “iPhone OS 1.1 has no App Store.” A search still lists apps greyed with “Requires iOS 2.0”.

### Store rows the device can't run (`CatalogApp.incompatibility`, Legacy Store `compat.reasons`)

A search lists them greyed, with the first reason as the subtitle and no Install; the suggested list leaves them out.

| Reason | Words |
|---|---|
| no runnable slice, or an armv6 slice that is ARMv7 code | Needs a newer processor (copy check: This copy needs a newer processor than this device has.) |
| requires_ios_x.y | Requires iOS x.y |
| device family, capability:!key | Not made for this device |
| capability:key | Needs hardware this device doesn’t have |
| encrypted | Encrypted — can’t open in Light Touch |
| unavailable | Download no longer available |
| not_analyzed | Not checked for compatibility yet |
| anything else | Not compatible with this device |
