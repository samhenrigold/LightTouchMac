# Existing components that could reduce Light Touch's footprint

Research date: 2026-09-30. Companion to [the holistic review](holistic-review-2026-09-30.md).
This is a source/documentation survey, not an integration or compatibility result.
Local references below refer to the audit candidates described in that review.

## Conclusion

We have not reached the reasonable minimum of custom code. The best reductions
come from transferring responsibilities to stock guest software and existing
QEMU infrastructure. Adding dependencies without deleting an owned responsibility
does not constitute simplification.

No project examined is a demonstrated drop-in replacement for our ARMv6/A4
hardware models, real boot chain, persistent flash, and full stock iOS environment.
Some SoC-specific work is intrinsic to the ambition. The GUI and device services
should not acquire their own filesystem, restore, shell, or database implementations.

## Candidates, ranked by practical value

### 1. Stock restore through idevicerestore: largest architectural reduction

[idevicerestore](https://github.com/libimobiledevice/idevicerestore) already
implements the host-side IPSW restore workflow, including erase/update and
DFU/recovery transitions. It and its dependencies are already part of our work;
this is a proposal to use more of that stack, not a newly discovered dependency.

With sufficiently faithful USB, flash, and crypto models, Apple's restore guest
can own partitioning, filesystem creation, flash translation, and filesystem
policy. That could eventually retire substantial portions of synthetic image
construction. It will not remove hardware emulation or automatic activation and
guest-addition provisioning by itself.

Gate: start with blank flash, complete restore, cold boot the resulting device,
change content, reboot, and verify persistence. A successful restore transaction
alone does not establish that all generated-image paths can be deleted.

### 2. Upstream QEMU flash/block infrastructure: reuse already in the tree

The audit QEMU checkout already contains `hw/block/nand.c`. Its `mem_and`
implements NAND programming as bit clearing; it uses `BlockBackend`, models
page/spare data, and reports backend access failures. Our iPad flash path instead
has custom mapped persistence and currently allows programming with `memcpy`.

Use this implementation as the starting point for a common physical-flash
backend, adapting geometry, commands, erased-state representation, and error
behavior to the actual chips. Keep Apple controller MMIO/DMA/IRQ behavior in
the controller models and guest FTL behavior in the guest. The generic NAND
model is not a drop-in Apple controller replacement.

[QEMU's block layer](https://www.qemu.org/docs/master/system/images.html) already
provides backing images and copy-on-write facilities. Evaluate those before
inventing another snapshot/storage format. Sparse zeroes must not silently mean
erased NAND, and crash consistency must be defined across flash and RAM state.

### 3. Imagination's PVRTC decoder: a bounded new substitution

Our `hw/arm/gles-host.c:1924` onward contains a custom PVRTC decoder, with
format, interpolation, modulation, and twiddle logic. Imagination publishes
[PVRTDecompress.cpp](https://github.com/powervr-graphics/Native_SDK/blob/master/framework/PVRCore/texture/PVRTDecompress.cpp)
in its [MIT-licensed SDK](https://github.com/powervr-graphics/Native_SDK/blob/master/LICENSE.md).
[touchHLE](https://github.com/touchHLE/touchHLE) identifies this decoder among its dependencies.

Evaluate vendoring just the necessary decoder and a narrow C wrapper, rather
than the entire SDK. This transfers ownership of a texture algorithm to its
vendor; it does not replace upload validation, guest memory access, texture
bookkeeping, or our compact/small mip compatibility behavior.

Gate: differential output on valid 2/4-bpp RGB/RGBA textures, rectangular atlases,
small mip levels, and modulation modes; reject truncated input before invoking
the decoder. Preserve independently obtained expected output. This is a stronger
immediate footprint candidate than a wholesale rendering rewrite.

### 4. Existing guest services, mounts, SSH and debugging

[libimobiledevice](https://github.com/libimobiledevice/libimobiledevice), already
used here, supplies clients for stock services. Prefer these for installation,
file access and backup rather than expanding the custom guest agent.
[ifuse](https://github.com/libimobiledevice/ifuse) offers an AFC filesystem mount;
root access requires an added root AFC service, and it is not native Finder
device discovery or media sync.

[OpenSSH](https://github.com/openssh/openssh-portable), SFTP and
[SSHFS](https://github.com/libfuse/sshfs) can provide developer terminal/root
file access. Legacy guest binaries and modern host-client interoperability need
actual testing. Keep the stopped editable volume workflow on the stock macOS
HFS driver. Neither a FUSE mount nor SFTP solves raw NAND decoding and ownership.

Use [QEMU's GDB stub](https://www.qemu.org/docs/master/system/gdb.html) for
ROM/kernel debugging. A compatible guest debugserver is a separate userspace
debugging capability. Do not build another debugger protocol.

### 5. Existing QEMU test infrastructure

[qtest/libqos](https://www.qemu.org/docs/master/devel/testing/qtest.html) already
supports MMIO, IRQ inspection and virtual-clock stepping. Use it for model tests
instead of creating another device-test harness or relying solely on extracted
source functions. Our behavioral expectations and boot matrix remain custom.
[Record/replay](https://www.qemu.org/docs/master/system/replay.html) is worth a
bounded feasibility test, but custom graphics and asynchronous services must
participate before we claim deterministic whole-device reproduction.

### 6. ANGLE: possible stability benefit, conditional code savings

[ANGLE](https://github.com/google/angle) is an existing OpenGL ES implementation
with a Metal backend. It may remove some of our ES-to-desktop-GL adaptation.
It cannot remove the guest transport, surface ownership, snapshots or guest
format contracts. Our native probes are encouraging but do not demonstrate
guest-level compatibility or a production backend.

Gate: select the same guest workload through each backend, compare output,
exercise context/sharegroup lifecycle and snapshots, then count the custom code
actually retired. Shipping two permanent backends would increase our footprint.

### 7. Future original-iPhone telephony: reuse protocols and network behavior

[Osmocom libosmocore](https://github.com/osmocom/libosmocore) includes GSM
protocol helpers, SIM infrastructure and voice codecs. The project's
[Virtual Um implementation](https://laforge.gnumonks.org/blog/20170719-osmocom_virtum/)
connects OsmocomBB and OsmoBTS to run a GSM network without radio hardware.
These are useful components if we need actual network protocol behavior.

The [AOSP emulator telephony source](https://android.googlesource.com/platform/external/qemu/+/refs/heads/jb-mr1.1-dev/telephony/)
also supplies prior art for simulated modem, SIM, SMS and remote-call behavior.
That source inventory does not establish iPhone command compatibility.

Neither stack is a drop-in iPhone baseband: the transport, command dialect,
unsolicited events and audio routing expected by Apple's drivers/CommCenter
remain to be measured. Start at that boundary before deciding whether a simple
modem model plus protocol helpers suffices or a complete virtual carrier is
warranted. Avoid writing a GSM core or codecs ourselves. Executing original
baseband firmware is a separate, much larger fidelity milestone.

## Alternatives that do not currently justify replacing our architecture

- [touchHLE](https://github.com/touchHLE/touchHLE) replaces iOS frameworks to
  run apps. It is useful prior art and a source of reusable components, but
  does not run stock iOS or its hardware drivers.
- [S5LBox](https://github.com/j0shua-SYSON/S5LBox) is particularly relevant
  original-iPhone prior art. Its documented default uses direct kernel boot,
  guest disk hooks and software rendering; it has no usable cellular model.
  Evaluate individual measured device behaviors, not replacing QEMU's CPU or
  adopting its storage/boot substitutions.
- [Inferno](https://github.com/ChefKissInc/Inferno), formerly QEMUAppleSilicon,
  is a QEMU Apple-device fork rooted in t8030 work. Its existence does not
  establish support for our legacy boards or a reusable MBX/SGX implementation.
  The current project also has distinct licensing for its own code.
- [libfshfs](https://github.com/libyal/libfshfs) explicitly describes itself as
  experimental and read-only. It cannot replace our stopped writable-volume
  workflow. Adding another HFS parser without deleting ours is poor value.
- libgpod is not automatically preferable to our small media helper: the latter
  asks guest MusicLibrary to mutate its own database. A host database writer
  could increase version-specific schema responsibility.

## Adoption order

First evaluate the isolated PVRTC replacement and consolidate flash backend
ownership. Advance stock restore until it can retire synthetic construction.
Expose existing device services and developer SSH/debugging without extending
our agent into a replacement OS service suite. Keep ANGLE behind a comparative
guest gate. Defer a full virtual carrier until the original-iPhone modem boundary
is understood.

The remaining custom core should consist of measured Apple hardware behavior,
board wiring, the minimum explicitly identified guest additions, and device
lifecycle/product integration. That is a reasonable target; today's codebase
still owns more storage and preparation policy than it ultimately needs to.
