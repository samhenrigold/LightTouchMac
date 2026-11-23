import Foundation
import Testing

@testable import LightTouchCore

/// Install Package… is offered on the first iPhone OS only: the iPhone 2G's and iPod touch's 1.x rows, not 2.0 on,
/// where apps install as IPAs.
struct InstallsPackagesTests {
    @Test func theFirstGenerationsOneXRowsInstallPackages() {
        _ = ShippedResources.machines
        let catalog = ShippedResources.catalog
        for id in ["n45ap-4A102", "m68ap-1A543a", "n45ap-3A101a"] {
            #expect(DeviceFeatures.installsPackages(catalog.entry(id: id)!), "\(id)")
        }
        for id in ["n72ap-7E18", "n88ap-10B500", "k48ap-7B500"] {
            #expect(!DeviceFeatures.installsPackages(catalog.entry(id: id)!), "\(id)")
        }
        let oneX = catalog.entries.filter { DeviceFeatures.installsPackages($0) }
        #expect(!oneX.isEmpty && oneX.allSatisfy { $0.major == 1 && !$0.managesApps })
    }
}
