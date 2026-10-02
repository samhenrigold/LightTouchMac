// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DeviceRuntime", platforms: [.macOS(.v13)],
    products: [.library(name: "DeviceRuntime", type: .static, targets: ["DeviceRuntime"])],
    dependencies: [.package(path: "../Packages/HostRuntime")],
    targets: [
        .target(name: "LTMLinkC", path: "CLink", publicHeadersPath: "."),
        .target(name: "DeviceRuntime", dependencies: ["HostRuntime", "LTMLinkC"], path: ".",
            exclude: ["CLink", "WebProxyCA.swift"],
            sources: ["DeviceLink.swift", "DeviceLinkProtocol.swift", "DeviceRendezvous.swift", "SharedStatus.swift", "DeviceSessionProcess.swift"])
    ], swiftLanguageModes: [.v5])
