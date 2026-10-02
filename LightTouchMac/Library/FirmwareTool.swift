import Foundation
import Subprocess
import System

/// Narrow host boundary: the GUI requests operations; FirmwareKit owns formats.
nonisolated enum FirmwareTool {
    /// FirmwareKit validates/migrates stopped storage and releases ownership
    /// before DeviceRuntime spawns the helper. No live NOR writer is hosted here.
    static func admitBoot(device: URL, managed: Bool, executable: URL) async throws -> Bool {
        let flags = managed ? ["--record-policy", "managed"] : ["--record-policy", "standalone", "--allow-raw"]
        let data = try await run(["boot-admit", "--device", device.path] + flags, executable: executable)
        let report = try JSONDecoder().decode(FirmwareWire.BootAdmission.self, from: data)
        guard report.event == "admitted" else {
            throw DeviceToolsError.failed("The firmware worker did not admit this device.")
        }
        return report.changed
    }

    static func run(_ arguments: [String], executable: URL) async throws -> Data {
        let child = try await Subprocess.run(.path(FilePath(executable.path)), arguments: Arguments(arguments),
            input: .none, output: .string(limit: 65536), error: .string(limit: 65536))
        guard child.terminationStatus == .exited(0) else {
            throw DeviceToolsError.failed(child.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Data(child.standardOutput.utf8)
    }
}
