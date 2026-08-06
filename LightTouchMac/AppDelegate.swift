// Created by Sam on 2026-08-05.

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var windowController: MainWindowController?
    private var emulator: EmulatorController?
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenuBuilder.install()
        #if DEBUG
        SpringBoardIcons.selfCheck()
        #endif
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let emulator = EmulatorController(options: .resolved())
        // Start before showing the window: the inspector checks the usbmux
        // session in its viewDidLoad, which runs during showWindow.
        emulator.start()
        
        let controller = MainWindowController(emulator: emulator)
        controller.showWindow(nil)
        
        self.emulator = emulator
        self.windowController = controller
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        emulator?.stop()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
