#!/usr/bin/env python3
"""Production keyboard preference and power-state gate, with an isolated defaults domain."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'LightTouchMac/Device/EmulatorController.swift').read_text()
a=s.index('    var keyboardInputEnabled: Bool {');b=s.index('    // MARK: - Machine control',a)
source=r"""import Foundation
@MainActor final class Check {
 let defaults=UserDefaults(suiteName:"ltm-keyboard-check-"+UUID().uuidString)!
 var acceptsInput=true,isSleeping=false
 var onStatusChange:(()->Void)?
 struct Instance { func defaultsKey(_ name:String)->String { name+".device" } }
 let instance=Instance()
 func perDeviceSetting(_ name:String)->Bool { defaults.object(forKey:instance.defaultsKey(name)) as? Bool ?? defaults.object(forKey:name) as? Bool ?? true }
 final class FakeLink { var commands:[LinkCommand]=[]; func send(_ c:LinkCommand){commands.append(c)} }
 let fake=FakeLink()
 var link:FakeLink? {fake}
 var sent:[Bool] { fake.commands.compactMap { if case let .key(_,down)=$0 {down} else {nil} } }
"""+s[a:b].replace('UserDefaults.standard','defaults')+r"""
 func run() {
  precondition(keyboardInputEnabled)
  var changes=0;onStatusChange={changes+=1}
  sendKey(macKeyCode:0,down:true);precondition(sent==[true])
  toggleKeyboardInput();precondition(!keyboardInputEnabled && changes==1)
  sendKey(macKeyCode:0,down:true);sendKey(macKeyCode:0,down:false)
  precondition(sent==[true,false],"release must remain possible after disabling")
  toggleKeyboardInput();precondition(keyboardInputEnabled && changes==2)
  isSleeping=true;sendKey(macKeyCode:0,down:true)
  isSleeping=false;acceptsInput=false;sendKey(macKeyCode:0,down:true)
  precondition(sent==[true,false],"sleeping/stopped devices must not receive key presses")
  print("PASS: keyboard toggle, disabled/sleep/stopped gating and release delivery")
 }
}
@main struct Main {@MainActor static func main(){Check().run()}}
"""
with tempfile.TemporaryDirectory() as tmp:
 tmp=Path(tmp);(tmp/'check.swift').write_text(source)
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(root/'Shared/DeviceLinkProtocol.swift'),str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
 subprocess.run([str(tmp/'check')],check=True)
