# Multi-device phase 0: spike results

2026-09-28, branch `multidevice`. Spikes for Risks 1, 2, 4, 6 and 11 of
[multi-device-plan.md](multi-device-plan.md). All of them ran headless from command-line targets. The
app was never launched.

| Risk | Verdict |
|---|---|
| 1 Rendezvous + IOSurface | **Fallback (a).** A dynamic `NSXPCListener(machServiceName:)` is refused. `bootstrap_check_in` + a Mach hello carrying IOSurface ports + a socketpair works, and so do validation and lifetime. |
| 2 GL helper, hardened runtime | **Go.** Needs one rule: the helper must never call `dispatchMain()`. |
| 4 Apple CDN | **Go.** HTTPS works, Range works, no ATS exception needed. iPod 3.1.3 (7E18) has no public URL. |
| 6 Two at once | **Go.** Nothing collided with per-instance paths; `ideviceinfo` answered on each (an IPA install into each was not tried). Two leftovers, below. |
| 11 Disk peaks | Measured. Peak ≈ IPSW + 2.9 GiB, final 1.4 GiB, ~85 s. The "2× IPSW + prepared" fallback underestimates it. |

## Setup

- **Code:** `spikes/` on this branch. `spikes/build.sh` builds and signs everything into `spikes/.build/` (git-ignored).
  - `spike-host` stands in for the app.
  - `LightTouchDevice` stands in for the helper.
  - `LightTouchDevice-adhoc` and `LightTouchDevice-otherteam` are impostors for the rejection tests.
  - `machprobe` is the rendezvous probe.
- **Drivers:**
  - `spikes/spike1.py`: rendezvous, validation, ring, lifetime.
  - `spikes/spike2.py ipad-boot | ipad-restore | ipod-boot | both`: spikes 2 and 3.
  - `spikes/disk_peak.py BUILD [--activation-hook H]`: spike 5.
- **Signing:**
  - Every binary is signed **"Developer ID Application: Sam Gold (SM75355Y6R)"** with hardened runtime (`flags=0x10000(runtime)`). The keychain allowed it without a prompt. It used `--timestamp=none`, so this is not notarizable as-is.
  - The helper carries `qemu-ios-ipad1/contrib/macos-app/entitlements.plist`: allow-jit, allow-unsigned-executable-memory, disable-library-validation.
- **Emulator dylib:** built privately from `~/Developer/qemu-ios-ipad1` (branch ipad1) at `47c02f6339`.
  - Build dir: **`~/Developer/qemu-ios-ipad1/build-spike-md/`**. It was freshly configured with the same options as `build/` (`configure.log` in the dir) and built with `make-dylib-macos.sh build-spike-md`.
  - Nothing else was rebuilt.
  - `ipad1` has moved on since (`26cacc69bf` at the time of writing).
- **Assets:** device state is under `~/Developer/qemu-ios-files/spikes/`.
  - Dumps (PNG): `multidevice/dumps/<scenario>/`.
  - Overlays, snapshots and serial logs: `multidevice/{ipad,ipod,both-*}/`.
  - Prepared devices: `disk/<build>/`.
  - Bases are used read-only: `ipad1/userland/golden-pristine`, `ipad1/7B500/k48-kboot.bin` and `nand-current` (→ `nand-agent-v4`).

## 1. Rendezvous + IOSurface (Risk 1): fallback (a)

**(a) A dynamic check-in from a non-launchd process.**
- `NSXPCListener(machServiceName: "gold.samhenri.LightTouchMac.devices.<pid>")` fails at once. The unified log shows `listener failed to activate: xpc_error=[1: Operation not permitted]`, and the child's lookup gets `[3: No such process]`.
- `machprobe` reproduces this with `xpc_connection_create_mach_service(..., LISTENER)`: INVALID.
- On the same process, **raw `bootstrap_check_in(bootstrap_port, name)` succeeds**, and the spawned child's `bootstrap_look_up` + `mach_msg` reach it.
- `mach_ports_register` is not usable: the checked-in right has no send right to register.

