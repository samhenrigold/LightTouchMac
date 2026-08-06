// Created by Sam on 2026-08-06.
//
// A minimal, standard preferences window (⌘,). One setting today: whether the
// app resumes the saved emulator state on launch. Resume skips the ~40s cold
// boot, but it restores a snapshot whose host-side USB session is gone — which
// can leave the guest unresponsive a few seconds in — so it needs an off switch.

import Cocoa

@MainActor
final class SettingsWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 130),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false      // reused for the app's lifetime
        window.setFrameAutosaveName("Settings")
        self.init(window: window)
        buildContent()
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let resume = NSButton(checkboxWithTitle: "Automatically resume where you left off",
                              target: self, action: #selector(toggleResume(_:)))
        resume.state = EmulatorController.resumeOnLaunch ? .on : .off

        let note = NSTextField(wrappingLabelWithString:
            "When on, the device state is saved on quit and restored on the next "
            + "launch, skipping the cold boot. Turn this off if resuming leaves the "
            + "device frozen or unresponsive. Takes effect at the next launch.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [resume, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
    }

    @objc private func toggleResume(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: EmulatorController.resumeDefaultsKey)
    }

    func show() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
