#!/usr/bin/env python3
"""The actual SpringBoard job and preference edits the component upgrade applies (GuestServices)."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'LightTouchMac/GuestServices.swift').read_text()
a = source.index('    static func lockButtonPreferences(')
b = source.index('    /// "it_agent v<N>" inside the binary', a)
method = source[a:b]
with tempfile.TemporaryDirectory(prefix='ltm-media-') as work:
    work = Path(work)
    swift = work / 'check.swift'
    swift.write_text(r'''import Foundation
enum DeviceToolsError: Error { case failed(String) }
enum Check {
''' + method + r'''}
let job: [String: Any] = ["Label": "com.apple.SpringBoard", "ProgramArguments": ["/System/Library/CoreServices/SpringBoard.app/SpringBoard"], "KeepAlive": true, "EnvironmentVariables": ["CA_ENABLE_OGL": "0", "OTHER": "untouched", "CA_ENABLE_MBX2D": "0"]]
for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
 let original = try PropertyListSerialization.data(fromPropertyList: job, format: format, options: 0)
 let updated = try Check.mediaLaunchConfiguration(original)!
 var actualFormat = PropertyListSerialization.PropertyListFormat.xml
 let decoded = try PropertyListSerialization.propertyList(from: updated, format: &actualFormat) as! [String: Any]
 precondition(actualFormat == format)
 var expected = job
 expected["EnvironmentVariables"] = ["CA_ENABLE_OGL": "1", "LK_ENABLE_OGL": "1", "OTHER": "untouched", "CA_ENABLE_MBX2D": "0"]
 precondition(NSDictionary(dictionary: decoded).isEqual(to: expected))
 let repeated = try Check.mediaLaunchConfiguration(updated)
 precondition(repeated == nil)
}
for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
 let prefs: [String: Any] = ["SBDontLockEver": true, "SBDisableCABlanking": true, "SBAutoLockTime": -1, "iconState2": ["untouched"]]
 let original = try PropertyListSerialization.data(fromPropertyList: prefs, format: format, options: 0)
 let updated = try Check.lockButtonPreferences(original)!
 var actualFormat = PropertyListSerialization.PropertyListFormat.xml
 let decoded = try PropertyListSerialization.propertyList(from: updated, format: &actualFormat) as! [String: Any]
 precondition(actualFormat == format && decoded["SBDontLockEver"] == nil && decoded["SBDisableCABlanking"] == nil)
 precondition(decoded["SBAutoLockTime"] as? Int == -1 && decoded["iconState2"] as? [String] == ["untouched"])
 let repeated = try Check.lockButtonPreferences(updated); precondition(repeated == nil)
}
do { _ = try Check.lockButtonPreferences(Data("broken".utf8)); fatalError("accepted corrupt preferences") } catch {}
for invalid: Any in [["Label": "wrong"], ["Label": "com.apple.SpringBoard", "EnvironmentVariables": "bad"], ["array"]] {
 let data = try PropertyListSerialization.data(fromPropertyList: invalid, format: .binary, options: 0)
 do { _ = try Check.mediaLaunchConfiguration(data); fatalError("accepted invalid job") } catch {}
}
do { _ = try Check.mediaLaunchConfiguration(Data("broken".utf8)); fatalError("accepted corrupt plist") } catch {}
''')
    executable = work / 'check'
    subprocess.run(['swiftc', '-module-cache-path', '/tmp/ltm-module-cache', str(swift), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
print('PASS: XML/binary media upgrade preserves settings, is idempotent, rejects corrupt jobs')
