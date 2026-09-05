import Cocoa

/// A version picker backed by the public copy API; install eligibility is
/// rechecked by the emulator endpoint when the user chooses a copy.
final class CatalogDetailsViewController: NSViewController {
    private let app: CatalogApp
    private let install: (CatalogApp) -> Void
    private let canInstall: () -> Bool
    private let picker = NSPopUpButton()
    private let details = NSTextField(wrappingLabelWithString: "Loading archived versions…")
    private let installButton = NSButton(title: "Install This Version", target: nil, action: nil)
    private var versions: [(version: CatalogVersion, copy: CatalogVersion.Copy)] = []
    private var loadTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var selected: CatalogApp?

    init(app: CatalogApp, canInstall: @escaping () -> Bool, install: @escaping (CatalogApp) -> Void) {
        self.app = app
        self.canInstall = canInstall
        self.install = install
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 510, height: 390))
        let title = NSTextField(labelWithString: app.name)
        title.font = .boldSystemFont(ofSize: 17)
        title.lineBreakMode = .byTruncatingTail
        picker.target = self
        picker.action = #selector(selectionChanged)
        picker.setAccessibilityLabel("Archived version")
        picker.isEnabled = false
        details.isSelectable = true
        let caution = NSTextField(wrappingLabelWithString:
            "Compatibility checks identify candidates, not tested games. Installing another version replaces the installed app; older versions may not understand its saved data.")
        caution.font = .systemFont(ofSize: 11)
        caution.textColor = .secondaryLabelColor
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\u{1b}"
        installButton.target = self
        installButton.action = #selector(installClicked)
        installButton.isEnabled = false
        let buttons = NSStackView(views: [close, installButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [title, picker, details, caution, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24),
            picker.widthAnchor.constraint(equalTo: stack.widthAnchor),
            details.widthAnchor.constraint(equalTo: stack.widthAnchor),
            caution.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let records = try await CatalogClient.versions(for: app)
                try Task.checkCancellation()
                versions = records.flatMap { version in
                    version.copies.filter { copy in
                        copy.ipa_id == String(self.app.ipaID) || (
                            copy.install_status == "installable" && copy.architectures?.contains("armv6") == true
                            && CatalogCopy.osIssue(version.minimum_os_version) == nil
                            && CatalogCopy.osIssue(copy.macho_min_os) == nil)
                    }.map { (version, $0) }
                }
                for row in versions {
                    let size = row.copy.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown size"
                    picker.addItem(withTitle: "Version \(row.version.version ?? "unknown") · \(size) · Copy \(row.copy.ipa_id)")
                }
                guard !versions.isEmpty else {
                    details.stringValue = "No candidate ARMv6 copies are currently available."
                    return
                }
                picker.isEnabled = true
                picker.selectItem(at: versions.firstIndex { $0.copy.ipa_id == String(self.app.ipaID) } ?? 0)
                selectionChanged()
            } catch {
                guard !Task.isCancelled else { return }
                details.stringValue = "Couldn’t load versions: \(error.localizedDescription)"
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        loadTask?.cancel()
        selectionTask?.cancel()
    }

    @objc private func selectionChanged() {
        selectionTask?.cancel()
        selected = nil
        installButton.isEnabled = false
        guard versions.indices.contains(picker.indexOfSelectedItem) else { return }
        let row = versions[picker.indexOfSelectedItem]
        details.stringValue = "Checking this archived copy…"
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let id = Int(row.copy.ipa_id), id > 0 else {
                    throw CatalogError.invalidCopy("The archive returned an invalid copy identifier.")
                }
                let copy = try await CatalogClient.copyDetails(id)
                try Task.checkCancellation()
                let issue = copy.unavailableReason(minimumOS: row.version.minimum_os_version)
                details.stringValue = [
                    "File: \(copy.filename ?? "Unknown")",
                    "Architecture: \(copy.binary?.architectures?.joined(separator: ", ") ?? "Unknown")",
                    "Minimum iOS: \(row.version.minimum_os_version ?? "Unknown") (binary: \(copy.binary?.macho_min_os ?? "Unknown"))",
                    "Download check: \(copy.md5 == nil ? "Size only; no archive checksum" : "Size and archive MD5")",
                    issue ?? "ARMv6 candidate for iOS 3.1.3; not runtime-tested."
                ].joined(separator: "\n")
                guard issue == nil else { return }
                let candidate = try await CatalogClient.compatibleCopy(id)
                try Task.checkCancellation()
                guard candidate.bundleID == app.bundleID else {
                    throw CatalogError.invalidCopy("This copy belongs to a different app.")
                }
                selected = candidate
                installButton.isEnabled = canInstall()
            } catch {
                guard !Task.isCancelled else { return }
                details.stringValue += "\n\n\(error.localizedDescription)"
            }
        }
    }

    @objc private func closeClicked() { dismiss(self) }
    @objc private func installClicked() {
        guard let selected, canInstall() else { return }
        install(selected)
        dismiss(self)
    }
}
