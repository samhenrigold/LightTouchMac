# Remaining architecture work and report disposition

Reviewed 2026-09-30; implementation status updated 2026-10-02 against the `codex/reuse-implementation` app and emulator
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
| Guest GL surface ownership | CoreSurface mapping and cached EGL-name lifetimes corrected; actual-source negative sanitizer tests and normal full2.1.1/3.1.3 gates pass8/8 | Exact-build independent stock-software controls and strict Boot/GLES gates pass on1.1,1.1.5,2.1.1 and3.0; deferred destruction/concurrency, raw GPU execution and release artifacts remain separate. |
| PVRTC reference decoder | Implemented and sanitizer/native-upload tested | Cross-platform EAGL integration and older/newer live snapshot round trips are not established by these tests. |
| iPad flush failure propagation | Implemented and failure-injected | Storage-generation publication is implemented and interruption-tested. Data-before-ownership publication is now ordered and SIGKILL/reopen tested; atomic guest operations and durability of every acknowledged program across host power loss remain open. |
| Exclusive offline export ownership | Implemented at reusable device API/CLI boundary | Production edit, deletion and cache maintenance now use ownership checks. Continue auditing restore entry points; isolated fixture APIs intentionally bypass ownership. |
| Safe HFS export/mount cleanup | Implemented | N72 edits preserve metadata and publish one recoverable generation containing NAND, NOR and fresh snapshot paths. Physical native FTL formats require separate support. |
| Stopped writable / running read-only access | N72 transactional CLI and Finder workflow implemented; certified edited generation passes two native boots | N45 format unsupported; K48 coupled partitions/keybag/crypto/YaFTL unresolved. Running reads must use guest VFS or a frozen generation. |
| Stock restore replacing generated stores | K48 geometry-only stock erase restore passes | Stock cold boot fails its identity gate; full activation/graphics/install/delete/persistence and interruption recovery are unproven on restored storage. |
| Raw H2FMI commands / spare FIFO / completion | Implemented, qtested, restore and prepared-device regressed | Broader chip/controller contracts still require firmware evidence. |
| Physical flash semantics / shared backend | Explicit `nand-xor-ff-v2` and upstream QEMU BlockBackend implemented | Erased FF, one-to-zero programming, erase row addressing, exclusive block ownership, flush and snapshot reopen tested; legacy formats retain their old semantics. RAM-owned bitmap changes publish only after page flush; crash/reopen and nonempty FIFO snapshots are tested. Per-operation crash atomicity remains. |
| N72 logical relocation in hardware model | Open | Stock physical commands/guest FTL must replace the compatibility mapping, with restore, large writes/deletes and cold-boot evidence. |
| FMSS snapshot equivalence | Physical-page cache and erase map serialized through upstream VMState trees | Four production-board qtests and native 7E18 file/USB/clock/live GL/audio/new Wi-Fi HTTP resume pass. Mode mismatch and uncertified old streams refuse load. Identity/file/clock/USB resume also passes 2.1.1, 3.0 and 4.2.1. Exact flash generation must still match; live graphics/audio/new HTTP are qualified on 7E18, and in-flight host TCP remains unqualified. |
| NAND crypto fidelity | Open | Plaintext generated stores still permit bypasses; prove encrypted restored-store execution through hardware engines. |
| Native boot arguments / N45 early touch | SYSIC touch masking corrected and older/newer runs pass | Native NOR/NVRAM handoff and downloaded touch firmware readiness remain research leads. Historical early-touch panic was not reproduced, so no readiness gate was invented. The incoming N45 four-page map-context fix removes the hard-stop FTLRestore corruption. Old-format baseline reproduces the kernel abort; two independent fixed-format reopens reach FTL_Open/BSD root without it. The retained 240-second baseline reaches a visible home screen. This was an out-of-bounds map restore, not an IOKit race. |
| Per-device service routing | Demonstrated hazard guarded and regression tested | Immutable per-device endpoint workers replace GUI C calls; stalled A does not block B, cancellation kills/reaps children, and a retired session cannot reopen. Native guest services pass 12/12. |
| Helper process ownership / cancellation | App fecd7a7 supplies one imported DeviceRuntime owner to GUI, helper, session CLI and lifecycle probes; actual builds, lease5/5, cancellation8 cases, preparation failure and affected offline probes pass | Current arm64 helper/dylib passes real2.1.1 two-boot lifecycle18/18; universal/Intel and release qualification remain separate. The existing transport/reaper is preserved. |
| Timezone lifecycle and children | Implemented and cancellation/deadline tested | BootSessionScope now owns readiness, recovery, staging, activation, installation, reset and synchronization tasks plus the observer. Controller orchestration can be reduced further as responsibilities stabilize. |
| Shared catalog / boot recipe types | Boot-field loss fixed and round-trip tested | Shared Foundation-only FirmwareWire preserves all catalog fields, including source resources. GUI does not import preparation machinery. |
| Developer SSH/SFTP/GDB | Automatic opt-in guest offer and per-instance keys; modern host SSH/SFTP passes on 5F138, 7A341, 7E18, 8C148 and 7B500 | Pinned-source shell and full source/license receipt are packaging-qualified. The legacy Bash ABI now passes actual SSH/SFTP and cold persistence on all four iPod builds; 1.x and 5.x remain unqualified. QEMU GDB uses an explicitly enabled stub; automatic GUI launch and application debugserver remain separate capabilities. |
| Native Finder discovery/media sync | Removed from scope at the user’s request | No virtual-controller adapter or entitlement request. Ordinary stopped HFS mounts and guest-mediated services remain. |
| Matrix evidence identity/publication | Implemented and real concurrent-process tested | Broader corpus execution and acceptance inventory remain ongoing engineering work. |
| Test prerequisites / real model coverage | Fourteen explicit production model suites established; MBX status/IRQ/reset/migration added. Exact visual references require independently qualified board/build/full-version provenance before guest launch | Explicit emulator test registrations replace source-text classification; physical flash, LCD, clock, radio, chip-ID and snapshot contracts now have actual model tests. Convert remaining high-risk DMA/IRQ/reset coverage incrementally. Skipped tests are not compatibility proof. |
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

