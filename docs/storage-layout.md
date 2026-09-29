# Runtime storage

This inventory covers the Mac app and helpers it invokes. It is based on source
inspection, not private runtime file contents. Every device, the built-in iPod
included, is a prepared base under `State/Devices/<uuid>`; the app ships that
iPod as one packed blob and unpacks it into a device on first launch.

Apple recommends Application Support for app-managed durable data, Caches for
recreatable support data, and the system temporary directory for short-lived
work. Temporary and cache contents must be safe to lose. The app should remove
temporary files when their work finishes; system cleanup has no guaranteed
schedule. See [Using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively).

## Current locations and ownership

`State` below means `~/Library/Application Support/gold.samhenri.LightTouchMac`.
`Logs` means `~/Library/Logs/gold.samhenri.LightTouchMac`. An explicit
`LTM_STATE_DIR` replaces the state root and places logs in `State/Logs`, keeping
verification runs completely separate from normal user data. A layout from
before the device library is not migrated; see "The old layout" below.

| Location | Contents and purpose | Lifetime and cleanup |
| --- | --- | --- |
| App bundle, `Contents/Resources/device` | `bootrom_240_4` (the iPod's SecureROM) and `n72ap-7E18.itbase`: the built-in iPod, a `firmwarekit create` of iOS 3.1.3 packed as one blob (`scripts/pack-base.py`) | Read-only inputs; never used as writable device storage. |
| `State/Devices/<uuid>/device.json` | The device record (`DeviceInstance`): board, catalog entry, base, storage paths, identity, provenance | The directory is the device; Delete renames it to `.deleting-<uuid>` and removes it. |
| `State/Devices/<uuid>/base/` | The prepared base: `iBoot.bin`/`kboot.bin`, `nor.bin`, `gid-blobs.bin`, `nand/`, `identity.json`, `device.lock.json`; immutable (`chflags uchg`). The built-in iPod's is unpacked from the bundle's blob on first launch; every other one is `firmwarekit create` output. | Retained with the device; reproducible from the IPSW (and the bundle). |
| `State/Devices/<uuid>/overlay/`, `nor.bin` | The device's writes: copy-on-write NAND pages pinned to the base's identity, and its private NOR copy | Durable user device data. Erase removes both; the next boot recreates them from the base. |
| `State/Devices/<uuid>/snapshot`, `.meta`, `.tmp`, `.bad` | Saved RAM from older builds (resume is gone) | Erase removes them. |
| `State/Devices/<uuid>/usbmuxd-conf/` | Host identity and pairing records, 0700/0600 | Durable; the built-in iPod inherits the pre-library `work/usbmuxd-conf` once. |
| `State/Devices/<uuid>/work/` | `lease`, `usbmuxd.pid`, the guest-package offer | Per session; excluded from backups. |
| `State/Preparing/<job>/`, `<job>.publish/` | A preparation being staged, then assembled; published into `Devices/<uuid>` by one rename | Never a device; the launch sweep empties it. |
| `State/Library/IPAs/<sha256>.ipa`, `index.json` | Every installed archive once, named by content; the index carries bundle id, name, version, min OS, size, md5 and the Legacy Store copy | Written by install (hashed once) and by the launch sweep of device copies. A blob outlives the device copies; Settings ▸ Storage ▸ Remove Unused deletes the ones no device references. Legacy Store reuses a blob whose md5 matches the catalog copy instead of downloading. |
| `State/Devices/<uuid>/IPAs/<bundle-id>.ipa` (was `State/IPAs`, migrated at launch) | This device's installed archives, APFS clones of Library blobs, used to drag installed apps out as files and to install on another device | Published via a temporary sibling and atomic rename. Removed after successful uninstall through the app (the blob stays). These copies serve a feature and are not disposable download scratch. |
| `~/Library/Caches/gold.samhenri.LightTouchMac/AppMetadata` | Installed-app display names, icons, and `index.json` | Disposable metadata. An isolated run uses `State/Caches/AppMetadata`. Missing metadata falls back to the device-reported name; installs populate the cache again. |
| `State/AppCache` | Legacy metadata location | Moved atomically to the new cache when no destination exists. See migration exceptions below. |
| `Logs/app.log`, `.1` | App events | Each generation is at most 1,000,000 bytes. App events also use unified logging under the bundle-ID subsystem, with dynamic text private in the unified log. |
| `Logs/serial.log`, `.1`; `Logs/usbmuxd.log`, `.1`; `Logs/native.log`, `.1` | Guest serial, USB daemon stdout/stderr, and the app process's native stdout/stderr (including linked QEMU and libraries) | Each stream has current plus previous generation, each at most 1,000,000 bytes. Pipe readers drain into a rotating app-owned writer, so long sessions remain bounded without truncating live child descriptors. The four streams total at most 8 MB. |
| System temporary directory: `LightTouch-serial-<UUID>/serial.in`, `.out` | Private FIFO endpoints for QEMU serial capture | Removed synchronously on normal app stop while open descriptors stay usable; full reader teardown occurs after QEMU returns. |
| `State/web-proxy.json`, `web-proxy.conf` | UI preferences and the helper's plain-text routing representation (read per guest connection) | Two intentional representations of the same setting, written atomically. |
| `State/web-proxy.conf.ca.pem`, `.ca.der`, `.ca.lock` | Proxy CA identity, exported certificate, and lock | Persistent identity reused across launches; guest trust refers to this certificate. Do not treat as cache or change its lifetime casually. |
| `State/web-proxy.conf.cache/` | The helper's web proxy URLCache: origin responses by HTTP caching rules, archived pages for a day | 128 MiB on disk (URLCache evicts), 8 MiB in memory. Disposable. The C helper's `.archive-gate` and `.archive-cache-XX` files are deleted when a device's helper starts. |
| System temporary directory: `ltm-proxy-<hash>.sock` | The Unix socket the guestfwd's `nc` reaches the helper's proxy through, one per device directory | Owner-only; replaced when the device boots again. |
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

## The old layout (before the built-in iPod was a prepared device)

Builds before 2026-09-28 unpacked the shipped iPod image into
`State/device/<nand>-<digest>` (chosen by `active-<nand>.json`), wrote its
pages to `State/nandrw-<key>` and `State/snapshot-<key>`, kept one host pairing
in `State/work/usbmuxd-conf`, and (the multidevice builds) adopted that image as
a `legacyBundled` record; 1.0 kept everything under
`Application Support/LightTouchMac`. None of it can carry over: an overlay only
fits the base it was made on, and the built-in iPod is now a different base.
`LegacyState` finds any of it at launch and asks once:

> Light Touch's built-in iPod has changed format. Erase it and continue (apps
> you've saved are kept), or quit. — **Erase & Continue** / **Quit**

Erase & Continue puts every retained `.ipa` (`State/IPAs`, the old root's
`IPAs`, each legacy record's `Devices/<uuid>/IPAs`) into the library, keeps the
host pairing (moved to `State/work/usbmuxd-conf` if it came from the old root),
then removes the old items and records, and the old root. The built-in iPod is
then unpacked and published with that pairing as its `usbmuxd-conf`, and
`State/work/usbmuxd-conf` goes. Quit changes nothing. Records the app cannot
read (a `base.kind` other than `prepared`) are never booted.

## Notes

- Ordinary logs use the standard Logs directory with private directory/file
  permissions and bounded generations. Native logging uses a pipe, so
  disk-write failure still drains output instead of wedging a helper. App
  events use `Logger` rather than `NSLog`, avoiding duplicate events in the
  native stream. Diagnostics and the log viewer use the same locations.
- Metadata uses the standard Caches location and respects `LTM_STATE_DIR`.
  Each icon/index write recreates its cache directory if it was purged while the
  app was running, then publishes the file atomically.
- The built-in iPod's blob is unpacked as a stream into `Preparing/<id>/`
  (`BundledBase.unpack`); a torn or truncated blob throws and the staging
  directory goes, so `Devices/` never sees a half base.
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

A device's base is reproducible (from its IPSW, or the bundle for the built-in
iPod), but an overlay is only valid over the exact base it was made on, so
bases and overlays stay in backups together (`docs/multi-device-plan.md`,
"Storage policy"); only recreatable or in-flight data is excluded.

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

There is no global storage budget. Settings ▸ Storage shows each device's
base, data and snapshot sizes and offers Delete Device.

## Remaining focused follow-ups

1. **`State/work` is Legacy Store download scratch** (`catalog-<id>-<uuid>`)
   and, in Debug, the development lockdown helpers; a device's own daemon files
   are under `Devices/<uuid>/work`. Move the download jobs to owned temporary
   directories and the directory can go.
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

- [State/log layout](../LightTouchMac/StorageLocations.swift),
  [the old layout's erase](../LightTouchMac/LegacyState.swift),
  [the built-in iPod's unpack](../LightTouchMac/BundledBase.swift) and
  [publish](../LightTouchMac/PreparationJob.swift),
  [bounded native pipe capture](../LightTouchMac/NativeLogging.swift),
  [path ownership](../LightTouchMac/Bundled.swift),
  [device-state persistence](../LightTouchMac/DeviceStateStorage.swift),
  [controller lifecycle](../LightTouchMac/EmulatorController.swift).
- [Diagnostics and captures](../LightTouchMac/MainWindowController.swift),
  [file export](../LightTouchMac/DeviceFiles.swift),
  [retained IPAs](../LightTouchMac/IPALibrary.swift),
  [download ownership](../LightTouchMac/CatalogClient.swift),
  [install cleanup](../LightTouchMac/AppsInspectorViewController.swift).
- [USB daemon state](../LightTouchMac/USBMux.swift),
  [proxy settings](../LightTouchMac/WebProxyConfiguration.swift),
  [helper environment](../LightTouchMac/DeviceTools.swift).
- [Focused storage lifecycle check](../tests/offline/check-storage-lifecycle.py) compiles
  production helpers under Swift 6 with MainActor defaults. It covers cache
  isolation and recovery after a purge, the built-in base's unpack (modes kept;
  a truncated blob and an escaping name refused), real ZIP contents, concurrent
  exports, cancellation and child teardown, preservation of existing
  destinations, and cleanup of owned staging. It creates only isolated fixtures
  and does not launch QEMU or inspect private user state.
- [The built-in device and the old layout](../tests/offline/check-bundled-prepared.py):
  a fresh state publishes the packed base as a `.prepared` record whose base
  has the boot files `BootRecipe` wants; the old layout is found, erased with
  its IPAs kept in the library and the pairing seeded into the new device.
- [Storage-location check](../tests/offline/check-storage-locations.py) exercises the
  layout with isolated Library fixtures: private state and log directories,
  override isolation, a blocked root refused, sustained log volume, EOF
  teardown, safe FIFO unlink with an open writer and immediate cleanup.
  [App-event tests](../tests/offline/check-app-events.py) cover concurrent formatting,
  permissions, rotation, bounded messages and file-write failure. No check
  touches the user's actual Application Support directory.
