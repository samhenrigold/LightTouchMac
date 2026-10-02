# N72 physical restore: measured first divergences

These are source and bounded native observations, not a completed physical
restore/coldboot/durable-write qualification. Root owns the native runners.

## NOR crypto correction

Stock 5F138 restore wraps signatures using UID encryption of the KDF seed.
SecureROM/iBoot preserve the AES direction bit by KEYLEN register read/modify/
write. The former zero readback lost this bit; generated NOR compensated with
decrypt-derived wrappers. Actual AES-source sanitizer tests and the stock cold
trace demonstrate the readback correction. The old 128-byte output suppression
at three guest addresses remains in production until automatic generated-NOR
migration and the firmware corpus pass. A private actual-source variant removes
it and reaches real SecureROM → LLB → iBoot385.22 from stock-restored NOR.

All four inspected readers (5F138/7A341/7E18/8C148) establish the same direction
contract. Their image-unwrapping policy depends on image-source descriptors;
major version alone does not determine wrapping. The 7E18 private control,
changing only SHSH KDF direction and preserving stage policy, passes the native
8/8 regression. Other corpus controls remain subject to native qualification.
The stopped migration planner/transaction is experimental and does not change
launch defaults: it must not claim seamless migration before that gate.

## Stock write producer

Stock 5F138 kernel Mach SHA256:
`20fa129653ad4094ce4fd885ddd1477e0ee175137c48898277c8ca7bfc3dd33f`.
The complete write script at file offset0x5c9810, size0xce8, matches the native
program0x085f2810 through its first blocked loop. Operation selector0xa02
captures the initial write without exhausting the cap on earlier reads.

At +0x100 it writes FMC40=0xc1, then +0x108 reads mask1 and +0x110 repeats while
nonzero. The model stores the command and never executes the transfer. Its
existing bit1 clearing cannot satisfy this bit0 wait. Do not clear bit0 merely
to advance the script: a completed transfer must own the result.

Three FMC60/64/68 words precede0xc1. Independently, READ-ID uses0x52 after a
five-byte flash read, then reads FMC60; auxiliary reads use0xc2 before consuming
three words. A counted bidirectional FIFO/window transfer is therefore a
specific next research contract. Exact routing and byte-count encoding still
need proof. Later write instructions issue ECC804←D30 with FMC1c=0 and then
ECC804←D2C with FMC1c=1. N72 parity polynomial/order, OOB placement, DMA and AES
ordering remain unqualified. The CPU D38 descriptor shortcut remains active;
stock RestoreFinished is insufficient to delete physical storage preparation.

The write research run's eight-Waiting-for-NAND guard killed a session that was
creating partitions/filesystems. Its consequent client read error is harness
termination, not a demonstrated restore failure.

## Initial restored coldboot fault

Private exception-entry observation captures the first DATA_ABORT at ARM PC
0x0ff1b810, FSR0x805, VA0x000f8400; LR0x0ff09aa3, r0=8, r1=0xffe0f7f6,
r2/r3=0. The instruction is a byte store in memset/bzero. Its caller is the
zeroing allocator0xff09a6c, returning from memset at0xff09a9e. Preserved r5 is
0xffffffe8: an enormous allocation request produces pointer8. The exact
allocator failure mechanism is not yet established; rounding is
`(size+15)&~7`, which keeps this particular request huge. The subsequent prefetch/vector cascade is secondary.

This does not justify an MMU change. Identify the size producer and its input
before attributing the failure to hardware or restored data. A subsequent internal-breakpoint capture now proves the producer: allocation
call36 reaches zeroalloc with request0xffffffe8, caller LR0xff06203,
r3=0xfffffffe and r10=5. YAFTL_Open computes12×this global count at
0xff061f8–61fc after its error-path doubling. The count originates in context
field[r6+0x2c], copied at0xff0576c into global0xff27108. The later bounded captures below establish that field and upstream read.
The bounded capture reaped after1.57s and read no stack or guest data.

