# Reuse and fidelity implementation

Current finding dispositions and next steps: [remaining work](remaining-work-2026-09-30.md).

This implementation follows the [architecture review](holistic-review-2026-09-30.md)
and [reuse survey](reuse-survey-2026-09-30.md). Those documents describe the
inspection states at the time of the review; their checkout table is historical.
The implementation starts from multidevice `eac0793` and emulator `2ece77c080`,
including the consolidation and guest package 9 that landed before this work.
The candidates also include the later multidevice UI tip `e9fcfc3` and emulator
CoreAudio tip `66bbf69862`; those changes are integrated only in these candidates.
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
| Stopped edits | Production CLI and Finder actions for explicit N72 generated stores; lease, durable edit intent, HFS metadata preservation, certified generation publication and recovery. | Actual editor replacement and metadata fixtures pass. A published generation passes two native cold boots, exact edited AFC reads and subsequent guest-write persistence. N45 and native K48 FTL remain unsupported. |
| Device routing | Killable per-device command/notification processes with immutable socket, UDID and boot session. GUI uses a typed subprocess boundary. | Actual stalled C calls are killed/reaped; B remains usable while A stalls, next A gets a new PID, retired sessions refuse requests. Native guest services pass 12/12. |
| Developer access | Small host CLI delegates SSH/SFTP to OpenSSH and usbmux forwarding to `inetcat`, with explicit loopback endpoint and per-instance host-key identity. Use the existing QEMU GDB protocol. | Real SSH parsing/proxy execution tests cover quoting and endpoint isolation. Live guest OpenSSH and modern host SSH/SFTP interoperability pass; reproducible redistributable shell packaging is still being completed. |
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
sampling finds a busy loop in IMGSGX535; its polled virtual address maps to ordinary DRAM at physical `0x4112e018`,
with a driver-allocated descriptor and GPU address. The microkernel producer
contract remains undecoded. There is no native SGX model.
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

The app offline tier passes 91 checks, with two display checks explicitly
skipped. The app release tier passes eight checks, with its network fetch check
explicitly skipped. The emulator host tier passes 106 checks, with 27 input/guest-dependent
checks explicitly skipped; targeted native acceptance runs cover the changes
listed above. All three model qtest suites pass, including the existing
CDMA/AES/SHA suite. Xcode builds the GUI and helper against the final emulator
library. The incoming CoreAudio fake-HAL check passes all six device-rate and
device-switch cases after integration. These results do not imply that every catalog firmware or the full
native corpus has been rerun.

Logs, full independent renderer captures, preparation metadata, restore input
hashes and acceptance output are preserved under
`/Users/shg/Developer/ltm-evidence/reuse-2026-09-30` with an archive hash ledger.
Large trace logs are compressed; physical flash stores, runtime overlays and
pairing material remain in their isolated working directories.

## Boundaries still requiring work

The stopped-edit implementation owns one N72 generated storage format. It does
not use that builder to rewrite native restored FTL. K48's stock physical format
requires VFL/YaFTL and keybag/crypto support; its reader now rejects v2/unknown
formats before publishing an export. Guest SSH/SFTP provides a live root-file
route through stock guest filesystem drivers instead.

Apple controllers now use QEMU BlockBackend for data/spare I/O and ownership.
The explicit `nand-xor-ff-v2` format represents erased FF and one-to-zero
programming without changing legacy sparse-store meanings. Stock blank erase
restore and prepared-device persistence pass after the migration. Page/bitmap
crash atomicity, N72 logical relocation retirement and encrypted restored-store
execution remain separate fidelity gates. Unsupported populated FMSS snapshots
now refuse rather than silently lose physical state.

BootSessionScope owns controller boot tasks and observation. Further reductions
should move stable responsibilities into owners with clear lifetimes; merely
splitting this controller into extension files would not establish that boundary.
The shared FirmwareWire and cache maintenance API are now implemented without
making the GUI import FirmwareKit.

ANGLE remains subject to the same guest workload, surface/sharegroup and snapshot
comparison. Explicit API context and snapshot versioning are being tested; no
shipping backend replacement or code reduction is claimed from native probes
alone. Native Finder USB discovery and sync were removed from scope at the
user’s request. No entitlement request or virtual USB adapter will be pursued;
ordinary stopped Finder filesystem mounts remain.

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
release. The prepared K48 boot/graphics/persistence checks, N72 certified stopped-edit publication,
and stock blank restore are distinct results; none substitutes for the failed
stock cold-boot identity gate.