FMSS physical-page and erase maps now migrate. Native 7E18 resume passes files, USB, clock, live graphics, audio and new HTTP requests; snapshots still require the exact storage generation and startup modes.
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

Candidate QEMU `7eadb42b54` adds the register-derived N72 root peripheral clock
and removes the direct-iBoot shared empty-literal argument patch. That patch also
redirected DeviceTree root lookup, so it erased the effective serial/model/region
handoff and changed the USB UDID. The existing argument data writer now discovers
promptly, refreshes at its normal cadence, and stops an unsuccessful search.
The app's shared boot recipe starts discovery without delay. The Swift/Python
ramdisk one-shot owns its `rd=md0` command line at the existing debugger handoff,
where it already stages RAMDisk and topOfKernelData; emulator argument injection
is disabled for that one-shot.

Evidence: 109 registered QEMU host checks pass (28 declared manual-input skips),
eight registered actual-board model suites pass without skips, and the Swift
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

### Additional October 1 contracts

N72 BCM HCI now stores BlueTool’s six-byte provisioned address instead of blindly
acknowledging it while returning a shared placeholder. Reads, invalid parameters,
HCI/board reset and partially received command migration pass UART1 qtests. The
native guest programs its generated MAC and BluetoothManager probes return in
9.7–10.5 ms. `/private/tmp/ltm-n72-bt-native/` and QEMU
`docs/research/ipod-bluetooth-address.md` preserve the scope and evidence.

A genuine ID3-tagged ADTS AAC fixture reproduced a second metadata-loss point:
conversion wrote only samples, then the importer read tags from that tagless M4A.
MediaSong now extracts tags and cover from its immutable source copy before
conversion. Its content identity uses those source bytes too, so two AAC files
with identical samples but different tags do not collapse into one import.
M4A and MP3 retain their previous byte-preserving identity. The host check covers
all twelve tags, baseline cover pixels, distinct AAC metadata identities and
stable repeated conversion. Native stock MediaPlayer decodes the imported cover,
and the library keeps full tags after hard-stop cold reopen at
`/private/tmp/ltm-aac-native-cold/`. Existing stripped imports are not rewritten;
remove/reimport to rebuild their missing tags/art.

