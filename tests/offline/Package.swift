// swift-tools-version: 6.2
// OfflineChecks: Swift Testing over code that lives in the app's executable targets (the app, the helper, the services
// worker), which no package exports. Each fixture target under Sources/ holds symlinks to the production files it
// tests, compiled whole, beside the stand-ins for what those files reach into (the hub classes, the C library);
// OfflineTests drives them. No window is ordered in, no emulator runs. The Unit test plan runs it.
import PackageDescription

let settings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances")
]

/// The vendored, patched libimobiledevice and libplist headers (build/vendor, the link scripts/vendor-check points at
/// the current pins' vendor directory), for the modules that import the engine.
let vendorInclude = Context.packageDirectory + "/../../build/vendor/include"
let imobiledevice = ["-Xcc", "-I" + vendorInclude]

let package = Package(
    name: "OfflineChecks",
    platforms: [.macOS("14.4")],
    dependencies: [
        .package(path: "../../Packages/LightTouchCore"),
        .package(path: "../../Packages/HostRuntime"),
        .package(path: "../../Packages/DeviceRuntime"),
        .package(path: "../../Packages/DeviceServices"),
        .package(path: "../../Packages/FirmwareKit")
    ],
    targets: [
        // The app's views and windows that stand alone: production files whole, with the stand-ins in StandIns.swift.
        .target(
            name: "AppViews",
            dependencies: [
                .product(name: "LightTouchCore", package: "LightTouchCore"),
                .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "HostServiceClient", package: "DeviceServices"),
                .product(name: "HostServiceWire", package: "DeviceServices")
            ],
            swiftSettings: settings
        ),
        // The sidebar and the Add Device sheet over a stand-in session host, jobs and library.
        .target(
            name: "Sidebar",
            dependencies: [
                .product(name: "LightTouchCore", package: "LightTouchCore"),
                .product(name: "FirmwareSchema", package: "FirmwareKit"),
                .product(name: "HostRuntime", package: "HostRuntime")
            ],
            swiftSettings: settings
        ),
        // The real main menu over no-op action targets.
        .target(
            name: "Menus",
            dependencies: [
                .product(name: "LightTouchCore", package: "LightTouchCore"),
                .product(name: "HostRuntime", package: "HostRuntime")
            ],
            swiftSettings: settings
        ),
        // DisplayView (the device screen) over a fake link and device, with a stand-in 3D model.
        .target(
            name: "Display",
            dependencies: [
                .product(name: "LightTouchCore", package: "LightTouchCore"),
                .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "DeviceRuntime", package: "DeviceRuntime")
            ],
            swiftSettings: settings
        ),
        // The 3D model (RealityKit), for headless renders.
        .target(
            name: "Model",
            dependencies: [
                .product(name: "LightTouchCore", package: "LightTouchCore"),
                .product(name: "HostRuntime", package: "HostRuntime")
            ],
            swiftSettings: settings
        ),
        // The helper's (LightTouchDevice's) own code that stands alone: the libqemu binding.
        .target(
            name: "Helper",
            dependencies: [
                .product(name: "DeviceRuntime", package: "DeviceRuntime"),
                .product(name: "HostRuntime", package: "HostRuntime")
            ],
            swiftSettings: settings
        ),
        // The helper's web proxy (WebProxy.swift and what it reaches: GuestTLS.c as CGuestTLS for its bridging header),
        // compiled as the helper target is, nonisolated in Swift 6.
        .target(name: "CGuestTLS"),
        .target(
            name: "HelperProxy",
            dependencies: [
                "CGuestTLS",
                .product(name: "DeviceRuntime", package: "DeviceRuntime"),
                .product(name: "HostRuntime", package: "HostRuntime")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6), .unsafeFlags(["-Xfrontend", "-import-module", "-Xfrontend", "CGuestTLS"])
            ]
        ),
        // The services helper's engine (LightTouchServices/Engine) over a libimobiledevice of the tests' own
        // (tests/fixtures/imobiledevice-fake.swift), with the vendored libimobiledevice's headers.
        .target(
            name: "CIMobileDevice",
            cSettings: [.unsafeFlags(["-I" + vendorInclude])]
        ),
        .target(
            name: "Engine",
            dependencies: ["CIMobileDevice", .product(name: "HostServiceWire", package: "DeviceServices")],
            swiftSettings: settings + [
                .unsafeFlags(imobiledevice + ["-Xfrontend", "-import-module", "-Xfrontend", "CIMobileDevice"])
            ]
        ),
        // A private home and app state for the test process (LightTouchCore's own, Tests/TestIsolation).
        .target(name: "OfflineIsolation"),
        .testTarget(
            name: "OfflineTests",
            dependencies: [
                "AppViews", "Display", "Engine", "Helper", "HelperProxy", "Menus", "Model", "Sidebar",
                "OfflineIsolation",
                .product(name: "DeviceRuntime", package: "DeviceRuntime")
            ],
            swiftSettings: settings + [.unsafeFlags(imobiledevice)]
        )
    ],
    swiftLanguageModes: [.v5]
)
