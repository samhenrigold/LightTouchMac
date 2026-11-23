// swift-tools-version: 6.0
// One device's host services (installation_proxy, AFC, springboardservices, notification_proxy, lockdown reads).
// HostServiceWire: what the app and the services helper share (the typed request/event protocol, errors, paths).
// HostServiceClient: the app's side, which runs every operation in a LightTouchServices process per endpoint.
// The engine that calls libimobiledevice is the LightTouchServices target's own (LightTouchServices/Engine): it
// links the vendored C library, which a package can't see.
import PackageDescription

let package = Package(
    name: "DeviceServices",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HostServiceWire", type: .static, targets: ["HostServiceWire"]),
        .library(name: "HostServiceClient", type: .static, targets: ["HostServiceClient"])
    ],
    dependencies: [
        .package(path: "../HostRuntime"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.2")
    ],
    targets: [
        .target(name: "HostServiceWire"),
        .target(
            name: "HostServiceClient",
            dependencies: [
                "HostServiceWire",
                .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "Subprocess", package: "swift-subprocess")
            ]
        ),
        .testTarget(name: "HostServiceWireTests", dependencies: ["HostServiceWire"]),
        .testTarget(name: "HostServiceClientTests", dependencies: ["HostServiceClient"])
    ]
)
