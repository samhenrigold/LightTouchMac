#!/usr/bin/env python3
"""Native GameController snapshots exercise the production input sampler."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
display=(root/'LightTouchMac/DisplayView.swift').read_text()
a=display.index('    private func sendVisualTouch(')
b=display.index('    private func sendVisualTouch2(',a)
touch=display[a:b].replace('private func','func')
a=display.index('    private func endControllerTouch()')
b=display.index('    private func updateController()',a)
touch+=display[a:b].replace('private func','func')
with tempfile.TemporaryDirectory(prefix='ltm-controller-') as tmp:
    tmp=Path(tmp)
    (tmp/'check.swift').write_text(r'''import GameController
import Foundation
@MainActor var events:[(Int32,Int32)]=[]
let QEMU_IOS_TOUCH_END=2
@MainActor func qemu_ios_ui_touch(_ slot:Int32,_ phase:Int32,_ x:Double,_ y:Double) { events.append((slot,phase)) }
@MainActor final class Touch {
 var controllerTouch:CGPoint?
 var touchInteractionEnabled=true
 func clearTouchOverlay() {}
 func noteTouch(slot:Int,phase:Int32,x:Double,y:Double) {}
'''+touch+r'''
}
@main struct Check {
 @MainActor static func main() {
  let touch=Touch()
  touch.controllerTouch=CGPoint(x:0.5,y:0.5)
  touch.sendVisualTouch(0,0,0.1,0.2)
  precondition(events.map{$0.1}==[2,0] && touch.controllerTouch==nil)
  events=[];touch.controllerTouch=CGPoint(x:0.5,y:0.5);touch.touchInteractionEnabled=false
  touch.endControllerTouch()
  precondition(events.map{$0.1}==[2] && touch.controllerTouch==nil)
  var input=GameControllerInput()
  let controller=GCController.withExtendedGamepad(), pad=controller.extendedGamepad!
  _=input.read(controller,enabled:true,curve:1)
  pad.leftThumbstick.setValueForXAxis(1,yAxis:-1)
  var state=input.read(controller,enabled:true,curve:1)
  precondition(abs(state.roll - .pi/4)<0.00001 && abs(state.pitch + .pi/4)<0.00001)
  precondition(GameControllerInput.angle(0.09,curve:1)==0)
  precondition(GameControllerInput.angle(.nan,curve:1)==0)
  precondition(GameControllerInput.angle(0.55,curve:2)<GameControllerInput.angle(0.55,curve:1))
  pad.buttonA.setValue(1)
  state=input.read(controller,enabled:true,curve:1);precondition(state.tapBegan)
  state=input.read(controller,enabled:true,curve:1);precondition(!state.tapBegan && !state.tapEnded)
  state=input.read(controller,enabled:false,curve:1);precondition(state.tapEnded && state.roll==0)
  state=input.read(controller,enabled:true,curve:1);precondition(!state.tapBegan)
  pad.buttonA.setValue(0);_=input.read(controller,enabled:true,curve:1)
  pad.buttonA.setValue(1);precondition(input.read(controller,enabled:true,curve:1).tapBegan)
  precondition(input.read(nil,enabled:true,curve:1).tapEnded)
  precondition(!input.read(controller,enabled:true,curve:1).tapBegan)
  pad.buttonMenu.setValue(1)
  precondition(input.read(controller,enabled:true,curve:1).home)
  precondition(!input.read(controller,enabled:true,curve:1).home)
  _=input.read(controller,enabled:false,curve:1)
  precondition(!input.read(controller,enabled:true,curve:1).home)
  if let options=pad.buttonOptions {
   options.setValue(1);precondition(input.read(controller,enabled:true,curve:1).shake)
   precondition(!input.read(controller,enabled:true,curve:1).shake)
  }
  print("PASS: native controller snapshots, deadzone/curve, button edges, focus/sleep suppression and disconnect release")
 }
}
''')
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',str(root/'LightTouchMac/GameControllerInput.swift'),str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
    subprocess.run([str(tmp/'check')],check=True)