A possible ISA research reference is
[S5L8702-FMISS-Tools](https://github.com/lemonjesus/S5L8702-FMISS-Tools/blob/main/Documentation.md).
Its physically tested ALU/branch forms corroborate decoding; wait/ECC/register
mappings are explicitly uncertain. No code or documentation has been adopted
into production (code GPL3, documentation CC BY-NC-SA).

The subsequent full write probe with the premature eight-notice guard disabled
reaches stock `Status: Restore Finished` again. It still uses CPU D38 storage
compatibility, so this is host/stock workflow progress, not physical controller
qualification.


## Context-page and READ-ID follow-up

The context-count capture now establishes the input: the first parser stop at
0xff0576c has r6=0xff60540 and the exact field at r6+0x2c contains0xffffffff.
The header comparison has already returned0xffffffbc ('erased0xff' versus 'C'
in CX01), yet the flag-zero parser path consumes the count. Its upstream read
through0xff04fe0 returned success. The underflow is therefore downstream of an
erased context page admitted by storage, not evidence of an MMU fault. The completed VFL/FIL and status captures below identify the physical
page and returned status without dumping payloads.

A private actual-source candidate executes the measured READ-ID producer:
FMC4=0xe2 receives DNUM+1 ID bytes, then FMC40=0x52/0x82 transfers5/8 bytes into
the FMC60/64 window before clearing receive-busy. Register reads no longer
fabricate ID bytes. Partial transfers preserve untouched window bytes, and a
missing or depleted producer leaves the command busy. Five actual-source
sanitizer/model suites pass, including the real7E18/8C148 scripts and enabled/
disabled trace parity. The candidate is now staged after baseline verification. All32 actual-board
FMSS qtests pass; the missing-producer test also rejects the retained pre-fix
binary. The current combined7E18 binary now passes all8 native regression
checks, two actual PMU-confirmed clean shutdowns and durable cold-boot
persistence/fsck. This is a combined-build qualification, not an isolated
FIFO binary.
FMC40=0xc1 NAND write, ECC results and raw OOB routing remain unsupported by this
candidate; they must not inherit a success status from the ID implementation.

Common FirmwareKit boot admission and the retaining-owner transaction API now
hold the same stopped-storage authority through migration and refreshed-record
validation. The CLI is `firmwarekit boot-admit --device DIR --record-policy
managed|standalone [--allow-raw]`. Twenty targeted tests and six actual CLI
checks pass, including refusing concurrent leases, pending intents and implicit
raw-device admission. The production qualified-build set remains empty until
the native corpus gates pass; the automatic migration is implemented but gated.

## Erased-read status contract and private candidate

The subsequent concrete VFL/FIL captures map logical context page0x3e9 to
chip1/page0x7a07d. The overlay has no page at that physical location, and the
actual FIL return is success. At the status decoder call0xff1471c, R0=1;
static instructions immediately before it read0x38a00c30. Production explicitly
returns1 for C30. The decoder counts one set correction-status bit and returns
success; whether the bit represents a NAND bit or chunk is not established. It is not
an erased-page status. The earlier suggestion of default-zero C30 is withdrawn.
The stock decoder distinguishes bit29 with zero corrected count as erased,
and bit30 as an error requiring per-chunk classification. Nonblank raw OOB/ECC
encoding and that classification remain unqualified.

A private candidate publishes bit29 only after a completed compatibility DMA
from a known physical hole/erased block. Stored pages, including all-FF payload,
remain unsupported because their current spare projection does not establish
raw ECC provenance. Missing/partial DMA, abort and descriptor mutation revoke
read readiness instead of publishing completion. Generated storage retains its
explicit C30=1 compatibility behavior. This does not implement physical FMC
read execution or a BCH decoder.

Private actual-source ASan/UBSan tests pass, and the actual board suite passes
33/33, including erased result timing, programmed all-FF provenance, descriptor
mutation, failed second-half DMA and abort. The pinned private binary SHA256 is
`745dffa0eb710cadeaa7f4c7b61b769580eb4f0a7153a20cbc4d2a9effcc79df`.
Root's bounded cold boot reaches FIL_Init/BUF/FPart but stops before VFL_Open
polling C0C. Read-result lifetime is therefore not native-qualified yet; the
next bounded trace must distinguish command ordering and failed DMA. There is
no cold-boot or durable physical NAND success claim and no production staging.

The suppression-free 7E18 corrected-NOR run passes all8 regression checks,
including two clean PMU shutdowns and durable subsequent writes. The 5F138 run
passes all8 functional checks and durable reboot data/fsck, but its second
legacy semantic shutdown gesture times out, so it is not fully qualified.
The dormant N72 migration wrapper still has an empty qualified-build set; generic production boot admission does not invoke conversion.

The root-owned3s native trace confirms D30→D34→D38→C04→C00. In the private
candidate, C04 invalidation discards the D38 transfer's readiness before start.
The earlier static D38-before-D30 claim is withdrawn: literal resolution was
wrong;0xff14650 writes D4C. A revised private candidate admits physical
compatibility reads at C00 before sequencer pointer consumption and reserves
erased certification for a single page, matching the decoder's condition.
Actual-source ASan/UBSan tests pass for measured D38-before-C04 ordering,
previous selectors, abort, failed current DMA and unsupported multi-page ECC.
The revised private binary SHA256 is
`14c80f6f944016b8c461b4851a3e8a090af38aceba69c795b602d3bcbb9f7604`.
The synthetic board suite passes33/33 with explicit D38→C04→C00 admission;
its erased-result test rejects the retained old candidate. All other retained
link inputs hash identically before/after; shared source-only engineering-profile
edits were not compiled. Root completed the bounded30s cold boot: FIL_Init/BUF/FPart succeed, then the guest reports NAND format invalid and enters recovery.
This is not complete FMC read execution or a qualified nonblank ECC result.


The private C00 result is a diagnostic refusal, not proof of a missing format.
Bit30 represents unqualified stored or multi-page ECC in this candidate; raw
nonblank parity has not been implemented. No format signature or success
fallback was added. Evidence is retained at
`/Users/shg/Developer/ltm-fidelity/evidence/ltm-fmss-c00-coldboot-2026-10-02`.

The first-FIL v1 and v2 captures timed out with no observed architectural
read ingress. Their `fil_calls=1` was an attempted capture, not an observed
call. The restored NOR's encrypted iBoot DATA was decrypted read-only using
catalog data and matches the stock 5F138 reference byte-for-byte (SHA256
`4c2ec4ea8b8c9ef93548275bfc0f44b447315b8b9631bfeeb147721a2f834b3d`).
The missing path is established from the static dispatch table: its+0x10
entry is common reader0xff14575; its+0x14 entry is raw wrapper0xff14789.
The raw wrapper calls0xff14574 directly, bypassing both watched single/batch
entries. A revised private probe watches the common/raw entry, preserves
incremental observations, and separates attempted and observed call counts.
This source correction does not qualify any NAND behavior.

Root committed the isolated READ-ID FIFO and bounded observational trace as
QEMU6adfad9444. Root committed generic lease-backed boot admission separately
as app48b8947; unqualified NOR migration remains unstaged. The admission split
passes24 targeted tests across5 suites, including borrowed-lease publication,
active/pending storage refusal and cancellation. No production conversion is
activated by that commit.

For future nonblank ECC work, Linux's existing generic BCH library is the
reuse candidate: it accepts field order, correction capability, optional
primitive polynomial and bit ordering rather than fixing one format. Its
GPLv2 licensing is compatible with QEMU's GPLv2 project. The controller
polynomial, sector/parity order and physical OOB routing still need measured
N72 evidence before integration. The repository's S5L8900 ECC model is an
explicit status stub and supplies no reusable codec.
References: https://github.com/torvalds/linux/blob/master/lib/bch.c and
https://github.com/torvalds/linux/blob/master/include/linux/bch.h .


The corrected v3 capture succeeds in1.631seconds and stops at the first decoder
error, retaining5 architectural events and1 observed read ingress. The raw
wrapper's LR is0xff147ab, confirming that the v2 entry list omitted the actual
path. Common reader receives data0xff3f240/spare0xff32c00; its D14 destination
is0xff31940 and the page-count register is1. Decoder receives C30=0x40000000,
count1 and that D14 destination; it scans8 per-sector result bytes and returns
0x80000002. This matches explicit unqualified-ECC refusal. No physical page
address was observed yet because the reader receives chip/page descriptor
pointers; inferring their pointees would be unjustified. No NAND format or
parity corruption conclusion follows. Evidence is
`/Users/shg/Developer/ltm-fidelity/evidence/ltm-fmss-first-fil-v3-2026-10-02`.
The B614D5AD source descriptor supplies4096blocks/CE,128pages/block,
4096data bytes/page and128physical spare bytes/page. Initialization copies
those packed descriptor fields and derives8 sectors/page; the actual decoder
loop's terminal index8 agrees. The projected storage format's64 spare bytes
must not be confused with the chip's full128-byte physical OOB.


The bounded metadata follow-up identifies CS0/page524160 (0x7ff80,
block4095). Its4160-byte programmed overlay record takes precedence over
that block's erased marker. The base page is absent. All8 result bytes at
D14 are zero, and the decoder returns0x80000002 for the experimental bit30
result. Offline inspection records only booleans and known marker positions:
the stored data and64-byte spare projection are nonblank, and DEVICEINFOBBT
appears at offset0. The record SHA256 is
`653dc23631b8cb7d37192c3af99a1025a8c6c11a069906aea743c6a9f22acdfe`.
Thus the first refusal is for an existing nonblank format-metadata page,
not an absent signature. The current record cannot prove raw ECC parity:
its4160bytes are4096data+64projection, whereas the configured chip's raw
page is4096data+128OOB. Replacing zero result codes with success would
conceal the unimplemented producer. Next work must establish the actual
FMC write-cache/spare/ECC producer and physical parity persistence, then
read/decode those bytes; generic BCH reuse needs independent vectors.
Evidence: `/Users/shg/Developer/ltm-fidelity/evidence/ltm-fmss-first-fil-metadata-2026-10-02/offline-provenance.json`.


A separate evidence-backed host durability correction is ready for native
regression. Page stores now sync the parent directory after publishing the
checked/fsynced temporary file. Erase syncs its marker entry before deleting
old pages, then syncs removals before acknowledgement/cache publication.
Newly created overlay directories sync their parent entries. Directory errors
use the existing sticky IO-error stop, suppressing the actual completion IRQ.
No NAND layout, guest bytes, ECC policy or generated relocation changes.
The dedicated actual-source sanitizer suite covers11 ordering/reopen/fault
cases; the retained baseline fails its missing-directory-publication assertion.
All10 source FMSS suites and32 actual-board tests pass. The private combined
native candidate is SHA256
`8b4b05409f1e1cab96624e8225adc5ce24bed589e423320a4e71f7962f07b2b4`,
with all retained inputs hashed before/after and unchanged, plus the retained
suppression-free AES object. Native qualification is root-scheduled.
These are host OS fsync ordering guarantees, not physical NAND power-loss
atomicity or completed physical restore. Evidence and isolated3-file patch:
`/Users/shg/Developer/ltm-fidelity/evidence/ltm-fmss-durability-candidate-2026-10-02`.
