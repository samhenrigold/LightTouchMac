// AFC in the services helper: free space, the chunked upload behind installs and media (/PublicStaging,
// /LightTouch), the startup sweep of orphaned uploads, and the Files browser's
// listing and export — all through DeviceServices' run kernel.

import Foundation
import HostServiceWire

/// An AFC client and, for an app's container, the house_arrest client it rides on, which outlives it.
nonisolated struct AFCConnection {
    let client: OpaquePointer
    var houseArrest: OpaquePointer?
    func close() {
        _ = afc_client_free(client)
        if let houseArrest { _ = house_arrest_client_free(houseArrest) }
    }
}

extension IMobileDevice {
    /// AFC through lockdown's StartService, each step's error kept (IMobileDevice.startService): the media folder,
    /// afc2 (the whole file system a jailbroken device serves) or an app's container. The caller closes it.
    nonisolated static func startAFC(device: OpaquePointer, root: AFCRoot = .media) throws -> AFCConnection {
        guard case .app(let bundleID) = root else {
            return AFCConnection(
                client: try startService(
                    root == .fileSystem ? "com.apple.afc2" : "com.apple.afc",
                    device: device,
                    newClient: { afc_client_new($0, $1, $2) },
                    freeClient: { afc_client_free($0) }
                ) { DeviceError.afc(.init(code: $0)) }
            )
        }
        // house_arrest's VendContainer: AFC rooted at the app's container. mobile_house_arrest has it on every 2.x to
        // 7.x build (the only command through 3.1.3; 3.2 adds VendDocuments, Documents alone) and vends any installed
        // app's, its signer unchecked; 8.3 later limits it to developer-signed apps. 1.x has no house_arrest.
        let arrest = try startService(
            "com.apple.mobile.house_arrest",
            device: device,
            newClient: { house_arrest_client_new($0, $1, $2) },
            freeClient: { house_arrest_client_free($0) },
            connectError: { DeviceError.failed("The device's app file service refused the connection (error \($0)).") }
        )
        var handedOff = false
        defer { if !handedOff { _ = house_arrest_client_free(arrest) } }
        let sent = house_arrest_send_command(arrest, "VendContainer", bundleID)
        var result: plist_t?
        let answered = sent.ok ? house_arrest_get_result(arrest, &result) : sent
        defer { if let result { plist_free(result) } }
        guard answered.ok, let result, let reply = decode(result) as? [String: Any] else {
            throw DeviceError.failed("The device's app file service didn't answer (error \(answered.code)).")
        }
        if let error = reply["Error"] as? String {
            throw DeviceError.failed("The device couldn't open this app's folder (\(error)).")
        }
        var client: OpaquePointer?
        let opened = afc_client_new_from_house_arrest_client(arrest, &client)
        guard opened.ok, let client else { throw DeviceError.afc(.init(code: opened.ok ? 1 : opened.code)) }
        handedOff = true
        return AFCConnection(client: client, houseArrest: arrest)
    }
}

extension DeviceServices {
    // MARK: - Free space

    /// Bytes free on the media partition, via AFC. The pre-flight that names a
    /// full device before installd fails opaquely with PackageExtractionFailed.
    func freeSpaceBytes() async throws -> Int64 {
        try await run(Timeouts.query, "free space") { device in
            let afc = try IMobileDevice.startAFC(device: device)
            defer { afc.close() }
            let client = afc.client
            var value: UnsafeMutablePointer<CChar>?
            let fr = afc_get_device_info_key(client, "FSFreeBytes", &value)
            guard fr.ok, let value else { throw DeviceError.afc(.init(code: fr.code)) }
            defer { free(value) }
            return Int64(String(cString: value)) ?? 0
        }
    }

    // MARK: - Stage (AFC upload into /PublicStaging)

    /// Upload the .ipa into PublicStaging and return its device-relative path, which is what instproxy_install wants.
    func stage(_ ipa: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await stageFile(ipa, remote: "PublicStaging/\(Self.stagingName(ipa))", progress: progress)
    }

