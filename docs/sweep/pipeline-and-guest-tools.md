# Sweep survey: guest tools and pipeline (2026-09-28, read-only)

# Guest tools + IPSW→device pipeline survey (read-only)

Repos: qemu-ios-ipad1 `821f1b5428`, LightTouchMac-multidevice `d1b3ce4`. Paths below are absolute under `/Users/shg/Developer/qemu-ios-ipad1` (Q) and `/Users/shg/Developer/LightTouchMac-multidevice` (L). Activation: only call sites noted (Q/imgtools/device.py:65,134; Q/imgtools/ipad1_rootfs.py:772,793; Q/imgtools/ipod2g_device.py:315; L/Packages/FirmwareKit/Sources/FirmwareKit/SystemEdits/SystemEdits.swift:194; L/.../N72/N72Recipe.swift:377).

## 1. Guest tools in contrib/

Arch/board evidence: `armv6-toolchain/armv6.sh` builds armv6 by default, `GUEST_ARCH=armv7` for iPad (Q/contrib/ipad1-guest/build.sh:12). Package families and per-build gating: Q/contrib/guest-package/mkpkg.py:51-68.

| Tool | Arch / boards | Baked / packaged / one-shot | Used by | Notes |
|---|---|---|---|---|
| it-agent (it_agent, it_typein.dylib) | armv6, n72 | baked + n72-ios3 package (mkpkg.py:41,53-57) | ipod2g_device.py, bake-guest-tools.sh:77-82, N72Recipe.swift:312-313, 8 iPod tests | **it_agent.c is a copy of it-pasteboard/it_pbd.c** (diff = 72 lines, header still says "the guest half of the clipboard", Q/contrib/it-agent/it_agent.c:2) |
| it-pasteboard (it_pbd; pbprobe, pbset) | armv7 via ipad1-guest/build.sh:16; source is arch-neutral | k48 package (mkpkg.py:42-43) | SystemEdits.swift:47, ipad1_rootfs.py:227 | pbprobe/pbset: 0 refs (dead) |
| it-boot | both (it-boot/build.sh:12, `LEGACY_LINK=1` for armv6) | baked loader (mkpkg.seed) | both preparers, GuestPackage.swift:18 | already one source, two targets: the model |
| it-prefs | both: ipad1-guest/build.sh:16 and it-prefs/build-ipod.sh (`IT_PREFS_TIP_ONLY`, it_prefs.c:63) | k48 package; iPod baked (ipod2g_device.py:58) | SystemEdits.swift:48, N72Recipe.swift:360 | runtime key discovery (it_prefs.c:21-23): the model for "no offsets" |
| it-keybag | both (ipad1-guest/build.sh:16; build-ipod.sh, `DATA_DEV` ifdef it_keybag.c:34) | prepare-time one-shot | ipad1_keybag.py, ipod2g_keybag.py, Preparer.swift:297, N72Keybag.swift | one source, two targets |
| it-ethlink | armv7 only | k48 package | ipad1_rootfs.py:227, regress.py | iPad has USB-Ethernet; iPod doesn't |
| it-seal | armv7 only | prepare one-shot | ipad1_seal.py, Preparer.swift:49 | iPod needs no seal (N72Recipe.swift:6) |
| it-msmquiet | armv7 (dylib) | k48 hook | SystemEdits.swift:48,190 | interposes by symbol |
| it-gles (mbxshim → MBXGLEngine-<BUILD>, sblaunch, GLTest, gles_tri/tex/surf/fw) | armv6 | MBXGLEngine: baked + hook; sblaunch: package | ipod2g_device.py:242, bake-guest-tools.sh, N72Recipe.swift:304,308 | gles_tri/gles_tex/gles_surf/gles_fw: 0 refs (dead probes) |
| ipad1-gles (glishim → GLEngine-<BUILD>, gldshim, glitsv.py, gligen.py, GLTest/GLTest2.app) | armv7 | baked + hook | ipad1_rootfs.py:100-114,630-647; SystemEdits.swift:244-272 | glishim.c includes mbxshim.c (glishim.c:7-9): **already one GL source**, two front ends |
| appsync | fat armv6+armv7 (appsync/build.sh:2-5) | k48 hook; n72 hook | both recipes | already one source |
| it-gltest | armv7 | test-only one-shot (`--gl-test`) | tests/ipad1/gltest.py; Preparer.swift:190 hardcodes `gl_test: false` | |
| it-heading | armv7 | test probe; built by ipad1-guest/build.sh:29 | **0 refs** in tests/preparers | dead |
| it-cctest | armv7 | test probe | tests/ipod/cctest_guest.py (1) | research |
| it-media (itmedia, itphoto), it-proxy (itproxy, ittrust, httpget), it-halt (ithalt, itbattery), it-status, it-orientation, it-instprogress (sbdlicon) | armv6, n72 | n72-ios3 package (mkpkg.py:41-45) | app payload set (L/scripts/build-guest-tools.sh:222-233) | iPod-only by design (vanilla-guest principle on iPad) |
| it-instprogress isprogress.dylib, sbunlock; it-kbd-agent | armv6 | not baked | 0 refs (it_kbd_agent: only removal from DYLD_INSERT, N72Recipe.swift:321; source says "never run", it_kbd_agent.c:5) | dead |
| it-webproxy | **host** binary (build.sh uses plain `cc`, curl) | not a guest tool | app | misfiled under contrib/it-* |
| it-audio (offline.c), ipad1-mictest, ipad1-hidbridge, ipad1-hw, it-harness | probes | not shipped | mic-check.py, regress (Harness.ipa) | hidbridge superseded by USB-keyboard (only `--hidbridge` flag ipad1_rootfs.py:657) |
| guest-package (mkpkg.py, build.sh) | both | packer + seed | both preparers, GuestPackage.swift | **FAMILIES hardcodes builds per family** (mkpkg.py:52-66) |

