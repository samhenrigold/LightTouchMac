import Foundation
import Testing
import ZIPFoundation

@testable import FirmwareKit

/// The 1.x jailbreak (SystemEdits.installJailbreak1x): afc2, SpringBoard 1.1-1.1.2's allowlist check off
/// (SpringBoardAllowlist), and the pinned Installer.app with 1.0's DisplayOrder.plist naming it.
struct Jailbreak1xTests {
    let fm = FileManager.default

    /// An ARM Mach-O shaped as SpringBoard 1.1's _addItemsToIconList: compiles it, with `selector` for the list's
    /// selector, a __text section at 0x200 and __OBJC,__message_refs at 0x300 naming the two selectors.
    static func springBoard(selector: String = "allowedDisplayIdentifiers") -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 0x500)
        func put(_ o: Int, _ v: UInt32) { for k in 0..<4 { b[o + k] = UInt8(truncatingIfNeeded: v >> (8 * k)) } }
        func name(_ o: Int, _ s: String) { b.replaceSubrange(o..<o + s.utf8.count, with: Array(s.utf8)) }
        let base: UInt32 = 0x1000
        put(0, 0xFEED_FACE)
        put(4, 12)  // ARM
        put(8, 6)
        put(12, 2)  // MH_EXECUTE
        put(16, 2)
        put(20, 2 * (56 + 68))
        for (k, (segment, section, offset, size)) in [
            ("__TEXT", "__text", 0x200, 0x38), ("__OBJC", "__message_refs", 0x300, 8)
        ]
        .enumerated() {
            let c = 28 + k * (56 + 68)
            put(c, 1)
            put(c + 4, 56 + 68)
            name(c + 8, segment)
            put(c + 24, base + UInt32(k == 0 ? 0 : offset))  // vmaddr
            put(c + 28, UInt32(k == 0 ? 0x300 : 0x200))  // vmsize
            put(c + 32, UInt32(k == 0 ? 0 : offset))  // fileoff
            put(c + 36, UInt32(k == 0 ? 0x300 : 0x200))  // filesize
            put(c + 48, 1)
            name(c + 56, section)
            name(c + 72, segment)
            put(c + 88, base + UInt32(offset))
            put(c + 92, UInt32(size))
            put(c + 96, UInt32(offset))
        }
        let code: [UInt32] = [
            0xE59F_1028,  // ldr r1, =@selector(allowedDisplayIdentifiers)
            0xE591_1000, 0xEB00_0000,
            0xE58D_0014,  // str r0, [sp, #0x14]
            0xE59F_101C,  // ldr r1, =@selector(containsObject:)
            0xE59D_0014,  // ldr r0, [sp, #0x14]
            0xE1A0_2004, 0xE591_1000, 0xEB00_0000,
            0xE310_00FF,  // tst r0, #255
            0x0A00_0000,  // beq: skips the app
            0xE8BD_80F0,
            base + 0x300, base + 0x304  // the literals: the selector references
        ]
        for (k, i) in code.enumerated() { put(0x200 + 4 * k, i) }
        put(0x300, base + 0x400)
        put(0x304, base + 0x420)
        name(0x400, selector)
        name(0x420, "containsObject:")
        return b
    }

    @Test func theAllowlistCheckBecomesANop() throws {
        let (patched, offset) = try #require(try SpringBoardAllowlist.patch(Self.springBoard()))
        #expect(offset == 0x228)
        #expect(Array(patched[0x228..<0x22C]) == [0x00, 0x00, 0xA0, 0xE1])
        var rest = patched
        rest.replaceSubrange(0x228..<0x22C, with: [0x00, 0x00, 0x00, 0x0A])
        #expect(rest == Self.springBoard(), "nothing else changes")
        #expect(throws: FirmwareError.self, "patched already: no check left") {
            try SpringBoardAllowlist.patch(patched)
        }
    }

    @Test func aSpringBoardWithNoAllowlistIsLeftAlone() throws {
        // 1.1.3 on: disallowedDisplayIdentifiers, whose name ends in the allowlist's
        #expect(try SpringBoardAllowlist.patch(Self.springBoard(selector: "disallowedDisplayIdentifiers")) == nil)
    }

    /// A 1.x root: lockdown's stock AFC, afcd, SpringBoard, and (1.0) a DisplayOrder.plist.
    func firmware(_ dir: URL, springBoard: [UInt8], displayOrder: Bool) throws -> URL {
        try JailbreakTests.put(
            PropertyListSerialization.data(
                fromPropertyList: ["com.apple.afc": JailbreakTests.stockAFC[0]],
                format: .xml,
                options: 0
            ),
            dir,
            SystemEdits.lockdownServices
        )
        try JailbreakTests.put(Data("usage: afcd -L | --lockdown".utf8), dir, SystemEdits.afcd)
        try JailbreakTests.put(Data(springBoard), dir, N72Board.springBoard)
        if displayOrder {
            let order = ["iconList": [["displayIdentifier": "com.apple.Preferences"]], "buttonBar": []]
            try JailbreakTests.put(
                PropertyListSerialization.data(fromPropertyList: order, format: .binary, options: 0),
                dir,
                SystemEdits.displayOrder
            )
        }
        return dir
    }

    /// The guest archive's jailbreak folder as scripts/vendor packs it: the repository's build-support/jailbreak.
    func guestTools(_ dir: URL) throws -> URL {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try fm.createDirectory(at: dir.appendingPathComponent("guest-tools"), withIntermediateDirectories: true)
        try fm.copyItem(
            at: repository.appendingPathComponent("build-support/jailbreak"),
            to: dir.appendingPathComponent("jailbreak")
        )
        return dir.appendingPathComponent("guest-tools")
    }

    @Test(arguments: [true, false])
    func aRootGetsAFC2TheSpringBoardPatchAndInstaller(displayOrder: Bool) throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-jb1x-\(UUID().uuidString)")
        defer { TemporaryTrees.remove(dir) }
        let root = try firmware(
            dir.appendingPathComponent("root"), springBoard: Self.springBoard(), displayOrder: displayOrder)
        let installer = try SystemEdits.InstallerApp.bundled(
            guestTools: try guestTools(dir.appendingPathComponent("guest")))
        let jb = try SystemEdits.installJailbreak1x(MountedVolume(root: root), installer: installer)
        let services = try #require(
            NSDictionary(contentsOf: root.appendingPathComponent(SystemEdits.lockdownServices)) as? [String: Any]
        )
        #expect(
            (services["com.apple.afc2"] as? [String: Any])?["ProgramArguments"] as? [String]
                == ["/usr/libexec/afcd", "--lockdown", "-d", "/"]
        )
        let sb = try Data(contentsOf: root.appendingPathComponent(N72Board.springBoard))
        #expect(Array(sb[0x228..<0x22C]) == [0x00, 0x00, 0xA0, 0xE1])
        let app = root.appendingPathComponent(SystemEdits.InstallerApp.path)
        let info = try #require(NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")))
        #expect(info["CFBundleIdentifier"] as? String == SystemEdits.InstallerApp.identifier)
        for (name, mode) in [
            ("Installer", 0o755), ("ditto", 0o755), ("InstallerPlugin.webplugin/InstallerPlugin", 0o755),
            ("icon.png", 0o644)
        ] {
            let attributes = try fm.attributesOfItem(atPath: app.appendingPathComponent(name).path)
            #expect((attributes[.posixPermissions] as? Int).map { $0 & 0o777 } == mode, "\(name)")
        }
        #expect(
            jb.root.contains(N72Board.springBoard) && jb.root.contains(SystemEdits.InstallerApp.path + "/Installer"))
        let order = NSDictionary(contentsOf: root.appendingPathComponent(SystemEdits.displayOrder))
        let icons = (order?["iconList"] as? [[String: String]])?.compactMap { $0["displayIdentifier"] }
        #expect(icons == (displayOrder ? ["com.apple.Preferences", SystemEdits.InstallerApp.identifier] : nil))
        #expect(
            try !SystemEdits.registerDisplayIdentifier(MountedVolume(root: root), SystemEdits.InstallerApp.identifier),
            "once")
        #expect(jb.lines.count == (displayOrder ? 4 : 3))
    }

    @Test func theInstallerIsThePinnedOne() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-jb1x-pin-\(UUID().uuidString)")
        defer { TemporaryTrees.remove(dir) }
        let tools = try guestTools(dir)
        try Data("other".utf8).write(to: dir.appendingPathComponent("jailbreak/" + SystemEdits.InstallerApp.zip.name))
        #expect(throws: FirmwareError.self) { try SystemEdits.InstallerApp.bundled(guestTools: tools) }
        try fm.removeItem(at: dir.appendingPathComponent("jailbreak"))
        #expect(throws: FirmwareError.self, "none") { try SystemEdits.InstallerApp.bundled(guestTools: tools) }
    }

    @Test func aZipMemberOutsideTheBundleIsRefused() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-jb1x-bad-\(UUID().uuidString)")
        defer { TemporaryTrees.remove(dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let plist = dir.appendingPathComponent("Info.plist")
        try Data("<plist/>".utf8).write(to: plist)
        let zip = dir.appendingPathComponent("escape.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        try archive.addEntry(with: "Installer.app/Info.plist", fileURL: plist)
        try archive.addEntry(with: "Installer.app/../../etc/fstab", fileURL: plist)
        #expect(throws: FirmwareError.self) { try SystemEdits.InstallerApp.load(zip) }
    }
}
