# Remaining architecture work and report disposition

Reviewed 2026-09-30 against the `codex/reuse-implementation` app and emulator
worktrees and USB host candidate `e19fac2`. These remain unmerged candidates.
This document supersedes the earlier review reports for implementation status,
not their reasoning. Commit and test evidence is recorded below as it stabilizes.

The second implementation pass adds a production stopped-edit workflow for the
explicitly supported N72 generated format, killable per-device services, shared
firmware wire data, coordinated cache pruning, and physical NAND semantics.
It does not make a restored K48 store interchangeable with a generated store:
stock restored cold boot still fails the identity gate, and the host reader now
refuses physical formats it cannot interpret correctly.

## Disposition of the report recommendations

| Recommendation | Current disposition | Remaining work / proof |
|---|---|---|
| Swift preparation / Python retirement | Included in the starting consolidation | Keep production orchestration in Swift; Python remains useful for test/research harnesses. No blanket migration of tests. |
| PVRTC reference decoder | Implemented and sanitizer/native-upload tested | Cross-platform EAGL integration and older/newer live snapshot round trips are not established by these tests. |
| iPad flush failure propagation | Implemented and failure-injected | Storage-generation publication is implemented and interruption-tested. Data-before-ownership publication is now ordered and SIGKILL/reopen tested; atomic guest operations and durability of every acknowledged program across host power loss remain open. |
| Exclusive offline export ownership | Implemented at reusable device API/CLI boundary | Production edit, deletion and cache maintenance now use ownership checks. Continue auditing restore entry points; isolated fixture APIs intentionally bypass ownership. |
| Safe HFS export/mount cleanup | Implemented | N72 edits preserve metadata and publish one recoverable generation containing NAND, NOR and fresh snapshot paths. Physical native FTL formats require separate support. |
| Stopped writable / running read-only access | N72 transactional CLI and Finder workflow implemented; certified edited generation passes two native boots | N45 format unsupported; K48 coupled partitions/keybag/crypto/YaFTL unresolved. Running reads must use guest VFS or a frozen generation. |
| Stock restore replacing generated stores | K48 geometry-only stock erase restore passes | Stock cold boot fails its identity gate; full activation/graphics/install/delete/persistence and interruption recovery are unproven on restored storage. |
| Raw H2FMI commands / spare FIFO / completion | Implemented, qtested, restore and prepared-device regressed | Broader chip/controller contracts still require firmware evidence. |
| Physical flash semantics / shared backend | Explicit `nand-xor-ff-v2` and upstream QEMU BlockBackend implemented | Erased FF, one-to-zero programming, erase row addressing, exclusive block ownership, flush and snapshot reopen tested; legacy formats retain their old semantics. RAM-owned bitmap changes publish only after page flush; crash/reopen and nonempty FIFO snapshots are tested. Per-operation crash atomicity remains. |
| N72 logical relocation in hardware model | Open | Stock physical commands/guest FTL must replace the compatibility mapping, with restore, large writes/deletes and cold-boot evidence. |
| FMSS snapshot equivalence | Unsupported physical-state snapshots explicitly rejected | Empty state migrates; populated physical state and uncertified old snapshot versions refuse save/load. Full physical-state migration remains a future capability. |
| NAND crypto fidelity | Open | Plaintext generated stores still permit bypasses; prove encrypted restored-store execution through hardware engines. |
| Native boot arguments / N45 early touch | SYSIC touch masking corrected and older/newer runs pass | Native NOR/NVRAM handoff and downloaded touch firmware readiness remain research leads. Historical early panic was not reproduced, so no readiness gate was invented. |
| Per-device service routing | Demonstrated hazard guarded and regression tested | Immutable per-device endpoint workers replace GUI C calls; stalled A does not block B, cancellation kills/reaps children, and a retired session cannot reopen. Native guest services pass 12/12. |
| Timezone lifecycle and children | Implemented and cancellation/deadline tested | BootSessionScope now owns readiness, recovery, staging, activation, installation, reset and synchronization tasks plus the observer. Controller orchestration can be reduced further as responsibilities stabilize. |
| Shared catalog / boot recipe types | Boot-field loss fixed and round-trip tested | Shared Foundation-only FirmwareWire preserves all catalog fields, including source resources. GUI does not import preparation machinery. |
| Developer SSH/SFTP/GDB | Automatic opt-in guest offer and per-instance keys; modern host SSH/SFTP passes on clean 7E18 and 7B500 under load | Pinned-source shell and full source/license receipt are packaging-qualified. Older firmware requires its own ABI proof. QEMU GDB uses an explicitly enabled stub; automatic GUI launch and application debugserver remain separate capabilities. |
| Native Finder discovery/media sync | Removed from scope at the user’s request | No virtual-controller adapter or entitlement request. Ordinary stopped HFS mounts and guest-mediated services remain. |
| Matrix evidence identity/publication | Implemented and real concurrent-process tested | Broader corpus execution and acceptance inventory remain ongoing engineering work. |
| Test prerequisites / real model coverage | Three explicit production qtest suites established | Explicit emulator test registrations replace source-text classification; physical flash and snapshot contracts now have actual model tests. Convert remaining high-risk DMA/IRQ/reset coverage incrementally. Skipped tests are not compatibility proof. |
| Cache pruning ownership | Shared preparation leases and exclusive prune CLI implemented | GUI and matrix call the same maintenance boundary. Verified cache remains reusable; concurrent external consumers prevent pruning. |
| Capacity handling | Implemented, shared GUI/preparation leaf, tested | Preserve the small dependency boundary; no need to introduce another storage framework. |
| ANGLE adoption | Comparative ES1 prototype evaluated; CGL retained | Exact ES1 pixels/readback and native sharegroups pass, but K48 composition fails on ES2 and legacy N72 requires rectangle semantics. Snapshots refuse explicitly. No net code or stability benefit demonstrated; prototype is research-only. |
| Factual docs / source pins / worktree hygiene | Matching candidate pins and durable evidence recorded | Historical reports now link here; generate current inventory from commits/artifacts. Integrate candidates and run the signed/universal supported-host release gate. |
| Retina / original iPhone / telephony | Future scope | Matched IP reuse and board wiring; measure Apple's modem boundary before choosing protocol helpers. No new-device support is implied. |

