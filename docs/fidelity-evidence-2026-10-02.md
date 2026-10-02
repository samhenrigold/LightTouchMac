# October 2 qualification journal

Uncommitted worktree candidates; no target merge or release. This journal distinguishes model tests, actual helper gates, diagnostic traces and ordinary native qualification. Native Finder virtual USB remains excluded.

## Verified evidence

- Generic virtual-time input: actual helper/session runner uses the shared DeviceRuntime host gesture adapter. `/private/tmp/ltm-next-host-input-native-retry` passes 19/19, including two PMU-confirmed shutdowns, helper exit zero, persistent marker and installed application across reboot. Initial helper identity rejection is retained separately; the security guard was not weakened. Latest concurrent-publication correction is not covered by that frozen artifact.
- Actual GUI and helper build after synchronized-folder membership correction. Canonical host automation source is imported once through DeviceRuntime.
- Experimental MBX black fill: six actual board qtests pass; 14 registered model suites pass with no skips. Covered operation writes actual translated pixels before completion. Native startup still stops before this operation; EVM/context initialization and full compositor remain unresolved. Default graphics compatibility remains explicit.
- N45 opt-in supplied-ROM reset: actual board test verifies reset vector, verbatim ROM jump table, write protection and retained DRAM. `/private/tmp/ltm-n45-rom-cold-candidate-retry` begins at PC zero and reaches the first hardware write, 0xa5 to 0x3e300000. A second bounded MMIO trace reaches repeated clock-status polling at 0x3c500040 with the fixed value 0xf; the model contract is under investigation. This is no cold boot or retained-RAM wake success claim; supplied asset provenance remains qualified.
- Darwin nanosecond waits: actual-source ASan/UBSan descriptor and EINTR parity tests pass. Exact 100000 ns timeout forwarding is checked, with latency recorded without a timing threshold. Diagnostic 2.1.1 full regression passes 8/8 with LCD tracing; ordinary untraced 2.1.1 passes 13/13 in `/private/tmp/ltm-next-poll-ordinary-ios211`, including actual warm reset, two clean shutdowns, cold persistence and fsck. Matching untraced3.1.3 baseline and candidate both pass8/8 with unchanged shared link input hashes. Worktree commitec254cb399 contains the host wait correction; guest timer rate and controlled comparative cadence remain pending.

## Stock restore and the next divergence

`/private/tmp/ltm-fmss-script-native-2026-10-02` reaches stock Restore Finished with host exit zero. Controller CPU-storage shortcuts and aborted sequencer completion remain, so this is not physical-flash fidelity or durable restore qualification. The earlier waiting-for-NAND observation is superseded for this exact artifact only; no behavioral FMSS correction caused this result.

A disposable cold clone returns to SecureROM DFU at PC 0x3186, before kernel or NAND boot. The AES observation in `/private/tmp/ltm-fmss-stock-aes-coldboot-2026-10-02` shows:

- The model returns zero for KEYLEN readback, losing SecureROM's direction setting during its measured read/modify/write sequence. An actual-source negative baseline and one-case readback candidate confirm this defect.
- At the restored LLB signature, a fixed-address 128-byte suppression calculates output but does not write it. This shortcut remains a boundary violation until removed with canonical generated-NOR wrapping and independent native controls.

Neither stock restore completion nor that crypto diagnosis proves cold boot, subsequent durable writes, BCH/OOB encoding or physical controller completion. FMSS trace independently exposes missing ECC result producers at controller registers 0x80c and 0x810; sibling OpeniBoot code corroborates status meanings but does not establish the N72 polynomial, bit order or raw spare layout.

## Artifact scope

`/private/tmp/ltm-next-integrated-artifacts` freezes helper-gate QEMU artifacts and object hashes. `/private/tmp/ltm-next-poll-pair` records identical shared link inputs for baseline/candidate, changing only the private timer archive object. These private paths contain runtime inputs and must not be copied wholesale to public evidence. Consolidate bounded text receipts, hashes, source and allowed UI images only.

Pending: native ordinary timer controls; AES register correction and genuine wrapping migration; physical write/ECC contract; stock restored cold boot and durable later writes; standalone QMP/N45 input controls; live MBX startup; retained-RAM power/wake; measured watchdog expiry; current universal/Intel qualification. These remain active work, not completed items.

## AES native control outcome

The readback-only artifact derives the independently expected UID wrapping key and exact original LLB signature on the restored cold clone. However, the existing generated 7E18 NOR enters recovery with `load_macho_image: failed to load device tree` under corrected readback (`/private/tmp/ltm-next-aes-readback-ios313`). Its envelopes use the old decrypt-derived key. This failed native gate is retained and the owned recovery guest was deliberately terminated; it is not a shutdown/persistence success. The hardware correction needs canonical preparation and transparent stopped migration before adoption. Production preparation defaults and output suppression remain unchanged.

## Input and N45 clock model gates

Actual input board suite passes 3/3 after its test JSON IDs were corrected to integers; the retained initial failure was schema misuse, not a production fix. Generic QMP sequences exercise real PMU events, timer deadlines, malformed replacement ownership, wrong-ID cancellation, matching paused cancellation and reset cleanup. The publication and manual touch pause fixes have sanitizer/concurrent primitive tests; latest dylib is pinned in `/private/tmp/ltm-next-pll-input-artifacts`, and does not inherit the older helper 19/19 qualification.

N45 PLL-root board tests pass 2/2 for the exact ROM sequence, independently enabled valid-divider lock bits, read-only status, 10-bit multiplier and unchanged secondary block. Derived lock status replaces fixed0xf only in the actual older-chip PLL root. Analog latency and clock rate remain unqualified. All15 registered model suites pass, no failures or skips, at `/private/tmp/ltm-next-pll-input-models`. Native ROM progression and default prepared-device controls remain pending.

## Broad host checks and cleanup

The quick tier initially reports121 pass,14 fail,29 explicit manual skips. Eleven CGL/VideoToolbox failures pass under the necessary host access (`/private/tmp/ltm-next-host-graphics-retry`). The other three are two runner imports and a stale drawable source harness. Worktree commit640460b13a fixes sibling scene resolution for imported runners, with both affected iPad checks passing. Commit09aeb6d6de updates the actual drawable leaf harness and checks balanced IOSurface mapping/retain lifetimes, failure rollback, rotating surfaces and shared owners under sanitizers. It passes independently. Thus all135 registered host checks have passing evidence;29 input-dependent checks remain explicitly skipped, not compatible. No target merge follows.

The N45 corrected native ROM trace returns PLL status1 and advances beyond the previous repeated poll into subsequent initialization. The extended diagnostic then fails parsing the ARM register alias `sb`; that is a tracer bug, fixed independently, not an emulator failure. Cold boot and wake remain pending.
