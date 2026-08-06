// Created by Sam on 2026-08-05.
//
// Hosts the device screen in the window's main column. The DisplayView is the
// controller's view; it centres its content and becomes first responder so
// keyboard passthrough works whenever the device area has focus.

import Cocoa

final class DeviceViewController: NSViewController {
    
    let emulator: EmulatorController
    private let displayView: DisplayView
    
    init(emulator: EmulatorController) {
        self.emulator = emulator
        self.displayView = DisplayView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        super.init(nibName: nil, bundle: nil)
        displayView.emulator = emulator
        displayView.onDropIPA = { [weak self] url in self?.installDropped(url) }
        displayView.onZoomStep = { [weak self] direction in
            (self?.view.window?.windowController as? MainWindowController)?.stepZoom(direction)
        }
    }
    
    required init?(coder: NSCoder) { fatalError("not used") }
    
    override func loadView() { view = displayView }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(displayView)
    }
    
    var screen: DisplayView { displayView }
    
    func setZoom(_ zoom: ZoomMode) { displayView.zoom = zoom }
    
    /// The same preconditions the menu and toolbar enforce for Install App…
    /// A drop used to bypass all of them, so an .ipa dropped during the ~40s
    /// boot (or with app sync off) was accepted, put a spinner in a sidebar
    /// that wasn't even polling, and failed a moment later with a modal —
    /// while the button for the identical operation sat greyed out.
    private func installDropped(_ url: URL) {
        guard emulator.canManageApps, emulator.isRunning, !emulator.isInstalling else {
            let alert = NSAlert()
            alert.messageText = "The device isn’t ready yet"
            alert.informativeText = emulator.isInstalling
                ? "Another app is being installed. Wait for it to finish, then try again."
                : "Apps can be installed once the device has finished starting up and USB is connected."
            if let window = view.window { alert.beginSheetModal(for: window) { _ in } }
            else { alert.runModal() }
            return
        }
        AppInstaller.start(url, with: emulator, presenting: view.window)
    }
}
