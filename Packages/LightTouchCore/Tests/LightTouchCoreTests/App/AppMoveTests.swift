import Foundation
import Testing

@testable import LightTouchCore

/// The move out of App Translocation: offered only where Sparkle can't update, to /Applications when it can be written
/// (else ~/Applications, never an administrator password), a copy already there replaced, and no file of the copy
/// left quarantined (it would be translocated again).
struct AppMoveTests {
    @Test func onlyATranslocatedCopyIsStuck() {
        let translocated = URL(
            fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/0A1B2C3D/d/Light Touch.app"
        )
        #expect(AppMove.isStuck(translocated))
        #expect(!AppMove.isStuck(FileManager.default.temporaryDirectory.appendingPathComponent("Light Touch.app")))
    }

    @Test func applicationsUnlessItOrTheCopyThereCantBeWritten() {
        let bundle = URL(fileURLWithPath: "/x/AppTranslocation/1/d/Light Touch.app")
        let system = FileManager.default.temporaryDirectory.appendingPathComponent("system-\(UUID().uuidString)")
        let home = URL(fileURLWithPath: "/Users/someone/Applications")
        #expect(
            AppMove.destination(for: bundle, system: system, home: home) { _ in true }.path
                == system.appendingPathComponent("Light Touch.app").path)
        #expect(
            AppMove.destination(for: bundle, system: system, home: home) { _ in false }.path
                == "/Users/someone/Applications/Light Touch.app")
        // another admin's copy in /Applications this user can't replace: the home folder's
        let existing = system.appendingPathComponent("Light Touch.app")
        try? FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: system) }
        #expect(
            AppMove.destination(for: bundle, system: system, home: home) { $0.path != existing.path }.path
                == "/Users/someone/Applications/Light Touch.app")
    }

    @Test func theCopyReplacesTheOldOneAndCarriesNoQuarantine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-move-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Downloads/Light Touch.app")
        let binary = bundle.appendingPathComponent("Contents/MacOS/LightTouch")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: binary)
        for url in [bundle, binary] { quarantine(url) }
        let destination = root.appendingPathComponent("Applications/Light Touch.app")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("old"))

        try AppMove.copy(bundle, to: destination)

        let copied = destination.appendingPathComponent("Contents/MacOS/LightTouch")
        #expect(try Data(contentsOf: copied) == Data("new".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("old").path))
        #expect(!isQuarantined(destination) && !isQuarantined(copied))
        #expect(isQuarantined(binary), "the original keeps its own")
    }

    private func quarantine(_ url: URL) {
        let value = "0081;00000000;Safari;"
        _ = url.withUnsafeFileSystemRepresentation {
            setxattr($0, "com.apple.quarantine", value, value.utf8.count, 0, XATTR_NOFOLLOW)
        }
    }

    private func isQuarantined(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { getxattr($0, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) } > 0
    }
}