    /// Callers supply a validated relative destination. The same chunked AFC
    /// upload, cancellation and incomplete-file cleanup serve apps and songs.
    func stageFile(
        _ ipa: URL,
        remote: String,
        reuseIdentical: Bool = false,
        replace: Bool = false,
        allowEmpty: Bool = false,
        root: AFCRoot = .media,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        try await run(Timeouts.stage, "upload") { device in
            // File I/O stays on the detached worker, including opening the file.
            let input = try FileHandle(forReadingFrom: ipa)
            defer { try? input.close() }
            let total = try input.seekToEnd()
            try input.seek(toOffset: 0)
            guard total > 0 || allowEmpty else { throw DeviceError.preflight("The file is empty.") }
            let afc = try IMobileDevice.startAFC(device: device, root: root)
            defer { afc.close() }
            let client = afc.client
            if reuseIdentical {
                var existing: UInt64 = 0
                let result = afc_file_open(client, remote, AFC_FOPEN_RDONLY, &existing)
                if result.ok {
                    defer { _ = afc_file_close(client, existing) }
                    var buffer = [CChar](repeating: 0, count: 65536)
                    while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
                        var offset = 0
                        while offset < chunk.count {
                            try Task.checkCancellation()
                            var count: UInt32 = 0
                            let rc = afc_file_read(client, existing, &buffer, UInt32(chunk.count - offset), &count)
                            guard rc.ok, count > 0, count <= chunk.count - offset,
                                Data(bytes: buffer, count: Int(count))
                                    == chunk.subdata(in: offset..<(offset + Int(count)))
                            else {
                                throw DeviceError.preflight(
                                    "An existing media file differs from this import. It was kept unchanged."
                                )
                            }
                            offset += Int(count)
                        }
                    }
                    var count: UInt32 = 0
                    guard afc_file_read(client, existing, &buffer, 1, &count).ok, count == 0 else {
                        throw DeviceError.preflight(
                            "An existing media file differs from this import. It was kept unchanged."
                        )
                    }
                    progress(1)
                    return remote
                }
                guard result == AFC_E_OBJECT_NOT_FOUND else { throw DeviceError.afc(.init(code: result.code)) }
            }
            // Publish complete media only. Interrupted uploads never truncate a
            // library file or leave a partial file at its content-derived path, nor a replaced file.
            let publish = reuseIdentical || replace
            let destination =
                publish ? remote + ".upload-" + Self.stagingSession + "-" + UUID().uuidString : remote
            var parent = ""
            for component in remote.split(separator: "/").dropLast() {
                parent = parent.isEmpty ? String(component) : parent + "/" + component
                _ = afc_make_directory(client, parent)
            }
            var handle: UInt64 = 0
            let opened = afc_file_open(client, destination, AFC_FOPEN_WRONLY, &handle)
            guard opened.ok else { throw DeviceError.afc(.init(code: opened.code)) }
            var closed = false
            var complete = false
            defer {
                if !closed { _ = afc_file_close(client, handle) }
                if !complete { _ = afc_remove_path(client, destination) }
            }
            var written: UInt64 = 0
            while written < total {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: Int(min(1 << 16, total - written))),
                    !chunk.isEmpty
                else { throw DeviceError.preflight("The file changed during upload.") }
                try chunk.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: CChar.self).baseAddress else {
                        throw DeviceError.preflight("The file changed during upload.")
                    }
                    var offset = 0
                    while offset < raw.count {
                        try Task.checkCancellation()
                        var count: UInt32 = 0
                        let rc = afc_file_write(client, handle, base + offset, UInt32(raw.count - offset), &count)
                        guard rc.ok, count > 0, count <= raw.count - offset else {
                            throw DeviceError.upload(.init(code: rc.ok ? 1 : rc.code), written: written, total: total)
                        }
                        offset += Int(count)
                        written += UInt64(count)
                    }
                }
                progress(Double(written) / Double(total))
            }
            let result = afc_file_close(client, handle)
            closed = true
            guard result.ok else { throw DeviceError.upload(.init(code: result.code), written: written, total: total) }
            try Task.checkCancellation()
            if publish {
                let renamed = afc_rename_path(client, destination, remote)
                guard renamed.ok else { throw DeviceError.afc(.init(code: renamed.code)) }
            }
            complete = true
            progress(1)
            return remote
        }
    }

    func sweepStaging() async {
        _ = try? await run(Timeouts.query, "staging sweep") { device in
            guard let afc = try? IMobileDevice.startAFC(device: device) else { return }
            defer { afc.close() }
            let client = afc.client

            func entries(_ path: String) -> [String] {
                var list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                guard afc_read_directory(client, path, &list).ok, let list else { return [] }
                defer { _ = afc_dictionary_free(list) }
                var names: [String] = []
                var i = 0
                while let entry = list[i] {
                    names.append(String(cString: entry))
                    i += 1
                }
                return names
            }
            for name in entries("PublicStaging") {
                try Task.checkCancellation()
                guard Self.isOrphanedStagingName(name) else { continue }
                logEvent("device: removing orphaned staging upload \(name)")
                _ = afc_remove_path(client, "PublicStaging/\(name)")
            }
            for directory in entries("LightTouch") where UUID(uuidString: directory) != nil {
                try Task.checkCancellation()
                for name in entries("LightTouch/\(directory)") {
                    try Task.checkCancellation()
                    guard Self.isOrphanedMediaUpload(name) else { continue }
                    _ = afc_remove_path(client, "LightTouch/\(directory)/\(name)")
                }
            }
        }
    }

    /// Best-effort cleanup of a staged upload.
    func removeStaged(_ path: String) async {
        _ = try? await run(Timeouts.query, "cleanup") { device in
            guard let afc = try? IMobileDevice.startAFC(device: device) else { return }
            defer { afc.close() }
            let client = afc.client
            _ = afc_remove_path(client, path)
        }
    }
}

