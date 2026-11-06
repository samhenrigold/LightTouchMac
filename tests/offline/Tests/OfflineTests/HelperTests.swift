import AppKit
import DeviceRuntime
import Foundation
import Metal
import Testing
import os

@testable import Helper
@testable import LightTouchCore

extension SharedState {
    /// The helper's pieces that need no emulator: the libqemu binding's API check, the frame surface's colors and the
    /// frame ring callback's isolation.
    @Suite struct HelperTests {
        /// The helper loads only a libqemu-arm.dylib whose C API major version is its own (qemu_ios_api_version(),
        /// major << 16 | minor): fake 2.0 and 2.7 dylibs load; 1.2, 3.0 and one without the symbol (from before the
        /// version) are refused with a message naming both versions.
        @Test func qemuAPIVersion() throws {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ltm-api-version-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            for (name, version) in [
                ("v2_0", "(2u << 16)"), ("v2_7", "(2u << 16) | 7u"), ("v1_2", "(1u << 16) | 2u"),
                ("v3_0", "(3u << 16)"), ("none", nil)
            ] {
                let source = work.appendingPathComponent("\(name).c")
                try
                    ("void qemu_ios_main(void) {}\n"
                    + (version.map { "unsigned qemu_ios_api_version(void) { return \($0); }\n" } ?? "")).write(
                        to: source,
                        atomically: true,
                        encoding: .utf8
                    )
                let cc = Process()
                cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
                cc.arguments = ["-dynamiclib", source.path, "-o", work.appendingPathComponent("\(name).dylib").path]
                try cc.run()
                cc.waitUntilExit()
                try #require(cc.terminationStatus == 0)
            }
            for (name, loads) in [("v2_0", true), ("v2_7", true), ("v1_2", false), ("v3_0", false), ("none", false)] {
                do {
                    _ = try Qemu(path: work.appendingPathComponent("\(name).dylib").path)
                    #expect(loads, "\(name) loaded")
                } catch {
                    let text = "\(error)"
                    let want = ["v1_2": "has C API 1.2", "v3_0": "has C API 3.0"][name] ?? "has C API 0.0"
                    #expect(
                        !loads && text.contains(want) && text.contains("needs \(Qemu.apiMajor).x"),
                        "\(name): \(text)"
                    )
                }
            }
        }

        /// The frame pump calls onRingChanged on its own queue, so the closure main.swift's @MainActor modes set there
        /// must not take the main actor's isolation: Swift 6 checks it where it runs, and every headless boot trapped
        /// at its first ring (SIGTRAP in dispatch_assert_queue_fail, in the reader's lock body).
        @Test func aRingCallbackSetOnTheMainActorIsNotMainActorIsolated() async throws {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-ring-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let source = work.appendingPathComponent("qemu.c")
            try "unsigned qemu_ios_api_version(void) { return \(Qemu.apiMajor)u << 16; }\n".write(
                to: source,
                atomically: true,
                encoding: .utf8
            )
            let dylib = work.appendingPathComponent("libqemu-arm.dylib")
            let cc = Process()
            cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
            cc.arguments = ["-dynamiclib", source.path, "-o", dylib.path]
            try cc.run()
            cc.waitUntilExit()
            try #require(cc.terminationStatus == 0)
            let status = StatusBlock.create()
            let host = DeviceHost(qemu: try Qemu(path: dylib.path), status: status)
            let isolations = OSAllocatedUnfairLock<[String]>(initialState: [])
            host.onRingChanged = { _ in
                let isolation = #isolation.map { "\($0)" } ?? "nonisolated"
                isolations.withLock { $0.append(isolation) }
            }
            let ring = FrameRingWriter(status: status)
            await withCheckedContinuation { done in
                DispatchQueue(label: "LightTouch.frames").async {
                    host.onRingChanged?(ring)
                    done.resume()
                }
            }
            #expect(isolations.withLock { $0 } == ["nonisolated"])
        }

