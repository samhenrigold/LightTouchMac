#!/usr/bin/env python3
"""Run the actual AppDelegate termination policy in an isolated NSApplication.

No user app or guest is opened. Desktop access is needed for AppKit's real
modal run loop. The failing old main-queue entry is demonstrated in a child
process with a timeout; all fixed paths must terminate normally.
"""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'LightTouchMac/AppDelegate.swift').read_text()
a=s.index('    static func requestTermination()');b=s.index('    @objc func showDeviceWindow',a)
request=s[a:b]
a=s.index('    func applicationShouldTerminate(');b=s.index('    func applicationShouldTerminateAfterLastWindowClosed',a)
terminate=s[a:b]
source=r'''import AppKit
@MainActor let mode=CommandLine.arguments[1]
@MainActor func logEvent(_ s:String){print(s);fflush(stdout)}
@MainActor enum AppInstaller {
 static let hasPendingWork=false
 static func cancelPendingWork(){}
}
@MainActor final class MainWindowController {
 let hasFileTransfer=false
 func cancelFileTransfer(){}
 func finishRecordingBeforeQuit()->Bool{false}
}
@MainActor final class EmulatorController {
 static let stopBudget=0.25
 let isInstalling=false,isDead=false,isPoweredOff=false,isErasing=false
 var requests=0
 func cancelFactoryReset(){}
 func halt(completion:@escaping(Bool)->Void){
  requests+=1;logEvent("shutdown-started")
  if mode=="backstop"{return}
  if mode=="synchronous"{completion(true);return}
  Task {
   logEvent("shutdown-task-began")
   try? await Task.sleep(for:.milliseconds(100))
   logEvent("shutdown-task-finished");completion(true)
  }
 }
}
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
 private var windowController:MainWindowController?
 private var emulators=[EmulatorController()]
 private var awaitingTermination=false
 private var terminationBackstop:Task<Void,Never>?
'''+request+terminate+r'''
 func applicationDidFinishLaunching(_ notification:Notification){
  logEvent("launched")
  if mode=="system-entry" {
   let timer=Timer(timeInterval:0.01,repeats:false){_ in
    MainActor.assumeIsolated{NSApp.terminate(nil)}
   };RunLoop.main.add(timer,forMode:.common)
  } else {
   DispatchQueue.main.async {
    if mode=="old-entry" {NSApp.terminate(nil)} else {
     Self.requestTermination()
     if mode=="repeated" {
      Self.requestTermination()
      DispatchQueue.main.asyncAfter(deadline:.now()+0.02){Self.requestTermination()}
     }
    }
   }
  }
 }
 func applicationWillTerminate(_ notification:Notification){
  precondition(emulators[0].requests==1)
  logEvent("terminated-once")
 }
}
@main struct Main {
 @MainActor static func main(){
  let app=NSApplication.shared, delegate=AppDelegate()
  app.delegate=delegate;app.setActivationPolicy(.prohibited);app.run()
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-quit-') as d:
 p=Path(d)/'check.swift';p.write_text(source)
 binary=d+'/check'
 subprocess.run(['swiftc','-parse-as-library','-swift-version','5','-module-cache-path',d+'/modules',str(p),'-o',binary],check=True)
 for mode in ['normal','repeated','synchronous','backstop','system-entry']:
  result=subprocess.run([binary,mode],capture_output=True,text=True,timeout=4)
  assert result.returncode==0 and 'terminated-once' in result.stdout,(mode,result.returncode,result.stdout,result.stderr)
  if mode in ['normal','system-entry']:assert 'shutdown-task-finished' in result.stdout
  if mode=='backstop':assert 'did not finish in time' in result.stdout
 # This confirms the cause, rather than merely asserting source patterns.
 try:
  result=subprocess.run([binary,'old-entry'],capture_output=True,text=True,timeout=1)
 except subprocess.TimeoutExpired as failure:
  output=failure.stdout or b''
  assert b'shutdown-started' in output and b'shutdown-task-began' not in output,output
 else:
  # Newer AppKit may fix this queue-reentrancy behavior; accepting a clean
  # completion keeps the test useful without encoding an OS bug forever.
  assert result.returncode==0 and 'terminated-once' in result.stdout,result
 print('PASS: real AppKit Quit from main queue, repeated Quit, synchronous completion, bounded fallback and native system-style entry')
