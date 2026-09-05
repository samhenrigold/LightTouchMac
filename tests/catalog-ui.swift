// Run via tests/run-catalog-checks.py --ui; uses an isolated local server and home.
import Cocoa

@main struct Check {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        UserDefaults.standard.set("http://127.0.0.1:\(CommandLine.arguments[1])", forKey: "LTMCatalogBaseURL")
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 510, height: 390),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "LightTouch Catalog Check"
        let delegate = Delegate(window: window)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    let window: NSWindow
    init(window: NSWindow) { self.window = window }
    func applicationDidFinishLaunching(_ note: Notification) {
        Task { @MainActor in
            do {
                SelectionCheck.run()
                let catalog = try await CatalogClient.compatibleCopy(123)
                var chosen: Int?
                let controller = CatalogDetailsViewController(app: catalog, canInstall: { true }) { chosen = $0.ipaID }
                let parent = NSViewController()
                parent.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 450))
                window.contentViewController = parent
                window.makeKeyAndOrderFront(nil)
                parent.presentAsSheet(controller)
                @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let picker = descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first!
                let button = descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Install This Version" }!
                for _ in 0..<100 {
                    if picker.numberOfItems == 2 && button.isEnabled { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                precondition(picker.numberOfItems == 2 && button.isEnabled)
                picker.selectItem(at: 1)
                picker.sendAction(picker.action!, to: picker.target)
                precondition(!button.isEnabled)
                for _ in 0..<100 {
                    if button.isEnabled { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                precondition(button.isEnabled)
                controller.view.layoutSubtreeIfNeeded()
                let rep = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds)!
                controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/ltm-catalog-sheet.png"))
                button.performClick(nil)
                precondition(chosen == 456)
                print("PASS: native version picker loads, revalidates selection and installs the selected copy")
                exit(0)
            } catch { print(error); exit(1) }
        }
    }
}
