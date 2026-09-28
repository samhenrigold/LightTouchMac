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

**Rendezvous:**
- The app runs an `NSXPCListener(machServiceName: "<bundle>.devices.<pid>")`.
- The helper's argv carries the instance UUID and a one-time token.
- The app checks the peer pid and `setCodeSigningRequirement` (same Team). This is **Risk 1: spike it first.**

**Lifetime:**
- The helper watches its parent (a process-exit source plus XPC invalidation). If the parent dies, it runs `qemu_ios_ui_powerdown`, waits for `guest_shutdown_confirmed` (bounded), and exits.
- The app sees a helper death and sets the session to `.dead(reason)` with **Restart**. `quitForRelaunch` leaves the self-heal path.
- The helper holds `beginActivity(.userInitiated, .latencyCritical)`.

### XPC protocol — `Shared/DeviceLink.swift` (both targets)

```swift
@objc protocol DeviceHostXPC {            // app -> helper
  func command(_ message: Data)                                  // LinkCommand, one-way, ordered
  func request(_ message: Data, reply: @escaping (Data) -> Void) // LinkRequest -> LinkReply
}
@objc protocol DeviceClientXPC {          // helper -> app
  func event(_ message: Data)                                    // LinkEvent
  func surfacesChanged(_ surfaces: [IOSurface])                  // [0] status block, [1...3] frame ring
}
enum LinkCommand: Codable { case touch(slot: Int8, phase: Int8, x: Double, y: Double), touch2(phase: Int8, x: Double, y: Double),
  button(Int8, down: Bool), key(macKeyCode: UInt16, down: Bool), rotate(clockwise: Bool), shake,
  attitude(pitch: Double, roll: Double, pose: Int8), paste(String), machine(MachineOp /*pause,resume,reset,powerdown,quit*/),
  snapshotSave(path: String), snapshotResume, agentCancel(id: String), audioStop(UInt64) }
enum LinkRequest: Codable { case hello(protocolVersion: Int), boot(BootConfig), snapshotStatus, agent(request: String, deadline: Double),
  audioStart, battery(level: Int, charging: Int32), usbConnection(Bool), compass(Int), usbCharger(Bool), orientation(Int) }
enum LinkReply: Codable { case hello(HelperInfo /*protocol, dylib path+mtime, build_id, device_info*/), ok(Bool),
  snapshot(status: Int, error: String?), agent(String?), audio(generation: UInt64), failure(String) }
enum LinkEvent: Codable { case qemuExited(Int32), audio(generation: UInt64, seconds: Double, pcm: Data) }
struct BootConfig: Codable { var argv: [String]; var environment: [String: String]; var serialLog: String; var machine: String }
```

