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
