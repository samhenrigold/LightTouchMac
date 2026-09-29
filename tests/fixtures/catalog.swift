import Foundation

@main struct Check {
    static func main() async throws {
        for (os, allowed) in [("2.2.1", true), ("3", true), ("3.1.3", true),
                              ("3.1.4", false), ("3.2", false), ("10.0", false),
                              ("3.x", false), ("-1", false), ("3..1", false), ("", false)] {
            precondition((CatalogCopy.osIssue(os) == nil) == allowed, os)
        }
        // The device's own version, not 3.1.3: a 4.2.1 iPod takes 4.0 apps, a 3.2.2 iPad refuses 4.0 and takes 3.2.
        for (os, device, allowed) in [("4.0", "4.2.1", true), ("4.2.1", "4.2.1", true), ("4.3", "4.2.1", false),
                                      ("3.2", "3.2.2", true), ("4.0", "3.2.2", false), ("3.1.3", "3.2", true)] {
            precondition((CatalogCopy.osIssue(os, deviceOS: device) == nil) == allowed, "\(os) on \(device)")
        }
        precondition(CatalogCopy.osIssue("4.0", deviceOS: "3.2.2") == "Requires iOS 4.0; this device runs iOS 3.2.2.")
        let data = Data("abc".utf8)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let good: [String: Any] = ["ipa_id": "123", "size": 3,
            "md5": "900150983cd24fb0d6963f7d28e17f72", "available": true,
            "binary": ["install_status": "installable", "architectures": ["armv6"], "macho_min_os": "3.0"]]
        func copy(_ changes: [String: Any] = [:]) throws -> CatalogCopy {
            try JSONDecoder().decode(CatalogCopy.self, from: JSONSerialization.data(withJSONObject: good.merging(changes) { _, new in new }))
        }
        try await copy().verifyDownload(file)
        precondition(try! copy().unavailableReason(minimumOS: "3.0") == nil)
        precondition(try! copy().unavailableReason(minimumOS: "3.2") != nil)
        // The iPad's armv7 CPU runs an armv6-only copy and an armv7 one; its version is the iPad's.
        precondition(try! copy().unavailableReason(minimumOS: "3.0", deviceOS: "3.2.2", arch: "armv7") == nil)
        let armv7: [String: Any] = ["binary": ["install_status": "installable", "architectures": ["armv7"], "macho_min_os": "3.2", "device_family_macho": ["2"]]]
        precondition(try! copy(armv7).unavailableReason(minimumOS: "3.2", deviceOS: "3.2.2", arch: "armv7") == nil)
        precondition(try! copy(armv7).unavailableReason(minimumOS: "4.0", deviceOS: "3.2.2", arch: "armv7") != nil)
        precondition(try! copy(armv7).unavailableReason(minimumOS: "3.2", arch: "armv6") != nil)
        for changes: [String: Any] in [["available": false], ["binary": NSNull()],
            ["binary": ["install_status": "encrypted", "architectures": ["armv6"]]],
            ["binary": ["install_status": "installable", "architectures": ["armv7"]]],
            ["binary": ["install_status": "installable", "architectures": ["armv6"], "macho_min_os": "4.0"]],
            ["binary": ["install_status": "installable", "architectures": ["armv6"], "device_family_macho": ["3"]]]] {
            precondition(try! copy(changes).unavailableReason(minimumOS: "2.0") != nil)
        }
        for changes: [String: Any] in [["size": 4], ["md5": String(repeating: "0", count: 32)], ["md5": "bad"]] {
            do { try await copy(changes).verifyDownload(file); fatalError("bad download accepted") }
            catch is CatalogError {}
        }
        // Actual deployed API responses, when supplied by the optional live check.
        if CommandLine.arguments.contains("--live-fixtures") {
            let actual = try JSONDecoder().decode(CatalogCopy.self, from: Data(contentsOf: URL(fileURLWithPath: "/tmp/ltm-live-copy.json")))
            precondition(actual.ipa_id == "192826" && actual.unavailableReason(minimumOS: "2.0") == nil)
            struct Versions: Decodable { let data: [CatalogVersion] }
            let versions = try JSONDecoder().decode(Versions.self, from: Data(contentsOf: URL(fileURLWithPath: "/tmp/ltm-live-versions.json")))
            precondition(!versions.data.isEmpty)
        }
        // The retained copies are tests/offline/check-ipa-library.py's.
        print("PASS: catalog schema, exact OS/architecture/encryption checks and file integrity")
    }
}
