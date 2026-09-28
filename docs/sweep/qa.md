# Sweep survey: app QA (2026-09-28, headless)

# QA sweep report — LightTouchMac multidevice (d1b3ce4 tip, includes fb36fb3 storage fixes)

Headless only, through the notarized bundle's own `LightTouchDevice`, `libqemu-arm.dylib` (build a86f1133) and `usbmuxd`, on APFS clones of prepared devices under `/tmp/qa-sweep` (all deleted at the end). No app launch, no State dir touched, every boot `-audio driver=none`. Two runs used the existing checks (`tests/check-sessions.py` on `ipad4-app-bugs` with the shipped armv7.itpack; `--guest` on `multidevice`); the rest was a small throwaway orchestrator (per-device usbmuxd on free ports + `--headless` configs + Homebrew `ideviceinfo/ideviceinstaller/idevicesyslog`).

Inputs: iPad 7B500 ×2 (clones of `qemu-ios-files/ipod-ipsw/merge/7B500/device`), iPad 8C148 (`merge/8C148/device`), iPod 7E18 (`merge/7E18/device` and `devices/7E18-a`), iPod 8C148 (`devices/8C148-b`), iPod 5F138 (`devices/5F138-d`). Caveat that matters below: all of these are Python `device.py` outputs from before today's tool; the release's own `firmwarekit` bases are not on disk (`build-release.py check_prepare` deletes `prepare-check/` in its `finally`, only `verify-frames/*/check.log` survive), and I did not run a prepare.

## 1. Multiple emulators at once

