import Cocoa

/// Every launch builds a new Mac interface. This does not govern guest snapshots
/// or the explicit capture/toolbar preferences stored by the app.
enum WindowRestorationPolicy {
    static func configureDefaults(_ defaults: UserDefaults = .standard) {
        // Apply before NSApplication is created, including after an unclean exit.
        // A volatile override cannot become a sticky preference for other apps.
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["NSQuitAlwaysKeepsWindows"] = false
        arguments["ApplePersistenceIgnoreState"] = true
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    static func configure(_ window: NSWindow) {
        window.isRestorable = false
        window.restorationClass = nil
        window.disableSnapshotRestoration()
        window.setFrameAutosaveName("")
    }
}

/// AppKit's restoration funnel remains closed even if an older saved archive
/// survives an upgrade or a launch request explicitly asks to restore it.
@objc(LightTouchApplication)
final class LightTouchApplication: NSApplication {
    override func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier,
                                state: NSCoder,
                                completionHandler: @escaping (NSWindow?, (any Error)?) -> Void) -> Bool {
        completionHandler(nil, nil)
        return true
    }

    // Intentionally omit super: it would encode/decode AppKit's saved interface.
    override func restoreState(with coder: NSCoder) {}
    override func encodeRestorableState(with coder: NSCoder) {}
    override func encodeRestorableState(with coder: NSCoder, backgroundQueue: OperationQueue) {}
}
