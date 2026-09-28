# Emulator follow-up: restore running graphics state

**User impact:** saving a running device with accelerated graphics cannot reliably resume it. A visible Save State command suggests a working snapshot feature that the backend does not support. The UX pass removes Save State Now and Discard Saved State from the menus; normal shutdown and persistent guest storage remain available.

**Evidence:** `../qemu-ios/hw/arm/gles-host.c`, `gles_begin_context` / `gles_end_context` (around lines 450–470), installs a migration blocker while a host OpenGL ES context is live. This is a source-confirmed backend limitation, not a new runtime reproduction.

**Backend work:** serialize guest-visible GL objects and context state, recreate host resources during load, restore bindings and drawable contents, and remove the migration blocker only once restoration is supported. Include textures, buffers, shaders, programs, framebuffer/renderbuffer attachments, and outstanding commands.

**Acceptance:** save and restore SpringBoard and a GL game; verify rendered contents, touch input, rotation, audio continuity, and subsequent resource creation/deletion. Repeat after backgrounding the guest app and after display rotation. Failed saves must leave the last valid state intact.

## Fixed: Settings and Contacts skip their launch animation

The September 19 regression was reproduced in the emulator library used by a normal Xcode build, using a copy of the affected writable NAND with networking enabled. BTServer repeatedly rejected replies (`ACL/SCO DATA?!?!?`), restarted, and left `BluetoothManager.sharedInstance` returning nil after approximately one second. Those synchronous Bluetooth calls stall SpringBoard during app transitions. Verbose DMA tracing changes the timing enough to hide the failure.

The fix is in the sibling `qemu-ios` checkout, in `hw/char/exynos4210_uart.c` and `hw/arm/ipod_touch_2g.c`. The S5L UART interrupt map had transmit at `0x08` (actually receive timeout) and receive at `0x100` (actually automatic baud measurement). This cleared genuine receive timeouts and dispatched incoming data to the wrong guest handler. The corrected mapping uses receive `0x10`, transmit `0x20`, timeout `0x08`, and error `0x40`, honoring their individual UCON enables and write-one-to-clear acknowledgments.

The UART no longer invents a DMA terminal count for a short reply. The guest uses a controller-counted 2,048-byte DMA descriptor and handles partial buffers through the UART timeout interrupt. Premature descriptor advancement made unfilled bytes look like Bluetooth packet data. No NAND patch or reset is needed.

Verification on three independent quiet cold boots of cloned device data:

| Boot | BluetoothManager attachment | Settings changed frames | Contacts changed frames | BTServer restarts / malformed replies |
| --- | ---: | ---: | ---: | --- |
| 1 | 13.3 ms | 48 | 17 | None |
| 2 | 11.7 ms | 35 | 17 | None |
| 3 | 13.2 ms | 36 | 17 | None |

Guest LCD frames were sampled at 60 Hz and visually inspected: both apps have intermediate scaled launch surfaces, rather than jumping to a full-screen app. Frame counts include subsequent content changes and are not frame-rate measurements. The default Xcode development library at `../qemu-ios/build-native14/qemu-build/libqemu-arm.dylib` was rebuilt from the corrected source.

The emulator regression checks now exercise the production interrupt handler, rather than stubbing it. `tests/ipod/check-bluetooth-stack.py` and `bluetooth-stack-probe.c` also provide a quiet guest-side readiness check; firmware-download traces alone are insufficient acceptance evidence.

## Fixed: Diner Dash Classic display geometry and rotated scanout

The September 20 reproduction installs the Store entry “Diner Dash Classic” as **Diner Dash Lite 1.0** (`com.playfirst.dinerdashlite`). On launch, the device rotates to landscape, but the game's opening card is compressed into the bottom two thirds of the LCD, with content cropped at the right. This is visible inside the LCD, independently of the Mac canvas framing.

The guest log showed the same CoreAnimation drawable binding twice: the first bind succeeded with a 320 × 480 surface, and the second returned zero. `-[PlaygroundView_cocoatouch layoutSubviews]` in the game's executable destroys and recreates its framebuffers. The shim retained the first surface after the rejected second bind.

The original iOS 3.1.3 (7E18, armv6) MBX engine provides the missing lifecycle contract: `GLESBindView` calls `_DetachTexture` at `0xd7dc` before calling the drawable's bind callback. `_DetachTexture` presents an outstanding acquired buffer at `0x1bed0`, calls the drawable's unbind callback at `0x1bee4`, and clears its drawable and surface bookkeeping. A null drawable is a successful detach. The emulator shim previously omitted this detach and described unbind as valid only after failure.

