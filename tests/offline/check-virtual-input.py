#!/usr/bin/env python3
"""Production shared host adapter ordering/refusal/cancellation; no guest substitute."""
from pathlib import Path
import subprocess, tempfile, sys
root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root/'scripts'))
import device_runtime
source=r'''
import Foundation
import DeviceRuntime
@main struct Main {
 @MainActor static func main() async throws {
  let n72=try HostInputAutomation.powerOffGesture(firstGeneration:false)
  let n45=try HostInputAutomation.powerOffGesture(firstGeneration:true)
  precondition(n72.count==29 && VirtualInputEvent.valid(n72) && VirtualInputEvent.valid(n45))
  precondition(n72[0].atMilliseconds==0 && n72[1].atMilliseconds==150)
  precondition(n72[2].atMilliseconds==2650 && n72[3].atMilliseconds==6150)
  precondition(n45[3].atMilliseconds==8650 && n72.last!.atMilliseconds==9570)
  precondition(n72.last!.phase==2 && n72.last!.x==295.0/320)
  var bad=n72;bad[1].atMilliseconds = -1;precondition(!VirtualInputEvent.valid(bad))
  bad=n72;bad[8].x = .nan;precondition(!VirtualInputEvent.valid(bad))
  bad=n72;bad.removeLast();precondition(!VirtualInputEvent.valid(bad))
  do {_ = try HostInputAutomation.powerOffGesture(firstGeneration:false,knobY:480);fatalError()} catch {}
  let keyboard = try PortraitKeyboardPlan.make("qwerty 42", initialState:
      .init(numeric: false, shifted: false, automaticCapitalizationDisabled: true))
  precondition(VirtualInputEvent.valid(keyboard.events) && keyboard.events.count == 20)
  precondition(keyboard.events[0].x == 15.0/320 && keyboard.events[0].y == 296.0/480)
  precondition(keyboard.events[1].atMilliseconds == 60 && keyboard.events[2].atMilliseconds == 200)
  precondition(keyboard.events[14].x == 30.0/320 && keyboard.events[14].y == 458.0/480)
  precondition(keyboard.finalState.numeric && !keyboard.finalState.shifted)
  let cases = try PortraitKeyboardPlan.make("Zz", initialState:
      .init(numeric: false, shifted: false, automaticCapitalizationDisabled: true))
  precondition(cases.events.count == 6 && cases.events[0].x == 24.0/320 &&
      cases.events[2].x == 63.0/320 && cases.events[4].x == 63.0/320)
  for text in [".", "qé", "💡", String(repeating: "q", count: 129)] {
      do { _ = try PortraitKeyboardPlan.make(text, initialState:
          .init(numeric: false, shifted: false, automaticCapitalizationDisabled: true)); fatalError("unsupported keyboard plan accepted") }
      catch {}
  }
  do { _ = try PortraitKeyboardPlan.make("q", initialState:
      .init(numeric: false, shifted: false, automaticCapitalizationDisabled: false)); fatalError() } catch {}
  // Actual encoded protocol preserves typed generic events, not UI strings.
  let message=AppMessage.request(id:1,.inputSequence(id:99,events:n72))
  let encoded=try JSONEncoder().encode(message)
  guard case let .request(_, .inputSequence(id,events))=try JSONDecoder().decode(AppMessage.self,from:encoded) else {fatalError()}
  precondition(id==99 && events==n72)
  var replies=0, seen:[LinkRequest]=[], confirmed=false, sleeping=false
  try await HostInputAutomation.performShutdown(id:99,events:n72,timeout:3,
   request:{r in
    seen.append(r)
    switch r {
     case .inputSequence: return .ok(true)
     case .inputSequenceStatus:
      replies += 1
      if replies==1 {sleeping=true;return .inputSequenceStatus(1)}
      return .inputSequenceStatus(2)
     case .usbConnection(false): confirmed=true;return .ok(true)
     default:fatalError("unexpected \(r)")
    }
   },power:{(confirmed,sleeping,false)})
  precondition(replies==2 && seen.last == .usbConnection(false))
  var refused:[LinkRequest]=[]
  do {
   try await HostInputAutomation.performShutdown(id:100,events:n72,timeout:1,
    request:{r in refused.append(r);return .failure("old dylib")},power:{(false,false,false)})
   fatalError("refusal accepted")
  } catch HostInputAutomation.Failure.refused {}
  precondition(refused.count==1)
  var timed:[LinkRequest]=[]
  do {
   try await HostInputAutomation.performShutdown(id:101,events:n72,timeout:0.02,
    request:{r in timed.append(r);if case .inputSequenceStatus=r{return .inputSequenceStatus(1)};return .ok(true)},
    power:{(false,true,false)})
   fatalError("timeout accepted")
  } catch HostInputAutomation.Failure.timedOut {}
  precondition(timed.last == .inputSequenceCancel(id:101))
  precondition(!timed.contains(.usbConnection(false)))
  var interrupted:[LinkRequest]=[]
  do {
   try await HostInputAutomation.performShutdown(id:102,events:n72,timeout:1,
    request:{r in interrupted.append(r);if case .inputSequenceStatus=r{return .inputSequenceStatus(3)};return .ok(true)},
    power:{(false,false,false)})
   fatalError("cancel accepted")
  } catch HostInputAutomation.Failure.interrupted {}
  precondition(interrupted.last == .inputSequenceCancel(id:102))
  var cancelled:[LinkRequest]=[]
  let task=Task { @MainActor in
   try await HostInputAutomation.performShutdown(id:103,events:n72,timeout:1,
    request:{r in cancelled.append(r);if case .inputSequenceStatus=r{return .inputSequenceStatus(1)};return .ok(true)},
    power:{(false,false,false)})
  }
  while cancelled.isEmpty {await Task.yield()}
  task.cancel()
  do {try await task.value;fatalError()} catch is CancellationError {}
  precondition(cancelled.last == .inputSequenceCancel(id:103))
  print("PASS: actual DeviceRuntime N45/N72 gesture deadlines, protocol roundtrip, backlight+completion cable gate, refusal, timeout, interruption/cancellation and portrait keyboard plans")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-virtual-input-') as d:
 p=Path(d)/'check.swift';p.write_text(source)
 subprocess.run(['swiftc',*device_runtime.swift_flags(root),'-parse-as-library',
                 '-module-cache-path',d+'/modules',str(p),'-o',d+'/check'],check=True)
 subprocess.run([d+'/check'],check=True,timeout=8)
