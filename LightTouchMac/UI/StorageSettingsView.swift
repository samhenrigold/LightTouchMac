import Cocoa
import FirmwareSchema
import LightTouchCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ Storage: what each device and the app's stores take on disk
/// (allocated bytes: bases and overlays are sparse), with the actions that
/// give it back. Laid out as Xcode's Settings ▸ Components: a device, an IPSW or
/// an app shows its details in an info sheet and its actions in a context menu.
struct StorageSettingsView: View {
    let model: StorageUsage
    @State private var info: StorageInfo?
    /// Add IPSW… or Add App…'s open panel, for files of `addingType`.
    @State private var isAdding = false
    @State private var addingType = Self.ipsw
    /// A deletion that can't be undone, asked first.
    @State private var confirmation: Confirmation?
    @State private var isConfirming = false
    private static let ipsw = UTType(filenameExtension: "ipsw") ?? .data
    private static let ipa = UTType(filenameExtension: "ipa") ?? .data

    var body: some View {
        let usage = model.usage
        // Every name below is read again after a rename or a Device Name Style change.
        let _ = model.nameRevision
        Form {
            Section("Devices") {
                if usage.measured, usage.devices.isEmpty {
                    Text("No devices")
                        .foregroundStyle(.secondary)
                }

                // Every record, also one no sidebar row shows (its entry left the catalog, or a newer record for the
                // same entry is the row's): each deletes itself.
                ForEach(usage.devices, id: \.instance.id) { device in
                    infoRow(deviceInfo(device))
                }
            }

            Section("Firmware") {
                if usage.measured, usage.ipsws.isEmpty, usage.builtIn.isEmpty {
                    Text("No downloaded or imported IPSWs")
                        .foregroundStyle(.secondary)
                }

                let inUse = model.jobs.ipswsInUse

                ForEach(usage.builtIn, id: \.url) { builtIn in
                    infoRow(builtInInfo(builtIn))
                }

                ForEach(usage.ipsws, id: \.url) { ipsw in
                    infoRow(ipswInfo(ipsw, busy: inUse.contains(ipsw.url.deletingPathExtension().lastPathComponent)))
                }

                Button("Add IPSW…", systemImage: "plus") {
                    add(Self.ipsw)
                }
                .buttonStyle(.borderless)
                .tint(.blue)
            }

            Section("Apps") {
                if usage.measured, usage.apps.isEmpty {
                    Text("No apps")
                        .foregroundStyle(.secondary)
                }

                ForEach(usage.apps) { app in
                    infoRow(appInfo(app, devices: usage.appDevices[app.sha256] ?? 0))
                }

                if !usage.unusedApps.isEmpty {
                    Button("Remove Unused Apps…", systemImage: "trash", role: .destructive) {
                        confirm(
                            Confirmation(
                                title: "Remove Unused Apps?",
                                message: "\(usage.unusedApps.count) apps no device has, \(size(usage.unusedBytes)). "
                                    + "You’ll need their .ipa files to install them again.",
                                action: "Remove",
                                perform: model.removeUnusedIPAs
                            )
                        )
                    }
                    .buttonStyle(.borderless)
                    .tint(.red)
                }

                Button("Add App…", systemImage: "plus") {
                    add(Self.ipa)
                }
                .buttonStyle(.borderless)
                .tint(.blue)
            }

            Section {
                LabeledContent("Decrypted firmware", value: size(usage.decrypted))
                    .contextMenu {
                        showInFinder(IPSWStore.cachesDirectory.appendingPathComponent("Decrypted", isDirectory: true))
                    }

                LabeledContent("Logs", value: size(usage.logs))
                    .contextMenu {
                        showInFinder(Bundled.logsDirectory)
                    }
            } header: {
                Text("Caches and Logs")
            } footer: {
                Text("Decrypted firmware is cleared after a device is prepared and when Light Touch opens.")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $info) { item in
            StorageInfoSheet(info: item)
        }
        .confirming(confirmation, isPresented: $isConfirming)
        .fileImporter(isPresented: $isAdding, allowedContentTypes: [addingType], allowsMultipleSelection: true) {
            result in
            guard let urls = try? result.get() else {
                return
            }
            _ = model.add(urls)
        }
        .onAppear(perform: model.reload)
    }

    private func add(_ type: UTType) {
        addingType = type
        isAdding = true
    }

    private func confirm(_ confirmation: Confirmation) {
        self.confirmation = confirmation
        isConfirming = true
    }

    /// A row's Delete: asked first when it can't be undone.
    private func delete(_ item: StorageInfo) {
        if let confirmation = item.confirmation {
            confirm(confirmation)
        } else {
            item.perform()
        }
    }

    private func showInFinder(_ url: URL) -> some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// A device's, an IPSW's or an app's row: its name, its size, its info button, and its actions in a context menu.
    private func infoRow(_ item: StorageInfo) -> some View {
        LabeledContent {
            Text(item.size)
                .textSelection(.disabled)

            Button("Info", systemImage: "info.circle") {
                info = item
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
        } label: {
            Label {
                Text(item.title)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                }
            } icon: {
                if let icon = item.rowIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                }
            }
        }
        .help(item.help ?? "")
        .contextMenu {
            Button("Get Info") {
                info = item
            }

            if let file = item.file {
                showInFinder(file)
            }

            if let extra = item.extra {
                Button(extra.title) {
                    extra.perform()
                }
                .disabled(!item.enabled)
            }

            if let action = item.action {
                Divider()

                Button(action, role: .destructive) {
                    delete(item)
                }
                .disabled(!item.enabled)
            }
        }
    }

