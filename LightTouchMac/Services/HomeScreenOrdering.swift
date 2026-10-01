import Foundation

extension DeviceServices {
    @discardableResult
    func moveOnHomeScreen(_ bundleID: String, before other: String?, profile: DeviceProfile) async throws -> [String] {
        try await moveOnHomeScreen(bundleID, before: other, deviceName: profile.shortName)
    }
}
