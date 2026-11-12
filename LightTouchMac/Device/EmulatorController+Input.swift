import Cocoa
import DeviceRuntime
import FirmwareSchema
import HostRuntime
import HostServiceClient
import HostServiceWire
import LightTouchCore
import Observation

extension EmulatorController {
    // MARK: - Input
    typealias Button = DeviceInput.Button
    func pressHome() { input.tap(.home) }
    func pressLock() { input.tap(.power) }
    func pressVolumeUp() { input.tap(.volumeUp) }
    func pressVolumeDown() { input.tap(.volumeDown) }
    func rotateLeft() { rotation.rotateLeft() }
    func rotateRight() { rotation.rotateRight() }
    var shakeGeneration: UInt64 { input.shakeGeneration }
    func shake() { input.shake() }
    typealias MotionPose = DeviceInput.MotionPose
    var motionPose: MotionPose { input.motionPose }
    func setMotionPose(_ pose: MotionPose) { input.setMotionPose(pose) }
    func setTilt(angle: Double, pitch: Double = 0) { input.setTilt(angle: angle, pitch: pitch) }
    func pasteToGuest(_ text: String) { input.paste(text) }
    func typeText(_ text: String, shiftHeld: Bool) { input.typeText(text, shiftHeld: shiftHeld) }
    func typeThroughAgent(_ text: String) async -> Bool { await guest.type(text) }

    /// A control request; `done(true)` when the machine applied it (false on a
    /// machine without the control, the iPod, or from a helper that's gone).
    func control(_ request: LinkRequest, _ done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        bootScope.control(request, on: link, done)
    }

    // MARK: - Compass
    var hasCompass: Bool { profile.hasCompass }
    func setCompassHeading(_ degrees: Int) {
        control(.compass(degrees)) { [weak self] applied in if applied { self?.compassHeading = degrees } }
    }

    // Location comes later (a4-iboot's location responder); it will sit here
    // beside the compass as another control request.

    // MARK: - Rotation
    var rotationDegrees: Int { rotation.degrees }
    var isLandscape: Bool { rotation.isLandscape }
    var heldDegrees: Int { rotation.heldDegrees }
    func toggleRotation() { rotation.toggle() }
    func rotate(clockwise: Bool) { rotation.rotate(clockwise: clockwise) }
    var autoRotateEnabled: Bool { rotation.autoRotateEnabled }
    func toggleAutoRotate() { rotation.toggleAutoRotate() }
    func startOrientationWatch() {
        if hasGuestTools { rotation.startGuestWatch() } else { rotation.startInterfaceWatch() }
    }
    func resetRotation() { rotation.reset() }

    // MARK: - Carrier (radio boards)
    var hasCellular: Bool { carrier.hasCellular }
    var carrierSettings: CarrierSettings { carrier.carrierSettings }
    @discardableResult
    func setCarrierSettings(_ settings: CarrierSettings) -> Bool { carrier.setCarrierSettings(settings) }
    func modem(_ property: String, _ value: String, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        carrier.modem(property, value, done: done)
    }
    func modemStatus(_ done: @escaping @MainActor (ModemStatus?) -> Void) { carrier.modemStatus(done) }

    // MARK: - Keyboard passthrough
    var keyboardInputEnabled: Bool { keyboard.enabled }
    func toggleKeyboardInput() { keyboard.toggleEnabled() }
    /// Connect Hardware Keyboard (⇧⌘K, per device): unplugged, iOS shows its on-screen keyboard in a text field.
    var hardwareKeyboardConnected: Bool { keyboard.hardwareConnected }
    func toggleHardwareKeyboard() { keyboard.toggleHardware() }
    func sendKey(macKeyCode: UInt16, down: Bool) { keyboard.sendKey(macKeyCode: macKeyCode, down: down) }
}
