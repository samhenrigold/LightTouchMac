#!/usr/bin/env python3
"""Production keyboard preference and power-state gate, with an isolated defaults domain."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'LightTouchMac/EmulatorController.swift').read_text()
a=s.index('    var keyboardInputEnabled: Bool {');b=s.index('    // MARK: - Machine control',a)
source=r"""import Foundation
@MainActor final class Check {
 let defaults=UserDefaults(suiteName:"ltm-keyboard-check-"+UUID().uuidString)!
 var acceptsInput=true,isSleeping=false
 var onStatusChange:(()->Void)?
 var sent:[Bool]=[]
 func qemu_ios_ui_key_mac(_ code:Int32,_ down:Bool) {sent.append(down)}
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
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
 subprocess.run([str(tmp/'check')],check=True)
