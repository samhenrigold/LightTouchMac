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

extension SideloadTools {
    /// The installation service links `library` itself: an LC_LOAD_DYLIB appended to its load commands, in the
    /// header's zero padding before its first section, then the pages hashed again. From iOS 10 neither way of
    /// inserting it by environment reaches dyld: launchd drops a job's DYLD_ variables ("Disallowing environment
    /// variable"), and dyld drops them for a process the kernel enforces code signing on unless it may be debugged
    /// (dyld-433 configureProcessRestrictions). dyld registers the interposing of every image it loads at launch, not
    /// only inserted ones, and applies it to the shared cache too. Unchanged when it already links `library`.
    static func installationServiceLinking(_ input: Data, library: String) throws -> Data {
        func unsupported(_ why: String) -> FirmwareError {
            FirmwareError(.unsupported, "Installation service: \(why)")
        }
        guard let parsed = MachOSignature.images(input), !parsed.fat,
            parsed.images.count == 1, let image = parsed.images.first,
            image.cputype == MachOSignature.armCPU, !image.is64Bit
        else { throw unsupported("not a thin 32-bit ARM Mach-O") }
        func word(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(input[offset + $1]) << ($1 * 8) }
        }
        func cString(_ offset: Int, _ end: Int) -> String {
            String(decoding: input[offset..<end].prefix { $0 != 0 }, as: UTF8.self)
        }
        var firstSection = input.count
        for command in image.commands {
            let size = word(command.offset + 4)
            if MachO32.linkCommands.contains(command.cmd) {
                let name = size >= 24 ? word(command.offset + 8) : 0
                guard name >= 24, name < size else { throw unsupported("a malformed library command") }
                if cString(command.offset + name, command.offset + size) == library { return input }
            }
            guard command.cmd == 1, size >= 56 else { continue }  // LC_SEGMENT and its sections' file offsets
            for index in 0..<word(command.offset + 48) where 56 + index * 68 + 68 <= size {
                let offset = word(command.offset + 56 + index * 68 + 40)
                if offset > 0 { firstSection = min(firstSection, offset) }
            }
        }
        let path = Array(library.utf8)
        let size = (24 + path.count + 1 + 3) / 4 * 4
        let end = 28 + word(20)
        guard end + size <= firstSection, input[end..<(end + size)].allSatisfy({ $0 == 0 }) else {
            throw unsupported("no room after its load commands for \(library)")
        }
        var output = input
        func put(_ value: Int, _ offset: Int) {
            for index in 0..<4 { output[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
        }
        // dylib_command: cmd, cmdsize, name's offset, timestamp, current and compatibility version (0: any)
        put(Int(MachO32.lcLoadDylib), end)
        put(size, end + 4)
        put(24, end + 8)
        output.replaceSubrange((end + 24)..<(end + 24 + path.count), with: path)
        put(word(16) + 1, 16)
        put(word(20) + size, 20)
        return try Activation.signed(output)
    }
}
