import Foundation
import MachOKit
import Testing
@testable import FirmwareKit

/// What MachOKit 0.53 reads of a dyld_v1 cache (iOS 3/4) the way SharedCache.swift does, and what it does not: the
/// header's mappings and images and an image's LC_SYMTAB agree; an image's section contents do not (MachOKit
/// resolves a cached image's sections through the image, not the cache's mappings, and reads load-command bytes
/// instead of __cstring). That, and the byte scans over `data` at cache file offsets (GLIDispatch, the AppSync
/// patch), are why the cache reader stays ours. When MachOKit's section resolution agrees here, its symbol and
/// image walks can replace forEachSymbol/findSymbol/cStrings.
struct MachOKitProbeTests {
    @Test(arguments: ["7B500", "7E18"]) func v1Cache(build: String) throws {
        guard Fixtures.hasRootfs(build) else { return }
        let dir = try Fixtures.tempDir("mk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Fixtures.cache(build, to: dir)
        let ours = try DyldSharedCache(contentsOf: url)
        let theirs = try DyldCache(url: url)
        let maps = theirs.mappingInfos ?? []
        #expect(maps.map { ($0.address, $0.size, $0.fileOffset) }.elementsEqual(ours.mappings.map { ($0.address, $0.size, $0.fileOffset) }, by: ==))
        #expect((theirs.imageInfos?.compactMap { $0.path(in: theirs) } ?? []) == ours.images.map(\.path))
        let ogl = "/System/Library/Frameworks/OpenGLES.framework/OpenGLES"
        let img = try #require(ours.image(ogl))
        let file = try #require(theirs.machOFiles().first { $0.imagePath == ogl })
        #expect(file.headerStartOffsetInCache == img.headerOffset)
        #expect(file.symbols32.map { $0.map(\.name) } == ours.symbolNames(in: img))
        let sections = file.cStrings?.map(\.string) ?? [], mine = ours.cStrings(in: img, section: "__cstring")
        print("\(build): OpenGLES __cstring: MachOKit \(sections.count) strings vs ours \(mine.count); agree: \(sections == mine)")
    }
}
