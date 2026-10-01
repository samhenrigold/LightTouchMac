// swift-tools-version: 6.0
// FirmwareKit: IPSW -> emulated device preparation (docs/multi-device-plan.md, section E and
// "Preparer contract"). Swift owns device preparation. Tests use frozen reference hashes and
// optional corpus inputs; strict acceptance fails when selected prerequisites are absent. Each module lives in its own
// subdirectory of Sources/FirmwareKit so agents can add modules without editing this file.
//
// Dependencies are pinned to exact versions and recorded with their licenses in build-support/dependencies.json
// (scripts/dependency-sources.py's manifest): ZIPFoundation (IPSW members), MachOKit (Mach-O headers, fat
// files, code signatures), swift-subprocess (`diskutil image` / `hdiutil` through DiskImage).
import PackageDescription

let package = Package(
    name: "FirmwareKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FirmwareKit", targets: ["FirmwareKit"]),
        .executable(name: "firmwarekit", targets: ["FirmwareKitCLI"]),
    ],
    dependencies: [
        .package(path: "../HostRuntime"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/p-x9/MachOKit.git", exact: "0.53.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.0"),
    ],
    targets: [
        .target(name: "FirmwareSchema"),
        .target(name: "CActivation", cSettings: [.define("LT_ACTIVATION_LIBRARY")]),
        .target(name: "FirmwareKit", dependencies: [
            "CActivation", "FirmwareSchema",
            .product(name: "HostRuntime", package: "HostRuntime"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            .product(name: "MachOKit", package: "MachOKit"),
            .product(name: "Subprocess", package: "swift-subprocess"),
        ]),
        .executableTarget(name: "FirmwareKitCLI", dependencies: ["FirmwareKit",
            .product(name: "HostRuntime", package: "HostRuntime"),
        ]),
        .testTarget(name: "FirmwareKitTests", dependencies: ["FirmwareKit"]),
    ]
)
