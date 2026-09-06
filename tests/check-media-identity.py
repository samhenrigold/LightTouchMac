#!/usr/bin/env python3
"""Content IDs and bounded normalization of generated M4A timestamps."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='ltm-identity-') as tmp:
    tmp=Path(tmp)
    (tmp/'check.swift').write_text(r'''import Foundation
enum DeviceToolsError:Error { case failed(String) }
@main struct Check {
 static func main() throws {
  let file=URL(fileURLWithPath:CommandLine.arguments[1])
  func word(_ n:UInt32)->Data { Data([UInt8(n>>24),UInt8((n>>16)&255),UInt8((n>>8)&255),UInt8(n&255)]) }
  func atom(_ kind:String,_ data:Data)->Data { word(UInt32(data.count+8))+Data(kind.utf8)+data }
  var payload=Data(repeating:0x55,count:32);payload[0]=1
  let movie=atom("moov",atom("trak",atom("mdia",atom("mdhd",payload))))+atom("mdat",Data("unchanged audio".utf8))
  try movie.write(to:file)
  try MediaIdentity.normalizeGeneratedM4A(file)
  payload.replaceSubrange(4..<20,with:Data(count:16))
  let expected=atom("moov",atom("trak",atom("mdia",atom("mdhd",payload))))+atom("mdat",Data("unchanged audio".utf8))
  let normalized=try Data(contentsOf:file);precondition(normalized==expected)
  let first=try MediaIdentity.identifier(for:file)
  try MediaIdentity.normalizeGeneratedM4A(file)
  let second=try MediaIdentity.identifier(for:file);precondition(second==first && UUID(uuidString:first) != nil)
  try Data("different".utf8).write(to:file)
  let changed=try MediaIdentity.identifier(for:file);precondition(changed != first)
  let bad=[Data([0,0,0,4])+Data("mvhd".utf8),
           word(1)+Data("moov".utf8)+Data(repeating:255,count:8),
           atom("mvhd",Data([2,0,0,0])+Data(count:16)),Data([0,0,0]),
           atom("moov",atom("moov",atom("moov",atom("moov",atom("moov",Data())))))]
  for data in bad {
   try data.write(to:file)
   do { try MediaIdentity.normalizeGeneratedM4A(file);fatalError("accepted invalid atom structure") } catch {}
  }
  print("PASS: content IDs, exact timestamp normalization, idempotence and malformed/version/depth bounds")
 }
}
''')
    subprocess.run(['xcrun','swiftc','-swift-version','5',str(root/'LightTouchMac/MediaIdentity.swift'),str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
    subprocess.run([str(tmp/'check'),str(tmp/'media.m4a')],check=True)
