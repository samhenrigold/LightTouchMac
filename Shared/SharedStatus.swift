// The status block and frame ring the helper shares with the app.
//
// IOSurface #0 is a 4 KB block of UInt64 slots, written by the helper at 20 Hz
// (frames at 60 Hz) with atomics and read synchronously by the app. #1...#3 are
// BGRA surfaces of the current screen size. The writer copies each new
// qemu_ios_ui_frame into a surface that is neither `front`, nor the reader's
// `held`, nor IOSurfaceIsInUse (Core Animation), then publishes `front` and
// `frameSerial` (seq-cst). The reader stores `held` and re-reads the serial.
// A stalled heartbeat means the helper is wedged; stalled frames, the guest.

import Accelerate
import Foundation
import IOSurface
import LTMLinkC

nonisolated public enum StatusSlot: Int, CaseIterable {
    case magic = 0, layoutVersion, heartbeat, frameSerial, front, width, height,
         ringGeneration, held,              // held: 1 + the ring index the app is reading, 0 none
         uiReady, storageFailed, shutdownConfirmed, displaySleeping, agentStatus,
         glesContexts, iconGeneration,
         qemuState,                         // QemuState
         exitCode, publishTicks, helperPID,
         // layout 2: it_boot's QC_PKG_REPORT and the GL shim's QC_GLES_HELLO
         guestPackageReported, guestPackage, guestPackageState,   // serial, it_boot R_* (Int64 bit patterns)
         glesProtocol, glesSerial,
         guestPackageSupported              // the dylib has the guest-package= property (set before boot)
}

nonisolated public enum QemuState: UInt64, Sendable {
    case notStarted = 0, running = 1, exited = 2
}

/// One synchronous read of the status block.
nonisolated public struct SharedStatus: Sendable, Equatable {
    public var heartbeat: UInt64
    public var frameSerial: UInt64
    public var width: Int
    public var height: Int
    public var ringGeneration: UInt64
    public var uiReady: Bool
    public var storageFailed: Bool
    public var shutdownConfirmed: Bool
    public var displaySleeping: Bool
    /// qemu_ios_agent_status: 0 absent/not running, 1 alive, 2 stale.
    public var agentStatus: Int
    public var glesContexts: Int
    public var iconGeneration: UInt64
    public var qemuState: QemuState
    public var exitCode: Int32
    public var helperPID: Int32
    /// it_boot's last report since the guest reset: the serial now current and
    /// its result (R_*: 0 unchanged, 1 installed, 2 switched, 3/4 reverted,
    /// 5 refused; negative: an install failed). Nil: no loader, or no offer yet.
    public var guestPackage: GuestPackageReport?
    /// QC_GLES_HELLO's wire protocol and package serial; 0 when no hello came.
    public var glesProtocol: Int32 = 0
    public var glesSerial: Int64 = 0
    /// The loaded dylib serves guest-package offers (older ones reject the property).
    public var guestPackageSupported = false
    public init(heartbeat: UInt64, frameSerial: UInt64, width: Int, height: Int, ringGeneration: UInt64, uiReady: Bool, storageFailed: Bool, shutdownConfirmed: Bool, displaySleeping: Bool, agentStatus: Int, glesContexts: Int, iconGeneration: UInt64, qemuState: QemuState, exitCode: Int32, helperPID: Int32, guestPackage: GuestPackageReport? = nil, glesProtocol: Int32 = 0, glesSerial: Int64 = 0, guestPackageSupported: Bool = false) {
        self.heartbeat = heartbeat
        self.frameSerial = frameSerial
        self.width = width
        self.height = height
        self.ringGeneration = ringGeneration
        self.uiReady = uiReady
        self.storageFailed = storageFailed
        self.shutdownConfirmed = shutdownConfirmed
        self.displaySleeping = displaySleeping
        self.agentStatus = agentStatus
        self.glesContexts = glesContexts
        self.iconGeneration = iconGeneration
        self.qemuState = qemuState
        self.exitCode = exitCode
        self.helperPID = helperPID
        self.guestPackage = guestPackage
        self.glesProtocol = glesProtocol
        self.glesSerial = glesSerial
        self.guestPackageSupported = guestPackageSupported
    }
}

nonisolated public struct GuestPackageReport: Sendable, Equatable {
    public var serial: Int64
    public var result: Int32
    public init(serial: Int64, result: Int32) {
        self.serial = serial
        self.result = result
    }
}

