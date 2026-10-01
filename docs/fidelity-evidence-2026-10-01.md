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
The2.1.1 mapping now has real dimensions/stride/base and no strict bridge
refusals, but its graphics gate still fails. QEMU a85802ffb8 strengthens that
gate to require the known inset cyan/magenta/yellow scene geometry in both
samples: equal total color areas cannot qualify striped or packed scanout.
Retained3.1.3 frames pass, and retained2.1.1 frames fail this geometry check.

Stock2.1.1 programs plane1 control, then reads it to OR in rotation. With the
native default lcd-planes option off, the model's missing+0x40 readback returns
zero, which the guest writes back. Stock3.1.3 constructs rotation before its
initial write and avoids that read. A narrow register-latch readback candidate
passes private actual-handler sanitizer reproduction; production QTests and
native qualification are pending. No zero-format reinterpretation or guest
patch is justified. Evidence:
`/Users/shg/Developer/ltm-evidence/coresurface-lifetime-2026-10-01`.
