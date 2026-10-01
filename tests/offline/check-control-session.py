#!/usr/bin/env python3
"""Late helper control replies must not mutate a subsequent boot."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
controller = (root/'LightTouchMac/Device/EmulatorController.swift').read_text()
start = controller.index('    private func control(')
end = controller.index('    // MARK: Battery', start)
method = controller[start:end].replace('private func control', 'func control', 1)
source = r'''import Foundation
enum LinkRequest { case test }
enum Reply { case ok(Bool) }
@MainActor final class FakeLink {
    var replies: [(Result<Reply, Error>) -> Void] = []
    func request(_ request: LinkRequest, done: @escaping (Result<Reply, Error>) -> Void) { replies.append(done) }
}
@MainActor final class Controller {
    let bootScope = BootSessionScope()
    var link: FakeLink? = FakeLink()
''' + method + r'''}
@main struct Probe {
    @MainActor static func main() {
        let c = Controller()
        var applied = 0
        c.control(.test) { if $0 { applied += 1 } }
        c.bootScope.retire()
        c.bootScope.renew()
        c.control(.test) { if $0 { applied += 10 } }
        c.link!.replies[0](.success(.ok(true)))
        precondition(applied == 0)
        c.link!.replies[1](.success(.ok(true)))
        precondition(applied == 10)
        c.bootScope.retire()
        c.link!.replies[1](.success(.ok(true)))
        precondition(applied == 10)
        print("PASS: old and retired helper replies cannot mutate a later boot")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-control-session-') as temporary:
    folder = Path(temporary)
    main = folder/'main.swift'; main.write_text(source)
    binary = folder/'probe'
    subprocess.run(['xcrun','swiftc','-parse-as-library',str(root/'LightTouchMac/Device/BootSessionScope.swift'),str(main),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
