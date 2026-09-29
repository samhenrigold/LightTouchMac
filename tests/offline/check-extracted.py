#!/usr/bin/env python3
"""Compile the actual small boundary/locking helpers, without loading QEMU."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[2]
def block(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]
once = (root/'LightTouchMac/Transport/DeviceExecution.swift').read_text()   # ResumeOnce is file-private, so the whole file goes in
inspector = (root/'LightTouchMac/UI/AppsInspectorViewController.swift').read_text()
freshness = block(inspector, '    static func freshnessText(', '    private func showStaleBanner')
source = '''import Foundation
nonisolated func logEvent(_ message: String) {}
import Dispatch
enum Archive {\n''' + freshness + '''}\n''' + once + '''
@main struct Check {
 static func main() async throws {
  precondition(IPAMembers.appRoot(["Payload/One.app/Info.plist", "Payload/One.app/Nested.app/Info.plist"]) == "Payload/One.app/")
  precondition(IPAMembers.appRoot(["Payload/One.app/Info.plist", "Payload/Two.app/Info.plist"]) == nil)
  precondition(IPAMembers.appRoot(["Elsewhere.app/Info.plist"]) == nil)
  precondition(IPAMembers.appRoot(["Payload/One.app/Info.plist", "Payload/One.app/Info.plist"]) == nil)
  let now = Date()
  precondition(Archive.freshnessText(since: nil, now: now) == "not yet refreshed")
  for offset in [0.0, -0.5, -59, 1] {
   precondition(Archive.freshnessText(since: now.addingTimeInterval(offset), now: now) == "last updated just now")
  }
  precondition(!Archive.freshnessText(since: now.addingTimeInterval(-120), now: now).contains("in "))
  let once = ResumeOnce<Int>()
  let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
  let counter = Counter()
  let winner = Task.detached {
   once.resume(.success(1), onWin: { entered.signal(); release.wait(); counter.add(1) })
  }
  await Task.detached { blockingWait(entered) }.value
  let loser = Task.detached { if !once.resume(.success(2)) { counter.add(-1) } }
  release.signal()
  _ = await winner.value; await loser.value
  precondition(counter.value == 0)
  let result = try await withCheckedThrowingContinuation { once.attach($0) }
  precondition(result == 1)
  print("PASS: unique root IPA identity and timeout accounting serialized before losing worker returns")
 }
}
func blockingWait(_ semaphore: DispatchSemaphore) { semaphore.wait() }
final class Counter: @unchecked Sendable {
 private let lock = NSLock()
 private var n = 0
 func add(_ d: Int) { lock.withLock { n += d } }
 var value: Int { lock.withLock { n } }
}
'''
with tempfile.TemporaryDirectory() as work:
    swift=Path(work)/'check.swift';swift.write_text(source)
    executable=Path(work)/'check'
    subprocess.run(['swiftc','-parse-as-library','-module-cache-path','/tmp/ltm-module-cache',str(root/'LightTouchMac/Library/IPAMembers.swift'),
                    str(swift),'-o',str(executable)],check=True)
    subprocess.run([str(executable)],check=True)
