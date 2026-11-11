// The Add Device sheet's panel under the versions: for one picked version, the device and build, its facts
// (released, download, source, prepared size) and what works on it (DeviceFeatures); for several, how many and what they
// take to download and prepare.

import FirmwareSchema
import HostRuntime
import LightTouchCore
import SwiftUI

struct AddDeviceSummary: View {
    let entries: [FirmwareCatalog.Entry]
    let downloaded: Set<String>
    /// Entries the bundled guest tools have a package for (GuestPackage.packaged).
    let guestPackaged: Set<String>

    /// What Add will download: the picked IPSWs that aren't here and don't ship with the app.
    static func downloadBytes(_ entries: [FirmwareCatalog.Entry], downloaded: Set<String>) -> Int64 {
        entries.filter { $0.bundled == nil && !downloaded.contains($0.id) }.map(AddDeviceRow.downloadBytes).reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if entries.count == 1, let entry = entries.first {
                single(entry)
            } else if !entries.isEmpty {
                several
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .padding(14)
    }

    // MARK: - One version

    private func single(_ entry: FirmwareCatalog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if let board = entry.profile {
                    Image(nsImage: board.icon).resizable().scaledToFit().frame(width: 40, height: 40)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.preferredName).font(.headline)
                    HStack(spacing: 6) {
                        Text("iOS \(entry.version)")
                        if let badge = entry.prereleaseBadge { Badge(text: badge) }
                        Text(entry.build).foregroundStyle(.secondary)
                        if let status = AddDeviceRow.statusText(entry.status) { Badge(text: status) }
                    }
                }
                Spacer(minLength: 12)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                    if let released = released(entry) { fact("Released", released) }
                    fact("IPSW", download(entry))
                    if let source = source(entry) { fact("Source", source) }
                    fact("Prepared", entry.estimates.preparedBytes.formatted(.byteCount(style: .file)))
                }
                .fixedSize()
            }
            Divider()
            Text("Supported")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .leading), count: 3),
                alignment: .leading,
                spacing: 5
            ) {
                ForEach(Feature.all(DeviceFeatures(entry, guestPackage: guestPackaged.contains(entry.id)))) {
                    FeatureCell(feature: $0)
                }
            }
        }
        .font(.callout)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func released(_ entry: FirmwareCatalog.Entry) -> String? {
        entry.released.flatMap { try? Date($0, strategy: .iso8601.year().month().day()) }?
            .formatted(date: .long, time: .omitted)
    }

    /// Where the IPSW comes from: Apple, or the mirror's host (archive.org).
    private func source(_ entry: FirmwareCatalog.Entry) -> String? {
        guard entry.bundled == nil, let host = entry.source.url?.host() else { return nil }
        return host.hasSuffix("apple.com") ? "Apple" : host
    }

    private func download(_ entry: FirmwareCatalog.Entry) -> String {
        if entry.bundled != nil { return "Included" }
        if downloaded.contains(entry.id) { return "Downloaded" }
        return AddDeviceRow.downloadBytes(entry).formatted(.byteCount(style: .file))
    }

    // MARK: - Several versions

    private var several: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(entries.count) versions").font(.headline)
                // One line each, the first few; the rest counted.
                ForEach(entries.prefix(4)) { entry in
                    Text(
                        "\(entry.preferredName), iOS \(entry.version)"
                            + (entry.prereleaseBadge.map { " \($0)" } ?? "")
                    )
                    .foregroundStyle(.secondary)
                }
                if entries.count > 4 {
                    Text("and \(entries.count - 4) more").foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                let bytes = Self.downloadBytes(entries, downloaded: downloaded)
                fact("Download", bytes == 0 ? "None" : bytes.formatted(.byteCount(style: .file)))
                fact(
                    "Prepared",
                    entries.map(\.estimates.preparedBytes).reduce(0, +).formatted(.byteCount(style: .file))
                )
            }
            .fixedSize()
        }
        .font(.callout)
    }
}

/// A tag beside the version: its beta or GM number, or its status.
private struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 5)
            .background(.quaternary, in: Capsule())
    }
}

/// One line of the Supported list: what it is, and whether this device and version has it.
struct Feature: Identifiable {
    let id: String
    let symbol: String
    let supported: Bool

    static func all(_ f: DeviceFeatures) -> [Feature] {
        [
            Feature(id: "Wi-Fi", symbol: "wifi", supported: f.wifi),
            Feature(id: "Cellular", symbol: "antenna.radiowaves.left.and.right", supported: f.cellular),
            Feature(id: "Audio", symbol: "speaker.wave.2", supported: f.audio),
            Feature(id: "Location", symbol: "location", supported: f.location),
            Feature(id: "Compass", symbol: "location.north.circle", supported: f.compass),
            Feature(id: "Vibration", symbol: "iphone.radiowaves.left.and.right", supported: f.vibration),
            Feature(id: "Rotation", symbol: "rotate.right", supported: f.rotation),
            Feature(id: "App Installs", symbol: "square.and.arrow.down", supported: f.appInstalls),
            Feature(id: "Free-Form Screen", symbol: "arrow.up.left.and.arrow.down.right", supported: f.freeFormScreen),
            Feature(id: "Skip Setup", symbol: "forward", supported: f.skipSetup),
            Feature(id: "Jailbreak", symbol: "lock.open", supported: f.jailbreak),
            Feature(id: "File System", symbol: "folder", supported: f.fileSystem),
            Feature(id: "Debug Port", symbol: "ladybug", supported: f.debugPort),
            Feature(id: "SSH and SFTP", symbol: "terminal", supported: f.developerTools),
            Feature(id: "Guest Tools", symbol: "wrench.and.screwdriver", supported: f.guestTools)
        ]
    }
}

private struct FeatureCell: View {
    let feature: Feature

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: feature.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(feature.id)
                .foregroundStyle(feature.supported ? .primary : .tertiary)
                .lineLimit(1)
            Spacer(minLength: 2)
            Image(systemName: feature.supported ? "checkmark" : "minus")
                .foregroundStyle(feature.supported ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(feature.id)
        .accessibilityValue(feature.supported ? "Supported" : "Not supported")
    }
}
