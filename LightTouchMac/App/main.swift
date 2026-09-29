// Created by Sam on 2026-08-05.

import Cocoa

// Top-level, so it is retained for the process lifetime (NSApplication.delegate
// is a weak reference). Program entry is the main thread; assumeIsolated lets
// the delegate's MainActor-isolated conformance be assigned without a hop.
logEvent("Light Touch started")
WindowRestorationPolicy.configureDefaults()
let delegate = AppDelegate()
MainActor.assumeIsolated {
    LightTouchApplication.shared.delegate = delegate
}
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
