
// The app no longer links libqemu-arm.dylib: every device runs in its own
// LightTouchDevice helper, reached through Shared/DeviceLink.swift (whose C
// glue is the LTMLinkC module, not this header).

// libimobiledevice is deliberately NOT included here. SpringBoard's icon
// layout needs it (there is no CLI for com.apple.springboardservices), but
// Homebrew builds its dylibs for whatever macOS the machine runs, and linking
// one would stop the app launching below that version -- see IMobileDevice.swift,
// which loads the few entry points at runtime instead.
