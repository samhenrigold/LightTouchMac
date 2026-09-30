// Run via tests/offline/run-catalog-checks.py --ui. The version sheet is tests/offline/check-store-ui.py.
import Cocoa

@main struct Check {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        SelectionCheck.run()
    }
}
