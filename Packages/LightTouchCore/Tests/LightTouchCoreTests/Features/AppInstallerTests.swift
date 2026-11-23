import Foundation
import HostServiceWire
import Testing

@testable import LightTouchCore

extension SharedState {
    /// The install queue (AppInstaller): per-device scope, removals behind installs, media imports and their
    /// cancellation, retry, pause and refusal.
    @Suite struct AppInstallerTests {
        final class Changes {
            var devices: [UUID?] = []
            var starts: [InstallJob] = []
            var updates: [String] = []
        }

        /// Records the queue's notifications for the life of `body`.
        func observing<T>(_ body: (Changes) async throws -> T) async rethrows -> T {
            let changes = Changes()
            let center = NotificationCenter.default
            let tokens = [
                center.addObserver(forName: .ltmAppsChanged, object: nil, queue: nil) { note in
                    let device = note.object as? UUID
                    MainActor.assumeIsolated { changes.devices.append(device) }
                },
                center.addObserver(forName: .ltmInstallStarted, object: nil, queue: nil) { note in
                    let job = note.object as! InstallJob
                    MainActor.assumeIsolated { changes.starts.append(job) }
                },
                center.addObserver(forName: .ltmInstallProgress, object: nil, queue: nil) { note in
                    let job = note.object as! InstallJob
                    MainActor.assumeIsolated { changes.updates.append(job.status) }
                }
            ]
            defer { tokens.forEach(center.removeObserver) }
            return try await body(changes)
        }

        func media(_ name: String, to device: FakeDevice) -> InstallJob {
            AppInstaller.startMedia(URL(fileURLWithPath: "/tmp/" + name), with: device, presenting: nil)
        }

        // MARK: - Per-device scope

