// swift-tools-version: 6.2
// The emulator-backed checks: the app's session code driving real helpers and guests, headless and silent.
//
//     swift run --package-path tests/sessions sessions <check> ... (sessions --help)
//
// `sessions` builds or takes the helper, runs a driver, judges its events and exits 1 on any FAIL. The drivers stand
// in for the app: session-driver (DeviceSessionProcess, BootRecipe, DeviceServices and the guest agent, as the app's
// sessions run them) and helper-driver (DeviceLink straight to the helper: scripted input, the modem, the pump).
// SessionKit holds what can be judged without an emulator (frame references, the home verdict, the Setup walks'
// page logic); its tests run in the Unit plan.
import PackageDescription

let driver: [SwiftSetting] = [.defaultIsolation(MainActor.self), .swiftLanguageMode(.v5)]
let parser: Target.Dependency = .product(name: "ArgumentParser", package: "swift-argument-parser")

let package = Package(
    name: "Sessions",
    platforms: [.macOS("14.4")],
    dependencies: [
        .package(path: "../../Packages/LightTouchCore"),
        .package(path: "../../Packages/HostRuntime"),
        .package(path: "../../Packages/DeviceRuntime"),
        .package(path: "../../Packages/DeviceServices"),
        .package(path: "../../Packages/FirmwareKit"),
        .package(path: "../../Packages/BuildTools"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2")
    ],
    targets: [
        .target(name: "SessionKit"),
        .executableTarget(
            name: "sessions",
            dependencies: [
                "SessionKit", parser, .product(name: "BuildSupport", package: "BuildTools"),
                .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "LightTouchCore", package: "LightTouchCore"),
                .product(name: "FirmwareSchema", package: "FirmwareKit"),
                .product(name: "FirmwareKit", package: "FirmwareKit")
            ]
        ),
        .executableTarget(
            name: "session-driver",
            dependencies: [
                "SessionKit",
                .product(name: "LightTouchCore", package: "LightTouchCore"),
                .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "DeviceRuntime", package: "DeviceRuntime"),
                .product(name: "HostServiceClient", package: "DeviceServices"),
                .product(name: "HostServiceWire", package: "DeviceServices"),
                .product(name: "FirmwareSchema", package: "FirmwareKit"),
                .product(name: "FirmwareKit", package: "FirmwareKit"),
                parser
            ],
            swiftSettings: driver
        ),
        .executableTarget(
            name: "helper-driver",
            dependencies: [
                "SessionKit",
                .product(name: "LightTouchCore", package: "LightTouchCore"),
                .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "DeviceRuntime", package: "DeviceRuntime"),
                .product(name: "HostServiceClient", package: "DeviceServices"),
                .product(name: "HostServiceWire", package: "DeviceServices"),
                parser
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "SessionKitTests", dependencies: ["SessionKit"])
    ]
)