The complete production Swift→AFC→guest path also passes for tagged ADTS AAC:
all tags and native artwork formats survive, retries leave one song, and the
guest confirms shutdown (`/private/tmp/ltm-aac-production-native-final.log`).
A controlled native test found the purchase API silently stores zero for
fractional durations; the guest adapter now rounds to positive whole milliseconds
before invoking that API. The same cold-reopen gate now requires exact duration
as well as tags and stock-decoded art (`/private/tmp/ltm-aac-duration-native-cold/`).
Payload serial 12 / 1.1.10 is the new candidate minimum. See QEMU
`docs/research/media-duration-contract.md`.

The native app harness now reads the prepared device’s machine settings and
separates its boot guest-package offer from flat upload tools. Its transport stubs
use the actual nonisolated contract. Qualification uses bundled service libraries;
the Homebrew library set returned AFC code 8 and is not counted as a passing
pipeline check. The candidate host gate passes 109 checks with 28 declared manual
input skips. All eight model suites passed for the clock/identity/BT code.


Fresh 5F138 follow-up: the production preparation and boot chain now work, and
the app's first-host activation handshake reaches a usable Home screen. The
headless session omitted that operation; it now uses the same child protocol.
Four AFC round trips, compatible cached IPA installation and guest-confirmed
shutdown pass in `/private/tmp/ltm-n72-211-handshake-pacman`. The remaining radio
identity defect is fixed in QEMU `69db528b32`: the card uses the unit's Wi-Fi MAC
and its Apple OTP carries the Bluetooth address. Native 5F138 now matches all
four generated identity values with Wi-Fi enabled, reaches actual Home and
powers off through the stock gesture. The complete matching bundled session
still needs requalification; these constituent probes do not certify it. The
3.1-only Harness IPA's BundleVerificationFailed result was a test input mismatch.
The shared Home judge rejects Connect to iTunes and preserves unknown when no
agent/reference evidence exists. Test helpers now use the app's signing identity
check by default, including ad hoc bundles, rather than requiring a maintainer
Team ID. Explicit test signing requirements remain available.

The shared boot recipe provisions both card addresses for new and existing N72
bases without modifying immutable storage. Its session identity gate checks
serial, UDID and both MACs with bounded retries. A legacy agent's `RB_HALT`
does not establish PMU power-off on 2.x; the native tests now select the stock
power sheet for those kernels. The existing legacy ABI toolchain can build all
five otherwise-omitted helpers, and the fitted 2.x agent reports Home correctly;
promoting that build across 3.x/4.x and into release packages remains pending.

Upstream fetch on October 1 found no new app commits beyond the already
integrated main/multidevice refs. The rewritten remote emulator history remains
separate from the coherent local ipad1 base; no unrelated history was merged.

### Legacy helper qualification (2026-10-01)

Guest package serial 13 / 1.1.11 now uses the existing legacy linker for one
armv6 helper set across 2.x–4.x. Stock 2.x's older SpringBoard launch API is
selected by export presence; injected it_typein is signed by its recipe and
unsigned package hooks are refused. Fresh 2.1.1, 3.0, 3.1.3 and 4.2.1 native
tests pass **18/18 each**, including actual installed-app foreground identity,
file/app persistence across cold reboot, generated serial/UDID/radio addresses,
automatic activation, Home and guest-confirmed power-off on both boots.
The test runner exposes `--single ... --launch --reboot` and judges those gates.
Evidence: `/private/tmp/ltm-n72-{211,30,421}-legacy13-signed-session` and
`/private/tmp/ltm-n72-313-legacy13-session`. The iPad's armv7 helpers are unchanged.
This closes the absent 2.x/3.0 core-helper seam; typing, clipboard, download
placeholders, media and developer SSH still require older-firmware API proofs.

### FMSS state migration (October 1)

QEMU `4a16474d1a` replaces the nonempty-FMSS-snapshot refusal with upstream
QEMU VMState GTree serialization. Four real-board qtests pass, including
RAM-only programmed pages, erase-map recovery with its disk fixture marker
removed, and startup-mode mismatch refusal. Version 4's certified-empty streams
remain accepted; older omitted-map streams remain refused. Generated FTL
relocation is still provisional and is not retired by this change.

