// The app's rotation for `turn` and `shot`: DeviceRotation (the shell's angle and the machine's control, as the app
// sends it for this board) and the picture as the window shows it (PanelCapture), for `sessions rotation`.

import CoreGraphics
import DeviceRuntime
import Foundation
import HostRuntime
import ImageIO
import LightTouchCore
import SessionKit
import UniformTypeIdentifiers

/// The driver's link with replies on the main queue, where the app's link delivers them (BootSessionScope.control).
final class MainQueueLink: HelperLink {
    let link: DeviceLink
    init(_ link: DeviceLink) { self.link = link }
    func send(_ command: LinkCommand) { link.send(command) }
    func request(_ request: LinkRequest, timeout: TimeInterval, reply: @escaping DeviceLink.Reply) {
        link.request(request, timeout: timeout) { result in DispatchQueue.main.async { reply(result) } }
    }
}

@MainActor final class RotationDriver: RotationHost {
    let bootScope = BootSessionScope()
    let mainLink: MainQueueLink
    var helperLink: HelperLink? { mainLink }
    var state: VMState = .running
    var preparingDevice = false, isSleeping = false, isInstalling = false, canReachDevice = false
    func interfaceOrientation() async throws -> Int { throw CancellationError() }
    func guestOrientation() async throws -> Int? { nil }

    let board: Board
    let scan: CGSize
    var rotation: DeviceRotation!
    /// The interface watch's last reading (`follow`).
    var lastInterface: Int?

    init(link: DeviceLink, board: Board, scan: CGSize, settings: URL) {
        mainLink = MainQueueLink(link)
        self.board = board
        self.scan = scan
        rotation = DeviceRotation(
            host: self,
            settings: DeviceSettingsFile(directory: settings),
            setsAccelerometer: board.orientationSource == .springBoard  // as EmulatorController
        )
    }

    /// Quarter turns clockwise from the published frame to the window's picture.
    var turns: Int {
        PanelCapture.quarterTurns(guestTurn: Board.guestTurn(scan: scan), deviceDegrees: rotation.degrees)
    }

    /// A point on the window's picture (0...1, top-left origin) as the touch the app sends: over the surface as
    /// published, so the inverse of `turns`.
    func touchPoint(shown u: Double, _ v: Double) -> (Double, Double) {
        switch turns {
        case 1: (v, 1 - u)
        case 2: (1 - u, 1 - v)
        case 3: (1 - v, u)
        default: (u, v)
        }
    }

    /// The dumped frame at `source` turned as the window shows it, written to `destination`.
    func writeShown(_ source: URL, to destination: URL) -> Bool {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(input, 0, nil),
            let shown = PanelCapture.rotated(image, clockwiseQuarterTurns: turns),
            let output = CGImageDestinationCreateWithURL(
                destination as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else { return false }
        CGImageDestinationAddImage(output, shown, nil)
        return CGImageDestinationFinalize(output)
    }
}

/// The angle the guest's interface stands at on a frame as published, in DeviceRotation's degrees (0, 90, 180, 270):
/// the clockwise turn, from the panel stood upright, that puts the status bar's clock centered at the top. Vision reads
/// text at any angle, so the clock's place, not its legibility, says which way up the interface is. nil: no clock.
func interfaceDegrees(frame: URL, scan: CGSize) -> Int? {
    guard let input = CGImageSourceCreateWithURL(frame as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(input, 0, nil)
    else { return nil }
    let upright = PanelCapture.quarterTurns(guestTurn: Board.guestTurn(scan: scan), deviceDegrees: 0)
    for quarter in 0..<4 {
        guard let turned = PanelCapture.rotated(image, clockwiseQuarterTurns: (upright + quarter) % 4),
            let clock = TextReader.clock(in: TextReader.read(turned))
        else { continue }
        if clock.y < 0.08 && abs(clock.x - 0.5) < 0.2 { return quarter * 90 }
    }
    return nil
}

/// Where Vision reads `word` on an image (top-left origin, 0...1): the first text equal to it, or nil.
func findWord(_ word: String, in image: URL) -> (x: Double, y: Double)? {
    TextReader.read(image).first { $0.text.trimmingCharacters(in: .whitespaces) == word }.map { ($0.x, $0.y) }
}

/// Every line Vision reads on an image, top to bottom.
func readText(in image: URL) -> [String] {
    TextReader.read(image, languageCorrection: false).sorted { $0.y < $1.y }.map(\.text)
}

/// The lines Vision reads on the status bar alone (an image's top 4.5%), grayscale and scaled to 1280 points wide: its
/// small text (an iPod's "-45" beside "iPod") goes unread on the whole picture.
func readStatusBar(in image: URL) -> [String] {
    guard let input = CGImageSourceCreateWithURL(image as CFURL, nil),
        let cg = CGImageSourceCreateImageAtIndex(input, 0, nil),
        case let height = Int((Double(cg.height) * 0.045).rounded(.up)),
        let strip = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: height)),
        case let scale = max(1, 1280 / max(cg.width, 1)),
        let ctx = CGContext(
            data: nil,
            width: cg.width * scale,
            height: height * scale,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
    else { return [] }
    ctx.interpolationQuality = .high
    ctx.draw(strip, in: CGRect(x: 0, y: 0, width: cg.width * scale, height: height * scale))
    guard let scaled = ctx.makeImage() else { return [] }
    return TextReader.read(scaled, languageCorrection: false).sorted { $0.x < $1.x }.map(\.text)
}

/// How far red and green are apart on average (0...255), either way: Core Animation's blended-layers tint, red where
/// layers blend and green where they're opaque (a 7.x Home screen turns red, a 3.x one mostly green).
func tint(of image: URL) -> Double {
    guard let input = CGImageSourceCreateWithURL(image as CFURL, nil),
        let cg = CGImageSourceCreateImageAtIndex(input, 0, nil),
        let ctx = CGContext(
            data: nil,
            width: 64,
            height: 96,
            bitsPerComponent: 8,
            bytesPerRow: 256,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return 0 }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 96))
    guard let data = ctx.data else { return 0 }
    let p = data.bindMemory(to: UInt8.self, capacity: 256 * 96)
    var sum = 0
    for i in stride(from: 0, to: 256 * 96, by: 4) {
        sum += abs(Int(p[i]) - Int(p[i + 1]))
    }
    return Double(sum) / Double(64 * 96)
}
