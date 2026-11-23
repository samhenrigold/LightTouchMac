import Foundation
import Testing

@testable import FirmwareKit

/// iPhone OS 1.x packages removed as their receipts say (Package1x.uninstall): the root as it was, what the package
/// didn't make kept, a receipt naming a path outside the roots refused.
struct Package1xUninstallTests {
    let fm = FileManager.default
    let t = Package1xTests()

    /// Every item under `root` but the receipts' folder: a file's bytes, a link's target, a folder.
    func tree(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        for rel in fm.subpaths(atPath: root.path) ?? [] where !rel.hasPrefix("Library/PXL") {
            let path = root.appendingPathComponent(rel).path
            if let target = try? fm.destinationOfSymbolicLink(atPath: path) {
                out[rel] = "-> " + target
            } else if let data = fm.contents(atPath: path) {
                out[rel] = data.base64EncodedString()
            } else {
                out[rel] = "/"
            }
        }
        return out
    }

    /// SummerBoard's shape: a framework, its postflight saving SpringBoard's launchd job and copying its own over
    /// it, its preremove moving the saved one back.
    @Test(arguments: [false, true])
    func anUninstallLeavesTheRootAsItWas(mobile: Bool) throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-pkg1x-rm-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let r = try t.root(dir.appendingPathComponent("root"), mobile: mobile)
        try JailbreakTests.put(Data("mine".utf8), r, "Library/LaunchDaemons/com.example.d.plist")
        let before = tree(r)
        let job = "/" + SystemEdits.springBoardJob
        let url = try t.pxl(
            dir,
            files: [
                ["source": "app", "destination": "/Applications/Edit.app"],
                ["source": "daemon", "destination": "/Library/LaunchDaemons", "overwrite": false],
                ["source": "notes.txt", "destination": "/var/root/Library/Edit/notes.txt"],
                ["source": "job", "destination": "/Library/Edit"]
            ],
            postflight: [
                ["/bin/launchctl", "load", job], ["/bin/cp", "/Library/Edit/job.plist", job],
                ["/bin/cp", job, "/Library/Edit/job.plist.bak"]
            ],
            members: [("job/job.plist", Data("edit's job".utf8), 0o644)]
        )
        var package = try Package1x.load(url)
        var info = package.info
        info["RDPxlPackagePreremove"] = [
            ["/bin/launchctl", "load", job], ["/bin/mv", "/Library/Edit/job.plist.bak", job]
        ]
        package = Package1x(
            identifier: package.identifier, name: package.name, info: info, placements: package.placements,
            postflight: package.postflight, warnings: [])
        let v = MountedVolume(root: r)
        _ = try package.install(v)
        #expect(try Data(contentsOf: r.appendingPathComponent(SystemEdits.springBoardJob)) == Data("edit's job".utf8))
        #expect(Package1x.installed(v) == [.init(identifier: "com.example.edit", name: "Edit", version: "0.2")])
        let receipt = try #require(
            NSDictionary(contentsOf: r.appendingPathComponent("Library/PXL/DB/com.example.edit.plist")))
        let replaced = (receipt["RDPxlPackageInstalledFiles"] as? [[String: Any]])?.filter {
            $0["replaced"] as? Bool == true
        }
        #expect(replaced?.compactMap { $0["file"] as? String } == [job], "the job it copied over, nothing it made")

        let done = try Package1x.uninstall("com.example.edit", v)
        #expect(tree(r) == before, "everything it made gone, SpringBoard's job back, the daemon it kept still mine")
        #expect(!fm.fileExists(atPath: r.appendingPathComponent("Library/PXL/DB/com.example.edit.plist").path))
        #expect(Package1x.installed(v).isEmpty)
        #expect(done.lines.contains("preremove /bin/mv /Library/Edit/job.plist.bak \(job)"))
        #expect(
            done.lines.contains { $0.contains("DisplayOrder.plist: com.example.edit.app out of iconList") } == !mobile)
        #expect(throws: FirmwareError.self) { try Package1x.uninstall("com.example.edit", v) }
    }

    @Test func whatItDidntMakeAndWhatIsPermanentStay() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-pkg1x-rm-keep-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let r = try t.root(dir.appendingPathComponent("root"), mobile: false)
        let v = MountedVolume(root: r)
        _ = try Package1x.load(t.pxl(dir)).install(v)  // notes.txt permanent
        try JailbreakTests.put(Data("the user's".utf8), r, "Applications/Edit.app/Documents/mine.txt")
        let done = try Package1x.uninstall("com.example.edit", v)
        #expect(fm.fileExists(atPath: r.appendingPathComponent("Applications/Edit.app/Documents/mine.txt").path))
        #expect(!fm.fileExists(atPath: r.appendingPathComponent("Applications/Edit.app/Edit").path))
        #expect(fm.fileExists(atPath: r.appendingPathComponent("private/var/root/Media/notes.txt").path), "permanent")
        #expect(!fm.fileExists(atPath: r.appendingPathComponent("Library/LaunchDaemons/com.example.d.plist").path))
        // Edit.app (the user's file), Media (the permanent notes) and Library (the receipts) stay
        #expect(
            done.lines.last
                == "Edit: 5 files and 1 folders removed, 1 kept (permanent or replaced), 3 folders not empty")
    }

    /// The receipt is the device's: a path in it outside the roots, or through a link out of them, removes nothing.
    @Test(arguments: ["/dev/x", "/Applications/dev/x", "/Applications/../dev", "/Library/PXL/DB"])
    func aReceiptOutsideTheRootsIsRefused(_ file: String) throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-pkg1x-rm-bad-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let r = try t.root(dir.appendingPathComponent("volume/root"), mobile: false)
        try JailbreakTests.put(Data("dev".utf8), dir.appendingPathComponent("volume"), "dev/x")
        try JailbreakTests.put(Data("keep".utf8), r, "Applications/Keep.app/Keep")
        let receipt: [String: Any] = [
            "CFBundleIdentifier": "bad",
            "RDPxlPackageInstalledFiles": [["file": "/Applications/Keep.app/Keep"], ["file": file]]
        ]
        try JailbreakTests.put(Package1xTests.plist(receipt), r, "Library/PXL/DB/bad.plist")
        #expect(throws: FirmwareError.self, "\(file)") { try Package1x.uninstall("bad", MountedVolume(root: r)) }
        #expect(fm.fileExists(atPath: r.appendingPathComponent("Applications/Keep.app/Keep").path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("volume/dev/x").path))
        #expect(throws: FirmwareError.self) { try Package1x.uninstall("../bad", MountedVolume(root: r)) }
    }

    @Test func aPreremoveThatRunsAToolIsRefused() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-pkg1x-rm-tool-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let r = try t.root(dir.appendingPathComponent("root"), mobile: false)
        let receipt: [String: Any] = [
            "CFBundleIdentifier": "tool", "RDPxlPackagePreremove": [["/usr/bin/springpatch", "-u"]],
            "RDPxlPackageInstalledFiles": [] as [Any]
        ]
        try JailbreakTests.put(Package1xTests.plist(receipt), r, "Library/PXL/DB/tool.plist")
        let error = #expect(throws: FirmwareError.self) { try Package1x.uninstall("tool", MountedVolume(root: r)) }
        #expect(error?.message.contains("preremove runs /usr/bin/springpatch") == true)
        #expect(fm.fileExists(atPath: r.appendingPathComponent("Library/PXL/DB/tool.plist").path))
    }
}
