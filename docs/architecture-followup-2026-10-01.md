# Architecture follow-up: measured contracts and reuse

Worktree candidates only. No target merge, installation, publication or release.
Native Finder virtual USB remains excluded. This follows the architecture
review in the original LightTouchMac checkout; it does not replace historical
test receipts with current compatibility claims.

| Area | Verified progress | Remaining acceptance boundary |
|---|---|---|
| Stock restore transport | Real SecureROM/iBSS/ramdisk reaches stock restored protocol 11; legacy client boot-only run passes with original firmware metadata. Production bridge reset/enumeration and exclusive mux handoff tested; measured PHY-reset gating now passes rapid DFU trials and complete stock ramdisk handoff without diagnostic settling. | Stock erase reports Waiting for NAND. Full restore, cold boot and durable later writes required before deleting offline FTL preparation. |
| FMSS | CPU/sequence scalar state through D7C/D3C, zero-immediate mask/shift forms and erased physical reads have model/native gates; latest340978ff58 checks sequencer DMA and passes FMSS23 and native3.1.3 eight checks. | Stock erase stops at D24. Its isolated latch candidate failed both native boots because newly reached FMC reads overwrite preloaded spare data; it was withdrawn. Physical commands, CPU DMA, timing and honest completion remain separate contracts; restore/cold boot is unqualified. |
| Silent audio migration | 0ceac9c55e fixes legacy silent stream host rate bookkeeping; model 4/4 including N45 snapshot, audio sanitizers and native two-boot 8/8. | Native N45 guest suspend/wake and in-flight host USB snapshots remain unqualified. |
| Host runtime | GuestPackageSession owns boot package qualification. GUI and session driver now import HostRuntime for prepared-device validation/assembly and actual wire values; package tests, real builds, failure cleanup and native N72 startup pass. | Broader process/service ownership and session source/stub coupling remain; async record/storage lifecycle and CLI cleanup are now qualified. Managed GUI boot-path authority and strict present-lock parsing are now verified; CLI record authority remains separate. |
| MBX reuse | Independently captured real N72 stock-driver fill packet/GART agrees with pinned MIT S5LBox decoder in sanitizer replay. | Snapshot was after stall, not pre-submit. No live pixel/completion/IRQ or full compositor qualification yet. Unapplied narrow prototype rejects startup/context requests without success. Startup EVM metadata effects and trigger/tag semantics remain unknown; existing GLES transport remains needed. |
| Packaging | Clean cc67737/31036cf8e9/e19fac2 universal candidate: actual 2.1.1 session 18/18, both Mach-O closures at macOS14.4 and ad hoc signature verification. | Later host/FMSS/PHY changes are not covered by that packaged candidate; Intel runtime and notarization unqualified. |

## Reuse versus writing new compatibility logic

