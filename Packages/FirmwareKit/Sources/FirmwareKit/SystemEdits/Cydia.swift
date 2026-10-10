// Cydia on a jailbroken device (firmwarekit create --jailbreak): the bootstrap the jailbreaks of the time left on the
// system volume, extracted as they extracted it.
//
// The bootstrap is saurik's freeze.tar as Legacy iOS Kit ships it for the jailbroken restores it builds for iOS 3.1
// to 6.x (github.com/LukeZGD/Legacy-iOS-Kit, resources/jailbreak/freeze.tar.gz, pinned by commit): Cydia 1.1.30
// (armv6 + arm64, MinimumOSVersion 2.0), apt, dpkg, bash and the base packages, dpkg's status already listing them,
// and Cydia's com.saurik.Cydia.Startup job. Its executables are ldid-signed, which the boot-args every device boots
// with let run (FitCheck.amfiArgs). On the first boot the Startup job runs /usr/libexec/cydia/startup, which writes
// the firmware package and runs uicache, so SpringBoard lists Cydia.app; the bootstrap's own SpringBoard preference
// SBShowNonDefaultSystemApps shows it there.
//
// Substrate (MobileSubstrate 0.9.7114 and its Safe Mode extension, armv6 + arm64) comes as Legacy iOS Kit adds it:
// cydiasubstrate.tar puts its .debs in Cydia's AutoInstall folder, which the Startup job installs with dpkg on the
// first boot. Its install script starts Substrate in launchd at once and, below iOS 7, for every later boot through
// /etc/launchd.conf (bsexec .. cynject 1 SubstrateLauncher.dylib), so every job launchd starts, SpringBoard and the
// apps among them, loads Substrate. Legacy iOS Kit adds it for 3.x to 5.x; 6.x takes the same package (its restores
// leave Substrate to Cydia there). 7.x gets none: its root stays read-only (no dpkg at boot), and on 7.x the script
// starts Substrate only from /etc/rc.d, which only a jailbreak's untether runs. On 3.x Cydia HTTPatch
// (cydiahttpatch.tar, a Substrate extension) points Cydia at http, as 3.x's TLS can't reach its repositories.
// Patcyh, a Substrate extension for lsd and installd that freeze.tar carries for iOS 8.3 and later, comes out, as
// Legacy iOS Kit takes it out below 8.3.
//
//   let file = try SystemEdits.Cydia.bootstrap(in: caches.appendingPathComponent("Jailbreak"), log: log)
//   let (line, root, mobile) = try SystemEdits.installCydia(m, bootstrap: file)

import CryptoKit
import Foundation

extension SystemEdits {
    public enum Cydia {
        static let source =
            "https://raw.githubusercontent.com/LukeZGD/Legacy-iOS-Kit/4b0a582f4d53e105be373b495734c8ed639fd634/resources/jailbreak/"
        /// The bootstrap, then what Legacy iOS Kit adds beside it: Substrate (cydiasubstrate.tar) and Cydia HTTPatch
        /// (cydiahttpatch.tar).
        static let files = [
            (name: "freeze.tar.gz", sha1: "c943e5ece72b7b71da589c22663a8f9b3b3d1190"),
            (name: "cydiasubstrate.tar", sha1: "264f47938acc09e6cc2890a3cc7c7988a6822da3"),
            (name: "cydiahttpatch.tar", sha1: "3a1302c6294fe290c6d52186dd4fe56cda7fd661"),
        ]
        static let name = files[0].name, noStash = ".cydia_no_stash"
        static let substrateMajors = 3...6
        static let springBoardPrefs = "private/var/mobile/Library/Preferences/com.apple.springboard.plist"
        static let patcyh = [
            "Library/MobileSubstrate/DynamicLibraries/patcyh.dylib",
            "Library/MobileSubstrate/DynamicLibraries/patcyh.plist", "usr/lib/libpatcyh.dylib",
            "private/var/lib/dpkg/info/com.saurik.patcyh.list", "private/var/lib/dpkg/info/com.saurik.patcyh.postrm",
            "private/var/lib/dpkg/info/com.saurik.patcyh.extrainst_",
        ]

