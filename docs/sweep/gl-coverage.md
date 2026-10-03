# GL bridge coverage audit (2026-09-28)

# GL coverage: the class of bug behind the A008 popover shadow

Branch `gl-coverage` in `/Users/shg/Developer/qemu-ios-gl-coverage` (worktree off ipad1 5e4ab3e6bf), 6 commits, tree clean, `build/qemu-system-arm` built at the tip. Nothing touched in ~/Developer/qemu-ios or LightTouchMac; no main/ipod_touch_2g merges; no device identifiers in tracked files.

## Commits
- 5ab34bdbda GL bridge: count every refusal, paint it magenta under gles-debug, take the rest of what the firmwares produce
- 87c529f872 GL bridge: a guest page being faulted in is not a refusal
- 4f520566f0 tests/ipad1: a --gl-test device's gles leg is the fixture; its screens are not read for magenta
- 110c59f0aa tests/ipad1/app-compat: a missing sbicons falls back to the page-2 slot instead of crashing the pass
- f25c9520d4 tests/ipod: the newly forwarded fixed-point and fence slots, and the new texture types, against real CGL
- 4286c9dd36 GL bridge: take CoreAnimation's surfaces up to 4096 wide

## 1. Static audit: every reject / unsupported / unimplemented / fallback path
"before" = ipad1 tip behaviour; "now" = the counter name in the machine's `gles-rejects` property (+M = gles-debug paints magenta).

