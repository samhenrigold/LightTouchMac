// firmwarekit: the preparer (docs/multi-device-plan.md, "Preparer contract").
//
//   firmwarekit create --entry ENTRY.json --ipsw IPSW --out STAGING_DIR
//                      [--seed SEED] [--helper PATH_TO_LightTouchDevice]
//                      [--cache DIR] [--guest-tools DIR]
//
// stdout is JSON Lines only; diagnostics go to stderr. Exit 0 after done, 1 after an error event; SIGTERM,
// or the parent (the app) exiting, cancels (children stopped, images under STAGING_DIR detached, exit 143)
// and leaves STAGING_DIR to the caller. A closed stdout never kills it (SIGPIPE is ignored).
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
import Foundation

signal(SIGPIPE, SIG_IGN)
let stdoutLock = NSLock()
@Sendable func emit(_ e: PrepareEvent) {
    // Throwing write: a reader that went away is EPIPE, not an exception.
    stdoutLock.withLock { try? FileHandle.standardOutput.write(contentsOf: Data((e.json + "\n").utf8)) }
}

var args = CommandLine.arguments.dropFirst()
let command = args.popFirst()
if command == "mount" || command == "export" || command == "unmount" {
    volumeCommand(command!, Array(args))
}
if command == "verify-keys" { verifyKeysCommand(Array(args)) }
guard command == "create" else {
    FileHandle.standardError.write(Data("""
        firmwarekit \(FirmwareKit.version)
        usage: firmwarekit create --entry ENTRY.json --ipsw IPSW --out DIR [--seed S]
                                  [--helper PATH] [--cache DIR] [--guest-tools DIR]
               firmwarekit mount|export --device DIR [--volume system|data|all] [--out DIR]
               firmwarekit unmount --out DIR
               firmwarekit verify-keys --entry ENTRY.json --ipsw IPSW

        """.utf8))
    exit(64)
}
var flags: [String: String] = [:]
let known: Set = ["--entry", "--ipsw", "--out", "--seed", "--helper", "--cache", "--guest-tools", "--keybag-ramdisk"]
while let a = args.popFirst() {
    guard known.contains(a), let v = args.popFirst() else { emit(.error(code: "internal", message: "bad argument \(a)")); exit(1) }
    flags[a] = v
}
guard let entryPath = flags["--entry"], let ipsw = flags["--ipsw"], let out = flags["--out"] else {
    emit(.error(code: "internal", message: "--entry, --ipsw and --out are required")); exit(1)
}
let url = { (p: String) in URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL }
let staging = url(out)

func cancelAndExit(_ why: String) -> Never {
    FileHandle.standardError.write(Data("firmwarekit: cancelled (\(why))\n".utf8))
    stdoutLock.lock()   // held until exit: a step failing because its child was stopped emits nothing
    Preparer.cancel(staging: staging)
    exit(143)
}
let signalSources = [SIGTERM, SIGINT].map { sig in
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { cancelAndExit(sig == SIGTERM ? "SIGTERM" : "SIGINT") }
    s.resume()
    return s
}
// The app quit or crashed without cancelling: nobody will publish this staging.
let parent = getppid()
let parentWatch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
parentWatch.setEventHandler { cancelAndExit("parent \(parent) exited") }
parentWatch.resume()
if parent == 1 || getppid() != parent { cancelAndExit("no parent") }

@Sendable func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("firmwarekit: \(error)\n".utf8))
    emit(Preparer.errorEvent(error))
    exit(1)
}
let options: Preparer.Options
do {
    let bundled = Bundle.main.executableURL!.resolvingSymlinksInPath().deletingLastPathComponent()
        .appendingPathComponent("../Resources/guest-tools").standardizedFileURL
    options = .init(entry: try FirmwareEntry.load(from: url(entryPath)), ipsw: url(ipsw), out: staging, seed: flags["--seed"],
                    helper: flags["--helper"].map(url),
                    guestTools: flags["--guest-tools"].map(url) ?? bundled, cache: flags["--cache"].map(url),
                    keybagRamdisk: flags["--keybag-ramdisk"].map(url))
} catch { fail(error) }

Thread.detachNewThread { [options] in
    do { try Preparer.create(options, emit: emit); exit(0) } catch { fail(error) }
}
withExtendedLifetime((signalSources, parentWatch)) { dispatchMain() }
