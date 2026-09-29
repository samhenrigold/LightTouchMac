#!/usr/bin/env python3
"""Every listing of the firmware catalog is per board, versions ascending (2.1.1, 3.1.3, 4.2.1; 3.2, 3.2.2, 4.2.1).

FirmwareCatalog.load sorts on load: boards keep the order the file introduces them, entries within
a board sort by numeric version (build as the tiebreak), whatever order the JSON has. The shipped
catalog must load in that order too.
"""
from pathlib import Path
import json, subprocess, tempfile

root = Path(__file__).resolve().parents[1]
shipped = root / "LightTouchMac/Resources/firmware-catalog.json"
source = r'''import Foundation
@main struct Check {
 static func main() throws {
  let args = CommandLine.arguments
  let c = try FirmwareCatalog.load(from: URL(fileURLWithPath: args[1]))
  let order = c.entries.map { "\($0.board) \($0.version) \($0.build)" }
  precondition(order == ["n72ap 2.1.1 5F138", "n72ap 3.1.3 7E18", "n72ap 3.1.3 7E18b", "n72ap 4.2.1 8C148", "k48ap 3.2 7B367", "k48ap 3.2.2 7B500", "k48ap 4.2.1 8C148"], "\(order)")
  let s = try FirmwareCatalog.load(from: URL(fileURLWithPath: args[2]))
  for board in Set(s.entries.map(\.board)) {
   let versions = s.entries.filter { $0.board == board }.map { $0.version.split(separator: ".").map { Int($0) ?? 0 } }
   precondition(versions == versions.sorted { $0.lexicographicallyPrecedes($1) }, "\(board): \(versions)")
  }
  print("PASS: catalog entries list per board by version ascending, build as the tiebreak; the shipped catalog too")
 }
}
'''
def entry(board, product, version, build):
    return {"id": f"{board}-{build}", "board": board, "product_type": product, "version": version, "build": build, "status": "available",
            "source": {"kind": "ipsw"}, "keys": {}, "emulator": {"min_protocol": 1},
            "estimates": {"seconds": 1, "prepared_bytes": 1, "peak_bytes": 1}}
fixture = {"format": 1, "entries": [entry("n72ap", "iPod2,1", "3.1.3", "7E18b"), entry("n72ap", "iPod2,1", "3.1.3", "7E18"),
                                    entry("n72ap", "iPod2,1", "4.2.1", "8C148"), entry("k48ap", "iPad1,1", "3.2.2", "7B500"),
                                    entry("n72ap", "iPod2,1", "2.1.1", "5F138"), entry("k48ap", "iPad1,1", "3.2", "7B367"),
                                    entry("k48ap", "iPad1,1", "4.2.1", "8C148")]}
with tempfile.TemporaryDirectory(prefix="ltm-catalog-order-") as d:
    p = Path(d) / "check.swift"
    p.write_text(source)
    (Path(d) / "catalog.json").write_text(json.dumps(fixture))
    subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", d + "/modules", str(root / "LightTouchMac/FirmwareCatalog.swift"),
                    str(root / "LightTouchMac/DeviceProfile.swift"), str(p), "-o", d + "/check"], check=True)
    subprocess.run([d + "/check", d + "/catalog.json", str(shipped)], check=True, timeout=20)
