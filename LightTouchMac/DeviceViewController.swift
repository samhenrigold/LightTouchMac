// Created by Sam on 2026-08-05.
//
// Hosts the device screen in the window's main column. The DisplayView is the
// main content; it centres its content and becomes first responder so
// keyboard passthrough works whenever the device area has focus.

import Cocoa

final class DeviceViewController: NSViewController {
    
    let emulator: EmulatorController
    private let displayView: DisplayView
    
    init(emulator: EmulatorController) {
        self.emulator = emulator
        self.displayView = DisplayView(frame: NSRect(origin: .zero, size: emulator.profile.screenPixels), profile: emulator.profile)
        super.init(nibName: nil, bundle: nil)
        displayView.emulator = emulator
        displayView.onDropIPA = { [weak self] url in self?.installDropped(url) }
        // Media import runs through the iPod's guest tools; the iPad has none,
        // so its screen doesn't take media drops (Import Media… is disabled too).
        if emulator.hasGuestTools {
            displayView.onDropMedia = { [weak self] url in
                guard let self, self.emulator.canQueueInstall else { return }
                AppInstaller.startMedia(url, with: self.emulator, presenting: self.view.window)
            }
        }
        displayView.onDropUnsupportedFiles = { [weak self] urls in
            guard let self else { return }
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = urls.count == 1
                ? "“\(urls[0].lastPathComponent)” wasn’t imported"
                : "\(urls.count) files weren’t imported"
            alert.informativeText = "Choose IPA apps, JPEG, PNG or HEIC photos, MP3, M4A, AAC or WAV audio, or MP4, M4V or QuickTime videos."
            if let window = self.view.window { alert.beginSheetModal(for: window) }
        }
        displayView.onDropCatalogApp = { [weak self] app in
            guard let self, self.emulator.canQueueInstall else { return }
            AppInstaller.startCatalog(app, with: self.emulator, presenting: self.view.window)
        }
    }
    
    required init?(coder: NSCoder) { fatalError("not used") }
    
    override func loadView() { view = DeviceContentView(screen: displayView) }

    func addStatus(_ status: NSView) { (view as? DeviceContentView)?.addStatus(status) }
    func updateStatusVisibility() { (view as? DeviceContentView)?.updateStatusVisibility() }
    
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
        // Deliberately NOT gated on isInstalling: AppInstaller queues each job
        // when their bytes are ready, so dropping another IPA is supported.
        // Refusing it was a regression — dropping three at once is the whole
        // point of accepting multiple files.
        guard emulator.canQueueInstall else {
            let alert = NSAlert()
            alert.messageText = "The device isn’t ready yet"
            alert.informativeText =
                "Apps can be installed once the device has finished starting up and USB is connected."
            if let window = view.window { alert.beginSheetModal(for: window) { _ in } }
            else { alert.runModal() }
            return
        }
        AppInstaller.start(url, with: emulator, presenting: view.window)
    }
}