Native 7E18 save/resume into a fresh process passes agent rekey, saved file,
clock, USB re-enumeration/pairing, continuing GL pixels/presentation and a separate
active stereo DMA/new Wi-Fi HTTP run. The final default tier passes 8/8. Evidence:
`/private/tmp/ltm-fmss-map-final-qtest2.log`,
`/private/tmp/ltm-fmss-tree-native-snapshot2.log`,
`/private/tmp/ltm-fmss-tree-audio-network-snapshot.log`,
`/private/tmp/ltm-fmss-tree-final-native-regress.log`.
The HTTP probe starts new requests; it does not certify open host socket migration.
The updated harness shares matched-device resolution with the default runner and
uses agent file/spawn plus stock lockdown clock services, requiring no guest shell.

### Physical combo-chip presence and iBoot rewrite retirement

QEMU `cbf1000344` deletes the Bluetooth UART-path string rewrite in iBoot.
Four native firmware lifecycle runs (2.1.1, 3.0, 3.1.3, 4.2.1) pass 18/18 each
with generated factory identity on both cold boots and untouched bootloader
code/literals. Their evidence is `/private/tmp/ltm-n72-{211,30,313,421}-no-btpatch-session`.

The network-disabled control exposed a remaining unfaithful device absence:
`wifi=off` removed the soldered BCM4325. Enumeration and OTP identity now remain
present regardless of host bridge policy. A disabled bridge has no NIC/backend;
it does not remove hardware. Four board SDIO qtests pass, and native save/resume
with networking off passes all four identity fields, guest files, clock and USB
pairing on every version above. 7E18 also keeps a live GL scene presenting.
The final default regression passes 8/8 and reports the expected UDID.
Evidence: `/private/tmp/ltm-n72-physical-combo-final-qtest.log`,
`/private/tmp/ltm-n72-{211,30,313,421}-physical-combo-snapshot`, and
`/private/tmp/ltm-n72-physical-combo-default-regress.log`.

This closes the rewrite and absence seams. The BCM dongle firmware remains HLE;
normal-boot command-line data injection and generated FTL relocation remain
explicit compatibility boundaries. Fetching upstream again at 10:00 UTC found
unchanged refs; no blind merge of the rewritten remote ipad1 history was made.

### Legacy developer shell and fixed-address translator retirement

The minimal-v2 GNU Bash recipe reserves iOS2.x's r9 thread pointer and proves
classic non-PIE bindings complete before removing LC_DYLD_INFO_ONLY, which
2.x dyld rejects. It retains Apple's SDK startup object, upstream GNU source,
all40 patches and complete notices. Independent scratch and production builds
produce the same qualified hash. Developer recipe revision2 updates existing
offers; GUI and composition now share one qualified-build predicate.

Production-composed offers install through the existing guest loader on
5F138, 7A341, 7E18 and 8C148. Every version passes authenticated stock host SSH
and byte-exact SFTP, then a cold reopen retaining the package, original keys,
shell and previously written files. K48 7B500 also passes SSH/SFTP with the
new shell and production offer. No new shell, SSH protocol or NAND writer was
added, and no support beyond these builds is implied. Pinned payload/source
audit and key-isolation/tamper tests pass. Evidence:
`/private/tmp/ltm-developer-v2-ipod-native`,
`/private/tmp/ltm-developer-v2-ipod-cold`,
`/private/tmp/ltm-developer-v2-k48-native`,
`/private/tmp/ltm-developer-v2-unit.log`, and
`/private/tmp/ltm-developer-v2-audit.log`.

QEMU `d1e43eb94c` removes 477 lines of optional fixed-address guest libc
substitutions and the ARM translator interception. The guest's memcpy/memmove,
memset and bzero execute through normal instruction translation. The default
native iPod regression passes 8/8, including stereo audio, live GL and two-boot
persistence. The iPad SSH/SFTP run uses this same translator. Evidence:
`/private/tmp/ltm-retire-tcg-hle-default-regress.log`. This retires two board
ledger P rows; it does not make guest GL/activation additions real hardware.

