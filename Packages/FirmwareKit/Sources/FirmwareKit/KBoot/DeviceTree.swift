// DeviceTree: Apple's flattened device tree, parsed, edited in place and serialized (ipad1_kboot.DeviceTree).
//
//   var dt = try DeviceTree(blob)
//   dt.contains("arm-io/sdio"); dt.props["chosen"]?["root-matching"]   // (offset, length)
//   try dt.set("chosen", "firmware-version", .string("iBoot-817.29"))  // into the existing slot, zero-padded
//   try dt.add("arm-io/usb-complex", "hsic-enabled")                    // appends a property; the blob grows
//   try dt.rename("chosen/memory-map", "MemoryMapReserved-0", "Kernel-__TEXT")
//   try dt.addNode("arm-io/spi0", "nor-flash", [("compatible", .string("nor-flash,spi"))])   // a child node
//   dt.value("chosen", "secure-root-prefix")                            // a property's bytes
//   dt.data                                                             // the serialized tree
//
// Node paths join the "name" properties below the root with "/" ("" is the root, "arm-io/sdio"); a later
// node with the same path shadows an earlier one, as in the Python. iBoot's DT reserves every slot it
// fills, so set() never resizes: a value longer than its slot is an error.

import BinaryParsing
import Foundation

public struct DeviceTree: Sendable {
    public enum Value: Sendable {
        case string(String)  // UTF-8 + NUL
        case u32(UInt32)
        case words([UInt32])  // little-endian u32s
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

    public struct Slot: Equatable, Sendable {
        public var offset: Int
        public var length: Int
    }

    public private(set) var data: Data
    /// Node path -> property name -> the property record's offset (name at +0, length at +32, value at +36).
    public private(set) var props: [String: [String: Slot]] = [:]
    /// Node path -> (node header offset, offset just past its properties).
    public private(set) var nodes: [String: (start: Int, propsEnd: Int)] = [:]
    /// Node path -> offset just past its last descendant (where addNode inserts).
    private var ends: [String: Int] = [:]

    public init(_ blob: Data) throws {
        data = blob.withUnsafeBytes { Data($0) }  // rebased: offsets are from 0
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
        guard v.count <= s.length else {
            throw FirmwareError(.unsupported, "DeviceTree: \(path):\(prop) holds \(s.length) bytes, got \(v.count)")
        }
        data.replaceSubrange(s.offset + 36..<s.offset + 36 + s.length, with: v + Data(count: s.length - v.count))
    }

    /// Replaces a property with a resized record; calculate handoff addresses after this operation.
    public mutating func replace(_ path: String, _ prop: String, _ value: Value) throws {
        guard let slot = props[path]?[prop] else {
            throw FirmwareError(.unsupported, "DeviceTree: no \(path):\(prop)")
        }
        let bytes = value.encoded
        let record =
            Self.name32(prop) + Value.le([UInt32(bytes.count)]) + bytes
            + Data(count: ((bytes.count + 3) & ~3) - bytes.count)
        data.replaceSubrange(slot.offset..<slot.offset + 36 + ((slot.length + 3) & ~3), with: record)
        try reparse()
    }

    /// Interpret restore-tree iBoot expressions before calculating handoff addresses.
    /// Missing syscfg values follow iBoot: try the next alternative, or omit the property.
    public mutating func resolveBootDirectives(
        syscfg: [String: Data], macAddresses: [String: Data]
    ) throws {
        var changes: [(Slot, Data?)] = []
        for properties in props.values {
            for slot in properties.values where try u32(slot.offset + 32) & 0x8000_0000 != 0 {
                let expression = String(
                    decoding: data[slot.offset + 36..<slot.offset + 36 + slot.length]
                        .prefix { $0 != 0 }, as: UTF8.self)
                var result: Data?
                var mayOmit = false
                for option in expression.split(separator: ",") {
                    let fields = option.split(separator: "/").map(String.init)
                    guard fields.count >= 2 && fields.count <= 3 else {
                        throw FirmwareError(.unsupported, "DeviceTree: invalid iBoot directive \(expression)")
                    }
                    var count: Int?
                    if fields.count == 3 || fields[0] == "zeroes" {
                        let text = fields.last!
                        count = text.hasPrefix("0x") ? Int(text.dropFirst(2), radix: 16) : Int(text)
                        guard let n = count, n >= 0, n <= 1 << 20 else {
                            throw FirmwareError(.unsupported, "DeviceTree: invalid directive size \(expression)")
                        }
                    }
                    switch fields[0] {
                    case "syscfg":
                        result = syscfg[fields[1]]
                        mayOmit = true
                    case "macaddr": result = macAddresses[fields[1]]
                    case "zeroes": result = Data(count: count!)
                    default:
                        throw FirmwareError(.unsupported, "DeviceTree: unknown iBoot directive \(expression)")
                    }
                    if let value = result {
                        if let count { result = Data(value.prefix(count)) + Data(count: max(0, count - value.count)) }
                        break
                    }
                }
                guard result != nil || mayOmit else {
                    throw FirmwareError(.unsupported, "DeviceTree: unresolved iBoot directive \(expression)")
                }
                changes.append((slot, result))
            }
        }
        // Descending offsets preserve every original slot until it is replaced.
        for (slot, value) in changes.sorted(by: { $0.0.offset > $1.0.offset }) {
            guard let value else {
                let owner = nodes.values.filter { $0.start < slot.offset && slot.offset < $0.propsEnd }
                    .max { $0.start < $1.start }!
                data.replaceSubrange(owner.start..<owner.start + 4, with: Value.le([try u32(owner.start) - 1]))
                data.removeSubrange(slot.offset..<slot.offset + 36 + ((slot.length + 3) & ~3))
                continue
            }
            let record =
                data[slot.offset..<slot.offset + 32] + Value.le([UInt32(value.count)])
                + value + Data(count: ((value.count + 3) & ~3) - value.count)
            data.replaceSubrange(slot.offset..<slot.offset + 36 + ((slot.length + 3) & ~3), with: record)
        }
        try reparse()
    }

