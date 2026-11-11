import Foundation

extension SideloadTools {
    /// The installation helper is explicitly selected by the preparation recipe.
    /// Modern installd carries a zero-sized dyld restriction marker which would
    /// silently discard that job's DYLD_INSERT_LIBRARIES. Rename only that empty
    /// marker; retain all code, load-command sizes and original entitlements.
    /// See Apple dyld-353.2.1/src/dyld.cpp, hasRestrictedSegment/processRestricted.
    static func installationServiceAllowingHelper(_ input: Data) throws -> Data {
        func unsupported() -> FirmwareError {
            FirmwareError(.unsupported, "Unsupported installation-service dyld restriction")
        }
        guard let parsed = MachOSignature.images(input), !parsed.fat,
            parsed.images.count == 1, let image = parsed.images.first,
            image.cputype == 12, !image.is64Bit
        else { throw unsupported() }
        var output = input
        func word(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= input.count - 4 else { throw unsupported() }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(input[offset + $1]) << ($1 * 8) }
        }
        func name(_ offset: Int) throws -> String {
            guard offset >= 0, offset <= input.count - 16 else { throw unsupported() }
            return String(decoding: input[offset..<(offset + 16)].prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        var changed = false
        for command in image.commands where command.cmd == 1 {
            let offset = command.offset
            let size = Int(try word(offset + 4))
            guard size >= 56, offset <= input.count - size else { throw unsupported() }
            guard try name(offset + 8) == "__RESTRICT" else { continue }
            let count = Int(try word(offset + 48))
            guard count <= (size - 56) / 68 else { throw unsupported() }
            for index in 0..<count {
                let section = offset + 56 + index * 68
                guard try name(section) == "__restrict" else { continue }
                guard try name(section + 16) == "__RESTRICT",
                    try word(offset + 28) == 0, try word(offset + 36) == 0,
                    try word(section + 36) == 0
                else { throw unsupported() }
                var marker = Data("__qemu_appsync".utf8)
                marker.append(contentsOf: repeatElement(0, count: 16 - marker.count))
                output.replaceSubrange(section..<(section + 16), with: marker)
                changed = true
            }
        }
        return changed ? try Activation.signed(output) : input
    }
}
