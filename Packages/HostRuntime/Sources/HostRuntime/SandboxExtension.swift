// A sandboxed LightTouchDevice's files, granted by the unsandboxed process that spawns it (the app's DeviceLink,
// firmwarekit's one-shots, the harness). Everything that issues or takes a grant is here.
//
// - libsystem_sandbox's file extensions (SPI, every symbol and flag looked up at run time; WebKit's and Chromium's
//   helpers take their files the same way). A missing symbol or flag issues nothing, so a sandboxed boot fails at
//   its first file instead of being granted more than it should.
// - Each token is bound to the helper: to its audit token once the rendezvous has checked its code requirement
//   (DeviceLink), or to the pid of an unreaped child (firmwarekit; a Debug build's emulator before the rendezvous).
//   Tokens go over the link or the helper's standard input, never argv or the environment, and are never logged.
// - Grants are typed: the caller names each path and whether the helper writes it (BootFiles, from the boot recipe),
//   nothing is derived from argv. Read-only unless the helper writes there.
// - A path is resolved (a library behind a symlink or on another volume works) and issued with NOFOLLOW_ANY, so a
//   symlink swapped in after that fails the grant instead of moving it. A macOS without that flag (14, or a later one
//   that drops it) falls back to NOFOLLOW, on purpose, so devices still start: it protects only the path's last
//   component, so a folder swapped in above it during the issue moves the grant. A symlink inside anything the helper
//   may write (a previous run could have planted it) refuses the grant. So does the deny-list: /, the home folder and
//   its ancestors, ~/Library and what runs or configures things from it, other apps' containers, /Applications, and
//   writing inside any app bundle.
// - Never user-intent, MACL, Mach, IOKit or generic extensions.
// - The helper takes its tokens before it opens anything and releases them when it exits.

import Foundation

