# Holistic architecture and fidelity review

2026-09-30. Consolidated from four parallel read-only reviews of the application,
emulator, storage, guest services, dependencies, tests, and registered worktrees.
This is an engineering assessment and proposed direction, not an implementation
completion report. Findings below are from code inspection unless a prior
acceptance run is explicitly named. No new device or failure-injection tests ran
as part of this review.

## Product scope clarified during this review

The goal is a curated set of early iOS devices and their historically distinctive
experiences, not a promise to implement every device or every firmware. Current
scope is iPod touch 1G, iPod touch 2G, and iPad 1. Plausible expansion includes the
original iPhone, iPhone 4, iPod touch 4G, and possibly iPhone 4S. iOS 6 is a
provisional natural boundary; iOS 7 and A5 are later decisions rather than
commitments. Older proposal language about a grid of hundreds of builds must not
be treated as the current product requirement.

Preservation of stock behaviors matters more than catalog size: making/receiving
calls, SMS, the original Phone UI, Retina drawing, media sync, applications and
ordinary device lifecycle. Use representative firmware generations as regression
probes, with wider corpus runs when they expose hardware differences. Supporting
arbitrary firmware should be a benefit of good models, not a compulsory release
matrix covering every beta.

Recommended expansion sequence, subject to bring-up evidence:

| Target | Value | Architectural consequence |
|---|---|---|
| Current three boards | Finish storage, persistence and ordinary device use | Establish reusable controller/storage/service contracts before adding SoCs. |
| iPod touch 4G | Retina without the cellular subsystem | Investigate A4 board/display/driver reuse; shared silicon does not establish panel, GPU or firmware compatibility. |
| Original iPhone | Preserve early Phone/SMS experiences | Audit reuse from N45-era blocks and add the modem/telephony path; it is not merely an iPod board with Phone installed. |
| iPhone 4 | Retina iPhone and an iOS 6 target | Reuse A4 IP blocks where contracts match; add phone-specific wiring, sensors, audio and cellular integration. |
| iPhone 4S / iOS 7 | Optional later scope | A5 is a separate hardware milestone. Siri service availability is separate from emulating the device and displaying its stock UI. |

