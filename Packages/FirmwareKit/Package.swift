// swift-tools-version: 6.0
// FirmwareKit: IPSW -> emulated device preparation.
// Swift owns device preparation. Tests use frozen reference hashes and
// optional corpus inputs; strict acceptance fails when selected prerequisites are absent. Each module lives in its own
// subdirectory of Sources/FirmwareKit so agents can add modules without editing this file.
//
// Dependencies are pinned to exact versions and recorded with their licenses in build-support/dependencies.json
// (BuildTools' dependency sources manifest): ZIPFoundation (IPSW members), swift-subprocess (`diskutil image` /
// `hdiutil` through DiskImage), Unrar.swift (a "rar" source's IPSW: RARLAB's UnRAR, extraction only),
// swift-argument-parser (the firmwarekit command lines, FirmwareSchema's FirmwareCommand), swift-binary-parsing (the
// firmware formats' readers) and swift-crypto (digests and HMAC, CryptoKit itself on Apple platforms; AES-CBC through
// CryptoExtras).
import PackageDescription

let package = Package(
    name: "FirmwareKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FirmwareKit", targets: ["FirmwareKit"]),
        .library(name: "FirmwareSchema", type: .static, targets: ["FirmwareSchema"]),
        .executable(name: "firmwarekit", targets: ["FirmwareKitCLI"]),
        .executable(name: "firmwarekit-prepare", targets: ["FirmwareKitPrepare"]),
        .executable(name: "firmwarekit-provision-guest-tools", targets: ["FirmwareKitProvisionGuestTools"])
    ],
    dependencies: [
        .package(path: "../HostRuntime"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.2"),
        .package(url: "https://github.com/mtgto/Unrar.swift.git", exact: "0.5.4"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/apple/swift-binary-parsing.git", exact: "0.0.4"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3")
    ],
    targets: [
        .target(
            name: "FirmwareSchema",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .target(name: "CActivation", cSettings: [.define("LT_ACTIVATION_LIBRARY")]),
        .target(
            name: "FirmwareKit",
            dependencies: [
                "CActivation", "FirmwareSchema",
                .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "Unrar", package: "Unrar.swift"),
                .product(name: "BinaryParsing", package: "swift-binary-parsing"),
                .product(name: "Crypto", package: "swift-crypto"),
                // AES-CBC off Apple platforms (AESCBC: CommonCrypto on them, which keeps BoringSSL out of the app)
                .product(
                    name: "CryptoExtras", package: "swift-crypto",
                    condition: .when(platforms: [.linux, .windows, .android, .openbsd]))
            ]
        ),
        .executableTarget(
            name: "FirmwareKitCLI",
            dependencies: [
                "FirmwareKit",
                .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(name: "FirmwareKitPrepare", dependencies: ["FirmwareKit"]),
        .executableTarget(name: "FirmwareKitProvisionGuestTools", dependencies: ["FirmwareKit"]),
        .testTarget(
            name: "FirmwareKitTests",
            dependencies: [
                "FirmwareKit", "FirmwareSchema", .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            exclude: ["iboot-trees"]  // KBootIBootTests reads them from the source tree
        )
    ]
)
