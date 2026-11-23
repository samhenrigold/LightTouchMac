import Foundation
import HostRuntime

extension AppBinary {
    /// `problem` for the binary at `member` of the archive `ipa`, read off the caller's actor.
    @concurrent public static func problem(in ipa: URL, member: String, soc: Board.SoC) async -> String? {
        problem(slices { ZipMembers.data(ipa, member, range: $0) }, soc: soc, name: ipa.lastPathComponent)
    }
}
