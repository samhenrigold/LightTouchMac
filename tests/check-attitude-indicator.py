#!/usr/bin/env python3
"""Render the production horizon and exercise its accessible Level button."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='ltm-attitude-') as tmp:
    tmp=Path(tmp)
    (tmp/'check.swift').write_text(r'''import Cocoa
@MainActor final class Target:NSObject {
 var leveled=false
 @objc func level(_ sender:Any?){leveled=true}
}
@main struct Check {
 @MainActor static func main() throws {
  _=NSApplication.shared
  let button=AttitudeIndicatorButton(frame:NSRect(x:0,y:0,width:40,height:40))
  let target=Target();button.target=target;button.action=#selector(Target.level(_:))
  button.performClick(nil);precondition(target.leveled)
  func render(_ name:String)throws->Data {
   let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:40,pixelsHigh:40,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:160,bitsPerPixel:32)!
   NSGraphicsContext.saveGraphicsState()
   NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
   button.draw(button.bounds)
   NSGraphicsContext.restoreGraphicsState()
   let data=bitmap.representation(using:.png,properties:[:])!
   try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name))
   return data
  }
  let level=try render("level.png")
  button.update(pitch:.pi/6,roll:.pi/6)
  let tilted=try render("tilted.png")
  precondition(level != tilted)
  precondition((button.accessibilityValue() as? String)?.contains("30°")==true)
  print("PASS: 40-point horizon rendering, pitch/roll accessibility and Level action")
 }
}
''')
    subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',str(root/'LightTouchMac/AttitudeIndicatorButton.swift'),str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
    subprocess.run([str(tmp/'check'),str(tmp)],check=True)
    from PIL import Image
    images=[Image.open(tmp/name).convert('RGBA').resize((160,160)) for name in ['level.png','tilted.png']]
    canvas=Image.new('RGBA',(320,160),(0,0,0,255))
    for i,image in enumerate(images): canvas.paste(image,(i*160,0),image)
    canvas.save('/tmp/ltm-attitude-check.png')
