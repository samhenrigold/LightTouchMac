# Consolidation sweep: the plan

From the five surveys in this directory (emulator, pipeline-and-guest-tools, app, repo-story, qa), 2026-09-28.
Tracked in docs/STATUS.md. Each item names the pieces it builds; "Gate" is what proves no regression.

Principles (Sam): reuse across boards and versions; runtime discovery over per-address patches; one guest agent
per arch that adapts at runtime; one generic pipeline from the stock IPSW, never per-version images; stock quirks
that hurt the user may be suppressed.

## Sam's decisions

| # | Decision | Recommendation |
|---|---|---|
| S1 | Retire the Python pipeline: Swift only; Python stays as `research/` and test drivers; oracle = golden lock hashes per firmware | **Approved by Sam 2026-09-28.** Order: C0 iBoot → C4 one Recipe → C5 |
| S2 | Bundled iPod becomes a prepared device (one Erase prompt for old state) | **Approved by Sam 2026-09-28.** C6, after Track A merges |
| S3 | Quit-with-resume snapshots: delete the unreachable code, or wire it up | **Sam: "Delete the code."** A9 on `app-correctness` |
| S4 | IPA UX: "Install on ▸" context menu, drops on sidebar rows, Store dedupe by hash | Proceeding as recommended (Track B) |
| S5 | Push `multidevice` and `ipad1` to the private remotes as backup (107 + N commits exist only here) | Sam runs pushes |
| S6 | Repo boundary | Two repos + contract now (decided); revisit moving tools at the main merge |

## In flight

| Branch | What | Gate |
|---|---|---|
| `fk-k48-iboot` (app) | real-iBoot chain in FirmwareKit; new die-id for new devices | byte-equal to Python; boot + restore-smoke on app-prepared 7B500 |
| `gl-coverage` (qemu-ios) | rejection counters, magenta fallback under `gles-debug`, produced-vs-rejected list, cheap formats | regress gles + shadow, app-compat counters |
| `usb-alert` (qemu-ios) | USB alert suppressed by the agent at runtime; package serial 3 | no alert after unlock; auto-lock observed; iPod unaffected |

## Track A: app correctness (done 2026-09-28 on `app-correctness`; to merge)

| Item | Gate |
|---|---|
| A1 Activation check once per boot; persistent message; "Prepared without activation" row subtitle — **done** | check-activation-gate 8/8 (offline slice + session driver on the hook-less 7E18-a) |
| A2 Boot deadline and recovery-mode detection → named error, never "Booting…" forever — **done** (lockdown is "iOS up"; the helper's uiReady is iBoot's display) | check-boot-deadline 3/3 (offline slices; 8C148-b recovery base, marker in 1.3 s; missing iBoot.bin named before boot) |
| A3 Per-device install queue: jobs carry the instance id, `discard(for:)`, filtered notifications, per-device pause — **done** | check-install-queue-scope; check-uninstall-queue, check-media-queue; check-sessions two-device install |
| A4 Device files: `chflags uchg` on base after publish (cleared on delete); watcher on Devices/<uuid> + overlay with a persistent notice; Stop skips msync into a dead inode; adopted iPod's Show in Finder → its own dir — **done** (the watch covers delete/rename/revoke; `.write` only on base: QEMU writes the overlay's own page files) | check-device-files; check-helper-boot --only meddle 6/6 |
| A5 Install checks use the device's iOS version, not "3.1.3" — **done** (and the slice: armv7 for the iPad) | tests/catalog.swift assertions (runner stale at baseline; verified by a scratch compile) |
| A6 "Guest tools" status line: Current / Reverted / Built-in / Legacy / Unknown / Not responding / Recovery / Not booted — **done** | check-guest-package (texts and states); the line is `EmulatorController.guestToolsLine` |
| A7 Per-device defaults (keyboardInputEnabled, autoRotateWithGuest) — **done**; tiltSnap and modelPresentation are CoreAnimation keys, not defaults | check-device-keyboard, check-settings |
| A8 usbmuxd idle poll interval (3 ms → 50 ms after 1 s idle, back on the first packet) — **done** on the fork's `idle-poll` branch (off `qemu-zlp` 41631a7, not pushed, not pinned) | 3 idle iPods: 6.3% → 0.3% of a core (usbmuxd CPU time over 30 s) |
| A9 Quit-with-resume snapshot code deleted (S3) — **done**; helper snapshot ops kept | app/helper/firmwarekit build; check-clean-shutdown, check-termination, check-helper-boot restore |

## Track B: IPA library (done 2026-09-28 on `ipa-library`; to merge)

