import FirmwareSchema
import Foundation
import HostRuntime
import HostServiceWire

/// A stopped generation is mounted by FirmwareKit; a durable intent keeps the
/// helper out even if this GUI quits. No filesystem writer lives in the GUI.
/// The app's instance is DeviceFilesystemEdits.shared (DeviceFilesystemEdits+App.swift).
@MainActor
public final class DeviceFilesystemEdits {
    /// firmwarekit (FirmwareJobs.preparer); nil: no operation is offered.
    private let preparer: URL?
    /// The state and log roots the devices' paths are under.
    private let state: URL, logs: URL
    /// The decrypt cache, beside which firmwarekit keeps Cydia's bootstrap (Jailbreak).
    private let cache: URL
    /// Shows a mounted volume (Finder), and an error with nowhere else to go.
    private let open: (URL) -> Void, presentError: (any Error) -> Void
    /// Whether a folder is a mount point now (the edit's volume is still mounted on it).
    private let isMounted: (URL) -> Bool
    /// Whether anything is writing to the volume mounted on a folder (a copy in progress).
    private let isWriting: (URL) async -> Bool
    private let poll: Duration

    public init(
        preparer: URL? = FirmwareJobs.preparer,
        state: URL = Bundled.stateDirectory,
        logs: URL = Bundled.logsDirectory,
        cache: URL = IPSWStore.cachesDirectory.appendingPathComponent("Decrypted", isDirectory: true),
        open: @escaping (URL) -> Void,
        presentError: @escaping (any Error) -> Void,
        isMounted: @escaping (URL) -> Bool = DeviceFilesystemEdits.isMountPoint,
        isWriting: @escaping (URL) async -> Bool = DeviceFilesystemEdits.isBeingWritten,
        poll: Duration = .seconds(1)
    ) {
        self.preparer = preparer
        self.state = state
        self.logs = logs
        self.cache = cache
        self.open = open
        self.presentError = presentError
        self.isMounted = isMounted
        self.isWriting = isWriting
        self.poll = poll
    }

