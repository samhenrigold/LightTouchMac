import Foundation

/// Source-built local VM helpers; stock installd owns installation and registration.
public enum SideloadTools {
    public static func install(system: URL, helpers: URL) throws {
        let v = try HFSPlusWriter(system)
        v.owner = (0, 0)
        let nativeIOS9 =
            v.plist(at: "System/Library/CoreServices/SystemVersion.plist")?["ProductBuildVersion"] as? String
            == "13A344"
        // iOS 8+ release installd ignores the configured helper while this
        // empty dyld restriction marker is present. Older profiles are intact.
        if SystemEdits.majorVersion(v) >= 8 {
            let path = "usr/libexec/installd"
            let before = try v.contents(at: path)
            var after = try installationServiceAllowingHelper(before)
            if nativeIOS9 { after = try installationServiceAllowingEnvironment(after) }
            if after != before { try v.put(after, at: path, mode: 0o755) }
        }
        try v.makeDirectory("usr/local/bin", mode: 0o755)
        for (name, path) in [
            ("it_agent", "usr/local/bin/it_agent"),
            ("it_install", "usr/local/bin/it_install"),
            ("it_netcheck", "usr/local/bin/it_netcheck"),
            ("libappsync.dylib", "usr/lib/libappsync.dylib")
        ] {
            try v.put(contentsOf: helpers.appendingPathComponent(name), at: path, mode: 0o755)
        }
        if nativeIOS9 {
            try v.put(
                contentsOf: helpers.appendingPathComponent(SystemEdits.Helpers.appsyncLauncher),
                at: SystemEdits.appsyncLauncherPath, mode: 0o755)
        }
        var job: [String: Any] = [
            "Label": "com.qemu.it-agent", "ProgramArguments": ["/usr/local/bin/it_agent"],
            "RunAtLoad": true, "KeepAlive": true, "StandardErrorPath": "/var/log/it_agent.log"
        ]
        // The host command bridge is latency-sensitive, like the stock MIDI
        // and network agents. iOS 8's default background policy throttles it
        // to priority 4, delaying even a 250 ms poll for many seconds.
        if SystemEdits.majorVersion(v) >= 8 { job["ProcessType"] = "Interactive" }
        // Release launchd on iOS 9+ also requires explicit admission for a
        // locally supplied job. Keep this scoped to our guest bridge; stock
        // daemon admission and the system-wide launch policy stay intact.
        if SystemEdits.majorVersion(v) >= 9 { job["ExecuteAllowed"] = true }
        try v.put(
            PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0),
            at: "System/Library/LaunchDaemons/com.qemu.it-agent.plist", mode: 0o644)
        // There must only be one clipboard/agent owner.
        let old = "System/Library/LaunchDaemons/com.qemu.it-pbd.plist"
        if v.exists(old) { try v.remove(old) }
        var patched = false
        for name in ["com.apple.mobile.installd.plist", "com.apple.installd.plist"] {
            let path = "System/Library/LaunchDaemons/" + name
            guard v.exists(path) else { continue }
            var job =
                try PropertyListSerialization.propertyList(from: v.contents(at: path), format: nil) as! [String: Any]
            var env = job["EnvironmentVariables"] as? [String: String] ?? [:]
            var libs = (env["DYLD_INSERT_LIBRARIES"] ?? "").split(separator: ":").map(String.init)
            if !libs.contains("/usr/lib/libappsync.dylib") { libs.append("/usr/lib/libappsync.dylib") }
            env["DYLD_INSERT_LIBRARIES"] = libs.joined(separator: ":")
            job["EnvironmentVariables"] = env
            if nativeIOS9 {
                guard let arguments = job["ProgramArguments"] as? [String], !arguments.isEmpty else {
                    throw FirmwareError(.unsupported, "Installation service has no native arguments")
                }
                let program = job["Program"] as? String ?? arguments[0]
                let launcher = "/" + SystemEdits.appsyncLauncherPath
                if program != launcher {
                    job["Program"] = launcher
                    job["ProgramArguments"] = [launcher, program] + Array(arguments.dropFirst())
                }
                job["ExecuteAllowed"] = true
            }
            try v.put(PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0), at: path)
            patched = true
        }
        guard patched else {
            throw NSError(
                domain: "Sideload", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No supported installd job on this image"])
        }
        try LaunchdCache.refresh(
            v,
            jobs: [
                "System/Library/LaunchDaemons/com.qemu.it-agent.plist",
                "System/Library/LaunchDaemons/com.qemu.it-pbd.plist",
                "System/Library/LaunchDaemons/com.apple.SpringBoard.plist",
                "System/Library/LaunchDaemons/com.apple.mobile.installd.plist",
                "System/Library/LaunchDaemons/com.apple.installd.plist"
            ], helpers: helpers)
        try v.close()
    }
}