**Guest shim contrib/it-gles/mbxshim.c (iPod; #included by glishim.c)**
| path | trigger | before | now |
|---|---|---|---|
| gles_unimpl (default table) | 119 of the 267 slots 3.1.3 exports are stubbed: all ES2 slots, APPLE fences 463-470, OES_fixed_point *x 766-805, matrix palette 807-810, glMapBufferOES/glUnmapBufferOES/glGetBufferPointervOES 649-652, glGetBufferParameteriv 651, glIsBuffer 645, glDrawRangeElements 405, glBlendColor 337, queries 634-641, glGetTexImage/LevelParameter 123-125, glShaderBinary 819-821 | log once, return 0 | `shim:unimpl:<glName>` reported at 1,2,4,8... calls; 29 of them now forwarded (fences, *x) |
| gli_unimpl (MBXGLEngine-8C148 via gli_fwd.h) | 4.2.1 slots with no 3.1.3 equivalent: VAOs x4, glDiscardFramebufferEXT, glFramebufferParameteriAPPLE, glResolveMultisampleFramebufferAPPLE | log once, 0 | `shim:unimpl:<name>`; DiscardFramebuffer is inert (no-op = implementation) |
| texture_bytes()==0 | format/type the shim cannot size (no page pre-touch) | silent | table extended to the host's set |
| surface_capture REJECTED | CA drawable with implausible geometry (3.1.3 hands a non-IOSurface object) | log, panel fallback | `shim:drawable:<fourcc>` |
| GLESBindCoreSurface "rejected texture surface" | format not in {L565,L555,BGRA,RGBA,A008,420v,420f} or size > 2048 | log first 8, return 0 -> CA texture unloadable -> zero texture (opaque black): THE BUG | format and size no longer screened in the shim; forwarded, host judges/counts/paints. Only geometry the host could not read is refused locally: `shim:surface:<fourcc>` |
| GLESBindView no slot / drawable->bind failed / nextBuffer none | >4 GCs with drawables; CA refuses | log | `shim:view:no-slot`, `shim:ca:bind`, `shim:ca:nextbuffer` |
| GLESGetProperty / gliSetInteger defaults / gliGetInteger / gld STUBs (gldshim.c) | 4.x EAGL parameters; gld* entry points | decline by design; gldshim say()s to fd 2 only | unchanged (gldshim has no host channel; noted as remaining) |

**Host hw/arm/gles-host.c + guest-gles.c**
| path | trigger | before | now |
|---|---|---|---|
| gles_bind_surface format | FourCC not in {BGRA,RGBA,L565,L555,A008,420v,420f} | -1 (zero texture) | `surface:<fourcc>` +M; L008, 4444, 1555, ARGB, ABGR bind |
| gles_bind_surface target/size/read/nv12 | not 2D/RECT, no texture, w/h 0 or >2048 (now >4096), unreadable, NV12 odd, NV12 on EAGL | -1 silent | `surface:target:`, `surface:no-texture`, `surface:size:WxH`, `surface:read:<fourcc>`, `surface:nv12:odd-size` +M |
| gles_sync_surface_1 | rendering INTO a non BGRA/RGBA/L565/L555 surface | -1 silent | `surface:render:<fourcc>` |
| present_to_surface | bad base/size/stride/write; (new) format other than BGRA/RGBA/L565 (bpp was guessed 4) | log, -1 | `present:bad-surface`, `present:<fourcc>`, `present:size:`, `present:stride`, `present:write` |
| present_to_panel no fb; drawable_storage size/OOM | | log / GL error | `present-panel:no-framebuffer`, `drawable:size:`, `drawable:memory`, `drawable:storage:0x` |
| glTexImage2D/glTexSubImage2D texel table miss; cap | format/type pair unknown; >64 MiB | warn once, INVALID_ENUM, black/incomplete texture | `teximage:0xF/0xT`, `texsubimage:0xF/0xT`, `cap:*` +M; table extended |
| gles_texture_end | host GL refused an upload | error to guest | `upload-error:0xtarget:0xerr` |
| glCompressedTexImage2D unhandled; palette short/overrun; PVRTC target/level/size/replace; CompressedTexSub non-PVRTC/offset | | log once, -1 | `compressed:0x`, `palette:short:`, `palette:overrun:`, `pvrtc:*`, `compressed-sub:*` +M |
| glReadPixels | format/type unknown; cap | INVALID_ENUM | `readpixels:0xF/0xT`, `cap:glReadPixels` |
| gles_bind_array | pointer type/size desktop GL refuses (after GL_BYTE/FIXED widening); host refused; VBO overrun; unreadable | log once, array dropped | `pointer:<array>:size:0xtype`, `pointer-host:*`, `vbo-overrun:<array>`, `guest-read:array` +M |
| glDrawElements (ES1/ES2) | index type not UB/US (OES_element_index_uint, not advertised by these engines); overrun; unreadable | log/-1 or silent 0 (ES2) | `index-type:0x`, `vbo-overrun:index`, `guest-read:index` +M |
| ES2 attribute | gles_type_size==0 (e.g. HALF_FLOAT_OES) | silently unbound | `attrib:type:0x:size` +M |
| shader compile/link; glShaderBinary | GLSL 1.00 the 1.20 translation cannot take; always | log / -1 | `shader:compile`, `program:link`, `shader:binary` |
| gles_check_draw GL error; incomplete FBO draw; glCheckFramebufferStatus; matrix stack | | log once | `draw-error:0x` +M, `fb-incomplete:0x`, `fb-status:0x`, `matrix-stack:op` |
| glGet* unknown pname; GetLight/Material/TexEnv/TexParameter*v; glTexParameterf/fv/iv; glTexEnviv/fv; Light/Material/LightModel fv; glPixelStorei; glGetPointerv; glEnableClientState unknown array (matrix palette's); glClientActiveTexture unit>=8; point-size array type | | INVALID_ENUM / silent / clamp | `get:0x`, `get:<slot>:0xT/0xP`, `texparam:0xT/0xP`, `texenv:0xT/0xP`, `light:`, `material:`, `lightmodel:`, `pixelstore:`, `getpointer:`, `clientstate:0x`, `texunit:N`, `pointsize:type:` |
| glGen*/glDelete*/glGenFencesAPPLE cap; glBufferData/SubData unbound/cap/overrun/unreadable; fetch_params/texels/zeroed | | log, -1 | `cap:<call>`, `buffer:unbound:0x`, `buffer:overrun:`, `guest-read:<what>` |
| default UNHANDLED slot | any wire slot without a case (see §2 list) | log once, return 0 | `slot:N` (+M for 405 glDrawRangeElements) |
| strict glGetError after every call | any host GL error (unknown enums to glEnable/glTexParameteri/glBlendFunc/glRenderbufferStorage...) | log once per slot | `glerror:<slot>:0xerr` (catch-all; needs a look at the enum: it also catches app bugs the device rejects too) |
| gles_host_init failure; context ops; guest-gles.c bad slot/argc/spill/batch; page never faults in | | -1 / log | `host:no-context`, `context:op:`, `context:unknown`, `bad-call:*`, `guest-read:spill:`, `guest-read:fault-dropped` |
| glHint dropped; texcoord/depth-clear notes; GLESGetProperty | deliberate | unchanged | not refusals |
Every guest-memory site counts only when no page fault is pending (the bridge faults pages in and reissues the call; the first iPod run showed `present:write x255` for exactly that and was fixed in 87c529f872).

## 2. What the firmwares can produce (scan of the dyld caches' QuartzCore, CoreSurface, IOSurface, UIKit, ImageIO, IOMobileFramebuffer, OpenGLES, CoreVideo, MediaToolbox, CoreGraphics, WebCore and the engine bundles MBXGLEngine 5F138/7E18/8C148, GLEngine+IMGSGX535GLDriver 7B500/8C148: literal-pool words, Thumb movw/movt pairs, instruction immediates via capstone, strings; scanner kept at /tmp/glcov/scan.py, results summarised in /tmp/glcov/audit.md)

Surface FourCCs named (all five builds unless noted): BGRA (QuartzCore x13-16), L565, L555, RGBA, **4444** (QuartzCore x8-9 on iPod builds, IOSurface, OpenGLES), **1555**, **ABGR**, **ARGB** (QuartzCore); 420v/420f (video); A008 appears as no literal anywhere (assembled at runtime; measured on 7B500/8C148). Marked bold = produced but REFUSED at ipad1 tip -> now bind. L008 (A008's sibling) added too.
Engine/driver GL enums: format/type pairs beyond the four the bridge took: BGRA+4444_REV/1555_REV (IMG/EXT_read_format, every build), RGBA|BGRA+8_8_8_8, FLOAT/HALF_FLOAT (8C148 iPad OES_texture_float/half_float), DEPTH_COMPONENT+USHORT/UINT (8C148 iPad OES_depth_texture) -> all now accepted. YCBCR_422_APPLE/RGB_422_APPLE (7B500/8C148 SGX) -> still counted (desktop has the same tokens; unverified on the "2.1 Metal" driver, so not enabled). Texture params: MAX_ANISOTROPY 0x84FE (MBXGLEngine x11; QuartzCore calls glTexParameterf(GL_TEXTURE_2D, 0x84FE, 8.0) on every layer texture on 7B500/8C148: was INVALID_ENUM on every boot), MAX_LEVEL, LOD bias via 0x8500/0x8501, point-sprite texenv 0x8861/0x8862 -> accepted. Queries MAX_TEXTURE_MAX_ANISOTROPY/LOD_BIAS/MAX_SAMPLES_APPLE/cube-map -> accepted. Renderbuffer formats (RGB565, RGBA4, RGB5_A1, RGB8, RGBA8, DEPTH16/24, DEPTH24_STENCIL8, STENCIL8) already passed through; the drawable FBO now carries DEPTH24_STENCIL8 so a stencil attachment to it is real (OES_packed_depth_stencil/OES_stencil8 are on every device).
Extension names each engine carries (the capability set apps assume): 7E18/5F138 MBX: OES {blend_subtract, compressed_paletted_texture, depth24, draw_texture, framebuffer_object, mapbuffer, matrix_palette, point_size_array, point_sprite, read_format, rgb8_rgba8, texture_mirrored_repeat}, IMG {read_format, texture_compression_pvrtc, texture_format_BGRA8888}, EXT {texture_filter_anisotropic, texture_lod_bias}, APPLE {client_storage, core_surface_texture, texture_rectangle}. 8C148 MBX adds APPLE_framebuffer_multisample, APPLE_texture_format_BGRA8888, APPLE_texture_max_level, EXT_discard_framebuffer, EXT_read_format_bgra, OES_vertex_array_object. 7B500 SGX adds OES_blend_equation/func_separate, fbo_render_mipmap, packed_depth_stencil, standard_derivatives, stencil8, APPLE_texture_2D_limited_npot, APPLE_rgb_422, EXT_blend_minmax. 8C148 SGX adds OES_depth_texture, OES_stencil_wrap, OES_texture_float/half_float, OES_vertex_array_object, EXT_shader_texture_lod, EXT_discard_framebuffer, EXT_read_format_bgra, APPLE_framebuffer_multisample, APPLE_texture_max_level.

**Pre-emptive list — produced/advertised but refused or degraded at ipad1 tip:**
Fixed here (desktop-direct, unit-tested): surfaces 4444/1555/ARGB/ABGR/L008; CA surfaces wider than 2048 (Exit Strategy's 2240x416 layer, found by the counters in app-compat; now up to 4096); anisotropy/max-level texparams; the REV/8_8_8_8/float/half/depth texture types; LOD-bias and point-sprite texenv targets; the six extension glGet pnames; drawable stencil; 21 OES_fixed_point setters/getters and 8 APPLE_fence slots forwarded; glDiscardFramebufferEXT inert.
Still refused, now counted (real work): OES_mapbuffer (needs guest-side shadow buffers in the shim + glBufferSubData on unmap); OES_vertex_array_object (8C148 both; per-VAO copies of the emulated array state); APPLE_framebuffer_multisample (8C148 both; read/draw framebuffer bindings + glBlitFramebufferEXT on resolve, plus new wire slots for entry points with no 3.1.3 number); OES_matrix_palette (all; skinning emulation); APPLE_ycbcr_422/rgb_422 uploads (passthrough candidates, unverified); ETC1/S3TC, OES_element_index_uint (not advertised, counted); glGetFixedv/glGetTexImage/queries/glGetBufferParameteriv/glIsBuffer (mostly not exported by OpenGLES); gldshim STUBs (fd 2 only); NV12 surfaces on the EAGL host build.

## 3. Loud and countable (what shipped)
- Host: `gles_refuse()` at every site above; `gles_host_rejects()` -> QOM string property `gles-rejects` ("NAME\tCOUNT\n" per name, sorted) on both `iPod-Touch` and `ipad1`; the guest shims report their own refusals through the existing GLES_OP_LOG channel as `[gles-reject] shim:NAME N` at 1, 2, 4, 8... calls (the host keeps the max), so the wire ABI is unchanged. `itqmp.gles_rejects(q)` reads it.
- Sam's addition: machine property `gles-debug` (bool, default off, both machines): a refused texture upload or surface bind leaves the bound texture a magenta 1x1 (`gles_debug_texture`), a refused draw paints the viewport magenta (`gles_debug_mark`); tests pass `gles-debug=on`, `itqmp.magenta_fraction()` reads screens.
- tests/ipod/regress.py: the gles leg fails on any counter. tests/ipad1/regress.py: `boot`, new `gles` (unlock, home, page swipe, Safari; on a --gl-test device gltest.py's fixture instead) and `shadow` all fail on any counter or on >0.1% magenta (`gl_clean`); `gles` is in the default tier now. tests/ipad1/gltest.py reports `rejects`. app-compat.py records `rejects` + `magenta` per app and results.md lists refusals by name ("the fix list") and by app.
- Unit tests (14/14 pass): new test_gles_rejects.py (counters, once-log, shim line parsing, fourcc, format tables, magenta paint, one real CGL upload per new texture type), new test_gles_fixed.py (fixed-point setters/getters both ways, enum passthrough, fences), test_gles_surface.py (+6 formats, an unknown one counted); gles_harness carries the refusal block; cubemap/drawable/drawable_storage/fixture tests adjusted.

## 4. Runs (gles-debug on, one emulator at a time, fresh devices from stock IPSW + manifest with this tree's shims/guest package)
- iPod 7E18 (nand-agent-v4 + --stage-gles-shim): boot PASS, gles PASS (GLTest scene), counters empty.
- iPad 7B500 (manifests/ipad1-7B500.json, lt-activation): boot PASS, gles PASS (lock, home, page 2, Safari), shadow PASS 255/186 — all "GL bridge refused nothing"; fixture device: gltest.py PASS (readback PASS, 293 fps, rejects {}).
- iPad 8C148 (manifests/ipad1-8C148.json): boot PASS, gles PASS, shadow PASS 255/186 — nothing refused (4.2.1 GL CA through GLEngine-8C148 + gldshim).
- app-compat on 7B500, 42 of 51 unique bundles (stopped at the coordinator's request; ~3 min/app): LAUNCH 37, CRASH 4 (Doodle Jump/kbtester/Magneto missing iOS 4 symbols, FigCam unrecognized selector — none GL), INSTALL-FAIL 1 (MissingBundleIdentifier). Non-zero counters, per app: **Cube Runner** `glerror:72:0x500 x1` = glEnable(GL_ALPHA), an app bug the MBX also rejects (not a gap); **Exit Strategy** `shim:surface:BGRA x1` = a 2240x416 layer surface refused on size, tutorial panel black -> fixed in 4286c9dd36 (rerun of that app NOT done). All other 40 apps: no counters, no magenta. Summary table: /tmp/glcov/app-compat-7B500/results.md.
- iPod 8C148: the existing 4.2.1 iPod devices bake the STOCK engine (made before gli-dispatch-8C148.tsv existed; their lock says so), so a fresh device from manifests/ipod2g-8C148.json was prepared (needs build/ipod-guest it_prefs + it_keybag, built) but its seal boot and boot+gles leg were NOT run — unverified. 5F138 has no manifest/device runs (scanned only).
Unverified after the last commit: the 4096 surface cap on hardware paths (unit-tested; the rebuilt shim/package are built but no device was re-created); the 9 untested app-compat apps.

## Notes for gl-runtime
- Test devices: kept `~/Developer/qemu-ios-files/ipad1/repro/glcov-7B500-ui/device` (1.4 GB, plain, activated, this tree's GLEngine, the app-compat device). Deleted the fixture and 8C148 devices; recreate one (or `--id k48ap-8C148`) with `firmwarekit create --catalog LightTouchMac/Resources/firmware-catalog.json --id k48ap-7B500 --ipsw IPSW --out OUT/device --helper LIGHTTOUCHDEVICE [--gl-test]` (LIGHTTOUCHDEVICE: the LightTouchDevice executable). A --gl-test device's fixture covers SpringBoard's screens: use it for gltest.py only.
- Untracked build inputs made here: contrib/it-gles/MBXGLEngine-{7E18,8C148}, contrib/ipad1-gles/GLEngine-{7B500,8C148} + GLRendererFloatQEMU.bundle, contrib/it-agent/it_agent, build/{appsync,ipad1-guest,ipod-guest,guest-package,ipad1-tools/sbicons}.
- Scratch cleaned (overlays, run dirs, mounts detached); /tmp/glcov keeps only audit.md, scan.py, slots.py, results.md (80 KB). Free space: 415 GiB.
