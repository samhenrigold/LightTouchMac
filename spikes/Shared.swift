// Phase 0 spike: the shared half of the app <-> LightTouchDevice link.
import Foundation
import IOSurface

/// Newline-delimited JSON over the socketpair (stands in for the Codable LinkCommand/LinkEvent).
final class Link {
    let fd: Int32
    private var buffer = Data()
    private let source: DispatchSourceRead
    private let writeLock = NSLock()
    init(fd: Int32, queue: DispatchQueue, onMessage: @escaping ([String: Any]) -> Void, onEOF: @escaping () -> Void) {
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [unowned self] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { source.cancel(); onEOF(); return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0a) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let m = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { onMessage(m) }
            }
        }
        source.resume()
    }
    func send(_ m: [String: Any]) {
        var d = try! JSONSerialization.data(withJSONObject: m)
        d.append(0x0a)
        writeLock.lock(); defer { writeLock.unlock() }
        _ = d.withUnsafeBytes { write(fd, $0.baseAddress, d.count) }
    }
}

/// Status block layout: uint64 slots in IOSurface #0.
enum Slot: Int {
    case magic = 0, heartbeat, frameSerial, front, width, height, publishTicks, uiReady,
         glesContexts, snapshotStatus, shutdownConfirmed, held  // held: 1 + ring index the parent is reading, 0 none
}
let statusMagic: UInt64 = 0x4C544D5354415431   // "LTMSTAT1"

struct Status {
    let base: UnsafeMutablePointer<UInt64>
    init(_ s: IOSurface) { base = s.baseAddress.assumingMemoryBound(to: UInt64.self) }
    subscript(_ k: Slot) -> UInt64 {
        get { ltm_load(base + k.rawValue) }
        nonmutating set { ltm_store(base + k.rawValue, newValue) }
    }
}

func makeSurface(width: Int, height: Int, bytesPerElement: Int = 4) -> IOSurface {
    IOSurface(properties: [.width: width, .height: height, .bytesPerElement: bytesPerElement,
                           .pixelFormat: 0x42475241 /* 'BGRA' */])!
}

var timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
func ticksToMs(_ t: UInt64) -> Double { Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1e6 }

func cpuSeconds() -> Double {
    var r = rusage(); getrusage(RUSAGE_SELF, &r)
    return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
}

func log(_ s: String) {
    var tv = timeval(); gettimeofday(&tv, nil)
    FileHandle.standardError.write("[\(String(format: "%.3f", Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)) \(getpid())] \(s)\n".data(using: .utf8)!)
}
