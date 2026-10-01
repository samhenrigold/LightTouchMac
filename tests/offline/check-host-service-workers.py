#!/usr/bin/env python3
"""Actual worker process ownership under a blocked libimobiledevice C factory."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import swift_subprocess
import host_service
with tempfile.TemporaryDirectory(prefix='ltm-host-workers-') as directory:
    tmp = Path(directory)
    flags = swift_subprocess.swift_flags(ROOT)
    common = ['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(tmp / 'modules'), *flags,
              *host_service.client_sources(ROOT)]
    worker = Path(os.environ.get('LTM_HOST_SERVICE_WORKER', tmp / 'LightTouchServices'))
    if not os.environ.get('LTM_HOST_SERVICE_WORKER'):
        host_service.build_worker(ROOT, worker, flags)
    shim = tmp / 'shim.c'
    shim.write_text(r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int idevice_new(void **device, const char *udid) {
 const char *socket = getenv("USBMUXD_SOCKET_ADDRESS");
 FILE *f=fopen(getenv("LTM_WORKER_PROBE_LOG"),"a");
 fprintf(f,"%ld %s %s\n",(long)getpid(),socket,udid?udid:"nil"); fclose(f);
 if (!udid || (strstr(socket,":31431") && strcmp(udid,"A")) || (strstr(socket,":31432") && strcmp(udid,"B"))) return -1;
 if (strstr(socket,":31431")) while (access(getenv("LTM_WORKER_PROBE_RELEASE"),F_OK)) usleep(10000);
 *device=(void*)1; return 0;
}
int idevice_free(void *device) { return 0; }
int np_client_start_service(void *device, void **client, const char *label) { *client=(void*)2;return 0; }
int np_client_free(void *client) { return 0; }
int np_observe_notification(void *client, const char *name) { return 0; }
int np_set_notify_callback(void *client, void *cb, void *ctx) { return 0; }
''')
    subprocess.run(['clang', '-dynamiclib', str(shim), '-o', str(tmp / 'libimobiledevice-1.0.dylib')], check=True)
    harness = tmp / 'Check.swift'
    harness.write_text(r'''
import Foundation
func logEvent(_ value: String) {}
@main struct Check {
 static func main() async throws {
  let dir=URL(fileURLWithPath:CommandLine.arguments[1]), release=dir.appendingPathComponent("release")
  let log=dir.appendingPathComponent("calls")
  Timeouts.serviceProbe=0.1
  let a=DeviceServices(clientSocket:"127.0.0.1:31431",udid:"A",session:UUID())
  let b=DeviceServices(clientSocket:"127.0.0.1:31432",udid:"B",session:UUID())
  let stalled=Task { try await a.checkAttachment() }
  let limit=ContinuousClock.now + .seconds(5)
  while !FileManager.default.fileExists(atPath:log.path) {
   precondition(ContinuousClock.now<limit,"worker never entered C factory")
   try await Task.sleep(for:.milliseconds(2))
  }
  setenv("USBMUXD_SOCKET_ADDRESS","127.0.0.1:1",1) // Deliberately poison the GUI's global endpoint.
  try await b.checkAttachment()
  do { try await stalled.value; fatalError("stalled worker succeeded") }
  catch DeviceError.timedOut {}
  let rows=try String(contentsOf:log,encoding:.utf8).split(separator:"\n").map { $0.split(separator:" ") }
  precondition(rows.contains { $0[1]=="127.0.0.1:31432" && $0[2]=="B" },"B was blocked or misrouted")
  let oldPID=Int32(rows.first { $0[1]=="127.0.0.1:31431" }![0])!
  precondition(kill(oldPID,0) != 0 && errno==ESRCH,"deadline returned before stalled process was reaped")
  try Data().write(to:release)
  try await a.checkAttachment() // Same endpoint's replacement worker, same immutable UDID.
  let newer=try String(contentsOf:log,encoding:.utf8).split(separator:"\n").map { $0.split(separator:" ") }
  let freshPID=Int32(newer.last { $0[1]=="127.0.0.1:31431" }![0])!
  precondition(freshPID != oldPID,"worker was not restarted")
  // Caller cancellation must reap a child still blocked in actual C.
  try FileManager.default.removeItem(at: release)
  Timeouts.serviceProbe=10
  let cancelScope=DeviceServices(clientSocket:a.endpoint.socket,udid:"A",session:UUID())
  let beforeCancel=newer.count
  let cancelled=Task { try await cancelScope.checkAttachment() }
  var cancelRows=newer
  while cancelRows.count == beforeCancel {
   try await Task.sleep(for:.milliseconds(2))
   cancelRows=try String(contentsOf:log,encoding:.utf8).split(separator:"\n").map { $0.split(separator:" ") }
  }
  let cancelledPID=Int32(cancelRows.last![0])!
  cancelled.cancel()
  do { try await cancelled.value;fatalError("cancelled C child succeeded") } catch is CancellationError {}
  precondition(kill(cancelledPID,0) != 0 && errno==ESRCH,"cancellation returned before child reap")
  await cancelScope.stopWorker()
  // Scope teardown also owns the independent notification subscription child.
  let observerScope=DeviceServices(clientSocket:a.endpoint.socket,udid:"A",session:UUID())
  let observation=Task { await HostServiceWorkers.shared.observe(endpoint:observerScope.endpoint,onChange:{}) }
  var observerRows=cancelRows
  while observerRows.count == cancelRows.count {
   try await Task.sleep(for:.milliseconds(2))
   observerRows=try String(contentsOf:log,encoding:.utf8).split(separator:"\n").map { $0.split(separator:" ") }
  }
  let observerPID=Int32(observerRows.last![0])!
  await observerScope.stopWorker()
  _ = await observation.value
  precondition(kill(observerPID,0) != 0 && errno==ESRCH,"teardown left notification child alive")
  await a.stopWorker(); await b.stopWorker()
  precondition(kill(freshPID,0) != 0 && errno==ESRCH,"scope stop left a host worker alive")
  do { try await a.checkAttachment();fatalError("retired boot session reopened") } catch is CancellationError {}
  print("PASS: C-stalled A reaped, B independently routed, A worker restarted, immutable UDIDs, caller cancellation and observer teardown reaped, scope retired")
 }
}
''')
    subprocess.run([*common, '-parse-as-library', str(harness), '-o', str(tmp / 'check')], check=True)
    env = os.environ | {'LTM_HOST_SERVICE_WORKER': str(worker), 'LTM_SERVICE_FRAMEWORKS': str(tmp),
        'LTM_WORKER_PROBE_LOG': str(tmp / 'calls'), 'LTM_WORKER_PROBE_RELEASE': str(tmp / 'release')}
    subprocess.run([str(tmp / 'check'), str(tmp)], env=env, check=True, timeout=20)
