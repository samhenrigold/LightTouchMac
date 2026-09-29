# GPU strategy for iPhone OS 1.x and 2.x (2026-09-28/29)

## GPU on iPhone OS 1.x/2.x: findings and recommendation

The short answer: 2.x on the 2G already composites correctly in software today. GL for 2.x apps is feasible with a small front end, and a spike proved the host path works on 2.1.1. For 1.x, software compositing is the right first state. Hoisting MBX 2D at the library level is optional later work.

**Where the brief's premises were stale:**
- The `gl-runtime` worktree is gone. The branch is merged into `ipad1`; its tip is 4475e33f6e.
- `ipad1`'s `build/qemu-system-arm` (18:23) is older than gles-debug and the refusal counters. I ran a copy of `qemu-ios-gl-421-bugs/build/qemu-system-arm`, which has them.
- The "4 of 178 trampolines decode" result has a simple cause: there are no trampolines. The gl* exports on 1.x/2.x are the GL implementations themselves.

### 1. How 2.x composites today (5F138 on the 2G)

**Pure software, not silent MBX 2D blits.**
- QuartzCore 2.1.1 (`CADisplayH1Server::render_update` at 0x31db1a4c, `render_surface` at 0x31db1b1c) tries three renderers in order:
  - GL (`gles_context`, then `CARenderOGLRenderDisplay`);
  - MBX 2D (`mbx2d_context`, then `CARenderMBX2DRenderDisplay`);
  - otherwise the base `CADisplayServer::render_update` (0x31db5890).
- The constructor (0x31db1140) reads three environment settings:
  - `CA_ENABLE_MBX2D`/`LK_ENABLE_MBX2D`: defaults to on. **Stock 2.x composites with MBX 2D.**
  - `CA_ENABLE_OGL`: defaults to off.
  - `CA_AUTO_ENABLE_OGL`: defaults to on. It switches to GL only for updates flagged 0x200000 (GL content present).
- Our bake (`imgtools/bake-guest-tools.sh:96-98`) sets MBX2D=0, OGL=0 and AUTO=0, so every frame takes the software path.
- That software path is Apple's own GL-style layer renderer running on a CPU rasteriser (`sw_context`, `sw_sample_*`), so effects are full fidelity.
  - What it lacks: planar YUV. Its samplers cover BGRA/ARGB/XRGB/BGRX, 565/555, A8 and packed 2vuy/yuvs, but not 420v/y420.
  - Video layers in 420v/y420 are instead detached to a display hardware plane (`CADisplayH1::detachable_layer_p`). That is the LCD plane model's job, not the GPU's. I did not measure video.

**Measured** on a fresh 5F138 device (device.py plus the activation hook, idevicepair and idevicedate, unlock), counting guest presents with `IT_LCD_FRAMETRACE`:

| Action | Rate | Notes |
|---|---|---|
| Unlock | 29.5 fps | |
| Home-page swipe, left | 23–25 fps | one page, so it rubber-bands; 33 ms median gap, 100 ms max |
| Home-page swipe, right | 45–50 fps | 17 ms median gap |
| Slow drag | 22.8 fps | |
| Safari launch zoom | 24–30 fps | 1.5–1.9 s; one stall of 316–532 ms |
| Safari close zoom | 45.5 fps | |
| Safari bookmark-list scroll | 38 fps | |
| Idle | 0–2 fps | |

- Frames were correct: home screen, Edit Home Screen tip, Safari Bookmarks. `gles-rejects` was `{}`, and QEMU's CPU use was low.
- Nothing visibly broke. Web pages were not loaded (no Wi-Fi in that run).

**With MBX 2D enabled** (a scratch bake with `SPIKE_MBX2D=1`), 5F138 was still on the Apple logo after 3:42. Only 2 presents occurred, and MBX MMIO stopped after the driver's init (156 accesses ending with the mask 0x867c).
- The software build shows Connect to iTunes at 15–35 s.
- So MBX 2D work is not satisfied; it wedges. That matches the missing 0x400 2D-sync completion noted at `hw/arm/ipod_touch_mbx.c:109-116`.

### 2. GL for 2.x apps: ABI and spike

**Who needs GL.** No stock 2.1.1 binary links OpenGLES except QuartzCore; 2.2.1 adds MapKit (EAGLContext plus about 45 gl* calls). Everything else is App Store games and apps (2.0+), all of which use GLES 1.1 through EAGL.

