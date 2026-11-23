// iPhone OS 1.x's library write, as iTunes syncs (libgpod's itdb_iphone_start_sync and stop_sync): syncWillStart
// through notification_proxy, the Media folder's com.apple.itunes.lock_sync locked, syncDidStart, the file written
// whole and renamed over the old one, then the lock released and syncDidFinish, which has a running Music load the
// library again.

import Foundation
import HostServiceWire

extension DeviceServices {
    func syncLibraryFile(_ source: URL, remote: String) async throws {
        try Self.validateFilePath(remote)
        let data = try Data(contentsOf: source)
        try await run(Timeouts.stage, "library sync") { device in
            func post(_ name: String) throws {
                var proxy: OpaquePointer?
                guard np_client_start_service(device, &proxy, "LightTouchMac").ok, let proxy else {
                    throw DeviceError.failed("The device's notification service didn't start.")
                }
                defer { _ = np_client_free(proxy) }
                guard np_post_notification(proxy, name).ok else {
                    throw DeviceError.failed("The device didn't take the \(name) notification.")
                }
            }
            let afc = try IMobileDevice.startAFC(device: device)
            defer { afc.close() }
            let client = afc.client
            try post("com.apple.itunes-mobdev.syncWillStart")
            var lock: UInt64 = 0
            let opened = afc_file_open(client, "/com.apple.itunes.lock_sync", AFC_FOPEN_RW, &lock)
            guard opened.ok else {
                try? post("com.apple.itunes-mobdev.syncFailedToStart")
                throw DeviceError.afc(.init(code: opened.code))
            }
            defer { _ = afc_file_close(client, lock) }
            try post("com.apple.itunes-mobdev.syncLockRequest")
            var locked = afc_file_lock(client, lock, AFC_LOCK_EX)
            for _ in 0..<50 where locked == AFC_E_OP_WOULD_BLOCK {
                try Task.checkCancellation()
                usleep(200_000)
                locked = afc_file_lock(client, lock, AFC_LOCK_EX)
            }
            guard locked.ok else {
                try? post("com.apple.itunes-mobdev.syncFailedToStart")
                throw DeviceError.afc(.init(code: locked.code))
            }
            defer { _ = afc_file_lock(client, lock, AFC_LOCK_UN) }
            try post("com.apple.itunes-mobdev.syncDidStart")
            var parent = ""
            for component in remote.split(separator: "/").dropLast() {
                parent = parent.isEmpty ? String(component) : parent + "/" + component
                _ = afc_make_directory(client, parent)
            }
            // Written aside and renamed, so an interrupted write never leaves a torn library.
            let temporary = remote + ".lt-sync-" + UUID().uuidString
            var handle: UInt64 = 0
            let created = afc_file_open(client, temporary, AFC_FOPEN_WRONLY, &handle)
            guard created.ok else { throw DeviceError.afc(.init(code: created.code)) }
            var complete = false
            defer { if !complete { _ = afc_remove_path(client, temporary) } }
            var written = 0
            var failure: afc_error_t = AFC_E_SUCCESS
            data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return }
                while written < raw.count {
                    var count: UInt32 = 0
                    let rc = afc_file_write(
                        client, handle, base + written, UInt32(min(1 << 16, raw.count - written)), &count)
                    guard rc.ok, count > 0 else {
                        failure = rc.ok ? AFC_E_IO_ERROR : rc
                        return
                    }
                    written += Int(count)
                }
            }
            _ = afc_file_close(client, handle)
            guard failure.ok, written == data.count else { throw DeviceError.afc(.init(code: failure.code)) }
            let renamed = afc_rename_path(client, temporary, remote)
            guard renamed.ok else { throw DeviceError.afc(.init(code: renamed.code)) }
            complete = true
            _ = afc_file_lock(client, lock, AFC_LOCK_UN)
            try post("com.apple.itunes-mobdev.syncDidFinish")
        }
    }
}
