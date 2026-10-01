# Editing a stopped device

Light Touch provides **Open Filesystem in Finder** for a stopped iPod touch 2G
whose storage is the supported N72 generated format. Stop the device normally
first; pausing it does not grant filesystem ownership. After editing, use **Save
Filesystem Changes** or **Discard Filesystem Changes**. A pending edit prevents
boot, erase and deletion, including commands from another process.

The equivalent preparation-tool API is:

```sh
firmwarekit edit --device /absolute/device/directory --action begin
firmwarekit edit --device /absolute/device/directory --action mount --session UUID
firmwarekit edit --device /absolute/device/directory --action commit --session UUID
firmwarekit edit --device /absolute/device/directory --action discard --session UUID
firmwarekit edit --device /absolute/device/directory --action recover
```

Use the session identifier returned by `begin`. Commands return JSON and fail
with a nonzero status when ownership, identity, format, filesystem checks or
publication validation fail. The durable intent survives tool or GUI exits;
`recover` finishes only a validated publication. Mounted volumes must be ejected
successfully before publication or discard. Failed cleanup retains the candidate
for diagnosis rather than force-ejecting an unrelated disk.

Each edit creates a private generation containing base NAND, empty overlay,
working NOR, HFS volumes and fresh snapshot paths. The original generation stays
intact. Saving uses macOS's HFS driver, restores ordinary guest ownership and
metadata after atomic editor saves, checks hardlinks and the filesystem, rebuilds
the supported store, and verifies its exported bytes. A durable hash manifest
covers mutable flash/NOR inputs before one atomic device-record publication.
Recovery validates that manifest and the original record identity. Existing RAM
snapshots belong to the original generation and cannot resume against the edit.

The tests cover uid/gid/mode, resource forks, xattrs, symlinks, hardlinks,
case-sensitive names, new files and interrupted publication. A certified edited
7E18 generation passes two actual cold boots, byte-identical AFC reads of the
edited plist, a subsequent guest write and guest-confirmed shutdowns.

This writer supports the generated N72 layout explicitly. It does not translate
native VFL/YaFTL or encrypted restored storage. N45 and physical K48 edits are
refused. For a running guest, use guest-mediated AFC or the opt-in SSH/SFTP tools;
those operations preserve guest filesystem/FTL ownership. A frozen export is a
separate read-only view, not a writable live NAND mapping.

The physical NAND backend now keeps unpublished ownership in RAM, flushes page
data before publishing ownership, and tests SIGKILL/reopen and failure paths.
That ordering prevents incomplete first-owned overlay pages from becoming
authoritative; it does not claim atomic guest operations or durable completion
of every acknowledged program across a host power loss. Host edit generation
publication and guest/controller persistence are separate contracts.
