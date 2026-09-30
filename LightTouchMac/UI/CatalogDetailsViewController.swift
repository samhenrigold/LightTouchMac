import Cocoa
import SwiftUI

/// A version picker backed by the public copy API; install eligibility is
/// rechecked by the emulator endpoint when the user chooses a copy.
final class CatalogDetailsViewController: NSHostingController<CatalogDetailsView> {
    let model: CatalogDetailsModel

    init(app: CatalogApp, device: String? = nil, deviceOS: String = "3.1.3", arch: String = "armv6",
         installedVersion: String? = nil, canInstall: @escaping () -> Bool, install: @escaping (CatalogApp) -> Void) {
        model = CatalogDetailsModel(app: app, device: device, deviceOS: deviceOS, arch: arch,
                                    installedVersion: installedVersion, canInstall: canInstall, install: install)
        super.init(rootView: CatalogDetailsView(model: model))
        sizingOptions = .preferredContentSize
        model.close = { [weak self] in self.map { $0.dismiss($0) } }
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor @Observable final class CatalogDetailsModel {
    typealias Row = (version: CatalogVersion, copy: CatalogVersion.Copy)
    let app: CatalogApp
    /// The device's model, iOS version and executable slice (its catalog entry).
    let device: String?, deviceOS: String, arch: String
    let installedVersion: String?
    let canInstall: () -> Bool
    let install: (CatalogApp) -> Void
    var close: () -> Void = {}

    /// nil while loading.
    var rows: [Row]?
    /// The chosen copy's ipa_id.
    var selection: String?
    var details: CatalogCopy?
    /// Why the chosen copy can't be installed, or why nothing loaded.
    var problem: String?
    /// The revalidated copy Install will fetch.
    var candidate: CatalogApp?

    init(app: CatalogApp, device: String?, deviceOS: String, arch: String, installedVersion: String?,
         canInstall: @escaping () -> Bool, install: @escaping (CatalogApp) -> Void) {
        self.app = app
        self.device = device
        self.deviceOS = deviceOS
        self.arch = arch
        self.installedVersion = installedVersion
        self.canInstall = canInstall
        self.install = install
    }

    var selectedRow: Row? { rows?.first { $0.copy.ipa_id == selection } }

    func title(_ row: Row) -> String {
        let size = row.copy.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        // Two archived copies of one version need their copy number to tell apart.
        let twin = (rows ?? []).filter { $0.version.version == row.version.version }.count > 1
        return [row.version.version ?? "Unknown", size, twin ? "Copy \(row.copy.ipa_id)" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Choosing an older version than the one installed: the only case where data is at risk.
    var downgradeNote: String? {
        guard let installedVersion, let chosen = selectedRow?.version.version,
              chosen.compare(installedVersion, options: .numeric) == .orderedAscending else { return nil }
        return "Version \(installedVersion) is installed. An older version may not read its data."
    }

    func load() async {
        guard rows == nil else { return }
        do {
            let records = try await CatalogClient.versions(for: app)
            let found: [Row] = records.flatMap { version in
                version.copies.filter { copy in
                    copy.ipa_id == String(app.ipaID) || (
                        copy.install_status == "installable" && CatalogCopy.runs(copy.architectures, on: arch)
                        && CatalogCopy.osIssue(version.minimum_os_version, deviceOS: deviceOS) == nil
                        && CatalogCopy.osIssue(copy.macho_min_os, deviceOS: deviceOS) == nil)
                }.map { (version, $0) }
            }
            rows = found
            guard !found.isEmpty else {
                problem = "No \(arch) copies are available."
                return
            }
            selection = found.first { $0.copy.ipa_id == String(app.ipaID) }?.copy.ipa_id ?? found[0].copy.ipa_id
        } catch {
            guard !Task.isCancelled else { return }
            rows = []
            problem = "Couldn’t load versions: \(error.localizedDescription)"
        }
    }

    /// Runs for each selection; the view cancels it when the selection changes.
    func check() async {
        guard let row = selectedRow, row.copy.ipa_id != details?.ipa_id else { return }
        details = nil
        candidate = nil
        problem = nil
        do {
            guard let id = Int(row.copy.ipa_id), id > 0 else {
                throw CatalogError.invalidCopy("The archive returned an invalid copy identifier.")
            }
            let copy = try await CatalogClient.copyDetails(id)
            try Task.checkCancellation()
            details = copy
            if let issue = copy.unavailableReason(minimumOS: row.version.minimum_os_version, deviceOS: deviceOS, arch: arch) {
                problem = issue
                return
            }
            let found = try await CatalogClient.compatibleCopy(id, device: device, os: deviceOS)
            try Task.checkCancellation()
            guard found.bundleID == app.bundleID else {
                throw CatalogError.invalidCopy("This copy belongs to a different app.")
            }
            candidate = found
        } catch {
            guard !Task.isCancelled else { return }
            problem = error.localizedDescription
        }
    }

    var canInstallSelection: Bool { candidate != nil && canInstall() }

    func installSelection() {
        guard let candidate, canInstall() else { return }
        install(candidate)
        close()
    }
}

struct CatalogDetailsView: View {
    @Bindable var model: CatalogDetailsModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if let rows = model.rows, !rows.isEmpty {
                        Picker("Version", selection: $model.selection) {
                            ForEach(rows, id: \.copy.ipa_id) { Text(model.title($0)).tag(Optional($0.copy.ipa_id)) }
                        }
                    } else {
                        LabeledContent("Version") {
                            if model.rows == nil { ProgressView().controlSize(.small) } else { Text("None") }
                        }
                    }
                    LabeledContent("File", value: model.details?.filename.map { ($0 as NSString).lastPathComponent } ?? "—")
                    LabeledContent("Architecture", value: model.details?.binary?.architectures?.joined(separator: ", ") ?? "—")
                    LabeledContent("Minimum iOS", value: minimumOS ?? "—")
                } header: {
                    Text(model.app.name).font(.headline)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let problem = model.problem {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                        }
                        if let note = model.downgradeNote { Text(note) }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Install This Version") { model.installSelection() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canInstallSelection)
                    .help(model.problem ?? "")
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        .task { await model.load() }
        .task(id: model.selection) { await model.check() }
    }

    /// The listing's minimum, and the binary's own when they disagree.
    private var minimumOS: String? {
        let listed = model.selectedRow?.version.minimum_os_version
        guard let binary = model.details?.binary?.macho_min_os, binary != listed else { return listed }
        return listed.map { "\($0) (binary \(binary))" } ?? binary
    }
}
