# Runtime storage

This inventory covers the Mac app and helpers it invokes. It is based on source
inspection, not private runtime file contents. The app continues to ship its
device assets in one package; firmware import is a separate future change.

Apple recommends Application Support for app-managed durable data, Caches for
recreatable support data, and the system temporary directory for short-lived
work. Temporary and cache contents must be safe to lose. The app should remove
temporary files when their work finishes; system cleanup has no guaranteed
schedule. See [Using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively).

## Current locations and ownership

`State` below means `~/Library/Application Support/gold.samhenri.LightTouchMac`.
`Logs` means `~/Library/Logs/gold.samhenri.LightTouchMac`. An explicit
`LTM_STATE_DIR` replaces the state root and places logs in `State/Logs`, keeping
verification runs completely separate from normal user data. The first launch
of this build atomically renames the legacy `Application Support/LightTouchMac`
directory. See migration behavior below.

| Location | Contents and purpose | Lifetime and cleanup |
| --- | --- | --- |
| App bundle, `Contents/Resources/device` | Boot assets and packed NAND supplied with this release | Read-only inputs; never used as writable device storage. |
| `State/device/active-<nand>.json` | Active base image pointer | Retained across app moves and upgrades. |
| `State/device/<nand>-<digest>`; legacy `State/device/<nand>` | Extracted, immutable NAND base | Retained while a device depends on it. An existing device keeps its original base after an app update. |
| `State/nandrw-<image-key>` | Writable NAND pages and private `nor.bin` | Durable user device data. Erase removes the selected overlay before the next boot. Ordinary shutdown and failed snapshots do not delete it. |
| `State/snapshot-<image-key>`, `.meta`, `.tmp`, `.bad` | Saved RAM, identity metadata, staging, and quarantine | At most one saved and one quarantined snapshot per key. Explicit discard removes these and their metadata, not the overlay. Resume is currently disabled in the controller. Old image generations are not automatically collected. |
| `State/Library/IPAs/<sha256>.ipa`, `index.json` | Every installed archive once, named by content; the index carries bundle id, name, version, min OS, size, md5 and the Legacy Store copy | Written by install (hashed once) and by the launch sweep of device copies. A blob outlives the device copies; Settings ▸ Storage ▸ Remove Unused deletes the ones no device references. Legacy Store reuses a blob whose md5 matches the catalog copy instead of downloading. |
| `State/Devices/<uuid>/IPAs/<bundle-id>.ipa` (was `State/IPAs`, migrated at launch) | This device's installed archives, APFS clones of Library blobs, used to drag installed apps out as files and to install on another device | Published via a temporary sibling and atomic rename. Removed after successful uninstall through the app (the blob stays). These copies serve a feature and are not disposable download scratch. |
| `~/Library/Caches/gold.samhenri.LightTouchMac/AppMetadata` | Installed-app display names, icons, and `index.json` | Disposable metadata. An isolated run uses `State/Caches/AppMetadata`. Missing metadata falls back to the device-reported name; installs populate the cache again. |
| `State/AppCache` | Legacy metadata location | Moved atomically to the new cache when no destination exists. See migration exceptions below. |
| `State/work/usbmuxd-conf` | System configuration and device pairing records | Durable daemon state, copied from bundled seed once. Keep across launches; never include in a generic scratch-directory deletion. |
| `State/work/session.env`, `usbmuxd.pid` | Helper connection information and owned daemon PID | Rewritten for a new session. Normal stop removes both files; verified stale-daemon recovery uses the PID after an interrupted app run. Session connection files are private (0600). |
| `Logs/app.log`, `.1` | App events | Each generation is at most 1,000,000 bytes. App events also use unified logging under the bundle-ID subsystem, with dynamic text private in the unified log. |
| `Logs/serial.log`, `.1`; `Logs/usbmuxd.log`, `.1`; `Logs/native.log`, `.1` | Guest serial, USB daemon stdout/stderr, and the app process's native stdout/stderr (including linked QEMU and libraries) | Each stream has current plus previous generation, each at most 1,000,000 bytes. Pipe readers drain into a rotating app-owned writer, so long sessions remain bounded without truncating live child descriptors. The four streams total at most 8 MB. |
| System temporary directory: `LightTouch-serial-<UUID>/serial.in`, `.out` | Private FIFO endpoints for QEMU serial capture | Removed synchronously on normal app stop while open descriptors stay usable; full reader teardown occurs after QEMU returns. |
| `State/web-proxy.json`, `web-proxy.conf` | UI preferences and the helper's plain-text routing representation | Two intentional representations of the same setting, written atomically. |
| `State/web-proxy.conf.ca.pem`, `.ca.der`, `.ca.lock` | Proxy CA identity, exported certificate, and lock | Persistent identity reused across launches; guest trust refers to this certificate. Do not treat as cache or change its lifetime casually. |
| `State/web-proxy.conf.archive-gate`, `.archive-cache-XX` | Request cooldown and archived-response cache | 64 slots, each capped near 2 MiB, roughly 128 MiB total. Responses expire logically after a day; slot files remain until replaced. |
| `State/work/catalog-<id>-<UUID>` | Completed catalog downloads awaiting installation | The install job removes its directory on normal success, failure, or cancellation. An abrupt process exit can leave completed downloads here. |
| System temporary directory: `ltm-music-<UUID>`, `ltm-photo-<UUID>`, `ltm-fixed-<UUID>.ipa` | Media preparation and repaired install archive | Operation-owned; cleanup covers normal completion, failure, and cancellation. |
| System temporary directory: `<UUID>.mov`, `.capture-<UUID>.mov` | In-progress recordings and cropped replacements | Successful export removes temporary output. Export errors deliberately retain the original recording as a recovery file and show its path. |
| System temporary directory: `LightTouch-diagnostics-<UUID>` | One diagnostics export's copied logs and provenance | Unique per export; removed after success, failure, or cancellation, after its archiver has stopped. |
| System temporary directory: `itssh` directory and command file | Terminal handoff script | Outer script cleans up failed handoff; generated command takes ownership after successful handoff and cleans up on completion. |
| Downloads/Light Touch, or user-selected capture folder | Screenshots and completed recordings | User output, not app cache. Names contain timestamps and random suffixes. Never removed by device erase or cache cleanup. |
| User-selected export destinations | Device files and diagnostics ZIPs | Published from completed adjacent staging files. Failed/cancelled diagnostics exports preserve an existing destination. |
| System preferences | UI settings and window state | Managed through `UserDefaults` and AppKit; no manually written Preferences files. |

