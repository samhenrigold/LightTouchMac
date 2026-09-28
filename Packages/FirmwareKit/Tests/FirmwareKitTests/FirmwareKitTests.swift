import Testing
@testable import FirmwareKit

@Test func versionIsSet() { #expect(!FirmwareKit.version.isEmpty) }
