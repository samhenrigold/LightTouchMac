#!/usr/bin/env python3
"""A delayed startup sweep must never remove this process's new uploads."""
from pathlib import Path
import subprocess, tempfile
source=(Path(__file__).resolve().parents[1]/'LightTouchMac/DeviceServices.swift').read_text()
a=source.index('    private static let stagingSession')
b=source.index('    func sweepStaging()',a)
methods=source[a:b].replace('private ', '')
with tempfile.TemporaryDirectory(prefix='ltm-staging-') as tmp:
    tmp=Path(tmp)
    (tmp/'check.swift').write_text('import Foundation\nenum Check {\n'+methods+'''
 static func run() {
  let file=URL(fileURLWithPath:"/tmp/Temple Run.ipa")
  let first=stagingName(file), second=stagingName(file)
  precondition(first != second)
  let old="Temple_Run-01234567.ipa"
  // Simulate the directory listing returning after both new uploads started.
  let removed=[old,first,second,".","..","../escape",""].filter(isOrphanedStagingName)
  precondition(removed == [old])
  precondition(!first.contains("/"))
  let uuid=UUID().uuidString
  precondition(isOrphanedMediaUpload("audio.m4a.upload-"+uuid))
  precondition(isOrphanedMediaUpload("image.jpg.upload-"+uuid+"-"+UUID().uuidString))
  precondition(!isOrphanedMediaUpload("audio.m4a.upload-"+stagingSession+"-"+uuid))
  for name in ["audio.m4a","image.jpg",".photo-receipt","song.json","audio.m4a.upload-invalid","../image.jpg.upload-"+uuid] {
   precondition(!isOrphanedMediaUpload(name),name)
  }
  print("PASS: late sweeps preserve active uploads, canonical media and receipts; only abandoned temporary files match")
 }
}
Check.run()
''')
    subprocess.run(['xcrun','swiftc',str(tmp/'check.swift'),'-o',str(tmp/'check')],check=True)
    subprocess.run([str(tmp/'check')],check=True)
