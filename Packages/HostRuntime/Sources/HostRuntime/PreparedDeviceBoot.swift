import Darwin
import Foundation

/// Preparation and launch assembly shared by the GUI and headless session callers.
/// The caller must hold the device's storage lease before calling prepare.
/// Explicit URLs are caller-selected: this component does not authorize managed
/// record paths or enforce containment. Maintenance ownership checks stay with
/// the application's storage transaction boundary.
public struct PreparedDeviceBoot {
    public enum Failure: Error, Equatable { case baseMismatch }
    private let board: Board
    private let boot: URL
    private let nand: URL
    /// The NAND overlay the emulator writes, nil when it writes `nand` itself (an image store's live clone).
    private let nandOverlay: URL?
    private let baseNOR: URL
    private let writableNOR: URL?
    private let overlay: URL
    private let bootrom: String
    private let strategy: String?
    private let gidBlobs: String?
    private let dieID: String?
    private let machine: [String: String]
    /// The unit's Wi-Fi MAC (identity.json), which the iPhone 5 boot gives its Wi-Fi device.
    private var wifiMAC: String? = nil

    public static func prepare(
        board: Board,
        base: URL,
        overlay: URL,
        writableNOR: URL?,
        storageKey: String?,
        bootrom: String,
        dieID: String? = nil,
        panel: String? = nil,
        clock: Date? = nil
    ) throws -> Self {
        let lock = try DeviceLock.read(base: base)
        let strategy = lock?.bootStrategy
        let required = try board.requiredFiles(strategy: strategy)
        let files = try BootRecipe.preparedFiles(
            base: base,
            overlay: overlay,
            writableNOR: writableNOR,
            boot: required.boot,
            also: required.files
        )
        if !board.isKBoot, files.writableNOR == nil {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "writable NOR"])
        }
        if board.isKBoot {
            _ = try BootRecipe.preparedIPadBoot(
                strategy: strategy,
                image: files.boot.path,
                writableNOR: files.writableNOR?.path,
                gidBlobs: base.appendingPathComponent("gid-blobs.bin").path
            )
        }
        if let storageKey, try !pinOverlay(overlay, toBase: storageKey) { throw Failure.baseMismatch }
        var boot = files.boot
        if board.soc == .s5l8920, required.boot == "kboot.bin" {
            boot = try audioClockBoot(kboot: files.boot, overlay: overlay)
        }
        var nand = files.nand
        var nandOverlay: URL? = overlay
        if isImageStore(files.nand) {
            nand = try liveNAND(base: files.nand, overlay: overlay)
            nandOverlay = nil
        }
        let identityURL = base.appendingPathComponent("identity.json")
        let identity = (try? Data(contentsOf: identityURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let unitDieID = dieID ?? (identity?["die-id"] as? [String])?.joined(separator: ":")
        return Self(
            board: board,
            boot: boot,
            nand: nand,
            nandOverlay: nandOverlay,
            baseNOR: base.appendingPathComponent("nor.bin"),
            writableNOR: files.writableNOR,
            overlay: overlay,
            bootrom: bootrom,
            strategy: strategy,
            gidBlobs: board.soc == .s5l8900 ? nil : base.appendingPathComponent("gid-blobs.bin").path,
            dieID: unitDieID,
            machine: (lock?.machineOptions(base: base) ?? [:]).merging(
                (panel.map { ["panel": $0] } ?? [:])
                    // Tweaks' Time Machine: the PMU's clock (and the agent's time sync) start at that moment.
                    .merging(clock.map { ["rtc-epoch": String(Int64($0.timeIntervalSince1970))] } ?? [:]) { $1 }
            ) { $1 },
            wifiMAC: identity?["wifi-mac"] as? String
        )
    }

    /// /arm-io/audio-complex ncoref-frequency (S5L8920/8922 only): iBoot fills it with PLL1's frequency, which LLB sets
    /// to 24 MHz x 81 / 6 / 2 = 162 MHz (7E18 n88ap and 8C148 n18ap LLB). The kernel's audio complex divides by its
    /// NCO's registers with it to find each I2S port's MCLK; left 0, every port reads 0 Hz (FirmwareKit KBoot).
    public static let ncorefHz: UInt32 = 162_000_000

    /// The kboot.bin a 3GS or iPod touch 3G boots. One prepared before KBoot filled ncoref-frequency (2026-10-09)
    /// has the IPSW's 0, so iPhone OS 3's mediaserverd finds no audio device and every sound fails: the first boot
    /// writes a copy with the value set into the overlay, read back before it's used, and later boots use that copy.
    /// The base stays as it was; Erase empties the overlay and the next boot writes the copy again.
    static func audioClockBoot(kboot: URL, overlay: URL) throws -> URL {
        let repaired = overlay.appendingPathComponent("kboot.bin")
        if FileManager.default.fileExists(atPath: repaired.path) { return repaired }
        var image = try Data(contentsOf: kboot)
        guard let at = ncorefOffset(image), image[at..<at + 4].allSatisfy({ $0 == 0 }) else { return kboot }
        withUnsafeBytes(of: ncorefHz.littleEndian) { image.replaceSubrange(at..<at + 4, with: $0) }
        let staged = overlay.appendingPathComponent(".kboot-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staged) }
        try image.write(to: staged)
        guard let written = try? Data(contentsOf: staged), written == image else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: staged.path])
        }
        try FileManager.default.moveItem(at: staged, to: repaired)
        FileHandle.standardError.write(
            Data("boot: kboot.bin's ncoref-frequency was 0; booting \(repaired.path)\n".utf8)
        )
        return repaired
    }

    /// Where the device tree property's 4-byte value is (a 32-byte name, a length of 4, the value), when it occurs
    /// exactly once.
    static func ncorefOffset(_ image: Data) -> Int? {
        let key = Data("ncoref-frequency".utf8) + Data(count: 16) + Data([4, 0, 0, 0])
        guard let first = image.range(of: key), image.range(of: key, in: first.upperBound..<image.endIndex) == nil,
            first.upperBound + 4 <= image.endIndex
        else { return nil }
        return first.upperBound
    }

    /// The country the emulated access point announces (qemu-ios wifi-country, its 802.11d element): the Mac's
    /// region, where the Mac and the network it shares are. Setup Assistant on 5.x and 6.x guesses the country from
    /// the access points a Wi-Fi scan finds when the SIM gives none, and offers that country's languages over its
    /// Welcome animation; with no country it lists every language and no Welcome. Nil (the emulator's US) for a
    /// region that is not a country ("001").
    static func wifiCountry(_ locale: Locale = .current) -> String? {
        guard let region = locale.region?.identifier, region.count == 2, region.allSatisfy(\.isLetter) else {
            return nil
        }
        return region
    }

    /// Explicit adapter for pre-library N72 regression fixtures with separate images.
    /// Prepared device records always use prepare; no firmware policy is inferred here.
    public static func legacyN72(
        nand: URL,
        nor: URL,
        iBoot: String,
        gidBlobs: String?,
        machine: [String: String],
        overlay: URL,
        bootrom: String
    ) throws -> Self {
        let destination = try writableNOR(base: nor, overlay: overlay)
        return Self(
            board: .n72,
            boot: URL(fileURLWithPath: iBoot.isEmpty ? "nor.bin" : iBoot),
            nand: nand,
            nandOverlay: overlay,
            baseNOR: nor,
            writableNOR: destination,
            overlay: overlay,
            bootrom: bootrom,
            strategy: iBoot.isEmpty ? "bootrom" : "iboot",
            gidBlobs: gidBlobs,
            dieID: nil,
            machine: machine
        )
    }

    /// Legacy raw-image fixtures use an exact 1 MiB private NOR copy.
    public static func writableNOR(base: URL, overlay: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
        let destination = overlay.appendingPathComponent("nor.bin")
        if !fm.fileExists(atPath: destination.path) {
            let staged = overlay.appendingPathComponent(".nor-\(UUID().uuidString).tmp")
            defer { try? fm.removeItem(at: staged) }
            try fm.copyItem(at: base, to: staged)
            let size = try fm.attributesOfItem(atPath: staged.path)[.size] as? NSNumber
            guard size?.intValue == 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
            let handle = try FileHandle(forWritingTo: staged)
            defer { try? handle.close() }
            try handle.synchronize()
            try fm.moveItem(at: staged, to: destination)
        }
        let attributes = try fm.attributesOfItem(atPath: destination.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.size] as? NSNumber)?.intValue == 1_048_576
        else { throw CocoaError(.fileReadCorruptFile) }
        return destination
    }

    public static func pinOverlay(_ overlay: URL, toBase identity: String) throws -> Bool {
        let fm = FileManager.default
        let stamp = overlay.appendingPathComponent(".base-identity")
        let contents = (try? fm.contentsOfDirectory(atPath: overlay.path)) ?? []
        if contents.isEmpty {
            try fm.createDirectory(at: overlay, withIntermediateDirectories: true)
            try Data(identity.utf8).write(to: stamp, options: .atomic)
            return true
        }
        return (try? String(contentsOf: stamp, encoding: .utf8)) == identity
    }

    /// An image store (record format 2: geometry.json storage_format nand-xor-ff-v2, FirmwareKit's A4 and S5L8920 stores,
    /// K48NAND.StoreFormat.image; nand-xor-blank-v2, the iPod touch 2G's and the 1.x boards', PageNANDImage) needs no
    /// page overlay: the device's NAND is an APFS clone of the base's, `overlay/nand`, which the emulator writes in
    /// place. Erase removes the overlay and the next boot clones again.
    public static func isImageStore(_ nand: URL) -> Bool {
        let geometry = (try? Data(contentsOf: nand.appendingPathComponent("geometry.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return ["nand-xor-ff-v2", "nand-xor-blank-v2"].contains(geometry?["storage_format"] as? String)
    }

    public static func liveNAND(overlay: URL) -> URL { overlay.appendingPathComponent("nand", isDirectory: true) }

    /// Written by the helper beside its lease when a session ends in a clean halt (QEMU paused, which flushes the
    /// storage, then returned); boot admission reads it and removes it before the next session.
    public static func cleanStopMarker(lease: URL) -> URL {
        lease.deletingLastPathComponent().appendingPathComponent("clean-stop")
    }

    /// While boot admission migrates the device's storage (FirmwareKit K48NANDMigration): how far it is, 0...1, as
    /// text beside the lease. The start's toast reads it; gone when the migration ends either way.
    public static func migrationProgress(lease: URL) -> URL {
        lease.deletingLastPathComponent().appendingPathComponent("migration-progress")
    }

    public static func readMigrationProgress(lease: URL) -> Double? {
        (try? String(contentsOf: migrationProgress(lease: lease), encoding: .utf8)).flatMap(Double.init)
    }

    /// The start's toast while the storage migrates.
    public static func migrationText(_ fraction: Double) -> String {
        "Updating storage (one time)… \(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }

    /// The device's live NAND, cloned from `base` (its read-only image store) on the first boot after preparation or
    /// Erase. The clone keeps the base's uchg and modes, so they are cleared before it is published by a rename.
    public static func liveNAND(base: URL, overlay: URL) throws -> URL {
        let fm = FileManager.default
        let live = liveNAND(overlay: overlay)
        // Page files an older build wrote over this base: never booted as an image, and never silently dropped.
        for name in ["bus0-ce0.pages", "bus0-ce0.dirty", "cs0", "bank0"]
        where fm.fileExists(atPath: overlay.appendingPathComponent(name).path) {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [
                    NSFilePathErrorKey: overlay.path,
                    NSLocalizedDescriptionKey:
                        "This device’s data was written in an older format over a newer system image."
                ]
            )
        }
        if fm.fileExists(atPath: live.path) { return live }
        let staged = overlay.appendingPathComponent(".nand-\(UUID().uuidString).tmp", isDirectory: true)
        defer { if fm.fileExists(atPath: staged.path) { try? removeClone(staged) } }
        try fm.createDirectory(at: staged, withIntermediateDirectories: false)
        // File by file (clonefile(2) discourages directories). ponytail: clonefile only; the state root is always
        // APFS, and a copy would allocate every chip's full size.
        for name in try fm.contentsOfDirectory(atPath: base.path) {
            let source = base.appendingPathComponent(name)
            guard clonefile(source.path, staged.appendingPathComponent(name).path, 0) == 0 else {
                throw CocoaError(
                    .fileWriteUnknown,
                    userInfo: [
                        NSFilePathErrorKey: source.path,
                        NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    ]
                )
            }
            // a clone keeps the base's uchg and read-only mode, and QEMU couldn't open it for writing
            try writable(staged.appendingPathComponent(name), mode: 0o644)
        }
        guard rename(staged.path, live.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return live
    }

    /// Once the helper has exited (a clean stop or not): QEMU's flush on macOS is fsync, which leaves writes in the
    /// drive's cache, so one F_FULLFSYNC on each live chip file and the NOR puts them on the medium before a power
    /// loss. (A killed helper's writes are in the page cache, which survives it.)
    public static func syncStorage(overlay: URL, writableNOR: URL?) {
        let live = liveNAND(overlay: overlay)
        let chips = ((try? FileManager.default.contentsOfDirectory(atPath: live.path)) ?? [])
            .filter { $0.hasSuffix(".pages") }.map { live.appendingPathComponent($0) }
        for url in chips + [writableNOR].compactMap({ $0 }) {
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { continue }
            _ = fcntl(fd, F_FULLFSYNC)
            close(fd)
        }
    }

    private static func writable(_ url: URL, mode: mode_t) throws {
        guard chflags(url.path, 0) == 0, chmod(url.path, mode) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func removeClone(_ url: URL) throws {
        try writable(url, mode: 0o755)
        try FileManager.default.removeItem(at: url)
    }

    /// The writable NOR's path; prepare requires one for every board but the iPads.
    private func writableNORPath() throws -> String {
        guard let writableNOR else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "writable NOR"]) }
        return writableNOR.path
    }

    /// The base's machine options and the access point's country, each only where the board's machine declares it
    /// (Board.machineOptions): QEMU stops at an option its machine lacks, before the guest runs.
    func machineOptions() -> [String: String] {
        let declared = board.machineOptions
        var options = machine.filter { declared.contains($0.key) }
        // the iPhone 5's modem takes its IMEI as a -global (BootRecipe.iPhone5)
        for key in machine.keys.sorted() where options[key] == nil && !(board.soc == .s5l8950 && key == "imei") {
            FileHandle.standardError.write(Data("boot: \(board.rawValue)'s machine has no \(key); left out\n".utf8))
        }
        if declared.contains("wifi-country"), options["wifi-country"] == nil, let country = Self.wifiCountry() {
            options["wifi-country"] = country
        }
        return options
    }

    /// `hardware`: the emulator's facts about the board (its hello's DeviceInfo; else Machines'): the -M machine,
    /// the modem, the USB host.
    public func configuration(
        hardware: DeviceInfo? = nil,
        bootArgs: String,
        usbAddress: String?,
        wifi: Bool,
        guestPackage: String?,
        serial: String,
        audio: [String],
        netdev: String?,
        restore: [String] = [],
        webProxy: WebProxyEndpoint? = nil,
        cellular: BootRecipe.Cellular = .on,
        carrier: CarrierSettings? = nil,
        refreshHz: Int = 60,
        angle: Bool = false
    ) throws -> BootConfig {
        guard let hardware = hardware ?? board.hardware else {
            throw CocoaError(
                .featureUnsupported,
                userInfo: [NSLocalizedDescriptionKey: "The emulator library has no machine for \(board.rawValue)."]
            )
        }
        var machine = machineOptions()
        // Settings ▸ General's experimental ANGLE renderer: the GL bridge draws through ANGLE on Metal. A snapshot
        // resumes on CGL, whose GL state it holds (ANGLE keeps none).
        if angle, restore.isEmpty, board.machineOptions.contains("gl-renderer") { machine["gl-renderer"] = "angle" }
        var config: BootConfig
        switch board.soc {
        case .s5l8900:
            config = BootRecipe.iPod1G(
                .init(
                    bootrom: bootrom,
                    iBoot: boot.path,
                    nand: nand.path,
                    writableNOR: try writableNORPath(),
                    overlay: nandOverlay?.path ?? "",
                    usbAddress: usbAddress,
                    wifi: wifi,
                    guestPackage: guestPackage,
                    machineOptions: machine
                ),
                hardware: hardware,
                serial: serial,
                audio: audio,
                netdev: netdev
            )
        case .s5l8720:
            config = BootRecipe.iPod(
                .init(
                    bootArgs: bootArgs,
                    iBoot: strategy == "bootrom" ? "" : boot.path,
                    bootrom: bootrom,
                    nand: nand.path,
                    nor: baseNOR.path,
                    writableNOR: try writableNORPath(),
                    overlay: nandOverlay?.path ?? "",
                    usbAddress: usbAddress,
                    wifi: wifi,
                    gidBlobs: gidBlobs,
                    guestPackage: guestPackage,
                    machineOptions: machine
                ),
                hardware: hardware,
                serial: serial,
                audio: audio,
                netdev: netdev,
                restore: restore
            )
        case .s5l8920, .s5l8930:
            let bootPath = try BootRecipe.preparedIPadBoot(
                strategy: strategy,
                image: boot.path,
                writableNOR: writableNOR?.path,
                gidBlobs: gidBlobs
            )
            var ipad = BootRecipe.IPad(
                boot: bootPath,
                nand: nand.path,
                overlay: nandOverlay?.path,
                dieID: dieID,
                usbAddress: usbAddress,
                wifi: wifi,
                guestPackage: guestPackage,
                machineOptions: machine
            )
            ipad.cellular = cellular
            config = BootRecipe.iPad(
                ipad,
                hardware: hardware,
                serial: serial,
                audio: audio,
                netdev: netdev,
                restore: restore
            )
        case .s5l8950:
            var phone = BootRecipe.IPad(
                boot: .kernel(image: boot.path, writableNOR: nil),
                nand: nand.path,
                overlay: nandOverlay?.path,
                dieID: nil,
                usbAddress: usbAddress,
                wifi: wifi,
                guestPackage: guestPackage,
                machineOptions: machine
            )
            phone.cellular = cellular
            phone.wifiMAC = wifiMAC
            phone.imei = self.machine["imei"]
            config = BootRecipe.iPhone5(
                phone,
                hardware: hardware,
                serial: serial,
                audio: audio,
                netdev: netdev,
                restore: restore
            )
        }
        // The device's saved Carrier panel settings: the modem starts with them (radio boards only).
        if let carrier, hardware.hasCellular { config.argv += carrier.globals }
        // The SIM keeps its PIN, PUK and tries left with the device's own state, as a card in the tray does.
        if hardware.hasCellular {
            config.argv += ["-global", "ios-baseband.sim-file=\(overlay.appendingPathComponent("sim").path)"]
        }
        config.argv += board.refreshGlobals(refreshHz)
        config.webProxy = webProxy
        config.files = files(bootrom: bootrom, guestPackage: guestPackage, serial: serial, audio: audio)
        return config
    }

    /// What this boot opens, by role (BootConfig.files). Written: the overlay (the NAND pages or the live NAND clone,
    /// the SIM, a staged kboot) and the writable NOR, the serial FIFOs, a recording. Read: the base (NAND, NOR,
    /// iBoot/kboot, gid blobs), the SecureROM's folder, the guest package offer.
    func files(bootrom: String, guestPackage: String?, serial: String, audio: [String]) -> BootFiles {
        var files = BootFiles()
        let fm = FileManager.default
        files.readWrite.append(overlay.path)
        if let writableNOR { files.readWrite.append(writableNOR.path) }
        if serial.hasPrefix("pipe:") {
            let path = String(serial.dropFirst("pipe:".count))
            files.readWrite += [path + ".in", path + ".out"]
        } else if serial.hasPrefix("file:") {
            files.readWrite.append(
                URL(fileURLWithPath: String(serial.dropFirst("file:".count))).deletingLastPathComponent().path
            )
        }
        for option in audio.flatMap({ $0.split(separator: ",") }) where option.hasPrefix("path=") {
            files.readWrite.append(
                URL(fileURLWithPath: String(option.dropFirst("path=".count))).deletingLastPathComponent().path
            )
        }
        files.readOnly += [baseNOR.deletingLastPathComponent().path, boot.deletingLastPathComponent().path]
        if nandOverlay != nil { files.readOnly.append(nand.deletingLastPathComponent().path) }
        if !bootrom.isEmpty { files.readOnly.append(URL(fileURLWithPath: bootrom).deletingLastPathComponent().path) }
        if let gidBlobs { files.readOnly.append(URL(fileURLWithPath: gidBlobs).deletingLastPathComponent().path) }
        if let guestPackage {
            var directory: ObjCBool = false
            let offer = URL(fileURLWithPath: guestPackage)
            files.readOnly.append(
                fm.fileExists(atPath: guestPackage, isDirectory: &directory) && directory.boolValue
                    ? offer.path : offer.deletingLastPathComponent().path
            )
        }
        return files
    }
}
