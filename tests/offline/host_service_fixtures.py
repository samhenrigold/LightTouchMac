"""Shared real worker wire leaves for low-level C-engine unit fixtures.

These tests deliberately inject a local C boundary; the process transport is
covered separately by check-host-service-workers. An accidental remote route
fails rather than silently performing device I/O during a fixture.
"""
from pathlib import Path

def leaves(root):
    app = root / 'LightTouchMac/Services'
    return [str(app / name) for name in ['HostServiceTypes.swift', 'HostServiceResources.swift']]

def local_engine_stub(tmp):
    path = tmp / 'LocalServiceFixture.swift'
    path.write_text('''import Foundation
extension DeviceServices {
 var local: Bool { true }
 func remote(_ operation: HostServiceOperation, seconds: Double,
   progress: @escaping @Sendable (HostServiceProgress) -> Void = { _ in }) async throws -> HostServiceValue {
  fatalError("local engine fixture unexpectedly used remote transport")
 }
}
''')
    return [str(path)]
