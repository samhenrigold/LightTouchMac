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

The user-facing rule is writable while stopped, read-only while running. A
stopped writable device mount is not implemented yet: these commands provide
read-only independent exports. A running read-only mount must use an immutable
storage snapshot, not concurrently read the changing live FTL. VM pause or host
flush establishes neither clean guest unmount nor application consistency.

Writable device editing needs a staging generation, persistent edit intent,
exclusive lease through eject/publication, RAM snapshot invalidation, metadata
and ownership preservation across atomic editor saves, and a verified NAND
writeback mechanism. No unproven physical NAND writeback is exposed here. The
existing host HFS+ driver remains the filesystem implementation. The safe current
engineering alternatives are editing an exported image as a separate artifact,
or using guest-mediated services while running.

Verification: `swift test --filter StoppedStorageTests` covers helper-compatible
lock contention, release, pending edit refusal, failed reconstruction cleanup,
source/destination separation, and malformed/foreign manifest preservation.
An independent Python flock holder and the built CLI also verified cross-process
busy refusal before output creation. Existing synthetic volume reconstruction
and busy mounted-volume checks passed; optional firmware corpus checks skipped.

## Disposable writable-edit experiment

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

A general commit implementation still needs full metadata preservation (including
xattrs, resource forks and hard-link identity), recovery across publication
failure, generation-bound saved states, and storage-family gates. The N72
experiment uses the generated-layout builder and resets its FTL metadata; it
does not establish fidelity for arbitrary physically managed flash.

K48 cannot safely reuse the builder as an editor: it regenerates VFL/YaFTL
metadata and changes a supplied data partition to type 0xAF. Export currently
reconstructs only partitions 1 and 2; a complete importer must also retain MBR,
partition 3 where present, NOR effaceable/keybag state, epochs, and class-protected
file semantics. A read-only reconstruction round trip is not proof that such a
rebuilt device preserves encryption or will boot. No K48 edit publication is
enabled on the basis of this experiment.

For an app-managed device, successful candidate boot is still only one commit
gate: publication must bind the new base/overlay/NOR to an instance generation,
update provenance, discard incompatible saved RAM, and provide rollback without
overwriting a shared prepared base. Those operations must use the app's existing
device lifecycle rather than introducing a competing storage manager here.