Content-addressed `State/Library/IPAs/<sha256>.ipa` + `index.json`; per-device copies are APFS clones of the blob; Store
downloads dedupe by the catalog copy's md5 (hashed alongside sha256 at store time); "Install on ▸ <running device>"; `.ipa`
drops on running sidebar rows; the launch sweep stores existing device copies once (the `State/IPAs` move folded in);
Settings ▸ Storage "Library" line + Remove Unused. Uninstall keeps the app-wide icon while another device has the app.
Gate: `tests/check-ipa-library.py` (two records → one blob, two clones, one entry; uninstall on A keeps B's copy and icon;
Remove Unused spares referenced blobs; Store dedupe with the fixture's IPA route disabled; sweep idempotent),
check-uninstall-queue, check-install-queue-scope, check-media-queue, check-storage-lifecycle, gate --quick, check-sessions
--ipad-device. Skipped: a per-device `installed.json` (the clone is the reference); hashing device copies to decide
"unused" (bundle id + size instead, which only ever keeps a blob longer).

## Track C: pipeline, Swift only (after S1)

| Item | Gate |
|---|---|
| C1 Runtime GL shim: parse the dispatch string at load; one GLEngine/MBXGLEngine per arch; no TSVs, no per-build names — **done 2026-09-28 (qemu-ios `gl-runtime`, app `gl-runtime-fk`)**: the shims read the layout at load by gles-names.h; FirmwareKit installs the one engine per arch, logs the slot count, drops `gli_dispatch` (see STATUS) | GLIDispatch generate == today's four tables; regress gles 7B500/8C148/7E18/8C148 |
| C2 mkpkg families by rule (board, iOS major, dyld legacy), hooks filtered at seed | mkpkg selfcheck; seed on 6 entries |
| C3 Catalog is the manifest; delete qemu-ios manifests/; tests take an entry JSON | fresh-device with --entry |
| C4 One Recipe with board plug-ins (verify/decrypt/identity/lock/keybag/bake shared) — **done 2026-09-28 (`one-recipe`)**: `Recipe.create` + `Board` (K48Board, N72Board); shared bake pieces in SystemEdits; helper names and the dyld cache by arch | swift test; `scripts/lock-identity.py diff`: every cached entry's lock byte-identical before/after (see STATUS) |
| C5 Retire Python: port real-iBoot (done in C0) and `--gl-test`; golden-lock oracle; delete ~4,500 lines; `research/` keeps the probes | fresh-device on all 6 entries via firmwarekit; one-time cross-check against the last Python locks |
| C6 Bundled iPod as a prepared device (S2); delete LegacyAdoption, LaunchOptions, the legacy branches — **done 2026-09-28 (`bundled-prepared`)**: `Resources/device/n72ap-7E18.itbase` (a packed `firmwarekit create`), published at first launch; one Erase & Continue / Quit prompt for the old layout; `LTM_DEV_BASE` for development | check-bundled-prepared (fresh → `.prepared`; old layout → prompt path); check-firmware-jobs publish (XFAIL retired); check-sessions --single ipod on the unpacked blob; test-release, test-package |
| C8 Disk images without `hdiutil` — **DiskImage done 2026-09-28 (`one-recipe`)**: one abstraction (attach/detach/resize/convert) on `diskutil image` where it exists (27+) and hdiutil below, both backends unit-tested on every host and byte-identical where both run; ZIPFoundation, MachOKit, swift-subprocess pinned. **Left:** prepare-time edits on the native HFSPlus module (three pieces: a block allocator, fork extension, catalog B-tree insertion; gate: lock-identity unchanged with no mount) so preparation never mounts; the attached-image listing still reads `hdiutil info` | swift test (DiskImageTests); lock-identity on every cached entry |
| C7 iPod 2.1.1 in the app (N72 recipe 2.x path, keys, catalog) — **2.1.1 done 2026-09-29 (`ipod-2x`)**: catalog recipe blocks, lock `boot_strategy: bootrom` (SecureROM boot, no iBoot.bin), lockdown-tz time set in the session driver as in the app, 2.2's wrap-all-but-LLB NOR (SCEP >= 2); byte-matched to ipod2g_device.py. **Left:** 2.2/2.2.1 need qemu-ios `ipod-2x` (0x38100000 block) merged + pin bump; the 2.x hold button (smoke #19) | in-bundle prepare + boot; matrix rows 5F138/5G77a/5H11a |

## Track F: fewer lines we own (Sam, 2026-09-28: "the best line of code is the line we never wrote")

| Item | Gate |
|---|---|
| F1 Host GL executor on ANGLE — **dropped 2026-09-28 (Sam):** the deletable translation is a few hundred lines; the rest of gles-host.c is wire/surface/present plumbing and iOS-only extensions ANGLE lacks; a million-line dependency and 10–20 MB for that isn't worth it, and OpenGL deprecation isn't a concern | — |
| F2 VideoToolbox boundary spike — **done 2026-09-28, verdict: ffmpeg stays.** H.264: the guest submits one slice per job with no last-slice marker, so picture completion is only knowable by parsing residuals (libavcodec chunk mode does that); single-slice CAVLC now decodes natively on VideoToolbox (byte-exact), libavcodec only for multi-slice. AAC/MP3/ALAC: the guest DMA is an unframed byte stream; AudioToolbox needs packet boundaries, which only a decoder can find. | test_h264_native (VT byte-exact), test_h264_slices/reader |
| F3 Web proxy in the app on URLSession (system trust store, HTTP/2, cache); guest keeps the PAC redirect only — **done 2026-09-29 (`proxy-urlsession`; qemu-ios `proxy-guestfwd` retires contrib/it-webproxy):** the device helper serves the guestfwd through `nc -U` (`LightTouchDevice/WebProxy.swift`, `WebProxyAdapters.swift`, `Shared/WebProxyCA.swift`); itwebproxy leaves the bundle | check-web-proxy-forwarding; check-web-proxy (new); check-proxy-trust 17/17 iPad 7B500 and bundled 7E18; Proxy-compatibility set through 3.2.2 Safari |

## Track G: iPhone OS 1.x/2.x graphics (docs/sweep/gpu-1x-2x.md)

| Item | Gate |
|---|---|
| G1 2.x compositing leaves the software path (Sam: "dog slow and janky"): CoreAnimation composites through the 2.x GL front end (CA_ENABLE_OGL, as 3.x does), else the MBX 2D API shim so the stock MBX2D compositor runs (built as part of G2) | home swipe / Safari zoom / scroll fps and stalls vs the software path; 3.x-level smoothness |
| G2 2.x GL front end for apps: `mkold.py --legacy` turns rebase opcodes into classic relocations (prereq); `gles2x.c` exports the firmware's own gl*/egl*/EAGL names over the same mbxshim core and gles-names.h wire; replaces OpenGLES.framework's binary via an n72-ios2 hook; first App Store game on screen, then compatibility | a 2.x game renders through the host with zero refusals; 5F138/5H11 boot+gles; 3.x/4.x unchanged |
| G3 1.x boots first with LK_ENABLE_MBX2D=0 (software) only to reach the milestone; **Sam (09-29): 1.x gets hardware acceleration too** — G4 is required for 1.x, not optional | 1G milestone screenshots |
| G4 1.x hardware acceleration (required): LayerKit has no EAGL, so its accelerated paths are MBX 2D (`LKRenderMBX2DRenderDisplay`, five draw ops incl. perspective quads) and its GLES renderer (`LKRenderGLESRenderDisplay`, egl-based). Hoist one of them: the GLES renderer through the 1.x export front end (same mbxshim core; 1.x exports 153/156 names in gles-names.h) if LayerKit's GLES path is complete, else the MBX 2D API shim (~40 exports → host blits/quads over CoreSurface memory). Never a hardware MBX model | 1.x home swipes, Cover Flow and video smooth on 4B1, measured vs software |

## Track D: emulator consolidation (after gl-coverage and usb-alert merge)

| Item | Gate |
|---|---|
| D1 One hypercall dispatcher with optional agent/kbd hooks | iPod regress agent,gles; iPad boot-smoke --guest-package |
| D2 Shared board helper (props, power-off gesture, chords, multitouch QMP) | both persist checks; test_ui_buttons, test_attitude_qmp |
| D3 Merge I2S, SHA-1, ChipID into one model each with variant properties | iPod audio; iPad audio-check; snapshot-check |
| D4 Delete the GID KBAG table and the kernel banner table (after the nand-current swap) | test_aes; fresh-device both boards |
| D5 I2C slaves into their own files; SPI global → property; iBoot literal tricks into it_iboot.c | regress boot both boards |
| D6 Delete dead tools and scripts (hidbridge, ssh terminal, kbd-agent, patch_*, probes); it_agent includes it_pbd | done 09-29 — test_agent_ops; boot-smoke paste |
| D7 IT_* env knobs → machine properties (tests and app pass properties) | regress both boards |
| D8 Tests by board parameter: tests/lib, boards/, checks/, one regress.py --board | both regress suites green |

## Track E: repo story (E1–E3, E5 after fk-k48-iboot merges)

| Item | Gate |
|---|---|
| E1 Pin file `build-support/sources.json` (qemu-ios, usbmuxd); qemu-ios `contrib/export-guest-artifacts.sh`; xcconfig/build-release/tests resolve through it | release build from the pin; test-release |
| E2 READMEs rewritten as entry points; docs → live / archive / research; contradictions fixed; dangling links removed | link check |
| E3 `tests/gate.sh --quick|--full` (qemu-ios) and `scripts/gate.sh` (app); fix test_regress mock | both green |
| E4 App tests: offline/ sessions/ release/ + run.py; slicers → whole-file compiles with stubs | run.py offline green before and after |
| E5 Prune 31 merged worktrees and branches; tag-then-delete the July experiments; drop the duplicate `fork` remote | worktree list |
| E6 Service layering (Transport/Services/Guest/Features) and big-VC extractions — **done 2026-09-29 (`service-layers`)**: layer directories, DeviceTools and the forwarders gone, AppInstaller/CaptureController/DroppedFiles/DeviceProcess/IPAMembers extracted; SLICED 39 → 27 (the rest are controller/view state, tests/SLICED.md) | offline 71/0; release 6; check-sessions 16/16 |

## Order

1. Track A done (`app-correctness`, 9 commits); merge it, pin usbmuxd `idle-poll`. In-flight branches merge as they land; then the next notarized build for Sam.
2. Track B, then E1/E3/E5 (after the iBoot merge), then C1–C3 (after gl-coverage merges).
3. S1/S2 decided → C4–C6; D1–D8 as a series of small branches; E2, E4, E6 last, when the code stops moving.
