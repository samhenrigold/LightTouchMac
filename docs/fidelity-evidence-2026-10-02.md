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

## Continued qualification: context provenance and clock references

The completed bounded restored-guest captures locate the cold-boot failure upstream of the allocator. `ltm-fmss-stock-contextcount-2026-10-02/receipt.json` records the first context parser receiving `0xffffffff` at `0x0ff6056c`. `ltm-fmss-stock-contextread-2026-10-02/receipt.json` records logical page `0x3e9`, data destination `0x0ff60540`, spare destination `0x0ff40240`, and actual VFL callee `0x0ff083a1` on read call158. Both research guests were stopped and reaped; neither receipt is a guest shutdown or cold-boot success. The next investigation is the real read/data/error producer, not an allocator or MMU workaround.

A complete selected-write trace again reaches stock Restore Finished at `ltm-fmss-write-script-full-native-2026-10-02`. The earlier selected-write run stopped because its diagnostic waiting-message guard fired after progress; that stop is not evidence of a restore failure. Physical flash qualification still requires controller byte movement, truthful ECC/error results, cold boot and durable subsequent writes.

The newly rebuilt N72 clock board suite passes4/4, including fuse-selected reference clock, oscillator bypass, PLL divider behavior and restored frequency. N45 ROM/PLL tests pass2/2 against the same binary. Commands used `QTEST_QEMU_BINARY=build-reuse/qemu-system-arm` with the actual `ipod-clock-test` and `ipod-n45-rom-test` executables. Native firmware controls remain pending; these model tests do not qualify watchdog expiry or analog lock latency.

## Suppression-free crypto and opt-in MBX execution

`/private/tmp/ltm-next-aes-no-preserve-ios313` passes all8 ordinary native checks against the pinned suppression-free AES artifact (`bfac08ab960dfe84ac2d0d209cc2ee2a063ff537332188fe78505554a120e0cf`) and independently corrected7E18 NOR. Both shutdowns are guest-confirmed with emulator exit0; the persistent marker is byte-identical after reboot and fsck exits0. Application install/foreground, HLE graphics, guest service round trips and stereo audio pass. This qualifies this firmware/artifact pair; other firmware and transparent migration remain pending.

Worktree commit `3fd4a589c4` contains the opt-in measured MBX black-fill consumer, MIT attribution, MMU enable/bypass handling and tests. Fresh actual-board suite passes6/6 in `/private/tmp/ltm-next-mbx-mmu-qtest.log`; all three MBX source suites pass. The default graphics path is unchanged and live EVM startup remains unsupported. These are model execution results, not a stock compositor success claim.

The next restored-context trace (`/private/tmp/ltm-fmss-stock-contextfil-2026-10-02/receipt.json`) follows logical page0x3e9 to CE1, physical page0x7a07d, actual FIL callee0x0ff147b5, and return status0. Data/spare destinations match the erased-context capture. Investigation now targets this exact physical read and status producer.

## N45 instruction-fetch boundary

The repaired tracer completes its bounded diagnostic cleanly in `/private/tmp/ltm-n45-rom-next100k-instruction-boundary`. After25,837 instructions the supplied ROM branches into Thumb code at0x22002b98, but the debugger returns E14 because that address is outside the current mapped SRAM fragments. The exact PC/CPSR/register receipt is retained; this is not a completed boot. Independent decoding of the local stock3A101a DeviceTree identifies the AMC/SRAM aperture at physical0x22000000 with size0x2c000. An opt-in contiguous-bank correction is under test; default prepared-device behavior remains unchanged.

## 2.1.1 control: functional success, final shutdown failure

`/private/tmp/ltm-next-aes-no-preserve-ios211` uses the same suppression-free AES artifact with all-stage5F138 canonical wrapping. All8 functional checks pass: home screen, install/launch, HLE graphics, service round trips, stereo audio, persistence and fsck. The first shutdown is PMU-confirmed and the second boot reads the marker byte-identically. However, the second legacy board gesture times out after180seconds without guest shutdown. The runner records `boot2-powerdown` harness failure and exits1. Therefore this is NOT a full passing firmware qualification. The final fsck is clean despite forced cleanup, not evidence of a clean second shutdown. A shared-host-gesture control is required before changing the qualified build set.

## Refined hardware and host boundaries

With DeviceTree-confirmed contiguous SRAM, `/private/tmp/ltm-n45-rom-contiguous-sram` passes the previous inaccessible instruction address and reaches the100,000-step bound. The trace includes a later ROM restart; this does not establish full boot. The next accelerated diagnostic will inspect only the observed branch destination and bounded instruction metadata to distinguish missing firmware content from a hardware access failure.

`/private/tmp/ltm-fmss-stock-contextstatus-2026-10-02/receipt.json` records the real status decoder ingressR0=1 and returnR0=0 for the context read. Static driver analysis ties the argument to controller0xC30, whose current source explicitly returns1. This corrects the earlier research inference that the register defaulted to0. The fixed status, not a guessed MMU/allocator fix, is the next relevant read contract.

The common host admission candidate now validates record identity and storage after helper lease acquisition, cancels both terminate/kill before boot, and starts the guest readiness budget after stopped preparation. Actual GUI/helper builds and the real no-guest kill/reaping/lease test pass. The final GUI build re-signed the helper; native testing pins SHA256`e77140a05f3502594b3c8a7ac8ff3a8740d6fb5c7346f5cc72573f3c0206f393` and cdhash`076f963add44c916045a5a04726fe1bbd7aaa9f6`, not the preceding signature. Firmware conversion admission remains gated; no qualified build has been enabled.

