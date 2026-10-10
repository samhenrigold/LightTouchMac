// The firmwarekit commands, one type each: the CLI (FirmwareKitCLI) parses its command line into them, and the app
// and the harness spawn firmwarekit with their `arguments`. FirmwareCommandTests holds the two sides to each other.
import ArgumentParser
import Foundation

/// A firmwarekit command line: the subcommand's name, then its options.
public protocol FirmwareCommandLine: ParsableCommand, Sendable {
    var arguments: [String] { get }
}

/// How a command finds and records a device's volumes: `managed` is the app's device directory (its record and
/// lease), `standalone` a directory of its own.
public enum RecordPolicy: String, CaseIterable, ExpressibleByArgument, Sendable {
    case standalone, managed
}

/// `--name value` for each value that is there.
private func options(_ pairs: KeyValuePairs<String, String?>) -> [String] {
    pairs.flatMap { name, value in value.map { ["--\(name)", $0] } ?? [] }
}

public enum FirmwareCommand {
    /// `create`: an IPSW to a device, JSON Lines on stdout (PrepareEvent).
    public struct Create: FirmwareCommandLine {
        public static let configuration = CommandConfiguration(commandName: "create")
        public enum Stop: String, ExpressibleByArgument, Sendable {
            /// fit.json: the fit checks' survey, no device.
            case volumes
        }
        @Option(help: "The catalog entry, as JSON.") public var entry: String? = nil
        @Option(help: "A catalog, with --id.") public var catalog: String? = nil
        @Option(help: "The entry's id in --catalog.") public var id: String? = nil
        @Option public var ipsw: String
        @Option(help: "The staging directory.") public var out: String
        @Option public var seed: String? = nil
        @Option(help: "LightTouchDevice, for the one-shot boots (default: the one beside firmwarekit).")
        public var helper: String? = nil
        @Option(help: "The decrypt cache.") public var cache: String? = nil
        @Option(help: "Default: the app bundle's packed guest tools.") public var guestTools: String? = nil
        @Option(help: "recipe.keybag_ramdisk_from's entry.") public var siblingEntry: String? = nil
        @Option public var siblingIpsw: String? = nil
        @Option public var stopAfter: Stop? = nil
        @Flag(help: "Adds the GL fixture job to a test device.") public var glTest = false
        @Flag(help: "Seeds Setup Assistant's finished state (iOS 5 and later): the device starts at the Home screen.")
        public var skipSetup = false
        @Flag(help: "Prepares the device jailbroken: afc2 (the whole file system over USB), Cydia and Substrate.")
        public var jailbreak = false

        public init() {}
        public init(
            entry: URL,
            ipsw: URL,
            out: URL,
            seed: String? = nil,
            helper: URL? = nil,
            cache: URL? = nil,
            guestTools: URL? = nil,
            sibling: (entry: URL, ipsw: URL)? = nil,
            skipSetup: Bool = false,
            jailbreak: Bool = false
        ) {
            self.entry = entry.path
            self.ipsw = ipsw.path
            self.out = out.path
            self.seed = seed
            self.helper = helper?.path
            self.cache = cache?.path
            self.guestTools = guestTools?.path
            siblingEntry = sibling?.entry.path
            siblingIpsw = sibling?.ipsw.path
            catalog = nil
            id = nil
            stopAfter = nil
            glTest = false
            self.skipSetup = skipSetup
            self.jailbreak = jailbreak
        }

        public func validate() throws {
            guard (entry != nil) != (catalog != nil && id != nil), (catalog == nil) == (id == nil) else {
                throw ValidationError("use --entry, or --catalog with --id")
            }
        }

        public var arguments: [String] {
            ["create"]
                + options([
                    "entry": entry, "catalog": catalog, "id": id, "ipsw": ipsw, "out": out, "seed": seed,
                    "helper": helper, "cache": cache, "guest-tools": guestTools, "sibling-entry": siblingEntry,
                    "sibling-ipsw": siblingIpsw, "stop-after": stopAfter?.rawValue,
                ]) + (glTest ? ["--gl-test"] : []) + (skipSetup ? ["--skip-setup"] : [])
                + (jailbreak ? ["--jailbreak"] : [])
        }
    }

    /// `unpack-base`: the built-in device's blob as a device of its own (JSON Lines, as create).
    public struct UnpackBase: FirmwareCommandLine {
        public static let configuration = CommandConfiguration(commandName: "unpack-base")
        @Option public var blob: String
        @Option public var out: String
        @Option public var seed: String

        public init() {}
        public init(blob: URL, out: URL, seed: String) {
            self.blob = blob.path
            self.out = out.path
            self.seed = seed
        }