## Remaining refactors and acceptance boundaries

### 1. Storage transactions and snapshot validity

The reusable host storage transaction boundary is now implemented for GUI and CLI:
exclusive lease, original generation, staging, metadata validation, filesystem
check/eject, atomic publication, and recovery after interruption. Saved RAM state
must reference the exact storage generation and be invalidated by offline edits.
NOR and flash metadata must be included wherever they are coupled.

Use the macOS HFS driver for the host view. Prefer applying changes through stock
guest drivers in a maintenance environment, so iOS remains the FTL/crypto writer.
If the N72 rebuilt-store path is retained provisionally, label its supported
formats and preserve the original on every failure. Do not generalize it to K48
or N45 without their own proof.

Acceptance: edit with an ordinary editor, preserve owners/modes/xattrs/hardlinks,
interrupt commit, recover, reject boot while mounted, reject stale RAM snapshots,
and verify both edited and subsequent guest-written files after two cold boots.

### 2. Killable host services and session ownership

Service execution now runs outside the GUI in one
restartable host worker per device, with immutable endpoint/UDID and a typed
request/reply contract. Reuse libimobiledevice and existing subprocess ownership.
Keep it separate from QEMU so a stalled library can be killed without killing the
guest. GUI, CLI and mounts should use the same service boundary.

The owned boot/session scope has been extracted from EmulatorController:
process lifecycle, readiness/recovery, cancellation and generation checks.
Storage transactions and guest provisioning become separate owners; the
controller presents state. Moving methods to extension files alone is not this
refactor. Internal separation does not introduce user-selected activation hooks
or a public plugin system; required provisioning remains automatic.

Acceptance: stall A, use B, restart A's worker, and ensure no request/completion
crosses either device or boot generation. Test stop/restart with readiness,
recovery, timezone and installation pending.

### 3. Physical NAND backend and remaining hardware contracts

QEMU BlockBackend now owns data/spare files below Apple controllers. Specify
physical data/spare, erased state, one-to-zero programming, erase, errors and
flush ordering. Preserve controller-specific MMIO/DMA/IRQ behavior and keep the
guest FTL above the hardware boundary. Migrate existing store formats explicitly;
do not change sparse zero meaning underneath users' devices.

Unsupported FMSS physical snapshots now fail explicitly; complete state migration is still needed for full save/resume equivalence.
Then retire logical relocation and crypto shortcuts individually through physical
restore/write/delete/interruption gates. Investigate native boot-argument and
multitouch divergences as separate hardware fixes, not another broad rewrite.

### 4. Stock GPU/restore boundary and automatic additions

First map the SGX driver's polled virtual address and determine the hardware or
firmware contract it awaits. A native SGX implementation is a major fidelity
project; the observed loop is not proof that one register stub will suffice.
Do not invent a completion to turn the cold-boot gate green.

Meanwhile define a supported restore-plus-automatic-provisioning workflow for
necessary graphics/activation/integration additions. Keep that product path and
a truly stock cold-boot research gate distinct. Neither should require the user
to choose a hook path. Only retire synthetic preparation when the replacement
completes the full ordinary-device lifecycle.

### 5. Smaller shared contracts, explicit tests and release evidence

The stable firmware wire schema is shared without the full preparation dependency.
Cache lease/prune policy is centralized in preparation tooling; GUI callers
request maintenance rather than deleting guessed paths.

Register tests with explicit tiers, inputs and prerequisites. Prefer upstream
qtest for hardware contracts, retaining focused unit tests where useful. Produce
factual support/status inventory from result artifacts, with handwritten
architecture explanations. Finish final-bundle signing, dependency packaging,
universal architecture and supported-host checks before a release claim.

## Deliberately deferred

ANGLE, Retina boards and telephony have explicit feasibility gates. Native
Finder USB discovery and sync were removed from scope at the user’s request; no
entitlement application or adapter work is planned. Stopped filesystem mounts
remain supported. Other postponements are engineering decisions, not completed
cleanup. More abstractions, a generic device plugin framework, a new filesystem
implementation, or a second host media-database writer would add ownership before
solving the boundaries above.

## Retained acceptance seam

The final ordered-ownership/snapshot-fixed K48 binary passes persistence and an
isolated boot/unlock replay. A concurrent loaded-host run instead reaches a
black display during the unlock judge, with LCD enable/disable transitions and
no demonstrated NAND error. Both runs are retained; the isolated pass does not
explain or fix the earlier failure. Touch/sleep timing under load remains an
acceptance investigation, not a claimed storage regression fix.
