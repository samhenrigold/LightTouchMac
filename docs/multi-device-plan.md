# Multi-device Light Touch: implementation plan

Status: plan of record, 2026-09-28. Branch `multidevice`, based on `ipad1`.

This implements the 2026-09-27 modularization and device-library proposals (untracked drafts that never
reached a branch) as a product.

**Decisions (Sam, 2026-09-28):**
- **One helper process per running device.** QEMU can't re-init in-process.
- **The IPSW → device pipeline is ported to Swift.** The Python imgtools in qemu-ios stay as the test oracle.
- **Keys are bundled with the catalog.**

**Hard rules:**
- **Activation is automatic.** FirmwareKit activates and re-signs the staged system as a built-in preparation step. There is no activation setting, executable path, or catalog policy.
- **Firmware and Apple assets never enter a repo.**
- **Nobody but Sam launches the app.** Verification is headless, e.g. `LightTouchDevice --headless`.

## A. Processes

| Process | Binary | Role |
|---|---|---|
| App | `LightTouchMac` | Sidebar/library, catalog, downloads, UI. `EmulatorController` (EC) keeps its policy per device. usbmuxd per device. libimobiledevice services in phase 1. **No QEMU in-process.** |
| Device helper, one per running device | `Contents/MacOS/LightTouchDevice` | Loads `libqemu-arm.dylib` and runs `qemu_ios_main` on a 16 MB-stack thread. Frames go to IOSurfaces and status to shared memory. It also handles commands, agent RPC and audio capture, and exits when QEMU returns. `--oneshot` mode runs the seal and keybag boots. `--headless config.json` is for tests. |
| Preparer, one per job | `Contents/MacOS/firmwarekit` (Swift CLI over FirmwareKit). DEBUG only: a Python bridge. | Staging, then decrypt/build, the one-shots via the helper, atomic publish, JSON-lines progress. |
| usbmuxd, one per device | existing fork | Per-instance ports, conf dir and log. |

**The helper is a bundled executable the app spawns, not an XPC service.**
- An XPC service is single-instance per app.
- XPC services respawn slowly, and every stop is an exit.
- launchd may kill an idle service.
- XPC services inherit no environment or stdout.
- A bundled executable can also be run headless from tests.

