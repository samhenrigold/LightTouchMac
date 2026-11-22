import Foundation

@testable import LightTouchCore

/// A minimal app archive at `url`: Payload/<name>.app/Info.plist naming `bundleID`, plus any extra plist keys,
/// and `executable` as its main binary when given, zipped by the system's zip.
func makeIPA(
    at url: URL, bundleID: String = "com.example.app", name: String = "X", info extra: [String: Any] = [:],
    executable: Data? = nil
) throws {
    let work = url.deletingLastPathComponent().appendingPathComponent(".ipa-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let app = work.appendingPathComponent("Payload/\(name).app", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    var info = extra.merging(["CFBundleIdentifier": bundleID, "CFBundleName": name]) { a, _ in a }
    if let executable {
        info["CFBundleExecutable"] = name
        try executable.write(to: app.appendingPathComponent(name))
    }
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
        to: app.appendingPathComponent("Info.plist")
    )
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.arguments = ["-qr", url.path, "Payload"]
    zip.currentDirectoryURL = work
    try zip.run()
    zip.waitUntilExit()
    precondition(zip.terminationStatus == 0, "zip failed")
}
