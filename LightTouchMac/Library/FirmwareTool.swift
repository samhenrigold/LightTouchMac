import Foundation
import Subprocess
import System

/// Narrow host boundary: the GUI requests operations; FirmwareKit owns formats.
nonisolated enum FirmwareTool {
    static func run(_ arguments: [String], executable: URL) async throws -> Data {
        let child = try await Subprocess.run(.path(FilePath(executable.path)), arguments: Arguments(arguments),
            input: .none, output: .string(limit: 65536), error: .string(limit: 65536))
        guard child.terminationStatus == .exited(0) else {
            throw DeviceToolsError.failed(child.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Data(child.standardOutput.utf8)
    }
}
