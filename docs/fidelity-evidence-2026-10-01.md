# Fidelity implementation evidence — October 1, 2026

Verified worktree changes and their qualification limits. Entries are historical;
later entries supersede earlier blocker locations. This is the shared evidence
journal for the fidelity ledger and architecture work list. No target merge or
release is implied.

### Verified USB PHY reset boundary (2026-10-01)

QEMU a2cc232364 gates physical traffic on ORSTCON bit 0 for N45/N72. The
stock ROM had asserted reset and freed its USB queue while the model still
injected SETUP DMA/interrupts, causing a data abort. Core registers and
latched IRQs remain intact, and migration redrives the PHY signal. No guest
patch or firmware-specific delay is used. Model qtests pass 3/3, rapid stock
5F138 handoffs 3/3, native 5F138 boot/USB 2/2, and the separate default 7E18
two-boot regression 8/8. The baseline binary fails the new reset gate.

Stock SecureROM through the restore ramdisk now passes with the production
bridge and no diagnostic settling wrapper. Descriptor polling keeps its
one-second deadline (f4226be0ff); the preceding timeout failure is retained.
This supersedes the earlier rapid-DFU research blocker for these measured
trials, not the unresolved physical flash restore. N45 native boot passes,
but native host USB is unsupported by that harness. N45 whole-board
migration exposes a separate inactive I2S host voice-rate validation bug;
K48 is not wired to this PHY signal.

Evidence: `/Users/shg/Developer/ltm-evidence/usb-phy-2026-10-01`. The app's
source pin now includes this verified QEMU correction; no new universal
package qualification, target merge or installation is claimed.

### Verified FMSS request parameters (2026-10-01)

QEMU 333bc8023c adds sequencer access to the existing D18 request-count latch
and models D28 as the guest-supplied count of 2048-byte page chunks. No fixed
count, descriptor-load or erase behavior is invented. Reset and VMState7
preserve D28; older supported streams initialize it to zero. Sanitized actual
handler/script tests, real FMSS qtests 4/4 and the separate default native
7E18 two-boot regression 8/8 pass, including filesystem health and persistence.
Evidence: `/Users/shg/Developer/ltm-evidence/fmss-parameters-2026-10-01`.

Stock bulk scripts still encounter opcode06 before descriptor opcode03;
read/status scripts encounter opcode03. These and real physical erase are
unqualified. The source pin advances to the verified parameter correction;
the earlier universal package does not include it.

The subsequent actual stock erase trace uses the production USB bridge with
no diagnostic settling wrapper. It connects to restored version11 and is
stopped after repeated Waiting for NAND. The bulk script's next measured
divergence is opcode06 `06040003 00000000` at +0x78; its semantics remain
unimplemented. Owned subprocesses are reaped. Text/trace evidence is retained
in the fmss-parameters-2026-10-01 directory above; this is not restore success.

### Silent I2S migration correction (2026-10-01)

QEMU 0ceac9c55e corrects the N45 silent-sink rate initialization and accepts
legacy zero host voice rate only without a realized/active host voice, after
all stream/ring/queued PCM/rate/pacing/FIFO validations pass. Guest TX/DMA
activity is valid in silent streams; it does not justify rejecting them.
The permanent whole-board PHY model suite passes 4/4 including N45 migration,
whose baseline failed in I2S. Actual audio sanitizer/alignment tests and the
separate default 7E18 native two-boot regression 8/8 pass.

Evidence: `/Users/shg/Developer/ltm-evidence/i2s-silent-2026-10-01`. This is
silent-stream migration bookkeeping, not N45 native guest suspend/wake,
in-flight USB snapshot qualification or a new packaged candidate. The app
source pin includes the verified fix; targets remain unmerged.

### Observed FMSS register copy (2026-10-01)