The sibling `qemu-ios/contrib/it-gles/mbxshim.c` now follows that contract on rebinding and context destruction. It preserves the callback identity through unbind, then clears the released surface metadata. Other graphics contexts retain their own drawables. `tests/ipod/test_gles_drawable.py` exercises this with a callback fixture that refuses a duplicate live binding; it fails the old implementation on the second bind and passes the correction. The existing IOSurface import and framebuffer writeback regression also passes.

A second, independently reproduced backend defect affected any accepted landscape layer. The host allocated and reported a fixed 320 × 480 drawable, then copied only `min(width, 320)` columns on presentation. A native test using a 480 × 320 drawable proves both failures: the old size query returns 320, and the old writeback leaves the rightmost 160 columns untouched. The original game cannot be considered visually fixed from this native test alone.

The host now receives the accepted layer dimensions through a new engine operation before the app queries or draws. It allocates color, depth, and readback storage together, publishes only a complete replacement, preserves GL bindings and viewport, reports the accepted dimensions, and writes the complete surface. Invalid sizes are rejected, failed allocation retains prior storage, and offscreen renderbuffers still report their own dimensions. The frozen request layout and existing operation numbers are unchanged; old shims retain the 320 × 480 default, and mismatched landscape presentation is rejected instead of cropped. The corrected behavior requires both the rebuilt host library and the rebuilt shim, which normal startup installs. `tests/ipod/test_gles_drawable_storage.py` covers portrait, landscape, and odd-sized layers, three pixel formats, row padding, right/top edge colors, offscreen queries, GL state preservation, and size validation under AddressSanitizer and UndefinedBehaviorSanitizer. The surface, context, object, frame-clear, and parameter regression tests also pass.

The next live run exposed a third defect: the layer now rendered correctly, but the LCD showed vertical stripes. A dump of the game’s 426 × 320 GL output was intact, while the visible panel was corrupted. Reading the live display registers identified direct RGB0 scanout, bypassing CoreAnimation’s GL compositor:

| Register | Value | Meaning |
| --- | --- | --- |
| `0x38900004` | `0x00000010` | RGB plane 0 only |
| `0x38900020` | `0x00e00700` | BGRA, rotation mode 3 |
| `0x38900028` | `0x000001b0` | 432 pixels per source row (1,728 bytes) |
| `0x38900030` | `0x01aa0140` | 426 × 320 source pixels |
| `0x38900034` | `0x0000001b` | Destination origin (0, 27) |

The LCD backend only selected its plane compositor when video or RGB1 was enabled. RGB0 alone always used a tightly packed 320 × 480 copy, ignoring the guest’s row stride, geometry, position, and rotation. The existing RGB compositor also rejected any rotation. The running 7E18 driver independently confirms the source stride is expressed in pixels: `0xc05e7e38` divides BGRA bytes-per-row by four, then `0xc05e7e88` writes it to LCD offset `0x28`.

`../qemu-ios/hw/arm/ipod_touch_lcd.c` now composes nonstandard RGB0 scanout using the programmed geometry, padded rows, destination position, and the validated quarter-turn mode 3. It preserves the dirty-tracked fast path for ordinary 320 × 480 portrait scanout, validates dimensions and RAM ranges before DMA, and rejects unsupported format/rotation modes. This is a general LCD hardware correction; the renderer has no game-specific scale or crop.

`tests/ipod/test_lcd_planes.py` adds the exact recorded registers with unique X/Y pixel channels, checks every output pixel including the 27-pixel borders, and exercises padding, clipping, malformed formats, unsupported transforms, overflow, and fast-path selection under ASan/UBSan. The original scanout selection fails the fixture; independently selecting RGB0 on the old compositor also fails. The corrected plane and existing interrupt tests pass.

**Live verification completed September 20:** the corrected library shows the complete upright Diner opening card and playable tutorial. A normal touch drag seats the first customers and advances to “Touch the table to pick up their order.” Returning Home restores a correctly rendered portrait SpringBoard; opening Settings renders correctly too. See [before](screenshots/diner-dash-before.png), [gameplay after correction](screenshots/diner-dash-after.png), and [Settings after returning Home](screenshots/diner-dash-settings-after.png).