**Rendezvous** (`Shared/DeviceRendezvous.swift`, `Shared/CLink/ltm_link.c`). A dynamic `NSXPCListener` is refused (Risk 1), so:
- The app checks in `<bundle id>.devices.<app pid>` once with `bootstrap_check_in`, and a thread receives hellos on it.
- The app spawns `Contents/MacOS/LightTouchDevice --connect NAME --token T --instance UUID` with `posix_spawn` (`Process` can't pass an extra descriptor): stdin `/dev/null`, stdout+stderr on the caller's descriptor (the instance's `native.log` via `ProcessLogCapture`), one end of a `socketpair` as fd 3, `POSIX_SPAWN_CLOEXEC_DEFAULT` and default signal dispositions.
- The helper sends a Mach **hello**: the token, the protocol version, a ring generation and the `IOSurfaceCreateMachPort` send rights of [status block] at start, then [status, ring0, ring1, ring2] for each ring (the first frame, and any resize).
- Every hello is validated before a port is used: the audit-token pid is one this app spawned and hasn't reaped; the code behind that audit token satisfies the requirement (`anchor apple generic and certificate leaf[subject.OU] = "<the app's Team ID>"`; an ad-hoc app falls back to the helper's own designated requirement, its cdhash); the token matches; the version matches. The name is visible to the whole session; the socketpair isn't, so only the hello needs the gate.

**Lifetime:**
- The helper watches its parent (a process-exit source on the ppid, plus EOF on fd 3), and treats SIGTERM/SIGINT the same. It then runs the device's clean shutdown, bounded by EC's `cleanShutdownBudget` (60 s), quits QEMU and exits:
  - iPad: `qemu_ios_ui_powerdown`, wait for `guest_shutdown_confirmed` (≤ 30 s; ~15.6 s measured).
  - iPod: the agent's `halt` (`reboot2(RB_HALT)`, what `requestIndependentHalt` sends) when `agent_status == 1`, wait ≤ 30 s (1.3 s measured), then powerdown as the fallback. The SSH `ithalt` path needs the app's usbmuxd, so the helper doesn't use it.
- The app sees a helper death (`onInvalidated`, then `onTerminated`, ~11 ms after a `kill -9`) and sets the session to `.dead(reason)` with **Restart**. `quitForRelaunch` leaves the self-heal path.
- The helper holds `beginActivity(.userInitiated, .latencyCritical)` from boot to exit.
- **The helper never calls `dispatchMain()`**: the dylib's `rcu_init` registered the main thread, so the main thread stays in `CFRunLoopRun()`.

**Helper modes** (`LightTouchDevice/main.swift`). The dylib is `$LTM_QEMU_DYLIB`, else `@executable_path/../Frameworks/libqemu-arm.dylib`, else `@rpath` (Debug: `QEMU_BUILD_DIR`). The helper never links it.
- `--connect …`: spawned by `DeviceLink`.
- `--headless config.json`: `{dylib?, boot: BootConfig, actions: ["dump NAME", "tap X Y", "drag X0 Y0 X1 Y1", "button N", "key CODE", "snapshot PATH", "resume", "wait S", "shutdown", "quit"], dumpDir, litFraction, maxSeconds}`. PNG dumps come from the ring; JSON lines (`ring`, `status` each second, `lit`, `dump`, `snapshot`, `exit`) go to stdout.
- `--oneshot config.json`: `{dylib?, boot, serialLog, stopMarker?, timeout}`. It runs until QEMU exits by itself or the serial log contains `stopMarker`, then prints `{"event":"oneshot","exited","exitCode","marker","seconds"}`. Exit 0 on the marker, QEMU's code on a natural exit, 124 on the timeout. This replaces `qemu-system-arm` in the seal and keybag boots.
- `--probe MACHINE`: loads the dylib and prints the hello's `HelperInfo` (packaging tests).
- Exit codes: QEMU's; 64 usage, 70 no dylib, 72 the rendezvous failed.

### Link protocol — `Shared/DeviceLinkProtocol.swift` (both targets)

Framed JSON on the socketpair: a 4-byte big-endian length, then one message, at most `DeviceLinkWire.maxMessageBytes` (4 MiB; a bigger frame closes the link). Writes go through a serial queue per end, so a wedged peer never blocks the app's main thread. `protocolVersion = 1` covers the messages, the status layout and the Mach hello.

```swift
enum AppMessage: Codable { case command(LinkCommand), request(id: UInt64, LinkRequest) }   // app -> helper
enum HelperMessage: Codable { case reply(id: UInt64, LinkReply), event(LinkEvent) }         // helper -> app
enum LinkCommand: Codable {           // fire-and-forget, in order
  case touch(slot: Int, phase: Int, x: Double, y: Double), touch2(phase: Int, x: Double, y: Double),
       button(Int, down: Bool), key(macKeyCode: Int, down: Bool), rotate(clockwise: Bool), shake,
       attitude(pitch: Double, roll: Double, pose: Int), paste(String), machine(MachineOp /*pause,resume,reset,powerdown,quit*/),
       snapshotSave(path: String), snapshotResume, agentCancel(id: String), audioStop(generation: UInt64) }
enum LinkRequest: Codable {           // exactly one reply per id
  case hello(protocolVersion: Int, machine: String?), boot(BootConfig), snapshotStatus,
       agent(request: String, deadline: Double), audioStart,
       battery(level: Int, charging: Int), usbConnection(Bool), compass(Int), usbCharger(Bool), orientation(Int) }
enum LinkReply: Codable { case hello(HelperInfo), ok(Bool), snapshot(status: Int, error: String?), agent(String?),
                          audio(generation: UInt64), failure(String) }
enum LinkEvent: Codable { case qemuExited(Int32), audio(generation: UInt64, seconds: Double, pcm: Data),
                          audioEnded(generation: UInt64, failed: Bool) }
struct BootConfig: Codable { var argv: [String]; var environment: [String: String]; var machine: String }  // machine picks the orphan shutdown
struct HelperInfo: Codable { var protocolVersion: Int; var pid: Int32; var dylibPath: String; var dylibModified: Double
                             var buildID: String?; var deviceInfo: DeviceInfo? }   // qemu_ios_device_info(hello.machine)
```

- `hello` is always first; the helper replies `.failure` for another protocol version, or when no dylib loaded (then it exits 70).
- `boot` replies `.ok(true)` once the QEMU thread runs; a second boot gets `.failure`. `qemuExited` follows when `qemu_ios_main` returns, and the helper exits with that code.
- `agent(request, deadline)` takes one `qemu_ios_agent_request` wire string. The helper owns `qemu_ios_agent_result`: it routes results by id, frees them, and replies `.agent(wire)`, or `.agent(nil)` after the deadline (and cancels). `deadline <= 0` only submits and replies `.ok(submitted)` (the halt). A refused queue gets `.failure`.
- `audioStart` replies `.audio(generation)`, then pushes `.audio` events (an empty `pcm` with `seconds >= 0` marks silence). After `audioStop`, what's queued is drained (≤ 1 s), then `.audioEnded(failed: false)`. An overflow or stop inside QEMU gives `.audioEnded(failed: true)`.
- `snapshotStatus` replies QemuIosSnapshotStatus (0 idle, 1 running, 2 done, 3 failed + error).

**Frames and status** (`Shared/SharedStatus.swift`):
- **Frames:** a ring of three BGRA IOSurfaces at the guest's size. The helper copies `qemu_ios_ui_frame` into a surface that is neither `front`, nor the reader's `held`, nor `IOSurfaceIsInUse`, then publishes `front` and `frameSerial` (seq-cst). The reader (`FrameRingReader.front()`) stores `held` and re-reads the serial. The app's display link sets `layer.contents = surface` when `isNew`. A capture should `incrementUseCount()` around its read (as `FrameTools` does). Nothing crosses the socket per frame.
- **Status block:** IOSurface #0, 4 KB of UInt64 slots with atomics. Frames are published at 60 Hz, status at 20 Hz, and the heartbeat on every tick (from launch, before boot). Slots: `magic ("LTMSTAT2"), layoutVersion, heartbeat, frameSerial, front, width, height, ringGeneration, held, uiReady, storageFailed, shutdownConfirmed, displaySleeping, agentStatus, glesContexts, iconGeneration, qemuState (0 not started, 1 running, 2 exited), exitCode, publishTicks, helperPID`. A stalled heartbeat means the helper is wedged; stalled frames mean the guest is wedged.

### The app-side client — `Shared/DeviceLink.swift`

```swift
let link = DeviceLink(configuration: .init(instance: id, outputDescriptor: capture.writeDescriptor), queue: .main)
// Configuration: helper (default Contents/MacOS/LightTouchDevice), dylib (dev: LTM_QEMU_DYLIB), environment,
//                machine (hello's deviceInfo), requirement (nil = same Team), connectTimeout (15 s), arguments
link.onEvent = { (e: LinkEvent) in … }                 // .qemuExited, .audio, .audioEnded
link.onInvalidated = { (e: DeviceLinkError) in … }     // once: EOF, rejected hello, protocol, timeout
link.onTerminated = { (t: DeviceTermination) in … }    // once: .exited(code) / .signaled(sig) / .unknown
link.start { (r: Result<HelperInfo, DeviceLinkError>) in … }   // spawn + validated hello + hello reply
link.send(.touch(slot: 0, phase: 0, x: 0.5, y: 0.5))            // LinkCommand
link.request(.battery(level: 80, charging: 0), timeout: 10) { (r: Result<LinkReply, DeviceLinkError>) in … }
let reply = try await link.request(.snapshotStatus)
link.status        // SharedStatus?, read synchronously from the block
link.frontSurface() // (surface: IOSurface, serial: UInt64, isNew: Bool)?, for one display-link thread
link.info, link.pid, link.terminate() /* SIGTERM: clean shutdown */, link.kill()
```

Callbacks run on `queue`. Pending requests fail with `.closed` when the link goes, and with `.timedOut` after their timeout. `tests/sessions/check-helper-boot.py` drives this through `tests/drivers/helper-driver`.

### How each C call crosses

| C call (today's file) | Crossing |
|---|---|
| `qemu_ios_main` (EC.start/startIPad1) | `request(.boot)`: the helper applies `BootConfig.environment` (EC's `setBootEnv`). Then `.qemuExited` and the helper exits. |
| `qemu_ios_device_info` (DeviceProfile+Display) | Board constants in `DeviceProfile`. `hello` returns the dylib's values, and a mismatch fails the boot. |
| `ui_attach` | Internal to the helper |
| `ui_frame`, `ui_copy_frame` (DisplayView) | Status block + IOSurface; capture holds a use count on the front surface |
| `ui_touch/touch2/button/key_mac/rotate/shake/attitude/paste` | `command` |
| `ui_battery/compass/usb_charger/orientation/usb_connection` | `request`, reply `.ok(Bool)` |
| `ui_pause/resume/reset/powerdown/quit` | `command(.machine)` |
| `ui_ready`, `ui_storage_failed`, `ui_guest_shutdown_confirmed`, `ui_display_sleeping`, `ui_icon_state_generation`, `agent_status`, `gles_contexts` | Status block |
| `agent_request/result/free_result`, `agent_cancel` (DeviceTools) | `request(.agent)` (the helper polls and frees within the deadline); `command(.agentCancel)` |
| `build_id` / dladdr provenance | `hello`, cached per session |
| `snapshot_save2/_status/_resume` | `command` + `request(.snapshotStatus)` polled every 100 ms |
| `audio_capture_*` (ScreenMovieWriter) | `request(.audioStart)`, then pushed `.audio` events, then `command(.audioStop)` and `.audioEnded` |
| Audio playback | Stays in the helper |
| `setenv USBMUXD_SOCKET_ADDRESS` + DeviceGate | In the app for phase 1, with per-instance sockets. Phase 4 option: move services into the helper. |

EC stays in the app: every `qemu_ios_*` call becomes a `link.…` call. `NativeLogging.swift` stays in the app: the helper writes plain stdout/stderr, and `DeviceLink` takes `ProcessLogCapture.writeDescriptor`.

## B. Data model and storage

**`DeviceProfile` is the board profile.**
- It stays an enum (`.iPodTouch2G`/n72ap, `.iPad1`/k48ap).
- It gains `boardID, productType, marketingName, hasGuestTools, hasCompass, canChooseUSBCharger, orientationSource`, lifted out of EC's `if`s.
- Geometry becomes constants: iPod 320×480, iPad 1024×768.
- **`DeviceProfile.current` is removed** (54 references in 18 files). Each profile comes from its instance or session.

**Firmware catalog: `Resources/firmware-catalog.json` + `FirmwareCatalog.swift`.** This is distinct from the app catalog in CatalogClient. Field names follow qemu-ios `manifests/*.json`.

```json
{"format":1,"entries":[{
 "id":"k48ap-8C148","board":"k48ap","product_type":"iPad1,1","version":"4.2.1","build":"8C148",
 "status":"experimental","status_note":"…",
 "source":{"kind":"ipsw","url":"https://…","sha1":"…","bytes":0},
 "keys":{"iBoot":{"iv":"…","key":"…"},"kernelcache":{},"DeviceTree":{},"UpdateRamDisk":{},"rootfs":{"key":"…"}},
 "recipe":{"name":"k48","version":1,"storage":"16g","system_mib":1280,"data_size":"partition",
           "options":{"ca_ogl":true,"appsync":false,"web_proxy":true,"usb_net":true,"writable_nor":true,"keybag_oneshot":true},
           "gli_dispatch":"gli-dispatch-8C148.tsv","guest":{"arch":"armv7","gl_engine":"GLEngine-8C148"}},
 "emulator":{"min_protocol":1}, "estimates":{"prepared_bytes":0,"peak_bytes":0,"seconds":0}}]}
```

- `status` is one of `available`, `experimental`, `coming_soon` or `user_ipsw`.
- `source.kind` is always `ipsw`. The entry the app ships a prepared base for carries `"bundled": "device/n72ap-7E18.itbase"` (C6, 2026-09-28): a `firmwarekit create` of that entry packed as one blob (`scripts/pack-base.py`, the .itpack format), unpacked into `Preparing/<id>/` and published like any preparation on first launch (`FirmwareJobs.prepareBundled`). The entry stays `user_ipsw`, so a user can re-prepare it from their own IPSW after deleting the built-in device.

Status column:

| Entry | Status |
|---|---|
| iPod 3.1.3 | user_ipsw, bundled (the built-in device) |
| iPad 3.2.2, 3.2 | available |
| iPad 4.2.1 | experimental |
| iPod 3.1.3 from IPSW, iPod 4.2.1, iPod 2.x | coming_soon |
| Betas | user_ipsw: pinned sha1, no URL |

**`DeviceInstance` (`Devices/<uuid>/device.json`):** `id, name, board, firmware, created, base {kind: prepared, path}, storage {key, overlay, writableNOR, snapshot, usbmuxConf}, identity {seed, udid, die_id}, provenance {lock, sha256}, guest`. `base.kind` is only ever `prepared` (C6); a development base (`LTM_DEV_BASE`) has an absolute path and is never locked. There is one instance per catalog entry for now; the model doesn't prevent duplicates.

**Layout.** State = `~/Library/Application Support/gold.samhenri.LightTouchMac`.

```
State/Devices/<uuid>/{device.json, base/ (read-only prepared output), overlay/, snapshot{,.meta,.tmp,.bad}, usbmuxd-conf/, work/}
State/IPSW/<sha1>.ipsw                                           user-imported
State/Preparing/<job-uuid>/                                      staging -> atomic rename to Devices/<uuid>/base
~/Library/Caches/<bundle>/IPSW/<sha1>.ipsw(.partial,.resume)     CDN downloads
~/Library/Caches/<bundle>/Decrypted/<sha1>/                      deleted after a successful prepare
~/Library/Logs/<bundle>/Devices/<uuid>/{serial,usbmuxd,native}.log
```

**The old layout is erased once, not migrated** (C6, 2026-09-28, `LegacyState.swift`; the adoption of it in place, `LegacyAdoption`, is gone with `LaunchOptions` and every non-prepared boot path).
- Found at launch: `State/device`, `nandrw-*`, `snapshot-*`, `.reset-*`, `State/IPAs`, `AppCache`, the old logs, records whose `base.kind` is not `prepared`, and the pre-library root `Application Support/LightTouchMac`.
- One prompt: "Light Touch's built-in iPod has changed format. Erase it and continue (apps you've saved are kept), or quit." Erase & Continue keeps every `.ipa` (into the library) and the host pairing (`work/usbmuxd-conf`, seeded into the built-in device when it is published), removes the rest. Quit changes nothing.
- Test: `tests/offline/check-bundled-prepared.py` (fresh state → the built-in iPod published as `.prepared`; old layout → erased, IPAs kept, pairing copied).

### Storage policy (2026-09-28, `storage-fixes`)

**Layout.** State is the only writable root; everything a device owns is under `State/Devices/<uuid>/`:

```
State/.app-lock                                  flock: one Light Touch per library
State/Devices/<uuid>/device.json                 the record; its directory is the device
                     base/                       read-only prepared output (kept in backups)
                     overlay/, nor.bin           user data (kept in backups)
                     snapshot{,.meta,.tmp,.bad}  saved RAM (excluded from backups)
                     usbmuxd-conf/               pairing: 0700, plists 0600
                     IPAs/<bundle-id>.ipa        the apps installed on this device: APFS clones of Library blobs
                     work/                       lease, usbmuxd.pid, session.env (excluded from backups)
State/Library/IPAs/<sha256>.ipa, index.json      every installed archive once (IPALibrary); Store dedupe, "Install on ▸"
State/Devices/.deleting-<uuid>/                  a delete in progress; finished by the launch sweep
State/Preparing/<job>/, <job>.publish/           staging (excluded from backups); never a device
State/IPSW/<sha1>.ipsw                           imports (excluded from backups)
State/Recordings/                                takes in progress (excluded while recording)
Caches/<bundle>/IPSW/<sha1>.ipsw(.resume)        downloads; Caches/<bundle>/Decrypted/<sha1>
Logs/<bundle>/Devices/<uuid>/, Logs/Preparing/
```

**Rules.**
- *One writer per device.* The app holds `State/.app-lock` from startup (a second copy says "Light Touch is
  already running with this library" and quits). Each helper holds `Devices/<uuid>/work/lease` before it
  answers hello and refuses otherwise, which also covers a helper still flushing after its app died. Only the
  lock holder runs launch sweeps, and usbmuxd is only reaped as an orphan (ppid 1).
- *One device per catalog entry.* An IPSW for an entry that has a device (a drop, an import, a download) is
  refused, not prepared again.
- *Publish is one rename.* The preparer's output becomes `Preparing/<id>.publish/{base, device.json}`, which is
  renamed to `Devices/<id>`. Nothing half-made ever appears in `Devices/`.
- *Removal stays in bounds.* Erase and Delete only remove paths strictly inside the state root that are not the
  root, `Devices/`, or inside another record's directory (`DeviceStateStorage.checkRemovable`). Delete renames
  `Devices/<uuid>` to `.deleting-<uuid>`, then removes it with read-only directories made writable; it also
  removes the device's logs and its `deviceNotice.<uuid>`/`motionPose.<uuid>` defaults.
- *Scratch always goes.* Each prepare ends (published, failed or cancelled) by deleting `Decrypted/<sha1>` and
  `<sha1>.tmp`. Quit cancels every preparation; firmwarekit and the one-shot helper also watch their parent
  and cancel on its exit (images detached). The launch sweep detaches images left under `Preparing/`, then
  empties it, and removes stale `*.partial` downloads, `.*.importing` copies, `.deleting-*` directories,
  logs of devices that no longer exist, and the pre-library `Logs/serial.log*`/`usbmuxd.log*`.
- *IPSWs.* A cached or imported IPSW that fails the preparer's SHA check is deleted. Cancelling a download or
  Remove IPSW deletes its `.resume` too; only a failed download keeps resume data.
- *Disk space.* Downloading needs the IPSW's bytes plus the entry's prepare peak plus the peaks of every
  download and preparation under way; preparing needs its peak plus the others'. An import from another volume
  checks the copy's size first, and the built-in iPod checks its entry's `prepared_bytes` before unpacking. Below 2 GB free, booting and
  starting a recording show a notice but go ahead. Every message gives the amounts needed and available.
- *Backups.* Recreatable or in-flight data is excluded (above); bases and overlays stay in backups until
  prepared bases are proven reproducible from the IPSW.
- *Recordings.* A take that can't be played after launch recovery is deleted, and the log says so.
- *Settings > Storage* shows each device's allocated base, data (overlay + NOR) and snapshot sizes, the
  downloaded and imported IPSWs, the decrypt cache and logs, with Remove IPSW, Clear Caches and Delete Device.
- Tests: `tests/offline/check-firmware-jobs.py` (removal guard, Delete with a read-only base, atomic publish, decrypt
  cache, SHA mismatch, sweeps), `tests/fixtures/device-state-storage.swift` (erase GC), `tests/sessions/check-helper-boot.py
  --only lease` (two helpers on one device's lease).

## C. UI (AppKit)

**Sidebar:** `NSSplitViewItem(sidebarWithViewController: DeviceLibraryViewController)` goes in front of the existing items. It is an `NSOutlineView` with `.sourceList` style and `autosaveExpandedItems`.
- Group rows are the models: "iPod touch (2nd generation)" and "iPad".
- Child rows are versions like "iOS 3.2.2", with a trailing state accessory:

| State | Accessory |
|---|---|
| not downloaded | size |
| downloading | ring and % |
| preparing | ring and "Step n of m" |
| ready | none |
| running | green dot |
| error | ⚠ |
| unavailable | "Coming Soon" or "Requires IPSW", row disabled |

- "Experimental" shows as a tag.

**Actions** (context menu, plus a Device menu for the selection): Start/Stop, Download & Prepare, Import IPSW… (also by drag and drop), Cancel, Erase All Content and Settings…, Show in Finder, Delete Device… (optionally also deleting the cached IPSW).

**Detail area when a device isn't running** (`DevicePlaceholderViewController`):
- Dimmed shell art, model, version and build.
- A status line and one primary button: Start / Download & Prepare / Import IPSW… / Try Again.
- A progress bar with the step name.
- On error, a short reason and Show Log.
- Sizes, and the Experimental note.

**When it's running:**
- A `DeviceWorkspace {deviceVC, inspectorVC}` is cached per instance. Selecting a row swaps the view controllers, so switching is instant.
- A hidden DisplayView stops its display link while the helper keeps running.
- The window title is the device name.
- `MainWindowController.emulator` becomes `session: DeviceSession?` (the selection), and actions, validation and the toolbar follow it.

**Launch and quit:**
- On launch, the last selected instance auto-starts.
- On quit, `beginCleanShutdown` runs on every session in parallel.

**Deferred:** pausing devices in the background, and a side-by-side window.

## D. IPSW download and import (`IPSWStore.swift`, `FirmwareDownloads.swift`)

**Download:**
- Background `URLSession`, so downloads survive quit.
- Resume data from a failure goes to `<sha1>.resume`.
- A streamed SHA1 (`Insecure.SHA1`) plus a size check, then a rename to `IPSW/<sha1>.ipsw`. On a mismatch the file is deleted and the error is "download corrupted".
- Dedupe is by sha1 across Caches and State/IPSW.

**Disk space:** check `volumeAvailableCapacityForImportantUsage` before the download (IPSW bytes) and before prepare (`estimates.peak_bytes`). Report the required and available amounts.

**Import:**
- NSOpenPanel or drag and drop, then a streamed SHA1 and a catalog lookup.
- On a miss, read `Restore.plist` with `/usr/bin/unzip -p` and say one of:
  - the build is known but this isn't the pinned file;
  - this isn't a supported firmware.
- The IPSW is cloned into State/IPSW.

**Cancel:**
- A download is discarded with its resume data (only a failed download keeps it).
- A prepare gets SIGTERM, and `Preparing/<job>` is removed.
- A published device is never touched.

## E. FirmwareKit: Swift port (`Packages/FirmwareKit`, library + `firmwarekit` CLI)

- **Fixtures** are read from `~/Developer/qemu-ios-files`; tests skip when they're absent.
- **Oracle levels:**
  - (1) byte-for-byte;
  - (2) tree and catalog-record equality (path, uid, gid, mode, sha256) where hdiutil or newfs_hfs are involved;
  - (3) headless boot acceptance, meeting the fresh-device.sh criteria.

| Module | Ports | Oracle | ~lines |
|---|---|---|---|
| Archive (via `/usr/bin/unzip -p`) | zipfile use | member bytes | 60 |
| BuildIdentity (Restore.plist/BuildManifest, 2.x fallback) | ipad1_fw.components, device.py verify | component map | 120 |
| IMG3 + AES-CBC (CommonCrypto), partial-block quirks | ipad1_fw img3_*, aes_cbc | bytes | 220 |
| LZSS/complzss/Adler-32/iBootIm logo | ipad1_fw/kboot lzss, logo_segments | bytes | 120 |
| VFDecrypt | vfdecrypt.c | bytes | 200 |
| UDIF → raw + APM slice (`hdiutil convert -format UDTO` allowed) | extract_rootfs, apm_hfs_slice | bytes | 60 |
| HFS+ read (volume header, B-tree, catalog, var_owners) | hfsvol.py, setowner index | listing | 500 |
| HFS+ in-place ownership/mode edits | setowner.py, build_nand.set_owner | bytes | 150 |
| HFS+ file writes: v1 uses `hdiutil attach -nobrowse` + `diskutil mount` + `newfs_hfs` + `hdiutil resize` + `fsck_hfs -n` (stock, no root) | ipad1_rootfs.Mounted | tree | 150 |
| System-volume edits (launchd env, MSM, BT, network/PAC, helper install) | ipad1_rootfs build/bake | tree + plist | 600 |
| GLIDispatchCheck | gli_abi_problem, gld_problem | verdict | 80 |
| SharedCache symbol lookup + AppSync patch | appsync_cachepatch.py | bytes | 220 |
| MachOSigner (ad-hoc CD + entitlements; replaces ldid, which is AGPL) | ldid calls | bytes vs `ldid -S` | 350 |
| Built-in activation (recognize, patch, re-sign, sha256s in lock) | Activation | lock fields | 60 |
| DeviceTree + KBoot (memory map, identity, entry, ramdisk mode, segments) | ipad1_kboot.py | bytes | 500 |
| Identity synthesis | synth_identity, udid | bytes | 80 |
| K48 NAND store (whitening, spares, VFL/BBT, BTOC, MBR, fstab, check) | ipad1_nand.py | bytes | 800 |
| N72 NOR + NAND (legacy FTL, gid-blobs) | build_nor/build_nand/ipod2g_nand/nandblob | bytes | 900 |
| One-shots (seal, keybag) via `LightTouchDevice --oneshot` | ipad1_seal, ipad1_keybag | boot acceptance | 250 |
| Recipe k48/n72, staging, progress, cancel, publish, device.lock.json | device.py, ipad1_device, ipod2g_device | lock schema | 500 |

- **No root anywhere.**
- **Removed dependencies:** python3, cc, ldid and git. openssl is replaced by CommonCrypto.
- **Guest helpers** are prebuilt and signed at app build time, and listed in `guest-tools.json`.

## F. Packaging

- `LightTouchDevice`: hardened runtime + the qemu entitlements (`contrib/macos-app/entitlements.plist`). Its closure goes through package.sh.
- `firmwarekit`: hardened runtime only.
- The app target stops linking the dylib: the bridging header drops the qemu headers.
- `Resources/firmware-catalog.json` and `Resources/gli/*.tsv`.
- **New per-build armv7 guest payloads go into one opaque blob per arch** (`Resources/guest/armv7.itpack`, in nandpack format). Unsigned nested `.bundle`s and raw payloads trip codesign and the notary.
- The built-in iPod ships as `Resources/device/n72ap-7E18.itbase` (about 250 MB: a `firmwarekit create` of 7E18 packed by `scripts/pack-base.py` in the .itpack format), beside `bootrom_240_4`. The old `nand.itnand`, `ios3/iBoot.bin` and `nor_7E18.bin` are gone: a prepared base carries its own iBoot and NOR.
- **Signing order:** frameworks, then `MacOS/*` (each with its own entitlements), then the app.
- **`test-package.py` must check:** no raw NAND, no tarballs, and no `*.ipsw` or img3 magic outside `.itnand`/`.itpack`.
- The Python bridge is `#if DEBUG` only, and `test-release.py` checks for it.
- **Notarize a helper build in phase 1.**

### Multi-device release build

`scripts/build-release.py --stage …` runs the release as resumable stages. Each stage takes under 10 minutes and skips work that is already current, so run them one at a time (or `--stage all`). Without `--stage`, the one-step build runs everything (including `build-package-native.sh`) from the same pinned sources.

**The pin.** `build-support/sources.json` names the qemu-ios commit (branch `ipad1`), its expected checkout path and development build directory, and the usbmuxd commit; `scripts/sources.py` resolves it for every script and check, and `sources.py check` prints pinned vs actual. `--qemu-source` and `--usbmuxd-source` default to the pin's paths. The build records pinned vs actual commits (`build-inputs.json` → `pin`) and refuses a Developer ID build whose qemu-ios checkout (and, one-step, usbmuxd) is not at the pinned commit, unless `--allow-unpinned`; ad-hoc builds only record. A new emulator or usbmuxd is a pin bump in this repository, and the two move together (usb-zlp needs qemu-zlp).

It needs these trees and SDKs:
- The pinned qemu-ios checkout (`~/Developer/qemu-ios-ipad1`, the `ipad1` branch, at the pinned commit) as `--qemu-ios`, with a private `--qemu-build` dir inside it. The default is `build-release-native`; the 09-28 build reused `build-w1-native`. Never use `build/`.
- A native root to reuse as `--native-deps`, e.g. `~/Developer/LightTouchMac/.build/releases/release-20260926/native`. Its prefix and static deps take longer than 10 minutes to build, so a fresh one comes from a one-step build.
- The pinned usbmuxd checkout (`~/Developer/usbmuxd-qemu/usbmuxd`) as `--usbmuxd-source`. The native stage rebuilds usbmuxd over the reused prefix from the pinned commit (`idle-poll` 33728ae on `qemu-zlp` 41631a7) through a temporary worktree, records it as `usbmuxd_commit`, and fails unless libslirp (the iPad's USB Ethernet) was found. The emulator and usbmuxd ship together: from qemu-ios `ipad1` abb1a1b817 the emulator invents no USB ZLPs, so usbmuxd must send them.
- iBoot32Patcher, which firmwarekit runs for the iPad's real-iBoot chain, is pinned in `build-support/dependencies.json` (group `tools`: LukeZGD's fork at `1ff9bd14648efae691ed23ae0abb55a4635111e3`, the build Legacy-iOS-Kit ships; archive sha256; license GPL-3.0). Both native paths (`build-package-native.sh` and `--stage native`) fetch that archive and build it with `scripts/build-iboot32patcher.sh` into `native/build/iBoot32Patcher` (arm64, macOS 14; `build.json` records commit, license and sha256). package.sh ships it as `Contents/MacOS/iBoot32Patcher`, signed with the other tools, with `LICENSE` and `SOURCE.txt` under `Resources/licenses/iBoot32Patcher/`. `K48IBootTests.patcherMatchesReference` (with `FIRMWAREKIT_IBOOT_PATCHER` pointing at a built copy) checks its output on the 7B500, 8C148 and 7B367 iBoots byte-for-byte against the Legacy-iOS-Kit v25.09.01 binary. Because the manifest and this script are native recipes, adding the patcher invalidated every earlier native root: the first `--native-deps` with it came from a one-step `build-package-native.sh` (`.build/native-iboot-ship`, 2026-09-28).
- `--sdk ~/Developer/ipod2g-re/OldSDK/iPhoneOS3.1.3.sdk` and `ldid` for the guest tools. `--assets` (`~/Developer/qemu-ios-files`) supplies only `bootrom_240_4` now; `--bundled-ipsw` (default `~/Developer/ipod2g-re/OldSDK/iPod2,1_3.1.3_7E18_Restore.ipsw`) is what the built firmwarekit prepares as the built-in iPod.
- Xcode, and the Developer ID identity plus the `ltm-notary` profile.

```
python3 scripts/sources.py check      # both checkouts at the pinned commits, clean
R=(scripts/build-release.py --output .build/releases/multidevice-YYYYMMDD
   --qemu-build ~/Developer/qemu-ios-ipad1/build-w1-native
   --native-deps ~/Developer/LightTouchMac/.build/releases/release-20260926/native
   --sdk ~/Developer/ipod2g-re/OldSDK/iPhoneOS3.1.3.sdk
   --sign-id "Developer ID Application: Sam Gold (SM75355Y6R)" --notary-profile ltm-notary)
for s in native qemu dylib guest app package notarize staple verify; do python3 "${R[@]}" --stage $s || break; done
```

What each stage does:
- **native:** usbmuxd and iBoot32Patcher.
- **qemu:** configure once, then ninja.
- **dylib:** `make-dylib-macos.sh`.
- **guest:** qemu-ios `contrib/export-guest-artifacts.sh` (through `scripts/build-guest-tools.sh`): every guest component built by its own `build.sh` from a source copy (`contrib/guest-package/build.sh`), staged as `guest/guest-tools` (the iPod set the app uploads) and `guest/ipad-guest-tools` (the flat directory firmwarekit reads: the iPad helpers, AppSync, the GL engines with their `gli-dispatch-*.tsv`, the n72 recipe's inputs, `armv6.itpack` and `armv7.itpack` at `contrib/guest-package/VERSION`'s serial; ldid-signed; `IPAD_SDK` picks the 3.2 SDK), plus the helper entitlements and headers, with `guest/manifest.json` (source commit, dirty flag, sha256 per input and per file). `validate_guest` checks the directories against the manifest, the required names (`GUEST_PAYLOADS`, `IPAD_GUEST_PAYLOADS`, the catalog's `gli_dispatch` tables) and that the checkout's HEAD and the recorded inputs are unchanged. package.sh ships the iPad set flat as `Contents/Resources/guest-tools`, and refuses to ship firmwarekit without it. `GLRendererFloatQEMU` ships as the flat Mach-O, so no nested bundle is signed. The app composes each boot's offer from the packages (guest-package-bootstrap.md, P5).
- **app:** xcodebuild Release (it embeds `LightTouchDevice` and `firmware-catalog.json`), and `swift build -c release` for `Packages/FirmwareKit`; package.sh ships it as `Contents/MacOS/firmwarekit` (hardened runtime, no entitlements). It must build: the built-in iPod needs it.
- **package:** first the built-in iPod (`bundled_base`): the built firmwarekit's `create` of `n72ap-7E18` from `--bundled-ipsw` with the built `ipad-guest-tools` (and the built helper), packed by `scripts/pack-base.py` into `bundled/n72ap-7E18.itbase` with `bundled.json` (inputs, the lock's hashes) beside it, skipped when its inputs are unchanged; then a fresh copy of the product, `build-inputs.json` and package.sh (`LTM_BASE_BLOB`). Notarization is not done here.
- **notarize:** submits once, records the id in `stages.json` and waits up to 9 minutes. Rerun it to keep waiting; `notary-log.json` is written if it's rejected.
- **staple.**
- **verify:** `test-package.py` (including `LightTouchDevice --probe ipad1`), `codesign --deep --strict`, stapler, and `spctl` must report "Notarized Developer ID". Then, for each of k48ap-7B500 (`--verify-ipsw`), k48ap-8C148, n72ap-7E18 and n72ap-8C148 (`VERIFY_ENTRIES`: the IPSWs in `~/Downloads` and `~/Developer/ipod2g-re/OldSDK`), the bundled `firmwarekit create` prepares it with its default `--guest-tools` and the bundled `LightTouchDevice` into `prepare-check/` (it must end with `done`), and `tests/sessions/check-sessions.py --single` boots the result through the bundle's helper, dylib, usbmuxd, Frameworks and bootrom: lit, lockdown over its own usbmuxd, AFC round trips of 16384/16385/65536/1048583 bytes (no restore), an IPA install, a clean shutdown. The output is deleted; the frames stay in `verify-frames/<entry>/`. One entry per run, so rerun `--stage verify` until every entry is current. Then it writes `LightTouchMac.zip`, `SHA256SUMS` and `bundle-inventory.json`.

After verify, delete `DerivedData/` and `firmwarekit-build/`. As before, `source-revisions.json` and the release notes are made by hand, and nothing here publishes.

## G. Phases

**Phase 0 – spikes** (Risks 1–6 below).

**Phase 1a – serial, one agent:** remove `DeviceProfile.current` and add geometry constants.
- Gate: the build is identical in behavior, with and without `LIGHTTOUCH_DEVICE`.

**Phase 1b – MVP in parallel:** the sidebar plus switching between the iPod 3.1.3 and iPad 3.2.2, each in its own helper.

| WS | Owns only |
|---|---|
| W1 Helper | `LightTouchDevice/*`, `Shared/DeviceLink.swift`, `Shared/SharedStatus.swift`, `Shared/NativeLogging.swift`, **project.pbxproj (sole owner)**, scripts/package.sh, build-release.py, test-package.py |
| W2 Link conversion | EmulatorController.swift, DisplayView.swift, ScreenMovieWriter.swift, GuestNotifications.swift, DeviceTools.swift (agent paths), Shim bridging header, app-side DeviceLink.swift |
| W3 Library + migration | DeviceInstance.swift, DeviceLibrary.swift, LegacyAdoption.swift (gone in C6), FirmwareCatalog.swift, Resources/firmware-catalog.json, LaunchOptions (gone in C6), Bundled, StorageLocations, DeviceStateStorage, USBMux (per-instance), tests/check-legacy-adoption.py (now check-bundled-prepared.py) |
| W4 UI | MainWindowController, AppDelegate, MainMenu, DeviceViewController, DeviceLibraryViewController, DevicePlaceholderViewController, DeviceSession.swift |

- W1 and W3 go first, publishing their APIs on day 1; W2 and W4 code against them.
- **Gate:**
  - Release signed and notarized.
  - A headless helper boots both devices (`tests/sessions/check-helper-boot.py`).
  - The adoption test passes.
- **Sam tests:**
  1. The existing iPod state is intact.
  2. With both devices running, switching is instant and input goes to the visible device.
  3. `kill -9` on the iPad helper leaves the iPod running, and the iPad offers Restart.
  4. Save State / Erase work per device.
  5. Quitting with both running unmounts both cleanly.
  6. Screenshot, recording with audio, and IPA drop work on each device.

**Phase 2 – catalog, download, import, preparation through the DEBUG Python bridge.**

| WS | Owns |
|---|---|
| W5 | IPSWStore, FirmwareDownloads |
| W6 | PreparationJob, PythonBridge (DEBUG; generates the manifest and keys text from the catalog entry) |
| W4 | Row and placeholder states |

- **Gate:** from a clean `LTM_STATE_DIR`, download and prepare iPad 3.2 from Apple, and boot it to a lit screen. A download killed mid-way resumes; a cancelled prepare leaves nothing behind.

**Phase 3 – FirmwareKit port, by module.**
- **Wave A (deterministic):** IMG3/LZSS/VFDecrypt, KBoot/DT/Identity, K48NAND, MachOSigner, SharedCache.
- **Wave B:** HFS, SystemEdits, OneShots, Recipe k48.
- **Wave C:** N72 and 4.2.1.
- A recipe switches from the bridge only after all of its modules pass their oracle and two boots on one overlay pass.

**Phase 4 – productize:**
- Drop the bridge from Release, pack the guest payloads, and drop JIT from the app.
- Optionally move services into the helper.
- Add iPod-from-IPSW once it's unblocked and its third-party tarballs are replaced.

## Risks

| # | Risk | Cheap retirement | Fallback |
|---|---|---|---|
| 1 | Dynamic `NSXPCListener(machServiceName:)` from a hardened, unsandboxed app plus a spawned child; IOSurface over NSXPC | Spike: a signed parent and child, headless. **Done: the listener is refused (EPERM) for a name launchd doesn't know** ([spikes](archive/multi-device-spikes.md#1-rendezvous--iosurface-risk-1-fallback-a)) | **Chosen:** `bootstrap_check_in` rendezvous. A Mach hello carries the token and the `IOSurfaceCreateMachPort` ports and is validated by audit token + `SecCodeCheckValidity` + token. A socketpair on fd 3 carries the Codable messages. |
| 2 | Hardened helper doing GL (CGL), coreaudio, JIT, GL snapshots outside an app | Signed helper boots the iPad GL CA golden headless, then save/restore. **Done: go with the qemu entitlements only.** The helper must never `dispatchMain()` (RCU) | Give the helper the app's entitlements |
| 3 | IOSurface ring tearing or latency | Display-measurement test + recording diff | Copy to a CGImage as today |
| 4 | Apple CDN serves the pinned IPSWs over HTTPS with Range | `curl -sIr 0-0` per URL. **Done: go. HTTPS works and the ranged GET returns 206; iPod 3.1.3 has no URL** | ATS exception for appldnld.apple.com (SHA1 guarantees integrity) |
| 5 | In-app hdiutil/diskutil rw mounts (TCC, Spotlight) | Run a bake from a signed binary once | Mount inside the preparer; do the Swift HFS+ writer earlier |
| 6 | Two QEMUs at once (usbmuxd ×2, shared web-proxy conf) | Two headless helpers + two usbmuxd, IPA into each. **Done: go** (lit, and `ideviceinfo` answers each; IPA not tried). `USBMUXD_SOCKET_ADDRESS` is process-global | Per-device proxy config; pause in background |
| 7 | Adoption misses a key variant | Fixture test over every EC key branch | Adoption never moves anything; keep the old dirs |
| 8 | Oracle non-determinism | Run Python twice and diff | — |
| 9 | Our ad-hoc signer accepted by iOS 3/4 amfid | Byte-diff vs `ldid -S` | Hook returns a signed file |
| 10 | iPod-from-IPSW uses Legacy-iOS-Kit tarballs | License review | Own guest helpers, like the iPad |
| 11 | Unknown disk-space estimates | `du` peaks during Python runs (7B500, 8C148). **Done: peak = IPSW + 2.8 GiB, prepared 1.4 GiB (a sparse 16.5 GiB NAND), ~85 s** | **Chosen:** `peak_bytes` = IPSW + 3 GiB ("2× IPSW + prepared" is too low). Copies must be sparse-aware. |

## Corrections from implementation

- **Tests (E4, 2026-09-28):** `tests/` is three tiers, `offline/` (no emulator), `sessions/` (helper + images) and `release/` (packaging), with `drivers/` (helper-driver, session-driver) and `fixtures/`; `tests/run.py {offline|sessions|release}` runs a tier (parallel through one shared module cache for offline and release, one emulator at a time for sessions) and `scripts/gate.sh` wraps it. Checks compile whole production files: `DeviceExecution.swift` (the deadline race, serial gate, errors and timeouts, out of DeviceServices), `BootRecipe.swift` and `DeviceRow.swift` (out of DeviceSession) and `DiagnosticsExport.swift` (out of MainWindowController) exist so they can. `tests/SLICED.md` lists the checks that still cut a section out of a hub file and the extraction that retires each.

**W3, 2026-09-28** (`b63d910`, `a731de4`):
- `device.json` has two more fields: `format` and `storage.key` (the image identity; it pins the overlay). C6 removed `storage.resetMarker` and `legacy {filesRoot, nand, pointer?}` with the adoption they served.
- **Runtime files are per instance.** That covers the usbmuxd pid, the lease and logs, under `Devices/<uuid>/work/` and `~/Library/Logs/<bundle>/Devices/<uuid>/`. `session.env` is gone (nothing read it).
- **Pairing conf:** each device has its own `Devices/<uuid>/usbmuxd-conf`; the built-in iPod inherits the pre-library `work/usbmuxd-conf` once (LegacyState).
- **The iPod 3.1.3 IPSW isn't on api.ipsw.me**, so a future from-IPSW entry needs another source.
- **Still open for W4:** Export Diagnostics and the log window still read the global `serial.log`, `usbmuxd.log` and `session.env`.
- **Still open for W2/W4:** EC still resolves its own instance in `init(options:profile:)`. It should receive one chosen from the library.


**W1, 2026-09-28** (helper, link, packaging):
- **The link is framed JSON on a socketpair, plus a Mach hello for the surfaces**, not NSXPC (section A). DeviceLink spawns with `posix_spawn`, not `Process`, because only `posix_spawn` can put the socket on fd 3. It's otherwise the same: logs go to a descriptor, and termination is observed.
- **The client lives in `Shared/`** (compiled into the app, the helper and the test driver), so W2 doesn't write an app-side `DeviceLink.swift`. `NativeLogging.swift` doesn't move.
- **The C glue is a Clang module** (`Shared/CLink`, `import LTMLinkC`, `SWIFT_INCLUDE_PATHS`), not the app's bridging header, which stays W2's. The audit-token pid is read without libbsm.
- **`BootConfig` has no `serialLog`**: the argv carries `-serial` (the app's FIFO works across processes). The one-shot config has one.
- **`LinkEvent.audioEnded(generation, failed)`** tells the recorder the drain after `audioStop` finished. `hello` takes a `machine` for `deviceInfo`. `HelperInfo` adds `pid`.
- **The orphan shutdown on the iPod is the agent halt** (1.3 s to a confirmed power-off), then powerdown. The iPad powerdown confirmed in 15.6 s.
- **Packaging:** Xcode embeds the helper in `Contents/MacOS` (an "Embed Device Helper" copy phase). Its embedded Info.plist identifier is `gold.samhenri.LightTouchMac.LightTouchDevice`. `CODE_SIGN_ENTITLEMENTS` is `$(QEMU_IOS_DIR)/contrib/macos-app/entitlements.plist`, and `OTHER_LDFLAGS` is empty (no qemu link). `package.sh` checks the helper, drops its absolute rpaths and signs it with those entitlements after the frameworks and tools and before the app. `tests/release/test-package.py APP` checks the signature, entitlements, closure and a `--probe` that loads `Frameworks/libqemu-arm.dylib`.
- **A Release build with the helper was notarized** (Accepted, stapled, `spctl`: Notarized Developer ID). It was `package.sh` with `LTM_ASSETS=none`, not `build-release.py`. `build-release.py` can't run end to end under a 10-minute step limit: its fresh native build is one long script, and `--native-build` would relink the prior release's native dir, which is configured for `~/Developer/qemu-ios`. That dir's ipod-branch dylib also lacks the iPad exports the app links (`qemu_ios_ui_compass`, `usb_charger`, `orientation`). **A multidevice release needs a native build from `qemu-ios-ipad1`.** The one used here was `qemu-ios-ipad1/build-w1-native`: the native recipe's QEMU configure, over the 09-26 release's prefix and static deps.
- **Tests boot with `-audio driver=none`**; the app keeps its own audio arguments.
- **`tests/sessions/check-helper-boot.py`: 22/22** (reject, iPod, iPad, restore, iPad orphan, one-shot, headless). The PNG dumps and driver logs are in `~/Developer/qemu-ios-files/w1-helper/dumps/`.

## Preparer contract (Sam, 2026-09-28: no Python bridge; the app runs the Swift preparer only)

The Python bridge is dropped. The app's PreparationJob runs one executable, `firmwarekit`:
- In Release, it's `Contents/MacOS/firmwarekit`.
- In Debug it can be overridden by `LTM_FIRMWAREKIT=/path`, e.g. `swift run` output from `Packages/FirmwareKit`.
- The Python imgtools in qemu-ios stay only as the test oracle for FirmwareKit.

```
firmwarekit create --entry ENTRY.json --ipsw IPSW --out STAGING_DIR
                   [--seed SEED] [--helper PATH_TO_LightTouchDevice]
                   [--cache DIR] [--guest-tools DIR]
```

- `ENTRY.json` is one catalog entry, exactly as in `Resources/firmware-catalog.json`, with its keys.
- `--helper` runs the seal and keybag one-shots (`LightTouchDevice --oneshot`).
- `--cache` holds decrypted components by IPSW sha1. It's recreatable.
- `--guest-tools` is a flat directory of the prebuilt, signed guest helpers (tools, launchd jobs, GLEngine-*, gli-dispatch-*.tsv, the gld plugin, libappsync.dylib, it_keybag), by file name. It defaults to `../Resources/guest-tools` next to the executable, the app bundle's copy.
- The k48 `iboot` recipe runs `iBoot32Patcher` (a separate process, `--rsa --debug -b <boot-args>`). `K48IBoot.patcher` takes the bundled copy first (`Contents/MacOS/iBoot32Patcher`, next to firmwarekit or the helper), then `FIRMWAREKIT_IBOOT_PATCHER` / `IBOOT32PATCHER` for development runs, then the bare name on PATH. The lock records the copy it used (`tool.iboot32patcher`: path, sha256).

**stdout is JSON Lines only, one object per line.** Diagnostics go to stderr.
```
{"event":"begin","steps":9,"seconds":[2,5,…]}  // seconds: expected duration per step, optional
{"event":"step","index":3,"name":"Building the system volume"}   // index is 1-based, 1…steps
{"event":"progress","fraction":0.42,"detail":"Booting to seal the flash — 42 s"}   // fraction within the current step; detail optional
{"event":"warning","message":"…"}
{"event":"done","lock":"device.lock.json"}      // relative to STAGING_DIR
{"event":"error","code":"key_missing|sha_mismatch|unsupported|activation_failed|oneshot_failed|disk_full|internal","message":"…"}
```

**Progress (2026-09-28, prep-ux):** during every step firmwarekit emits a `progress` event about once a second, and a final `fraction` 1.0 just before the next `step` (or `done`).
- Within a step the fraction never goes down, and it stays below 1 until that final event.
- `detail` says what the step is doing now and how long it has been running.
- The verify and lock steps measure the bytes they hash.
- The seal and keybag boots use the serial-log milestones of their one-shots (FTL open, launchd, it_prefs, it_seal, the check boot), and elapsed time up to the next milestone. Elapsed time never goes past a milestone that hasn't appeared yet.
- The other steps use elapsed time against their expected seconds.
- `begin.seconds` gives those expected seconds (`Recipe/StepProgress.swift`), so the app can weight its overall bar. It is 91 s for 7B500 on an M4 Max, and the seal is 72 s of that.

STAGING_DIR exists and is empty when firmwarekit starts; the app creates it.

**Exit codes:** 0 on done; 1 on error, after emitting an error event; SIGTERM means cancel. On cancel the preparer stops within 2 s and leaves STAGING_DIR for the app to delete.

**On success, STAGING_DIR contains exactly:**
- the board's boot files, by the recipe's boot strategy:
  - k48 `iboot` (default): `iBoot.bin` (pattern-patched), `nor.bin` (packed, writable), `gid-blobs.bin`;
  - k48 `kboot` (debugging, `recipe.boot: "kboot"`): `kboot.bin`, and `nor.bin` only for 4.x data protection;
  - n72: `iBoot.bin`, `nor.bin`, `gid-blobs.bin`;
- `nand/`, kept sparse (the k48 iboot store carries the IPSW's img3 kernelcache in its system volume, for iBoot's fsboot);
- `identity.json` (mode 600);
- `device.lock.json`: the inputs and their hashes, the tool version, the UDID, the activation input/output hashes, the product version, and — for k48 — `boot_strategy` (`iboot`/`kboot`), `gid_components`, `iboot_signature_checks`, and `outputs.nand.listing_sha256`.

**Reproducible stores (2026-09-28, `iboot-ship`):** `outputs.nand.built_listing_sha256` (both boards) is the listing of the store as built from the volumes, before any boot writes into it. It is the same for the same entry, seed, IPSW and guest tools: the host mount's traces are normalized after the unmount (`HFSPlusVolume.normalize`: every date the recipe touched becomes the IPSW's newest file date, macOS's "date added" is cleared, B-tree slack is zeroed, the data volume's identifier derives from the seed; `VolumeMount.withMounted` puts a journaled volume's empty journal back as it was). `listing_sha256` stays the identity of the shipped store; for k48 it differs run to run by design, because the keybag (4.x) and seal boots write the guest's first-boot state (SpringBoard, lockdownd, guest-clock timestamps) into the store, and for n72 8C148 the keybag boot folds guest pages in. Golden-lock tests compare `built_listing_sha256` (and `iboot`/`nor`/`gid_blobs`), never `listing_sha256`. `SystemEditsTests.volumesAreReproducible` builds the k48 volumes and store twice and names any differing page.

**One recipe (C4/C8, 2026-09-28, `one-recipe`).** `Preparer.create` picks a board (`K48Board`, `N72Board`) and runs
`Recipe.create`: verify → decrypt → identity + `board.bootFiles` → `board.volumes` → `board.store` → [`board.keybag` if
data protection] → [`board.seal` if the board needs one] → lock. Shared in `Recipe`: the sha1 and Restore.plist checks,
the decrypt cache, the seed name (`<board.seedPrefix>-<build>-default`), the step/progress events, the read-only
outputs, the store listing hashes and the lock (the board's keys merged in). Shared in `SystemEdits` (every board's
system volume): the PAC, AppSync (cache patch + installd interposer), the SpringBoard job edit, activation, the
guest-package seed. Helper names and the dyld cache derive from `board.arch` (`Helpers.name("it_prefs", "armv6")`,
`Helpers.itpack(arch)`, `dyldCache(arch)`), never from a per-recipe string. The board keeps its NAND writer, NOR,
boot chain (iBoot/kboot vs direct-iboot), data volume (k48) and seal (k48). The lock's keys and bytes are unchanged:
`scripts/lock-identity.py create` builds every catalog entry whose IPSW is in the download store and `diff` compares
`built_listing_sha256`, the iboot/nor/gid_blobs hashes and the whole lock minus `created`.

- **Disk images** go through `DiskImage` (attach, detach, resize, UDIF → raw): hdiutil while macOS ships it
  (deprecated on 27, functional; the floor is 14.4), `diskutil image` otherwise; `FIRMWAREKIT_DISK_IMAGE` overrides.
  Not diskutil first: its attach presents the image as a solid-state device and the HFS+ driver then lays files out
  differently (no metadata zone), so a store edited through it differs from the golden hashes (7E18: 281 pages moved).
  Resize and convert are byte-identical on both: hdiutil grows to whole allocation blocks less one when the file's
  end is not block-aligned (the iPad IPSW volumes: 8 KiB blocks, 4 KiB past the last block), so the diskutil backend
  asks for size - (slack mod block size) (DiskImageTests.backendsAgree, 4 and 8 KiB blocks, 0-8 KiB slack). Listing
  attached images (cancel, Export's unmount) reads `hdiutil info -plist`: `diskutil` has no listing that names the
  image file. Mount/unmount, newfs_hfs and fsck_hfs are not disk-image operations and stay in VolumeMount. The
  volume header's writeCount (the mount's write count, chunking included) is zeroed by `HFSPlusVolume.normalize`
  like the dates, and the lock's `entry.sha256` is over a sorted-keys encoding (it was per-process random before).
- **Still mounted at prepare time:** the system volume (file adds: helpers, jobs, PAC, the kernelcache, the guest
  package; plist rewrites that change size), the data volume (newfs_hfs + the /private/var skeleton copy) and the
  keybag ramdisk (restored_external). The native HFSPlus module edits owners, dates, the volume identifier, B-tree
  slack and the journal; to prepare without a mount it needs a block allocator, fork extension and catalog B-tree
  insertion (docs/sweep/PLAN.md C8). Export/Mount (F1) mount by design.
- **IPSW members** are read through ZIPFoundation (`IPSWArchive`; zip64 included); guest-helper Mach-O checks
  (`MachOSignature`: thin/fat headers, load commands, LC_CODE_SIGNATURE) through MachOKit; tools run through
  swift-subprocess. The dyld_v1 shared-cache reader stays FirmwareKit's own: MachOKit reads a v1 cache's mappings,
  images and symbol tables the same way but resolves a cached image's sections wrongly, and the GL dispatch and AppSync
  scans need the cache's bytes at file offsets (`MachOKitProbeTests`). All three are pinned exact in
  `Packages/FirmwareKit/Package.swift` and recorded with licenses in `build-support/dependencies.json` (`swiftpm`).

The app publishes STAGING_DIR by rename (`PreparationJob.publish`, also used for the built-in iPod's unpacked blob and, kept in place, an `LTM_DEV_BASE` development base).

**The built-in iPod (C6, 2026-09-28).** The release build runs the same `firmwarekit create` for `n72ap-7E18` (built firmwarekit, built guest tools, the 7E18 IPSW) and packs STAGING_DIR with `scripts/pack-base.py` into `Resources/device/n72ap-7E18.itbase`: the .itpack format ("ITPACK01", a JSON index of the files in stream order, one zlib stream), which the notary does not open. The app (`BundledBase.unpack`) streams it into `Preparing/<id>/` and publishes it as above; nothing in the app boots anything but a prepared base. Development runs: `LTM_DEV_BASE=<firmwarekit create output>` writes a `.prepared` record naming that directory once (absolute path, never locked), for the entry its lock names.

**W5/W6, 2026-09-28 (`b4d14f4`):**
- **Resumed downloads return HTTP 206.** Any 2xx is accepted; the size and SHA1 checks guarantee integrity.
- **`kill -9` of the app doesn't cancel a background download.** A relaunch reattaches; resume data only comes from a cancel or a failure.
- **Prepared bases are read-only** (`chmod a-w`), so deletion needs `IPSWStore.removeTree`.
- **Still open for W4:**
  - a preparing row with a step count of 0 (import hashing) should show just its name;
  - add a fraction to `FirmwareJob.preparing` for in-step progress.
- **For W2, how prepared devices boot** (`base.kind == .prepared`):
  - iPad, by the lock's `boot_strategy` (`BootRecipe.bootStrategy`): `iboot` (default) → `iboot=<base>/iBoot.bin,gid-blobs=<base>/gid-blobs.bin,nor-rw=<clone of base/nor.bin>`; `kboot` (absent strategy = the two older records) → `kboot=<base>/kboot.bin`. Both add `nand=<base>/nand`, `nand-overlay=<paths.overlay>` and die id from `instance.identity.dieID`.
  - Clone `base/nor.bin` to `storage.writableNOR` on first boot (`cp -c`, then `chmod u+w`) and pass it as the writable NOR — always for iboot (iBoot writes NVRAM/effaceable there), and for 4.x kboot data protection.
  - Create the overlay and usbmuxd-conf directories on first boot.
  - Never write inside `base/`. (C6: there are no other paths; every device is a prepared base.)

**FirmwareKit wave A2, 2026-09-28** (`2907d45`, `45fdbdd`, `2dbe750`):
- **GL dispatch tables are generated at prepare time from the IPSW's shared cache.** They use one shipped base table (`gli-dispatch-7B500.tsv`) for the per-function columns. The catalog's `gli_dispatch` field is unused and can be dropped.
- **No MachOSigner in FirmwareKit.** Guest helpers are signed once when the app is built (`build-release.py` on the dev Mac), so FirmwareKit never signs at run time.
**W2, 2026-09-28** (link conversion, sessions):
- **The app no longer links `libqemu-arm.dylib`** (app target `OTHER_LDFLAGS = ""`, no qemu headers in the bridging header); `otool -L` and `nm -u` show nothing of it. Every former `qemu_ios_*` call goes through `DeviceLink` as the section A table says.
- **`DeviceProcess`** (DeviceSession.swift, Foundation only) owns one helper: its `native.log` (`ProcessLogCapture`), the hello check (a board mismatch is logged, not fatal), the boot, and one death with a reason ("killed (signal 9)", "exited unexpectedly (code n)", a start failure). **`BootRecipe`** builds both boards' argv from paths, and the prepared-base first boot (`preparedFiles`). tests/sessions/check-sessions.py compiles that section as the app does.
- **The boot is built after the hello**, not before the spawn: snapshot identity needs the helper's build id, and usbmuxd still starts before the guest's USB.
- **EmulatorController polls the status block on its own 30 Hz timer** (liveness, storage failure, power-off, sleep), so a hidden device with no display link still flips booting → running. DisplayView only draws: `layer.contents` is the front IOSurface; the 3D model and captures make a CGImage from it under a use count.
- **The helper forces the alpha byte opaque** when it copies a frame (`FrameRingWriter.copy`, vImage): iBoot and the iPod framebuffer leave it 0, and a layer showing the surface directly would honour it.
- **Restart replaces the session** (`DeviceSessionHost.restart`): the old helper is killed if alive and must have exited before a new one opens the overlay. It serves the dead overlay's Restart, a restore that never came alive, and the boot after erasing a running device. Erasing a stopped device just erases. Nothing quits the app.
- **One app-wide DeviceGate** sets the right device's `USBMUXD_SOCKET_ADDRESS` inside each operation (`DeviceGate.point(at:)`); devices wait for each other. A thread abandoned past its deadline could still connect after a switch; that case is logged. Phase-4 option: services in each helper.
- **Web-proxy files are per device**: `Devices/<uuid>/web-proxy.{conf,json}` and its CA; the device that kept `work/usbmuxd-conf` keeps the state-directory files, so the CA its guest trusts is unchanged.
- **Prepared devices**: usbmuxd-conf is created (and seeded) by USBMux on first start, not pre-created, since USBMux only seeds a missing directory.
- **Recording audio**: the clock is the dylib's (monotonic seconds since the capture started), kept in the app; packets arrive as `.audio` events.
- **iPad power-off confirmation: 45 s** in both the app's quit path and the helper's parent-death path (4.2.1 took 16–25 s and once passed 30 s, leaving the FTL unclosed). `cleanShutdownBudget` stays 60 s and covers 5 + 45.
- **For W1**: `DeviceLink` keeps the reaped pid, so `terminate()`/`kill()` after death could signal a reused pid; DeviceProcess guards it, but the link should zero its pid on reap.
- **A kill -9 right after an install can lose it** (no guest sync): expected, as in powerdown-fixed; the iPad has no guest shell to sync through.

**Guest services without SSH (qemu-ios guest-services-plan P2), 2026-09-28** (`7f73aad`):
- Every guest command is an agent op (`GuestServices.swift`): spawn with no shell, put/get/chown/unlink,
  sync, launch/frontmost/lockstatus, orientation, dlicon, halt. Capabilities come from the v2 ping; a v1
  agent (images with freeze's shell) gets the missing ops through its `exec`. (The in-place component
  upgrade of a legacy image, `updateMediaComponents`, went with C6: every image is a prepared base whose
  guest tools the loader keeps current.)
- The SSH transport, the script installer, itorient-over-SSH and Open Terminal are gone; package.sh no
  longer ships it-ssh-terminal.sh, sbdlicon, ithalt, itstatus, itproxy, ittrust or itorient. The web
  proxy on both boards is the image's PAC plus the CA trusted silently through the guest agent
  (GuestServices.trustCertificate: the package's ittrust, or the app's copy out of the armv6 itpack, so no
  "Install Profile" screen); the MCInstall profile is the fallback for a guest without an agent, offered
  once (lockdown-mcinstall --installed) and named in the proxy settings ("Tap Install on the device…").
  A legacy image without a baked PAC keeps whatever proxy settings itproxy last wrote.
- The helper's SIGTERM path no longer resumes a VM whose guest already powered off (a quit after Power
  Off or after the app's halt aborted QEMU: "invalid runstate transition: 'shutdown' -> 'running'").

**Integration, 2026-09-28** (fk-n72, gpkg-p4, prep-ux, finder-f0, automatic-activation):
- **Activation is built in for both recipes** (automatic-activation): `firmwarekit create` has no `--activation-hook` (an unknown argument now), the lock records `inputs.activation {input_sha256, output_sha256}`, and a failure is `activation_failed`.
- **Prepared iPods boot** (`base.kind == .prepared`, n72ap): `direct-iboot=<base>/iBoot.bin`, `nor=<base>/nor.bin` with `nor-rw=` the private copy (`storage.writableNOR`, cloned on first boot, removed by Erase with the overlay), `gid-blobs=<base>/gid-blobs.bin`, `nand=<base>/nand`, and the overlay pinned to `storage.key`. The n72 machine has no `die-id`: the identity is in nor.bin.
- **Lock `machine` options**: every boot of a prepared base appends its device.lock.json `"machine"` (sorted, escaped) to `-M`. N72Recipe always writes `{"aes-uid": "engine"}`, as ipod2g_device.py does.
- **iPod 3.1.3 is a `user_ipsw` entry** (pinned `5f4f5c01…`, the IPSW docs/ipod/from-ipsw.md names; no URL) with recipe n72 (8g, system_mib 7168, gles_shim/appsync/web_proxy, gli-dispatch-7E18.tsv), and the built-in device (`bundled`, C6): the row is Ready once its packed base is published at first launch; after a Delete it offers Prepare (the blob again) and Import IPSW….
- **The seal's check boot matches `FTL_Open\s*\[OK\]` over the log with its newlines removed** (the helper's `--oneshot` `stopPattern`), as ipad1_seal.py now does.
- **`build-guest-tools.sh` stages the n72 inputs** into the firmwarekit directory: MBXGLEngine, sblaunch, sbdlicon, it_agent, it_typein.dylib, com.qemu.it-agent.plist and gli-dispatch-7E18.tsv (libappsync.dylib is the fat one already there).

**iPod 4.2.1, 2026-09-28** (ipod4-app, qemu-ios abb1a1b817):
- **n72ap-8C148 is experimental.** N72Recipe's `options.data_protection` runs the restore-ramdisk keybag one-shot (N72Keybag, qemu-ios ipod2g_keybag.py) through `LightTouchDevice --oneshot`: firmwarekit stages the ramdisk at the kernel entry over the helper's gdbstub (`-gdb tcp:127.0.0.1:PORT -S`). So an iPod 4.x prepare needs `--helper`, the bootrom (the bundle's `Resources/device`, `LTM_FILES`, or `~/Developer/qemu-ios-files`) and `it_keybag-armv6` in the guest tools.
- **The MBX shim is per dispatch layout** (`MBXGLEngine-<BUILD>` next to `gli-dispatch-<BUILD>.tsv`, both built and staged by `build-guest-tools.sh`); N72Recipe installs the one whose table is the firmware's, and on 4.x (the engine is in the shared cache) creates dyld's `enable-dylibs-to-override-cache`.
- **A prepared base's files are per board** (`DeviceProfile.preparedBootFile`/`preparedFiles`): publish failed every iPod prepare while it required `kboot.bin`.
