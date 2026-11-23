import Foundation
import HostRuntime
import HostServiceWire
import Testing

@testable import HostServiceClient

struct WorkerGrantsTests {
    /// A sandboxed worker is granted, per request, only the file it reads and the private folder it writes into.
    @Test func eachRequestGrantsOnlyItsOwnFiles() {
        let file = DeviceFile(name: "a", path: "a", isDirectory: false, isRegular: true, size: 1)
        #expect(
            HostServiceOperation.install(ipa: "/x/app.ipa", staged: "PublicStaging/app.ipa", bundleID: "b").grants
                == [.init(URL(fileURLWithPath: "/x/app.ipa"), .read)]
        )
        #expect(
            HostServiceOperation.upload(
                source: "/x/song.m4a",
                remote: "r",
                reuse: false,
                replace: false,
                allowEmpty: false,
                root: .media
            ).grants == [.init(URL(fileURLWithPath: "/x/song.m4a"), .read)]
        )
        #expect(
            HostServiceOperation.syncLibraryFile(source: "/x/ltm-itunesdb-1", remote: "iTunes_Control/iTunes/iTunesDB")
                .grants == [.init(URL(fileURLWithPath: "/x/ltm-itunesdb-1"), .read)]
        )
        #expect(
            HostServiceOperation.download(file, destination: "/x/.LightTouch-host-1/file", root: .media).grants
                == [.init(URL(fileURLWithPath: "/x/.LightTouch-host-1"), .readWrite)]
        )
        #expect(
            HostServiceOperation.crashReports(copyTo: "/x/reports").grants
                == [.init(URL(fileURLWithPath: "/x/reports"), .readWrite)]
        )
        for operation in [
            HostServiceOperation.crashReports(copyTo: nil), .apps, .observe, .files("Downloads", root: .fileSystem),
            .delete("a", root: .media), .lockdownValue("ProductVersion")
        ] {
            #expect(operation.grants.isEmpty, "\(operation)")
        }
    }

    /// The tokens travel with the request; one written without them (no grants) still decodes.
    @Test func tokensAreOptionalOnTheWire() throws {
        var request = HostServiceRequest(id: UUID(), session: UUID(), operation: .apps)
        let plain = try JSONDecoder().decode(HostServiceRequest.self, from: JSONEncoder().encode(request))
        #expect(plain.tokens == nil)
        request.tokens = ["t"]
        #expect(try JSONDecoder().decode(HostServiceRequest.self, from: JSONEncoder().encode(request)).tokens == ["t"])
    }
}
