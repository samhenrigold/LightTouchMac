import Foundation
import HostServiceWire

@testable import LightTouchCore

/// `single --replug`: the cable (the helper's usbConnection, the machine's usb-attached) pulled until lockdown stops
/// answering over the device's usbmuxd, then plugged until it answers again, and one AFC round trip over the new link.
@MainActor func replug(_ d: Device, slow: Double) async {
    var event: [String: Any] = ["device": d.name]
    func cable(_ attached: Bool) async -> Bool {
        guard case .ok(true)? = try? await d.process.link.request(.usbConnection(attached)) else {
            event["error"] = "usbConnection(\(attached)) refused"
            return false
        }
        return true
    }
    func wait(answering: Bool, _ seconds: Double) async -> Double? {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds, !d.process.isDead {
            if (await d.productType() != nil) == answering { return Date().timeIntervalSince(start) }
            try? await Task.sleep(for: .seconds(1))
        }
        return nil
    }
    defer { emit("replug", event) }
    guard await cable(false) else { return }
    event["gone"] = await wait(answering: false, 60 * slow)
    guard await cable(true) else { return }
    event["back"] = await wait(answering: true, 120 * slow)
    let name = "ltm-replug.bin"
    let local = d.dir.appendingPathComponent(name)
    let back = d.dir.appendingPathComponent("back-" + name)
    let bytes = Data((0..<16385).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) })
    defer {
        try? FileManager.default.removeItem(at: local)
        try? FileManager.default.removeItem(at: back)
    }
    do {
        try bytes.write(to: local)
        try await d.services.uploadFile(local, into: "") { _ in }
        guard let file = try await d.services.files(in: "").first(where: { $0.name == name }) else {
            throw DeviceError.preflight("\(name) not listed")
        }
        try await d.services.download(file, to: back) { _ in }
        event["same"] = try Data(contentsOf: back) == bytes
        await d.services.removeStaged(name)
    } catch { event["error"] = "\(error)" }
}