URLSession may also manage its own HTTP cache and temporary downloads. The app
uses the standard session APIs rather than naming or sweeping those files.
`/tmp/ltm-*`, `/tmp/itorient`, media staging, and similar paths inside guest
commands belong to the emulated device, not the Mac's `/tmp` directory.

## Changes made in this cleanup

- Durable state moves as a complete directory to the bundle-ID location,
  preserving base/overlay/NOR pairs, IPA archives, pairing records, proxy CA,
  file identities and recovery state. Legacy absolute active-image pointers
  become relative paths before the move, so they remain valid on either side
  of an interrupted migration. If both roots contain data, or a move/pointer
  validation fails, startup stops and preserves the existing data; it does not
  merge roots or create a replacement device. A live older app must stop first.
  A verified orphan usbmuxd from a previous crash is stopped before migration;
  PID identity, executable bundle, owner and parent are checked before signaling.
- Ordinary logs use the standard Logs directory with private directory/file
  permissions and bounded generations. Migration keeps the newest two distinct
  bounded tails of each owned old log, stages both before publication, and
  removes legacy sources only after successful publication. Unrelated files,
  pairing records and CA material are never part of log cleanup. Failed log
  migration preserves the old sources for a later retry. Native logging uses
  a pipe, so disk-write failure still drains output instead of wedging a helper.
  App events use `Logger` rather than `NSLog`, avoiding duplicate events in the
  native stream. Diagnostics and the log viewer use the same locations.