Apple's announcements establish the [iPhone 4's A4/Retina features](https://www.apple.com/in/newsroom/2010/06/07Apple-Presents-iPhone-4/),
the [iPod touch 4G's A4/Retina features](https://www.apple.com/ie/newsroom/2010/09/01Apple-Introduces-New-iPod-touch/),
and the [4S's dual-core A5](https://www.apple.com/newsroom/2011/10/04Apple-Launches-iPhone-4S-iOS-5-iCloud/).
The ordering above is an engineering proposal, not measured effort or a
compatibility guarantee.

For calls and SMS, model a **virtual cellular environment**. The stock guest
telephony stack should receive modem/network events and render its own Phone,
Messages, notifications and call history. Do not drive these experiences by
patching SpringBoard or directly opening an imitation incoming-call screen.
Separate modem transport/firmware from a scripted carrier/test peer. An initial
protocol-level modem stand-in is high-level emulation and must be labeled as such;
eventual firmware execution is a different fidelity milestone.

Begin with offline deterministic scenarios: registration, outgoing/incoming call,
answer/reject/hangup, busy/no-service, SMS send/receive and persistence. Then route
calls/messages between two virtual devices, including audio path and timing.
This preserves functionality without depending on a public legacy radio network.
Real carrier/VoIP integration is not necessary for that goal. Siri and other remote
Apple services need their own explicit compatibility/service policy; unavailable
servers must not be confused with a CPU or peripheral failure.

## Decisions to carry forward

1. iOS owns the FTL, partitions, filesystem, encryption policy, files, and media
   databases. The emulator owns the hardware that services its requests.
2. The emulator necessarily reads/programs/erases physical NAND. It must not
   relocate a write because it recognizes a logical filesystem page, edit a plist,
   or patch guest memory to accommodate a particular firmware.
3. A major-version regression is evidence to investigate: locate the first
   hardware/protocol divergence and fix that contract. Prove whether a failure is
   missing hardware behavior, legitimate OS behavior, guest-addition incompatibility,
   or host-client incompatibility before adding a version exception.
4. Adopt the requested access policy: **writable when stopped; read-only when
   running**. Enforce it through storage ownership and coherent views, not simply
   changing a mount flag on the same changing backing store.
5. Keep Light Touch the GUI. Device lifecycle, storage transactions, preparation,
   and service clients must also be usable by CLI, tests, and mount helpers.
6. Reuse existing protocol and persistence implementations where they fit. A
   dependency is worthwhile when it removes responsibility, not merely lines.

## Repositories, worktrees, and integration state

These are inspected Git states, not claims that every listed branch is actively
running. Worktrees/branch existence alone does not establish a live agent task.

| Checkout | Inspected revision | Meaning |
|---|---|---|
| `/Users/shg/Developer/LightTouchMac` | main `5d4eb9f` | Older single-device product; has untracked architecture/Finder proposals. Do not place multidevice implementation here by accident. |
| `/Users/shg/Developer/LightTouchMac-multidevice` | multidevice `8d2e98d` | Current integration branch. |
| `/Users/shg/Developer/ltm-audit-app` | detached `44a0649` | Consolidation candidate: Swift orchestration, cache integrity, strict prerequisites, typed boots, acceptance report. Not integrated into multidevice. |
| `/Users/shg/Developer/ltm-bundle-cleanup` | bundle-cleanup `8d2e98d` | Same inspected tip as multidevice; name does not imply pending differences. |
| `/Users/shg/Developer/ltm-rc1` | detached `3f892ad` | Prior release candidate; separate from current consolidation. |
| `/Users/shg/Developer/qemu-ios-ipad1` | ipad1 `7b92325bde` | Current emulator integration branch. Contains an untracked `contrib/ipad1-gles/` directory; not included in this assessment's verified changes. |
| `/Users/shg/Developer/ltm-audit-qemu` | detached `ecd789e2be` | Consolidation candidate: FMSS policy separation, watchdog, Python retirement, harness fixes, ANGLE evaluation. Not integrated into ipad1. |
| `/Users/shg/Developer/qemu-ios-rc2` | detached `7b92325bde` | Release worktree at current primary emulator tip. |
| `/Users/shg/Developer/qemu-ios` | ipod_touch_2g `aa3c52d913` | Older iPod integration line; inspect ancestry before bringing changes across. |
| `/Users/shg/Developer/universal/LightTouchMac` | universal-intel `09096a7` | Separate universal release line. |
| `/Users/shg/Developer/universal/qemu-ios` | universal-intel `d41f872` | Matching architecture/release work; not the current multidevice emulator. |

Relevant unmerged NAND work includes QEMU `n45-fmc` (`988ae54`) and
`ae19-fmss-writepath-wip` (`74cd719`). Audit their command/sequencer changes before
starting a replacement FMSS/FMC implementation. Older `ipod-nand4`/`night-nand`
names must not be assumed to contain new pending fixes. Intel startup/boot-budget
branches also overlap lifecycle code; preserve their evidence during integration.

Prior test evidence was relocated from temporary directories to
`/Users/shg/Developer/ltm-evidence/fidelity-2026-09-30` and
`/Users/shg/Developer/ltm-evidence/audit-2026-09-30`. The consolidation report still
contains historical temporary paths. Preserve provenance while fixing those links.

## Writable stopped access and read-only running access

The proposed UI is good. Its implementation needs three distinct views:

| State/view | Owner and guarantee |
|---|---|
| Guest running, live read-only view | Guest services execute reads through the guest VFS. Results are current per operation; not a transactional snapshot of an active database. |
| Guest running, frozen read-only view | Capture a coordinated storage generation and mount its logical export. It is an explicitly labeled snapshot, not continuously updated storage. |
| Guest stopped, editable view | Exclusive edit lease; stage logical volumes read-write, eject/check, apply edits, then publish a new storage generation. Boot cannot race this transaction. |

"Stopped" must mean no guest/helper writer remains, or an explicit maintenance
mode owns storage. CPU pause alone does not flush guest filesystem caches.
Backend `msync` makes completed backend writes durable, not the guest filesystem
clean. A hard halt needs journal recovery on staging before editing. A host
read-only mount of storage being changed by another writer is not coherent.

The boot transition must wait for open writable views to eject and commit. Failure
leaves the original generation usable; it does not boot with a half-applied edit.
Any RAM snapshot tied to the old generation is invalidated. NOR, page/spare bytes,
and storage metadata must belong to the same generation where they are coupled.
Sharing the existing device lease across export, edit, maintenance, delete, restore,
and boot is preferable to inventing another lock convention.

Existing `VolumeExport` already clones/reconstructs logical volumes, repairs a
staging copy, and uses `hdiutil` plus the stock macOS HFS driver for Finder mounts.
No new filesystem driver is needed for these stopped logical images. However:

- `VolumeExport.swift:10` delegates stopped/lease enforcement to the caller, while
  `FirmwareKitCLI/Volumes.swift:39` calls it without acquiring that lease. An
  otherwise read-only export can be inconsistent if it samples a changing overlay.
  A multi-file clone is not automatically a point-in-time storage snapshot.
- Durable edit intent, clean-state markers, and snapshot invalidation described in
  `docs/filesystem-f0-findings.md` are largely proposed rather than implemented.
- `VolumeRebuild.swift:29` recognizes N72 and K48 formats, not N45's bank layout.
  Expose storage-format capabilities; do not advertise generic iPod support.
- Host editing needs a metadata contract: `VolumeMount.swift:12` documents
  `noowners` and ownership repair during preparation. Finder/editor atomic saves
  can replace an inode. Preserve existing ownership/modes/xattrs/hardlinks and
  define ownership for new files; "write in place" is not a sufficient rule for
  arbitrary editors. Test case-sensitive paths and symlinks too.

Prefer applying staged file changes through stock guest drivers in a maintenance
ramdisk. That keeps the FTL and crypto in iOS. A transactional host rebuilt-store
writer is possible as a provisional route, but it retains a second writable
FTL/crypto/format implementation. Never insert changed logical blocks directly into
physical flash without translating through the real ownership model.

## Concrete storage and fidelity findings

| Priority | Finding | Evidence | Improvement and gate |
|---|---|---|---|
| P1 | iPad NAND flush errors do not reach the app's storage-failure state. The sync function reports success even after errors. | audit-qemu `hw/arm/s5l8930_iop.c:1433–1441`; `contrib/ios-app/qemu-ios-ui.c:307` only queries FMSS/NOR failures. Also present on primary. | Sticky shared storage-error reporting, accurate halt result, page/ownership durability ordering; inject failed flush/full-disk cases and require visible failure. |
| P1 | Offline export's stopped-storage contract is unenforced at the CLI boundary. | audit-app `VolumeExport.swift:10`, `FirmwareKitCLI/Volumes.swift:39`. | Acquire the shared lease in the reusable API boundary, not just GUI callers; boot/export/edit/delete race tests. |
| P1 | N72 persisted writes undo the guest FTL and depend on a generated layout. | primary FMSS `:690`; consolidation retains relocation and physical-session cache. | Restore-created physical flash; execute actual commands and preserve spare bytes. Gate large installs, deletes, relocation, cold reboot, restore, interrupted writes. |
| P2 | iPad NAND programming uses overwrite semantics; all-zero pages are treated as erased. | audit-qemu `s5l8930_iop.c:340`, `:427`. | Model NAND bit transitions, explicit erased state, chip geometry and command rules. Distinguish a hole from programmed zero data. |
| P2 | FMSS physical-page/erased-block state is omitted from migration. | audit-qemu FMSS `:1423`. | Migrate/reconstruct the actual state or refuse unsupported snapshot operations; boot persistence alone does not prove RAM-snapshot equivalence. |
| P2 | NAND FIFO AES is bypassed because generated stores are plaintext. | audit-qemu `s5l8930_cdma.c:92`. | Keep crypto execution in the hardware model and logical extraction in guest services. Existing plaintext export evidence is not a promise for restored encrypted storage. |
| P2 | Early host touches can interfere with N45 multitouch firmware loading. | Consolidation acceptance report: AppleMultitouchSPI panic before the harness was gated; `ipod_touch_multitouch.c:288`, `:891`. | Investigate controller readiness/ATN protocol through traces; quiet boot passing fixes the stimulus, not the hardware contract. |
| P2 | N72 boot-argument compatibility writes remain. | audit-qemu `ipod_touch_2g.c:1170`; isolated no-injection NVRAM probes failed to deliver native arguments. | Trace real iBoot NOR/NVRAM consumption; remove memory injection only once native delivery passes older and newer builds. |

Evaluate upstream QEMU `hw/block/nand.c` before designing a new flash store: it
already uses `BlockBackend`, models AND-style programming, and handles block I/O.
It is not a drop-in FMSS/H2FMI replacement; geometry, spare layout, crypto, controller
commands and timing must still fit. Share physical storage contracts beneath the
controllers, not a firmware-specific logical mapping above them.

Clock trees, PMU sleep/resume, display timing, Wi-Fi firmware protocols, and real
GPU execution remain fidelity opportunities. Prioritize observed divergences and
cross-version contracts rather than working down a stub count mechanically.
Security tied to unavailable silicon needs declared stand-ins; activation,
AppSync, developer services and graphics additions remain explicit product
accommodations, not evidence of unmodified-device fidelity.

## Guest, host, GUI, and service ownership

| Layer | Owns | Must not own |
|---|---|---|
| Hardware emulator | SoC/IP blocks, board wiring, CPU/DMA/IRQ/timing, physical flash commands, USB endpoints | File paths, plist edits, FTL relocation policy, firmware-build fixes |
| Flash backend | Physical page/spare persistence, erased state, errors, flush/ownership/generation | HFS or media databases |
| Stock guest | FTL/VFL, partitions, HFS, crypto/filesystem policy, applications and databases | Host GUI policy |
| Guest additions | Necessary GL bridge, narrow app-integration agent, optional developer tools | Hidden replacement hardware behavior |
| Host services library/worker | Lockdown/AFC/install/backup clients, immutable device identity/endpoint, deadlines and capabilities | Global endpoint switching or UI presentation |
| FirmwareKit | IPSW/keys/identity, preparation or restore orchestration, addition provisioning, offline inspection | A competing live filesystem writer |
| Light Touch | GUI, device library, workflows and presentation | Device protocol reimplementations or raw NAND editing |

**Service isolation is a correctness issue.** The current `DeviceGate` switches
process-global `USBMUXD_SOCKET_ADDRESS`. Its own comment admits an abandoned C
worker can reconnect after the switch to another daemon
(`LightTouchMac/Transport/DeviceExecution.swift:239`). The abandoned-worker cap is
also process-global. This is a code-identified hazard, not a reproduced cross-device
write in this review.

Use a killable per-device service worker with an immutable endpoint and UDID, or
an upstream per-client endpoint API if one can replace global routing. Prefer a
worker separate from QEMU: restarting blocked host libraries should not stop the
guest. Share one typed service contract across GUI, CLI and mount clients, bound
to the device/session generation. Stock services remain useful even when the
custom agent is unavailable; negotiate each capability separately.

`EmulatorController` currently combines roughly 1,850 lines of lifecycle,
readiness/recovery, activation, package offers, input, storage, installs and UI
status. Extract ownership and cancellation boundaries, not just extension files.
Lifecycle completions must be tied to the initiating boot generation. Preserve
the existing one-QEMU-helper-per-device process isolation.

Micro examples: `EmulatorController.swift:654` installs a time-zone block observer
on each start without retaining its removal token and launches untracked tasks.
Connection-recovery cleanup at `:189` is not uniformly generation-owned. Centralize
observer/task disposal per boot and test restart while these operations are pending.
The locationd cache workaround in `GuestServices.swift:139` belongs in a recorded
guest compatibility adapter, not in hardware or generic transport.

## Reuse for filesystem, terminal, debugging, and sync

| Capability | Existing system to evaluate/reuse | Limitation/gate |
|---|---|---|
| Stopped Finder volume | Current VolumeExport + hdiutil + stock HFS driver | Add lease, editable transaction and N45 capability; logical export is not raw NAND. |
| Live media/app documents | Stock AFC/house_arrest + libimobiledevice; ifuse for mounting | Scope is media/container access, not root. Test legacy service availability. |
| Developer terminal/SFTP | Compatible guest OpenSSH + iproxy/inetcat | Real SSH server in guest; pin binaries that load on 1.x–5.x. No custom shell protocol. |
| Full-root live view | Guest SFTP + SSHFS, or AFC2 where it fits | Metadata/write/rename/disconnect semantics must be tested; AFC2 is an added guest service. |
| Application debugging | Guest debugserver, developer image/service, compatible debugger | Legacy ARM and service compatibility are separate from modern tool availability. |
| ROM/kernel/IOP debugging | Existing QEMU GDB stub | Independent of guest daemon availability; expose a per-device endpoint. |
| Native Finder device sync | Apple's discovery/pairing/transport integration | Private usbmux is not native discovery. First prove supported attach/detach/pairing with physical devices coexisting. |
| Flash backing/COW/flush | QEMU NAND + block infrastructure | Preserve flash semantics; benchmark before imposing qcow2 or a new format. |

Keep the agent for frontmost-app/orientation/pasteboard and other integration not
provided by stock services. Adding SSH must not move all GUI operations through
shell commands. Existing OpenSSH infrastructure is not a guarantee a current
server binary runs on these old guests.

The historical OpenSSH 6.7p1 ARMv6 image under `qemu-ios-files/ssh` demonstrates
7E18 feasibility, but carries obsolete libmis/cache changes, pre-generated host
keys and an old boot-address workaround. Reuse tested upstream components, not
that entire image's provisioning policy. Verify SFTP explicitly; a historical SCP
shell test does not establish modern client compatibility.

**Correction to the preceding assessment:** `itmedia` is about 215 lines and
`itphoto` about 229; the media helper delegates database mutation to guest
MusicLibrary services. SQLite reads reconcile retries. It is not a custom host
database writer. Its verified 7E18-only method is a compatibility boundary to
broaden through evidence. Replacing it with libgpod could increase schema/checksum
ownership. Native sync could retire it after that path is proven.

Existing FSKit/macFUSE and native Finder feasibility notes need updating. macFUSE
now has a user-space FSKit backend; the project deployment floor still needs a
separate compatibility decision. Apple documents a restricted entitlement-request
route for `IOUSBHostControllerInterface`; this changes "impossible" to a bounded,
unproven feasibility investigation. Entitlement availability is not proof Finder
accepts a virtual legacy iPad. Do not replace system usbmuxd, patch Finder, or fake
a physical device's identity as the product's default integration strategy.

ANGLE's native Metal probes pass, but the transport, surfaces, object tracking,
snapshots, and guest-specific formats remain ours. Keep CGL until a guest-level
backend comparison demonstrates compatible output and enough simplification or
stability improvement. A real GPU model is a separate research effort.

## Smaller architecture and evidence repairs

- Share core catalog/recipe/lock types. The app's recipe omits `boot`, while
  FirmwareKit's recipe accepts it; `PreparationJob` re-encodes the app model into
  an entry file. A catalog boot override can be silently lost in GUI preparation.
  Gate a round-trip through the actual app-to-CLI boundary.
- Bind matrix results to source/binary hashes, catalog digest, guest manifest and
  judge version. `matrix.py:635` currently skips by entry ID alone; stored tool
  paths do not identify the code that ran. Preserve all runs rather than replacing
  failure evidence with reruns.
- Give test tiers explicit prerequisites. `tests/gate.sh` uses source-text searches
  to classify emulator-dependent tests and omits some from all normal tiers.
  Add qtests/real-device-model tests for DMA, IRQ ordering, reset and pending timers;
  extracted C tests are useful but cannot establish all integration behavior.
- Define cache pruning under the same cross-process ownership rules as production.
  Matrix/PreparationJob cleanup still targets legacy SHA1 paths. Settings already
  removes the whole Decrypted parent, so claiming it cannot see format 2 is wrong;
  the issue is safe coordination with external CLI users and retention policy.
- Reconcile STATUS, smoke/fidelity ledgers, catalog support and actual pins. Some
  documents describe retired GL/AppSync/Python paths as current. Generate factual
  inventory from artifacts; keep architectural explanations written by humans.
- Complete a release gate with the final bundle and supported host OS: development
  Homebrew linking and ad-hoc helper acceptance do not certify deployment targets,
  dependency packaging or distribution signing.
- Keep SoC/IP-block reuse distinct from board identity. New Retina and phone
  boards should reuse only matched controllers, with separate panel, sensors,
  audio and modem wiring. Avoid a broad plugin framework or cosmetic directory
  shuffle before these actual hardware/service contracts are clean.

## Sequence and acceptance

| Step | Deliverable | Acceptance |
|---|---|---|
| 1 | Integrate the reviewed consolidation with exact pins and evidence links | App/helper/emulator build; strict selected corpus; current six-device baseline; native session checks. |
| 2 | Shared storage lease/error/generation contract | Export-vs-boot/delete/edit races fail safely; failed flush is visible; no false durable-success result. |
| 3 | Stopped editable staging, running read-only service/snapshot | Finder plist edit round-trip; metadata preserved; commit interruption recoverable; boot waits for eject; RAM snapshot rejected after edits. |
| 4 | Restore-backed physical NAND on one board/build | Restore → boot → activation → graphics → install/delete → shutdown/reboot; interrupted-write recovery. Extend the corpus before deleting old writers. |
| 5 | Per-device service workers and developer endpoints | Device A's stalled call cannot route to/degrade B; worker restart preserves guest; CLI SSH/SFTP/debugger access. |
| 6 | Remove proven-obsolete compatibility code | Retire relocation, inferred erase and boot-memory writes individually with older/newer regression evidence. |
| 7 | Native Finder discovery feasibility and sync | Supported discovery/pairing route; two virtual and one physical device coexist; backup/media sync verified separately. |

These steps overlap where independent, but writable host access should not wait
for a perfect emulator. It can ship as an explicit staged transaction while the
physical-flash and restore paths improve underneath it.

## Primary external sources

- [QEMU NAND implementation](https://github.com/qemu/qemu/blob/master/hw/block/nand.c)
  and [disk-image infrastructure](https://www.qemu.org/docs/master/system/images.html).
- [ifuse scope and requirements](https://github.com/libimobiledevice/ifuse).
- [libusbmuxd forwarding and endpoint configuration](https://github.com/libimobiledevice/libusbmuxd).
- [OpenSSH capabilities](https://github.com/openssh/openssh-portable) and
  [libimobiledevice services](https://github.com/libimobiledevice/libimobiledevice).
- [QEMU system debugging](https://www.qemu.org/docs/master/system/gdb.html).
- [macFUSE backends and limitations](https://github.com/macfuse/macfuse/wiki/FUSE-Backends).
- [Apple IOUSBHostControllerInterface entitlement discussion](https://developer.apple.com/forums/thread/802495).
- [Apple Finder synchronization](https://support.apple.com/en-gb/102471).

External tools establish existing capabilities, not compatibility acceptance for
our emulated legacy devices. Every proposed replacement still needs its stated gate.
