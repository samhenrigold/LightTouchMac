#!/usr/bin/env python3
"""Saved guest-network choice and explicit CLI overrides do not show a prompt."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
import subprocess,tempfile
DEVICE_PROFILE = str(Path(__file__).resolve().parents[2] / 'LightTouchMac/Device/DeviceProfile.swift')
root=Path(__file__).resolve().parents[2]
fixture=r'''import Cocoa
@main struct Check {
 @MainActor static func main() {
  _=NSApplication.shared
  let defaults=UserDefaults.standard
  defer {defaults.removeObject(forKey:NetworkAccessPreference.key)}
  let explicit=CommandLine.arguments.contains("--network") || CommandLine.arguments.contains("--no-network")
  for saved in [true,false] {
   defaults.set(saved,forKey:NetworkAccessPreference.key)
   let network=NetworkAccessPreference.resolve(profile: .iPodTouch2G)
   precondition(network == (explicit ? !CommandLine.arguments.contains("--no-network") : saved))
   precondition(defaults.bool(forKey:NetworkAccessPreference.key)==saved)
  }
  print("PASS: remembered guest-network choice and explicit command-line override")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-network-') as directory:
 work=Path(directory);(work/'check.swift').write_text(fixture)
 subprocess.run(['swiftc', *host_runtime.swift_flags(Path(__file__).resolve().parents[2]), DEVICE_PROFILE,'-default-isolation','MainActor','-module-cache-path',str(work/'modules'),str(root/'LightTouchMac/App/NetworkAccessPreference.swift'),str(work/'check.swift'),'-o',str(work/'check')],check=True)
 for flags in [[],['--network'],['--no-network']]:
  subprocess.run([str(work/'check'),*flags],check=True,timeout=10)