public nonisolated enum SandboxExtension {
    public enum Access: String, Sendable, Codable {
        case read = "com.apple.app-sandbox.read"
        case readWrite = "com.apple.app-sandbox.read-write"
    }

    public struct Grant: Hashable, Sendable {
        public var path: String
        public var access: Access
        public init(_ url: URL, _ access: Access) {
            path = url.standardizedFileURL.path
            self.access = access
        }
    }

    /// Who the tokens are for.
    public enum Holder {
        /// The rendezvous' audit token, checked against the helper's code requirement.
        case process(audit_token_t)
        /// An unreaped child, so the pid can't be reused yet.
        case pid(pid_t)
    }

    private typealias IssueToProcess =
        @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32, audit_token_t) -> UnsafeMutablePointer<
            CChar
        >?
    private typealias IssueToPID =
        @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32, pid_t) -> UnsafeMutablePointer<CChar>?
    private typealias Consume = @convention(c) (UnsafePointer<CChar>) -> Int64
    private typealias Release = @convention(c) (Int64) -> Int32

    /// RTLD_DEFAULT: every loaded image (libsystem_sandbox is in libSystem).
    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }

    /// A flag as this macOS defines it (the values have moved between releases).
    private static func flag(_ name: String) -> UInt32? {
        symbol(name).map { $0.load(as: UInt32.self) }.flatMap { $0 == 0 ? nil : $0 }
    }
    static var noFollowAny: UInt32? { flag("SANDBOX_EXTENSION_NOFOLLOW_ANY") }
    static var noFollow: UInt32? { flag("SANDBOX_EXTENSION_NOFOLLOW") }

    // MARK: - Spawner

    /// Tokens for `grants` that only `holder` can take, and each path refused with why. `deny`: more folders never
    /// granted themselves (a library root and its Devices folder: one device's helper must not get every device).
    public static func issue(
        _ grants: [Grant],
        to holder: Holder,
        deny: [URL] = []
    ) -> (tokens: [String], refused: [String]) {
        guard let flags = noFollowAny ?? noFollow else { return ([], grants.map { "\($0.path) (no NOFOLLOW)" }) }
        let issue: (Access, String) -> UnsafeMutablePointer<CChar>?
        switch holder {
        case .process(let audit):
            guard let s = symbol("sandbox_extension_issue_file_to_process") else {
                return ([], grants.map { "\($0.path) (no issue call)" })
            }
            let call = unsafeBitCast(s, to: IssueToProcess.self)
            issue = { call($0.rawValue, $1, flags, audit) }
        case .pid(let pid):
            guard let s = symbol("sandbox_extension_issue_file_to_process_by_pid") else {
                return ([], grants.map { "\($0.path) (no issue call)" })
            }
            let call = unsafeBitCast(s, to: IssueToPID.self)
            issue = { call($0.rawValue, $1, flags, pid) }
        }
        let writable = (grants.filter { $0.access == .readWrite }.map(\.path) + [HelperSandbox.groupContainer.path])
            .compactMap(canonical)
        let denied = Set(deny.compactMap { canonical($0.path) })
        var tokens: [String] = []
        var refused: [String] = []
        var seen = Set<String>()
        // Read-write first, so a path granted both ways is issued once, writable.
        for grant in grants.sorted(by: { ($0.access == .read ? 1 : 0, $0.path) < ($1.access == .read ? 1 : 0, $1.path) }
        ) {
            guard let real = canonical(grant.path) else {
                refused.append("\(grant.path) (missing)")
                continue
            }
            if let why = plantedLink(grant.path, under: writable) ?? deniedReason(real, grant.access, denied) {
                refused.append("\(grant.path) (\(why))")
                continue
            }
            guard seen.insert(real).inserted else { continue }
            guard let token = issue(grant.access, real) else {
                refused.append("\(grant.path) (\(String(cString: strerror(errno))))")
                continue
            }
            tokens.append(String(cString: token))
            free(token)
        }
        return (tokens, refused)
    }

    /// Why `real` (canonical) is never granted with `access`, or nil.
    static func deniedReason(_ real: String, _ access: Access, _ denied: Set<String>) -> String? {
        let home = canonical(HelperSandbox.realHome) ?? HelperSandbox.realHome
        let library = home + "/Library"
        if real == "/" || inside(home, real) { return "the home folder or above it" }
        if denied.contains(real) { return "a library root" }
        if [library, library + "/Application Support", "/Applications", "/System", "/Library", "/Users"].contains(real)
        {
            return "a shared folder"
        }
        for root in [
            "LaunchAgents", "LaunchDaemons", "Application Scripts", "Preferences", "Containers", "Group Containers",
            "Keychains", "Mail", "Messages", "Safari", "Cookies"
        ] where inside(real, library + "/" + root) {
            return "~/Library/\(root)"
        }
        if [".ssh", ".gnupg", ".config", ".zshrc", ".bash_profile", ".profile"].contains(where: {
            inside(real, home + "/" + $0)
        }) {
            return "a configuration file"
        }
        if access == .readWrite, real.split(separator: "/").contains(where: { $0.hasSuffix(".app") }) {
            return "inside an app"
        }
        return nil
    }

    /// `path` with every symlink resolved, nil if it doesn't exist.
    static func canonical(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    static func inside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// A symlink on `path` whose folder is inside one of `roots` (canonical), which the helper could have made.
    static func plantedLink(_ path: String, under roots: [String]) -> String? {
        var prefix = ""
        for component in URL(fileURLWithPath: path).standardizedFileURL.pathComponents.dropFirst() {
            let folder = prefix.isEmpty ? "/" : prefix
            prefix += "/" + component
            var info = stat()
            guard lstat(prefix, &info) == 0 else { return nil }
            if info.st_mode & S_IFMT == S_IFLNK, let parent = canonical(folder),
                roots.contains(where: { inside(parent, $0) })
            {
                return "a symlink where the helper writes: \(prefix)"
            }
        }
        return nil
    }

    // MARK: - Helper

    nonisolated(unsafe) private static var handles: [Int64] = []
    private static let lock = NSLock()

    /// Takes tokens issued to this process; why each refused one was (errno), never the token.
    @discardableResult public static func consume(_ tokens: [String]) -> [String] {
        guard !tokens.isEmpty else { return [] }
        guard let s = symbol("sandbox_extension_consume") else { return ["no sandbox_extension_consume"] }
        let consume = unsafeBitCast(s, to: Consume.self)
        var refused: [String] = []
        for token in tokens {
            let handle = consume(token)
            if handle == -1 {
                refused.append(String(cString: strerror(errno)))
            } else {
                lock.withLock { handles.append(handle) }
            }
        }
        return refused
    }

    /// Gives back every token taken (at exit).
    public static func releaseAll() {
        guard let s = symbol("sandbox_extension_release") else { return }
        let release = unsafeBitCast(s, to: Release.self)
        let taken = lock.withLock {
            defer { handles.removeAll() }
            return handles
        }
        for handle in taken { _ = release(handle) }
    }

    /// The spawner's tokens on standard input (a pipe it writes them to as JSON, then closes), taken before the
    /// helper opens anything. Standard input that isn't a pipe (/dev/null, a terminal) carries none.
    public static func consumeStandardInput() -> (tokens: Int, refused: [String]) {
        var info = stat()
        guard fstat(0, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else { return (0, []) }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty, let tokens = try? JSONDecoder().decode([String].self, from: data) else { return (0, []) }
        return (tokens.count, consume(tokens))
    }
}

/// What a boot's QEMU opens, by role (filled by PreparedDeviceBoot from the device's own paths): the spawner grants
/// exactly these to a sandboxed helper (SandboxExtension).
public nonisolated struct BootFiles: Codable, Sendable, Equatable {
    /// Written: the NAND overlay, the writable NOR, the serial FIFOs, a recording.
    public var readWrite: [String] = []
    /// Read: the base, the SecureROMs, the guest package offer.
    public var readOnly: [String] = []
    public init(readWrite: [String] = [], readOnly: [String] = []) {
        self.readWrite = readWrite
        self.readOnly = readOnly
    }

    public var grants: [SandboxExtension.Grant] {
        readWrite.map { .init(URL(fileURLWithPath: $0), .readWrite) }
            + readOnly.map { .init(URL(fileURLWithPath: $0), .read) }
    }
}
