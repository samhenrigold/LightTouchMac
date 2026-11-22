import Foundation

/// Source-built local VM helpers; stock installd owns installation and registration.
public enum SideloadTools {
    public static func install(system: URL, helpers: URL) throws {
        let v = try HFSPlusWriter(system)
        v.owner = (0, 0)
        let nativeIOS9 =
            v.plist(at: "System/Library/CoreServices/SystemVersion.plist")?["ProductBuildVersion"] as? String
            == "13A344"
        _ = try SystemEdits.installAppSync(
            v, helper: helpers.appendingPathComponent(SystemEdits.Helpers.appsync),
            cache: ["armv7s", "armv7"].map(SystemEdits.dyldCache).first(where: v.exists)
                ?? SystemEdits.dyldCache("armv7"),
            log: { _ in })
        if nativeIOS9 {
            let before = try v.contents(at: SystemEdits.installd)
            let after = try installationServiceAllowingEnvironment(before)
            if after != before { try v.put(after, at: SystemEdits.installd, mode: 0o755) }
        }
        try v.makeDirectory("usr/local/bin", mode: 0o755)
        // ltm-httpget: the harness's Wi-Fi check, baked in because the image's root is read-only and its sandbox
        // lets it_agent exec only what is on the system volume, so nothing the agent puts at run time can run.
        for (name, path) in [("it_agent", "usr/local/bin/it_agent"), ("httpget-armv7", "usr/local/bin/ltm-httpget")] {
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
        // 13A344's launchd filters the job's DYLD_INSERT_LIBRARIES: appsync-launch sets it and execs installd.
        if nativeIOS9, let job = SystemEdits.installdJobs.first(where: v.exists) {
            try SystemEdits.rewritePlist(v, job) { job in
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
