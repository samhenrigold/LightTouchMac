import Foundation
import MachOKit
import Testing
@testable import FirmwareKit

/// Whether MachOKit reads the dyld_v1 caches (iOS 3/4) the way our reader does: mappings, images, one image's
/// LC_SYMTAB. Decides what SharedCache.swift keeps.
struct MachOKitProbeTests {
    @Test(arguments: ["7B500", "7E18"]) func v1Cache(build: String) throws {
        guard Fixtures.hasRootfs(build) else { return }
        let dir = try Fixtures.tempDir("mk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Fixtures.cache(build, to: dir)
        let ours = try DyldSharedCache(contentsOf: url)
        let theirs = try DyldCache(url: url)
        let maps = theirs.mappingInfos ?? []
        print("\(build): MachOKit mappings \(maps.count) vs \(ours.mappings.count); images \(theirs.imageInfos?.count ?? -1) vs \(ours.images.count)")
        #expect(maps.map { ($0.address, $0.size, $0.fileOffset) }.elementsEqual(ours.mappings.map { ($0.address, $0.size, $0.fileOffset) }, by: ==))
        let paths = theirs.imageInfos?.compactMap { $0.path(in: theirs) } ?? []
        #expect(paths == ours.images.map(\.path))
        let ogl = "/System/Library/Frameworks/OpenGLES.framework/OpenGLES"
        let img = try #require(ours.image(ogl))
        let mine = ours.symbolNames(in: img)
        let file = theirs.machOFiles().first { $0.imagePath == ogl }
        let syms = file?.symbols32.map { $0.map(\.name) } ?? []
        print("\(build): OpenGLES symbols MachOKit \(syms.count) vs ours \(mine.count); headerOffset \(file?.headerStartOffsetInCache ?? -1) vs \(img.headerOffset)")
        #expect(syms == mine)
        let strings = ours.cStrings(in: img, section: "__cstring")
        let theirStrings = file?.cStrings?.map(\.string) ?? []
        print("\(build): OpenGLES __cstring MachOKit \(theirStrings.count) vs ours \(strings.count)")
        #expect(theirStrings == strings)
    }
}
