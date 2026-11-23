import Darwin
import Foundation
import HostRuntime
import HostServiceWire

/// stdout is exclusively the typed service protocol; logs go to stderr.
nonisolated func logEvent(_ message: String) {
    writeDroppingClosedPipe(Data((message + "\n").utf8), to: .standardError)
}

@main struct ServiceMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        // The lockdown writes (Lockdown/Lockdown.h): one per process, which exits with the operation's status.
        let operations = [
            "lockdown-tz": ltm_lockdown_tz, "lockdown-mcinstall": ltm_lockdown_mcinstall,
            "lockdown-ddi": ltm_lockdown_ddi, "lockdown-ax": ltm_lockdown_ax
        ]
        if let name = args.first, let operation = operations[name] {
            // a sandboxed child's grants (the files it sends), from its spawner, before it opens anything
            let refused = SandboxExtension.consumeStandardInput().refused
            if !refused.isEmpty { logEvent("\(name): grants refused: \(refused)") }
            exit(operation(CommandLine.argc - 1, CommandLine.unsafeArgv + 1))
        }
        // usbmuxd PATH ARGS…: this device's usbmuxd in this process's sandbox (USBMux): takes the spawner's grants
        // (its usbmuxd-conf), then becomes PATH, which inherits the sandbox and the grants.
        if args.count >= 2, args[0] == "usbmuxd" {
            let refused = SandboxExtension.consumeStandardInput().refused
            if !refused.isEmpty { logEvent("usbmuxd: grants refused: \(refused)") }
            if let socketFlag = args.firstIndex(of: "-S"), socketFlag + 1 < args.count {
                ServicesSandbox.prepareSocketFolder(forSocketPath: args[socketFlag + 1])
            }
            let argv = args.dropFirst().map { strdup($0) } + [nil]
            execv(args[1], argv)
            logEvent("usbmuxd: can't run \(args[1]): \(String(cString: strerror(errno)))")
            exit(127)
        }
        guard args.count == 6, args[0] == "--socket", args[2] == "--udid", args[4] == "--session",
            let session = UUID(uuidString: args[5]),
            ProcessInfo.processInfo.environment["USBMUXD_SOCKET_ADDRESS"] == args[1]
        else { exit(2) }
        // A GUI killed without cancellation cannot leave a blocked C call or
        // idle notification process orphaned. This observes only our parent,
        // never the independently owned QEMU process.
        let parent = getppid()
        guard parent > 1 else { exit(0) }
        let parentWatch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
        parentWatch.setEventHandler { exit(0) }
        parentWatch.resume()
        defer { parentWatch.cancel() }
        if getppid() != parent { exit(0) }  // it went before the source was watching
        let socket = args[1]
        let udid = args[3].isEmpty ? nil : args[3]
        let service = DeviceServices(clientSocket: socket, udid: udid, session: session)
        let writer = EventWriter()
        while let line = readLine() {
            guard let request = try? JSONDecoder().decode(HostServiceRequest.self, from: Data(line.utf8)),
                request.version == HostServiceRequest.version, request.session == session
            else { exit(2) }
            let emit: @Sendable (HostServiceEvent.Payload) -> Void = { payload in
                writer.send(HostServiceEvent(id: request.id, session: session, payload: payload))
            }
            // this request's grants alone (HostServiceWorkers), given back once it is done
            SandboxExtension.consume(request.tokens ?? [])
            do { emit(.result(try await execute(request.operation, service: service, emit: emit))) } catch {
                emit(.failure(HostServiceFailure(error)))
            }
            SandboxExtension.releaseAll()
        }
    }

    static func execute(
        _ operation: HostServiceOperation,
        service: DeviceServices,
        emit: @escaping @Sendable (HostServiceEvent.Payload) -> Void
    ) async throws -> HostServiceValue {
        switch operation {
        case .attachment:
            try await service.checkAttachment()
            return .none
        case .apps: return .apps(try await service.installedApps())
        case .archives: return .strings(try await service.archivedApps())
        case .freeSpace: return .integer(try await service.freeSpaceBytes())
        case .lockdownValue(let key, let domain): return .string(try await service.lockdownValue(key, domain: domain))
        case .installReady: return .boolean(await service.installProxyReady())
        case .homeOrder: return .strings(try await service.homeScreenOrder())
        case .orientation: return .integer(Int64(try await service.interfaceOrientation()))
        case .uninstall(let id):
            try await service.uninstall(id)
            return .none
        case .install(let ipa, let staged, let bundleID):
            try await service.install(URL(fileURLWithPath: ipa), staged: staged, bundleID: bundleID) {
                emit(.progress(.install($0, $1)))
            }
            return .none
        case .upload(let source, let remote, let reuse, let replace, let allowEmpty, let root):
            return .string(
                try await service.stageFile(
                    URL(fileURLWithPath: source),
                    remote: remote,
                    reuseIdentical: reuse,
                    replace: replace,
                    allowEmpty: allowEmpty,
                    root: root
                ) { emit(.progress(.fraction($0))) }
            )
        case .sweep:
            await service.sweepStaging()
            return .none
        case .syncLibraryFile(let source, let remote):
            try await service.syncLibraryFile(URL(fileURLWithPath: source), remote: remote)
            return .none
        case .remove(let path):
            await service.removeStaged(path)
            return .none
        case .files(let path, let root): return .files(try await service.files(in: path, root: root))
        case .download(let file, let destination, let root):
            try await service.download(file, to: URL(fileURLWithPath: destination), root: root) {
                emit(.progress(.fraction($0)))
            }
            return .none
        case .delete(let path, let root):
            try await service.delete(path, root: root)
            return .none
        case .rename(let path, let name, let root):
            try await service.rename(path, to: name, root: root)
            return .none
        case .makeFolder(let path, let root):
            try await service.makeFolder(path, root: root)
            return .none
        case .move(let bundle, let before, let name):
            return .strings(try await service.moveOnHomeScreen(bundle, before: before, deviceName: name))
        case .crashReports(let copyTo):
            return .ages(try await service.crashReports(copyTo: copyTo.map { URL(fileURLWithPath: $0) }))
        case .observe:
            return .boolean(
                await NotificationEngine.observeOnce(
                    socket: service.clientSocket,
                    attachAllowed: { true },
                    onChange: { emit(.progress(.notification)) }
                )
            )
        }
    }
}