QEMU c49f3cdae4 implements the stock immediate-zero opcode06 register-copy
form; unknown forms remain unsupported. The actual-handler baseline fails
the copy assertion; sanitizer fixtures, real FMSS qtests 5/5 and the separate
default 7E18 native two-boot regression 8/8 pass. Actual target8720 dataflow
corroborates [related hardware-tested8702 research](https://github.com/lemonjesus/S5L8702-FMISS-Tools/blob/70b45859af8807a7f841cf649564ce6638e1c112/Documentation.md);
no reference implementation or documentation text was copied into production.

The subsequent actual stock erase trace reaches opcode03
`03010000 00000000` at +0x88, still waits for NAND and is intentionally stopped.
No descriptor DMA, arithmetic, physical erase or completion qualification
follows from the register-copy correction. Durable evidence:
`/Users/shg/Developer/ltm-evidence/fmss-opcode06-2026-10-01`. Source pin advances
to this verified correction; no new packaged candidate or target merge.

### Stock FMSS descriptor DMA (2026-10-01)

QEMU 089b055d73 supports observed opcode03 immediate-zero little-endian32
descriptor loads using QEMU guest memory transactions. Unsupported forms and
failed transactions stop before fabricated data or later stores. Actual-handler
sanitizer tests, real FMSS qtests6/6 and the separate default native7E18
two-boot regression8/8 pass. Full stock erase trace now reaches opcode0A
`0a000004 00000000` at +0xa8, still waits for NAND and is intentionally stopped.
No arithmetic, completion or physical erase qualification follows. Evidence:
`/Users/shg/Developer/ltm-evidence/fmss-opcode03-2026-10-01`. Source pin advances
to verified descriptor support; targets remain unmerged and package unchanged.

Shared prepared boot assembly now lives in Packages/HostRuntime and is imported
by GUI and session driver. Ten package tests, actual app/helper/services builds,
real helper preparation-failure cleanup and native prepared N72 startup/AFC
checks pass. Broader service/process reuse, managed boot-path authority and
malformed lock typing remain. Details and evidence: architecture-followup-2026-10-01.md
and `/Users/shg/Developer/ltm-evidence/host-runtime-2026-10-01`.

### October 1: stock sequencer mask intersection

QEMU 0fb13887b1 adds the observed opcode0A register/immediate AND forms,
corroborated by actual stock5F138 script dataflow. The preceding model fails
the sanitizer overlap test; actual-handler sanitizers, real FMSS qtests7/7
and independent default7E18 native two-boot8/8 pass. Evidence:
`/Users/shg/Developer/ltm-evidence/fmss-opcode0a-2026-10-01`.
Other arithmetic, physical storage, erase and aborted-script completion remain
separate contracts. The production-bridge stock5F138 erase trace now stops at opcode14
`14000001 00000010` at +0x128, after eight Waiting for NAND responses.
The research harness stops/reaps its own children; no full physical
restore/coldboot qualification follows from this correction.

### October 1: physical erased reads and maintained persistence gates

QEMU 8b3856af65 gives confirmed physical holes and erased markers exact FF
bytes, preserving generated storage and invalid/truncated/I/O-error fallbacks.
The packed parser distinguishes holes from invalid records. Stored spare
remains a 64-byte projection with 12 guest-visible bytes; raw OOB/ECC is
not qualified. Actual-source sanitizer behavioral baseline fails, fixed gates
pass, real FMSS qtests12/12 and independent default native8/8 pass. Persistence
fixture declarations now match the existing GTree caches: all 18 fault cases
and the 1,024-page bulk write pass.

Stock physical erase remains at opcode14/imm16+0x128 with eight Waiting for
NAND responses. The research harness stops/reaps its own children. Experimental
MMIO capture cannot expose unimplemented pointer-register readbacks; those
zeros are not parameter-state evidence. No stock restore/coldboot pass follows.
Evidence: `/Users/shg/Developer/ltm-evidence/fmss-physical-blank-2026-10-01`.

Further storage gaps: payloads are controller DMA bytes, not proven raw flash;
bitwise programming cannot be added blindly. First/repeated writes still infer
block erases, stock FMC erase commands do not execute against the backend, and
aborted sequencer runs still receive deferred completion. Directory fsync and
full command/error/timing contracts remain distinct from erased-read fidelity.

### October 1: chip-selector host bounds and default sequencer dependency

QEMU 2020f66cde checks the populated-chip bound before shifting by ctz32(sel).
Empty selection previously shifted by 32 in host C. Strict sanitizer baseline
fails; corrected actual-source/IRQ and real model13/13 pass. Independent
default native7E18 two-boot8/8 passes with diagnostic-only QEMU logging.

Those diagnostics show incomplete opcode14/imm16 in both iBoot/XNU, plus an
unmodeled D48 read in a separate XNU script. Deferred completion currently
hides these gaps even in normal boot. Honest completion must be gated against
these measured dependencies; passing boot is not complete sequencer fidelity.
Evidence: `/Users/shg/Developer/ltm-evidence/fmss-ce-2026-10-01`.
No physical restore or full flash-command qualification follows.

### October 1: observed bounded descriptor shift

QEMU 865961d1e5 supports opcode14 immediate16 for bit31-clear sources, where
logical and arithmetic shifts agree. Other forms remain explicitly unsupported;
shift signedness is unmeasured. Strict behavioral baseline fails; actual-source
sanitizer/IRQ gates, real model14/14 and independent native7E18 two-boot8/8 pass.
Diagnostic-only traces now reach D34 reads in the iBoot/kernel bulk paths and
D48 in a separate kernel script. The exact live descriptor word was not captured;
this progress does not establish a complete ISA, flash execution or completion.
Evidence: `/Users/shg/Developer/ltm-evidence/fmss-opcode14-2026-10-01`.
The completed production-bridge stock5F138 erase trace now reaches D34
at bulk +0xda0, D54 at read +0x330 and D48 at status +0x30. Eight Waiting
for NAND responses trigger research stop/reap; no restore pass is claimed.

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

## FMSS D34/D48 parameters qualified

QEMU cf8c118a8e retains independent full-width CPU-supplied D34/D48
parameters, makes them available to the sequencer, clears them on reset and
saves them in VMState v8. A retained actual v7 stream loads with absent new
fields cleared and prior D4C/D28 values preserved. No guest address, timing
value, ECC result or completion behavior was added.

Actual-source baseline compiles and fails D48 readback; fixed sanitizer checks
and all 15 model tests pass. Six source gates include 18 persistence faults
and 1024 page writes. Default native checks pass 8/8, including clean shutdown,
reboot persistence and fsck. The D48 test uses an immediate OR observation
oracle; it does not certify the still-unfixed stock register-OR instruction.
Default traces now reach D38 reads at +0x158 in iBoot and XNU. Native success
still relies on the existing incomplete-script completion shortcut and stock
graphics additions; it does not qualify physical restore or raw graphics.
Evidence: `/Users/shg/Developer/ltm-evidence/fmss-d34-d48-2026-10-01`.
A separate disposable stock erase restore trace is in progress. D54 loop
state and Dxx writes remain distinct contracts.

Stock restore against cf8c118a8e completed its bounded trace and owned-process
cleanup. It reached stock restored protocol11 but again waited eight times for
NAND. The next stops are D38+0x158 (106112) and D54+0x330 (21726), with no
remaining D34/D48 stop in this capture. This is progress in contract coverage,
not a successful restore. Text evidence is archived under the D34/D48 receipt.

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

D38 scalar CPU/sequence ownership is separately evidenced and has a scratch
proposal; it has not been promoted by this audit. Raw NAND program encodings,
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

The completed stock5F138 physical erase trace after D54 records only D38
reads at bulk+0x158 (105600 stops), with no D54 stop. Stock restored again
waited eight times for NAND; the harness stopped deliberately and reaped its
own processes. This narrows the next contract without establishing restore
success. Logs are preserved in the D54 evidence directory's stock-restore receipt.

## Stopped record ownership qualified

App2137e27 acquires the shared lease before reading device.json and retains
one immutable snapshot through export or generation creation. Edit preflight
uses that same snapshot and descriptor; it cannot certify one generation then
publish another observation. Export selections are declarative and release
the lease at return/error even while the selection lives. Public Source
.base/.overlay previews were removed; raw isolated sources remain explicit.

Managed GUI edits select strict record policy through the CLI. Shared path
authority now serves both GUI and FirmwareKit: UUID/directory agreement,
private work admission, actual-base disjointness and mutable state beneath
the owner. Caller-selected standalone paths retain their legacy relative-root
convention and external-source support. Unknown record fields and output
style are preserved. Present malformed optional mutable fields reject;
deliberately absent ones remain supported. Private lease creation may precede
invalid-record rejection; descriptor-relative hostile-rename protection is
not established. Physical FTL editing is still unsupported.

HostRuntime21/21, FirmwareKit14/14 and the unchanged stopped-store10/10
selection pass, including16 weak-owner lifetime cases, wrong resume, snapshot
selection and failure release. Actual native HFS tests verify successful
export releases its lease with Source alive, resource forks/hardlinks/owners
and exact generated NAND publication. GUI/helper/session builds and five
actual hello-only helper checks pass. No guest launched in these gates;
updated managed prepared-firmware cold boot was not run. Initial nested-owner
lifetime failures remain recorded; direct descriptor/snapshot transfer passes
without retries, test waits or a speculative compiler-cause claim.
Evidence: `/Users/shg/Developer/ltm-evidence/host-owned-record-2026-10-01`.

A separate parallel discard stress exposed synchronous DiskImage.exec
blocking16 Swift cooperative workers while detached Subprocess work needed
that pool. This deadlock remains unfixed in2137e27. The owner-only stress
omits disk operations; existing discard/recovery and native HFS tests retain
them. Next investigate an async subprocess boundary, preserving transaction
exclusion and cancellation cleanup; extra threads or pool knobs are not a
qualification gate. The sampled failure is retained with the host receipts.

## D38 transfer parameter qualified

QEMU dd7e9e2102 independently retains the CPU-supplied D38 transfer-count
parameter and exposes it to CPU diagnostics and sequencer reads. It preserves
the existing legacy CPU page dispatch unchanged; it neither retires that
shortcut nor runs physical NAND work. VMState v10 appends the scalar after
D54 v9, with reset/older-stream initialization. No guest-address dispatch or
fixed parameter value was added.

Six actual-source sanitizer checks and18 FMSS model tests pass. Actual v9
loading clears preseeded D38 while preserving D54 and older parameters;
current physical/generated round trips retain D38. The baseline compiles and
fails D38 readback. Independent default native checks pass8/8, including
guest shutdown, persistence after reboot and fsck. Graphics still uses the
stock additions and storage still uses the compatibility execution path.
Evidence: `/Users/shg/Developer/ltm-evidence/fmss-d38-2026-10-01`.

## Watchdog provider source established, expiry still open

Static stock7E18 analysis follows watchdog index0 through DT clock-ids[0]=2,
its concrete provider and inherited getter to a cached platform bus-frequency
field initialized from cpu0 DT properties. This explains the driver's source
without substituting QEMU PCLK or a12MHz constant. Runtime-selected property,
bootloader clock publication, counter/clear/expiry semantics and clock-change
behavior still need observations. No countdown or clock wiring was changed.
Evidence: `/Users/shg/Developer/ltm-evidence/watchdog-provider-2026-10-01`.

The completed stock physical erase trace after D38 reaches one explicit
unsupported D7C read at bulk+0x218 (106112 stops). No D38/D54 stop remains
in this capture. Stock restored still waits eight times for NAND; owned
processes were reaped. D7C ownership and silent controller transfers remain
research leads, not capabilities inferred from reaching the ramdisk.

## Register OR retains destination bits

QEMU1c3417a255 corrects opcode0B's observed zero-immediate register form
to union the existing destination and source. Previously the destination
configuration bits were lost. The nonzero-immediate source|constant form
remains unchanged. Captured stock D4C→FMCTRL0 dataflow is exercised without
assuming the hardware effect of those controller bits. No shift, DMA, flash
command, crypto or completion behavior changed.

The baseline fails configuration preservation; six actual-source checks,
19 FMSS model tests and independent native8/8 pass, including persistence
after guest shutdown/reboot and fsck. This qualifies the register form that
earlier D48 tests deliberately avoided; it does not qualify auxiliary
controller operations. Evidence:
`/Users/shg/Developer/ltm-evidence/fmss-register-or-2026-10-01`.

The bounded stock erase trace after register OR again records106112 D7C
reads at+0x218, then eight Waiting for NAND messages. No restore success
was inferred from corrected control bits; own processes were reaped.

## Async subprocess leaf proven in isolation

An isolated whole-source build reproduces the real DiskImage.exec deadlock
with64 harmless printf requests under ordinary executor settings. An external
15-second supervisor terminates/reaps the blocked test. A private direct
async Subprocess leaf completes64 equivalent exact-output requests; nonzero
exit/stdout+stderr, signal, closed stdin, spawn failure and cancellation also
pass. The canceled owned child is absent and already reaped after await.
No disk tools, mounts, guests or shared cache were used by this comparison.

This proves the leaf correction, not the complete production call-chain
migration. Async propagation and cancellation-safe storage/CLI ownership
are still in progress and unqualified. Evidence:
`/Users/shg/Developer/ltm-evidence/subprocess-starvation-2026-10-01`.

## D7C sequencer result latch qualified

QEMU c60d637ba2 retains the observed opcode02/zero-immediate D7C result
store and exposes the scalar to sequencer reads and CPU diagnostics. Other
write forms remain explicitly unsupported. Reset and VMState v11 preserve
ownership; loading an actual v10 stream clears the absent field while
preserving older parameters. No auxiliary result, ECC operation, flash
transfer or completion event was synthesized.

The compiled baseline fails exact readback. Six actual-source sanitizer
checks, all12 model suites (FMSS20/20), and independent native8/8 pass,
including guest-confirmed shutdown, identical persisted bytes after reboot,
and fsck_hfs. Graphics additions and legacy storage execution remain in use.
Textual evidence and hashes are retained at
`/Users/shg/Developer/ltm-evidence/fmss-d7c-2026-10-01`.

The subsequent stock blank-flash erase trace stops at D3C bulk+0x2f0
(105961 unsupported reads) and six diagnostic op01 D7C/Cafebabe writes
at+0x60. The measured D7C result read no longer stops this trace. Stock
restored still waits eight times for NAND; the bounded harness intentionally
exits1 and reaps its owned processes. Full restore, restored cold boot, and
durable subsequent writes remain unqualified.

## Published-generation admission regression corrected

Review found a regression in2137e27: treating the entire generations container
as mutable rejected a supported immutable base inside a published generation.
The compiled baseline fixture reproduces invalidPath(generations).
App dd9d66a separates container confinement from disjoint writable leaves,
allowing immutable published descendants while rejecting a base equal to or
above the container, mutable/base overlap and foreign generation symlinks.
Pending edit admission still requires explicit recovery authorization.

All24 actual HostRuntime tests pass. This is a path-admission correction;
the broader asynchronous storage transaction migration remains unqualified,
including newly exposed lease-release lifetime failures. Earlier receipts
are retained, with the new failing baseline and passing fixtures at
`/Users/shg/Developer/ltm-evidence/host-generation-policy-2026-10-01`.

## D3C status accumulator qualified

QEMU04ae5b5820 retains the measured D3C zero initializer and register-write
forms, sequencer readback and CPU diagnostic reads. Unsupported encodings
still stop before downstream stores. It accumulates guest-computed bits;
no auxiliary status, ECC result or completion is fabricated. Reset and
VMState v12 retain the scalar independently of D7C and older parameters.

The actual-source baseline fails readback. Six sanitizer checks, all12 model
suites (FMSS21/21), real v11 incoming migration, and independent native8/8
pass. Both native boots end in guest-confirmed shutdown; persisted bytes
match after reboot and fsck_hfs reports a valid volume. Existing graphics
additions and legacy CPU storage execution remain in use. Evidence:
`/Users/shg/Developer/ltm-evidence/fmss-d3c-2026-10-01`.

The next stock blank-flash erase trace reaches D24 at bulk+0x308
(106343 unsupported reads), plus eight unsupported diagnostic immediate
D7C writes. The D3C read no longer stops this trace. Stock restored still
waits eight times for NAND; the harness intentionally exits1 and reaps its
owned processes. Restored cold boot and durable physical writes remain
unqualified.

## Register left shift preserves the accumulator

QEMU280e4584cd corrects the observed opcode13 zero-immediate form to shift
the existing destination by the source register count. Stock read/status
programs use it to derive chip-selection bits. Nonzero-immediate behavior is
unchanged. Counts32 or above explicitly stop as an unmodeled form; this is
a model limitation, not a claim about hardware rejection. Chip0..3 and
high-bit/count31 cases are fixture inputs, not captured live descriptors.

The compiled baseline loses the zero-count destination. Six actual-source
sanitizer checks,22 FMSS model tests and independent native8/8 pass,
including guest shutdown, reboot persistence and fsck_hfs. D3C VMState v12
and other hardware contracts remain unchanged. Evidence:
`/Users/shg/Developer/ltm-evidence/fmss-register-shl-2026-10-01`.

The subsequent bounded stock blank-flash erase trace still reaches D24
at+0x308 (106118 unsupported reads) and seven diagnostic immediate D7C
writes. Stock restored waits eight times for NAND; the intentional
research-stop exit1 reaps owned processes. Physical controller execution,
full restore and restored durability remain unqualified.

## D24 integration deferred after two native boot failures

A bounded D24 CPU address-latch/read proposal passes six sanitizer gates,
all12 model suites (FMSS23/23), and real v12 incoming/v13 roundtrip checks.
It is nevertheless unqualified: both3.1.3 and2.1.1 native boots fail iBoot
VFL context loading and enter recovery. Root stopped/reaped both owned
harnesses with interrupt130 after confirmed failure; the remaining guest
checks did not run. No passing native gate or full firmware capability is
claimed. An initial migration helper omission is also retained separately.

Two independent actual-interpreter proofs isolate an earlier new mutation:
D24=0 bypasses optional counters, then shipping iBoot's newly reached
FMC60/64/68 stores overwrite valid12-byte spare metadata already loaded by
the legacy CPU D38 shortcut with0/0/ffff0000. D2C read at+0x480 is later.
The proof uses known synthetic RAM metadata, not a raw native memory capture.
The latch itself is not disproven; incomplete controller execution and
duplicate transfer ownership make its integration unsafe.

The exact seven-file candidate and failed receipts are preserved, and only
that candidate was withdrawn from production. The verified source remains
280e4584cd; D24 has no production commit or source pin. Required next work
is one measured NAND transfer owner and command/CE/row/column/read-data
transport. Mirroring the last CPU-loaded spare, suppressing guest stores,
or inventing successful ECC results would conceal the boundary problem.
Evidence: `/Users/shg/Developer/ltm-evidence/fmss-d24-deferred-2026-10-01`.

## D7C literal initializer qualified; older-firmware failures classified

QEMU43858b7318 implements the observed opcode01 literal write to D7C,
retaining the register-write form and limits for other registers. The
initializer is present in five inspected stock kernels; it supplies an
immediate value rather than a source register. No D24, FIFO, ECC, shift14,
DMA or completion change is combined. VMState v12 remains unchanged.

The compiled baseline fails initializer readback; six source/sanitizer
checks and22 FMSS tests pass. Independent3.1.3 native checks pass8/8.
A broader2.1.1 comparison against exactly the previous280e source and the
same untouched base yields the same3pass/5fail in both: boot, reboot
persistence and agent transport pass; fsck_hfs reports minor header repair,
and incompatible IPA verification blocks install/launch/graphics/audio.
This is not a passing2.1.1 gate. The base independently passes read-only
fsck. Default Harness/GLTest minimum OS versions3.1/3.0 exceed2.1.1;
AppSync-enabled manifests alone do not establish runtime injection.

Source and candidate/baseline/rebuilt executable hashes are kept separately.
The diagnostic wrapper ignores main's return value, so results.json and
actual checks are authoritative rather than its shell exit code. The committed
rebuild stock erase trace reaches only the known D24 stop at+0x308
(105600 occurrences), with no remaining D7C initializer diagnostic. Stock
restored still waits eight times for NAND; intentional research-stop exit1
reaps owned processes. Restore completion/cold boot/durability remain
unqualified. Evidence:
`/Users/shg/Developer/ltm-evidence/fmss-d7c-initializer-2026-10-01`.

## Older HFS alternate-header and raw NAND representation leads

Matched2.1.1 baseline and initializer-candidate volumes both have a stale
alternate HFS header: primary catalog allocation3047 blocks versus
alternate999. Debug read-only fsck reports this exact disagreement and
invalid alternate VHB; both primary headers carry the unmounted bit and
other checker status categories are zero. The untouched base independently
passes read-only fsck. No alternate HFS header appears anywhere in either
persisted overlay. Guest emission, actual FTL destination and dispatch order
still need measurement; no header copy, repair or forced clean bit is a fix.
The11-block GPT/HFS trailing-size difference remains an uncertain lead.

Pinned adjacent-platform openiBoot code uses4096-byte main/128-byte raw
OOB for B614D5AD and separately ECC-decodes12-byte metadata. Opaque target
chip-table fields offer matching geometry evidence but their consumer still
needs naming. Our64-byte backing and12-byte guest view are therefore not
qualified raw-OOB representations. Generic QEMU NAND command/pin logic is
a reuse starting point; current2K maximum, ID/geometry, timing and backing
limits prevent treating it as a drop-in target controller. Exact8720 ECC,
encryption and data-window contracts remain unmeasured.

Textual diagnostics, pinned primary sources and limits:
`/Users/shg/Developer/ltm-evidence/nand-boundaries-2026-10-01`.

## Genuine 2.x fixture acceptance separates ABI from hardware failures

Private Harness and ES1 GLTest fixtures were rebuilt against actual SDK2.0
APIs with ARMv6 legacy ABI conversion and independently audited imports and
load commands. Merely lowering MinimumOSVersion on the3.x fixtures would
leave unavailable APIs and incompatible relocation/startup conventions.
The Harness uses guest AudioQueue stereo PCM; compressed audio and media
query controls remain explicitly unsupported in this private variant.
These prototypes are not yet maintained production fixture selection.

On QEMU43858b7318 rebuilt executable b004277e835e, the actual2.1.1 native
run passes6/8: boot, install/list, foreground launch, two-boot persistence,
agent binary transport and measured stereo audio (6.46s,440/880Hz). Both
shutdowns are guest-confirmed. Filesystem consistency still fails; strict
graphics qualification still reports three bridge refusals since boot
(first-buffer, nextbuffer and unknown drawable). Nothing is skipped or
converted to an expected failure; harness exit1 matches results.json.

This resolves the earlier fixture incompatibility classification without
claiming the graphics or storage model is correct. The graphics callback's
CoreSurface locking contract and the stale alternate HFS header's actual
block-write path are being measured separately. Text-only evidence:
`/Users/shg/Developer/ltm-evidence/ios211-compatible-fixtures-2026-10-01`.

## Async firmware tools and owned cancellation qualified

App bf72e7416c replaces the synchronous semaphore bridge with awaited
Swift Subprocess calls through firmware preparation, HFS mount/export/edit
and storage publication. StorageGeneration is an actor with explicit overlap
refusal and record/storage rechecks after suspension. Owners keep exclusion
through awaited teardown and close explicitly; retained aliases become closed
owners. StorageLease releases flock before closing its descriptor, so a
transient pre-exec inherited alias cannot extend an ended ownership scope.
The unused StoppedStorageLease adapter is deleted; callers and tests use the
actual shared record owner. No alternate process framework was introduced.

The CLI uses one native ordered stream writer for stdout and resource-owning
diagnostics. A closed or blocked pipe cannot prevent child/disk teardown.
Actual closed-parent-pipe testing first exposed a Foundation stderr SIGABRT
before cancellation; that failed receipt is retained alongside the fixed
real CLI tests. Normal output is awaited. Cancellation diagnostics are best
effort: stopped streams can discard queued lines even for healthy consumers;
cleanup failure is observable as exit1 and retained staging. SIGINT/SIGTERM
retain the CLI's existing143 cancellation policy.

HostRuntime29/29, storage/module contracts21/21, helper admission5/5 and
actual HFS cleanup/metadata3/3 pass. The real GUI/helper/service/CLI builds
pass. Ordinary-executor64-command progress, typed cancellation/reaping,
blocked stdout/stderr, closed parent pipes, parent death and cleanup-failure
gates pass. No thread-pool tuning or test sleeps were added to mask failures.
Earlier adapter/lease failures and a wrong-manifest test-fixture failure remain
documented; deleting the unused adapter does not establish their compiler
cause. Attachment compensation assumes serialized ownership of a given image
and does not claim to distinguish unrelated concurrent same-image attaches.
These host tests did not run a guest or qualify current QEMU dylib packaging.
Evidence: `/Users/shg/Developer/ltm-evidence/host-async-runtime-2026-10-01`.

## Checked sequencer memory transactions qualified

QEMU340978ff58 checks actual address-space results for eight-byte instruction
fetches and opcode11 four-byte stores, with explicit little-endian wire bytes.
Any non-MEMTX_OK result stops interpretation rather than executing subsequent
instructions using failed data. Earlier instructions and any partial effects
of the failed transaction are not rolled back. This does not supply an abort
IRQ contract: C00's existing completion behavior remains unchanged, and CPU
NAND descriptor/data transactions remain separately unchecked. No D24, ECC,
FIFO, flash execution, timer or VMState change is included.

The actual-source baseline compiles then fails separate fetch/store assertions;
seven source/sanitizer gates,12 model suites and23 FMSS QTests pass. QTests
exercise normal byte output, failed initial/mid fetch and unmapped stores,
preserving earlier writes and preventing later sentinel overwrite. Native
3.1.3 checks pass8/8 with no skips: guest-confirmed shutdowns, cold reboot
persistence, clean fsck, installation/foreground, graphics, agent and stereo
audio (6.45s,440/880Hz). Candidate99769a9c674b and committed rebuild
ba38dfefdce6 executable hashes are recorded separately. The app source pin
now names340978ff58; full restore and updated dylib/release packaging remain
unqualified. Evidence:
`/Users/shg/Developer/ltm-evidence/fmss-checked-dma-2026-10-01`.

The committed checked-DMA stock blank-flash erase probe still stops only at
D24+0x308 (59028 occurrences), with no checked-transaction error before that
stop. Stock restored waits eight times for NAND; research-stop exit1 reaps
owned processes. Counts are trace observations, not an execution-rate or
performance comparison. Full restore remains failed.

The current arm64 dylib was relinked from340978ff58 (SHA256 acf1f57659a4,
UUID AEE4DBA6-695D-3965-BA55-EDC226DDC500). The real production helper
passes5/5 hello-only lease admission/refusal cases with this dylib; no boot
request is sent. This updates local build identity, not universal packaging,
Intel runtime, signing/notarization or native dylib guest qualification.

## N72 partition extent correction qualified

App0b43f26 and QEMUb2090969d4 remove the synthetic11 allocation blocks
beyond the supplied HFS extent in both maintained preparers. Protective MBR,
NAND format, freepool and filesystem contents remain unchanged. The low-level
writers consume caller-supplied counts; the preparation paths validate or
derive the actual HFS extent. This is not an arbitrary backing-file parser.

The original2.1.1 trace correlated primary-header writes with FMSS KEEP but
observed no alternate update. Near-target public XNU1228.7.58 explains why
excess partition slack disables the alternate location; it is not identical
to the shipping1228.7.27 source. Controlled private clones changed only two
GPT metadata pages and their CRCs. The actual2.1.1 guest then emitted its
alternate-header write, matched to FMSS KEEP. Unpaused2.1.1 and3.1.3 runs
both pass boot/persistence/fsck3/3, with two clean guest shutdowns and matching
catalog sizes. The earlier debugger/input race remains a failed diagnostic
run, not native qualification. No header copy or repair supplied the result.

Swift geometry/CRC/golden gates, Python12-size selfcheck and native-fixture
page comparisons, actual DeviceRow12-lock policy cases and GUI/helper/service/
CLI builds pass. Exactly22 N72 catalog recipes move to revision2 so existing
bases request Prepare Again. No automatic migration of user images occurs;
Erase with an existing base does not rebuild it.4.x native qualification and
an offline migration for old bases remain separate work. Evidence:
`/Users/shg/Developer/ltm-evidence/nand-boundaries-2026-10-01`.

## Legacy graphics first divergence

QEMU75704ad744 balances CoreSurface locks and ownership across the stock2.x
callback lifetime; actual callback sanitizer tests and3.1.3 native5/5 pass.
The2.1.1 mapping now has real dimensions/stride/base and clears the
previous surface-contract refusal, but its graphics gate still fails. QEMU a85802ffb8 strengthens that
gate to require the known inset cyan/magenta/yellow scene geometry in both
samples: equal total color areas cannot qualify striped or packed scanout.
Retained3.1.3 frames pass, and retained2.1.1 frames fail this geometry check.

Stock2.1.1 programs plane1 control, then reads it to OR in rotation. With the
native default lcd-planes option off, the model's missing+0x40 readback returns
zero, which the guest writes back. Stock3.1.3 constructs rotation before its
initial write and avoids that read. QEMU8e9fac00f6 supplies the narrow register-latch readback. Actual-handler
sanitizer reproduction,13 model suites and five LCD QTests pass, including
reset, existing VMState off/on roundtrips and N45 mapping. No zero-format reinterpretation or guest
patch is justified. Evidence:
`/Users/shg/Developer/ltm-evidence/coresurface-lifetime-2026-10-01`.

The combined private exact-GPT/preboot-CoreSurface candidate passes all eight
3.1.3 native checks, with two guest-confirmed exit0 shutdowns, clean fsck,
durable reboot writes, correct scene geometry and6.45s440/880Hz audio. The
same frozen executable88ba2cd4e414 runs2.1.1 at6/8: boot,fsck,installation,
foreground,agent and6.76s stereo pass; graphics is black in the correct inset
and gesture shutdown times out, so persistence explicitly fails. Fsck0 after
that forced teardown does not certify clean shutdown or durability.

Live qom-get confirms lcd-planes false. The failing2.x run never programs
plane1; its zero latch therefore reads identically in baseline/candidate. Its
black pixels are already in the flat CoreAnimation framebuffer, so this run
does not establish native exercise of the measured plane1 RMW correction or
causality for the change from earlier stripes. Identical installed GLTest and
guest-addition hashes are verified; two late context/batch refusals occur in
both old and new traces and need exact packet/interval attribution. Do not
reinterpret format zero, reorder planes, or reset counters to pass the gate.
Evidence: `/Users/shg/Developer/ltm-evidence/lcd-control-readback-2026-10-01`.
The source pin now includes cf196aefd1 (LCD8e9fac00f6 and maintained fixtures); current arm64 dylib still represents340978ff58
until relinked. Universal packaging/native dylib guest qualification remain
unverified.

## Maintained fixture eligibility and offline linkage

QEMU c27bb514f5 accepts separate installation IPA, audio Harness, GLES app
and slot-map inputs. Declared full numeric deployment versions are checked
before output/overlay creation or guest/service launch. Seven meaningful
preflight tests and registry validation pass, including malformed XML,
multiple IPA apps, unknown explicit guest versions and incompatible patch
versions. Actual old3.x Harness is rejected for2.1.1; the genuine privateSDK2
fixtures pass declared eligibility. Eligibility does not prove API or runtime
compatibility; historical raw-NAND defaults without a declared version retain
the earlier unchecked behavior.

App648a471 links23 existing offline probes to the actual shared HostRuntime
module, with separate package outputs for explicit compiler targets. All23
compile and execute, including arm64 and x86_64 under Rosetta. Four native
window/capture/media tests need normal macOS access; sandbox-only failures
are retained alongside successful native retries. No production Swift logic,
replacement app types or assertions changed. Native Intel hardware is not
qualified by the Rosetta result. Evidence:
`/Users/shg/Developer/ltm-evidence/host-runtime-2026-10-01/offline-module-linkage`.

## Maintained SDK2 fixture backend qualified

QEMUcf196aefd1 adds an explicit isolatedios2 fixture flavor using the actual
SDK2.0, compiler API target2.0 and existing legacy ARMv6 link conversion.
Harness uses AudioQueue PCM callbacks on UIKit's run loop with explicit
failure/cleanup ownership; AVFoundation initialization is excluded in that
flavor. Unsupported compressed playback, MPMediaQuery and UIPasteboard
controls report their limits. Full3.x source still builds to the identical
signed executable under the unchanged default flags.

Both ios2 fixtures compile, sign and pass static ARMv6/entry/load-command/
SDK-import audits. Their temporary SDK linker stub has a fresh owned directory
with cleanup on success/error; pre-existing output children survive. PCM
ASan/UBSan tests cover enqueue/read/alignment failures, failure before Start,
retained failed-dispose ownership and idempotent close. Actual binary mutation
audits reject PIE/subtype/entry/import changes; the manual audit requires
explicit SDK and binary inputs rather than passing for missing assets.

The new maintained Harness passes seven selected native2.1.1 checks, with no
skips: boot,fsck,persistence,installation,foreground,agent and6.46s stereo
440/880Hz audio. Both guest-confirmed shutdowns exit0 and reboot preserves
the written bytes. GLES was deliberately a separate contract: this backend
qualification does not replace the full2.x run's black scene/shutdown failure.
GLTest's rebuilt executable is byte-identical to the prior genuineSDK2
fixture. Ordinary full-workflow graphics remains unresolved; all2.x/3.0 firmware
runtime is unqualified. Evidence:
`/Users/shg/Developer/ltm-evidence/maintained-ios2-fixtures-2026-10-01`.

## Fixture selection and graphics lifetime investigation

QEMUeeccc6abe5 selects the isolated ios2 fixtures for declared2.x devices,
preserves independent explicit overrides and the default SpringBoard graphics
leg, and refuses missing requested legacy artifacts before launching a guest.
It also fixes internal parser flags leaking into ledger child arguments.
Six selection/receipt/actual-ledger tests and the seven existing deployment
preflight tests pass. Each run writes a separate requested-input hash receipt;
selection and deployment declarations do not expand native qualification.
Evidence: the maintained fixture archive's `selector` directory.

The corrected temporary graphics observer passes the full2.1.1 workflow8/8,
including strict scene geometry, two clean exit0 shutdowns, reboot persistence
and fsck0. App and CoreAnimation captures match host/guest pixels exactly, and
the stock plane1 control read-modify-write preserves00310700. This diagnostic
does not reproduce the prior normal executable's sustained black inset and
shutdown failure; extra diagnostic I/O may alter a race. Graphics is therefore
not declared fixed. Earlier observer-v1 app guest comparisons had a doubled
address offset and are excluded; the corrected extracted observer passes
ASan/UBSan tests against the actual ARM translation API contract.

The diagnostic separately identifies stale cached graphics-context pointers:
surface cleanup sends framebuffer/texture deletes after the context is freed.
That is a concrete guest-addition lifetime lead, not evidence that it caused
the earlier scene failure. Instrumentation was removed, and original source,
objects and the qualified88ba executable were restored and hash-verified.
The full diagnostic, corrected pixel analysis and retained failure boundaries
are archived at
`/Users/shg/Developer/ltm-evidence/gles-contract-diagnostic-2026-10-01`.

## CPU NAND transaction results qualified

QEMU32f131195e checks actual AddressSpace transaction results in the remaining
CPU-side NAND compatibility transfers. Failed descriptor reads are not decoded
or consumed; failed data/metadata writes stop later transfers. Earlier writes
and partial effects of the failed transaction remain. Target descriptors decode
LE32 only after successful reads. Original address arithmetic, RAM-only write
source admission, fatal write-source policy and controller completion behavior
are preserved; this does not make the compatibility path physical NAND.

All eight FMSS source/sanitizer suites pass, including twelve adversarial CPU
DMA cases. Baseline compiles but fails nine of those cases. Actual FMSS QTests
pass25/25 and all thirteen registered model suites pass. Real tests cover
unmapped descriptors/destinations, prior complete-page preservation and a
partial write crossing the actual mapped RAM end. A mapped transaction returning
an error is covered by actual-handler doubles, not a real error-returning device.

The frozen7eb0664b executable passes all eight native3.1.3 checks and seven
selected2.1.1 checks, both with two clean exit0 shutdowns, persistence and fsck0.
The2.x run also exercises automatic default fixture selection; the rebuilt
Harness and GLTest executables match the qualified maintained artifacts exactly.
That seven-check run supplies no GLES qualification; the later full EGL ownership
workflow below supplies its separate eight-check evidence.
Evidence: the NAND archive's `cpu-dma-checked-candidate` directory, including
native logs and input receipts. No new physical restore, ECC, IRQ or dylib
qualification is claimed.

## Dead host failure channel removed

App2446f86 removes an unused private failure map/method from DeviceSessionHost
and the corresponding DeviceRow argument/branch. Actual session `.dead` and
preparation `.failed` remain the error authorities. Five constructor/UI probes
retain their retry and failed-import assertions and pass; the actual GUI and
device/service helper Debug build also passes. An initial SwiftUI macro sandbox
denial is retained beside the authorized native retry. Evidence:
`/Users/shg/Developer/ltm-evidence/session-failure-cleanup-2026-10-01`.

## EGL surface ownership corrected

QEMU f00997c13c makes each EGL context track surfaces whose cached texture and
framebuffer names reference its graphics context. Context destruction releases
those names while the context is live and detaches surviving surfaces, which
can then be rebound safely. Both unchanged frontend sources compile and
reproduce a heap-use-after-free under ASan; the corrected actual callbacks pass
context-first, surface-first, multiple-buffer, rebind and window teardown tests.
Existing frontend/export/CoreSurface tests and the native CGL context test pass.

The normal standalone executable with privately staged additions passes all
eight native checks on both 2.1.1 and 3.1.3, including strict scene geometry,
two clean shutdowns, persistence and fsck0. This does not establish the cause of
the earlier intermittent black inset. Native 1.x qualification remains partial:
1.1 repeat candidate and unchanged baseline both show a stock Wi-Fi dialog and
fail the strict Safari reference, while an earlier baseline passed. The 1.1.5
candidate passes boot but fails the swipe reference with a different rendered
icon layout; the unchanged same-version baseline reproduces the same mismatch. No prompts, thresholds,
or counters were altered to pass these checks. Stock 1.x does not import
`eglDestroyContext`, so its native runs do not exercise the repaired ordering.

Evidence: the CoreSurface archive's `egl-owner`, `egl-owner-n45-repeat-controls`
and private-fixture receipt directories. Concurrent EGL use, deferred context
destruction, current dylib builds and release packaging remain unqualified.

## Cancellation-resistant helper exit wait

App2b56949: the actual DeviceProcess waiter now uses a monotonic deadline in an awaited,
independent MainActor task so an already-cancelled caller does not turn each
sleep into immediate error polling. The wait remains bounded, returns false
while the helper is still live, and leaves DeviceLink as the exclusive reaper.
No detached task, extra process owner or replacement reaper is introduced.

The unchanged actual adapter used about425ms of CPU during a one-second
cancelled wait; the corrected maintained gate observed about3ms on this host.
This is a measured polling correction, not evidence of a blocked main actor:
heartbeat callbacks remained responsive in both cases. Eight hello-only cases
cover normal/pre-cancelled/mid-cancelled waits, actual exit, zero/negative bounds,
live lease exclusion, exclusive reaping and injected failure cleanup. Existing
helper admission and preparation-failure gates and the GUI/helper build pass.
Explicit artifact/source hashes separate the old340978 dylib's hello-only
admission from native standalone guest qualification. No guest is booted by
this gate, and missing explicit helper/dylib inputs do not claim success.

Evidence: `/Users/shg/Developer/ltm-evidence/host-exit-wait-2026-10-01`.

## Measured NAND descriptor-pointer writes

QEMU f2ea5bde6d accepts the stock opcode02/immediate-zero sequencer write to
its existing D10 descriptor-pointer latch. Captured stock scripts advance the
pointer by four after a descriptor load and rewind it on their retry path;
previously the model silently discarded the write and reused the first word.
Unmeasured opcode01/nonzero forms stop before later DMA or stores. This changes
no physical command, decoded-spare producer, CPU storage interception, interrupt,
completion, reset or migration layout.

The compiled actual-handler baseline fails the second-descriptor assertion;
the corrected ASan/UBSan suite sees distinct words and addresses forward/backward.
All eight FMSS source suites,27 real controller QTests and13 registered model
suites pass, including existing-latch snapshot/reset and unsupported-form refusal.
The frozen0f9f1bf7 standalone executable then passes all eight native checks on
both2.1.1 and3.1.3, with strict GLTest scene, stereo audio, two clean exit0
shutdowns, a durable guest marker and fsck0. Static driver analysis finds fresh
CPU D10 setup before D38 starts; every dynamic callback ordering is not measured.
The latest retained stock physical-restore trace stops at D24; the withdrawn
latch candidate exposed the unresolved decoded-spare ownership seam.
No full restore or stock FTL replacement follows from this scalar correction.

D10 evidence: NAND archive directories `d10-model-qualified-candidate` and
`d10-native-qualified`. The separate unchanged 1.1.5 control also fails its
shared 1.x swipe reference with the same stock icon grid; candidate/control
pixels below the status bar match exactly. Its strict failure remains unwaived,
with receipts under the CoreSurface archive's
`egl-owner-n45-4B1-baseline-control` directory.

## Source pin and current development artifact

The app pin advances to QEMU f2ea5bde6d7cc9e2899def437f5cb32cbfd86dd1;
the unchanged compatible usbmuxd pin remains e19fac2d4b. The resolver verifies
both isolated worktree HEADs. Relinking the development arm64 dylib succeeds;
its SHA is f78258570b00051b4434a67dc13980278753e7063b22e91610bee230da68034c,
UUID4FED5CBE-61E5-3DA9-863C-A2309D578E91. Eight actual helper hello-only
lifecycle cases pass with that artifact, including failure cleanup; no boot is
sent. Evidence: the host-exit-wait archive's `current-dylib-admission` directory.

The rebuild regenerates the committed source version and changes the standalone
hash to575ffb13. Native D10 qualification belongs to frozen0f9f1bf7, with the
same committed hardware source hashes, rather than automatically transferring
it to the rebuilt artifact or app-facing main loop. Current dylib native guest,
Intel/universal, signing/notarization and release gates remain separate. No
target merge, publication or installation occurred.


## Observational MBX interrupt status

QEMU20d98f5898 removes the STATUS read side effect which cleared pending events
before the stock7E18 ISR's explicit enabled-mask W1C acknowledgement. No new
completion, startup, EVM, GPU execution or timer behavior is supplied. Actual
handler negative controls reproduce event loss; four real production-board
qtests cover pending/masked events, VIC IRQ, reset and migration. ASan/UBSan and
all fourteen registered model suites pass. Normal frozen71f6258b standalone
runs pass8/8 on both2.1.1 and3.1.3, each with strict GLTest, stereo audio,
two guest-confirmed exit0 shutdowns, identical durable markers and fsck0.
Owned processes are reaped. The executable is separately identified from the
older f7825857 development dylib. Evidence:
`/Users/shg/Developer/ltm-evidence/mbx-status-readback-2026-10-01`.

## One imported process owner

App fecd7a7 packages the existing canonical transport and new profile-neutral
DeviceSessionProcess in DeviceRuntime at Shared/Package.swift. GUI DeviceProcess
now owns presentation, log capture and geometry notices. Production helper,
GUI, session CLI and hello-only lifecycle probes import the same owner;
Xcode source exclusions prevent a second transport/CLink compilation.
Transport behavior is byte-identical after the public ABI declarations and DTO
initializers are accounted for. No parallel spawn/reap implementation is added.
Actual arm64 GUI/helper/client builds, lease5/5, cancellation8 cases, preparation
failure, real-module death classification, GUI labels and affected offline
package/service/audio/boot/model checks pass. Initial sandbox/build exclusion
and missing-import failures are retained separately. All processes are reaped;
no guest, universal/Intel, signing or release qualification is claimed.
Evidence: `/Users/shg/Developer/ltm-evidence/shared-process-owner-2026-10-01`.

## Exact-build visual coverage admission

QEMU91487b886d shares iPad/iPod visual-reference validation and requires the
exact board, build, full product version, independent software/physical
provenance and PNG hash. The old major-version icon layout is no longer borrowed,
and missing visual coverage fails before output creation or guest launch.
Actual-gate tests reject all-liveness-green but unqualified scenes; both board
reference suites, six selector cases, seven fixture-preflight cases and the
unchanged flipped/stale/red-blue frame mutations pass. Existing1.x Wi-Fi and
1.1.5 grid failures remain historical evidence, not waived rendering verdicts.
Independent exact1.x software reference captures remain pending qualification;
no candidate GL frame is promoted to its own oracle.


## D0C address-word producer

QEMU af4c040cb8 accepts only the captured opcode02/immediate-zero write to the
existing D0C scalar latch. Stock5F138 and7E18 bulk scripts load a descriptor,
advance its pointer and feed FMC address-register words; discarded writes
previously repeated the first descriptor. READ-ID still uses the same scalar
for chip selection, so no universal row-address meaning is assigned.
Actual-interpreter negative baseline, eight ASan/UBSan suites,29 controller
qtests and all14 registered model suites pass. Frozen2b4ae15b standalone then
passes full8/8 native checks on both2.1.1 and3.1.3, with two guest-confirmed
exit0 shutdowns, strict GLTest/stereo audio, byte-identical durable marker and
fsck0. All owned processes are reaped and source/executable hashes preserved.
D24, raw/decoded spare ownership, flash commands and completion are unchanged;
physical restore remains unsupported. Evidence: NAND archive's
`d0c-scalar-producer` directory (68 bounded hash-inventoried files).

## Probe build responsibility

App7a3f23b restores independent HostRuntime builds for38 pure-host consumers;
13 device consumers import DeviceRuntime explicitly. One small SwiftPM product
routine supplies build/link paths. Six affected probes no longer compile a
second canonical DeviceLinkProtocol source beside the imported ABI. Eleven
headless logic groups pass and a cold package copy builds/imports HostRuntime
without Shared or DeviceRuntime artifacts. Four recording/model probes, actual
media driver/recorder, exit-wait and both host target slices compile/link;
those compile-only executables were not launched and prove no new guest/media
runtime capability. The initial sandbox Subprocess manifest failure and failed
private cold fixture are retained separately. Owner/transport ABI is unchanged.

The first private1.1 software-control attempt changed only LK_ENABLE_OGL1→0,
but native evidence still contains two GL contexts and one front-end hello.
Its frames are rejected as independent goldens. The explicit provenance guard
failed before any committed reference was supplied; stock configuration and
possible file/runtime override are being investigated. No rendering threshold,
Wi-Fi modal or missing coverage is waived.

## D20 main-address producer qualified (October 2)

QEMUe2ce2d7b1d accepts the captured opcode02/immediate-zero write to D20.
Stock bulk scripts fetch the descriptor's main-address word for FMC34 and
advance the pointer. Actual-interpreter negative baseline, eight sanitizer
suites,31 FMSS qtests and all fourteen registered models pass. Frozen
383dc2781a7288d590ac264225bcc45f1eadf3d10cd9001dd9df10971c77d5dd
standalone passes separate full2.1.1/3.1.3 native8/8, with strict graphics/audio,
two guest-confirmed shutdowns, durable marker and fsck0. Source/artifact hashes
and65 bounded files are retained in the NAND archive's d20-scalar-producer.

The stock physical restore remains Waiting for NAND at D24. Stock FMC40
sequences poll then consume FMC60/64/68 into spare buffers; neither the
physical OOB-to-decoded representation nor its producer is established.
D24's withdrawn candidate is not restored, and fixed READ-ID words are not
reused as fabricated bulk data or completion.

## Seed ownership and exact1.x independent controls (October 2)

QEMU1837635068 and app4f16464 record each seeded hook only after successful
installation, saving ownership after each success. Filtered, omitted and failed
copies remain unclaimed; earlier successful hooks survive a later copy failure.
The actual guest it_boot ASan/UBSan baseline fails restoration, while fixed
restoration, filtering, failure and rollback tests pass. Native Swift Testing
N72Tests.frontEndMatchesPython passes with the real armv6 offer/5F138 corpus.
Thirty-seven recipe revisions (24K48,6N45,7N72) trigger Prepare Again; fifteen
N72 4.x stub/no-hook recipes stay unchanged. Payload/loader serials are unchanged.
Durable source/text evidence: seed-hook-bookkeeping-2026-10-02 (20 content files).

The first1.1 LK-only control remains rejected. Corrected private controls
disable the stock CA/LK flags and let the guest loader restore the original
OpenGLES.baked through its documented ownership state, preserving other hooks.
Both stock1.1/3A101a and1.1.5/4B1 captures show zero GL contexts/hellos and
logged stock restoration. Framework backups are traced to prepared original
inputs, not fresh independent IPSW extraction. Identity, modes, spares and
unchanged source hashes are recorded; these boot-only captures make no clean
unmount or durability claim. The1.1 Safari Wi-Fi dialog and1.1.5 Bookmarks
state are retained as captured, with no dismissal or added mask.

QEMU4a15968526 commits exact board/build/full-version references and requires
a nonempty numeric full version. Reference downsampling uses the unchanged
64x96 BOX algorithm. Flip, channel swap, stale-scene and borrowed-build
mutations fail. Normal GL candidates on both builds pass Boot/GLES2/2 and
all three scene differences are0.000, with no diagnostic observer or LCD
trace. Both attach the frozen383dc278 artifact, not the later rebuilt dylib.
Durable n45-independent-controls-2026-10-01 contains50 hash-verified bounded
content files, including unchanged rejected-control evidence. This supersedes
the earlier pending exact1.x coverage status, not its historical failures.

## Shared runtime through an actual guest (October 2)

Current development arm64 helper and QEMU3c85a3803e dylib pass the actual
2.1.1/5F138 session18/18. GUI and session driver import the same DeviceRuntime
owner. Two boots confirm Home, activation, factory identity, AFC transfers
(16384,16385,65536,1048583bytes), installation and foreground identity. Two
PMU-confirmed shutdowns end with helper exit0; the marker is byte-identical
and the app survives cold boot. Prepared base size/mode/mtime are unchanged.
The driver exits0 and read-only checks find none of its recorded driver/helper/
usbmuxd PIDs alive. This guest receipt does not independently assert ECHILD.

Exact artifact SHA256: dylib
a95cf1b89e485fdb4ec1db015df1c0a0175ff74b426c00596179ef67b2017a06;
helper49c5d73248539cd5c0ba885fc921680a5970a44702df9db30297c858dfb06bde;
services3217d6066f13fab219f3bf439b99dc56cf228dcd8ff4f2c85178703276309a87.
The rebuilt standalone da512148 is not promoted from the earlier frozen
383dc278 standalone proof. These are development arm64 artifacts, not a signed
universal release, Intel-native qualification, strict scene/audio gate, stock
GPU implementation or physical restore. Durable evidence:
/Users/shg/Developer/ltm-evidence/final-shared-runtime-2026-10-02
(42 hash-verified source/text/UI files). The old f2ea hello-only artifact receipt
is historical and superseded for this scoped current guest capability.

## Production original-file provenance and loader14

QEMU c23c72542e and app126ba26 fix the real installer→seed ordering: the
OpenGLES installer preserves firmware-original bytes/mode before replacement.
A cache-only original uses an empty .baked-absent marker. Existing provenance
is immutable; conflicting or malformed markers fail closed. Dynamic hooks
record original absence, restore it on removal and preserve it through
reinstall/rollback. A dangling original is not misclassified as absent. Custom
addition backups remain prepared baselines, not claimed Apple originals.

The pack declares loader/hook-provenance `file-or-absence 1`. Both seeders reject
missing/unknown capability before publishing an absence-dependent seed; no
serial guess or cache-to-executable reconstruction is used. Maintained serial14/
version1.1.12 exports rebuild successfully. Actual loader sanitizer tests
reproduce the old absence failure and pass restoration, dynamic install/removal,
reinstall, rollback, malformed markers, dangling original and stale capability
controls. Native Swift Testing passes four tests/three suites with five actual
production installer→seed cases:5F138/7A341 stock files and7E18/8C148/K48-7B500
cache-only absence. N72 and three K48 seed-parity cases also pass.

All52 catalog recipe revisions advance for the changed loader/preparer outputs;
old bases remain usable and request explicit Prepare Again. Twelve admission
locks and catalog-order/forwarding checks pass. N72 4.x remains a hookless seed
stub: preserving original provenance does not make its compatibility frontend
owned by the package loader. Cached-absence native rollback remains a separate
capability. Durable source/text inventory: hook-original-provenance-2026-10-02,
30 hash-verified receipts. Exports preserve their exact dirty3c85 build identity;
no clean release artifact is claimed.

## Required cleanup cannot leave an all-green run

QEMU a4445faf32 makes required first/final guest shutdown failures, execution
exceptions after completed verdicts and cleanup exceptions fail the native run.
Failure-only `_harness` result metadata and harness.json preserve stages/reasons
and artifacts; `--clean` cannot delete a failed run. Successful eight-check
counts remain unchanged, and Boot/GLES-only intentional hard stop remains
separate. Seven actual-main controls pass; unchanged-source negatives reproduced
exit0 and deleted artifacts for the final-timeout and late-exception cases.
Durable evidence: harness-final-shutdown-2026-10-02 (11 bounded files).

The observed stock-software2.1.1 control is preserved as a visual-only baseline:
verified genuine framework, zero GL contexts/hellos and first clean reopen,
but final gesture shutdown FAILED. Its old runner incorrectly returned0; this
is not a complete clean-stop qualification. Stock3.0 initially failed because
userspace UART was unavailable. The retry records that absence separately and
proves installed custom→genuine stock bytes, staged offer/state/software flags
and exact loader hash through actual guest VFS. The new armv6 loader
13c52c1218f448f0eb1e9529c9bc047b249d39d58a95ac43c8e1210e72e58861
runs with unchanged legacy seed13; both guest-confirmed shutdowns and persistence
pass2/2. This proves ABI/present-file restoration, not a fresh seed14 native
cache-only rollback. Durable control evidence: n72-independent-controls-2026-10-02;
all earlier failures and interrupted selector attempt remain distinct.

## Exact N72 frontend coverage and final source pin

QEMU038490937b qualifies exact5F138/2.1.1 and7A341/3.0 independent stock-software
references. The generic opened-app scene identifies actual Safari on2.1.1 and
Mail on3.0, preserving the unchanged first-icon tap and all captured bytes.
Existing1.x scene keys are renamed without changing either PNG. All four
build oracles reject flipped frames, channel swaps, stale scenes and borrowed
builds; existing frame thresholds/status mask are unchanged.

An explicit --gles-front-end selector is mutually exclusive with --gles-app
and preserves installed-helper provenance/default GLTest selection. Actual
selector/config/preflight tests cover9cases and7prerequisite cases, including
missing exact references before output/guest launch. A mistaken default-app
attempt was interrupted before rendering verdicts, exit130; no lock was
falsified. The frontend no longer requires usable USB merely because usbmuxd
is installed: actual-main baseline failed this negative control, fixed source
passes, and successful eight-check counts remain unchanged.

Normal candidates pass Boot/GLES2/2 on each build, with one frontend hello,
2contexts on2.1.1/3contexts on3.0, no refusals and all six scene differences0.000.
Both owned process sets are reaped. These are intentional hard-stop visual
gates, not new clean shutdown/persistence or physical GPU qualification. Native
proof attaches to Rsource ba064b0940c51d1d54d8a8ca4ac0b32bcc2619a445f91aded7a1bb00fbfad529
and frozen standalone da512148. The subsequent USB admission-only change has
separate actual-main proof; it is not retagged as a native rerun. Exact archived
native source was reconstructed privately by reversing only that condition and
matching the recorded full hash; both rejected archive attempts are retained.

Durable frontend-coverage-2026-10-02 contains29verified bounded files and
independently verifies all90entries in the linked N72 controls/native archive.
No framework binaries, keys, raw RAM or NAND were archived.

Final app source pin is QEMU038490937bdb278b0a964b819ee4abb18aa6a52a; compatible
usbmuxd remains e19fac2d4bf344f67fc05e693f8239d2b7101190. Source-checkout identity
is separate from the earlier3c85 compiled dylib/helper and frozen standalone
receipts. No latest universal/Intel/release artifact promotion, target merge,
publication or installation occurred.
