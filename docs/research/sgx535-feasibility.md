# SGX535 feasibility study, and the GL seam options (iPad 1, iOS 3.2 to 5.1.1)

2026-09-29. Research only: static reading of the firmware on disk plus public sources. No emulator runs.
Ledger context: K48 row 54 (SGX535 absent), rows 55 and 59, guest-side rows for `GLEngine-<BUILD>`,
`GLRendererFloatQEMU.bundle`, the dyld override and the SpringBoard env; roadmap rows 11 and 12; smoke #24, #25 and #41.

Builds read: 3.2 7B367 and 3.2.2 7B500 (kernel only), 4.2.1 8C148, 4.3.5 8L1, 5.0.1 9A405 (kernel only), 5.1.1 9B206.
The method and the scratch tools are in the appendix.

## TL;DR

1. **Seam first.** One option sits between "private shims" and "a full GPU model": replace
   `OpenGLES.framework` itself. It would export the Khronos `gl*` names and implement EAGL,
   as `contrib/it-gles/gles2x.c` already does for iPhone OS 1.x/2.x.
   - Every consumer of GL in the shared cache goes through OpenGLES's exports and EAGL.
     GLEngine, libGFXShared and the gld plugin are reached only from inside OpenGLES.framework.
     The one outside user is OpenCL on 5.x, which nothing on the iPad calls.
   - Between 4.2.1 and 4.3.5 that layer did not change at all: the same 318 exports, the same 62
     QuartzCore imports and the same EAGL selectors.
   - The layer below did change: libGFXShared gained 16 exports and renamed the shared-state calls,
     the gld plugin table had 6 changes, and GLEngine's imports changed by about 50 symbols.
     That lower layer is where our shim sits, and it is why 4.3 lost GL.
   - Scope: six pieces (§1.5 table: export lists per build, the native window v6/v7, private EAGL, the 5.x macro
     context, Apple's extension entry points, the framecheck gates on four builds). The unknown is the private
     EAGL surface CoreAnimation uses beyond the selectors already listed. It retires glishim, gldshim and the
     libGFXShared generation logic. It is still class **P**, but it is P at the most stable seam there is.
2. **Full SGX535 model (class R): six phases (§3: registers + MMU, driver init, USSE1 interpreter, TA/ISP,
   fragment/texture, host shader translation); go/no-go is decoding the undocumented USSE1 encoding.**
   - The hardware interface is stable. The set of registers the kext touches is essentially
     identical from 3.2.2 to 5.1.1, and the names and offsets match the public Dual MIT/GPLv2 `sgx535defs.h`.
   - The microkernel is not a hardware constant. It is 2 to 5 USSE blobs embedded in each kext,
     and it grows and changes with every release, so it has to be executed rather than emulated at a high level.
   - **The single biggest unknown is the USSE1 instruction encoding.** It has no public documentation;
     the only complete source is a leaked DDK, which we must not read. We need it for the microkernel
     and for every shader the gld plugin's compiler emits.
3. **Recommendation:** do the public-API seam now, because it makes point releases a non-event for GL.
   Keep the SGX model as a research track whose first phase is the register file plus the MMU walker (S1).
   S1 is **not** the smoke #24 fix the ledger expects (see S1).

---

## 1. Seam options

### 1.1 Who touches GL in the shared cache

Every cached image outside `OpenGLES.framework/` that imports from OpenGLES, GLEngine, libGFXShared,
libGLProgrammability or libGLImage:

| build | importers (count of imported symbols) |
|---|---|
| 3.2.2 7B500 | QuartzCore (OpenGLES 60), MapKit (52), iLifeSlideshow (48) |
| 4.2.1 8C148 | QuartzCore (62), WebCore (136), MapKit (52), iLifeSlideshow (48), MediaToolbox (13); IMGSGX535GLDriver (libGLImage 4, libGLProgrammability 3) |
| 4.3.5 8L1 | as 4.2.1 + PhotoBoothEffects (32) |
| 5.1.1 9B206 | QuartzCore (**5**), WebCore (134), GLKit (70), iLifeSlideshow (48), ToneLibrary (44), PhotoBoothEffects (35), FaceCoreLight (29), MediaToolbox (13), CoreVideo (10), CoreImage (4); IMGSGX535GLDriver, libGPUSupport(Mercury) (libGLImage/libGLProgrammability); **OpenCL (libGFXShared 32)** |

- Nothing outside OpenGLES.framework reaches GLEngine.
- libGFXShared is imported only by the SGX gld plugin (which we would stop loading) and by 5.x OpenCL,
  which no iPad API exposes.
- Apps use the public exports. dyld's `enable-dylibs-to-override-cache` switch, which we already use,
  exists in all four dyld builds. So a file-based OpenGLES.framework would reach every process.

### 1.2 The CoreAnimation render server (SpringBoard's QuartzCore on 3.x to 5.x)

QuartzCore's imports and EAGL selectors (from `__objc_methname`/`__cstring`):

| | 3.2.2 | 4.2.1 | 4.3.5 | 5.1.1 |
|---|---|---|---|---|
| OpenGLES imports | 60 | 62 | 62 (= 4.2.1) | **5** |
| of which public Khronos ES2 | 54 | 56 | 56 | 0 |
| Apple/extension gl entry points | `glFinishObjectAPPLE`, `glFramebufferParameteriAPPLE`, `glMapBufferOES`, `glUnmapBufferOES` | same | same | none |
| EAGL public | `EAGLContext`, `EAGLSharegroup` classes, `kEAGLContextPropertySharegroup`, `initWithAPI:`, `setCurrentContext:` | same + `EAGLMemoryNotificationRecycling` | same | `EAGLContext`, `sharegroup`, `kEAGLContextPropertyClientRetainRelease` |
| EAGL private selectors | `attachImage:toCoreSurface:invertedRender:`, `swapNotification:forTransaction:onLayer:`, `sendNotification:forTransaction:onLayer:`, `initWithAPI:properties:`, `kEAGLContextPropertyAccelerated` | same | same | same + **`GetMacroContextPrivate`**, `texImageIOSurface:target:internalFormat:width:height:format:type:plane:invert:` |
| CAEAGLLayer → EAGL drawable | `nativeWindow`, `drawableProperties` | same | same | same |
| IOSurface / IOMobileFramebuffer imports | 50 / 26 | 53 / 26 | 54 / 26 | 63 / 34 |

What changed at each step:
- **3.2.2 → 4.2.1:** QuartzCore gained `glBlendEquation`, `glGenerateMipmap` and
  `EAGLMemoryNotificationRecycling`, and dropped `glUniform1f`.
- **4.2.1 → 4.3.5:** no change to the OpenGLES imports. The IOSurface imports gained one constant,
  `kIOSurfaceBufferTileMode`.
- **4.3.5 → 5.1.1:** QuartzCore stops importing `gl*` at all. It fetches the GLI "macro context"
  (`-[EAGLContext GetMacroContextPrivate]`, the export `EAGLGetCurrentMacroContextPrivate`) and calls
  through the context's `__GLIFunctionDispatchRec`. The 5.x QuartzCore has no `gl*` import and no `gl*`
  string for a `dlsym`, so this is inferred from the imports, not disassembled. It means a replacement
  OpenGLES must hand 5.x QuartzCore and CoreImage a dispatch table laid out as in the firmware.
  - The layout is the `__GLIFunctionDispatchRec` @encode: 826, 841, 870 and 905 fields on the four builds.
  - `contrib/it-gles/gles_dispatch.c` already reads that @encode at load, so this reuses existing code.
- IOSurface and IOMobileFramebuffer stay Apple's under every option. They sit on the kernel models we already have.

### 1.3 The renderbuffer-storage and present path (CAEAGLLayer ↔ EAGL ↔ IOSurface)

These are all private. The encodings come from the shared caches.

- **The native-window object** that `-[CAEAGLLayer nativeWindow]` returns and EAGL binds:
  - 3.2.2: `{_EAGLNativeWindowObject="version"i "attach" "detach" "begin" "swap" "collect"}` together with
    `{EAGLNativeWindowCallbacksRec="callback_data" "create_buffer" "destroy_buffer"}`.
  - 4.2.1, 4.3.5 and 5.1.1: the same struct plus a seventh entry, **`"properties"`**. It is identical on all three.
  - It is the same closure gles2x.c drives for 2.x, shaped {bind, unbind, nextBuffer, present},
    and the same one mbxshim/glishim handle today inside the GLI layer (mbxshim.c ~1280-1376).
    The `version` word tells the shapes apart.
- **EAGL methods on that path:**
  - `renderbufferStorage:fromDrawable:` and `presentRenderbuffer:` are public.
  - `attachImage:toCoreSurface:invertedRender:` is CA's compositor target, with type string
    `c20@0:4I8^{__IOSurface=}12c16`. The signature is the same from 3.2.2 to 5.1.1.
  - `texImageIOSurface:…:plane:invert:` exists from 4.2.1 (`c44@0:4^{__IOSurface=}8I12I16I20I24I28I32I36c40`).
    QuartzCore uses it from 5.x; CoreVideo and CoreImage use it on 5.x.
  - `getParameter:to:` and `setParameter:to:` are private.
  - `swapNotification:`/`sendNotification:forTransaction:onLayer:` are the EAGL↔CA frame notifications,
    unchanged from 3.2.2 to 5.1.1.
  - 5.x adds `loadGLIPlugin:sharedWithCompute:`, `initWithAPI:sharedWithCompute:` and `getGLIShared`.
    These are internal to OpenGLES; a replacement simply never calls them.

### 1.4 The layer below, where our shim sits today

| | 3.2.2 | 4.2.1 | 4.3.5 | 5.1.1 |
|---|---|---|---|---|
| OpenGLES exports (all / `gl*`) | 310 / 290 | 318 / 297 | **318 / 297 (identical)** | 357 / 333 |
| GLEngine | on disk | cached, 20 exports (`gliCreateContextWithShared` added) | 20 (identical) | 20 (identical) |
| GLI dispatch fields (@encode) | 826 | 841 | **870** | 905 |
| libGFXShared exports | 51 | 51 | **65** (`gfxRetain/ReleaseSharedStateAndHash` replace `gfxRetain/ReleaseSharedState`, sync/sampler/buffer calls added, `gfxPluginDisconnectAll` gone) | 68 |
| gld entry points libGFXShared looks up | 79 | 81 | **83** (+`gldCopyBufferSubData`, `gldCreateSampler`, `gldDestroySampler`, `gldUpdateReadFramebuffer`; −`gldFlushBuffer`, `gldUpdateFramebuffers`) | 113 (gld 4.0: device/share-group/queue model) |
| GLEngine's imports (non-libSystem) | – | – | ~50 symbols changed vs 4.2.1 (libGFXShared renames, the new libCVMSPluginSupport hash machine, libGLProgrammability `Sh*`/`glsm*` rework) | – |

All of the 4.3 churn sits under OpenGLES's exports. That is consistent with "4.3.x silently lost
hardware GL": our gld plugin answers 4.2.1's 81-entry table, and 4.3's libGFXShared wants a different
83-entry one. The fallback's exact trigger was not traced here.

### 1.5 Could gles2x.c's front end cover the iPad?

Yes, as an extension of what exists.

What gles2x.c already has:
- It exports exactly the stock binary's names, read by `gles2x_exports.py`.
- It routes each `gl*` export to the mbxshim core by its `gles-names.h` row.
- It implements `EAGLContext`/`EAGLSharegroup` with `initWithAPI:[sharegroup:]`, `setCurrentContext:`,
  `currentContext`, `renderbufferStorage:fromDrawable:`, `presentRenderbuffer:`,
  `attachImage:toCoreSurface:invertedRender:` and `swapNotification:…`.
- It drives the native-window closure.
- The ES2 slots already run on the host (`gles-host.c`); glishim uses them today.

What the iPad needs on top, per build:

| work | builds | unknown |
|---|---|---|
| Export lists for 7B500/8C148/8L1/9B206 (run `gles2x_exports.py` on each cached OpenGLES; new EXT names get generated forwarders or counted refusals) | all | – (generated) |
| The native window v6/v7 (`version`, `collect`, `properties`) instead of 2.x's four-entry closure | all | which fields each version adds |
| Private EAGL: `initWithAPI:properties:` (kEAGLContextPropertyAccelerated, Sharegroup, ClientRetainRelease), `getParameter:to:`/`setParameter:to:`, `sendNotification:…`, `texImageIOSurface:…` | 3.2+ / 4.x+ | private selectors CA calls that the static read missed |
| 5.x macro context: `GetMacroContextPrivate`/`EAGLGetCurrentMacroContextPrivate`, `GLIContextFromEAGLContext`, the `GLC*Dispatch` exports, a dispatch table at the firmware's @encode layout (reuse `gles_dispatch.c`) | 5.x (the GLC/GLI exports exist on all four) | who calls the GLC/GLI exports on 5.x |
| Apple extension entry points CA uses (`glFramebufferParameteriAPPLE`, `glFinishObjectAPPLE`), MSAA resolve and discard (4.x+) on the host | all | – |
| Gates: regress gles legs plus `framecheck.py` against the software-CA reference on all four builds; smoke entries | all | – (this row is the gate) |
| **Done when** | | the gate row passes on 7B500, 8C148, 8L1 and 9B206 with no GLEngine or gld plugin installed |

What it retires and what it keeps:
- **Retires:**
  - glishim (`GLEngine-<BUILD>`).
  - gldshim (`GLRendererFloatQEMU.bundle`).
  - `gfx_gen.h`, i.e. the libGFXShared generation detection, `gliInitializeLibrary` argument matching and the float-plugin scan flag.
  - Smoke #41, since the 0x28FF parameter, the format-less label surfaces and the scan bit are all engine behaviours no longer in the path.
  - Most of smoke #25, since the present cadence becomes ours by contract rather than a match to the stock engine's.
  - The per-build dispatch derivation for 3.x/4.x, where CA calls exports. 5.x still reads the @encode.
- **Keeps:**
  - The dyld override switch. OpenGLES is cached on every build.
  - The hypercall and the host bridge.
  - `amfi_allow_any_signature` for the injected framework.
  - Possibly the SpringBoard CA env. Whether stock CA picks GL once a working accelerated EAGL answers is untested.
- **Smoke #24** (surface pages) is unchanged. It is a host-side problem under every option except the full model.

The same seam serves the iPod: 3.x/4.x there also sit on a GLI engine (`MBXGLEngine`), and 1.x/2.x already use gles2x.

### 1.6 Ranking

Stability is how much of the seam's private surface changed across 3.2 → 4.2.1 → 4.3.5 → 5.1.1.
Scope is what parity on the four builds needs, then what each new point release needs.

| rank | option | class | seam stability (measured) | scope now | per point release |
|---|---|---|---|---|---|
| 1 | **Public-API OpenGLES + EAGL front end** (gles2x generalised) | P | public ABI fixed by apps; private part: 3.2→4.2 one struct field and one method; **4.2→4.3 zero**; 4.3→5.1 macro context and EXT exports | the six pieces of §1.5 | new EXT exports, generated |
| 2 | Self-discovering GLI shim (today's seam, hardened: gld/gfx tables read at load) | P | 4.2→4.3: 16 libGFXShared exports, 6 gld entries, 29 dispatch rows; 4.3→5.1: gld 3.1→4.0 (83→113) | 4.3's libGFXShared/gld/dispatch deltas | unbounded: a new contract with Apple's internal plugin ABI each release |
| 3 | Full SGX535 model running Apple's stack unchanged | **R** | the hardware: register set identical 4.3.5 = 5.1.1, near-identical from 3.2.2 (§2.3) | the six phases of §3; go/no-go on the USSE1 encoding | none expected |
| 4 | Microkernel HLE (register model, host implements the microkernel's command protocol) | H | the microkernel and its host interface are per-kext and change every release (§2.4), the same trap as the IOP HLE | option 3 without the microkernel, still with the shader ISA | per build |
| 5 | Kext user-client / command-buffer intercept | H | worst: the payload is SGX hardware commands built in user space by the gld plugin's USC compiler (USSE and PDS code); the ABI changed 3.2→4.2 (`IOGLStreamHardwareCommand`, `validateRenderCommand`) and 5.x moved the user clients to IOAcceleratorFamily (`IOAccelGLContext`, `IOAccelSharedUserClient`) | ≈ option 3 minus the microkernel | per build |

Options 4 and 5 are dominated: they cost most of option 3 and keep the fragility of option 2.
Option 5 is the "stable kernel boundary" idea, and it does not exist on this platform.

---

## 2. What is known about the SGX535

### 2.1 Public sources

| source | covers | complete? | licence |
|---|---|---|---|
| `sgx535defs.h` in the GPL/MIT "eurasia_km" kernel drops, e.g. https://github.com/CyanogenMod/android_kernel_samsung_exynos5410/blob/HEAD/drivers/gpu/pvr/services4/srvkm/hwdefs/sgx535defs.h (739 lines, 343 `EUR_CR_*`); TI trees https://github.com/rcn-ee/ti-omap5-sgx-ddk-linux , https://github.com/mvduin/omap5-sgx-ddk-linux | register map; SGX535 core rev 121 (Intel Poulsbo target) with errata for 121/126/HEAD | register names/offsets/fields: good. Behaviour: not documented | **Dual MIT/GPLv2** (usable in QEMU) |
| The same KM drops: `sgxmmu.h`, `sgx_mkif_km.h`, `sgxscript.h`, `sgxinit.c`, `sgxreset.c`, `sgxpower.c` | MMU (4 KiB pages, 10/10/12 split, PTE valid/WO/RO/CC/EDM bits, 16 directory lists), IMG's host↔microkernel interface, init scripts, reset, power | good for IMG's own driver. **Apple's kext is its own driver** (GraphicsDriversES) and its microkernel interface is Apple's build (§2.4) | Dual MIT/GPLv2 |
| Mainline Linux gma500 `psb_reg.h`, `mmu.c` | SGX535 (Poulsbo) `PSB_CR_*` subset, MMU page tables, BIF faults; no 3D submission | partial | GPL-2.0 |
| Letux openpvrsgx https://github.com/openpvrsgx-devgroup/linux_openpvrsgx | KM only, DDK 1.9-1.17 | KM only | GPL |
| SGX535-reMESA https://github.com/gabrieelgama/SGX535-reMESA (created 2026-09-16) | Poulsbo archaeology; its own status: registers confirmed, MMU/BIF partial, PDS reconstructed, **shader ISA unknown, microkernel unknown** | early | no licence file |
| sgx540-reversing https://codeberg.org/Garnet/sgx540-reversing | SGX540 USSE disassembly by driving IMG binaries, partial assembler | partial; different core | no licence |
| Vita3K `usse_disasm.cpp`, `grammar.yaml` https://github.com/Vita3K/Vita3K | the most complete open USSE decoder and translator, **for SGX543 (USSE2)**; USSE1 differs | structural reference only | GPL-2.0 |
| Imagination "Series 5 SGX Architecture Guide for Developers" (mirror in https://github.com/anonymousjustice/pvr-pi) | conceptual TBDR/USSE | no encodings, no registers | IMG "public" doc |
| Imagination forum, 2024-05-31 https://forums.imgtec.com/t/sgx545-core-programmer-documentation/3940 | "no plans currently to release any [SGX] documentation" | – | – |
| Mesa `src/imagination` https://docs.mesa3d.org/drivers/powervr.html | Rogue only; pre-Series6 "cannot be supported" | n/a | MIT |
| **Leaked DDK** (https://github.com/shaqfu786/GFX_Linux_DDK "LEAKED by LGE"; https://github.com/GrapheneCt/PVR_PSP2) | microkernel USSE source, useasm (USSE encoding), usc2 compiler | complete | **proprietary, all rights reserved. Must not be read by anyone working on this (taint).** |
| Register-level SGX or MBX emulation anywhere | – | **not found** | – |
| Imagination csim / public SGX simulator | – | **not found** | – |
| iLEmu https://github.com/MC-XiaoXiao/iLEmu | MBX HLE at the IOKit user-client level | not register level | MPL-2.0 |
| devos50 qemu-ios, FOSDEM 2024 slides | "Avoided GPU rendering with a flag" | no GPU | GPL |
| Dreamcast PowerVR2 (e.g. http://mc.pp.se/dc/pvr.html , KallistiOS `pvr_regs.h`; flycast and redream emulate it) | TBDR ancestor, TA/ISP/TSP concepts | good, but a different generation: no USSE, no MMU | various |

**Known:** the register map, the MMU format, and IMG's reference host driver.
**Unknown with no legitimate source:** the USSE1 encoding, the PDS encoding for this core, the TA/ISP/TSP
parameter formats, and timing and reset behaviour. The Apple A4's SGX core revision was not found in public sources.

### 2.2 Architecture in brief (as it matters for a model)

- A host-visible register file of 64 KiB at `0x85100000`: DT `sgx` node, `reg` 0x05100000/0x10000,
  interrupt 0x2f, clock/power gate 0x5d. Its compatible is `sgx,s5l8930x`/`sgx,s5l8920x`, the same on
  every build read. S5L8920 is the iPhone 3GS, so the model would also serve 3GS-class boards.
- A BIF (memory interface) with its own MMU. Page directories are selected per requestor through
  DIR_LIST_BASE*, and faults are reported in BIF_INT_STAT/BIF_FAULT.
- A microkernel: USSE programs running on the shader cores as the "EDM" task, started by PDS programs.
  It owns scheduling (TA kick, 3D kick, 2D/transfer, hardware recovery) and talks to the host through
  memory structures (CCBs) and event registers.
- TA (tiling accelerator) → parameter buffer → ISP (hidden-surface removal per tile) → TSP/USSE
  (texturing and shading) → pixel back end → ZLS (depth/stencil load and store).
- Everything programmable (vertex and fragment shaders, the microkernel, the PDS "data movement"
  programs) is USSE/PDS code. On iOS the gld plugin's USC compiler emits it in user space.
  `IMGSGX535GLDriver` carries IMG's `usc`/`emitpds` asserts, the "SA-update USSE code" and the
  `SGX520…SGX545` target table.

### 2.3 How iOS drives it: the register interface is the stable layer

The register-offset census covers loads and stores through the kext's register-base field, taken from
linear Thumb-2 disassembly of IMGSGX535 carved out of each kernelcache. The base field is 0x36c on
3.2.2, 0x364 on 4.2.1, 0x36c on 4.3.5 and 0x2b0 on 5.1.1. A heuristic census like this finds a lower
bound: accesses through computed offsets, such as the indexed DIR_LIST bases, are undercounted.

| | 3.2.2 (38.10) | 4.2.1 (48.20) | 4.3.5 (58.6) | 5.1.1 (63.24) |
|---|---|---|---|---|
| distinct offsets | 54 | 53 | 63 | 63 |
| written | 38 | 38 (+0x140, −0xc3c) | 36 | **36, identical to 4.3.5** |
| read | 16 | 15 | 30 (4.3 added the hang dump: ISP_STATUS, USE*_SERV_*, PDS_PC_BASE, 0x620-0x668) | **identical to 4.3.5** |

- **Written on every build:**
  - CLKGATECTL 0x000, SOFT_RESET 0x080, and EVENT_HOST_ENABLE2/CLEAR2 0x110/0x114.
  - EVENT_HOST_ENABLE/CLEAR 0x130/0x134, 0x13c, 0x630 and 0x804.
  - The USE/PDS code bases: 0xa00, 0xa0c = USE_CODE_BASE(0) and 0xa58-0xa80.
  - PDS_EXEC_BASE 0xaa0, EVENT_KICKER 0xaac, 0xab8/0xabc, EVENT_KICK 0xac8 and EVENT_TIMER 0xacc.
  - 0xb30.
  - BIF_CTRL 0xc00, BIF_TILE* 0xc10/0xc14, BIF_BANK_SET/BANK0/BANK1 0xc74-0xc7c, BIF_DIR_LIST_BASE0 0xc84 and BIF_MEM_ARB_CONFIG 0xca0.
- **Read on every build:** EVENT_STATUS 0x12c, EVENT_STATUS2 0x118, BIF_INT_STAT 0xc04, BIF_FAULT 0xc08,
  BIF_MEM_REQ_STAT 0xca8 and ZLS 0x480-0x490. CORE_ID 0x10 and REVISION 0x14 are read on 3.x/4.2.
- **Cross-check:** the kext's own hang dump names its registers with the same offsets as the public header.
  4.2.1 at 0x807f139c-0x807f1488 reads `[regs+0x12c]` for "EUR_CR_EVENT_STATUS", 0x118 for STATUS2,
  0xc04/0xc08/0xca8 for BIF_INT_STAT/FAULT/MEM_REQ_STAT, and so on. Those offsets match
  `sgx535defs.h` (0x12C, 0x118, 0xC04, 0xC08, 0xCA8, PDS_PC_BASE 0xB2C). **Apple's A4 SGX has IMG's register map.**
- **What 4.3 changed:** the kext became shared with the SGX543MP. It gained `EnableMPCores`, `chip-revision`
  and an `S5L8940XFPGA` string, and 5.x renamed the class `SGXDriver535`. The register set the 535 path
  touches did not grow.

So the hardware interface is, as expected, the stable layer. A register-level model written against
4.3.5 would face the same register set on 5.1.1.

### 2.4 The microkernel is part of each driver release, not of the hardware

The kext embeds its microkernel as USSE blobs in `__data`. It uploads them at start: 4.2.1
`0x807ee4d2-0x807ee5f6` allocates GPU memory and copies each blob, with flags 0x8000/2. Before uploading,
it **scans each blob, 8 bytes per instruction** (4.2.1 `0x807ed7e8-0x807ed8c6`), and refuses any USSE
store-to-register that targets:
- BIF_DIR_LIST_BASE0 (0xc84) or the other directory bases (0xc38-0xc70);
- BIF_CTRL (0xc00) with certain bits;
- the USE code bases (0xa0c-0xa4b).

Its message is "SGX Microkernel scan found %d str instructions, %d to register, %d to list base,
%d var to bif ctrl, %d to use code". In other words, Apple sandboxes its own microkernel against remapping the GPU MMU.

| build | microkernel-sized blobs (bytes) | small PDS-sized blobs |
|---|---|---|
| 3.2.2 | 0x6ac0, 0x47c0 | 0x68, 0xa4 |
| 4.2.1 | 0x4fa0, 0x4a30, 0x5420, 0x4120, 0x30a0 (~88 KB) | 0x4c, 0xb4 |
| 4.3.5 | 0x5810, 0x6178, 0x5178, 0x3778 (+1 at 0x808b52d4) | 0x38, 0x48, 0x38 |
| 5.1.1 | 0x5ac0, 0x5850, 0x6240, 0x52c0 (~90 KB) | 0x48, 0x38 |

Consequences:
1. A register-level model **executes whatever blob the kext uploads**, so per-release microkernel changes cost it nothing. This is the IOP decision again (memory `iop-second-core`): run Apple's firmware on a modelled core.
2. The microkernel HLE (option 4) would have to re-implement a host protocol that is Apple's build of IMG's `sgx_mkif` and changes with every blob. Rejected for the same reason the IOP v3 table was.
3. Apple's own scanner decodes the USSE store-to-register form, masks included. That is a small, legitimate foothold into the USSE1 encoding.
4. Other quirks the model must satisfy, from the kext's strings:
   - "Microkernel unresponsive", "Microkernel detected lockup" and "5 second render policy" (hang recovery).
   - "sgx ukernel didn't clear HWR state", "sgx: unexpected bif activity" (4.x+), "clearing BIF fault during reset: PD index %d, PT index %d", and "SGX timed out waiting for timestamp".
   - Nothing points to a dependence on a hardware bug beyond IMG's published errata for core revs 121/126. The kext reads `chip-revision` from 4.3 on. Which revision A4 reports is **unknown**, and the kext's comparisons have to be read for it in S2.

### 2.5 User-client and command-submission interface (for completeness)

- **3.2.2:**
  - The user-client classes are `IOSGX535GraphicsClient`, `IOSGX535GLContext`, `IOSGX535Shared` and `IOSGX535Device`, on the GLKernel `IOVendor*` base. The kernel walks the GL command stream (`processCommandBuffer`).
- **4.2.1 and 4.3.5:**
  - The same classes.
  - New validation of user-supplied hardware commands (`IOGLStreamHardwareCommand`, `validateRenderCommand`/`validateTransferCommand`, "found %d code buffers, expected one", "Vendor payload way too small").
  - The GART is the SGX page tables: `addDescToGART` and "bad pte bits on page".
- **5.1.1:**
  - The user clients moved to `IOAcceleratorFamily` (`IOAccelGLContext`, `IOAccelSharedUserClient`, `IOAccelCommandBuffer` …). The kext keeps `IMGSGXGLContext`, `IMGSGXTextureBuffer`, `IMGSGXTransferBuffer` and `IMGSGXSharedUserClient`.
- The selector-level method tables were not enumerated. Given §1.6 they are not on the recommended path.

---

## 3. Phased plan for the SGX535 model (research track)

Each phase is sized by what it builds, the unknown it hinges on and the gate that proves it, with the existing test
harness.

| phase | deliverable | gate | unknown | retires |
|---|---|---|---|---|
| **S1** Register file + MMU walker | `hw/arm/s5l8930_sgx.c`: 64 KiB register file with reset values, CORE_ID/REVISION, SOFT_RESET/CLKGATECTL semantics, EVENT_STATUS/HOST_ENABLE/CLEAR plus IRQ 0x2f, BIF with DIR_LIST_BASE*, BIF_CTRL, fault reporting, and a host page-table walker (public `sgxmmu.h` format) used by a QMP/debug dump; the `sgx` DT node kept stock and matched | the kext matches and starts on 3.2.2, 4.2.1, 4.3.5 and 5.1.1 without panic; microkernel blobs uploaded (the host logs the scan-approved blob addresses via the walker); page-table dump of the EDM directory is self-consistent | whether IOSurface creation alone populates the GART (see below) | the SGX part of the unimplemented window (K48 #60); **not** smoke #24, see below |
| **S2** Init to a waiting kernel | the kext's init path complete up to the first microkernel handshake: reset sequence, clock gating, EVENT_TIMER, kick registers latched; the `chip-revision`/core-revision checks read | the kext times out *only* on "Microkernel unresponsive" and not earlier, on all four builds | the reset/clock-gating order the kext checks | – |
| **S3** USSE1 + PDS interpreter, microkernel runs | a USSE1 interpreter (clean-room: Apple's blobs, the kext's scan masks, the public register map, Vita3K/sgx540-reversing as structural guides only) and a PDS interpreter; EDM task scheduling on events | the microkernel acknowledges init and the host kicks; no HWR in 10 min idle; stock GLEngine + IMGSGX535GLDriver create a context and `glClear` + present completes a (trivial) 3D kick | **the USSE1 and PDS encodings (undocumented; clean-room RE): the go/no-go** | – |
| **S4** TA + ISP (geometry, tiling, HSR, ZLS) | TA consuming the vertex-shader output into a parameter buffer, ISP depth/stencil per tile, ZLS load/store to the addresses the kext programs | SpringBoard composites with the stock stack (CA's GL path) on 4.2.1; `framecheck.py` within THR against the software-CA reference | the parameter-buffer and ZLS formats the kext programs | – |
| **S5** Fragment USSE + TSP + textures | fragment shading, texture sampling incl. PVRTC and the IMG twiddled layouts, blending, the pixel back end | Apple's apps (Settings, Safari, Maps, Photos) and a GL ES 1.1/2.0 test app on 3.2.2/4.2.1/4.3.5/5.1.1 pass framecheck; `gles-rejects` gone | PVRTC and the twiddled layouts; the TSP state words | **glishim, gldshim, the dyld override, the SpringBoard env, `gles-host.c` and the GL use of the cp15 hypercall** (K48 #55 and guest-side rows; #56 once nothing else uses it; `amfi_allow_any_signature` once nothing is injected) |
| **S6** Performance | USSE → host translation (Metal or GL compute/fragment), tile work on the host GPU, caching of translated programs by blob hash | SpringBoard at 60 Hz, games at playable rates on the dev Mac | how much of USSE1 maps onto host shaders; the reason S6 stays open-ended | – |
| **Order** | S1 and S2 need no ISA; S3 is the go/no-go; S4-S6 each need the phase before | | | |

Interpreter or translation:
- Start with an interpreter (S3-S5). It is the correctness oracle.
- Translate to host shaders in S6, only after framecheck pins the interpreter.
- A software rasteriser plus an interpreter will not hold 60 Hz at the iPad's resolution for games,
  though it may for SpringBoard. The cost of S6 is the reason the total stays open-ended.

**About S1 and smoke #24.** The ledger records the MMU as a separable first milestone that "retires smoke
#24's fault loop", because "the kext already builds those tables for every surface". Static reading does
not support that yet.
- The kext maps memory into the SGX page tables (`addDescToGART`) from its GL-context and texture paths
  (`IMGSGX_gl_context.cpp`: "Failed to add to GART").
- Those paths are driven by Apple's gld plugin through the user client. With our shim in place of
  GLEngine and gld, nothing asks the kext to map CA's surfaces.
- So the walker gives #24 its page lists only once Apple's stack runs on the kext, which is S3 and later.
- Until then #24 stays with the host-side IOSurface answer smoke.md already names. That answer is class H:
  read the IOSurface kernel object's physical segments by ID.
- To verify in S1: does IOSurface creation alone call into the SGX kext's GART?

### 3.1 MBX Lite (iPod touch 1G/2G) equivalent

- **No microkernel and no USSE.** MBX is fixed-function: TA, ISP and TSP with a 2D engine.
- The public GPL MBX kernel driver ported to the iPhone 2G/3G (https://github.com/fergy/iPhone_kernel_26/tree/HEAD/drivers/gpu/mbx)
  gives only the ID and interrupt registers (0x12c/0x130/0x134) and the S5L8900 slave ports. We already model those (ledger N72 #49).
- **The command formats are unknown:** `MBXGLEngine` in user space writes TA/3D state straight to the slave ports.
- **What carries over from an SGX model:** the TBDR pipeline skeleton (tiling, ISP HSR, ZLS, texture and
  blend back end, the host rasteriser, framecheck gates) and PVRTC decoding.
- **What doesn't carry over:** USSE, PDS, the microkernel and the BIF MMU (MBX's memory model is different).
- Roughly 30-40% of S4-S6 carries over. The MBX model still needs its own go/no-go: decoding the TA/3D state the
  MBXGLEngine writes to the slave ports (ledger N72 #49).
- The public-API seam (§1) covers the iPod's 3.x/4.x GLI layer for a fraction of that.

---

## 4. Risks

| risk | why | mitigation |
|---|---|---|
| USSE1 encoding (the biggest unknown) | no public spec for SGX535; USSE2 (Vita3K) differs; the only complete source is a leak | clean-room RE from Apple's own blobs and the gld plugin's output (compile known shaders in the guest on the stock stack, diff the code), the kext's scan masks, sgx540-reversing's method; budget S3 as the go/no-go |
| Legal/taint | the LGE-leaked DDK and PVR_PSP2 carry IMG "all rights reserved" sources | brief rule: no agent opens those repos or copies from them; cite only Dual MIT/GPLv2 KM headers (compatible with QEMU's GPLv2) and GPL-2 Vita3K; Apple's microkernel blobs run from the guest's own firmware and are never redistributed |
| Undocumented microcode behaviour | Apple's microkernel and its CCBs are private and differ per kext | execute them (R); never model the protocol (H) |
| Parameter buffer and ZLS formats | TA→ISP is internal to the hardware, but the kext sizes the parameter buffer (`SetParamBufferSize`, `TiledSceneBytes`) and programs ZLS bases, and the microkernel may touch region headers | keep TA/ISP private where the microkernel doesn't read it; trace which PB words the microkernel reads (S3 instrumentation) |
| Shader performance | interpreted USSE plus a software rasteriser | S6 translation; CA at 60 Hz may not need it, games will |
| Timing-dependent recovery | the 5-second render policy and HWR paths; a slow model may trip them | model EVENT_TIMER faithfully; watch recoveryCount (IORegistry `PerformanceStatistics`) as a gate metric |
| Core revision | A4's SGX revision is unknown; the errata paths the kext takes depend on it | read the kext's comparisons in S2; if possible, read `chip-revision` from the real iPad's IORegistry (Sam's device) |

### Test strategy

- **Oracle:** `tests/sessions/framecheck.py` references from the software-CA path. A correct frame
  scores 0.000-0.007 and a stale iPad surface 0.10 (THR 0.02). Frames from Sam's real iPad on the same
  build and screen would be the ideal oracle for S4/S5, and the same screens work for the seam work in §1.
- **Behaviour gates, not source shape** (memory `test-rigor-no-self-grading`):
  - kext-level: IORegistry `PerformanceStatistics` present, `recoveryCount` 0, no "Microkernel unresponsive" in 10 minutes;
  - GL-level: a guest test app with known output (GLTest.app exists) on ES 1.1 and 2.0, including PVRTC;
  - system-level: the regress gles legs and the matrix graphics column on all four builds.
- **Fail-when-reverted:**
  - Each phase adds a check that fails with the model's piece disabled. Examples: the MMU walker disabled
    must break the page-table dump; the interpreter stubbed must bring back "Microkernel unresponsive".
  - An independent auditor reviews S3 onwards.

---

## 5. Recommendation

1. **Now: the public-API seam (§1.5), its six pieces.**
   - Branch off `contrib/it-gles/gles2x.c`, and keep the mbxshim core and `gles-host.c`.
   - Gate on 7B500/8C148/8L1/9B206 with framecheck. Then retire glishim, gldshim and `gfx_gen.h`.
   - The ledger row stays P, but the row's "per point release" cost goes to about zero.
     That is what "4.3 silently lost GL" asked for.
2. **Research track: S1 (register file + MMU walker)** when the IOP/NAND core work frees a slot.
   - It is low-risk and moves the SGX window from S to a partial R.
   - It also answers the open S1 question (does IOSurface alone populate the GART?).
3. **Decide on S3 after a USSE1 spike.**
   - The spike: from the 4.2.1 and 5.1.1 blobs plus stock-compiled shaders, decode enough of the ISA
     to disassemble the microkernel's init path.
   - If the spike can't read the init path, park the full model. The seam from item 1 keeps GL working.

## Appendix: method

- **Kext:**
  - IMGSGX535 was carved from each prelinked kernelcache by its mach header (the `ipsw kernel kexts`
    addresses; `ipsw kernel extract` does not support pre-fileset caches).
  - It was disassembled linearly with capstone (Thumb-2), with literal-pool, `add rX, pc` and
    movw/movt resolution.
  - Register offsets were tallied from `ldr rA,[rB,#field]` followed within 7 instructions by `ldr/str [rA,#off]`,
    choosing the field whose offsets best match `sgx535defs.h`.
  - Blob addresses and sizes came from the `ldr r2,=blob; movw r3,#size; bl upload` pattern.
- **Userland:**
  - The rootfs were attached read-only. 8L1 was decrypted with the catalog key.
  - Old `dyld_v1` caches were parsed directly, because `ipsw dyld` can't parse them.
  - Imports were grouped by two-level-namespace library ordinal. Exports and `__objc_methname`/`__cstring`
    were read per image, and struct encodings were grepped from the whole cache.
- **Scratch:** everything lived in /tmp/sgx-study and was deleted afterwards. The scripts were throwaway;
  the pattern exists in `imgtools/ipad1_rootfs.py` (`cache_images`, `image_strings`) and `contrib/ipad1-gles/glitsv.py`.
- **Public-source survey:** web search, 2026-09-29. "Not found" means not found in about 40 searches and fetches.
