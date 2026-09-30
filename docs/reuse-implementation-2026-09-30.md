# Reuse and fidelity implementation

This implementation follows the [architecture review](holistic-review-2026-09-30.md)
and [reuse survey](reuse-survey-2026-09-30.md). Those documents describe the
inspection states at the time of the review; their checkout table is historical.
The implementation starts from multidevice `eac0793` and emulator `2ece77c080`,
including the consolidation and guest package 9 that landed before this work.
The app and emulator candidates are isolated on `codex/reuse-implementation`
worktrees. A matching usbmuxd candidate is on `codex/stock-control-transfer`.
None has been merged into the target branches.

## Implemented boundaries

| Area | Change | What the evidence establishes |
|---|---|---|
| Texture decoding | Replace the owned PVRTC interpolation/modulation algorithm with Imagination's unmodified MIT reference implementation and a narrow guest-upload wrapper. Package its attribution. | Independent 2/4-bpp RGB/RGBA, modulation, rectangular and compact mip fixtures pass under ASan/UBSan. Native CGL upload checks pass. This does not replace the guest graphics transport. |
| Physical storage durability | Latch failures from both iPad page and dirty-map flushes; the GUI save/resume gate sees the failure and a later successful flush cannot clear it. | Injected page/map `msync` failures reach the actual stop callback and UI guard. This does not establish power-loss atomicity across separate backing files. |
| Offline ownership | FirmwareKit device-directory exports acquire the helper's existing exclusive lease. Boot checks durable edit intent under the same lease. | Swift tests and a real cross-process lease conflict reject access before export creates output. Pause is not treated as a clean shutdown. |
| Host mounts | Use macOS HFS and disk-image tools. Validate export paths and current attachment identity; retain staging on failed discovery/eject/repair. | Existing directories are preserved, stale disk nodes are not force-ejected, and failed filesystem repair cannot produce a successful export. |
| Stopped edits | Opt-in N72 proof on a disposable APFS-cloned device: edit a plist, rebuild with Swift, compare logical bytes and boot the candidate. | Two native cold boots, byte-identical AFC reads of the offline-added plist, persistence of a subsequent guest write, and both clean shutdowns pass. This is an experiment, not a production writable mount. |
| Device routing | Select the private usbmux endpoint before entering the C library. Refuse a switch while an abandoned call could reconnect. | A compiled delayed-connect regression preserves routing; install/recovery/notification/AFC checks pass. Calls remain process-wide serialized; full killable service workers are still needed. |
| Developer access | Small host CLI delegates SSH/SFTP to OpenSSH and usbmux forwarding to `inetcat`, with explicit loopback endpoint and per-instance host-key identity. Use the existing QEMU GDB protocol. | Real SSH parsing/proxy execution tests cover quoting and endpoint isolation. A compatible guest SSH server and user-facing provisioning are not yet provided. |
| Lifecycle | Retire timezone observer/task on stop, helper death and power-off; establish a new scope on power-on. Use the existing Swift Subprocess library to bound, cancel and reap timezone children. Preserve the catalog boot recipe through GUI serialization. | Actual-function lifecycle fixtures and a compiled Swift catalog round trip pass. A child ignoring SIGTERM is killed/reaped; cancelled readiness cannot trigger a timezone mutation or retry. |
| Capacity | Share a Foundation-only capacity leaf between GUI and FirmwareKit. Fall back to physical free space when macOS reports unusable ImportantUsage capacity. | Real preparation exposed the false zero; tests retain true disk-full refusal. The GUI adds no IPSW/Mach-O preparation dependency. |
| Acceptance provenance | Bind matrix reuse to hashed inputs/options, immutable attempt evidence, and host identity. Serialize result publication with a stable lock and reread before merging. | Same-size binary changes invalidate reuse; simultaneous processes with separate scratch roots preserve all 40 result records and history. |
| Hardware tests | Drive real PMGR and H2FMI MMIO/IRQ/FIFOs through upstream libqtest and virtual time; include the existing CDMA/AES/SHA suite. Missing prerequisites fail the explicit model tier. | Timer IRQ independence/acknowledgement, gating, watchdog feed/deadline, and normal/raw NAND phase transitions pass without Apple firmware. Existing inferred clock rates are not claimed as independent silicon measurements. |

## Restore is a hardware acceptance gate

The restore smoke test now has an explicit `--erase --blank-nand` mode. It creates
disposable geometry-only sparse physical chips and copies no FTL, filesystem or
bad-block-table seed. It retains the declared device identity, ROM, NOR recovery
configuration and per-IPSW keys. Input hashes are written with the evidence.

The stock restore guest exposed a new controller boundary: its raw page read
keeps transfer control at 3 after a new page command, then drains physical spare
bytes through the data FIFO. The original model required a control edge and
always separated metadata. Hardware corrections must preserve ordinary ECC
reads, FIFO sequencing and migration; qtest reproduces the observed operations.
A complete stock erase restore from this blank store now passes. The guest
creates its own FTL/partitions/filesystems, ASR transfers and verifies the system,
and idevicerestore reports Restore Finished after firmware flashing, epoch
finalization and unmount. The corrected controller also passes the prepared
device's cold boot and 70001-byte persistence test.