    /// Appends a property to a node; the blob grows, so lay memory out after the last add().
    public mutating func add(_ path: String, _ prop: String, _ value: Data = Data()) throws {
        guard let node = nodes[path] else { throw FirmwareError(.unsupported, "DeviceTree: no node \(path)") }
        var rec = Self.name32(prop) + Value.le([UInt32(value.count)]) + value
        rec += Data(count: ((value.count + 3) & ~3) - value.count)
        data.insert(contentsOf: rec, at: node.propsEnd)
        data.replaceSubrange(node.start..<node.start + 4, with: Value.le([try u32(node.start) + 1]))
        try reparse()
    }

    /// Appends a child node (its name first, then `props`) to `parent`; the blob grows, as add().
    public mutating func addNode(_ parent: String, _ name: String, _ props: [(String, Value)] = []) throws {
        guard let node = nodes[parent], let end = ends[parent] else {
            throw FirmwareError(.unsupported, "DeviceTree: no node \(parent)")
        }
        var rec = Value.le([UInt32(1 + props.count), 0])
        for (k, v) in [("name", Value.string(name))] + props {
            let e = v.encoded
            rec += Self.name32(k) + Value.le([UInt32(e.count)]) + e + Data(count: ((e.count + 3) & ~3) - e.count)
        }
        data.insert(contentsOf: rec, at: end)
        data.replaceSubrange(node.start + 4..<node.start + 8, with: Value.le([try u32(node.start + 4) + 1]))
        try reparse()
    }

    public mutating func rename(_ path: String, _ old: String, _ new: String) throws {
        guard let s = props[path]?.removeValue(forKey: old) else {
            throw FirmwareError(.unsupported, "DeviceTree: no \(path):\(old)")
        }
        data.replaceSubrange(s.offset..<s.offset + 32, with: Self.name32(new))
        props[path, default: [:]][new] = s
    }

    static func name32(_ s: String) -> Data { Data(Array(s.utf8).prefix(32)) + Data(count: max(0, 32 - s.utf8.count)) }

    private func u32(_ at: Int) throws -> UInt32 { try parsing(data, "DeviceTree") { s in try s.le32(at: at) } }

    /// Deeper than any tree iBoot hands over (a handful of levels); a deeper one is refused, not recursed into.
    static let maxDepth = 64

    private mutating func reparse() throws {
        var props: [String: [String: Slot]] = [:]
        var nodes: [String: (start: Int, propsEnd: Int)] = [:]
        var ends: [String: Int] = [:]
        // A node: its property and child counts (little-endian u32s), each property (a NUL-padded 32-byte name, a
        // u32 length whose top bit is a flag, the value padded to 4 bytes), then its children.
        func node(_ s: inout ParserSpan, parent: String?, depth: Int) throws {
            guard depth < Self.maxDepth else {
                throw FirmwareError(.unsupported, "DeviceTree: nested deeper than \(Self.maxDepth) nodes")
            }
            let start = s.startPosition
            let nprops = try UInt32(parsingLittleEndian: &s)
            let nchildren = try UInt32(parsingLittleEndian: &s)
            var mine: [String: Slot] = [:]
            var name: [UInt8]?
            for _ in 0..<nprops {
                let offset = s.startPosition
                let key = String(decoding: try [UInt8](parsing: &s, byteCount: 32).prefix { $0 != 0 }, as: UTF8.self)
                let length = Int(try UInt32(parsingLittleEndian: &s) & 0x7FFF_FFFF)
                let value = try [UInt8](parsing: &s, byteCount: length)
                try s.seek(toRelativeOffset: (4 - length % 4) % 4)
                mine[key] = Slot(offset: offset, length: length)
                if key == "name" { name = value }
            }
            guard let name else { throw FirmwareError(.unsupported, "DeviceTree: node without a name") }
            let text = String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)
            let path = parent.map { String("\($0)/\(text)".drop { $0 == "/" }) } ?? ""
            props[path] = mine
            nodes[path] = (start, s.startPosition)
            for _ in 0..<nchildren { try node(&s, parent: path, depth: depth + 1) }
            ends[path] = s.startPosition
        }
        try parsing(data, "DeviceTree") { s in
            try node(&s, parent: nil, depth: 0)
            guard s.isEmpty else {
                throw FirmwareError(.unsupported, "DeviceTree: trailing bytes after the device tree")
            }
        }
        (self.props, self.nodes, self.ends) = (props, nodes, ends)
    }
}
