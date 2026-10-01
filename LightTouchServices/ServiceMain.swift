import Foundation
import Darwin

/// stdout is exclusively the typed service protocol; logs go to stderr.
nonisolated func logEvent(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// Synchronous C progress callbacks and the command task share stdout. The
// lock serializes each entire encoded event, so callback bytes cannot interleave.
nonisolated final class EventWriter: @unchecked Sendable {
    private let lock = NSLock()
    func send(_ event: HostServiceEvent) {
        lock.withLock {
            if let bytes = try? JSONEncoder().encode(event) { FileHandle.standardOutput.write(bytes + Data([10])) }
        }
    }
}

@main struct ServiceMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 6, args[0] == "--socket", args[2] == "--udid", args[4] == "--session",
              let session = UUID(uuidString: args[5]),
              ProcessInfo.processInfo.environment["USBMUXD_SOCKET_ADDRESS"] == args[1] else { exit(2) }
        // A GUI killed without cancellation cannot leave a blocked C call or
        // idle notification process orphaned. This observes only our parent,
        // never the independently owned QEMU process.
        let parent = getppid()
        guard parent > 1 else { exit(0) }
        let parentWatch = Task.detached {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if getppid() != parent { exit(0) }
            }
        }
        defer { parentWatch.cancel() }
        let socket = args[1], udid = args[3].isEmpty ? nil : args[3]
        let service = DeviceServices(clientSocket: socket, udid: udid, session: session, local: true)
        let writer = EventWriter()
        while let line = readLine() {
            guard let request = try? JSONDecoder().decode(HostServiceRequest.self, from: Data(line.utf8)),
                  request.version == HostServiceRequest.version, request.session == session else { exit(2) }
            let emit: @Sendable (HostServiceEvent.Payload) -> Void = { payload in
                writer.send(HostServiceEvent(id: request.id, session: session, payload: payload))
            }
            do { emit(.result(try await execute(request.operation, service: service, emit: emit))) }
            catch { emit(.failure(HostServiceFailure(error))) }
        }
    }

    static func execute(_ operation: HostServiceOperation, service: DeviceServices,
                        emit: @escaping @Sendable (HostServiceEvent.Payload) -> Void) async throws -> HostServiceValue {
        switch operation {
        case .attachment: try await service.checkAttachment(); return .none
        case .apps: return .apps(try await service.installedApps())
        case .freeSpace: return .integer(try await service.freeSpaceBytes())
        case .lockdownValue(let key): return .string(try await service.lockdownValue(key))
        case .installReady: return .boolean(await service.installProxyReady())
        case .homeOrder: return .strings(try await service.homeScreenOrder())
        case .orientation: return .integer(Int64(try await service.interfaceOrientation()))
        case .uninstall(let id): try await service.uninstall(id); return .none
        case .install(let path):
            try await service.install(stagedPath: path) { emit(.progress(.install($0, $1))) }; return .none
        case .upload(let source, let remote, let reuse, let allowEmpty):
            return .string(try await service.stageFile(URL(fileURLWithPath: source), remote: remote,
                reuseIdentical: reuse, allowEmpty: allowEmpty) { emit(.progress(.fraction($0))) })
        case .sweep: await service.sweepStaging(); return .none
        case .remove(let path): await service.removeStaged(path); return .none
        case .files(let path): return .files(try await service.files(in: path))
        case .download(let file, let destination):
            try await service.download(file, to: URL(fileURLWithPath: destination)) { emit(.progress(.fraction($0))) }; return .none
        case .move(let bundle, let before, let name):
            return .strings(try await service.moveOnHomeScreen(bundle, before: before, deviceName: name))
        case .observe:
            return .boolean(await NotificationProxy.localObserveOnce(socket: service.clientSocket,
                attachAllowed: { true }, onChange: { emit(.progress(.notification)) }))
        }
    }
}
