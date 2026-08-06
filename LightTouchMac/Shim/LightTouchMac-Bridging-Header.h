// The C ABI into libqemu-arm.dylib. Headers live in the qemu-ios checkout;
// QEMU_IOS_DIR (a build setting) puts their directories on the search path.

#include "qemu-ios-ui.h"
#include "qemu-macos-extras.h"

// libimobiledevice is deliberately NOT included here. SpringBoard's icon
// layout needs it (there is no CLI for com.apple.springboardservices), but
// Homebrew builds its dylibs for whatever macOS the machine runs, and linking
// one would stop the app launching below that version -- see IMobileDevice.swift,
// which loads the few entry points at runtime instead.
