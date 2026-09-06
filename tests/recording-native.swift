import Cocoa
import Darwin

@main struct NativeRecording {
    static func main() async throws {
        _ = NSApplication.shared
        let library = CommandLine.arguments[1]
        let config = URL(fileURLWithPath: CommandLine.arguments[2])
        let directory = URL(fileURLWithPath: CommandLine.arguments[3])
        guard dlopen(library, RTLD_NOW | RTLD_GLOBAL) != nil else {
            fatalError(String(cString: dlerror()))
        }
        func symbol<T>(_ name: String, _ type: T.Type) -> T {
            unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)!, to: type)
        }
        typealias Main = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        typealias Callback = @convention(c) (UnsafeMutableRawPointer?) -> Void
        typealias Attach = @convention(c) (Callback?, UnsafeMutableRawPointer?) -> Void
        typealias Frame = @convention(c) (UnsafeMutablePointer<UnsafeRawPointer?>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<UInt64>?) -> Bool
        let run = symbol("qemu_ios_main", Main.self)
        let frame = symbol("qemu_ios_ui_frame", Frame.self)
        symbol("qemu_ios_ui_attach", Attach.self)(nil, nil)
        let arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: config))
        Thread.detachNewThread {
            let strings = arguments.map { strdup($0) }
            var argv = strings + [nil]
            let result = argv.withUnsafeMutableBufferPointer { run(Int32(arguments.count), $0.baseAddress) }
            for string in strings { free(string) }
            try? Data(String(result).utf8).write(to: directory.appendingPathComponent("qemu-exited"))
        }
        let fm = FileManager.default
        while !fm.fileExists(atPath: directory.appendingPathComponent("record-start").path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let writer = ScreenMovieWriter()
        try await writer.start(url: directory.appendingPathComponent("recording.mov"), recordGuestAudio: true)
        try Data().write(to: directory.appendingPathComponent("record-ready"))
        var serial: UInt64 = 0
        var latest: CGImage?
        while !fm.fileExists(atPath: directory.appendingPathComponent("record-stop").path) {
            var pixels: UnsafeRawPointer?
            var width: Int32 = 0, height: Int32 = 0
            if frame(&pixels, &width, &height, &serial), let pixels, width > 0, height > 0 {
                let data = Data(bytes: pixels, count: Int(width * height * 4))
                latest = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: Int(width * 4), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)],
                    provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            }
            try await writer.append(latest, seconds: 0)
            try await Task.sleep(for: .milliseconds(33))
        }
        try await writer.finish(seconds: 0)
        try Data().write(to: directory.appendingPathComponent("record-finished"))
        while !fm.fileExists(atPath: directory.appendingPathComponent("qemu-exited").path) {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
