#!/usr/bin/env python3
"""Production keyboard pointer gesture sequencing and bounds."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'LightTouchMac/DisplayView.swift').read_text()
a=s.index('    private func endKeyboardTouch()');b=s.index('    private func updateKeyboardPointer()',a)
code=r"""import Cocoa
let QEMU_IOS_TOUCH_BEGIN=0,QEMU_IOS_TOUCH_UPDATE=1,QEMU_IOS_TOUCH_END=2
@MainActor final class Check {
 final class Emulator {var keyboardInputEnabled=false}
 let emulator:Emulator?=Emulator()
 var keyboardPoint=CGPoint(x:0.5,y:0.5),keyboardTouchKeys=Set<UInt16>(),hasKeyboardPointer=false
 var touchInteractionEnabled=true,touchDown=false,pinchingGuest=false
 var scrollPoint:CGPoint?
 var sent:[Int32]=[]
 func sendVisualTouch(_ slot:Int32,_ phase:Int32,_ x:Double,_ y:Double,controller:Bool=false,keyboard:Bool=false) {
  precondition(keyboard && (0...1).contains(x) && (0...1).contains(y));sent.append(phase)
 }
"""+s[a:b].replace('private func','func')+r"""
 func key(_ code:UInt16,_ down:Bool=true,_ flags:NSEvent.ModifierFlags=[])->Bool {
  let event=NSEvent.keyEvent(with:down ? .keyDown : .keyUp,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
  return keyboardPointerKey(event,down:down)
 }
 func run() {
  precondition(key(124) && keyboardPoint.x>0.5 && sent.isEmpty && hasKeyboardPointer)
  for _ in 0..<100 { _=key(123);_=key(126) }
  precondition(keyboardPoint == .zero)
  for _ in 0..<100 { _=key(124);_=key(125) }
  precondition(keyboardPoint == CGPoint(x:1,y:1))
  _=key(49);_=key(49);_=key(123);_=key(49,false)
  precondition(sent==[0,1,2] && keyboardTouchKeys.isEmpty)
  sent=[];_=key(123,true,.shift);_=key(126,true,.shift)
  _=key(123,false);precondition(sent==[0,1,1])
  _=key(126,false);precondition(sent==[0,1,1,2])
  sent=[];_=key(49);endKeyboardTouch();endKeyboardTouch()
  precondition(sent==[0,2])
  for flags:NSEvent.ModifierFlags in [.command,.control,.option,[.control,.option]] {
   precondition(!key(49,true,flags))
  }
  emulator!.keyboardInputEnabled=true;precondition(!key(49))
  emulator!.keyboardInputEnabled=false
  for kind in 0..<3 {
   sent=[];touchDown=kind==0;pinchingGuest=kind==1;scrollPoint=kind==2 ? .zero:nil
   _=key(49);precondition(sent.isEmpty)
  }
  touchDown=false;pinchingGuest=false;scrollPoint=nil;touchInteractionEnabled=false
  _=key(49);precondition(sent.isEmpty)
  print("PASS: pointer bounds, Space hold/repeat, Shift-arrow drag, release, modifier and input-ownership gates")
 }
}
@main struct Main {@MainActor static func main(){Check().run()}}
"""
with tempfile.TemporaryDirectory() as tmp:
 tmp=Path(tmp);(tmp/'check.swift').write_text(code)
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
 subprocess.run([str(tmp/'check')],check=True)
