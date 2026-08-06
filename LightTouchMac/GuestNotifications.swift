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
    /// Held so the watcher can actually be stopped. Both of these used to be
    /// bare `Task.detached`s with nothing retaining them, so `Task.isCancelled`
    /// was never true and the loops ran for the life of the process — the
    /// blocking one parked on a cooperative-pool thread, which is core-count
    /// sized and shared with every other async task in the app.
    private var watcher: Task<Void, Never>?
    private var iconTick: Task<Void, Never>?
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

    /// `probe` answers "is the device still there" through the app's own gated,
    /// deadlined path — this used to call `idevice_new` directly, which has no
    /// timeout, so a half-open usbmuxd socket parked the watcher forever.
    func start(probe: @escaping @Sendable () async -> Bool,
               onChange: @escaping @Sendable () -> Void) {
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
        iconTick = Task {
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

        watcher = Task {
            // Re-establish on loss: the guest drops its services on reboot and
            // on a USB reset, and a watcher that gave up then would leave the
            // sidebar quietly stale for the rest of the session.
            while !Task.isCancelled {
                let ok = await Self.observeOnce(socket: socket, probe: probe, onChange: onChange)
                // A failed attach usually means the guest is still booting;
                // a successful session that ended means the link dropped.
                try? await Task.sleep(for: .seconds(ok ? 2 : 10))
            }
        }
    }

    /// Ends the session. Called when the inspector goes away or USB does.
    func stop() {
        running = false
        watcher?.cancel();  watcher = nil
        iconTick?.cancel(); iconTick = nil
    }

    deinit { watcher?.cancel(); iconTick?.cancel() }

    /// Opens one session and blocks until it dies. Returns whether it ever got
    /// as far as observing, so the caller can back off sensibly.
    private nonisolated static func observeOnce(socket: String,
                                                probe: @escaping @Sendable () async -> Bool,
                                                onChange: @escaping @Sendable () -> Void) async -> Bool {
        // np_client_start_service does a full lockdown handshake and start_service
        // internally, so it goes through the gate like every other service
        // connect. Ungated, it was a second lockdown session opened against a
        // guest that serves about one — retried every 10s, including for the
        // whole of an install, which is precisely the collision every other path
        // in the app suppresses itself to avoid.
        let handles: Session?
        do {
            handles = try await DeviceGate.shared.serialized {
                try await withDeadline(Timeouts.serviceProbe * 2, "notification watcher") {
                    connect(socket: socket, onChange: onChange)
                }
            }
        } catch {
            return false
        }
        guard let handles else { return false }

        // The callback runs on a thread libimobiledevice owns. Wait out here
        // while it does — asynchronously, so no pool thread is parked — and let
        // np_client_free join that thread before the context is released, never
        // under it.
        while !Task.isCancelled, await probe() {
            try? await Task.sleep(for: .seconds(5))
        }
        _ = IMobileDevice.np_client_free?(handles.client)
        Unmanaged<Sink>.fromOpaque(handles.ctx).release()
        return true
    }

    /// The blocking half: open the session and arm the callback.
    private nonisolated static func connect(socket: String,
                                            onChange: @escaping @Sendable () -> Void)
        -> Session?
    {
        let imd = IMobileDevice.self
        guard let idevice_new = imd.idevice_new,
              let start = imd.np_client_start_service,
              let observe = imd.np_observe_notification,
              let setCB = imd.np_set_notify_callback else { return nil }
        setenv("USBMUXD_SOCKET_ADDRESS", socket, 1)

        var device: OpaquePointer?
        guard idevice_new(&device, nil) == imd.success, let device else { return nil }
        defer { _ = imd.idevice_free?(device) }

        var client: OpaquePointer?
        guard start(device, &client, "LightTouchMac") == imd.success, let client else { return nil }

        for name in observed {
            _ = name.withCString { observe(client, $0) }
        }

        let sink = Sink(onChange)
        let ctx = Unmanaged.passRetained(sink).toOpaque()
        guard setCB(client, callback, ctx) == imd.success else {
            Unmanaged<Sink>.fromOpaque(ctx).release()
            _ = imd.np_client_free?(client)
            return nil
        }
        return Session(client: client, ctx: ctx)
    }

    /// The open session's handles. A box, because OpaquePointer is not Sendable
    /// and these cross the gate's await.
    nonisolated private final class Session: @unchecked Sendable {
        let client: OpaquePointer
        let ctx: UnsafeMutableRawPointer
        init(client: OpaquePointer, ctx: UnsafeMutableRawPointer) {
            self.client = client; self.ctx = ctx
        }
    }
}