    private func deviceInfo(_ device: StorageUsage.DeviceUsage) -> StorageInfo {
        let instance = device.instance
        let entry = model.catalog.entry(id: instance.firmware)
        let version = entry.map { entry in
            "\(entry.version) (\(entry.build))"
        }
        // As its sidebar row reads; a record no row runs (its entry left the catalog, or the row runs a newer record)
        // says so.
        let row = model.label(instance)
        let label =
            row
            ?? entry.map { entry in
                SidebarList.label(for: entry, name: nil)
            }
        return StorageInfo(
            id: instance.id.uuidString,
            title: label?.title ?? instance.firmware,
            subtitle: row?.subtitle ?? label.map { "\($0.subtitle), not in the sidebar" } ?? "Not in the sidebar",
            size: size(device.base + device.data + device.snapshot),
            icon: {
                instance.profile?.icon
            },
            facts: [
                ("Version", version ?? instance.firmware),
                ("Base OS", size(device.base)),
                ("User Data", size(device.data + device.snapshot)),
                ("Added", instance.created.formatted(date: .abbreviated, time: .omitted))
            ],
            file: instance.paths.directory,
            action: "Delete…",
            enabled: model.canDelete(instance),
            perform: {
                model.delete(instance)
            }
        )
    }

    private func ipswInfo(
        _ ipsw: (entry: String, url: URL, bytes: Int64, referenced: URL?),
        busy: Bool
    ) -> StorageInfo {
        let entry = model.catalog.entry(id: ipsw.entry)
        let kind = ipsw.url.path.hasPrefix(IPSWStore.shared.imports.path) ? "Imported" : "Downloaded"
        // A referenced IPSW takes no space here, and removing it leaves the user's file.
        let path = ipsw.referenced.map { url in
            (url.path as NSString).abbreviatingWithTildeInPath
        }
        return StorageInfo(
            id: ipsw.url.path,
            title: firmwareTitle(entry) ?? ipsw.entry,
            size: path == nil ? size(ipsw.bytes) : "Not copied",
            help: firmwareHelp(entry),
            icon: {
                entry?.profile?.icon
            },
            facts: [("Device", entry?.preferredName ?? ipsw.entry), ("Source", kind)]
                + (path.map { [("File", $0)] } ?? []),
            file: ipsw.referenced ?? ipsw.url,
            action: path == nil ? "Delete" : "Remove",
            enabled: !busy,
            perform: {
                model.removeIPSW(ipsw.url)
            },
            extra: path == nil ? nil : ("Copy into Light Touch", { model.copyIn(ipsw.url) })
        )
    }