The restored stock store loads and decompresses its kernelcache through
SecureROM/iBoot after a stock recovery-exit command clears auto-boot=false.
The new cold-boot judge requires a stock lockdown identity response;
recovery-screen brightness is not accepted as boot success. A direct host USB
connection exposed prematurely completed partial descriptors. The matching
usbmuxd fix preserves 64-byte EP0 transfers across NAK pauses and ends on actual
short packets/ZLPs. A real-daemon fake-guest regression passes, while the old
daemon reproduces 128/149-byte truncation. Prepared-device identity, AFC size
boundaries and persistence pass with the new daemon.

Stock cold boot still fails the identity judge after 300 seconds. Read-only gdb
sampling finds a busy loop in IMGSGX535; its polled virtual address has not been
mapped to distinguish MMIO from GPU-shared memory. There is no native SGX model.
Prepared images explicitly set `arm-io/sgx` compatible to `none` in KBoot and use
the guest graphics bridge. The stock restored DeviceTree exercises the missing
GPU path. This is a concrete fidelity lead, not justification for inventing a
completion or clearing guest memory. Full restored userland and persistence are
unproven. A supported restore workflow needs either this GPU implementation or
an explicit additions/provisioning stage; stock restore alone cannot replace the
preparation pipeline yet.

The graphics gate now requires an exact-build reference and provenance. A
separately prepared 7B500 device with stock software CoreAnimation supplies the
independent home reference; live lockdown confirms iPad/3.2.2/7B500. The current
GL candidate passes at the unchanged threshold. Historical unqualified images
cannot be assigned to another firmware, and missing coverage explicitly fails.

## Verification and evidence

The app offline tier passes 87 checks, with two display checks explicitly
skipped. The app release tier passes eight checks, with its network fetch check
explicitly skipped. The emulator host tier passes 106 checks, with 26 input/guest-dependent
checks explicitly skipped; targeted native acceptance runs cover the changes
listed above. All three model qtest suites pass, including the existing
CDMA/AES/SHA suite. Xcode builds the GUI and helper against the final emulator
library. These results do not imply that every catalog firmware or the full
native corpus has been rerun.

Logs, full independent renderer captures, preparation metadata, restore input
hashes and acceptance output are preserved under
`/Users/shg/Developer/ltm-evidence/reuse-2026-09-30` with an archive hash ledger.
Large trace logs are compressed; physical flash stores, runtime overlays and
pairing material remain in their isolated working directories.

## Responsibilities we have not transferred yet

Production stopped editing needs atomic generation publication/rollback,
preservation of all metadata, saved-state invalidation and provenance changes.
K48 also needs partition 3/MBR, NOR keybag/encryption and YaFTL state preserved.
The preparation builder is not a safe generic editor. Live read-only views must
read through guest services or explicitly publish a frozen generation.

The next physical-storage milestone is a shared backend below the controllers,
using QEMU block infrastructure where it fits, with explicit erased-state and
NAND bit-transition semantics. Current mapped overlays and sparse zero handling
still constrain fidelity. Stock restore is the gate for retiring generated FTL
and host construction policy, not a reason to seed more guest tables.

The endpoint guard closes a demonstrated routing hazard but cannot kill a wedged
C thread. Move service execution to restartable per-device workers with immutable
endpoint/UDID and one reusable GUI/CLI contract; do not put these workers inside
the emulator process. A host SSH wrapper likewise does not constitute guest SSH
provisioning, root filesystem mounting or Finder media sync.

The merged ANGLE evaluation remains the decision: native ES viability is proven,
guest surface/snapshot compatibility and a net reduction in owned code are not.
Keep CGL until a comparative guest gate justifies replacing it. Shipping another
adapter backend simply to claim adoption would add responsibility. FirmwareKit's
Swift orchestration and the earlier Python retirement are already in the bases;
this branch builds on them rather than introducing another preparation system.

Future Retina boards and telephony remain scoped bring-up work. Preserve stock
guest UI and protocols; reuse modem/network helpers after measuring the Apple
boundary. Neither a virtual carrier nor additional device support is implied by
this implementation.

## Candidate integration

| Repository | Candidate worktree | Branch |
|---|---|---|
| Light Touch | `/private/tmp/ltm-reuse-app` | `codex/reuse-implementation` |
| Emulator | `/private/tmp/ltm-reuse-qemu` | `codex/reuse-implementation` |
| USB host | `/private/tmp/ltm-reuse-usbmuxd` | `codex/stock-control-transfer` |

The app source manifest pins the emulator and USB host together. Before these
branches are integrated, development builds must resolve the candidate paths
with `QEMU_IOS_DIR`, `QEMU_BUILD_DIR` and `USBMUXD_SOURCE_DIR`; the canonical
checkout paths intentionally remain the integration targets. The recorded native
build uses `build-reuse` and `/private/tmp/ltm-reuse-xcode`, not a universal signed
release. The prepared K48 boot/graphics/persistence checks, N72 stopped-edit proof,
and stock blank restore are distinct results; none substitutes for the failed
stock cold-boot identity gate.
