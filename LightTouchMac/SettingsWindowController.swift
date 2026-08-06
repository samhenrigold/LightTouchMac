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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
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

        let verbose = NSButton(checkboxWithTitle: "Verbose boot",
                               target: self, action: #selector(toggleVerbose(_:)))
        verbose.state = EmulatorController.verboseBoot ? .on : .off

        let verboseNote = NSTextField(wrappingLabelWithString:
            "Boot with -v, so the guest prints kernel messages over the Apple logo. "
            + "The only view of what the device is doing between iBoot and "
            + "SpringBoard. Takes effect at the next launch.")
        verboseNote.font = .systemFont(ofSize: 11)
        verboseNote.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [resume, note, verbose, verboseNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(18, after: note)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
    }

    @objc private func toggleVerbose(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: EmulatorController.verboseBootDefaultsKey)
    }

    @objc private func toggleResume(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: EmulatorController.resumeDefaultsKey)
    }

    func show() {
        // Only on first use — setFrameAutosaveName already restored a saved
        // position, and centering every time discarded wherever the user put it.
        if window?.setFrameUsingName("Settings") != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
