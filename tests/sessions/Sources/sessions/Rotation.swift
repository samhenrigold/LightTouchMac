import CoreGraphics
import Foundation
import ImageIO
import SessionKit

/// `sessions rotation BASE [--overlay DIR]`: the app's Rotate Right and Rotate Left (DeviceRotation, the control this
/// board takes) with Safari in front, and the picture as the window shows it (PanelCapture): upright in portrait, a
/// clockwise turn and a counter-clockwise turn, each judged by where Vision reads the status bar's clock (centered at
/// the top); then a tap on the address field as shown brings the keyboard up (the touch lands where it was aimed).
/// Then the device stays held landscape while the interface turns without it (issue 103): Home, portrait-only on the
/// iPhone and iPod, turns the interface to portrait and the shell follows, the device still held landscape; Safari
/// opened again comes up landscape and the shell turns back. With Auto-Rotate with Device off, the shell stays where the
/// device is held. The interface is read off each frame as published (where the status bar's clock stands) and handed
/// to the app's rotation as its watch does; every frame keeps the panel's scan, whatever way the device is held.
/// The helper alone boots the base, with no lockdown activation: a 2.x base would stay at Connect to iTunes, and a
/// 5.x-7.x base not prepared --skip-setup in Setup, so those boot from the overlay of a first boot as the app boots
/// them (activatedOverlay), or --overlay's, cloned.
func rotationCheck(_ args: RotationCheck) -> Never {
    let base = Base(args.base, args.inputs)
    let work = workDirectory(args.inputs, "rotation")
    let tools = Tools.resolve(args.inputs, work: work)
    let r = Report()
    if let source = args.overlay ?? activatedOverlay(base, args.inputs, work: work) {
        let overlay = work.appendingPathComponent("rotation/overlay")
        try? FileManager.default.createDirectory(
            at: overlay.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        run("/bin/cp", ["-cR", source.path, overlay.path])  // a clone: the source stays as it was
    }
    // The lock screen's slider and Safari's address field as the window shows them (the iPad's panel lies on its side).
    let iPad = base.board == "k48ap"
    let slide = iPad ? "dragshown 0.36 0.935 0.8 0.935" : "dragshown 0.18 0.9 0.92 0.9"
    let field = iPad ? "tapshown 0.4 0.072" : "tapshown 0.4 0.18"
    let d = HelperDriver(
        "rotation",
        tools: tools,
        work: work,
        scenario: preparedScenario(
            base,
            tools: tools,
            work: work,
            name: "rotation",
            steps: [
                // Home first: the S5L8920 boards power the digitizer down on the lock screen; their first slide
                // after boot can go unanswered, so twice (on the Home screen the second is a page swipe).
                // Connect Hardware Keyboard off, as a user who types on the screen boots: with the USB keyboard in,
                // 7.x keeps its on-screen keyboard down (and on the iPhone 4 refuses it with an alert).
                "boot", "lit 0.03 300", "keyboard off", "wait 5", "button 0", "wait 2", slide, "wait 4", "button 0",
                "wait 2", slide,
                // The app's watch takes its first reading (portrait at Home) as the boot's, before any turn.
                "wait 4", "shot home", "follow start",
                // Safari through the guest agent; without one (iPhone OS 1), its Home screen icon.
                "agentop launch com.apple.mobilesafari", "wait 8", "tapword Safari -0.06", "wait 10",
                // A first launch's alerts and Safari's bookmarks sheet (Done again: a tap while Safari opens can be lost).
                "tapword OK", "wait 2", "tapword Dismiss", "wait 2", "tapword Dismiss", "wait 2", "tapword Done",
                "wait 3", "tapword Done",
                "wait 4", "shot portrait",
                "turn cw", "wait 5", "shot cw",
                "turn ccw", "wait 3", "turn ccw", "wait 5", "shot ccw",
                field, "wait 4", "shot typing",
                // Held landscape: Home and back to Safari, then the same with auto-rotation off.
                "follow held", "button 0", "wait 6", "follow home", "shot home-held",
                "agentop launch com.apple.mobilesafari", "wait 8", "tapword Safari -0.06", "wait 10",
                "follow back", "shot back",
                "autorotate off", "button 0", "wait 6", "follow locked",
                "agentop launch com.apple.mobilesafari", "wait 8", "tapword Safari -0.06", "wait 10",
                "follow locked-back", "autorotate on",
                "quit", "expectExit 60"
            ]
        )
    )
    r.check(d.finish(1500) == 0, "rotation: scenario completed")
    var shots: [String: URL] = [:]
    for e in d.events.find("shot") where e.bool("ok") {
        if let name = e.string("name"), let path = e.string("path") { shots[name] = URL(fileURLWithPath: path) }
    }
    for (name, landscape) in [("portrait", false), ("cw", true), ("ccw", true)] {
        guard let url = shots[name], let image = loadImage(url) else {
            r.check(false, "rotation: \(name): no picture")
            continue
        }
        let (ok, at) = upright(image)
        r.check(
            (image.width > image.height) == landscape && ok,
            "rotation: \(name): the picture as shown is upright \(landscape ? "landscape" : "portrait") "
                + "(\(image.width)x\(image.height), the status bar's \(at))"
        )
    }
    heldChecks(d, r, iPad: iPad, major: base.major, picture: shots["back"].flatMap(loadImage))
    if let before = shots["ccw"].flatMap(loadImage), let after = shots["typing"].flatMap(loadImage) {
        let change = abs(bottomLuminance(after) - bottomLuminance(before))
        r.check(
            change > 0.08 && upright(after).ok,
            "rotation: a tap on the address field as shown brings the keyboard up, upright (bottom band's luminance "
                + "moved \(format(change, 2)))"
        )
    } else {
        r.check(false, "rotation: no picture of the tap")
    }
    finish(r, work: work)
}

/// Issue 103's shape on every board: the device held at 270 (`turn ccw` twice from 90), so the interface and the shell
/// stand at 270 in Safari; Home turns the interface to portrait (the iPad's Home follows the device and stays at 270)
/// and the shell follows it, the device still held at 270; Safari again stands at 270 with the shell. Auto-rotation
/// off: the shell stays where Safari left it, at Home and back. At every reading the device stays held at 270: no front app turns it. iPhone OS
/// 3 and earlier open Safari portrait again with the device held at 270 (they turn an app on the accelerometer's next
/// change, which a device held still never makes), so there it is the shell's following the interface that is checked.
/// Every dumped frame keeps the first one's size: the panel's scan is the same whatever way the device is held.
private func heldChecks(_ d: HelperDriver, _ r: Report, iPad: Bool, major: Int, picture: CGImage?) {
    let home = iPad ? 270 : 0
    let back = major >= 4 ? 270 : nil
    let followed = Dictionary(
        d.events.find("followed").compactMap { e in e.string("name").map { ($0, e) } },
        uniquingKeysWith: { a, _ in a }
    )
    // Auto-rotation off keeps the shell where Safari left it.
    let kept = followed["back"]?.int("degrees") ?? -2
    let want: [(String, interface: Int?, shell: Int?)] = [
        ("held", 270, 270), ("home", home, home), ("back", back, back), ("locked", home, kept),
        ("locked-back", back, kept)
    ]
    for (name, interface, shell) in want {
        let e = followed[name]
        let (i, s, h) = (e?.int("interface") ?? -2, e?.int("degrees") ?? -2, e?.int("held") ?? -2)
        r.check(
            i >= 0 && i == (interface ?? i) && s == (shell ?? i) && h == 270,
            "rotation: \(name): the interface at \(interface.map(String.init) ?? "any"), the shell at "
                + "\(shell.map(String.init) ?? "the interface's"), the device held at 270 (read \(i), \(s), \(h))"
        )
    }
    if back != nil {
        let (ok, at) = picture.map(upright) ?? (false, "no picture")
        r.check(
            picture.map { $0.width > $0.height } == true && ok,
            "rotation: back in Safari the picture as shown is upright landscape (\(at))"
        )
    }
    let sizes = d.events.find("dump").compactMap { e -> String? in
        guard e.bool("ok"), let w = e.int("width"), let h = e.int("height") else { return nil }
        return "\(w)x\(h)"
    }
    r.check(
        sizes.count > 5 && Set(sizes).count == 1,
        "rotation: every published frame keeps the panel's scan (\(Set(sizes).sorted().joined(separator: ", ")))"
    )
}

private func loadImage(_ url: URL) -> CGImage? {
    CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
}

/// Where the status bar's clock reads, if Vision finds one: its center (top-left origin, 0...1). Vision reads text at
/// any angle, so the clock's place, not its legibility, says which way up the picture is: upright, it is centered in
/// the top band.
private func clock(_ image: CGImage) -> (x: Double, y: Double)? {
    TextReader.clock(in: TextReader.read(image)).map { ($0.x, $0.y) }
}

private func upright(_ image: CGImage) -> (ok: Bool, at: String) {
    guard let c = clock(image) else { return (false, "no clock read") }
    return (c.y < 0.08 && abs(c.x - 0.5) < 0.2, "clock at \(format(c.x, 2)), \(format(c.y, 2))")
}

/// Mean luminance (0...1) of the bottom 40% of the image, where the keyboard comes up.
private func bottomLuminance(_ image: CGImage) -> Double {
    let w = image.width
    let h = image.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard
        let ctx = CGContext(
            data: &px,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    else { return 0 }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var sum = 0.0
    var n = 0
    for y in (h * 6 / 10)..<h {
        for x in stride(from: 0, to: w, by: 2) {
            let i = (y * w + x) * 4
            sum += 0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])
            n += 1
        }
    }
    return n == 0 ? 0 : sum / Double(n) / 255
}

/// The overlay of a first boot as the app boots the base (`sessions single`, no install, its work kept under
/// `work`), for a base the helper alone can't bring to the Home screen; nil for the rest. iPhone OS 2 out of the box
/// stays at Connect to iTunes until a host activates it and sets its clock over lockdown, as the app does at every
/// boot; iOS 5 and later sit in Setup until it is walked, unless prepared --skip-setup.
func activatedOverlay(_ base: Base, _ inputs: Inputs, work: URL) -> URL? {
    guard base.major == 2 || base.bootsIntoSetup else { return nil }
    let boot = work.appendingPathComponent("activation")
    print("\(base.version): a first boot as the app boots it, for its overlay (sessions single, in \(boot.path))")
    guard
        sessions(["single", base.url.path, "--no-install", "--keep-work", "--work", boot.path], inputs) == 0
    else { die("the first boot failed: see \(boot.path)") }
    return boot.appendingPathComponent(base.driverBoard).appendingPathComponent("overlay")
}
