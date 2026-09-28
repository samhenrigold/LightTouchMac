# Multi-device Light Touch: implementation plan

Status: plan of record, 2026-09-28. Branch `multidevice`, based on `ipad1`.

This implements [device-firmware-modularization-plan.md](device-firmware-modularization-plan.md)
and [device-library-architecture.md](device-library-architecture.md) as a product.

**Decisions (Sam, 2026-09-28):**
- **One helper process per running device.** QEMU can't re-init in-process.
- **The IPSW → device pipeline is ported to Swift.** The Python imgtools in qemu-ios stay as the test oracle.
- **Keys are bundled with the catalog.**

**Hard rules:**
- **Activation belongs to Sam.** The app only runs a user-configured hook executable, as a black box, and never ships, writes or describes one.
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

Callbacks run on `queue`. Pending requests fail with `.closed` when the link goes, and with `.timedOut` after their timeout. `tests/check-helper-boot.py` drives this through `tests/helper-driver`.

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
 "activation_hook":"optional",
 "emulator":{"min_protocol":1}, "estimates":{"prepared_bytes":0,"peak_bytes":0,"seconds":0}}]}
```

- `status` is one of `available`, `experimental`, `coming_soon` or `user_ipsw`.
- `source.kind` is `ipsw`, or `bundled` for the legacy iPod image: `{"kind":"bundled","resource":"device/nand.itnand"}`.

Status column:

| Entry | Status |
|---|---|
| iPod 3.1.3 | available, bundled |
| iPad 3.2.2, 3.2 | available |
| iPad 4.2.1 | experimental |
| iPod 3.1.3 from IPSW, iPod 4.2.1, iPod 2.x | coming_soon |
| Betas | user_ipsw: pinned sha1, no URL |

**`DeviceInstance` (`Devices/<uuid>/device.json`):** `id, name, board, firmware, created, base {kind: prepared|legacyBundled|development, path}, storage {overlay, writableNOR, snapshot, usbmuxConf}, identity {seed, udid, die_id}, provenance {lock, sha256}, lastEmulatorBuild`. There is one instance per catalog entry for now; the model doesn't prevent duplicates.

**Layout.** State = `~/Library/Application Support/gold.samhenri.LightTouchMac`.

```
State/Devices/<uuid>/{device.json, base/ (read-only prepared output), overlay/, snapshot{,.meta,.tmp,.bad}, usbmuxd-conf/, work/}
State/IPSW/<sha1>.ipsw                                           user-imported
State/Preparing/<job-uuid>/                                      staging -> atomic rename to Devices/<uuid>/base
~/Library/Caches/<bundle>/IPSW/<sha1>.ipsw(.partial,.resume)     CDN downloads
~/Library/Caches/<bundle>/Decrypted/<sha1>/                      deleted after a successful prepare
~/Library/Logs/<bundle>/Devices/<uuid>/{serial,usbmuxd,native}.log
```

**Migration adopts state in place and never moves it** (`LegacyAdoption.swift`, run once when `Devices/` is absent).
- The key code moves verbatim: `legacyImageKey`, `imageKey`, `migrateStateNames`, `DeviceStateStorage.packedImage`.
- It writes one `device.json` per existing device, pointing at the legacy names (`nandrw-<key>`, `snapshot-<key>`, `work/usbmuxd-conf`, `device/<nand>-<digest>` + `active-<nand>.json`). The iPod gets `legacyBundled`; the iPad in dev gets `development`.
- Nothing is renamed, and keys are frozen in the record.
- UserDefaults `deviceNotice` and `motionPose` gain a `.<uuid>` suffix; the legacy value is read for the adopted iPod.
- Test: `tests/check-legacy-adoption.py`, with a fixture copy of a 1.0-release state tree. The overlay inode and paths must be unchanged.

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
- Resume data goes to `<sha1>.resume`.
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
- A download keeps its resume data.
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
| HookRunner (user hook, black box: exit 0, file changed, re-sign, sha256s in lock) | activation_hook | lock fields | 60 |
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
- The legacy iPod `nand.itnand` stays until iPod-from-IPSW ships. Without it the app is roughly 100–150 MB.
- **Signing order:** frameworks, then `MacOS/*` (each with its own entitlements), then the app.
- **`test-package.py` must check:** no raw NAND, no tarballs, and no `*.ipsw` or img3 magic outside `.itnand`/`.itpack`.
- The Python bridge is `#if DEBUG` only, and `test-release.py` checks for it.
- **Notarize a helper build in phase 1.**

### Multi-device release build

`scripts/build-release.py --stage …` runs the release as resumable stages. Each stage takes under 10 minutes and skips work that is already current, so run them one at a time (or `--stage all`). Without `--stage`, the one-step iPod build from `~/Developer/qemu-ios` is unchanged.

It needs these trees and SDKs:
- `~/Developer/qemu-ios-ipad1` (the `ipad1` branch) as `--qemu-ios`, with a private `--qemu-build` dir inside it. The default is `build-release-native`; the 09-28 build reused `build-w1-native`. Never use `build/`.
- A native root to reuse as `--native-deps`, e.g. `~/Developer/LightTouchMac/.build/releases/release-20260926/native`. Its prefix and static deps take longer than 10 minutes to build, so a fresh one comes from a one-step build.
- `~/Developer/usbmuxd-qemu/usbmuxd` (branch `qemu-backend`). The native stage rebuilds usbmuxd from it over the reused prefix, and fails unless libslirp (the iPad's USB Ethernet) was found.
- `--sdk ~/Developer/ipod2g-re/OldSDK/iPhoneOS3.1.3.sdk` and `ldid` for the guest tools. Also the assets in `~/Developer/qemu-ios-files`: the iPod `nand-current` still ships as `nand.itnand`.
- Xcode, and the Developer ID identity plus the `ltm-notary` profile.

```
R=(scripts/build-release.py --output .build/releases/multidevice-YYYYMMDD
   --qemu-ios ~/Developer/qemu-ios-ipad1 --qemu-build ~/Developer/qemu-ios-ipad1/build-w1-native
   --native-deps ~/Developer/LightTouchMac/.build/releases/release-20260926/native
   --sdk ~/Developer/ipod2g-re/OldSDK/iPhoneOS3.1.3.sdk
   --sign-id "Developer ID Application: Sam Gold (SM75355Y6R)" --notary-profile ltm-notary)
for s in native qemu dylib guest app package notarize staple verify; do python3 "${R[@]}" --stage $s || break; done
```

What each stage does:
- **native:** usbmuxd.
- **qemu:** configure once, then ninja.
- **dylib:** `make-dylib-macos.sh`.
- **guest:** the armv6 helpers.
- **app:** xcodebuild Release (it embeds `LightTouchDevice` and `firmware-catalog.json`). This stage also runs `swift build -c release` for `Packages/FirmwareKit`. If that builds, package.sh ships it as `Contents/MacOS/firmwarekit` (hardened runtime, no entitlements); if not, the app ships without it.
- **package:** a fresh copy of the product, `build-inputs.json` and package.sh. Notarization is not done here.
- **notarize:** submits once, records the id in `stages.json` and waits up to 9 minutes. Rerun it to keep waiting; `notary-log.json` is written if it's rejected.
- **staple.**
- **verify:** `test-package.py` (including `LightTouchDevice --probe ipad1`), `codesign --deep --strict`, stapler, and `spctl` must report "Notarized Developer ID". Then it writes `LightTouchMac.zip`, `SHA256SUMS` and `bundle-inventory.json`.

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
| W3 Library + migration | DeviceInstance.swift, DeviceLibrary.swift, LegacyAdoption.swift, FirmwareCatalog.swift, Resources/firmware-catalog.json, LaunchOptions, Bundled, StorageLocations, DeviceStateStorage, USBMux (per-instance), tests/check-legacy-adoption.py |
| W4 UI | MainWindowController, AppDelegate, MainMenu, DeviceViewController, DeviceLibraryViewController, DevicePlaceholderViewController, DeviceSession.swift |

- W1 and W3 go first, publishing their APIs on day 1; W2 and W4 code against them.
- **Gate:**
  - Release signed and notarized.
  - A headless helper boots both devices (`tests/check-helper-boot.py`).
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
| 1 | Dynamic `NSXPCListener(machServiceName:)` from a hardened, unsandboxed app plus a spawned child; IOSurface over NSXPC | Spike: a signed parent and child, headless. **Done: the listener is refused (EPERM) for a name launchd doesn't know** ([spikes](multi-device-spikes.md#1-rendezvous--iosurface-risk-1-fallback-a)) | **Chosen:** `bootstrap_check_in` rendezvous. A Mach hello carries the token and the `IOSurfaceCreateMachPort` ports and is validated by audit token + `SecCodeCheckValidity` + token. A socketpair on fd 3 carries the Codable messages. |
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

**W3, 2026-09-28** (`b63d910`, `a731de4`):
- `device.json` has four more fields: `format`, `storage.key` (the image identity; it pins the overlay), `storage.resetMarker`, and `legacy {filesRoot, nand, pointer?}`, used to match development launches and the active pointer.
- **Runtime files are per instance, including for adopted devices.** That covers the usbmuxd pid, `session.env` and logs, now under `Devices/<uuid>/work/` and `~/Library/Logs/<bundle>/Devices/<uuid>/`. Only durable state (overlay, snapshot, base, conf) stays at its legacy path.
- **Pairing conf:** the first adopted device keeps `work/usbmuxd-conf`. Later devices get a copy in `Devices/<uuid>/usbmuxd-conf`, so two daemons never share one.
- **The packaged iPod's key is not frozen.** Erase moves it to the newly bundled base, and the active pointer stays authoritative for it.
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
- **Packaging:** Xcode embeds the helper in `Contents/MacOS` (an "Embed Device Helper" copy phase). Its embedded Info.plist identifier is `gold.samhenri.LightTouchMac.LightTouchDevice`. `CODE_SIGN_ENTITLEMENTS` is `$(QEMU_IOS_DIR)/contrib/macos-app/entitlements.plist`, and `OTHER_LDFLAGS` is empty (no qemu link). `package.sh` checks the helper, drops its absolute rpaths and signs it with those entitlements after the frameworks and tools and before the app. `scripts/test-package.py APP` checks the signature, entitlements, closure and a `--probe` that loads `Frameworks/libqemu-arm.dylib`.
- **A Release build with the helper was notarized** (Accepted, stapled, `spctl`: Notarized Developer ID). It was `package.sh` with `LTM_ASSETS=none`, not `build-release.py`. `build-release.py` can't run end to end under a 10-minute step limit: its fresh native build is one long script, and `--native-build` would relink the prior release's native dir, which is configured for `~/Developer/qemu-ios`. That dir's ipod-branch dylib also lacks the iPad exports the app links (`qemu_ios_ui_compass`, `usb_charger`, `orientation`). **A multidevice release needs a native build from `qemu-ios-ipad1`.** The one used here was `qemu-ios-ipad1/build-w1-native`: the native recipe's QEMU configure, over the 09-26 release's prefix and static deps.
- **Tests boot with `-audio driver=none`**; the app keeps its own audio arguments.
- **`tests/check-helper-boot.py`: 22/22** (reject, iPod, iPad, restore, iPad orphan, one-shot, headless). The PNG dumps and driver logs are in `~/Developer/qemu-ios-files/w1-helper/dumps/`.

## Preparer contract (Sam, 2026-09-28: no Python bridge; the app runs the Swift preparer only)

The Python bridge is dropped. The app's PreparationJob runs one executable, `firmwarekit`:
- In Release, it's `Contents/MacOS/firmwarekit`.
- In Debug it can be overridden by `LTM_FIRMWAREKIT=/path`, e.g. `swift run` output from `Packages/FirmwareKit`.
- The Python imgtools in qemu-ios stay only as the test oracle for FirmwareKit.

```
firmwarekit create --entry ENTRY.json --ipsw IPSW --out STAGING_DIR
                   [--seed SEED] [--activation-hook PATH] [--helper PATH_TO_LightTouchDevice]
                   [--cache DIR] [--guest-tools DIR]
```

- `ENTRY.json` is one catalog entry, exactly as in `Resources/firmware-catalog.json`, with its keys.
- `--activation-hook` is a user-chosen executable. It's run directly as `hook FILE` on the recipe's target, as a black box; a file that isn't executable fails with `hook_failed`. The hook must leave the file signed (see wave A2 below). The app only stores and passes the path.
- `--helper` runs the seal and keybag one-shots (`LightTouchDevice --oneshot`).
- `--cache` holds decrypted components by IPSW sha1. It's recreatable.
- `--guest-tools` is a flat directory of the prebuilt, signed guest helpers (tools, launchd jobs, GLEngine-*, gli-dispatch-*.tsv, the gld plugin, libappsync.dylib, it_keybag), by file name. It defaults to `../Resources/guest-tools` next to the executable, the app bundle's copy.

**stdout is JSON Lines only, one object per line.** Diagnostics go to stderr.
```
{"event":"begin","steps":9}
{"event":"step","index":3,"name":"Building the system volume"}   // index is 1-based, 1…steps
{"event":"progress","fraction":0.42}            // within the current step, optional
{"event":"warning","message":"…"}
{"event":"done","lock":"device.lock.json"}      // relative to STAGING_DIR
{"event":"error","code":"key_missing|sha_mismatch|unsupported|hook_failed|oneshot_failed|disk_full|internal","message":"…"}
```

STAGING_DIR exists and is empty when firmwarekit starts; the app creates it.

**Exit codes:** 0 on done; 1 on error, after emitting an error event; SIGTERM means cancel. On cancel the preparer stops within 2 s and leaves STAGING_DIR for the app to delete.

**On success, STAGING_DIR contains exactly:**
- `kboot.bin` (or the board's boot files);
- `nand/`, kept sparse;
- `nor.bin` if the recipe uses a writable NOR;
- `identity.json` (mode 600);
- `device.lock.json`: the inputs and their hashes, the tool version, the UDID, the hook sha256, and the product version.

The app publishes STAGING_DIR by rename.

**W5/W6, 2026-09-28 (`b4d14f4`):**
- **Resumed downloads return HTTP 206.** Any 2xx is accepted; the size and SHA1 checks guarantee integrity.
- **`kill -9` of the app doesn't cancel a background download.** A relaunch reattaches; resume data only comes from a cancel or a failure.
- **Prepared bases are read-only** (`chmod a-w`), so deletion needs `IPSWStore.removeTree`.
- **Still open for W4:**
  - a preparing row with a step count of 0 (import hashing) should show just its name;
  - add a fraction to `FirmwareJob.preparing` for in-step progress.
- **For W2, how prepared devices boot** (`base.kind == .prepared`):
  - iPad: `kboot=<base>/kboot.bin`, `nand=<base>/nand`, `nand-overlay=<paths.overlay>`, and die id from `instance.identity.dieID`.
  - When `storage.writableNOR` is set, clone `base/nor.bin` to that path on first boot (`cp -c`, then `chmod u+w`) and pass it as the writable NOR.
  - Create the overlay and usbmuxd-conf directories on first boot.
  - Never write inside `base/`, and skip `missingAssets` and the legacy development paths.

**FirmwareKit wave A2, 2026-09-28** (`2907d45`, `45fdbdd`, `2dbe750`):
- **GL dispatch tables are generated at prepare time from the IPSW's shared cache.** They use one shipped base table (`gli-dispatch-7B500.tsv`) for the per-function columns. The catalog's `gli_dispatch` field is unused and can be dropped.
- **No MachOSigner in FirmwareKit.** Guest helpers are signed once when the app is built (`build-release.py` on the dev Mac), so FirmwareKit never signs at run time.
- **Hook contract change:** the activation hook must leave its target file validly signed. FirmwareKit checks that a CodeDirectory is present and records the sha256 values, but doesn't re-sign. This replaces the Python pipeline's post-hook `ldid` re-sign. Sam's activation agent owns the hook side of this.

**W2, 2026-09-28** (link conversion, sessions):
- **The app no longer links `libqemu-arm.dylib`** (app target `OTHER_LDFLAGS = ""`, no qemu headers in the bridging header); `otool -L` and `nm -u` show nothing of it. Every former `qemu_ios_*` call goes through `DeviceLink` as the section A table says.
- **`DeviceProcess`** (DeviceSession.swift, Foundation only) owns one helper: its `native.log` (`ProcessLogCapture`), the hello check (a board mismatch is logged, not fatal), the boot, and one death with a reason ("killed (signal 9)", "exited unexpectedly (code n)", a start failure). **`BootRecipe`** builds both boards' argv from paths, and the prepared-base first boot (`preparedFiles`). tests/check-sessions.py compiles that section as the app does.
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
