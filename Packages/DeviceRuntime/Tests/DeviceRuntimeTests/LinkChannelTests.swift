import Foundation
import Testing

@testable import DeviceRuntime

struct LinkChannelTests {
    /// A channel on a descriptor number no other test's file takes, so it is this test's to reuse, and the peer's end.
    func channel() -> (LinkChannel<AppMessage, HelperMessage>, fd: Int32, peer: Int32) {
        var sv: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0)
        let fd = fcntl(sv[0], F_DUPFD, 200)
        #expect(fd >= 200)
        close(sv[0])
        let channel = LinkChannel<AppMessage, HelperMessage>(
            fd: fd,
            queue: DispatchQueue(label: "link"),
            onMessage: { _ in },
            onClose: { _ in }
        )
        return (channel, fd, sv[1])
    }

    @Test func whatWasQueuedBeforeACloseStillArrives() throws {
        let (channel, _, peer) = channel()
        defer { close(peer) }
        let frame = try LinkChannel<AppMessage, HelperMessage>.frame(.event(.qemuExited(0)))
        #expect(channel.send(.event(.qemuExited(0))))
        channel.close()
        var delivered = [UInt8](repeating: 0, count: frame.count)
        #expect(read(peer, &delivered, frame.count) == frame.count)
    }

    /// Issue 137: the app's link wrote to another file's guarded descriptor and macOS killed the app.
    @Test func aSendAfterCloseNeverWritesToTheDescriptorsNextOwner() {
        let (channel, fd, peer) = channel()
        defer { close(peer) }
        channel.close()
        let deadline = Date() + 5
        while fcntl(fd, F_GETFD) != -1, Date() < deadline { usleep(1000) }
        var next: [Int32] = [-1, -1]
        #expect(pipe(&next) == 0)
        defer { for end in next { close(end) } }
        #expect(dup2(next[1], fd) == fd)
        defer { close(fd) }
        #expect(channel.send(.event(.qemuExited(0))))
        channel.drain()
        #expect(fcntl(next[0], F_SETFL, O_NONBLOCK) == 0)
        var byte: UInt8 = 0
        #expect(read(next[0], &byte, 1) == -1 && errno == EAGAIN)
    }
}
