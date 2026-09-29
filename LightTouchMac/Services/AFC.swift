// AFC: free space, the chunked upload behind installs and media (/PublicStaging,
// /LightTouch), the startup sweep of orphaned uploads, and the Files browser's
// listing and export — all through DeviceServices' run kernel.

import Foundation

extension DeviceServices {
    // MARK: - Free space

    /// Bytes free on the media partition, via AFC. The pre-flight that names a
    /// full device before installd fails opaquely with PackageExtractionFailed.
    func freeSpaceBytes() async throws -> Int64 {
        try await run(Timeouts.query, "free space") { imd, device in
            guard let start = imd.afc_client_start_service,
                  let infoKey = imd.afc_get_device_info_key else { throw DeviceError.unavailable }
            var client: OpaquePointer?
            let rc = start(device, &client, "LightTouchMac")
            guard rc == imd.success, let client else {
                throw DeviceError.afc(.init(code: rc))
            }
            defer { _ = imd.afc_client_free?(client) }
            var value: UnsafeMutablePointer<CChar>?
            let fr = "FSFreeBytes".withCString { infoKey(client, $0, &value) }
            guard fr == imd.success, let value else { throw DeviceError.afc(.init(code: fr)) }
            defer { free(value) }
            return Int64(String(cString: value)) ?? 0
        }
    }

