import CIMobileDevice
import Foundation
import Testing

@testable import Engine

extension SharedState {
    /// iPhone OS 1 and 2's crash reports (LightTouchServices/Engine/CrashReportCopy.swift) over the fake
    /// libimobiledevice: the guest decides how many reports CrashReportCopyAgent sends and how long they are, so one
    /// pass keeps no more than CrashReportCopy's caps.
    @Suite struct EngineCrashReportTests {
        /// A device that sends `files` reports of `hunks` hunks of `hunkBytes` each, then says it is done.
        static func reports(files: Int, hunks: Int, hunkBytes: Int) throws -> [CrashReportCopy.Report] {
            let saved = (IMDFake.plistServiceNew, IMDFake.plistServiceSend, IMDFake.plistServiceReceive)
            defer { (IMDFake.plistServiceNew, IMDFake.plistServiceSend, IMDFake.plistServiceReceive) = saved }
            var script: [Any] = [
                ["DLMessageVersionExchange", 300], ["DLMessageDeviceReady"],
                ["DLMessageProcessMessage", ["CrashReportReply": "SysInfoReply"]]
            ]
            let hunk = Data(count: hunkBytes)
            for file in 0..<files {
                for part in 0..<hunks {
                    let info: [String: Any] = [
                        "DLFileDest": "CrashReporter/r\(file).plist", "DLFileOffsetKey": part * hunkBytes,
                        "DLFileStatusKey": part == hunks - 1 ? 2 : 1
                    ]
                    script.append(["DLSendFile", hunk, info])
                }
            }
            script.append(["DLMessageProcessMessage", ["CrashReportReply": "CrashReportDoneCopying"]])
            nonisolated(unsafe) var next = 0
            IMDFake.plistServiceNew = { _, _, out in
                out?.pointee = OpaquePointer(bitPattern: 0x60)
                return PROPERTY_LIST_SERVICE_E_SUCCESS
            }
            IMDFake.plistServiceSend = { _, _ in PROPERTY_LIST_SERVICE_E_SUCCESS }
            IMDFake.plistServiceReceive = { _, out, _ in
                guard next < script.count else { return PROPERTY_LIST_SERVICE_E_RECEIVE_TIMEOUT }
                out?.pointee = IMDFake.node(script[next])
                next += 1
                return PROPERTY_LIST_SERVICE_E_SUCCESS
            }
            return try CrashReportCopy.reports(device: OpaquePointer(bitPattern: 17)!)
        }

        @Test func aFewReportsComeWhole() throws {
            let got = try Self.reports(files: 3, hunks: 2, hunkBytes: 1000)
            #expect(got.map(\.path) == (0..<3).map { "CrashReporter/r\($0).plist" })
            #expect(got.allSatisfy { $0.data.count == 2000 })
        }

        @Test func moreReportsThanTheCapStopAtIt() throws {
            let got = try Self.reports(files: CrashReportCopy.maxReports + 50, hunks: 1, hunkBytes: 10)
            #expect(got.count == CrashReportCopy.maxReports)
        }

        /// The report the cap falls in is dropped, not kept cut short.
        @Test func moreBytesThanTheCapStopAtTheReportBefore() throws {
            let got = try Self.reports(files: 3, hunks: 24, hunkBytes: 1 << 20)
            #expect(got.reduce(0) { $0 + $1.data.count } <= CrashReportCopy.maxBytes)
            #expect(got.map(\.data.count) == [24 << 20])
        }
    }
}
