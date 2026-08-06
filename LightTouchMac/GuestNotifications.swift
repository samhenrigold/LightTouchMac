// Created by Sam on 2026-08-06.
//
// Push instead of poll. iOS 3.1.3 already has notification_proxy, and it
// publishes application_installed / application_uninstalled — so the sidebar
// can be told the moment something changes on the device instead of asking
// every few seconds. The np symbols were loaded for exactly this and had gone
// unused; this is the consumer.
//
// Icon rearranges are the gap: SpringBoard publishes no notification for the
// layout, only install/uninstall. Those come from the emulator instead — the
// layout cannot reach flash without crossing the emulated NAND, which counts
// the writes and lets us watch a counter. See qemu_ios_ui_icon_state_generation.
//
// None of it replaces the poll outright: a dropped USB session would leave the
// list silently frozen either way. So the poll stays as a slow backstop and
// these two make the common cases instant.

import Foundation

/// A long-lived notification_proxy session. One per device; `start` is
/// idempotent and the watcher re-establishes itself if the link drops.
@MainActor
final class GuestNotifications {

    /// What the guest actually publishes on 3.1.3.
    ///
    /// nonisolated, like everything else the session touches: `observeOnce`
    /// runs on a detached thread and the C callback on libimobiledevice's own,
    /// so none of this may be main-actor bound.
    nonisolated private static let observed = [
        "com.apple.mobile.application_installed",
        "com.apple.mobile.application_uninstalled",
    ]

    private var running = false
    private let socket: String
    /// Handed to the C callback; retained for the session's whole life and
    /// released only after np_client_free has joined the callback thread.
    nonisolated private final class Sink: @unchecked Sendable {
        let fire: @Sendable () -> Void
        init(_ fire: @escaping @Sendable () -> Void) { self.fire = fire }
    }

    init(clientSocket: String) { self.socket = clientSocket }

    /// The C callback runs on libimobiledevice's own thread: decode nothing,
    /// block on nothing, just hand off.
    nonisolated private static let callback: IMobileDevice.NpNotifyCB = { _, userData in
        guard let userData else { return }
        Unmanaged<Sink>.fromOpaque(userData).takeUnretainedValue().fire()
    }

    func start(onChange: @escaping @Sendable () -> Void) {
        guard !running, IMobileDevice.isAvailable else { return }
        running = true
        let socket = self.socket

        // The home screen is the one change the guest will never announce, so
        // take it from underneath instead: the icon layout can only reach flash
        // through the emulated NAND, which now counts those writes for us (see
        // qemu_ios_ui_icon_state_generation). Reading it is an atomic load, so
        // a one-second tick costs less than the notification_proxy session
        // below does sitting idle, and still reads as instant next to the
        // 15-second poll it replaces.
        Task {
            var seen = qemu_ios_ui_icon_state_generation()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                // One rearrange is several NAND pages, and the plist goes
                // through the journal as well. Comparing once per tick collapses
                // the whole burst into a single refresh.
                let now = qemu_ios_ui_icon_state_generation()
                if now != seen {
                    seen = now
                    onChange()
                }
            }
        }

        Task.detached {
            // Re-establish on loss: the guest drops its services on reboot and
            // on a USB reset, and a watcher that gave up then would leave the
            // sidebar quietly stale for the rest of the session.
            while !Task.isCancelled {
                let ok = Self.observeOnce(socket: socket, onChange: onChange)
                // A failed attach usually means the guest is still booting;
                // a successful session that ended means the link dropped.
                try? await Task.sleep(for: .seconds(ok ? 2 : 10))
            }
        }
    }

    /// Opens one session and blocks until it dies. Returns whether it ever got
    /// as far as observing, so the caller can back off sensibly.
    private nonisolated static func observeOnce(socket: String,
                                                onChange: @escaping @Sendable () -> Void) -> Bool {
        let imd = IMobileDevice.self
        guard let idevice_new = imd.idevice_new,
              let start = imd.np_client_start_service,
              let observe = imd.np_observe_notification,
              let setCB = imd.np_set_notify_callback else { return false }
        setenv("USBMUXD_SOCKET_ADDRESS", socket, 1)

        var device: OpaquePointer?
        guard idevice_new(&device, nil) == imd.success, let device else { return false }
        defer { _ = imd.idevice_free?(device) }

        var client: OpaquePointer?
        guard start(device, &client, "LightTouchMac") == imd.success, let client else { return false }

        for name in observed {
            _ = name.withCString { observe(client, $0) }
        }

        let sink = Sink(onChange)
        let ctx = Unmanaged.passRetained(sink).toOpaque()
        guard setCB(client, callback, ctx) == imd.success else {
            Unmanaged<Sink>.fromOpaque(ctx).release()
            _ = imd.np_client_free?(client)
            return false
        }

        // The callback runs on a thread libimobiledevice owns. Park here while
        // it does; np_client_free is what joins that thread, so the context is
        // released only after it, never under it.
        while !Task.isCancelled, IMobileDevice.deviceReady(socket: socket) {
            Thread.sleep(forTimeInterval: 2)
        }
        _ = imd.np_client_free?(client)
        Unmanaged<Sink>.fromOpaque(ctx).release()
        return true
    }
}
