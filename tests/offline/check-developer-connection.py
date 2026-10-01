#!/usr/bin/env python3
"""Execute live endpoint publication and stale-session retirement."""
import pathlib, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = r'''import Foundation
nonisolated enum GuestDeveloperTools {
    static let state = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROFILE_TEST_STATE"]!)
}
@main struct Probe {
    static func main() throws {
        let instance = UUID(), first = UUID(), second = UUID()
        let root = GuestDeveloperTools.state.appendingPathComponent(instance.uuidString.lowercased())
        let profile = root.appendingPathComponent("connection.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try DeveloperConnectionProfile.publish(instance: instance, session: first, socket: "127.0.0.1:4010", udid: "first-device")
        precondition(!FileManager.default.fileExists(atPath: profile.path))
        try Data().write(to: root.appendingPathComponent("enabled"))
        try DeveloperConnectionProfile.publish(instance: instance, session: first, socket: "127.0.0.1:4010", udid: "first-device")
        let old = try JSONDecoder().decode(DeveloperConnectionProfile.Connection.self, from: Data(contentsOf: profile))
        precondition(old.instance == instance && old.session == first && old.udid == "first-device")
        precondition(old.inetcat == Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("inetcat").path)
        let mode = try FileManager.default.attributesOfItem(atPath: profile.path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        try DeveloperConnectionProfile.publish(instance: instance, session: second, socket: "127.0.0.1:4020", udid: "second-device")
        DeveloperConnectionProfile.retire(instance: instance, session: first)
        let current = try JSONDecoder().decode(DeveloperConnectionProfile.Connection.self, from: Data(contentsOf: profile))
        precondition(current.session == second && current.usbmux == "127.0.0.1:4020")
        DeveloperConnectionProfile.retire(instance: instance, session: second)
        precondition(!FileManager.default.fileExists(atPath: profile.path))
        print("PASS: opt-in, bundled forwarding tool, private profile, exact boot endpoint, stale retirement isolated")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="ltm-profile-") as temporary:
    folder = pathlib.Path(temporary)
    main = folder / "main.swift"
    main.write_text(SOURCE)
    tool = folder / "inetcat"
    tool.write_text("#!/bin/sh\nexit 0\n")
    tool.chmod(0o755)
    executable = folder / "probe"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(ROOT / "LightTouchMac/Guest/DeveloperConnectionProfile.swift"), str(main), "-o", str(executable)], check=True)
    import os
    subprocess.run([str(executable)], env={**os.environ, "PROFILE_TEST_STATE": str(folder / "state")}, check=True)
