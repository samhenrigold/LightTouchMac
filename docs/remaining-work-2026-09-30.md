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
| Native boot arguments / N45 early touch | SYSIC touch masking corrected and older/newer runs pass | Native NOR/NVRAM handoff and downloaded touch firmware readiness remain research leads. Historical early-touch panic was not reproduced, so no readiness gate was invented. The incoming N45 four-page map-context fix removes the hard-stop FTLRestore corruption. Old-format baseline reproduces the kernel abort; two independent fixed-format reopens reach FTL_Open/BSD root without it. The retained 240-second baseline reaches a visible home screen. This was an out-of-bounds map restore, not an IOKit race. |
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
| Factual docs / source pins / worktree hygiene | Matching candidate pins and durable evidence recorded | Historical reports now link here; generate current inventory from commits/artifacts. Universal ad hoc candidate builds; integrate candidates and run Developer ID/notarization and actual supported-host runtime gates. |
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

## Overnight fidelity pass

Authorized September 30; hourly continuation through October 1, 08:00 Eastern.
All changes stay in the existing worktrees. Native Finder virtual USB work
remains excluded. Do not mark the whole backlog complete because a run ends.

First audit corrected a stale claim: K48 watchdog timed reset already landed in
`4ecef106c1`. Production board qtests now cover feed/expiry, disable/resume and
compare changes (5/5 pass), alongside the sanitizer-enabled PMGR contract test.
Evidence: `/private/tmp/ltm-overnight-pmgr-qtest.log`. No new timer model is claimed.
N72 watchdog timed expiry still requires timeout-field and clock evidence.

The N45 failure is now explained by incoming commit `14c5c0e`: four physical
map pages, not eighteen, belong to its one-bank 8 KiB table. `_FTLRestore`
copied the extra pages into kernel memory. Recipe version 2 and Prepare Again
are integrated from the multidevice target. Fixed and old bases were prepared
from the same 3A101a IPSW. Evidence: `/private/tmp/ltm-n45-hardstop-fresh`
(old-format abort), `/private/tmp/ltm-n45-hardstop-fixed` and
`/private/tmp/ltm-n45-hardstop-awake` (fixed reopens, no abort). The longer
`/private/tmp/ltm-n45-pmu-baseline/screen.png` shows the stock home screen.
The N45 layout checks pass; seven corpus cases were explicitly skipped.

Music import investigation found two real seams: only title/artist/album were
forwarded and no artwork cache was built; older guest packages could silently
ignore new fields. Host staging now carries album artist, composer, genre,
track/disc numbers and a bounded JPEG alongside unchanged MP3/M4A bytes. The
current app helper is uploaded for every media commit. Stock MusicLibrary and
ArtworkCache own all library/cache writes; the host never writes these databases.
Native 7E18 tests pass fresh import, duplicate reconciliation and cold reopen,
including actual MediaPlayer decoded artwork. Evidence:
`/private/tmp/ltm-media-artwork-regression2`, with `import-artwork.png` and
`reboot-artwork.png`. MP3/ID3 and M4A preparation, AFC transfer, helper selection
and stale-base checks pass 4/4 in `/private/tmp/ltm-music-offline-results`.
This remains the existing 7E18-only native media service. Already-imported tracks
with artwork ID zero require removal in Music and reimport; no silent upgrade or
broader firmware compatibility is claimed.

The repeat-import regression exposed a legacy SQLite schema race while Apple's
sync service updates the attached Locations database. Read-only reconciliation
now reopens and reprepares only on SQLITE_SCHEMA, at most three attempts; all
other errors remain fatal. Fault injection covers ATTACH, prepare and step.
The native rerun passes import/repeat and cold reopen with decoded artwork in
`/private/tmp/ltm-media-artwork-schema-regression`.

N45 interrupt contract committed in QEMU `9114592748`: PCF50635 five status/mask
banks, correct USB edge bank, EXTON1 both edges, configured shutdown reset and
VMState version boundary. Production-board qtest passes I2C -> GPIO source 0x55
-> VIC source 0x1f, including masked latching and parent ACK while held. D1759
ADC/RTC/shutdown tests and the native 7E18 media/reboot gate pass. Evidence:
`/private/tmp/ltm-n45-pmu-qtest.log` and
`/private/tmp/ltm-media-artwork-schema-regression`.

The native N45 170-second run remains black after `pmu go hib`: the CPU ends at
c005a6d0 with IRQ/FIQ masked after PCF standby 0x0c=2. This is not evidence of
working sleep/resume. Correct interrupt delivery cannot replace the retained-RAM
resume/ROM handoff. Evidence: `/private/tmp/ltm-n45-pmu-candidate`. The PCF ADC,
charger/regulator sequencing and native resume remain open. No guest-code patch
or invented wake vector was added.