        public var arguments: [String] { ["unpack-base"] + options(["blob": blob, "out": out, "seed": seed]) }
    }

    /// `pack-base`: a create output as one blob (the release build).
    public struct PackBase: FirmwareCommandLine {
        public static let configuration = CommandConfiguration(commandName: "pack-base")
        @Option(help: "A create output.") public var base: String
        @Option public var out: String

        public init() {}
        public init(base: URL, out: URL) {
            self.base = base.path
            self.out = out.path
        }

        public var arguments: [String] { ["pack-base"] + options(["base": base, "out": out]) }
    }

    /// `boot-admit`: a stopped device's storage checked and migrated before its helper starts.
    public struct BootAdmit: FirmwareCommandLine {
        public static let configuration = CommandConfiguration(commandName: "boot-admit")
        @Option public var device: String
        @Option public var recordPolicy: RecordPolicy = .standalone
        @Flag public var allowRaw = false

        public init() {}
        public init(device: URL, recordPolicy: RecordPolicy, allowRaw: Bool = false) {
            self.device = device.path
            self.recordPolicy = recordPolicy
            self.allowRaw = allowRaw
        }

        public var arguments: [String] {
            ["boot-admit"] + options(["device": device, "record-policy": recordPolicy.rawValue])
                + (allowRaw ? ["--allow-raw"] : [])
        }
    }

    /// `edit`: a stopped device's volumes opened for writing, then committed or discarded.
    public struct Edit: FirmwareCommandLine {
        public static let configuration = CommandConfiguration(commandName: "edit")
        public enum Action: String, ExpressibleByArgument, Sendable {
            case begin, mount, commit, discard, recover
            /// 1.x: --cert as a system anchor (begin, mount, the anchor row, commit).
            case trustAnchor = "trust-anchor"
        }
        @Option public var device: String
        @Option public var action: Action
        @Option public var session: String? = nil
        @Option public var recordPolicy: RecordPolicy = .standalone
        @Option(help: "A DER certificate, for trust-anchor.") public var cert: String? = nil
        @Option public var mountPoint: String? = nil

        public init() {}
        public init(
            device: URL,
            action: Action,
            session: UUID? = nil,
            recordPolicy: RecordPolicy,
            cert: URL? = nil,
            mountPoint: URL? = nil
        ) {
            self.device = device.path
            self.action = action
            self.session = session?.uuidString
            self.recordPolicy = recordPolicy
            self.cert = cert?.path
            self.mountPoint = mountPoint?.path
        }

        public var arguments: [String] {
            ["edit"]
                + options([
                    "device": device, "action": action.rawValue, "session": session,
                    "record-policy": recordPolicy.rawValue, "cert": cert, "mount-point": mountPoint,
                ])
        }
    }

    /// Which of a device's volumes `mount` and `export` rebuild.
    public enum Volume: String, ExpressibleByArgument, Sendable {
        case system, data, all
    }

    /// `mount`: a stopped device's volumes rebuilt from base and overlay into sparse images in --out and attached
    /// read-only; with --root, as the device's one tree there (system at DIR, data on DIR/private/var).
    public struct Mount: FirmwareCommandLine {
        public static let configuration = CommandConfiguration(commandName: "mount")
        @Option public var device: String
        @Option public var volume: Volume = .all
        @Option(help: "Default: a new temporary directory.") public var out: String? = nil
        @Option public var root: String? = nil
        @Option public var recordPolicy: RecordPolicy = .standalone

        public init() {}
        public init(device: URL, recordPolicy: RecordPolicy, out: URL, root: URL) {
            self.device = device.path
            volume = .all
            self.recordPolicy = recordPolicy
            self.out = out.path
            self.root = root.path
        }

        public var arguments: [String] {
            ["mount"]
                + options([
                    "device": device, "volume": volume.rawValue, "out": out, "root": root,
                    "record-policy": recordPolicy.rawValue,
                ])
        }
    }

    /// `export`: as mount, without attaching.
    public struct Export: FirmwareCommandLine {
        public static let configuration = CommandConfiguration(commandName: "export")
        @Option public var device: String
        @Option public var volume: Volume = .all
        @Option(help: "Default: a new temporary directory.") public var out: String? = nil
        @Option public var recordPolicy: RecordPolicy = .standalone

        public init() {}

        public var arguments: [String] {
            ["export"]
                + options([
                    "device": device, "volume": volume.rawValue, "out": out, "record-policy": recordPolicy.rawValue,
                ])
        }
    }

