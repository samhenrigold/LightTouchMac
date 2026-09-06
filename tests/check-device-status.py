#!/usr/bin/env python3
"""Native status layout, accessibility labels and enabled/toggled state."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='ltm-status-') as tmp:
 tmp=Path(tmp)
 (tmp/'check.swift').write_text(r"""import Cocoa
@MainActor class MainWindowController:NSWindowController {
 @objc func configureBattery(_ sender:Any?) {}
 @objc func configureWebProxy(_ sender:Any?) {}
 @objc func toggleKeyboardInput(_ sender:Any?) {}
}
@main struct Check {
 @MainActor static func main() {
  _ = NSApplication.shared
  let status=DeviceStatusView(frame:.zero)
  let host=NSView(frame:NSRect(x:0,y:0,width:240,height:300))
  host.addSubview(status);status.translatesAutoresizingMaskIntoConstraints=false
  NSLayoutConstraint.activate([status.topAnchor.constraint(equalTo:host.topAnchor),status.leadingAnchor.constraint(equalTo:host.leadingAnchor),status.trailingAnchor.constraint(equalTo:host.trailingAnchor)])
  for width in [240.0,400.0] {
   host.frame.size.width=width
   status.update(status:"Storage write failed; device stopped",batteryLevel:9,charging:"On battery",proxyStatus:"HTTP proxy connected through your Mac",agentStatus:"Not responding",keyboardInput:false,canConfigureBattery:false,canConfigureProxy:true)
   host.layoutSubtreeIfNeeded()
   precondition(status.frame.height>80 && status.frame.height<200)
   for row in status.arrangedSubviews {
    precondition(row.frame.width>0 && row.frame.minX>=0 && row.frame.maxX<=width, "width=\(width) status=\(status.frame) row=\(row.frame)")
   }
   let buttons=status.arrangedSubviews.compactMap{$0 as? NSButton}
   precondition(buttons.count==3 && !buttons[0].isEnabled && buttons[1].isEnabled && buttons[2].state == .off)
   precondition(buttons[0].accessibilityLabel()==buttons[0].title)
   precondition(buttons[1].toolTip==buttons[1].title)
   status.update(status:"Running",batteryLevel:96,charging:"Charging",proxyStatus:"Disabled",agentStatus:"Connected",keyboardInput:true,canConfigureBattery:true,canConfigureProxy:false)
   precondition(buttons[0].isEnabled && !buttons[1].isEnabled && buttons[2].state == .on)
  }
  print("PASS: status states, full accessibility labels and 240/400-point layout")
 }
}
""")
 subprocess.run(['xcrun','swiftc','-default-isolation','MainActor',str(root/'LightTouchMac/DeviceStatusView.swift'),str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
 subprocess.run([str(tmp/'check')],check=True)