    nonisolated static func validateFilePath(_ path: String) throws {
        guard !path.hasPrefix("/"), !path.contains("\0"),
              path.isEmpty || path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DeviceError.preflight("Invalid device file path.")
        }
    }

    // MARK: - Stage (AFC upload into /PublicStaging)

    /// Upload the .ipa into the AFC jail and return its device-relative path,
    /// which is what instproxy_install wants. Chunked so progress is live.
    func stage(_ ipa: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await stageFile(ipa, remote: "PublicStaging/\(Self.stagingName(ipa))", progress: progress)
    }

    func stageSong(_ song: MediaSong, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard UUID(uuidString: song.id) != nil,
              MediaSong.extensions.contains(song.audio.pathExtension),
              song.audio.lastPathComponent == "audio." + song.audio.pathExtension else {
            throw DeviceError.preflight("Invalid media staging path.")
        }
        _ = try await stageFile(song.audio, remote: "LightTouch/\(song.id)/\(song.audio.lastPathComponent)",
                                reuseIdentical: true, progress: progress)
    }

    func stagePhoto(_ photo: MediaPhoto, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard UUID(uuidString: photo.id) != nil, photo.image.lastPathComponent == "image.jpg" else {
            throw DeviceError.preflight("Invalid photo staging path.")
        }
        _ = try await stageFile(photo.image, remote: "LightTouch/\(photo.id)/image.jpg", reuseIdentical: true, progress: progress)
    }

    func stageVideo(_ video: MediaVideo, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard UUID(uuidString: video.id) != nil, video.video.lastPathComponent == "video.m4v" else {
            throw DeviceError.preflight("Invalid video staging path.")
        }
        _ = try await stageFile(video.video, remote: "LightTouch/\(video.id)/video.m4v", reuseIdentical: true, progress: progress)
    }

    func uploadFile(_ source: URL, into directory: String,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        try Self.validateFilePath(directory)
        let path = directory.isEmpty ? source.lastPathComponent : directory + "/" + source.lastPathComponent
        try Self.validateFilePath(path)
        guard !path.isEmpty else { throw DeviceError.preflight("Select a file to import.") }
        _ = try await stageFile(source, remote: path, reuseIdentical: true, allowEmpty: true, progress: progress)
    }

    /// Callers supply a validated relative destination. The same chunked AFC
    /// upload, cancellation and incomplete-file cleanup serve apps and songs.
    private func stageFile(_ ipa: URL, remote: String, reuseIdentical: Bool = false, allowEmpty: Bool = false,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        return try await run(Timeouts.stage, "upload") { imd, device in
            // File I/O stays on the detached worker, including opening the file.
            let input = try FileHandle(forReadingFrom: ipa)
            defer { try? input.close() }
            let total = try input.seekToEnd()
            try input.seek(toOffset: 0)
            guard total > 0 || allowEmpty else { throw DeviceError.preflight("The file is empty.") }
            guard let start = imd.afc_client_start_service,
                  let mkdir = imd.afc_make_directory,
                  let open = imd.afc_file_open,
                  let write = imd.afc_file_write,
                  let close = imd.afc_file_close else { throw DeviceError.unavailable }
            var client: OpaquePointer?
            let rc = start(device, &client, "LightTouchMac")
            guard rc == imd.success, let client else { throw DeviceError.afc(.init(code: rc)) }
            defer { _ = imd.afc_client_free?(client) }
            if reuseIdentical {
                guard let read = imd.afc_file_read, imd.afc_rename_path != nil else { throw DeviceError.unavailable }
                var existing: UInt64 = 0
                let result = remote.withCString { open(client, $0, 1, &existing) } // AFC_FOPEN_RDONLY.
                if result == imd.success {
                    defer { _ = close(client, existing) }
                    var buffer = [CChar](repeating: 0, count: 65536)
                    while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
                        var offset = 0
                        while offset < chunk.count {
                            try Task.checkCancellation()
                            var count: UInt32 = 0
                            let rc = read(client, existing, &buffer, UInt32(chunk.count - offset), &count)
                            guard rc == imd.success, count > 0, count <= chunk.count - offset,
                                  Data(bytes: buffer, count: Int(count)) == chunk.subdata(in: offset..<(offset + Int(count))) else {
                                throw DeviceError.preflight("An existing media file differs from this import. It was kept unchanged.")
                            }
                            offset += Int(count)
                        }
                    }
                    var count: UInt32 = 0
                    guard read(client, existing, &buffer, 1, &count) == imd.success, count == 0 else {
                        throw DeviceError.preflight("An existing media file differs from this import. It was kept unchanged.")
                    }
                    progress(1)
                    return remote
                }
                guard result == 8 else { throw DeviceError.afc(.init(code: result)) } // Object not found.
            }
            // Publish complete media only. Interrupted uploads never truncate a
            // library file or leave a partial file at its content-derived path.
            let destination = reuseIdentical ? remote + ".upload-" + Self.stagingSession + "-" + UUID().uuidString : remote
            var parent = ""
            for component in remote.split(separator: "/").dropLast() {
                parent = parent.isEmpty ? String(component) : parent + "/" + component
                _ = parent.withCString { mkdir(client, $0) }
            }
            var handle: UInt64 = 0
            let opened = destination.withCString { open(client, $0, IMobileDevice.afcWriteMode, &handle) }
            guard opened == imd.success else { throw DeviceError.afc(.init(code: opened)) }
            var closed = false
            var complete = false
            defer {
                if !closed { _ = close(client, handle) }
                if !complete { _ = destination.withCString { imd.afc_remove_path?(client, $0) } }
            }
            var written: UInt64 = 0
            while written < total {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: Int(min(1 << 16, total - written))),
                      !chunk.isEmpty else { throw DeviceError.preflight("The file changed during upload.") }
                try chunk.withUnsafeBytes { raw in
                    let base = raw.bindMemory(to: CChar.self).baseAddress!
                    var offset = 0
                    while offset < raw.count {
                        try Task.checkCancellation()
                        var count: UInt32 = 0
                        let rc = write(client, handle, base + offset, UInt32(raw.count - offset), &count)
                        guard rc == imd.success, count > 0, count <= raw.count - offset else {
                            throw DeviceError.upload(.init(code: rc == 0 ? 1 : rc), written: written, total: total)
                        }
                        offset += Int(count)
                        written += UInt64(count)
                    }
                }
                progress(Double(written) / Double(total))
            }
            let result = close(client, handle)
            closed = true
            guard result == imd.success else { throw DeviceError.upload(.init(code: result), written: written, total: total) }
            try Task.checkCancellation()
            if reuseIdentical {
                let renamed = destination.withCString { from in
                    remote.withCString { to in imd.afc_rename_path!(client, from, to) }
                }
                guard renamed == imd.success else { throw DeviceError.afc(.init(code: renamed)) }
            }
            complete = true
            progress(1)
            return remote
        }
    }

    /// A stable device-side filename from the .ipa: staging paths must survive
    /// odd characters (`Super Monkey Ball [SEGA]`), so reduce to a safe set.
    /// Unique per upload. Collapsing punctuation to "_" made "Temple Run",
    /// "Temple-Run" and "Temple.Run" all stage to one path, so re-dropping a
    /// newer build landed on a file the device still held open from the last
    /// attempt — AFC refused it (the bare "File-transfer error: code 1") — and
    /// one install's fire-and-forget cleanup could delete the next install's
    /// upload out from under it. A unique suffix removes both.
    static let stagingSession = UUID().uuidString

    static func stagingName(_ ipa: URL) -> String {
        let base = ipa.deletingPathExtension().lastPathComponent
        let safe = String(base.map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(48))
        return "\(safe)-\(stagingSession)-\(UUID().uuidString.prefix(8)).ipa"
    }

    /// Startup cleanup can run after a new upload begins. Session-tagged names
    /// protect every upload from this process, including ones not yet queued.
    /// Internal, with the names above, for tests/offline/check-upload.py.
    static func isOrphanedStagingName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.contains("-\(stagingSession)-")
    }

    static func isOrphanedMediaUpload(_ name: String) -> Bool {
        let parts = name.components(separatedBy: ".upload-")
        guard parts.count == 2,
              ["audio.mp3", "audio.m4a", "audio.aac", "audio.wav", "image.jpg"].contains(parts[0]),
              !parts[1].hasPrefix(stagingSession + "-") else { return false }
        let suffix = parts[1]
        if UUID(uuidString: suffix) != nil { return true } // Earlier atomic uploads.
        return suffix.count == 73 && suffix[suffix.index(suffix.startIndex, offsetBy: 36)] == "-"
            && UUID(uuidString: String(suffix.prefix(36))) != nil
            && UUID(uuidString: String(suffix.suffix(36))) != nil
    }

    func sweepStaging() async {
        _ = try? await run(Timeouts.query, "staging sweep") { imd, device in
            guard let start = imd.afc_client_start_service,
                  let readDir = imd.afc_read_directory,
                  let remove = imd.afc_remove_path,
                  let dictFree = imd.afc_dictionary_free else { return }
            var client: OpaquePointer?
            guard start(device, &client, "LightTouchMac") == imd.success, let client else { return }
            defer { _ = imd.afc_client_free?(client) }

            func entries(_ path: String) -> [String] {
                var list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                guard path.withCString({ readDir(client, $0, &list) }) == imd.success,
                      let list else { return [] }
                defer { _ = dictFree(list) }
                var names: [String] = [], i = 0
                while let entry = list[i] { names.append(String(cString: entry)); i += 1 }
                return names
            }
            for name in entries("PublicStaging") {
                try Task.checkCancellation()
                guard Self.isOrphanedStagingName(name) else { continue }
                logEvent("device: removing orphaned staging upload \(name)")
                _ = "PublicStaging/\(name)".withCString { remove(client, $0) }
            }
            for directory in entries("LightTouch") where UUID(uuidString: directory) != nil {
                try Task.checkCancellation()
                for name in entries("LightTouch/\(directory)") {
                    try Task.checkCancellation()
                    guard Self.isOrphanedMediaUpload(name) else { continue }
                    _ = "LightTouch/\(directory)/\(name)".withCString { remove(client, $0) }
                }
            }
        }
    }

    /// Best-effort cleanup of a staged upload.
    func removeStaged(_ path: String) async {
        _ = try? await run(Timeouts.query, "cleanup") { imd, device in
            guard let start = imd.afc_client_start_service,
                  let remove = imd.afc_remove_path else { return }
            var client: OpaquePointer?
            guard start(device, &client, "LightTouchMac") == imd.success, let client else { return }
            defer { _ = imd.afc_client_free?(client) }
            _ = path.withCString { remove(client, $0) }
        }
    }
}

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