**The ABI.**
- 2.x has no GLI plugin bundle. `OpenGLES.framework` is just `Info.plist` plus a 268 KB binary: the IMG PowerVR driver itself.
- It exports 178 gl* functions, 30 egl* functions, and 12 EAGLContext/EAGLSharegroup methods. The exported functions are implementations, not trampolines: `_glClear` at 0x3126c728 calls `OGL_GetTLSValue`, `SetError` and `FramebufferCheck`. It reaches the kernel through IOKit directly.
- Internally, `GLESGetEGLInterface` (0x31267368) returns a versioned, 18-entry table (`Create/DestroySharegroup`, `Create/DestroyGC`, `MakeCurrent`, `AttachDrawable`, `FlushBuffers`, `BindTexImage`, `BindCoreSurface`, `BindView`, `PresentView`…). These are the same `GLES*` functions mbxshim implements for 3.x, but here they are static.
- 5F138 and 5H11 have identical export sets and an identical interface layout. Symbols are unstripped.

**The third discovery strategy is trivial: the export names are the ABI.**
- 176 of 178 2.x exports (157 direct, 19 via the OES suffix) already have rows in `gles-names.h`.
- The two missing, `glTexImageCoreSurfaceAPPLE` and `glFinishTextureAPPLE`, map onto existing ops.
- 1.x (4B1) matches 153 of 156.
- No decoder and no table are needed.

**Spike: it passed.** It is committed on scratch branch `gpu2x-spike` at 195a897488 in the `qemu-ios-ipad1` repo; the worktree itself is removed and nothing is merged.
- `contrib/it-gles/gles2x.c` wraps `mbxshim.c` and exports one forwarder per `gles-names.h` row under the row's name (plus an OES alias), with one implicit context.
- It was built legacy-linked (`build-gles2x.sh`), delivered as an `n72-ios2` guest-package hook plus a one-shot job, and run by 2.1.1's `it_boot`.
- The probe created an FBO (status 0x8cd5), cleared it to (1, .5, .25, 1) and read back **0xff4080ff** with `glGetError` 0. The host logged `[gles] host GL up: 2.1 Metal`, and `gles-rejects` was `{}`.
- This proves: 2.x dyld loads a legacy dylib, name-keyed forwarding needs no discovery, and the host wire works unchanged from 2.x userland.

**What the spike did not prove:**
- **EAGL/CAEAGLLayer presentation.** No real app was tested.
- **Slide safety.** `mkold.py --legacy` drops `LC_DYLD_INFO_ONLY` and with it the dylib's rebases. It only checks the PIE flag and binds, so it accepted the dylib anyway. The spike relied on `-seg1addr 0x2f000000` and loading unslid.
- `glGetString(GL_RENDERER)` returned an empty string.

### 3. 1.x on the 1G (4B1)

**How LayerKit renders.** `LKPurpleServerStart` has the same defaults as 2.x: `LK_ENABLE_MBX2D` on, `LK_ENABLE_OGL` off, `LK_AUTO_ENABLE_OGL` on. `render_for_time` (around 0x30c32300) tries three renderers in order:
- GLES (`LKRenderGLESRenderDisplay`);
- MBX 2D (`LKRenderMBX2DRenderDisplay`);
- otherwise, **or when MBX 2D declines a frame**, `LKRenderBitmapRender`.

**What `LK_ENABLE_MBX2D=0` costs.** Every frame goes to the bitmap renderer, a small CoreGraphics scanline compositor (about 6 KB: `bitmap_render_layer`, `fetchRegion`). It checks `LKTransformIsAffine_`, so perspective layers take a different path. **Cover Flow in Music is the effect at risk**; in the MBX 2D renderer that is `blit_persp` / `mbx3DQuadCopyPerspective`. Not boot-verified. YUV video goes through Celestial's own `MBX2D` link, including `mbxYUV420Rotate90`.

**No third-party GL on 1.x.** OpenGLES 1.x exports 156 gl* and egl* functions but has no EAGL. Only LayerKit links it; there was no SDK (jailbreak toolchain apps aside).

**The MBX 2D command set CoreAnimation issues** is identical on 1.x LayerKit and 2.x QuartzCore (same import list; 2.1.1 call sites below):

