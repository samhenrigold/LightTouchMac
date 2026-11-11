// The device's orientation: the quarter turns the user asks for, and auto-rotation with the guest.
//
// Open a landscape-only app and the emulated iPod swings to landscape by
// itself; press home and it swings back. The signal comes from the guest,
// because on 3.1.3 there is nowhere else it can come from: SpringBoard's
// -[SpringBoard noteUIOrientationChanged:display:] updates an ivar and calls
// GSEventRotateSimulator() in-process, and posts nothing. The three
// com.apple.springboard.*Orientation Darwin notifications that notification_proxy
// WOULD have relayed are posted from the accelerometer path — they describe
// how the device is being held, which is the thing we are faking anyway —
// and springboardservicesrelay on 3.1.3 answers only getIconState /
// setIconState / getIconPNGData, so libimobiledevice's
// sbservices_get_interface_orientation has nothing to talk to.
//
// The guest agent reads SpringBoardServices' SBGetUIOrientation MIG stub
// (7E18's ABI; other builds answer ENOSYS and the shell stays put).
//
// EDGES, NOT LEVELS, is the rule that keeps this from fighting the user.
// We rotate when the guest's orientation *changes*; we never correct the
// shell towards the guest's steady state. The home screen is portrait-only
// on 3.1.3, so a levels rule would undo a manual rotation the instant it was
// made — the user turns the device, the guest stays at 0, and we would turn
// it straight back. With edges, a manual rotation the guest declines to
// follow simply stands, and a manual rotation the guest DOES follow reports
// the orientation we already moved to, so it lands on a no-op. The user only
// loses their manual angle when the front app actually changes what it wants,
// which is the moment they asked us to follow.
//
// TWO ANGLES, as on hardware: how the device is held (`heldDegrees`, the
// accelerometer, set by the user's turns) and how its interface stands
// (`degrees`, the shell, which follows the front app). A portrait-only app on
// an iPad held landscape turns the shell to portrait and leaves the
// accelerometer landscape, so when the app quits SpringBoard turns back to
// landscape and the shell follows it (issue 103). Every board's panel scans
// out as is, whatever way the device is held, so this holds for all of them.

import DeviceRuntime
import Foundation
import HostRuntime
import Observation

/// What the rotation reads of the session, and the guest's two orientation sources.
public protocol RotationHost: AnyObject {
    var bootScope: BootSessionScope { get }
    var helperLink: HelperLink? { get }
    var state: VMState { get }
    var preparingDevice: Bool { get }
    var isSleeping: Bool { get }
    var isInstalling: Bool { get }
    var canReachDevice: Bool { get }
    /// springboardservices' UIInterfaceOrientation (the iPad: 3.2's relay answers it, no guest tools needed).
    func interfaceOrientation() async throws -> Int
    /// SpringBoard's degrees through the guest agent; nil when this image has no agent.
    func guestOrientation() async throws -> Int?
    /// The UIInterfaceOrientation the guest agent last told (GuestReport.interfaceOrientation), a quarter second old
    /// at most and with no USB to wait for; nil where it tells none, and lockdown's relay is asked.
    var reportedInterfaceOrientation: Int? { get }
}

extension RotationHost {
    public var reportedInterfaceOrientation: Int? { nil }
}

@Observable public final class DeviceRotation {
    @ObservationIgnored private unowned let host: RotationHost
    @ObservationIgnored private let settings: DeviceSettingsFile
    /// The iPad sets its accelerometer outright (Board.orientationSource == .springBoard).
    @ObservationIgnored private let setsAccelerometer: Bool

    public init(host: RotationHost, settings: DeviceSettingsFile, setsAccelerometer: Bool) {
        self.host = host
        self.settings = settings
        self.setsAccelerometer = setsAccelerometer
    }