The matching clean-commit universal bundle before these last changes passes
hygiene, 32 provenance tests and the full 18/18 native lifecycle matrix on all
four iPod firmwares. The new final bundle must be rebuilt and regated after
commit/pin reconciliation; that earlier bundle is not proof of later source.

### K48 physical Wi-Fi presence and matched audio oracle

QEMU `a5e2c8c529` leaves the soldered BCM4329/SDHCI present with host
networking disabled, and does not attach a supplied wifi0 backend in that mode.
Startup policy cannot pretend to change physical topology at runtime. Three
board qtests pass enumeration, CIS identity, reset and host bridge controls.
Both SDIO boards now run through the explicit model gate: 10 suites pass,
no skips. The required iPod default gate remains 8/8.

Stock 7B500 enumerates/initializes the chip with no host NIC and reports all
four generated identity fields. Save/new-process resume retains identity, USB
and an exact guest file. The full iPad gate passes 9/9: boot/unlock/lock,
qualified Home GL comparison, USB/AFC, clean two-boot persistence, Wi-Fi, early
join, HTTP and four stock sounds. Evidence:
`/private/tmp/ltm-k48-physical-card-final-models.log`,
`/private/tmp/ltm-k48-physical-card-snapshot2`,
`/private/tmp/ltm-k48-physical-card-final-regress.log`, and
`/private/tmp/ltm-k48-physical-card-ipod-regress.log`.

QEMU `ddc2764bd6` replaces a missing, fixed host-mounted sound oracle with
references read through the tested guest's VFS. Standalone/default/snapshot
audio share this capture; older images without an agent need an explicit
matching extracted rootfs. Standalone audio reuses the existing Boot owner,
private overlay/NOR and child cleanup. Its real four-sound test passes; it
does not claim channel-order or all-version selector coverage.

The suspected fixed-default K48 Wi-Fi address overwrite did not reproduce:
stock firmware initializes with the generated unit address and lockdown matches
serial/UDID/both MACs. No new factory-address shim was added. The initial native
probe retried actual USB enumeration; the first missing-device sample is retained.
The snapshot's first private harness failed only in its duplicate imported
logging clock; the corrected full roundtrip passes.

Upstream refs were refreshed at 11:28 UTC; requested local targets remain
multidevice `af0c867` and ipad1 `fd5a1d0845`. Their working files remain untouched.
The rewritten remote ipad1 history remains deliberately unmerged.

### N72 DFU / ECID and final bundle gates

The matched universal ad-hoc bundle from clean app `8ba30bc`, QEMU
`a5e2c8c529` and usbmuxd `e19fac2` passes source/license hygiene, 32 release
provenance fixtures, and actual packaged 2.1.1/3.0/3.1.3/4.2.1 lifecycle
checks: 18/18 each. Logs: `/private/tmp/ltm-final-bundle-gates.log` and
`/private/tmp/ltm-n72-{211,30,313,421}-final-bundle-session`.

QEMU follow-up `ae75469472` models read-only N72 ECID fuse inputs at the
registers the stock ROM/iBSS actually read. Both unchanged defaults and
provisioned fuses survive reset and reject guest writes in production-board
qtests. All eleven model suites pass without skips and the required full
iPod default regression remains 8/8. Native stock ROM DFU → unmodified
5F138 iBSS recovery reports the configured ECID unchanged, and stock
idevicerestore can now select that emulated target. The next stop is the
host's old-IPSW suitability check, not completed restore. Automatic per-device
N72 ECID provisioning is still open; existing generated devices keep zero
defaults. See QEMU `docs/research/n72-dfu-recovery.md`.

The app source pin advances to that individually tested follow-up. A new
bundle's build receipt must match the new pin before its native lifecycle
result can be combined with the preceding qualification. The consolidated
[overnight notes](overnight-fidelity-2026-10-01.md) preserve what remains.

### N72 unit ECID provisioning, 2026-10-01

New N72 identities now include the existing seed-derived ECID; their machine
lock passes it to immutable CHIPID fuses. Legacy bases recover that same value
from their stored seed at the boot-recipe boundary without modifying the base,
serial/MAC/UDID, or N45 identity. Explicit machine ECID overrides win. QEMU pin
53e722ae63 carries the model and reusable stock SecureROM/iBSS identity test.
Swift identity tests (11) and the compiled production BootRecipe check pass;
CHIPID qtests pass 3/3 and default native 7E18 regression passes 8/8.

