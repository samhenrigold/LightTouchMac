import Cocoa

/// Settings > Storage: what each device and the app's stores take on disk
/// (allocated bytes: bases and overlays are sparse), with the actions that
/// give it back. docs/multi-device-plan.md, "Storage policy".
final class StorageSettingsView: NSView {
    nonisolated struct DeviceUsage: Sendable {
        let instance: DeviceInstance
        let base: Int64, data: Int64, snapshot: Int64
    }
    nonisolated struct Usage: Sendable {
        var devices: [DeviceUsage] = []
        /// Entry id, file, allocated bytes.
        var ipsws: [(entry: String, url: URL, bytes: Int64)] = []
        var decrypted: Int64 = 0
        var logs: Int64 = 0
        /// The IPA store's blobs (the device copies are clones of them).
        var library: Int64 = 0
    }

    private let catalog: FirmwareCatalog
    /// MainWindowController's Delete Device (its confirmation included), and whether it may run now.
    private let delete: (FirmwareCatalog.Entry) -> Void
    private let canDelete: (FirmwareCatalog.Entry) -> Bool
    private let stack = NSStackView()
    private var loading: Task<Void, Never>?
    var onResize: (() -> Void)?

    init(catalog: FirmwareCatalog = .bundled, delete: @escaping (FirmwareCatalog.Entry) -> Void,
         canDelete: @escaping (FirmwareCatalog.Entry) -> Bool) {
        self.catalog = catalog
        self.delete = delete
        self.canDelete = canDelete
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.widthAnchor.constraint(equalToConstant: 520),
        ])
        for name in [DeviceLibrary.didChangeNotification, FirmwareJobs.didChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: name, object: nil)
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var fittingSize: NSSize { stack.fittingSize }

    @objc private func changed(_ note: Notification) { if window?.isVisible == true { reload() } }

    func reload() {
        loading?.cancel()
        let instances = DeviceLibrary.shared.instances, catalog = catalog, store = IPSWStore.shared
        loading = Task { [weak self] in
            let usage = await Task.detached { Self.measure(instances, catalog: catalog, store: store) }.value
            guard !Task.isCancelled else { return }
            self?.show(usage)
        }
    }

    // MARK: - Measuring

    /// Allocated bytes of a file or a whole tree (links not followed).
    nonisolated static func allocated(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let item = walk?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    nonisolated static func measure(_ instances: [DeviceInstance], catalog: FirmwareCatalog, store: IPSWStore) -> Usage {
        var usage = Usage()
        for instance in instances {
            let paths = instance.paths
            let nor = paths.writableNOR.flatMap { $0.path.hasPrefix(paths.overlay.path + "/") ? nil : allocated($0) } ?? 0
            let snapshot = [paths.snapshot, paths.snapshotMeta, paths.snapshotTmp, paths.snapshotBad].map(allocated).reduce(0, +)
            usage.devices.append(.init(instance: instance, base: allocated(paths.base), data: allocated(paths.overlay) + nor, snapshot: snapshot))
        }
        for entry in catalog.entries {
            guard let sha1 = entry.source.sha1 else { continue }
            for url in [store.download(sha1), store.imported(sha1)] where FileManager.default.fileExists(atPath: url.path) {
                usage.ipsws.append((entry.id, url, allocated(url)))
            }
        }
        usage.decrypted = allocated(IPSWStore.cachesDirectory.appendingPathComponent("Decrypted", isDirectory: true))
        usage.logs = allocated(Bundled.logsDirectory)
        usage.library = allocated(IPALibrary.directory)
        return usage
    }

    // MARK: - Showing

    private func show(_ usage: Usage) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        func name(_ id: String) -> String {
            catalog.entry(id: id).map { "\($0.profile?.displayName ?? $0.productType) iOS \($0.version)" } ?? id
        }
        func heading(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            return label
        }
        func detail(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.textColor = .secondaryLabelColor
            return label
        }
        func button(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) -> NSButton {
            let button = InlineActionButton(title: title, perform: action)
            button.isEnabled = enabled
            return button
        }
        func grid(_ rows: [[NSView]]) -> NSGridView {
            let grid = NSGridView(views: rows)
            grid.column(at: 0).width = 180
            grid.columnSpacing = 12
            grid.rowSpacing = 8
            grid.yPlacement = .center
            return grid
        }

        stack.addArrangedSubview(heading("Devices"))
        stack.addArrangedSubview(usage.devices.isEmpty ? detail("No devices.") : grid(usage.devices.map { device in
            let entry = catalog.entry(id: device.instance.firmware)
            return [NSTextField(labelWithString: name(device.instance.firmware)),
                    detail("System \(size(device.base)) · Data \(size(device.data + device.snapshot))"),
                    button("Delete Device…", enabled: entry.map(canDelete) ?? false) { [weak self] in entry.map { self?.delete($0) } }]
        }))

        stack.addArrangedSubview(heading("Firmware"))
        let jobs = FirmwareJobs.shared.jobs
        stack.addArrangedSubview(usage.ipsws.isEmpty ? detail("No downloaded or imported IPSWs.") : grid(usage.ipsws.map { ipsw in
            let busy = jobs[ipsw.entry].map { if case .failed = $0 { false } else { true } } ?? false
            let kind = ipsw.url.path.hasPrefix(IPSWStore.shared.imports.path) ? "Imported" : "Downloaded"
            return [NSTextField(labelWithString: name(ipsw.entry)), detail("\(kind) IPSW · \(size(ipsw.bytes))"),
                    button("Remove IPSW", enabled: !busy) { [weak self] in self?.removeIPSW(ipsw.url) }]
        }))

        stack.addArrangedSubview(heading("Caches and Logs"))
        let preparing = jobs.values.contains { if case .preparing = $0 { true } else { false } }
        stack.addArrangedSubview(grid([
            [NSTextField(labelWithString: "Decrypted firmware"), detail(size(usage.decrypted)),
             button("Clear Caches", enabled: usage.decrypted > 0 && !preparing) { [weak self] in self?.clearCaches() }],
            [NSTextField(labelWithString: "Logs"), detail(size(usage.logs)), NSView()],
        ]))

        stack.addArrangedSubview(heading("Apps"))
        let unused = IPALibrary.unused(devices: DeviceLibrary.shared.instances)
        let unusedBytes = unused.values.reduce(0) { $0 + $1.size }
        stack.addArrangedSubview(grid([
            [NSTextField(labelWithString: "Library"),
             detail("\(IPALibrary.index.count) IPAs · \(size(usage.library))" + (unused.isEmpty ? "" : " · \(size(unusedBytes)) unused")),
             button("Remove Unused Apps", enabled: !unused.isEmpty) { [weak self] in self?.removeUnusedIPAs() }],
        ]))
        layoutSubtreeIfNeeded()
        onResize?()
    }

    // MARK: - Actions

    private func removeIPSW(_ url: URL) {
        do {
            let sha1 = url.deletingPathExtension().lastPathComponent
            try IPSWStore.shared.remove(sha1)
            logEvent("storage: removed IPSW \(sha1)")
        } catch { NSApp.presentError(error) }
        reload()
    }

    private func removeUnusedIPAs() {
        do {
            try IPALibrary.removeUnused(devices: DeviceLibrary.shared.instances)
            logEvent("storage: removed the IPAs no device has")
        } catch { NSApp.presentError(error) }
        reload()
    }

    /// Only between preparations: a running one reads its decrypt cache.
    private func clearCaches() {
        do {
            try DeviceStateStorage.removeTree(IPSWStore.cachesDirectory.appendingPathComponent("Decrypted", isDirectory: true))
            logEvent("storage: cleared the decrypt cache")
        } catch { NSApp.presentError(error) }
        reload()
    }
}

extension StorageSettingsView: SettingsPane {}