    /// The shell's angle as degrees turned clockwise from portrait: the way the
    /// interface stands, which a front app may turn away from how the device is
    /// held (heldDegrees). DisplayView poses the shell from this.
    /// Observed: the toolbar's rotate glyph shows which way the NEXT turn goes, so it follows an automatic
    /// rotation too, not just the three manual actions.
    public private(set) var degrees = 0
    public var isLandscape: Bool { degrees == 90 || degrees == 270 }
    /// How the device is held, in the same degrees: the accelerometer's angle. Only the user's turns (and a boot's
    /// adoption of the orientation iOS came back up in) move it, never a front app; a tilt rests on it. A machine
    /// stepped a quarter turn at a time (ipod_touch_kbd_rotate: portrait → 90 → 180 → 270) stands here, so every
    /// turn of the accelerometer goes through rotate(clockwise:) or it drifts out of step with the guest.
    public private(set) var heldDegrees = 0

    public func rotateLeft() { host.helperLink?.send(.rotate(clockwise: false)) }
    public func rotateRight() { host.helperLink?.send(.rotate(clockwise: true)) }

    /// Toggle between portrait and landscape: enter counter-clockwise (home
    /// button ends up on the right), leave by heading back the short way.
    public func toggle() {
        rotate(clockwise: degrees == 270)
    }

    /// Rotate a quarter turn in a named direction from how the interface stands; the device is then held as shown.
    public func rotate(clockwise: Bool) {
        let next = (degrees + (clockwise ? 90 : 270)) % 360
        if !setAccelerometer(for: next) {
            // A stepped machine moves from how it is held, which a front app's turn may have left apart from the shell.
            switch (next - heldDegrees + 360) % 360 {
            case 90: rotateRight()
            case 180:
                rotateRight()
                rotateRight()
            case 270: rotateLeft()
            default: break
            }
        }
        degrees = next
        heldDegrees = next
    }

    /// A fresh boot starts portrait. A helper still coming up can't take the accelerometer yet, and its machine
    /// starts portrait anyway, so that refusal isn't logged (it read as an error at every iPad and 3GS start).
    public func reset() {
        degrees = 0
        heldDegrees = 0
        setAccelerometer(for: 0, logRefusal: false)
    }

    /// The iPad sets its accelerometer outright for the shell's angle rather
    /// than stepping it: the machine moves it on its own (the power-off
    /// gesture), and a relative step from there lands on the wrong side.
    /// Values are UIDeviceOrientation: a clockwise turn from portrait (1) puts
    /// Home on the left (4), then upside down (2), then Home right (3).
    @discardableResult
    private func setAccelerometer(for degrees: Int, logRefusal: Bool = true) -> Bool {
        guard setsAccelerometer, let value = [0: 1, 90: 4, 180: 2, 270: 3][degrees] else { return false }
        // The machine answers asynchronously now; only an iPad takes this path,
        // and it always has the control, so a refusal is just logged.
        host.bootScope.control(.orientation(value), on: host.helperLink) { applied in
            if !applied && logRefusal { logEvent("rotation: the device refused orientation \(value)") }
        }
        return true
    }

    /// Quarter-turn our way to `target`, the short way round. Every step goes
    /// through rotate(clockwise:) so the guest and `degrees` stay in
    /// lockstep — this is a caller of the one source of truth, not a second one.
    func rotate(toward target: Int) {
        while true {
            let delta = (target - degrees + 360) % 360
            guard delta != 0 else { return }
            rotate(clockwise: delta != 270)  // 90 and 180 go clockwise, 270 back
        }
    }

    /// The front app turned the interface to `target`: the shell follows it, and the accelerometer stays as the
    /// device is held.
    func follow(_ target: Int) { degrees = target }

    // MARK: Auto-rotation

    /// Off switch, for anyone who would rather the device never move on its own. Per device
    /// (DeviceSettings.autoRotateWithGuest); on by default — it is only ever driven by an explicit change on the
    /// guest's side.
    public var autoRotateEnabled: Bool { settings.value.autoRotateWithGuest ?? true }
    public func toggleAutoRotate() {
        let enabled = !autoRotateEnabled
        settings.change { $0.autoRotateWithGuest = enabled }
    }

    /// The last value SpringBoard reported, in SpringBoard's degrees (0, 90,
    /// 180, -90). nil until the first line arrives — that first one only seeds
    /// this, so a watcher that attaches to an already-running guest never yanks
    /// the shell around on connect.
    @ObservationIgnored var lastGuestOrientation: Int?
    private var task: Task<Void, Never>? {
        get { host.bootScope[.orientation] }
        set { host.bootScope[.orientation] = newValue }
    }
    public func stopWatching() { task?.cancel() }