- Metadata uses the standard Caches location and respects `LTM_STATE_DIR`.
  Migration moves only the owned legacy `AppCache`, with no duplicate on normal
  success. If migration fails, the original remains usable. If both locations
  already exist, current metadata wins and legacy `State/AppCache` remains for
  conflict review; merging potentially different indexes is intentionally not
  guessed. No complete state-directory deletion is involved.
  Each icon/index write recreates its cache directory if it was purged while the
  app was running, then publishes the file atomically.
- NAND extraction removes its `.partial` directory after a failed helper
  launch, failed extraction, or failed publication. A retry must successfully
  remove abandoned partial output before beginning. The helper also reports
  deferred output errors instead of publishing a truncated base as successful.
- Diagnostics uses a unique temporary workspace, checks subprocess success,
  waits for child termination on cancellation, and atomically publishes the
  finished archive on the destination volume. Repeated exports cannot delete
  each other's working directories. Errors reach the UI.
- The Terminal helper now cleans up failed launch handoff. The proxy cache
  publishes complete entries atomically and removes its own temporary file on
  ordinary write/close/rename failure; cache misses do not create empty slots.

Forced termination or a system crash can interrupt cleanup. Unique temporary
names keep such remnants separate from complete data; no broad startup sweep
was added that could delete another running process's files. Adjacent export
staging files can remain in a chosen destination directory after a hard kill.

## Backup and disk-space policy

The extracted NAND duplicates material in the shipped app, but it is **not
currently a safely disposable cache**. After an app update, an existing overlay
may still depend on the old extracted base, which the updated app no longer
contains. Back up the base, active pointer, and writable overlay together.
Do not blanket-exclude extracted bases from Time Machine or move them into
purgeable Caches until there is a verified way to reproduce every referenced
base. No backup exclusion was added to those paths.

Backups taken while the guest is writing are not a verified coherent device
snapshot. Stop the device/app before a manual state backup. A restored RAM
snapshot may fail its inode/build/base checks and cold-boot; the overlay remains
the durable device data. Pairing records, proxy CA identity, and retained IPAs
also have durable roles and should not be erased to reduce apparent duplication.

The metadata cache is allowed to disappear: the app can operate without it.
Apple advises excluding recreatable data from backups, but that classification
must follow actual recoverability, especially for large support files. See
[Using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively)
and [backup exclusion semantics](https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup).

There is no global storage budget or automatic cleanup of old device generations.
Keeping old base/overlay pairs is deliberate protection against data loss. A
future storage-management screen should show their sizes and dependencies and
offer explicit removal of an unused device generation as a pair. Reducing the
download size through user-supplied firmware is a separate effort.

## Remaining focused follow-ups

1. **Separate remaining mixed-lifetime work.** `work` no longer holds logs,
   but still contains durable pairing records, per-session control files and
   disposable catalog downloads. Its name is historical, not a promise that
   the entire directory can be deleted. Move only short-lived download jobs
   to owned temporary directories; never sweep the pairing subtree.
2. **Move only proxy response cache data to Caches.** The helper currently
   derives cache, certificate, and cooldown paths from one config filename.
   Splitting these needs explicit helper path inputs and migration; moving the
   whole set would incorrectly make persistent CA identity disposable. Atomic
   cache publication is fixed without changing these paths.
3. **Make recording recovery durable.** A failed export leaves a recovery movie
   in the system temporary directory. Preserve recoverable recordings in an
   app-managed recovery location, then offer reveal/retry/discard; do not sweep
   these files as if they were failed disposable work.
