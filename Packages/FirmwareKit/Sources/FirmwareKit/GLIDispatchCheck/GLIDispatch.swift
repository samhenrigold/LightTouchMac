// The firmware's GL dispatch facts a preparer reads from the IPSW's shared cache. The GL code finds the dispatch
// layout itself at load (qemu-ios contrib/it-gles/gles_dispatch.c, by the names in
// include/hw/arm/guest-services/gles-names.h); FitCheck.glesFrontEnd proves every field is a named row.
import Foundation

public enum GLIDispatch {

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
}