    /// SpringBoard's degrees are the angle the *content* is rotated by; ours are
    /// the angle the *device* is turned clockwise. They are mirror images.
    ///
    /// From -[SBApplication defaultStatusBarOrientation]: UIInterfaceOrientation
    /// Portrait → 0, PortraitUpsideDown → 180, LandscapeLeft → 90, LandscapeRight
    /// → -90. UIInterfaceOrientationLandscapeLeft is the one with the home button
    /// on the RIGHT, which is the device turned 270° clockwise — hence the flip.
    static func hostDegrees(forGuest degrees: Int) -> Int? {
        switch degrees {
        case 0: return 0
        case 180: return 180
        case 90: return 270  // LandscapeLeft:  home button right
        case -90, 270: return 90  // LandscapeRight: home button left
        default: return nil  // a torn line, or a value we don't know
        }
    }

    func guestOrientationChanged(to degrees: Int) {
        guard let target = Self.hostDegrees(forGuest: degrees) else { return }
        defer { lastGuestOrientation = degrees }
        // First reading seeds only: see lastGuestOrientation.
        guard let previous = lastGuestOrientation, previous != degrees else { return }
        guard autoRotateEnabled, host.state == .running else { return }
        follow(target)
    }

    /// The iPad: 3.2's springboardservicesrelay answers getInterfaceOrientation,
    /// so no guest tools are needed. iOS comes back up in the orientation it
    /// last had while the app starts every process portrait, so the first
    /// reading after boot is adopted, shell and accelerometer; after that only
    /// changes are followed, by the shell alone (the edges rule above).
    public func startInterfaceWatch() {
        task?.cancel()
        task = Task { [weak self] in
            var last: Int?
            while !Task.isCancelled {
                // Told by the guest agent, as often as it samples; else lockdown's relay is asked every 3 s.
                let told = self?.host.reportedInterfaceOrientation != nil
                try? await Task.sleep(for: told ? .milliseconds(250) : .seconds(3))
                guard let self else { return }
                if host.state == .booting { last = nil }  // a restart: adopt again
                guard !host.isSleeping, !host.isInstalling else { continue }
                if let reading = host.reportedInterfaceOrientation {
                    last = interfaceRead(reading, last: last)
                    continue
                }
                // Only once lockdown has answered: before that every try is "not reachable over USB yet", every 3 s in the log.
                guard host.canReachDevice, let reading = try? await host.interfaceOrientation() else { continue }
                last = interfaceRead(reading, last: last)
            }
        }
    }

    /// One reading of the iPad's interface orientation; returns it as the next `last`.
    public func interfaceRead(_ reading: Int, last: Int?) -> Int? {
        guard let target = Self.iPadDegrees(forInterface: reading) else { return last }
        guard target != degrees else { return reading }
        if last == nil {
            rotate(toward: target)
        } else if last != reading && autoRotateEnabled {
            follow(target)
        }
        return reading
    }

    /// SpringBoard's UIInterfaceOrientation -> the app's clockwise device
    /// angle, as on hardware: upright is Portrait (1); turned clockwise, Home
    /// is on the left and the UI is LandscapeLeft (4); then upside down (2);
    /// then LandscapeRight (3).
    public static func iPadDegrees(forInterface orientation: Int) -> Int? {
        [1: 0, 4: 90, 2: 180, 3: 270][orientation]
    }

    /// Keeps one reporter alive for as long as the app runs, re-attaching after
    /// a boot, a respring, or a dropped USB session — the same "the guest drops
    /// its services and comes back" reality NotificationProxy backs off around.
    public func startGuestWatch() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if host.state == .running, !host.preparingDevice, !host.isSleeping, !host.isInstalling {
                    let generation = host.bootScope.generation
                    do {
                        if let degrees = try await host.guestOrientation() {
                            try Task.checkCancellation()
                            guard generation == host.bootScope.generation else { continue }
                            guestOrientationChanged(to: degrees)
                        }
                    } catch {
                        if Task.isCancelled { return }
                        lastGuestOrientation = nil
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    }
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }
}
