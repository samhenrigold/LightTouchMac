// Where the guest runs httpget (contrib/it-proxy) for the Wi-Fi and proxy checks: the copy its preparation baked into
// the system image, where there is one, else the host's build put to /tmp. The iPhone 5's (14G61) root is read-only
// and its sandbox lets it_agent exec only from the system volume, so a put there could never run.
import Foundation

@testable import LightTouchCore

extension GuestAgent {
    static let bakedHTTPGet = "/usr/local/bin/ltm-httpget"

    /// The guest path of an httpget to spawn: the baked one, or `bytes` put to /tmp/ltm-httpget.
    func httpget(_ bytes: Data) async throws -> String {
        // An agent too old for `get` throws: it has no baked copy either.
        if (try? await get(Self.bakedHTTPGet, limit: 1 << 20)) != nil { return Self.bakedHTTPGet }
        try await put("/tmp/ltm-httpget", mode: 0o755, bytes)
        return "/tmp/ltm-httpget"
    }
}
