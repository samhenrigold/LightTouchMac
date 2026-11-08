import Foundation
import Testing
@testable import FirmwareKit

struct DeviceTreeDirectiveTests {
    @Test func resizingPropertyPreservesFollowingRecordsAndDescendants() throws {
        var tree = try DeviceTree(KBootTests.node([
            ("name", Data("root\0".utf8)), ("seed", Data(count: 2)), ("following", Data([9]))
        ], [KBootTests.node([("name", Data("child\0".utf8)), ("marker", Data([42]))])]))
        for count in [64, 1] {
            try tree.replace("", "seed", .bytes(Data(repeating: 7, count: count)))
            let reparsed = try DeviceTree(tree.data)
            #expect(reparsed.value("", "seed") == Data(repeating: 7, count: count))
            #expect(reparsed.value("", "following") == Data([9]))
            #expect(reparsed.value("child", "marker") == Data([42]))
        }
    }
    func flagged(_ name: String, _ expression: String) -> Data {
        var record = KBootTests.prop(name, Data((expression + "\0").utf8))
        record.replaceSubrange(32..<36, with: DeviceTree.Value.le([UInt32(expression.utf8.count + 1) | 0x8000_0000]))
        return record
    }
    @Test func resolvesFallbacksResizesAndPreservesDescendants() throws {
        let name = KBootTests.prop("name", Data("device-tree\0".utf8))
        let blob = DeviceTree.Value.le([5, 1]) + name
            + flagged("calibration", "syscfg/MtCl/0x400,zeroes/0x400")
            + flagged("serial", "syscfg/SrNm/0x20,zeroes/0x20")
            + flagged("optional", "syscfg/MkBH")
            + flagged("mac", "macaddr/wifiaddr,syscfg/WMac/6,zeroes/6")
            + KBootTests.node([("name", Data("child\0".utf8)), ("marker", Data([42]))])
        var tree = try DeviceTree(blob)
        try tree.resolveBootDirectives(syscfg: ["SrNm": Data("EMU123\0".utf8)],
                                       macAddresses: ["wifiaddr": Data([2, 0, 0, 0, 0, 1])])
        #expect(tree.value("", "calibration") == Data(count: 1024))
        #expect(tree.value("", "serial")?.prefix(7) == Data("EMU123\0".utf8))
        #expect(tree.props[""]?["serial"]?.length == 32)
        #expect(tree.value("", "optional") == nil)
        #expect(tree.value("", "mac") == Data([2, 0, 0, 0, 0, 1]))
        #expect(tree.value("child", "marker") == Data([42]))
        for properties in tree.props.values {
            for slot in properties.values {
                #expect(KBootTests.u32(tree.data, slot.offset + 32) == UInt32(slot.length))
            }
        }
        let previous = tree.data
        try tree.resolveBootDirectives(syscfg: [:], macAddresses: [:])
        #expect(tree.data == previous)
    }
    @Test func rejectsUnsupportedExpressionsWithoutMutation() throws {
        let blob = DeviceTree.Value.le([2, 0]) + KBootTests.prop("name", Data("root\0".utf8))
            + flagged("unknown", "future/value")
        var tree = try DeviceTree(blob)
        #expect(throws: FirmwareError.self) { try tree.resolveBootDirectives(syscfg: [:], macAddresses: [:]) }
        #expect(tree.data == blob)
    }
    @Test func kbootMeasuresResolvedTreeBeforePlacingBootArguments() throws {
        var source = try DeviceTree(KBootTests.dtBlob)
        try source.add("", "compatible", Data("N42AP\0iPhone5,2\0AppleARM\0".utf8))
        try source.add("chosen", "large-calibration", Data("syscfg/Test/0x4000,zeroes/0x4000\0".utf8))
        let slot = source.props["chosen"]!["large-calibration"]!
        var bytes = source.data
        bytes.replaceSubrange(slot.offset + 32..<slot.offset + 36,
                              with: DeviceTree.Value.le([UInt32(slot.length) | 0x8000_0000]))
        let image = try KBoot.build(kernel: KBootTests.kernel(at: 0x8000_0000),
                                    deviceTree: bytes, identity: KBootTests.placeholder)
        let args = Int(image.bootArgsPA - image.loadPA)
        let offset = Int(KBootTests.u32(image.image, args + 0x30) - image.loadPA)
        let length = Int(KBootTests.u32(image.image, args + 0x34))
        #expect(length > 0x4000)
        #expect(offset + length <= args)
        let tree = try DeviceTree(image.image[offset..<offset + length])
        #expect(tree.value("chosen", "large-calibration") == Data(count: 0x4000))
    }
}