So the fallback is what the spike implements (`spikes/mach.c`, `host/main.swift`, `device/main.swift`):
- **Mach, one message per `surfacesChanged`.**
  - The app checks in `<bundle>.devices.<pid>`.
  - The helper looks it up and sends one complex message: the token plus `IOSurfaceCreateMachPort` of [status, ring0, ring1, ring2], moved as send rights.
  - The app receives with `MACH_RCV_TRAILER_AUDIT` and calls `IOSurfaceLookupFromMachPort`.
- **Codable messages go over a `socketpair`.** The app's end is CLOEXEC. The helper's end is passed as fd 3 through `posix_spawn_file_actions_adddup2` (Foundation's `Process` can't pass an extra fd). The spike sends newline-delimited JSON as a stand-in for LinkCommand/LinkEvent/LinkRequest. Nothing else from the plan's DeviceLink types changes.
- XPC's replies and ordering are lost. Requests need an id and a reply table; that's about 40 lines on top of the planned ~300.

**(b) Validation.** Every hello is checked in the host before any port is used:
1. The sender pid from the kernel audit token is a device the app spawned and hasn't accepted yet.
2. `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)` + `SecCodeCheckValidity` against `anchor apple generic and certificate leaf[subject.OU] = "SM75355Y6R"`. This uses the audit token, not just the pid, so a recycled pid can't pass.
3. The one-time token from argv matches.

Results (`spike1.py`):

| Peer | Result |
|---|---|
| Spawned, Developer ID SM75355Y6R, right token | ACCEPT |
| Same binary re-signed ad hoc | REJECT: requirement failed (-67050) |
| Same binary signed "Nealfun Inc (U3A5RKDN46)" | REJECT: requirement failed (-67050) |
| Spawned, wrong token | REJECT: wrong token |
| Correctly signed but not spawned by the host (a rogue that looked up the name) | REJECT: pid not a spawned device |

The name is visible to any process in the session, but the socketpair isn't, so only the Mach hello needs this gate.

**(c) The IOSurface ring: 3 BGRA surfaces plus a 4 KB status block (atomics).**
- The writer picks a surface that isn't `front`, isn't the reader's `held` slot, and isn't `IOSurfaceIsInUse`. It publishes `front`, then `serial` (seq-cst).
- The reader stores `held` and re-reads `serial`, a Dekker-style handshake. It retries if the serial moved, and holds a use count the way `layer.contents` would.
- Synthetic frames are 1024×768 at 60 Hz for 10 s. Each is a solid colour derived from its serial, and 64 pixels are checked for tearing on every observed frame.

| | 1 ms reader poll | 16.7 ms poll (display-link cadence) |
|---|---|---|
| Frames observed / published | 601 / 601 | 444 / 601 (skips are expected at 60 Hz sampling) |
| Publish → observe latency p50 / p95 / max | **0.76 / 1.41 / 1.50 ms** | 8.9 / 16.3 / 16.6 ms (bounded by the poll) |
| Torn frames, retries, no free surface | 0, 0, 0 | 0, 0, 0 |
| Helper CPU (10 s) | 0.027 s (0.3 %) | 0.031 s |
| Host CPU (10.8 s) | 0.030 s (0.3 %) | 0.010 s (0.1 %) |

With real QEMU frames (spike 2), copying `qemu_ios_ui_frame` into the ring took:
- iPad 1024×768: p50 0.05 ms, max 4.7 ms. One earlier run had a 29.8 ms outlier.
- iPod 320×480: p50 0.016 ms.

Also with real frames:
- The host's reader CPU was 0.16 s over 35 s.
- No torn frames.
- Exactly one "no free surface" (a dropped frame) per session.

The transport adds nothing measurable: latency is the reader's cadence.

**(d) Lifetime.**

| Event | Noticed after | By |
|---|---|---|
| `kill -9` of the parent | **0.6 ms** | Link EOF and the process-exit source on the ppid, same ms. The child then exits. |
| `kill -9` of the child | **0.7 ms** | Link EOF and the process-exit source. `waitpid` status 9. |
| SIGTERM of the host with two real devices (spike 3) | same ms | Both helpers ran `qemu_ios_ui_powerdown`. The iPad confirmed in 14.5–15.2 s. |

The iPod confirmed once in 15.2 s and once not within 20 s. See the plan changes.

## 2. GL helper under hardened runtime (Risk 2): go

