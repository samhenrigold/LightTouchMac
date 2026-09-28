# Consolidation sweep: the plan

From the five surveys in this directory (emulator, pipeline-and-guest-tools, app, repo-story, qa), 2026-09-28.
Tracked in docs/STATUS.md. Effort is in agent-days. "Gate" is what proves no regression.

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

## Track A: app correctness (start now; ~2 d)

| Item | Effort | Gate |
|---|---|---|
| A1 Activation check once per boot; persistent message; "Prepared without activation" row subtitle | 0.25 | new check-activation-gate (session driver on a hook-less base) |
| A2 Boot deadline and recovery-mode detection → named error, never "Booting…" forever | 0.5 | check-boot-deadline (missing iBoot.bin; recovery base) |
| A3 Per-device install queue: jobs carry the instance id, `discard(for:)`, filtered notifications, per-device pause | 0.5 | check-install-queue-scope; check-sessions two-device install |
| A4 Device files: `chflags uchg` on base after publish (cleared on delete); watcher on Devices/<uuid> + overlay with a persistent notice; Stop skips msync into a dead inode; adopted iPod's Show in Finder → its own dir | 0.5 | check-helper-boot --only meddle |
| A5 Install checks use the device's iOS version, not "3.1.3" | 0.1 | unit assertions |
| A6 "Guest tools" status line: Current / Reverted / Built-in / Legacy / Unknown / Not responding / Recovery / Not booted | 0.5 | check-device-health |
| A7 Per-device defaults (keyboardInputEnabled, autoRotateWithGuest, tiltSnap, modelPresentation) | 0.1 | offline check |
| A8 usbmuxd idle poll interval (3 ms → longer once idle) | 0.25 | CPU sample with 3 idle devices |

## Track B: IPA library (after A3; ~2 d)

Content-addressed `State/Library/IPAs/<sha256>.ipa` + `index.json`; per-device copies become APFS clones; Store downloads
dedupe by hash; "Install on ▸"; sidebar-row drops; launch sweep hashes existing copies. Gate: new offline check (same IPA on two
records → one blob; uninstall on A keeps B), check-uninstall-queue, check-sessions install step.

## Track C: pipeline, Swift only (after S1; ~10 d)

| Item | Effort | Gate |
|---|---|---|
| C1 Runtime GL shim: parse the dispatch string at load; one GLEngine/MBXGLEngine per arch; no TSVs, no per-build names | 3 | GLIDispatch generate == today's four tables; regress gles 7B500/8C148/7E18/8C148 |
| C2 mkpkg families by rule (board, iOS major, dyld legacy), hooks filtered at seed | 0.5 | mkpkg selfcheck; seed on 6 entries |
| C3 Catalog is the manifest; delete qemu-ios manifests/; tests take an entry JSON | 0.5 | fresh-device with --entry |
| C4 One Recipe with board plug-ins (verify/decrypt/identity/lock/keybag/bake shared) | 2 | swift test; lock diff empty on all entries |
| C5 Retire Python: port real-iBoot (done in C0) and `--gl-test`; golden-lock oracle; delete ~4,500 lines; `research/` keeps the probes | 4 | fresh-device on all 6 entries via firmwarekit; one-time cross-check against the last Python locks |
| C6 Bundled iPod as a prepared device (S2); delete LegacyAdoption, LaunchOptions, the legacy branches | 2.5 | check-firmware-jobs publish; check-sessions --single ipod; legacy-tree → prompt check |
| C7 iPod 2.1.1 in the app (N72 recipe 2.x path, keys, catalog) | 1 | in-bundle prepare + boot |

## Track D: emulator consolidation (after gl-coverage and usb-alert merge; ~10 d)

| Item | Effort | Gate |
|---|---|---|
| D1 One hypercall dispatcher with optional agent/kbd hooks | 0.5 | iPod regress agent,gles; iPad boot-smoke --guest-package |
| D2 Shared board helper (props, power-off gesture, chords, multitouch QMP) | 2 | both persist checks; test_ui_buttons, test_attitude_qmp |
| D3 Merge I2S, SHA-1, ChipID into one model each with variant properties | 2.5 | iPod audio; iPad audio-check; snapshot-check |
| D4 Delete the GID KBAG table and the kernel banner table (after the nand-current swap) | 1 | test_aes; fresh-device both boards |
| D5 I2C slaves into their own files; SPI global → property; iBoot literal tricks into it_iboot.c | 2 | regress boot both boards |
| D6 Delete dead tools and scripts (hidbridge, ssh terminal, kbd-agent, patch_*, probes); it_agent includes it_pbd | 1 | test_agent_ops; boot-smoke paste |
| D7 IT_* env knobs → machine properties (tests and app pass properties) | 1 | regress both boards |
| D8 Tests by board parameter: tests/lib, boards/, checks/, one regress.py --board | 2 | both regress suites green |

## Track E: repo story (E1–E3, E5 after fk-k48-iboot merges; ~6 d)

| Item | Effort | Gate |
|---|---|---|
| E1 Pin file `build-support/sources.json` (qemu-ios, usbmuxd); qemu-ios `contrib/export-guest-artifacts.sh`; xcconfig/build-release/tests resolve through it | 1 | release build from the pin; test-release |
| E2 READMEs rewritten as entry points; docs → live / archive / research; contradictions fixed; dangling links removed | 1 | link check |
| E3 `tests/gate.sh --quick|--full` (qemu-ios) and `scripts/gate.sh` (app); fix test_regress mock | 1 | both green |
| E4 App tests: offline/ sessions/ release/ + run.py; slicers → whole-file compiles with stubs | 2 | run.py offline green before and after |
| E5 Prune 31 merged worktrees and branches; tag-then-delete the July experiments; drop the duplicate `fork` remote | 0.5 | worktree list |
| E6 Service layering (Transport/Services/Guest/Features) and big-VC extractions | 4.5 | offline checks after marker updates; check-sessions |

## Order

1. Track A now (one agent). In-flight branches merge as they land; then the next notarized build for Sam.
2. Track B, then E1/E3/E5 (after the iBoot merge), then C1–C3 (after gl-coverage merges).
3. S1/S2 decided → C4–C6; D1–D8 as a series of small branches; E2, E4, E6 last, when the code stops moving.
