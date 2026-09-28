# Guest-package bootstrap

Status: built, 2026-09-28 (STATUS.md "Guest-package bootstrap": loader, versioned packages and rollback in the
emulator, the preparer and the app; `tests/check-sessions.py --guest`). Sections 1–7 are the design; the app
side as built is in "P5, the app" at the end. This is the "guest package bootstrap contract" that
`device-firmware-modularization-plan.md` (an uncommitted 2026-09-27 proposal, on no branch) called for in its M2,
next to [multi-device-plan.md](multi-device-plan.md).

**Goal:** upgrade our guest helpers without re-preparing the device, detect stale guest tools, and roll
back a bad package.

## Constraints found

- **The iPad has no agent channel.** `hw/arm/ipad1.c` handles only GLES and pasteboard calls, so upgrades
  can't be delivered through the agent on both boards.
- **AFC can only write under `/var/mobile/Media`.**
- **Staging files into the NAND overlay is unsafe:** the overlay holds raw FTL pages.
- **The hypercall ABI is frozen:** 52 bytes, args ≤ 32. New ops reuse `qc_ag_args_t`, and unknown call
  numbers already return -1 on old emulators.
- **dyld refuses a missing or non-root-owned `DYLD_INSERT_LIBRARIES` dylib**, so stock jobs can't point into a
  package directory that might be absent.

## 1. What is baked and what is packaged

| Class | Items | Where |
|---|---|---|
| Firmware transforms (baked) | fstab, SpringBoard env, DYLD_INSERT entries, AppSync cache patch, dyld override switch (4.x), BTServer off, PAC/network prefs | stock paths |
| Prepare-only one-shots (baked) | it_seal, keybag one-shot, it_gltest | `/usr/local/bin` |
| **Loader** (baked, minimal, not upgradeable) | `it_boot` + `com.qemu.it-boot.plist` (RunAtLoad) | `/usr/local/bin`, LaunchDaemons |
| Seed package (baked copy) | the package bundled at prepare time | `/usr/local/lighttouch/pkgs/<serial>/`, `current` → it |
| Hook-point files (seeded, package can override) | GL shim (GLEngine/MBXGLEngine), gld plugin, it_typein.dylib, libappsync.dylib, it_msmquiet.dylib | stock paths, plus a `<path>.baked` copy |
| Package | it_agent (iPod), it_pbd, it_ethlink, it_prefs, itmedia, itphoto, ittrust, sbdlicon + jobs | `pkgs/<serial>/{bin,lib,jobs}` |

Package state lives on the **system volume**, which is physically in the per-device overlay. It never goes
in `/var`, because the guest's own Erase reformats `/var` and it's mounted nosuid.

## 2. Format and versioning

- **Host side:** one `Resources/guest/<arch>.itpack` per arch, holding one package per ABI family:
  n72-ios2, n72-ios3, n72-ios4, k48-ios3 and k48-ios4.
- **Manifest (JSON):**
  - `serial`: a monotonic integer used for every comparison;
  - `version`: for display only;
  - `family`, `arch`;
  - `requires {boards, builds, link, host protocol ranges}`;
  - `provides`;
  - `files [name, mode, sha256]`;
  - `jobs`;
  - `hooks [file, target, gli id, respring]`.
- **Checks happen three times:** at package build (Mach-O shape, signatures), at offer composition in the
  app (board, build, the GL engine id recorded in device.lock.json, protocol overlap), and at install in the
  guest (`kern.osversion`, size and hash).

## 3. Delivery and activation

**New hypercalls**, in a shared `hw/arm/guest-package.c` wired into both machines:
- `QC_PKG_OFFER 0x170`: the offer text;
- `QC_PKG_READ 0x171`: a file by index, in windows of ≤ 1 KiB;
- `QC_PKG_REPORT 0x172`: the serial and a result code.