nonisolated public struct StatusBlock: @unchecked Sendable {
    public static let magic: UInt64 = 0x4C544D5354415432   // "LTMSTAT2"
    public static let layoutVersion: UInt64 = 2
    public static let bytes = 4096

    public let surface: IOSurface
    private let base: UnsafeMutablePointer<UInt64>

    public init(_ surface: IOSurface) {
        self.surface = surface
        base = surface.baseAddress.assumingMemoryBound(to: UInt64.self)
    }

    /// The helper's block, zeroed and stamped.
    public static func create() -> StatusBlock {
        let block = StatusBlock(makeSurface(width: bytes / 8, height: 1, bytesPerElement: 8))
        memset(block.base, 0, bytes)
        block[.layoutVersion] = layoutVersion
        block[.helperPID] = UInt64(getpid())
        block[.magic] = magic
        return block
    }

    public var isValid: Bool {
        surface.allocationSize >= Self.bytes && self[.magic] == Self.magic && self[.layoutVersion] == Self.layoutVersion
    }

    public subscript(_ slot: StatusSlot) -> UInt64 {
        get { ltm_load(base + slot.rawValue) }
        nonmutating set { ltm_store(base + slot.rawValue, newValue) }
    }
    public func loadSeq(_ slot: StatusSlot) -> UInt64 { ltm_load_seq(base + slot.rawValue) }
    public func storeSeq(_ slot: StatusSlot, _ value: UInt64) { ltm_store_seq(base + slot.rawValue, value) }
    public func bumpHeartbeat() { _ = ltm_add(base + StatusSlot.heartbeat.rawValue, 1) }

    public func snapshot() -> SharedStatus {
        SharedStatus(heartbeat: self[.heartbeat], frameSerial: self[.frameSerial],
                     width: Int(self[.width]), height: Int(self[.height]),
                     ringGeneration: self[.ringGeneration],
                     uiReady: self[.uiReady] != 0, storageFailed: self[.storageFailed] != 0,
                     shutdownConfirmed: self[.shutdownConfirmed] != 0, displaySleeping: self[.displaySleeping] != 0,
                     agentStatus: Int(self[.agentStatus]), glesContexts: Int(self[.glesContexts]),
                     iconGeneration: self[.iconGeneration],
                     qemuState: QemuState(rawValue: self[.qemuState]) ?? .notStarted,
                     exitCode: Int32(truncatingIfNeeded: Int64(bitPattern: self[.exitCode])),
                     helperPID: Int32(truncatingIfNeeded: self[.helperPID]),
                     guestPackage: self[.guestPackageReported] == 0 ? nil
                        : GuestPackageReport(serial: Int64(bitPattern: self[.guestPackage]),
                                             result: Int32(truncatingIfNeeded: Int64(bitPattern: self[.guestPackageState]))),
                     glesProtocol: Int32(truncatingIfNeeded: Int64(bitPattern: self[.glesProtocol])),
                     glesSerial: Int64(bitPattern: self[.glesSerial]),
                     guestPackageSupported: self[.guestPackageSupported] != 0)
    }
}

nonisolated public func makeSurface(width: Int, height: Int, bytesPerElement: Int = 4) -> IOSurface {
    IOSurface(properties: [.width: width, .height: height, .bytesPerElement: bytesPerElement,
                           .pixelFormat: 0x42475241 /* 'BGRA' */])!
}

/// The helper's side of the ring: three surfaces, and a publish that never
/// touches the surface the reader holds or Core Animation is showing.
nonisolated public final class FrameRingWriter: @unchecked Sendable {
    public let status: StatusBlock
    public private(set) var surfaces: [IOSurface] = []
    public private(set) var generation: UInt64 = 0
    private var serial: UInt64 = 0
    public private(set) var dropped = 0

    public init(status: StatusBlock) { self.status = status }

    public var width: Int { surfaces.first?.width ?? 0 }
    public var height: Int { surfaces.first?.height ?? 0 }

    /// A new ring of `width` x `height`. The caller sends the Mach hello for
    /// it, then calls `activate()` before publishing into it.
    public func resize(width: Int, height: Int) {
        surfaces = (0..<3).map { _ in makeSurface(width: width, height: height) }
        generation += 1
    }

    public func activate() {
        status[.width] = UInt64(width)
        status[.height] = UInt64(height)
        status[.front] = 0
        status[.ringGeneration] = generation
    }

    /// Fill a free surface and publish it. False if all three were busy (a dropped frame).
    @discardableResult
    public func publish(_ fill: (IOSurface) -> Void) -> Bool {
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

    /// Copy tightly packed BGRA rows into the surface's (padded) rows, with the
    /// alpha byte forced opaque: iBoot and the iPod's framebuffer leave it 0,
    /// and the app's layer shows the surface as is (a copy ignored it).
    public static func copy(_ pixels: UnsafeRawPointer, width: Int, height: Int, into surface: IOSurface) {
        let rowBytes = width * 4
        let dst = surface.baseAddress
        if surface.bytesPerRow == rowBytes {
            memcpy(dst, pixels, rowBytes * height)
        } else {
            for y in 0..<height { memcpy(dst + y * surface.bytesPerRow, pixels + y * rowBytes, rowBytes) }
        }
        var buffer = vImage_Buffer(data: dst, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                   rowBytes: surface.bytesPerRow)
        _ = vImageOverwriteChannelsWithScalar_ARGB8888(255, &buffer, &buffer, 0x1 /* the 4th byte */, vImage_Flags(kvImageNoFlags))
    }
}

/// The app's side: which surface to show. One reader per ring.
nonisolated public final class FrameRingReader: @unchecked Sendable {
    public let status: StatusBlock
    public let generation: UInt64
    public let surfaces: [IOSurface]
    private var lastSerial: UInt64 = 0
    private var current: IOSurface?
    private var currentIndex = -1

    public init(status: StatusBlock, generation: UInt64, surfaces: [IOSurface]) {
        self.status = status
        self.generation = generation
        self.surfaces = surfaces
    }

    /// The newest published surface, and whether it is new since the last call.
    /// While the helper is between rings (a resize in flight) this keeps
    /// returning the last surface. Call from one thread (the display link).
    public func front() -> (surface: IOSurface, serial: UInt64, isNew: Bool)? {
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
    public func release() { status.storeSeq(.held, 0) }
}
