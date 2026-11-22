import CIMobileDevice
import Foundation
import HostServiceWire
import Testing

@testable import Engine

extension SharedState {
    /// The Files browser's listing (LightTouchServices/Engine/AFC.swift files(in:)) over the fake libimobiledevice: an
    /// entry whose file info isn't found is left out, as iPhone OS 1.x's afcd answers for /mach, a link to the
    /// mach_kernel the device doesn't ship, when afc2 lists "/".
    @Suite struct EngineDanglingLinkTests {
        @Test func aLinkToNothingIsLeftOutOfTheListing() async throws {
            let saved = (IMDFake.ideviceNew, IMDFake.afcClientNew, IMDFake.afcReadDirectory, IMDFake.afcFileInfo)
            defer { (IMDFake.ideviceNew, IMDFake.afcClientNew, IMDFake.afcReadDirectory, IMDFake.afcFileInfo) = saved }
            Attachment.install()
            func strings(_ list: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
                let out = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: list.count + 1)
                for (i, s) in list.enumerated() { out[i] = strdup(s) }
                out[list.count] = nil
                return out
            }
            IMDFake.afcClientNew = { _, _, out in
                out?.pointee = OpaquePointer(bitPattern: 0x50)
                return AFC_E_SUCCESS
            }
            IMDFake.afcReadDirectory = { _, p, out in
                guard String(cString: p!) == "/" else { return AFC_E_OBJECT_NOT_FOUND }
                out?.pointee = strings([".", "..", "Applications", "mach", "private"])
                return AFC_E_SUCCESS
            }
            IMDFake.afcFileInfo = { _, p, out in
                guard String(cString: p!) != "mach" else { return AFC_E_OBJECT_NOT_FOUND }
                out?.pointee = strings(["st_ifmt", "S_IFDIR"])
                return AFC_E_SUCCESS
            }
            let listed = try await DeviceServices(clientSocket: "fixture").files(in: "", root: .fileSystem)
            #expect(listed.map(\.name) == ["Applications", "private"])
        }
    }
}
