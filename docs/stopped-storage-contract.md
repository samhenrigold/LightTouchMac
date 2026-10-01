# Stopped storage and host filesystem access

`firmwarekit mount` and `export --device DIR` acquire `DIR/work/lease` using the
same exclusive, nonblocking flock as the VM helper. Keep the lock inode in place;
deleting a lease file would allow a second writer to bypass its owner. An existing
`work/edit.json` prevents export until its editing operation is resolved. The
lock is held through reconstruction and validation, then released: a mounted
read-only export is an independent copy and the guest may subsequently boot.

Every export owns a fresh output directory. Failure removes only that directory,
never pre-existing output or source storage; failed image discovery/eject retains
staging and reports its path for recovery. An invalid/missing export manifest
does not authorize deletion. Unmount queries the current image/device association
instead of trusting a saved `/dev/diskN`, does not force eject, and refuses cleanup
when image discovery fails or an attachment remains.

Direct `VolumeExport.Source(base:overlay:)` is a low-level API for isolated
research fixtures whose caller already controls concurrency. Research runners
that launch QEMU without the device lease remain outside this guarantee.

The user-facing rule is writable while stopped, read-only while running. The
supported N72 generated format now has a production stopped-edit transaction and
Finder actions; see [the editing workflow](stopped-filesystem-editing.md).
`StorageGeneration` owns the lease, durable intent, certified NAND/NOR generation,
atomic record publication and recovery. `StoppedVolumeEdit` uses the native HFS
driver and preserves metadata across editor saves. New snapshot paths prevent
resuming RAM against edited storage. Boot, erase and deletion all refuse a
pending edit.

Running reads must use guest services or an independent frozen export, never the
changing live FTL. Pause or host flush establishes neither clean guest unmount
nor application consistency. No physical K48 or N45 writeback is exposed: K48's
reader now refuses v2/unknown native physical layouts before it could publish a
filesystem reconstructed through the generated-store mapping.

Verification: `swift test --filter StoppedStorageTests` covers helper-compatible
lock contention, release, pending edit refusal, failed reconstruction cleanup,
source/destination separation, and malformed/foreign manifest preservation.
An independent Python flock holder and the built CLI also verified cross-process
busy refusal before output creation. Existing synthetic volume reconstruction
and busy mounted-volume checks passed; optional firmware corpus checks skipped.

## Historical disposable experiment (superseded for N72)

`StoppedEditSpikeTests.n72Candidate` clones a prepared N72 device with APFS,
reconstructs its volume using FirmwareKit, and edits it with macOS's HFS+ driver.
It performs an atomic save of SystemVersion.plist, restores its original UID,
GID and mode, checks BSD flags, and creates a media plist with explicit mobile
ownership. The existing N72 builder produces a new NAND candidate, which must
reconstruct to the exact edited image SHA-256. Only the disposable clone is
changed; the input device is never published or overwritten.

Run explicitly with `FK_EDIT_SPIKE_DEVICE=DIR FK_EDIT_SPIKE_OUT=NEW_DIR swift test
--filter StoppedEditSpikeTests`, then `tests/sessions/stopped-edit-candidate.py
--qemu-root QEMU_SOURCE --expected NEW_DIR/expected-marker.plist --device
NEW_DIR/device --qemu QEMU_BINARY --usbmuxd USBMUXD --checks boot,persist
--require-inputs --out NEW_RUN_DIR`. The native wrapper reads the offline-added
plist over AFC before and after guest-confirmed shutdown and a cold reboot, in
addition to the standard newly-written persistence marker. This experiment is
not an in-place editing interface or an automatic commit operation.

The 2026-09-30 N72/7E18 experiment passed: the final offline test rebuilt the
edited image byte-for-byte and preserved the existing plist's owner/mode/flags;
the native candidate reached Home on two cold boots, returned the offline-added
plist byte-for-byte through AFC on both, preserved a subsequent guest write, and
confirmed both guest shutdowns with QEMU exit 0. Offline evidence is
`/private/tmp/ltm-stopped-edit-spike3.log`; native evidence is
`/private/tmp/ltm-stopped-edit-native.log` and its adjacent run directory.
Earlier candidates reached the logical round-trip check but failed the final
directory move because cloned prepared roots were read-only; those experiments
are retained. The final spike makes only the private cloned roots writable.

The subsequent production N72 transaction implements metadata preservation
(including xattrs, resource forks and hardlinks), publication recovery,
generation-bound saved states and explicit format gates. The N72
experiment uses the generated-layout builder and resets its FTL metadata; it
does not establish fidelity for arbitrary physically managed flash.

K48 cannot safely reuse the builder as an editor: it regenerates VFL/YaFTL
metadata and changes a supplied data partition to type 0xAF. Export currently
reconstructs only partitions 1 and 2; a complete importer must also retain MBR,
partition 3 where present, NOR effaceable/keybag state, epochs, and class-protected
file semantics. A read-only reconstruction round trip is not proof that such a
rebuilt device preserves encryption or will boot. No K48 edit publication is
enabled on the basis of this experiment.

For an app-managed N72 edit, publication now binds base/overlay/NOR and
provenance to one generation and creates fresh snapshot paths without overwriting
the original prepared base. These guarantees are implemented at the shared
preparation/device API boundary and called by the GUI, not duplicated in it.
