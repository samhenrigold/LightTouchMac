// firmwarekit: the preparer (docs/multi-device-plan.md, "Preparer contract").
//
//   firmwarekit create --entry ENTRY.json --ipsw IPSW --out STAGING_DIR
//                      [--seed SEED] [--helper PATH_TO_LightTouchDevice]
//                      [--cache DIR] [--guest-tools DIR] [--sibling-entry ENTRY.json --sibling-ipsw IPSW]
//
// stdout is JSON Lines only; diagnostics go to stderr. Exit 0 after done, 1 after an error event; SIGTERM,
// or the parent (the app) exiting, cancels (children stopped, images under STAGING_DIR detached, exit 143)
// and leaves STAGING_DIR to the caller. Closed command pipes cannot interrupt owned cleanup.
// --guest-tools defaults to ../Resources/guest-tools next to this executable (the app bundle's).
//
//   firmwarekit mount  --device DIR [--volume system|data|all] [--out DIR]   (a STOPPED device only)
//   firmwarekit export --device DIR [--volume system|data|all] [--out DIR]
//   firmwarekit unmount --out DIR
//
// mount/export rebuild the device's HFS+ volumes from base + overlay into sparse images in --out (default:
// a new temp dir) and print one JSON line per volume: {volume, image, clean, repaired, seconds, and for
// mount device + mountPoint (attached read-only, visible in Finder)}. unmount detaches them and deletes --out.
// An error prints {"error": ...} and exits 1.

import FirmwareKit
import HostRuntime
import Foundation

let commandOutput = PipeOutput(fileDescriptor: STDOUT_FILENO)
@Sendable func emit(_ event: PrepareEvent) {
    commandOutput.write(Data((event.json + "\n").utf8))
}

var args = CommandLine.arguments.dropFirst()
let command = args.popFirst()
if command == "mount" || command == "export" || command == "unmount" {
    let selected = command!, arguments = Array(args)
    let lifetime = CommandLifetime(output: commandOutput) { await volumeCommand(selected, arguments) }
    exit(await lifetime.wait())
}
if command == "developer-audit" { developerAuditCommand(Array(args)) }
if command == "developer-offer" { developerOfferCommand(Array(args)) }
if command == "cache-prune" { cacheCommand(Array(args)) }
if command == "edit" {
    let arguments = Array(args)
    let lifetime = CommandLifetime(output: commandOutput) { await stoppedEditCommand(arguments) }
    exit(await lifetime.wait())
}
if command == "verify-keys" { verifyKeysCommand(Array(args)) }
if command == "fit" { fitCommand(Array(args)) }
guard command == "create" else {
    FirmwareDiagnostics.write(Data("""
        firmwarekit \(FirmwareKit.version)
        usage: firmwarekit edit --device DIR --action begin|mount|commit|discard|recover [--session UUID]
               firmwarekit cache-prune --root DIR [--ipsw SHA1]
               firmwarekit create --entry ENTRY.json --ipsw IPSW --out DIR [--seed S]
                                  [--helper PATH] [--cache DIR] [--guest-tools DIR]
                                  [--sibling-entry ENTRY.json --sibling-ipsw IPSW]   (recipe.keybag_ramdisk_from)
                                  [--stop-after volumes]   (fit.json: the fit checks' survey, no device)
               firmwarekit create --catalog CATALOG.json --id ENTRY_ID --ipsw IPSW --out DIR [create options]
               --gl-test adds the GL fixture job to a test device
               firmwarekit mount|export --device DIR [--volume system|data|all] [--out DIR]
               firmwarekit unmount --out DIR
               firmwarekit verify-keys --entry ENTRY.json --ipsw IPSW
               firmwarekit fit --root MOUNTED_SYSTEM_VOLUME [--arch armv6|armv7] MACHO...

        """.utf8))
    _ = await FirmwareDiagnostics.finish()
    exit(64)
}
var flags: [String: String] = [:]
let known: Set = ["--catalog", "--id", "--entry", "--ipsw", "--out", "--seed", "--helper", "--cache", "--guest-tools", "--sibling-entry", "--sibling-ipsw", "--stop-after"]
while let a = args.popFirst() {
    if a == "--gl-test" { flags[a] = "1"; continue }
    guard known.contains(a), let v = args.popFirst() else { emit(.error(code: "internal", message: "bad argument \(a)")); _ = await commandOutput.finish(); exit(1) }
    flags[a] = v
}
guard let ipsw = flags["--ipsw"], let out = flags["--out"],
      (flags["--entry"] != nil && flags["--catalog"] == nil && flags["--id"] == nil)
        || (flags["--entry"] == nil && flags["--catalog"] != nil && flags["--id"] != nil) else {
    emit(.error(code: "internal", message: "use --entry or --catalog with --id; --ipsw and --out are required")); _ = await commandOutput.finish(); exit(1)
}
let url = { (p: String) in URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL }
let staging = url(out)

@Sendable func fail(_ error: Error) async -> Never {
    FirmwareDiagnostics.write(Data("firmwarekit: \(error)\n".utf8))
    emit(Preparer.errorEvent(error))
    _ = await commandOutput.finish(); _ = await FirmwareDiagnostics.finish()
    exit(1)
}
var options: Preparer.Options
do {
    let bundled = Bundle.main.executableURL!.resolvingSymlinksInPath().deletingLastPathComponent()
        .appendingPathComponent("../Resources/guest-tools").standardizedFileURL
    var entry = try flags["--entry"].map { try FirmwareEntry.load(from: url($0)) }
        ?? FirmwareEntry.load(id: flags["--id"]!, fromCatalog: url(flags["--catalog"]!))
    if flags["--gl-test"] != nil { entry.recipe?.options["gl_test"] = true }
    options = .init(entry: entry, ipsw: url(ipsw), out: staging, seed: flags["--seed"],
                    helper: flags["--helper"].map(url),
                    guestTools: flags["--guest-tools"].map(url) ?? bundled, cache: flags["--cache"].map(url),
                    sibling: try flags["--sibling-entry"].map { (try FirmwareEntry.load(from: url($0)), url(flags["--sibling-ipsw"] ?? "")) })
} catch { await fail(error) }
if let stop = flags["--stop-after"] {
    guard stop == "volumes" else { emit(.error(code: "internal", message: "--stop-after takes only volumes")); _ = await commandOutput.finish(); exit(1) }
    options.stopAfterVolumes = true
}

do { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) }
catch { await fail(error) }

let selectedOptions = options
let lifetime = CommandLifetime(output: commandOutput, cleanup: { try await Preparer.cancel(staging: staging) }) {
    do { try await Preparer.create(selectedOptions, emit: emit); return 0 }
    catch {
        if Task.isCancelled { return 143 }
        FirmwareDiagnostics.write(Data("firmwarekit: \(error)\n".utf8))
        emit(Preparer.errorEvent(error))
        return 1
    }
}
exit(await lifetime.wait())