**Diagnostic caveat:** the older `IT_GLES_DUMP_DIR` files named `panel-*.ppm` read raw scanout memory as tightly packed portrait pixels. They bypass the LCD plane compositor and remain striped for valid rotated direct scanout, even when the visible display is correct. The acceptance images above come from QMP `screendump` (the composed display) and were also checked in the running Mac app. Temporary QMP enablement and graphics tracing were removed from the normal app run.

The development host library and guest shim were rebuilt. The host library was linked to a separate staging file, signed, checked for an unchanged exported ABI and dependency closure, then atomically published. The running process's previous inode and SHA-256 were preserved through a separate hard link. The staging audit also found an existing `_pipe2` weak import in native14's static GLib: the original and replacement libraries have the same import, and the existing GLib configuration defines `HAVE_PIPE2`. Therefore the strict “no weak imports” release check remains failing for this pre-existing build dependency; the drawable patch introduces no new weak imports.

## Fixed: notification watcher mistakes service loss and install contention for each other

The September 20 transport audit found a host-side lifecycle error in `GuestNotifications.swift`. The libimobiledevice notification callback uses an empty notification string to report a lost service and then exits its reader thread. This contract is documented in `include/libimobiledevice/notification_proxy.h` and implemented in `src/notification_proxy.c` in the bundled 1.4.0 source. The app ignored that string and treated every callback as an app-list change. Its separate five-second USB-attachment probe could keep a dead notification session open indefinitely because USB attachment survives a notification-service failure. Conversely, a healthy session was torn down when an installation held the device gate longer than that probe's ten-second queue deadline.

The watcher now waits for the service's own disconnect event, preserves established subscriptions through installs and transfers, and defers new handshakes while an operation or recovery is active. Eligibility is checked again after acquiring the service gate. Failed observe requests no longer produce a silently unusable subscription. Closing the C client runs off the main actor with a bounded wait, while the retained callback context remains alive until its reader has actually joined; late connects and cancellation retain the same single-owner cleanup guarantee.

`tests/check-guest-notifications.py` compiles the production watcher, deadline, and gate code against a controlled C-service fixture. It verifies app-change delivery, disconnect without a false app-change event, reconnect after active work ends, no healthy-session teardown during a long install, eligibility changes while queued for the gate, failed subscriptions, cancellation, a blocked C join, and a connect that returns after cancellation. This is a source- and fixture-confirmed correction; it does not identify the original cause of every previous “Device not responding” report.

The preserved app log at `/tmp/ltm-device-failure-20260920/app.log` shows alternating list-app and notification-attach timeouts at 00:39–00:44 UTC, consistent with extra attempts during a service failure. Those entries lack individual service error codes and cannot establish the initial failure. Later usbmux activity at 17:19 local time shows requests, complete replies, and individual service resets, rather than a silent USB bridge. The service factory closes its temporary lockdown connection immediately after starting the notification service (`src/service.c`); the lasting subscription itself does not occupy a lockdown session. The new health diagnostics must distinguish attachment, individual service failure, and active operations rather than infer a device-wide outage from any one of them.

That audit also confirmed that libimobiledevice's convenience installation-service factory discards handshake and start-service errors: its caller initializes the result to installation_proxy `-256`, and the factory returns early without replacing it when lockdown fails. `IMobileDevice.startInstallationProxy(device:)` now performs the same handshake, service start, and client construction explicitly. It preserves exact lockdown errors, closes lockdown before opening the installation socket, and frees descriptors and partial handles on failure. App listing, installation, removal, and the installation-readiness check use this helper. `tests/check-install-service-connection.py` loads the complete production Swift bridge against a compiled C fixture and verifies error domains/codes, call order, partial and null handles, missing symbols, and client ownership on success.

Installation startup also lacked a deadline: `install` awaited an uncancellable detached task, while the existing idle watchdog only began after device discovery and service connection. A blocked startup could therefore retain the process-wide device gate indefinitely, preventing queued app operations and health checks. Startup now has its own ten-second deadline, separate from the mutation watchdog. A timed-out or cancelled startup releases the gate; late handles are closed without submitting an installation. Cancellation between a successful connection and mutation closes both handles exactly once. Once the mutation begins, the original idle/absolute watchdog continues to own it until completion, and its callback context is released only after the C reader joins. `tests/check-install-startup.py` deterministically exercises blocked device and service setup, timeout and cancellation, both handle-handoff races, gate reuse, terminal and immediate failure callbacks, and single-slot abandonment accounting without a live guest.
