import GameController
import Foundation

/// Polled on the existing display tick. No callback queue or extra timer.
struct GameControllerInput {
    struct State {
        var roll = 0.0, pitch = 0.0
        var tapBegan = false, tapEnded = false, home = false, shake = false
    }
    private var controller: ObjectIdentifier?
    private var tap = false, menu = false, options = false
    private var suppressTap = false

    mutating func read(_ source: GCController?, enabled: Bool, curve: Double) -> State {
        let identity = source.map(ObjectIdentifier.init)
        let changed = identity != controller
        controller = identity
        let pad = source?.extendedGamepad
        let a = pad?.buttonA.isPressed ?? false
        let m = pad?.buttonMenu.isPressed ?? false
        let o = pad?.buttonOptions?.isPressed ?? false
        if changed || !enabled { suppressTap = a }
        if !a { suppressTap = false }
        let pressed = enabled && !suppressTap && a
        var result = State()
        result.tapBegan = pressed && !tap
        result.tapEnded = tap && (!pressed || changed)
        result.home = enabled && !changed && m && !menu
        result.shake = enabled && !changed && o && !options
        tap = pressed; menu = m; options = o
        if enabled, let pad {
            result.roll = Self.angle(Double(pad.leftThumbstick.xAxis.value), curve: curve)
            result.pitch = Self.angle(Double(pad.leftThumbstick.yAxis.value), curve: curve)
        }
        return result
    }
    static func angle(_ value: Double, curve: Double) -> Double {
        guard value.isFinite else { return 0 }
        let magnitude = min(max((abs(value) - 0.1) / 0.9, 0), 1)
        return (value < 0 ? -1 : 1) * pow(magnitude, curve == 2 ? 2 : 1) * .pi / 4
    }
    static var enabled: Bool { UserDefaults.standard.object(forKey: "controllerEnabled") as? Bool ?? true }
    static var curve: Double { UserDefaults.standard.double(forKey: "controllerCurve") == 2 ? 2 : 1 }
    static func coordinate(_ key: String) -> Double {
        guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber else { return 0.5 }
        let value = number.doubleValue
        return value.isFinite ? min(max(value, 0), 1) : 0.5
    }
}