## Latest helper native gate and content-boundary deletion

`/private/tmp/ltm-next-notes-host-native` passes19/20 actual helper checks with the latest input/runtime and suppression-free AES dylib (`5c8ef3fe4808deb23036df9801b1166db23cb1e2f3eb54af63c8da07007868f9`). Both shared host shutdown gestures receive actual PMU confirmation and helper exit0. Activation/identity, Home screen, AFC boundary sizes, app installation/foreground and cold marker/app persistence pass; prepared input is unchanged. Notes typing fails: both captured Notes databases contain no note bodies, and the screenshot remains on the empty Notes list. This is a failed native keyboard test, not a successful text injection. Setup is being corrected to use guest virtual time and verify editor focus before typing; database assertions remain unchanged.

Verified worktree commits `18856bf609` (QEMU) and `9b3bc26` (app) delete the NAND scan for SpringBoard plist contents and its host polling counter. Hardware no longer searches pages for `iconState`. Existing stock install/uninstall notifications and15-second coalesced app/layout polling remain; guest icon rearrangements can therefore take that polling interval to appear. The retired shared-status slot stays zero to preserve offsets. Notification lifecycle tests, actual app/helper/dylib builds and the latest native session pass their relevant checks; no immediate icon-reorder notification is claimed.

The accelerated N45 entry receipt (`/private/tmp/ltm-n45-rom-entry-boundary`) shows that the real branch destination now exists but contains zero bytes, followed by a return to ROM address0. SRAM mapping alone does not load the missing instructions. The next investigation is supplied-ROM relocation/provenance and genuine firmware loading, not staging guessed code into the emulator.

The focused Notes retry (`/private/tmp/ltm-next-notes-focus-native`) fails18/20: virtual-time Add delivery completes but the editor-focus screenshot still shows No Notes. Its prolonged unsupported UI diagnostic lets the guest lock, and the later app-launch gate also fails; this second failure is retained rather than reclassified as a pass. Both actual host shutdowns and cold persistence still pass. Source inspection identifies a possible digitizer calibration mismatch (advertised5000x7500 versus emitted4602x7306). That remains a research lead pending actual guest-consumed frame traces; no calibration change has been made merely to hit one button.

## Physical status and strict GPU observations

The private physical flash result-lifetime candidate (`745dffa0eb710cadeaa7f4c7b61b769580eb4f0a7153a20cbc4d2a9effcc79df`) runs stock ROM/LLB/iBoot and identifies all four chips in `/private/tmp/ltm-fmss-stock-honest-status-coldboot`. At30seconds it is polling controller completion at PC0x0ff14338, before VFL_Open. It is NOT a restored boot success: truthful unsupported/error reporting and read-completion ordering remain under investigation. Generated-store behavior is explicitly separate compatibility. No candidate source was promoted on this observation alone.

`/private/tmp/ltm-mbx-strict-current-startup` captures all five requested stock7E18 allocator setup observations with the current strict MMU/fill model and suppression-free crypto binary `742448356ef29bc50aca6c356bc2456de60ad5d7d5c2c271870276129de9bbac`. Canonical NOR remains byte-identical. The receipt is bounded startup metadata, not rendering qualification; EVM table effects and real completion remain undecoded.

## Durable workspace and latest combined qualification

The active worktrees now live in `/Users/shg/Developer/ltm-fidelity/{app,qemu,usbmuxd}`. Research and test artifacts cited by their former `/private/tmp/ltm-*` paths were moved to `/Users/shg/Developer/ltm-fidelity/evidence/<same basename>`; the old paths are compatibility symlinks only. Worktree status, binary diffs and untracked source hashes were compared across the move. The root move receipts enumerate three worktrees and 808 evidence items. New persistent work belongs in the durable directories.

`evidence/ltm-next-current-hardware-ios313` passes all eight native checks against pinned QEMU `742448356ef29bc50aca6c356bc2456de60ad5d7d5c2c271870276129de9bbac`: current N72 reference-clock and READ-ID changes, suppression-free AES, and default graphics compatibility. Both host-driven shutdowns are guest-PMU confirmed, cold persistence matches, and fsck exits zero. This is combined-build qualification, not strict GPU execution. The isolated READ-ID FIFO correction and its tests are committed as QEMU `6adfad9444`.

The faster Notes trace (`evidence/ltm-next-notes-touch-trace`) passes 15/16 checks, failing editor focus. Actual guest frame reads consume the complete contact, motion and release sequence; simple delivery loss is ruled out. Stock MultitouchSupport normalization places the measured contact approximately inside the Add button, so the earlier coordinate-extent lead does not justify changing hardware. Live registry and held-contact observations are next; keyboard completion remains unqualified.

## Secure engineering profile and physical read ordering

The N72 secure-development profile candidate passes four actual-board chip-ID tests, including retail/secure-development/insecure-development CPFM values, read-only fuses, reset and post-start immutability. Results are in `evidence/ltm-n72-security-profile-candidate/board-test.log`. The stock ROM distinguishes its secure input from the security-domain field; the former environment toggles conflated them. Retail remains the default. Full unmodified-chain boot with signature forging disabled and a corrupted-signature rejection control is pending.

The private physical read command-start candidate reaches the stock NAND format-error path and recovery in `evidence/ltm-fmss-c00-coldboot-2026-10-02`, rather than remaining in the previous completion poll. The bounded 30-second diagnostic was stopped and reaped; exit zero reflects diagnostic cleanup, not guest boot success. Per-chunk ECC/error status production remains unmodeled, so this candidate is not production-qualified and has not replaced generated-storage compatibility.