**Per device (code):** helper process + Mach rendezvous + IOSurface ring/status block (`Shared/DeviceLink.swift`, `DeviceRendezvous.swift`); usbmuxd process with two kernel-assigned free ports (`USBMux.start`: `-S 127.0.0.1:<free>` client, `USBMUXD_QEMU_ADDR 127.0.0.1:<free>` guest, `-C Devices/<uuid>/usbmuxd-conf`); serial FIFO `$TMPDIR/LightTouch-serial-<UUID>/` (`NativeLogging.swift:153`); logs `Logs/<bundle>/Devices/<uuid>/{serial,usbmuxd,native}.log`; web proxy is a slirp `guestfwd=tcp:10.0.2.100:3128-cmd:` inside that QEMU (`WebProxyConfiguration.swift:70`), no host port; overlay, nor.bin, snapshot, `IPAs/`, `work/lease` (flock), `work/guest-offer`; UserDefaults `deviceNotice.<uuid>`, `motionPose.<uuid>`. No QMP socket, no gdb port at run time (firmwarekit's keybag one-shot uses `-gdb tcp:127.0.0.1:PORT`, prepare-time only).

**Shared / global (code):**
- `DeviceGate.shared` + `setenv("USBMUXD_SOCKET_ADDRESS")` (`DeviceServices.swift:807–827`): every libimobiledevice op in the app is serialized across all devices; a 10-min install on A blocks B's AFC browse and app list. Documented as ponytail; real cost with ≥2 devices.
- `AppInstaller` statics (`AppsInspectorViewController.swift:82–112`): one `jobs` array, one `removals` dict, one `readyQueue` (`InstallationQueue`) for the whole app. **`EmulatorController.powerOff` (1300) and `requestFactoryReset` (1829) call `AppInstaller.discardAll()`, which cancels every device's queued installs and removals**, and `pauseIfNeeded` (405) pauses the queue for every device after one device's transient error. `InstallJob` has no device id and both inspectors observe `.ltmInstallStarted/.ltmInstallProgress` with `object: nil` (663–664), so device B's inspector shows device A's rows.
- `AppMetadataCache.shared` is keyed by bundle id only (names/icons shared across devices; a 3.x and a 4.x build of one app share one entry).
- App-wide UserDefaults that are really per-device: `keyboardInputEnabled`, `autoRotateWithGuest`, `tiltSnap`, `modelPresentation`, `lastDevice`.
- Fine as shared: `.app-lock`, `DeviceRendezvousServer.shared`, `FirmwareJobs.shared` (concurrent prepares allowed, disk check sums peaks), `Bundled.workDirectory/catalog-<ipaID>-<UUID>` (UUID-suffixed scratch), the app's own `native.log`.

**Headless run (two 7B500 clones + iPod 3.1.3 at once):** lit at 39.4 s / 39.6 s / 25.2 s; lockdown over each device's own socket returned `iPad1,1 3.2.2 UDID 144707f3…` on both iPads and `iPod2,1` on the iPod, no cross-talk; `ideviceinstaller install Harness.ipa` on both iPads concurrently: 2.1 s each, `Test Harness` listed on both; SIGTERM to iPad A: helper exit in 0.06 s, iPad B and the iPod still answered lockdown and kept publishing frames. `check-sessions.py --ipad-device` (ipad4-app-bugs tip, bundled helper) 16/18: kill -9 noticed in 38 ms, survivor +226 heartbeats, restart on the same overlay, Stop halts both in 0.1 s; the two FAILs are guest-package (see 4). Cost per `ps`: iPad helper 35–60% CPU while booting, 10–20% idle at home, RSS 600–740 MB (4.2.1: 690–740 MB); iPod helper 20–37% / ~7%, RSS 120–450 MB; usbmuxd 6–13 MB but 5–24% CPU (3 ms poll) — three idle devices burn about half a core in usbmuxd polling alone. Two devices of the same firmware work at the engine level (separate usbmuxd confs); the app forbids it by policy (one device per catalog entry), and the two clones carry the same UDID/serial/MACs, so if duplicates ever ship the second needs its own `--seed`.

**Proposal:** (a) make the install queue per device: move `jobs/removals/readyQueue` into a `DeviceWorkspace`-owned object, tag `InstallJob` with the instance id, filter the notification handlers; `discardAll()` becomes `discard(for: instance)`. ~half a day, `AppsInspectorViewController.swift` + `EmulatorController.swift`. (b) Keep `DeviceGate` for now but lower the usbmuxd poll (`USBMUXD_QEMU_POLL` or the fork's `-p`) once devices are idle; phase-4 "services in the helper" removes the gate. (c) Move the four per-device defaults to `instance.defaultsKey`.

## 2. Meddling with device files while running (iPad 3.2.2 headless, iPod for NOR)

The helper holds 44 descriptors under the device: base `nand/*.pages` read-only, overlay `bus*-ce*.{pages,dirty}` as `txt` (mmap), the writable `nor.bin` as `15u`. Nothing in the app watches files (`DispatchSource.makeFileSystemObjectSource` appears only in `CaptureFileMonitor.swift`).

| Action | Running helper | What the app would show | Next boot |
|---|---|---|---|
| delete overlay/* | keeps running on the unlinked inodes; `uiReady` true, `storageFailed` false; AFC still answers | nothing | after Stop the overlay directory is 0 B: **the whole session's data is silently gone**; rebooted on the empty overlay to a fresh device (the app installed earlier: gone). Lockdown didn't answer within my 3-min window on that reboot (7 USB enumeration cycles) — unverified whether the empty-overlay first boot is just slow |
| stray file in base/ | nothing | nothing | nothing; `preparedFiles` only checks kboot/nand exist; the lock's `outputs.nand.files` hashes are never verified, so a modified base is never detected either |
| rename Devices/<uuid> | unaffected (open fds) | nothing | `DeviceInstance.all` skips a directory whose name isn't a UUID or whose `device.json.id` mismatches (`DeviceInstance.swift:193–201`): the device **silently vanishes from the sidebar** and the entry offers Download & Prepare again; renaming back restores it |
| edit device.json | not run; by code the controller re-reads and rewrites it on every guest-package event (`updateGuestRecord`), so a hand edit is overwritten, and a malformed file makes `try?` return nil: guest records stop updating silently, and at next launch the device disappears (unreadable record = skipped) | | |
| replace nor.bin (iPod 3.1.3, atomic rename) | keeps its fd to the old inode, guest unaffected | nothing | on disk = the replacement; the guest's NOR writes went to the dead inode and are lost |
| delete snapshot | not run; by code only read at boot (`-incoming`); harmless while running, cold boot next |

**Recommendation:** two cheap layers, no hidden layout. (1) `chflags uchg` on `base/` after publish (one line in the publish path, cleared in `IPSWStore.removeTree`/delete): Finder then refuses to delete or rename the base with a system dialog. (2) A per-running-device `DispatchSource` on `Devices/<uuid>` and `overlay/` (`.delete | .rename | .write`) in `EmulatorController` that sets a persistent notice "Files of this iPad were changed while it was running. Stop and start it again; unsaved changes may be lost." and marks the session so Stop doesn't `msync` into a dead inode. ~half a day. Refusing Show in Finder while running is not needed; the adopted iPod's Show in Finder currently opens the whole State root (`MainWindowController.swift:382`), which should point at its `Devices/<uuid>` instead.

## 3. IPAs across devices

**Flow:** drop on the canvas or inspector (`DisplayView.droppedIPAs`, `AppsInspectorViewController.droppedIPAs`) or Add… → `AppInstaller.start(ipa, with: emulator)`. Legacy Store: `CatalogClient.download` revalidates the copy, streams to `Bundled.workDirectory/catalog-<ipaID>-<UUID>/<Name>.ipa`, verifies the sha (`details.verifyDownload`), installs, then `IPALibrary.adopt` copies it to `Devices/<uuid>/IPAs/<bundle-id>.ipa` and the scratch dir is deleted (line 252). There is **no download cache** (`CatalogClient` only memoizes icons): the same app on a second device is downloaded and verified again. Moving between devices today: drag the installed row out (it is the per-device retained copy, `IPALibrary.url`), switch device in the sidebar, drop; one window, one workspace visible, no "Install on…". No Files-app path.

**Proposal (download once, install anywhere):** content-addressed store `State/Library/IPAs/<sha256>.ipa` + `index.json` `{sha: {bundleID, version, name, catalogIpaID}}`. `IPALibrary.adopt` hashes once, stores, and `clonefile`s into `Devices/<uuid>/IPAs/<bundle-id>.ipa` (APFS clone, zero space) so drag-out and `forget` stay as they are. `CatalogClient.download` consults the index by the copy's sha before fetching. Installed-row context menu "Install on ▸ <running devices>" (from `DeviceLibrary.shared`) and `.ipa` drops on sidebar rows both call `AppInstaller.start(url, with: thatEmulator)`. Launch sweep hashes existing per-device copies into the store. Effort ~2 days: `IPALibrary.swift`, `CatalogClient.swift`, `AppsInspectorViewController.swift`, `DeviceLibraryViewController.swift`, `StorageSettingsView.swift` (one size line). Depends on 1(a) so a second device's install doesn't wait in the first device's queue.

## 4. Guest services

Status slots come from `DeviceHost.refreshStatus` (uiReady, agentStatus 0/1 alive/2 stale, glesContexts, guestPackageReported/serial/result, glesProtocol/serial); the app judges them in `EmulatorController.startGuestPackageWatch` (1126–1176) and `GuestPackage.verdict/status`.

| Firmware (base) | uiReady | lockdown | agent | package report | GL hello | jobs seen (serial) | install |
|---|---|---|---|---|---|---|---|
| iPad 3.2.2 (7B500, pre-loader lock) | 39 s | yes, Activated | 0 (none) | none; with the app's offer (check-sessions): offered serial 1, loader reports serial -1 result -99 | glesProtocol 0, contexts 3 | it_ethlink up/LinkStatus 0→1, it_prefs, it_msmquiet; it_pbd never logs | 2 s ok |
| iPad 4.2.1 (8C148, merge/) | yes | yes, Activated | 0 | none | 0, contexts 2 | it_ethlink, it_prefs | **fails at VerifyingApplication 40%**: installd `verify_signer_identity -402620402`; this base's lock has `libappsync.dylib: null` (device provenance; the release's own 8C148 verify passed 11/11 incl. install) |
| iPod 3.1.3 fresh (7E18, no hook in lock) | 25 s | yes, **Unactivated** | 1 → 2 (stale) once the display slept | none (no offer) | 0 | — | `Service prohibited` (-34) |
| iPod 3.1.3 shipping (nand-current, `--guest`) | yes | yes | v1 → v2 after the component step | none, verdict legacy | 0 | — | 4 s, launched via agent, respring, time zone ok; photo/halt steps unverified (my `--guest-tools` pointed at the bundle dir, which has no `itphoto`; the driver aborted there) |
| iPod 4.2.1 (8C148-b, made 09-27) | never | never (246 s) | 0 | — | — | iBoot: "root filesystem mount failed / Entering recovery mode" (stale device vs today's keybag work; the release's 8C148 verify passed) | — |
| iPod 2.1.1 (5F138-d) | — | — | — | — | — | no `iBoot.bin` in that device dir → QEMU "Cannot read boot image", helper exits | — |

Where the app is blind: (1) the shipped armv7.itpack has no agent (`ipad4-agent` branch's does), so `hasGuestTools == false` and "healthy" for an iPad = uiReady + lockdown answering (1154–1155); it_pbd and it_prefs have no liveness signal at all, it_ethlink only through the serial log. (2) On a pre-loader base there is no report, the verdict is `.legacy` and `statusLine` deliberately hides that text: the window says "Running" with nothing about tools or updates. (3) `glesProtocols = 0...0` (`GuestPackage.swift:62`): a shim that never says hello reads as current. (4) A guest stuck in iBoot recovery, or one that never lights, stays "Booting…" forever: the helper's headless mode has `maxSeconds`, the app has no boot deadline. (5) An unactivated guest: see 5. (6) The iPad's install-failure alert says "newer version of iOS than 3.1.3" (`AppsInspectorViewController.swift:346`).

**Surface a "Guest tools" line** with concrete states: Current (serial N, report 0–2) · Reverted (3–5, with why) · Built-in (offer serial 0) · Legacy (no loader; "Erase and prepare again to receive updates") · Unknown (no report within 30 s) · Not responding (agent 2 stale for >60 s, or for the iPad: it_ethlink never reported up in serial) · Recovery (serial matched "Entering recovery mode") · Not booted (no uiReady in 120 s). Give the iPad an agent (ipad4-app-bugs's itpack already carries `k48-ios3/bin/it_agent`) so `ping` can list which jobs answer.

## 5. Activation (verified only; no logic described)

Recording: `firmwarekit` writes `inputs.activation {input_sha256, output_sha256}` into `device.lock.json` (`Preparer.swift:182`, `N72Recipe.swift:206`), `null` when nothing ran; an `ActivationFailure` becomes `{"event":"error","code":"activation_failed"}` and exit 1 (`Preparer.swift:206`), which `PreparationJob` shows and `tests/check-firmware-jobs.py:177` covers. So a failed hook fails the prepare loudly; nothing is published. Gap: the app never reads that lock field, so a base prepared elsewhere without it (both Python iPod 7E18 dirs here: `activation_hook: null`) is accepted as Ready.

At boot the app makes **no activation check**: `EmulatorController.activationState()` (1976) exists and has no caller (dead since the torn-FS diagnostic). The only activation-aware UI is `DeviceConnectionIssue` for lockdown -32/-33; an unactivated guest answers lockdown normally and refuses every service with -34 `SERVICE_PROHIBITED`, which lands in the default case: "Couldn’t update apps — retrying…" forever, while the screen sits on Connect to iTunes (uiReady true, lit true). Verified over lockdown: iPad 7B500 ×2 Activated, iPad 8C148 Activated, iPod 7E18-a Unactivated, iPod 7E18 (merge) -34 on install (driver's `installRetry` event).

**Proposal:** in `deviceReachable`'s `didSet` (first lockdown answer) call the existing `activationState()` once per boot; anything but "Activated" sets a persistent `connectionIssue` with `blocksCommands = true` and no retry: "This iPad isn’t activated. Choose Erase All Content and Settings, then prepare it again." Map -34 to the same text. In the library row, subtitle "Prepared without activation" when `device.lock.json.inputs.activation` is null. ~2 h: `EmulatorController.swift`, `DeviceConnectionIssue.swift`, `DeviceLibraryViewController.swift`.

## 6. Other gaps (noted, not fixed)

- Quit during the non-cancellable "Installing…" phase: Quit Anyway → `cancelPendingWork` (no effect on the active C call) → helper SIGTERM mid-install; installd's `/var/tmp/install_staging.*` and the SpringBoard placeholder can outlive it (the `installPlaceholder("cancel")` defer only runs when the task finishes). Unverified.
- Uninstall while the app is frontmost in the guest: no check; iOS kills it. Low risk, unverified.
- Two installs queued on two devices: B waits for A, B's row appears in A's inspector, A's transient error pauses B (see 1).
- Prepare while a device of that firmware runs: impossible by model (`allows(.downloadAndPrepare)` needs `!isStartable`). Delete a running device: refused (`!hasSession`, same predicate in Settings ▸ Storage). Erase a running device: allowed, and drops every device's installs.
- Low disk mid-prepare: ENOSPC (POSIX, Cocoa, underlying) maps to `disk_full` (`Preparer.swift:204–211`) and the app says "Not enough disk space…"; pre-check sums the peaks of all downloads and prepares. Not exercised.
- Boot with no deadline; recovery-mode guest undetected (4).
- SIGTERM to the shipped helper logs "clean shutdown: powerdown" but exits in 60 ms with `qemu_ios_main returned 0` (and "invalid runstate transition: 'shutdown' -> 'running'" on the iPod): effectively a hard halt already; ipad4-hard-halt makes it explicit.

## QA matrix (firmware × feature)

| | iPad 3.2.2 | iPad 4.2.1 | iPod 3.1.3 | iPod 4.2.1 | iPod 2.1.1 |
|---|---|---|---|---|---|
| in-bundle prepare + boot + AFC + install | release verify 11/11 | release verify 11/11 | release verify 11/11 | release verify 11/11 | not in catalog (coming soon) |
| boot to home, headless (this sweep) | yes ×3 | yes | yes | no (stale device dir) | no (device dir incomplete) |
| lockdown + ActivationState | Activated | Activated | Unactivated (device made without the hook) | unverified | unverified |
| concurrent install (2 devices) | yes | unverified | yes (check-sessions) | — | — |
| same firmware ×2 at once | yes (clones) | unverified | unverified | — | — |
| guest package report / agent | no loader on this base; bundled itpack has no iPad agent | same | shipping: agent v2 ok; fresh: unverified | unverified | unverified |
| GL hello | protocol 0 (== "current") | 0 | 0 | — | — |
| Stop (SIGTERM) / kill -9 | 0.06 s / noticed 38 ms | 0.05 s | 0.06 s | — | — |
| file meddling | overlay/base/rename/NOR done; device.json/snapshot by code only | unverified | NOR done | — | — |
| snapshot save/restore | not run (check-helper-boot covers it per STATUS) | | | | |

## Tests worth adding (none added; each needs a ≥40 s guest boot or would fail today, so I did not open the qa-sweep worktree)

1. `check-sessions.py --ipad-device-2`: two clones of one base plus the iPod; distinct sockets, both install, Stop of one leaves the others (my manual run, made permanent).
2. `check-install-queue-scope.py`: compile the `AppInstaller` section with a fake controller; `discard(for:)` on A leaves B's job; rows carry a device id. Fails today, guards the fix.
3. `check-activation-gate.py`: session driver on a base whose lock has `inputs.activation == null` (any hook-less device.py output); assert the activation issue text, not "retrying".
4. `check-helper-boot.py --only meddle`: unlink overlay files under a running helper, SIGTERM, assert the app-side notice. Fails today.
5. `check-boot-deadline.py`: `--headless` with a missing `iBoot.bin` and with a recovery-mode base; assert the app state becomes a named error within N s. Fails today.

## Cleanup and free space

`/tmp/qa-sweep` (clones, overlays, logs, driver builds) deleted after `chmod -R u+w` (the bases' `nand/` dirs are `dr-xr-xr-x`); my one leftover usbmuxd (pid 51860) killed; no helper, usbmuxd or driver of mine remains; `~/Developer/LightTouchMac-multidevice` has 0 dirty files; no branch or worktree created. Free space: 149 GiB at start, 127 GiB now — my scratch is fully gone, so the 22 GiB went to other agents' concurrent work or purgeable space (worth a look at the lead level; `qemu-ios-files/ipad1/repro-ipad4bugs` is only 5 MB).