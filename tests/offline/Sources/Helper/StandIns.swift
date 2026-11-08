// What DeviceHost.swift reaches beyond the files linked here: main.swift's launch and WebProxy.swift's proxy. The
// tests boot no QEMU, so neither does anything.
import Foundation
import HostRuntime

/// main.swift's launch: a helper that holds no lease.
let launch = HelperLaunch(.machines)

/// WebProxy.swift's proxy, as DeviceHost.boot drives it.
final class WebProxy: @unchecked Sendable {
    var offline = false
    var localNetwork = true

    init(config: URL) {}

    func listen(socket path: String) throws {}

    func serve(passedOver fd: Int32) {}
}