4. **Library ownership for multiple devices** — done (Track B): archives are
   content-addressed under `State/Library/IPAs` with a clone per device;
   uninstall drops the device's clone, and the app-wide name and icon only
   when no device keeps the app.
5. **External install wrapper scratch.** The external/non-baked
   `qemu-ios-files/apps/install-app.sh` creates work or fallback temporary space
   even when it immediately hands off to the actual installer. It should resolve
   the existing session path without creating an unowned directory. The current
   default packaged device does not invoke this wrapper.
6. **Atomic daemon pairing writes.** The pinned usbmuxd implementation removes
   a prior pairing/configuration file before writing its replacement. A later
   dependency patch should atomically replace these files inside its configured
   app-owned directory. It does not use the Mac's shared pairing directory.

## Logging boundaries

The Mac's ordinary logs belong in `Library/Logs`, while Application Support
contains durable app-managed data under the bundle identifier. These follow
[Apple's macOS Library directory conventions](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html).
The app event stream also participates in [unified logging](https://developer.apple.com/documentation/os/logging).

Host device operations generally report failures through app events and the UI;
short-lived tools capture bounded error output for their operation. Metadata
probing intentionally discards expected `unzip` failures and falls back to
reported names/icons. The Terminal window owns its interactive SSH output.
The HTTP proxy deliberately suppresses stderr in guest-forwarding mode because
libslirp mixes it into the guest's network connection; redirecting that stream
into native logging would corrupt the protocol. Its configuration errors reach
the app where the helper's exit status is available. This change does not add a
second proxy log channel.

Guest helper logs and `/var/log` paths belong to the emulated iPod filesystem,
not the Mac's Library. QEMU's explicit developer trace/dump environment options
can still write to the paths the developer requests; the app does not enable
those options or sweep arbitrary developer-selected files. Ordinary QEMU
stdout/stderr tracing is bounded by `native.log`.

## Source references and validation

- [State/log migration](../LightTouchMac/StorageLocations.swift),
  [bounded native pipe capture](../LightTouchMac/NativeLogging.swift),
  [path ownership](../LightTouchMac/Bundled.swift),
  [metadata migration](../LightTouchMac/AppMetadataCache.swift),
  [device-state persistence](../LightTouchMac/DeviceStateStorage.swift),
  [controller extraction and lifecycle](../LightTouchMac/EmulatorController.swift).
- [Diagnostics and captures](../LightTouchMac/MainWindowController.swift),
  [file export](../LightTouchMac/DeviceFiles.swift),
  [retained IPAs](../LightTouchMac/IPALibrary.swift),
  [download ownership](../LightTouchMac/CatalogClient.swift),
  [install cleanup](../LightTouchMac/AppsInspectorViewController.swift).
- [USB daemon state](../LightTouchMac/USBMux.swift),
  [proxy settings](../LightTouchMac/WebProxyConfiguration.swift),
  [helper environment](../LightTouchMac/DeviceTools.swift).
- [Focused storage lifecycle check](../tests/check-storage-lifecycle.py) compiles
  production helpers under Swift 6 with MainActor defaults. It covers cache
  migration/isolation/failure and recovery after a purge, partial extraction
  cleanup, real ZIP contents, concurrent exports, cancellation and child teardown, preservation of existing
  destinations, and cleanup of owned staging. It creates only isolated fixtures
  and does not launch QEMU or inspect private user state.

- [Storage-location regression check](../tests/check-storage-locations.py)
  exercises the production migration with isolated Library fixtures, including
  preserved inode/base/overlay/identity data, absolute pointers, conflicting
  roots, rename failure and retry, override isolation, log collisions and
  symlinks, real active and orphan helper processes, sustained log volume,
  EOF teardown, safe FIFO unlink with an open writer and immediate cleanup.
  [App-event tests](../tests/check-app-events.py) cover concurrent formatting,
  permissions, rotation, bounded messages and file-write failure. No validation
  invokes migration on the user's actual Application Support directory.
