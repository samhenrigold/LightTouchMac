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
        displayView.onDropCatalogApp = { [weak self] app in
            guard let self, self.emulator.canQueueInstall else { return }
            AppInstaller.startCatalog(app, with: self.emulator, presenting: self.view.window)
        }
    }
    
    required init?(coder: NSCoder) { fatalError("not used") }
    
    override func loadView() { view = displayView }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(displayView)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(appLaunched),
                                               name: .ltmAppLaunched, object: nil)
    }

    // MARK: - Tilt hint

    /// Nothing on screen suggests the accelerometer exists, so the first app
    /// launch earns a one-time capsule under the iPod pointing at drag-to-tilt.
    private static let tiltHintShownKey = "tiltHintShown"

    @objc private func appLaunched() {
        guard !UserDefaults.standard.bool(forKey: Self.tiltHintShownKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.tiltHintShownKey)

        let label = NSTextField(labelWithString: "Drag next to the iPod to tilt it side-to-side")
        label.font = .systemFont(ofSize: 11)
        // The device area is black in both appearances; fixed light text, not a
        // semantic color that would go dark-on-black in light mode.
        label.textColor = NSColor(white: 1, alpha: 0.8)
        label.translatesAutoresizingMaskIntoConstraints = false

        let capsule = NSView()
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        capsule.layer?.cornerRadius = 12
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(label)
        displayView.addSubview(capsule)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: capsule.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -5),
            capsule.centerXAnchor.constraint(equalTo: displayView.centerXAnchor),
            capsule.bottomAnchor.constraint(equalTo: displayView.bottomAnchor, constant: -12),
        ])

        capsule.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            capsule.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.8
                capsule.animator().alphaValue = 0
            }, completionHandler: { capsule.removeFromSuperview() })
        }
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
