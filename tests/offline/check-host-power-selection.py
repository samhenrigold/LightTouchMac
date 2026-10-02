#!/usr/bin/env python3
"""Actual session config selection: proven N72/5F138 default, explicit overrides."""
from pathlib import Path
import subprocess, tempfile, ast, argparse
root = Path(__file__).resolve().parents[2]
s = (root / 'tests/drivers/session-driver/single.swift').read_text()
a = s.index('struct SingleConfig: Decodable {')
b = s.index('@MainActor func runSingle', a)
config = s[a:b]
# Exercise the actual maintained CLI actions: omission must stay nil so Swift
# can choose its qualified default; false must remain an explicit override.
main = next(n for n in ast.parse((root / 'tests/sessions/check-sessions.py').read_text()).body
            if isinstance(n, ast.FunctionDef) and n.name == 'main')
start = next(i for i, n in enumerate(main.body)
             if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'power' for t in n.targets))
parser = argparse.ArgumentParser()
exec(compile(ast.Module(body=main.body[start:start + 3], type_ignores=[]), '<actual power CLI actions>', 'exec'), {'ap': parser})
assert parser.parse_args([]).host_power_gesture is None
assert parser.parse_args(['--host-power-gesture']).host_power_gesture is True
assert parser.parse_args(['--no-host-power-gesture']).host_power_gesture is False
probe = r'''
import Foundation
''' + config + r'''
@main struct Main {
 static func main() throws {
  func check(_ board: String, _ build: String?, _ override: Bool?, _ expected: Bool) throws {
   var wire: [String: Any] = ["board": board, "base": "/fixture"]
   if let override { wire["hostPowerGesture"] = override }
   let data = try JSONSerialization.data(withJSONObject: wire)
   let config = try JSONDecoder().decode(SingleConfig.self, from: data)
   precondition(config.prefersHostPowerGesture(build: build) == expected)
  }
  try check("ipod", "5F138", nil, true)
  for board in ["ipod1g", "ipad", "unknown"] {
   try check(board, "5F138", nil, false)
  }
  for build in [nil, "7E18", "8C148", "unknown"] {
   try check("ipod", build, nil, false)
  }
  try check("ipod", "5F138", false, false)
  try check("ipod", "7E18", true, true)
  try check("ipod1g", nil, true, true)
  print("PASS: actual decoded session config uses host power by default only for qualified N72/5F138; overrides retained")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='ltm-power-selection-') as temp:
 p = Path(temp) / 'check.swift'; p.write_text(probe)
 subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(p), '-o', temp + '/check'], check=True)
 subprocess.run([temp + '/check'], check=True)
