import Foundation

@main struct Check {
    static func main() async throws {
        for (os, allowed) in [("2.2.1", true), ("3", true), ("3.1.3", true),
                              ("3.1.4", false), ("3.2", false), ("10.0", false),
                              ("3.x", false), ("-1", false), ("3..1", false), ("", false)] {
            precondition((CatalogCopy.osIssue(os) == nil) == allowed, os)
        }
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
        for changes: [String: Any] in [["available": false], ["binary": NSNull()],
            ["binary": ["install_status": "encrypted", "architectures": ["armv6"]]],
            ["binary": ["install_status": "installable", "architectures": ["armv7"]]],
            ["binary": ["install_status": "installable", "architectures": ["armv6"], "macho_min_os": "4.0"]],
            ["binary": ["install_status": "installable", "architectures": ["armv6"], "device_family_macho": ["2"]]]] {
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
        // Failed replacement and adopting a library file itself preserve bytes.
        await IPALibrary.adopt(file, for: "test.catalog")
        let saved = IPALibrary.url(for: "test.catalog")!
        await IPALibrary.adopt(file.appendingPathExtension("missing"), for: "test.catalog")
        precondition(try! Data(contentsOf: saved) == data)
        await IPALibrary.adopt(saved, for: "test.catalog")
        precondition(try! Data(contentsOf: saved) == data)
        IPALibrary.forget("test.catalog")
        print("PASS: catalog schema, exact OS/architecture/encryption checks, file integrity and atomic IPA replacement")
    }
}
