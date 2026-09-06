import Foundation

struct DeviceFile: Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isRegular: Bool
    let size: UInt64
}

extension DeviceServices {
    func files(in path: String) async throws -> [DeviceFile] {
        try Self.validateFilePath(path)
        return try await run(Timeouts.browse, "browse files") { imd, device in
            guard let start = imd.afc_client_start_service,
                  let read = imd.afc_read_directory,
                  let info = imd.afc_get_file_info,
                  let free = imd.afc_dictionary_free else { throw DeviceError.unavailable }
            var client: OpaquePointer?
            let rc = start(device, &client, "LightTouchMac")
            guard rc == imd.success, let client else { throw DeviceError.afc(.init(code: rc)) }
            defer { _ = imd.afc_client_free?(client) }
            var names: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
            let result = (path.isEmpty ? "/" : path).withCString { read(client, $0, &names) }
            guard result == imd.success, let names else { throw DeviceError.afc(.init(code: result)) }
            defer { _ = free(names) }
            var entries: [DeviceFile] = []
            var i = 0
            while let raw = names[i] {
                try Task.checkCancellation()
                i += 1
                let name = String(cString: raw)
                if name == "." || name == ".." { continue }
                guard !name.isEmpty, !name.contains("/") else {
                    throw DeviceError.preflight("The device returned an invalid filename.")
                }
                let child = path.isEmpty ? name : path + "/" + name
                var values: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                let rc = child.withCString { info(client, $0, &values) }
                guard rc == imd.success, let values else { throw DeviceError.afc(.init(code: rc)) }
                defer { _ = free(values) }
                var metadata: [String: String] = [:]
                var j = 0
                while let key = values[j] {
                    guard let value = values[j + 1] else {
                        throw DeviceError.preflight("The device returned incomplete file information.")
                    }
                    metadata[String(cString: key)] = String(cString: value)
                    j += 2
                }
                entries.append(DeviceFile(name: name, path: child,
                    isDirectory: metadata["st_ifmt"] == "S_IFDIR",
                    isRegular: metadata["st_ifmt"] == "S_IFREG",
                    size: UInt64(metadata["st_size"] ?? "") ?? 0))
            }
            return entries.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    /// Save to a private adjacent file, then publish only a completed transfer.
    func download(_ file: DeviceFile, to destination: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        try Self.validateFilePath(file.path)
        guard file.isRegular, !file.path.isEmpty else {
            throw DeviceError.preflight("Select a regular file to export.")
        }
        try await run(Timeouts.stage, "export file") { imd, device in
            guard let start = imd.afc_client_start_service,
                  let open = imd.afc_file_open, let read = imd.afc_file_read,
                  let close = imd.afc_file_close else { throw DeviceError.unavailable }
            var client: OpaquePointer?
            let rc = start(device, &client, "LightTouchMac")
            guard rc == imd.success, let client else { throw DeviceError.afc(.init(code: rc)) }
            defer { _ = imd.afc_client_free?(client) }
            var handle: UInt64 = 0
            let opened = file.path.withCString { open(client, $0, 1, &handle) }
            guard opened == imd.success else { throw DeviceError.afc(.init(code: opened)) }
            defer { _ = close(client, handle) }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".LightTouch-" + UUID().uuidString)
            let fd = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
            var buffer = [CChar](repeating: 0, count: 65536)
            var received: UInt64 = 0
            while true {
                try Task.checkCancellation()
                var count: UInt32 = 0
                let rc = read(client, handle, &buffer, UInt32(buffer.count), &count)
                guard rc == imd.success, count <= buffer.count else {
                    throw DeviceError.afc(.init(code: rc == 0 ? 1 : rc))
                }
                if count == 0 { break }
                guard UInt64(count) <= file.size - min(received, file.size) else {
                    throw DeviceError.preflight("The file changed. Refresh Files and try again.")
                }
                try output.write(contentsOf: Data(bytes: buffer, count: Int(count)))
                received += UInt64(count)
                progress(file.size == 0 ? 1 : Double(received) / Double(file.size))
            }
            guard received == file.size else {
                throw DeviceError.preflight("The file changed. Refresh Files and try again.")
            }
            try output.synchronize()
            try output.close()
            try Task.checkCancellation()
            let result = temporary.path.withCString { from in
                destination.path.withCString { to in Darwin.rename(from, to) }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            progress(1)
        }
    }
}