        /// The app gone (crashed or killed): the helper's stderr pipe has no reader, and its "link closed" log line
        /// must not abort it before the shutdown that flushes the device's storage. FileHandle.write(_:) raised on
        /// EPIPE there (SIGPIPE is ignored in the helper, as here).
        @Test func logToAPipeWithNoReader() throws {
            signal(SIGPIPE, SIG_IGN)
            let pipe = Pipe()
            try pipe.fileHandleForReading.close()
            helperLog("link closed", to: pipe.fileHandleForWriting)
            writeStandardError("web-proxy: GET /\n", to: pipe.fileHandleForWriting)
            try pipe.fileHandleForWriting.close()
        }

        /// The live LCD on a wide-gamut display: the helper's frame surface (makeSurface) holding pure red, composited by
        /// Core Animation into a Display P3 target as a P3 screen would, comes out as sRGB red in P3 (about 234, 51, 35),
        /// not P3's own oversaturated (255, 0, 0).
        @Test func frameSurfaceColorsOnP3() throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            let queue = try #require(device.makeCommandQueue())
            let surface = makeSurface(width: 8, height: 8)
            surface.lock(options: [], seed: nil)
            let p = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
            for y in 0..<8 {
                for x in 0..<8 {
                    let o = y * surface.bytesPerRow + x * 4
                    p[o] = 0
                    p[o + 1] = 0
                    p[o + 2] = 255
                    p[o + 3] = 255
                }
            }
            surface.unlock(options: [], seed: nil)
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: 8,
                height: 8,
                mipmapped: false
            )
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .managed
            let texture = try #require(device.makeTexture(descriptor: desc))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let layer = CALayer()
            layer.frame = CGRect(x: 0, y: 0, width: 8, height: 8)
            layer.contents = surface
            let renderer = CARenderer(
                mtlTexture: texture,
                options: [
                    kCARendererColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                    kCARendererMetalCommandQueue: queue
                ]
            )
            renderer.layer = layer
            renderer.bounds = layer.frame
            CATransaction.commit()
            CATransaction.flush()
            renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            let b = try #require(queue.makeCommandBuffer())
            let blit = try #require(b.makeBlitCommandEncoder())
            blit.synchronize(resource: texture)
            blit.endEncoding()
            b.commit()
            b.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: 256)
            texture.getBytes(&px, bytesPerRow: 32, from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0)
            let (b0, g0, r0) = (Int(px[144]), Int(px[145]), Int(px[146]))
            #expect(
                abs(r0 - 234) <= 3 && abs(g0 - 51) <= 4 && abs(b0 - 35) <= 4,
                "pure red on a P3 screen: (\(r0), \(g0), \(b0)); (255, 0, 0) is oversaturated"
            )
        }

        /// The web proxy serves at most its capacity of connections at once: the next is closed unanswered (its
        /// peer reads end of file) while they last, and taken again once one finishes.
        @Test func connectionsPastTheCapAreClosed() throws {
            let limit = ConnectionLimit(capacity: 2)
            let release = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            func pair() -> (ours: Int32, peer: Int32) {
                var fds: [Int32] = [0, 0]
                precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
                return (fds[0], fds[1])
            }
            let serve: @Sendable (Int32) -> Void = { fd in
                release.wait()
                close(fd)
                finished.signal()
            }
            let held = [pair(), pair()]
            for connection in held { #expect(limit.start(connection.ours, serve)) }
            let extra = pair()
            defer { close(extra.peer) }
            #expect(!limit.start(extra.ours, serve))
            var wait = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(extra.peer, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            var byte: UInt8 = 0
            #expect(read(extra.peer, &byte, 1) == 0, "the connection past the cap is closed")
            release.signal()
            finished.wait()
            let next = pair()
            #expect(limit.start(next.ours, serve), "a finished connection frees its place")
            release.signal()
            release.signal()
            for _ in 0..<2 { finished.wait() }
            for connection in held + [next] { close(connection.peer) }
        }
    }
}
