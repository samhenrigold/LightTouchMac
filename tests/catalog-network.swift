import Cocoa

@main struct Check {
    @MainActor static func main() async throws {
        let port = CommandLine.arguments[1]
        let before = UserDefaults.standard.object(forKey: "LTMCatalogBaseURL")
        UserDefaults.standard.set("http://127.0.0.1:\(port)", forKey: "LTMCatalogBaseURL")
        defer {
            if let before { UserDefaults.standard.set(before, forKey: "LTMCatalogBaseURL") }
            else { UserDefaults.standard.removeObject(forKey: "LTMCatalogBaseURL") }
        }
        let found = try await CatalogClient.search("fixture")
        precondition(found.count == 1)
        let versions = try await CatalogClient.versions(for: found[0])
        precondition(versions.count == 2)
        let work = Bundled.workDirectory
        func scratch() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: work.path).filter { $0.hasPrefix("catalog-") })
        }
        let baseline = try scratch()
        let file = try await CatalogClient.download(found[0]) { _ in }
        precondition(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        let bad = try await CatalogClient.compatibleCopy(666)
        do { _ = try await CatalogClient.download(bad) { _ in }; fatalError("bad hash accepted") }
        catch is CatalogError {}
        do { _ = try await CatalogClient.compatibleCopy(999); fatalError("503 accepted") }
        catch CatalogError.badStatus(503) {}
        let slow = try await CatalogClient.compatibleCopy(777)
        let task = Task { try await CatalogClient.download(slow) { _ in } }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; fatalError("cancelled download succeeded") }
        catch {}
        let final = try scratch()
        precondition(baseline == final, "scratch leaked")
        print("PASS: real HTTP catalog decode, download, checksum rejection, HTTP errors, cancellation and scratch cleanup")
    }
}
