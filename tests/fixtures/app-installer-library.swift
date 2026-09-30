// IPALibrary and the Legacy Store as Features/AppInstaller.swift calls them, recording what the removal flow asks,
// for the queue checks that don't compile the real ones (tests/fixtures/app-installer.swift has the rest).

import Foundation

@MainActor enum IPALibrary {
    struct Metadata {
        var bundleID: String, name: String? = nil, version: String? = nil, minOS: String? = nil, catalogIpaID: Int? = nil
    }
    static var forgotten: [String] = []
    static func adopt(_ ipa: URL, _ metadata: Metadata, device: DeviceInstance) async {}
    static func forget(_ id: String, device: DeviceInstance) { forgotten.append(id) }
    /// Another device still keeps the app: its icon stays.
    static var elsewhere: Set<String> = []
    static func retained(_ id: String, by devices: [DeviceInstance]) -> Bool { elsewhere.contains(id) }
}

struct CatalogApp { let bundleID: String?, name: String, ipaID: Int, iconURL: URL?, size: Int64? }
enum CatalogError: LocalizedError {
    case invalidCopy(String), unreadable
    var errorDescription: String? { if case .unreadable = self { "Legacy Store sent a response Light Touch couldn’t read." } else { nil } }
}
enum CatalogClient {
    static func download(_ app: CatalogApp, device: String?, deviceOS: String, arch: String,
                         progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> URL {
        throw CatalogError.invalidCopy("offline")
    }
}
