#!/usr/bin/env python3
"""Physical sizing must reject fallback metadata and preserve measured sizes."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='ltm-display-') as directory:
 work=Path(directory)
 (work/'check.swift').write_text('''import AppKit
@main struct Check {
 static func main() {
  let logical=CGSize(width:1512,height:982)
  let mm=CGSize(width:302.4,height:196.4)
  let value=DisplayMeasurements.pointsPerMillimeter(logical:logical,hardware:mm,fallbackBounds:logical)!
  precondition(abs(value * 110 - 550) < 0.01)
  let fallback=CGSize(width:1512 * 25.4 / 72,height:982 * 25.4 / 72)
  precondition(DisplayMeasurements.pointsPerMillimeter(logical:logical,hardware:fallback,fallbackBounds:logical)==nil)
  precondition(DisplayMeasurements.pointsPerMillimeter(logical:logical,hardware:.zero,fallbackBounds:logical)==nil)
  precondition(DisplayMeasurements.pointsPerMillimeter(logical:logical,hardware:CGSize(width:100,height:500),fallbackBounds:logical)==nil)
  print("PASS: measured physical dimensions, synthetic 72dpi fallback, absent and inconsistent metadata")
 }
}''')
 subprocess.run(['swiftc','-module-cache-path',str(work/'modules'),str(root/'LightTouchMac/UI/DisplayMeasurements.swift'),str(work/'check.swift'),'-o',str(work/'check')],check=True)
 subprocess.run([str(work/'check')],check=True)
