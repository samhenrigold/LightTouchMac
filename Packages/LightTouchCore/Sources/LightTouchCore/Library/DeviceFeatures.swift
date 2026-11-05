// What a catalog entry's device does once added, before it has ever booted: each from the rule the app goes by
// when it runs (Add Device's Supported list). Wi-Fi, rotation and the debug port have no gate: every boot gets
// wifi0 (EmulatorController+Boot), every device turns, every running device takes a debugger.

import FirmwareSchema
import Foundation
import HostRuntime

public struct DeviceFeatures: Sendable, Equatable {
    public var wifi = true
    /// A modem: calls, messages and cellular data (Board.hasCellular, the emulator's machine table).
    public var cellular: Bool
    /// Sound out of the Mac: every boot gets Core Audio, and every board plays through it.
    public var audio = true
    /// Location from a GPS receiver (Board.hasGPS).
    public var location: Bool
    /// A magnetometer the emulator models (Board.hasCompass, the emulator's machine table).
    public var compass: Bool
    public var vibration: Bool
    public var rotation = true
    /// Installing apps (Entry.managesApps: iPhone OS 1 has no installation service).
    public var appInstalls: Bool
    /// A screen of any size (Board.supportsFreeForm).
    public var freeFormScreen: Bool
    /// Prepared past Setup Assistant (FirmwareJobs.offersSkipSetup: iOS 5 and later; not the image the app ships).
    public var skipSetup: Bool
    /// Prepared jailbroken (FirmwareJobs.offersJailbreak: iPhone OS 2.0 and later; not the image the app ships).
    public var jailbreak: Bool
    /// Show File System edits the stopped device's store: every board (DeviceFilesystemEdits.canPerform).
    public var fileSystem: Bool
    public var debugPort = true
    /// SSH and SFTP into the device (GuestDeveloperTools: the builds they're packaged for).
    public var developerTools: Bool
    /// Light Touch's guest agent: baked into the image (Board.hasGuestTools) or in a guest package for the build.
    public var guestTools: Bool

    /// `guestPackage`: the bundled itpack has a package for the entry's board and build (GuestPackage.packaged).
    public init(_ entry: FirmwareCatalog.Entry, guestPackage: Bool) {
        let board = entry.profile
        cellular = board?.hasCellular ?? false
        location = board?.hasGPS ?? false
        compass = board?.hasCompass ?? false
        vibration = board?.hasVibrator ?? false
        appInstalls = entry.managesApps
        freeFormScreen = board?.supportsFreeForm ?? false
        skipSetup = entry.bundled == nil && FirmwareJobs.offersSkipSetup(entry)
        jailbreak = entry.bundled == nil && FirmwareJobs.offersJailbreak(entry)
        fileSystem = board != nil
        developerTools = GuestDeveloperTools.supports(build: entry.build)
        guestTools = (board?.hasGuestTools ?? false) || guestPackage
    }
}

extension GuestPackage {
    /// Whether a device of `firmware` runs the guest agent: baked into its image (Board.hasGuestTools, only the iPod
    /// touch 2G) or from a guest package at boot (the iPhones and iPads), as DeviceFeatures.guestTools says.
    @MainActor public static func runsAgent(
        firmware: String,
        catalog: FirmwareCatalog = .bundled,
        pack: (String) -> URL? = { bundledPack(arch: $0, filesRoot: Bundled.filesRoot, guestRoot: Bundled.guestRoot) }
    ) -> Bool {
        guard let entry = catalog.entry(id: firmware) else { return false }
        return (entry.profile?.hasGuestTools ?? false) || packaged([entry], pack: pack).contains(entry.id)
    }

    /// The entries whose board and build the bundled itpacks (`pack` by arch) hold a package with the guest agent
    /// for (not a stub, nor only a GL hook or it_prefs, as iPhone OS 1's and the iPod touch 2G's 4.x are); each
    /// itpack read once.
    public static func packaged(_ entries: [FirmwareCatalog.Entry], pack: (String) -> URL?) -> Set<String> {
        var read: [String: [(name: String, data: Data)]] = [:]
        var found: Set<String> = []
        for entry in entries {
            guard let arch = entry.profile?.arch else { continue }
            if read[arch] == nil { read[arch] = pack(arch).flatMap { try? GuestPack.read($0) } ?? [] }
            if let entries = read[arch],
                (try? GuestPack.packages(entries, board: entry.board, build: entry.build))?
                    .contains(where: { $0.payloads["bin/it_agent"] != nil }) == true
            {
                found.insert(entry.id)
            }
        }
        return found
    }
}