        @Test func discardPauseAndBusyAreScopedToOneDevice() async throws {
            try await withInstallerState { _, log in
                try await observing { changes in
                    let a = FakeDevice("a")
                    let b = FakeDevice("b")
                    // Rows carry their device; each device's queue is its own.
                    try await AppInstaller.queue(for: a.instance.id).acquire()
                    try await AppInstaller.queue(for: b.instance.id).acquire()
                    let onA = media("On A.png", to: a)
                    let onB = media("On B.png", to: b)
                    #expect(onA.deviceID == a.instance.id && onB.deviceID == b.instance.id)
                    try await until {
                        onA.status == "Waiting for other transfers…" && onB.status == "Waiting for other transfers…"
                    }
                    #expect(
                        AppInstaller.hasPendingWork(for: a.instance.id)
                            && AppInstaller.hasPendingWork(for: b.instance.id)
                    )
                    #expect(AppInstaller.isUsingDevice(a.instance.id) && AppInstaller.isUsingDevice(b.instance.id))

                    // Power Off / Erase on A discards A's job only; B's keeps waiting and then runs.
                    AppInstaller.discard(for: a.instance.id)
                    try await until { onA.isFinished }
                    #expect(onA.isCancelled && onA.dismissed && !onB.isFinished && !onB.dismissed && !onB.isCancelled)
                    #expect(changes.devices.contains(a.instance.id) && !changes.devices.contains(b.instance.id))
                    #expect(
                        !AppInstaller.hasPendingWork(for: a.instance.id)
                            && AppInstaller.hasPendingWork(for: b.instance.id)
                    )
                    AppInstaller.queue(for: b.instance.id).release()
                    try await until { b.started == ["On B"] }
                    b.finish("On B")
                    try await until { onB.isFinished }
                    #expect(onB.status == "Added to Photos" && !AppInstaller.hasPendingWork)
                    AppInstaller.queue(for: a.instance.id).release()
                    #expect(!AppInstaller.isUsingDevice(a.instance.id) && !AppInstaller.isUsingDevice(b.instance.id))

                    // A transport failure on A pauses A's queue and A's waiting rows, not B's.
                    let lostA = media("Lost A.png", to: a)
                    try await until { a.started == ["Lost A"] }
                    let waitA = media("Wait A.png", to: a)
                    let waitB = media("Wait B.png", to: b)
                    try await until {
                        waitA.status == "Waiting for other transfers…" && b.started == ["On B", "Wait B"]
                    }
                    a.finish("Lost A", error: DeviceError.timedOut(operation: "upload"))
                    try await until { lostA.isFinished }
                    #expect(
                        lostA.failed && AppInstaller.isPaused(a.instance.id) && !AppInstaller.isPaused(b.instance.id)
                    )
                    #expect(
                        waitA.status == "Paused" && waitB.status == "Copying media… 25%" && a.failures == 1
                            && b.failures == 0
                    )
                    // The failure's whole error is logged, not only the row's words.
                    #expect(
                        log.all.contains {
                            $0.hasPrefix("install: Lost A failed: ") && $0.contains("timedOut") && $0.contains("upload")
                        },
                        "\(log.all)"
                    )
                    b.finish("Wait B")
                    try await until { waitB.isFinished }
                    #expect(waitB.status == "Added to Photos" && !waitB.failed)
                    AppInstaller.resume(a.instance.id)
                    try await until { a.started == ["Lost A", "Wait A"] }
                    a.finish("Wait A")
                    try await until { waitA.isFinished }
                    #expect(waitA.status == "Added to Photos")

                    // A removal on B is B's pending work, and A's discard leaves it queued.
                    var finished = 0
                    AppInstaller.remove(
                        [InstalledApp(id: "app.b", name: "B", version: "1")],
                        with: b,
                        presenting: nil,
                        willRemove: { _ in },
                        didRemove: { _ in }
                    ) { finished += 1 }
                    try await until { b.started.last == "app.b" }
                    #expect(
                        AppInstaller.hasPendingWork(for: b.instance.id)
                            && !AppInstaller.hasPendingWork(for: a.instance.id)
                    )
                    AppInstaller.discard(for: a.instance.id)
                    await Task.yield()
                    #expect(finished == 0 && AppInstaller.isUsingDevice(b.instance.id))
                    b.finish("app.b")
                    try await until { finished == 1 }
                    #expect(!AppInstaller.hasPendingWork && !a.overlapped && !b.overlapped)
                }
            }
        }

        /// A response that didn't decode: the row says so plainly; the log has the DecodingError and its coding path.
        @Test func undecodableResponseReadsPlainly() async throws {
            try await withInstallerState { _, log in
                struct Copy: Decodable {
                    let ipaID: String
                    enum CodingKeys: String, CodingKey { case ipaID = "ipa_id" }
                }
                var decodeError: Error?
                do { _ = try JSONDecoder().decode(Copy.self, from: Data(#"{"ipa_id": [1, 2]}"#.utf8)) } catch {
                    decodeError = error
                }
                let device = FakeDevice()
                let garbled = media("Garbled.png", to: device)
                try await until { device.started.last == "Garbled" }
                device.finish("Garbled", error: decodeError!)
                try await until { garbled.isFinished }
                #expect(garbled.failed && garbled.status == "Legacy Store sent a response Light Touch couldn’t read.")
                #expect(
                    log.all.contains {
                        $0.hasPrefix("install: Garbled failed: ") && $0.contains("typeMismatch")
                            && $0.contains("ipa_id")
                    }
                )
            }
        }

        // MARK: - Removals

        @Test func removalsQueueBehindInstallsCancelPauseAndKeepSharedIcons() async throws {
            let other = FakeDevice("other")
            let devices: () -> [DeviceInstance] = { [other.instance] }
            try await withInstallerState(named: ["diner", "broken", "shared"], devices: devices) { state, _ in
                let device = FakeDevice()
                let id = device.instance.id
                let queue = AppInstaller.queue(for: id)
                var started: [String] = []
                var removed: [String] = []
                var finished = 0
                @MainActor func remove(_ ids: [String]) {
                    AppInstaller.remove(
                        ids.map { InstalledApp(id: $0, name: $0, version: "1") },
                        with: device,
                        presenting: nil
                    ) {
                        started.append($0.id)
                    } didRemove: {
                        removed.append($0.id)
                    } didFinish: {
                        finished += 1
                    }
                }
                /// The device keeps a copy of each of these apps (IPALibrary).
                func keepCopies(_ ids: [String], on instance: DeviceInstance) throws {
                    let dir = instance.paths(state: state, logs: state.appendingPathComponent("Logs")).ipas
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    for id in ids { try Data(id.utf8).write(to: dir.appendingPathComponent("\(id).ipa")) }
                }
                try keepCopies(["diner", "broken", "shared"], on: device.instance)
                try keepCopies(["shared"], on: other.instance)

                // The user confirms while an install owns the device: the request is kept.
                try await queue.acquire()
                remove(["diner"])
                #expect(AppInstaller.hasPendingWork)
                await Task.yield()
                #expect(started.isEmpty && removed.isEmpty && AppInstaller.isUsingDevice(id))
                queue.release()
                try await until { started == ["diner"] }
                var laterInstall = false
                let installer = Task { @MainActor in
                    try await queue.acquire()
                    laterInstall = true
                    queue.release()
                }
                await Task.yield()
                #expect(!laterInstall && removed.isEmpty)
                device.finish("diner")
                try await installer.value
                try await until { finished == 1 }
                #expect(removed == ["diner"] && laterInstall && !AppInstaller.hasPendingWork)
                #expect(
                    AppMetadataCache.shared.name(for: "diner") == nil
                        && IPALibrary.url(for: "diner", device: device.instance) == nil
                )

                // Quit cancels queued removals, including when transfers have been paused.
                queue.pause()
                remove(["cancelled"])
                await Task.yield()
                AppInstaller.cancelPendingWork()
                try await until { finished == 2 }
                queue.resume()
                #expect(
                    !started.contains("cancelled") && !AppInstaller.hasPendingWork && !AppInstaller.isUsingDevice(id)
                )

                // An in-progress guest call keeps the slot and the quit guard until it finishes; cancellation skips the rest.
                remove(["active", "skip"])
                try await until { started.contains("active") }
                AppInstaller.cancelPendingWork()
                await Task.yield()
                #expect(AppInstaller.hasPendingWork && AppInstaller.isUsingDevice(id) && finished == 2)
                device.finish("active")
                try await until { finished == 3 }
                #expect(!started.contains("skip") && removed.contains("active") && !AppInstaller.hasPendingWork)

                // A failure reports once, releases the queue and leaves the app's metadata and copy.
                struct Failure: Error {}
                remove(["broken", "unattempted"])
                try await until { started.contains("broken") }
                device.finish("broken", error: Failure())
                try await until { finished == 4 }
                #expect(device.errors.count == 1 && !started.contains("unattempted"))
                #expect(
                    !removed.contains("broken") && IPALibrary.url(for: "broken", device: device.instance) != nil
                        && AppMetadataCache.shared.name(for: "broken") == "broken"
                )
                #expect(!AppInstaller.isUsingDevice(id) && !AppInstaller.hasPendingWork)

                // A dead transport pauses the queue; later requests stay accepted, but no write begins until resumed.
                remove(["lost"])
                try await until { started.contains("lost") }
                remove(["after-recovery"])
                await Task.yield()
                device.finish("lost", error: DeviceError.timedOut(operation: "uninstall"))
                try await until { finished == 5 }
                #expect(AppInstaller.isPaused(id) && !AppInstaller.isUsingDevice(id) && AppInstaller.hasPendingWork)
                #expect(device.deviceReachable == false && !started.contains("after-recovery"))
                AppInstaller.resume(id)
                try await until { started.contains("after-recovery") }
                device.finish("after-recovery")
                try await until { finished == 6 }
                #expect(device.errors.count == 2 && !AppInstaller.hasPendingWork && !AppInstaller.isUsingDevice(id))

                // A guest failure after Quit cancelled the active task opens no alert during shutdown.
                remove(["quit-active"])
                try await until { started.contains("quit-active") }
                AppInstaller.cancelPendingWork()
                device.finish("quit-active", error: DeviceError.timedOut(operation: "uninstall"))
                try await until { finished == 7 }
                #expect(device.errors.count == 2 && !AppInstaller.isPaused(id) && !AppInstaller.hasPendingWork)

                // Another device still has the app: its copy here goes, the app-wide name and icon stay.
                remove(["shared"])
                try await until { started.contains("shared") }
                device.finish("shared")
                try await until { finished == 8 }
                #expect(
                    IPALibrary.url(for: "shared", device: device.instance) == nil
                        && AppMetadataCache.shared.name(for: "shared") == "shared"
                )
                #expect(!device.overlapped)
            }
        }

        // MARK: - Media

        @Test func mediaWaitsBehindInstallsImportsInOrderAndCancels() async throws {
            try await withInstallerState { _, _ in
                try await observing { changes in
                    let device = FakeDevice()
                    let id = device.instance.id
                    let queue = AppInstaller.queue(for: id)
                    // An install owns the guest. Dropping a photo publishes a job at once and keeps the prepared
                    // media until its serialized turn.
                    try await queue.acquire()
                    let photo = media("Photo.png", to: device)
                    #expect(changes.starts.last === photo && photo.status == "Preparing media…")
                    #expect(AppInstaller.hasPendingWork)
                    try await until { photo.status == "Waiting for other transfers…" }
                    let song = media("Song.mp3", to: device)
                    try await until { song.status == "Waiting for other transfers…" }
                    #expect(device.started.isEmpty && !photo.isFinished && !song.isFinished)
                    queue.release()
                    try await until { device.started == ["Photo"] }
                    try await until { photo.downloadProgress == 0.25 }
                    #expect(photo.status == "Copying media… 25%" && song.status == "Waiting for other transfers…")
                    device.finish("Photo")
                    try await until { photo.isFinished && device.started == ["Photo", "Song"] }
                    #expect(photo.status == "Added to Photos" && !photo.failed && !photo.isCancellable)
                    device.finish("Song")
                    try await until { song.isFinished }
                    #expect(song.status == "Added to Music" && device.committed == ["Photo", "Song"])
                    #expect(!AppInstaller.hasPendingWork && !AppInstaller.isUsingDevice(id))
                    #expect(
                        changes.updates.contains("Adding to Photos…") && changes.updates.contains("Adding to Music…")
                    )

                    // Cancelling before the slot is acquired removes no other job and is no failed row.
                    try await queue.acquire()
                    let cancelled = media("Cancelled.png", to: device)
                    try await until { cancelled.status == "Waiting for other transfers…" }
                    cancelled.cancel()
                    try await until { cancelled.isFinished }
                    #expect(cancelled.isCancelled && !cancelled.failed && !device.started.contains("Cancelled"))
                    queue.release()
                    device.delayed.insert("Preparing")
                    let preparing = media("Preparing.png", to: device)
                    try await until { device.preparing["Preparing"] != nil }
                    preparing.cancel()
                    // Some system media APIs return their own error on cancellation.
                    device.preparing.removeValue(forKey: "Preparing")!.resume(throwing: FakeDevice.Unreadable())
                    try await until { preparing.isFinished }
                    #expect(preparing.isCancelled && !preparing.failed)
                    #expect(!device.overlapped)
                }
            }
        }

        @Test func badMediaIsRetryableAndADisconnectionPausesWaitingImports() async throws {
            try await withInstallerState { _, _ in
                let device = FakeDevice()
                let id = device.instance.id
                // Bad input is visible and retryable, never a success that vanishes.
                device.failing.insert("Bad")
                let bad = media("Bad.png", to: device)
                try await until { bad.isFinished }
                #expect(bad.failed && bad.status == "Unreadable photo" && bad.retry != nil)
                device.failing.remove("Bad")
                bad.retry?()
                #expect(bad.dismissed)
                try await until { device.started.last == "Bad" }
                device.finish("Bad")
                try await until { !AppInstaller.hasPendingWork }

                // A transport error pauses waiting imports; Resume runs the original job without a second drop.
                let disconnected = media("Disconnected.png", to: device)
                try await until { device.started.last == "Disconnected" }
                let waiting = media("After reconnect.mp3", to: device)
                try await until { waiting.status == "Waiting for other transfers…" }
                device.finish("Disconnected", error: DeviceError.timedOut(operation: "upload"))
                try await until { disconnected.isFinished }
                #expect(disconnected.failed && AppInstaller.isPaused(id) && waiting.status == "Paused")
                #expect(!device.started.contains("After reconnect") && !waiting.isFinished)
                AppInstaller.resume(id)
                try await until { device.started.last == "After reconnect" }
                device.finish("After reconnect")
                try await until { waiting.isFinished }
                #expect(!waiting.failed && waiting.status == "Added to Music" && !device.overlapped)
            }
        }

        /// Media the firmware's helpers can't take is refused on its row at once: nothing prepared, queued or run in
        /// the guest, and nothing to retry (MediaSupport).
        @Test func unsupportedFirmwareRefusesBeforePreparing() async throws {
            try await withInstallerState { _, _ in
                let device = FakeDevice()
                device.mediaFirmware = .init(version: "1.1", name: "iOS 1.1")
                for (file, words) in [
                    ("Refused song.mp3", "Adding music isn’t supported on iOS 1.1 yet."),
                    ("Refused photo.png", "Adding photos isn’t supported on iOS 1.1 yet.")
                ] {
                    let job = media(file, to: device)
                    #expect(job.isFinished && job.failed && job.retry == nil && job.status == words)
                }
                try await Task.sleep(for: .milliseconds(100))
                #expect(device.prepared.isEmpty && device.started.isEmpty && !AppInstaller.hasPendingWork)
            }
        }

        /// An app install on iPhone OS 1 is refused before it reaches the device: it has no installation service.
        @Test func appInstallsRefusedOniPhoneOS1() async throws {
            try await withInstallerState { _, _ in
                let device = FakeDevice()
                device.iosVersion = "1.1.5"
                let job = AppInstaller.start(URL(fileURLWithPath: "/tmp/App.ipa"), with: device, presenting: nil)
                await job.task?.value
                #expect(job.failed && job.status == "App installs aren’t supported on iPhone OS 1.")
                #expect(device.started.isEmpty)
            }
        }
    }
}