[LukeZGD idevicerestore](https://github.com/LukeZGD/idevicerestore) upstream
9e6eacc788d532b887b9b0883477d6b89c5a2841 already understands old Restore.plist
and restored without UniqueChipID. The private branch adds 26314aa, a small
ProductType lifetime fix with a failing ASan baseline and passing ASan/UBSan
fixture. This replaces our early metadata workaround; no guest response is
fabricated. Client installation/release source licensing remains a later gate.

[S5LBox MBX](https://github.com/j0shua-SYSON/S5LBox/blob/6f203ba550b49afadee008c7eb55373a838eed33/core/src/soc/mbx.c)
is pinned at 6f203ba550b49afadee008c7eb55373a838eed33 with MIT license. Its decoder
links independently from its machine/boot model. The real captured N72 packet
has a0060500 header, 94060500 descriptor, 8000f0f0 fill control, opaque-black
color and (0,0)..(320,480) rectangle; separate f0000000 ring submission. With
captured GART it produces 153600 translated pixel writes in ASan/UBSan replay,
then completion/mask/W1C behavior. This is decoder agreement, not measured
hardware timing or a successful native compositor. Adopt covered decoding
knowledge with attribution, not the upstream machine substitutions or a
presumed complete GPU implementation.

## Boundaries retained

Physical devices own hardware registers, DMA, interrupts and timing. Stock iOS
owns formatting, filesystems and processes. A stock supported restore argument
belongs to the host restore workflow; a missing sequencer register belongs to
FMSS. Diagnose each first divergence before changing either. Guest addresses
used for research captures do not become emulator patch sites.

GuestPackageSession retains BootSessionScope task ownership. The GUI supplies
fresh observations and handles presentation/persistence. The next runtime
extractions should make this same owner importable to CLI/session tests,
rather than growing a parallel orchestration framework.

Evidence: docs/fidelity-ledger.md; durable restore-crypto and restore-usb
2026-10-01 directories under /Users/shg/Developer/ltm-evidence; temporary
/private/tmp/ltm-nand-contract-agent and /private/tmp/ltm-mbx-reuse-agent.
The latter contains private raw RAM solely for research; do not copy/publish it.

## MBX startup boundary from the stock driver

The captured startup sequence allocates an EVM pool. The buffer base written
to 0x83c is not a proven buffer size, and the fixed 0x6d8 tag is not a
demonstrated DMA address. Upstream acknowledgements therefore cannot prove
execution. The reviewed scratch proposal removes new idle/context success
bits and completes only a successfully executed fill. It remains unapplied:
the native guest may stop before that fill until real pool metadata effects
and the triggering operation are established.

Durable reviewed proposal, MIT provenance and sanitizer receipts:
`/Users/shg/Developer/ltm-evidence/mbx-reuse-2026-10-01`. No private raw RAM
or guest firmware is copied into that evidence directory.

## Reusable prepared-device boot boundary

`Packages/HostRuntime` now owns BootConfig/WebProxyEndpoint, BootRecipe and
PreparedDeviceBoot. GUI and session driver use the same implementation. The
session driver now prepares storage after the helper hello/lease acquisition;
its previous preparation before helper start is removed. An actual missing-NOR
failure preserves its diagnostic, reaps the helper, releases its lease and
stops its usbmuxd without sending a boot request. Wire compatibility and
private NOR/base semantics are retained.

Ten package tests, relevant offline checks and actual GUI/helper/services
builds pass. The native N72 session reaches Home with matching identity and
byte-exact AFC transfers, then performs bounded helper Stop/reaping. It uses
a freshly relinked dylib from verified QEMU 089b055d73; this is not a new
packaged release or clean guest FTL shutdown claim. Evidence:
`/Users/shg/Developer/ltm-evidence/host-runtime-2026-10-01`.

The runtime accepts caller-authorized URLs. Maintenance path containment is
stronger than current managed-record boot authorization; extraction does not
fix that seam. Malformed/non-string lock strategies can still fall into legacy
nil handling. These need explicit managed-record and parsing contracts.
DeviceProcess/services, record persistence and current session test replacement
types remain outside the extracted module.

## Present boot locks fail on malformed input

HostRuntime now uses one throwing strategy reader in boot preparation and
publication. A present lock must contain a JSON object, and a present strategy
must be a string. Syntax, type and read failures no longer select the legacy
boot path. Deliberate missing-file compatibility and valid old locks without
a strategy retain their board defaults. This is not full lock-schema or
managed storage ownership validation.

Actual package tests pass (13 tests, including 33 invalid-input board cases and
6 legacy-default cases). Publication rejects invalid locks without moving
staging or publishing records. Existing strategy, sibling preparation/import,
legacy erase and session compile checks pass; the actual GUI and helpers build.
Evidence: `/Users/shg/Developer/ltm-evidence/host-lock-2026-10-01`.

## Helper lease admission matches maintenance

The live helper now opens the lease leaf with O_NOFOLLOW, matching stopped
maintenance. Actual hello-only tests admit ordinary and explicit external
leases, refuse a lease-file symlink before hello, preserve its target, and
verify process reaping and released locks. The actual app/helpers and test
driver compile. No guest was started by this admission test.

Parent-directory containment and managed-record path authority remain
separate; this single flag does not establish either. Evidence:
`/Users/shg/Developer/ltm-evidence/host-lease-2026-10-01`.

## Generic NAND reuse requires a measured storage boundary

The existing QEMU NAND core is a useful future flash child, but it is not a
drop-in replacement for FMSS. The advertised AD D5 14 B6 identity and current
controller geometry describe 4 KiB pages and 128 pages per erase block. The
generic core's D5 entry instead selects 2 KiB pages, 64 pages per block and a
different extended ID. It needs explicit geometry, full ID, wider capacity
and bounded 4 KiB support before this chip can use it.

A combined data/OOB BlockBackend could avoid allocating whole flash or a
large volatile spare area. Sparse file holes return zero, however, whereas
erased flash returns FF. FF-valued backing, durable failure reporting and
block snapshot/migration ownership need separate qualification. Current FMSS
64-byte stored metadata and 12-byte guest projection are not a proven full
raw OOB/ECC layout; generic ID decoding does not establish Apple's projection.

Keep the generated-image compatibility format separate. First qualify stock
restore, physical writes and cold boot; only then replace custom media
operations with a tested generic flash child. A format adapter that merely
moves current synthetic metadata into a new driver would not establish reuse
or fidelity. Read-only source audit:
`/Users/shg/Developer/ltm-evidence/nand-reuse-2026-10-01`.

## Managed GUI storage ownership before boot

The controller now checks record-owned mutable paths before constructing or
spawning a helper. It uses the existing storage authority, requires writable
paths beneath the owning UUID directory, and keeps them disjoint from the
read-only base. External read-only bases, absolute own paths, generation
descendants, relocated relative state roots and existing private/root aliases
remain supported. Broken links, shared or escaped writable paths, base overlap
and parent traversal after a symlink are refused. Explicit raw CLI sources
retain their separate caller-selected path contract.

Actual DeviceInstance/DeviceStateStorage fixtures pass accepted and rejected
layouts without mutating refused records or publishing writable state. Existing
maintenance, stopped-lease and HostRuntime tests pass, and the actual app/helpers
build. The controller's ordering was reviewed and compiled; this is not an
executed GUI start or new native guest qualification. The preflight assumes
private owned state, rather than descriptor-relative protection from concurrent
renames. FirmwareKit record export/edit admission remains a separate shared
resolver/lease boundary. Evidence:
`/Users/shg/Developer/ltm-evidence/host-managed-storage-2026-10-01`.

## One lease owner across host clients

App 41637a5 replaces three descriptor implementations with HostRuntime's
StorageLease. The helper, GUI maintenance and FirmwareKit share exclusive
nonblocking locking, close-on-exec/nofollow admission and durable edit checks
after locking. Caller path policy and exact resume-session validation remain
separate. FirmwareKit uses a value error adapter retaining the shared owner;
no lease inode is removed.

HostRuntime 16/16, stopped storage/generation 10/10 and five actual hello-only
helper checks pass. The GUI/helpers and actual session driver build. Tests
verify independent contention, descriptor release, unchanged symlink targets
and pending intents, and exact resume refusal. An initial extra class adapter
held a lease longer in two tests; failures are retained. Removing that extra
reference layer passed unchanged tests without waits or instrumentation; the
Swift runtime/compiler cause is not established. No guest ran in these tests.
Evidence: `/Users/shg/Developer/ltm-evidence/host-shared-lease-2026-10-01`.

The next host boundary is lock-before-record-read and retention of the exact
record generation throughout export/edit. That work remains unqualified.

## Controller execution must have one owner

Read-only stock instruction inventories expose a silent gap beyond unsupported
opcodes: bulk scripts write CSGENRC to controller offset0x804 and use0x810.
Both lie outside the current 256-byte local FMC shadow, so writes are dropped
and reads return zero. Status scripts issue60/row/D0 erase and70 status, but
these currently change only the command shadow. Even a script that reaches
END would therefore not establish flash work.

CPU D38 currently invokes host read/write helpers independently of the script.
A future physical controller path must replace that dispatch, not run beside
it. The existing store helper infers block erase and performs generated-image
relocation; reusing it for real flash programming risks losing neighboring
pages or mapping twice. A single execution owner, bounded checked DMA and
explicit command/status/abort behavior must precede shortcut deletion. Stock
restore, cold boot and durable subsequent writes remain the final gate.

D38 scalar CPU/sequence ownership was subsequently qualified separately
(see the evidence journal); this audit did not qualify physical execution.
Raw NAND program encodings,
AES/ECC and complete spare layout remain unmeasured. Findings and explicitly
unqualified proposal: `/Users/shg/Developer/ltm-evidence/fmss-controller-audit-2026-10-01`.

## D54 sequencer loop state qualified

QEMU 0a602cca75 implements the observed D54 register-write/read pair as
sequencer-owned CSGENR15 state. The stock read script seeds it from D28,
decrements it and writes it back for its chunk loop. The model retains a
full-width scalar across script invocations, exposes observed CPU diagnostic
readback, and saves it in VMState v9. No CPU-write form, other Dxx mutation,
forced chunk count, crypto or completion behavior was introduced.

Six actual-source suites and 17 real model tests pass; the baseline fails a
loop-count assertion. Tests vary counts1/2/3/7, exercise independent scalar
values, reset and actual snapshot replacement. A real retained v8 stream
clears preinitialized D54 while preserving D34/D48. Default native checks
pass 8/8, including clean guest shutdown, reboot persistence and fsck.
Default diagnostics still stop at D38 reads; existing false-completion and
CPU storage shortcuts remain. Stock physical restore is not qualified.
Evidence: `/Users/shg/Developer/ltm-evidence/fmss-d54-2026-10-01`.

The detailed gate chronology is maintained once in the
[fidelity evidence journal](fidelity-evidence-2026-10-01.md); the ledger and
remaining-work report link to it. Their earlier dated entries remain history.

## Stopped record ownership qualified

App2137e27 now locks before reading device.json and retains one record snapshot
and descriptor through export/edit. GUI and FirmwareKit share managed path
authority; explicit standalone sources keep their prior convention. Package,
actual HFS, helper admission and build gates pass. Full qualification, the
Source API change and retained lifetime failures are recorded in the
[shared journal](fidelity-evidence-2026-10-01.md#stopped-record-ownership-qualified).

Parallel disk-image work exposed cooperative-worker starvation in the old
synchronous subprocess bridge. Appbf72e7416c replaces that bridge with awaited
execution and qualifies exclusion, cancellation and cleanup through real CLI gates.

D38 is also qualified through model/migration and native8/8 gates; it retains
the scalar while preserving the still-required CPU storage shortcut. Watchdog
research establishes the guest's cached bus-frequency source but leaves
physical expiry unmodeled. Detailed receipts are in the shared journal.

The D7C result latch is now qualified through native8/8 as well. Stock restore
moves to D3C and the diagnostic immediate D7C form; controller execution is
still missing. The managed published-generation admission regression is
corrected in dd9d66a. The broader async host migration was subsequently qualified in bf72e7416c
with cancellation and explicit descriptor release gates. Current
receipts and limits are maintained in the shared evidence journal.

The genuine2.x private regression fixtures now pass installation, foreground
launch and measured stereo audio. That initial2.1.1 gate was6/8. Subsequent work qualifies the CoreSurface
callback mapping, while strict scene geometry still fails at LCD scanout.
The GPT extent correction independently passes boot/persistence/fsck3/3
on2.1.1 and3.1.3; a combined full gate remains pending. Latest
stock erase still stops at D24; the literal initializer no longer stops it.
Exact receipts and remaining limits are recorded in the shared journal.

App bf72e7416c now carries async disk tools through the maintained firmware
CLI, with actor-owned publication and native pipe cancellation/cleanup gates.
QEMU340978ff58 checks sequencer fetch/store transaction results and passes
all eight native3.1.3 checks. The app source pin is aligned; the current arm64 dylib passes hello-only helper admission. Universal packaging,
native dylib guest qualification and full stock restore remain separate gates. Full receipts and
retained failures are recorded in the shared evidence journal.

App0b43f26 and QEMUb2090969d4 correct the N72 prepared GPT extent without
filesystem-aware hardware changes. Existing N72 bases request Prepare Again;
automatic old-image migration and4.x native qualification remain separate.
QEMU75704ad744 qualifies CoreSurface callback ownership; a85802ffb8 rejects
incorrectly packed graphics even when aggregate color areas match. A measured
stock2.x control-register RMW exposes missing LCD plane1 readback. QEMU8e9fac00f6 qualifies the narrow
readback through13 models/five LCD QTests and native3.1.3 eight checks. The
combined2.1.1 run is6/8: graphics and clean-shutdown persistence still fail;
that run does not exercise the plane1 correction. No full2.x graphics pass is
claimed. App648a471 also repairs actual shared-module linkage in23 existing
offline probes, all compiling and executing. Current receipts and remaining
first-divergence research are recorded once in the evidence journal.
