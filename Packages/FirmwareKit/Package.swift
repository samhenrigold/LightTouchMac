// swift-tools-version: 6.0
// FirmwareKit: IPSW -> emulated device preparation (docs/multi-device-plan.md, section E and
// "Preparer contract"). The Python imgtools in qemu-ios are the oracle; tests read fixtures from
// ~/Developer/qemu-ios-files and skip when they are absent. Each module lives in its own
// subdirectory of Sources/FirmwareKit so agents can add modules without editing this file.
import PackageDescription

let package = Package(
    name: "FirmwareKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FirmwareKit", targets: ["FirmwareKit"]),
        .executable(name: "firmwarekit", targets: ["FirmwareKitCLI"]),
    ],
    targets: [
        .target(name: "CActivation", cSettings: [.define("LT_ACTIVATION_LIBRARY")]),
        .target(name: "FirmwareKit", dependencies: ["CActivation"]),
        .executableTarget(name: "FirmwareKitCLI", dependencies: ["FirmwareKit"]),
        .testTarget(name: "FirmwareKitTests", dependencies: ["FirmwareKit"]),
    ]
)