The host serves a directory the app composes, named by the `guest-package=Devices/<uuid>/work/guest-offer/`
machine property. The guest never sends a path.

**The offer** is line text:

```
ltpkg 1
build 7B500
serial 14 1.4.0
verdict good 13 | bad 12
file 0 bin/it_pbd 755 <size> <sha>
job  1 jobs/com.qemu.it-pbd.plist
hook 2 /System/.../GLEngine 755 <size> <sha> respring
```

`serial 0` means revert to the seed package (safe mode).

**`it_boot`** runs at every boot. It is fail-open: on any error it loads `current` unchanged.
1. Read its state.
2. Pull the offer, bounded to about 10 s.
3. If the offered serial differs, stage `pkgs/<s>.tmp/` with fsync, rename it into place, then flip the
   `current` symlink atomically.
4. Apply the host's verdict: `bad`, or 2 failed attempts with no verdict, reverts to the previous package or
   the seed.
5. Apply hooks by rename, keeping the `.baked` copies. Respring once if a respring hook changed.
6. Unload the previous package's jobs and load the current ones.
7. `sync`, then REPORT.

**Rollback is decided by the host:**
- `good` after a healthy session: uiReady, agent ping or pb alive, and a GL hello when a GL hook was offered;
- `bad` when uiReady doesn't come within the budget, or GL doesn't come up.

**Recovery, in the app:** Restart with previous tools, then Start with built-in tools (`serial 0`), then Erase.
A broken loader means the base is broken, and the fix is re-preparing.

**Live upgrade on the iPod:** the agent spawns `launchctl start com.qemu.it-boot`. On the iPad, upgrades apply
at the next boot.

## 4. State, Erase, snapshots

- **`device.json`** gains `guest {seed, active, lastGood, bad[]}`.
- **The per-boot offer** lives in `work/guest-offer/` and isn't durable.
- **App Erase** deletes the overlay, so the device falls back to its seed package, and the next boot pulls the
  current offer.
- **Snapshots:** an install writes flash, so the existing `overlayIsNewer` logic already discards stale
  snapshots.

## 5. Version handshake

- **The package:** the helper publishes status slots `guestPackage`, `guestPackageState` and `glesProtocol`,
  with a layoutVersion bump.
- **The agent:** `ping` returns `it_agent <proto> <serial>`.
- **GL:** a new `QC_GLES_HELLO 0x142 {proto, serial}` at context creation. A shim with no hello counts as
  proto 0, today's wire. The host keeps serving protos N and N-1.
- **HelperInfo** gains `guestProtocols` ranges.
- **The app:**
  - it upgrades silently when the reported serial is below the bundled one;
  - it shows "Guest tools out of date — restart to update" when a GL proto is out of range, instead of
    black scenes;
  - it shows a "legacy baked tools" state when no report arrives.
- **This retires** the `.lt-guest-tools-v2` marker and `hasGuestTools` as a proxy.

## 6. GL shims

The shim is bound to the firmware's dispatch table and must be present before SpringBoard.
- Bake seeds it, and a package may override it only with the engine whose `gli` id matches the one recorded
  at prepare.
- A boot that changes the engine costs one respring. Rejected alternative: wrapping SpringBoard with the
  loader, which would make the loader boot-critical.

## 7. Migration (about 10–14 days)

| Phase | Work | Effort |
|---|---|---|
| P0 | Tag every baked item with its class | 0.5 d |
| P1 | Guest-tools build emits per-family manifests + `.itpack`; loader built legacy-linked for 2.x | 1–1.5 d |
| P2 | QEMU `guest-package.c`, the `guest-package=` property, `QC_GLES_HELLO` + proto 0, status slots | 1.5–2 d |
| P3 | `it_boot` in C (libSystem only), with a host test using a fake `qc()` | 2–3 d |
| P4 | Preparer (Python and Swift together): loader + seed package + `.baked` copies | 1.5–2 d |
| P5 | App: offer composition, `device.json guest`, verdicts, UI states; delete `updateMediaComponents` and the marker | 2–3 d |
| P6 | Existing devices: adopted iPod images get the loader through the old path once, and `nand.itnand` is re-bundled; already-prepared iPads stay on frozen tools (said plainly in the UI) | 1 d |