- **Frames:** a ring of three BGRA IOSurfaces. The helper copies `qemu_ios_ui_frame` into a surface that is neither front nor `IOSurfaceIsInUse`, then publishes `front` and `serial`. The app's display link sets `layer.contents = surface` when the serial changes. Nothing crosses XPC per frame.
- **Status block** (IOSurface #0, 4 KB, atomics, `Shared/SharedStatus.swift`), written at 20 Hz and on edges: `magic, version, heartbeat, frameSerial, front, width, height, uiReady, storageFailed, shutdownConfirmed, displaySleeping, agentStatus, glesContexts, iconGeneration`. A stalled heartbeat means the helper is wedged; stalled frames mean the guest is wedged.

### How each C call crosses

| C call (today's file) | Crossing |
|---|---|
| `qemu_ios_main` (EC.start/startIPad1) | `request(.boot)`: the helper applies the env from `setBootEnv`. Then `.qemuExited` and the helper exits. |
| `qemu_ios_device_info` (DeviceProfile+Display) | Board constants in `DeviceProfile`. `hello` returns the dylib's values, and a mismatch fails the boot. |
| `ui_attach` | Internal to the helper |
| `ui_frame`, `ui_copy_frame` (DisplayView) | Status block + IOSurface; capture locks the front surface |
| `ui_touch/touch2/button/key_mac/rotate/shake/attitude/paste` | `command` |
| `ui_battery/compass/usb_charger/orientation/usb_connection` | `request`, reply `.ok(Bool)` |
| `ui_pause/resume/reset/powerdown/quit` | `command(.machine)` |
| `ui_ready`, `ui_storage_failed`, `ui_guest_shutdown_confirmed`, `ui_display_sleeping`, `ui_icon_state_generation`, `agent_status`, `gles_contexts` | Status block |
| `agent_request/result/free_result`, `agent_cancel` (DeviceTools) | `request(.agent)` (the helper polls and frees within the deadline); `command(.agentCancel)` |
| `build_id` / dladdr provenance | `hello`, cached per session |
| `snapshot_save2/_status/_resume` | `command` + `request(.snapshotStatus)` polled every 100 ms |
| `audio_capture_*` (ScreenMovieWriter) | `request(.audioStart)`, then pushed `.audio` events, then `command(.audioStop)` |
| Audio playback | Stays in the helper |
| `setenv USBMUXD_SOCKET_ADDRESS` + DeviceGate | In the app for phase 1, with per-instance sockets. Phase 4 option: move services into the helper. |

EC stays in the app: every `qemu_ios_*` call becomes a `link.…` call. `DeviceLink.swift` (app) is about 300 lines; `LightTouchDevice/DeviceHost.swift` about 500 and `main.swift` about 150. `NativeLogging.swift` moves to `Shared/`.

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
| 1 | Dynamic `NSXPCListener(machServiceName:)` from a hardened, unsandboxed app plus a spawned child; IOSurface over NSXPC | Spike: a signed parent and child, headless | `bootstrap_check_in` rendezvous with raw Mach ports (`IOSurfaceCreateMachPort`) plus a socketpair |
| 2 | Hardened helper doing GL (CGL), coreaudio, JIT, GL snapshots outside an app | Signed helper boots the iPad GL CA golden headless, then save/restore | Give the helper the app's entitlements |
| 3 | IOSurface ring tearing or latency | Display-measurement test + recording diff | Copy to a CGImage as today |
| 4 | Apple CDN serves the pinned IPSWs over HTTPS with Range | `curl -sIr 0-0` per URL | ATS exception for appldnld.apple.com (SHA1 guarantees integrity) |
| 5 | In-app hdiutil/diskutil rw mounts (TCC, Spotlight) | Run a bake from a signed binary once | Mount inside the preparer; do the Swift HFS+ writer earlier |
| 6 | Two QEMUs at once (usbmuxd ×2, shared web-proxy conf) | Two headless helpers + two usbmuxd, IPA into each | Per-device proxy config; pause in background |
| 7 | Adoption misses a key variant | Fixture test over every EC key branch | Adoption never moves anything; keep the old dirs |
| 8 | Oracle non-determinism | Run Python twice and diff | — |
| 9 | Our ad-hoc signer accepted by iOS 3/4 amfid | Byte-diff vs `ldid -S` | Hook returns a signed file |
| 10 | iPod-from-IPSW uses Legacy-iOS-Kit tarballs | License review | Own guest helpers, like the iPad |
| 11 | Unknown disk-space estimates | `du` peaks during Python runs (7B500, 8C148) | 2× IPSW + prepared |

## Corrections from implementation

**W3, 2026-09-28** (`b63d910`, `a731de4`):
- `device.json` has four more fields: `format`, `storage.key` (the image identity; it pins the overlay), `storage.resetMarker`, and `legacy {filesRoot, nand, pointer?}`, used to match development launches and the active pointer.
- **Runtime files are per instance, including for adopted devices.** That covers the usbmuxd pid, `session.env` and logs, now under `Devices/<uuid>/work/` and `~/Library/Logs/<bundle>/Devices/<uuid>/`. Only durable state (overlay, snapshot, base, conf) stays at its legacy path.
- **Pairing conf:** the first adopted device keeps `work/usbmuxd-conf`. Later devices get a copy in `Devices/<uuid>/usbmuxd-conf`, so two daemons never share one.
- **The packaged iPod's key is not frozen.** Erase moves it to the newly bundled base, and the active pointer stays authoritative for it.
- **The iPod 3.1.3 IPSW isn't on api.ipsw.me**, so a future from-IPSW entry needs another source.
- **Still open for W4:** Export Diagnostics and the log window still read the global `serial.log`, `usbmuxd.log` and `session.env`.
- **Still open for W2/W4:** EC still resolves its own instance in `init(options:profile:)`. It should receive one chosen from the library.