extension DeviceServices {
    func files(in path: String, root: AFCRoot = .media) async throws -> [DeviceFile] {
        try Self.validateFilePath(path)
        return try await run(Timeouts.browse, "browse files") { device in
            let afc = try IMobileDevice.startAFC(device: device, root: root)
            defer { afc.close() }
            let client = afc.client
            var names: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
            let result = afc_read_directory(client, path.isEmpty ? "/" : path, &names)
            guard result.ok, let names else { throw DeviceError.afc(.init(code: result.code)) }
            defer { _ = afc_dictionary_free(names) }
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
                let rc = afc_get_file_info(client, child, &values)
                // Gone since the listing, or a link to nothing: 1.x's afcd stats through links, and every 1.x root
                // has /mach -> mach_kernel, which the device doesn't ship, so afc2 couldn't list "/" at all.
                if rc == AFC_E_OBJECT_NOT_FOUND { continue }
                guard rc.ok, let values else { throw DeviceError.afc(.init(code: rc.code)) }
                defer { _ = afc_dictionary_free(values) }
                var metadata: [String: String] = [:]
                var j = 0
                while let key = values[j] {
                    guard let value = values[j + 1] else {
                        throw DeviceError.preflight("The device returned incomplete file information.")
                    }
                    metadata[String(cString: key)] = String(cString: value)
                    j += 2
                }
                entries.append(
                    DeviceFile(
                        name: name,
                        path: child,
                        isDirectory: metadata["st_ifmt"] == "S_IFDIR",
                        isRegular: metadata["st_ifmt"] == "S_IFREG",
                        size: UInt64(metadata["st_size"] ?? "") ?? 0
                    )
                )
            }
            return entries.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    /// Save to a private adjacent file, then publish only a completed transfer.
    func download(
        _ file: DeviceFile,
        to destination: URL,
        root: AFCRoot = .media,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Self.validateFilePath(file.path)
        guard file.isRegular, !file.path.isEmpty else {
            throw DeviceError.preflight("Select a regular file to export.")
        }
        return try await run(Timeouts.stage, "export file") { device in
            let afc = try IMobileDevice.startAFC(device: device, root: root)
            defer { afc.close() }
            let client = afc.client
            var handle: UInt64 = 0
            let opened = afc_file_open(client, file.path, AFC_FOPEN_RDONLY, &handle)
            guard opened.ok else { throw DeviceError.afc(.init(code: opened.code)) }
            defer { _ = afc_file_close(client, handle) }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(
                ".LightTouch-" + UUID().uuidString
            )
            let fd = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) }
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer {
                try? output.close()
                try? FileManager.default.removeItem(at: temporary)
            }
            var buffer = [CChar](repeating: 0, count: 65536)
            var received: UInt64 = 0
            while true {
                try Task.checkCancellation()
                var count: UInt32 = 0
                let rc = afc_file_read(client, handle, &buffer, UInt32(buffer.count), &count)
                guard rc.ok, count <= buffer.count else {
                    throw DeviceError.afc(.init(code: rc.ok ? 1 : rc.code))
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

extension DeviceServices {
    /// The Files browser's delete: a file, or a folder with everything in it (AFC removes only empty ones).
    func delete(_ path: String, root: AFCRoot) async throws {
        try Self.validateFilePath(path)
        guard !path.isEmpty else { throw DeviceError.preflight("Select a file or folder to delete.") }
        try await run(Timeouts.browse, "delete") { device in
            let afc = try IMobileDevice.startAFC(device: device, root: root)
            defer { afc.close() }
            func remove(_ path: String) throws {
                try Task.checkCancellation()
                let removed = afc_remove_path(afc.client, path)
                if removed.ok { return }
                var names: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                guard afc_read_directory(afc.client, path, &names).ok, let names else {
                    throw DeviceError.afc(.init(code: removed.code))
                }
                var children: [String] = []
                var i = 0
                while let raw = names[i] {
                    i += 1
                    let name = String(cString: raw)
                    if name != "." && name != ".." && !name.isEmpty && !name.contains("/") { children.append(name) }
                }
                _ = afc_dictionary_free(names)
                guard !children.isEmpty else { throw DeviceError.afc(.init(code: removed.code)) }
                for child in children { try remove(path + "/" + child) }
                let again = afc_remove_path(afc.client, path)
                guard again.ok else { throw DeviceError.afc(.init(code: again.code)) }
            }
            try remove(path)
        }
    }

    /// `path` renamed to `name` in the same folder; an item already called that is left alone.
    func rename(_ path: String, to name: String, root: AFCRoot) async throws {
        try Self.validateFilePath(path)
        let parent = (path as NSString).deletingLastPathComponent
        let target = parent.isEmpty ? name : parent + "/" + name
        guard !path.isEmpty, !name.isEmpty, !name.contains("/") else {
            throw DeviceError.preflight("Choose a name without a slash.")
        }
        try Self.validateFilePath(target)
        try await run(Timeouts.query, "rename") { device in
            let afc = try IMobileDevice.startAFC(device: device, root: root)
            defer { afc.close() }
            try Self.refuseExisting(afc.client, target, name)
            let renamed = afc_rename_path(afc.client, path, target)
            guard renamed.ok else { throw DeviceError.afc(.init(code: renamed.code)) }
        }
    }

    func makeFolder(_ path: String, root: AFCRoot) async throws {
        try Self.validateFilePath(path)
        guard !path.isEmpty else { throw DeviceError.preflight("Choose a name for the folder.") }
        try await run(Timeouts.query, "new folder") { device in
            let afc = try IMobileDevice.startAFC(device: device, root: root)
            defer { afc.close() }
            try Self.refuseExisting(afc.client, path, (path as NSString).lastPathComponent)
            let made = afc_make_directory(afc.client, path)
            guard made.ok else { throw DeviceError.afc(.init(code: made.code)) }
        }
    }

    nonisolated static func refuseExisting(_ client: OpaquePointer, _ path: String, _ name: String) throws {
        var info: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        let found = afc_get_file_info(client, path, &info)
        if let info { _ = afc_dictionary_free(info) }
        if found.ok { throw DeviceError.preflight("An item named “\(name)” is already there.") }
    }
}

extension DeviceServices {
    /// The guest's crash reports and how long before the device's own clock now each was written, so a guest whose
    /// clock is not the Mac's still compares with how long it has been up. crashreportmover first moves in the ones
    /// root's processes left waiting (where the guest has it); com.apple.crashreportcopymobile lists them, one level
    /// of folders deep. Before 3.0 lockdownd refuses that service and CrashReportCopyAgent sends them instead
    /// (CrashReportCopy), whole files: with `copyTo`, those are also written into that folder under their own names
    /// (3.0 on, idevicecrashreport copies them). Throws where the guest has neither service.
    func crashReports(copyTo: URL? = nil) async throws -> [String: Double] {
        try await run(Timeouts.browse * 2, "crash reports") { device in
            if let mover = try? IMobileDevice.startService(
                "com.apple.crashreportmover",
                device: device,
                newClient: { service_client_new($0, $1, $2) },
                freeClient: { service_client_free($0) },
                connectError: { DeviceError.lockdown($0) }
            ) {
                // It says "ping" once they are moved; up to 10 s.
                var ping = [CChar](repeating: 0, count: 4)
                for _ in 0..<5 {
                    var count: UInt32 = 0
                    let rc = service_receive_with_timeout(mover, &ping, 4, &count, 2000)
                    if count > 0 || rc != SERVICE_E_TIMEOUT { break }
                }
                _ = service_client_free(mover)
            }
            var now = Date().timeIntervalSince1970
            var lockdown: OpaquePointer?
            if lockdownd_client_new_with_handshake(device, &lockdown, "LightTouchMac").ok, let lockdown {
                var value: plist_t?
                if lockdownd_get_value(lockdown, nil, "TimeIntervalSince1970", &value).ok, let value {
                    if let seconds = IMobileDevice.decode(value) as? Double { now = seconds }
                    plist_free(value)
                }
                _ = lockdownd_client_free(lockdown)
            }
            let client: OpaquePointer
            do {
                client = try IMobileDevice.startService(
                    "com.apple.crashreportcopymobile",
                    device: device,
                    newClient: { afc_client_new($0, $1, $2) },
                    freeClient: { afc_client_free($0) }
                ) { DeviceError.afc(.init(code: $0)) }
            } catch DeviceError.lockdown(let code) {
                // 2.2's lockdownd says InvalidService, 2.1.1's -256.
                let reports: [CrashReportCopy.Report]
                do { reports = try CrashReportCopy.reports(device: device) } catch DeviceError.lockdown {
                    throw DeviceError.lockdown(code)  // neither service
                }
                var ages: [String: Double] = [:]
                for report in reports {
                    ages[report.path] = now - (report.modified?.timeIntervalSince1970 ?? now)
                    // the device names the report: a plain name, made new in the folder (never through a link there)
                    let name = (report.path as NSString).lastPathComponent
                    if let copyTo, !name.isEmpty, !name.hasPrefix("."), !name.contains("/") {
                        try report.data.write(to: copyTo.appendingPathComponent(name), options: .withoutOverwriting)
                    }
                }
                return ages
            }
            defer { _ = afc_client_free(client) }
            var ages: [String: Double] = [:]
            func list(_ path: String, depth: Int) {
                var names: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                guard afc_read_directory(client, path.isEmpty ? "/" : path, &names).ok, let names else { return }
                defer { _ = afc_dictionary_free(names) }
                var i = 0
                while let raw = names[i] {
                    i += 1
                    let name = String(cString: raw)
                    if name.isEmpty || name == "." || name == ".." || name.contains("/") { continue }
                    let child = path.isEmpty ? name : path + "/" + name
                    var values: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                    guard afc_get_file_info(client, child, &values).ok, let values else { continue }
                    var info: [String: String] = [:]
                    var j = 0
                    while let key = values[j], let value = values[j + 1] {
                        info[String(cString: key)] = String(cString: value)
                        j += 2
                    }
                    _ = afc_dictionary_free(values)
                    if info["st_ifmt"] == "S_IFDIR" {
                        if depth > 0 { list(child, depth: depth - 1) }
                    } else if let modified = info["st_mtime"].flatMap(Double.init) {
                        ages[child] = now - modified / 1e9  // nanoseconds
                    }
                }
            }
            list("", depth: 1)
            return ages
        }
    }
}