Stock 5F138 SecureROM and unmodified iBSS report the same unit ECID
`0x98e452f953`. This test uses a private all-FF NOR and NAND overlay and allows
USB reinitialization to settle. Tight descriptor polling reproduces a return
to DFU; its cause remains a transport/controller research lead. A private
host-only legacy Restore.plist compatibility experiment reached iBSS and
uploaded the ramdisk, then failed before DeviceTree upload. Full stock restore
and removal of generated FTL relocation remain open. Existing restored K48
cold-boot and graphics limitations are unchanged. A private universal bundle from app bb5e6e2 / QEMU 53e722ae63 passed
18/18 on a native 2.1.1 session, including foreground launch, persistence and
cold reboot. These results do not qualify later source changes.

The traced restore-ramdisk failure was an explicit fatal unknown GID KBAG
(`d39f8a35...1ea87bd`), not simply an unexplained USB loss. N72 key export
omitted restore components. Adding the catalog Update/Restore ramdisk keys on
a disposable clone lets the existing idevicerestore upload ramdisk, DeviceTree,
and kernel without that fatal error. Final boot still returns to DFU; no stock
restore completion or physical NAND replacement is claimed. N72 preparation
now exports available keys for all resolved normal/restore components, with a
production archive/component test covering both ramdisks. No firmware patch
or permissive unknown-key fallback was added.

### Complete restore crypto transfers (2026-10-01)

QEMU `d2fb06759a` removes the 16 MiB AES register clamp while bounding host
scratch storage to 64 KiB. Stock 5F138 iBSS decrypts its complete 25,313,280-byte
update ramdisk byte-for-byte against the catalog-key reference. The old
`Process 1 exec of /sbin/launchd failed, errno 8` panic was encrypted data left
in the ramdisk tail, not a missing RAM region or a guest executable patch.
Sanitized production-handler tests and the default native 7E18 8/8 regression
pass independently for this correction.

QEMU `31036cf8e9` fixes the same transfer-length issue in SHA DMA with bounded
buffers, raw block chaining, and unchanged guest-owned padding. A new test
reproduced the old register clamp and then compared the complete digest with
hashlib; interrupt and snapshot-state tests pass. Its separate default native
7E18 regression also passes 8/8. The app pins that verified QEMU revision.

An unmodified stock 5F138 restore ramdisk now runs `launchd` and two
`restored_update` processes after 60 seconds, without watchdog suppression.
Process presence is not a restore protocol success. The kernel USB trace waits
with RESET/ENUMDONE interrupts enabled while the retained recovery connection
receives descriptor NAKs. Actual host bus reset/re-enumeration is being tested;
no fabricated descriptor, forced guest completion, or production delay was
added. Rapid post-DFU polling separately reproduces a SecureROM abort/reset.
Physical N72 formatting, full restore, encrypted restored cold boot and removal
of generated-store FTL relocation remain open.

Before these crypto changes, the clean universal app ec3cdeb / QEMU 53e722
candidate also passed native 3.1.3 lifecycle gates 18/18. Its complete Mach-O
closure and ad hoc signature checks pass for the declared macOS 14.4 minimum.
Those packaging results do not qualify the subsequent crypto revision.
Evidence: `/private/tmp/ltm-aes-restore-default`,
`/private/tmp/ltm-sha1-restore-default`,
`/private/tmp/ltm-n72-ramdisk-aes-fixed/ramdisk-comparison.json`, and
`/private/tmp/ltm-n72-kernel-processes/processes.json`.

### Stock restore transport progress (2026-10-01)

The N72 stock restore daemon now replies on actual emulated kernel USB;
QEMU 5d1e9dfd9c fixes reset/re-enumeration and exclusive mux handoff. Reusing
LukeZGD idevicerestore's existing pre-iOS 3 support lets the original 5F138
firmware metadata reach restore mode without our earlier plist workaround.
A small private client lifetime fix is ASan/UBSan verified. Nothing installed.

