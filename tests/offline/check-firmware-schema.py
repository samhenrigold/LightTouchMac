#!/usr/bin/env python3
"""Actual shared catalog wire and GUI projection preserve the entire flat entry."""
from pathlib import Path
import subprocess
import tempfile
from firmwarekit_leaf import schema_sources
ROOT = Path(__file__).resolve().parents[2]
source = r'''import Foundation
@main struct Check {
 static func main() throws {
  let raw = #"{"id":"k48ap-test","board":"k48ap","product_type":"iPad1,1","version":"5.0","build":"test","released":"2011-06-07","status":"experimental","status_note":"probe","prerelease":"beta","prerelease_number":3,"source":{"kind":"ipsw","url":"https://example.com/firmware.ipsw","sha1":"abc","bytes":123,"resource":"embedded.ipsw"},"keys":{"iBoot":{"file":"iBoot.img3","iv":"iv","key":"key"},"OS":{"file":"rootfs.dmg","key":"vf"}},"recipe":{"name":"k48","version":1,"storage":"nand","system_mib":100,"data_size":"1G","options":{"appsync":true},"guest":{"arch":"armv7","gl_engine":"native"},"boot":"iboot","keybag_ramdisk_from":"k48ap-sibling"},"emulator":{"min_protocol":9},"estimates":{"prepared_bytes":1234,"peak_bytes":5678,"seconds":90}}"#
  let input=Data(raw.utf8), decoder=JSONDecoder(), encoder=JSONEncoder()
  let expected=try JSONSerialization.jsonObject(with:input) as! NSDictionary
  let wire=try decoder.decode(FirmwareWire.Entry.self,from:input)
  var gui=try decoder.decode(FirmwareCatalog.Entry.self,from:input)
  for data in [try encoder.encode(wire),try encoder.encode(gui)] {
   let actual=try JSONSerialization.jsonObject(with:data) as! NSDictionary
   precondition(actual==expected,"flat wire field was lost")
  }
  precondition(gui.profile == .iPad1 && gui.prereleaseBadge == "Beta 3" && gui.status == .experimental)
  gui.recipe?.boot="kboot";gui.source.resource="other.ipsw";gui.status = .available
  let changed=try decoder.decode(FirmwareWire.Entry.self,from:encoder.encode(gui))
  precondition(changed.recipe?.boot=="kboot" && changed.source.resource=="other.ipsw" && changed.status=="available")
  // Preparation accepts future status/source tags; the GUI retains its stricter presentation policy.
  for future in [raw.replacingOccurrences(of:"experimental",with:"future"), raw.replacingOccurrences(of:"\"kind\":\"ipsw\"",with:"\"kind\":\"future\"")] {
   _ = try decoder.decode(FirmwareWire.Entry.self,from:Data(future.utf8))
   do { _ = try decoder.decode(FirmwareCatalog.Entry.self,from:Data(future.utf8));fatalError("unknown GUI presentation accepted") } catch is DecodingError {}
  }
  let catalog=try FirmwareCatalog.load(from:URL(fileURLWithPath:CommandLine.arguments[1]))
  for entry in catalog.entries {
   let exported=try encoder.encode(entry)
   let again=try decoder.decode(FirmwareCatalog.Entry.self,from:exported)
   precondition(entry==again)
   _ = try decoder.decode(FirmwareWire.Entry.self,from:exported)
  }
  print("PASS: shared flat firmware wire retains boot, keys, identity, resource and prerelease metadata; GUI policy stays separate")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-firmware-schema-') as directory:
    tmp=Path(directory)
    (tmp/'Check.swift').write_text(source)
    subprocess.run(['xcrun','swiftc','-parse-as-library','-swift-version','5','-default-isolation','MainActor',
        '-module-cache-path',str(tmp/'modules'),*schema_sources(),
        str(ROOT/'LightTouchMac/Library/FirmwareCatalog.swift'),str(ROOT/'LightTouchMac/Device/DeviceProfile.swift'),
        str(tmp/'Check.swift'),'-o',str(tmp/'check')],check=True)
    subprocess.run([str(tmp/'check'),str(ROOT/'LightTouchMac/Resources/firmware-catalog.json')],check=True)
