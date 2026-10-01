#!/usr/bin/env python3
"""An Intel Mac's boot gets the budget its slower emulation needs: DeviceProfile.swift compiled for each slice.

The arm64 build keeps the Apple silicon budgets (iPod 240 s, iPad 300 s); the x86_64 build (run under Rosetta
here, natively on an Intel Mac) scales them by hostSlowdown, measured at 4-10x (DeviceProfile.hostSlowdown).
"""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import host_runtime
import subprocess, tempfile

ROOT = Path(__file__).resolve().parents[2]
main = r'''
@main struct Check {
    static func main() {
        #if arch(x86_64)
        let slowdown = 5.0
        #else
        let slowdown = 1.0
        #endif
        precondition(DeviceProfile.hostSlowdown == slowdown, "\(DeviceProfile.hostSlowdown)")
        precondition(DeviceProfile.iPodTouch2G.bootBudget == 240 * slowdown && DeviceProfile.iPad1.bootBudget == 300 * slowdown,
                     "\(DeviceProfile.iPodTouch2G.bootBudget) \(DeviceProfile.iPad1.bootBudget)")
        print("PASS \(DeviceProfile.iPodTouch2G.bootBudget) \(DeviceProfile.iPad1.bootBudget)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-slowdown-') as d:
    (Path(d) / 'main.swift').write_text(main)
    for arch in ('arm64', 'x86_64'):
        exe = f'{d}/check-{arch}'
        target = f'{arch}-apple-macos14'
        subprocess.run(['xcrun', 'swiftc', *host_runtime.swift_flags(ROOT, target=target), '-parse-as-library', '-target', target, '-module-cache-path', f'{d}/modules-{arch}',
                        str(ROOT / 'LightTouchMac/Device/DeviceProfile.swift'), f'{d}/main.swift', '-o', exe], check=True)
        out = subprocess.run(['arch', f'-{arch}', exe], check=True, capture_output=True, text=True, timeout=30).stdout.strip()
        print(f'{arch}: {out}')
print('PASS: arm64 keeps the Apple silicon boot budgets; x86_64 (Intel, or Rosetta) scales them by hostSlowdown')
