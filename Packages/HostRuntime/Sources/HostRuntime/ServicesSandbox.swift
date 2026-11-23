// Whether LightTouchServices runs under the App Sandbox, and what that changes for whoever spawns it: the services
// worker, its lockdown children (lockdown-tz, -mcinstall, -ddi, -ax) and the device's usbmuxd, which the worker's
// usbmuxd operation becomes (exec) inside the worker's sandbox, so all three parse what the guest sends without the
// user's files. One switch, LTM_HELPER_SANDBOX, as for the device helper (HelperSandbox): it signs LightTouchServices
// with LightTouchServices-Sandbox.entitlements, and the spawner reads that signature.
//
// - Sockets: libusbmuxd connects to usbmuxd again for every service, so the client socket has a path, and a sandboxed
//   process reaches Unix sockets only in its containers. Both of a device's sockets are in the services' own app
//   group's container (`servicesGroup`), in the app's pid folder: no device helper is in that group, so QEMU can't
//   reach them; any device's services processes can, as any device's helpers can reach the helpers' group.
// - Files: none of their own. Whoever spawns one grants it what it may open (SandboxExtension, to the unreaped
//   child's pid, on its standard input or with each request): usbmuxd its device's usbmuxd-conf (the pairing
//   records), read-write; the worker, per request, the file it uploads or installs (read) and the private folder a
//   download or crash report copy is written into (read-write, which the app then quarantines and publishes); a
//   lockdown child the files it sends (read).
// - Unsandboxed (LTM_HELPER_SANDBOX = NO), nothing changes: the sockets are in the temporary directory, usbmuxd runs
//   itself, and no token is sent.

import Foundation

public nonisolated enum ServicesSandbox {
    /// The services' app group (Configuration/LightTouchServices-Sandbox.entitlements); the app is in it too.
    public static let group = "SM75355Y6R.ltm.services"

    /// The group's container, whether or not it exists yet.
    public static var container: URL {
        URL(fileURLWithPath: HelperSandbox.realHome, isDirectory: true).appendingPathComponent(
            "Library/Group Containers/\(group)",
            isDirectory: true
        )
    }

    /// Whether `worker`'s signature asks for the App Sandbox.
    public static func isSandboxed(_ worker: String) -> Bool { HelperSandbox.isSandboxed(URL(fileURLWithPath: worker)) }

    /// Where this process's services sockets go: its own folder in the group's container (owner-only; the launch
    /// sweep removes it once the process is gone, HelperSandbox.sweepStaleSockets), else the temporary directory.
    public static func socketFolder(sandboxed: Bool, in container: URL = container) -> String {
        guard sandboxed else { return NSTemporaryDirectory() }
        let folder = container.appendingPathComponent("\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return folder.path + "/"
    }

    /// What a Debug build may load from outside its bundle (a development usbmuxd, LTM_USBMUXD): its folder and its
    /// LC_RPATH folders, read-only. A Release build runs only what its bundle holds: nothing.
    public static func loadGrants(_ binary: String) -> [SandboxExtension.Grant] {
        #if DEBUG
            let url = URL(fileURLWithPath: binary).resolvingSymlinksInPath()
            return ([url.deletingLastPathComponent().path] + HelperSandbox.runPaths(url)).map {
                SandboxExtension.Grant(URL(fileURLWithPath: $0), .read)
            }
        #else
            return []
        #endif
    }
}

extension SandboxExtension {
    /// What a spawner writes to a sandboxed child's standard input (consumeStandardInput): tokens for `grants` only the
    /// unreaped child `pid` can take, as JSON, and each path refused with why.
    public static func standardInput(_ grants: [Grant], for pid: pid_t) -> (data: Data, refused: [String]) {
        let (tokens, refused) = issue(grants, to: .pid(pid))
        return ((try? JSONEncoder().encode(tokens)) ?? Data(), refused)
    }
}
