// How iPhone OS 1 and 2 serve their crash reports: CrashReportCopyAgent (com.apple.crashreportcopy), a DeviceLink
// protocol, where 3.0 and later have com.apple.crashreportcopymobile's AFC (DeviceServices.crashReports).

import Foundation
import HostServiceWire

nonisolated extension property_list_service_error_t: IMobileDeviceResult {}

nonisolated enum CrashReportCopy {
    /// One report as the agent sent it: its path under the destination the request named, when the device last
    /// modified it, and its bytes.
    struct Report {
        var path: String
        var modified: Date?
        var data = Data()
    }

    /// What one pass takes, at most: the guest chooses how many reports it sends and how long they are, and a
    /// running device is asked every minute. Past either, the pass stops with the whole reports it has.
    static let maxReports = 256
    static let maxBytes = 32 << 20

    /// Every report the agent has: the .plist, .log and .zip files (and the baseband's log-bb-*) in root's and
    /// mobile's CrashReporter folders, each sent with DLSendFile on a SendNewCrashLogs request, then
    /// CrashReportDoneCopying. Nothing is marked as sent (MarkCrashLogAsSent), which would delete it on the device.
    /// Throws DeviceError.lockdown where lockdownd doesn't start the service.
    static func reports(device: OpaquePointer) throws -> [Report] {
        let client = try IMobileDevice.startService(
            "com.apple.crashreportcopy",
            device: device,
            newClient: { property_list_service_client_new($0, $1, $2) },
            freeClient: { property_list_service_client_free($0) },
            connectError: { DeviceError.lockdown($0) }
        )
        defer { _ = property_list_service_client_free(client) }
        func send(_ message: [Any]) throws {
            guard let node = IMobileDevice.encode(message) else {
                throw DeviceError.failed("crashreportcopy: unencodable message")
            }
            defer { plist_free(node) }
            let rc = property_list_service_send_binary_plist(client, node)
            guard rc.ok else { throw DeviceError.failed("crashreportcopy: send \(rc.rawValue)") }
        }
        func receive(_ seconds: UInt32 = 15) throws -> [Any] {
            var node: plist_t?
            let rc = property_list_service_receive_plist_with_timeout(client, &node, seconds * 1000)
            guard rc.ok, let node else { throw DeviceError.failed("crashreportcopy: receive \(rc.rawValue)") }
            defer { plist_free(node) }
            guard let message = IMobileDevice.decode(node) as? [Any] else {
                throw DeviceError.failed("crashreportcopy: not a message")
            }
            return message
        }
        // DeviceLink's handshake: the device offers its version, the host accepts it, the device says it is ready.
        let offer = try receive()
        guard offer.first as? String == "DLMessageVersionExchange", offer.count > 1 else {
            throw DeviceError.failed("crashreportcopy: no version exchange: \(offer)")
        }
        try send(["DLMessageVersionExchange", "DLVersionsOk", offer[1]])
        guard try receive().first as? String == "DLMessageDeviceReady" else {
            throw DeviceError.failed("crashreportcopy: not ready")
        }
        // GetSysInfo is where the agent gathers the files (SysInfoReply carries their CrashLogCountKey);
        // SendNewCrashLogs alone sends none.
        try send(["DLMessageProcessMessage", ["CrashReportRequest": "GetSysInfo"]])
        let info = try receive()
        guard ((info.count > 1 ? info[1] : nil) as? [String: Any])?["CrashReportReply"] as? String == "SysInfoReply"
        else { throw DeviceError.failed("crashreportcopy: no SysInfoReply: \(info.first ?? "")") }
        try send([
            "DLMessageProcessMessage",
            ["CrashReportRequest": "SendNewCrashLogs", "FileDestPath": "CrashReporter"]
        ])
        var reports: [String: Report] = [:]
        var received = 0
        reading: while true {
            let message = try receive()
            switch message.first as? String {
            case "DLSendFile":
                // A file in hunks: its bytes, then where it goes and its attributes.
                guard message.count > 2, let info = message[2] as? [String: Any],
                    let path = info["DLFileDest"] as? String
                else { continue }
                let hunk = message[1] as? Data ?? Data()
                received += hunk.count
                guard received <= maxBytes, reports[path] != nil || reports.count < maxReports else {
                    reports[path] = nil  // cut short
                    break reading
                }
                let attributes = info["DLFileAttributesKey"] as? [String: Any]
                var report = reports[path] ?? Report(path: path)
                if info["DLFileOffsetKey"] as? Int == 0 { report.data = Data() }
                report.data += hunk
                // The agent's dates count from 1970 where a plist's count from 2001: 31 years late as read (a report
                // written at 18:17:20Z on 2026-10-20 reads 2057-10-20 18:17:20Z).
                if let date = attributes?["ModificationTime"] as? Date {
                    report.modified = date.addingTimeInterval(-Date.timeIntervalBetween1970AndReferenceDate)
                }
                reports[path] = report
                // The last hunk (status 2) waits for the host's word before the next file. "CouldntSaveFile" keeps
                // the report on the device (a plain MarkCrashLogAsSent deletes it) and moves on all the same.
                if info["DLFileStatusKey"] as? Int == 2 {
                    try send([
                        "DLMessageProcessMessage",
                        [
                            "CrashReportRequest": "MarkCrashLogAsSent", "CrashReportLogPath": path,
                            "kPTCrashReportErrorKey": "CouldntSaveFile"
                        ]
                    ])
                }
            case "DLMessageProcessMessage":
                let reply = message.count > 1 ? message[1] as? [String: Any] : nil
                if reply?["CrashReportReply"] as? String == "CrashReportError" {
                    throw DeviceError.failed("crashreportcopy: \(reply ?? [:])")
                }
                if reply?["CrashReportReply"] as? String == "CrashReportDoneCopying" { break reading }
            case "DLMessageDisconnect": break reading
            default: continue
            }
        }
        try? send(["DLMessageDisconnect", "All done, thanks for the memories"])
        return reports.values.sorted { $0.path < $1.path }
    }
}