    /// Posted when a device's `activity` changes.
    public static let didChangeNotification = Notification.Name("DeviceFilesystemEditsDidChange")
    /// What each device's filesystem operation is doing now ("Preparing to mount the file system…"), for the device area; a
    /// device with an entry here can't start or open another.
    public private(set) var activity: [UUID: String] = [:] {
        didSet { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
    }
    private var busy: Set<UUID> { Set(activity.keys) }
    /// A 1.x device whose storage wasn't shut down cleanly can't be opened; this offers to shut it down first.
    public var onUncleanShutdown: ((FirmwareCatalog.Entry) -> Void)?
    public struct Intent: Decodable {
        public let id: UUID
        public let phase: String
    }
    public struct Mounted: Decodable {
        let id: UUID
        let mountPoint: String?
    }
    private func paths(_ instance: DeviceInstance) -> DeviceInstance.Paths { instance.paths(state: state, logs: logs) }
    public func pending(_ instance: DeviceInstance) -> Intent? {
        try? JSONDecoder().decode(
            Intent.self,
            from: Data(contentsOf: paths(instance).work.appendingPathComponent("edit.json"))
        )
    }
    public func blocked(_ instance: DeviceInstance) -> Bool {
        busy.contains(instance.id)
            || FileManager.default.fileExists(atPath: paths(instance).work.appendingPathComponent("edit.json").path)
    }
    /// Start may go ahead after saving or discarding an open edit (`editing`, startAfterEdit); anything else in
    /// flight, or an edit stuck mid-commit (Finish Filesystem Recovery), holds it.
    public func blocksStart(_ instance: DeviceInstance) -> Bool {
        busy.contains(instance.id) || (blocked(instance) && pending(instance)?.phase != "editing")
    }
    /// An edit open in Finder: Start asks to save or discard it first.
    public func hasOpenEdit(_ instance: DeviceInstance) -> Bool {
        !busy.contains(instance.id) && pending(instance)?.phase == "editing"
    }

    /// Where an edit's volume is mounted: a folder named for the device, out of Finder's sidebar (nobrowse), opened in
    /// a Finder window of its own. The volume keeps the device's /private/var, so this is the whole tree.
    public func mountPoint(_ instance: DeviceInstance) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "LightTouch-edit-\(instance.id.uuidString)",
            isDirectory: true
        )
        .appendingPathComponent(instance.profile?.marketingName ?? instance.name, isDirectory: true)
    }
    /// The edit's volume is mounted (an edit can be open with it unmounted: after a restart of the Mac).
    public func isEditMounted(_ instance: DeviceInstance) -> Bool { isMounted(mountPoint(instance)) }
    public func canPerform(_ action: DeviceAction, instance: DeviceInstance) -> Bool {
        guard preparer != nil, !busy.contains(instance.id), instance.profile != nil else { return false }
        switch action {
        case .openFilesystem: return pending(instance)?.phase == nil || pending(instance)?.phase == "editing"
        case .commitFilesystem: return pending(instance)?.phase == "editing"
        case .recoverFilesystem: return pending(instance).map { $0.phase != "editing" } == true
        case .discardFilesystem: return pending(instance)?.phase == "editing"
        case .jailbreak:
            return pending(instance) == nil
                && (try? DeviceLock.read(base: paths(instance).base))??.jailbroken != true
        default: return false
        }
    }
    /// Install Package… on a stopped iPhone OS 1.x device (DeviceFeatures.installsPackages): nothing else in flight.
    public func canInstallPackage(_ instance: DeviceInstance) -> Bool {
        preparer != nil && !busy.contains(instance.id) && instance.profile != nil && pending(instance) == nil
    }

    /// The iPhone OS 1.x package at `url` (.pxl, an Installer-era .zip or an .app) into the stopped device
    /// (firmwarekit edit --action install-package, FirmwareKit's Package1x), from a copy in the device's work folder,
    /// where firmwarekit reads it. A package it refuses says why.
    public func install(
        package url: URL,
        entry: FirmwareCatalog.Entry,
        instance: DeviceInstance,
        library: DeviceLibrary,
        releaseStopped: @escaping () async -> Bool
    ) {
        // under its own name: a package without an identifier is named for its file
        let folder = paths(instance).work.appendingPathComponent("package-\(UUID().uuidString)")
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        packageEdit(
            "Installing \(url.deletingPathExtension().lastPathComponent)…",
            .installPackage,
            entry: entry,
            instance: instance,
            library: library,
            releaseStopped: releaseStopped,
            package: copy
        ) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
        } cleanup: {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// A package Install Package… put in a 1.x device, as its receipt names it.
    public struct InstalledPackage: Decodable, Sendable, Equatable {
        public let identifier: String
        public let name: String
        public let version: String?
    }

    /// The packages installed in the stopped 1.x device, from their receipts (firmwarekit edit --action
    /// list-packages); nil, the error shown, when they can't be read.
    public func installedPackages(
        entry: FirmwareCatalog.Entry,
        instance: DeviceInstance,
        library: DeviceLibrary,
        releaseStopped: @escaping () async -> Bool
    ) async -> [InstalledPackage]? {
        await withCheckedContinuation { done in
            var out: Data?
            packageEdit(
                "Reading the installed packages…", .listPackages, entry: entry, instance: instance, library: library,
                releaseStopped: releaseStopped, output: { out = $0 }
            ) {
            } cleanup: {
                done.resume(returning: out.flatMap { try? JSONDecoder().decode([InstalledPackage].self, from: $0) })
            }
        }
    }

    /// The package `identifier` out of the stopped 1.x device, as its receipt says (firmwarekit edit --action
    /// uninstall-package).
    public func uninstall(
        package: InstalledPackage,
        entry: FirmwareCatalog.Entry,
        instance: DeviceInstance,
        library: DeviceLibrary,
        releaseStopped: @escaping () async -> Bool
    ) {
        packageEdit(
            "Uninstalling \(package.name)…", .uninstallPackage, entry: entry, instance: instance, library: library,
            releaseStopped: releaseStopped, identifier: package.identifier
        ) {
        } cleanup: {
        }
    }

    /// One package edit of the stopped device, `activity` in the device area meanwhile: `prepare`, firmwarekit, its
    /// stdout to `output`, then `cleanup`. A failure is shown (an unclean shutdown offered to be fixed).
    private func packageEdit(
        _ activity: String,
        _ action: FirmwareCommand.Edit.Action,
        entry: FirmwareCatalog.Entry,
        instance: DeviceInstance,
        library: DeviceLibrary,
        releaseStopped: @escaping () async -> Bool,
        package: URL? = nil,
        identifier: String? = nil,
        output: @escaping (Data) -> Void = { _ in },
        prepare: @escaping () throws -> Void,
        cleanup: @escaping () -> Void
    ) {
        guard let executable = preparer, canInstallPackage(instance) else { return cleanup() }
        self.activity[instance.id] = activity
        Task {
            defer {
                self.activity[instance.id] = nil
                library.reload()
                NotificationCenter.default.post(name: DeviceLibrary.didChangeNotification, object: library)
                cleanup()
            }
            do {
                guard await releaseStopped() else {
                    throw DeviceToolsError.failed("Shut down the device before installing or uninstalling a package.")
                }
                try prepare()
                output(
                    try await FirmwareTool.run(
                        FirmwareCommand.Edit(
                            device: paths(instance).directory,
                            action: action,
                            recordPolicy: .managed,
                            package: package,
                            identifier: identifier
                        ),
                        executable: executable
                    )
                )
            } catch {
                if "\(error)".contains("was not shut down cleanly"), let onUncleanShutdown {
                    onUncleanShutdown(entry)
                } else {
                    presentError(error)
                }
            }
        }
    }

    /// `releaseStopped`: the session host lets go of the stopped device (false: it is running).
    public func perform(
        _ action: DeviceAction,
        entry: FirmwareCatalog.Entry,
        instance: DeviceInstance?,
        library: DeviceLibrary,
        releaseStopped: @escaping () async -> Bool
    ) {
        guard let instance, let executable = preparer,
            canPerform(action, instance: instance)
        else { return }
        // Already mounted: Show in Finder only shows it.
        if action == .openFilesystem, pending(instance)?.phase == "editing", isEditMounted(instance) {
            return open(mountPoint(instance))
        }
        activity[instance.id] =
            switch action {
            case .commitFilesystem: "Saving the file system…"
            case .discardFilesystem: "Discarding changes…"
            case .recoverFilesystem: "Recovering the file system…"
            case .jailbreak: "Jailbreaking…"
            default: "Preparing to mount the file system…"
            }
        Task {
            defer {
                activity[instance.id] = nil
                library.reload()
                NotificationCenter.default.post(name: DeviceLibrary.didChangeNotification, object: library)
            }
            do {
                guard await releaseStopped() else {
                    throw DeviceToolsError.failed("Shut down the device before showing its file system.")
                }
                if action == .commitFilesystem { try await waitForCopies(instance) }
                if action == .jailbreak {
                    _ = try await FirmwareTool.run(
                        FirmwareCommand.Edit(
                            device: paths(instance).directory,
                            action: .jailbreak,
                            recordPolicy: .managed,
                            cache: cache
                        ),
                        executable: executable
                    )
                    return
                }
                var intent = pending(instance)
                if action == .openFilesystem, intent == nil {
                    let result = try await FirmwareTool.run(
                        FirmwareCommand.Edit(device: paths(instance).directory, action: .begin, recordPolicy: .managed),
                        executable: executable
                    )
                    let created = try JSONDecoder().decode(Mounted.self, from: result)
                    intent = Intent(id: created.id, phase: "editing")
                }
                guard let intent else { throw DeviceToolsError.failed("The edit session is unavailable.") }
                let operation: FirmwareCommand.Edit.Action =
                    switch action {
                    case .openFilesystem: .mount
                    case .commitFilesystem: .commit
                    case .discardFilesystem: .discard
                    case .recoverFilesystem: .recover
                    default: throw DeviceToolsError.failed("Unsupported file system action.")
                    }
                if action == .openFilesystem { activity[instance.id] = "Opening in Finder…" }
                let mountPoint = mountPoint(instance)
                _ = try await FirmwareTool.run(
                    FirmwareCommand.Edit(
                        device: paths(instance).directory,
                        action: operation,
                        session: intent.id,
                        recordPolicy: .managed,
                        mountPoint: action == .openFilesystem ? mountPoint : nil
                    ),
                    executable: executable
                )
                if action == .openFilesystem {
                    open(mountPoint)
                    watch(instance, library: library)
                } else {
                    removeMountFolder(instance)
                }
            } catch {
                if "\(error)".contains("was not shut down cleanly"), let onUncleanShutdown {
                    onUncleanShutdown(entry)
                } else {
                    presentError(error)
                }
            }
        }
    }

    /// Before Start: an open edit saved (`commit`) or discarded. Saving waits for copies into the mounted volume to
    /// finish first. Throws when an edit couldn't be resolved.
    public func release(_ instance: DeviceInstance, library: DeviceLibrary, commit: Bool?) async throws {
        guard let commit, hasOpenEdit(instance), let executable = preparer, let intent = pending(instance) else {
            return
        }
        defer { activity[instance.id] = nil }
        if commit { try await waitForCopies(instance) }
        activity[instance.id] = commit ? "Saving the file system…" : "Discarding changes…"
        _ = try await FirmwareTool.run(
            FirmwareCommand.Edit(
                device: paths(instance).directory,
                action: commit ? .commit : .discard,
                session: intent.id,
                recordPolicy: .managed
            ),
            executable: executable
        )
        removeMountFolder(instance)
        library.reload()
    }

    /// While an edit is open: its volume unmounted from outside (Eject in Finder, diskutil) saves it, as Save Changes
    /// does. Only an unmount seen here counts; an edit found unmounted (after a restart of the Mac) waits for a choice.
    public func watch(_ instance: DeviceInstance, library: DeviceLibrary) {
        guard pending(instance)?.phase == "editing", watching.insert(instance.id).inserted else { return }
        let mountPoint = mountPoint(instance)
        Task {
            defer { watching.remove(instance.id) }
            var mounted = false
            while pending(instance)?.phase == "editing" {
                if isMounted(mountPoint) {
                    mounted = true
                } else if mounted, !busy.contains(instance.id) {
                    do { try await release(instance, library: library, commit: true) } catch { presentError(error) }
                    library.reload()
                    NotificationCenter.default.post(name: DeviceLibrary.didChangeNotification, object: library)
                    return
                }
                try? await Task.sleep(for: poll)
            }
        }
    }
    private var watching: Set<UUID> = []

    /// Before a save of a mounted edit: until nothing is writing into the volume (a Finder copy in progress).
    private func waitForCopies(_ instance: DeviceInstance) async throws {
        let mountPoint = mountPoint(instance)
        let saving = activity[instance.id]
        guard isMounted(mountPoint), await isWriting(mountPoint) else { return }
        activity[instance.id] = "Waiting for copies to finish…"
        while await isWriting(mountPoint) { try await Task.sleep(for: poll) }
        activity[instance.id] = saving
    }

    /// The mount point's folders, once nothing is mounted on them (rmdir: never into a volume).
    private func removeMountFolder(_ instance: DeviceInstance) {
        let mountPoint = mountPoint(instance)
        guard !isMounted(mountPoint) else { return }
        rmdir(mountPoint.path)
        rmdir(mountPoint.deletingLastPathComponent().path)
    }

    /// statfs: `url` is where a file system is mounted. realpath, not resolvingSymlinksInPath: that drops the
    /// /private of the temporary directory's /private/var/folders, where the mount table has it.
    public nonisolated static func isMountPoint(_ url: URL) -> Bool {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0, let real = realpath(url.path, nil) else { return false }
        defer { free(real) }
        let mountedOn = withUnsafeBytes(of: &fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return mountedOn == String(cString: real)
    }

    /// A file open for writing on the volume, or its free space or file count moving over half a second.
    @concurrent public nonisolated static func isBeingWritten(_ url: URL) async -> Bool {
        func counts() -> [UInt64] {
            var fs = statfs()
            return statfs(url.path, &fs) == 0 ? [fs.f_bfree, fs.f_ffree] : []
        }
        let before = counts()
        if hasWriter(onVolume: url) { return true }
        try? await Task.sleep(for: .milliseconds(500))
        return counts() != before
    }
}

extension DeviceFilesystemEdits {
    /// Any process with a file open for writing on the volume mounted at `url` (libproc: what lsof's access mode
    /// shows, without spawning it).
    nonisolated static func hasWriter(onVolume url: URL) -> Bool {
        guard let real = realpath(url.path, nil) else { return false }
        let root = String(cString: real) + "/"
        free(real)
        let flags = UInt32(PROC_LISTPIDSPATH_PATH_IS_VOLUME | PROC_LISTPIDSPATH_EXCLUDE_EVTONLY)
        let pidSize = MemoryLayout<pid_t>.size
        let needed = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, url.path, flags, nil, 0)
        guard needed > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(needed) / pidSize + 16)
        let listed = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, url.path, flags, &pids, Int32(pids.count * pidSize))
        for pid in pids.prefix(max(0, Int(listed)) / pidSize) where pid > 0 {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
            for fd in fds.prefix(max(0, Int(got)) / MemoryLayout<proc_fdinfo>.stride)
            where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else {
                    continue
                }
                let path = withUnsafeBytes(of: info.pvip.vip_path) {
                    String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
                }
                if info.pfi.fi_openflags & UInt32(FWRITE) != 0, path.hasPrefix(root) { return true }
            }
        }
        return false
    }
}
