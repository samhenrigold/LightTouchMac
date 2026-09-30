# Remaining architecture work and report disposition

Reviewed 2026-09-30 against app candidate `8284f76`, emulator candidate
`abf8194101`, and USB host candidate `e19fac2`. These are clean, unmerged
candidates, not changes already present in the integration targets. This document
supersedes the review reports for implementation status, not their reasoning.

The earlier pass closed several concrete defects and established stronger gates.
It did not complete the entire architecture plan. In particular, a successful
blank-NAND restore is not a successful restored-device lifecycle, and the N72
edit experiment is not a production writable Finder volume.

## Disposition of the report recommendations

| Recommendation | Current disposition | Remaining work / proof |
|---|---|---|
| Swift preparation / Python retirement | Included in the starting consolidation | Keep production orchestration in Swift; Python remains useful for test/research harnesses. No blanket migration of tests. |
| PVRTC reference decoder | Implemented and sanitizer/native-upload tested | Cross-platform EAGL integration and older/newer live snapshot round trips are not established by these tests. |
| iPad flush failure propagation | Implemented and failure-injected | Cross-file crash consistency and storage-generation publication remain open. |
| Exclusive offline export ownership | Implemented at reusable device API/CLI boundary | Extend the same ownership contract to production edit, restore, deletion and cache maintenance; isolated fixture APIs intentionally bypass it. |
| Safe HFS export/mount cleanup | Implemented | Production edits need metadata preservation and recoverable publication, rather than treating preparation as a generic editor. |
| Stopped writable / running read-only access | N72 stopped-edit proof passes two native boots | Transactional product workflow absent; N45 format unsupported; K48 coupled partitions/keybag/crypto/YaFTL unresolved. Running reads must use guest VFS or a frozen generation. |
| Stock restore replacing generated stores | K48 geometry-only stock erase restore passes | Stock cold boot fails its identity gate; full activation/graphics/install/delete/persistence and interruption recovery are unproven on restored storage. |
| Raw H2FMI commands / spare FIFO / completion | Implemented, qtested, restore and prepared-device regressed | Broader chip/controller contracts still require firmware evidence. |
| Physical flash semantics / shared backend | Open | All-zero sparse pages are still inferred erased; programming overwrites bytes; generated-store compatibility must be migrated deliberately. |
| N72 logical relocation in hardware model | Open | Stock physical commands/guest FTL must replace the compatibility mapping, with restore, large writes/deletes and cold-boot evidence. |
| FMSS snapshot equivalence | Open | `phys_pages` / `erased_blocks` are not migrated. Either represent/reconstruct authoritative physical state or explicitly reject unsupported snapshots. |
| NAND crypto fidelity | Open | Plaintext generated stores still permit bypasses; prove encrypted restored-store execution through hardware engines. |
| Native boot arguments / N45 early touch | Open | Trace NOR/NVRAM consumption and multitouch readiness/ATN; remove injections/stimulus restrictions only with older/newer regression proof. |
| Per-device service routing | Demonstrated hazard guarded and regression tested | Guard still serializes globally and cannot terminate a wedged C thread. Per-device killable workers remain necessary. |
| Timezone lifecycle and children | Implemented and cancellation/deadline tested | Other controller tasks still need a uniform boot/session ownership boundary. |
| Shared catalog / boot recipe types | Boot-field loss fixed and round-trip tested | Duplicated wire models remain; share a narrow schema module without importing all preparation machinery into the GUI. |
| Developer SSH/SFTP/GDB | Host OpenSSH/inetcat wrapper and existing GDB protocol exposed | Guest server provisioning, fresh host keys, legacy compatibility and live root-file semantics remain. Application debugserver is a separate capability. |
| Native Finder discovery/media sync | Open feasibility work | Prove a supported discovery/pairing path and virtual/physical coexistence before promising native Finder sync. An AFC mount is a different capability. |
| Matrix evidence identity/publication | Implemented and real concurrent-process tested | Broader corpus execution and acceptance inventory remain ongoing engineering work. |
| Test prerequisites / real model coverage | Three explicit production qtest suites established | Replace source-text classification with explicit registrations; convert high-risk DMA/IRQ/reset/snapshot coverage incrementally. Skipped tests are not compatibility proof. |
| Cache pruning ownership | Open | PreparationJob knows versioned paths, but ownership/retention is not unified; matrix cleanup still names legacy SHA1 paths. Pruning must coordinate with external CLI consumers. |
| Capacity handling | Implemented, shared GUI/preparation leaf, tested | Preserve the small dependency boundary; no need to introduce another storage framework. |
| ANGLE adoption | Deferred after native probes | Same guest workload, surfaces/sharegroups and snapshot round trips must demonstrate benefit and deletable custom adaptation before changing the shipping backend. |
| Factual docs / source pins / worktree hygiene | Matching candidate pins and durable evidence recorded | Historical reports now link here; generate current inventory from commits/artifacts. Integrate candidates and run the signed/universal supported-host release gate. |
| Retina / original iPhone / telephony | Future scope | Matched IP reuse and board wiring; measure Apple's modem boundary before choosing protocol helpers. No new-device support is implied. |

## Proposed refactors and order

### 1. Storage transactions and snapshot validity

Create one reusable host storage transaction boundary for GUI and CLI:
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

Extract service execution from process-global endpoint switching into one
restartable host worker per device, with immutable endpoint/UDID and a typed
request/reply contract. Reuse libimobiledevice and existing subprocess ownership.
Keep it separate from QEMU so a stalled library can be killed without killing the
guest. GUI, CLI and mounts should use the same service boundary.

Extract an owned boot/session scope from the 1,875-line EmulatorController:
process lifecycle, readiness/recovery, cancellation and generation checks.
Storage transactions and guest provisioning become separate owners; the
controller presents state. Moving methods to extension files alone is not this
refactor. Internal separation does not introduce user-selected activation hooks
or a public plugin system; required provisioning remains automatic.

Acceptance: stall A, use B, restart A's worker, and ensure no request/completion
crosses either device or boot generation. Test stop/restart with readiness,
recovery, timezone and installation pending.

### 3. Physical NAND backend and remaining hardware contracts

Adapt existing QEMU block/NAND infrastructure below Apple controllers. Specify
physical data/spare, erased state, one-to-zero programming, erase, errors and
flush ordering. Preserve controller-specific MMIO/DMA/IRQ behavior and keep the
guest FTL above the hardware boundary. Migrate existing store formats explicitly;
do not change sparse zero meaning underneath users' devices.

Fix or reject unsupported FMSS snapshots before claiming save/resume equivalence.
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

Extract only stable catalog/recipe/identity/service wire types into a small
shared host module. Centralize cache lease/prune policy in preparation tooling;
GUI callers request maintenance rather than deleting guessed paths.

Register tests with explicit tiers, inputs and prerequisites. Prefer upstream
qtest for hardware contracts, retaining focused unit tests where useful. Produce
factual support/status inventory from result artifacts, with handwritten
architecture explanations. Finish final-bundle signing, dependency packaging,
universal architecture and supported-host checks before a release claim.

## Deliberately deferred

ANGLE, native Finder USB discovery, Retina boards and telephony have explicit
feasibility gates. Their postponement is an engineering decision, not completed
cleanup. More abstractions, a generic device plugin framework, a new filesystem
implementation, or a second host media-database writer would add ownership before
solving the boundaries above.