**Risks:**
- one respring on upgrade boots;
- a bad hook dylib is only caught one boot late;
- the 2.x link constraints, and CommonCrypto availability there;
- any guest process can read the offer or spoof a REPORT, which affects UI status only;
- about 5 MB of system-volume space.

## P5, the app (2026-09-28)

- **The itpacks ship in the flat `Resources/guest-tools`** (build-guest-tools.sh builds them with qemu-ios
  `contrib/guest-package/build.sh` into the iPad set), not `Resources/guest/`: firmwarekit seeds from the
  same directory. Development builds read `LTM_GUEST_PACKAGE` or a qemu-ios checkout's `build/guest-package`.
- **Each boot composes `Devices/<uuid>/work/guest-offer/`** (`GuestPackage.compose`, byte-identical to
  mkpkg.py `offer`; tests/check-guest-package.py uses it as the oracle) and passes `guest-package=`. The
  family is the itpack's for the device's board and build; stubs, other builds and a guest-package
  protocol outside the manifest's `requires.host` get no offer. With a device.lock.json, hooks are dropped
  as the seed did: another GL table than `guest_package.gli`, or a target missing from `guest_package.hooks`.
  The property is passed only when the helper's dylib exports the report (status slot
  `guestPackageSupported`), since an older dylib rejects it.
- **The helper publishes the report** (`qemu_ios_guest_package_report`, `qemu_ios_gles_protocol`, both
  optional dlsyms) as status slots `guestPackageReported, guestPackage, guestPackageState, glesProtocol,
  glesSerial`; layoutVersion 2. The `guest-package-status` text (prev/good/tries/seed) isn't read: the seed
  comes from the lock.
- **device.json `guest {seed, active, lastGood, bad[], builtIn}`.** `active` is every report's serial.
  Verdicts (`GuestPackage.verdict`): healthy for 10 s with a report is `good` (the iPod: uiReady and the
  agent alive; the iPad: uiReady and lockdown, because the dylib exports no pasteboard-agent status); no
  healthy session within 300 s is `bad`, except for the seed and the last good serial. No report after
  30 s of health is **legacy baked tools**. A restored snapshot never re-runs the loader, so it judges
  nothing; it shows "out of date" when `active` is older than the bundled serial.
- **UI:** the status line says "Guest tools out of date — restart to update" (older than the bundled
  serial, a failed install, or a GL wire outside the host's range), "Previous guest tools" (the loader
  reverted or refused) or "Built-in guest tools". Device ▸ Restart with Previous / Built-in / Latest
  Guest Tools records the choice (`bad` += the running serial; `builtIn` = the bundled serial, offered
  as `serial 0` until a newer bundle; or clear both), discards the snapshot, powers off cleanly and starts
  a fresh helper. Not a guest reset: after `system_reset` a fresh 7E18 once stayed on the Apple logo.
- **The app no longer touches packaged components.** `updateMediaComponents` (GuestServices) returns at
  once when a report arrived or the agent's own job runs it from `/usr/local/lighttouch/`; on a legacy
  image it upgrades the agent at the path its job names. Media helpers run from `current/bin` when packaged.
  The `.lt-guest-tools-v2` marker was never read by this branch; its stand-in (`nand` contains
  "ultimate") went with the script installer in P2.
- **Verified headless** (tests/check-sessions.py --guest): on a fresh no-shell 7E18 (seed 1, P4) the
  loader installed the bundled serial 2 (R_INSTALLED), judged good; after `verdict bad 2` and a fresh
  helper it reverted to 1 (R_REVERTED_BAD). The shipping image (no loader) reports nothing: legacy.