        /// The bootstrap in `dir`, with the packages beside it, each downloaded there first when it is missing or
        /// other bytes.
        public static func bootstrap(
            in dir: URL,
            download: (URL, URL) throws -> Void = SourceFetch.download,
            log: (String) -> Void = { _ in }
        ) throws -> URL {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, sha1) in files {
                let file = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path),
                    try Preparer.digest(file, Insecure.SHA1()) == sha1
                {
                    continue
                }
                guard let url = URL(string: source + name) else { throw FirmwareError(.internal, "Cydia: \(name)") }
                let part = dir.appendingPathComponent("." + name + ".download")
                defer { try? FileManager.default.removeItem(at: part) }
                log("Cydia: \(url.absoluteString)")
                try download(url, part)
                let got = try Preparer.digest(part, Insecure.SHA1())
                guard got == sha1 else { throw FirmwareError(.shaMismatch, "Cydia: \(name) SHA-1 \(got), not \(sha1)") }
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: part, to: file)
            }
            return dir.appendingPathComponent(name)
        }
    }

    /// The bootstrap extracted into the mounted system volume `m`, keeping every file the firmware already has (tar
    /// -k). Returns the log line and the volume paths to make root's and mobile's: what it added, mobile's under
    /// /private/var/mobile, root's elsewhere (its symbolic links too, which tar replaces).
    static func installCydia(_ m: URL, bootstrap: URL) throws -> (line: String, root: [String], mobile: [String]) {
        let fm = FileManager.default
        func exists(_ rel: String) -> Bool {
            (try? fm.attributesOfItem(atPath: m.appendingPathComponent(rel).path)) != nil
        }
        func link(_ rel: String) -> Bool {
            (try? fm.destinationOfSymbolicLink(atPath: m.appendingPathComponent(rel).path)) != nil
        }
        // Substrate on 3.x to 6.x, HTTPatch on 3.x
        let major =
            Int(
                (NSDictionary(contentsOf: m.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist"))?[
                    "ProductVersion"
                ] as? String)?.split(separator: ".").first ?? ""
            ) ?? 0
        let packages = [
            (Cydia.files[0].name, true), (Cydia.files[1].name, Cydia.substrateMajors.contains(major)),
            (Cydia.files[2].name, major == 3),
        ].filter(\.1).map { bootstrap.deletingLastPathComponent().appendingPathComponent($0.0) }
        var entries: [String] = []
        for p in packages {
            entries += try tar(["-tf", p.path]).split(separator: "\n").map {
                String($0.hasPrefix("./") ? $0.dropFirst(2) : $0[...]).trimmingCharacters(in: ["/"])
            }
        }
        entries = entries.filter { !$0.isEmpty }
        let added = Set(entries.filter { !exists($0) })
        for p in packages { _ = try tar(["-xkf", p.path, "-C", m.path]) }
        guard exists("Applications/Cydia.app/Cydia") else {
            throw FirmwareError(.internal, "Cydia bootstrap: no Applications/Cydia.app/Cydia after extracting")
        }
        // Patcyh (a Substrate extension for lsd and installd, for iOS 8.3 and later) out, as Legacy iOS Kit takes
        // it out below 8.3: with Substrate it would load into installd beside AppSync.
        for rel in Cydia.patcyh { try? fm.removeItem(at: m.appendingPathComponent(rel)) }
        for rel in ["private/var/lib/dpkg/status", "private/var/lib/dpkg/available"] {
            let u = m.appendingPathComponent(rel)
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
            let kept = text.components(separatedBy: "\n\n").filter { !$0.hasPrefix("Package: com.saurik.patcyh\n") }
            try put(Data(kept.joined(separator: "\n\n").utf8), u)
        }
        entries.removeAll { Cydia.patcyh.contains($0) }
        // SpringBoard lists a system app outside its own set only with this key (the bootstrap's copy of the file
        // gives it, unless the firmware has the file already).
        let prefs = m.appendingPathComponent(Cydia.springBoardPrefs)
        let hadPrefs = exists(Cydia.springBoardPrefs)
        try seedPlist(prefs) { $0["SBShowNonDefaultSystemApps"] = true }
        // Cydia's first launch would otherwise stash /Applications, /usr/share and the rest onto the data volume
        // ("Preparing Filesystem", then exit) to free a stock-sized root; this root is grown, so no stash, as Legacy
        // iOS Kit's own restores mark it.
        try put(Data(), m.appendingPathComponent(Cydia.noStash), mode: 0o644)
        var root: [String] = [Cydia.noStash]
        var mobile: [String] = []
        for rel in entries where added.contains(rel) || link(rel) {
            if rel.hasPrefix("private/var/mobile/") { mobile.append(rel) } else { root.append(rel) }
        }
        if !hadPrefs, !mobile.contains(Cydia.springBoardPrefs) { mobile.append(Cydia.springBoardPrefs) }
        return ("Cydia: \(bootstrap.lastPathComponent), \(added.count) of \(entries.count) entries added", root, mobile)
    }

    /// /usr/bin/tar `args`; its stdout, or an error with its stderr.
    private static func tar(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw FirmwareError(.internal, "tar \(args.first ?? ""): \(String(decoding: errors, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
