# Filesystem / Finder integration: F0 findings

Status: investigation result, 2026-09-28, for `filesystem-finder-integration-plan.md` (an uncommitted 2026-09-27 proposal for root-filesystem access and Finder integration; on no branch).
F1 core is built (see "F1 core results" at the end); nothing else is.

## Headline

Offline access needs no new filesystem technology:
1. rebuild each logical volume from base + overlay into a private sparse raw image;
2. `hdiutil attach` it, so the kernel's own HFS+ driver handles the journal, HFSX case sensitivity, hard links,
   xattrs and compression.

FirmwareKit already has most of the host side:
- **iPod:** `imgtools/dumpvol.py` plus the overlay.
- **iPad:** a YaFTL scan, largely already walked by `K48NANDCheck`.

## Storage contract, additions to today's code

- **Lease:** the helper takes `flock(Devices/<uuid>/work/lease)` with `LOCK_EX|LOCK_NB` before it answers hello
  (done on `storage-fixes`: a second helper is refused with "in use by another Light Touch", and the app holds
  `State/.app-lock`). Exports take `LOCK_SH` only while they clone.
- **Edit intent:** a durable `work/edit.json` for an edit session. Boot refuses to start until it's resolved.
- **Clean marker:** write `overlay/.clean` after `shutdownConfirmed`, and delete it at boot. That's the only way to
  tell a clean stop from a crash after the fact.
- **Export:**
  1. take `LOCK_SH`;
  2. `clonefile` the overlay;
  3. release the lock;
  4. rebuild into a sparse image;
  5. run `fsck_hfs -fy` on the staging copy;
  6. attach it read-only.
  The source files are never opened for writing.
- **Snapshots:** any commit explicitly deletes the RAM snapshot. Don't rely on mtimes: a clone keeps them.
- **Erase:** refuse while a lease or edit intent exists, and delete `work/export-*`.
- **App wiring (not done yet; mount/export isn't in the app).** When it is wired in, it must:
  - put every image and staging directory in `Devices/<uuid>/work/export-*`, never in a temp dir or beside the
    base, so Delete Device and the launch sweeps find them;
  - on any failure, detach what it attached and delete its `export-*` directory before reporting the error;
  - make Erase and Delete Device refuse while one of the device's images is attached (`hdiutil info` names an
    image under its `work/export-*`), and say so, instead of removing files under a mounted volume.

| State | Allowed | Label |
|---|---|---|
| Running | AFC / guest service; snapshot by clone during a VM pause (F4) | crash-consistent |
| Stopped, `.clean`, no RAM snapshot | read-only export or mount; exclusive edit | clean |
| Stopped with a RAM snapshot | export only; edit after the snapshot is discarded, or after resuming and shutting down | crash-consistent |
| Stopped without `.clean` | export a copy repaired in staging | crash-consistent |

## Transport

- **F1/F2:** `hdiutil` + the built-in HFS driver. It's the only option already written that covers the macOS 14.4
  floor.
- **Live:** AFC in the app's Files browser, as today.
- **A live Finder volume of the whole root:**
  - defer it: it needs a guest file daemon, which sits on the guest-package bootstrap;
  - if it goes ahead, prefer an NFS loopback while the floor is 14.4;
  - revisit FSKit once the floor reaches macOS 26, because URL resources need 26 and programmatic mounting needs 27.
- **Rejected:**
  - File Provider and SMB: they break case sensitivity;
  - macFUSE: it needs a kext.

## Native Finder device recognition

**Not feasible with generally available APIs.**
- Finder only sees devices through the system usbmuxd, and our device is a TCP stream into a forked usbmuxd.
- The one public path is a synthetic USB device via `IOUSBHostControllerInterface`, which needs the restricted
  `com.apple.developer.usb.host-controller-interface` entitlement.
- It would also need unique UDIDs per instance, and Finder may not handle iOS 3/4 at all.
- **A zero-code check:** plug a real iPod touch 2G or iPad 1 into the Mac and see whether Finder shows it.

## Estimates

