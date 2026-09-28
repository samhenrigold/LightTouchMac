// The status block and frame ring the helper shares with the app.
//
// IOSurface #0 is a 4 KB block of UInt64 slots, written by the helper at 20 Hz
// (frames at 60 Hz) with atomics and read synchronously by the app. #1...#3 are
// BGRA surfaces of the current screen size. The writer copies each new
// qemu_ios_ui_frame into a surface that is neither `front`, nor the reader's
// `held`, nor IOSurfaceIsInUse (Core Animation), then publishes `front` and
// `frameSerial` (seq-cst). The reader stores `held` and re-reads the serial.
// A stalled heartbeat means the helper is wedged; stalled frames, the guest.

import Foundation
import IOSurface
import LTMLinkC

nonisolated enum StatusSlot: Int, CaseIterable {
    case magic = 0, layoutVersion, heartbeat, frameSerial, front, width, height,
         ringGeneration, held,              // held: 1 + the ring index the app is reading, 0 none
         uiReady, storageFailed, shutdownConfirmed, displaySleeping, agentStatus,
         glesContexts, iconGeneration,
         qemuState,                         // QemuState
         exitCode, publishTicks, helperPID
}

nonisolated enum QemuState: UInt64, Sendable {
    case notStarted = 0, running = 1, exited = 2
}

/// One synchronous read of the status block.
nonisolated struct SharedStatus: Sendable, Equatable {
    var heartbeat: UInt64
    var frameSerial: UInt64
    var width: Int
    var height: Int
    var ringGeneration: UInt64
    var uiReady: Bool
    var storageFailed: Bool
    var shutdownConfirmed: Bool
    var displaySleeping: Bool
    /// qemu_ios_agent_status: 0 absent/not running, 1 alive, 2 stale.
    var agentStatus: Int
    var glesContexts: Int
    var iconGeneration: UInt64
    var qemuState: QemuState
    var exitCode: Int32
    var helperPID: Int32
}

nonisolated struct StatusBlock: @unchecked Sendable {
    static let magic: UInt64 = 0x4C544D5354415432   // "LTMSTAT2"
    static let layoutVersion: UInt64 = 1
    static let bytes = 4096

    let surface: IOSurface
    private let base: UnsafeMutablePointer<UInt64>

    init(_ surface: IOSurface) {
        self.surface = surface
        base = surface.baseAddress.assumingMemoryBound(to: UInt64.self)
    }

    /// The helper's block, zeroed and stamped.
    static func create() -> StatusBlock {
        let block = StatusBlock(makeSurface(width: bytes / 8, height: 1, bytesPerElement: 8))
        memset(block.base, 0, bytes)
        block[.layoutVersion] = layoutVersion
        block[.helperPID] = UInt64(getpid())
        block[.magic] = magic
        return block
    }

    var isValid: Bool {
        surface.allocationSize >= Self.bytes && self[.magic] == Self.magic && self[.layoutVersion] == Self.layoutVersion
    }

    subscript(_ slot: StatusSlot) -> UInt64 {
        get { ltm_load(base + slot.rawValue) }
        nonmutating set { ltm_store(base + slot.rawValue, newValue) }
    }
    func loadSeq(_ slot: StatusSlot) -> UInt64 { ltm_load_seq(base + slot.rawValue) }
    func storeSeq(_ slot: StatusSlot, _ value: UInt64) { ltm_store_seq(base + slot.rawValue, value) }
    func bumpHeartbeat() { _ = ltm_add(base + StatusSlot.heartbeat.rawValue, 1) }

    func snapshot() -> SharedStatus {
        SharedStatus(heartbeat: self[.heartbeat], frameSerial: self[.frameSerial],
                     width: Int(self[.width]), height: Int(self[.height]),
                     ringGeneration: self[.ringGeneration],
                     uiReady: self[.uiReady] != 0, storageFailed: self[.storageFailed] != 0,
                     shutdownConfirmed: self[.shutdownConfirmed] != 0, displaySleeping: self[.displaySleeping] != 0,
                     agentStatus: Int(self[.agentStatus]), glesContexts: Int(self[.glesContexts]),
                     iconGeneration: self[.iconGeneration],
                     qemuState: QemuState(rawValue: self[.qemuState]) ?? .notStarted,
                     exitCode: Int32(truncatingIfNeeded: Int64(bitPattern: self[.exitCode])),
                     helperPID: Int32(truncatingIfNeeded: self[.helperPID]))
    }
}

