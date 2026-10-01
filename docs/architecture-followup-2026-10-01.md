# Architecture follow-up: measured contracts and reuse

Worktree candidates only. No target merge, installation, publication or release.
Native Finder virtual USB remains excluded. This follows the architecture
review in the original LightTouchMac checkout; it does not replace historical
test receipts with current compatibility claims.

| Area | Verified progress | Remaining acceptance boundary |
|---|---|---|
| Stock restore transport | Real SecureROM/iBSS/ramdisk reaches stock restored protocol 11; legacy client boot-only run passes with original firmware metadata. Production bridge reset/enumeration and exclusive mux handoff tested; measured PHY-reset gating now passes rapid DFU trials and complete stock ramdisk handoff without diagnostic settling. | Stock erase reports Waiting for NAND. Full restore, cold boot and durable later writes required before deleting offline FTL preparation. |
| FMSS | D4C CPU parameter latch/readback/reset/migration corrected from actual stock scripts; qtests 4/4, sanitizers and default native two-boot 8/8 pass. | D18/D28 CPU/sequencer parameters are also corrected (333bc8023c), with model tests and separate native 8/8. Opcode06 register copy also passes real model5/5 and native8/8 (c49f3cdae4); descriptor DMA also passes model6/6 and native8/8 (089b055d73); opcode0A mask intersection passes model7/7 and native8/8 (0fb13887b1). Stock erase now stops at opcode14/imm16 at +0x128. Arithmetic forms, actual erase and honest aborted-script completion remain separate contracts. |
| Silent audio migration | 0ceac9c55e fixes legacy silent stream host rate bookkeeping; model 4/4 including N45 snapshot, audio sanitizers and native two-boot 8/8. | Native N45 guest suspend/wake and in-flight host USB snapshots remain unqualified. |
| Host runtime | GuestPackageSession owns boot package qualification. GUI and session driver now import HostRuntime for prepared-device validation/assembly and actual wire values; package tests, real builds, failure cleanup and native N72 startup pass. | Broader process/service ownership, record I/O and session source/stub coupling remain. Managed boot-path authority remains separate; strict present-lock parsing is now verified. |
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
