import Foundation
import Testing
@testable import FirmwareKit

struct StorageCapacityTests {
    @Test(arguments: [Int64?.none, Int64?(0), Int64?(-1)])
    func unavailableImportantUsageFallsBack(_ important: Int64?) throws {
        let available = try StorageCapacity.available(important: { important }, physical: { 458 << 30 })
        #expect(available == 458 << 30)
        try StorageCapacity.require(20 << 30, available: available)
    }

    @Test func positiveImportantUsageKeepsReclaimableSpace() throws {
        let available = try StorageCapacity.available(important: { 100 }, physical: {
            throw FirmwareError(.internal, "physical query should not run")
        })
        #expect(available == 100)
    }

    @Test func trulyFullVolumeStillRefusesPreparation() throws {
        let available = try StorageCapacity.available(important: { 0 }, physical: { 0 })
        #expect(available == 0)
        #expect(throws: FirmwareError.self) { try StorageCapacity.require(1, available: available) }
    }

    @Test func unavailablePhysicalCapacityDoesNotPretendSpaceExists() {
        #expect(throws: FirmwareError.self) {
            try StorageCapacity.available(important: { nil }, physical: { throw FirmwareError(.internal, "unavailable") })
        }
    }

    @Test func existingDestinationCapacityIsReadable() throws {
        let dir = try Fixtures.tempDir("capacity")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try StorageCapacity.available(at: dir) >= 0)
        try StorageCapacity.require(0, at: dir)
    }
}