Same job twice: **it_agent vs it_pbd** (clipboard; the only real duplicate). prefs/keybag/appsync/GL shim are already single-source with a target list; what remains split is the *build glue* (ipad1-guest/build.sh, build-ipod.sh, it-gles/build.sh, ipad1-gles/build.sh, guest-package/build.sh, L/scripts/build-guest-tools.sh:93-156 re-implementing per-component recipes a second time).

## 2. Per-address / per-build inventory (b)

| File:line | What | Kind | Replace with | Blocks new FW? |
|---|---|---|---|---|
| patch_libmis.py:41-45 | `0x33A27C58` MISValidateSignature, bytes `AF00B580` | address | already replaced by appsync_cachepatch.py (LC_SYMTAB scan, :29-62) | no: 5F138-only, dead |
| patch_springboard.py:51-62 | `0x26B44` (2.1.1 ARM), `0x17D1C` (3.1.3 Thumb) applicationSignatureState | address+pattern table | appsync dylib covers launch gate (appsync.c:1-12); objc.py could locate by selector | no: dead |
| patch_codesign_gate.py:52-65 | drives the two above; GOLDEN path hardcoded | orchestration | delete | no |
| README-appsync.md:22-25 | installd `0x9F34`,`0x605C`; cache `0x1750EF8` | doc of retired offsets | delete/mark historical | no |
| patch_launchd_env.py:52-67 | bplist search by size+Label in raw NAND | pattern (not address) | superseded by mounted edit (ipad1_rootfs.rewrite_plist:273) | no |
| patch_gpt.py:21 | `sys.path.insert(0, "/Users/shg/Developer/qemu-ios/.claude/worktrees/consolidate/imgtools")` | dead absolute path | delete | no |
| patch_syscfg.py:46-59 | SysCfg found by magic scan | pattern | fine; superseded by build_nor.py | no |
| appsync_cachepatch.py:15-17 | symbol `_MISValidateSignature`, Thumb entry check | **symbol** (model) | keep | no |
| ipad1_kboot.py:63 / KBoot.swift:26 | DEFAULT_BOOT_ARGS incl. `enable-hsic=1` (Py) vs without (Swift) | per-build boot-args, **drifted** | manifest `boot_args` | medium |
| ipad1_kboot.py:65,68-73 | IBOOT_VERSION fallback `iBoot-817.29`; derived from iBoot.bin when present | derived (fallback constant) | fine | no |
| ipad1_kboot.py:128-129,216-218 | clock table (measured 7B500 unit) | board constant | belongs in board profile (manifest board section or DT from IPSW) | no (per board) |
| ipad1_kboot.py:134-145 / KBoot.swift:40-47 | NAND DT props incl. `ppn-device`, 4.x meta layout, "*-ns dropped on iBoot-931" | per-board + iBoot-version branch (`if key in disk` :330) | already conditional on DT shape: fine | no |
| ipad1_kboot.py:293-296 / KBoot.swift:119 | `display-rotation 270` (4.x-only semantics, comment :289-292) | per-major behaviour | fine, documented | no |
| ipad1_kboot.py:345 / KBoot.swift:157 | `vbase & 0xF0000000` (3.x C000, 4.x 8000) | derived from Mach-O | fine | no |
| ipad1_kboot.py:156-158 / KBoot.swift:48 / Identity.swift:42 | MODELS `{"16g":"MB292"}`, region `LL/A`; N72Recipe.swift:21 `8g/16g/32g` | board table, **duplicated Py/Swift and iPad hardcodes region** | manifest (iPod already has `model_number`/`region_info`; iPad doesn't) | low |
| ipad1_nand.py:113-132 / K48NAND.swift:91-97 | GEOMETRIES `k48-16g` (Hynix 0xB614D5AD), `GEOMETRY={"16g":...}` ipad1_device.py:28 | board/storage table | manifest `storage` already keys it; fine | no (new storage size = new row) |
| ipad1_nand.py:80-81 / K48NAND.swift:12 | NSIG `0x43313131`, SIG_FLAGS; whitening LCG seed | FTL format constants "checked against 7B500 kernelcache" (:59) | fine (format), but no runtime check for 4.x/5.x FTL changes | medium for iOS 5 |
| ipad1_nand.py:85 / K48NAND.kernelVersion | "Darwin Kernel Version" string from kernelcache | **derived** | keep | no |
| ipod2g_device.py:148-158,171-183 / N72Recipe.swift:89,112-114,133-138,155,182 | `major >= 3` ×6: wrap_shsh, direct_iboot, guest_tools_supported, kernelcache member source | iOS-major branches | most are "does the IPSW have BuildManifest / does dyld take LC_DYLD_INFO_ONLY": detect from the IPSW/dyld instead | low |
| ipod2g_device.py:89 / N72Recipe.swift:240 | kernelcache path from iBoot string | derived | keep | no |
| ipod2g_nand.py:19,109 / N72NAND.swift:98-102 | NANDDRIVERSIGN from Restore.plist SCEP | derived | keep | no |
| build_nor.py:107 | `S5L8930_UID_KEY = b"K48AP-UID-S5L8930-iPad1-7B500-01"`; N72NOR.swift:20 `uidKey 0123…` | emulated-UID constants | board constant in manifest; must match machine | no |
| ipad1_iboot.py:75-77 | iBoot32Patcher `--rsa --debug -b` ("-a broken for 817.29") | external pattern patcher, per-iBoot quirk | keep pattern-based; note Swift has none (below) | medium |
| ipad1_seal.py:18-22 / Preparer.swift:49-56 | serial markers `CXT is not valid`, `FTL_Open [OK]`, `it_seal: halting` | log strings | fine | no |
| ipad1_keybag.py:25 / ipod2g_keybag.py:34,35,145 | `phys == 0x08000000`, `CMDLINE_OFF 0x38`, boot_args struct rev 1 | boot_args ABI | derived from kernel Mach-O + boot_args rev; fine | no |
| ipad1_rootfs.py:100,GLI_TSVS; ipod2g_device.py:51 | `docs/{ipad1,ipod}/gli-dispatch-<BUILD>.tsv` list; shim ABI check by `@encode` (:199-209) | **derived at prepare time, but the shim is precompiled per TSV** | keep check; TSV can be generated (glitsv.py; GLIDispatch.generate Swift, only in tests L/.../GLIDispatchCheckTests.swift:64) | **high**: every new dispatch layout = new TSV + new shim build + mkpkg row + build-release lists |
| mkpkg.py:52-66 | FAMILIES `builds: ["7B367","7B500"]`, `["8C148"]`, LEGACY_BUILDS `("5F138",)` | per-build lists | derive family from (board, major, gli id, dyld legacy) at seed time; GuestPackage.swift:87 already matches by manifest | **high** |
| L/scripts/build-release.py:23-31 | `GLEngine-7B500`, `gli-dispatch-8C148.tsv`, `MBXGLEngine-7E18`, … | per-build file allowlist | glob `GLEngine-*`/`gli-dispatch-*.tsv` | high |
| L/scripts/build-guest-tools.sh:58-59,244-277 | same per-build names; "8C148 TSV must be same file" cmp | per-build | glob | high |
| Q/hw/arm/ipod_touch_firmware.c:9-12 | kernel banners 5F138, 7E18 | per-build in emulator | STATUS.md already lists as debt | medium (iPod) |
| Q/hw/arm/ipod_touch_aes.c:52-180 | 25 named GID KBAG entries (5F138 ×11, 7E18 ×14), superseded by `gid-blobs=` (:385-420) | per-build in emulator | delete table; manifests already ship gid-blobs.bin | low (but is key material in the binary, cf. ipad1_gid.py:4) |
| ipad1_rootfs.py:78-89,939-946 | FILES `~/Developer/qemu-ios-files/ipad1`, `hw2/…` defaults, BASES jailbroken | machine-local paths | research-only; move out of the pipeline module | no |
| firmware-catalog.json (L) | `gli_dispatch` pins per entry (7E18/7B500/8C148), `guest.gl_engine` field | per-build pin | drop pin; recipes already auto-detect when absent (N72Recipe.swift:287, SystemEdits.swift:249) | low |

Ranking by "blocks a new firmware": (1) GL shim per-TSV build + name lists in 3 places; (2) mkpkg FAMILIES; (3) Python↔Swift drift on boot strategy/boot-args (below); (4) emulator per-build tables (iPod); (5) everything else is board-level or derived.

## 3. Python vs Swift

**Classification of imgtools (Q/imgtools/):**
- Pipeline: device.py, ipad1_device.py, ipod2g_device.py, ipad1_fw.py, ipad1_gid.py, ipad1_kboot.py, ipad1_iboot.py, ipad1_nand.py, ipad1_rootfs.py (build/bake), ipad1_seal.py, ipad1_keybag.py, ipod2g_keybag.py, ipod2g_nand.py, build_nand.py, build_nor.py, bake-guest-tools.sh, set-sound-defaults.py, appsync_cachepatch.py, vfdecrypt.py, macho.py, hfsvol.py/hfsfile.py (owner patching), nandblob.py.
- Test harness / drivers: itqmp.py, itdrive.py, itshell.py, record.py, bootshot.py, ffmpeg_guard.py, cdverify.py, ftlcheck.py, ftlmap.py, nand_manifest (tests/).
- Research/debug: klog.py, sel.py, objc.py, objct.py, sb_probe_call.py, sb_workflow_*.py, fairplay_probe.py, extract_bootlogo.py, lldb/, ipad1_boot.py, dumpvol.py, packvol.py, editimg.py, grow_volume.py, patch_gpt.py, pack_nand.py.
- Dead/historical: patch_codesign_gate.py, patch_libmis.py, patch_springboard.py, patch_launchd_env.py, patch_syscfg.py, free_disk_space.py, inject_apps.py, setup_networking.py, reset-content.sh, install-ipa.sh (ssh-era; STATUS "Guest tools without SSH").

**Sync mechanism today:** Swift tests shell out to python3 at test time (L/.../K48NANDTests.swift:24,98; HFSPlusTests.swift:14; GLIDispatchCheckTests.swift:46,68) plus stored oracle hashes (OracleFixtures.swift:1-4, pinned to *specific old commits* `e6de24c7fa`, `5f365778a4`). So "byte-matched" is module-level, and the oracle pin is already stale relative to `821f1b5428`.

**Already diverged (whole-device level):**
- iPad boot strategy: Python ships `iBoot.bin + nor.bin + gid-blobs.bin` via iBoot32Patcher and seals with `--iboot` (ipad1_device.py:60-62,96-97; lock `boot_strategy: "iboot"` :113; default since `ff331e1ef9`). Swift ships `kboot.bin` and seals with kboot (Preparer.swift:125,155,187). No iBoot path in FirmwareKit at all.
- iPad boot-args: Python has `enable-hsic=1` (ipad1_kboot.py:63), Swift doesn't (KBoot.swift:26) → 4.2.1 USB keyboard differs (STATUS "4.2.1 keyboard bug open").
- Python writes iPad `nor.bin` always; Swift only `writable_nor` and as blank 0xFF (Preparer.swift:147).
- Swift-only: F1 mount/export (VolumeRebuild/), StepProgress, cancel, Activation built in (CActivation). Python-only: `--gl-test`, jailbroken base/fetch/report, hidbridge, real-iBoot, `--activation-hook-arg` for iPod (device.py:135), `--disable LABEL`.

**Cost of the last two firmwares in both repos:**
- iPod 8C148: Q commits a6a6742f72, e21b99956c, f0e8cc1a97, 84f60c2b16, b91de881da → imgtools: ipod2g_device.py (+83), ipod2g_keybag.py (+235 new), ipod2g_nand.py (+19), bake-guest-tools.sh, ipad1_rootfs.py; contrib: it-keybag build-ipod.sh, mbxshim.c (+115), gligen/glitsv, it-gles/build.sh, guest-package (mkpkg row); docs: new gli-dispatch-8C148.tsv (845 lines) and 7E18 TSV regenerated (1651 lines changed); manifest; regress. Then L: N72Keybag.swift (+247 new, a port of ipod2g_keybag.py), N72Recipe.swift (+90), Preparer.swift (+53), SystemEdits.swift (+32), build-guest-tools.sh (+36), build-release lists, catalog entry (6 lines), 2 app tests. **~2 weeks of Python work re-done in Swift within ~2 days**: the port tax is roughly 400 Swift lines per new mechanism.
- iPod 2.1.1 (5F138): Q f555749efe: 16 files, 404+/684-, mostly emulator (ipod_touch_2g.c -382, mbx.c -233); imgtools: build_nor.py (+29), ipod2g_device.py (+14), bake-guest-tools.sh (+27). L: only activation (56598a3, Sam's) and catalog (`coming_soon`, no recipe). The Swift side never received the 2.x `guest_tools_supported`/legacy-loader logic fully (STATUS "needs the N72 recipe path").

**Recommendation: option (ii) with a twist — Swift is the pipeline; Python survives only as `research/` + the emulator-facing test drivers, never as an oracle.**
- (i) keep both as oracle: cost = every mechanism twice (measured above), plus the oracle pin drifts (already stale), plus the divergences above are *unnoticed* because tests compare modules, not devices. Rejected.
- (ii) Swift only: delete device.py/ipad1_device.py/ipod2g_device.py/ipad1_rootfs.py build+bake/ipad1_seal/ipad1_keybag/ipod2g_keybag/build_nand/build_nor/ipod2g_nand/bake-guest-tools.sh/set-sound-defaults (≈4,500 lines); keep ipad1_fw.py, ipad1_kboot.py, ipad1_nand.py as *documentation of the formats* only if the Swift files' comments aren't sufficient (they largely are: K48NAND.swift:1-20). Port the two Python-only pipeline features Sam needs (real-iBoot boot: ipad1_iboot.py is 109 lines + iBoot32Patcher dependency; `--gl-test` bake is already in SystemEdits.Options). Oracle tests become golden `device.lock.json` hashes per firmware (nand `listing_sha256`, nor/iboot sha256 already in the lock: N72Recipe.swift:210-211, Preparer.swift:187-189) regenerated on intentional change; tests/ipad1/fresh-device.sh and tests/ipod/fresh-device.sh invoke `firmwarekit create` (they only need a lock + a device dir; their Python is glue). Scope: the port, then a golden-hash test per firmware; risk: losing the iPad real-iBoot path in the app unless ported first.
- (iii) Python for spikes only: same as (ii) but keep `research/` (klog, sel, objc, sb_*, editimg, dumpvol, itqmp...) as-is; that's what (ii) does anyway. So (ii)+(iii) are the same plan.

One rule after the switch: qemu-ios tests boot devices made by `firmwarekit`, so the emulator repo depends on the app repo's CLI. Acceptable (STATUS already says the app runs only firmwarekit); ship the CLI as a build artifact the qemu-ios tests fetch, or move FirmwareKit into qemu-ios as `tools/firmwarekit` (Swift package; no Xcode needed).

## 4. Manifests vs catalog

- Not copied and not referenced: `manifests/*.json` (Q, `format 1`, per-build keys: board, product_type, build, storage, ipsw{path,sha1}, keys=path to a keys text page, identity.seed, system_mib/volume_blocks, options, activation.hook) vs `firmware-catalog.json` (L: id, board, product_type, version, build, status, source{url,sha1,bytes}, keys inline, recipe{name,version,storage,system_mib,data_size,options,gli_dispatch}, emulator, estimates). Same sha1s, same options; the catalog **inlines the keys** and adds URL/estimates/status; the manifest has file paths on Sam's disk. FirmwareCatalog.swift:2 says "field names follow qemu-ios manifests"; that's the only link. Schema doc: docs/multi-device-plan.md §B (L:139); manifests have no schema doc beyond device.py's docstring (Q/imgtools/device.py:1-16).
- Per-board vs per-build: per-board = board, storage→geometry, model/region, uid key, recipe name; per-build = build/version, sha1/url/bytes, keys, options (`writable_nor`, `data_protection`, `appsync`), gli_dispatch pin, estimates.
- New firmware needs: manifest (Q) + catalog entry with inlined keys (L) + mkpkg FAMILIES row (Q) + TSV+shim if the GL layout is new (Q) + allowlists (L ×2) + app row tests (L/tests/check-device-rows.py, e.g. 67d2803).
- One source: yes. Make the catalog entry the manifest (device.py already only needs sha1, keys, seed, options; the keys page → inline dict is a 10-line converter). Then delete Q/manifests/ and have qemu-ios tests read `firmware-catalog.json` from the FirmwareKit checkout (or vendor the JSON into Q as the one file that crosses).

## 5. FirmwareKit K48 vs N72

Duplicated between Preparer.swift (k48) and N72Recipe.swift: verify+sha1 (P:94-101 / N:78-86), decrypt cache (P:103-118 / N:93-107, identical), identity seed naming (P:122 / N:117), step/progress scaffolding (P:83-92 / N:68-76), read-only outputs + hashing + lock assembly (P:157-197 / N:181-222, ~40 lines each, lock keys differ slightly), keybag one-shot retry (P:294-320 / N72Keybag.run), guest-package seed + owners (SystemEdits:196-201 / N:381-385), web-proxy PAC+prefs (SystemEdits:154-157,220 / N:365-375), appsync cache patch + installd inject (SystemEdits:164-170 / N:348-358), GL install + cached-image override (SystemEdits:244-294 / N:298-305,343-347), activation call, SpringBoard env edit (SystemEdits:159-163 / N:315-323), it_prefs install (SystemEdits Helpers.tools / N:359-364). Board-specific and rightly so: NAND writer (K48NAND vs N72NAND), NOR (N72NOR only), kboot vs direct-iboot, data volume (k48 only), seal (k48 only), sound defaults + `.lt-guest-tools-v*` markers (n72 only, legacy app contract).

One Recipe with conditional steps is feasible: `create()` = verify → decrypt → identity → board.bootFiles → board.volumes(bake: shared) → board.store → [keybag if data_protection] → [seal if board.needsSeal] → lock. The shared bake list is driven by `options` already; the only per-board bake differences are helper *names* (`it_prefs` vs `it_prefs-armv6`, N:360) and the cache path (armv6 vs armv7: SystemEdits:86 / N:23) — both derivable from `board`/arch.

## 6. Cross-repo artifacts

| Artifact | Source of truth | Consumer | Pinning |
|---|---|---|---|
| contrib/*/ sources (armv6-toolchain, it-*, ipad1-*, appsync, guest-package) | Q | L/scripts/build-guest-tools.sh:20 `QEMU_IOS_DIR` default `../qemu-ios` (**whatever is checked out**; validate_guest records path+sha256 of inputs, build-release.py:163-184, not a commit) | none; source hashes recorded after the fact |
| docs/ipad1/gli-dispatch-*.tsv, docs/ipod/gli-dispatch-*.tsv | Q docs/ (generated by glitsv.py from the IPSW cache, needs capstone) | copied into the app's guest-tools dir (build-guest-tools.sh:86-87,251-271); read at prepare time (SystemEdits:250, N72Recipe:287) | by name; 8C148 identical in both dirs (cmp OK) |
| GLEngine-<B>, MBXGLEngine-<B>, GLRendererFloatQEMU | built from Q sources + TSV | app Resources/guest-tools | name lists in build-release.py:23-31 |
| armv6.itpack / armv7.itpack | Q/contrib/guest-package/build.sh (VERSION serial 1) | preparers seed; app composes offers | by file; serial manual |
| libqemu-arm.dylib | Q build | app | `--qemu-source` checkout, `source_identity` records rev+dirty (build-release.py:57-76) |
| usbmuxd | separate repo | app | **pinned** `USBMUXD_COMMIT` (build-release.py:224-226) — the only real pin |
| bootrom_240_4 | qemu-ios-files | N72Keybag (N72Recipe.swift:227-233) | none |
| manifests ↔ catalog | see §4 | | none |
| Oracle pins | OracleFixtures.swift:3 (`e6de24c7fa`, `5f365778a4`) | tests | stale |

## (a) Ranked consolidation proposals

1. **Generate the GL dispatch TSV at prepare time and stop shipping per-build shims.** Files: L/.../GLIDispatch.swift:182 (generate exists, test-only), SystemEdits.swift:244-272, N72Recipe.swift:283-305, Q/contrib/ipad1-gles/{glitsv.py,gligen.py,glishim.c}, it-gles/mbxshim.c. The shim's slot table is `gli_fwd.h` generated per TSV; make glishim/mbxshim read a table from a data file (or build the forwarders once for the union of slots with a runtime slot→wire map: gli_slot313[] already exists, gligen.py:8-13) so one GLEngine binary per arch serves every layout. Benefit: new firmware = zero GL touch points in 5 files. Risk: forwarder ABI per slot argc must be static → keep argc from the base table (gligen TAIL_ARGC); unknown new slot = stub (already the behaviour). Proof: GLIDispatchCheckTests `generate` equals committed TSVs for all 4 layouts; gltest.py/regress gles on 7B500, 8C148, 7E18.
2. **Retire Python pipeline; golden-lock oracle** (§3). Files: Q/imgtools/{device,ipad1_device,ipod2g_device,ipad1_rootfs,ipad1_seal,ipad1_keybag,ipod2g_keybag,build_nand,build_nor,ipod2g_nand}.py, bake-guest-tools.sh; L tests OracleFixtures/K48NANDTests/HFSPlusTests. Port first: real-iBoot boot (ipad1_iboot.py:70-89 + K48 NOR base) and `enable-hsic`. Proof: fresh-device.sh on all 6 entries via firmwarekit; lock hashes equal the last Python locks once (one-time cross-check), then golden.
3. **One Recipe, board plug-ins** (§5). Files: Preparer.swift, N72Recipe.swift, SystemEdits.swift, N72Keybag.swift. After #2. Proof: existing swift tests + fresh-device on all entries; lock diff empty.
4. **Catalog is the manifest** (§4). Delete Q/manifests/, teach Q tests to take an entry JSON (device.py already validates sha1/ProductType/Board; firmwarekit does the same, BuildIdentity.swift). Proof: fresh-device.sh with `--entry`.
5. **mkpkg families by rule, not by build list.** Q/contrib/guest-package/mkpkg.py:52-68: family = (board, "ios"+major, legacy = dyld lacks LC_DYLD_INFO support / build major < 3), hooks filtered by gli id at seed (already: mkpkg.seed :283, GuestPackage.swift:87). Proof: mkpkg selfcheck + seed on 6 entries.
6. **One guest-tools build recipe.** Delete L/scripts/build-guest-tools.sh:93-156 (a second copy of the contrib recipes) and the name allowlists (build-release.py:17-31); call Q/contrib/guest-package/build.sh and glob the output. Proof: test-guest-build.py, release verify.
7. **Delete it-agent's clipboard copy**: make it_agent include it_pbd.c or vice-versa (72-line diff). Proof: tests/ipod/test_agent_ops.py, boot-smoke --guest-package paste on iPad.
8. **Emulator per-build tables → inputs**: ipod_touch_aes.c:52-180 KBAG table (gid-blobs.bin already supplies it), ipod_touch_firmware.c banners (kernel banner is read at build: K48NAND.kernelVersion). Proof: regress 3.1.3/2.1.1 with gid-blobs only.
9. **Board profile in the catalog** (uid key, models/region, clocks, NAND DT props, boot-args) replacing KBoot.swift:26-48 / Identity.swift:42-43 / N72NOR.swift:20 constants. Only worth it with a second board of the same SoC; otherwise skip (YAGNI).

## (d) Dead or superseded

- Q/imgtools: patch_codesign_gate.py, patch_libmis.py (docstrings say 5F138-only; superseded by appsync_cachepatch.py), patch_springboard.py (appsync dylib), patch_launchd_env.py, patch_syscfg.py, patch_gpt.py (dead sys.path :21), free_disk_space.py, inject_apps.py, setup_networking.py, reset-content.sh, install-ipa.sh (ssh era), README-appsync.md offsets table; ipad1_rootfs.py `--base jailbroken`/`fetch`/`--hidbridge`/`--gles` apps (unit-dump era, memory says no unit data).
- Q/contrib: it-kbd-agent (never run), it-instprogress isprogress.dylib + sbunlock (0 refs), it-pasteboard pbprobe/pbset, it-gles gles_tri/gles_tex/gles_surf/gles_fw (0 refs), it-heading (0 refs), ipad1-hidbridge (USB keyboard replaced it), ipad1-hw (DFU research), it-webproxy misfiled (host tool).
- L: OracleFixtures pins to `e6de24c7fa`/`5f365778a4`; catalog `recipe.guest{arch,gl_engine}` fields (FirmwareCatalog.swift:36-40) unused by any entry; `gli_dispatch` pins redundant with auto-detect.

## (e) Adding a firmware (say iPod 3.0 / 7A341)

Today, 13 touch points: (Q) 1 manifests/ipod2g-7A341.json; 2 keys page on disk; 3 glitsv.py run → docs/ipod/gli-dispatch-7A341.tsv (if layout differs); 4 it-gles/build.sh rebuilds; 5 mkpkg.py FAMILIES row; 6 possibly `major`-branch tweaks in ipod2g_device.py; 7 tests/ipod/fresh-device.sh run; 8 emulator banner/KBAG tables if the emulator needs them. (L) 9 catalog entry with inlined keys + URL + estimates; 10 build-guest-tools.sh name checks; 11 build-release.py allowlist; 12 N72Recipe/SystemEdits port of any Python change; 13 tests/check-device-rows.py etc. Plus re-pin oracle hashes.

After #1, #2, #4, #5, #6: 3 touch points: catalog entry (keys, sha1, url, options), `firmwarekit create` + fresh-device run, and an emulator fix only if the boot chain needs one. GL layouts, packages, allowlists and Python go away.

### Critical Files for Implementation
- /Users/shg/Developer/LightTouchMac-multidevice/Packages/FirmwareKit/Sources/FirmwareKit/Recipe/Preparer.swift
- /Users/shg/Developer/LightTouchMac-multidevice/Packages/FirmwareKit/Sources/FirmwareKit/N72/N72Recipe.swift
- /Users/shg/Developer/LightTouchMac-multidevice/Packages/FirmwareKit/Sources/FirmwareKit/GLIDispatchCheck/GLIDispatch.swift
- /Users/shg/Developer/qemu-ios-ipad1/contrib/guest-package/mkpkg.py
- /Users/shg/Developer/LightTouchMac-multidevice/scripts/build-guest-tools.sh