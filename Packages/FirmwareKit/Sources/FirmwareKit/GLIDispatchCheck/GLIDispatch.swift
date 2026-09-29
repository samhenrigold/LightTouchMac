// The firmware's GL dispatch facts a preparer reads from the IPSW's shared cache. The shims (GLEngine,
// MBXGLEngine) find the dispatch layout themselves at load (qemu-ios contrib/it-gles/gles_dispatch.c, by the
// names in include/hw/arm/guest-services/gles-names.h), so the recipe only logs the slot count as a sanity
// line, and checks that the gld plugin covers what 4.x's libGFXShared looks up.
import Foundation

public enum GLIDispatch {
    static let openGLES = "/System/Library/Frameworks/OpenGLES.framework/OpenGLES"
    static let libGFXShared = "/System/Library/Frameworks/OpenGLES.framework/libGFXShared.dylib"

    /// The dispatch_field list from the first `{__GLIFunctionDispatchRec=...}` @encode in `data`.
    public static func fields(in data: Data) -> [String]? {
        data.withUnsafeBytes { b -> [String]? in
            let needle = Array("{__GLIFunctionDispatchRec=".utf8)
            guard let base = b.baseAddress,
                  let hit = needle.withUnsafeBytes({ memmem(base, b.count, $0.baseAddress, needle.count) }) else { return nil }
            var i = base.distance(to: UnsafeRawPointer(hit)) + needle.count
            var end = i
            while end < b.count && b[end] != UInt8(ascii: "}") { end += 1 }
            guard end < b.count else { return nil }
            var out: [String] = []
            while i < end {                               // re.findall(rb'"([^"]+)"')
                guard b[i] == UInt8(ascii: "\"") else { i += 1; continue }
                var j = i + 1
                while j < end && b[j] != UInt8(ascii: "\"") { j += 1 }
                guard j < end else { break }
                if j > i + 1 { out.append(String(decoding: b[(i + 1)..<j], as: UTF8.self)); i = j + 1 } else { i += 1 }
            }
            return out
        }
    }

    /// ipad1_rootfs.gld_problem: (needed, why). Needed when this firmware's EAGL takes a libGFXShared shared
    /// state (4.x: OpenGLES imports gfxCreateSharedState); why is nil when the gld plugin exports every
    /// gld* entry point libGFXShared dlsyms.
    public static func gldProblem(_ cache: DyldSharedCache, plugin: URL) -> (needed: Bool, why: String?) {
        guard let ogl = cache.image(openGLES), cache.symbolNames(in: ogl).contains("_gfxCreateSharedState") else { return (false, nil) }
        guard let gfx = cache.image(libGFXShared) else { return (true, "OpenGLES imports gfxCreateSharedState but the cache has no libGFXShared") }
        let want = cache.cStrings(in: gfx, section: "__cstring").filter { $0.wholeMatch(of: /gld[A-Z]\w+/) != nil }
        guard let have = try? Data(contentsOf: plugin) else { return (true, "\(plugin.path) missing (run contrib/ipad1-gles/build.sh)") }
        let lost = want.filter { have.range(of: Data(("\0_" + $0 + "\0").utf8)) == nil }
        return (true, !lost.isEmpty || want.isEmpty ? "gldshim lacks \(lost.joined(separator: ", "))" : nil)
    }
}
