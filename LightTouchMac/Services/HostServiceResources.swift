import Foundation

/// Resources of the host service executable, independent of GUI and firmware
/// preparation. Libraries still deploy through the existing dlopen boundary.
nonisolated enum HostServiceResources {
    static let stagingSession = ProcessInfo.processInfo.environment["LTM_SERVICE_STAGING_SESSION"] ?? UUID().uuidString
    static var udid: String? { ProcessInfo.processInfo.environment["LTM_SERVICE_UDID"].flatMap { $0.isEmpty ? nil : $0 } }
    static var frameworksDirectory: String? {
        ProcessInfo.processInfo.environment["LTM_SERVICE_FRAMEWORKS"] ?? Bundle.main.privateFrameworksPath
    }
    static var executable: String? {
        if let override = ProcessInfo.processInfo.environment["LTM_HOST_SERVICE_WORKER"] {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("LightTouchServices").path
        return sibling.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }
}
