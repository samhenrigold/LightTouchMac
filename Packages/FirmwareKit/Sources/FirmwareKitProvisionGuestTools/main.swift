import FirmwareKit
import Foundation

// Prepare a stopped NAND clone. Stock installd owns app installation and containers.
let a = CommandLine.arguments
guard a.count == 5 else { fatalError("firmwarekit-provision-guest-tools SNAPSHOT-NAND HELPERS OUT EPOCH") }
let url = { URL(fileURLWithPath: $0).standardizedFileURL }
let source = url(a[1])
let helpers = url(a[2])
let out = url(a[3])
do {
    let volumes = try VolumeRebuild.rebuild(base: source, overlay: nil, into: out)
    // A live VM snapshot can contain committed HFS journal transactions. Replay
    // them only on the exported staging images before making file-level edits.
    for volume in volumes {
        let attach = Process()
        let pipe = Pipe()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = [
            "attach", "-nomount", "-noverify", "-imagekey", "diskimage-class=CRawDiskImage", "-plist", volume.image.path
        ]
        attach.standardOutput = pipe
        try attach.run()
        let result = pipe.fileHandleForReading.readDataToEndOfFile()
        attach.waitUntilExit()
        guard attach.terminationStatus == 0,
            let plist = try PropertyListSerialization.propertyList(from: result, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]],
            let dev = entities.compactMap({ $0["dev-entry"] as? String }).first
        else {
            throw NSError(
                domain: "Sideload", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not attach staging image for journal recovery"])
        }
        let fsck = Process()
        fsck.executableURL = URL(fileURLWithPath: "/sbin/fsck_hfs")
        fsck.arguments = ["-fy", dev]
        try fsck.run()
        fsck.waitUntilExit()
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", dev]
        try detach.run()
        detach.waitUntilExit()
        guard fsck.terminationStatus == 0, detach.terminationStatus == 0 else {
            throw NSError(
                domain: "Sideload", code: 3, userInfo: [NSLocalizedDescriptionKey: "Staging filesystem recovery failed"]
            )
        }
        // fsck can repair the catalog but retain a legacy journal header. The
        // repaired staging volume gets a fresh guest-sized journal on boot.
        let repaired = try HFSPlusVolume(volume.image, writable: true)
        if try repaired.journal() != nil { try repaired.leaveJournalToDevice() }
    }
    let system = volumes.first { $0.name == "system" }!.image
    try SideloadTools.install(system: system, helpers: helpers)
    if try VolumeRebuild.board(of: source) == .ipad {
        try await K48NAND.rebuild(
            store: source, overlay: nil, system: system,
            data: volumes.first { $0.name == "data" }?.image,
            out: out.appendingPathComponent("nand"), work: out,
            log: {
                print($0)
                fflush(stdout)
            })
    } else {
        _ = try N72NAND.write(
            volume: system, blocks: HFSPlusVolume(system).totalBlocks,
            epoch: Int(a[4])!, out: out.appendingPathComponent("nand"))
    }
    print("Guest installation service prepared")
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
