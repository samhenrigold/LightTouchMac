// DeviceTree: Apple's flattened device tree, parsed, edited in place and serialized (ipad1_kboot.DeviceTree).
//
//   var dt = try DeviceTree(blob)
//   dt.contains("arm-io/sdio"); dt.props["chosen"]?["root-matching"]   // (offset, length)
//   try dt.set("chosen", "firmware-version", .string("iBoot-817.29"))  // into the existing slot, zero-padded
//   try dt.add("arm-io/usb-complex", "hsic-enabled")                    // appends a property; the blob grows
//   try dt.rename("chosen/memory-map", "MemoryMapReserved-0", "Kernel-__TEXT")
//   dt.value("chosen", "secure-root-prefix")                            // a property's bytes
//   dt.data                                                             // the serialized tree
//
// Node paths join the "name" properties below the root with "/" ("" is the root, "arm-io/sdio"); a later
// node with the same path shadows an earlier one, as in the Python. iBoot's DT reserves every slot it
// fills, so set() never resizes: a value longer than its slot is an error.

import Foundation

public struct DeviceTree: Sendable {
    public enum Value: Sendable {
        case string(String)      // UTF-8 + NUL
        case u32(UInt32)
        case words([UInt32])     // little-endian u32s
        case bytes(Data)

        var encoded: Data {
            switch self {
            case .string(let s): return Data(s.utf8) + [0]
            case .u32(let v): return Self.le([v])
            case .words(let w): return Self.le(w)
            case .bytes(let d): return d
            }
        }

        static func le(_ w: [UInt32]) -> Data {
            Data(w.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8 & 0xFF), UInt8($0 >> 16 & 0xFF), UInt8($0 >> 24)] })
        }
    }

    public struct Slot: Equatable, Sendable { public var offset: Int; public var length: Int }

    public private(set) var data: Data
    /// Node path -> property name -> the property record's offset (name at +0, length at +32, value at +36).
    public private(set) var props: [String: [String: Slot]] = [:]
    /// Node path -> (node header offset, offset just past its properties).
    public private(set) var nodes: [String: (start: Int, propsEnd: Int)] = [:]

    public init(_ blob: Data) throws {
        data = blob.withUnsafeBytes { Data($0) }   // rebased: offsets are from 0
        try reparse()
    }

    public func contains(_ path: String) -> Bool { props[path] != nil }

    public func value(_ path: String, _ prop: String) -> Data? {
        guard let s = props[path]?[prop] else { return nil }
        return data.subdata(in: s.offset + 36..<s.offset + 36 + s.length)
    }

    public mutating func set(_ path: String, _ prop: String, _ value: Value) throws {
        guard let s = props[path]?[prop] else { throw FirmwareError(.unsupported, "DeviceTree: no \(path):\(prop)") }
        let v = value.encoded
        guard v.count <= s.length else { throw FirmwareError(.unsupported, "DeviceTree: \(path):\(prop) holds \(s.length) bytes, got \(v.count)") }
        data.replaceSubrange(s.offset + 36..<s.offset + 36 + s.length, with: v + Data(count: s.length - v.count))
    }

    /// Appends a property to a node; the blob grows, so lay memory out after the last add().
    public mutating func add(_ path: String, _ prop: String, _ value: Data = Data()) throws {
        guard let node = nodes[path] else { throw FirmwareError(.unsupported, "DeviceTree: no node \(path)") }
        var rec = Self.name32(prop) + Value.le([UInt32(value.count)]) + value
        rec += Data(count: ((value.count + 3) & ~3) - value.count)
        data.insert(contentsOf: rec, at: node.propsEnd)
        data.replaceSubrange(node.start..<node.start + 4, with: Value.le([u32(node.start) + 1]))
        try reparse()
    }

    public mutating func rename(_ path: String, _ old: String, _ new: String) throws {
        guard let s = props[path]?.removeValue(forKey: old) else { throw FirmwareError(.unsupported, "DeviceTree: no \(path):\(old)") }
        data.replaceSubrange(s.offset..<s.offset + 32, with: Self.name32(new))
        props[path]![new] = s
    }

    static func name32(_ s: String) -> Data { Data(Array(s.utf8).prefix(32)) + Data(count: max(0, 32 - s.utf8.count)) }

    private func u32(_ at: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
    }

    private mutating func reparse() throws {
        props = [:]; nodes = [:]
        let end = try node(at: 0, parent: nil)
        guard end == data.count else { throw FirmwareError(.unsupported, "DeviceTree: trailing bytes after the device tree") }
    }

    private mutating func node(at start: Int, parent: String?) throws -> Int {
        guard start + 8 <= data.count else { throw FirmwareError(.unsupported, "DeviceTree: truncated") }
        let nprops = Int(u32(start)), nchildren = Int(u32(start + 4))
        var off = start + 8, mine: [String: Slot] = [:]
        for _ in 0..<nprops {
            guard off + 36 <= data.count else { throw FirmwareError(.unsupported, "DeviceTree: truncated") }
            let name = String(decoding: data[off..<off + 32].prefix { $0 != 0 }, as: UTF8.self)
            let len = Int(u32(off + 32) & 0x7FFF_FFFF)
            guard off + 36 + len <= data.count else { throw FirmwareError(.unsupported, "DeviceTree: truncated") }
            mine[name] = Slot(offset: off, length: len)
            off += 36 + ((len + 3) & ~3)
        }
        guard let n = mine["name"] else { throw FirmwareError(.unsupported, "DeviceTree: node without a name") }
        let name = String(decoding: data[n.offset + 36..<n.offset + 36 + n.length].prefix { $0 != 0 }, as: UTF8.self)
        let path = parent.map { String("\($0)/\(name)".drop { $0 == "/" }) } ?? ""
        props[path] = mine
        nodes[path] = (start, off)
        for _ in 0..<nchildren { off = try node(at: off, parent: path) }
        return off
    }
}
