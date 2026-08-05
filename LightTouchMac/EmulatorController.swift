// Created by Sam on 2026-08-05.
//
// Owns the emulator: builds argv/env from the parsed launch options, starts
// usbmuxd (for app management) before handing the main loop to a background
// thread, and exposes device input + app operations to the UI. QEMU can only
// be started once per process, so this is a single-shot controller.

import Cocoa

@MainActor
final class EmulatorController {
    
    let options: LaunchOptions
    private let usbmux = USBMux()
    private var started = false
    
    init(options: LaunchOptions) {
        self.options = options
    }
    
    /// Per-user machine state (the NAND copy-on-write overlay + logs).
    private var stateDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LightTouchMac", isDirectory: true)
    }
    
    // MARK: - Boot
    
    func start() {
        guard !started else { return }
        started = true
        
        // One overlay per base image, so an overlay is never replayed onto a
        // different NAND (which would shadow unrelated blocks).
        let overlay = stateDir.appendingPathComponent("nandrw-\(options.nand)", isDirectory: true)
        try? FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        
        setBootEnv()
        
        // usbmuxd must be listening before the guest USB core comes up.
        if options.appsync,
           let session = usbmux.start(filesRoot: options.filesRoot,
                                      nand: options.nand, overlay: overlay.path) {
            setenv("IT_USB_TCP", session.guestAddress, 1)
            setenv("IT_OSK", "1", 1)   // appsync runs imply the on-screen keyboard
        }
        
        var machine = "iPod-Touch"
        + ",bootrom=\(options.bootrom)"
        + ",nand=\(options.nandImage)"
        + ",nor=\(options.nor)"
        + ",nandrw=\(overlay.path)"
        if options.network {
            machine += ",wifi=on"          // brings up the emulated BCM4325
        }
        
        var argv = [
            "LightTouchMac",
            "-M", machine,
            "-m", options.memory,
            "-display", "none",
            "-serial", "file:\(stateDir.path)/serial.log",
        ]
        if options.network {
            argv += ["-netdev", "user,id=wifi0"]   // host networking via slirp
        }
        
        qemu_ios_ui_attach(nil, nil)
        
        let thread = Thread {
            var cargs = argv.map { strdup($0) }
            cargs.append(nil)
            _ = qemu_ios_main(Int32(argv.count), &cargs)
        }
        thread.name = "qemu-main"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 16 << 20
        thread.start()
    }
    
    func stop() {
        usbmux.stop()
    }
    
    // MARK: - Hardware buttons
    
    private static let holdInterval: TimeInterval = 0.25
    
    private func tapButton(_ button: Int32) {
        qemu_ios_ui_button(button, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdInterval) {
            qemu_ios_ui_button(button, false)
        }
    }
    
    func pressHome()       { tapButton(Int32(QEMU_IOS_BUTTON_HOME)) }
    func pressLock()       { tapButton(Int32(QEMU_IOS_BUTTON_POWER)) }
    func pressVolumeUp()   { tapButton(Int32(QEMU_IOS_BUTTON_VOLUME_UP)) }
    func pressVolumeDown() { tapButton(Int32(QEMU_IOS_BUTTON_VOLUME_DOWN)) }
    func rotateLeft()      { qemu_ios_ui_rotate(false) }
    func rotateRight()     { qemu_ios_ui_rotate(true) }
    func shake()           { qemu_ios_ui_shake() }
    
    /// Toggle between portrait and landscape. The guest rotate is a 90° edge
    /// event, so we alternate direction to swing back and forth. Exposed so
    /// the toolbar can show which way the *next* press will rotate.
    private(set) var isLandscape = false
    func toggleRotation() {
        isLandscape ? rotateLeft() : rotateRight()
        isLandscape.toggle()
    }
    
    // MARK: - Keyboard passthrough
    
    /// Forward a host key by its macOS virtual keycode; the shim maps it to a
    /// QKeyCode exactly as ui/cocoa.m does.
    func sendKey(macKeyCode: UInt16, down: Bool) {
        qemu_ios_ui_key_mac(Int32(macKeyCode), down)
    }
    
    // MARK: - Machine control
    
    func pause()     { qemu_ios_ui_pause() }
    func resume()    { qemu_ios_ui_resume() }
    func reset()     { qemu_ios_ui_reset() }
    func powerDown() { qemu_ios_ui_powerdown() }
    
    func pasteToGuest(_ text: String) { qemu_ios_ui_paste(text) }
    
    // MARK: - App management
    
    var canManageApps: Bool { usbmux.session != nil }
    
    private func tools() throws -> DeviceTools {
        guard let session = usbmux.session else {
            throw DeviceToolsError.failed("The device is not reachable over USB yet.")
        }
        return DeviceTools(clientSocket: session.clientSocket, filesRoot: options.filesRoot)
    }
    
    func installedApps() async throws -> [InstalledApp] { try await tools().installedApps() }
    func install(_ ipa: URL) async throws -> String     { try await tools().install(ipa) }
    func uninstall(_ bundleID: String) async throws      { try await tools().uninstall(bundleID) }
    func openTerminal() async throws                     { try await tools().openTerminal() }
    
    // MARK: - Boot environment
    
    private func setBootEnv() {
        // The settings 3.1.3 will not boot without, plus the code-signing gate
        // (values from contrib/run-ipod-touch.sh).
        let env = [
            "IT_LCD_BRIGHT": "255",
            "IT_DIRECT_IBOOT": options.iBoot,
            "IT_WDT_NORESET": "1",
            "IT_TVOUT_READY": "1",
            "IT_TVOUT_VBLANK": "1",
            "IT_IMG3_SIG_ASIS": "1",   // restores the Apple boot logo on 3.1.3
            "IT_BOOT_ARGS": "amfi_allow_any_signature=1 cs_enforcement_disable=1",
            "IT_BOOT_ARGS_DELAY_MS": "1500",
            "IT_BOOT_ARGS_REPEAT": "200",
            "IT_BOOT_ARGS_INTERVAL_MS": "250",
        ]
        for (k, v) in env { setenv(k, v, 1) }
    }
}