Continue physical NAND/crypto and native boot/power handoff one independently
verified contract at a time. GPU remains a separate feasibility gate.

Latest local main reconciliation: multidevice `af0c867` and ipad1 `fd5a1d0845`
now form the candidate base. Their full metadata work is integrated into one
MediaSong tag reader and the shared MediaPhoto JPEG writer; the duplicate
metadata regression was retired. The candidate retains bounded images, the
current-helper route, schema retries and a native allocated artwork ID read
back on retry, rather than deriving the cache key from a truncated hash.
Year uses MusicLibrary's own writer connection because the purchase insert has
no year property; no host database writer is added. Candidate guest package
serial is 11 / 1.1.9 so the changed payload follows main's serial 10.

The full app-side tagged test passes production Swift -> service worker -> AFC
-> itmedia -> native library/cache, including year, compilation, genre and
artwork format/pixels, duplicate reconciliation, and guest-confirmed shutdown.
Evidence: `/private/tmp/ltm-media-merged-native.log` and its retained output path.
Four offline checks pass without skips in `/private/tmp/ltm-media-merged-offline`.
The native harness now accepts explicit asset/base paths for isolated worktrees.
The additional cold-reopen check passes on the merged path: full tags, exactly
one song after repeated import, and a PNG decoded through the guest's MediaPlayer
on both boots. Evidence: `/private/tmp/ltm-media-merged-cold-boot2` and its `.log`.

The rebuilt universal ad hoc candidate is
`/private/tmp/ltm-universal-candidate/Light Touch.app`, pinned to QEMU
`9d2d3c2f0beb5756b302d19441b6e602e3fed81e` and the USB host candidate above.
Guest payload serial 11 and both host architectures are included. Release fixture
checks pass 8/8 with the dependency-download network check skipped; actual bundle
hygiene passes. This is not Developer ID/notarization or supported-host runtime
qualification. Evidence: `/private/tmp/ltm-overnight-release-final.log` and
`/private/tmp/ltm-overnight-bundle-hygiene.log`.

The broader offline run passes 100 checks, skips two opt-in GUI checks, and fails
one metadata check because that invocation selected the separate main checkout
instead of the candidate QEMU source. The focused rerun with the explicit
candidate path passes, including fractional-tag and unsafe-artwork-path rejection.
Keep both results: `/private/tmp/ltm-overnight-offline-final.log` and
`/private/tmp/ltm-overnight-metadata-candidate.log`.

## October 1 overnight continuation

Candidate QEMU `2659e4f08f` adds the register-derived N72 root peripheral clock
and removes the direct-iBoot shared empty-literal argument patch. That patch also
redirected DeviceTree root lookup, so it erased the effective serial/model/region
handoff and changed the USB UDID. The existing argument data writer now discovers
promptly, refreshes at its normal cadence, and stops an unsuccessful search.
The app's shared boot recipe starts discovery without delay. The Swift/Python
ramdisk one-shot owns its `rd=md0` command line at the existing debugger handoff,
where it already stages RAMDisk and topOfKernelData; emulator argument injection
is disabled for that one-shot.

Evidence: 109 registered QEMU host checks pass (28 declared manual-input skips),
seven registered actual-board model suites pass without skips, and the Swift
preparer test run succeeds (145 tests reported, corpus checks remain opt-in).
Native 7E18 passes early kernel UART and factory serial/UDID/both MACs; full tags,
repeat-import reconciliation and stock-decoded cover art persist across two cold
boots at `/private/tmp/ltm-n72-identity-media-phased/`. Native 8C148 completes fresh
production Swift preparation, including its Update ramdisk keybag boot, then
passes factory identity and early BSD mount logging at
`/private/tmp/ltm-n72-identity-ios4/`. The one-shot used the existing ad hoc helper
(source 9d2d3c2f0b) with argument injection disabled; its cold boot used the current
emulator. The optional 3.1.3-linked IORegistry probe fails to execute on 4.2.1 and
is not counted as guest-tool qualification. The obsolete 8C148-b prepared base
fails iBoot VFL checks and was not altered.

Open: root clock consumers/gates, S5L8720 watchdog timed expiry, the Bluetooth
DeviceTree path rewrite, other direct-iBoot firmware timing, and the previously
listed NAND/GPU/power-resume boundaries. The existing universal package is still
source 9d2d3c2f0b until rebuilt; it does not yet contain this new clock/identity work.