    /// The firmware this app ships prepared: always here, so it has no Delete.
    private func builtInInfo(_ builtIn: (entry: String, url: URL, bytes: Int64)) -> StorageInfo {
        let entry = model.catalog.entry(id: builtIn.entry)
        return StorageInfo(
            id: builtIn.url.path,
            title: firmwareTitle(entry) ?? builtIn.entry,
            size: size(builtIn.bytes),
            help: firmwareHelp(entry),
            icon: {
                entry?.profile?.icon
            },
            facts: [("Device", entry?.preferredName ?? builtIn.entry), ("Source", "Built in")],
            file: builtIn.url
        )
    }

    /// "iPhone3,1 7.0 (24A435)".
    private func firmwareTitle(_ entry: FirmwareCatalog.Entry?) -> String? {
        entry.map { entry in
            "\(entry.productType) \(entry.version) (\(entry.build))"
        }
    }

    /// "iPhone 4, iOS 7.0".
    private func firmwareHelp(_ entry: FirmwareCatalog.Entry?) -> String? {
        entry.map { entry in
            "\(entry.preferredName), iOS \(entry.version)"
        }
    }

    /// An app in the library: one a device has stays (the device's copy is a clone of it).
    private func appInfo(_ app: StorageUsage.LibraryApp, devices: Int) -> StorageInfo {
        let name = app.name ?? app.bundleID
        let remove = {
            model.removeApps([app.sha256])
        }
        return StorageInfo(
            id: app.sha256,
            title: name,
            subtitle: app.version,
            size: size(app.size),
            rowIcon: AppMetadataCache.shared.icon(for: app.bundleID),
            icon: {
                guard AppMetadataCache.shared.hasIcon(app.bundleID) else {
                    return nil
                }
                return NSImage(contentsOf: AppMetadataCache.shared.iconURL(app.bundleID))
            },
            facts: [
                ("Version", app.version ?? "Unknown"), ("Bundle ID", app.bundleID),
                ("On Devices", devices == 0 ? "None" : "\(devices)")
            ] + (app.minOS.map { [("Requires", "iOS \($0)")] } ?? []),
            file: IPALibrary.blob(app.sha256),
            action: "Delete…",
            enabled: devices == 0,
            perform: remove,
            confirmation: Confirmation(
                title: "Delete “\(name)”?",
                message: "You’ll need its .ipa file to install it again.",
                action: "Delete",
                perform: remove
            )
        )
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// A row's details for its info sheet and context menu: what it is, Show in Finder, and the Delete that gives its space
/// back.
private struct StorageInfo: Identifiable {
    let id: String
    let title: String
    /// Under the title (an app's version, which tells two copies of one app apart).
    var subtitle: String?
    let size: String
    /// Beside the title (an app's icon).
    var rowIcon: NSImage?
    /// The row's tooltip.
    var help: String?
    /// The sheet's icon, made only when it opens: macOS's device artwork is slow to load.
    var icon: () -> NSImage? = {
        nil
    }
    let facts: [(String, String)]
    /// What Show in Finder selects.
    var file: URL?
    /// Delete (or Remove): none for what can't be deleted, such as the firmware built into the app.
    var action: String?
    var enabled = true
    var perform: () -> Void = {
    }
    /// A second action beside Delete (Copy into Light Touch, for an IPSW that isn't copied in).
    var extra: (title: String, perform: () -> Void)?
    /// Asked before `perform`, when the deletion can't be undone.
    var confirmation: Confirmation?
}

/// A deletion that can't be undone: its question, what it means, and its button.
private struct Confirmation {
    let title: String
    let message: String
    let action: String
    let perform: () -> Void
}

extension View {
    /// Asks `confirmation` while `isPresented`; its button runs it after `first`.
    fileprivate func confirming(
        _ confirmation: Confirmation?,
        isPresented: Binding<Bool>,
        first: @escaping () -> Void = {
        }
    ) -> some View {
        confirmationDialog(confirmation?.title ?? "", isPresented: isPresented, presenting: confirmation) {
            confirmation in
            Button(confirmation.action, role: .destructive) {
                first()
                confirmation.perform()
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}

private struct StorageInfoSheet: View {
    let info: StorageInfo
    @State private var isConfirming = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent {
                        Text(info.size)
                    } label: {
                        Label {
                            Text(info.title)
                                .bold()
                        } icon: {
                            if let icon = info.icon() {
                                Image(nsImage: icon)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 32, height: 32)
                            }
                        }
                    }
                }

                Section {
                    ForEach(info.facts.indices, id: \.self) { index in
                        LabeledContent(info.facts[index].0, value: info.facts[index].1)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Button("Copy Information") {
                let lines =
                    ["\(info.title), \(info.size)"]
                    + info.facts.map { fact in
                        "\(fact.0): \(fact.1)"
                    }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding([.horizontal, .bottom], 20)

            Divider()

            HStack {
                HStack {
                    if let action = info.action {
                        Button(action) {
                            if info.confirmation == nil {
                                dismiss()
                                info.perform()
                            } else {
                                isConfirming = true
                            }
                        }
                        .disabled(!info.enabled)
                    }

                    if let extra = info.extra {
                        Button(extra.title) {
                            dismiss()
                            extra.perform()
                        }
                        .disabled(!info.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 440)
        .confirming(info.confirmation, isPresented: $isConfirming) {
            dismiss()
        }
    }
}

/// What Storage shows, measured off the main thread; measured again when its pane is shown, and while it is shown when
/// the devices, their sessions or the firmware jobs change (which also asks canDelete again).
@Observable final class StorageUsage {
    nonisolated struct DeviceUsage: Sendable {
        let instance: DeviceInstance
        let base: Int64, data: Int64, snapshot: Int64
    }
    /// One app in the library, as Settings ▸ Storage lists it.
    nonisolated struct LibraryApp: Identifiable, Sendable {
        let sha256: String
        let bundleID: String
        let name: String?
        let version: String?
        let minOS: String?
        let size: Int64
        var id: String { sha256 }
    }

    nonisolated struct Usage: Sendable {
        var devices: [DeviceUsage] = []
        /// Entry id, file, allocated bytes, and the user's file an import from another volume refers to.
        var ipsws: [(entry: String, url: URL, bytes: Int64, referenced: URL?)] = []
        /// The firmware this app ships prepared (the catalog's `bundled`): entry id, its packed base, its bytes.
        var builtIn: [(entry: String, url: URL, bytes: Int64)] = []
        var decrypted: Int64 = 0
        var logs: Int64 = 0
        /// The library's apps by name, those a device has (the device copies are clones of them), and those no device
        /// has and nobody kept, with their bytes.
        var apps: [LibraryApp] = []
        /// How many devices have each app, by sha256 (none: absent).
        var appDevices: [String: Int] = [:]
        var unusedApps: Set<String> = []
        var unusedBytes: Int64 = 0
        /// Whether this is a measurement, not the empty Usage before the first one: the empty states wait for it.
        var measured = false
    }

    private(set) var usage = Usage()
    /// Bumped when a device's name changes (a rename, Device Name Style), which the view reads to draw them again.
    private(set) var nameRevision = 0
    @ObservationIgnored let catalog: FirmwareCatalog
    @ObservationIgnored let jobs: FirmwareJobs
    /// MainWindowController's Delete Device for one record (its confirmation included), and whether it may run now.
    @ObservationIgnored let delete: (DeviceInstance) -> Void
    @ObservationIgnored let canDelete: (DeviceInstance) -> Bool
    /// The sidebar's label for the record its row runs (the user's name, or the marketing name, over the version); nil
    /// for any other record.
    @ObservationIgnored let label: (DeviceInstance) -> SidebarList.Label?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Whether Storage is on screen: changes measure again only then (a download changes its job many times a second).
    @ObservationIgnored var isShown: () -> Bool = { false }
    /// A preview's fixed usage: never measured, and its actions touch nothing.
    @ObservationIgnored private var isPreview = false

    init(
        catalog: FirmwareCatalog = .bundled,
        jobs: FirmwareJobs,
        delete: @escaping (DeviceInstance) -> Void,
        canDelete: @escaping (DeviceInstance) -> Bool,
        label: @escaping (DeviceInstance) -> SidebarList.Label? = { _ in
            nil
        }
    ) {
        self.catalog = catalog
        self.jobs = jobs
        self.delete = delete
        self.canDelete = canDelete
        self.label = label
        observers = [
            DeviceLibrary.didChangeNotification, FirmwareJobs.didChangeNotification,
            DeviceSessionHost.didChangeNotification, IPSWStore.didChangeNotification
        ].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.isShown() == true { self?.reload() } }
            }
        }
        // A rename or Device Name Style: the names are read again at once, nothing measured.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: SidebarList.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.nameRevision += 1
                }
            }
        )
    }

    /// `usage` as given, for a preview: nothing is measured, watched or deleted.
    init(
        preview usage: Usage,
        catalog: FirmwareCatalog = .bundled,
        jobs: FirmwareJobs = .shared,
        canDelete: @escaping (DeviceInstance) -> Bool = { _ in true },
        label: @escaping (DeviceInstance) -> SidebarList.Label? = { _ in
            nil
        }
    ) {
        self.catalog = catalog
        self.jobs = jobs
        delete = { _ in }
        self.canDelete = canDelete
        self.label = label
        isPreview = true
        self.usage = usage
    }

    func reload() {
        guard !isPreview else { return }
        loading?.cancel()
        let instances = DeviceLibrary.shared.instances
        let catalog = catalog
        let store = IPSWStore.shared
        let builtIn = catalog.entries.compactMap { entry in
            FirmwareJobs.bundledBlob(entry).map { url in
                (entry.id, url)
            }
        }
        let index = IPALibrary.index
        let library = index.map { sha256, entry in
            LibraryApp(
                sha256: sha256,
                bundleID: entry.bundleID,
                name: entry.name,
                version: entry.version,
                minOS: entry.minOS,
                size: entry.size
            )
        }
        loading = Task { [weak self] in
            let usage = await Self.measure(
                instances, catalog: catalog, store: store, apps: index, library: library, builtIn: builtIn)
            guard !Task.isCancelled else { return }
            self?.usage = usage
        }
    }

    // MARK: - Measuring

    /// Allocated bytes of a file or a whole tree (links not followed); a cancelled measure stops walking.
    nonisolated static func allocated(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while !Task.isCancelled, let item = walk?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Off the main actor: it walks every device's files.
    @concurrent nonisolated static func measure(
        _ instances: [DeviceInstance],
        catalog: FirmwareCatalog,
        store: IPSWStore,
        apps: [String: IPALibrary.Entry],
        library: [LibraryApp],
        builtIn: [(String, URL)]
    ) async -> Usage {
        var usage = Usage(measured: true)
        for instance in instances {
            let paths = instance.paths
            let nor =
                paths.writableNOR.flatMap { $0.path.hasPrefix(paths.overlay.path + "/") ? nil : allocated($0) } ?? 0
            let snapshot = [paths.snapshot, paths.snapshotMeta, paths.snapshotTmp, paths.snapshotBad].map(allocated)
                .reduce(0, +)
            usage.devices.append(
                .init(
                    instance: instance,
                    base: allocated(paths.base),
                    data: allocated(paths.overlay) + nor,
                    snapshot: snapshot
                )
            )
        }
        for entry in catalog.entries {
            guard let sha1 = entry.source.sha1 else { continue }
            _ = store.existing(sha1)  // drops a reference whose file is gone or changed
            for url in [store.download(sha1), store.imported(sha1)]
            where FileManager.default.fileExists(atPath: url.path) {
                let referenced = url == store.imported(sha1) ? store.referenced(sha1) : nil
                usage.ipsws.append((entry.id, url, referenced == nil ? allocated(url) : 0, referenced))
            }
        }
        usage.decrypted = allocated(IPSWStore.cachesDirectory.appendingPathComponent("Decrypted", isDirectory: true))
        usage.logs = allocated(Bundled.logsDirectory)
        usage.builtIn = builtIn.map { id, url in
            (id, url, allocated(url))
        }
        usage.apps = library.sorted { a, b in
            (a.name ?? a.bundleID).localizedStandardCompare(b.name ?? b.bundleID) == .orderedAscending
        }
        usage.appDevices = IPALibrary.deviceCounts(apps, devices: instances)
        let unused = IPALibrary.unused(apps, devices: instances)
        usage.unusedApps = Set(unused.keys)
        usage.unusedBytes = unused.keys.reduce(0) { $0 + allocated(IPALibrary.blob($1)) }
        return usage
    }

    // MARK: - Actions

    func removeIPSW(_ url: URL) {
        guard !isPreview else { return }
        let sha1 = url.deletingPathExtension().lastPathComponent
        do {
            // A job that started since the pane was drawn may read it.
            guard !jobs.ipswsInUse.contains(sha1) else { return reload() }
            try IPSWStore.shared.remove(sha1)
            logEvent("storage: removed IPSW \(sha1)")
            jobs.pruneDecrypted(sha1)
        } catch { NSApp.presentError(error) }
        reload()
    }

    /// Add IPSW…, Add App… and files dropped on Settings: IPSWs stored, apps kept; false when there's neither.
    func add(_ urls: [URL]) -> Bool {
        let ipsws = urls.filter { url in
            url.pathExtension.lowercased() == "ipsw"
        }
        let ipas = urls.filter { url in
            url.pathExtension.lowercased() == "ipa"
        }
        if !ipsws.isEmpty {
            addIPSWs(ipsws)
        }
        if !ipas.isEmpty {
            addApps(ipas)
        }
        return !ipsws.isEmpty || !ipas.isEmpty
    }

    /// Add IPSW…: stored, not prepared; matched to the catalog off the main thread (the store's change measures again).
    func addIPSWs(_ urls: [URL]) {
        guard !isPreview else { return }
        jobs.importIPSWs(urls, prepare: false)
    }

    /// Add App…: each kept in the library without installing it.
    func addApps(_ urls: [URL]) {
        guard !isPreview else { return }
        Task {
            for url in urls {
                do {
                    try await IPALibrary.keep(url)
                } catch {
                    NSApp.presentError(error)
                }
            }
            reload()
        }
    }

    /// Copy into Light Touch: an IPSW kept as a reference to a file elsewhere is copied in, off the main thread.
    func copyIn(_ url: URL) {
        guard !isPreview else { return }
        let sha1 = url.deletingPathExtension().lastPathComponent
        Task {
            do {
                try await Task.detached {
                    try IPSWStore.shared.copyIn(sha1)
                }
                .value
                logEvent("storage: copied IPSW \(sha1) in")
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    /// Delete for apps no device has: gone from the library; the user's own files elsewhere stay.
    func removeApps(_ sha256s: [String]) {
        guard !isPreview else { return }
        do {
            try IPALibrary.remove(sha256s)
            logEvent("storage: removed \(sha256s.count) IPAs")
        } catch {
            NSApp.presentError(error)
        }
        reload()
    }

    func removeUnusedIPAs() {
        guard !isPreview else { return }
        do {
            try IPALibrary.removeUnused(devices: DeviceLibrary.shared.instances)
            logEvent("storage: removed the IPAs no device has")
        } catch { NSApp.presentError(error) }
        reload()
    }
}

extension StorageUsage {
    /// Settings ▸ Storage with a row of each kind, for the Settings preview: two devices (one running, so it can't be
    /// deleted), the built-in firmware, a downloaded, an imported and a referenced IPSW, the caches, and a library of apps on devices, kept and
    /// unused.
    static var preview: StorageUsage {
        let catalog = FirmwareCatalog.bundled
        let store = IPSWStore.shared
        let gb: Int64 = 1_000_000_000
        func device(_ firmware: String, base: Int64, data: Int64) -> DeviceUsage {
            let id = UUID()
            let path = "Devices/\(id.uuidString)"
            let instance = DeviceInstance(
                id: id,
                name: "",
                board: String(
                    firmware.prefix { character in
                        character != "-"
                    }
                ),
                firmware: firmware,
                created: Date(timeIntervalSinceNow: -12 * 86_400),
                base: .init(kind: .prepared, path: "\(path)/base"),
                storage: .init(
                    key: "",
                    overlay: "\(path)/overlay",
                    snapshot: "\(path)/snapshot",
                    usbmuxConf: "\(path)/usbmuxd-conf"
                )
            )
            return DeviceUsage(instance: instance, base: base, data: data, snapshot: 0)
        }
        func app(_ sha256: String, _ bundleID: String, _ name: String?, _ version: String?, _ size: Int64) -> LibraryApp
        {
            LibraryApp(sha256: sha256, bundleID: bundleID, name: name, version: version, minOS: "3.0", size: size)
        }
        func sha1(_ id: String) -> String {
            catalog.entry(id: id)?.source.sha1 ?? id
        }
        let usage = Usage(
            devices: [
                device("n72ap-7E18", base: 2 * gb, data: 340_000_000), device("k48ap-7B500", base: 3 * gb, data: gb)
            ],
            ipsws: [
                ("n45ap-4A102", store.download(sha1("n45ap-4A102")), 280_000_000, nil),
                ("k48ap-7B500", store.imported(sha1("k48ap-7B500")), 560_000_000, nil),
                (
                    "n88ap-10B500", store.imported(sha1("n88ap-10B500")), 0,
                    URL(fileURLWithPath: "/Volumes/Archive/iPhone2,1_6.1.3_10B500_Restore.ipsw")
                )
            ],
            builtIn: [
                (
                    "n72ap-7E18",
                    URL(fileURLWithPath: "/Applications/Light Touch.app/Contents/Resources/Device/n72ap-7E18.itbase"),
                    420_000_000
                )
            ],
            decrypted: 1_400_000_000,
            logs: 48_000_000,
            apps: [
                app("a1", "com.lima.doodlejump", "Doodle Jump", "1.8", 31_200_000),
                app("a2", "com.atebits.Tweetie2", "Twitter", "3.3", 2_900_000),
                app("a3", "com.burbn.instagram", "Instagram", "1.0.2", 17_700_000),
                app("a4", "com.spotify.client", "Spotify Music", "0.4", 12_200_000),
                app("a5", "com.wattpad.Wattpad", nil, nil, 734_000)
            ],
            appDevices: ["a1": 2, "a3": 1],
            unusedApps: ["a2", "a5"],
            unusedBytes: 3_634_000,
            measured: true
        )
        return StorageUsage(
            preview: usage,
            canDelete: { instance in
                instance.firmware != "k48ap-7B500"
            },
            label: { instance in
                catalog.entry(id: instance.firmware).map { entry in
                    SidebarList.label(for: entry, name: entry.id == "k48ap-7B500" ? "Sam’s iPad" : nil)
                }
            }
        )
    }
}

#Preview("Device details") {
    StorageInfoSheet(
        info: StorageInfo(
            id: "device",
            title: "iPod touch (2nd generation) iOS 3.1.3",
            size: "2.34 GB",
            facts: [
                ("Version", "3.1.3 (7E18)"), ("Base OS", "2 GB"), ("User Data", "340 MB"), ("Added", "Oct 30, 2026")
            ],
            action: "Delete…",
            enabled: true,
            perform: {}
        )
    )
}

#Preview("IPSW details, not copied") {
    StorageInfoSheet(
        info: StorageInfo(
            id: "ipsw",
            title: "iPhone 3GS iOS 6.1.3",
            size: "Not copied",
            facts: [
                ("Version", "6.1.3 (10B500)"),
                ("Source", "Imported"),
                ("File", "/Volumes/Archive/iPhone2,1_6.1.3_10B500_Restore.ipsw")
            ],
            action: "Remove",
            enabled: true,
            perform: {},
            extra: ("Copy into Light Touch", {})
        )
    )
}