| Stage | Work | Estimate |
|---|---|---|
| F0 remainder | lease + `.clean` + a lifecycle test | 1 d |
| F1 | iPod rebuild (0.5 d); iPad YaFTL rebuild with oracle (2–3 d); clone→rebuild→fsck→attach pipeline (1 d); Mount/Export UI (1.5–2 d) | 6–8 d |
| F2 | read-write staging + fsck + owners (1 d); iPod write-back of changed blocks as page files (1–1.5 d); iPad full rebuild into a new base generation (4 d), or append pages and force YaFTL's read-only restore (1–1.5 d, if a spike holds); candidate boot, publish, fault injection (2 d) | 7–10 d |
| F3 | AFC-backed file protocol (1 d); a full-root guest daemon waits on guest packages; a Finder volume via NFS loopback (5–8 d) | 1 d, then 3+ weeks |
| F4 | `storageSnapshot(dest)` link command: pause, msync (iPad), clone, resume | 2 d |

## Riskiest unknowns

| # | Unknown | Cheapest retirement |
|---|---|---|
| U1 | Whether the YaFTL "highest USN wins" scan matches what the guest sees after heavy use and an unclosed shutdown | Boot a clone, install IPAs, rebuild, compare with a guest AFC walk |
| U2 | Whether F2(b)'s appended pages and erased control blocks work | Append one page, boot, read the file back |
| U3 | Whether 4.2.1 data files are plaintext on the emulated NAND | Rebuild a 4.2.1 device and read a class-protected file |
| U4 | Whether a clone catches the iPad's dirty MAP_SHARED pages | Always msync before cloning |
| U6 | Whether current Finder handles iOS 3/4 | Plug in a real device |
| U7 | How the USB host-controller entitlement is granted | Developer portal, or ask Apple |

## F1 core results (2026-09-28)

`firmwarekit mount|export --device DIR [--volume system|data|all] [--out DIR]` and `firmwarekit unmount --out DIR`
(FirmwareKit `VolumeRebuild`, `VolumeExport`). `--device` takes an app instance (`device.json`) or an imgtools
device dir (`nand/` or `base/`, plus `overlay/`).
- **iPod:** the emulator stores every guest write at its generated-layout address, so the rebuild is `ftlmap.predict`
  with the overlay over the base. It has one volume, `system`, sized by its HFS+ header; the GPT partition is 11 blocks
  longer, and macOS would look for the alternate header there.
- **iPad:** a YaFTL walk over base + overlay (the `.dirty` bitmap picks the source). For each LPN, the highest
  (USN, vpn) wins; MBR partitions 1 and 2 go to `system` and `data`, with only mapped pages written.

**U1 retired, for these cases.** `tests/volume-rebuild-oracle.py` boots a disposable overlay; then
`FK_U1=OUT swift test --filter guestOracle` compares the rebuild with what the guest reported.

| Device | Guest writes | Stop | Result |
|---|---|---|---|
| iPad 7B500, fresh | 107 AFC pushes (1 B–24 MiB) plus deletes, 2 IPAs (Doodle Jump, Bobby Carrot), 3 boots | clean | `fsck_hfs -fn` OK on both volumes; 112/112 AFC-walked files and 128/128 + 340/340 app Payload files identical |
| iPad 7B500, fresh | the same, plus 1 IPA | SIGKILL 40 s after the writes | both volumes flagged unclean; `fsck_hfs -fy` then mount replays the journal; 112/112 and 128/128 identical |
| iPad 8C148, fresh | 107 AFC pushes and an overwrite (no AppSync in the manifest, so IPAs are refused) | clean | fsck OK; 114/114 files identical |
| iPod nand-current | `tests/ipod/regress.py` appinstall + persist (2 boots) | clean | byte-identical to regress's Python compose; fsck OK; the persist marker and 8/8 Harness.app files identical |

**U3: 4.2.1 data is plaintext.** The builder's data volume lacks the content-protection bit (attributes
`0x80002100`), and the attributes B-tree holds only 4 `cprotect` keys. Every SQLite and plist file sampled is readable:
`keychain-2.db`, `sms.db`, `AddressBook.sqlitedb`, `notes.sqlite` and `systembag.kb`. A real restored device would
need the class keys.

**Timings (release build):**

| Device | Mount | Of which, rebuild |
|---|---|---|
| iPad (8C148, overlay) | 12 s | 9.8 s |
| iPod | about 15–30 s | — |

The iPod spends its time opening about 157k page files.
