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
// the writes and lets us watch a counter: the helper's status block carries
// it (SharedStatus.iconGeneration).
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
    /// The device's NAND icon-state write counter, read from its helper.
    private let iconGeneration: () -> UInt64?
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
        let closed: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init(_ fire: @escaping @Sendable () -> Void) {
            self.fire = fire
            (closed, continuation) = AsyncStream.makeStream()
        }

        func receive(_ notification: UnsafePointer<CChar>?) {
            // libimobiledevice reports ProxyDeath or a failed receive by
            // calling the notification callback with an empty string, then
            // exits its reader thread. USB attachment can still be healthy.
            guard let notification, notification.pointee != 0 else {
                continuation.finish()
                return
            }
            if GuestNotifications.observed.contains(String(cString: notification)) {
                fire()
            }
        }
    }

    init(clientSocket: String, iconGeneration: @escaping () -> UInt64?) {
        self.socket = clientSocket
        self.iconGeneration = iconGeneration
    }

    /// The C callback runs on libimobiledevice's own thread. Classify the
    /// notification and hand it off without blocking that reader.
    nonisolated private static let callback: IMobileDevice.NpNotifyCB = { notification, userData in
        guard let userData else { return }
        Unmanaged<Sink>.fromOpaque(userData).takeUnretainedValue().receive(notification)
    }

    /// Only inspect host activity in `attachAllowed`; existing subscriptions
    /// stay open during installs. The library reports loss of this specific
    /// service, so there is no extra USB health probe to queue behind transfers.
    func start(attachAllowed: @escaping @Sendable () async -> Bool,
               onChange: @escaping @Sendable () -> Void) {
        guard !running, IMobileDevice.isAvailable else { return }
        running = true
        let socket = self.socket

        // The home screen is the one change the guest will never announce, so
        // take it from underneath instead: the icon layout can only reach flash
        // through the emulated NAND, which now counts those writes for us (the
        // status block's iconGeneration). Reading it is an atomic load, so
        // a one-second tick costs less than the notification_proxy session
        // below does sitting idle, and still reads as instant next to the
        // 15-second poll it replaces.
        let iconGeneration = iconGeneration
        iconTick = Task {
            var seen = iconGeneration()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                // One rearrange is several NAND pages, and the plist goes
                // through the journal as well. Comparing once per tick collapses
                // the whole burst into a single refresh.
                let now = iconGeneration()
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
                guard await attachAllowed() else {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    continue
                }
                let ok = await Self.observeOnce(socket: socket, attachAllowed: attachAllowed,
                                               onChange: onChange)
                // A failed attach usually means the guest is still booting;
                // a successful session that ended means the link dropped.
                do { try await Task.sleep(for: .seconds(ok ? 2 : 10)) } catch { break }
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
                                                attachAllowed: @escaping @Sendable () async -> Bool,
                                                onChange: @escaping @Sendable () -> Void) async -> Bool {
        // np_client_start_service does a full lockdown handshake and start_service
        // internally, so it goes through the gate like every other service
        // connect. Its factory then closes lockdown; the lasting subscription
        // uses its own service socket and does not reserve a lockdown session.
        // The deadline's loser is DISCARDED by withDeadline, so a connect that
        // lands late still needs its client and retained callback context freed.
        let landed = LateSession()
        let handles: Session?
        do {
            handles = try await DeviceGate.shared.serialized {
                // An install may have started while this task waited for the
                // gate. Do not introduce another handshake between its stages.
                guard await attachAllowed() else { return nil }
                return try await withDeadline(Timeouts.serviceProbe * 2, "notification watcher") {
                    let session = connect(socket: socket, onChange: onChange)
                    if let session { landed.store(session) }
                    return session
                }
            }
        } catch {
            await landed.freeIfLate()
            return false
        }
        guard let handles else { await landed.freeIfLate(); return false }
        landed.claim()

        // The callback runs on a thread libimobiledevice owns. Wait out here
        // while it does — asynchronously, so no pool thread is parked — and let
        // np_client_free join that thread before the context is released, never
        // under it.
        // Cancellation ends the stream wait as well. A busy install is not a
        // disconnected notification socket, and an attached USB device is not
        // proof that this reader thread is still alive.
        for await _ in handles.closed { }
        await close(handles)
        return true
    }

    private nonisolated static func close(_ session: Session) async {
        // np_client_free sends Shutdown and joins the C reader. A partial
        // packet can leave that reader blocked; never perform the join on the
        // main actor or release its callback context until the join completes.
        // This independent task must run even when the watcher was cancelled.
        await Task.detached {
            _ = try? await withDeadline(Timeouts.serviceProbe * 2, "notification cleanup") {
                session.free()
            }
        }.value
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
        DeviceGate.point(at: socket)

        var device: OpaquePointer?
        guard idevice_new(&device, nil) == imd.success, let device else { return nil }
        defer { _ = imd.idevice_free?(device) }

        var client: OpaquePointer?
        guard start(device, &client, "LightTouchMac") == imd.success, let client else { return nil }

        for name in observed {
            guard name.withCString({ observe(client, $0) }) == imd.success else {
                _ = imd.np_client_free?(client)
                return nil
            }
        }

        let sink = Sink(onChange)
        let ctx = Unmanaged.passRetained(sink).toOpaque()
        guard setCB(client, callback, ctx) == imd.success else {
            Unmanaged<Sink>.fromOpaque(ctx).release()
            _ = imd.np_client_free?(client)
            return nil
        }
        return Session(client: client, ctx: ctx, closed: sink.closed)
    }

    /// Holds whatever `connect` produced so the deadline's losing side can still
    /// close it. `claim()` says the caller took ownership; otherwise the session
    /// is freed the moment we know nobody is waiting for it any more.
    nonisolated private final class LateSession: @unchecked Sendable {
        private let lock = NSLock()
        private var session: Session?
        private var claimed = false

        func store(_ s: Session) {
            lock.lock()
            if claimed { lock.unlock(); s.free(); return }   // already gave up
            session = s
            lock.unlock()
        }
        func claim() { lock.lock(); claimed = true; session = nil; lock.unlock() }
        func freeIfLate() async {
            let s = lock.withLock {
                claimed = true
                let s = session; session = nil
                return s
            }
            if let s { await GuestNotifications.close(s) }
        }
    }

    /// The open session's handles. A box, because OpaquePointer is not Sendable
    /// and these cross the gate's await.
    nonisolated private final class Session: @unchecked Sendable {
        let client: OpaquePointer
        let ctx: UnsafeMutableRawPointer
        let closed: AsyncStream<Void>
        init(client: OpaquePointer, ctx: UnsafeMutableRawPointer, closed: AsyncStream<Void>) {
            self.client = client; self.ctx = ctx
            self.closed = closed
        }
        func free() {
            _ = IMobileDevice.np_client_free?(client)
            Unmanaged<Sink>.fromOpaque(ctx).release()
        }
    }
}
