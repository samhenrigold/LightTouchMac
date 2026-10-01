import Foundation

nonisolated struct InstalledApp: Identifiable, Codable, Sendable {
    /// The `CFBundleIdentifier`
    let id: String
    let name: String
    let version: String
}

nonisolated struct DeviceFile: Codable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isRegular: Bool
    let size: UInt64
}


/// A host worker can never select another device after it starts. The session
/// distinguishes reused ports and prevents completions crossing a cold boot.
nonisolated struct HostServiceEndpoint: Hashable, Codable, Sendable {
    let socket: String
    let udid: String?
    let session: UUID
}

nonisolated enum HostServiceOperation: Codable, Sendable {
    case attachment, apps, freeSpace, installReady, homeOrder, orientation
    case lockdownValue(String)
    case uninstall(String), install(String)
    case upload(source: String, remote: String, reuse: Bool, allowEmpty: Bool)
    case sweep, remove(String), files(String)
    case download(DeviceFile, destination: String)
    case move(bundle: String, before: String?, deviceName: String)
    case observe
}

nonisolated enum HostServiceValue: Codable, Sendable {
    case none, boolean(Bool), integer(Int64), string(String?), strings([String])
    case apps([InstalledApp]), files([DeviceFile])
}

nonisolated enum HostServiceProgress: Codable, Sendable {
    case fraction(Double), install(Int, String), notification
}