The helper `dlopen`s `build-spike-md/libqemu-arm.dylib` with `RTLD_NOW` and resolves the entry points with `dlsym`. It runs `qemu_ios_main` on a 16 MB-stack `Thread`, with argv/env built as `EmulatorController.start` / `startIPad1` do. The machine options come from `tests/ipad1/boot-smoke.py`.
- iPad: `ipad1,kboot=…,nand=golden-pristine,nand-overlay=<private>`, `-device usb-kbd`, slirp Wi-Fi.
- iPod: `IT_TVOUT_READY=1`, boot-args, a writable NOR copy, `-audio coreaudio`.

A 60 Hz timer copies frames into the ring. Scripted actions (`tap`, `drag`, `button`, `snapshot`, `resume`, `quit`) run once the screen is lit.

| Run | Result |
|---|---|
| iPad 3.2.2 GL-CA cold boot | Lit lock screen at **15.4 s**, 3 GL contexts. The unlock drag reached the home screen (`dumps/ipad-boot/dev0-{lock,home}.png`). |
| `qemu_ios_snapshot_save2` with live GL (3 contexts) | status DONE in **0.96 s**, 126 MB. `snapshot_resume` kept the home screen live (`dev0-after-resume.png`). A second save took 0.97 s. Then `ui_quit`, exit 0. |
| iPad restore (`-incoming file:snap2`, same overlay, new helper process) | Lit at **0.5 s**, 3 GL contexts. A tap opened Settings (GL-composited, `dumps/ipad-restore/dev0-settings.png`), and Home returned to SpringBoard. Five repeat runs: 5/5. |
| iPod nand-current cold boot | Lock screen at **9.0 s**. The slider drag reached the home screen (`dumps/ipod-boot/dev0-home.png`). |

JIT (TCG), CGL GL contexts, CoreAudio and the dylib's Homebrew dependencies all loaded under hardened runtime with the qemu entitlements alone. **The app's own entitlements aren't needed.**

**A trap that looked like a GL or restore bug.**
- The first helper parked its main thread with `dispatchMain()`, which `pthread_exit`s the main thread.
- The dylib's `rcu_init` constructor (`util/rcu.c`) registered that thread as an RCU reader, so `call_rcu_thread` then walks a freed TLS record.
- The symptoms were random:
  - a SIGSEGV in `object_class_property_init_all` during `ipad1_init`;
  - `-incoming file:…: unknown migration protocol: (null)` from a heap-clobbered argv string;
  - a restore that never painted.
- Crash report: thread 0 was in `dispatch_main → pthread_exit → _dispatch_queue_cleanup2`, and the faulting thread was in `wait_for_readers`.
- Running the stock `qemu-system-arm` under Guard Malloc was clean. Replacing it with `CFRunLoopRun()` made restores 5/5.
- The app is immune only because AppKit keeps its main thread alive. **LightTouchDevice's `main.swift` must park the main thread in a run loop.**

## 3. Two at once (Risk 6): go

Setup:
- One host spawned both helpers (iPod + iPad).
- Each device had its own usbmuxd (`~/Developer/usbmuxd-qemu`, the same flags as `USBMux.swift`: `-f -v -S <client> -P NONE -C <conf>` with `USBMUXD_QEMU_ADDR`, `USBMUXD_QEMU_DELAY=0`).
- Each had its own client port, guest port and conf dir.

Results:
- Both lit: iPod at 9.7 s, iPad at 17.0 s (`dumps/both/dev0-home.png`, `dev1-lock.png`).
- `ideviceinfo` with `USBMUXD_SOCKET_ADDRESS` per call answered first try: **iPod2,1 3.1.3** and **iPad1,1 3.2.2**.
- `idevice_id -l` listed one UDID per daemon.
- Pairing records landed in each conf dir.

What each process held (`lsof`):
- Each helper: its own overlay and serial log, one TCP connection to its own usbmuxd guest port, and slirp's outbound sockets.
- Each usbmuxd: its two listeners and its own log.
- **No fixed port and no file in common**, apart from the system Metal shader cache.

With private paths, nothing collided. Global state that would collide in today's app:

| Shared global | Status on this branch |
|---|---|
| `work/usbmuxd-conf`, `usbmuxd.pid` (reapStaleDaemon would kill the other device's daemon), `session.env`, `serial.log`, `usbmuxd.log` | Per instance since W3 (`a731de4`). Export Diagnostics and the log window still read the global names (W4). |
| `setenv("USBMUXD_SOCKET_ADDRESS")` in DeviceServices, IMobileDevice, GuestNotifications, SpringBoardIcons | **Process-global.** Two devices' services in one app process race it. The DeviceServices gate must either be one gate for the whole app across devices (serializes the two devices) or become per-device, with `libusbmuxd` pointed per call (not possible through the env var), or with services moved into the helper (plan phase 4, which this argues for earlier). CLI tools launched with the env per process (`DeviceTools`) are fine. |
| `web-proxy.conf` / `web-proxy.json` in the state dir, one routing mode read by every device's itwebproxy guestfwd | Shared by design. Fine if the proxy setting is app-wide. Per-device needs per-device files. |
| `IT_*` env knobs, `qemu_ios_*` globals, QEMU's one-VM-per-process | Solved by one helper per device: each has its own env and dylib instance. |
| `app.log`, `native.log` | App-level, one per app. Helper output needs its own `native.log` per device. |

## 4. Apple CDN (Risk 4): go

URLs from `https://api.ipsw.me/v4/device/<id>?type=ipsw`. Each was checked with `curl -sI -r 0-0` and a 2-byte ranged GET, and every one answered `HTTP/1.1 200` to the HEAD. All are `Server: AmazonS3`, `Accept-Ranges: bytes`, no redirect, TLS verify 0. The ranged GET returned **206** with `Content-Range: bytes 0-1/<size>` and body `PK`. Plain `http://appldnld.apple.com/…` also answers 200.

| Device, build | URL | Bytes | ETag | sha1 (ipsw.me = catalog) |
|---|---|---|---|---|
| iPad1,1 3.2 7B367 | `https://secure-appldnld.apple.com/iPad/061-7987.20100403.mjiTr/iPad1,1_3.2_7B367_Restore.ipsw` | 478959325 | `2912cefa0304e5430594c576ad88d398` | 172e8297… |
| iPad1,1 3.2.2 7B500 | `https://secure-appldnld.apple.com/iPad/061-8801.20100811.CvfR5/iPad1,1_3.2.2_7B500_Restore.ipsw` | 479001595 | `cf6d93fffdc60dcca487a80004d250fa` | 68b613f7… |
| iPad1,1 4.2.1 8C148 | `https://secure-appldnld.apple.com/iPad/061-9857.20101122.VGthy/iPad1,1_4.2.1_8C148_Restore.ipsw` | 578084840 | `9402d5f05348fd68c87f885ff4cb4717` | 8717b3be… |
| iPod2,1 4.2.1 8C148 | `https://secure-appldnld.apple.com/iPhone4/061-9855.20101122.Lrft6/iPod2,1_4.2.1_8C148_Restore.ipsw` | 363553480 | `0045e3543647e23470b84c2c1de96ab1` | b9efddc7… |
| iPod2,1 2.1.1 5F138 | `https://secure-appldnld.apple.com/iPod/SBML/osx/bundles/061-5494.20080909.8i9o0/iPod2,1_2.1.1_5F138_Restore.ipsw` | 282083944 | `a45cdd3510f0569b5c3c78a5cc86baea` | c3c700be… |
| iPod2,1 3.1.3 7E18 | **not on ipsw.me** (paid-era iPod update; none of its iPod2,1 3.x builds are listed). No Apple URL found. | – | – | – |

- **No ATS exception is needed:** it's HTTPS end to end.
- The ETags have no `-N` suffix, so they're single-part S3 MD5s. A cheap pre-check, but the SHA1 stays the integrity guarantee.
- All objects were last modified in 2016. They're stable.
- **iPod 3.1.3 from IPSW can only be `user_ipsw`.** A local copy's cache dir is `ipod-ipsw/cache/5f4f5c01…`.

## 5. Disk peaks (Risk 11)

Method:
- `imgtools/ipad1_device.py create` ran with its `CACHE` constant overridden to a private dir, so the decrypt step is included and the shared cache is untouched, and with the private `build-spike-md/qemu-system-arm`.
- It ran from **a private worktree, `~/Developer/qemu-ios-ipad1-spike-md`** (detached at ipad1 `26cacc69bf`). The shared checkout was missing its untracked guest builds: `build/ipad1-guest`, `build/appsync` and `contrib/ipad1-gles/GLEngine-*`. The worktree has its own copies, built by the three `build.sh`.
- Before switching to the worktree, `build/ipad1-guest/` and `build/appsync/` were also built into the shared checkout. They were absent before, so nothing was overwritten.
- Sampling: `du -sk` of output + cache every 2 s, plus the volume's free space.

| | 7B500 (3.2.2) | 8C148 (4.2.1, with Sam's hook as `--activation-hook`) |
|---|---|---|
| Result | rc 0, UDID 144707f3… | rc 0, UDID a24ec333… |
| Duration | **85 s** (decrypt 2 s, volumes 7 s, NAND 3 s, seal boot 64 s, lock 7 s) | **87 s** (adds a 5 s keybag one-shot, seal 58 s) |
| Peak, output + decrypt cache | **2.84 GiB**, from 16 s until work/ is deleted at the end | **2.73 GiB** |
| Peak volume delta (noisy: other agents write to the same disk) | 4.8 GiB | 3.3 GiB |
| Decrypt cache | 461 MiB | 545 MiB |
| IPSW (read in place) | 457 MiB | 551 MiB |
| **Prepared device** | **1.38 GiB** allocated (`nand/` 1.37 GiB) | **1.39 GiB** (`nand/` 1.38 GiB) |
| `nand/` apparent size | **16.5 GiB, sparse** | 16.5 GiB, sparse |

Estimates for the catalog:
- `peak_bytes` ≈ IPSW + 3.0 GiB (the spike measured IPSW + 2.8). Check for 4 GiB free to leave margin; the planned "2× IPSW + prepared" gives 2.3–2.5 GiB, too low.
- `prepared_bytes` ≈ 1.4 GiB.
- `seconds` ≈ 90 on this Mac.

**The prepared NAND is sparse at 12×.**
- Every copy must preserve holes: APFS clone (`cp -c`, `copyfile(COPYFILE_CLONE)`) or a sparse-aware copy.
- A naive copy, zip or tar without `-S` inflates it to 16.5 GiB.
- The atomic publish (`Preparing/` → `Devices/<uuid>/base` rename) is safe on the same volume.

## Changes to the plan

1. **Rendezvous (A, the Risk 1 row): the fallback is now the design.**
   - `bootstrap_check_in` + a Mach hello (token + IOSurface ports) + a socketpair on fd 3 for Codable messages.
   - Validation: audit-token pid ∈ spawned, then `SecCodeCheckValidity` (Team SM75355Y6R) on the audit token, then the token.
   - `DeviceHostXPC`/`DeviceClientXPC` become a small framed-JSON link with request ids; `surfacesChanged` becomes the Mach hello, resent on a resize.
2. **LightTouchDevice's main thread must stay alive** (a run loop, never `dispatchMain()`). Add a comment where it's parked, and cover it with `check-helper-boot.py` repeat boots.
3. **The orphan shutdown in the helper is per profile.**
   - iPad: `qemu_ios_ui_powerdown` + `guest_shutdown_confirmed` works in about 15 s (the app's budget is 30 s).
   - iPod: the app's clean path is the guest-tools halt (`haltFilesystem`), not powerdown. Powerdown alone confirmed in only 1 of 2 runs within 20 s.
   - So on parent death the helper needs the iPod halt too (agent or SSH), or the halt must stay app-driven with the helper only as the last resort.
4. **Services across devices:** `USBMUXD_SOCKET_ADDRESS` is process-global, so in phase 1 either one app-wide DeviceServices gate or services in the helper. Moving services into the helper should be weighed for phase 1b, not phase 4.
5. **Estimates:** the catalog's `estimates` are about 1.4 GiB prepared and a peak of IPSW + 3 GiB. Copies must be sparse-aware.
6. **iPod 3.1.3 from IPSW** has no CDN source, so it's `user_ipsw` only.