The stock erase protocol starts but repeatedly reports Waiting for NAND (28)
on disposable empty storage in physical relocation mode. This is the next
measured blocker, not a successful blank-flash restore. N72 still synthesizes
absent-page bytes and infers erase from writes; trace the actual driver before
changing those contracts. Rapid DFU reconnect remains an independent failure;
the private probes explicitly retain diagnostic settling, absent from the
production bridge. Preserve generated FTL compatibility until full restore,
cold boot and durable later writes pass.

Detailed results and source pins are in fidelity-ledger.md and durable evidence
`/Users/shg/Developer/ltm-evidence/restore-usb-2026-10-01`. The separate clean
cc67737/31036cf8e9 universal candidate passes native 2.1.1 session 18/18 and
closure/signature checks; those results do not qualify later Swift edits.

### Host qualification owner and measured hardware follow-up

App b5e9af2 extracts cold-boot package qualification into GuestPackageSession;
actual owner/cancellation/oracle checks and actual app build pass. It reduces
controller responsibility, not a complete GUI/CLI shared-runtime module.

QEMU ace95b664b fixes the measured stock D4C parameter latch; real snapshot
qtests 4/4 and default native 7E18 8/8 pass. Further script operations remain
unsupported, so no restore completion follows. Independent N72 MBX fill
capture now agrees with pinned S5LBox code in sanitizer replay; post-stall
GART capture does not establish live graphics completion or full composition.
The consolidated new review is architecture-followup-2026-10-01.md.

The post-D4C stock capture confirms nand-enable-reformat=1 is already in
actual kernel BootArgs; the host argument-policy lead is not this blocker.
Dynamic tracing advances to unsupported D18. The app pins verified ace95b664b;
that does not qualify any subsequent hardware prototype.

## October 1 implementation evidence

The shared [qualification journal](fidelity-evidence-2026-10-01.md) records
current hardware and host contracts, commits, actual native/model checks and
remaining failure boundaries. Keep new gate receipts there rather than copying
them into both reports. Later evidence supersedes earlier research leads;
stock restore, raw graphics and hardware timing remain separately qualified.

## October 2 closeout additions

QEMU e2ce2d7b1d qualifies the distinct stock D20 main-address pointer write
through31 controller qtests, fourteen model suites and separate full2.1.1/3.1.3
eight-check runs. Physical erase restore still stops at D24; the decoded spare
producer must be established before that candidate can safely return.

App4f16464 and QEMU1837635068 record only successfully installed seeded hooks.
The actual guest-loader negative control and native Swift/Python corpus parity
pass. Thirty-seven affected preparation recipes request Prepare Again; old bases
are preserved. QEMU4a15968526 adds independently captured exact1.1/1.1.5 visual
controls and rejects malformed full versions. Normal GL candidates pass Boot
and strict three-scene graphics2/2 on each build, without widening thresholds.

Current development arm64 helper with QEMU3c85a3803e passes an actual2.1.1
two-boot session18/18, including persistent writes, unchanged prepared base
and guest-confirmed shutdowns. This does not promote older universal packages
or qualify stock GPU execution. Exact artifacts and limitations are recorded
in the shared qualification journal.

The final production-order audit found that N72/K48 installed the frontend
before saving .baked; older N72 backups were custom code and are not stock
oracles. App126ba26/QEMUc23c72542e preserve the true original file or cache-only
absence first. Loader14 and explicit capability admission are tested against
five firmware inputs, with actual3.0 present-file restoration/two clean boots.
All52 recipe revisions now require explicit reprepare for the new output.
Stock-software2.1.1 final shutdown remains failed; its earlier incorrect run
success is retained and the runner now fails required cleanup. These are
measured corrections, not full physical GPU/restore completion.

QEMU038490937b closes exact2.1.1/3.0 frontend coverage: ordinary explicit
frontend runs pass Boot/GLES2/2 each and all six pixel comparisons are0.000.
The independent3.0 capture also qualifies new loader14 with legacyseed13,
including two clean stops/persistence. Exact source/runtime/asset identities and
remaining failure boundaries are in the journal. Physical NAND restore, raw
GPUs, measured power/timing/wake and safe semantic-input extraction remain
open; none is upgraded by the host/frontend passes.
