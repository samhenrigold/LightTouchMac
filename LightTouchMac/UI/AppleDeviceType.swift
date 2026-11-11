import Cocoa
import UniformTypeIdentifiers

public nonisolated struct AppleDeviceType: Hashable, Sendable, CustomStringConvertible {
    public let modelIdentifier: String
    public let contentType: UTType

    public init?(
        _ modelIdentifier: String,
        conformingTo supertype: UTType? = nil
    ) {
        guard
            !modelIdentifier.isEmpty,
            let contentType = UTType(
                tag: modelIdentifier,
                tagClass: .appleDeviceModelCode,
                conformingTo: supertype
            ),
            contentType.isDeclared
        else {
            return nil
        }

        self.modelIdentifier = modelIdentifier
        self.contentType = contentType
    }

    public var identifier: String {
        contentType.identifier
    }

    public var localizedName: String? {
        contentType.localizedDescription
    }

    public var modelCodes: [String] {
        contentType.tags[.appleDeviceModelCode] ?? []
    }

    public var icon: NSImage {
        NSWorkspace.shared.icon(for: contentType)
    }

    public var description: String {
        localizedName ?? identifier
    }
}

extension UTTagClass {
    fileprivate nonisolated static var appleDeviceModelCode: UTTagClass {
        UTTagClass(rawValue: "com.apple.device-model-code")
    }
}