nonisolated func makeSurface(width: Int, height: Int, bytesPerElement: Int = 4) -> IOSurface {
    IOSurface(properties: [.width: width, .height: height, .bytesPerElement: bytesPerElement,
                           .pixelFormat: 0x42475241 /* 'BGRA' */])!
}

/// The helper's side of the ring: three surfaces, and a publish that never
/// touches the surface the reader holds or Core Animation is showing.
nonisolated final class FrameRingWriter: @unchecked Sendable {
    let status: StatusBlock
    private(set) var surfaces: [IOSurface] = []
    private(set) var generation: UInt64 = 0
    private var serial: UInt64 = 0
    private(set) var dropped = 0

    init(status: StatusBlock) { self.status = status }

    var width: Int { surfaces.first?.width ?? 0 }
    var height: Int { surfaces.first?.height ?? 0 }

    /// A new ring of `width` x `height`. The caller sends the Mach hello for
    /// it, then calls `activate()` before publishing into it.
    func resize(width: Int, height: Int) {
        surfaces = (0..<3).map { _ in makeSurface(width: width, height: height) }
        generation += 1
    }

    func activate() {
        status[.width] = UInt64(width)
        status[.height] = UInt64(height)
        status[.front] = 0
        status[.ringGeneration] = generation
    }

    /// Fill a free surface and publish it. False if all three were busy (a dropped frame).
    @discardableResult
    func publish(_ fill: (IOSurface) -> Void) -> Bool {
        let front = Int(status[.front])
        let held = Int(status.loadSeq(.held)) - 1
        guard let i = surfaces.indices.first(where: { $0 != front && $0 != held && !surfaces[$0].isInUse }) else {
            dropped += 1
            return false
        }
        surfaces[i].lock(options: [], seed: nil)
        fill(surfaces[i])
        surfaces[i].unlock(options: [], seed: nil)
        serial += 1
        status[.front] = UInt64(i)
        status[.publishTicks] = mach_absolute_time()
        status.storeSeq(.frameSerial, serial)
        return true
    }

    /// Copy tightly packed BGRA rows into the surface's (padded) rows.
    static func copy(_ pixels: UnsafeRawPointer, width: Int, height: Int, into surface: IOSurface) {
        let rowBytes = width * 4
        let dst = surface.baseAddress
        if surface.bytesPerRow == rowBytes {
            memcpy(dst, pixels, rowBytes * height)
        } else {
            for y in 0..<height { memcpy(dst + y * surface.bytesPerRow, pixels + y * rowBytes, rowBytes) }
        }
    }
}

/// The app's side: which surface to show. One reader per ring.
nonisolated final class FrameRingReader: @unchecked Sendable {
    let status: StatusBlock
    let generation: UInt64
    let surfaces: [IOSurface]
    private var lastSerial: UInt64 = 0
    private var current: IOSurface?
    private var currentIndex = -1

    init(status: StatusBlock, generation: UInt64, surfaces: [IOSurface]) {
        self.status = status
        self.generation = generation
        self.surfaces = surfaces
    }

    /// The newest published surface, and whether it is new since the last call.
    /// While the helper is between rings (a resize in flight) this keeps
    /// returning the last surface. Call from one thread (the display link).
    func front() -> (surface: IOSurface, serial: UInt64, isNew: Bool)? {
        guard surfaces.count == 3 else { return nil }
        let s1 = status.loadSeq(.frameSerial)
        if s1 == lastSerial || status[.ringGeneration] != generation {
            return current.map { ($0, lastSerial, false) }
        }
        let index = Int(status[.front])
        guard index < 3 else { return current.map { ($0, lastSerial, false) } }
        status.storeSeq(.held, UInt64(index + 1))
        // Moved under us: the helper may already be writing into `index`. Keep
        // the last one; the next call takes the newer frame.
        guard status.loadSeq(.frameSerial) == s1 else {
            status.storeSeq(.held, UInt64(currentIndex + 1))
            return current.map { ($0, lastSerial, false) }
        }
        lastSerial = s1
        current = surfaces[index]
        currentIndex = index
        return (surfaces[index], s1, true)
    }

    /// Stop holding any surface (the display is hidden or the ring is replaced).
    func release() { status.storeSeq(.held, 0) }
}