| Kind | Operations |
|---|---|
| Draw | `mbx2DBlitColor` (fill: `blit_fill`, `mbx2d_fill_opaque`)<br>`mbx2DBlitCopy` (`blit_copy`, `blit_copy_simple`)<br>`mbx3DQuadColor` (`blit_fill_quad`)<br>`mbx3DQuadCopy` (`blit_quad`)<br>`mbx3DQuadCopyPerspective` (`blit_persp`) |
| State | blend equation (plus a "complex" variant), scissor, 90° rotation, scale factor, source/destination surface, enable/disable |
| Surfaces | create, release, remove-client, flush (three kinds), finish, swap notification |
| Formats | BGRA, ARGB, 565, 555, 4444, A8, 2vuy, 420v, y420 |

**Two ways to hoist it:**
- **At the API level: small.** Replace `MBX2D.framework` (about 40 exports) with a shim that forwards these five draw ops to host 2D blits over CoreSurface memory. Estimate: 5–8 days.
- **At the hardware level: not small.** The 2D-core packets are small (`pack2DCtxBlitCopy` does about 33 stores per command), but every quad goes through the MBX 3D TA stream (`mbx3DCtx*`, 2.8–3.5 KB packers). That is the 120–250-day undocumented MBX row.

### 4. Recommendations, in matrix order

**2.x on the 2G (in the catalog now)**

1. **Keep software compositing (0 days).** It is Apple's renderer with an env switch: class P, full visual fidelity, 24–50 fps measured. Log it in the ledger with its measured numbers and the planar-YUV/video-plane caveat, and measure video on the LCD plane path next.
2. **Build a 2.x GL front end for apps: about 4–6 days to a first game on screen, plus 2–3 days of compatibility work. Class P, same as the 3.x/4.x bridges.** It stays one shim per arch: the same `mbxshim` core and `gles-names.h` wire, with the `gles2x.c` export front end.
   - Replace `/System/Library/Frameworks/OpenGLES.framework/OpenGLES` through an `n72-ios2` hook.
   - Front ends to add: the 12 EAGL methods (`renderbufferStorage:fromDrawable:`, `presentRenderbuffer:`, `attachImage:toCoreSurface:invertedRender:`, `swapNotification:forTransaction:onLayer:`…) and the 11 egl calls QuartzCore makes, presenting CoreSurface BGRA buffers that the software compositor can already sample.
   - Export only the firmware's own names (read from the stock binary's symbol table at build or seed time) rather than OES aliases for every row.
   - **Prerequisite (about half a day):** extend `mkold.py --legacy` to turn rebase opcodes into classic local relocations for dylibs and bundles, and refuse any dylib whose rebases it would otherwise drop. Today it passes them silently.
   - Leave `CA_AUTO_ENABLE_OGL=0` unless an app is found that needs GL compositing.
3. **Optional, after that: the MBX 2D API shim** (the item-3 work), which also restores 2.x's stock MBX 2D compositor path. It is only worth doing if the matrix wants stock-path fidelity or Cover Flow-style perspective.

**1.x on the 1G (the 1G milestone)**

4. **Ship with software compositing via `LK_ENABLE_MBX2D=0`, as devos50 does (0 days, class P).** On the first 4B1 boot, test Cover Flow and a video. There is nothing to hoist for GL.
5. **If Cover Flow or video is visibly wrong:** do the MBX 2D API shim (5–8 days, class P; shared with item 3, so one piece of work covers both majors). Do not start a hardware MBX model; that is the 120–250-day row.

1.x/2.x on the 1G later reuse the 2G's 2.x decisions unchanged, since both run the same OpenGLES binary family and export set.

### Housekeeping

Only one emulator of mine ran at a time, always with `-audio driver=none`. `/tmp/gpu2x` is deleted: decrypted 5H11/4B1 rootfs, two scratch devices, disassemblies. Images are detached, and the spike worktree directory is removed; only branch `gpu2x-spike` remains. Nothing was committed or merged to `ipad1` or main.

In the `ipad1` checkout, `imgtools/device.py create` wrote nothing inside the repo. `git worktree add` created a local branch there.

Key files:
- `/Users/shg/Developer/qemu-ios-ipad1/imgtools/bake-guest-tools.sh`
- `/Users/shg/Developer/qemu-ios-ipad1/hw/arm/ipod_touch_mbx.c`
- `/Users/shg/Developer/qemu-ios-ipad1/contrib/it-gles/mbxshim.c`
- `/Users/shg/Developer/qemu-ios-ipad1/contrib/armv6-toolchain/mkold.py`
- `/Users/shg/Developer/qemu-ios-ipad1/contrib/guest-package/mkpkg.py`
- `/Users/shg/Developer/qemu-ios-ipad1/include/hw/arm/guest-services/gles-names.h`