    /// `unmount`: what mount attached in --out detached (data first), and --out deleted.
    public struct Unmount: FirmwareCommandLine {
        public static let configuration = CommandConfiguration(commandName: "unmount")
        @Option public var out: String

        public init() {}
        public init(out: URL) { self.out = out.path }

        public var arguments: [String] { ["unmount"] + options(["out": out]) }
    }

    /// `cache-prune`: the decrypt cache under --root, or one IPSW's part of it.
    public struct CachePrune: FirmwareCommandLine {
        public static let configuration = CommandConfiguration(commandName: "cache-prune")
        @Option public var root: String
        @Option(help: "An IPSW's SHA-1.") public var ipsw: String? = nil

        public init() {}
        public init(root: URL) {
            self.root = root.path
            ipsw = nil
        }

        public var arguments: [String] { ["cache-prune"] + options(["root": root, "ipsw": ipsw]) }
    }

    /// `detach-images`: force-detach the disk images whose files are under --root (the app's launch sweep).
    public struct DetachImages: FirmwareCommandLine {
        public static let configuration = CommandConfiguration(commandName: "detach-images")
        @Option public var root: String

        public init() {}
        public init(root: URL) { self.root = root.path }

        public var arguments: [String] { ["detach-images"] + options(["root": root]) }
    }

    /// `verify-keys`: every keyed component of the entry decrypted from the IPSW and its plaintext judged.
    public struct VerifyKeys: FirmwareCommandLine {
        public static let configuration = CommandConfiguration(commandName: "verify-keys")
        @Option public var entry: String
        @Option public var ipsw: String

        public init() {}

        public var arguments: [String] { ["verify-keys"] + options(["entry": entry, "ipsw": ipsw]) }
    }

    /// `fit`: each guest Mach-O checked against the firmware whose system volume is mounted at --root.
    public struct Fit: FirmwareCommandLine {
        public static let configuration = CommandConfiguration(commandName: "fit")
        @Option(help: "A mounted system volume.") public var root: String
        @Option public var arch = "armv7"
        @Option public var host: String? = nil
        @Argument public var files: [String] = []

        public init() {}

        public var arguments: [String] { ["fit"] + options(["root": root, "arch": arch, "host": host]) + files }
    }

    /// `unwrap`: a "rar" source's downloaded archive to its checked IPSW.
    public struct Unwrap: FirmwareCommandLine {
        public static let configuration = CommandConfiguration(commandName: "unwrap")
        @Option public var entry: String
        @Option public var archive: String
        @Option public var out: String

        public init() {}
        public init(entry: URL, archive: URL, out: URL) {
            self.entry = entry.path
            self.archive = archive.path
            self.out = out.path
        }

        public var arguments: [String] { ["unwrap"] + options(["entry": entry, "archive": archive, "out": out]) }
    }

    /// `fetch`: the entry's IPSW from its source, then each mirror, checked as the catalog says.
    public struct Fetch: FirmwareCommandLine {
        public static let configuration = CommandConfiguration(commandName: "fetch")
        @Option public var entry: String
        @Option public var out: String

        public init() {}

        public var arguments: [String] { ["fetch"] + options(["entry": entry, "out": out]) }
    }

    /// `developer-offer`: the developer payload offered to one device instance.
    public struct DeveloperOffer: FirmwareCommandLine {
        public static let configuration = CommandConfiguration(commandName: "developer-offer")
        @Option public var offer: String
        @Option public var payload: String
        @Option(help: "A private directory.") public var state: String
        @Option public var instance: String
        @Option public var publicKey: String? = nil
        @Option public var serial: Int

        public init() {}

        public var arguments: [String] {
            ["developer-offer"]
                + options([
                    "offer": offer, "payload": payload, "state": state, "instance": instance, "public-key": publicKey,
                    "serial": String(serial),
                ])
        }
    }

    /// `developer-audit`: the developer payload's binaries, sources and notices.
    public struct DeveloperAudit: FirmwareCommandLine {
        public static let configuration = CommandConfiguration(commandName: "developer-audit")
        @Option public var payload: String

        public init() {}

        public var arguments: [String] { ["developer-audit"] + options(["payload": payload]) }
    }

    /// Every command, in the order `firmwarekit --help` lists them.
    public static let all: [any FirmwareCommandLine.Type] = [
        Create.self, UnpackBase.self, PackBase.self, BootAdmit.self, Edit.self, Mount.self, Export.self,
        Unmount.self, CachePrune.self, DetachImages.self, VerifyKeys.self, Fit.self, Unwrap.self, Fetch.self,
        DeveloperOffer.self, DeveloperAudit.self,
    ]
}
